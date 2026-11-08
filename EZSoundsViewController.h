//
//  EZSoundsViewController.h
//  EZSounds
//
//  Generate background noises and any other sound from a text prompt
//  (ElevenLabs sound generation via the ez-elevenlabs edge function,
//  action "generate_sound"), with an adjustable length of 1–30 seconds.
//  Generated sounds are archived in the Sounds library (EZSounds/) and
//  played through the shared EZMediaPlayerManager. From the library a
//  sound can be added to a video or used as the background bed of a
//  Text-to-Speech clip.
//
//  The screen's flow mirrors TextToSpeechViewController: describe →
//  generate → auto-play → archived in the library.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface EZSoundsViewController : UIViewController

@end

NS_ASSUME_NONNULL_END
