// AppDelegate.m
// EZCompleteUI
 
#import "AppDelegate.h"
#import "ViewController.h"
#import "EZKeyVault.h"
#import "LoginViewController.h"
#import "EZAuthManager.h"

 
@implementation AppDelegate
 
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    [EZKeyVault seedSupportEmailIfNeeded];

    // Show login screen while we check session
    LoginViewController *loginVC = [[LoginViewController alloc] init];
    self.window.rootViewController = loginVC;
    [self.window makeKeyAndVisible];

    // Try to restore existing session
    [[EZAuthManager shared] restoreSessionWithCompletion:^(BOOL loggedIn) {
        if (loggedIn) {
            ViewController *vc = [[ViewController alloc] init];
            [UIView transitionWithView:self.window
                              duration:0.3
                               options:UIViewAnimationOptionTransitionCrossDissolve
                            animations:^{ self.window.rootViewController = vc; }
                            completion:nil];
        }
        // If not logged in, LoginViewController is already showing
    }];

    return YES;
}

 
- (void)applicationDidBecomeActive:(UIApplication *)application {
    // Short delay so ViewController.viewDidLoad is guaranteed to have run
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"EZAppDidBecomeActive" object:nil];
    });
}
 
- (void)applicationDidEnterBackground:(UIApplication *)application {
    __block UIBackgroundTaskIdentifier bgTask = UIBackgroundTaskInvalid;
    bgTask = [application beginBackgroundTaskWithExpirationHandler:^{
        [application endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [application endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
    });
}
 
@end
