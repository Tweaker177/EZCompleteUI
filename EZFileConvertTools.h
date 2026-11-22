#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Executes the chat model's convert_file tool against the app's
/// on-device files. The model names a source file (the same names and
/// paths read_local_file accepts — EZLocalFileTools finds it inside
/// the five allowed roots) and a target format; this class performs
/// the conversion on-device and writes the result next to the
/// original, under the original's name with the new extension (a
/// number is appended on a name collision: "song 2.m4a"). The
/// original file is never modified or deleted.
///
/// Supported conversions:
///   Images: PNG, JPEG and HEIC sources to PNG or JPEG (ImageIO).
///   Audio:  MP4, MOV, M4A, WAV, MP3, AAC and CAF sources to M4A
///           (AVAssetExportSession, Apple M4A preset) — this covers
///           pulling the audio out of a video as M4A.
/// MP3 as a target is deliberately NOT faked: iOS has no MP3 encoder,
/// so a request for MP3 comes back as a tool result saying so and
/// naming M4A as the available alternative — never a silent swap to
/// a different format than the one that was asked for.
///
/// Every outcome — converted, already in that format, unsupported
/// pair, not found, ambiguous name, failed export — comes back as a
/// tool result the model can react to; this class never throws and
/// never fails the chat turn.
///
/// Result dictionaries handed to the completion:
///   success: @{ @"kind": @"converted", @"text": <framed result>,
///               @"displayLine": <one line for the visible chat>,
///               @"isImage": @YES/@NO, and for images also
///               @"data", @"fileName", @"extension", @"byteSize" }
///   other:   @{ @"kind": @"text", @"text": <framed result> }
/// The image payload is returned raw so the caller can run it
/// through EZImageAttachmentPreparer, exactly like read_local_file.
@interface EZFileConvertTools : NSObject

/// Runs the request (a validated convert_file_request dictionary
/// from ez-chat: name + target_format) on a background queue and
/// calls completion on the main queue with a result dictionary as
/// described above.
+ (void)executeRequest:(NSDictionary *)request
            completion:(void (^)(NSDictionary *result))completion;

@end

NS_ASSUME_NONNULL_END
