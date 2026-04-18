// ViewController_integration_patch.m
// EZCompleteUI
//
// ─────────────────────────────────────────────────────────────────────────────
// HOW TO INTEGRATE helpers.h / helpers.m INTO YOUR EXISTING ViewController.m
// ─────────────────────────────────────────────────────────────────────────────
//
// This file is NOT a drop-in replacement — it is a reference / patch guide.
// Find the matching sections in your ViewController.m and add the lines marked
// with  ◀ ADD  next to them. Existing code is marked with  // ...existing...
//
// STEP 1 ── Add the import at the top of ViewController.m
// ─────────────────────────────────────────────────────────────────────────────
// #import "ViewController.h"
#import "helpers.h"               // ◀ ADD THIS LINE
// ─────────────────────────────────────────────────────────────────────────────


// STEP 2 ── In viewDidLoad (or applicationDidBecomeActive in AppDelegate.m)
//            add log rotation so logs don't grow unbounded.
// ─────────────────────────────────────────────────────────────────────────────
//
// - (void)viewDidLoad {
//     [super viewDidLoad];
//     ...existing setup...
//
      EZLogRotateIfNeeded(512 * 1024);   // ◀ ADD: rotate logs if > 512 KB
      EZLog(EZLogLevelInfo, @"APP", @"EZCompleteUI launched"); // ◀ ADD: startup log
// }
// ─────────────────────────────────────────────────────────────────────────────


// STEP 3 ── Replace / wrap your "Send" button action.
//            Instead of sending directly, first call analyzePromptForContext().
// ─────────────────────────────────────────────────────────────────────────────
//
// ─── BEFORE (your existing send action, simplified) ───
//
// - (IBAction)sendButtonTapped:(id)sender {
//     NSString *prompt = self.inputField.text;
//     [self callOpenAIWithPrompt:prompt];
// }
//
// ─── AFTER (with helper integration) ───────────────────
//
// - (IBAction)sendButtonTapped:(id)sender {
//
//     NSString *userPrompt = self.inputField.text;
//     if (userPrompt.length == 0) return;
//
//     // ◀ ADD: load recent memories (last 15 entries)
//     NSString *memories = loadMemoryContext(15);
//
//     // ◀ ADD: let the context analyzer decide if memories should be injected
//     analyzePromptForContext(userPrompt, memories, API_KEY, ^(EZContextResult *result) {
//
//         // result.finalPrompt is either the bare prompt or prompt + memory context
//         EZLogf(EZLogLevelInfo, @"SEND",
//                @"Sending prompt. needsContext=%@ tokens≈%ld",
//                result.needsContext ? @"YES" : @"NO",
//                (long)result.estimatedTokens);
//
//         // ◀ Call your existing OpenAI method with the (possibly augmented) prompt
//         [self callOpenAIWithPrompt:result.finalPrompt];
//     });
// }
// ─────────────────────────────────────────────────────────────────────────────


// STEP 4 ── Inside your OpenAI completion handler, call createMemoryFromCompletion().
//            This runs after you receive the assistant reply.
// ─────────────────────────────────────────────────────────────────────────────
//
// Wherever you currently display the API response (e.g. in your NSURLSession
// completion handler), add the memory call right after you extract the reply text:
//
// // ...existing code that extracts 'replyText' from the API JSON...
//
//     // ◀ ADD: save a memory of this exchange (async, background, cheap)
//     createMemoryFromCompletion(originalUserPrompt, replyText, API_KEY,
//                                ^(NSString *entry) {
//         if (entry) {
//             EZLogf(EZLogLevelInfo, @"MEMORY", @"Memory saved (%lu chars)",
//                    (unsigned long)entry.length);
//         }
//     });
//
// // ...existing code that updates the UI with replyText...
// ─────────────────────────────────────────────────────────────────────────────


// STEP 5 ── (Optional) Add a Debug/Stats button or shake gesture to show stats.
// ─────────────────────────────────────────────────────────────────────────────
//
// Example: show stats in an alert when user shakes the device.
//
// - (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
//     if (motion == UIEventSubtypeMotionShake) {
//         NSString *stats = EZHelperStats();
//         UIAlertController *alert =
//             [UIAlertController alertControllerWithTitle:@"EZHelper Stats"
//                                                message:stats
//                                         preferredStyle:UIAlertControllerStyleAlert];
//         [alert addAction:[UIAlertAction actionWithTitle:@"OK"
//                                                   style:UIAlertActionStyleDefault
//                                                 handler:nil]];
//         [self presentViewController:alert animated:YES completion:nil];
//     }
// }
// ─────────────────────────────────────────────────────────────────────────────


// STEP 6 ── (Optional) Add a "Clear Memories" button in settings or long-press.
// ─────────────────────────────────────────────────────────────────────────────
//
// - (IBAction)clearMemoriesTapped:(id)sender {
//     UIAlertController *confirm =
//         [UIAlertController alertControllerWithTitle:@"Clear Memory?"
//                                            message:@"All saved conversation memories will be deleted."
//                                     preferredStyle:UIAlertControllerStyleAlert];
//     [confirm addAction:[UIAlertAction actionWithTitle:@"Delete"
//                                                 style:UIAlertActionStyleDestructive
//                                               handler:^(UIAlertAction *a) {
//         BOOL ok = clearMemoryLog();
//         NSString *msg = ok ? @"Memories cleared." : @"Error clearing memories.";
//         // Show a toast or update UI...
//         EZLog(EZLogLevelInfo, @"UI", msg);
//     }]];
//     [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel"
//                                                 style:UIAlertActionStyleCancel
//                                               handler:nil]];
//     [self presentViewController:confirm animated:YES completion:nil];
// }
// ─────────────────────────────────────────────────────────────────────────────
//
// END OF INTEGRATION GUIDE
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// NOTE: SettingsViewController
// ─────────────────────────────────────────────────────────────────────────────
// The repo also has SettingsViewController.h / .m. You can wire helpers there too:
//
// If your Settings screen has a "Clear Memories" option, add #import "helpers.h"
// to SettingsViewController.m and use clearMemoryLog() for that action.
//
// If your Settings screen shows a debug/stats panel, call EZHelperStats() and
// display the returned string in a UITextView or UIAlertController.
//
// The log path (EZLogGetPath()) and memory path (EZMemoryGetPath()) can also
// be used to add share/export buttons to Settings so users can email their logs.
// ─────────────────────────────────────────────────────────────────────────────
