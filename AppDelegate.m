// AppDelegate.m
// EZCompleteUI
//
// Purpose:
//   Application entry point. Initializes the main window, kicks off session
//   restoration at launch (showing LoginViewController while the check runs),
//   and handles incoming deep links for the password reset flow.
//
// Changes:
//   - Added application:openURL:options: to handle ezcomplete:// deep links
//     for the password reset flow. Tokens are applied via EZAuthManager which
//     posts EZPasswordResetReadyNotification — LoginViewController observes
//     this and switches to its password-reset UI state.
//   - Fixed race condition: restoreSessionWithCompletion: now checks
//     isInPasswordRecoveryMode before transitioning to ViewController. Without
//     this guard, a previously-logged-in user tapping the reset link would see
//     the recovery URL handled, then have ViewController transition on top of
//     it 300-500ms later when the async session restore completed.
//   - Added fallback URL parsing for direct Supabase redirects (no edge function):
//     when the edge function is unreachable or not yet deployed, Supabase puts
//     tokens in the URL fragment (ezcomplete://#access_token=...&type=recovery)
//     rather than as query params on the password-reset host. Both formats are
//     handled so the reset flow works with or without the edge function deployed.

#import "AppDelegate.h"
#import "ViewController.h"
#import "EZKeyVault.h"
#import "LoginViewController.h"
#import "EZAuthManager.h"
#import "EZReferralManager.h"
#import "EZPhotoGalleryViewController.h"
#import "helpers.h"

static NSString *const kPendingExternalImageAskPath = @"EZPendingExternalImageAskPath";
static NSString *const kPendingExternalDocumentPath = @"EZPendingExternalDocumentPath";
static NSString *const kPendingSharedImageAskPaths = @"EZPendingSharedImageAskPaths";
static NSString *const kEZShareAppGroup = @"group.com.i0stweak3r.ezcompleteui";
static NSString *const kEZShareManifestName = @"pending-image-import.plist";


@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    [EZKeyVault seedSupportEmailIfNeeded];

    // Show login screen while we check session
    LoginViewController *loginVC = [[LoginViewController alloc] init];
    self.window.rootViewController = loginVC;
    [self.window makeKeyAndVisible];

    // Try to restore existing session. Guard against the race condition where
    // application:openURL:options: fires between didFinishLaunching returning
    // and this async completion running: if a password reset deep link was
    // received, isInPasswordRecoveryMode will already be YES and we must NOT
    // transition away from the reset UI that LoginViewController just set up.
    [[EZAuthManager shared] restoreSessionWithCompletion:^(BOOL loggedIn) {
        if (loggedIn && ![[EZAuthManager shared] isInPasswordRecoveryMode]) {
            // Redeem a referral code stashed at sign-up (e.g. sign-up
            // needed email confirmation, so no session existed then).
            // Silent and idempotent — no-op when nothing is stashed.
            [EZReferralManager applyPendingReferralCode];
            ViewController *vc = [[ViewController alloc] init];
            [UIView transitionWithView:self.window
                              duration:0.3
                               options:UIViewAnimationOptionTransitionCrossDissolve
                            animations:^{ self.window.rootViewController = vc; }
                            completion:nil];
        }
        // Not logged in, or in recovery mode — LoginViewController stays
    }];

    NSURL *launchURL = launchOptions[UIApplicationLaunchOptionsURLKey];
    // A custom auth URL can launch a terminated app. Route it through the same
    // handler used for a warm app; previously only file URLs were handled here,
    // silently discarding signup-confirmation and password-reset callbacks.
    if (launchURL) [self application:application openURL:launchURL options:@{}];
    [self importImagesStagedByShareExtension];

    return YES;
}

// The Share Extension has its own sandbox. It stages files in the shared App
// Group, and the main app promptly copies them into its own temporary area
// before passing them to the regular multi-image attachment pipeline.
- (void)importImagesStagedByShareExtension {
    NSURL *container = [[NSFileManager defaultManager]
        containerURLForSecurityApplicationGroupIdentifier:kEZShareAppGroup];
    NSURL *manifestURL = [container URLByAppendingPathComponent:kEZShareManifestName];
    NSDictionary *manifest = [NSDictionary dictionaryWithContentsOfURL:manifestURL];
    NSString *folderName = [manifest[@"folder"] isKindOfClass:[NSString class]] ? manifest[@"folder"] : nil;
    NSArray *files = [manifest[@"files"] isKindOfClass:[NSArray class]] ? manifest[@"files"] : nil;
    if (!folderName.length || !files.count) return;

    NSURL *sourceFolder = [[container URLByAppendingPathComponent:@"ShareInbox" isDirectory:YES]
        URLByAppendingPathComponent:folderName isDirectory:YES];
    NSString *destinationFolder = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"shared-photos-%@", NSUUID.UUID.UUIDString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:destinationFolder
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (id value in files) {
        if (![value isKindOfClass:[NSString class]]) continue;
        NSString *name = value;
        NSURL *source = [sourceFolder URLByAppendingPathComponent:name];
        NSData *data = [NSData dataWithContentsOfURL:source];
        if (!data.length || ![UIImage imageWithData:data]) continue;
        NSString *path = [destinationFolder stringByAppendingPathComponent:name];
        if ([data writeToFile:path atomically:YES]) [paths addObject:path];
    }
    [[NSFileManager defaultManager] removeItemAtURL:sourceFolder error:nil];
    [[NSFileManager defaultManager] removeItemAtURL:manifestURL error:nil];
    if (!paths.count) return;
    [[NSUserDefaults standardUserDefaults] setObject:paths forKey:kPendingSharedImageAskPaths];
    if ([self.window.rootViewController isKindOfClass:[ViewController class]]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:EZAttachImageToChat object:nil
                                                          userInfo:@{ @"filePaths": paths }];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kPendingSharedImageAskPaths];
    }
}

// Copies an Open In / Files-provider item while its security-scoped access is
// valid. Images keep their established image-edit route; text documents go to
// the normal chat file-analysis pipeline, ready for a question.
- (BOOL)acceptIncomingFileURL:(NSURL *)url {
    if (!url.isFileURL) return NO;
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (scoped) [url stopAccessingSecurityScopedResource];
    if (!data.length) return NO;

    NSString *fileName = url.lastPathComponent.length ? url.lastPathComponent : @"open-in-document.txt";
    NSString *destination = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"open-in-%@-%@", NSUUID.UUID.UUIDString, fileName]];
    if (![data writeToFile:destination atomically:YES]) return NO;

    if ([UIImage imageWithData:data]) {
        // Open In is conversational by default. Gallery's explicit Edit with
        // AI action is the sole route that should enter image-edit mode
        // without first reading the person's prompt.
        [[NSUserDefaults standardUserDefaults] setObject:destination forKey:kPendingExternalImageAskPath];
        if ([self.window.rootViewController isKindOfClass:[ViewController class]]) {
            [[NSNotificationCenter defaultCenter] postNotificationName:EZAttachImageToChat
                                                                object:nil
                                                              userInfo:@{ @"filePath": destination }];
        }
        return YES;
    }

    [[NSUserDefaults standardUserDefaults] setObject:destination forKey:kPendingExternalDocumentPath];
    if ([self.window.rootViewController isKindOfClass:[ViewController class]]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:EZAttachExternalDocumentToChat
                                                            object:nil
                                                          userInfo:@{ @"filePath": destination }];
    }
    return YES;
}

// ── Deep link handler ─────────────────────────────────────────────────────────
// Called by iOS when any ezcomplete:// URL is opened — from Mail, Safari, or
// LiveContainer's open-url forwarding. Handles password recovery and completed
// email-confirmation callbacks.
//
// Two URL formats are supported:
//
//   Via edge function (preferred — provides branded page + LiveContainer fallbacks):
//     ezcomplete://password-reset?access_token=...&refresh_token=...
//     Tokens arrive as query parameters on the "password-reset" host.
//
//   Direct Supabase redirect (fallback — works without edge function deployed):
//     ezcomplete://#access_token=...&refresh_token=...&type=recovery
//     Tokens arrive in the URL fragment with no host. Only the "recovery" type
//     is handled; other Supabase auth callbacks (magic links etc.) are ignored.
//
// Routing after tokens are extracted:
//   - LoginViewController already root: EZPasswordResetReadyNotification fires
//     and LoginVC shows the reset overlay immediately.
//   - ViewController is root (user was logged in): transition to a fresh
//     LoginViewController which detects isInPasswordRecoveryMode in viewDidLoad.

- (BOOL)application:(UIApplication *)application
            openURL:(NSURL *)url
            options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {

    if (url.isFileURL) return [self acceptIncomingFileURL:url];

    if (![url.scheme isEqualToString:@"ezcomplete"]) return NO;

    if ([url.host isEqualToString:@"shared-images"]) {
        [self importImagesStagedByShareExtension];
        return YES;
    }

    NSString *accessToken  = nil;
    NSString *refreshToken = nil;
    NSString *callbackType = nil;

    if ([url.host isEqualToString:@"password-reset"]) {
        // ── Edge function format ───────────────────────────────────────────────
        // ezcomplete://password-reset?access_token=...&refresh_token=...
        NSURLComponents *components = [NSURLComponents componentsWithURL:url
                                                resolvingAgainstBaseURL:NO];
        for (NSURLQueryItem *item in components.queryItems) {
            if ([item.name isEqualToString:@"access_token"])  accessToken  = item.value;
            if ([item.name isEqualToString:@"refresh_token"]) refreshToken = item.value;
            if ([item.name isEqualToString:@"type"])          callbackType = item.value;
        }

    } else if ([url.host isEqualToString:@"auth"]) {
        NSURLComponents *components = [NSURLComponents componentsWithURL:url
                                                resolvingAgainstBaseURL:NO];
        for (NSURLQueryItem *item in components.queryItems) {
            if ([item.name isEqualToString:@"access_token"])  accessToken  = item.value;
            if ([item.name isEqualToString:@"refresh_token"]) refreshToken = item.value;
            if ([item.name isEqualToString:@"type"])          callbackType = item.value;
        }

    } else if (url.fragment.length) {
        // ── Direct Supabase fallback format ───────────────────────────────────
        // ezcomplete://#access_token=...&refresh_token=...&type=recovery
        //
        // The URL fragment is not sent to any server — iOS passes the full URL
        // including fragment to this method. We reuse NSURLComponents query
        // parsing by temporarily treating the fragment as a query string.
        NSURLComponents *fragmentComponents = [[NSURLComponents alloc] init];
        fragmentComponents.query = url.fragment;

        NSMutableDictionary<NSString *, NSString *> *fragmentParams =
            [NSMutableDictionary dictionaryWithCapacity:fragmentComponents.queryItems.count];
        for (NSURLQueryItem *item in fragmentComponents.queryItems) {
            if (item.value) fragmentParams[item.name] = item.value;
        }

        accessToken  = fragmentParams[@"access_token"];
        refreshToken = fragmentParams[@"refresh_token"];
        callbackType = fragmentParams[@"type"];
    }

    if (!accessToken.length || !refreshToken.length) {
        NSLog(@"[AppDelegate] Password reset URL missing tokens — ignoring. URL: %@", url);
        return NO;
    }

    if ([callbackType isEqualToString:@"recovery"] || [url.host isEqualToString:@"password-reset"]) {
        // Store recovery tokens and post EZPasswordResetReadyNotification.
        // LoginViewController observes this notification and shows the reset overlay.
        [[EZAuthManager shared] applyPasswordResetTokens:accessToken
                                            refreshToken:refreshToken];
    } else if ([callbackType isEqualToString:@"signup"] ||
               [callbackType isEqualToString:@"email_change"]) {
        // Supabase has already verified the email before issuing these tokens.
        // Persist the session so the user is taken straight into the app.
        [[EZAuthManager shared] saveSession:@{
            @"access_token": accessToken,
            @"refresh_token": refreshToken,
        }];
        ViewController *mainVC = [[ViewController alloc] init];
        [UIView transitionWithView:self.window duration:0.3
                           options:UIViewAnimationOptionTransitionCrossDissolve
                        animations:^{ self.window.rootViewController = mainVC; }
                        completion:nil];
        return YES;
    } else {
        NSLog(@"[AppDelegate] Unsupported auth callback type '%@'.", callbackType);
        return NO;
    }

    if (![self.window.rootViewController isKindOfClass:[LoginViewController class]]) {
        // ViewController is showing (user was previously logged in). Transition
        // to a fresh LoginViewController — its viewDidLoad detects
        // isInPasswordRecoveryMode and calls showPasswordResetEntryState directly.
        LoginViewController *resetLoginVC = [[LoginViewController alloc] init];
        [UIView transitionWithView:self.window
                          duration:0.3
                           options:UIViewAnimationOptionTransitionCrossDissolve
                        animations:^{ self.window.rootViewController = resetLoginVC; }
                        completion:nil];
    }

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
