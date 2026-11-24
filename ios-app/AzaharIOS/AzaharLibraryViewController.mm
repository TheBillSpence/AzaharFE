#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "AzaharEmulator.h"
#import "AZPreferences.h"
#import "AZSettings.h"
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
            button.backgroundColor = AZPanel();
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
    self.host.experimentalJITEnabled = [AZValue(@"AzaharExperimentalJIT", self.game) isEqual:@"on"];
    NSError *error = nil;
    if (![self.host startGameAtURL:self.game error:&error]) {
        [self azaharEmulatorDidFail:error.localizedDescription ?: @"Unable to load Azahar."];
    }
}

- (void)showSettings {
    AZSettings *settings = [[AZSettings alloc] initForGame:NO];
    settings.title = @"Settings";
    settings.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Game Settings" style:UIBarButtonItemStylePlain target:self action:@selector(showCurrentProfile)];
    settings.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(closeSettings)];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:settings];
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self presentViewController:nav animated:YES completion:nil];
}
- (void)showCurrentProfile {
    AZSettings *profile = [[AZSettings alloc] initForGame:YES];
    profile.game = self.game;
    profile.sessionOptions = self.host.launchOptions;
    profile.title = @"Current game";
    UINavigationController *nav = (UINavigationController *)self.presentedViewController;
    [nav pushViewController:profile animated:YES];
}
- (void)closeSettings { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)stopGame {
    [self.host stop];
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
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
    NSString *mode = jitActive ? @"JIT27 universal prepared" :
                     (requested ? @"JIT unavailable (interpreter)" : @"Interpreter");
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
    cell.imageView.image = [UIImage systemImageNamed:@"gamecontroller.fill"];
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
        if ([NSFileManager.defaultManager removeItemAtURL:url error:NULL]) AZForgetGame(url);
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
    UIViewController *reserved = [UIViewController new];
    reserved.view.backgroundColor = AZNavy();
    self.pages = @[self.library, reserved, self.profile, [[AZSettings alloc] initForGame:NO]];
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
    NSArray *names = @[@"Library", @"More", @"Game Settings", @"Settings"];
    NSArray *symbols = @[@"square.grid.2x2", @"ellipsis.circle", @"slider.horizontal.3", @"gearshape"];
    NSMutableArray *items = [NSMutableArray array];
    for (NSInteger i=0; i<4; ++i) {
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
        CGFloat footerHeight = i==3 ? self.footer.intrinsicContentSize.height+16 : 0;
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
    self.footer.hidden=index!=3;
    for (NSUInteger i=0;i<self.pages.count;++i) self.pages[i].view.accessibilityElementsHidden=(NSInteger)i!=index;
}
- (void)tabBar:(UITabBar *)bar didSelectItem:(UITabBarItem *)item {
    [self selectPage:item.tag];
    [self.pager setContentOffset:CGPointMake(item.tag*self.pager.bounds.size.width,0) animated:!UIAccessibilityIsReduceMotionEnabled()];
}
- (void)syncPage {
    if (self.pager.bounds.size.width>0) {
        NSInteger index=lround(self.pager.contentOffset.x/self.pager.bounds.size.width);
        [self selectPage:MAX(0,MIN(3,index))];
    }
}
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView { [self syncPage]; }
- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView { [self syncPage]; }
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (!decelerate) [self syncPage];
}
@end

extern "C" UIViewController *AzaharCreateLibraryController(void) { return [AZHome new]; }
