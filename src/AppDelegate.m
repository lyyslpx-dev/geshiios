// AppDelegate.m —— iOS 14 兼容：不使用 scene 配置，直接用 window + UINavigationController
#import "AppDelegate.h"
#import "RootViewController.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    RootViewController *root = [RootViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    if (@available(iOS 15.0, *)) {
        UINavigationBarAppearance *ap = [UINavigationBarAppearance new];
        [ap configureWithOpaqueBackground];
        nav.navigationBar.standardAppearance = ap;
        nav.navigationBar.scrollEdgeAppearance = ap;
    }
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}

- (BOOL)application:(UIApplication *)app
            openURL:(NSURL *)url
            options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
    // 从「文件」App 用"用其他应用打开"导入
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"FMOpenFile" object:url];
    return YES;
}

@end
