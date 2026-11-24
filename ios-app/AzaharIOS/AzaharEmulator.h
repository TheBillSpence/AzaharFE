#import <UIKit/UIKit.h>

@protocol AzaharEmulatorDelegate <NSObject>
- (void)azaharEmulatorDidRenderImage:(UIImage *)image;
- (void)azaharEmulatorDidFail:(NSString *)message;
- (void)azaharEmulatorDidChangeJITStatus:(NSString *)status;
- (void)azaharEmulatorDidMeasureFPS:(double)fps jitActive:(BOOL)jitActive;
@end

@interface AzaharEmulator : NSObject
@property (nonatomic, weak) id<AzaharEmulatorDelegate> delegate;
@property (nonatomic, assign) BOOL experimentalJITEnabled;
@property (nonatomic, readonly) BOOL jitActive;

+ (NSString *)sessionJITStatus;
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSString *> *launchOptions;

// Loads the bundled libretro dylib and starts the emulation loop on a worker queue.
- (BOOL)startGameAtURL:(NSURL *)url error:(NSError **)error;
- (void)stop;
- (void)setInputEnabled:(BOOL)enabled;
- (void)setPointerX:(int16_t)x y:(int16_t)y pressed:(BOOL)down;
- (void)setCircleX:(int16_t)x y:(int16_t)y;
- (void)setButton:(unsigned)identifier pressed:(BOOL)pressed;
@end
