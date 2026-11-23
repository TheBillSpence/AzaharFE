#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "AzaharEmulator.h"
#include "libretro.h"

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

@interface AzaharGameViewController : UIViewController <AzaharEmulatorDelegate>
- (instancetype)initWithGame:(NSURL *)game;
@end

@interface AzaharGameViewController ()
@property (nonatomic, strong) NSURL *game;
@property (nonatomic, strong) AzaharEmulator *host;
@property (nonatomic, strong) UIImageView *screen;
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
    self.view.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;

    self.screen = [UIImageView new];
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
    controls.axis = UILayoutConstraintAxisVertical;
    controls.spacing = 8;
    controls.distribution = UIStackViewDistributionFillEqually;
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
            button.backgroundColor = [UIColor colorWithWhite:0.22 alpha:1];
            button.layer.cornerRadius = 8;
            [button addTarget:self action:@selector(press:)
                forControlEvents:UIControlEventTouchDown];
            [button addTarget:self action:@selector(release:)
                forControlEvents:UIControlEventTouchUpInside |
                    UIControlEventTouchUpOutside | UIControlEventTouchCancel];
            [stack addArrangedSubview:button];
        }
        [controls addArrangedSubview:stack];
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
    if (self.started) return;
    self.started = YES;
    self.host = [AzaharEmulator new];
    self.host.delegate = self;
    self.host.experimentalJITEnabled = [[NSUserDefaults standardUserDefaults]
        boolForKey:@"AzaharExperimentalJIT"];
    NSError *error = nil;
    if (![self.host startGameAtURL:self.game error:&error]) {
        [self azaharEmulatorDidFail:error.localizedDescription ?: @"Unable to load Azahar."];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.host stop];
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
}

- (void)azaharEmulatorDidMeasureFPS:(double)fps jitActive:(BOOL)jitActive {
    BOOL requested = self.host.experimentalJITEnabled;
    NSString *mode = jitActive ? @"JIT27 universal prepared" :
                     (requested ? @"JIT unavailable (interpreter)" : @"Interpreter");
    self.status.text = [NSString stringWithFormat:@"%.1f FPS | %@ | Software graphics",
                        fps, mode];
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
@end

@implementation AzaharLibraryViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Azahar JIT Test";
    self.tableView.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1];
    self.navigationController.navigationBar.barStyle = UIBarStyleBlack;
    self.navigationController.navigationBar.tintColor = UIColor.systemTealColor;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
        target:self action:@selector(importGame)];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"JIT OFF" style:UIBarButtonItemStylePlain
        target:self action:@selector(toggleJIT)];
    [self refreshJITButton];

    // A wrapping footer prevents the instructions from clipping on
    // narrower iPhones, and the last row stays clear of the build badge.
    UIView *footer = [[UIView alloc] initWithFrame:
        CGRectMake(0, 0, self.view.bounds.size.width, 176)];
    UILabel *help = MakeLabel(
        @"Experimental frontend\nImport a decrypted, legally obtained 3DS game.\n"
        @"JIT ON requires StikDebug universal.js (otherwise it may crash).\n"
        @"Audio and touchscreen are not implemented.", 13);
    help.textAlignment = NSTextAlignmentLeft;
    [footer addSubview:help];
    [NSLayoutConstraint activateConstraints:@[
        [help.topAnchor constraintEqualToAnchor:footer.topAnchor constant:14],
        [help.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:16],
        [help.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-16],
        [help.bottomAnchor constraintLessThanOrEqualToAnchor:footer.bottomAnchor constant:-8]
    ]];
    self.tableView.tableFooterView = footer;
    self.tableView.contentInset = UIEdgeInsetsMake(0, 0, 28, 0);
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
    [self.tableView reloadData];
}

- (void)refreshJITButton {
    BOOL on = [[NSUserDefaults standardUserDefaults] boolForKey:@"AzaharExperimentalJIT"];
    self.navigationItem.leftBarButtonItem.title = on ? @"JIT ON" : @"JIT OFF";
}

- (void)toggleJIT {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey:@"AzaharExperimentalJIT"]) {
        [defaults setBool:NO forKey:@"AzaharExperimentalJIT"];
        [self refreshJITButton];
        return;
    }
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Experimental JIT test"
        message:@"Enable JIT through StikDebug or LiveContainer, then launch the game. "
                @"For iOS 27, select universal.js in StikDebug FIRST. Azahar prepares writable "
                @"and executable memory mappings. JIT is experimental and OFF by default."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Enable JIT Test"
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [defaults setBool:YES forKey:@"AzaharExperimentalJIT"];
            [self refreshJITButton];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)importGame {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;
    [self presentViewController:picker animated:YES completion:nil];
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
    cell.textLabel.text = url.lastPathComponent;
    cell.detailTextLabel.text = @"Tap to attempt launch";
    cell.backgroundColor = UIColor.clearColor;
    cell.textLabel.textColor = UIColor.whiteColor;
    cell.detailTextLabel.textColor = UIColor.lightGrayColor;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
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
        [NSFileManager.defaultManager removeItemAtURL:self.games[indexPath.row] error:NULL];
        [self refreshGames];
    }
}
@end

extern "C" UIViewController *AzaharCreateLibraryController(void) {
    return [[AzaharLibraryViewController alloc] initWithStyle:UITableViewStylePlain];
}
