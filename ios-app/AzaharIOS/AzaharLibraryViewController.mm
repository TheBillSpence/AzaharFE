#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <ImageIO/ImageIO.h>
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

static NSURL *CoverURL(NSURL *game) {
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
                                                           inDomains:NSUserDomainMask].firstObject;
    NSURL *folder = [documents URLByAppendingPathComponent:@"Covers" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES
                                          attributes:nil error:NULL];
    return [folder URLByAppendingPathComponent:[game.lastPathComponent stringByAppendingString:@".jpg"]];
}

static UIImage *CoverThumbnail(NSURL *game) {
    UIImage *cover = [UIImage imageWithContentsOfFile:CoverURL(game).path];
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
@end

@implementation AZTouchScreen
- (void)updateTouch:(UITouch *)touch {
    CGPoint p = [touch locationInView:self];
    CGRect bounds = self.bounds;
    CGSize image = self.image.size;
    const auto pointer = AZInput::Project(p.x - CGRectGetMinX(bounds), p.y - CGRectGetMinY(bounds),
        bounds.size.width, bounds.size.height, image.width, image.height);
    [self.host setPointerX:pointer.x y:pointer.y pressed:pointer.down];
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
    [AZPanel() setFill];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(c.x-diameter/2, c.y-diameter/2,
                                                       diameter, diameter)] fill];
    const CGFloat thumb = diameter * 0.46;
    const CGFloat travel = (diameter - thumb) / 2;
    [AZBlue() setFill];
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(c.x + self.deflection.x * travel - thumb/2,
        c.y + self.deflection.y * travel - thumb/2, thumb, thumb)] fill];
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

@interface AzaharGameViewController : UIViewController <AzaharEmulatorDelegate, UIAdaptivePresentationControllerDelegate>
- (instancetype)initWithGame:(NSURL *)game;
@end

@interface AzaharGameViewController ()
@property (nonatomic, strong) NSURL *game;
@property (nonatomic, strong) AzaharEmulator *host;
@property (nonatomic, strong) AZTouchScreen *screen;
@property (nonatomic, strong) AZCirclePad *circlePad;
@property (nonatomic) BOOL settingsOpen;
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
    self.view.backgroundColor = AZNavy();
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
    NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
    [notifications addObserver:self selector:@selector(appInactive:) name:UIApplicationWillResignActiveNotification object:nil];
    [notifications addObserver:self selector:@selector(appActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    self.screen = [AZTouchScreen new];
    self.screen.userInteractionEnabled = YES;
    self.screen.contentMode = UIViewContentModeScaleAspectFit;
    self.screen.backgroundColor = UIColor.blackColor;
    self.screen.layer.cornerRadius = 10;
    self.screen.clipsToBounds = YES;
    self.screen.translatesAutoresizingMaskIntoConstraints = NO;
    [self.screen setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                   forAxis:UILayoutConstraintAxisVertical];
    [self.view addSubview:self.screen];

    self.status = MakeLabel(@"Starting Azahar...\nExperimental JIT test", 12);
    self.status.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightMedium];
    self.status.textAlignment = NSTextAlignmentLeft;
    self.status.numberOfLines = 3;
    self.status.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.status setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                  forAxis:UILayoutConstraintAxisVertical];
    [self.view addSubview:self.status];

    UIStackView *controls = [[UIStackView alloc] init];
    controls.axis = UILayoutConstraintAxisHorizontal;
    controls.spacing = 8;
    self.circlePad = [AZCirclePad new];
    self.circlePad.backgroundColor = UIColor.clearColor;
    self.circlePad.opaque = NO;
    self.circlePad.accessibilityLabel = @"Circle Pad";
    [controls addArrangedSubview:self.circlePad];
    [self.circlePad.widthAnchor constraintEqualToConstant:64].active = YES;
    UIStackView *rows = [UIStackView new];
    rows.axis = UILayoutConstraintAxisVertical;
    rows.distribution = UIStackViewDistributionFillEqually;
    rows.spacing = 8;
    [controls addArrangedSubview:rows];
    controls.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:controls];

    NSArray<NSArray<NSString *> *> *labels = @[
        @[@"↑", @"↓", @"←", @"→", @"A", @"B"],
        @[@"X", @"Y", @"L", @"R", @"Start", @"Select"]
    ];
    NSArray<NSArray<NSNumber *> *> *ids = @[
        @[@(RETRO_DEVICE_ID_JOYPAD_UP), @(RETRO_DEVICE_ID_JOYPAD_DOWN),
          @(RETRO_DEVICE_ID_JOYPAD_LEFT), @(RETRO_DEVICE_ID_JOYPAD_RIGHT),
          @(RETRO_DEVICE_ID_JOYPAD_A), @(RETRO_DEVICE_ID_JOYPAD_B)],
        @[@(RETRO_DEVICE_ID_JOYPAD_X), @(RETRO_DEVICE_ID_JOYPAD_Y),
          @(RETRO_DEVICE_ID_JOYPAD_L), @(RETRO_DEVICE_ID_JOYPAD_R),
          @(RETRO_DEVICE_ID_JOYPAD_START), @(RETRO_DEVICE_ID_JOYPAD_SELECT)]
    ];

    for (NSUInteger row = 0; row < labels.count; row++) {
        UIStackView *stack = [[UIStackView alloc] init];
        stack.axis = UILayoutConstraintAxisHorizontal;
        stack.spacing = 5;
        stack.distribution = UIStackViewDistributionFillEqually;
        for (NSUInteger col = 0; col < labels[row].count; col++) {
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
            button.tag = ids[row][col].integerValue;
            [button setTitle:labels[row][col] forState:UIControlStateNormal];
            button.titleLabel.font = [UIFont boldSystemFontOfSize:13];
            button.titleLabel.adjustsFontSizeToFitWidth = YES;
            button.titleLabel.minimumScaleFactor = 0.72;
            button.accessibilityLabel = labels[row][col];
            button.tintColor = UIColor.whiteColor;
            button.backgroundColor = AZPanel();
            button.layer.cornerRadius = 8;
            [button addTarget:self action:@selector(press:)
                forControlEvents:UIControlEventTouchDown];
            [button addTarget:self action:@selector(release:)
                forControlEvents:UIControlEventTouchUpInside |
                    UIControlEventTouchUpOutside | UIControlEventTouchCancel];
            [stack addArrangedSubview:button];
        }
        [rows addArrangedSubview:stack];
    }

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;

    // Prefer a generous screen but shrink it when the status or controls
    // need more vertical room (e.g. accessibility text sizes, smaller phones).
    NSLayoutConstraint *preferredScreenHeight =
        [self.screen.heightAnchor constraintEqualToAnchor:safe.heightAnchor multiplier:0.58];
    preferredScreenHeight.priority = UILayoutPriorityDefaultHigh;
    NSLayoutConstraint *minimumScreenHeight =
        [self.screen.heightAnchor constraintGreaterThanOrEqualToConstant:120];
    minimumScreenHeight.priority = UILayoutPriorityDefaultLow;

    [NSLayoutConstraint activateConstraints:@[
        [self.screen.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [self.screen.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
        [self.screen.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8],
        [self.screen.heightAnchor constraintLessThanOrEqualToAnchor:safe.heightAnchor multiplier:0.58],
        preferredScreenHeight,
        minimumScreenHeight,

        [self.status.topAnchor constraintEqualToAnchor:self.screen.bottomAnchor constant:10],
        [self.status.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:14],
        [self.status.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-14],
        [self.status.bottomAnchor constraintLessThanOrEqualToAnchor:controls.topAnchor constant:-10],

        [controls.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
        [controls.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8],
        // Reserve the bottom-left safe area for the persistent build badge.
        [controls.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-30],
        [controls.heightAnchor constraintEqualToConstant:96]
    ]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.started) { [self refreshInput]; return; }
    self.started = YES;
    self.host = [AzaharEmulator new];
    self.host.delegate = self;
    self.circlePad.host = self.host;
    self.screen.host = self.host;
    NSError *error = nil;
    if (![self.host startGameAtURL:self.game error:&error]) {
        [self azaharEmulatorDidFail:error.localizedDescription ?: @"Unable to load Azahar."];
    } else {
        [self refreshInput];
    }
}

- (void)refreshInput {
    BOOL enabled = !self.settingsOpen && self.viewIfLoaded.window &&
        self.navigationController.topViewController == self &&
        UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    [self.host setInputEnabled:enabled];
    if (!enabled) [self.circlePad centerStick];
}
- (void)appInactive:(NSNotification *)note {
    [self.host setInputEnabled:NO];
    [self.circlePad centerStick];
}
- (void)appActive:(NSNotification *)note { [self refreshInput]; }

- (void)showSettings {
    self.settingsOpen = YES;
    [self refreshInput];
    AZSettings *settings = [[AZSettings alloc] initForGame:NO];
    settings.title = @"Settings";
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
    profile.sessionOptions = self.host.launchOptions;
    profile.title = @"Current game";
    UINavigationController *nav = (UINavigationController *)self.presentedViewController;
    [nav pushViewController:profile animated:YES];
}
- (void)settingsClosed {
    self.settingsOpen = NO;
    [self refreshInput];
}
- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    [self settingsClosed];
}
- (void)closeSettings {
    [self dismissViewControllerAnimated:YES completion:^{ [self settingsClosed]; }];
}

- (void)stopGame {
    [self.host stop];
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.host setInputEnabled:NO];
    [self.circlePad centerStick];
    if (self.isMovingFromParentViewController || self.navigationController.isBeingDismissed) [self.host stop];
}

- (void)press:(UIButton *)button {
    [self.host setButton:(unsigned)button.tag pressed:YES];
}

- (void)release:(UIButton *)button {
    [self.host setButton:(unsigned)button.tag pressed:NO];
}

- (void)azaharEmulatorDidRenderImage:(UIImage *)image {
    self.screen.image = image;
    // FPS callback updates the status once per second.
}

- (void)azaharEmulatorDidChangeJITStatus:(NSString *)status {
    self.status.text = status;
    self.navigationItem.prompt = [AzaharEmulator sessionJITStatus];
}

- (void)azaharEmulatorDidMeasureFPS:(double)fps jitActive:(BOOL)jitActive {
    BOOL requested = self.host.experimentalJITEnabled;
    NSString *mode = jitActive ? @"JIT running" : (self.host.jitActive ? @"JIT prepared" :
                     (requested ? @"JIT unavailable (interpreter)" : @"Interpreter"));
    self.status.text = [NSString stringWithFormat:@"%.1f FPS | %@ | %@ graphics",
                        fps, mode, self.host.launchOptions[@"citra_graphics_api"] ?: @"Software"];
}

- (void)azaharEmulatorDidFail:(NSString *)message {
    self.status.text = @"Game could not start";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Azahar"
        message:message preferredStyle:UIAlertControllerStyleAlert];
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
            [NSFileManager.defaultManager removeItemAtURL:CoverURL(url) error:NULL];
            AZForgetGame(url);
        }
        [self refreshGames];
    }
}
@end

@interface AZCovers : UITableViewController <UIDocumentPickerDelegate>
@property (nonatomic, copy) NSArray<NSURL *> *games;
@property (nonatomic, strong) NSURL *pendingGame;
@property (nonatomic, copy) void (^coversChanged)(void);
- (void)refreshCovers;
@end

@implementation AZCovers
- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = AZNavy();
    self.tableView.separatorColor = [AZBlue() colorWithAlphaComponent:0.18];
    self.tableView.rowHeight = 84;
    [self refreshCovers];
}

- (void)refreshCovers {
    if (!self.isViewLoaded) return;
    self.tableView.backgroundView = self.games.count ? nil :
        MakeLabel(@"Import a game in Library first, then add its cover here.", 16);
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.games.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cover"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Cover"];
    NSURL *game = self.games[indexPath.row];
    UIImage *cover = CoverThumbnail(game);
    cell.textLabel.text = game.lastPathComponent.stringByDeletingPathExtension;
    cell.detailTextLabel.text = cover ? @"Tap to replace or remove cover" : @"Tap to import cover";
    cell.textLabel.textColor = UIColor.whiteColor;
    cell.detailTextLabel.textColor = AZBlue();
    cell.backgroundColor = AZPanel();
    cell.imageView.image = cover ?: [UIImage systemImageNamed:@"photo"];
    cell.imageView.tintColor = AZBlue();
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)chooseImageForGame:(NSURL *)game {
    self.pendingGame = game;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeImage] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self.navigationController presentViewController:picker animated:YES completion:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSURL *game = self.games[indexPath.row];
    if (![NSFileManager.defaultManager fileExistsAtPath:CoverURL(game).path]) {
        [self chooseImageForGame:game];
        return;
    }
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:game.lastPathComponent.stringByDeletingPathExtension
        message:@"Manage this game's cover." preferredStyle:UIAlertControllerStyleAlert];
    [menu addAction:[UIAlertAction actionWithTitle:@"Replace Cover" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) { [self chooseImageForGame:game]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Remove Cover" style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *action) {
            [NSFileManager.defaultManager removeItemAtURL:CoverURL(game) error:NULL];
            [self refreshCovers];
            if (self.coversChanged) self.coversChanged();
        }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:menu animated:YES completion:nil];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    self.pendingGame = nil;
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *game = self.pendingGame;
    self.pendingGame = nil;
    NSURL *imageURL = urls.firstObject;
    if (!game || !imageURL || ![NSFileManager.defaultManager fileExistsAtPath:game.path]) return;
    BOOL scoped = [imageURL startAccessingSecurityScopedResource];
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)imageURL, NULL);
    CGImageRef thumbnail = NULL;
    if (source) {
        NSDictionary *options = @{
            (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
            (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
            (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @768
        };
        thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
        CFRelease(source);
    }
    NSData *data = nil;
    if (thumbnail) {
        data = UIImageJPEGRepresentation([UIImage imageWithCGImage:thumbnail], 0.88);
        CGImageRelease(thumbnail);
    }
    if (scoped) [imageURL stopAccessingSecurityScopedResource];
    NSError *error = nil;
    if (!data || ![data writeToURL:CoverURL(game) options:NSDataWritingAtomic error:&error]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Cover import failed"
            message:error.localizedDescription ?: @"Choose a valid PNG, JPEG or supported image."
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    [self refreshCovers];
    if (self.coversChanged) self.coversChanged();
}
@end

@interface AZHome : UIViewController <UIScrollViewDelegate, UITabBarDelegate>
@property (nonatomic, strong) UIScrollView *pager;
@property (nonatomic, strong) UITabBar *tabs;
@property (nonatomic, strong) UILabel *footer;
@property (nonatomic, strong) NSArray<UIViewController *> *pages;
@property (nonatomic, strong) AzaharLibraryViewController *library;
@property (nonatomic, strong) AZSettings *profile;
@property (nonatomic, strong) AZCovers *covers;
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
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:add];

    self.library = [[AzaharLibraryViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    self.profile = [[AZSettings alloc] initForGame:YES];
    self.covers = [[AZCovers alloc] initWithStyle:UITableViewStyleInsetGrouped];
    self.pages = @[self.library, self.profile, self.covers, [[AZSettings alloc] initForGame:NO]];
    __weak AZHome *weakSelf = self;
    void (^select)(NSURL *) = ^(NSURL *game) {
        weakSelf.profile.game = game;
        [NSUserDefaults.standardUserDefaults setObject:game.lastPathComponent forKey:@"AZSelectedGame"];
        [weakSelf.profile.tableView reloadData];
    };
    self.profile.selectGame = select;
    self.library.gameSelected = select;
    self.covers.coversChanged = ^{ [weakSelf.library.tableView reloadData]; };
    self.library.libraryChanged = ^(NSArray<NSURL *> *games) {
        weakSelf.profile.games = games;
        weakSelf.covers.games = games;
        [weakSelf.covers refreshCovers];
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
    NSArray *names = @[@"Library", @"Game Prep", @"Covers", @"Settings"];
    NSArray *symbols = @[@"square.grid.2x2", @"slider.horizontal.3", @"photo.on.rectangle", @"gearshape"];
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
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGSize size=self.pager.bounds.size;
    for (NSUInteger i=0; i<self.pages.count; ++i) {
        CGFloat footerHeight = i==self.pages.count-1 ? self.footer.intrinsicContentSize.height+16 : 0;
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
    if (self.pages[index] == self.covers) [self.covers refreshCovers];
    self.footer.hidden=index!=(NSInteger)self.pages.count-1;
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
