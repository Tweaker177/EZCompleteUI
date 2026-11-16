#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Executes the chat model's local file tools (read_local_file and
/// list_local_files) against five of the app's Documents folders —
/// the allowed roots: EZAttachments, EZPhotoGallery, EZSounds,
/// EZMusic and EZThreads. Read-only: nothing here writes, moves or
/// deletes.
///
/// The model asks for a file either by a path relative to one of the
/// roots ("EZAttachments/notes/plan.md" — subfolders are expected,
/// users organize their own files) or by a bare file name, which is
/// searched across all five roots (exact, then case-insensitive, then
/// unique substring; ambiguous names come back as a candidate list
/// with full paths). list_local_files with a path browses one root or
/// subfolder; without a path it lists everything, recursively.
///
/// The ONLY path restriction: after the requested path is
/// standardized and its ".." and symlinks are resolved, it must still
/// sit inside one of the five roots. Anything inside them is fair
/// game, however deep.
///
/// Text-vs-binary is decided by content, never by extension. Every
/// outcome — success, not found, ambiguous name, outside the allowed
/// folders, binary file, too large, unreadable — comes back as a tool
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
