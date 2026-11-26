#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <AVFoundation/AVFoundation.h>
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import "AZDisplayGeometry.h"
#import "AzaharEmulator.h"
#import "AZPreferences.h"
#import "AZSettings.h"
#include "AZGameInput.h"

static NSArray<NSString *> *GameExtensions(void) {
    return @[@"3ds", @"3dsx", @"z3dsx", @"elf", @"axf", @"cci", @"zcci",
             @"cxi", @"zcxi", @"app", @"bcci", @"bcxi"];
}

static NSURL *GamesDirectory(void) {
    NSURL *documents = [[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
        inDomains:NSUserDomainMask] firstObject];
    NSURL *folder = [documents URLByAppendingPathComponent:@"Games" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:folder
        withIntermediateDirectories:YES attributes:nil error:NULL];
    return folder;
}

static UIImage *CoverThumbnail(NSURL *game) {
    UIImage *cover = AZGameArt(game);
    if (!cover) return nil;
    CGSize size = CGSizeMake(48, 64);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGFloat scale = MIN(size.width / cover.size.width, size.height / cover.size.height);
        CGSize scaled = CGSizeMake(cover.size.width * scale, cover.size.height * scale);
        [cover drawInRect:CGRectMake((size.width-scaled.width)/2, (size.height-scaled.height)/2,
                                    scaled.width, scaled.height)];
    }];
}

static UILabel *MakeLabel(NSString *text, CGFloat size) {
    UILabel *label = [UILabel new];
    label.text = text;
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont systemFontOfSize:size];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

@interface AZTouchScreen : UIImageView
@property (nonatomic, weak) AzaharEmulator *host;
@property (nonatomic, strong) UIImage *frameImage;
@property (nonatomic, strong) CAMetalLayer *metalPanel;
@property (nonatomic, strong) CALayer *topPanel;
@property (nonatomic, strong) CALayer *bottomPanel;
@property (nonatomic) CGSize frameSize;
@property (nonatomic) BOOL landscape;
@property (nonatomic) BOOL metalVisible;
@property (nonatomic, copy) NSDictionary *displayOptions;
- (void)displayFrame:(UIImage *)image;
- (void)displayMetalWidth:(unsigned)width height:(unsigned)height;
- (void)configureLandscape:(BOOL)landscape options:(NSDictionary *)options;
- (CAMetalLayer *)prepareMetal;
@end

@implementation AZTouchScreen
- (CAMetalLayer *)prepareMetal {
    if (!self.metalPanel) {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return nil;
        CAMetalLayer *layer = [CAMetalLayer layer];
        layer.device = device;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = NO;
        layer.opaque = YES;
        layer.maximumDrawableCount = 3;
        layer.presentsWithTransaction = NO;
        layer.allowsNextDrawableTimeout = YES;
        [self.layer addSublayer:layer];
        self.metalPanel = layer;
    }
    self.metalVisible = YES;
    self.metalPanel.hidden = NO;
    [self setNeedsLayout];
    return self.metalPanel;
}

- (void)configureLandscape:(BOOL)landscape options:(NSDictionary *)options {
    if (_landscape == landscape && [_displayOptions isEqual:options]) return;
    [self.host setPointerX:0 y:0 pressed:NO];
    _landscape = landscape;
    _displayOptions = [options copy];
    [self setNeedsLayout];
}

- (AZDisplayGeometry)geometry {
    return AZMakeDisplayGeometry(self.frameSize,self.bounds.size,self.landscape,self.displayOptions);
}

- (void)displayFrame:(UIImage *)image {
    const CGSize previous = self.frameSize;
    const BOOL wasMetal = self.metalVisible;
    self.frameImage = image;
    self.frameSize = image ? image.size : CGSizeZero;
    self.metalVisible = NO;
    self.metalPanel.hidden = YES;
    if (!self.topPanel) {
        self.topPanel = [CALayer layer];
        self.bottomPanel = [CALayer layer];
        self.topPanel.contentsGravity = kCAGravityResize;
        self.bottomPanel.contentsGravity = kCAGravityResize;
        [self.layer addSublayer:self.topPanel];
        [self.layer addSublayer:self.bottomPanel];
    }
    self.image = nil;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.topPanel.contents = self.bottomPanel.contents = image ? (__bridge id)image.CGImage : nil;
    [CATransaction commit];
    if (wasMetal || !CGSizeEqualToSize(previous,self.frameSize) || !image) [self setNeedsLayout];
}

- (void)displayMetalWidth:(unsigned)width height:(unsigned)height {
    self.frameImage = nil;
    self.image = nil;
    self.frameSize = CGSizeMake(width,height);
    self.metalVisible = YES;
    self.metalPanel.hidden = NO;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    const auto geometry = [self geometry];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.metalPanel.frame = self.bounds;
    CGFloat scale = self.window ? self.window.screen.scale : UIScreen.mainScreen.scale;
    CGSize drawableSize = CGSizeMake(std::lround(self.bounds.size.width*scale),
                                    std::lround(self.bounds.size.height*scale));
    if (drawableSize.width > 0 && drawableSize.height > 0 &&
        !CGSizeEqualToSize(self.metalPanel.drawableSize,drawableSize))
        self.metalPanel.drawableSize = drawableSize;
    self.topPanel.hidden = self.metalVisible || !geometry.count;
    self.bottomPanel.hidden = self.metalVisible || geometry.count < 2;
    if (geometry.count) {
        self.topPanel.frame = geometry.destination[0];
        self.topPanel.contentsRect = geometry.source[0];
    }
    if (geometry.count > 1) {
        self.bottomPanel.frame = geometry.destination[1];
        self.bottomPanel.contentsRect = geometry.source[1];
    }
    [CATransaction commit];
}

- (void)updateTouch:(UITouch *)touch {
    CGPoint p = [touch locationInView:self];
    const auto geometry = [self geometry];
    if (geometry.touchIndex < 0) {
        [self.host setPointerX:0 y:0 pressed:NO];
        return;
    }
    CGRect target = geometry.destination[geometry.touchIndex];
    if (CGRectIsEmpty(target) || !CGRectContainsPoint(target,p)) {
        [self.host setPointerX:0 y:0 pressed:NO];
        return;
    }
    CGRect source = geometry.source[geometry.touchIndex];
    const double u = source.origin.x + source.size.width * (p.x-target.origin.x)/target.size.width;
    const double v = source.origin.y + source.size.height * (p.y-target.origin.y)/target.size.height;
    [self.host setPointerX:AZInput::Axis(u*2-1) y:AZInput::Axis(v*2-1) pressed:YES];
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self updateTouch:touches.anyObject];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self updateTouch:touches.anyObject];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self.host setPointerX:0 y:0 pressed:NO];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self.host setPointerX:0 y:0 pressed:NO];
}
@end

@interface AZCirclePad : UIControl
@property (nonatomic, weak) AzaharEmulator *host;
@property (nonatomic) CGPoint deflection;
- (void)centerStick;
@end

@implementation AZCirclePad
- (void)drawRect:(CGRect)rect {
    CGRect b = self.bounds;
    const CGFloat diameter = MIN(b.size.width, b.size.height) - 4;
    CGPoint c = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
    UIColor *rim = [UIColor colorWithWhite:0.75 alpha:0.52];
    UIBezierPath *base = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(c.x-diameter/2, c.y-diameter/2, diameter, diameter)];
    [[UIColor colorWithWhite:0.09 alpha:0.95] setFill];
    [base fill];
    [rim setStroke]; base.lineWidth = 1.5; [base stroke];
    UIBezierPath *inner = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(base.bounds, 6, 6)];
    [[UIColor colorWithWhite:0.28 alpha:0.75] setStroke]; inner.lineWidth = 1; [inner stroke];
    const CGFloat thumb = diameter * 0.46;
    const CGFloat travel = (diameter - thumb) / 2;
    UIBezierPath *knob = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(
        c.x + self.deflection.x * travel - thumb/2, c.y + self.deflection.y * travel - thumb/2, thumb, thumb)];
    [[UIColor colorWithWhite:0.65 alpha:1] setFill]; [knob fill];
    [[UIColor colorWithWhite:0.92 alpha:0.7] setStroke]; knob.lineWidth = 1.5; [knob stroke];
}
- (void)moveStick:(UITouch *)touch {
    CGPoint p = [touch locationInView:self];
    CGRect b = self.bounds;
    const CGFloat radius = MAX(1.0, MIN(b.size.width, b.size.height) / 2);
    double x = (p.x - CGRectGetMidX(b)) / radius, y = (p.y - CGRectGetMidY(b)) / radius;
    const double length = std::max(1.0, std::hypot(x, y));
    self.deflection = CGPointMake(x / length, y / length);
    [self.host setCircleX:AZInput::Axis(self.deflection.x) y:AZInput::Axis(self.deflection.y)];
    [self setNeedsDisplay];
}
- (void)centerStick {
    self.deflection = CGPointZero;
    [self.host setCircleX:0 y:0];
    [self setNeedsDisplay];
}
- (BOOL)beginTracking:(UITouch *)touch withEvent:(UIEvent *)event {
    [self moveStick:touch]; return YES;
}
- (BOOL)continueTracking:(UITouch *)touch withEvent:(UIEvent *)event {
    [self moveStick:touch]; return YES;
}
- (void)endTracking:(UITouch *)touch withEvent:(UIEvent *)event { [self centerStick]; }
- (void)cancelTrackingWithEvent:(UIEvent *)event { [self centerStick]; }
@end

// Original handheld-inspired controls: separate diamond and cross clusters,
// tactile pressed states and unobtrusive graphite styling.
@interface AZPadButton : UIButton
@property (nonatomic) BOOL roundCap;
@end
@implementation AZPadButton
- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = self.roundCap ? MIN(self.bounds.size.width, self.bounds.size.height) / 2 : 8;
}
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.backgroundColor = highlighted ? [UIColor colorWithWhite:0.58 alpha:1] :
        [UIColor colorWithWhite:0.23 alpha:0.97];
    self.layer.borderColor = [UIColor colorWithWhite:highlighted ? 0.94 : 0.55 alpha:0.85].CGColor;
    self.transform = highlighted ? CGAffineTransformMakeScale(0.94, 0.94) : CGAffineTransformIdentity;
}
@end

@interface AZControllerDeck : UIView
@property (nonatomic, strong) AZCirclePad *stick;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, AZPadButton *> *buttons;
@property (nonatomic) BOOL landscape;
@end
@implementation AZControllerDeck
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // The transparent center must not intercept the 3DS touchscreen.
    return hit == self ? nil : hit;
}
- (void)place:(unsigned)identifier x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w h:(CGFloat)h {
    AZPadButton *button = self.buttons[@(identifier)];
    button.frame = CGRectMake(x-w/2, y-h/2, w, h);
}
- (void)layoutSubviews {
    [super layoutSubviews];
    const CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    if (self.landscape) {
        const CGFloat side = MIN(140, w * 0.23);
        const CGFloat left = side/2, right = w-side/2;
        const CGFloat f = MIN(34, MIN(side/3.5, h/7.5)), d = MIN(26, f);
        const CGFloat stick = MIN(58, h*0.26);
        self.stick.frame = CGRectMake(left-stick/2, h*0.34-stick/2, stick, stick);
        const CGFloat shoulder = MIN(54, side/2-4);
        [self place:RETRO_DEVICE_ID_JOYPAD_L x:side*0.25 y:h*0.08 w:shoulder h:24];
        [self place:RETRO_DEVICE_ID_JOYPAD_L2 x:side*0.75 y:h*0.08 w:shoulder h:24];
        [self place:RETRO_DEVICE_ID_JOYPAD_R2 x:w-side*0.75 y:h*0.08 w:shoulder h:24];
        [self place:RETRO_DEVICE_ID_JOYPAD_R x:w-side*0.25 y:h*0.08 w:shoulder h:24];
        const CGFloat cross = h*0.72, diamond = h*0.36, step = f+2;
        [self place:RETRO_DEVICE_ID_JOYPAD_UP x:left y:cross-d w:d h:d];
        [self place:RETRO_DEVICE_ID_JOYPAD_DOWN x:left y:cross+d w:d h:d];
        [self place:RETRO_DEVICE_ID_JOYPAD_LEFT x:left-d y:cross w:d h:d];
        [self place:RETRO_DEVICE_ID_JOYPAD_RIGHT x:left+d y:cross w:d h:d];
        [self place:RETRO_DEVICE_ID_JOYPAD_X x:right y:diamond-step w:f h:f];
        [self place:RETRO_DEVICE_ID_JOYPAD_B x:right y:diamond+step w:f h:f];
        [self place:RETRO_DEVICE_ID_JOYPAD_Y x:right-step y:diamond w:f h:f];
        [self place:RETRO_DEVICE_ID_JOYPAD_A x:right+step y:diamond w:f h:f];
        [self place:RETRO_DEVICE_ID_JOYPAD_SELECT x:left+side*0.28 y:h*0.94 w:MIN(54,side/2-4) h:20];
        [self place:RETRO_DEVICE_ID_JOYPAD_START x:right-side*0.28 y:h*0.60 w:MIN(54,side/2-4) h:20];
        return;
    }
    const CGFloat left = w * 0.19, right = w * 0.81;
    const CGFloat face = MIN(40, w * 0.115), step = face + 2;
    const CGFloat dpad = MIN(28, w * 0.08);
    const CGFloat stickSize = MIN(62, h * 0.31);
    self.stick.frame = CGRectMake(left-stickSize/2, h*0.36-stickSize/2, stickSize, stickSize);
    const CGFloat shoulder = MIN(73, w*0.21);
    [self place:RETRO_DEVICE_ID_JOYPAD_L x:w*0.13 y:h*0.09 w:shoulder h:29];
    [self place:RETRO_DEVICE_ID_JOYPAD_L2 x:w*0.37 y:h*0.09 w:shoulder h:29];
    [self place:RETRO_DEVICE_ID_JOYPAD_R2 x:w*0.63 y:h*0.09 w:shoulder h:29];
    [self place:RETRO_DEVICE_ID_JOYPAD_R x:w*0.87 y:h*0.09 w:shoulder h:29];
    const CGFloat cross = h*0.76;
    [self place:RETRO_DEVICE_ID_JOYPAD_UP x:left y:cross-dpad w:dpad h:dpad];
    [self place:RETRO_DEVICE_ID_JOYPAD_DOWN x:left y:cross+dpad w:dpad h:dpad];
    [self place:RETRO_DEVICE_ID_JOYPAD_LEFT x:left-dpad y:cross w:dpad h:dpad];
    [self place:RETRO_DEVICE_ID_JOYPAD_RIGHT x:left+dpad y:cross w:dpad h:dpad];
    const CGFloat diamond = h*0.56;
    [self place:RETRO_DEVICE_ID_JOYPAD_X x:right y:diamond-step w:face h:face];
    [self place:RETRO_DEVICE_ID_JOYPAD_B x:right y:diamond+step w:face h:face];
    [self place:RETRO_DEVICE_ID_JOYPAD_Y x:right-step y:diamond w:face h:face];
    [self place:RETRO_DEVICE_ID_JOYPAD_A x:right+step y:diamond w:face h:face];
    const CGFloat menuWidth = MIN(54, w*0.14);
    [self place:RETRO_DEVICE_ID_JOYPAD_SELECT x:w*0.41 y:h*0.87 w:menuWidth h:24];
    [self place:RETRO_DEVICE_ID_JOYPAD_START x:w*0.57 y:h*0.87 w:menuWidth h:24];
}
@end

@interface AZDisplayMenu : UITableViewController
@property (nonatomic, strong) NSURL *game;
@property (nonatomic, copy) void (^changed)(void);
@end

@implementation AZDisplayMenu
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return AZDisplayKeys().count;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    NSString *key = AZDisplayKeys()[indexPath.row];
    cell.textLabel.text = AZOptionTitle(key);
    cell.detailTextLabel.text = AZChoiceTitle(key,AZValue(key,self.game));
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *key = AZDisplayKeys()[indexPath.row];
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:AZOptionTitle(key)
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *value in AZChoices(key)) {
        [menu addAction:[UIAlertAction actionWithTitle:AZChoiceTitle(key,value)
            style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                AZSetValue(key,value,self.game);
                if (self.changed) self.changed();
                [tableView reloadData];
            }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"Use universal setting" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            AZSetValue(key,nil,self.game);
            if (self.changed) self.changed();
            [tableView reloadData];
        }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView = tableView;
    menu.popoverPresentationController.sourceRect = [tableView rectForRowAtIndexPath:indexPath];
    [self presentViewController:menu animated:YES completion:nil];
}
@end

@interface AzaharGameViewController : UIViewController <AzaharEmulatorDelegate, UIAdaptivePresentationControllerDelegate>
- (instancetype)initWithGame:(NSURL *)game;
@end

@interface AzaharGameViewController ()
@property (nonatomic, strong) NSURL *game;
@property (nonatomic, strong) AzaharEmulator *host;
@property (nonatomic, strong) AZTouchScreen *screen;
@property (nonatomic, strong) AZCirclePad *circlePad;
@property (nonatomic, strong) AZControllerDeck *controls;
@property (nonatomic) BOOL settingsOpen;
@property (nonatomic) BOOL restartPending;
@property (nonatomic) BOOL leavingGame;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *settingsSnapshot;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *previousOptions;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *pendingOptions;
@property (nonatomic) BOOL audioInterrupted;
@property (nonatomic, strong) UILabel *status;
@property (nonatomic, assign) BOOL started;
@end

@implementation AzaharGameViewController

- (instancetype)initWithGame:(NSURL *)game {
    if ((self = [super init])) self.game = game;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Keep long ROM filenames from competing with the navigation back button.
    self.title = self.game.lastPathComponent.stringByDeletingPathExtension;
    self.view.backgroundColor = [UIColor colorWithWhite:0.045 alpha:1];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;

    UIBarButtonItem *gear = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"gearshape"]
        style:UIBarButtonItemStylePlain target:self action:@selector(showSettings)];
    gear.accessibilityLabel = @"Session settings";
    UIBarButtonItem *stop = [[UIBarButtonItem alloc]
        initWithTitle:@"Stop" style:UIBarButtonItemStylePlain
        target:self action:@selector(stopGame)];
    stop.tintColor = UIColor.systemRedColor;
    stop.accessibilityLabel = @"Stop game and return to library";
    self.navigationItem.rightBarButtonItems = @[gear, stop];
    UIBarButtonItem *display = [[UIBarButtonItem alloc] initWithTitle:@"Display Options"
        style:UIBarButtonItemStylePlain target:self action:@selector(showDisplayOptions)];
    [display setTitleTextAttributes:@{NSFontAttributeName:[UIFont systemFontOfSize:11 weight:UIFontWeightMedium]}
                           forState:UIControlStateNormal];
    self.navigationItem.leftItemsSupplementBackButton = YES;
    self.navigationItem.leftBarButtonItem = display;
    NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
    [notifications addObserver:self selector:@selector(appInactive:) name:UIApplicationWillResignActiveNotification object:nil];
    [notifications addObserver:self selector:@selector(appActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [notifications addObserver:self selector:@selector(audioInterrupted:) name:AVAudioSessionInterruptionNotification object:nil];
    [notifications addObserver:self selector:@selector(audioReset:) name:AVAudioSessionMediaServicesWereResetNotification object:nil];
    [notifications addObserver:self selector:@selector(controllerChanged:) name:GCControllerDidConnectNotification object:nil];
    [notifications addObserver:self selector:@selector(controllerChanged:) name:GCControllerDidDisconnectNotification object:nil];
    self.screen = [AZTouchScreen new];
    self.screen.userInteractionEnabled = YES;
    self.screen.contentMode = UIViewContentModeScaleAspectFit;
    self.screen.backgroundColor = UIColor.blackColor;
    self.screen.layer.cornerRadius = 10;
    self.screen.clipsToBounds = YES;
    self.screen.translatesAutoresizingMaskIntoConstraints = YES;
    [self.screen setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                   forAxis:UILayoutConstraintAxisVertical];
    [self.view addSubview:self.screen];

    self.status = MakeLabel(@"Starting Azahar...\nExperimental JIT test", 12);
    self.status.translatesAutoresizingMaskIntoConstraints = YES;
    self.status.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightMedium];
    self.status.textAlignment = NSTextAlignmentLeft;
    self.status.numberOfLines = 3;
    self.status.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.status setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                  forAxis:UILayoutConstraintAxisVertical];
    [self.view addSubview:self.status];

    AZControllerDeck *controls = [AZControllerDeck new];
    controls.buttons = [NSMutableDictionary new];
    controls.translatesAutoresizingMaskIntoConstraints = YES;
    self.controls = controls;
    controls.multipleTouchEnabled = YES;
    [self.view addSubview:controls];

    self.circlePad = [AZCirclePad new];
    self.circlePad.backgroundColor = UIColor.clearColor;
    self.circlePad.opaque = NO;
    self.circlePad.accessibilityLabel = @"Circle Pad";
    controls.stick = self.circlePad;
    [controls addSubview:self.circlePad];

    NSArray<NSString *> *labels = @[@"↑", @"↓", @"←", @"→", @"A", @"B", @"X", @"Y",
        @"L", @"R", @"ZL", @"ZR", @"START", @"SELECT"];
    NSArray<NSNumber *> *ids = @[@(RETRO_DEVICE_ID_JOYPAD_UP), @(RETRO_DEVICE_ID_JOYPAD_DOWN),
        @(RETRO_DEVICE_ID_JOYPAD_LEFT), @(RETRO_DEVICE_ID_JOYPAD_RIGHT),
        @(RETRO_DEVICE_ID_JOYPAD_A), @(RETRO_DEVICE_ID_JOYPAD_B),
        @(RETRO_DEVICE_ID_JOYPAD_X), @(RETRO_DEVICE_ID_JOYPAD_Y),
        @(RETRO_DEVICE_ID_JOYPAD_L), @(RETRO_DEVICE_ID_JOYPAD_R),
        @(RETRO_DEVICE_ID_JOYPAD_L2), @(RETRO_DEVICE_ID_JOYPAD_R2),
        @(RETRO_DEVICE_ID_JOYPAD_START), @(RETRO_DEVICE_ID_JOYPAD_SELECT)];
    NSArray<UIColor *> *faceColors = @[
        [UIColor colorWithRed:0.99 green:0.48 blue:0.44 alpha:1],
        [UIColor colorWithRed:0.99 green:0.82 blue:0.45 alpha:1],
        [UIColor colorWithRed:0.47 green:0.74 blue:0.99 alpha:1],
        [UIColor colorWithRed:0.47 green:0.87 blue:0.61 alpha:1]];
    for (NSUInteger i = 0; i < labels.count; ++i) {
        AZPadButton *button = [[AZPadButton alloc] initWithFrame:CGRectZero];
        button.tag = ids[i].integerValue;
        button.roundCap = i >= 4 && i < 8;
        [button setTitle:labels[i] forState:UIControlStateNormal];
        [button setTitleColor:button.roundCap ? faceColors[i-4] : UIColor.whiteColor forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont monospacedSystemFontOfSize:i >= 12 ? 9 : (button.roundCap ? 18 : 13)
                                                             weight:UIFontWeightSemibold];
        button.titleLabel.adjustsFontSizeToFitWidth = YES;
        button.titleLabel.minimumScaleFactor = 0.7;
        button.accessibilityLabel = labels[i];
        button.exclusiveTouch = NO;
        button.layer.borderWidth = 1.3;
        button.layer.masksToBounds = YES;
        [button setHighlighted:NO];
        [button addTarget:self action:@selector(press:) forControlEvents:UIControlEventTouchDown];
        [button addTarget:self action:@selector(release:)
         forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        controls.buttons[ids[i]] = button;
        [controls addSubview:button];
    }

    [self refreshControllerVisibility];
}

- (void)refreshControllerVisibility {
    BOOL connected = NO;
    for (GCController *controller in GCController.controllers) {
        if (controller.extendedGamepad) { connected = YES; break; }
    }
    connected = connected && [AZValue(@"AzaharHideControls",self.game) isEqual:@"on"];
    if (connected != self.controls.hidden) {
        for (AZPadButton *button in self.controls.buttons.allValues) {
            [self.host setButton:(unsigned)button.tag pressed:NO];
            [button setHighlighted:NO];
        }
        [self.circlePad centerStick];
        self.controls.hidden = connected;
        self.controls.userInteractionEnabled = !connected;
    }
    [self.view setNeedsLayout];
}

- (void)controllerChanged:(NSNotification *)note {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self refreshControllerVisibility]; });
        return;
    }
    [self refreshControllerVisibility];
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [self.host setPointerX:0 y:0 pressed:NO];
    for (AZPadButton *button in self.controls.buttons.allValues) {
        [self.host setButton:(unsigned)button.tag pressed:NO];
        [button setHighlighted:NO];
    }
    [self.circlePad centerStick];
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect area = CGRectInset(self.view.safeAreaLayoutGuide.layoutFrame, 8, 4);
    CGFloat w = MAX(0, area.size.width), h = MAX(0, area.size.height);
    BOOL landscape = self.view.bounds.size.width > self.view.bounds.size.height;
    BOOL showControls = !self.controls.hidden;
    self.controls.landscape = landscape;
    self.controls.alpha = landscape ? [AZValue(@"AzaharControlOpacity",self.game) doubleValue]/100.0 : 1;
    self.status.numberOfLines = landscape ? 1 : 3;
    CGFloat statusHeight = landscape ? 18 : 42;
    CGFloat contentHeight = MAX(0, h-statusHeight-4);
    CGRect screen = CGRectMake(area.origin.x, area.origin.y, w, contentHeight);
    if (showControls && landscape) {
        // Overlay controls rather than sacrificing the game screen's width.
        self.controls.frame = CGRectMake(area.origin.x, area.origin.y, w, contentHeight);
    } else if (showControls) {
        CGFloat deckHeight = MIN(190, contentHeight*0.44);
        screen.size.height = MAX(0,contentHeight-deckHeight-4);
        self.controls.frame = CGRectMake(area.origin.x, area.origin.y+screen.size.height+4,
                                         w, deckHeight);
    }
    self.screen.frame = screen;
    self.status.frame = CGRectMake(area.origin.x, area.origin.y+contentHeight+4, w, statusHeight);
    [self updateDisplayGeometry];
    [self.controls setNeedsLayout];
}

- (void)updateDisplayGeometry {
    NSMutableDictionary *options = [AZLaunchOptions(self.game) mutableCopy];
    NSDictionary *launch = self.host.launchOptions;
    for (NSString *key in @[@"citra_layout_option", @"citra_swap_screen"]) {
        if (launch[key]) options[key] = launch[key];
    }
    BOOL landscape = self.view.bounds.size.width > self.view.bounds.size.height;
    [self.screen configureLandscape:landscape options:options];
    CGFloat scale = self.view.window ? self.view.window.screen.scale : UIScreen.mainScreen.scale;
    CGSize size = self.screen.bounds.size;
    [self.host setDisplaySize:CGSizeMake(std::lround(size.width*scale),std::lround(size.height*scale))
                    landscape:landscape options:options];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self refreshControllerVisibility];
    if (self.started) {
        [self maybeStartRestart];
        [self refreshInput];
        return;
    }
    self.started = YES;
    [self startSessionWithOptions:AZLaunchOptions(self.game)];
}

- (void)startSessionWithOptions:(NSDictionary<NSString *, NSString *> *)options {
    [self.screen displayFrame:nil];
    self.status.text = @"Starting game…";
    self.host = [AzaharEmulator new];
    self.host.delegate = self;
    self.circlePad.host = self.host;
    self.screen.host = self.host;
    if ([options[@"citra_graphics_api"] isEqual:@"Vulkan"] &&
        [options[@"AzaharPresentation"] isEqual:@"metal"])
        self.host.metalLayer = [self.screen prepareMetal];
    [self.view setNeedsLayout];
    [self.view layoutIfNeeded];
    [self updateDisplayGeometry];
    [self.screen layoutIfNeeded];
    NSError *error = nil;
    if (![self.host startGameAtURL:self.game options:options error:&error]) {
        self.host = nil;
        [self azaharEmulatorDidFail:error.localizedDescription ?: @"Unable to load Azahar."];
    } else {
        [self refreshInput];
    }
}

- (void)refreshInput {
    BOOL enabled = !self.leavingGame && !self.settingsOpen && !self.restartPending && !self.audioInterrupted && self.viewIfLoaded.window &&
        self.navigationController.topViewController == self &&
        UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    [self.host setPaused:!enabled];
    [self.host setInputEnabled:enabled];
    if (!enabled) [self.circlePad centerStick];
}
- (void)appInactive:(NSNotification *)note {
    [self.host setPaused:YES];
    [self.host setInputEnabled:NO];
    [self.circlePad centerStick];
}
- (void)appActive:(NSNotification *)note {
    [self refreshControllerVisibility];
    [self maybeStartRestart];
    [self refreshInput];
}
- (void)audioInterrupted:(NSNotification *)note {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self audioInterrupted:note]; });
        return;
    }
    self.audioInterrupted = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] == AVAudioSessionInterruptionTypeBegan;
    if (!self.audioInterrupted) [self.host refreshAudioRoute];
    [self refreshInput];
}
- (void)audioReset:(NSNotification *)note { [self.host refreshAudioRoute]; }
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)showDisplayOptions {
    if (self.leavingGame || self.restartPending || self.settingsOpen) return;
    self.settingsOpen = YES;
    self.settingsSnapshot = AZLaunchOptions(self.game);
    [self refreshInput];
    AZDisplayMenu *menu = [[AZDisplayMenu alloc] initWithStyle:UITableViewStyleInsetGrouped];
    menu.game = self.game;
    menu.title = @"Display Options";
    __weak AzaharGameViewController *weakSelf = self;
    menu.changed = ^{
        [weakSelf refreshControllerVisibility];
        [weakSelf.view setNeedsLayout];
        [weakSelf updateDisplayGeometry];
    };
    menu.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closeSettings)];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:menu];
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self presentViewController:nav animated:YES completion:nil];
    nav.presentationController.delegate = self;
}

- (void)showSettings {
    if (self.leavingGame || self.restartPending || self.settingsOpen) return;
    self.settingsSnapshot = AZLaunchOptions(self.game);
    self.settingsOpen = YES;
    [self refreshInput];
    AZSettings *settings = [[AZSettings alloc] initForGame:NO];
    settings.title = @"Settings";
    settings.restartOnClose = YES;
    settings.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Game Settings" style:UIBarButtonItemStylePlain target:self action:@selector(showCurrentProfile)];
    settings.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closeSettings)];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:settings];
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self presentViewController:nav animated:YES completion:nil];
    nav.presentationController.delegate = self;
}
- (void)showCurrentProfile {
    AZSettings *profile = [[AZSettings alloc] initForGame:YES];
    profile.game = self.game;
    profile.games = @[self.game];
    profile.restartOnClose = YES;
    profile.title = @"Current game";
    UINavigationController *nav = (UINavigationController *)self.presentedViewController;
    [nav pushViewController:profile animated:YES];
}
- (void)maybeStartRestart {
    if (!self.restartPending || self.host || self.settingsOpen ||
        !self.viewIfLoaded.window || self.navigationController.topViewController != self ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    NSDictionary *options = self.pendingOptions ?: AZLaunchOptions(self.game);
    self.pendingOptions = nil;
    self.restartPending = NO;
    [self startSessionWithOptions:options];
}

- (void)restartWithOptions:(NSDictionary<NSString *, NSString *> *)options {
    self.pendingOptions = options;
    self.restartPending = YES;
    self.status.text = @"Applying settings… waiting for previous game to stop.";
    [self refreshInput];
    AzaharEmulator *old = self.host;
    [old stop];
    if (!old) { [self maybeStartRestart]; return; }
    __weak AzaharGameViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        AzaharGameViewController *strongSelf = weakSelf;
        if (strongSelf.restartPending && strongSelf.host == old)
            strongSelf.status.text = @"Previous session has not stopped. Use Stop to return to the library; force-close if it remains stuck.";
    });
}

- (void)azaharEmulatorDidFinish:(AzaharEmulator *)emulator {
    if (self.host != emulator) return;
    emulator.delegate = nil;
    self.host = nil;
    self.circlePad.host = nil;
    self.screen.host = nil;
    if (self.leavingGame) {
        if (self.navigationController.topViewController == self)
            [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    [self maybeStartRestart];
}

- (void)settingsClosed {
    if (!self.settingsOpen) return;
    self.settingsOpen = NO;
    NSDictionary *after = AZLaunchOptions(self.game);
    BOOL changed = self.settingsSnapshot && AZLaunchOptionsRequireRestart(self.settingsSnapshot, after);
    self.settingsSnapshot = nil;
    [self refreshControllerVisibility];
    [self updateDisplayGeometry];
    [self refreshInput];
    if (changed && self.host) {
        // Core options are immutable for a running session. Do not tear down and
        // immediately recreate Dynarmic/graphics while dismissing UIKit settings.
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Settings saved"
            message:@"Your current game will keep its existing configuration. New settings apply when you open the game again. Save your progress before stopping."
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Continue playing" style:UIAlertActionStyleCancel handler:nil]];
        __weak AzaharGameViewController *weakSelf = self;
        [alert addAction:[UIAlertAction actionWithTitle:@"Stop and return to library" style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *action) { [weakSelf stopGame]; }]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}
- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    [self settingsClosed];
}
- (void)closeSettings {
    [self dismissViewControllerAnimated:YES completion:^{ [self settingsClosed]; }];
}

- (void)stopGame {
    if (self.leavingGame) return;
    self.restartPending = NO;
    self.pendingOptions = nil;
    self.leavingGame = YES;
    self.status.text = @"Stopping game and releasing core…";
    [self.host setInputEnabled:NO];
    [self.circlePad centerStick];
    if (!self.host) {
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    // Wait asynchronously for DidFinish, including dylib close. Keep the
    // navigation controller interactive; never join the emulation thread here.
    [self.host stop];
    __weak AzaharGameViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        AzaharGameViewController *strongSelf = weakSelf;
        if (strongSelf.leavingGame && strongSelf.host)
            strongSelf.status.text = @"Core still stopping. Back can return to library; launching stays blocked until teardown finishes.";
    });
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.host setPaused:YES];
    [self.host setInputEnabled:NO];
    [self.circlePad centerStick];
    if (self.isMovingFromParentViewController || self.navigationController.isBeingDismissed) {
        self.restartPending = NO;
        self.pendingOptions = nil;
        self.host.delegate = nil;
        [self.host stop];
    }
}

- (void)press:(UIButton *)button {
    if (self.controls.hidden) return;
    [self.host setButton:(unsigned)button.tag pressed:YES];
}

- (void)release:(UIButton *)button {
    [self.host setButton:(unsigned)button.tag pressed:NO];
}

- (void)azaharEmulatorDidRenderImage:(UIImage *)image {
    if (self.leavingGame || self.restartPending) return;
    self.previousOptions = nil;
    [self.screen displayFrame:image];
    // FPS callback updates the status once per second.
}

- (void)azaharEmulatorDidPresentMetalFrameWidth:(unsigned)width height:(unsigned)height {
    if (self.leavingGame || self.restartPending) return;
    [self.screen displayMetalWidth:width height:height];
}

- (void)azaharEmulatorDidChangeJITStatus:(NSString *)status {
    if (self.leavingGame || self.restartPending) return;
    self.status.text = status;
    self.navigationItem.prompt = [AzaharEmulator sessionJITStatus];
}

- (void)azaharEmulatorDidMeasureFPS:(double)fps jitActive:(BOOL)jitActive {
    if (self.leavingGame || self.restartPending) return;
    BOOL requested = self.host.experimentalJITEnabled;
    NSString *mode = jitActive ? @"JIT running" : (self.host.jitActive ? @"JIT prepared" :
                     (requested ? @"JIT unavailable (interpreter)" : @"Interpreter"));
    self.status.text = [NSString stringWithFormat:@"%.1f FPS | %@ | %@ graphics",
                        fps, mode, self.host.launchOptions[@"citra_graphics_api"] ?: @"Software"];
}

- (void)azaharEmulatorDidFail:(NSString *)message {
    if (self.leavingGame || self.restartPending) return;
    self.status.text = @"Game could not start";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Azahar"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    if (self.previousOptions) {
        NSDictionary *previous = self.previousOptions;
        [alert addAction:[UIAlertAction actionWithTitle:@"Retry previous session settings" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            self.previousOptions = nil;
            [self restartWithOptions:previous];
        }]];
        alert.message = [message stringByAppendingString:@"\nRetry uses the previous configuration for this session only; saved preferences stay unchanged."];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault
        handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

@interface AzaharLibraryViewController : UITableViewController <UIDocumentPickerDelegate>
@property (nonatomic, copy) NSArray<NSURL *> *games;
@property (nonatomic, copy) void (^libraryChanged)(NSArray<NSURL *> *);
@property (nonatomic, copy) void (^gameSelected)(NSURL *);
- (void)importGame;
- (void)refreshGames;
@end

@implementation AzaharLibraryViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = AZNavy();
    self.tableView.separatorColor = [AZBlue() colorWithAlphaComponent:0.18];
    [self refreshGames];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshGames];
}

- (void)refreshGames {
    NSArray<NSURL *> *files = [NSFileManager.defaultManager
        contentsOfDirectoryAtURL:GamesDirectory() includingPropertiesForKeys:nil
        options:NSDirectoryEnumerationSkipsHiddenFiles error:NULL] ?: @[];
    NSPredicate *allowed = [NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary *_) {
        return [GameExtensions() containsObject:url.pathExtension.lowercaseString];
    }];
    self.games = [[files filteredArrayUsingPredicate:allowed]
        sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
            return [a.lastPathComponent localizedCaseInsensitiveCompare:b.lastPathComponent];
        }];
    if (self.libraryChanged) self.libraryChanged(self.games);
    self.tableView.backgroundView = self.games.count ? nil : MakeLabel(@"Add a game to your library.", 17);
    [self.tableView reloadData];
}

- (void)importGame {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;
    [self.navigationController presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    for (NSURL *url in urls) {
        if (![GameExtensions() containsObject:url.pathExtension.lowercaseString]) continue;
        BOOL scoped = [url startAccessingSecurityScopedResource];
        NSString *filename = url.lastPathComponent;
        NSURL *destination = [GamesDirectory() URLByAppendingPathComponent:filename];
        unsigned suffix = 2;
        while ([NSFileManager.defaultManager fileExistsAtPath:destination.path]) {
            NSString *candidate = [NSString stringWithFormat:@"%@ (%u).%@",
                filename.stringByDeletingPathExtension, suffix++, filename.pathExtension];
            destination = [GamesDirectory() URLByAppendingPathComponent:candidate];
        }
        NSError *error = nil;
        [NSFileManager.defaultManager copyItemAtURL:url toURL:destination error:&error];
        if (scoped) [url stopAccessingSecurityScopedResource];
        if (error) NSLog(@"Import failed: %@", error);
    }
    [self refreshGames];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.games.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
        cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Game"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
        reuseIdentifier:@"Game"];
    NSURL *url = self.games[indexPath.row];
    cell.textLabel.text = url.lastPathComponent.stringByDeletingPathExtension;
    cell.detailTextLabel.text = url.pathExtension.uppercaseString;
    cell.backgroundColor = AZPanel();
    cell.imageView.image = CoverThumbnail(url) ?: [UIImage systemImageNamed:@"gamecontroller.fill"];
    cell.imageView.tintColor = AZBlue();
    cell.textLabel.textColor = UIColor.whiteColor;
    cell.detailTextLabel.textColor = UIColor.lightGrayColor;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ([AzaharEmulator hasActiveSession]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Previous game still stopping"
            message:@"Wait for the previous core to finish releasing its resources before launching again. If it never finishes, export the diagnostics and reopen the app."
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    if (self.gameSelected) self.gameSelected(self.games[indexPath.row]);
    [self.navigationController pushViewController:
        [[AzaharGameViewController alloc] initWithGame:self.games[indexPath.row]]
        animated:YES];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style
    forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (style == UITableViewCellEditingStyleDelete) {
        NSURL *url = self.games[indexPath.row];
        if ([NSFileManager.defaultManager removeItemAtURL:url error:NULL]) {
            AZForgetGame(url);
        }
        [self refreshGames];
    }
}
@end

@interface AZHome : UIViewController <UIScrollViewDelegate, UITabBarDelegate>
@property (nonatomic, strong) UIScrollView *pager;
@property (nonatomic, strong) UITabBar *tabs;
@property (nonatomic, strong) UILabel *footer;
@property (nonatomic, strong) NSArray<UIViewController *> *pages;
@property (nonatomic, strong) AzaharLibraryViewController *library;
@property (nonatomic, strong) AZSettings *profile;
@property (nonatomic, strong) AZSettings *settings;
@property (nonatomic, strong) UIBarButtonItem *addGameItem;
@property (nonatomic, strong) UIBarButtonItem *jitStatusItem;
@property (nonatomic, strong) NSTimer *jitStatusTimer;
@property (nonatomic) NSInteger page;
@property (nonatomic) CGFloat pageWidth;
@end

@implementation AZHome
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = AZNavy();
    self.navigationItem.backButtonTitle = @"Library";
    UIButton *add = [UIButton buttonWithType:UIButtonTypeSystem];
    [add setTitle:@"+ Add Game" forState:UIControlStateNormal];
    [add setTitleColor:AZNavy() forState:UIControlStateNormal];
    add.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    add.contentEdgeInsets = UIEdgeInsetsMake(8,14,8,14);
    add.backgroundColor = AZYellow(); add.layer.cornerRadius = 16;
    [add addTarget:self action:@selector(importGame) forControlEvents:UIControlEventTouchUpInside];
    self.addGameItem = [[UIBarButtonItem alloc] initWithCustomView:add];
    UILabel *jitLabel = [UILabel new];
    jitLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    jitLabel.adjustsFontForContentSizeCategory = YES;
    jitLabel.textColor = AZBlue();
    self.jitStatusItem = [[UIBarButtonItem alloc] initWithCustomView:jitLabel];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(jitStatusChanged:)
        name:@"AzaharSessionStatusChanged" object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(jitStatusChanged:)
        name:UIApplicationDidBecomeActiveNotification object:nil];

    self.library = [[AzaharLibraryViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    self.profile = [[AZSettings alloc] initForGame:YES];
    self.settings = [[AZSettings alloc] initForGame:NO];
    self.pages = @[self.library, self.settings, self.profile];
    __weak AZHome *weakSelf = self;
    void (^select)(NSURL *) = ^(NSURL *game) {
        weakSelf.profile.game = game;
        [NSUserDefaults.standardUserDefaults setObject:game.lastPathComponent forKey:@"AZSelectedGame"];
        [weakSelf.profile.tableView reloadData];
    };
    self.profile.selectGame = select;
    self.library.gameSelected = select;
    self.library.libraryChanged = ^(NSArray<NSURL *> *games) {
        weakSelf.profile.games = games;
        NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:@"AZSelectedGame"];
        NSURL *selected = games.firstObject;
        for (NSURL *url in games) if ([url.lastPathComponent isEqual:saved]) { selected=url; break; }
        weakSelf.profile.game = selected;
        if (weakSelf.profile.isViewLoaded) [weakSelf.profile.tableView reloadData];
    };

    self.pager = [UIScrollView new];
    self.pager.delegate = self;
    self.pager.pagingEnabled = YES;
    self.pager.directionalLockEnabled = YES;
    self.pager.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.pager.showsHorizontalScrollIndicator = NO;
    self.pager.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.pager];
    for (UIViewController *page in self.pages) {
        [self addChildViewController:page];
        [self.pager addSubview:page.view];
        [page didMoveToParentViewController:self];
    }

    self.footer = MakeLabel([NSString stringWithFormat:@"——AzaharFE——\n%@", AZVersion()], 13);
    self.footer.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightMedium];
    self.footer.textColor = AZBlue();
    self.tabs = [UITabBar new];
    self.tabs.delegate = self;
    self.tabs.translatesAutoresizingMaskIntoConstraints = NO;
    UITabBarAppearance *barStyle = [UITabBarAppearance new];
    [barStyle configureWithOpaqueBackground]; barStyle.backgroundColor = AZPanel();
    self.tabs.standardAppearance = barStyle;
    if (@available(iOS 15.0, *)) self.tabs.scrollEdgeAppearance = barStyle;
    self.tabs.tintColor = AZBlue();
    self.tabs.unselectedItemTintColor = [UIColor colorWithRed:0.62 green:0.70 blue:0.81 alpha:1];
    NSArray *names = @[@"Library", @"Settings", @"Game Prep"];
    NSArray *symbols = @[@"square.grid.2x2", @"gearshape", @"slider.horizontal.3"];
    NSMutableArray *items = [NSMutableArray array];
    for (NSInteger i=0; i<(NSInteger)names.count; ++i) {
        [items addObject:[[UITabBarItem alloc] initWithTitle:names[i] image:[UIImage systemImageNamed:symbols[i]] tag:i]];
    }
    self.tabs.items = items;
    [self.view addSubview:self.footer]; [self.view addSubview:self.tabs];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.pager.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.pager.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.pager.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.pager.bottomAnchor constraintEqualToAnchor:self.tabs.topAnchor],
        [self.tabs.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [self.tabs.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tabs.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.footer.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.footer.bottomAnchor constraintEqualToAnchor:self.tabs.topAnchor constant:-8]
    ]];
    self.footer.backgroundColor = AZNavy();
    [self selectPage:0];
}
- (void)importGame { [self.library importGame]; }

- (void)jitStatusChanged:(NSNotification *)notification {
    [self refreshLibraryStatus];
}
- (void)refreshLibraryStatus {
    if (self.pages[self.page] != self.library) return;
    UILabel *label = (UILabel *)self.jitStatusItem.customView;
    label.text = [AzaharEmulator sessionJITStatus];
    [label sizeToFit];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self refreshLibraryStatus];
    __weak AZHome *weakSelf = self;
    [self.jitStatusTimer invalidate];
    self.jitStatusTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
        if (!weakSelf) { [timer invalidate]; return; }
        if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) [weakSelf refreshLibraryStatus];
    }];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.jitStatusTimer invalidate];
    self.jitStatusTimer = nil;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize size=self.pager.bounds.size;
    for (NSUInteger i=0; i<self.pages.count; ++i) {
        CGFloat footerHeight = self.pages[i] == self.settings ? self.footer.intrinsicContentSize.height+16 : 0;
        self.pages[i].view.frame=CGRectMake(size.width*i,0,size.width,MAX(0,size.height-footerHeight));
    }
    self.pager.contentSize=CGSizeMake(size.width*self.pages.count,size.height);
    if (self.pageWidth != size.width) {
        self.pageWidth=size.width;
        self.pager.contentOffset=CGPointMake(self.page*size.width,0);
    }
}
- (void)selectPage:(NSInteger)index {
    self.page=index;
    self.tabs.selectedItem=self.tabs.items[index];
    self.title=self.tabs.selectedItem.title;
    if ([self.pages[index] isKindOfClass:AZSettings.class])
        [((AZSettings *)self.pages[index]).tableView reloadData];
    BOOL isLibrary = self.pages[index] == self.library;
    self.navigationItem.leftBarButtonItem = isLibrary ? self.addGameItem : nil;
    self.navigationItem.rightBarButtonItem = isLibrary ? self.jitStatusItem : self.addGameItem;
    if (isLibrary) {
        [self.library.tableView reloadData];
        [self refreshLibraryStatus];
    }
    self.footer.hidden = self.pages[index] != self.settings;
    for (NSUInteger i=0;i<self.pages.count;++i) self.pages[i].view.accessibilityElementsHidden=(NSInteger)i!=index;
}
- (void)tabBar:(UITabBar *)bar didSelectItem:(UITabBarItem *)item {
    [self selectPage:item.tag];
    [self.pager setContentOffset:CGPointMake(item.tag*self.pager.bounds.size.width,0) animated:!UIAccessibilityIsReduceMotionEnabled()];
}
- (void)syncPage {
    if (self.pager.bounds.size.width>0) {
        NSInteger index=lround(self.pager.contentOffset.x/self.pager.bounds.size.width);
        [self selectPage:MAX(0,MIN((NSInteger)self.pages.count-1,index))];
    }
}
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView { [self syncPage]; }
- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView { [self syncPage]; }
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (!decelerate) [self syncPage];
}
@end

extern "C" UIViewController *AzaharCreateLibraryController(void) { return [AZHome new]; }
