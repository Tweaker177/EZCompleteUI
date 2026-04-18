// AppDelegate.m
// EZCompleteUI

#import "AppDelegate.h"
#import "ViewController.h"
#import "helpers.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[ViewController alloc] init];
    [self.window makeKeyAndVisible];

    EZLog(EZLogLevelInfo, @"APP", @"Application launched");
    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    // Delay slightly so ViewController is fully on screen before we ask it to resume Sora
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"EZAppDidBecomeActive" object:nil];
    });
    EZLog(EZLogLevelInfo, @"APP", @"Application became active");
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    // Ask for a little extra background time to finish any pending file writes
    __block UIBackgroundTaskIdentifier bgTask = UIBackgroundTaskInvalid;
    bgTask = [application beginBackgroundTaskWithExpirationHandler:^{
        [application endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
    }];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // NSUserDefaults already synced by Sora job creation,
        // just give file queue a moment to flush thread saves
        [NSThread sleepForTimeInterval:1.0];
        [application endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
    });
    EZLog(EZLogLevelInfo, @"APP", @"Application entered background");
}

- (void)applicationWillTerminate:(UIApplication *)application {
    EZLog(EZLogLevelInfo, @"APP", @"Application will terminate");
}

@end
