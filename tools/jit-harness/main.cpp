// AzaharFE host-native JIT regression tests. No ROMs, firmware or device data.
// Exercises the pinned Dynarmic A32 -> ARM64 backend on an Apple Silicon runner.
// The independent interpreter below intentionally implements only this fixture.
#include <array>
#include <cstdint>
#include <cstdlib>
#include <exception>
#include <iomanip>
#include <iostream>
#include <optional>
#include <stdexcept>
#include <string>

#include <dynarmic/interface/A32/a32.h>
#include <dynarmic/interface/optimization_flags.h>

namespace {
using u8 = std::uint8_t;
using u16 = std::uint16_t;
using u32 = std::uint32_t;
using u64 = std::uint64_t;
constexpr u32 kCode = 0x1000;
constexpr u32 kData = 0x2000;
constexpr std::size_t kMemorySize = 0x4000;
constexpr u32 kFlagsAndMode = 0xF000003F;

void Require(bool condition, const std::string& message) {
    if (!condition) throw std::runtime_error(message);
}
std::string Hex(u32 value) {
    constexpr char digits[] = "0123456789abcdef";
    std::string result = "0x00000000";
    for (int i = 0; i < 8; ++i) result[9 - i] = digits[(value >> (i * 4)) & 15];
    return result;
}
struct GuestMemory {
    std::array<u8, kMemorySize> bytes{};
    bool out_of_bounds = false;
    u8 Read8(u32 address) {
        if (address >= bytes.size()) { out_of_bounds = true; return 0; }
        return bytes[address];
    }
    u16 Read16(u32 address) {
        return static_cast<u16>(Read8(address) | (u16(Read8(address + 1)) << 8));
    }
    u32 Read32(u32 address) {
        return u32(Read16(address)) | (u32(Read16(address + 2)) << 16);
    }
    u64 Read64(u32 address) {
        return u64(Read32(address)) | (u64(Read32(address + 4)) << 32);
    }
    void Write8(u32 address, u8 value) {
        if (address >= bytes.size()) { out_of_bounds = true; return; }
        bytes[address] = value;
    }
    void Write16(u32 address, u16 value) {
        Write8(address, static_cast<u8>(value));
        Write8(address + 1, static_cast<u8>(value >> 8));
    }
    void Write32(u32 address, u32 value) {
        Write16(address, static_cast<u16>(value));
        Write16(address + 2, static_cast<u16>(value >> 16));
    }
    void Write64(u32 address, u64 value) {
        Write32(address, static_cast<u32>(value));
        Write32(address + 4, static_cast<u32>(value >> 32));
    }
};

class Environment final : public Dynarmic::A32::UserCallbacks {
public:
    GuestMemory memory;
    u64 ticks_left = 0;
    u64 ticks_charged = 0;
    unsigned add_ticks_calls = 0;
    unsigned remaining_calls = 0;
    unsigned svc_calls = 0;
    u32 last_svc = 0;
    Dynarmic::A32::Jit* halt_at_svc = nullptr;
    bool unexpected_exception = false;

    std::optional<u32> MemoryReadCode(u32 address) override {
        if (address > kMemorySize - 4) {
            memory.out_of_bounds = true;
            return std::nullopt;
        }
        return memory.Read32(address);
    }
    u8 MemoryRead8(u32 address) override { return memory.Read8(address); }
    u16 MemoryRead16(u32 address) override { return memory.Read16(address); }
    u32 MemoryRead32(u32 address) override { return memory.Read32(address); }
    u64 MemoryRead64(u32 address) override { return memory.Read64(address); }
    void MemoryWrite8(u32 address, u8 value) override { memory.Write8(address, value); }
    void MemoryWrite16(u32 address, u16 value) override { memory.Write16(address, value); }
    void MemoryWrite32(u32 address, u32 value) override { memory.Write32(address, value); }
    void MemoryWrite64(u32 address, u64 value) override { memory.Write64(address, value); }
    void InterpreterFallback(u32, std::size_t) override { std::terminate(); }
    void CallSVC(u32 svc) override {
        ++svc_calls;
        last_svc = svc;
        if (halt_at_svc) halt_at_svc->HaltExecution();
    }
    void ExceptionRaised(u32, Dynarmic::A32::Exception) override {
        unexpected_exception = true;
    }
    void AddTicks(u64 ticks) override {
        ++add_ticks_calls;
        ticks_charged += ticks;
        ticks_left = ticks > ticks_left ? 0 : ticks_left - ticks;
    }
    u64 GetTicksRemaining() override {
        ++remaining_calls;
        return ticks_left;
    }
};

Dynarmic::A32::UserConfig ConservativeConfig(Environment& env) {
    Dynarmic::A32::UserConfig config{};
    config.callbacks = &env;
    config.code_cache_size = 16 * 1024 * 1024;
    config.optimizations &= ~(Dynarmic::OptimizationFlag::BlockLinking |
                              Dynarmic::OptimizationFlag::ReturnStackBuffer |
                              Dynarmic::OptimizationFlag::FastDispatch);
    config.enable_cycle_counting = true;
    config.always_little_endian = true;
    return config;
}
void InitCPU(Dynarmic::A32::Jit& cpu) {
    cpu.Regs().fill(0);
    cpu.Regs()[2] = kData;
    cpu.Regs()[4] = 5;
    cpu.Regs()[15] = kCode;
    cpu.SetCpsr(0x10);  // ARM state, user mode.
}
void WriteLoopProgram(GuestMemory& mem) {
    // Deterministic ARM-state fixture: 5x add/store/load/decrement,
    // a conditional branch, then a finite NOP and an idle self-branch.
    constexpr u32 instructions[] = {
        0xE3A00000,  // mov r0, #0
        0xE3A01001,  // mov r1, #1
        0xE0800001,  // add r0, r0, r1
        0xE5820000,  // str r0, [r2]
        0xE5923000,  // ldr r3, [r2]
        0xE2544001,  // subs r4, r4, #1
        0x1AFFFFFA,  // bne kCode + 8
        0xE1A00000,  // mov r0, r0
        0xEAFFFFFE,  // b .
    };
    for (std::size_t i = 0; i < std::size(instructions); ++i)
        mem.Write32(kCode + static_cast<u32>(i * 4), instructions[i]);
}

// A deliberately small, independent reference interpreter: it DOES NOT
// invoke Dynarmic or reuse its decoded IR. Unknown opcodes fail closed.
struct ReferenceCPU {
    GuestMemory memory;
    std::array<u32, 16> regs{};
    u32 cpsr = 0x10;
    void Init() {
        regs[2] = kData;
        regs[4] = 5;
        regs[15] = kCode;
    }
    void Step() {
        const u32 pc = regs[15];
        const u32 opcode = memory.Read32(pc);
        u32 next_pc = pc + 4;
        switch (opcode) {
        case 0xE3A00000: regs[0] = 0; break;
        case 0xE3A01001: regs[1] = 1; break;
        case 0xE0800001: regs[0] += regs[1]; break;
        case 0xE5820000: memory.Write32(regs[2], regs[0]); break;
        case 0xE5923000: regs[3] = memory.Read32(regs[2]); break;
        case 0xE2544001: {
            const u32 before = regs[4];
            const u32 result = before - 1;
            regs[4] = result;
            cpsr &= ~0xF0000000u;
            if (result & 0x80000000u) cpsr |= 0x80000000u;  // N
            if (result == 0) cpsr |= 0x40000000u;            // Z
            if (before >= 1) cpsr |= 0x20000000u;            // C
            if (((before ^ 1u) & (before ^ result) & 0x80000000u) != 0)
                cpsr |= 0x10000000u;                         // V
            break;
        }
        case 0x1AFFFFFA:
            if ((cpsr & 0x40000000u) == 0) next_pc = kCode + 8;
            break;
        case 0xE1A00000: break;  // MOV r0, r0
        case 0xEAFFFFFE: next_pc = pc; break;  // B .
        default: throw std::runtime_error("Reference interpreter unsupported " +
                                          Hex(opcode) + " at " + Hex(pc));
        }
        regs[15] = next_pc;
    }
};
void TestParity() {
    Environment env;
    WriteLoopProgram(env.memory);
    ReferenceCPU reference;
    reference.memory = env.memory;
    reference.Init();
    Dynarmic::A32::Jit cpu(ConservativeConfig(env));
    InitCPU(cpu);
    // 32 steps walk through the loop, exit and park branch.
    // Every individual step compares all 16 registers, CPSR and memory.
    for (unsigned step = 0; step < 32; ++step) {
        reference.Step();
        env.ticks_left = 1;
        cpu.Step();
        for (std::size_t r = 0; r < 16; ++r) {
            Require(cpu.Regs()[r] == reference.regs[r],
                    "step " + std::to_string(step + 1) + " r" + std::to_string(r) +
                    " JIT=" + Hex(cpu.Regs()[r]) +
                    " reference=" + Hex(reference.regs[r]));
        }
        Require((cpu.Cpsr() & kFlagsAndMode) == (reference.cpsr & kFlagsAndMode),
                "CPSR diverged at step " + std::to_string(step + 1));
        Require(env.memory.bytes == reference.memory.bytes,
                "memory diverged at step " + std::to_string(step + 1));
        Require(!env.memory.out_of_bounds && !env.unexpected_exception,
                "unexpected memory fault or ARM exception during parity test");
    }
    Require(cpu.Regs()[0] == 5 && cpu.Regs()[3] == 5 &&
            env.memory.Read32(kData) == 5, "loop result incorrect");
    std::cout << "PASS ARM32 Step/independent interpreter parity (32 steps)\n";
}
void TestBudget() {
    Environment env;
    WriteLoopProgram(env.memory);
    Dynarmic::A32::Jit cpu(ConservativeConfig(env));
    InitCPU(cpu);
    for (u64 budget : {u64{32}, u64{64}, u64{256}}) {
        env.ticks_left = budget;
        const u64 before = env.ticks_charged;
        cpu.Run();  // Must return to the host after the cycle budget.
        Require(env.ticks_left == 0, "Run did not exhaust cycle budget");
        Require(env.ticks_charged > before, "Run consumed no cycles");
        Require(env.add_ticks_calls > 0 && env.remaining_calls > 0,
                "timer callbacks not reached");
        Require(!env.unexpected_exception && !env.memory.out_of_bounds,
                "unexpected exception during Run");
    }
    Require(cpu.Regs()[0] == 5 && cpu.Regs()[3] == 5 &&
            env.memory.Read32(kData) == 5 && cpu.Regs()[4] == 0,
            "Run diverged from known ARM32 fixture result");
    std::cout << "PASS continuous Run returns for 32/64/256 guest ticks\n";
}
void TestSVC() {
    Environment env;
    env.memory.Write32(kCode, 0xE3A00001);      // mov r0, #1
    env.memory.Write32(kCode + 4, 0xEF000021);  // svc #0x21
    env.memory.Write32(kCode + 8, 0xE2800002);  // add r0, r0, #2
    env.memory.Write32(kCode + 12, 0xEAFFFFFE); // b .
    Dynarmic::A32::Jit cpu(ConservativeConfig(env));
    InitCPU(cpu);
    env.halt_at_svc = &cpu;
    env.ticks_left = 64;
    cpu.Run();
    Require(env.svc_calls == 1 && env.last_svc == 0x21,
            "SVC 0x21 host callback not observed");
    Require(cpu.Regs()[0] == 1, "guest executed past SVC safe-exit request");
    Require(!env.unexpected_exception, "unexpected SVC exception");
    env.halt_at_svc = nullptr;
    env.ticks_left = 16;
    cpu.Run();
    Require(cpu.Regs()[0] == 3, "guest did not resume correctly after SVC");
    Require(env.svc_calls == 1, "SVC callback executed more than once");
    std::cout << "PASS SVC 0x21 host-call safe-exit and resumed execution\n";
}
void TestInvalidate() {
    Environment env;
    env.memory.Write32(kCode, 0xE3A00001);      // mov r0, #1
    env.memory.Write32(kCode + 4, 0xEAFFFFFE);  // b .
    Dynarmic::A32::Jit cpu(ConservativeConfig(env));
    InitCPU(cpu);
    env.ticks_left = 1;
    cpu.Step();
    Require(cpu.Regs()[0] == 1, "initial code was not executed");
    env.memory.Write32(kCode, 0xE3A00007);  // mov r0, #7
    cpu.InvalidateCacheRange(kCode, 4);
    cpu.Regs()[15] = kCode;
    env.ticks_left = 1;
    cpu.Step();
    Require(cpu.Regs()[0] == 7, "guest code cache invalidation did not work");
    std::cout << "PASS invalidate recompiled ARM32 code and re-execute\n";
}
}  // namespace

int main(int argc, char** argv) {
    try {
#if !defined(__aarch64__) && !defined(__arm64__)
        throw std::runtime_error("This harness MUST execute on native ARM64");
#endif
        Require(argc == 2, "usage: azahar_jit_harness parity|budget|svc|invalidate");
        const std::string name{argv[1]};
        if (name == "parity") TestParity();
        else if (name == "budget") TestBudget();
        else if (name == "svc") TestSVC();
        else if (name == "invalidate") TestInvalidate();
        else throw std::runtime_error("unknown test: " + name);
        return EXIT_SUCCESS;
    } catch (const std::exception& e) {
        std::cerr << "FAIL " << e.what() << '\n';
        return EXIT_FAILURE;
    }
}
