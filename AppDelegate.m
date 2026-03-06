#import "AppDelegate.h"
#import "ViewController.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    ViewController *mainViewController = [[ViewController alloc] init];
    self.window.rootViewController = mainViewController;
    [self.window makeKeyAndVisible];
    return YES;
}

@end
