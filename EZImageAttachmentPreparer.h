#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Prepares image bytes for a single chat request. The result dictionaries
/// contain `data`, `mimeType`, and `didTransform`.
@interface EZImageAttachmentPreparer : NSObject

/// Keeps compatible originals when the collection fits the budget. If it
/// does not, images are fairly budgeted, converted to JPEG as needed, and
/// downscaled only after JPEG quality alone cannot meet that budget.
+ (nullable NSArray<NSDictionary<NSString *, id> *> *)preparedImagesFromData:(NSArray<NSData *> *)data
                                                                    extensions:(NSArray<NSString *> *)extensions
                                                         maximumTotalByteCount:(NSUInteger)maximumTotalByteCount
                                                                         error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
