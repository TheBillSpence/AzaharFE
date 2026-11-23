#import <UIKit/UIKit.h>

UIViewController *AzaharCreateLibraryController(void);

@interface AzaharAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation AzaharAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UINavigationController *navigation = [[UINavigationController alloc]
        initWithRootViewController:AzaharCreateLibraryController()];
    navigation.navigationBar.prefersLargeTitles = YES;
    self.window.rootViewController = navigation;
    [self.window makeKeyAndVisible];

    // Always visible in the bottom-left, including while a game is running.
    // Read the packaged Info.plist so GitHub Actions can bump the build
    // counter automatically without requiring UI source edits.
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"0.1.0";
    NSString *build = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"?";
    UILabel *versionBadge = [UILabel new];
    versionBadge.text = [NSString stringWithFormat:@"  v%@  ·  build %@  ", version, build];
    versionBadge.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightMedium];
    versionBadge.textColor = [UIColor colorWithWhite:0.82 alpha:1];
    versionBadge.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.82];
    versionBadge.layer.cornerRadius = 5;
    versionBadge.layer.masksToBounds = YES;
    versionBadge.userInteractionEnabled = NO;
    versionBadge.translatesAutoresizingMaskIntoConstraints = NO;
    [self.window addSubview:versionBadge];
    UILayoutGuide *safe = self.window.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [versionBadge.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:10],
        [versionBadge.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-3],
        [versionBadge.heightAnchor constraintEqualToConstant:18]
    ]];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(AzaharAppDelegate.class));
    }
}
