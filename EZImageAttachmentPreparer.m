#import "EZImageAttachmentPreparer.h"
#import <UIKit/UIKit.h>

@implementation EZImageAttachmentPreparer

+ (NSString *)mimeTypeForExtension:(NSString *)extension {
    NSString *ext = extension.lowercaseString;
    if ([ext isEqualToString:@"png"]) return @"image/png";
    if ([ext isEqualToString:@"gif"]) return @"image/gif";
    if ([ext isEqualToString:@"webp"]) return @"image/webp";
    return @"image/jpeg";
}

+ (BOOL)isAPICompatibleExtension:(NSString *)extension {
    return [@[@"jpg", @"jpeg", @"png", @"gif", @"webp"] containsObject:extension.lowercaseString];
}

+ (nullable NSData *)jpegDataForImage:(UIImage *)image maximumByteCount:(NSUInteger)maximumByteCount {
    if (!image || maximumByteCount == 0) return nil;
    CGSize size = image.size;
    // Try quality first. This retains every source pixel whenever possible.
    for (NSUInteger resizePass = 0; resizePass < 8; resizePass++) {
        CGFloat low = 0.35, high = 0.92;
        NSData *best = nil;
        for (NSUInteger attempt = 0; attempt < 7; attempt++) {
            CGFloat quality = (low + high) / 2.0;
            NSData *candidate = UIImageJPEGRepresentation(image, quality);
            if (candidate.length <= maximumByteCount) { best = candidate; low = quality; }
            else high = quality;
        }
        if (best) return best;
        CGSize nextSize = CGSizeMake(MAX(320.0, floor(size.width * 0.78)),
                                     MAX(320.0, floor(size.height * 0.78)));
        if (CGSizeEqualToSize(nextSize, size)) break;
        UIGraphicsBeginImageContextWithOptions(nextSize, NO, 1.0);
        [image drawInRect:(CGRect){CGPointZero, nextSize}];
        UIImage *resized = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        if (!resized) break;
        image = resized;
        size = nextSize;
    }
    return UIImageJPEGRepresentation(image, 0.25);
}

+ (nullable NSArray<NSDictionary<NSString *,id> *> *)preparedImagesFromData:(NSArray<NSData *> *)data
                                                                    extensions:(NSArray<NSString *> *)extensions
                                                         maximumTotalByteCount:(NSUInteger)maximumTotalByteCount
                                                                         error:(NSError **)error {
    if (data.count == 0 || data.count != extensions.count || maximumTotalByteCount == 0) {
        if (error) *error = [NSError errorWithDomain:@"EZImageAttachmentPreparer" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid image attachment input."}];
        return nil;
    }
    NSUInteger total = 0;
    for (NSData *item in data) total += item.length;
    BOOL needsBudgeting = total > maximumTotalByteCount;
    NSUInteger perImageBudget = MAX((NSUInteger)(64 * 1024), maximumTotalByteCount / data.count);
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:data.count];
    for (NSUInteger i = 0; i < data.count; i++) {
        NSData *source = data[i];
        NSString *extension = extensions[i].lowercaseString;
        BOOL keepOriginal = [self isAPICompatibleExtension:extension] && (!needsBudgeting || source.length <= perImageBudget);
        if (keepOriginal) {
            [result addObject:@{ @"data": source, @"mimeType": [self mimeTypeForExtension:extension], @"didTransform": @NO }];
            continue;
        }
        NSData *jpeg = [self jpegDataForImage:[UIImage imageWithData:source] maximumByteCount:perImageBudget];
        if (!jpeg) {
            if (error) *error = [NSError errorWithDomain:@"EZImageAttachmentPreparer" code:2 userInfo:@{NSLocalizedDescriptionKey: @"One of the selected images could not be converted to JPEG."}];
            return nil;
        }
        [result addObject:@{ @"data": jpeg, @"mimeType": @"image/jpeg", @"didTransform": @YES }];
    }
    return result;
}

@end
