#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Executes the chat model's local file tools (read_local_file and
/// list_local_files) against the app's two file stores: Documents/
/// EZAttachments (documents and other files) and the EZPhotoGallery
/// directory (images — uploads, generations and edits save there, not
/// in EZAttachments).
///
/// The model never gets a path: it asks for a file by name, and every
/// lookup happens inside those two directories. Names containing "/"
/// or ".." are refused outright, so there is no way to reach anything
/// outside them. Every outcome — success, not found, ambiguous
/// name, binary file, too large, unreadable — comes back as a tool
/// result the model can react to; this class never throws and never
/// fails the chat turn.
///
/// Result dictionaries handed to the completion:
///   text:  @{ @"kind": @"text",  @"text": <framed result for the model> }
///   image: @{ @"kind": @"image", @"fileName": ..., @"data": NSData,
///             @"extension": ..., @"byteSize": NSNumber }
/// The image case is returned raw so the caller can run the bytes
/// through EZImageAttachmentPreparer and build a vision message with
/// the existing attachment pipeline.
@interface EZLocalFileTools : NSObject

/// Runs the request (a validated local_file_request dictionary from
/// ez-chat) on a background queue and calls completion on the main
/// queue with a result dictionary as described above.
+ (void)executeRequest:(NSDictionary *)request
            completion:(void (^)(NSDictionary *result))completion;

@end

NS_ASSUME_NONNULL_END
