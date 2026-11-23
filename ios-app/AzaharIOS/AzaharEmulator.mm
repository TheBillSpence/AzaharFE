#import "AzaharEmulator.h"
#import "AZPreferences.h"

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <stdarg.h>
#import <stdio.h>

#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <libkern/OSCacheControl.h>
#include <sys/mman.h>
#include <unistd.h>
#include "../../src/citra_libretro/ios_frame_control.h"

// Apple's CS_DEBUGGED flag indicates that a debugger has granted JIT access.
static bool AzaharDebuggerIsEnabled() {
    using CSOps = int (*)(pid_t, unsigned int, void *, size_t);
    auto csopsFn = reinterpret_cast<CSOps>(dlsym(RTLD_DEFAULT, "csops"));
    uint32_t flags = 0;
    constexpr uint32_t kCSDebugged = 0x10000000;
    return csopsFn && csopsFn(getpid(), 0, &flags, sizeof(flags)) == 0 &&
           (flags & kCSDebugged) != 0;
}

// On iOS 27, TXM requires universal.js even on iPhone 11 / A13.
__attribute__((noinline, optnone, naked))
static void *AzaharUniversalJITRegion(void *, size_t) {
    __asm__ volatile("mov x16, #1\n"
                     "brk #0xf00d\n"
                     "ret\n");
}
static bool AzaharProbeJITMapping(void (^report)(NSString *)) {
    // A BRK without the universal script attached may crash. Test JIT ON only.
    if (!AzaharDebuggerIsEnabled()) return false;
    if (@available(iOS 27.0, *)) {
        constexpr size_t size = 16384;
        void *rx = AzaharUniversalJITRegion(nullptr, size);
        const uintptr_t addr = reinterpret_cast<uintptr_t>(rx);
        if (!rx || rx == MAP_FAILED || (addr & 0x3fff) ||
            addr == 0x690000e0ULL || addr == 0xcccccccc690000e0ULL)
            return false;
        vm_address_t rw = 0;
        vm_prot_t cur = 0, max = 0;
        kern_return_t result = vm_remap(mach_task_self(), &rw, (vm_size_t)size, 0,
                                        VM_FLAGS_ANYWHERE, mach_task_self(),
                                        reinterpret_cast<vm_address_t>(rx),
                                        FALSE, &cur, &max, VM_INHERIT_NONE);
        bool ok = result == KERN_SUCCESS;
        if (ok) {
            ok = vm_protect(mach_task_self(), rw, (vm_size_t)size, FALSE,
                            VM_PROT_READ | VM_PROT_WRITE) == KERN_SUCCESS;
            if (ok) {
                // Test actual ARM64 execution through the RX mapping. A
                // successful vm_remap alone proves nothing about TXM.
                // mov x0, #42; ret -- the A13 executes normal arm64 code in
                // our arm64-signed iOS binary (arm64e device is compatible).
                if (report) report(@"2b/7 RW/RX mappings ready; writing ARM64 test");
                auto *code = reinterpret_cast<uint32_t *>(rw);
                code[0] = 0xD2800540U;
                code[1] = 0xD65F03C0U;
                // Synchronize both virtual aliases of the same physical pages.
                sys_icache_invalidate(reinterpret_cast<void *>(rw), 8);
                sys_icache_invalidate(rx, 8);
                if (report) report(@"2c/7 Executing ARM64 test in RX memory");
                using JITTest = uint64_t (*)();
                uint64_t value = reinterpret_cast<JITTest>(rx)();
                if (report) {
                    report([NSString stringWithFormat:
                        @"2d/7 ARM64 RX test returned %llu (expected 42)",
                        static_cast<unsigned long long>(value)]);
                }
                ok = value == 42;
            } else if (report) {
                report(@"2b/7 Writable alias protection failed");
            }
            vm_deallocate(mach_task_self(), rw, (vm_size_t)size);
        } else if (report) {
            report(@"2b/7 vm_remap failed");
        }
        munmap(rx, size);
        return ok;
    }
    return false;
}

@class AzaharEmulator;

static __weak AzaharEmulator *sCurrentEmulator;

@interface AzaharEmulator () {
    void *_libraryHandle;
    std::mutex _jitBridgeMutex;
    void (*_requestJITHalt)(void);
    std::atomic<bool> _stopping;
    std::atomic<bool> _frameQueued;
    std::atomic<uint64_t> _buttons;
    std::atomic<bool> _jitEnabled;
    NSDictionary<NSString *, NSString *> *_gameOptions;
    std::atomic<bool> _guestRan;
    std::atomic<bool> _jitPending;
    std::atomic<uint64_t> _completedSlices;
    std::atomic<bool> _waitingForFirstFrame;
    NSObject *_playSession;
    BOOL _receivedFirstVideo;
    std::atomic<uint64_t> _deliveredImages;
    FILE *_diagnosticsFile;
    NSString *_systemDirectory;
    NSString *_saveDirectory;
    NSString *_lastMessage;

    // Experimental libretro Vulkan/MoltenVK bridge, deliberately optional.
    struct retro_hw_render_callback _vkRenderCallback{};
    const void *_vkNegotiation = nullptr;
    void *_vkInterface = nullptr;
    bool _vkRequested = false;
    bool _vkReadbackErrorReported = false;
    bool (*_vkStart)(const void *) = nullptr;
    const void *(*_vkGetInterface)(void) = nullptr;
    bool (*_vkReadback)(unsigned, unsigned, const void **, size_t *) = nullptr;
    void (*_vkShutdown)(void) = nullptr;

    decltype(&retro_set_environment) _setEnvironment;
    decltype(&retro_set_video_refresh) _setVideoRefresh;
    decltype(&retro_set_audio_sample) _setAudioSample;
    decltype(&retro_set_audio_sample_batch) _setAudioBatch;
    decltype(&retro_set_input_poll) _setInputPoll;
    decltype(&retro_set_input_state) _setInputState;
    decltype(&retro_init) _initCore;
    decltype(&retro_deinit) _deinitCore;
    decltype(&retro_load_game) _loadGame;
    decltype(&retro_unload_game) _unloadGame;
    decltype(&retro_run) _runFrame;
}
- (BOOL)handleEnvironment:(unsigned)command data:(void *)data;
- (void)receiveVideo:(const void *)data width:(unsigned)width
               height:(unsigned)height pitch:(size_t)pitch;
- (int16_t)inputStateForDevice:(unsigned)device identifier:(unsigned)identifier;
- (void)runGameAtURL:(NSURL *)url;
- (void)reportJITStage:(NSString *)message;
- (BOOL)shouldStopAfterSlices:(uint64_t)slices;
- (void)requestJITHalt;
@end

static bool AzaharEnvironment(unsigned command, void *data) {
    AzaharEmulator *host = sCurrentEmulator;
    return host ? [host handleEnvironment:command data:data] : false;
}

static bool AzaharShouldStop(uint64_t slices) {
    AzaharEmulator *host = sCurrentEmulator;
    return !host || [host shouldStopAfterSlices:slices];
}

static void AzaharVideo(const void *data, unsigned width, unsigned height, size_t pitch) {
    AzaharEmulator *host = sCurrentEmulator;
    if (host) {
        [host receiveVideo:data width:width height:height pitch:pitch];
    }
}

static void AzaharAudioSample(int16_t left, int16_t right) {
    // Audio output is a later milestone. This prototype is silent.
}

static size_t AzaharAudioBatch(const int16_t *data, size_t frames) {
    // Return accepted frame count so the core can continue.
    return frames;
}

static void AzaharInputPoll(void) {}

static int16_t AzaharInputState(unsigned port, unsigned device, unsigned index, unsigned id) {
    AzaharEmulator *host = sCurrentEmulator;
    return port == 0 && host ? [host inputStateForDevice:device identifier:id] : 0;
}

static void AzaharLog(enum retro_log_level level, const char *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    vfprintf(stderr, format, args);
    va_end(args);
}

@implementation AzaharEmulator

+ (NSString *)sessionJITStatus {
    AzaharEmulator *host = sCurrentEmulator;
    if (!host || host->_stopping.load()) return @"JIT is inactive";
    if (host->_guestRan.load()) return @"JIT is active";
    return host->_jitPending.load() ? @"Checking JIT…" : @"JIT is inactive";
}

- (NSDictionary<NSString *, NSString *> *)launchOptions { return _gameOptions; }

- (BOOL)jitActive { return _jitEnabled; }

// Persist each stage before risky JIT debugger operations, because a stalled
// breakpoint may stop every process thread before a UI message can repaint.
- (void)writeDiagnostic:(NSString *)message {
    NSLog(@"Azahar JIT27: %@", message);
    @synchronized (self) {
        if (_diagnosticsFile) {
            fprintf(_diagnosticsFile, "%.3f %s\n", NSDate.date.timeIntervalSince1970,
                    message.UTF8String);
            fflush(_diagnosticsFile);
        }
    }
}

- (void)reportJITStage:(NSString *)message {
    BOOL changed = NO;
    if (([message containsString:@"JIT27TRACE step 1/512"] ||
         [message containsString:@"JIT27TRACE turbo first full Run"]) &&
        [message hasSuffix:@"returned"]) {
        changed = !_guestRan.exchange(true);
        _jitPending.store(false);
    } else if ([message containsString:@"using interpreter"]) {
        changed = _jitPending.exchange(false);
    }
    if (changed) dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:@"AzaharSessionStatusChanged" object:nil];
    });
    [self writeDiagnostic:message];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate azaharEmulatorDidChangeJITStatus:message];
    });
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    _requestJITHalt = nullptr;
    _stopping.store(false);
    _frameQueued.store(false);
    _buttons.store(0);

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *support = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    _systemDirectory = [support stringByAppendingPathComponent:@"AzaharSystem"];
    _saveDirectory = [documents stringByAppendingPathComponent:@"Saves"];
    [fm createDirectoryAtPath:_systemDirectory
 withIntermediateDirectories:YES attributes:nil error:NULL];
    [fm createDirectoryAtPath:_saveDirectory
 withIntermediateDirectories:YES attributes:nil error:NULL];
    return self;
}

- (BOOL)loadLibrary:(NSError **)error {
    NSString *frameworks = NSBundle.mainBundle.privateFrameworksPath;
    NSString *path = [frameworks stringByAppendingPathComponent:@"azahar_libretro.dylib"];
    _libraryHandle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);

    if (!_libraryHandle) {
        NSString *detail = [NSString stringWithUTF8String:dlerror() ?: "Unknown dlopen error"];
        if (error) *error = [NSError errorWithDomain:@"AzaharIOS" code:1
            userInfo:@{NSLocalizedDescriptionKey: detail}];
        return NO;
    }

#define LOAD_SYMBOL(variable, name) \
    variable = reinterpret_cast<decltype(variable)>(dlsym(_libraryHandle, #name)); \
    if (!variable) { \
        if (error) *error = [NSError errorWithDomain:@"AzaharIOS" code:2 \
            userInfo:@{NSLocalizedDescriptionKey: @"Missing libretro symbol: " @#name}]; \
        dlclose(_libraryHandle); _libraryHandle = nullptr; \
        return NO; \
    }

    LOAD_SYMBOL(_setEnvironment, retro_set_environment);
    LOAD_SYMBOL(_setVideoRefresh, retro_set_video_refresh);
    LOAD_SYMBOL(_setAudioSample, retro_set_audio_sample);
    LOAD_SYMBOL(_setAudioBatch, retro_set_audio_sample_batch);
    LOAD_SYMBOL(_setInputPoll, retro_set_input_poll);
    LOAD_SYMBOL(_setInputState, retro_set_input_state);
    LOAD_SYMBOL(_initCore, retro_init);
    LOAD_SYMBOL(_deinitCore, retro_deinit);
    LOAD_SYMBOL(_loadGame, retro_load_game);
    LOAD_SYMBOL(_unloadGame, retro_unload_game);
    LOAD_SYMBOL(_runFrame, retro_run);
#undef LOAD_SYMBOL
    return YES;
}

- (BOOL)startGameAtURL:(NSURL *)url error:(NSError **)error {
    @synchronized (AzaharEmulator.class) {
        if (sCurrentEmulator) {
            if (error) *error = [NSError errorWithDomain:@"AzaharIOS" code:3
                userInfo:@{NSLocalizedDescriptionKey: @"The previous game is still running or stopping."}];
            return NO;
        }
        if (![self loadLibrary:error]) return NO;
        _stopping.store(false);
        _frameQueued.store(false);
        _buttons.store(0);
        _guestRan.store(false);
        _jitPending.store(self.experimentalJITEnabled);
        NSMutableDictionary *options = [NSMutableDictionary dictionary];
        for (NSString *key in AZOptionKeys()) {
            options[key] = AZValue(key, url);
        }
        _gameOptions = [options copy];
        _vkRenderCallback = {};
        _vkNegotiation = nullptr;
        _vkInterface = nullptr;
        _vkRequested = false;
        _vkReadbackErrorReported = false;
        _playSession = [NSObject new];
        _completedSlices.store(0);
        _waitingForFirstFrame.store(false);
        _receivedFirstVideo = NO;
        _deliveredImages.store(0, std::memory_order_relaxed);
        @synchronized (self) { _lastMessage = nil; }
        _jitEnabled = NO;
        NSString *path = [[_saveDirectory stringByDeletingLastPathComponent]
            stringByAppendingPathComponent:@"AzaharJITDiagnostics.txt"];
        // Preserve the previous diagnostic session so another run cannot
        // destroy the only evidence of a JIT stall.
        NSString *previousPath = [[path stringByDeletingPathExtension]
            stringByAppendingString:@".previous.txt"];
        NSFileManager *fm = NSFileManager.defaultManager;
        if ([fm fileExistsAtPath:path]) {
            [fm removeItemAtPath:previousPath error:NULL];
            [fm moveItemAtPath:path toPath:previousPath error:NULL];
        }
        _diagnosticsFile = fopen(path.fileSystemRepresentation, "w");
        if (!_diagnosticsFile) NSLog(@"Could not open AzaharJITDiagnostics.txt");
        sCurrentEmulator = self;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self runGameAtURL:url];
        {
            // No stop callback may outlive the dynamic library containing it.
            std::lock_guard<std::mutex> lock(_jitBridgeMutex);
            _requestJITHalt = nullptr;
            if (_libraryHandle) {
                dlclose(_libraryHandle);
                _libraryHandle = nullptr;
            }
        }
        @synchronized (self) {
            if (_diagnosticsFile) fclose(_diagnosticsFile);
            _diagnosticsFile = nullptr;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            @synchronized (AzaharEmulator.class) {
                if (sCurrentEmulator == self) sCurrentEmulator = nil;
                [NSNotificationCenter.defaultCenter postNotificationName:@"AzaharSessionStatusChanged" object:nil];
            }
        });
    });
    return YES;
}

- (void)scheduleFirstFrameCheckForSession:(NSObject *)session
                                  started:(std::chrono::steady_clock::time_point)started
                            previousSlices:(uint64_t)previousSlices
                                  initial:(BOOL)initial {
    __weak AzaharEmulator *weakHost = self;
    // A busy main queue delayed both watchdog callbacks by ~11 seconds on
    // device. Poll on a utility queue; reportJITStage dispatches UI changes
    // back to the main queue and persists the trace under its own lock.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (initial ? 3 : 7) * (int64_t)NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        AzaharEmulator *host = weakHost;
        if (!host) return;
        @synchronized (AzaharEmulator.class) {
            if (host->_playSession != session || host->_stopping.load() ||
                !host->_waitingForFirstFrame.load()) return;
            const uint64_t slices = host->_completedSlices.load();
            const auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
                std::chrono::steady_clock::now() - started).count();
            [host reportJITStage:[NSString stringWithFormat:
                @"First frame pending after %lld s; completed scheduler slices: %llu",
                (long long)elapsed, (unsigned long long)slices]];
            if (!initial && slices == previousSlices) {
                [host reportJITStage:@"JIT27TRACE watchdog: scheduler stalled; request CPU safe-exit"];
                [host requestJITHalt];
            }
            [host scheduleFirstFrameCheckForSession:session started:started previousSlices:slices initial:NO];
        }
    });
}

- (void)runGameAtURL:(NSURL *)url {
    @autoreleasepool {
        if (self.experimentalJITEnabled) {
            [self reportJITStage:@"1/7 Waiting for StikDebug debugger permission"];

            // Wait only on the worker so the UI can still report progress.
            for (unsigned n = 0; n < 150 && !_stopping.load(); ++n) {
                if (AzaharDebuggerIsEnabled()) break;
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
            }

            if (_stopping.load()) return;
            const bool debugged = AzaharDebuggerIsEnabled();
            if (debugged) {
                [self reportJITStage:@"2/7 Debugger found; requesting 16 KB JIT memory"];
            } else {
                [self reportJITStage:@"Debugger NOT found; using interpreter"];
            }
            // The breakpoint must be handled by universal.js. If it stalls,
            // the last durable log entry will identify this exact operation.
            _jitEnabled = debugged && AzaharProbeJITMapping(^(NSString *message) {
                [self reportJITStage:message];
            });
            if (_jitEnabled) {
                [self reportJITStage:@"3/7 JIT mapping prepared; initializing core"];
            } else if (debugged) {
                [self reportJITStage:@"Universal JIT memory failed; using interpreter"];
            }
        } else {
            [self reportJITStage:@"JIT OFF; initializing interpreter"];
        }

        if (_stopping.load()) return;
        _setEnvironment(AzaharEnvironment);
        _vkStart = reinterpret_cast<bool (*)(const void *)>(
            dlsym(_libraryHandle, "azahar_ios_vk_start"));
        _vkGetInterface = reinterpret_cast<const void *(*)(void)>(
            dlsym(_libraryHandle, "azahar_ios_vk_get_interface"));
        _vkReadback = reinterpret_cast<bool (*)(unsigned, unsigned, const void **, size_t *)>(
            dlsym(_libraryHandle, "azahar_ios_vk_readback"));
        _vkShutdown = reinterpret_cast<void (*)(void)>(
            dlsym(_libraryHandle, "azahar_ios_vk_shutdown"));
        {
            std::lock_guard<std::mutex> lock(_jitBridgeMutex);
            _requestJITHalt = reinterpret_cast<void (*)(void)>(
                dlsym(_libraryHandle, "azahar_jit_request_halt"));
            if (!_requestJITHalt) {
                [self reportJITStage:@"JIT27TRACE core does not export the halt bridge"];
            }
        }
        _setVideoRefresh(AzaharVideo);
        _setAudioSample(AzaharAudioSample);
        _setAudioBatch(AzaharAudioBatch);
        _setInputPoll(AzaharInputPoll);
        _setInputState(AzaharInputState);
        [self reportJITStage:@"4/7 Calling retro_init"];
        _initCore();
        [self reportJITStage:@"5/7 Core initialized; loading game"];

        struct retro_game_info game = {};
        game.path = url.fileSystemRepresentation;

        BOOL loaded = _loadGame(&game);
        if (loaded && _vkRequested) {
            BOOL started = _vkStart && _vkGetInterface && _vkReadback && _vkShutdown &&
                           _vkNegotiation && _vkRenderCallback.context_reset &&
                           _vkStart(_vkNegotiation);
            if (started) {
                _vkInterface = const_cast<void *>(_vkGetInterface());
                if (_vkInterface) {
                    [self reportJITStage:@"JIT27TRACE MoltenVK device ready; initializing Vulkan PICA200"];
                    _vkRenderCallback.context_reset();
                } else {
                    started = NO;
                }
            }
            if (!started) {
                // An unavailable GPU driver must never prevent games from
                // working in the existing software rendering mode.
                [self reportJITStage:@"JIT27TRACE MoltenVK initialization failed; retrying software renderer"];
                _deinitCore();
                if (_vkShutdown) _vkShutdown();
                _vkInterface = nullptr;
                _vkNegotiation = nullptr;
                _vkRequested = false;
                _vkRenderCallback = {};
                NSMutableDictionary *fallback = [_gameOptions mutableCopy];
                fallback[@"citra_graphics_api"] = @"Software";
                _gameOptions = [fallback copy];
                _initCore();
                loaded = _loadGame(&game);
            }
        }
        [self reportJITStage:loaded ? @"6/7 Game loaded; starting first frame"
                                    : @"Game load failed"];
        if (!loaded) {
            NSString *message;
            @synchronized (self) { message = _lastMessage; }
            if (!message) message = @"Azahar couldn't load this game. Check the ROM format and whether it is decrypted.";
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate azaharEmulatorDidFail:message];
            });
        } else {
            auto nextFrame = std::chrono::steady_clock::now();
            auto fpsWindow = nextFrame;
            unsigned frameCount = 0;
            auto performanceWindow = nextFrame;
            unsigned emulatedFrames = 0;
            double coreRunMilliseconds = 0.0;
            uint64_t previousImages = 0;
            bool firstFrame = true;
            if (_jitEnabled) {
                _waitingForFirstFrame.store(true);
                [self scheduleFirstFrameCheckForSession:_playSession started:nextFrame previousSlices:0 initial:YES];
            }
            while (!_stopping.load()) {
                const auto runStarted = std::chrono::steady_clock::now();
                @autoreleasepool {
                    _runFrame();
                }
                const auto now = std::chrono::steady_clock::now();
                if (_stopping.load()) break;
                ++frameCount;
                const double coreRunMs =
                    std::chrono::duration<double, std::milli>(now - runStarted).count();
                if (firstFrame && _receivedFirstVideo) {
                    firstFrame = false;
                    performanceWindow = now;
                    previousImages = _deliveredImages.load(std::memory_order_relaxed);
                    [self reportJITStage:@"7/7 First video frame received; measuring FPS"];
                } else if (!firstFrame) {
                    ++emulatedFrames;
                    coreRunMilliseconds += coreRunMs;
                    const double seconds = std::chrono::duration<double>(now - performanceWindow).count();
                    if (seconds >= 5.0) {
                        const auto images = _deliveredImages.load(std::memory_order_relaxed);
                        [self writeDiagnostic:[NSString stringWithFormat:
                            @"Performance: %.1f emulated FPS, %.1f images/s delivered to view over %.1fs; mean retro_run %.1f ms",
                            emulatedFrames / seconds, (images - previousImages) / seconds, seconds,
                            coreRunMilliseconds / emulatedFrames]];
                        performanceWindow = now;
                        emulatedFrames = 0;
                        coreRunMilliseconds = 0.0;
                        previousImages = images;
                    }
                }
                double elapsed = std::chrono::duration<double>(now - fpsWindow).count();
                if (elapsed >= 1.0) {
                    if (_receivedFirstVideo) {
                        double fps = frameCount / elapsed;
                        BOOL usedJITCandidate = _jitEnabled;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self.delegate azaharEmulatorDidMeasureFPS:fps
                                                            jitActive:usedJITCandidate];
                        });
                    }
                    fpsWindow = now;
                    frameCount = 0;
                }
                nextFrame += std::chrono::milliseconds(16);
                if (nextFrame < now) nextFrame = now;
                std::this_thread::sleep_until(nextFrame);
            }
            _waitingForFirstFrame.store(false);
            _unloadGame();
        }

        _deinitCore();
        if (_vkShutdown) {
            _vkShutdown();
            _vkInterface = nullptr;
        }
    }
}

- (BOOL)handleEnvironment:(unsigned)command data:(void *)data {
    switch (command) {
        case LibRetro::GetFrameStopCallback:
            if (!data) return NO;
            *static_cast<LibRetro::FrameStopCallback *>(data) = AzaharShouldStop;
            return YES;
        case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
            if (!data) return NO;
            *(const char **)data = _systemDirectory.UTF8String;
            return YES;
        case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
            if (!data) return NO;
            *(const char **)data = _saveDirectory.UTF8String;
            return YES;
        case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
            if (!data) return NO;
            ((retro_log_callback *)data)->log = AzaharLog;
            return YES;
        case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
            return data && *(const retro_pixel_format *)data == RETRO_PIXEL_FORMAT_XRGB8888;
        case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION:
            if (!data) return NO;
            *(unsigned *)data = 0; // Legacy options; use the core's defaults.
            return YES;
        case RETRO_ENVIRONMENT_GET_VARIABLE: {
            auto *variable = static_cast<retro_variable *>(data);
            if (!variable || !variable->key) return NO;
            NSString *key = [NSString stringWithUTF8String:variable->key];
            NSString *value = key ? _gameOptions[key] : nil;
            variable->value = value.UTF8String;
            return value != nil;
        }
        case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
            if (!data) return NO;
            *(bool *)data = false;
            return YES;
        case RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER:
            if (!data) return NO;
            *(retro_hw_context_type *)data =
                [_gameOptions[@"citra_graphics_api"] isEqualToString:@"Vulkan"]
                    ? RETRO_HW_CONTEXT_VULKAN : RETRO_HW_CONTEXT_NONE;
            return YES;
        case RETRO_ENVIRONMENT_SET_HW_RENDER:
            if (!data) return NO;
            if (static_cast<retro_hw_render_callback *>(data)->context_type !=
                RETRO_HW_CONTEXT_VULKAN) return NO;
            if (![_gameOptions[@"citra_graphics_api"] isEqualToString:@"Vulkan"] ||
                !_vkStart || !_vkReadback) return NO;
            _vkRenderCallback = *static_cast<retro_hw_render_callback *>(data);
            _vkRequested = true;
            return YES;
        case RETRO_ENVIRONMENT_SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE:
            if (!data || !_vkRequested) return NO;
            // LibRetro passes the static negotiation struct directly as data.
            _vkNegotiation = data;
            return YES;
        case RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE:
            if (!data || !_vkInterface) return NO;
            *static_cast<void **>(data) = _vkInterface;
            return YES;
        case RETRO_ENVIRONMENT_GET_JIT_CAPABLE:
            if (!data) return NO;
            // Only report JIT after external debugger + dual mapping preflight.
            *(bool *)data = _jitEnabled;
            return YES;
        case RETRO_ENVIRONMENT_SET_MESSAGE:
            if (data) {
                const retro_message *message = (const retro_message *)data;
                if (message->msg) {
                    NSString *text = [NSString stringWithUTF8String:message->msg];
                    if ([text hasPrefix:@"JIT27TRACE "]) {
                        [self reportJITStage:text];
                    } else if ([text hasPrefix:@"PERF27 "]) {
                        // PERF27 is diagnostic output, not a JIT state change.
                        // Persist it alongside JIT27TRACE so Settings -> Log Data
                        // contains the on-device CPU/GPU/HLE profiler reports.
                        [self writeDiagnostic:text];
                    } else if (text) {
                        @synchronized (self) { _lastMessage = text; }
                    }
                }
            }
            return YES;
        case RETRO_ENVIRONMENT_SET_VARIABLES:
        case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
        case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
        case RETRO_ENVIRONMENT_SET_GEOMETRY:
            return YES;
        default:
            return NO;
    }
}

- (int16_t)inputStateForDevice:(unsigned)device identifier:(unsigned)identifier {
    if (device != RETRO_DEVICE_JOYPAD || identifier >= 64) return 0;
    return (_buttons.load() & (uint64_t(1) << identifier)) != 0 ? 1 : 0;
}

- (void)setButton:(unsigned)identifier pressed:(BOOL)pressed {
    if (identifier >= 64) return;
    uint64_t mask = uint64_t(1) << identifier;
    if (pressed) _buttons.fetch_or(mask);
    else _buttons.fetch_and(~mask);
}

- (void)receiveVideo:(const void *)data width:(unsigned)width
               height:(unsigned)height pitch:(size_t)pitch {
    if (data == RETRO_HW_FRAME_BUFFER_VALID && _vkReadback && _vkInterface) {
        const void *gpuPixels = nullptr;
        size_t gpuPitch = 0;
        if (!_vkReadback(width, height, &gpuPixels, &gpuPitch)) {
            if (!_vkReadbackErrorReported) {
                _vkReadbackErrorReported = true;
                [self reportJITStage:@"JIT27TRACE MoltenVK image readback failed; select Software graphics"];
            }
            return;
        }
        data = gpuPixels;
        pitch = gpuPitch;
    }
    if (!data || data == RETRO_HW_FRAME_BUFFER_VALID || width == 0 || height == 0 ||
        width > 4096 || height > 4096 || pitch < width * 4 ||
        pitch > (4096 * 4) || _frameQueued.exchange(true)) return;

    if (!_receivedFirstVideo) {
        _receivedFirstVideo = YES;
        // A returned retro_run() alone does not prove a video buffer arrived.
        _waitingForFirstFrame.store(false);
        [self reportJITStage:[NSString stringWithFormat:
            @"First %@ video buffer: %u x %u", _vkInterface ? @"MoltenVK" : @"software", width, height]];
    }
    NSData *pixels = [NSData dataWithBytes:data length:pitch * height];
    dispatch_async(dispatch_get_main_queue(), ^{
        CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
        CGColorSpaceRef colors = CGColorSpaceCreateDeviceRGB();
        CGImageRef frame = CGImageCreate(width, height, 8, 32, pitch,
            colors, kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst,
            provider, NULL, false, kCGRenderingIntentDefault);
        if (frame) {
            UIImage *image = [UIImage imageWithCGImage:frame];
            id<AzaharEmulatorDelegate> delegate = self.delegate;
            if (delegate && !_stopping.load()) {
                [delegate azaharEmulatorDidRenderImage:image];
                if (_deliveredImages.fetch_add(1, std::memory_order_relaxed) == 0) {
                    [self reportJITStage:@"First software image delivered to the game view"];
                }
            }
            CGImageRelease(frame);
        }
        CGColorSpaceRelease(colors);
        CGDataProviderRelease(provider);
        _frameQueued.store(false);
    });
}

- (BOOL)shouldStopAfterSlices:(uint64_t)slices {
    if (slices && _waitingForFirstFrame.load(std::memory_order_relaxed)) {
        _completedSlices.fetch_add(1, std::memory_order_relaxed);
    }
    return _stopping.load();
}

- (void)requestJITHalt {
    // Keep the dynamic library loaded throughout the optional C callback.
    BOOL sent = NO;
    {
        std::lock_guard<std::mutex> lock(_jitBridgeMutex);
        if (_requestJITHalt) {
            _requestJITHalt();
            sent = YES;
        }
    }
    [self reportJITStage:sent
        ? @"JIT27TRACE frontend halt bridge invoked"
        : @"JIT27TRACE halt skipped; core halt bridge is unavailable"];
}

- (void)stop {
    _stopping.store(true);
    _buttons.store(0);
    [self requestJITHalt];
}

@end
