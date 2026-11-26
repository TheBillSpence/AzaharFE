#import "AzaharEmulator.h"
#import "AZPreferences.h"
#import "AZAudioOutput.h"
#import <QuartzCore/CAMetalLayer.h>
#import "AZDisplayGeometry.h"
#include <algorithm>

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <stdarg.h>
#import <stdio.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <exception>
#include <mutex>
#include <thread>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <libkern/OSCacheControl.h>
#include <sys/mman.h>
#include <unistd.h>
#include "AZControllerInput.h"
#include "../../src/citra_libretro/ios_frame_control.h"
#include "../../src/citra_libretro/ios_moltenvk_bridge.h"

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
static unsigned long long sSessionNumber = 0;
// A failed execution test takes precedence over the passive debugger flag.
static std::atomic<bool> sJITProbeFailed{false};

@interface AzaharEmulator () {
    void *_libraryHandle;
    std::mutex _jitBridgeMutex;
    AZAudioOutput *_audioOutput;
    void (*_requestJITHalt)(void);
    std::atomic<bool> _stopping;
    std::atomic<bool> _paused;
    std::atomic<uint64_t> _audioEpoch;
    std::atomic<uint64_t> _audioRouteEpoch;
    std::atomic<bool> _pauseAcknowledged;
    std::atomic<bool> _frameQueued;
    AZInput::State _input;
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
    struct retro_hw_render_callback _vkRenderCallback;
    const void *_vkNegotiation;
    void *_vkInterface;
    bool _vkRequested;
    unsigned _readbackFailures;
    unsigned _readbackAttempts;
    double _readbackMilliseconds;
    decltype(&azahar_ios_vk_start) _vkStart;
    decltype(&azahar_ios_vk_get_interface) _vkGetInterface;
    decltype(&azahar_ios_vk_readback) _vkReadback;
    decltype(&azahar_ios_vk_readback_frame) _vkReadbackFrame;
    unsigned _readbackPending;
    decltype(&azahar_ios_vk_set_metal_layer) _vkSetMetalLayer;
    decltype(&azahar_ios_vk_present_frame) _vkPresentFrame;
    decltype(&azahar_ios_vk_present_extent) _vkPresentExtent;
    unsigned _lastSurfaceWidth, _lastSurfaceHeight;
    CGSize _lastRequestedSurface;
    bool _metalActive;
    unsigned _metalPending, _metalAttempts, _metalSubmitted, _metalWidth, _metalHeight;
    CGSize _metalDisplaySize;
    BOOL _displayLandscape;
    NSDictionary *_displayOptions;
    decltype(&azahar_ios_vk_readback_failed) _vkReadbackFailed;
    decltype(&azahar_ios_vk_drain_readback) _vkDrainReadback;
    decltype(&azahar_ios_vk_shutdown) _vkShutdown;
    decltype(&azahar_ios_vk_game_loaded) _vkGameLoaded;

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
    decltype(&retro_get_system_av_info) _getAVInfo;
}
- (BOOL)handleEnvironment:(unsigned)command data:(void *)data;
- (void)receiveVideo:(const void *)data width:(unsigned)width
               height:(unsigned)height pitch:(size_t)pitch;
- (void)pollInput;
- (void)receiveAudio:(const int16_t *)data frames:(size_t)frames;
- (int16_t)inputStateForDevice:(unsigned)device index:(unsigned)index identifier:(unsigned)identifier;
- (void)runGameAtURL:(NSURL *)url;
- (BOOL)startVulkanRenderer;
- (void)runLoadedGame;
- (void)replaceAudioWithSampleRate:(double)rate;
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
    const int16_t stereo[] = {left, right};
    [sCurrentEmulator receiveAudio:stereo frames:1];
}

static size_t AzaharAudioBatch(const int16_t *data, size_t frames) {
    [sCurrentEmulator receiveAudio:data frames:frames];
    // Never stall the guest when the device falls behind.
    return frames;
}

static void AzaharInputPoll(void) {
    [sCurrentEmulator pollInput];
}

static int16_t AzaharInputState(unsigned port, unsigned device, unsigned index, unsigned id) {
    AzaharEmulator *host = sCurrentEmulator;
    return port == 0 && host ? [host inputStateForDevice:device index:index identifier:id] : 0;
}

static void AzaharLog(enum retro_log_level level, const char *format, ...) {
    if (!format) return;
    va_list args;
    va_start(args, format);
    vfprintf(stderr, format, args);
    va_end(args);
}

@implementation AzaharEmulator

+ (BOOL)hasActiveSession {
    @synchronized (AzaharEmulator.class) { return sCurrentEmulator != nil; }
}

+ (NSString *)sessionJITStatus {
    AzaharEmulator *host = sCurrentEmulator;
    if (host) {
        if (host->_stopping.load()) return @"Game stopping";
        if (host->_guestRan.load()) return @"JIT is active";
        return host->_jitPending.load() ? @"Checking JIT…" : @"JIT is inactive";
    }
    if (AzaharDebuggerIsEnabled())
        return sJITProbeFailed.load() ? @"JIT unavailable" : @"JIT is active";
    sJITProbeFailed.store(false);
    return host && !host->_stopping.load() && host->_jitPending.load() ? @"Checking JIT…" : @"JIT is inactive";
}

- (NSDictionary<NSString *, NSString *> *)launchOptions { @synchronized (self) { return _gameOptions; } }

- (BOOL)jitActive { return _jitEnabled; }
- (void)setDisplaySize:(CGSize)size landscape:(BOOL)landscape options:(NSDictionary *)options {
    @synchronized (self) {
        _metalDisplaySize = size;
        _displayLandscape = landscape;
        _displayOptions = [options copy];
    }
}

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
    _audioRouteEpoch.store(0);
    _pauseAcknowledged.store(false);
    _vkRenderCallback = {};
    _vkNegotiation = nullptr;
    _vkInterface = nullptr;
    _vkRequested = false;
    _readbackFailures = 0;
    _vkStart = nullptr;
    _vkGetInterface = nullptr;
    _vkReadback = nullptr;
    _vkReadbackFrame = nullptr;
    _vkReadbackFailed = nullptr;
    _vkDrainReadback = nullptr;
    _vkShutdown = nullptr;
    _vkGameLoaded = nullptr;
    _stopping.store(false);
    _paused.store(false);
    _audioEpoch.store(0);
    _frameQueued.store(false);
    _input.Enable(false);

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
    LOAD_SYMBOL(_getAVInfo, retro_get_system_av_info);
#undef LOAD_SYMBOL
    return YES;
}

- (BOOL)startGameAtURL:(NSURL *)url error:(NSError **)error {
    return [self startGameAtURL:url options:AZLaunchOptions(url) error:error];
}

- (BOOL)startGameAtURL:(NSURL *)url options:(NSDictionary<NSString *, NSString *> *)options error:(NSError **)error {
    unsigned long long sessionNumber;
    @synchronized (AzaharEmulator.class) {
        if (sCurrentEmulator) {
            if (error) *error = [NSError errorWithDomain:@"AzaharIOS" code:3
                userInfo:@{NSLocalizedDescriptionKey: @"The previous game is still running or stopping."}];
            return NO;
        }
        _stopping.store(false);
        _paused.store(false);
        _audioEpoch.store(0);
        _frameQueued.store(false);
        _input.Enable(false);
        _guestRan.store(false);
        @synchronized (self) { _gameOptions = [options copy]; }
        self.experimentalJITEnabled = [options[@"AzaharExperimentalJIT"] isEqual:@"on"];
        _jitPending.store(self.experimentalJITEnabled);
        _vkRenderCallback = {};
        _vkNegotiation = nullptr;
        _vkInterface = nullptr;
        _vkRequested = false;
        _metalActive = false;
        _metalPending = _metalAttempts = _metalSubmitted = _metalWidth = _metalHeight = 0;
        _lastSurfaceWidth = _lastSurfaceHeight = 0;
        _lastRequestedSurface = CGSizeZero;
        _readbackFailures = 0;
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
        sessionNumber = ++sSessionNumber;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self writeDiagnostic:[NSString stringWithFormat:
            @"LIFECYCLE session %llu launch options=%@", sessionNumber, self.launchOptions]];
        [self writeDiagnostic:@"LIFECYCLE opening core library"];
        NSError *loadError = nil;
        if ([self loadLibrary:&loadError]) {
            [self writeDiagnostic:@"LIFECYCLE core library opened"];
            [self runGameAtURL:url];
        } else if (!_stopping.load()) {
            NSString *message = loadError.localizedDescription ?: @"Unable to load core.";
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self->_stopping.load()) [self.delegate azaharEmulatorDidFail:message];
            });
        }
        [self writeDiagnostic:@"LIFECYCLE worker exiting; releasing audio and core library"];
        [self replaceAudioWithSampleRate:0];
        {
            // No stop callback may outlive the dynamic library containing it.
            std::lock_guard<std::mutex> lock(_jitBridgeMutex);
            _requestJITHalt = nullptr;
            if (_libraryHandle) {
                [self writeDiagnostic:@"LIFECYCLE closing core library"];
                dlclose(_libraryHandle);
                _libraryHandle = nullptr;
                [self writeDiagnostic:@"LIFECYCLE core library closed"];
            }
        }
        [self writeDiagnostic:@"LIFECYCLE session teardown finished; library launch may resume"];
        @synchronized (self) {
            if (_diagnosticsFile) fclose(_diagnosticsFile);
            _diagnosticsFile = nullptr;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            @synchronized (AzaharEmulator.class) {
                if (sCurrentEmulator == self) sCurrentEmulator = nil;
            }
            [NSNotificationCenter.defaultCenter postNotificationName:@"AzaharSessionStatusChanged" object:nil];
            id<AzaharEmulatorDelegate> delegate = self.delegate;
            if ([delegate respondsToSelector:@selector(azaharEmulatorDidFinish:)])
                [delegate azaharEmulatorDidFinish:self];
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
            if (host->_playSession != session) return;
        }
        if (host->_stopping.load() || !host->_waitingForFirstFrame.load()) return;
        {
            const uint64_t slices = host->_completedSlices.load();
            if (host->_paused.load()) {
                [host scheduleFirstFrameCheckForSession:session started:started previousSlices:slices initial:NO];
                return;
            }
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
            const bool automatic = [self.launchOptions[@"AzaharJITPreset"] isEqual:@"combined"];
            for (unsigned n = 0; !automatic && n < 150 && !_stopping.load(); ++n) {
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
            sJITProbeFailed.store(debugged && !_jitEnabled.load());
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
        _vkStart = reinterpret_cast<decltype(_vkStart)>(
            dlsym(_libraryHandle, "azahar_ios_vk_start"));
        _vkGetInterface = reinterpret_cast<decltype(_vkGetInterface)>(
            dlsym(_libraryHandle, "azahar_ios_vk_get_interface"));
        _vkReadback = reinterpret_cast<decltype(_vkReadback)>(
            dlsym(_libraryHandle, "azahar_ios_vk_readback"));
        _vkReadbackFrame = reinterpret_cast<decltype(_vkReadbackFrame)>(
            dlsym(_libraryHandle, "azahar_ios_vk_readback_frame"));
        _vkSetMetalLayer = reinterpret_cast<decltype(_vkSetMetalLayer)>(
            dlsym(_libraryHandle, "azahar_ios_vk_set_metal_layer"));
        _vkPresentFrame = reinterpret_cast<decltype(_vkPresentFrame)>(
            dlsym(_libraryHandle, "azahar_ios_vk_present_frame"));
        _vkPresentExtent = reinterpret_cast<decltype(_vkPresentExtent)>(
            dlsym(_libraryHandle, "azahar_ios_vk_present_extent"));
        _vkReadbackFailed = reinterpret_cast<decltype(_vkReadbackFailed)>(
            dlsym(_libraryHandle, "azahar_ios_vk_readback_failed"));
        _vkDrainReadback = reinterpret_cast<decltype(_vkDrainReadback)>(
            dlsym(_libraryHandle, "azahar_ios_vk_drain_readback"));
        _vkShutdown = reinterpret_cast<decltype(_vkShutdown)>(
            dlsym(_libraryHandle, "azahar_ios_vk_shutdown"));
        _vkGameLoaded = reinterpret_cast<decltype(_vkGameLoaded)>(
            dlsym(_libraryHandle, "azahar_ios_vk_game_loaded"));
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
        struct retro_game_info game = {};
        game.path = url.fileSystemRepresentation;
        while (!_stopping.load()) {
            [self reportJITStage:@"4/7 Calling retro_init"];
            _initCore();
            [self reportJITStage:@"5/7 Core initialized; loading game"];
            BOOL loaded = _loadGame(&game);
            BOOL retrySoftware = _vkRequested && (!loaded || ![self startVulkanRenderer]);
            NSString *failure = nil;
            if (!retrySoftware && loaded) {
                [self reportJITStage:@"6/7 Game loaded; starting first frame"];
                [self runLoadedGame];
                [self writeDiagnostic:@"LIFECYCLE stopping audio"];
                [self replaceAudioWithSampleRate:0];
                if (_vkRequested && _vkDrainReadback && !_vkDrainReadback()) {
                    [self reportJITStage:@"Vulkan GPU copy is still pending. Waiting on worker; restart is blocked until safe teardown."];
                    // Never unload the core or free a source image while the
                    // driver's submission could still access it. Keep the
                    // session owned and the UI responsive if the GPU is stuck.
                    while (!_vkDrainReadback())
                        std::this_thread::sleep_for(std::chrono::milliseconds(100));
                    [self writeDiagnostic:@"LIFECYCLE pending Vulkan copy drained"];
                }
                [self writeDiagnostic:@"LIFECYCLE unloading game"];
                _unloadGame();
                [self writeDiagnostic:@"LIFECYCLE game unloaded"];
                const auto recovery = LibRetro::CheckReadback(_readbackFailures, _receivedFirstVideo);
                retrySoftware = recovery == LibRetro::ReadbackRecovery::RetrySoftware;
                if (recovery == LibRetro::ReadbackRecovery::ReportFailure)
                    failure = @"Vulkan stopped returning video. Select Software in this game's Graphics API settings and reopen the game.";
            } else if (!retrySoftware) {
                @synchronized (self) { failure = _lastMessage; }
                if (!failure) failure = @"Azahar couldn't load this game. Check the ROM format and whether it is decrypted.";
            }
            [self writeDiagnostic:@"LIFECYCLE deinitializing core"];
            _deinitCore();
            [self writeDiagnostic:@"LIFECYCLE shutting down Vulkan bridge"];
            if (_vkShutdown) _vkShutdown();
            [self writeDiagnostic:@"LIFECYCLE core and graphics teardown complete"];
            _vkInterface = nullptr;
            if (_stopping.load()) break;
            if (failure) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.delegate azaharEmulatorDidFail:failure];
                });
                break;
            }
            if (!retrySoftware) break;
            [self reportJITStage:@"MoltenVK failed to start or return pixels; retrying with Software"];
            @synchronized (self) {
                NSMutableDictionary *options = [_gameOptions mutableCopy];
                options[@"citra_graphics_api"] = @"Software";
                _gameOptions = [options copy];
                _lastMessage = nil;
            }
            @synchronized (AzaharEmulator.class) { _playSession = [NSObject new]; }
            _completedSlices.store(0);
            _vkRequested = false;
            _vkNegotiation = nullptr;
            _vkRenderCallback = {};
            _readbackFailures = 0;
        }
    }
}

- (void)receiveAudio:(const int16_t *)data frames:(size_t)frames {
    if (_stopping.load() || _paused.load()) return;
    AZAudioOutput *output;
    @synchronized (self) { output = _audioOutput; }
    [output appendSamples:data frames:frames];
}

- (void)setPaused:(BOOL)paused {
    if (_stopping.load()) return;
    if (_paused.exchange(paused != NO) != (paused != NO)) {
        _audioEpoch.fetch_add(1);
        if (paused) {
            _input.Enable(false);
            // The core checks the frame-stop callback at scheduler boundaries.
            // Normal menu pauses never call into generated code from a second thread.
        }
    }
}

- (void)refreshAudioRoute {
    _audioRouteEpoch.fetch_add(1);
    _audioEpoch.fetch_add(1);
}

// Only the emulation worker manages the audio session and queue.
- (void)replaceAudioWithSampleRate:(double)rate {
    AZAudioOutput *old;
    @synchronized (self) { old = _audioOutput; _audioOutput = nil; }
    [old stop];
    if (rate <= 0 || _stopping.load() || _paused.load()) return;
    AZAudioOutput *output = [AZAudioOutput new];
    if ([output startWithSampleRate:rate]) {
        @synchronized (self) { _audioOutput = output; }
        [self writeDiagnostic:[NSString stringWithFormat:@"Audio: stereo PCM at %.0f Hz", rate]];
    } else {
        [self writeDiagnostic:@"Audio output unavailable; continuing without sound"];
    }
}

- (BOOL)startVulkanRenderer {
    if (!_vkStart || !_vkGetInterface || !_vkReadback || !_vkReadbackFailed ||
        !_vkDrainReadback || !_vkShutdown || !_vkGameLoaded ||
        !_vkNegotiation || !_vkRenderCallback.context_reset) return NO;
    try {
        _metalActive = _vkSetMetalLayer && _vkPresentFrame && self.metalLayer &&
            [self.launchOptions[@"AzaharPresentation"] isEqual:@"metal"];
        if (_metalActive) _vkSetMetalLayer((__bridge void *)self.metalLayer);
        if (!_vkStart(_vkNegotiation)) return NO;
        _vkInterface = const_cast<void *>(_vkGetInterface());
        if (!_vkInterface) return NO;
        [self reportJITStage:@"MoltenVK device ready; initializing Vulkan PICA200"];
        _vkRenderCallback.context_reset();
        return _vkGameLoaded();
    } catch (const std::exception& ex) {
        [self reportJITStage:[NSString stringWithFormat:@"Vulkan initialization failed: %s", ex.what()]];
    } catch (...) {
        [self reportJITStage:@"Vulkan initialization raised an exception"];
    }
    return NO;
}

- (void)runLoadedGame {
    struct retro_system_av_info av = {};
    _getAVInfo(&av);
    const double fpsTarget = std::isfinite(av.timing.fps) && av.timing.fps >= 1 && av.timing.fps <= 240 ? av.timing.fps : 60.0;
    const auto framePeriod = std::chrono::duration_cast<std::chrono::steady_clock::duration>(std::chrono::duration<double>(1.0 / fpsTarget));
    uint64_t audioEpoch = UINT64_MAX;
    uint64_t routeEpoch = UINT64_MAX;
    auto nextFrame = std::chrono::steady_clock::now();
    auto fpsWindow = nextFrame;
    unsigned frameCount = 0;
    auto performanceWindow = nextFrame;
    unsigned emulatedFrames = 0;
    _readbackAttempts = 0;
    _readbackPending = 0;
    _readbackMilliseconds = 0;
    _metalAttempts = _metalSubmitted = 0;
    double coreRunMilliseconds = 0.0;
    uint64_t previousImages = 0;
    bool firstFrame = true;
    if (_jitEnabled) {
        _waitingForFirstFrame.store(true);
        [self scheduleFirstFrameCheckForSession:_playSession started:nextFrame previousSlices:0 initial:YES];
    }
    while (!_stopping.load()) {
        const auto epoch = _audioEpoch.load();
        if (audioEpoch != epoch) {
            audioEpoch = epoch;
            const auto route = _audioRouteEpoch.load();
            AZAudioOutput *output;
            @synchronized (self) { output = _audioOutput; }
            if (_paused.load()) {
                [output setMuted:YES];
            } else if (!output || routeEpoch != route) {
                [self replaceAudioWithSampleRate:av.timing.sample_rate];
                routeEpoch = route;
            } else {
                [output setMuted:NO];
            }
            nextFrame = fpsWindow = performanceWindow = std::chrono::steady_clock::now();
            frameCount = emulatedFrames = 0;
            coreRunMilliseconds = 0;
            _readbackAttempts = 0;
            _readbackPending = 0;
            _readbackMilliseconds = 0;
            _metalAttempts = _metalSubmitted = 0;
            previousImages = _deliveredImages.load();
        }
        if (_paused.load()) {
            if (!_pauseAcknowledged.exchange(true))
                [self writeDiagnostic:@"LIFECYCLE pause acknowledged by emulation worker"];
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
            continue;
        }
        if (_pauseAcknowledged.exchange(false))
            [self writeDiagnostic:@"LIFECYCLE resumed emulation worker"];
        const auto runStarted = std::chrono::steady_clock::now();
        @autoreleasepool {
            _runFrame();
        }
        const auto now = std::chrono::steady_clock::now();
        if (_stopping.load() || LibRetro::CheckReadback(_readbackFailures, _receivedFirstVideo) !=
                                LibRetro::ReadbackRecovery::Continue) break;
        if (_paused.load() || audioEpoch != _audioEpoch.load()) continue;
        ++frameCount;
        const double coreRunMs =
            std::chrono::duration<double, std::milli>(now - runStarted).count();
        if (firstFrame && _receivedFirstVideo) {
            firstFrame = false;
            performanceWindow = now;
            previousImages = _deliveredImages.load(std::memory_order_relaxed);
            [self reportJITStage:@"7/7 First video frame received or submitted; measuring emulation FPS"];
        } else if (!firstFrame) {
            ++emulatedFrames;
            coreRunMilliseconds += coreRunMs;
            const double seconds = std::chrono::duration<double>(now - performanceWindow).count();
            if (seconds >= 5.0) {
                const auto images = _deliveredImages.load(std::memory_order_relaxed);
                [self writeDiagnostic:[NSString stringWithFormat:
                    @"Performance: %.1f emulated FPS, %.1f CPU images/s delivered to view over %.1fs; mean retro_run %.1f ms",
                    emulatedFrames / seconds, (images - previousImages) / seconds, seconds,
                    coreRunMilliseconds / emulatedFrames]];
                if (_readbackAttempts) {
                    [self writeDiagnostic:[NSString stringWithFormat:
                        @"MoltenVK readback: %u calls, %u pending, mean %.2f ms per call",
                        _readbackAttempts, _readbackPending, _readbackMilliseconds / _readbackAttempts]];
                }
                if (_metalAttempts) {
                    [self writeDiagnostic:[NSString stringWithFormat:
                        @"Metal surface: %u attempts, %u accepted submissions (%.1f/s); not unique game frames or measured display scanout",
                        _metalAttempts, _metalSubmitted, _metalSubmitted / seconds]];
                }
                _metalAttempts = _metalSubmitted = 0;
                _readbackAttempts = 0;
                _readbackPending = 0;
                _readbackMilliseconds = 0;
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
                BOOL executedJIT = _guestRan.load();
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.delegate azaharEmulatorDidMeasureFPS:fps
                                                    jitActive:executedJIT];
                });
            }
            fpsWindow = now;
            frameCount = 0;
        }
        nextFrame += framePeriod;
        if (nextFrame < now) nextFrame = now;
        std::this_thread::sleep_until(nextFrame);
    }
    _waitingForFirstFrame.store(false);
}

- (BOOL)handleEnvironment:(unsigned)command data:(void *)data {
    switch (command) {
        case LibRetro::GetAcceptedVideoFrame:
            if (!data) return NO;
            *static_cast<bool *>(data) = _receivedFirstVideo;
            return YES;
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
            NSString *value = key ? self.launchOptions[key] : nil;
            // The touchscreen supplies the stylus independently of the C-Stick.
            if ([key isEqual:@"citra_analog_function"]) value = @"c_stick";
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
                [self.launchOptions[@"citra_graphics_api"] isEqualToString:@"Vulkan"]
                    ? RETRO_HW_CONTEXT_VULKAN : RETRO_HW_CONTEXT_NONE;
            return YES;
        case RETRO_ENVIRONMENT_SET_HW_RENDER:
            if (!data) return NO;
            if (static_cast<retro_hw_render_callback *>(data)->context_type !=
                RETRO_HW_CONTEXT_VULKAN) return NO;
            if (![self.launchOptions[@"citra_graphics_api"] isEqualToString:@"Vulkan"]) return NO;
            _vkRenderCallback = *static_cast<retro_hw_render_callback *>(data);
            _vkRequested = true;
            return _vkStart && _vkReadback;
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
                    } else if ([text hasPrefix:@"SHADER27 "]) {
                        [self reportJITStage:[text substringFromIndex:9]];
                    } else if ([text hasPrefix:@"PERF27 "] || [text hasPrefix:@"SUPER27 "] ||
                               [text hasPrefix:@"SW27 "]) {
                        // Persist profiler and experimental renderer diagnostics without
                        // changing the frontend JIT lifecycle state.
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

- (void)pollInput {
    AZInput::Pad pad;
    for (GCController *controller in GCController.controllers) {
        GCExtendedGamepad *gamepad = controller.extendedGamepad;
        if (!gamepad) continue;
        pad = AZInput::ReadGamepad(gamepad);
        break;
    }
    _input.Poll(pad);
}

- (int16_t)inputStateForDevice:(unsigned)device index:(unsigned)index identifier:(unsigned)identifier {
    return _input.Read(device, index, identifier);
}

- (void)setButton:(unsigned)identifier pressed:(BOOL)pressed {
    _input.Button(identifier, pressed);
}

- (void)setInputEnabled:(BOOL)enabled { _input.Enable(enabled); }
- (void)setPointerX:(int16_t)x y:(int16_t)y pressed:(BOOL)down { _input.Touch({x, y, down != NO}); }
- (void)setCircleX:(int16_t)x y:(int16_t)y { _input.Circle(x, y); }

- (void)receiveVideo:(const void *)data width:(unsigned)width
               height:(unsigned)height pitch:(size_t)pitch {
    if (!data || width == 0 || height == 0 || width > 4096 || height > 4096 ||
        _stopping.load() || _paused.load()) return;
    const BOOL hardware = data == RETRO_HW_FRAME_BUFFER_VALID;
    if (hardware && _metalActive) {
        CGSize size;
        BOOL landscape;
        NSDictionary *options;
        @synchronized (self) {
            size = _metalDisplaySize;
            landscape = _displayLandscape;
            options = _displayOptions ?: _gameOptions;
        }
        const auto geometry = AZMakeDisplayGeometry(CGSizeMake(width,height), size, landscape, options);
        if (geometry.count && size.width >= 1 && size.height >= 1) {
            // Compute the same normalized layout as the CPU fallback and touch input.
            float rect[16]{};
            for (unsigned n=0; n<geometry.count; ++n) {
                const CGRect src=geometry.source[n], dst=geometry.destination[n];
                float *r=rect+n*8;
                r[0]=CGRectGetMinX(src); r[1]=CGRectGetMinY(src);
                r[2]=CGRectGetMaxX(src); r[3]=CGRectGetMaxY(src);
                r[4]=CGRectGetMinX(dst)/size.width; r[5]=CGRectGetMinY(dst)/size.height;
                r[6]=CGRectGetMaxX(dst)/size.width; r[7]=CGRectGetMaxY(dst)/size.height;
            }
            ++_metalAttempts;
            const int result = _vkPresentFrame(width, height, (unsigned)std::lround(size.width),
                                               (unsigned)std::lround(size.height), rect, geometry.count);
            if (_vkPresentExtent) {
                unsigned surfaceWidth = 0, surfaceHeight = 0;
                _vkPresentExtent(&surfaceWidth, &surfaceHeight);
                if (surfaceWidth != _lastSurfaceWidth || surfaceHeight != _lastSurfaceHeight ||
                    !CGSizeEqualToSize(size, _lastRequestedSurface)) {
                    _lastSurfaceWidth = surfaceWidth;
                    _lastSurfaceHeight = surfaceHeight;
                    _lastRequestedSurface = size;
                    [self writeDiagnostic:[NSString stringWithFormat:
                        @"Metal resolution: core %ux%u; requested drawable %.0fx%.0f px; actual swapchain %ux%u px; status %d",
                        width, height, size.width, size.height, surfaceWidth, surfaceHeight, result]];
                }
            }
            if (result == 1) {
                ++_metalSubmitted;
                _metalPending = 0;
                _readbackFailures = 0;
                if (!_receivedFirstVideo) {
                    _receivedFirstVideo = YES;
                    _waitingForFirstFrame.store(false);
                    [self reportJITStage:[NSString stringWithFormat:
                        @"First GPU-only Metal surface submission: %u x %u", width, height]];
                }
                if (_metalWidth != width || _metalHeight != height) {
                    _metalWidth=width; _metalHeight=height;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        id<AzaharEmulatorDelegate> delegate = self.delegate;
                        if (!_stopping.load() &&
                            [delegate respondsToSelector:@selector(azaharEmulatorDidPresentMetalFrameWidth:height:)])
                            [delegate azaharEmulatorDidPresentMetalFrameWidth:width height:height];
                    });
                }
                return;
            }
            if (result == 0 && ++_metalPending < 120) return;
        } else if (++_metalPending < 120) {
            return;
        }
        _metalActive = false;
        [self reportJITStage:@"Direct Metal surface unavailable or busy; using Vulkan CPU readback"];
    }
    if (_frameQueued.exchange(true)) return;
    bool rgba = false;
    if (hardware) {
        const auto started = std::chrono::steady_clock::now();
        const void *gpuPixels = nullptr;
        int status = -1;
        if (_vkInterface && _vkReadbackFrame) {
            const bool async = ![self.launchOptions[@"AzaharVulkanReadback"] isEqual:@"sync"];
            status = _vkReadbackFrame(width, height, &gpuPixels, &pitch, &rgba, async);
        } else if (_vkReadback && _vkInterface) {
            status = _vkReadback(width, height, &gpuPixels, &pitch) ? 1 : -1;
        }
        ++_readbackAttempts;
        _readbackMilliseconds += std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started).count();
        if (status == 0) {
            ++_readbackPending;
            _frameQueued.store(false);
            return;
        }
        data = status == 1 ? gpuPixels : nullptr;
    }
    if (!data || pitch < width * 4 || pitch > 4096 * 4) {
        if (hardware) {
            if (_vkReadbackFailed && _vkReadbackFailed()) {
                _readbackFailures = 3;
                [self reportJITStage:@"MoltenVK GPU submission failed or fence timed out; leaving frame loop"];
            } else if (++_readbackFailures == 1) {
                [self reportJITStage:@"MoltenVK image readback failed"];
            }
        }
        _frameQueued.store(false);
        return;
    }
    _readbackFailures = 0;

    if (!_receivedFirstVideo) {
        _receivedFirstVideo = YES;
        // A returned retro_run() alone does not prove a video buffer arrived.
        _waitingForFirstFrame.store(false);
        [self reportJITStage:[NSString stringWithFormat:
            @"First %@ video buffer: %u x %u", hardware ? @"MoltenVK" : @"software", width, height]];
    }
    NSData *pixels = [NSData dataWithBytes:data length:pitch * height];
    dispatch_async(dispatch_get_main_queue(), ^{
        CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
        CGColorSpaceRef colors = CGColorSpaceCreateDeviceRGB();
        CGImageRef frame = CGImageCreate(width, height, 8, 32, pitch,
            colors, rgba ? (kCGBitmapByteOrder32Big | kCGImageAlphaNoneSkipLast)
                         : (kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst),
            provider, NULL, false, kCGRenderingIntentDefault);
        if (frame) {
            UIImage *image = [UIImage imageWithCGImage:frame];
            id<AzaharEmulatorDelegate> delegate = self.delegate;
            if (delegate && !_stopping.load() && !_paused.load()) {
                [delegate azaharEmulatorDidRenderImage:image];
                if (_deliveredImages.fetch_add(1, std::memory_order_relaxed) == 0) {
                    [self reportJITStage:hardware ? @"First MoltenVK image delivered to the game view"
                                                  : @"First software image delivered to the game view"];
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
    return _stopping.load() || _paused.load();
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
    if (_stopping.exchange(true)) return;
    _input.Enable(false);
    // Prefer cooperative exit; only interrupt a genuinely delayed worker.
    // Keep the bridge/library lifetime protected and never block UIKit.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self writeDiagnostic:@"LIFECYCLE stop requested; waiting for cooperative exit"];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        if (self->_stopping.load() && !self->_pauseAcknowledged.load())
            [self requestJITHalt];
    });
}

@end
