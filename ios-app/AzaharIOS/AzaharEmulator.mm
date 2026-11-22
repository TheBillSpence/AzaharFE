#import "AzaharEmulator.h"

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <stdarg.h>
#import <stdio.h>

#include <atomic>
#include <chrono>
#include <thread>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <sys/mman.h>
#include <unistd.h>
#include "libretro.h"

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
static bool AzaharProbeJITMapping() {
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
            vm_deallocate(mach_task_self(), rw, (vm_size_t)size);
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
    std::atomic<bool> _stopping;
    std::atomic<bool> _frameQueued;
    std::atomic<uint64_t> _buttons;
    BOOL _jitEnabled;
    BOOL _running;
    NSMutableString *_jitDiagnostics;
    NSString *_systemDirectory;
    NSString *_saveDirectory;
    NSString *_lastMessage;

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
@end

static bool AzaharEnvironment(unsigned command, void *data) {
    AzaharEmulator *host = sCurrentEmulator;
    return host ? [host handleEnvironment:command data:data] : false;
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

- (BOOL)jitActive { return _jitEnabled; }

// Persist each stage before risky JIT debugger operations, because a stalled
// breakpoint may stop every process thread before a UI message can repaint.
- (void)reportJITStage:(NSString *)message {
    NSLog(@"Azahar JIT27: %@", message);
    @synchronized (self) {
        if (!_jitDiagnostics) _jitDiagnostics = [NSMutableString new];
        [_jitDiagnostics appendFormat:@"%.3f %@\n",
            [[NSDate date] timeIntervalSince1970], message];
        NSString *documents = [_saveDirectory stringByDeletingLastPathComponent];
        NSString *path = [documents stringByAppendingPathComponent:@"AzaharJITDiagnostics.txt"];
        NSError *error = nil;
        if (![_jitDiagnostics writeToFile:path atomically:YES
                                encoding:NSUTF8StringEncoding error:&error]) {
            NSLog(@"Azahar JIT27 diagnostic write failed: %@", error);
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.delegate azaharEmulatorDidChangeJITStatus:message];
    });
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

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
    if (_running) {
        if (error) *error = [NSError errorWithDomain:@"AzaharIOS" code:3
            userInfo:@{NSLocalizedDescriptionKey: @"A game is already running."}];
        return NO;
    }
    if (![self loadLibrary:error]) return NO;

    _running = YES;
    _stopping.store(false);
    _frameQueued.store(false);
    _buttons.store(0);
    _jitDiagnostics = [NSMutableString new];
    // JIT readiness is evaluated on the worker, after StikDebug attaches.
    _jitEnabled = NO;
    sCurrentEmulator = self;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self runGameAtURL:url];
    });
    return YES;
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

            const bool debugged = AzaharDebuggerIsEnabled();
            if (debugged) {
                [self reportJITStage:@"2/7 Debugger found; requesting 16 KB JIT memory"];
            } else {
                [self reportJITStage:@"Debugger NOT found; using interpreter"];
            }
            // The breakpoint must be handled by universal.js. If it stalls,
            // the last durable log entry will identify this exact operation.
            _jitEnabled = debugged && AzaharProbeJITMapping();
            if (_jitEnabled) {
                [self reportJITStage:@"3/7 JIT mapping prepared; initializing core"];
            } else if (debugged) {
                [self reportJITStage:@"Universal JIT memory failed; using interpreter"];
            }
        } else {
            [self reportJITStage:@"JIT OFF; initializing interpreter"];
        }

        _setEnvironment(AzaharEnvironment);
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
        [self reportJITStage:loaded ? @"6/7 Game loaded; starting first frame"
                                    : @"Game load failed"];
        if (!loaded) {
            NSString *message = _lastMessage ?: @"Azahar couldn't load this game. Check the ROM format and whether it is decrypted.";
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate azaharEmulatorDidFail:message];
            });
        } else {
            auto nextFrame = std::chrono::steady_clock::now();
            auto fpsWindow = nextFrame;
            unsigned frameCount = 0;
            while (!_stopping.load()) {
                @autoreleasepool {
                    _runFrame();
                }
                ++frameCount;
                if (frameCount == 1) {
                    [self reportJITStage:@"7/7 First frame returned; measuring FPS"];
                }
                auto now = std::chrono::steady_clock::now();
                double elapsed = std::chrono::duration<double>(now - fpsWindow).count();
                if (elapsed >= 1.0) {
                    double fps = frameCount / elapsed;
                    BOOL usedJITCandidate = _jitEnabled;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self.delegate azaharEmulatorDidMeasureFPS:fps
                                                        jitActive:usedJITCandidate];
                    });
                    fpsWindow = now;
                    frameCount = 0;
                }
                nextFrame += std::chrono::milliseconds(16);
                if (nextFrame < now) nextFrame = now;
                std::this_thread::sleep_until(nextFrame);
            }
            _unloadGame();
        }

        _deinitCore();
        sCurrentEmulator = nil;
        if (_libraryHandle) {
            dlclose(_libraryHandle);
            _libraryHandle = nullptr;
        }
        _running = NO;
    }
}

- (BOOL)handleEnvironment:(unsigned)command data:(void *)data {
    switch (command) {
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
        case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
            if (!data) return NO;
            *(bool *)data = false;
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
                    _lastMessage = [NSString stringWithUTF8String:message->msg];
                    // The linked libretro core sends bounded startup breadcrumbs.
                    // Persist them in Documents before JIT can stall again.
                    if ([_lastMessage hasPrefix:@"JIT27TRACE "]) {
                        [self reportJITStage:_lastMessage];
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
    if (!data || width == 0 || height == 0 ||
        width > 4096 || height > 4096 || pitch < width * 4 ||
        pitch > (4096 * 4) || _frameQueued.exchange(true)) return;

    NSData *pixels = [NSData dataWithBytes:data length:pitch * height];
    dispatch_async(dispatch_get_main_queue(), ^{
        CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
        CGColorSpaceRef colors = CGColorSpaceCreateDeviceRGB();
        CGImageRef frame = CGImageCreate(width, height, 8, 32, pitch,
            colors, kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst,
            provider, NULL, false, kCGRenderingIntentDefault);
        if (frame) {
            UIImage *image = [UIImage imageWithCGImage:frame];
            [self.delegate azaharEmulatorDidRenderImage:image];
            CGImageRelease(frame);
        }
        CGColorSpaceRelease(colors);
        CGDataProviderRelease(provider);
        _frameQueued.store(false);
    });
}

- (void)stop {
    _stopping.store(true);
    _buttons.store(0);
}

@end
