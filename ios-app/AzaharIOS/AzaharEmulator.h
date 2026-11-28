#import <UIKit/UIKit.h>
@class CAMetalLayer;

@class AzaharEmulator;

@protocol AzaharEmulatorDelegate <NSObject>
- (void)azaharEmulatorDidRenderImage:(UIImage *)image;
- (void)azaharEmulatorDidFail:(NSString *)message;
- (void)azaharEmulatorDidChangeJITStatus:(NSString *)status;
- (void)azaharEmulatorDidMeasureFPS:(double)fps jitActive:(BOOL)jitActive;
@optional
- (void)azaharEmulatorDidPresentMetalFrameWidth:(unsigned)width height:(unsigned)height;
- (void)azaharEmulatorDidFinish:(AzaharEmulator *)emulator;
@end

@interface AzaharEmulator : NSObject
@property (nonatomic, weak) id<AzaharEmulatorDelegate> delegate;
@property (nonatomic, assign) BOOL experimentalJITEnabled;
@property (nonatomic, readonly) BOOL jitActive;
// Retain the layer throughout the worker/core lifetime. Main thread sets its size.
@property (nonatomic, strong) CAMetalLayer *metalLayer;
- (void)setDisplaySize:(CGSize)size landscape:(BOOL)landscape options:(NSDictionary *)options;

+ (NSString *)sessionJITStatus;
+ (BOOL)hasActiveSession;
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSString *> *launchOptions;

// Loads the bundled libretro dylib and starts the emulation loop on a worker queue.
- (BOOL)startGameAtURL:(NSURL *)url error:(NSError **)error;
- (BOOL)startGameAtURL:(NSURL *)url options:(NSDictionary<NSString *, NSString *> *)options error:(NSError **)error;
- (void)stop;
- (void)setPaused:(BOOL)paused;
- (void)refreshAudioRoute;
- (void)setAudioInterrupted:(BOOL)interrupted;
// Persist frontend events without changing the emulator state.
- (void)recordFrontendEvent:(NSString *)event;
- (void)setInputEnabled:(BOOL)enabled;
- (void)setPointerX:(int16_t)x y:(int16_t)y pressed:(BOOL)down;
- (void)setCircleX:(int16_t)x y:(int16_t)y pressed:(BOOL)held;
- (void)setButton:(unsigned)identifier pressed:(BOOL)pressed;
@end
