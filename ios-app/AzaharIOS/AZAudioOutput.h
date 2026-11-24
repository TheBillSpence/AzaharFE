#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stddef.h>

@interface AZAudioOutput : NSObject
- (BOOL)startWithSampleRate:(double)sampleRate;
- (void)appendSamples:(const int16_t *)samples frames:(size_t)frames;
- (void)stop;
@end
