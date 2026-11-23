// Copyright 2016-2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the misc/licenses/gplv2.txt file included.

#include <csignal>
#include <cstring>
#ifdef IOS
#include <atomic>
#include <cstdio>
#include <mutex>
#include <unordered_set>
#include "citra_libretro/environment.h"
#endif
#include <dynarmic/interface/A32/a32.h>
#include <dynarmic/interface/optimization_flags.h>
#include "common/assert.h"
#include "common/microprofile.h"
#include "core/arm/dynarmic/arm_dynarmic.h"
#include "core/arm/dynarmic/arm_dynarmic_cp15.h"
#include "core/arm/dynarmic/arm_exclusive_monitor.h"
#include "core/arm/dynarmic/arm_tick_counts.h"
#include "core/arm/exception_handler.h"
#include "core/core.h"
#include "core/core_timing.h"
#ifdef ENABLE_GDBSTUB
#include "core/gdbstub/gdbstub.h"
#endif
#include "core/hle/kernel/svc.h"
#include "core/memory.h"

#ifndef SIGILL
constexpr u32 SIGILL = 4;
#endif

#ifndef SIGTRAP
constexpr u32 SIGTRAP = 5;
#endif

namespace Core {

#ifdef IOS
// Start tracing timer callbacks only when the first full guest JIT run begins.
// Single-step uses a separate code path and isn't representative here.
static std::atomic<bool> gAzaharJITFullRunStarted{false};
static std::atomic<unsigned> gAzaharJITRunCount{0};
// Set immediately before a JIT Run on the same emulation thread. Dynarmic's
// GetTicksRemaining callback reads this limit inside the generated prelude.
static thread_local std::uint64_t gAzaharJITBudgetCap = 64;

// AzaharFE run registry: active JITs are registered without holding the
// mutex during generated code. HaltExecution only requests a safe exit.
static std::mutex gAzaharJITRunMutex;
static std::unordered_set<Dynarmic::A32::Jit*> gAzaharActiveJITs;
class AzaharScopedJITRun final {
public:
    explicit AzaharScopedJITRun(Dynarmic::A32::Jit* current) : current(current) {
        std::lock_guard<std::mutex> lock(gAzaharJITRunMutex);
        gAzaharActiveJITs.insert(current);
    }
    ~AzaharScopedJITRun() {
        std::lock_guard<std::mutex> lock(gAzaharJITRunMutex);
        gAzaharActiveJITs.erase(current);
    }
    AzaharScopedJITRun(const AzaharScopedJITRun&) = delete;
    AzaharScopedJITRun& operator=(const AzaharScopedJITRun&) = delete;

private:
    Dynarmic::A32::Jit* current;
};
void AzaharRequestRunningJITToHalt() {
    unsigned active = 0;
    {
        std::lock_guard<std::mutex> lock(gAzaharJITRunMutex);
        active = static_cast<unsigned>(gAzaharActiveJITs.size());
        for (auto* running : gAzaharActiveJITs)
            running->HaltExecution();
    }
    // Report after releasing the lock (frontend callback acquires ObjC locks).
    char message[128];
    std::snprintf(message, sizeof(message), "JIT27TRACE host halt request delivered active_jits=%u",
                  active);
    LibRetro::DisplayMessage(message);
}
#endif

class DynarmicUserCallbacks final : public Dynarmic::A32::UserCallbacks {
public:
    explicit DynarmicUserCallbacks(ARM_Dynarmic& parent)
        : parent(parent), svc_context(parent.system), memory(parent.memory) {}
    ~DynarmicUserCallbacks() = default;

    std::optional<std::uint32_t> MemoryReadCode(VAddr vaddr) override {
#ifdef IOS
        // A code fetch identifies where translation has reached, even when Run()
        // has yet to return. Limit output to the first 12 page changes per core.
        const u32 page = vaddr >> 12;
        if (code_page_reports < 12 && page != last_code_page) {
            last_code_page = page;
            ++code_page_reports;
            char message[128];
            std::snprintf(message, sizeof(message), "JIT27TRACE code fetch core=%u addr=0x%08x",
                          parent.GetID(), vaddr);
            LibRetro::DisplayMessage(message);
        }
#endif
        return memory.Read32OrNullopt(vaddr);
    }

    std::uint8_t MemoryRead8(VAddr vaddr) override {
        return memory.Read8(vaddr);
    }
    std::uint16_t MemoryRead16(VAddr vaddr) override {
        return memory.Read16(vaddr);
    }
    std::uint32_t MemoryRead32(VAddr vaddr) override {
        return memory.Read32(vaddr);
    }
    std::uint64_t MemoryRead64(VAddr vaddr) override {
        return memory.Read64(vaddr);
    }

    void MemoryWrite8(VAddr vaddr, std::uint8_t value) override {
        memory.Write8(vaddr, value);
    }
    void MemoryWrite16(VAddr vaddr, std::uint16_t value) override {
        memory.Write16(vaddr, value);
    }
    void MemoryWrite32(VAddr vaddr, std::uint32_t value) override {
        memory.Write32(vaddr, value);
    }
    void MemoryWrite64(VAddr vaddr, std::uint64_t value) override {
        memory.Write64(vaddr, value);
    }

    bool MemoryWriteExclusive8(u32 vaddr, u8 value, u8 expected) override {
        return memory.WriteExclusive8(vaddr, value, expected);
    }
    bool MemoryWriteExclusive16(u32 vaddr, u16 value, u16 expected) override {
        return memory.WriteExclusive16(vaddr, value, expected);
    }
    bool MemoryWriteExclusive32(u32 vaddr, u32 value, u32 expected) override {
        return memory.WriteExclusive32(vaddr, value, expected);
    }
    bool MemoryWriteExclusive64(u32 vaddr, u64 value, u64 expected) override {
        return memory.WriteExclusive64(vaddr, value, expected);
    }

    void InterpreterFallback(VAddr pc, std::size_t num_instructions) override {
        // Should never happen.
        UNREACHABLE_MSG("InterpeterFallback reached with pc = 0x{:08x}, code = 0x{:08x}, num = {}",
                        pc, MemoryReadCode(pc).value(), num_instructions);
    }

    void CallSVC(std::uint32_t swi) override {
#ifdef IOS
        const bool trace = svc_reports < 32;
        char message[128];
        if (trace) {
            ++svc_reports;
            std::snprintf(message, sizeof(message), "JIT27TRACE SVC 0x%02x core=%u entered", swi,
                          parent.GetID());
            LibRetro::DisplayMessage(message);
        }
#endif
        svc_context.CallSVC(swi);
#ifdef IOS
        // A32's SVC terminal saves the next PC before invoking the callback
        // and checks for a halt afterwards. Yield to CoreTiming at this kernel
        // boundary rather than starting another guest block in the same Run.
        parent.PrepareReschedule();
        if (trace) {
            std::snprintf(message, sizeof(message), "JIT27TRACE SVC 0x%02x core=%u returned", swi,
                          parent.GetID());
            LibRetro::DisplayMessage(message);
        }
#endif
    }

    void ExceptionRaised(VAddr pc, Dynarmic::A32::Exception exception) override {
        switch (exception) {
        case Dynarmic::A32::Exception::UndefinedInstruction:
        case Dynarmic::A32::Exception::UnpredictableInstruction:
        case Dynarmic::A32::Exception::DecodeError:
        case Dynarmic::A32::Exception::NoExecuteFault:
            break;
        case Dynarmic::A32::Exception::Breakpoint:
#ifdef ENABLE_GDBSTUB
            if (GDBStub::IsConnected()) {
                parent.SetPC(pc);
                parent.ServeBreak(SIGTRAP);
                return;
            }
#endif
            break;
        case Dynarmic::A32::Exception::SendEvent:
        case Dynarmic::A32::Exception::SendEventLocal:
        case Dynarmic::A32::Exception::WaitForInterrupt:
        case Dynarmic::A32::Exception::WaitForEvent:
        case Dynarmic::A32::Exception::Yield:
        case Dynarmic::A32::Exception::PreloadData:
        case Dynarmic::A32::Exception::PreloadDataWithIntentToWrite:
        case Dynarmic::A32::Exception::PreloadInstruction:
            return;
        }

        static constexpr auto ExceptionToString = [](Dynarmic::A32::Exception e) -> std::string {
            switch (e) {
            case Dynarmic::A32::Exception::UndefinedInstruction:
                return "UndefinedInstruction";
            case Dynarmic::A32::Exception::UnpredictableInstruction:
                return "UnpredictableInstruction";
            case Dynarmic::A32::Exception::DecodeError:
                return "DecodeError";
            case Dynarmic::A32::Exception::NoExecuteFault:
                return "NoExecuteFault";
            case Dynarmic::A32::Exception::Breakpoint:
                return "Breakpoint";
            default:
                return fmt::format("Unknown({})", e);
            }
        };

        parent.SetPC(pc);
#ifdef ENABLE_GDBSTUB
        if (GDBStub::IsConnected()) {
            parent.ServeBreak(SIGILL);
        } else
#endif
        {
            Core::ExceptionType exc_type;
            switch (exception) {
            case Dynarmic::A32::Exception::UndefinedInstruction:
            case Dynarmic::A32::Exception::UnpredictableInstruction:
            case Dynarmic::A32::Exception::DecodeError:
            case Dynarmic::A32::Exception::NoExecuteFault:
                exc_type = Core::ExceptionType::UndefinedInstruction;
                break;
            case Dynarmic::A32::Exception::Breakpoint:
                exc_type = Core::ExceptionType::Break;
                break;
            default:
                exc_type = Core::ExceptionType::UndefinedInstruction;
                break;
            }
            Core::LogException(parent.system, exc_type);
        }
    }

    void AddTicks(std::uint64_t ticks) override {
        parent.GetTimer().AddTicks(ticks);
#ifdef IOS
        if (gAzaharJITFullRunStarted.load(std::memory_order_relaxed)) {
            if (add_tick_reports < 3) {
                ++add_tick_reports;
                char info[160];
                std::snprintf(info, sizeof(info),
                              "JIT27TRACE AddTicks(%llu) core=%u remaining=%lld",
                              static_cast<unsigned long long>(ticks), parent.GetID(),
                              static_cast<long long>(parent.GetTimer().GetDowncount()));
                LibRetro::DisplayMessage(info);
            }
        }
#endif
    }
    std::uint64_t GetTicksRemaining() override {
        const s64 ticks = parent.GetTimer().GetDowncount();
#ifdef IOS
        if (gAzaharJITFullRunStarted.load(std::memory_order_relaxed)) {
            // Adaptive diagnostic: the Run caller ramps the cap only after
            // previous short runs returned successfully. Keep this per-thread
            // so other emulator threads cannot overwrite the active budget.
            const auto remaining = static_cast<std::uint64_t>(ticks <= 0 ? 0 : ticks);
            const auto limited = remaining < gAzaharJITBudgetCap ? remaining : gAzaharJITBudgetCap;
            if (remaining_tick_reports < 3) {
                ++remaining_tick_reports;
                char info[170];
                std::snprintf(info, sizeof(info),
                              "JIT27TRACE GetTicksRemaining core=%u original=%lld capped=%llu",
                              parent.GetID(), static_cast<long long>(ticks),
                              static_cast<unsigned long long>(limited));
                LibRetro::DisplayMessage(info);
            }
            return limited;
        }
#endif
        return static_cast<std::uint64_t>(ticks <= 0 ? 0 : ticks);
    }
    std::uint64_t GetTicksForCode(bool is_thumb, VAddr, std::uint32_t instruction) override {
        return Core::TicksForInstruction(is_thumb, instruction);
    }

#ifdef IOS
    u32 last_code_page = ~u32{0};
    unsigned code_page_reports = 0;
    unsigned svc_reports = 0;
    unsigned add_tick_reports = 0;
    unsigned remaining_tick_reports = 0;
#endif
    ARM_Dynarmic& parent;
    Kernel::SVCContext svc_context;
    Memory::MemorySystem& memory;
};

ARM_Dynarmic::ARM_Dynarmic(Core::System& system_, Memory::MemorySystem& memory_, u32 core_id_,
                           std::shared_ptr<Core::Timing::Timer> timer_,
                           Core::ExclusiveMonitor& exclusive_monitor_)
    : ARM_Interface(core_id_, timer_), system(system_), memory(memory_),
      cb(std::make_unique<DynarmicUserCallbacks>(*this)),
      exclusive_monitor{dynamic_cast<Core::DynarmicExclusiveMonitor&>(exclusive_monitor_)} {
#ifdef IOS
    if (core_id_ == 0) {
        gAzaharJITRunCount.store(0, std::memory_order_relaxed);
        gAzaharJITFullRunStarted.store(false, std::memory_order_relaxed);
    }
#endif
    SetPageTable(memory.GetCurrentPageTable());
}

ARM_Dynarmic::~ARM_Dynarmic() = default;

MICROPROFILE_DEFINE(ARM_Jit, "ARM JIT", "ARM JIT", MP_RGB(255, 64, 64));

void ARM_Dynarmic::Run() {
    ASSERT(memory.GetCurrentPageTable() == current_page_table);
    MICROPROFILE_SCOPE(ARM_Jit);
    if (break_flag) [[unlikely]] {
        return;
    }

#ifdef IOS
    // Build #16: one generated guest instruction returned, while the
    // first full Dynarmic::Run never returned. Step through several
    // hundred guest instructions first to determine whether this is
    // an individual instruction, core, or full-dispatch-loop failure.
    // Limit logs so the iPhone's Documents file stays manageable.
    constexpr unsigned kStepProbeCount = 512;
    const unsigned probe = gAzaharJITRunCount.fetch_add(1, std::memory_order_relaxed);
    const bool trace_probe =
        probe < 4 || probe == 15 || probe == 63 || probe == 255 || probe == kStepProbeCount - 1;
    if (probe < kStepProbeCount) {
        if (trace_probe) {
            char status[192];
            std::snprintf(status, sizeof(status),
                          "JIT27TRACE step %u/%u core=%u pc=0x%08x ticks=%lld entered", probe + 1,
                          kStepProbeCount, GetID(), jit->Regs()[15],
                          static_cast<long long>(GetTimer().GetDowncount()));
            LibRetro::DisplayMessage(status);
        }
        jit->Step();
        if (trace_probe) {
            char status[192];
            std::snprintf(status, sizeof(status),
                          "JIT27TRACE step %u/%u core=%u pc=0x%08x ticks=%lld returned", probe + 1,
                          kStepProbeCount, GetID(), jit->Regs()[15],
                          static_cast<long long>(GetTimer().GetDowncount()));
            LibRetro::DisplayMessage(status);
        }
        return;
    }
    // Build #26: full JIT run 80 consistently stalls; cross its boundary
    // using Dynarmic's separate ARM64 single-step recompiler path.
    constexpr unsigned kTargetRun = kStepProbeCount + 79;
    constexpr unsigned kTargetStepCount = 1024;
    if (probe >= kTargetRun && probe < kTargetRun + kTargetStepCount) {
        const unsigned n = probe - kTargetRun;
        // Step 32 returned, but step 64 was not reached on the iPhone.
        // Emit entry/exit around every instruction in that narrowed range.
        const bool trace = n < 64 || n == 127 || n == 255 || n == 511 || n == 767 ||
                           n == kTargetStepCount - 1;
        if (n == 0) {
            LibRetro::DisplayMessage(
                "JIT27TRACE run80 targeted single-step probe started; 1024 instructions");
        }
        if (trace) {
            char message[256];
            std::snprintf(message, sizeof(message),
                          "JIT27TRACE run80 step=%u/%u core=%u pc=0x%08x cpsr=0x%08x r0=0x%08x "
                          "r1=0x%08x lr=0x%08x ticks=%lld entered",
                          n + 1, kTargetStepCount, GetID(), GetPC(), GetCPSR(), GetReg(0),
                          GetReg(1), GetReg(14), static_cast<long long>(GetTimer().GetDowncount()));
            LibRetro::DisplayMessage(message);
        }
        AzaharScopedJITRun active_step{jit};
        const auto reason = jit->Step();
        if (trace) {
            char message[256];
            std::snprintf(message, sizeof(message),
                          "JIT27TRACE run80 step=%u/%u core=%u pc=0x%08x cpsr=0x%08x r0=0x%08x "
                          "r1=0x%08x lr=0x%08x ticks=%lld returned reason=0x%x",
                          n + 1, kTargetStepCount, GetID(), GetPC(), GetCPSR(), GetReg(0),
                          GetReg(1), GetReg(14), static_cast<long long>(GetTimer().GetDowncount()),
                          static_cast<unsigned>(reason));
            LibRetro::DisplayMessage(message);
        }
        if (n + 1 == kTargetStepCount) {
            LibRetro::DisplayMessage(
                "JIT27TRACE run80 probe completed; resuming 256-tick JIT slices");
        }
        return;
    }
    bool trace_budget_stage = false;
    if (probe >= kStepProbeCount) {
        // Run 16 full JIT slices at each tested budget. If a later budget
        // freezes, the last "entered" trace identifies the failing stage.
        // This is NOT a final FPS optimization: full ~375k ticks stays off.
        constexpr std::uint64_t kBudgets[] = {64, 256, 1024, 4096, 16384, 65536, 262144};
        constexpr unsigned kRunsPerStage = 16;
        const unsigned run_index = probe - kStepProbeCount;
        const unsigned stage_number = run_index / kRunsPerStage;
        constexpr unsigned kLastStage = sizeof(kBudgets) / sizeof(kBudgets[0]) - 1;
        const unsigned stage = stage_number > kLastStage ? kLastStage : stage_number;
        gAzaharJITBudgetCap = probe >= kTargetRun + kTargetStepCount ? 256 : kBudgets[stage];
        if (probe == kStepProbeCount) {
            gAzaharJITFullRunStarted.store(true, std::memory_order_release);
        }
        // Sample every run in the 16K stage: the previous black screen was
        // observed between its first return and the next stage marker.
        trace_budget_stage = (stage_number <= kLastStage &&
                              (run_index % kRunsPerStage == 0 || gAzaharJITBudgetCap == 16384)) ||
                             (probe >= kTargetRun + kTargetStepCount &&
                              (probe == kTargetRun + kTargetStepCount ||
                               (probe - kTargetRun - kTargetStepCount) % 128 == 0));
        if (trace_budget_stage) {
            char status[200];
            std::snprintf(status, sizeof(status),
                          "JIT27TRACE stage=%u run=%u core=%u pc=0x%08x r0=0x%08x r1=0x%08x "
                          "budget=%llu entered",
                          stage + 1, run_index + 1, GetID(), GetPC(), GetReg(0), GetReg(1),
                          static_cast<unsigned long long>(gAzaharJITBudgetCap));
            LibRetro::DisplayMessage(status);
        }
    }
#endif
#ifdef IOS
    AzaharScopedJITRun active_jit{jit};
    const auto jit_halt_reason = jit->Run();
#else
    jit->Run();
#endif
#ifdef IOS
    if (probe == kStepProbeCount) {
        LibRetro::DisplayMessage("JIT27TRACE first full Dynarmic::Run returned");
    }
    if (trace_budget_stage) {
        char status[200];
        std::snprintf(
            status, sizeof(status),
            "JIT27TRACE run=%u core=%u pc=0x%08x r0=0x%08x r1=0x%08x returned reason=0x%x",
            probe - kStepProbeCount + 1, GetID(), GetPC(), GetReg(0), GetReg(1),
            static_cast<unsigned>(jit_halt_reason));
        LibRetro::DisplayMessage(status);
    }
#endif
}

void ARM_Dynarmic::Step() {
    if (break_flag) [[unlikely]] {
        return;
    }

#ifdef IOS
    static std::atomic<bool> log_first_step{true};
    const bool trace_first_step = log_first_step.exchange(false);
    if (trace_first_step) {
        LibRetro::DisplayMessage("JIT27TRACE Dynarmic::Step entered");
    }
#endif
    jit->Step();
#ifdef IOS
    if (trace_first_step) {
        LibRetro::DisplayMessage("JIT27TRACE Dynarmic::Step returned");
    }
#endif
}

void ARM_Dynarmic::SetPC(u32 pc) {
    jit->Regs()[15] = pc;
}

u32 ARM_Dynarmic::GetPC() const {
    return jit->Regs()[15];
}

u32 ARM_Dynarmic::GetReg(int index) const {
    return jit->Regs()[index];
}

void ARM_Dynarmic::SetReg(int index, u32 value) {
    jit->Regs()[index] = value;
}

u32 ARM_Dynarmic::GetVFPReg(int index) const {
    return jit->ExtRegs()[index];
}

void ARM_Dynarmic::SetVFPReg(int index, u32 value) {
    jit->ExtRegs()[index] = value;
}

u32 ARM_Dynarmic::GetVFPSystemReg(VFPSystemRegister reg) const {
    switch (reg) {
    case VFP_FPSCR:
        return jit->Fpscr();
    case VFP_FPEXC:
        return fpexc;
    default:
        UNREACHABLE_MSG("Unknown VFP system register: {}", reg);
    }

    return UINT_MAX;
}

void ARM_Dynarmic::SetVFPSystemReg(VFPSystemRegister reg, u32 value) {
    switch (reg) {
    case VFP_FPSCR:
        jit->SetFpscr(value);
        return;
    case VFP_FPEXC:
        fpexc = value;
        return;
    default:
        UNREACHABLE_MSG("Unknown VFP system register: {}", reg);
    }
}

u32 ARM_Dynarmic::GetCPSR() const {
    return jit->Cpsr();
}

void ARM_Dynarmic::SetCPSR(u32 cpsr) {
    jit->SetCpsr(cpsr);
}

u32 ARM_Dynarmic::GetCP15Register(CP15Register reg) const {
    switch (reg) {
    case CP15_THREAD_UPRW:
        return cp15_state.cp15_thread_uprw;
    case CP15_THREAD_URO:
        return cp15_state.cp15_thread_uro;
    default:
        UNREACHABLE_MSG("Unknown CP15 register: {}", reg);
    }

    return 0;
}

void ARM_Dynarmic::SetCP15Register(CP15Register reg, u32 value) {
    switch (reg) {
    case CP15_THREAD_UPRW:
        cp15_state.cp15_thread_uprw = value;
        return;
    case CP15_THREAD_URO:
        cp15_state.cp15_thread_uro = value;
        return;
    default:
        UNREACHABLE_MSG("Unknown CP15 register: {}", reg);
    }
}

void ARM_Dynarmic::SaveContext(ThreadContext& ctx) {
    ctx.cpu_registers = jit->Regs();
    ctx.cpsr = jit->Cpsr();
    ctx.fpu_registers = jit->ExtRegs();
    ctx.fpscr = jit->Fpscr();
    ctx.fpexc = fpexc;
}

void ARM_Dynarmic::LoadContext(const ThreadContext& ctx) {
    jit->Regs() = ctx.cpu_registers;
    jit->SetCpsr(ctx.cpsr);
    jit->ExtRegs() = ctx.fpu_registers;
    jit->SetFpscr(ctx.fpscr);
    fpexc = ctx.fpexc;
}

void ARM_Dynarmic::PrepareReschedule() {
    if (jit->IsExecuting()) {
        jit->HaltExecution();
    }
}

void ARM_Dynarmic::ClearInstructionCache() {
    for (const auto& j : jits) {
        j.second->ClearCache();
    }
}

void ARM_Dynarmic::InvalidateCacheRange(u32 start_address, std::size_t length) {
    jit->InvalidateCacheRange(start_address, length);
}

void ARM_Dynarmic::ClearExclusiveState() {
    jit->ClearExclusiveState();
}

std::shared_ptr<Memory::PageTable> ARM_Dynarmic::GetPageTable() const {
    return current_page_table;
}

void ARM_Dynarmic::SetPageTable(const std::shared_ptr<Memory::PageTable>& page_table) {
    current_page_table = page_table;
    ThreadContext ctx{};
    if (jit) {
        SaveContext(ctx);
    }

    auto iter = jits.find(current_page_table);
    if (iter != jits.end()) {
        jit = iter->second.get();
        LoadContext(ctx);
        return;
    }

    auto new_jit = MakeJit();
    jit = new_jit.get();
    LoadContext(ctx);
    jits.emplace(current_page_table, std::move(new_jit));
}

void ARM_Dynarmic::ServeBreak([[maybe_unused]] int signal) {
#ifdef ENABLE_GDBSTUB
    GDBStub::Break(signal);
#endif
}

std::unique_ptr<Dynarmic::A32::Jit> ARM_Dynarmic::MakeJit() {
    Dynarmic::A32::UserConfig config;
#ifdef IOS
    // 16 MiB avoids Dynarmic's documented ~8 MiB minimum.
    config.code_cache_size = 16 * 1024 * 1024;
    // Build #18 confirmed 512 generated guest instructions execute correctly,
    // but full jit->Run() never returns from a tight PC 0x00100034..0x3c loop.
    // Disable direct block linking, return-stack prediction and fast dispatch
    // temporarily to force execution through the dispatcher, which checks the
    // cycle budget. Keep other safe IR optimizations and cycle counting on.
    config.optimizations = config.optimizations & ~(Dynarmic::OptimizationFlag::BlockLinking |
                                                    Dynarmic::OptimizationFlag::ReturnStackBuffer |
                                                    Dynarmic::OptimizationFlag::FastDispatch);
    config.enable_cycle_counting = true;
    // Leave Dynarmic's optional page table unset to isolate generated direct
    // memory accesses from the rest of the iOS JIT. Loads and stores then use
    // the existing MemorySystem callbacks, including exclusive accesses.
    LibRetro::DisplayMessage("JIT27TRACE guest memory callbacks; block linking OFF");
#else
    if (current_page_table) {
        config.page_table = &current_page_table->GetPointerArray();
    }
#endif
    config.callbacks = cb.get();
    config.coprocessors[15] = std::make_shared<DynarmicCP15>(cp15_state);
    config.define_unpredictable_behaviour = true;

    // Multi-process state
    config.processor_id = GetID();
    config.global_monitor = &exclusive_monitor.monitor;

#ifdef IOS
    LibRetro::DisplayMessage("JIT27TRACE Dynarmic::MakeJit allocating code cache");
#endif
    auto created_jit = std::make_unique<Dynarmic::A32::Jit>(config);
#ifdef IOS
    LibRetro::DisplayMessage("JIT27TRACE Dynarmic::MakeJit returned");
#endif
    return created_jit;
}

} // namespace Core
