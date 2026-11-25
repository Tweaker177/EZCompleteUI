// EZSupabaseConfig.m
// EZCompleteUI

#import "EZSupabaseConfig.h"

NSString *const EZSupabaseURL     = @"https://spuoimtqofhbdzosrbng.supabase.co";
NSString *const EZSupabaseAnonKey = @"sb_publishable_AzEVhLuIj1nSMwZvIgKw7A__Y3Ghdtl";

#pragma mark - Store sales

static NSString *const kEZStoreSaleCacheKey = @"EZActiveStoreSaleCache";

static NSDate *EZStoreSaleDate(NSString *string) {
    if (![string isKindOfClass:[NSString class]] || string.length == 0) return nil;
    static NSISO8601DateFormatter *withFractional;
    static NSISO8601DateFormatter *plain;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        withFractional = [NSISO8601DateFormatter new];
        withFractional.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        plain = [NSISO8601DateFormatter new];
        plain.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    });
    return [withFractional dateFromString:string] ?: [plain dateFromString:string];
}

static BOOL EZStoreSaleIsLive(NSDictionary *sale, NSDate *now) {
    if (![sale isKindOfClass:[NSDictionary class]]) return NO;
    NSDate *starts = EZStoreSaleDate(sale[@"starts_at"]);
    NSDate *ends = EZStoreSaleDate(sale[@"ends_at"]);
    if (!starts || !ends) return NO;
    return [starts compare:now] != NSOrderedDescending && [ends compare:now] == NSOrderedDescending;
}

NSDictionary *EZCachedActiveStoreSale(void) {
    NSDictionary *cached = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kEZStoreSaleCacheKey];
    return EZStoreSaleIsLive(cached, [NSDate date]) ? cached : nil;
}

void EZFetchActiveStoreSale(void (^completion)(NSDictionary *sale)) {
    NSString *urlString = [NSString stringWithFormat:
        @"%@/rest/v1/store_sales?select=id,title,body,multiplier,starts_at,ends_at&active=eq.true&order=starts_at.desc&limit=5",
        EZSupabaseURL];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    request.timeoutInterval = 10;
    [request setValue:EZSupabaseAnonKey forHTTPHeaderField:@"apikey"];
    [request setValue:[@"Bearer " stringByAppendingString:EZSupabaseAnonKey] forHTTPHeaderField:@"Authorization"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *liveSale = nil;
        if (data && !error) {
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([parsed isKindOfClass:[NSArray class]]) {
                NSDate *now = [NSDate date];
                for (id row in (NSArray *)parsed) {
                    if (EZStoreSaleIsLive(row, now)) { liveSale = row; break; }
                }
            }
        }
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        if (liveSale) [defaults setObject:liveSale forKey:kEZStoreSaleCacheKey];
        else [defaults removeObjectForKey:kEZStoreSaleCacheKey];
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(liveSale); });
    }] resume];
}
