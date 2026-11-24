#import "AZSettings.h"
#import "AZPreferences.h"
#import "AzaharEmulator.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <ImageIO/ImageIO.h>

@interface AZSettings () <UIDocumentPickerDelegate>
@property (nonatomic) BOOL perGame;
@property (nonatomic, strong) UILabel *runtimeLabel;
@property (nonatomic, strong) NSTimer *statusTimer;
@property (nonatomic) BOOL showAdvanced;
@end

@implementation AZSettings
- (instancetype)initForGame:(BOOL)perGame {
    if ((self=[super initWithStyle:UITableViewStyleInsetGrouped])) _perGame=perGame;
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor=AZNavy();
    self.tableView.tintColor=AZBlue();
    self.tableView.separatorColor=[AZBlue() colorWithAlphaComponent:0.18];
    self.tableView.rowHeight=UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight=68;
    self.tableView.accessibilityIdentifier=self.perGame ? @"gameSettings" : @"universalSettings";
    if (!self.perGame) {
        self.runtimeLabel=[UILabel new];
        self.runtimeLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleTitle1];
        self.runtimeLabel.adjustsFontForContentSizeCategory=YES;
        self.runtimeLabel.textAlignment=NSTextAlignmentRight;
        self.runtimeLabel.textColor=AZBlue();
        self.runtimeLabel.numberOfLines=0;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionStatusChanged:)
            name:@"AzaharSessionStatusChanged" object:nil];
        [self refreshStatus];
    }
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.runtimeLabel && !self.statusTimer) {
        __weak AZSettings *weakSelf = self;
        self.statusTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
            if (!weakSelf) { [timer invalidate]; return; }
            if (weakSelf.viewIfLoaded.window && UIApplication.sharedApplication.applicationState == UIApplicationStateActive)
                [weakSelf refreshStatus];
        }];
    }
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.statusTimer invalidate];
    self.statusTimer = nil;
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshStatus];
    if (!self.perGame && self.navigationController.viewControllers.firstObject == self && !self.tableView.tableFooterView) {
        UILabel *version=[[UILabel alloc] initWithFrame:CGRectMake(0,0,self.tableView.bounds.size.width,68)];
        version.text=[NSString stringWithFormat:@"——AzaharFE——\n%@",AZVersion()];
        version.numberOfLines=2;
        version.textAlignment=NSTextAlignmentCenter;
        version.font=[UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightMedium];
        version.textColor=AZBlue();
        self.tableView.tableFooterView=version;
    }
    [self.tableView reloadData];
}
- (void)sessionStatusChanged:(NSNotification *)notification { [self refreshStatus]; }
- (void)refreshStatus { self.runtimeLabel.text=[AzaharEmulator sessionJITStatus]; }
- (NSArray<NSString *> *)keysForSection:(NSInteger)section {
    if (section == 1)
        return @[@"AzaharJITPreset", @"citra_graphics_api", @"citra_resolution_factor",
                 @"citra_layout_option", @"citra_swap_screen"];
    return @[@"AzaharExperimentalJIT", @"AzaharJITSpeed", @"AzaharDeepProfile", @"AzaharSoftwareThreads"];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section==0) return 1;
    if (self.perGame && !self.game) return 0;
    if (section == 2) return 1 + (self.showAdvanced ? [self keysForSection:section].count : 0);
    return [self keysForSection:section].count;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section==2) return nil;
    if (section==0) return self.perGame ? @"Selected game" : nil;
    return self.perGame ? (self.game ? @"Settings for this game" : nil) : @"Universal Settings";
}
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (section!=0 || self.perGame) return nil;
    UIView *view=[UIView new];
    UILabel *label=self.runtimeLabel;
    [view addSubview:label];
    label.translatesAutoresizingMaskIntoConstraints=NO;
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:16],
        [label.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-18],
        [label.topAnchor constraintEqualToAnchor:view.topAnchor constant:8],
        [label.bottomAnchor constraintEqualToAnchor:view.bottomAnchor constant:-12]]];
    return view;
}
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return UITableViewAutomaticDimension;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section==0 && self.perGame && !self.game) return @"Add a game to set its preferences.";
    if (section==1 && self.sessionOptions) return @"Values used to launch this session.";
    if (section==1 && (!self.perGame || self.game)) return @"Changes apply when you launch the game.";
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.backgroundColor=AZPanel();
    UIListContentConfiguration *content=[UIListContentConfiguration subtitleCellConfiguration];
    content.textProperties.color=UIColor.whiteColor;
    content.secondaryTextProperties.color=AZBlue();
    content.secondaryTextProperties.numberOfLines=0;
    cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    if (self.sessionOptions) cell.accessoryType=UITableViewCellAccessoryNone;
    if (ip.section==0 && self.perGame) {
        content.text=self.game ? self.game.lastPathComponent.stringByDeletingPathExtension : @"No game selected";
        content.textProperties.numberOfLines=3;
        content.secondaryText=self.sessionOptions ? @"Current session" : (self.game ? @"Select game or change cover" : nil);
        content.image=self.game ? AZGameArt(self.game) : nil;
        if (!content.image) content.image=[UIImage systemImageNamed:@"gamecontroller"];
        content.imageProperties.maximumSize=CGSizeMake(96,128);
        content.imageProperties.cornerRadius=8;
    } else if (ip.section==0) {
        content.text=@"Log Data";
        content.image=[UIImage systemImageNamed:@"doc.text"];
    } else if (ip.section == 2 && ip.row == 0) {
        content.text = self.showAdvanced ? @"Hide advanced settings" : @"Show advanced settings";
        cell.accessoryType = UITableViewCellAccessoryNone;
    } else {
        NSString *key=[self keysForSection:ip.section][ip.row - (ip.section == 2 ? 1 : 0)];
        content.text=AZOptionTitle(key);
        NSDictionary *resolved = self.sessionOptions ?: AZLaunchOptions(self.perGame ? self.game : nil);
        NSString *value=AZChoiceTitle(key, resolved[key]);
        BOOL local = self.perGame && (AZHasOverride(key,self.game) ||
            ([key isEqual:@"AzaharJITPreset"] && (AZHasOverride(@"AzaharExperimentalJIT",self.game) ||
                                                 AZHasOverride(@"AzaharJITSpeed",self.game))));
        NSString *origin = local ? @"Game override" : @"Universal";
        if (self.sessionOptions) {
            content.secondaryText=AZChoiceTitle(key, self.sessionOptions[key]);
        } else content.secondaryText=self.perGame ? [NSString stringWithFormat:@"%@  ·  %@",value,origin] : value;
    }
    cell.contentConfiguration=content;
    return cell;
}
- (void)presentMenu:(UIAlertController *)menu row:(NSIndexPath *)ip {
    [menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView=self.tableView;
    menu.popoverPresentationController.sourceRect=[self.tableView rectForRowAtIndexPath:ip];
    [self presentViewController:menu animated:YES completion:nil];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 2 && ip.row == 0) {
        self.showAdvanced = !self.showAdvanced;
        [tableView reloadData];
        return;
    }
    if (self.sessionOptions) return;
    if (ip.section==0 && !self.perGame) {
        UIViewController *logs=[UIViewController new]; logs.title=@"Log Data";
        UITextView *view=[UITextView new]; view.editable=NO; view.backgroundColor=AZNavy();
        view.textColor=UIColor.whiteColor; view.font=[UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
        view.textContainerInset=UIEdgeInsetsMake(16,14,20,14);
        view.text=[NSString stringWithContentsOfURL:AZLogURL() encoding:NSUTF8StringEncoding error:nil] ?: @"No session log yet.";
        logs.view=view; [self.navigationController pushViewController:logs animated:YES]; return;
    }
    if (ip.section==0) {
        if (!self.game) return;
        UIAlertController *menu=[UIAlertController alertControllerWithTitle:@"Game profile" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSURL *url in self.games) {
            [menu addAction:[UIAlertAction actionWithTitle:url.lastPathComponent.stringByDeletingPathExtension style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
                self.game=url; if (self.selectGame) self.selectGame(url); [tableView reloadData];
            }]];
        }
        [menu addAction:[UIAlertAction actionWithTitle:@"Choose cover image…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
            UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeImage] asCopy:YES];
            picker.delegate=self; [self presentViewController:picker animated:YES completion:nil];
        }]];
        [self presentMenu:menu row:ip]; return;
    }
    NSString *key=[self keysForSection:ip.section][ip.row - (ip.section == 2 ? 1 : 0)]; NSURL *url=self.perGame ? self.game : nil;
    UIAlertController *menu=[UIAlertController alertControllerWithTitle:AZOptionTitle(key)
        message:[key isEqual:@"AzaharJITPreset"] ? @"Combined uses Turbo and Direct RAM when JIT is detected. Advanced settings lets you choose the CPU and speed mode separately." :
                [key isEqual:@"AzaharExperimentalJIT"] ? @"On iOS 27, attach StikDebug with universal.js before launching with JIT." :
                ([key isEqual:@"AzaharJITSpeed"] ? @"Turbo skips historical startup probes and uses a larger code cache; Direct RAM also enables fast page-table memory access. Both are experimental and may freeze or corrupt guest state. Relaunch to apply." :
                 ([key isEqual:@"AzaharDeepProfile"] ? @"Opt in to 5-second timing reports for CPU, JIT, HLE, PICA, software rasterization, and audio, plus a one-time CPU-only JIT benchmark. Profiling itself costs CPU time. Restart to apply." :
                 ([key isEqual:@"AzaharSoftwareThreads"] ? @"Choose the number of software PICA graphics worker threads. Automatic uses the current device behavior; compare the same scene to choose. Restart to apply." :
                 ([key isEqual:@"citra_graphics_api"] ? @"Vulkan uses MoltenVK to accelerate PICA200 3D rendering on the iPhone GPU. Highly experimental: it can fail to launch or render incorrectly. Software is always available as a safe fallback. Relaunch to apply." :
                 ([key isEqual:@"citra_resolution_factor"] ? @"1× is native 3DS resolution. With software graphics, 2×–4× upscale the image rather than rendering extra 3D detail. Higher settings cost memory and performance. Relaunch the game to apply." : nil)))))
        preferredStyle:UIAlertControllerStyleActionSheet];
    if (url) [menu addAction:[UIAlertAction actionWithTitle:@"Use universal setting" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        AZSetValue(key,nil,url); [tableView reloadData];
    }]];
    for (NSString *value in AZChoices(key)) {
        [menu addAction:[UIAlertAction actionWithTitle:AZChoiceTitle(key, value) style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
            BOOL individual = [key isEqual:@"AzaharExperimentalJIT"] || [key isEqual:@"AzaharJITSpeed"];
            BOOL customize = individual || ([key isEqual:@"AzaharJITPreset"] && [value isEqual:@"custom"]);
            if (customize && ![AZValue(@"AzaharJITPreset",url) isEqual:@"custom"]) {
                NSDictionary *current = AZLaunchOptions(url);
                AZSetValue(@"AzaharExperimentalJIT", current[@"AzaharExperimentalJIT"], url);
                AZSetValue(@"AzaharJITSpeed", current[@"AzaharJITSpeed"], url);
                AZSetValue(@"AzaharJITPreset", @"custom", url);
            }
            AZSetValue(key,value,url);
            if ([key isEqual:@"AzaharJITPreset"] && [value isEqual:@"custom"]) self.showAdvanced = YES;
            [tableView reloadData];
        }]];
    }
    [self presentMenu:menu row:ip];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url=urls.firstObject; if (!url || !self.game) return;
    BOOL scoped=[url startAccessingSecurityScopedResource];
    CGImageSourceRef src=CGImageSourceCreateWithURL((__bridge CFURLRef)url,NULL);
    NSDictionary *options=@{(__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
        (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform:@YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize:@720};
    CGImageRef thumb=src ? CGImageSourceCreateThumbnailAtIndex(src,0,(__bridge CFDictionaryRef)options) : NULL;
    NSData *jpeg=thumb ? UIImageJPEGRepresentation([UIImage imageWithCGImage:thumb],0.85) : nil;
    BOOL saved=[jpeg writeToURL:AZCustomArtURL(self.game) options:NSDataWritingAtomic error:nil];
    if (thumb) CGImageRelease(thumb);
    if (src) CFRelease(src);
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (saved) [self.tableView reloadData];
    else {
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Couldn’t save cover" message:@"Choose another image." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}
@end
