// Copyright 2026 AzaharFE contributors
// Licensed under GPLv3 or any later version.
#pragma once

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <sys/mman.h>
#include <unistd.h>

namespace Core {

// Map shared guest RAM aliases into a 4 GiB virtual address window.
// Only complete, contiguous, aligned 16 KiB host groups are eligible.
class IOSFastmemArena {
public:
    static constexpr std::size_t GuestPages = 1u << 20;
    static constexpr std::size_t GroupPages = 4;
    static constexpr std::size_t Groups = GuestPages / GroupPages;
    static constexpr std::size_t HostPage = 16384;
    static constexpr std::size_t Window = std::size_t{1} << 32;

    IOSFastmemArena() {
        if (getpagesize() != HostPage) {
            return;
        }
        void* reservation = mmap(nullptr, Window, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (reservation != MAP_FAILED) {
            base = reinterpret_cast<std::uintptr_t>(reservation);
            if (!ProbeAlias()) {
                munmap(reservation, Window);
                base = 0;
                return;
            }
            Reset();
        }
    }
    ~IOSFastmemArena() {
        if (base) {
            munmap(reinterpret_cast<void*>(base), Window);
        }
    }
    IOSFastmemArena(const IOSFastmemArena&) = delete;
    IOSFastmemArena& operator=(const IOSFastmemArena&) = delete;

    bool Available() const {
        return base != 0;
    }
    std::uintptr_t Base() const {
        return base;
    }
    std::uintptr_t Guard() const {
        return reinterpret_cast<std::uintptr_t>(valid.data());
    }

    void Invalidate(std::size_t guest_page) {
        if (!base) {
            return;
        }
        const auto group = guest_page / GroupPages;
        if (valid[group]) {
            valid[group] = 0;
            --mapped_groups;
        }
        if (!dirty[group]) {
            dirty[group] = 1;
            pending.push_back(group);
        }
    }
    void Reset() {
        valid.fill(0);
        mapped_groups = 0;
        if (!base) {
            return;
        }
        dirty.fill(1);
        pending.resize(Groups);
        for (std::size_t i = 0; i < Groups; ++i) {
            pending[i] = i;
        }
    }

    void Sync(const std::array<std::uint8_t*, GuestPages>& pages) {
        if (!base || pending.empty()) {
            return;
        }
        std::sort(pending.begin(), pending.end());
        std::size_t i = 0;
        while (i < pending.size()) {
            const auto group = pending[i];
            const auto source = Source(pages, group);
            dirty[group] = 0;
            if (!source) {
                // Drop an obsolete alias rather than retaining freed backing pages.
                if (aliased[group] &&
                    mmap(reinterpret_cast<void*>(base + group * HostPage), HostPage, PROT_NONE,
                         MAP_FIXED | MAP_PRIVATE | MAP_ANON, -1, 0) != MAP_FAILED) {
                    aliased[group] = 0;
                }
                ++i;
                continue;
            }
            std::size_t end = i + 1;
            while (end < pending.size() && pending[end] == group + end - i &&
                   Source(pages, pending[end]) == source + (end - i) * HostPage) {
                dirty[pending[end]] = 0;
                ++end;
            }
            const auto size = (end - i) * HostPage;
            vm_address_t target = static_cast<vm_address_t>(base + group * HostPage);
            const auto expected = target;
            vm_prot_t current = 0, maximum = 0;
            const auto result =
                vm_remap(mach_task_self(), &target, size, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
                         mach_task_self(), static_cast<vm_address_t>(source), FALSE, &current,
                         &maximum, VM_INHERIT_NONE);
            if (result == KERN_SUCCESS && target == expected &&
                vm_protect(mach_task_self(), target, size, FALSE, VM_PROT_READ | VM_PROT_WRITE) ==
                    KERN_SUCCESS) {
                for (auto k = i; k < end; ++k) {
                    valid[pending[k]] = 1;
                    aliased[pending[k]] = 1;
                    ++mapped_groups;
                }
            }
            i = end;
        }
        pending.clear();
    }

    std::size_t TakeFirstCoverageReport() {
        if (!reported && mapped_groups) {
            reported = true;
            return mapped_groups;
        }
        return 0;
    }

private:
    // Verify that the kernel creates a writable shared alias, not a copy.
    // Use scratch RAM so this probe never changes game data.
    bool ProbeAlias() {
        void* scratch =
            mmap(nullptr, HostPage, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        if (scratch == MAP_FAILED) {
            return false;
        }
        auto* original = static_cast<volatile std::uint32_t*>(scratch);
        *original = 0x12345678;
        vm_address_t target = static_cast<vm_address_t>(base);
        vm_prot_t current = 0, maximum = 0;
        bool okay =
            vm_remap(mach_task_self(), &target, HostPage, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
                     mach_task_self(), reinterpret_cast<vm_address_t>(scratch), FALSE, &current,
                     &maximum, VM_INHERIT_NONE) == KERN_SUCCESS &&
            target == base &&
            vm_protect(mach_task_self(), target, HostPage, FALSE, VM_PROT_READ | VM_PROT_WRITE) ==
                KERN_SUCCESS;
        if (okay) {
            auto* alias = reinterpret_cast<volatile std::uint32_t*>(target);
            okay = *alias == 0x12345678;
            *alias = 0x89abcdef;
            okay = okay && *original == 0x89abcdef;
            *original = 0xabcdef01;
            okay = okay && *alias == 0xabcdef01;
        }
        munmap(scratch, HostPage);
        return mmap(reinterpret_cast<void*>(base), HostPage, PROT_NONE,
                    MAP_FIXED | MAP_PRIVATE | MAP_ANON, -1, 0) != MAP_FAILED &&
               okay;
    }

    static std::uintptr_t Source(const std::array<std::uint8_t*, GuestPages>& pages,
                                 std::size_t group) {
        const auto index = group * GroupPages;
        const auto address = reinterpret_cast<std::uintptr_t>(pages[index]);
        if (!address || (address & (HostPage - 1))) {
            return 0;
        }
        for (std::size_t i = 1; i < GroupPages; ++i) {
            if (reinterpret_cast<std::uintptr_t>(pages[index + i]) != address + i * 4096) {
                return 0;
            }
        }
        return address;
    }

    std::uintptr_t base = 0;
    std::array<std::uint8_t, Groups> valid{};
    std::array<std::uint8_t, Groups> dirty{};
    std::array<std::uint8_t, Groups> aliased{};
    std::size_t mapped_groups = 0;
    bool reported = false;
    std::vector<std::size_t> pending;
};
} // namespace Core
