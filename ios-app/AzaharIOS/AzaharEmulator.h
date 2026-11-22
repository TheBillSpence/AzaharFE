#import <UIKit/UIKit.h>

@protocol AzaharEmulatorDelegate <NSObject>
- (void)azaharEmulatorDidRenderImage:(UIImage *)image;
- (void)azaharEmulatorDidFail:(NSString *)message;
- (void)azaharEmulatorDidMeasureFPS:(double)fps jitActive:(BOOL)jitActive;
@end

@interface AzaharEmulator : NSObject
@property (nonatomic, weak) id<AzaharEmulatorDelegate> delegate;
@property (nonatomic, assign) BOOL experimentalJITEnabled;
@property (nonatomic, readonly) BOOL jitActive;

// Loads the bundled libretro dylib and starts the emulation loop on a worker queue.
- (BOOL)startGameAtURL:(NSURL *)url error:(NSError **)error;
- (void)stop;
- (void)setButton:(unsigned)identifier pressed:(BOOL)pressed;
@end
