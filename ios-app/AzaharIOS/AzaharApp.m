#import <UIKit/UIKit.h>
#import "AZPreferences.h"

UIViewController *AzaharCreateLibraryController(void);

@interface AzaharAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation AzaharAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UINavigationController *navigation = [[UINavigationController alloc]
        initWithRootViewController:AzaharCreateLibraryController()];
    self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    navigation.navigationBar.prefersLargeTitles = NO;
    UINavigationBarAppearance *navStyle = [UINavigationBarAppearance new];
    [navStyle configureWithOpaqueBackground];
    navStyle.backgroundColor = AZNavy();
    navStyle.titleTextAttributes = @{NSForegroundColorAttributeName: UIColor.whiteColor};
    navigation.navigationBar.standardAppearance = navStyle;
    navigation.navigationBar.scrollEdgeAppearance = navStyle;
    navigation.navigationBar.tintColor = AZBlue();
    self.window.rootViewController = navigation;
    [self.window makeKeyAndVisible];

    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(AzaharAppDelegate.class));
    }
}
