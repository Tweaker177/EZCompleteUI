#import "EZFileConvertTools.h"
#import "EZLocalFileTools.h"
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@implementation EZFileConvertTools

#pragma mark - entry point

+ (void)executeRequest:(NSDictionary *)request
            completion:(void (^)(NSDictionary *result))completion {
    if (!completion) return;
    NSDictionary *safeRequest = [request isKindOfClass:[NSDictionary class]] ? request : @{};
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *result = [self runConvert:safeRequest];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
    });
}

#pragma mark - framing helpers

+ (NSDictionary *)textResult:(NSString *)header body:(NSString *)body {
    return @{ @"kind": @"text",
              @"text": [NSString stringWithFormat:
                  @"[File conversion result — convert_file: %@]\n%@\n[End of file conversion result]",
                  header, body] };
}

+ (NSString *)sizeString:(unsigned long long)bytes {
    return [NSByteCountFormatter stringFromByteCount:(long long)bytes
                                          countStyle:NSByteCountFormatterCountStyleFile];
}

/// The output lives next to the source, under the source's name with
/// the new extension; a collision appends a number ("song 2.m4a"),
/// matching how the app names saved files everywhere else.
+ (NSString *)uniqueOutputPathForSourcePath:(NSString *)sourcePath targetExtension:(NSString *)targetExtension {
    NSString *directory = [sourcePath stringByDeletingLastPathComponent];
    NSString *base = [[sourcePath lastPathComponent] stringByDeletingPathExtension];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *candidate = [directory stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%@.%@", base, targetExtension]];
    NSUInteger suffix = 2;
    while ([fm fileExistsAtPath:candidate]) {
        candidate = [directory stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@ %lu.%@", base, (unsigned long)suffix++, targetExtension]];
    }
    return candidate;
}

+ (NSString *)displayPathForOutputPath:(NSString *)outputPath sourceDisplay:(NSString *)sourceDisplay {
    NSString *folder = [sourceDisplay stringByDeletingLastPathComponent];
    NSString *name = [outputPath lastPathComponent];
    return folder.length ? [folder stringByAppendingPathComponent:name] : name;
}

#pragma mark - conversion

+ (NSDictionary *)runConvert:(NSDictionary *)request {
    NSString *name = [request[@"name"] isKindOfClass:[NSString class]]
        ? [request[@"name"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] : @"";
    NSString *target = [request[@"target_format"] isKindOfClass:[NSString class]]
        ? [[request[@"target_format"] lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] : @"";
    if ([target isEqualToString:@"jpeg"]) target = @"jpg";
    NSString *header = [NSString stringWithFormat:@"%@ → %@",
        name.length ? name : @"(no file)", target.length ? [target uppercaseString] : @"(no format)"];
    if (!name.length) {
        return [self textResult:@"error" body:@"No file name was given, so nothing was converted. Use list_local_files to see what is available."];
    }
    if (!target.length) {
        return [self textResult:@"error" body:@"No target format was given, so nothing was converted. Supported targets are PNG, JPG, M4A and MP3 (with the MP3 limit described in the tool instructions)."];
    }

    NSDictionary *located = [EZLocalFileTools locateFileForName:name];
    if (located[@"problem"]) {
        return [self textResult:@"error" body:located[@"problem"]];
    }
    NSString *sourcePath = located[@"path"];
    NSString *sourceDisplay = located[@"display"];
    unsigned long long sourceBytes = [located[@"byteSize"] unsignedLongLongValue];
    NSString *sourceExtension = [[sourcePath pathExtension] lowercaseString];
    if ([sourceExtension isEqualToString:@"jpeg"]) sourceExtension = @"jpg";

    if ([sourceExtension isEqualToString:target]) {
        return [self textResult:header body:[NSString stringWithFormat:
            @"\"%@\" is already in %@ format, so no conversion was needed and no copy was made.",
            sourceDisplay, [target uppercaseString]]];
    }

    NSSet<NSString *> *imageSources = [NSSet setWithArray:@[@"png", @"jpg", @"heic", @"heif", @"gif"]];
    NSSet<NSString *> *imageTargets = [NSSet setWithArray:@[@"png", @"jpg"]];
    NSSet<NSString *> *audioSources = [NSSet setWithArray:@[@"mp4", @"mov", @"m4a", @"wav", @"mp3", @"aac", @"caf", @"aif", @"aiff"]];

    if ([imageTargets containsObject:target] && [imageSources containsObject:sourceExtension]) {
        return [self convertImageAtPath:sourcePath
                            sourceDisplay:sourceDisplay
                            sourceBytes:sourceBytes
                          sourceExtension:sourceExtension
                                   target:target
                                   header:header];
    }

    if ([target isEqualToString:@"mp3"]) {
        // iOS has no MP3 encoder and the app bundles none, so this is
        // reported honestly instead of silently producing a different
        // format than the one that was asked for.
        return [self textResult:header body:[NSString stringWithFormat:
            @"\"%@\" could not be converted to MP3: the app cannot encode MP3 on this device (iOS has no built-in MP3 encoder), and no file was created. It can be converted to M4A instead, which plays in the same places MP3 does — ask for M4A if that works.",
            sourceDisplay]];
    }

    if ([target isEqualToString:@"m4a"] && [audioSources containsObject:sourceExtension]) {
        return [self exportAudioToM4AAtPath:sourcePath
                              sourceDisplay:sourceDisplay
                                sourceBytes:sourceBytes
                            sourceExtension:sourceExtension
                                     header:header];
    }

    return [self textResult:header body:[NSString stringWithFormat:
        @"Converting %@ to %@ is not supported. Supported conversions: PNG, JPG, HEIC or GIF images to PNG or JPG; MP4, MOV, M4A, WAV, MP3, AAC or CAF audio (or a video's audio track) to M4A. MP3 output is not available on-device.",
        [sourceExtension uppercaseString], [target uppercaseString]]];
}

+ (NSDictionary *)successResultForSourceDisplay:(NSString *)sourceDisplay
                                sourceExtension:(NSString *)sourceExtension
                                    sourceBytes:(unsigned long long)sourceBytes
                                  outputDisplay:(NSString *)outputDisplay
                                         target:(NSString *)target
                                     outputPath:(NSString *)outputPath
                                       imageData:(NSData *)imageData {
    unsigned long long outputBytes = [[[NSFileManager defaultManager]
        attributesOfItemAtPath:outputPath error:nil][NSFileSize] unsignedLongLongValue];
    NSMutableString *body = [NSMutableString stringWithFormat:
        @"Converted \"%@\" (%@, %@) to \"%@\" (%@, %@). The new file was saved next to the original in the same folder and shown to the user in this chat; the original file was not changed.",
        sourceDisplay, [sourceExtension uppercaseString], [self sizeString:sourceBytes],
        outputDisplay, [target uppercaseString], [self sizeString:outputBytes]];
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"kind"] = @"converted";
    result[@"isImage"] = imageData ? @YES : @NO;
    result[@"displayLine"] = [NSString stringWithFormat:
        @"Converted \"%@\" to \"%@\" — saved in %@",
        [sourceDisplay lastPathComponent], [outputDisplay lastPathComponent],
        [outputDisplay stringByDeletingLastPathComponent].length
            ? [outputDisplay stringByDeletingLastPathComponent] : @"the same folder"];
    if (imageData) {
        [body appendString:@" The converted image is attached as image context."];
        result[@"data"] = imageData;
        result[@"fileName"] = [outputDisplay lastPathComponent];
        result[@"extension"] = target;
        result[@"byteSize"] = @(outputBytes);
    }
    result[@"text"] = [NSString stringWithFormat:
        @"[File conversion result — convert_file]\n%@\n[End of file conversion result]", body];
    return [result copy];
}

+ (NSDictionary *)convertImageAtPath:(NSString *)sourcePath
                       sourceDisplay:(NSString *)sourceDisplay
                         sourceBytes:(unsigned long long)sourceBytes
                     sourceExtension:(NSString *)sourceExtension
                              target:(NSString *)target
                              header:(NSString *)header {
    NSData *input = [NSData dataWithContentsOfFile:sourcePath];
    CGImageSourceRef source = input.length ? CGImageSourceCreateWithData((__bridge CFDataRef)input, NULL) : NULL;
    if (!source || CGImageSourceGetCount(source) == 0) {
        if (source) CFRelease(source);
        return [self textResult:header body:[NSString stringWithFormat:
            @"\"%@\" could not be read as an image, so it was not converted.", sourceDisplay]];
    }
    NSString *outputPath = [self uniqueOutputPathForSourcePath:sourcePath targetExtension:target];
    NSString *typeIdentifier = [target isEqualToString:@"png"] ? UTTypePNG.identifier : UTTypeJPEG.identifier;
    NSMutableData *output = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData(
        (__bridge CFMutableDataRef)output, (__bridge CFStringRef)typeIdentifier, 1, NULL);
    NSDictionary *options = [target isEqualToString:@"jpg"]
        ? @{ (id)kCGImageDestinationLossyCompressionQuality: @0.9 } : @{};
    BOOL written = NO;
    if (destination) {
        CGImageDestinationAddImageFromSource(destination, source, 0, (__bridge CFDictionaryRef)options);
        written = CGImageDestinationFinalize(destination);
        CFRelease(destination);
    }
    CFRelease(source);
    NSError *writeError = nil;
    if (written) written = [output writeToFile:outputPath options:NSDataWritingAtomic error:&writeError];
    if (!written) {
        return [self textResult:header body:[NSString stringWithFormat:
            @"\"%@\" could not be converted to %@: %@ No file was created.",
            sourceDisplay, [target uppercaseString],
            writeError.localizedDescription ?: @"the image encoder failed."]];
    }
    return [self successResultForSourceDisplay:sourceDisplay
                               sourceExtension:sourceExtension
                                   sourceBytes:sourceBytes
                                 outputDisplay:[self displayPathForOutputPath:outputPath sourceDisplay:sourceDisplay]
                                        target:target
                                    outputPath:outputPath
                                     imageData:output];
}

+ (NSDictionary *)exportAudioToM4AAtPath:(NSString *)sourcePath
                           sourceDisplay:(NSString *)sourceDisplay
                             sourceBytes:(unsigned long long)sourceBytes
                         sourceExtension:(NSString *)sourceExtension
                                  header:(NSString *)header {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:sourcePath] options:nil];
    if (![asset tracksWithMediaType:AVMediaTypeAudio].count) {
        return [self textResult:header body:[NSString stringWithFormat:
            @"\"%@\" has no audio track, so there is nothing to convert to M4A.", sourceDisplay]];
    }
    NSString *outputPath = [self uniqueOutputPathForSourcePath:sourcePath targetExtension:@"m4a"];
    AVAssetExportSession *session = [[AVAssetExportSession alloc] initWithAsset:asset
                                                                     presetName:AVAssetExportPresetAppleM4A];
    if (!session) {
        return [self textResult:header body:[NSString stringWithFormat:
            @"\"%@\" could not be converted on this device. No file was created.", sourceDisplay]];
    }
    session.outputURL = [NSURL fileURLWithPath:outputPath];
    session.outputFileType = AVFileTypeAppleM4A;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [session exportAsynchronouslyWithCompletionHandler:^{ dispatch_semaphore_signal(done); }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (session.status != AVAssetExportSessionStatusCompleted) {
        [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
        return [self textResult:header body:[NSString stringWithFormat:
            @"\"%@\" could not be converted to M4A: %@ No file was created.",
            sourceDisplay, session.error.localizedDescription ?: @"the export failed."]];
    }
    return [self successResultForSourceDisplay:sourceDisplay
                               sourceExtension:sourceExtension
                                   sourceBytes:sourceBytes
                                 outputDisplay:[self displayPathForOutputPath:outputPath sourceDisplay:sourceDisplay]
                                        target:@"m4a"
                                    outputPath:outputPath
                                     imageData:nil];
}

@end
