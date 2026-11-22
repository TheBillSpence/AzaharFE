#!/usr/bin/env python3
"""Patch the pinned Oaknut/Dynarmic submodules in Actions for pre-TXM iOS JIT.

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
source = replace(source, "#include <new>\n",
                 "#include <new>\n", "new header guard")
source = replace(source, "#    include <TargetConditionals.h>\n",
                 "#    include <mach/mach.h>\n#    include <mach/vm_map.h>\n"
                 "#    include <TargetConditionals.h>\n", "Mach headers")
source = replace(
    source,
    "        m_memory = (std::uint32_t*)mmap(nullptr, size, PROT_READ | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);",
    """        // iOS needs a W^X code cache: generate code through RW pages,
        // execute it through a separate RX mapping of the same pages.
        m_writable_memory = (std::uint32_t*)mmap(
            nullptr, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
        if (m_writable_memory == MAP_FAILED)
            throw std::bad_alloc{};

        vm_address_t executable = 0;
        vm_prot_t current = 0, maximum = 0;
        const kern_return_t result = vm_remap(
            mach_task_self(), &executable, size, 0, VM_FLAGS_ANYWHERE,
            mach_task_self(), (vm_address_t)m_writable_memory, false,
            &current, &maximum, VM_INHERIT_NONE);
        if (result != KERN_SUCCESS) {
            munmap(m_writable_memory, size);
            m_writable_memory = nullptr;
            throw std::bad_alloc{};
        }
        m_memory = (std::uint32_t*)executable;
        if (mprotect(m_memory, size, PROT_READ | PROT_EXEC) != 0) {
            munmap(m_memory, size);
            munmap(m_writable_memory, size);
            m_memory = nullptr;
            m_writable_memory = nullptr;
            throw std::bad_alloc{};
        }""",
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
