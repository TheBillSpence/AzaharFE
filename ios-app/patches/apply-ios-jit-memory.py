#!/usr/bin/env python3
"""Patch the pinned Oaknut/Dynarmic submodules in Actions for iOS 27 universal.js JIT.

The upstream submodules are immutable gitlinks in this repository. Apply
strict, version-specific source edits in the CI workspace and fail on drift.
"""
from pathlib import Path


def replace(source: str, before: str, after: str, label: str, count: int = 1) -> str:
    found = source.count(before)
    if found != count:
        raise SystemExit(f"{label}: expected {count} matching regions, found {found}")
    return source.replace(before, after)


oaknut = Path("externals/oaknut/include/oaknut/code_block.hpp")
source = oaknut.read_text()
if "#include <new>\n" not in source:
    raise SystemExit("Oaknut missing expected <new> header")
source = replace(source, "#    include <TargetConditionals.h>\n",
                 "#    include <mach/mach.h>\n#    include <mach/vm_map.h>\n"
                 "#    include <TargetConditionals.h>\n", "Mach headers")
source = replace(
    source,
    "namespace oaknut {\n\nclass CodeBlock {",
    """namespace oaknut {

#if defined(__APPLE__) && TARGET_OS_IPHONE && defined(__aarch64__)
// x16=1 requests the universal.js executable-memory preparation RPC.
__attribute__((noinline, optnone, naked))
static void* AzaharRequestUniversalJITRegion(void*, std::size_t) {
    __asm__ volatile("mov x16, #1\\n"
                     "brk #0xf00d\\n"
                     "ret\\n");
}
#endif

class CodeBlock {""",
    "universal JIT RPC",
)
source = replace(
    source,
    "#    if TARGET_OS_IPHONE\n"
    "        m_memory = (std::uint32_t*)mmap(nullptr, size, PROT_READ | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);",
    """#    if TARGET_OS_IPHONE
        // StikDebug universal.js must grant TXM-executable pages on iOS 27.
        // The NULL address triggers debugserver allocation and page preparation.
        m_memory = (std::uint32_t*)AzaharRequestUniversalJITRegion(nullptr, size);
        const auto address = reinterpret_cast<std::uintptr_t>(m_memory);
        if (!m_memory || m_memory == MAP_FAILED || (address & 0x3fff) ||
            address == 0x690000e0ULL || address == 0xcccccccc690000e0ULL)
            throw std::bad_alloc{};
        vm_address_t writable = 0;
        vm_prot_t current = 0, maximum = 0;
        auto result = vm_remap(mach_task_self(), &writable, (vm_size_t)size, 0,
                               VM_FLAGS_ANYWHERE, mach_task_self(),
                               reinterpret_cast<vm_address_t>(m_memory),
                               FALSE, &current, &maximum, VM_INHERIT_NONE);
        if (result != KERN_SUCCESS) {
            munmap(m_memory, size);
            throw std::bad_alloc{};
        }
        if (vm_protect(mach_task_self(), writable, (vm_size_t)size, FALSE,
                       VM_PROT_READ | VM_PROT_WRITE) != KERN_SUCCESS) {
            vm_deallocate(mach_task_self(), writable, (vm_size_t)size);
            munmap(m_memory, size);
            throw std::bad_alloc{};
        }
        m_writable_memory = reinterpret_cast<std::uint32_t*>(writable);""",
    "iOS RW/RX dual mapping",
)
source = replace(
    source,
    "#if defined(_WIN32)\n        VirtualFree((void*)m_memory, 0, MEM_RELEASE);\n#else\n        munmap(m_memory, m_size);\n#endif",
    "#if defined(_WIN32)\n        VirtualFree((void*)m_memory, 0, MEM_RELEASE);\n"
    "#elif defined(__APPLE__) && TARGET_OS_IPHONE\n"
    "        munmap(m_writable_memory, m_size);\n        munmap(m_memory, m_size);\n"
    "#else\n        munmap(m_memory, m_size);\n#endif",
    "release both JIT mappings",
)
source = replace(
    source,
    "    void protect()\n    {",
    """    std::uint32_t* wptr() const
    {
#if defined(__APPLE__) && TARGET_OS_IPHONE
        return m_writable_memory;
#else
        return m_memory;
#endif
    }

    void protect()
    {""",
    "expose writable alias",
)
source = replace(
    source,
    "#if defined(__APPLE__) && !TARGET_OS_IPHONE\n        pthread_jit_write_protect_np(1);",
    "#if defined(__APPLE__) && TARGET_OS_IPHONE\n"
    "        // W^X is enforced by the two permanent mappings.\n"
    "#elif defined(__APPLE__) && !TARGET_OS_IPHONE\n"
    "        pthread_jit_write_protect_np(1);",
    "protect code cache",
)
source = replace(
    source,
    "#if defined(__APPLE__) && !TARGET_OS_IPHONE\n        pthread_jit_write_protect_np(0);",
    "#if defined(__APPLE__) && TARGET_OS_IPHONE\n"
    "        // Write using wptr(); RX remains executable.\n"
    "#elif defined(__APPLE__) && !TARGET_OS_IPHONE\n"
    "        pthread_jit_write_protect_np(0);",
    "unprotect code cache",
)
source = replace(
    source,
    "    std::uint32_t* m_memory;\n    std::size_t m_size = 0;",
    "    std::uint32_t* m_memory;\n"
    "#if defined(__APPLE__) && TARGET_OS_IPHONE\n"
    "    std::uint32_t* m_writable_memory = nullptr;\n#endif\n"
    "    std::size_t m_size = 0;",
    "writable mapping storage",
)
# The JIT code is written through the RW mapping and executed through RX.
# Flushing only the RX pointer can leave newly emitted instructions stale in
# the D-cache of the RW alias on iOS. Sync both mappings, as in our successful
# 16 KiB ARM64 test (returned 42 on iOS 27.2.1 / A13).
source = replace(
    source,
    "#if defined(__APPLE__)\n        sys_icache_invalidate(mem, size);",
    """#if defined(__APPLE__) && TARGET_OS_IPHONE
        const auto offset = reinterpret_cast<std::uintptr_t>(mem) -
                            reinterpret_cast<std::uintptr_t>(m_memory);
        auto* writable = reinterpret_cast<void*>(
            reinterpret_cast<std::uintptr_t>(m_writable_memory) + offset);
        sys_icache_invalidate(writable, size);
        sys_icache_invalidate(mem, size);
#elif defined(__APPLE__)
        sys_icache_invalidate(mem, size);""",
    "invalidate RW and RX aliases",
)
oaknut.write_text(source)

dynarmic = Path("externals/dynarmic/src/dynarmic/backend/arm64/address_space.cpp")
source = dynarmic.read_text()
source = replace(source, ", code(mem.ptr(), mem.ptr())",
                 ", code(mem.wptr(), mem.ptr())", "emitter dual addresses")
source = replace(source, "CodeGenerator c{mem.ptr(), mem.ptr()};",
                 "CodeGenerator c{mem.wptr(), mem.ptr()};",
                 "relocation patch dual addresses", 2)
dynarmic.write_text(source)
print("iOS JIT: patched pinned Oaknut CodeBlock and Dynarmic ARM64 address space.")
