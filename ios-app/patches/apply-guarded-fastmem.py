#!/usr/bin/env python3
"""Patch the pinned ARM64 backend for checked native fastmem, without intentional faults."""
from pathlib import Path
root = Path("externals/dynarmic/src/dynarmic")

def edit(path, before, after, count=1):
    file = root / path
    data = file.read_text()
    if data.count(before) != count:
        raise SystemExit(f"{path}: expected {count} instances of {before!r}, got {data.count(before)}")
    file.write_text(data.replace(before, after))

edit("interface/A32/config.h",
     "    std::optional<uintptr_t> fastmem_pointer = std::nullopt;",
     "    std::optional<uintptr_t> fastmem_pointer = std::nullopt;\n"
     "    uintptr_t guarded_fastmem_table = 0;")
edit("backend/arm64/emit_arm64.h",
     "    std::optional<u64> fastmem_pointer;",
     "    std::optional<u64> fastmem_pointer;\n    u64 guarded_fastmem_table = 0;")
edit("backend/arm64/a32_address_space.cpp",
     "        .fastmem_pointer = conf.fastmem_pointer,",
     "        .fastmem_pointer = conf.fastmem_pointer,\n"
     "        .guarded_fastmem_table = conf.guarded_fastmem_table,")
edit("backend/arm64/a32_address_space.cpp",
     "        if (conf.page_table) {\n            code.MOV(Xpagetable, mcl::bit_cast<u64>(conf.page_table));\n        }",
     "        if (conf.guarded_fastmem_table) {\n"
     "            code.MOV(Xpagetable, conf.guarded_fastmem_table);\n"
     "        } else if (conf.page_table) {\n"
     "            code.MOV(Xpagetable, mcl::bit_cast<u64>(conf.page_table));\n        }", 2)
edit("backend/arm64/emit_arm64_memory.cpp",
     "    if (!ctx.conf.fastmem_pointer || !ctx.fastmem.SupportsFastmem()) {",
     "    if (ctx.conf.fastmem_pointer && ctx.conf.guarded_fastmem_table) {\n"
     "        return std::make_tuple(ctx.block.Location(), inst->GetName());\n"
     "    }\n"
     "    if (!ctx.conf.fastmem_pointer || !ctx.fastmem.SupportsFastmem()) {")
edit("backend/arm64/emit_arm64_memory.cpp",
     "    if (ctx.conf.fastmem_address_space_bits == 64 || ShouldExt32(ctx)) {",
     """    if (ctx.conf.guarded_fastmem_table) {
        if constexpr (bitsize > 8) {
            code.AND(Xscratch0, Xaddr, 0x3fff);
            code.ADD(Xscratch0, Xscratch0, bitsize / 8 - 1);
            code.LSR(Xscratch0, Xscratch0, 14);
            code.CBNZ(Xscratch0, *fallback);
        }
        code.UBFX(Xscratch0, Xaddr, 14, 18);
        code.LDRB(Wscratch0, Xpagetable, oaknut::RReg{Xscratch0}, oaknut::IndexExt::LSL);
        code.CBZ(Wscratch0, *fallback);
        return std::make_pair(Xfastmem, Xaddr);
    }
    if (ctx.conf.fastmem_address_space_bits == 64 || ShouldExt32(ctx)) {""")
print("Patched ARM64 guarded fastmem.")
