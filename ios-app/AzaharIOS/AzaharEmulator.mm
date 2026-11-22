#import "AzaharEmulator.h"

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <stdarg.h>
#import <stdio.h>

#include <atomic>
#include <chrono>
#include <thread>
#include "libretro.h"

@class AzaharEmulator;

static __weak AzaharEmulator *sCurrentEmulator;

@interface AzaharEmulator () {
    void *_libraryHandle;
    std::atomic<bool> _stopping;
    std::atomic<bool> _frameQueued;
    std::atomic<uint64_t> _buttons;
    BOOL _running;
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
    sCurrentEmulator = self;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self runGameAtURL:url];
    });
    return YES;
}

- (void)runGameAtURL:(NSURL *)url {
    @autoreleasepool {
        _setEnvironment(AzaharEnvironment);
        _setVideoRefresh(AzaharVideo);
        _setAudioSample(AzaharAudioSample);
        _setAudioBatch(AzaharAudioBatch);
        _setInputPoll(AzaharInputPoll);
        _setInputState(AzaharInputState);
        _initCore();

        struct retro_game_info game = {};
        game.path = url.fileSystemRepresentation;

        BOOL loaded = _loadGame(&game);
        if (!loaded) {
            NSString *message = _lastMessage ?: @"Azahar couldn't load this game. Check the ROM format and whether it is decrypted.";
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.delegate azaharEmulatorDidFail:message];
            });
        } else {
            auto nextFrame = std::chrono::steady_clock::now();
            while (!_stopping.load()) {
                @autoreleasepool {
                    _runFrame();
                }
                nextFrame += std::chrono::milliseconds(16);
                auto now = std::chrono::steady_clock::now();
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
            // Don't claim JIT is enabled without runtime entitlement/memory tests.
            *(bool *)data = false;
            return YES;
        case RETRO_ENVIRONMENT_SET_MESSAGE:
            if (data) {
                const retro_message *message = (const retro_message *)data;
                if (message->msg)
                    _lastMessage = [NSString stringWithUTF8String:message->msg];
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
