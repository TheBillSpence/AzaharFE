#import "AZAudioOutput.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include "AZAudioBuffer.h"
#include <atomic>
#include <cmath>
#include <cstring>

static constexpr UInt32 kBufferFrames = 512;
static constexpr UInt32 kBufferBytes = kBufferFrames * 2 * sizeof(int16_t);

namespace {
struct Playback {
    AZAudioBuffer pcm;
    std::atomic<bool> running{false};
    AudioQueueRef queue = nullptr;
};
void FillBuffer(void *context, AudioQueueRef queue, AudioQueueBufferRef buffer) {
    auto *state = static_cast<Playback *>(context);
    if (!state->running.load(std::memory_order_acquire)) return;
    state->pcm.PullBuffered(static_cast<int16_t *>(buffer->mAudioData), kBufferFrames, 1536);
    buffer->mAudioDataByteSize = kBufferBytes;
    if (state->running.load(std::memory_order_acquire))
        AudioQueueEnqueueBuffer(queue, buffer, 0, nullptr);
}
}

@implementation AZAudioOutput {
    Playback _playback;
    BOOL _sessionActive;
}

- (BOOL)startWithSampleRate:(double)sampleRate {
    [self stop];
    if (!std::isfinite(sampleRate) || sampleRate < 8000 || sampleRate > 192000) return NO;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSError *error = nil;
    if (![session setCategory:AVAudioSessionCategoryPlayback
                         mode:AVAudioSessionModeDefault
                      options:0 error:&error] ||
        ![session setActive:YES error:&error]) {
        NSLog(@"Azahar audio session: %@", error);
        return NO;
    }
    _sessionActive = YES;
    AudioStreamBasicDescription format{};
    format.mSampleRate = sampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    format.mBytesPerPacket = 4;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = 4;
    format.mChannelsPerFrame = 2;
    format.mBitsPerChannel = 16;
    OSStatus result = AudioQueueNewOutput(&format, FillBuffer, &_playback,
                                         nullptr, nullptr, 0, &_playback.queue);
    if (result != noErr) { [self stop]; return NO; }
    _playback.running.store(true, std::memory_order_release);
    for (unsigned i = 0; i < 3; ++i) {
        AudioQueueBufferRef buffer = nullptr;
        result = AudioQueueAllocateBuffer(_playback.queue, kBufferBytes, &buffer);
        if (result != noErr) { [self stop]; return NO; }
        memset(buffer->mAudioData, 0, kBufferBytes);
        buffer->mAudioDataByteSize = kBufferBytes;
        result = AudioQueueEnqueueBuffer(_playback.queue, buffer, 0, nullptr);
        if (result != noErr) { [self stop]; return NO; }
    }
    if (AudioQueueStart(_playback.queue, nullptr) != noErr) {
        [self stop];
        return NO;
    }
    return YES;
}

- (void)appendSamples:(const int16_t *)samples frames:(size_t)frames {
    if (_playback.running.load(std::memory_order_acquire))
        _playback.pcm.Push(samples, frames);
}

- (void)stop {
    _playback.running.store(false, std::memory_order_release);
    if (_playback.queue) {
        AudioQueueStop(_playback.queue, true);
        AudioQueueDispose(_playback.queue, true);
        _playback.queue = nullptr;
    }
    _playback.pcm.Clear();
    if (_sessionActive) {
        [AVAudioSession.sharedInstance setActive:NO
                                     withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                           error:NULL];
        _sessionActive = NO;
    }
}

- (void)dealloc { [self stop]; }
@end
