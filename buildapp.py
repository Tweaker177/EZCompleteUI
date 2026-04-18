
from pathlib import Path
import re

p = Path("helpers.m")
src = p.read_text(encoding="utf-8")

# Find and replace the entire _EZOpenAICall function
old_func = re.search(
    r'(// FIX 1:.*?^static NSString \*_EZOpenAICall.*?^\})',
    src, re.DOTALL | re.MULTILINE
)

if not old_func:
    # Try without the comment
    old_func = re.search(
        r'^static NSString \*_EZOpenAICall.*?^\}',
        src, re.DOTALL | re.MULTILINE
    )

if not old_func:
    print("ERROR: Could not find _EZOpenAICall — printing lines 90-180 for debug:")
    lines = src.splitlines()
    for i, l in enumerate(lines[89:179], 90):
        print(f"{i}: {l}")
else:
    print(f"Found function at chars {old_func.start()}-{old_func.end()}")
    new_func = '''\
// FIX 1: Replaced removed sendSynchronousRequest API with semaphore wrapper.
// Fully null-safe: guards every JSON field against NSNull before subscripting.
static NSString *_EZOpenAICall(NSString *systemPrompt, NSString *userMessage,
                                NSString *apiKey, NSInteger maxTokens) {
    NSURL *url = [NSURL URLWithString:kOpenAIEndpoint];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKey]
       forHTTPHeaderField:@"Authorization"];

    NSDictionary *body = @{
        @"model"      : kEZHelperModel,
        @"max_tokens" : @(maxTokens),
        @"temperature": @0.2,
        @"messages"   : @[
            @{ @"role": @"system", @"content": systemPrompt },
            @{ @"role": @"user",   @"content": userMessage  }
        ]
    };

    NSError *jsonErr;
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonErr];
    if (jsonErr) { NSLog(@"[EZHelper] JSON encode error: %@", jsonErr); return nil; }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSData  *responseData = nil;
    __block NSError *netErr       = nil;

    NSURLSessionDataTask *task =
        [[NSURLSession sharedSession] dataTaskWithRequest:req
                                       completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            responseData = d;
            netErr = e;
            dispatch_semaphore_signal(sem);
        }];
    [task resume];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    if (netErr || !responseData) { NSLog(@"[EZHelper] Network error: %@", netErr); return nil; }

    NSError *parseErr;
    id jsonObj = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:&parseErr];
    if (parseErr || !jsonObj || [jsonObj isKindOfClass:[NSNull class]]) {
        NSLog(@"[EZHelper] JSON parse error: %@", parseErr); return nil;
    }
    NSDictionary *json = jsonObj;

    id choicesObj = json[@"choices"];
    if (!choicesObj || [choicesObj isKindOfClass:[NSNull class]]) {
        NSLog(@"[EZHelper] Missing choices in response"); return nil;
    }
    NSArray *choices = choicesObj;
    if (choices.count == 0) {
        NSLog(@"[EZHelper] Empty choices array"); return nil;
    }

    id firstChoice = choices[0];
    if (!firstChoice || [firstChoice isKindOfClass:[NSNull class]]) {
        NSLog(@"[EZHelper] Null first choice"); return nil;
    }

    id msgObj = ((NSDictionary *)firstChoice)[@"message"];
    if (!msgObj || [msgObj isKindOfClass:[NSNull class]]) {
        NSLog(@"[EZHelper] Null message object"); return nil;
    }

    id contentObj = ((NSDictionary *)msgObj)[@"content"];
    if (!contentObj || [contentObj isKindOfClass:[NSNull class]]) {
        NSLog(@"[EZHelper] Null content — model may have refused"); return nil;
    }

    return [((NSString *)contentObj) stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}'''

    src = src[:old_func.start()] + new_func + src[old_func.end():]
    p.write_text(src, encoding="utf-8")
    print("Done. _EZOpenAICall fully replaced with null-safe version.")

