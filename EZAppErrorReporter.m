#import "EZAppErrorReporter.h"
#import "EZSupabaseConfig.h"
#import "EZAuthManager.h"

@implementation EZAppErrorReporter

+ (void)reportSource:(NSString *)source code:(NSString *)code message:(NSString *)message {
    if (source.length == 0) return;
    NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"";
    NSMutableDictionary *body = [@{ @"source": source,
                                    @"error_code": code ?: @"error",
                                    @"app_version": version } mutableCopy];
    if (message.length) {
        body[@"message"] = message.length > 300 ? [message substringToIndex:300] : message;
    }
    NSData *payload = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!payload) return;
    [[EZAuthManager shared] getValidAccessToken:^(NSString *token, NSError *authError) {
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[EZSupabaseURL stringByAppendingString:@"/functions/v1/report-app-error"]]];
        request.HTTPMethod = @"POST";
        request.timeoutInterval = 10;
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [request setValue:EZSupabaseAnonKey forHTTPHeaderField:@"apikey"];
        if (token) [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
        request.HTTPBody = payload;
        [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        }] resume];
    }];
}

@end
