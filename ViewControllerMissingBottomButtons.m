// ViewController.m
// EZCompleteUI v9.4
//
// Changes from v9.3:
//   - FIXED: both "[System: Generating/Editing image with...]" messages
//     hardcoded "gpt-image-1" regardless of which model was actually
//     selected — reported as "says gpt 1 when I have 2.5 selected."
//     callImageEdit now uses preEditModeModel (the real model, same value
//     already sent in the actual request body). callGptImage1's message
//     was built before imgModel got resolved a few lines later, so it was
//     structurally incapable of reflecting the real model — moved the
//     message after imgModel's resolution instead of duplicating that
//     logic at the top. Also fixed two stale MARK comments in the same
//     area that still said "gpt-image-1" only.
//
// Changes from v9.2:
//   - Added gpt-image-2, gpt-image-2.5-flare, gpt-image-2.5-sunburst to
//     self.models and the edit-capable-models set. No changes needed to
//     isGptImage1Family — its hasPrefix:@"gpt-image-" check already
//     covered all three automatically.
//   - Removed dall-e-3 entirely (product decision — the gpt-image family
//     now covers everything it did): every isEqualToString:@"dall-e-3"
//     special case removed (inImageGenMode, isChatModel, isImageModel,
//     imageSettingsButton visibility, the feature-classification block),
//     callDalle3 and its sole caller downloadAndSaveImage:purpose: deleted
//     outright (not commented out, unlike Sora — this is a deliberate
//     product removal, not an external forced shutdown, so there's no
//     "adapt this scaffolding later" reason to keep it). Kept
//     downloadAndSaveImage:'s QLPreviewControllerDataSource methods
//     (numberOfPreviewItemsInPreviewController:/previewItemAtIndex:) —
//     those are shared, generic infrastructure other features still use,
//     not DALL-E-3-specific despite living in the same method before.
//   - The generate-intent dispatch used to diverge: gpt-image-family models
//     went straight to callGptImage1 with no memory context, while the
//     (now-removed) dall-e-3 fallback got prior-image-prompt context
//     prepended first via callDalle3. Both paths now reach callGptImage1
//     — applying memory context to only one of two paths doing the same
//     thing no longer made sense, so consolidated to always apply it.
//   - NOT done — flagged, not fixed: xhigh/max quality tiers (new on the
//     2.5 pair) are fully wired up server-side (ez-image v1.4,
//     check-entitlement v1.5) and in EZEntitlementManager's pre-flight
//     forwarding, but there's no hardcoded quality-options list anywhere
//     in this file — the actual quality picker UI must live in
//     EZImageSettingsViewController, which isn't in context. That file
//     needs its own update to make xhigh/max selectable; the backend
//     already supports them regardless.
//
// Changes from v9.1:
//   - FIXED the root cause of "estimated cost shows high quality regardless
//     of what was selected": the entitlement pre-check for images was
//     calling EZEntitlementManager's 5-param checkEntitlementForFeature:,
//     which never sent quality, size, or is_edit — only the flattened
//     image_low/medium/high feature string. check-entitlement's own
//     estimator treats missing quality as "high" (a deliberate conservative
//     default for genuinely-unknown quality — not meant to fire when the
//     real value is known and simply never got sent). quality/size were
//     already being read correctly from NSUserDefaults right above this
//     call and used to pick the feature tier; they just weren't also being
//     forwarded as their own fields. Now calls EZEntitlementManager's new
//     8-param overload with quality/size/isEdit included — see its own
//     changelog.
//
// Changes from v9.0:
//   - Root-caused and fixed the "unintentional edit mode" bug (made
//     directly, not through this changelog process — documenting here so
//     the record stays accurate). Edit mode was sticky in a way disconnected
//     from whether there was actually anything to edit: the dispatch gate
//     was a bare `selectedModel isEqualToString:@"gpt-image-1-edit"` check,
//     so once edit mode was entered, EVERY subsequent message got routed
//     straight to callImageEdit — including a brand new, unrelated
//     generation request typed after edit mode had already been left
//     stale. Two-part fix: the gate now also requires
//     pendingImagePaths.count > 0, so edit mode only intercepts when
//     there's a real pending source image; and new
//     exitImageEditModeIfNeeded snaps selectedModel back to the real
//     underlying model (via preEditModeModel) once intent routing resolves
//     to reopen or generate, so the edit-mode UI state can't leak into
//     later turns after a previous edit completed.
//   - Added gpt-6-astra (new flagship reasoning model) alongside the
//     gpt-5.x family in the model list, isGPT5's Responses-API routing,
//     isHeavyReasoningModel's extended timeout, and modelSupportsVision.
//   - Complementary fix on my end: hasLocal in the image-intent router was
//     only checking .length > 0 on lastImageLocalPath, true even for a
//     stale path whose file no longer exists — which could independently
//     steer a plain generation into edit mode via the intent classifier
//     even when selectedModel was never stuck on gpt-image-1-edit. Now
//     also confirms the file actually exists before treating "there's a
//     local image" as true. Same root problem as the fix above (edit-mode
//     state outliving what it's actually pointing at), different code path.
//
// Changes from v8.9:
//   - FIXED: none of the three image completion handlers (DALL-E-3,
//     gpt-image-1 generate, image edit) ever read json["reason"] on
//     failure — only json["error"], the terse error code. ez-image
//     reports whether coins were refunded in "reason" specifically for
//     this reason (see its own changelog), but since nothing on the
//     client read it, a timed-out or failed generation just showed
//     something like "Image generation timed out" with zero indication
//     of whether the coins came back. All three now append the reason
//     text when present, same pattern already used for TTS errors.
//   - IMPORTANT OPEN QUESTION, not resolved this pass: traced the actual
//     coin charge for image generation back to
//     [[EZEntitlementManager shared] checkEntitlementForFeature:] — a
//     class not in context. Its feature tags (image_low/medium/high) are
//     flat, not model-aware, and check-entitlement's own COIN_COSTS_FLAT
//     table under those exact keys is calibrated for gpt-image-1.5 only.
//     A ledger review showed identical 11-coin charges across gpt-image-1,
//     gpt-image-1.5, gpt-image-1-mini, and gpt-image-1-edit requests all
//     tagged "image_medium" — consistent with EZEntitlementManager (not
//     ez-image's own model-aware IMAGE_COST_USD table) being what actually
//     determines the real charge. If so, the ez-image v1.2 pricing fix may
//     never be the thing setting the real price in production. Need
//     EZEntitlementManager.h/.m to confirm rather than guess further.
//
// Changes from v8.8:
//   - Added memory entries for image generation and editing — previously
//     only chat completions got one (createMemoryFromCompletion was called
//     from exactly two places, both in the chat flow). Added three more
//     call sites at each flow's actual save point: downloadAndSaveImage:
//     (DALL-E-3 — confirmed it has exactly one caller, callDalle3, so this
//     covers that path without affecting anything else), callGptImage1:,
//     and callImageEdit:. createMemoryFromCompletion itself isn't defined
//     in any file I have (must be in helpers.h/.m) — its signature was
//     inferred from its two existing call sites' consistent usage rather
//     than guessed at from nothing: prompt, answer, token, threadID,
//     attachment paths array, completion block. Answer text is synthesized
//     per flow ("Generated N image(s) for: <prompt>" / "Edited the
//     attached image per: <prompt>") since there's no natural-language
//     model answer the way there is for chat.
//
// Changes from v8.7:
//   - FIXED: attached images vanished entirely when a thread was restored.
//     Root cause: chatHistoryDidSelectThread's restore loop only handled
//     string content and silently `continue`d past anything else —
//     "skip vision attachment blobs on restore," per the old comment.
//     Vision messages (image_url + text blocks) have array content, so
//     every one was dropped with no trace. Fixed via a new
//     ez_recoverImagePathsFromVisionContent: the full base64 data survives
//     in chatContext regardless of how many turns have passed
//     (sanitizedContextForAPI only ever produces a derived copy, never
//     mutates self.chatContext itself — confirmed before relying on it),
//     so this decodes it back into a real local file and restores the
//     attachment bubble, plus the original question text if there was one
//     beyond the placeholder. Works retroactively on already-saved
//     threads, not just future ones.
//   - FIXED: edit-mode source images had ZERO trace anywhere in
//     chatContext — the vision-message-adding code only ever ran in the
//     vision-analysis branch of attachImage:, never the edit-mode branch —
//     so there was nothing for the fix above to recover for edit
//     attachments specifically. Moved that code to run unconditionally.
//     Doesn't change what editing actually does (still goes through
//     callImageEdit's direct call to ez-image, not chatContext) — this
//     purely records the attachment for restore/history purposes, reusing
//     the exact same already-correct _isVisionAttachment merge/prune
//     mechanism rather than inventing a new one. (A brand new role/marker
//     type was considered and rejected — confirmed sanitizedContextForAPI
//     forwards every message's role straight into the real API request
//     with no allow-list, so an invented role would have gotten sent to
//     OpenAI and likely rejected.)
//   - Added a best-effort fallback for edit-mode attachments from BEFORE
//     this fix, which have no chatContext trace to recover at all:
//     activeThread.attachmentPaths (a flat, unordered-relative-to-messages
//     list) surfaces anything not already shown, grouped together with an
//     honest "exact position couldn't be recovered" label rather than
//     pretending to place it precisely. Threads saved going forward don't
//     need this path.
//   - Added tap-to-expand for attachment bubbles (EZAttachmentPreviewCell
//     had none). Same technique as the existing long-press-copy feature:
//     a gesture attached from cellForRowAtIndexPath, resolved to a row via
//     indexPathForCell: at tap time — no changes needed to that cell
//     class, whose source isn't in context. Reuses the previewURL/
//     QLPreviewControllerDataSource plumbing already in this file rather
//     than building new preview infrastructure.
//   - Cleaned up a corrupted/duplicated comment line in analyzeFile: found
//     while working in this area ("Save a copy for
//     persistataWithContentsOfURL:fileURL];" — a mangled leftover, harmless
//     since it was a comment, but confusing).
//   - NOT done this pass: a distinct inline preview for user-uploaded
//     PDF/CSV files (they still get folded into the prompt text at send
//     time — there's no separate-bubble mechanism for those today, at send
//     time or restore). That's a new feature, not a restore bug, and
//     didn't want to add a third large change in the same pass — flagged
//     as a follow-up.
//
// Changes from v8.6:
//   - FIXED: after seeing EZCodeBlockCell's actual source, confirmed a real
//     bug in the v8.6 feature — addMessageSegments tried to read every
//     [CODE:lang:path] saved file as UTF8 text for display. For a real PDF
//     that decode fails outright (shows "(code unavailable)"); for RTF it
//     "succeeds" but returns raw escape-sequence markup, not readable
//     text — neither useful to show or copy. PDF/RTF paths now show a
//     friendly description instead of attempting a text decode. CSV is
//     unaffected — it's genuinely plain text, decodes and displays fine.
//     EZCodeBlockCell.m updated to match: its Copy button now copies the
//     real file data (correct UTI) for PDF/RTF instead of copying that
//     description sentence as text — see its own changelog.
//
// Changes from v8.5:
//   - Added real generated files via fence detection, same mechanism as
//     code blocks: a model can write a fence with language EZPDF, EZDOCX,
//     or EZXCEL (optionally with a filename on the fence line, exactly like
//     the ```python foo.py pattern from v8.5) and get a real generated file
//     instead of a plain-text snippet.
//     - EZPDF  -> real, properly paginated PDF (UIGraphicsPDFRenderer +
//       CoreText; long content correctly flows onto additional pages
//       instead of being clipped to one).
//     - EZDOCX -> RTF, not true .docx. True .docx is a ZIP+XML (OOXML)
//       format iOS has zero built-in support for creating — doing it for
//       real means hand-rolling a ZIP writer (local headers, central
//       directory, CRC32) from scratch, which is a substantially bigger
//       and riskier undertaking than this pass. RTF opens natively in both
//       Word and Pages and iOS generates it natively via NSAttributedString
//       — same practical result (a real document the user can open)
//       without that risk. Decided with the user rather than assumed.
//     - EZXCEL -> CSV, not true .xlsx, same reasoning (also ZIP+XML).
//       Opens natively in Excel/Numbers/Sheets.
//     Extension is always forced to the real format regardless of what the
//     model or fence-line filename suggests (ez_filename:forcedExtension:)
//     — a file is never shipped with a misleading extension.
//     Content convention (needs to go in the system prompt too — not a
//     file I have in context to edit directly): EZPDF/EZDOCX bodies use a
//     small markdown subset (# / ## headings, **bold**, blank-line
//     paragraphs — NOT full markdown, deliberately kept small so it's easy
//     to document accurately). EZXCEL bodies are pipe-delimited rows
//     (Name|Age|City) rather than comma-delimited, specifically so the
//     model never has to get CSV quoting/escaping right itself — this code
//     does that conversion, including properly quoting fields that contain
//     a comma, quote, or newline.
//     Reuses the exact same [CODE:label:path] placeholder /
//     EZCodeBlockCell rendering pipeline as regular code blocks — no
//     changes needed there. One caveat worth knowing: I don't have
//     EZCodeBlockCell's own source, so I can't confirm what its "Copy"
//     button does for a binary (PDF/RTF/CSV) attachment vs. a text
//     snippet — if it assumes text content, that's a pre-existing surface
//     of that class, not something new here.
//
// Changes from v8.4:
//   - FIXED: processReplyWithCodeBlocks's fence regex only tolerated
//     whitespace between the language token and the newline
//     (```python\n rendered fine, ```python foo.py\n did not — the whole
//     match failed, so the code block silently fell back to plain text
//     instead of an EZCodeBlockCell). Some models annotate fences with a
//     filename this way. Regex now captures that trailing fence-line text
//     as its own group instead of requiring it to be empty, and — since an
//     explicit fence-line filename is a deliberate annotation rather than
//     a guess — it's checked first, ahead of the existing heuristic that
//     scans the first two lines of the code body for something that looks
//     like a filename. That body-scan is unchanged and still runs as the
//     fallback when the fence line doesn't have one.
//
// Changes from v8.3:
//   - All Sora code commented out (not deleted), per request — user removed
//     Sora from Settings on their own, and OpenAI's Sora API shutdown
//     (2026-09-24) makes it dead either way. Kept as comments rather than
//     deleted since Sora's submit-job/poll-status/download call shape is
//     close to how most other video-gen APIs work (Runway, Luma Dream
//     Machine, Kling, Veo) — may be worth adapting the polling/refund
//     scaffolding if a replacement gets added later, rather than starting
//     from scratch. Touched: the pendingVideoURL property (lastVideoPrompt
//     too, though that one turned out to already be dead — never actually
//     read or written anywhere outside its own declaration), the
//     viewDidLoad job-resume observer, the sora-2/sora-2-pro model list
//     entries, the feature-tier detection branch, the send-flow dispatch,
//     the entire callSora/pollSoraJob/resumePendingSoraJobIfNeeded/
//     fetchSoraContent/downloadAndShowVideo implementation (wrapped in one
//     block comment), and the deferred-video-presentation hook in
//     viewWillAppear. Search this file for "SORA —" to find every spot if
//     restoring or fully deleting later.
//   - NOTE: EZModelPickerViewController.m was NOT touched — it has its own
//     independent hardcoded model list (doesn't read self.models at all,
//     per the v7 changelog entry on that file) and still shows a Video
//     section with sora-2/sora-2-pro. Since self.selectedModel can no
//     longer actually become "sora-*" through normal use (removed from
//     self.models here), picking that entry would fail rather than
//     silently misbehave, but it's a stale, misleading option to leave
//     showing in the UI — worth a follow-up pass on that file too.
//
// Changes from v8.2:
//   - FIXED: the same bug as v8.2's image fix, but for file attachments
//     (PDF/ePub/text) — asked about directly, turned out to affect them too.
//     pendingFileContext/pendingFileName were two parallel singular
//     NSStrings; attaching a second file before sending overwrote both
//     entirely, silently discarding the first file's extracted text with
//     no trace. Simpler fix than images needed: file content only gets
//     folded into the outgoing prompt once, at send time (unlike images,
//     there's no per-attachment chatContext message to worry about
//     pruning), so this is just pendingFileContext/pendingFileName →
//     pendingFiles, one array of {name, content} dicts (rather than two
//     parallel arrays, which could desync a name with the wrong content),
//     appended to instead of overwritten, and looped over at send time so
//     every attached file — not just the last — gets injected.
//
// Changes from v8.1:
//   - FIXED: attaching more than one image before sending only actually
//     reached the AI with the last one. Two compounding causes:
//     (1) pendingImagePath was a singular NSString, so each new attachment
//     silently overwrote the last — now pendingImagePaths, an array.
//     (2) attachImage: created a brand-new standalone chatContext vision
//     message per image, and sanitizedContextForAPI deliberately keeps only
//     the single most recent vision MESSAGE (correct, desirable behavior
//     for genuinely old attachments left over from an earlier, already-
//     completed turn — that's what stops every prior image getting
//     re-sent as base64 on every future turn). With each image in its own
//     message, that pruning logic had no way to tell "old attachment from
//     3 turns ago" apart from "second image attached 2 seconds ago in the
//     same not-yet-sent turn" — it downgraded both to plain text the same
//     way, keeping only the last. attachImage: now merges an image into
//     the previous chatContext entry's content array instead of creating a
//     new message, but only when that previous entry is itself still an
//     unsent vision attachment — the merge naturally stops the instant the
//     user sends (which appends a real user-prompt message right after),
//     so images from an actually-completed earlier turn are never merged
//     into by mistake. sanitizedContextForAPI itself needed no changes.
//   - Edit mode (callImageEdit, the AI-intent-detected edit switch, both
//     gallery-share notification handlers) uses pendingImagePaths.lastObject
//     — edit mode only supports one source image per OpenAI's edit
//     endpoint as currently wired up here, so this preserves existing
//     single-image-edit behavior; extending editing itself to accept
//     multiple reference images would be a separate, larger change to
//     ez-image's edit action.
//   - The "memory" attachment-tracking arrays (attachmentsAtSend,
//     capturedAttachments) now collect every pending path instead of just
//     one, via addObjectsFromArray: instead of addObject:.
//
// Changes from v8.0:
//   - Fixed the edit-mode model hardcode flagged (but not fixed) in v8.0.
//     Added preEditModeModel, set by a new shared
//     enterImageEditModeFromCurrentSelection helper that now replaces every
//     place that used to set selectedModel = @"gpt-image-1-edit" directly
//     (attach-image flow, legacy dall-e-2-edit fallback, AI-intent-detected
//     edit switch, gallery-share notification handler — the last of these
//     had a dead conditional that computed whether the prior model was an
//     image model but never did anything with the result; replaced with
//     the real logic). preEditModeModel is sticky across a chat-mode
//     detour (see the helper's own comment) rather than resetting on every
//     non-edit-capable selection.
//   - callImageEdit, callGptImage1's edit→generate model conversion, and
//     the entitlement pre-check's apiModel all now use preEditModeModel
//     instead of a hardcoded "gpt-image-1" — this is what actually lets
//     gpt-image-1.5/2/mini edits reach ez-image's now-fixed model handling
//     (v1.2) instead of silently downgrading at the client before the
//     request is even built.
//   - Edit-mode button title is now dynamic ("Model: gpt-image-1.5 (edit
//     mode)" etc.) instead of a hardcoded "gpt-image-1" label, so it
//     doesn't lie about which model is actually being used.
//
// Changes from v7.9:
//   - Added a status banner (spinner + cycling text) to all three image
//     flows (DALL-E-3, gpt-image-1 generate, image edit) so it's clear
//     generation is still working rather than stuck. Didn't build a new UI
//     for this — generalized the existing GPT-5 status banner
//     (showGPT5StatusBanner/hideGPT5StatusBanner), which already had the
//     spinner/label/timer/cross-dissolve cycling infrastructure, pulling
//     its hardcoded message array out into statusBannerMessages so any
//     caller can supply its own set. GPT-5's own banner behavior is
//     unchanged — showGPT5StatusBanner is now a thin wrapper. New
//     showImageGenStatusBanner uses the requested phrasing ("Working on
//     your request…", "Do not leave the page while generating…", etc.).
//     Banner is shown right before each postToEZFunction call (after all
//     pre-flight guard clauses, so a validation failure never leaves it
//     stuck showing) and hidden as the first line of each completion
//     block, ahead of every branch, so it can't be left up on any exit path.
//   - Noted but did NOT fix: callImageEdit still hardcodes
//     model:"gpt-image-1" client-side. ez-image's matching server-side
//     hardcode is fixed (v1.2), but the client has no real model to send in
//     the first place — self.selectedModel during edit mode is the literal
//     string "gpt-image-1-edit", a UI mode flag rather than a real model.
//     Letting users edit with gpt-image-1.5/2/mini needs a property
//     remembering which real model was selected before entering edit mode;
//     flagged in place rather than guessed at.
//
// Changes from v7.8:
//   - Added long-press-to-copy on chat bubbles (both user prompts and AI
//     completions). Implemented as a UIContextMenuInteraction attached to
//     each EZBubbleCell's contentView in cellForRowAtIndexPath, rather than
//     inside EZBubbleCell itself — didn't have that file in context, and
//     this approach doesn't need it: the interaction resolves which
//     message it belongs to at invocation time via indexPathForCell:, so
//     it stays correct across cell reuse without touching the cell class.
//     "Copy" puts the message's raw text on the pasteboard and confirms
//     with the same "[System: ...]" convention used for every other
//     transient confirmation in this file (verified appendToChat tags
//     these role:"system", which the API payload builder already excludes
//     — same as the existing "[System: Image saved...]" etc. messages).
//     Added UIContextMenuInteractionDelegate to the class extension's
//     protocol list at the top of this file.
//
// Changes from v7.7:
//   - speakWithElevenLabsEdge: root-caused the recurring "TTS network error"
//     reports. The edge function's base64 encoding was crashing on any
//     non-trivial audio length (fixed server-side in ez-elevenlabs v6.6 —
//     see that file's changelog); the client made it worse by leaving
//     req.timeoutInterval on the 60s default, too short once the server
//     legitimately needs up to two 90s attempts on a format fallback.
//     Timeout raised to 220s. Also added a client-side 10,000-char cap
//     (matches ez-elevenlabs MAX_TTS_CHARS / the eleven_multilingual_v2
//     model's real limit) so an oversized response fails immediately with
//     a clear message instead of attempting a doomed round trip.
//   - Generic non-200 handler now shows the server's "reason" field when
//     present instead of a bare status code — ez-elevenlabs' new error
//     paths (text_too_long, tts_timeout, tts_fetch_failed) all include one.
//
// Changes from v7.6:
//   - self.models: added gpt-5.6-sol, gpt-5.6-terra, gpt-5.6-luna (new
//     flagship/standard/mini tier, replaces gpt-5.5 as OpenAI's top model)
//     and gpt-image-2 (supersedes gpt-image-1.5). isGptImage1Family and
//     modelSupportsVision already prefix-match "gpt-image-"/"gpt-5" so both
//     picked up the new models automatically — no changes needed there.
//   - Fixed duplicate vision-capability whitelist: the image-attach handler
//     in handleAttachImage kept its own hardcoded NSSet of vision-capable
//     models instead of calling modelSupportsVision:, so it never learned
//     about gpt-4.1.x, o3.x, o4.x, or now gpt-5.6.x — attaching an image
//     while one of those was selected would silently downgrade to gpt-4o.
//     Now calls [self modelSupportsVision:] directly; one source of truth.
//   - Fixed coin-tier bucketing for gpt-5.6: the featureTier classifier
//     assumed every cheap gpt-5.x variant ends in "-mini" or "-nano"
//     (true for 5, 5.4), but gpt-5.6's tiers are named sol/terra/luna with
//     no shared suffix. Added an explicit cheap-tier name check so
//     gpt-5.6-luna logs as chat_mini instead of chat_premium. Logging only —
//     real billing is computed server-side in ez-chat off the exact model
//     string, this just keeps ez_usage_log's feature column meaningful.
//
// Changes from v7.5:
//   - Added insurancePolicyButton to the top button row, wired to
//     openInsurancePolicy, presenting EZInsuranceLandingViewController the
//     same way openSupport/openTTS/openCloning present their view
//     controllers. Added to the existing fixed-width topStack for now —
//     that stack isn't actually inside the SidewaysScrollView the class
//     declares a property for (see the unused sidewaysScrollView property
//     below); it's a plain UIStackView pinned to the view's edges. Worth
//     revisiting once SidewaysScrollView.h is available, since the row is
//     now at 14 icons in a fixed width.
//
// Changes from v7.4:
//   - sanitizedContextForAPI: Responses API image blocks now use
//     { type:"input_image", source_type:"base64", data:<b64>, media_type:<mime> }
//     instead of the broken { type:"input_image", image_url:<string> } shape that
//     caused "invalid format" errors on gpt-5.1-mini, gpt-4.1-mini, and gpt-4.1.
//     Chat Completions path unchanged: { type:"image_url", image_url:{url:...} }.
//   - modelSupportsVision: gpt-4.1.x, o3.x, o4.x added via prefix checks.
//   - webSearchCompatible: gpt-4.1.x, o3.x, o4.x added; simplified to prefix checks.
//   - useResponsesAPI: gpt-4.1 family now routes through Responses API natively.
//
// Changes from v7.3:
//   - analyzePromptForContext and createMemoryFromCompletion now receive the
//     Supabase JWT ([EZAuthManager shared].accessToken) instead of nil — fixes
//     NSCParameterAssert crash and the silent pipeline failure that followed
//   - handleSendAuthorized: JWT retrieved once at entry with a nil guard;
//     captured by the fetchRelevantMemories completion block so it's available
//     to both analyzePromptForContext call sites and the Tier-1
//     createMemoryFromCompletion call without redundant accessToken lookups
//   - fetchRelevantMemories: JWT captured before dispatch_async and passed to
//     EZThreadSearchMemory so the AI-powered memory ranker (Stage 2) now runs
//     instead of always falling back to loadMemoryContext(5)
//   - callChatCompletions: createMemoryFromCompletion now passes the already-
//     captured token (was nil) — memory creation after chat replies now works
//
// Changes from v7.2:
//   - Fixed: tapping Send while keyboard is visible caused first tap to dismiss
//     keyboard but not send. Root cause: the view-wide UITapGestureRecognizer
//     (dismissTap) was firing on the same touch as the send button, starting a
//     keyboard-hide layout animation that repositioned the inputContainer mid-
//     touch, causing UIKit to cancel the button's touchUpInside before it fired.
//   - Fix: ViewController now adopts UIGestureRecognizerDelegate and implements
//     gestureRecognizer:shouldReceiveTouch: to return NO when the touch lands on
//     any UIControl (button, switch, etc.). The dismissTap gesture is therefore
//     skipped entirely on button taps — no animation race, send always fires.
//   - dismissTap.delegate = self wired in setupUI.
//
// Changes from v7.1:
//   - TTS now routed through ez-elevenlabs Supabase edge function (server-side
//     ElevenLabs key via Supabase secret) instead of the user's own API key.
//     Coins are deducted server-side at 1 coin per 50 chars (rounded up).
//   - speakLastResponse: responses > 160 chars now show a UIAlertController
//     warning with estimated coin cost, offering: Use ElevenLabs, Use Apple
//     TTS (free), or Don't Read — prevents accidentally reading huge responses.
//   - Insufficient-coins response (HTTP 402) from edge function shows its own
//     alert: Apple TTS fallback or Get Coins (opens coin store).
//   - All ElevenLabs error paths fall back to Apple TTS with a chat notice.
//   - Coin balance display is refreshed after a successful TTS call.
//   - Old direct-to-ElevenLabs code (user API key path) commented out, not
//     deleted, in case user keys need to be restored in the future.
//   - Added #import "EZAuthManager.h" for JWT access ([EZAuthManager shared].accessToken).
//
// Changes from v6.9:
//   - handleSend now disables send button and shows user bubble IMMEDIATELY on
//     tap, before any entitlement check or API call — eliminates the visible
//     delay where text sat in the input field doing nothing
//   - Same early UI commit (clear field, dismiss keyboard) now applies to all
//     model types: chat, image, sora — previously only chat got it synchronously
//   - Duplicate-send bug fixed: send button is disabled at the very top of
//     handleSend, so rapid taps during the async entitlement network round-trip
//     can no longer queue up extra calls
//   - handleSendAuthorized: removed redundant appendToChat/endEditing/setInputText
//     (already done in handleSend); chatContext addObject kept since it still
//     needs the fully-assembled fullPrompt (with file context injected)
//   - Removed two redundant sendButton.enabled = NO lines in handleSendAuthorized
//     (image intent path and chat path) — button is already disabled on entry
//   - handleAPIError now re-enables send button on main thread so any API failure
//     path correctly unlocks the button
//   - Both entitlement-denied blocks in handleSend now re-enable send button
//     before showing the error/coin-store so user can retry
//   - No-API-key early return in handleSendAuthorized re-enables send button
//   - callImageEdit early-exit guards (no path, bad data, decode fail, PNG fail)
//     all re-enable send button before returning
//
// Changes from v6.7:
//   - Fixed: stale lastImageLocalPath no longer injected into unrelated memory entries
//     Root cause: chatContext scan for _isVisionAttachment was permanently sticky after
//     the first image send; replaced with pendingImagePath check (this-turn-only signal)
//   - Fixed same bug in direct-answer (Tier 1) memory path — same stale injection removed
//   - pendingImagePath now cleared immediately after capture in both memory paths
//
// Changes from v6.6:
//   - GPT-5 timeout increased (180s solo, 240s with web search)
//   - Web search now silently skipped with warning for incompatible models
//   - Copy button shows checkmark confirmation for 1.5s
//   - Language→extension map fixed for objective-c/objc variants + normalization
//   - Image display intent detection: "show it again" reopens instead of regenerating
//   - attachmentPaths now always includes lastImageLocalPath + pendingImagePath
//   - Code block detection: extracts ```, saves to EZAttachments, renders inline widget
//   - processReplyWithCodeBlocks: saves snippets, returns display string with placeholders
//   - sanitizedContextForAPI: converts image/text block types for Responses vs Chat API
//   - ElevenLabs + Whisper keys now stored via EZKeyVault (Keychain), not NSUserDefaults
//   - URLs in AI responses are now tappable (dataDetectorTypes) with styled link appearance
//   - checkReplyForLocalFilePaths regex broadened to /var/mobile/ prefix + any extension
//   - Bubble chat UI: UITableView replaces UITextView; user (blue, right) and
//     assistant (gray, left) message bubbles with iMessage-style tail corners
//   - Code blocks rendered as EZCodeBlockCell with Copy + Share buttons
//   - Thread title now set from attachment filename when attachment is first action
//   - Sora: video deferred to pendingVideoURL when app is backgrounded, presented on foreground
//
// Changes from v6.5 / v6.6:
//   - Code blocks fixed at ~1/3 screen height with internal scrolling (restored original look)
//   - Spurious attachment bug fixed: lastImageLocalPath/pendingImagePath no longer blindly
//     injected into every chat completion's captured attachments
//   - gpt-image-1 models expanded: gpt-image-1.5, gpt-image-1-mini, chatgpt-image-latest
//   - Image generation settings: quality, size, output_format, background, moderation
//     stored in NSUserDefaults; showImageSettings sheet from model button when image model active

#import "ViewController.h"
#import "SettingsViewController.h"
#import "ChatHistoryViewController.h"
#import "helpers.h"
#import "EZKeyVault.h"
#import <objc/runtime.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <QuickLook/QuickLook.h>
#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>
#import <PDFKit/PDFKit.h>
#import <CoreText/CoreText.h>
#import <Photos/Photos.h>
#import <PhotosUI/PhotosUI.h>
#import <QuartzCore/QuartzCore.h>
#import "SidewaysScrollView.h"
#import "EZModelPickerViewController.h"
#import "EZImageSettingsViewController.h"
#import "EZAttachMenuViewController.h"
#import "ViewController+EZKeepAwake.h"
#import "ElevenLabsCloneViewController.h"
#import "EZCoinStoreViewController.h"
#import "EZPhotoGalleryViewController.h"
#import "EZCoinPotView.h"
#import "TextToSpeechViewController.h"
#import "MemoriesViewController.h"
#import "SupportRequestViewController.h"
#import "BrainRotViewController.h"
#import "EZBubbleCell.h"
#import "EZSystemCell.h"
#import "EZCodeBlockCell.h"
#import "EZImageGridCell.h"
#import "EZEntitlementManager.h"
#import "EZAuthManager.h"         // needed for [EZAuthManager shared].accessToken (edge function JWT)
#import "EZSupabaseConfig.h"
#import "EZTermsAcceptanceViewController.h"
#import "HelperLogViewController.h"
#import <CommonCrypto/CommonDigest.h>

NSNotificationName const EZAttachExternalDocumentToChat = @"EZAttachExternalDocumentToChat";
static NSString *const kPendingExternalDocumentPath = @"EZPendingExternalDocumentPath";
static NSString *const kPendingExternalImageAskPath = @"EZPendingExternalImageAskPath";

// Stable, non-reversible identifier for OpenAI safety tracking.  Keep this a
// raw SHA-256 hex digest: OpenAI's maximum is 64 characters, and a SHA-256
// digest is exactly 64.  Do not add the old "user_" prefix.
static NSString *ez_safetyIdentifierForUserId(NSString *userId) {
    if (userId.length == 0) return nil;

    NSData *data = [userId dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);

    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}


typedef NS_ENUM(NSInteger, EZAttachMode) {
    EZAttachModeNone,
    EZAttachModeWhisper,
    EZAttachModeAnalyze,
};

@interface ViewController () <UIDocumentPickerDelegate,
                               UITextFieldDelegate,
                               UITextViewDelegate,
                               UITableViewDataSource,
                               UITableViewDelegate,
                               QLPreviewControllerDataSource,
                               PHPickerViewControllerDelegate,
                               SFSpeechRecognizerDelegate,
                               UIGestureRecognizerDelegate,
                               UIContextMenuInteractionDelegate,
                               ChatHistoryViewControllerDelegate>




// UI
/// UITableView that renders all chat messages as bubble / system / code cells.
//@property (nonatomic, strong) UITableView   *chatTableView;
/// Flat array of display-message dicts driving chatTableView.
/// Keys: role (@"user"|@"assistant"|@"system"|@"code"), text, language, savedPath.
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *displayMessages;
@property (nonatomic, strong) UIView        *inputContainer;
@property (nonatomic, strong) UITextView    *messageTextField;  // was UITextField; now expanding UITextView
@property (nonatomic, strong) UIButton      *sendButton;
@property (nonatomic, strong) UIButton      *modelButton;
@property (nonatomic, strong) UIButton      *attachButton;
@property (nonatomic, strong) UIButton      *settingsButton;
@property (nonatomic, strong) UIButton      *clipboardButton;
@property (nonatomic, strong) UIButton      *speakButton;
@property (nonatomic, strong) UIButton      *clearButton;
/// Appears in input area when an image model is active — opens image parameter sheet.
@property (nonatomic, strong) UIButton      *imageSettingsButton;
/// Shows and edits the number of turns supplied to triage after UNCERTAIN.
@property (nonatomic, strong) UILabel       *triageUncertainTurnsLabel;
@property (nonatomic, strong) UIStepper     *triageUncertainTurnsStepper;
@property (nonatomic, strong) UIButton      *dictateButton;
@property (nonatomic, strong) UIButton      *webSearchButton;
/// Lightning bolt: permits helper models to answer directly when enabled.
@property (nonatomic, strong) UIButton      *helperDirectAnswersButton;
@property (nonatomic, strong) UIButton      *historyButton;
@property (nonatomic, strong) UIButton      *addChatButton;
@property (nonatomic, strong) UIButton      *memoriesButton;
@property (nonatomic, strong) UIButton      *supportRequestButton;
@property (nonatomic, strong) UIButton      *textToSpeechButton;
@property (nonatomic, strong) UIButton      *cloningButton;
@property (nonatomic, strong) UIButton      *galleryButton;
@property (nonatomic, strong) UIButton      *brainRotButton;
/// The cell currently editing a code/document block, if any. The composer
/// remains visible but is deliberately inactive during that focused edit.
@property (nonatomic, weak) EZCodeBlockCell *activeDocumentEditingCell;
//@property (nonatomic, strong) UIButton      *textToSpeechButton;

@property (nonatomic, strong) NSLayoutConstraint *containerBottomConstraint;
/// Height constraint on the message input view — animated on focus/blur.
@property (nonatomic, strong) NSLayoutConstraint *messageInputHeightConstraint;
/// Tappable label showing the active thread title — tap to rename.

/// Button in top bar that triggers renaming.
@property (nonatomic, strong) UIButton      *renameButton;

// State
@property (nonatomic, strong) NSArray       *models;
@property (nonatomic, strong) NSString      *selectedModel;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *chatContext;
@property (nonatomic, assign) BOOL          webSearchEnabled;

// Active thread
@property (nonatomic, strong) EZChatThread  *activeThread;

// Media / file state
@property (nonatomic, strong) NSURL         *previewURL;
// ── SORA — commented out, not deleted. User removed Sora from Settings;
// OpenAI's Sora API is also scheduled for shutdown 2026-09-24 regardless.
// Left intact rather than deleted: Sora's submit-job/poll-status/download
// pattern is close to how most other video-gen APIs work too (Runway,
// Luma Dream Machine, Kling, Veo), so this may be worth adapting rather
// than rewriting from scratch if/when a replacement gets added. ─────────
// /// Non-nil when a Sora video completed while the app was backgrounded.
// /// Presented the next time the view becomes visible.
// @property (nonatomic, strong) NSURL         *pendingVideoURL;
// ── END SORA ─────────────────────────────────────────────────────────────
// Every file (PDF/ePub/text) attached since the last send, not yet folded
// into a sent message. Was two parallel singular NSStrings
// (pendingFileContext/pendingFileName) — same bug as pendingImagePath had:
// attaching a second file before sending overwrote the first's extracted
// text entirely, with no trace it ever existed. Kept as one array of
// {name, content} dicts rather than two parallel arrays, so there's no way
// for a name and its content to end up misaligned.
@property (nonatomic, strong) NSMutableArray<NSDictionary<NSString *, NSString *> *> *pendingFiles;
// Every image attached since the last send that hasn't been folded into a
// sent message yet. Was a singular NSString — attaching a second image
// before sending silently overwrote the first, and separately, each
// attachment also produced its own standalone chatContext vision message,
// so sanitizedContextForAPI's "only resend the newest image" pruning (real,
// desirable behavior for genuinely old attachments from earlier turns) had
// no way to tell that apart from two images attached in the *same* turn —
// it kept only the last one either way. Both are fixed together: this is
// now an array, and attachImage: merges same-turn attachments into one
// chatContext message instead of creating a new one each time.
@property (nonatomic, strong) NSMutableArray<NSString *> *pendingImagePaths;
@property (nonatomic, strong) NSString      *lastImagePrompt;      // last DALL-E prompt (for follow-ups)
// @property (nonatomic, strong) NSString      *lastVideoPrompt;      // last Sora prompt (for memory indexing)
// ^ SORA — commented out with the rest below. Note: grepping the rest of this
// file, this property was never actually read or written anywhere outside
// its own declaration — looks like it was already dead before Sora removal,
// not something this comment-out created.
@property (nonatomic, strong) NSString      *lastImageLocalPath;   // local path of last generated image

// TTS / audio
@property (nonatomic, strong) AVSpeechSynthesizer *speechSynthesizer;
@property (nonatomic, strong) AVAudioPlayer *audioPlayer;
@property (nonatomic, strong) NSString      *lastAIResponse;
@property (nonatomic, strong) NSString      *lastUserPrompt;

// Dictation
@property (nonatomic, strong) SFSpeechRecognizer               *speechRecognizer;
@property (nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *recognitionRequest;
@property (nonatomic, strong) SFSpeechRecognitionTask          *recognitionTask;
@property (nonatomic, strong) AVAudioEngine                    *audioEngine;
@property (nonatomic, assign) BOOL                              isDictating;


    // Sideways-scrolling top-row container (inserted)
    @property (nonatomic, strong) UIView *topButtonsContainer;
    @property (nonatomic, strong) SidewaysScrollView *sidewaysScrollView;
@property (nonatomic, strong) UIView        *statusBannerView;
@property (nonatomic, strong) UILabel       *statusBannerLabel;
@property (nonatomic, strong) UIActivityIndicatorView *statusBannerSpinner;
@property (nonatomic, strong) NSTimer       *statusBannerTimer;
@property (nonatomic, assign) NSInteger      statusBannerPhase;
@property (nonatomic, strong) NSArray<NSString *> *statusBannerMessages;
// Remembers which real image model (gpt-image-1/-1-mini/-1.5/-2/
// chatgpt-image-latest) was selected before switching into edit mode, since
// self.selectedModel becomes the literal string "gpt-image-1-edit" (a UI
// mode flag) while editing — there'd otherwise be no way to know which real
// model to actually send. Set only by enterImageEditModeFromCurrentSelection.
@property (nonatomic, strong) NSString *preEditModeModel;
- (void)setupKeyboardObservers;

// History drawer (slide-in panel from left)
@property (nonatomic, strong) UIView                 *drawerContainerView;
@property (nonatomic, strong) UIView                 *drawerDimView;
@property (nonatomic, strong) UINavigationController *drawerNavController;
@property (nonatomic, strong) NSLayoutConstraint     *drawerLeadingConstraint;
@property (nonatomic, assign) BOOL                    drawerOpen;

// Memories drawer (slide-in panel from right)
@property (nonatomic, strong) UIView                 *memoriesDrawerContainerView;
@property (nonatomic, strong) UIView                 *memoriesDrawerDimView;
@property (nonatomic, strong) UINavigationController *memoriesDrawerNavController;
@property (nonatomic, strong) NSLayoutConstraint     *memoriesDrawerTrailingConstraint;
@property (nonatomic, assign) BOOL                    memoriesDrawerOpen;
@property (nonatomic, strong) UILabel *coinBalanceLabel; // kept for compatibility
@property (nonatomic, strong) EZCoinPotView *coinPotView;

// Private helpers added since previous interface
- (void)restoreImageGridCellsForThread:(NSString *)threadID;
- (void)appendAttachmentBubble:(NSString *)imagePath;
- (void)presentCoinStoreForFeature:(NSString * _Nullable)featureName;
- (NSString *)featureLabel:(EZFeature)feature;
- (void)offerToOpenLocalFile:(NSString *)path;
- (void)classifyImageIntent:(NSString *)prompt
              hasLocalImage:(BOOL)hasLocalImage
                 completion:(void(^)(NSString *intent))completion;
// - (void)callSora:(NSString *)prompt;   // SORA — see comment block near its implementation
- (BOOL)modelSupportsVision:(NSString *)model;
- (NSArray<NSString *> *)ez_recoverImagePathsFromVisionContent:(NSArray *)contentBlocks;
- (void)showGPT5StatusBanner;
- (void)hideGPT5StatusBanner;
- (void)showStatusBannerWithMessages:(NSArray<NSString *> *)messages;
- (void)hideStatusBanner;
- (void)showImageGenStatusBanner;
- (void)enterImageEditModeFromCurrentSelection;
- (void)exitImageEditModeIfNeeded;
- (void)handleAPIError:(NSString *)msg;
- (void)checkReplyForLocalFilePaths:(NSString *)reply;
- (NSArray *)sanitizedContextForAPI:(NSArray *)context
                  modelSupportsVision:(BOOL)supportsVision
                      useResponsesAPI:(BOOL)useResponsesAPI;
// - (void)downloadAndShowVideo:(NSString *)urlString;   // SORA — see the big commented block
- (void)appendImageGridToChat:(NSArray<NSString *> *)imagePaths
                       prompt:(NSString *)prompt
                      isError:(BOOL)isError
                    errorText:(nullable NSString *)errorText;
- (void)persistImagePath:(NSString *)path prompt:(NSString *)prompt;
- (void)callImageEdit:(NSString *)prompt imagePath:(NSString *)imagePath;
- (void)triageUncertainTurnsChanged:(UIStepper *)sender;
- (void)toggleHelperDirectAnswers;
- (void)updateHelperDirectAnswersButton;
- (void)callChatCompletionsWithRetryCount:(NSInteger)retryCount;
- (void)recoverUndeliveredGalleryImagesIfNeeded;
- (void)consumePendingExternalImageEdit;
- (void)consumePendingExternalImageQuestion;
- (void)consumePendingExternalDocument;
- (void)handleExternalDocumentOpen:(NSNotification *)notification;

@end
@interface ViewController (EZPrivateForward)
- (void)scrollChatToBottom;
- (void)transcribeAudio:(NSURL *)fileURL;
- (BOOL)isGptImage1Family:(NSString *)model;
- (void)analyzeFile:(NSURL *)fileURL;
- (void)setupKeyboardObservers;
- (void)closeDrawer;
@end

@implementation ViewController

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Lifecycle
// ─────────────────────────────────────────────────────────────────────────────

- (void)viewDidLoad {
    [super viewDidLoad];

   
    EZLogRotateIfNeeded(512 * 1024);
    EZHelperLogRotateIfNeeded(512 * 1024);
    EZLog(EZLogLevelInfo, @"APP", @"EZCompleteUI v7.6 viewDidLoad");
    [self setupData];
    [self setupUI];
    [self setupKeyboardObservers];
    [self setupDictation];
    [self requestSpeechPermissionsIfNeeded];
    // SORA — commented out with the rest of the Sora code (see the big block
    // near callSora's implementation). Was: resume polling a Sora job that
    // was still in flight when the app was last backgrounded/killed.
    // [[NSNotificationCenter defaultCenter] addObserver:self
    //     selector:@selector(resumePendingSoraJobIfNeeded)
    //     name:@"EZAppDidBecomeActive" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(handleOpenChatThread:)
        name:@"EZOpenChatThread" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(handleSubscriptionUpdated)
        name:@"EZSubscriptionUpdated" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(handleAttachImageToChat:)
        name:EZAttachImageToChat object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(handleEditImageInChat:)
        name:EZEditImageInChat object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(handleCodeBlockEditingState:)
        name:EZCodeBlockEditingStateDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(handleExternalDocumentOpen:)
        name:EZAttachExternalDocumentToChat object:nil];
    [self consumePendingExternalImageEdit];
    [self consumePendingExternalImageQuestion];
    [self consumePendingExternalDocument];
    [[EZEntitlementManager shared] refreshBalanceWithCompletion:^(NSInteger balance) {
        [self updateCoinBalanceDisplay];
    }];
    [self recoverUndeliveredGalleryImagesIfNeeded];

}

- (void)consumePendingExternalDocument {
    NSString *path = [[NSUserDefaults standardUserDefaults]
        stringForKey:kPendingExternalDocumentPath];
    if (!path.length) return;
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kPendingExternalDocumentPath];
        return;
    }
    [self handleExternalDocumentOpen:[NSNotification notificationWithName:EZAttachExternalDocumentToChat
                                                                     object:nil
                                                                   userInfo:@{ @"filePath": path }]];
}

- (void)consumePendingExternalImageQuestion {
    NSString *path = [[NSUserDefaults standardUserDefaults]
        stringForKey:kPendingExternalImageAskPath];
    if (!path.length) return;
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kPendingExternalImageAskPath];
        return;
    }
    [self handleAttachImageToChat:[NSNotification notificationWithName:EZAttachImageToChat
                                                                 object:nil
                                                               userInfo:@{ @"filePath": path }]];
}

- (void)handleExternalDocumentOpen:(NSNotification *)notification {
    NSString *path = [notification.userInfo[@"filePath"] isKindOfClass:[NSString class]]
        ? notification.userInfo[@"filePath"] : nil;
    if (!path.length || ![[NSFileManager defaultManager] fileExistsAtPath:path]) return;

    // Make the normal attachment path wait for a usable session. A launch
    // from Files can happen while restoration is still underway; refreshing
    // here means the document is immediately question-ready instead of
    // requiring a relaunch before the first chat request succeeds.
    [[EZAuthManager shared] getValidAccessToken:^(NSString *token, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!token.length) {
                // Keep the copied document for the next successful login.
                [[NSUserDefaults standardUserDefaults] setObject:path
                                                            forKey:kPendingExternalDocumentPath];
                [self appendToChat:@"[System: Document saved. Sign in to ask a question about it.]"];
                return;
            }
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:kPendingExternalDocumentPath];
            [self analyzeFile:[NSURL fileURLWithPath:path]];
        });
    }];
}

- (void)handleCodeBlockEditingState:(NSNotification *)notification {
    EZCodeBlockCell *cell = [notification.object isKindOfClass:[EZCodeBlockCell class]]
        ? notification.object : nil;
    BOOL editing = [notification.userInfo[@"editing"] boolValue];
    if (editing) {
        self.activeDocumentEditingCell = cell;
    } else if (!self.activeDocumentEditingCell || self.activeDocumentEditingCell == cell) {
        self.activeDocumentEditingCell = nil;
    }

    BOOL composerActive = self.activeDocumentEditingCell != nil;
    self.inputContainer.userInteractionEnabled = !composerActive;
    self.inputContainer.alpha = composerActive ? 0.58 : 1.0;
    self.inputContainer.accessibilityHint = composerActive
        ? @"Finish editing the open document to use chat input."
        : nil;
}

- (void)consumePendingExternalImageEdit {
    NSString *path = [[NSUserDefaults standardUserDefaults] stringForKey:@"EZPendingExternalImageEditPath"];
    if (!path.length || ![[NSFileManager defaultManager] fileExistsAtPath:path]) return;
    [[NSNotificationCenter defaultCenter] postNotificationName:EZEditImageInChat
                                                        object:nil
                                                      userInfo:@{ @"filePath": path }];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Gallery recovery
// ─────────────────────────────────────────────────────────────────────────────

- (void)recoverUndeliveredGalleryImagesIfNeeded {
    static BOOL recoveryInFlight = NO;
    if (recoveryInFlight) return;
    NSString *userID = [EZAuthManager shared].userId;
    if (!userID.length) return;

    NSString *manifestKey = [@"EZRecoveredRemoteImagePaths." stringByAppendingString:userID];
    NSSet<NSString *> *knownPaths = [NSSet setWithArray:
        [[NSUserDefaults standardUserDefaults] arrayForKey:manifestKey] ?: @[]];
    recoveryInFlight = YES;
    __weak typeof(self) weakSelf = self;
    [[EZAuthManager shared] getValidAccessToken:^(NSString *token, NSError *tokenError) {
        if (!token.length) { recoveryInFlight = NO; return; }
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:
            @"%@/functions/v1/recover-user-images", EZSupabaseURL]];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.HTTPMethod = @"POST";
        request.timeoutInterval = 45.0;
        [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{ @"known_paths": knownPaths.allObjects }
                                                                 options:0 error:nil];
        [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:
          ^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error || !data) { recoveryInFlight = NO; return; }
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSArray<NSDictionary *> *images = [json[@"images"] isKindOfClass:[NSArray class]] ? json[@"images"] : @[];
            if (images.count == 0) { recoveryInFlight = NO; return; }

            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                NSMutableSet<NSString *> *claimed = [knownPaths mutableCopy];
                NSMutableArray<NSData *> *existingData = [NSMutableArray array];
                for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:EZPhotoGalleryDirectory() error:nil]) {
                    NSData *localData = [NSData dataWithContentsOfFile:[EZPhotoGalleryDirectory() stringByAppendingPathComponent:name]];
                    if (localData.length) [existingData addObject:localData];
                }

                NSUInteger restored = 0;
                for (NSDictionary *entry in images) {
                    NSString *remotePath = [entry[@"path"] isKindOfClass:[NSString class]] ? entry[@"path"] : nil;
                    NSString *signedURL = [entry[@"url"] isKindOfClass:[NSString class]] ? entry[@"url"] : nil;
                    if (!remotePath.length || !signedURL.length || [claimed containsObject:remotePath]) continue;
                    NSData *remoteData = [NSData dataWithContentsOfURL:[NSURL URLWithString:signedURL]];
                    if (!remoteData.length || ![UIImage imageWithData:remoteData]) continue;

                    BOOL alreadyLocal = NO;
                    for (NSData *localData in existingData) {
                        if (localData.length == remoteData.length && [localData isEqualToData:remoteData]) {
                            alreadyLocal = YES;
                            break;
                        }
                    }
                    if (!alreadyLocal) {
                        NSString *name = remotePath.lastPathComponent.length ? remotePath.lastPathComponent : @"recovered-image.png";
                        NSString *savedPath = EZPhotoGallerySave(remoteData, name);
                        if (savedPath) {
                            [existingData addObject:remoteData];
                            restored++;
                        }
                    }
                    // Mark both restored and already-present images as claimed.
                    // Future app launches therefore do not redownload them.
                    [claimed addObject:remotePath];
                }
                [[NSUserDefaults standardUserDefaults] setObject:claimed.allObjects forKey:manifestKey];
                recoveryInFlight = NO;
                if (restored > 0) {
                    EZLogf(EZLogLevelInfo, @"GALLERY", @"Recovered %lu undelivered image(s) from cloud storage", (unsigned long)restored);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [weakSelf updateCoinBalanceDisplay];
                    });
                }
            });
        }] resume];
    }];
}

- (void)setupData {
    // Model list — internal identifiers, must match real OpenAI API model
    // strings exactly (not ChatGPT subscription tier names — see the isGPT5
    // comment in callChatCompletions for why that distinction matters).
    // Display labels are added downstream in EZModelPickerViewController,
    // which takes this array as-is.
    self.models = @[
           // ── Chat / Reasoning ──────────────────────────────────────────────
           @"gpt-6-astra", // newest flagship reasoning model
           @"gpt-5.6-sol", @"gpt-5.6-terra", @"gpt-5.6-luna",
           @"gpt-5-pro", @"gpt-5", @"gpt-5-mini",
           @"gpt-4o", @"gpt-4o-mini", @"gpt-4-turbo", @"gpt-4",
           @"gpt-3.5-turbo",
           // ── Image Generation & Edit ───────────────────────────────────────
           @"gpt-image-2.5-flare",    // newest, fastest — low/medium/high/xhigh/max
           @"gpt-image-2.5-sunburst", // precision editing — low/medium/high/xhigh/max
           @"gpt-image-2",          // low/medium/high only
           @"gpt-image-1.5",
           @"gpt-image-1",          // generation + edit
           @"gpt-image-1-mini",     // faster/cheaper image generation
           @"chatgpt-image-latest", // always points to current ChatGPT image model
        // ── Video ─────────────────────────────────────────────────────────
        // SORA — commented out, not deleted. User removed Sora from Settings;
        // OpenAI's Sora API is also scheduled for shutdown 2026-09-24
        // regardless. See the big commented block near callSora's old
        // implementation for the full story on why this stayed as a comment
        // instead of getting deleted outright.
        // @"sora-2", @"sora-2-pro",
        // ── Audio ─────────────────────────────────────────────────────────
        @"whisper-1"
    ];
    self.chatContext        = [NSMutableArray array];
    self.pendingImagePaths  = [NSMutableArray array];
    self.pendingFiles       = [NSMutableArray array];
    self.displayMessages    = [NSMutableArray array];
    self.speechSynthesizer = [[AVSpeechSynthesizer alloc] init];
    self.selectedModel     = [[NSUserDefaults standardUserDefaults] stringForKey:@"selectedModel"]
                             ?: self.models[0];
    self.webSearchEnabled  = [[NSUserDefaults standardUserDefaults] boolForKey:@"webSearchEnabled"];

    // Triage re-evaluates uncertain prompts with this many prior turns.
    // Store an explicit initial value so both the control and helpers.m agree
    // that a fresh install starts at three rather than NSUserDefaults' zero.
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:@"TriageUncertainTurns"] == nil) {
        [defaults setInteger:3 forKey:@"TriageUncertainTurns"];
    }
    if ([defaults objectForKey:@"HelperDirectAnswersEnabled"] == nil) {
        [defaults setBool:YES forKey:@"HelperDirectAnswersEnabled"];
    }

    // Restore persisted image/attachment paths so they survive app restarts.
    // This is the key fix for "reopen image" failing — lastImageLocalPath was
    // always nil after relaunch, so the intent check fell through to generation.
    NSUserDefaults *d = defaults;
    NSString *savedImagePath = [d stringForKey:@"lastImageLocalPath"];
    if (savedImagePath.length > 0 &&
        [[NSFileManager defaultManager] fileExistsAtPath:savedImagePath]) {
        self.lastImageLocalPath = savedImagePath;
        EZLogf(EZLogLevelInfo, @"APP", @"Restored lastImageLocalPath: %@",
               savedImagePath.lastPathComponent);
    }
    NSString *savedPrompt = [d stringForKey:@"lastImagePrompt"];
    if (savedPrompt.length > 0) {
        self.lastImagePrompt = savedPrompt;
    }

    [self startNewThread];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Thread Management
// ─────────────────────────────────────────────────────────────────────────────

- (void)startNewThread {
    EZChatThread *t = [[EZChatThread alloc] init];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat       = @"yyyy-MM-dd'T'HH:mm:ss";
    fmt.locale           = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    t.threadID           = [fmt stringFromDate:[NSDate date]];
    t.modelName          = self.selectedModel;
    t.chatContext        = @[];
    t.attachmentPaths    = @[];
    self.activeThread    = t;
    EZLogf(EZLogLevelInfo, @"THREAD", @"New thread: %@", t.threadID);
}

- (void)saveActiveThread {
    if (!self.activeThread || self.chatContext.count == 0) return;

    // Sync chatContext into thread before saving
    self.activeThread.chatContext = [self.chatContext copy];
    self.activeThread.modelName   = self.selectedModel;

    // Set title from first user message if not set.
    // Strip Tier-3 context preamble if present — we want the raw user question, not the injected context.
    if ([self.activeThread.title isEqualToString:@"New Conversation"] ||
        self.activeThread.title.length == 0) {
        for (NSDictionary *msg in self.chatContext) {
            if ([msg[@"role"] isEqualToString:@"user"]) {
                id content = msg[@"content"];
                NSString *text = @"";

                if ([content isKindOfClass:[NSString class]]) {
                    text = content;
                } else if ([content isKindOfClass:[NSArray class]]) {
                    // Vision attachment: extract text block, or fall back to filename
                    for (NSDictionary *block in (NSArray *)content) {
                        NSString *t = block[@"text"];
                        if (t.length > 0 &&
                            ![t isEqualToString:@"[image attached \u2014 await user question]"]) {
                            text = t;
                            break;
                        }
                    }
                    if (text.length == 0) {
                        // No text block — use the attachment filename as the title
                        NSString *fname = self.activeThread.attachmentPaths.lastObject.lastPathComponent;
                        text = fname.length > 0
                            ? [@"Attachment: " stringByAppendingString:fname]
                            : @"[Attachment]";
                    }
                }

                // Strip Tier-3 context preamble
                NSString *contextPrefix = @"[Memories with possible relevance:]";
                if ([text hasPrefix:contextPrefix]) {
                    NSRange userMsgRange = [text rangeOfString:@"[User message]\n"];
                    if (userMsgRange.location != NSNotFound) {
                        text = [text substringFromIndex:userMsgRange.location + userMsgRange.length];
                    } else { continue; }
                }

                text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (text.length == 0) continue;
                self.activeThread.title = text.length > 60
                    ? [[text substringToIndex:60] stringByAppendingString:@"\u2026"]
                    : text;
                break;
            }
        }
    }
    // Carry last image path if any
    if (self.lastImageLocalPath) self.activeThread.lastImageLocalPath = self.lastImageLocalPath;

    // Keep visible label in sync whenever the title gets auto-derived
    dispatch_async(dispatch_get_main_queue(), ^{ [self updateThreadTitleLabel]; });
    EZThreadSave(self.activeThread, nil);
    EZLogf(EZLogLevelInfo, @"THREAD", @"Saved: %@", self.activeThread.threadID);
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ChatHistoryViewControllerDelegate
// ─────────────────────────────────────────────────────────────────────────────

- (void)chatHistoryDidSelectThread:(EZChatThread *)thread {
    [self closeDrawer];
    [self.chatContext removeAllObjects];
    [self.chatContext addObjectsFromArray:thread.chatContext];
    [self.displayMessages removeAllObjects];

    self.activeThread       = thread;
    self.selectedModel      = thread.modelName ?: self.selectedModel;
    self.lastImageLocalPath = thread.lastImageLocalPath;
    self.lastUserPrompt     = nil;
    self.lastAIResponse     = nil;
    [self.pendingFiles removeAllObjects];
    [self.pendingImagePaths removeAllObjects];

    [self.modelButton setTitle:[NSString stringWithFormat:@"Model: %@", self.selectedModel]
                      forState:UIControlStateNormal];

    // Rebuild display messages from saved context
    for (NSDictionary *msg in self.chatContext) {
        NSString *role    = msg[@"role"] ?: @"";
        id        content = msg[@"content"];
        NSString *text    = [content isKindOfClass:[NSString class]] ? content : nil;

        // Image-generation results are UI-only timeline events.  Keeping them
        // in the thread (rather than a separate UserDefaults side cache) is
        // what preserves their exact position among chat messages.
        if ([role isEqualToString:@"_ui_imagegrid"]) {
            id rawPaths = msg[@"imagePaths"];
            NSMutableArray<NSString *> *validPaths = [NSMutableArray array];
            if ([rawPaths isKindOfClass:[NSArray class]]) {
                for (id rawPath in (NSArray *)rawPaths) {
                    if (![rawPath isKindOfClass:[NSString class]]) continue;
                    NSString *path = EZAttachmentPath(rawPath);
                    if (path.length > 0) [validPaths addObject:path];
                }
            }
            BOOL isError = [msg[@"isError"] boolValue];
            if (validPaths.count > 0 || isError) {
                NSMutableDictionary *entry = [@{
                    @"role": @"imagegrid",
                    @"imagePaths": [validPaths copy],
                    @"prompt": msg[@"prompt"] ?: @"",
                    @"isError": @(isError),
                } mutableCopy];
                if (msg[@"errorText"]) entry[@"errorText"] = msg[@"errorText"];
                [self.displayMessages addObject:[entry copy]];
            }
            continue;
        }

        if (!text && [content isKindOfClass:[NSArray class]] && [role isEqualToString:@"user"]) {
            // Vision attachment (image_url + text blocks) — previously
            // skipped entirely on restore ("skip vision attachment blobs"),
            // which is why attached images vanished on reload. The full
            // base64 data survives here regardless of how many turns have
            // passed (see ez_recoverImagePathsFromVisionContent's own
            // comment on why), so every attachment in the thread is
            // recoverable, not just the most recent one.
            NSArray<NSString *> *recovered =
                [self ez_recoverImagePathsFromVisionContent:(NSArray *)content];
            for (NSString *path in recovered) [self appendAttachmentBubble:path];

            // If there was a real question alongside the image (not just
            // the "[image attached — await user question]" placeholder),
            // show it as a normal bubble right after, same as it looked
            // originally.
            for (NSDictionary *block in (NSArray *)content) {
                NSString *blockText = block[@"text"];
                if (blockText.length > 0 &&
                    ![blockText isEqualToString:@"[image attached — await user question]"]) {
                    [self appendToChat:[NSString stringWithFormat:@"You: %@", blockText]];
                    break;
                }
            }
            continue;
        }
        if (!text) continue;

        if ([role isEqualToString:@"user"]) {
            if ([text hasPrefix:@"[Memories with possible relevance:]"]) {
                NSRange r = [text rangeOfString:@"[User message]\n"];
                if (r.location != NSNotFound) text = [text substringFromIndex:r.location + r.length];
            }
            text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (text.length > 0) [self appendToChat:[NSString stringWithFormat:@"You: %@", text]];
        } else if ([role isEqualToString:@"assistant"]) {
            self.lastAIResponse = text;
            if ([text containsString:@"```"]) {
                NSMutableArray *cp = [NSMutableArray array];
                NSString *processed = [self processReplyWithCodeBlocks:text savedPaths:cp isRestore:YES];
                [self appendToChat:[NSString stringWithFormat:@"AI: %@", processed]];
            } else {
                [self appendToChat:[NSString stringWithFormat:@"AI: %@", text]];
            }
        }
    }

    // Restore only old, side-cache image grids now. Newer grids above came
    // from their ordered thread events. Doing this before the attachment
    // fallback lets the fallback avoid duplicating generated output as a lone
    // attachment bubble.
    [self restoreImageGridCellsForThread:thread.threadID];

    // Best-effort fallback for edit-mode attachments from BEFORE this fix —
    // those never got added to chatContext at all (see
    // enterImageEditModeFromCurrentSelection / attachImage:'s history), so
    // there's nothing to recover above. attachmentPaths is the only trace
    // that exists for them. This can't know exactly where in the
    // conversation each one belonged — attachmentPaths is a flat,
    // unordered-relative-to-messages list — so anything not already shown
    // above gets surfaced together near the top with an honest label
    // rather than pretending to place it precisely. Threads saved after
    // this fix won't need this path — edit-mode attachments now get a real
    // chatContext entry same as any other attachment.
    NSMutableSet<NSString *> *alreadyShown = [NSMutableSet set];
    for (NSDictionary *m in self.displayMessages) {
        if ([m[@"role"] isEqualToString:@"attachment"]) {
            [alreadyShown addObject:[m[@"imagePath"] lastPathComponent] ?: @""];
        } else if ([m[@"role"] isEqualToString:@"imagegrid"]) {
            for (NSString *path in m[@"imagePaths"] ?: @[]) {
                [alreadyShown addObject:path.lastPathComponent ?: @""];
            }
        }
    }
    NSMutableArray<NSString *> *unaccountedFor = [NSMutableArray array];
    for (NSString *path in self.activeThread.attachmentPaths) {
        NSString *ext = [path.pathExtension lowercaseString];
        BOOL isImage = [ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"] || [ext isEqualToString:@"png"];
        NSString *resolvedPath = EZAttachmentPath(path);
        if (isImage && ![alreadyShown containsObject:path.lastPathComponent]
                    && resolvedPath.length > 0) {
            [unaccountedFor addObject:resolvedPath];
        }
    }
    if (unaccountedFor.count > 0) {
        [self appendToChat:[NSString stringWithFormat:
            @"[System: %lu older attachment(s) restored — exact position in the "
            @"conversation couldn't be recovered]", (unsigned long)unaccountedFor.count]];
        for (NSString *path in unaccountedFor) [self appendAttachmentBubble:path];
    }

    [self appendToChat:[NSString stringWithFormat:@"[System: Thread \"%@\" restored ✓]", thread.title]];
    [self scrollChatToBottom];
    [self updateThreadTitleLabel];
    EZLogf(EZLogLevelInfo, @"THREAD", @"Restored: %@ (%lu turns)",
           thread.threadID, (unsigned long)self.chatContext.count);
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - EZOpenChatThread notification (from MemoriesViewController)
// ─────────────────────────────────────────────────────────────────────────────

/// Handles the "EZOpenChatThread" notification posted by MemoriesViewController
/// when the user taps a memory's timestamp label.
///
/// userInfo[@"threadID"] is the stem of the thread filename WITHOUT the .json
/// extension, using dashes for the time component, e.g. "2026-04-05T14-29-20".
/// EZChatThread.threadID uses colons internally ("2026-04-05T14:29:20"), so we
/// normalise before calling EZThreadLoad.
- (void)handleOpenChatThread:(NSNotification *)notification {
    NSString *rawID = notification.userInfo[@"threadID"];
    if (!rawID.length) {
        EZLog(EZLogLevelWarning, @"THREAD", @"handleOpenChatThread: missing threadID");
        return;
    }

    // Normalise: the memory helper emits "yyyy-MM-dd'T'HH-mm-ss" (dashes in
    // the time part).  EZChatThread.threadID and EZThreadLoad expect colons.
    // Replace only the time-separator dashes (after the 'T') with colons.
    NSString *threadID = rawID;
    NSRange tRange = [rawID rangeOfString:@"T"];
    if (tRange.location != NSNotFound) {
        NSString *datePart = [rawID substringToIndex:tRange.location + 1]; // "yyyy-MM-ddT"
        NSString *timePart = [rawID substringFromIndex:tRange.location + 1]; // "HH-mm-ss"
        timePart  = [timePart stringByReplacingOccurrencesOfString:@"-" withString:@":"];
        threadID  = [datePart stringByAppendingString:timePart];
    }

    EZLogf(EZLogLevelInfo, @"THREAD", @"Opening thread from memory tap: %@", threadID);

    // Save current work before switching away
    [self saveActiveThread];

    // Load the requested thread via the helpers API
    EZChatThread *thread = EZThreadLoad(threadID);
    if (!thread) {
        EZLogf(EZLogLevelWarning, @"THREAD", @"EZThreadLoad returned nil for: %@", threadID);
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *a = [UIAlertController
                alertControllerWithTitle:@"Thread Not Found"
                                 message:[NSString stringWithFormat:
                                    @"Could not load thread %@ \n\nThe file may have been deleted.", threadID]
                          preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
        });
        return;
    }

    // Hand off to the existing delegate method which rebuilds the full UI
    dispatch_async(dispatch_get_main_queue(), ^{
        [self chatHistoryDidSelectThread:thread];
    });
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Shake → Stats
// ─────────────────────────────────────────────────────────────────────────────

- (BOOL)canBecomeFirstResponder { return YES; }

- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    if (motion == UIEventSubtypeMotionShake) {
        HelperLogViewController *helperLogVC = [[HelperLogViewController alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:helperLogVC];
        nav.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:nav animated:YES completion:nil];
        /*
        NSString *stats = EZHelperStats();
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"EZHelper Stats"
                                                                   message:stats
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            [UIPasteboard generalPasteboard].string = stats;
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
         */
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Dictation
// ─────────────────────────────────────────────────────────────────────────────

- (void)setupDictation {
    self.speechRecognizer = [[SFSpeechRecognizer alloc]
        initWithLocale:[NSLocale localeWithLocaleIdentifier:@"en-US"]];
    self.speechRecognizer.delegate = self;
    self.audioEngine = [[AVAudioEngine alloc] init];
    self.isDictating = NO;
}

/// Request both speech recognition and microphone permissions upfront
/// so they appear in Privacy settings and don't surprise the user mid-tap.
- (void)requestSpeechPermissionsIfNeeded {
    // Only prompt if not yet determined
    if ([SFSpeechRecognizer authorizationStatus] == SFSpeechRecognizerAuthorizationStatusNotDetermined) {
        [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.dictateButton.enabled = (status == SFSpeechRecognizerAuthorizationStatusAuthorized);
                EZLogf(EZLogLevelInfo, @"DICTATE", @"Speech auth: %ld", (long)status);
            });
        }];
    }
    AVAuthorizationStatus micStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (micStatus == AVAuthorizationStatusNotDetermined) {
        [AVAudioSession.sharedInstance requestRecordPermission:^(BOOL granted) {
            EZLogf(EZLogLevelInfo, @"DICTATE", @"Mic permission: %@", granted ? @"granted" : @"denied");
        }];
    }
}

- (void)speechRecognizer:(SFSpeechRecognizer *)speechRecognizer availabilityDidChange:(BOOL)available {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.dictateButton.enabled = available;
        EZLogf(EZLogLevelDebug, @"DICTATE", @"Availability: %@", available ? @"YES" : @"NO");
    });
}

- (void)toggleDictation {
    if (self.isDictating) { [self stopDictation]; return; }
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (status == SFSpeechRecognizerAuthorizationStatusAuthorized) {
                [AVAudioSession.sharedInstance requestRecordPermission:^(BOOL granted) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (granted) [self startDictation];
                        else [self appendToChat:@"[Dictation Error]: Mic permission denied."];
                    });
                }];
            } else {
                [self appendToChat:@"[Dictation Error]: Speech recognition permission denied."];
            }
        });
    }];
}

- (void)startDictation {
    if (self.recognitionTask) { [self.recognitionTask cancel]; self.recognitionTask = nil; }
    NSError *err;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryRecord
                    mode:AVAudioSessionModeMeasurement
                 options:AVAudioSessionCategoryOptionDuckOthers error:&err];
    [session setActive:YES withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&err];
    if (err) { EZLogf(EZLogLevelError, @"DICTATE", @"Session: %@", err); return; }

    self.recognitionRequest = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
    self.recognitionRequest.shouldReportPartialResults = YES;
    AVAudioInputNode *inputNode = self.audioEngine.inputNode;
    __weak typeof(self) ws = self;
    self.recognitionTask = [self.speechRecognizer recognitionTaskWithRequest:self.recognitionRequest
        resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
        __strong typeof(ws) ss = ws; if (!ss) return;
        if (result) dispatch_async(dispatch_get_main_queue(), ^{
            [ss setInputText:result.bestTranscription.formattedString];
        });
        if (error || result.isFinal) {
            [ss.audioEngine stop]; [inputNode removeTapOnBus:0];
            ss.recognitionRequest = nil; ss.recognitionTask = nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                ss.isDictating = NO;
                [ss.dictateButton setTintColor:[UIColor systemBlueColor]];
            });
        }
    }];
    [inputNode installTapOnBus:0 bufferSize:1024 format:[inputNode outputFormatForBus:0]
                         block:^(AVAudioPCMBuffer *buf, AVAudioTime *when) {
        [self.recognitionRequest appendAudioPCMBuffer:buf];
    }];
    [self.audioEngine prepare];
    NSError *engineErr;
    [self.audioEngine startAndReturnError:&engineErr];
    if (engineErr) { EZLogf(EZLogLevelError, @"DICTATE", @"Engine: %@", engineErr); return; }
    self.isDictating = YES;
    [self.dictateButton setTintColor:[UIColor systemRedColor]];
    EZLog(EZLogLevelInfo, @"DICTATE", @"Started");
}

- (void)stopDictation {
    if (self.audioEngine.isRunning) { [self.audioEngine stop]; [self.recognitionRequest endAudio]; }
    self.isDictating = NO;
    [self.dictateButton setTintColor:[UIColor systemBlueColor]];
    EZLog(EZLogLevelInfo, @"DICTATE", @"Stopped");
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UI Setup
// ─────────────────────────────────────────────────────────────────────────────

- (void)setupUI {
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    // Top bar buttons
    // + New chat (save current, start fresh)
    self.addChatButton   = [self _iconButton:@"square.and.pencil" tint:[UIColor systemGreenColor]
                                      action:@selector(newChat)];
    self.supportRequestButton = [self _iconButton:@"questionmark.circle.fill" tint:[UIColor systemRedColor] action:@selector(openSupport)];
    // History (browse/restore past threads)
    self.historyButton   = [self _iconButton:@"clock.arrow.circlepath" tint:nil
                                      action:@selector(openHistory)];
    // Copy last AI response
    self.clipboardButton = [self _iconButton:@"doc.on.doc" tint:nil
                                      action:@selector(copyLastResponse)];
    // Speak last AI response
    self.speakButton     = [self _iconButton:@"speaker.wave.2.fill" tint:nil
                                      action:@selector(speakLastResponse)];

    
    self.cloningButton = [self _iconButton:@"doc.richtext" tint:nil action:@selector(openCloning)];
    
    self.galleryButton = [self _iconButton:@"photo.on.rectangle.angled" tint:nil action:@selector(openGallery)];
    self.brainRotButton = [self _iconButton:@"brain.head.profile" tint:nil action:@selector(openBrainRot)];

    self.textToSpeechButton = [self _iconButton:@"play.circle.fill" tint:nil action:@selector(openTTS)];

    self.memoriesButton   = [self _iconButton:@"memory" tint:nil
                                      action:@selector(openMemories)];
    // Web search toggle
    self.webSearchButton = [self _iconButton:@"globe" tint:nil
                                      action:@selector(toggleWebSearch)];
    [self updateWebSearchButtonTint];
    self.helperDirectAnswersButton = [self _iconButton:@"bolt.fill" tint:nil
                                                action:@selector(toggleHelperDirectAnswers)];
    self.helperDirectAnswersButton.accessibilityLabel = @"Helper direct answers";
    [self updateHelperDirectAnswersButton];
    // Settings
    self.settingsButton  = [self _iconButton:@"gearshape.fill" tint:nil
                                      action:@selector(openSettings)];
    // Trash = delete current chat (confirm) then start new one
    self.clearButton   = [self _iconButton:@"trash.fill" tint:[UIColor systemRedColor]
                                    action:@selector(deleteCurrentChat)];
    // Rename thread title
    self.renameButton  = [self _iconButton:@"pencil.line" tint:nil
                                    action:@selector(renameThread)];

    // Create Coin Pot placeholder used inside the top row
    self.coinPotView = [[EZCoinPotView alloc] init];
    self.coinPotView.coinImage = [UIImage imageNamed:@"EZCoin"];
    self.coinPotView.translatesAutoresizingMaskIntoConstraints = NO;
    self.coinPotView.userInteractionEnabled = YES;
    UITapGestureRecognizer *potTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(coinPotTapped)];
    [self.coinPotView addGestureRecognizer:potTap];

    // Full-width stack — equalSpacing distributes buttons edge to edge
    UIStackView *topStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.addChatButton, self.historyButton, self.clipboardButton,
        self.speakButton, self.webSearchButton, self.helperDirectAnswersButton, self.coinPotView,
        self.renameButton, self.clearButton, self.memoriesButton, self.cloningButton, self.supportRequestButton,
        self.textToSpeechButton, self.galleryButton]];
    topStack.distribution = UIStackViewDistributionEqualSpacing;
    topStack.alignment    = UIStackViewAlignmentCenter;
    topStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:topStack];

    [NSLayoutConstraint activateConstraints:@[
        [self.coinPotView.widthAnchor constraintEqualToConstant:48],
        [self.coinPotView.heightAnchor constraintEqualToConstant:52],
    ]];
    [self.coinPotView setContentHuggingPriority:UILayoutPriorityRequired
                                        forAxis:UILayoutConstraintAxisHorizontal];
    [self.coinPotView setContentHuggingPriority:UILayoutPriorityRequired
                                        forAxis:UILayoutConstraintAxisVertical];

    // Legacy label — hidden, kept so any remaining references don't crash
    self.coinBalanceLabel = [[UILabel alloc] init];
    self.coinBalanceLabel.hidden = YES;
    self.coinBalanceLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.coinBalanceLabel];

    // Thread title label — tappable, sits between top bar and chat table
    self.threadTitleLabel                 = [[UILabel alloc] init];
    self.threadTitleLabel.text            = @"New Conversation";
    self.threadTitleLabel.font            = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    self.threadTitleLabel.textColor       = [UIColor secondaryLabelColor];
    self.threadTitleLabel.textAlignment   = NSTextAlignmentCenter;
    self.threadTitleLabel.userInteractionEnabled = YES;
    self.threadTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    UITapGestureRecognizer *titleTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(renameThread)];
    [self.threadTitleLabel addGestureRecognizer:titleTap];
    [self.view addSubview:self.threadTitleLabel];

    // Chat table view — each message is a bubble, system, or code cell
    self.chatTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.chatTableView.dataSource         = self;
    self.chatTableView.delegate           = self;
    self.chatTableView.separatorStyle     = UITableViewCellSeparatorStyleNone;
    self.chatTableView.backgroundColor    = [UIColor systemBackgroundColor];
    self.chatTableView.estimatedRowHeight = 60;
    self.chatTableView.rowHeight          = UITableViewAutomaticDimension;
    self.chatTableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.chatTableView registerClass:[EZBubbleCell class]    forCellReuseIdentifier:@"EZBubble"];
    [self.chatTableView registerClass:[EZSystemCell class]    forCellReuseIdentifier:@"EZSystem"];
    [self.chatTableView registerClass:[EZCodeBlockCell class] forCellReuseIdentifier:@"EZCodeBlock"];
    [self.chatTableView registerClass:[EZImageGridCell class] forCellReuseIdentifier:@"EZImageGrid"];
    [self.chatTableView registerClass:[EZAttachmentPreviewCell class] forCellReuseIdentifier:@"EZAttachment"];
    [self.view addSubview:self.chatTableView];

    self.statusBannerView = [[UIView alloc] init];
    self.statusBannerView.backgroundColor = [UIColor colorWithDynamicProvider:
        ^UIColor *(UITraitCollection *tc) {
            return tc.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithRed:0.12 green:0.12 blue:0.16 alpha:0.96]
                : [UIColor colorWithRed:0.95 green:0.95 blue:0.98 alpha:0.97];
        }];
    self.statusBannerView.layer.cornerRadius = 10;
    self.statusBannerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusBannerView.alpha = 0;
    [self.view addSubview:self.statusBannerView];
    self.statusBannerSpinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.statusBannerSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusBannerSpinner.hidesWhenStopped = NO;
    [self.statusBannerView addSubview:self.statusBannerSpinner];
    self.statusBannerLabel = [[UILabel alloc] init];
    self.statusBannerLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    self.statusBannerLabel.textColor = [UIColor secondaryLabelColor];
    self.statusBannerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.statusBannerView addSubview:self.statusBannerLabel];

    // Input container
    self.inputContainer = [[UIView alloc] init];
    self.inputContainer.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.inputContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.inputContainer];
    
        // Dictate button
        self.dictateButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [self.dictateButton setImage:[UIImage systemImageNamed:@"mic.fill"] forState:UIControlStateNormal];
        [self.dictateButton setTintColor:[UIColor systemBlueColor]];
        [self.dictateButton addTarget:self action:@selector(toggleDictation)
                     forControlEvents:UIControlEventTouchUpInside];
        self.dictateButton.translatesAutoresizingMaskIntoConstraints = NO;
        [self.inputContainer addSubview:self.dictateButton];

    // Model picker button
    self.modelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.modelButton setTitle:[NSString stringWithFormat:@"Model: %@", self.selectedModel]
                      forState:UIControlStateNormal];
    [self.modelButton addTarget:self action:@selector(showModelPicker)
                forControlEvents:UIControlEventTouchUpInside];
    self.modelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.inputContainer addSubview:self.modelButton];

    // Attach button
    self.attachButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.attachButton setImage:[UIImage systemImageNamed:@"paperclip.circle.fill"]
                       forState:UIControlStateNormal];
    [self.attachButton addTarget:self action:@selector(showAttachMenu)
                forControlEvents:UIControlEventTouchUpInside];
    self.attachButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.inputContainer addSubview:self.attachButton];

    

    // Message input — UITextView so it can expand to multiple lines.
    // Wrapped in a rounded container view to replicate UITextBorderStyleRoundedRect look.
    UIView *inputWrapper = [[UIView alloc] init];
    inputWrapper.backgroundColor   = [UIColor systemBackgroundColor];
    inputWrapper.layer.cornerRadius = 10.0;
    inputWrapper.layer.borderWidth  = 1.5;
    inputWrapper.layer.borderColor  = [UIColor separatorColor].CGColor;
    inputWrapper.clipsToBounds      = YES;
    inputWrapper.translatesAutoresizingMaskIntoConstraints = NO;

    self.messageTextField = [[UITextView alloc] init];
    self.messageTextField.font                  = [UIFont systemFontOfSize:16];
    self.messageTextField.textColor             = [UIColor labelColor];
    self.messageTextField.backgroundColor       = [UIColor clearColor];
    self.messageTextField.textContainerInset    = UIEdgeInsetsMake(8, 6, 8, 6);
    self.messageTextField.textContainer.lineFragmentPadding = 0;
    self.messageTextField.scrollEnabled         = YES;
    self.messageTextField.delegate              = self;
    self.messageTextField.returnKeyType         = UIReturnKeyDefault;
    self.messageTextField.translatesAutoresizingMaskIntoConstraints = NO;
    
    self.messageTextField.layer.cornerRadius = 10;
    self.messageTextField.layer.masksToBounds = YES;
    self.messageTextField.layer.borderColor = [UIColor secondaryLabelColor].CGColor;

    // Placeholder label — UITextView has no built-in placeholder
    UILabel *placeholder = [[UILabel alloc] init];
    placeholder.text      = @"Type message...";
    placeholder.font      = [UIFont systemFontOfSize:16];
    placeholder.textColor = [UIColor placeholderTextColor];
    placeholder.tag       = 9001;   // retrieved to show/hide as user types
    placeholder.translatesAutoresizingMaskIntoConstraints = NO;
    [self.messageTextField addSubview:placeholder];
    [NSLayoutConstraint activateConstraints:@[
        [placeholder.leadingAnchor  constraintEqualToAnchor:self.messageTextField.leadingAnchor  constant:10],
        [placeholder.topAnchor      constraintEqualToAnchor:self.messageTextField.topAnchor      constant:9],
    ]];

    [inputWrapper addSubview:self.messageTextField];
    [NSLayoutConstraint activateConstraints:@[
        [self.messageTextField.topAnchor      constraintEqualToAnchor:inputWrapper.topAnchor],
        [self.messageTextField.bottomAnchor   constraintEqualToAnchor:inputWrapper.bottomAnchor],
        [self.messageTextField.leadingAnchor  constraintEqualToAnchor:inputWrapper.leadingAnchor],
        [self.messageTextField.trailingAnchor constraintEqualToAnchor:inputWrapper.trailingAnchor],
    ]];
    [self.inputContainer addSubview:inputWrapper];

    // Store inputWrapper so constraints can reference it below
    inputWrapper.tag = 9002;

    // Send button
    self.sendButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.sendButton setTitle:@"Send" forState:UIControlStateNormal];
    [self.sendButton addTarget:self action:@selector(handleSend)
              forControlEvents:UIControlEventTouchUpInside];
    self.sendButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.inputContainer addSubview:self.sendButton];
    self.inputContainer.backgroundColor = [UIColor colorWithRed:0 green:0.44 blue:0.34 alpha:0.8];
    self.inputContainer.layer.borderWidth = 2.0;
    self.inputContainer.layer.borderColor = [UIColor secondaryLabelColor].CGColor;
    self.inputContainer.layer.masksToBounds = YES;
    self.inputContainer.layer.cornerRadius = 10.0;

    [self.sendButton setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                     forAxis:UILayoutConstraintAxisHorizontal];
    [self.messageTextField setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                           forAxis:UILayoutConstraintAxisHorizontal];

    // Image settings button — only visible when an image model is selected
    self.imageSettingsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.imageSettingsButton setImage:[UIImage systemImageNamed:@"slider.horizontal.3"]
                              forState:UIControlStateNormal];
    [self.imageSettingsButton addTarget:self action:@selector(showImageSettings)
                      forControlEvents:UIControlEventTouchUpInside];
    self.imageSettingsButton.hidden = YES; // shown when image model active
    self.imageSettingsButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.inputContainer addSubview:self.imageSettingsButton];

    // Compact triage-turn control in the input container's upper-right.
    // Its numeric label makes the stepper's current value visible at a glance.
    self.triageUncertainTurnsLabel = [[UILabel alloc] init];
    self.triageUncertainTurnsLabel.font =
        [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold];
    self.triageUncertainTurnsLabel.textAlignment = NSTextAlignmentRight;
    self.triageUncertainTurnsLabel.textColor = [UIColor secondaryLabelColor];
    self.triageUncertainTurnsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.inputContainer addSubview:self.triageUncertainTurnsLabel];

    NSInteger triageTurns = [[NSUserDefaults standardUserDefaults]
        integerForKey:@"TriageUncertainTurns"];
    triageTurns = MAX(0, MIN(15, triageTurns));
    self.triageUncertainTurnsStepper = [[UIStepper alloc] init];
    self.triageUncertainTurnsStepper.minimumValue = 0;
    self.triageUncertainTurnsStepper.maximumValue = 15;
    self.triageUncertainTurnsStepper.stepValue = 1;
    self.triageUncertainTurnsStepper.value = MAX(0, MIN(15, triageTurns));
    self.triageUncertainTurnsStepper.accessibilityLabel =
        @"Turns for uncertain triage";
    self.triageUncertainTurnsStepper.translatesAutoresizingMaskIntoConstraints = NO;
    [self.triageUncertainTurnsStepper addTarget:self
                                         action:@selector(triageUncertainTurnsChanged:)
                               forControlEvents:UIControlEventValueChanged];
    [self.inputContainer addSubview:self.triageUncertainTurnsStepper];
    self.triageUncertainTurnsLabel.text = [NSString stringWithFormat:@"%ld", (long)triageTurns];

    self.containerBottomConstraint =
        [self.inputContainer.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor];

    [NSLayoutConstraint activateConstraints:@[
        [topStack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:5],
        [topStack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [topStack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.threadTitleLabel.topAnchor    constraintEqualToAnchor:topStack.bottomAnchor constant:4],
        [self.threadTitleLabel.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.threadTitleLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.chatTableView.topAnchor constraintEqualToAnchor:self.threadTitleLabel.bottomAnchor constant:52],
        [self.chatTableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.chatTableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.chatTableView.bottomAnchor constraintEqualToAnchor:self.inputContainer.topAnchor],
        [self.inputContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.inputContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        self.containerBottomConstraint,
        [self.modelButton.topAnchor constraintEqualToAnchor:self.inputContainer.topAnchor constant:8],
        [self.modelButton.leadingAnchor constraintEqualToAnchor:self.inputContainer.leadingAnchor constant:12],
        [self.imageSettingsButton.centerYAnchor constraintEqualToAnchor:self.modelButton.centerYAnchor],
        [self.imageSettingsButton.leadingAnchor constraintEqualToAnchor:self.modelButton.trailingAnchor constant:8],
        [self.imageSettingsButton.widthAnchor constraintEqualToConstant:32],
        [self.imageSettingsButton.heightAnchor constraintEqualToConstant:32],
        [self.triageUncertainTurnsStepper.trailingAnchor constraintEqualToAnchor:self.inputContainer.trailingAnchor constant:-12],
        [self.triageUncertainTurnsStepper.centerYAnchor constraintEqualToAnchor:self.modelButton.centerYAnchor],
        [self.triageUncertainTurnsLabel.trailingAnchor constraintEqualToAnchor:self.triageUncertainTurnsStepper.leadingAnchor constant:-4],
        [self.triageUncertainTurnsLabel.centerYAnchor constraintEqualToAnchor:self.triageUncertainTurnsStepper.centerYAnchor],
        [self.triageUncertainTurnsLabel.widthAnchor constraintEqualToConstant:24],
        [self.modelButton.trailingAnchor constraintLessThanOrEqualToAnchor:self.triageUncertainTurnsLabel.leadingAnchor constant:-6],
        [self.imageSettingsButton.trailingAnchor constraintLessThanOrEqualToAnchor:self.triageUncertainTurnsLabel.leadingAnchor constant:-6],
        [self.attachButton.leadingAnchor constraintEqualToAnchor:self.inputContainer.leadingAnchor constant:12],
        [self.attachButton.topAnchor constraintEqualToAnchor:self.modelButton.bottomAnchor constant:12],
        [self.dictateButton.leadingAnchor constraintEqualToAnchor:self.attachButton.trailingAnchor constant:6],
        [self.dictateButton.centerYAnchor constraintEqualToAnchor:self.attachButton.centerYAnchor],
        [inputWrapper.leadingAnchor constraintEqualToAnchor:self.dictateButton.trailingAnchor constant:8],
        [inputWrapper.topAnchor     constraintEqualToAnchor:self.attachButton.topAnchor],
        [inputWrapper.trailingAnchor constraintEqualToAnchor:self.sendButton.leadingAnchor constant:-8],
        [self.sendButton.trailingAnchor constraintEqualToAnchor:self.inputContainer.trailingAnchor constant:-12],
        [self.sendButton.centerYAnchor constraintEqualToAnchor:inputWrapper.centerYAnchor],
        [self.inputContainer.bottomAnchor constraintEqualToAnchor:inputWrapper.bottomAnchor constant:12],
    ]];
    // Collapsed height: ~2 lines (72pt). Expanded: ~4 lines (136pt).
    // The constraint is animated in textViewDidBeginEditing / textViewDidEndEditing.
    self.messageInputHeightConstraint = [inputWrapper.heightAnchor constraintEqualToConstant:72.0];
    self.messageInputHeightConstraint.active = YES;

    [NSLayoutConstraint activateConstraints:@[
        [self.statusBannerView.bottomAnchor constraintEqualToAnchor:self.inputContainer.topAnchor constant:-8],
        [self.statusBannerView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.statusBannerView.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor constant:-32],
        [self.statusBannerSpinner.leadingAnchor constraintEqualToAnchor:self.statusBannerView.leadingAnchor constant:12],
        [self.statusBannerSpinner.centerYAnchor constraintEqualToAnchor:self.statusBannerView.centerYAnchor],
        [self.statusBannerLabel.leadingAnchor constraintEqualToAnchor:self.statusBannerSpinner.trailingAnchor constant:8],
        [self.statusBannerLabel.trailingAnchor constraintEqualToAnchor:self.statusBannerView.trailingAnchor constant:-12],
        [self.statusBannerLabel.topAnchor constraintEqualToAnchor:self.statusBannerView.topAnchor constant:10],
        [self.statusBannerLabel.bottomAnchor constraintEqualToAnchor:self.statusBannerView.bottomAnchor constant:-10],
    ]];

    // Tap anywhere outside the input field to dismiss the keyboard.
    // delegate set to self so gestureRecognizer:shouldReceiveTouch: can
    // prevent the gesture from firing on buttons (avoids a layout-animation
    // race that cancelled touchUpInside on the first send tap).
    UITapGestureRecognizer *dismissTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(dismissKeyboard)];
    dismissTap.cancelsTouchesInView = NO;
    dismissTap.delegate = self;
    [self.view addGestureRecognizer:dismissTap];
}

/// Persists the setting used by helpers.m when triage needs more conversation
/// context. The helper reloads this value at the start of every prompt.
- (void)triageUncertainTurnsChanged:(UIStepper *)sender {
    NSInteger turns = MAX(0, MIN(15, (NSInteger)sender.value));
    sender.value = turns;
    self.triageUncertainTurnsLabel.text =
        [NSString stringWithFormat:@"%ld", (long)turns];
    self.triageUncertainTurnsLabel.accessibilityLabel =
        [NSString stringWithFormat:@"%ld turns for uncertain triage", (long)turns];
    [[NSUserDefaults standardUserDefaults] setInteger:turns
                                               forKey:@"TriageUncertainTurns"];
    EZLogf(EZLogLevelInfo, @"TRIAGE", @"Uncertain triage turn count set to %ld", (long)turns);
}

- (UIButton *)_iconButton:(NSString *)sfSymbol tint:(nullable UIColor *)tint action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setImage:[UIImage systemImageNamed:sfSymbol] forState:UIControlStateNormal];
    if (tint) [b setTintColor:tint];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder]; return YES;
}

- (void)updateCoinBalanceDisplay {
    NSInteger balance      = [EZEntitlementManager shared].coinBalance.integerValue;
    NSString  *tier        = [EZEntitlementManager shared].currentTier ?: @"basic";
    NSInteger includedCoins = 400; // default basic

    NSDictionary *tierCoins = @{
        @"basic":    @(400),
        @"standard": @(900),
        @"pro":      @(1600),
        @"ultra":    @(2500),
    };
    NSNumber *included = tierCoins[tier.lowercaseString];
    if (included) includedCoins = included.integerValue;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.coinPotView updateBalance:balance
                          includedCoins:includedCoins
                               animated:YES];
        // Legacy label kept in sync in case anything still reads it
        self.coinBalanceLabel.text = [NSString stringWithFormat:@"🪙 %ld", (long)balance];
    });
}

- (void)coinPotTapped {
    [self presentCoinStoreForFeature:nil];
}

- (void)handleSubscriptionUpdated {
    NSInteger previousBalance = [EZEntitlementManager shared].coinBalance.integerValue;
    [[EZEntitlementManager shared] refreshBalanceWithCompletion:^(NSInteger newBalance) {
        NSInteger gained = newBalance - previousBalance;
        if (gained > 0) {
            [self animateCoinGain:gained newBalance:newBalance];
        } else {
            [self updateCoinBalanceDisplay];
        }
    }];
}

/// Called after coins are added (top-up or subscription) to play the toss animation
/// then update the pot fill level.
- (void)animateCoinGain:(NSInteger)coinsAdded newBalance:(NSInteger)newBalance {
    NSString  *tier         = [EZEntitlementManager shared].currentTier ?: @"basic";
    NSDictionary *tierCoins = @{
        @"basic":    @(400),
        @"standard": @(900),
        @"pro":      @(1600),
        @"ultra":    @(2500),
    };
    NSInteger includedCoins = [tierCoins[tier.lowercaseString] integerValue] ?: 400;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self.coinPotView animateCoinToss:coinsAdded completion:^{
            [self.coinPotView updateBalance:newBalance
                              includedCoins:includedCoins
                                   animated:YES];
        }];
    });
}


// ── UITextViewDelegate — expanding input ─────────────────────────────────────

- (void)textViewDidBeginEditing:(UITextView *)textView {
    if (textView != self.messageTextField) return;
    self.messageInputHeightConstraint.constant = 120.0;  //was 136
    [UIView animateWithDuration:0.25
                          delay:0
         usingSpringWithDamping:0.85
          initialSpringVelocity:0.3
                        options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ [self.view layoutIfNeeded]; }
                     completion:nil];
}

- (void)textViewDidEndEditing:(UITextView *)textView {
    if (textView != self.messageTextField) return;
    self.messageInputHeightConstraint.constant = 72.0;
    [UIView animateWithDuration:0.25
                          delay:0
         usingSpringWithDamping:0.85
          initialSpringVelocity:0.3
                        options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ [self.view layoutIfNeeded]; }
                     completion:nil];
}

- (void)textViewDidChange:(UITextView *)textView {
    if (textView != self.messageTextField) return;
    // Show/hide placeholder
    UILabel *ph = (UILabel *)[textView viewWithTag:9001];
    ph.hidden = textView.text.length > 0;
}

// Return key inserts a newline. Send button is the only send trigger.
- (BOOL)textView:(UITextView *)textView shouldChangeTextInRange:(NSRange)range
                                                replacementText:(NSString *)text {
    if (textView != self.messageTextField) return YES;
    return YES;
}

- (void)setInputText:(NSString *)text {
    self.messageTextField.text = text;
    // Keep placeholder in sync when text is set programmatically
    UILabel *ph = (UILabel *)[self.messageTextField viewWithTag:9001];
    if (ph) ph.hidden = text.length > 0;
}

- (void)dismissKeyboard {
    [self.view endEditing:YES];
}

// The dismissTap gesture must not fire when the touch lands on a UIControl
// (UIButton, UISwitch, etc.). Without this, tapping Send while the keyboard
// is visible starts a keyboard-hide layout animation mid-touch that moves the
// inputContainer, causing UIKit to cancel the button's touchUpInside event.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    return ![touch.view isKindOfClass:[UIControl class]];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Web Search Toggle
// ─────────────────────────────────────────────────────────────────────────────

- (void)toggleWebSearch {
    self.webSearchEnabled = !self.webSearchEnabled;
    [[NSUserDefaults standardUserDefaults] setBool:self.webSearchEnabled forKey:@"webSearchEnabled"];
    [self updateWebSearchButtonTint];
    [self appendToChat:[NSString stringWithFormat:@"[System: Web Search %@]",
                        self.webSearchEnabled ? @"ON 🌐" : @"OFF"]];
    EZLogf(EZLogLevelInfo, @"WEBSEARCH", @"Toggled %@", self.webSearchEnabled ? @"ON" : @"OFF");
}

- (void)updateWebSearchButtonTint {
    [self.webSearchButton setTintColor:self.webSearchEnabled
        ? [UIColor systemGreenColor] : [UIColor systemGrayColor]];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Helper Direct-Answer Toggle
// ─────────────────────────────────────────────────────────────────────────────

- (void)toggleHelperDirectAnswers {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL enabled = ![defaults boolForKey:@"HelperDirectAnswersEnabled"];
    [defaults setBool:enabled forKey:@"HelperDirectAnswersEnabled"];
    [self updateHelperDirectAnswersButton];
    [self appendToChat:[NSString stringWithFormat:@"[System: Helper direct answers %@]",
                        enabled ? @"ON ⚡" : @"OFF"]];
    EZLogf(EZLogLevelInfo, @"TRIAGE", @"Helper direct answers %@",
           enabled ? @"enabled" : @"disabled");
}

- (void)updateHelperDirectAnswersButton {
    BOOL enabled = [[NSUserDefaults standardUserDefaults]
        boolForKey:@"HelperDirectAnswersEnabled"];
    [self.helperDirectAnswersButton setTintColor:enabled
        ? [UIColor systemYellowColor] : [UIColor systemGrayColor]];
    self.helperDirectAnswersButton.accessibilityValue = enabled ? @"On" : @"Off";
    self.helperDirectAnswersButton.accessibilityHint = enabled
        ? @"Tap to require the main model to answer every prompt"
        : @"Tap to allow helper models to answer directly";
}

    // ─────────────────────────────────────────────────────────────────────────────
// MARK: - Thread Title Editing
// ─────────────────────────────────────────────────────────────────────────────

/// Syncs the visible threadTitleLabel with the active thread's current title.
- (void)updateThreadTitleLabel {
    NSString *title = self.activeThread.title;
    if (!title.length || [title isEqualToString:@"New Conversation"]) {
        self.threadTitleLabel.text      = @"New Conversation";
        self.threadTitleLabel.textColor = [UIColor tertiaryLabelColor];
    } else {
        self.threadTitleLabel.text      = title;
        self.threadTitleLabel.textColor = [UIColor secondaryLabelColor];
    }
}

/// Shows an alert with a prefilled text field so the user can rename the thread.
- (void)renameThread {
    NSString *current = self.activeThread.title.length > 0
        ? self.activeThread.title : @"";
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Rename Thread"
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text             = current;
        tf.placeholder      = @"Thread name";
        tf.clearButtonMode  = UITextFieldViewModeWhileEditing;
        tf.returnKeyType    = UIReturnKeyDone;
        tf.autocapitalizationType = UITextAutocapitalizationTypeSentences;
    }];
    __weak typeof(self) ws = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Save"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *_) {
        NSString *newTitle = [alert.textFields.firstObject.text
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!newTitle.length) return;
        ws.activeThread.title = newTitle;
        [ws updateThreadTitleLabel];
        [ws saveActiveThread];
        EZLogf(EZLogLevelInfo, @"THREAD", @"Renamed to: %@", newTitle);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Image Generation Settings
// ─────────────────────────────────────────────────────────────────────────────

/// Presents a series of action sheets to configure gpt-image-1 generation params.
/// Settings are persisted in NSUserDefaults and read in callGptImage1 / callImageEdit.
- (void)showImageSettings {
    EZImageSettingsViewController *vc = [[EZImageSettingsViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = nav.sheetPresentationController;
        sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent];
        sheet.prefersGrabberVisible = YES;
    }
    [self presentViewController:nav animated:YES completion:nil];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Chat History
// ─────────────────────────────────────────────────────────────────────────────

- (void)openHistory {
    if (self.memoriesDrawerOpen) {
        [self closeMemoriesDrawerWithCompletion:nil];
    }
    if (self.drawerOpen) { [self closeDrawer]; return; }

    // ── Lazy build — only on first open ──────────────────────────────────────
    if (!self.drawerContainerView) {
        CGFloat drawerWidth = self.view.bounds.size.width * 0.75;

        // Dim overlay — full screen, tap anywhere right of drawer to close
        self.drawerDimView = [[UIView alloc] init];
        self.drawerDimView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
        self.drawerDimView.alpha = 0;
        self.drawerDimView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:self.drawerDimView];
        [NSLayoutConstraint activateConstraints:@[
            [self.drawerDimView.topAnchor     constraintEqualToAnchor:self.view.topAnchor],
            [self.drawerDimView.bottomAnchor  constraintEqualToAnchor:self.view.bottomAnchor],
            [self.drawerDimView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [self.drawerDimView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        ]];
        UITapGestureRecognizer *dimTap = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(closeDrawer)];
        [self.drawerDimView addGestureRecognizer:dimTap];\
        
        // Drawer container — slides in from left
        self.drawerContainerView = [[UIView alloc] init];
        self.drawerContainerView.backgroundColor = [UIColor systemBackgroundColor];
        self.drawerContainerView.translatesAutoresizingMaskIntoConstraints = NO;
        self.drawerContainerView.layer.shadowColor   = [UIColor blackColor].CGColor;
        self.drawerContainerView.layer.shadowOpacity = 0.22;
        self.drawerContainerView.layer.shadowRadius  = 14;
        self.drawerContainerView.layer.shadowOffset  = CGSizeMake(6, 0);
        [self.view addSubview:self.drawerContainerView];

        // Start fully off-screen to the left
        self.drawerLeadingConstraint = [self.drawerContainerView.leadingAnchor
            constraintEqualToAnchor:self.view.leadingAnchor constant:-drawerWidth];
        [NSLayoutConstraint activateConstraints:@[
            self.drawerLeadingConstraint,
            [self.drawerContainerView.topAnchor    constraintEqualToAnchor:self.view.topAnchor],
            [self.drawerContainerView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
            [self.drawerContainerView.widthAnchor  constraintEqualToConstant:drawerWidth],
        ]];

        // Embed ChatHistoryViewController as a child VC
        ChatHistoryViewController *historyVC = [[ChatHistoryViewController alloc]
            initWithStyle:UITableViewStylePlain];
        historyVC.delegate = self;
        self.drawerNavController = [[UINavigationController alloc]
            initWithRootViewController:historyVC];
        [self addChildViewController:self.drawerNavController];
        self.drawerNavController.view.translatesAutoresizingMaskIntoConstraints = NO;
        [self.drawerContainerView addSubview:self.drawerNavController.view];
        [NSLayoutConstraint activateConstraints:@[
            [self.drawerNavController.view.topAnchor    constraintEqualToAnchor:self.drawerContainerView.topAnchor],
            [self.drawerNavController.view.bottomAnchor constraintEqualToAnchor:self.drawerContainerView.bottomAnchor],
            [self.drawerNavController.view.leadingAnchor constraintEqualToAnchor:self.drawerContainerView.leadingAnchor],
            [self.drawerNavController.view.trailingAnchor constraintEqualToAnchor:self.drawerContainerView.trailingAnchor],
        ]];
        [self.drawerNavController didMoveToParentViewController:self];
        [self.view layoutIfNeeded];
    }

    // ── Animate in ───────────────────────────────────────────────────────────
    self.drawerOpen = YES;
    self.drawerDimView.hidden = NO;
    self.drawerLeadingConstraint.constant = 0;
    [UIView animateWithDuration:0.32
                          delay:0
         usingSpringWithDamping:0.88
          initialSpringVelocity:0.4
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.drawerDimView.alpha = 1.0;
        [self.view layoutIfNeeded];
    } completion:nil];
}

- (void)closeDrawer {
    if (!self.drawerOpen) return;
    self.drawerOpen = NO;
    CGFloat drawerWidth = self.drawerContainerView.bounds.size.width;
    self.drawerLeadingConstraint.constant = -drawerWidth;
    [UIView animateWithDuration:0.26
                          delay:0
         usingSpringWithDamping:1.0
          initialSpringVelocity:0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        self.drawerDimView.alpha = 0;
        [self.view layoutIfNeeded];
    } completion:^(BOOL _) {
        self.drawerDimView.hidden = YES;
    }];
}

- (void)closeMemoriesDrawer {
    [self closeMemoriesDrawerWithCompletion:nil];
}

- (void)closeMemoriesDrawerWithCompletion:(dispatch_block_t)completion {
    if (!self.memoriesDrawerOpen) {
        if (completion) completion();
        return;
    }

    self.memoriesDrawerOpen = NO;
    CGFloat drawerWidth = self.memoriesDrawerContainerView.bounds.size.width;
    self.memoriesDrawerTrailingConstraint.constant = drawerWidth;
    [UIView animateWithDuration:0.26
                          delay:0
         usingSpringWithDamping:1.0
          initialSpringVelocity:0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        self.memoriesDrawerDimView.alpha = 0;
        [self.view layoutIfNeeded];
    } completion:^(BOOL _) {
        self.memoriesDrawerDimView.hidden = YES;
        if (completion) completion();
    }];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Attach Menu
// ─────────────────────────────────────────────────────────────────────────────

- (void)showAttachMenu {
    EZAttachMenuViewController *vc = [[EZAttachMenuViewController alloc] init];
    __weak typeof(self) ws = self;
    vc.onWhisper     = ^{ [ws presentFilePickerForMode:EZAttachModeWhisper]; };
    vc.onAnalyze     = ^{ [ws presentFilePickerForMode:EZAttachModeAnalyze]; };
    vc.onImageFiles  = ^{ [ws presentFilePickerForMode:EZAttachModeAnalyze forceTypes:@[UTTypeImage]]; };
    vc.onPhotoLibrary= ^{ [ws presentPhotoLibraryPicker]; };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = nav.sheetPresentationController;
        sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent];
        sheet.prefersGrabberVisible = YES;
    }
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)presentFilePickerForMode:(EZAttachMode)mode {
    NSArray *types;
    if (mode == EZAttachModeWhisper) {
        types = @[UTTypeAudio, UTTypeVideo, UTTypeMovie, UTTypeAudiovisualContent];
    } else {
        // Be explicit — UTTypeData catch-all breaks iOS 15 file picker
        types = @[UTTypePDF,
                  [UTType typeWithIdentifier:@"org.idpf.epub-container"],
                  UTTypePlainText,
                  UTTypeRTF,
                  UTTypeHTML,
                  UTTypeImage,
                  [UTType typeWithIdentifier:@"public.comma-separated-values-text"],
                  [UTType typeWithIdentifier:@"public.json"],
                  [UTType typeWithIdentifier:@"public.xml"]];
    }
    [self presentFilePickerForMode:mode forceTypes:types];
}

- (void)presentFilePickerForMode:(EZAttachMode)mode forceTypes:(NSArray *)types {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    // Store mode via associated object — safer than .view.tag on iOS 15
    objc_setAssociatedObject(picker, "EZAttachMode",
                             @(mode), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self presentViewController:picker animated:YES completion:nil];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Document Picker Delegate
// ─────────────────────────────────────────────────────────────────────────────

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *fileURL = urls.firstObject;
    if (!fileURL) return;

    // Retrieve mode from associated object — fall back to analyze
    NSNumber *modeNum = objc_getAssociatedObject(controller, "EZAttachMode");
    EZAttachMode mode = modeNum ? (EZAttachMode)modeNum.integerValue : EZAttachModeAnalyze;

    NSString *ext = fileURL.pathExtension.lowercaseString;
    BOOL isImage  = [@[@"jpg",@"jpeg",@"png",@"gif",@"webp",@"heic"] containsObject:ext];

    if (mode == EZAttachModeWhisper) {
        [self transcribeAudio:fileURL];
    } else if (isImage) {
        [self attachImage:fileURL];
    } else {
        [self analyzeFile:fileURL];
    }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    EZLog(EZLogLevelInfo, @"FILE", @"Document picker cancelled by user");
}

- (void)presentPhotoLibraryPicker {
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] initWithPhotoLibrary:[PHPhotoLibrary sharedPhotoLibrary]];
    cfg.filter = [PHPickerFilter imagesFilter]; cfg.selectionLimit = 1;
    PHPickerViewController *p = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    p.delegate = self; [self presentViewController:p animated:YES completion:nil];
}
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    PHPickerResult *r = results.firstObject; if (!r) return;
    NSItemProvider *pv = r.itemProvider;
    if ([pv hasItemConformingToTypeIdentifier:UTTypeImage.identifier]) {
        [pv loadFileRepresentationForTypeIdentifier:UTTypeImage.identifier completionHandler:^(NSURL *url, NSError *e) {
            if (!url) { dispatch_async(dispatch_get_main_queue(), ^{ [self appendToChat:@"[Error: Could not load photo]"]; }); return; }
            NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:url.lastPathComponent];
            [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
            NSError *ce; [[NSFileManager defaultManager] copyItemAtURL:url toURL:[NSURL fileURLWithPath:tmp] error:&ce];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (ce) { [self appendToChat:@"[Error: Could not copy photo]"]; return; }
                [self attachImage:[NSURL fileURLWithPath:tmp]];
            });
        }];
    } else if ([pv canLoadObjectOfClass:[UIImage class]]) {
        [pv loadObjectOfClass:[UIImage class] completionHandler:^(UIImage *img, NSError *e) {
            if (!img) return;
            NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"photo_pick.jpg"];
            [UIImageJPEGRepresentation(img, 0.92) writeToFile:tmp atomically:YES];
            dispatch_async(dispatch_get_main_queue(), ^{ [self attachImage:[NSURL fileURLWithPath:tmp]]; });
        }];
    }
}
- (void)offerSaveToPhotos:(NSString *)path {
    if (!path.length) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Save to Photos?"
        message:@"Save this image to your Photo Library." preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *_) { [self saveImageToPhotos:path]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Not Now" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)saveImageToPhotos:(NSString *)localPath {
    if (![[NSFileManager defaultManager] fileExistsAtPath:localPath]) {
        [self appendToChat:@"[Error: Image not found]"]; return;
    }
    UIImage *img = [UIImage imageWithContentsOfFile:localPath];
    if (!img) { [self appendToChat:@"[Error: Cannot decode image]"]; return; }
    UIImageWriteToSavedPhotosAlbum(img, self,
        @selector(ezPhotoSaved:didFinishSavingWithError:contextInfo:), NULL);
}
- (void)ezPhotoSaved:(UIImage *)img didFinishSavingWithError:(NSError *)err contextInfo:(void *)ctx {
    if (err) [self appendToChat:[NSString stringWithFormat:@"[Error: Save failed \u2014 %@]", err.localizedDescription ?: @"?"]];
    else [self appendToChat:@"[System: Image saved to Photo Library \u2713]"];
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Image Attachment
// ─────────────────────────────────────────────────────────────────────────────

- (void)attachImage:(NSURL *)fileURL {
    NSData *rawData = [NSData dataWithContentsOfURL:fileURL];
    if (!rawData) {
        [self appendToChat:@"[Error: Could not read image]"]; return;
    }

    NSString *name = fileURL.lastPathComponent;
    NSString *ext  = fileURL.pathExtension.lowercaseString;

    // ── Format validation & conversion ───────────────────────────────────────
    // OpenAI vision + image edit APIs accept: png, jpeg, gif, webp ONLY.
    // HEIC (default iOS camera format) must be converted to JPEG.
    // Any other unsupported format also gets converted to JPEG.
    NSData   *imageData = rawData;
    NSString *mime      = @"image/jpeg";
    BOOL      converted = NO;

    NSSet *supported = [NSSet setWithObjects:@"png", @"jpg", @"jpeg", @"gif", @"webp", nil];

    if (![supported containsObject:ext]) {
        // Attempt conversion via UIImage → JPEG
        UIImage *img = [UIImage imageWithData:rawData];
        if (img) {
            NSData *jpegData = UIImageJPEGRepresentation(img, 0.92);
            if (jpegData) {
                imageData  = jpegData;
                mime       = @"image/jpeg";
                converted  = YES;
                [self appendToChat:[NSString stringWithFormat:
                    @"[System: %@ converted from %@ to JPEG for API compatibility ✓]",
                    name, ext.uppercaseString]];
                EZLogf(EZLogLevelInfo, @"ATTACH", @"Converted %@ → JPEG (%lu bytes)",
                       ext, (unsigned long)imageData.length);
            } else {
                [self appendToChat:[NSString stringWithFormat:
                    @"[Error: Could not convert %@ to a supported format. "
                    @"Please use PNG, JPEG, GIF, or WebP.]", ext.uppercaseString]];
                return;
            }
        } else {
            [self appendToChat:[NSString stringWithFormat:
                @"[Error: Unsupported image format '%@'. Please use PNG, JPEG, GIF, or WebP.]",
                ext.uppercaseString]];
            return;
        }
    } else {
        // Set correct mime for supported formats
        if ([ext isEqualToString:@"png"])              mime = @"image/png";
        else if ([ext isEqualToString:@"gif"])         mime = @"image/gif";
        else if ([ext isEqualToString:@"webp"])        mime = @"image/webp";
        else                                           mime = @"image/jpeg";
    }

    // ── Save to EZPhotoGallery ────────────────────────────────────────────────
    NSString *saveName  = converted
        ? [[name stringByDeletingPathExtension] stringByAppendingPathExtension:@"jpeg"]
        : name;
    NSString *localPath = EZPhotoGallerySave(imageData, saveName);
    NSString *thisPath  = localPath ?: fileURL.path;
    [self.pendingImagePaths addObject:thisPath];
    [self appendAttachmentBubble:thisPath];

    if (localPath) {
        NSMutableArray *att = [self.activeThread.attachmentPaths mutableCopy];
        [att addObject:localPath];
        self.activeThread.attachmentPaths = [att copy];
    }

    // An attached image is not inherently an edit request. Preserve the
    // selected model and let the send-time intent router choose chat, edit,
    // or generation from the actual prompt. Only Photo Detail's explicit
    // Edit with AI action enters edit mode immediately.
    if (![self modelSupportsVision:self.selectedModel] &&
        ![self isGptImage1Family:self.selectedModel]) {
        NSString *prev     = self.selectedModel;
        self.selectedModel = @"gpt-4o";
        [self.modelButton setTitle:@"Model: gpt-4o" forState:UIControlStateNormal];
        [self appendToChat:[NSString stringWithFormat:
            @"[System: Image attached — %@ doesn't support vision. "
            @"Switched to gpt-4o. Ask a question or describe an edit.]", prev]];
    } else {
        [self appendToChat:[NSString stringWithFormat:
            @"[System: Image %@ attached. Ask a question, describe an edit, or request a new image.]", saveName]];
    }

    // Add vision message to context — use base64 data URL. Runs regardless
    // of inImageGenMode: this used to live only in the vision-analysis else
    // branch above, which meant an edit-mode source image had zero trace
    // anywhere in chatContext and could never be restored after reloading
    // the thread — see chatHistoryDidSelectThread's fallback comment for
    // how already-broken threads from before this fix are handled. This
    // doesn't change what editing actually does: callImageEdit sends the
    // image to ez-image directly over its own HTTP call, not through
    // chatContext/ez-chat, so recording it here is purely for restore/
    // history purposes. If the user later sends a normal chat message,
    // sanitizedContextForAPI's existing "only resend the newest image"
    // logic treats this like any other recent attachment — reasonable,
    // since the model having context on what image was being edited if
    // asked about it later isn't a bug.
    // NOTE: this message is marked so we can strip it after first use
    // to avoid re-sending huge base64 blobs on every subsequent turn
    NSString *base64  = [imageData base64EncodedStringWithOptions:0];
    NSString *dataURL = [NSString stringWithFormat:@"data:%@;base64,%@", mime, base64];
    NSDictionary *newImageBlock = @{@"type": @"image_url", @"image_url": @{@"url": dataURL}};

    // If the previous chatContext entry is ALSO a still-pending (unsent)
    // vision attachment, merge this image into it as an additional block
    // instead of creating a separate message. This is what actually
    // fixes multi-image attach: sanitizedContextForAPI only preserves
    // the single most recent vision MESSAGE (correct, desirable
    // behavior for genuinely old attachments left over from an earlier,
    // already-completed turn — that's what stops every prior image
    // getting re-sent as base64 on every future turn), so two images
    // attached in the same not-yet-sent turn need to live in ONE
    // combined message, or the older one silently loses its image data.
    // A vision message stops being "the previous entry" the instant the
    // user sends (which appends a real user-prompt message right after
    // it — see the fullPrompt append below), so this only ever merges
    // attachments from the same pending turn, never a leftover image
    // from an already-completed exchange.
    NSDictionary *lastMsg = self.chatContext.lastObject;
    if ([lastMsg[@"_isVisionAttachment"] boolValue]) {
        NSMutableArray *mergedBlocks = [lastMsg[@"content"] mutableCopy] ?: [NSMutableArray array];
        // Insert before the trailing placeholder text block so the
        // placeholder stays last no matter how many images accumulate.
        NSUInteger insertAt = mergedBlocks.count > 0 ? mergedBlocks.count - 1 : 0;
        [mergedBlocks insertObject:newImageBlock atIndex:insertAt];
        NSMutableDictionary *mergedMsg = [lastMsg mutableCopy];
        mergedMsg[@"content"] = [mergedBlocks copy];
        [self.chatContext removeLastObject];
        [self.chatContext addObject:[mergedMsg copy]];
    } else {
        NSDictionary *visionMsg = @{
            @"role":     @"user",
            @"content":  @[
                newImageBlock,
                @{@"type": @"text", @"text": @"[image attached — await user question]"}
            ],
            @"_isVisionAttachment": @YES   // internal flag — stripped before API call
        };
        [self.chatContext addObject:visionMsg];
    }

    EZLogf(EZLogLevelInfo, @"ATTACH", @"Image ready: %@ mime=%@ bytes=%lu",
           saveName, mime, (unsigned long)imageData.length);
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - File Analysis (PDF / ePub / text)
// ─────────────────────────────────────────────────────────────────────────────

- (void)analyzeFile:(NSURL *)fileURL {
    NSString *ext  = fileURL.pathExtension.lowercaseString;
    NSString *name = fileURL.lastPathComponent;
    EZLogf(EZLogLevelInfo, @"FILE", @"Analyzing: %@", name);
    [self appendToChat:[NSString stringWithFormat:@"[System: Reading %@...]", name]];

    // Save a copy for persistence
    NSData *fileData = [NSData dataWithContentsOfURL:fileURL];
    if (fileData) {
        NSString *savedPath = EZAttachmentSave(fileData, name);
        if (savedPath) {
            NSMutableArray *att = [self.activeThread.attachmentPaths mutableCopy];
            [att addObject:savedPath];
            self.activeThread.attachmentPaths = [att copy];
        }
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *extractedText = nil;
        if ([ext isEqualToString:@"pdf"]) {
            extractedText = [self extractTextFromPDF:fileURL];
        } else if ([ext isEqualToString:@"epub"]) {
            extractedText = [self extractTextFromEPUB:fileURL];
        } else if ([@[@"rtf", @"html", @"htm", @"doc", @"docx", @"odt"] containsObject:ext]) {
            // UIKit's document reader handles rich text and supported Office/
            // OpenDocument files. Keep the plain-text fallback below for
            // source, CSV, JSON, XML, Markdown, and unknown text formats.
            extractedText = [self extractTextFromRichDocument:fileURL];
        } else {
            extractedText = [NSString stringWithContentsOfURL:fileURL
                                                     encoding:NSUTF8StringEncoding error:nil]
                         ?: [NSString stringWithContentsOfURL:fileURL
                                                     encoding:NSISOLatin1StringEncoding error:nil];
        }
        if (!extractedText.length) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendToChat:@"[Error: Could not extract text from file]"];
            });
            return;
        }
        /*
        if (extractedText.length > 12000) {
            extractedText = [[extractedText substringToIndex:12000]
                             stringByAppendingString:@"\n[...truncated...]"];
        }
         */
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.pendingFiles addObject:@{@"name": name, @"content": extractedText}];
            [self appendToChat:[NSString stringWithFormat:
                @"[System: %@ ready (%lu chars). Ask me anything about it.]",
                name, (unsigned long)extractedText.length]];
            [self.messageTextField becomeFirstResponder];
            EZLogf(EZLogLevelInfo, @"FILE", @"Context ready: %@ (%lu chars)",
                   name, (unsigned long)extractedText.length);
        });
    });
}

- (NSString *)extractTextFromRichDocument:(NSURL *)url {
    NSError *error = nil;
    NSAttributedString *document = [[NSAttributedString alloc]
        initWithURL:url options:@{} documentAttributes:nil error:&error];
    if (document.string.length > 0) return document.string;
    if (error) EZLogf(EZLogLevelWarning, @"FILE", @"Rich document extraction failed: %@", error.localizedDescription);
    return nil;
}

- (NSString *)extractTextFromPDF:(NSURL *)url {
    PDFDocument *doc = [[PDFDocument alloc] initWithURL:url];
    if (!doc) return nil;
    NSMutableString *text = [NSMutableString string];
    for (NSInteger i = 0; i < doc.pageCount; i++) {
        NSString *pg = [[doc pageAtIndex:i] string];
        if (pg) [text appendFormat:@"%@\n", pg];
    }
    return text;
}

- (NSString *)extractTextFromEPUB:(NSURL *)url {
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data) return nil;
    NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                 ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if (!raw) return @"[Could not decode ePub]";
    NSMutableString *stripped = [NSMutableString string];
    BOOL inTag = NO;
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        if (c == '<')      { inTag = YES; continue; }
        if (c == '>')      { inTag = NO; [stripped appendString:@" "]; continue; }
        if (!inTag)        [stripped appendFormat:@"%C", c];
    }
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\\s{3,}"
                                                                        options:0 error:nil];
    return [re stringByReplacingMatchesInString:stripped options:0
                                          range:NSMakeRange(0, stripped.length)
                                   withTemplate:@"\n\n"];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - TTS
// ─────────────────────────────────────────────────────────────────────────────

- (void)speakLastResponse {
    if (!self.lastAIResponse) return;

    NSString *voiceID     = [[NSUserDefaults standardUserDefaults] stringForKey:@"elevenVoiceID"];
    NSString *textToSpeak = self.lastAIResponse;
    NSInteger charCount   = (NSInteger)textToSpeak.length;

    // ── Old user-API-key path — commented out, kept in case user keys return ──
    // NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    // // CHANGED: ElevenLabs key now loaded from EZKeyVault (Keychain) instead of NSUserDefaults
    // NSString *elKey   = [EZKeyVault loadKeyForIdentifier:EZVaultKeyElevenLabs];
    // NSString *elVoice = [d stringForKey:@"elevenVoiceID"];
    // if (elKey.length > 0 && elVoice.length > 0) {
    //     [self speakWithElevenLabs:textToSpeak key:elKey voiceID:elVoice];
    // } else {
    //     [self speakWithApple:textToSpeak];
    // }
    // ─────────────────────────────────────────────────────────────────────────

    // No voice configured — fall back to Apple TTS silently
    if (voiceID.length == 0) {
        [self speakWithApple:textToSpeak];
        return;
    }

    // ── Long-response guard (> 160 chars) ────────────────────────────────────
    // Coin cost mirrors the edge function: ceil(charCount / 50)
    NSInteger estimatedCoins = (NSInteger)ceil(charCount / 50.0);

    if (charCount > 160) {
        NSString *alertMessage = [NSString stringWithFormat:
            @"This response is %ld characters long.\n\n"
            @"Reading it with ElevenLabs will cost approximately %ld coins.\n\n"
            @"Choose an option:",
            (long)charCount, (long)estimatedCoins];

        UIAlertController *lengthAlert = [UIAlertController
            alertControllerWithTitle:@"Long Response"
                             message:alertMessage
                      preferredStyle:UIAlertControllerStyleAlert];

        NSString *elevenLabsLabel = [NSString stringWithFormat:
            @"ElevenLabs (≈%ld coins)", (long)estimatedCoins];
        [lengthAlert addAction:[UIAlertAction
            actionWithTitle:elevenLabsLabel
                      style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *action) {
            [self speakWithElevenLabsEdge:textToSpeak voiceID:voiceID];
        }]];

        [lengthAlert addAction:[UIAlertAction
            actionWithTitle:@"Apple TTS (free)"
                      style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *action) {
            [self speakWithApple:textToSpeak];
        }]];

        [lengthAlert addAction:[UIAlertAction
            actionWithTitle:@"Don't Read"
                      style:UIAlertActionStyleCancel
                    handler:nil]];

        [self presentViewController:lengthAlert animated:YES completion:nil];
    } else {
        // Short response — go straight to ElevenLabs, no warning needed
        [self speakWithElevenLabsEdge:textToSpeak voiceID:voiceID];
    }
}

- (void)speakWithApple:(NSString *)text {
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                            mode:AVAudioSessionModeDefault
                                         options:AVAudioSessionCategoryOptionDuckOthers error:nil];
    [[AVAudioSession sharedInstance] setActive:YES error:nil];
    if (self.speechSynthesizer.isSpeaking)
        [self.speechSynthesizer stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    AVSpeechUtterance *u = [AVSpeechUtterance speechUtteranceWithString:text];
    u.voice = [AVSpeechSynthesisVoice voiceWithLanguage:@"en-US"];
    u.rate  = AVSpeechUtteranceDefaultSpeechRate;
    [self.speechSynthesizer speakUtterance:u];
}

// ── speakWithElevenLabs:key:voiceID: — COMMENTED OUT (user API key path) ────
// Kept in case user-supplied ElevenLabs keys need to be restored later.
// All TTS now routes through the ez-elevenlabs Supabase edge function.
//
// - (void)speakWithElevenLabs:(NSString *)text key:(NSString *)key voiceID:(NSString *)voiceID {
//     EZLogf(EZLogLevelInfo, @"TTS", @"ElevenLabs voiceID=%@", voiceID);
//     NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:
//         @"https://api.elevenlabs.io/v1/text-to-speech/%@", voiceID]];
//     NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
//     req.HTTPMethod = @"POST";
//     [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
//     [req setValue:key forHTTPHeaderField:@"xi-api-key"];
//     req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
//         @"text": text, @"model_id": @"eleven_turbo_v2_5",
//         @"voice_settings": @{@"stability": @0.5, @"similarity_boost": @0.5}
//     } options:0 error:nil];
//     [[[NSURLSession sharedSession] dataTaskWithRequest:req
//         completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
//         if (error) {
//             dispatch_async(dispatch_get_main_queue(), ^{ [self speakWithApple:text]; });
//             return;
//         }
//         NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
//         if (http.statusCode != 200) {
//             NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
//             EZLogf(EZLogLevelError, @"TTS", @"ElevenLabs %ld: %@", (long)http.statusCode, body);
//             dispatch_async(dispatch_get_main_queue(), ^{
//                 [self appendToChat:[NSString stringWithFormat:
//                     @"[ElevenLabs HTTP %ld — falling back to Apple TTS]", (long)http.statusCode]];
//                 [self speakWithApple:text];
//             });
//             return;
//         }
//         dispatch_async(dispatch_get_main_queue(), ^{
//             [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
//                                                     mode:AVAudioSessionModeDefault
//                                                  options:0 error:nil];
//             [[AVAudioSession sharedInstance] setActive:YES error:nil];
//             NSError *playerErr;
//             self.audioPlayer = [[AVAudioPlayer alloc] initWithData:data error:&playerErr];
//             if (playerErr) { [self speakWithApple:text]; return; }
//             [self.audioPlayer prepareToPlay];
//             [self.audioPlayer play];
//         });
//     }] resume];
// }
// ─────────────────────────────────────────────────────────────────────────────

// ── speakWithElevenLabsEdge:voiceID: — routes through ez-elevenlabs edge fn ─
// Sends text to the Supabase edge function which uses the server-side
// ElevenLabs API key (Supabase secret). Coins are deducted server-side at
// 1 coin per 50 characters, rounded up. Returns base64-encoded audio.
- (void)speakWithElevenLabsEdge:(NSString *)text voiceID:(NSString *)voiceID {
    NSString *jwt = [EZAuthManager shared].accessToken;
    if (!jwt.length) {
        EZLog(EZLogLevelError, @"TTS", @"No auth token — cannot call TTS edge function");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendToChat:@"[TTS Error: Not signed in — using Apple TTS]"];
            [self speakWithApple:text];
        });
        return;
    }

    NSInteger charCount = (NSInteger)text.length;
    EZLogf(EZLogLevelInfo, @"TTS", @"ElevenLabs edge TTS voiceID=%@ chars=%ld",
           voiceID, (long)charCount);

    // eleven_multilingual_v2 (the model ez-elevenlabs uses) hard-caps requests
    // at 10,000 characters — matches MAX_TTS_CHARS server-side. Fail fast
    // here instead of spending a round trip (and a coin deduct/refund cycle)
    // on a request the server will reject anyway.
    static const NSInteger kMaxTTSChars = 10000;
    if (charCount > kMaxTTSChars) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendToChat:[NSString stringWithFormat:
                @"[TTS: Response is %ld characters, ElevenLabs' limit is %ld — using Apple TTS instead]",
                (long)charCount, (long)kMaxTTSChars]];
            [self speakWithApple:text];
        });
        return;
    }

    NSURL *edgeURL = [NSURL URLWithString:
        @"https://spuoimtqofhbdzosrbng.supabase.co/functions/v1/ez-elevenlabs"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:edgeURL];
    req.HTTPMethod = @"POST";
    // Was left on the NSURLSession default (60s). ElevenLabs generation time
    // scales with text length and the edge function itself now has a 90s
    // budget per attempt (up to two attempts on a format fallback — see
    // ez-elevenlabs EL_REQUEST_TIMEOUT_MS) — 60s meant longer responses could
    // time out client-side before the server had a real chance to fail
    // cleanly and refund. 220s covers two 90s server attempts plus margin.
    req.timeoutInterval = 220;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", jwt]
       forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{
        @"action":     @"tts",
        @"text":       text,
        @"voice_id":   voiceID,
        @"char_count": @(charCount),
    } options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *responseData, NSURLResponse *response, NSError *networkError) {

        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;

        // ── Network-level failure ─────────────────────────────────────────────
        if (networkError) {
            EZLogf(EZLogLevelError, @"TTS", @"Network error: %@",
                   networkError.localizedDescription);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendToChat:@"[TTS: Network error — using Apple TTS]"];
                [self speakWithApple:text];
            });
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:responseData
                                                             options:0 error:nil];

        // ── Insufficient coins (402) ──────────────────────────────────────────
        if (http.statusCode == 402) {
            NSInteger costNeeded   = [json[@"cost"] integerValue];
            NSInteger currentCoins = [json[@"balance"] integerValue];
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *coinMessage = [NSString stringWithFormat:
                    @"This TTS request costs %ld coins but your balance is %ld.\n\n"
                    @"Use Apple TTS for free, or top up your coins.",
                    (long)costNeeded, (long)currentCoins];
                UIAlertController *coinAlert = [UIAlertController
                    alertControllerWithTitle:@"Not Enough Coins"
                                     message:coinMessage
                              preferredStyle:UIAlertControllerStyleAlert];
                [coinAlert addAction:[UIAlertAction
                    actionWithTitle:@"Use Apple TTS (free)"
                              style:UIAlertActionStyleDefault
                            handler:^(UIAlertAction *a) { [self speakWithApple:text]; }]];
                [coinAlert addAction:[UIAlertAction
                    actionWithTitle:@"Get Coins"
                              style:UIAlertActionStyleDefault
                            handler:^(UIAlertAction *a) {
                    [self presentCoinStoreForFeature:nil];
                }]];
                [coinAlert addAction:[UIAlertAction
                    actionWithTitle:@"Cancel"
                              style:UIAlertActionStyleCancel handler:nil]];
                [self presentViewController:coinAlert animated:YES completion:nil];
            });
            return;
        }

        // ── Any other non-200 ─────────────────────────────────────────────────
        if (http.statusCode != 200) {
            NSString *errorDetail = json[@"error"] ?: @"Unknown error";
            // ez-elevenlabs sends a human-readable "reason" alongside the
            // error code for the cases users are most likely to hit
            // (text_too_long, tts_timeout, tts_fetch_failed) — show it when
            // present instead of a bare status code that means nothing to
            // someone who isn't looking at server logs.
            NSString *reason = json[@"reason"];
            EZLogf(EZLogLevelError, @"TTS", @"Edge function HTTP %ld: %@",
                   (long)http.statusCode, errorDetail);
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *displayMessage = reason.length
                    ? [NSString stringWithFormat:@"[TTS: %@ — using Apple TTS]", reason]
                    : [NSString stringWithFormat:@"[TTS Error %ld — using Apple TTS]", (long)http.statusCode];
                [self appendToChat:displayMessage];
                [self speakWithApple:text];
            });
            return;
        }

        // ── Success ───────────────────────────────────────────────────────────
        NSString *audioB64   = json[@"audio_b64"];
        NSInteger newBalance = [json[@"balance"] integerValue];
        NSInteger coinsSpent = [json[@"coins_spent"] integerValue];

        if (!audioB64.length) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendToChat:@"[TTS Error: No audio in response — using Apple TTS]"];
                [self speakWithApple:text];
            });
            return;
        }

        NSData *audioData = [[NSData alloc]
            initWithBase64EncodedString:audioB64
                                options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (!audioData) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendToChat:@"[TTS Error: Could not decode audio — using Apple TTS]"];
                [self speakWithApple:text];
            });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                                    mode:AVAudioSessionModeDefault
                                                 options:0 error:nil];
            [[AVAudioSession sharedInstance] setActive:YES error:nil];
            NSError *playerErr = nil;
            self.audioPlayer = [[AVAudioPlayer alloc] initWithData:audioData error:&playerErr];
            if (playerErr) {
                EZLogf(EZLogLevelError, @"TTS", @"AVAudioPlayer error: %@",
                       playerErr.localizedDescription);
                [self speakWithApple:text];
                return;
            }
            [self.audioPlayer prepareToPlay];
            [self.audioPlayer play];

            // Refresh coin display — edge function already deducted server-side
            [[EZEntitlementManager shared] refreshBalanceWithCompletion:^(NSInteger balance) {
                [self updateCoinBalanceDisplay];
            }];

            EZLogf(EZLogLevelInfo, @"TTS",
                   @"ElevenLabs audio playing — spent %ld coins, balance now %ld",
                   (long)coinsSpent, (long)newBalance);
        });
    }] resume];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - handleSend
// ─────────────────────────────────────────────────────────────────────────────

- (void)handleSend {
    NSString *text = self.messageTextField.text;
    if (text.length == 0) return;

    // ── Immediate UI feedback ─────────────────────────────────────────────────
    // Show the user bubble, clear the input field, and dismiss the keyboard NOW,
    // before any async entitlement check or API call. This eliminates the delay
    // where the user sees nothing happen after tapping Send. Disabling the button
    // here also blocks duplicate submissions during the async round-trip.
    self.sendButton.enabled = NO;
    [self appendToChat:[NSString stringWithFormat:@"You: %@", text]];
    [self.view endEditing:YES];
    [self setInputText:@""];

    // ── Determine feature for entitlement check ───────────────────────────────
    EZFeature feature = EZFeatureChatMini;

    // Classify non-mini chat models for the flat-rate entitlement check path.
    // Note: chat models bypass this block entirely (isChatModel path returns
    // early) — this is only used for images/sora/whisper feature detection.
    if ([self.selectedModel isEqualToString:@"gpt-4o"] ||
        [self.selectedModel isEqualToString:@"gpt-4.1"] ||
        [self.selectedModel isEqualToString:@"gpt-4-turbo"]) {
        feature = EZFeatureChatGPT4o;
    }
    if ([self isGptImage1Family:self.selectedModel] ||
        [self.selectedModel isEqualToString:@"gpt-image-1-edit"] ||
        [self.selectedModel isEqualToString:@"dall-e-2-edit"]) {
        feature = EZFeatureImageMedium;
    }
    // SORA — commented out with the rest of the Sora code.
    // if ([self.selectedModel hasPrefix:@"sora-"]) {
    //     feature = EZFeatureSora10s;
    // }

    // ── Entitlement check moved to callChatCompletions where we know the actual
    // token count from the assembled payload. For image/sora models we still
    // gate here since those don't go through callChatCompletions.
    BOOL isChatModel = ![self isGptImage1Family:self.selectedModel]
        && ![self.selectedModel isEqualToString:@"dall-e-2-edit"]
        && ![self.selectedModel isEqualToString:@"gpt-image-1-edit"]
        && ![self.selectedModel hasPrefix:@"sora-"];

    if (isChatModel) {
        // Chat models — defer entitlement check to callChatCompletions
        // so we can pass the actual assembled token count.
        [self handleSendAuthorized:text];
        return;
    }

    // Non-chat models — check entitlement now with flat cost.
    // For image models, pick the feature tier by quality setting and multiply by n.
    if ([self isGptImage1Family:self.selectedModel] ||
        [self.selectedModel isEqualToString:@"gpt-image-1-edit"] ||
        [self.selectedModel isEqualToString:@"dall-e-2-edit"]) {

        NSUserDefaults *d  = [NSUserDefaults standardUserDefaults];
        NSString *quality  = [d stringForKey:@"imgQuality"] ?: @"auto";
        NSString *size     = [d stringForKey:@"imgSize"]    ?: @"1024x1024";
        NSInteger n        = [d integerForKey:@"imgVariations"];
        if (n < 1) n = 1;

        // Map quality → feature tier
        EZFeature imageFeature;
        if ([quality isEqualToString:@"high"]) {
            imageFeature = EZFeatureImageHigh;
        } else if ([quality isEqualToString:@"low"]) {
            imageFeature = EZFeatureImageLow;
        } else {
            imageFeature = EZFeatureImageMedium; // "auto" or "medium"
        }

        // Non-square sizes cost 25% more — round up to nearest whole image unit
        // so the edge function only needs to multiply by an integer quantity.
        CGFloat sizeMultiplier = [size isEqualToString:@"1024x1024"] ? 1.0 : 1.25;
        NSInteger quantity = (NSInteger)ceil(n * sizeMultiplier);

        BOOL isEdit = [self.selectedModel isEqualToString:@"gpt-image-1-edit"] ||
                      [self.selectedModel isEqualToString:@"dall-e-2-edit"];
        NSString *apiModel = isEdit ? (self.preEditModeModel ?: @"gpt-image-1") : self.selectedModel;

        EZLogf(EZLogLevelInfo, @"COINS",
               @"Image cost: feature=%@ n=%ld size=%@ sizeMultiplier=%.2f quantity=%ld isEdit=%d",
               [self featureLabel:imageFeature], (long)n, size, sizeMultiplier, (long)quantity, isEdit);

        [[EZEntitlementManager shared] checkEntitlementForFeature:imageFeature
                                                         quantity:quantity
                                                           prompt:text
                                                            model:apiModel
                                                          quality:quality
                                                             size:size
                                                           isEdit:isEdit
                                                       completion:^(BOOL allowed,
                                                                    NSInteger balance,
                                                                    NSString *reason) {
            if (!allowed) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.sendButton.enabled = YES;
                    if ([reason isEqualToString:@"Not logged in"]) {
                        [self appendToChat:@"[Error: Please sign in to use EZCompleteUI]"];
                    } else if ([reason isEqualToString:@"Insufficient coins"] ||
                               [reason isEqualToString:@"No account found"]) {
                        [self presentCoinStoreForFeature:nil];
                    } else {
                        [self appendToChat:[NSString stringWithFormat:
                            @"[Error: %@]", reason ?: @"Access denied-please close app and log back in,"]];
                    }
                });
                return;
            }
            [self handleSendAuthorized:text];
        }];
        return;
    }

    [[EZEntitlementManager shared] checkEntitlementForFeature:feature
                                                         quantity:1
                                                           prompt:text
                                                            model:self.selectedModel
                                                       completion:^(BOOL allowed,
                                                                    NSInteger balance,
                                                                    NSString *reason) {
            if (!allowed) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.sendButton.enabled = YES;
                    if ([reason isEqualToString:@"Not logged in"]) {
                        [self appendToChat:@"[Error: Please sign in to use EZCompleteUI]"];
                    } else if ([reason isEqualToString:@"Insufficient coins"] ||
                               [reason isEqualToString:@"No account found"]) {
                        [self presentCoinStoreForFeature:nil];
                    } else {
                        [self appendToChat:[NSString stringWithFormat:
                            @"[Error: %@]", reason ?: @"Access denied-please reopen app and log in."]];
                    }
                });
                return;
            }
            [self handleSendAuthorized:text];
        }];
    }

- (void)handleSendAuthorized:(NSString *)text {

    if (self.isDictating) [self stopDictation];

    // Retrieve the JWT once here so it can be captured by all nested completion
    // blocks without redundant accessToken lookups. Every helper pipeline call
    // (triage, memory search, memory creation) needs it to reach ez-helper.
    NSString *jwtToken = [EZAuthManager shared].accessToken;
    if (!jwtToken) {
        [self appendToChat:@"[Error: Not signed in]"];
        self.sendButton.enabled = YES;
        return;
    }

    self.lastUserPrompt = text;

    // Inject pending file context — every file attached since the last
    // send, not just the most recent one (previously pendingFileContext/
    // pendingFileName were singular, so a second attached file silently
    // discarded the first's extracted text entirely).
    NSString *fullPrompt = text;
    if (self.pendingFiles.count > 0) {
        NSMutableString *filesBlock = [NSMutableString string];
        for (NSDictionary<NSString *, NSString *> *file in self.pendingFiles) {
            [filesBlock appendFormat:@"[Attached file: %@]\n\n%@\n\n",
                file[@"name"], file[@"content"]];
        }
        fullPrompt = [NSString stringWithFormat:@"%@[User question]: %@", filesBlock, text];
        [self.pendingFiles removeAllObjects];
        [self appendToChat:@"[System: File context injected ✓]"];
    }

    [self.chatContext addObject:@{@"role": @"user", @"content": fullPrompt}];

    // ── Guard: Whisper is transcription-only, not a chat model ───────────────
    if ([self.selectedModel isEqualToString:@"whisper-1"]) {
        self.selectedModel = @"gpt-4o";
        [self.modelButton setTitle:@"Model: gpt-4o" forState:UIControlStateNormal];
        [self appendToChat:@"[System: Whisper is for audio transcription only — switched to gpt-4o for chat]"];
    }

    // ── Explicit image edit (a newly attached source image) ──────────────────
    // Edit mode remains visible after a completed edit, but it must not force
    // every later prompt into edit. Without a pending source image, let the
    // image-intent router below choose generate, edit, or reopen instead.
    if ([self.selectedModel isEqualToString:@"gpt-image-1-edit"] &&
        self.pendingImagePaths.count > 0) {
        [self callImageEdit:text imagePath:self.pendingImagePaths.lastObject ?: self.lastImageLocalPath];
        [self.pendingImagePaths removeAllObjects];
        return;
    }

    // ── Legacy dall-e-2-edit fallback ────────────────────────────────────────
    if ([self.selectedModel isEqualToString:@"dall-e-2-edit"]) {
        [self enterImageEditModeFromCurrentSelection];
        [self callImageEdit:text imagePath:self.pendingImagePaths.lastObject ?: self.lastImageLocalPath];
        [self.pendingImagePaths removeAllObjects];
        return;
    }

    // ── Image model intent check ──────────────────────────────────────────────
    BOOL isImageModel = [self isGptImage1Family:self.selectedModel];
    // A pending source image deserves intent routing even if the person had a
    // chat model selected when they attached it. This is what makes “what is
    // this?” stay conversational while “remove the background” becomes an
    // edit, rather than attachment itself deciding for them.
    if (isImageModel || self.pendingImagePaths.count > 0) {
        if (!self.lastImageLocalPath.length) {
            NSString *persisted = [[NSUserDefaults standardUserDefaults]
                                   stringForKey:@"lastImageLocalPath"];
            if (persisted.length > 0 &&
                [[NSFileManager defaultManager] fileExistsAtPath:persisted]) {
                self.lastImageLocalPath = persisted;
            }
        }
        // Was just checking .length > 0 — true for a stale path from
        // earlier in the session whose underlying file no longer exists
        // (cache cleanup, app restart, etc.). Complementary to the
        // pendingImagePaths-gated edit dispatch and exitImageEditModeIfNeeded
        // above/below: those stop a sticky edit-mode UI state from
        // hijacking an unrelated message; this stops a stale-but-non-empty
        // path from making hasLocal falsely true in the intent router
        // itself, which could independently steer a plain generation into
        // edit mode via the classifier even when selectedModel was never
        // stuck on gpt-image-1-edit to begin with.
        NSString *pendingImagePath = self.pendingImagePaths.lastObject;
        BOOL hasLocal = (pendingImagePath.length > 0 &&
                         [[NSFileManager defaultManager] fileExistsAtPath:pendingImagePath]) ||
                        (self.lastImageLocalPath.length > 0 &&
                         [[NSFileManager defaultManager] fileExistsAtPath:self.lastImageLocalPath]);

        [self classifyImageIntent:text hasLocalImage:hasLocal
                       completion:^(NSString *intent) {
            self.sendButton.enabled = YES;
            if ([intent isEqualToString:@"reopen"] && hasLocal) {
                [self exitImageEditModeIfNeeded];
                EZLogf(EZLogLevelInfo, @"IMAGE", @"Intent=reopen → %@",
                       self.lastImageLocalPath.lastPathComponent);
                [self appendToChat:@"[System: Reopening last image ✓]"];
                [self offerToOpenLocalFile:self.lastImageLocalPath];
            } else if ([intent isEqualToString:@"edit"] && hasLocal) {
                EZLogf(EZLogLevelInfo, @"IMAGE", @"Intent=edit → switching to edit mode");
                [self enterImageEditModeFromCurrentSelection];
                NSString *editPath = self.pendingImagePaths.lastObject ?: self.lastImageLocalPath;
                [self.pendingImagePaths removeAllObjects];
                [self callImageEdit:text imagePath:editPath];
            } else if ([intent isEqualToString:@"chat"]) {
                if (isImageModel || ![self modelSupportsVision:self.selectedModel]) {
                    self.selectedModel = @"gpt-5.6-luna";
                    [self.modelButton setTitle:@"Model: gpt-5.6-luna" forState:UIControlStateNormal];
                    [self appendToChat:@"[System: Switched to gpt-5.6-luna to discuss the attached image]"];
                }
                [self callChatCompletions];
            } else {
                EZLogf(EZLogLevelInfo, @"IMAGE", @"Intent=generate");
                [self exitImageEditModeIfNeeded];
                if (![self isGptImage1Family:self.selectedModel]) {
                    self.selectedModel = @"gpt-image-2.5-flare";
                    [self.modelButton setTitle:@"Model: gpt-image-2.5-flare" forState:UIControlStateNormal];
                }
                // Both branches used to diverge here: gpt-image-family
                // models went straight to callGptImage1 with no memory
                // context, while anything else (previously dall-e-3, now
                // removed and unreachable) got the prior-image-prompt
                // context prepended first via callDalle3. With dall-e-3
                // gone, every image model reaches this branch and goes to
                // callGptImage1 — applying memory context to only one of
                // two paths that do the same thing no longer made sense,
                // so this now always applies it.
                if (self.lastImagePrompt.length > 0) {
                    [self fetchRelevantMemories:text
                                    completion:^(NSString *memories) {
                        analyzePromptForContext(text, memories, jwtToken,
                                               self.activeThread.threadID,
                        ^(EZContextResult *result) {
                            NSString *finalPrompt = text;
                            if (result.tier >= EZRoutingTierMemory) {
                                finalPrompt = [NSString stringWithFormat:
                                    @"Previous image prompt was: \"%@\". Now create: %@",
                                    self.lastImagePrompt, text];
                                [self appendToChat:@"[System: Previous image context included ✓]"];
                            }
                            [self callGptImage1:finalPrompt];
                        });
                    }];
                } else {
                    [self callGptImage1:text];
                }
            }
        }];
        return;
    }

    // ── Sora ──────────────────────────────────────────────────────────────────
    // SORA — commented out with the rest of the Sora code (see the big block
    // near callSora's old implementation).
    // if ([self.selectedModel hasPrefix:@"sora-"]) {
    //     [self callSora:fullPrompt];
    //     return;
    // }

    // ── Chat / reasoning models ───────────────────────────────────────────────
    [self fetchRelevantMemories:text completion:^(NSString *memories) {
        analyzePromptForContext(text, memories, jwtToken, self.activeThread.threadID,
        ^(EZContextResult *result) {
            self.sendButton.enabled = YES;
            EZLogf(EZLogLevelInfo, @"SEND",
                   @"Tier %ld — conf=%.2f tokens≈%ld reason: %@",
                   (long)result.tier, result.confidence,
                   (long)result.estimatedTokens, result.reason);

            // Helpers classify only the short typed question, never the full
            // attached-file payload or image bytes. A helper direct answer
            // would therefore bypass the main model without seeing either.
            BOOL hasAttachedFileContext = ![fullPrompt isEqualToString:text];
            BOOL hasPendingImageAttachment = self.pendingImagePaths.count > 0;
            if (result.tier == EZRoutingTierDirect && result.shortCircuitAnswer.length > 0 &&
                !hasAttachedFileContext && !hasPendingImageAttachment) {
                NSString *answer = result.shortCircuitAnswer;
                self.lastAIResponse = answer;
                [self.chatContext addObject:@{@"role": @"assistant", @"content": answer}];
                [self appendToChat:[NSString stringWithFormat:@"AI: %@", answer]];
                [self appendToChat:@"[System: Answered directly by helper model ⚡]"];
                EZLogf(EZLogLevelInfo, @"SEND", @"Tier 1 direct answer displayed");

                NSMutableArray *attachmentsAtSend = [NSMutableArray array];
                if (self.pendingImagePaths.count > 0) {
                    [attachmentsAtSend addObjectsFromArray:self.pendingImagePaths];
                }
                [self.pendingImagePaths removeAllObjects];

                createMemoryFromCompletion(text, answer, jwtToken,
                                           self.activeThread.threadID,
                                           attachmentsAtSend,
                                           ^(NSString *entry) {
                    if (entry) EZLogf(EZLogLevelInfo, @"MEMORY", @"Saved: %lu chars",
                                      (unsigned long)entry.length);
                });
                [self saveActiveThread];
                return;
            }

            // Triage/memory routing enriches the short typed question. When a
            // file was attached, replace that trailing question with the full
            // expanded prompt so the attached file's extracted text reaches
            // ez-chat instead of being silently discarded by this replacement.
            NSString *promptForMainModel = result.finalPrompt;
            if (hasAttachedFileContext && result.tier >= EZRoutingTierMemory) {
                NSRange typedQuestionRange = [promptForMainModel rangeOfString:text
                                                                       options:NSBackwardsSearch];
                if (typedQuestionRange.location != NSNotFound &&
                    NSMaxRange(typedQuestionRange) == promptForMainModel.length) {
                    NSMutableString *withFileContext = [promptForMainModel mutableCopy];
                    [withFileContext replaceCharactersInRange:typedQuestionRange
                                                    withString:fullPrompt];
                    promptForMainModel = [withFileContext copy];
                } else {
                    // Defensive fallback for a future helper prompt format:
                    // preserve the file context even if its user-message
                    // marker changes, rather than ever dropping it.
                    promptForMainModel = [NSString stringWithFormat:
                        @"%@\n\n[Attached file context]\n%@", promptForMainModel, fullPrompt];
                }
            }

            if (result.tier == EZRoutingTierFullHistory &&
                result.injectedHistory.count > 0) {
                if (self.chatContext.count > 0) [self.chatContext removeLastObject];
                NSMutableArray *rebuilt = [NSMutableArray array];
                [rebuilt addObjectsFromArray:result.injectedHistory];
                [rebuilt addObjectsFromArray:self.chatContext];
                [rebuilt addObject:@{@"role": @"user", @"content": promptForMainModel}];
                self.chatContext = rebuilt;
                [self appendToChat:@"[System: Full chat history injected ✓]"];
            } else if (result.tier >= EZRoutingTierMemory) {
                if (self.chatContext.count > 0) [self.chatContext removeLastObject];
                [self.chatContext addObject:@{@"role": @"user",
                                              @"content": promptForMainModel}];
                [self appendToChat:@"[System: Memory context included ✓]"];
            }

            [self callChatCompletions];
        });
    }];
}


// ─────────────────────────────────────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────
// MARK: - EZ Edge Function Helper
// ─────────────────────────────────────────────────────────────────────────────

/// POST JSON body to a Supabase edge function with the user's JWT.
/// Calls completion on the main queue with the parsed JSON response.
/// Handles two failure modes automatically:
///   - Invalid/expired JWT → refreshes session and retries once
///   - Network timeout     → shows "retrying" message and retries once
- (void)postToEZFunction:(NSString *)functionName
                   token:(NSString *)token
                    body:(NSDictionary *)body
              completion:(void(^)(NSDictionary * _Nullable json, NSError * _Nullable error))completion {
    [self postToEZFunction:functionName token:token body:body retryCount:0 completion:completion];
}

- (void)postToEZFunction:(NSString *)functionName
                   token:(NSString *)token
                    body:(NSDictionary *)body
              retryCount:(NSInteger)retryCount
              completion:(void(^)(NSDictionary * _Nullable json, NSError * _Nullable error))completion {
    NSString *urlStr = [NSString stringWithFormat:
        @"https://spuoimtqofhbdzosrbng.supabase.co/functions/v1/%@", functionName];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 240;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];

    NSError *bodyErr;
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:&bodyErr];
    if (bodyErr) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, bodyErr); });
        return;
    }

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {

        // ── Timeout: retry once with a user-visible message ──────────────────
        if (error && (error.code == NSURLErrorTimedOut ||
                      error.code == NSURLErrorNetworkConnectionLost) && retryCount < 1) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendToChat:@"[System: Request timed out — retrying automatically...]"];
                [self postToEZFunction:functionName token:token body:body
                            retryCount:retryCount + 1 completion:completion];
            });
            return;
        }

        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
            return;
        }

        NSError *jsonErr;
        NSDictionary *json = [NSJSONSerialization
            JSONObjectWithData:data ?: [NSData data] options:0 error:&jsonErr];

        // ── Invalid/expired token: refresh session and retry once ────────────
        NSString *errStr = json[@"error"];
        BOOL isTokenError = (errStr && ([errStr isEqualToString:@"Invalid token"] ||
                                        [errStr isEqualToString:@"No auth"] ||
                                        [errStr isEqualToString:@"invalid_token"]));
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if ((isTokenError || http.statusCode == 401) && retryCount < 1) {
            dispatch_async(dispatch_get_main_queue(), ^{
                EZLogf(EZLogLevelInfo, @"AUTH", @"Token expired — refreshing session");
                [[EZAuthManager shared] refreshSessionIfNeeded:^(NSString *newAccessToken, NSError *authError) {
                    if (!authError && newAccessToken.length) {
                        [self postToEZFunction:functionName token:newAccessToken body:body
                                    retryCount:retryCount + 1 completion:completion];
                    } else {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self appendToChat:@"[System: Session expired — please sign in again]"];
                            completion(nil, authError ?: [NSError errorWithDomain:@"EZAuth" code:401
                                userInfo:@{NSLocalizedDescriptionKey: @"Session expired"}]);
                        });
                    }
                }];
            });
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(json, jsonErr);
        });
    }] resume];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Memory Search
// ─────────────────────────────────────────────────────────────────────────────

- (void)fetchRelevantMemories:(NSString *)prompt
                   completion:(void (^)(NSString *memories))completion {
    // Capture the JWT on the calling thread (main thread) before we hop to a
    // background queue. EZThreadSearchMemory needs it to call the AI ranker via
    // ez-helper; without it the ranker is skipped and we fall back to recency only.
    NSString *jwtToken = [EZAuthManager shared].accessToken;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *memories = @"";

        NSString *all = loadMemoryContext(0);
        NSInteger entryCount = 0;
        if (all.length > 0) {
            for (NSString *line in [all componentsSeparatedByString:@"\n"]) {
                if ([line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length > 0) entryCount++;
            }
        }

        if (entryCount >= 5) {
            EZLogf(EZLogLevelInfo, @"MEMORY", @"Semantic search over %ld entries for: %@",
                   (long)entryCount, prompt);
            NSString *searched = EZThreadSearchMemory(prompt, jwtToken);
            memories = searched.length > 0 ? searched : loadMemoryContext(15);
            EZLogf(EZLogLevelInfo, @"MEMORY", @"Search returned %lu chars",
                   (unsigned long)memories.length);
        } else if (entryCount > 0) {
            memories = loadMemoryContext(15);
            EZLogf(EZLogLevelInfo, @"MEMORY", @"Using recency (%ld entries)", (long)entryCount);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(memories);
        });
    });
}

- (void)callChatCompletions {
    [self callChatCompletionsWithRetryCount:0];
}

/// Sends one already-assembled chat turn. A retry reuses chatContext, which
/// already contains the submitted prompt and its attached-file/image content.
- (void)callChatCompletionsWithRetryCount:(NSInteger)retryCount {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    // GPT-5.x models and GPT-6 Astra use the Responses API.
    // "gpt-5-pro" is a ChatGPT subscription tier name, not an API model string —
    // sending it to the API returns a model-not-found error. Remove it from
    // any model picker. Real API strings: gpt-5, gpt-5-mini, gpt-5.4, gpt-5.4-mini,
    // gpt-5.4-nano, gpt-5.5, gpt-5.6-sol, gpt-5.6-terra, gpt-5.6-luna. All are
    // correctly matched by hasPrefix:@"gpt-5".
    BOOL isGPT5 = [self.selectedModel hasPrefix:@"gpt-5"] ||
                  [self.selectedModel isEqualToString:@"gpt-6-astra"];
    // Web search works on gpt-5.x (via Responses API), gpt-4.1.x, and listed gpt-4o models.
    // Prefix checks cover all sub-variants without needing to enumerate each.
    BOOL modelSupportsWebSearch = isGPT5
        || [self.selectedModel hasPrefix:@"gpt-4.1"]
        || [self.selectedModel hasPrefix:@"o3"]
        || [self.selectedModel hasPrefix:@"o4"]
        || [self.selectedModel isEqualToString:@"gpt-4o"]
        || [self.selectedModel isEqualToString:@"gpt-4o-mini"]
        || [self.selectedModel isEqualToString:@"gpt-4-turbo"];
    BOOL useWebSearch    = self.webSearchEnabled && modelSupportsWebSearch;
    // gpt-4.1 family uses the Responses API natively; also required for web search.
    BOOL isGPT41       = [self.selectedModel hasPrefix:@"gpt-4.1"];
    BOOL useResponsesAPI = isGPT5 || isGPT41 || useWebSearch;

    if (self.webSearchEnabled && !modelSupportsWebSearch) {
        [self appendToChat:[NSString stringWithFormat:
            @"[System: Web search skipped — not supported by %@. "
             "Switch to gpt-4o or a gpt-5 model to use web search.]",
            self.selectedModel]];
    }

    NSString *userPreferences = [defaults stringForKey:@"modelPreferences"];
    NSArray *cleanContext = [self sanitizedContextForAPI:self.chatContext
                                     modelSupportsVision:[self modelSupportsVision:self.selectedModel]
                                         useResponsesAPI:useResponsesAPI];

    // The original GPT-4 alias is limited to an 8K context window. GPT-3.5
    // Turbo has a 16,385-token window but allows at most 4,096 output tokens;
    // reserve ample room for the system prompt, completion, and token-estimate
    // variance by retaining no more than ~8K input tokens (24K characters).
    // Newer GPT-4 variants have much larger windows and do not need history
    // pruning here.
    BOOL isLegacyGPT35 = [self.selectedModel hasPrefix:@"gpt-3.5"];
    if ([self.selectedModel isEqualToString:@"gpt-4"] || isLegacyGPT35) {
        NSInteger characterBudget = isLegacyGPT35 ? 24000 : 18000;
        NSMutableArray *newestFirst = [NSMutableArray array];
        NSInteger retainedCharacters = 0;
        for (NSDictionary *message in cleanContext.reverseObjectEnumerator) {
            id content = message[@"content"];
            NSInteger characters = [content isKindOfClass:[NSString class]] ? [content length] : 0;
            if (newestFirst.count > 0 && retainedCharacters + characters > characterBudget) continue;
            [newestFirst addObject:message];
            retainedCharacters += characters;
        }
        cleanContext = newestFirst.reverseObjectEnumerator.allObjects;
    }

    // Token estimation: sum content character lengths across all messages,
    // then divide by 4 (standard ~4 chars/token heuristic).
    // Counting content characters (not serialized JSON bytes) avoids the
    // 25-40% JSON-overhead inflation that was causing false "insufficient coins"
    // errors on long GPT-5 conversations — JSON key names, quotes, brackets,
    // and escape chars all inflate contextData.length without adding real tokens.
    NSInteger contentCharCount = 0;
    for (NSDictionary *contextMsg in cleanContext) {
        id msgContent = contextMsg[@"content"];
        if ([msgContent isKindOfClass:[NSString class]]) {
            contentCharCount += ((NSString *)msgContent).length;
        } else if ([msgContent isKindOfClass:[NSArray class]]) {
            // Vision message — sum text blocks only
            for (NSDictionary *block in (NSArray *)msgContent) {
                NSString *blockText = block[@"text"];
                if (blockText.length > 0) contentCharCount += blockText.length;
            }
        }
    }
    NSInteger inputEstimate  = contentCharCount / 4;
    NSInteger outputEstimate = isGPT5 ? 1500 : 800;
    NSInteger totalEstimate  = inputEstimate + outputEstimate;

    // Legacy `gpt-4` has an 8,192-token context window.  ez-chat previously
    // defaulted every model to an 8,000-token completion, which is impossible
    // once even a short prompt is included.  Reserve conservative room for the
    // messages and server instructions, then pass an explicit safe completion
    // limit to the edge function.
    NSInteger maxCompletionTokens = 8000;
    if ([self.selectedModel isEqualToString:@"gpt-4"]) {
        NSInteger conservativeInputEstimate = MAX(inputEstimate, (contentCharCount + 2) / 3);
        maxCompletionTokens = MIN(6000, MAX(256, 8192 - conservativeInputEstimate - 512));
    } else if (isLegacyGPT35) {
        // Official GPT-3.5 Turbo limit: 16,385 total context / 4,096 output.
        // The server independently clamps this too, so a modified client
        // cannot recreate the context-window error.
        maxCompletionTokens = 4096;
    } else if ([self.selectedModel hasPrefix:@"gpt-4"]) {
        // GPT-4 mini and GPT-4 Turbo deployments cap one completion at 4,096
        // tokens. Use that safe ceiling for all non-legacy GPT-4 variants,
        // rather than inheriting ez-chat's historical 8,000-token default.
        maxCompletionTokens = 4096;
    }

    // featureTier is only used for logging context in ez-chat.
    // Actual coin cost is computed per exact model string server-side.
    NSString *featureTier;
    if ([self.selectedModel hasPrefix:@"o1"] || [self.selectedModel hasPrefix:@"o3"]) {
        featureTier = @"chat_premium"; // reasoning models
    } else if (isGPT5) {
        // gpt-5, gpt-5.4, gpt-5.5 = premium; mini/nano variants = mini.
        // gpt-5.6 broke the suffix convention (sol/terra/luna instead of
        // base/-mini/-nano), so it needs an explicit name check rather than
        // hasSuffix — a future gpt-5.7 etc. renamed the same way will need
        // its own line here too.
        static NSSet<NSString *> *cheapGPT56Tiers;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            cheapGPT56Tiers = [NSSet setWithObjects:@"gpt-5.6-luna", nil];
        });
        if ([self.selectedModel hasSuffix:@"-mini"] ||
            [self.selectedModel hasSuffix:@"-nano"] ||
            [cheapGPT56Tiers containsObject:self.selectedModel]) {
            featureTier = @"chat_mini";
        } else {
            featureTier = @"chat_premium";
        }
    } else if ([self.selectedModel isEqualToString:@"gpt-4o-mini"] ||
               [self.selectedModel isEqualToString:@"gpt-4o-mini-2024-07-18"] ||
               [self.selectedModel isEqualToString:@"gpt-4.1-mini"] ||
               [self.selectedModel isEqualToString:@"gpt-4.1-nano"] ||
               [self.selectedModel hasPrefix:@"o4-mini"]) {
        featureTier = @"chat_mini";
    } else {
        featureTier = @"chat_standard";
    }

    EZLogf(EZLogLevelInfo, @"COINS",
           @"Token estimate: input=%ld output=%ld total=%ld tier=%@",
           (long)inputEstimate, (long)outputEstimate, (long)totalEstimate, featureTier);

    NSString *capturedPrompt      = self.lastUserPrompt;
    NSString *capturedThreadID    = self.activeThread.threadID;
    NSMutableArray *capturedAttachments = [NSMutableArray array];
    if (self.pendingImagePaths.count > 0) [capturedAttachments addObjectsFromArray:self.pendingImagePaths];
    [self.pendingImagePaths removeAllObjects];

    if (isGPT5) { dispatch_async(dispatch_get_main_queue(), ^{ [self showGPT5StatusBanner]; }); }

    // Build ez-chat request body
    NSMutableDictionary *ezBody = [NSMutableDictionary dictionary];
    ezBody[@"model"]            = self.selectedModel;
    ezBody[@"messages"]         = cleanContext;
    ezBody[@"estimated_tokens"] = @(totalEstimate);
    ezBody[@"max_tokens"]        = @(maxCompletionTokens);
    ezBody[@"feature_tier"]     = featureTier;
    if (userPreferences.length > 0) ezBody[@"user_preferences"] = userPreferences;
    if (useWebSearch)           ezBody[@"web_search"] = @YES;
    if (capturedPrompt.length > 0) {
        NSUInteger cap = MIN(capturedPrompt.length, 120);
        ezBody[@"prompt_preview"] = [capturedPrompt substringToIndex:cap];
    }
    NSString *loc = [defaults stringForKey:@"webSearchLocation"] ?: @"";
    if (loc.length > 0) ezBody[@"location"] = loc;

    NSString *safetyIdentifier = ez_safetyIdentifierForUserId([EZAuthManager shared].userId);
    if (safetyIdentifier.length > 0) ezBody[@"safety_identifier"] = safetyIdentifier;

    NSString *token = [EZAuthManager shared].accessToken;
    if (!token) { [self handleAPIError:@"Not signed in"]; return; }

    NSURL *ezURL = [NSURL URLWithString:@"https://spuoimtqofhbdzosrbng.supabase.co/functions/v1/ez-chat"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:ezURL];
    request.HTTPMethod = @"POST";
    BOOL isHeavyReasoningModel = [self.selectedModel isEqualToString:@"gpt-5.6-sol"] ||
                                  [self.selectedModel isEqualToString:@"gpt-6-astra"];
    // Leave headroom beyond ez-chat's server-side OpenAI deadline. Previously
    // the 90s/180s client deadlines could cancel a request the server was still
    // legitimately processing, producing the misleading local timeout error.
    if ((isGPT5 && useWebSearch) || isHeavyReasoningModel) request.timeoutInterval = 350;
    else if (isGPT5)                                        request.timeoutInterval = 350;
    else                                                     request.timeoutInterval = 250;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:ezBody options:0 error:nil];

    EZLogf(EZLogLevelInfo, @"API", @"→ ez-chat [%@]%@", self.selectedModel, useWebSearch ? @" +web" : @"");
    dispatch_async(dispatch_get_main_queue(), ^{ self.sendButton.enabled = NO; });

    [[[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self hideGPT5StatusBanner]; });

        BOOL isTransientConnectionError = error &&
            (error.code == NSURLErrorTimedOut ||
             error.code == NSURLErrorNetworkConnectionLost ||
             error.code == NSURLErrorCannotConnectToHost ||
             error.code == NSURLErrorNotConnectedToInternet);
        if (isTransientConnectionError && retryCount < 1) {
            EZLogf(EZLogLevelWarning, @"API", @"Transient chat failure (%@); retrying once", error.localizedDescription);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendToChat:@"[System: Connection interrupted — retrying your request automatically...]"];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [self callChatCompletionsWithRetryCount:retryCount + 1];
                });
            });
            return;
        }

        if (error) { [self handleAPIError:error.localizedDescription]; return; }

        NSError *jsonErr;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data ?: [NSData data]
                                                             options:0 error:&jsonErr];
        if (jsonErr || !json) { [self handleAPIError:@"Could not parse API response"]; return; }

        id errObj = json[@"error"];
        if (errObj && ![errObj isKindOfClass:[NSNull class]]) {
            NSString *errMsg = [errObj isKindOfClass:[NSString class]] ? errObj : @"API error";
            // ez-chat returns this only after its own OpenAI deadline and
            // refund path. Retrying the preserved client request is safe.
            if ([errMsg isEqualToString:@"Request timed out"] && retryCount < 1) {
                EZLog(EZLogLevelWarning, @"API", @"ez-chat timed out; retrying once");
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self appendToChat:@"[System: The model took too long — retrying your request automatically...]"];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        [self callChatCompletionsWithRetryCount:retryCount + 1];
                    });
                });
                return;
            }
            // Insufficient coins — show store
            if ([errMsg isEqualToString:@"Insufficient coins"] ||
                [json[@"reason"] isEqualToString:@"Insufficient coins"]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self presentCoinStoreForFeature:featureTier];
                });
            } else {
                [self handleAPIError:errMsg];
            }
            return;
        }

        NSString *reply = json[@"reply"];
        if (!reply.length) {
            EZLogf(EZLogLevelError, @"API", @"No reply in ez-chat response: %@", json);
            [self handleAPIError:@"Unexpected response format"]; return;
        }

        // Update balance from response
        id balanceObj = json[@"balance"];
        if (balanceObj && ![balanceObj isKindOfClass:[NSNull class]]) {
            [[EZEntitlementManager shared] applyKnownBalance:[balanceObj integerValue]];
        }

        EZLogf(EZLogLevelInfo, @"API", @"Reply %lu chars", (unsigned long)reply.length);

        dispatch_async(dispatch_get_main_queue(), ^{
            self.sendButton.enabled = YES;
            self.lastAIResponse = reply;
            [self.chatContext addObject:@{@"role": @"assistant", @"content": reply}];

            NSMutableArray<NSString *> *codePaths = [NSMutableArray array];
            NSString *displayReply = [self processReplyWithCodeBlocks:reply savedPaths:codePaths];

            NSMutableArray *allAttachments = [capturedAttachments mutableCopy];
            for (NSString *p in codePaths) {
                if (![allAttachments containsObject:p]) [allAttachments addObject:p];
            }

            [self appendToChat:[NSString stringWithFormat:@"AI: %@", displayReply]];
            [self saveActiveThread];
            [self checkReplyForLocalFilePaths:reply];
            [self updateCoinBalanceDisplay];
        });

        createMemoryFromCompletion(capturedPrompt ?: @"", reply, token, capturedThreadID,
                                   capturedAttachments,
        ^(NSString *entry) {
            if (entry) EZLogf(EZLogLevelInfo, @"MEMORY", @"Saved %lu chars",
                              (unsigned long)entry.length);
        });
    }] resume];
}
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - GPT Image Text-to-Image Generation (gpt-image-1/1.5/mini/2/2.5)
// ─────────────────────────────────────────────────────────────────────────────

- (void)callGptImage1:(NSString *)prompt {
    EZLog(EZLogLevelInfo, @"GPTIMAGE", @"Sending generation request via ez-image");

    NSString *token = [EZAuthManager shared].accessToken;
    if (!token) { [self handleAPIError:@"Not signed in"]; return; }

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *imgSize    = [d stringForKey:@"imgSize"]       ?: @"1024x1024";
    NSString *imgQuality = [d stringForKey:@"imgQuality"]    ?: @"auto";
    NSString *imgFormat  = [d stringForKey:@"imgFormat"]     ?: @"png";
    NSString *imgBg      = [d stringForKey:@"imgBackground"] ?: @"auto";
    NSString *imgExtension = [imgFormat isEqualToString:@"jpeg"] ? @"jpg" : imgFormat;
    NSString *imgModel   = self.selectedModel;
    if ([imgModel isEqualToString:@"gpt-image-1-edit"]) imgModel = self.preEditModeModel ?: @"gpt-image-1";
    NSInteger imgN = [d integerForKey:@"imgVariations"];
    if (imgN < 1 || imgN > 4) imgN = 1;

    [self appendToChat:[NSString stringWithFormat:@"[System: Generating image with %@...]", imgModel]];

    NSMutableDictionary *body = [@{
        @"action":        @"generate",
        @"model":         imgModel,
        @"prompt":        prompt,
        @"n":             @(imgN),
        @"size":          imgSize,
        @"quality":       imgQuality,
        @"output_format": imgFormat,
        @"background":    imgBg,
    } mutableCopy];

    NSString *savedPrompt = prompt;
    [self showImageGenStatusBanner];
    [self postToEZFunction:@"ez-image" token:token body:body
                completion:^(NSDictionary *json, NSError *error) {
        [self hideStatusBanner];
        if (error) { [self handleAPIError:error.localizedDescription]; return; }
        id errObj = json[@"error"];
        if (errObj && ![errObj isKindOfClass:[NSNull class]]) {
            NSString *errMsg = [errObj isKindOfClass:[NSString class]] ? errObj : @"Image error";
            // ez-image reports whether coins were refunded in "reason",
            // which was never being shown to the user for image
            // generation failures until this fix.
            NSString *reason = json[@"reason"];
            NSString *fullMsg = reason.length ? [NSString stringWithFormat:@"%@ %@", errMsg, reason] : errMsg;
            [self handleAPIError:fullMsg];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendImageGridToChat:@[] prompt:savedPrompt isError:YES errorText:fullMsg];
            });
            return;
        }

        id balanceObj = json[@"balance"];
        if (balanceObj && ![balanceObj isKindOfClass:[NSNull class]])
            [[EZEntitlementManager shared] applyKnownBalance:[balanceObj integerValue]];

        NSArray *images = json[@"images"];
        if (!images.count) {
            NSString *errMsg = @"No image in response";
            [self handleAPIError:errMsg];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendImageGridToChat:@[] prompt:savedPrompt isError:YES errorText:errMsg];
            });
            return;
        }

        // Download each signed URL and save locally
        NSMutableArray<NSString *> *savedPaths = [NSMutableArray array];
        for (NSDictionary *imgObj in images) {
            NSString *signedURL = imgObj[@"url"];
            if (!signedURL.length) continue;
            NSData *imgData = [NSData dataWithContentsOfURL:[NSURL URLWithString:signedURL]];
            if (!imgData) continue;
            NSString *fname = [NSString stringWithFormat:@"gptimage_%lu.%@",
                               (unsigned long)savedPaths.count + 1, imgExtension];
            NSString *path = EZPhotoGallerySave(imgData, fname);
            if (path) [savedPaths addObject:path];
        }

        NSString *firstPath = savedPaths.firstObject;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.lastImagePrompt = savedPrompt;
            if (firstPath) {
                self.lastImageLocalPath = firstPath;
                self.activeThread.lastImageLocalPath = firstPath;
                NSMutableArray *att = [self.activeThread.attachmentPaths mutableCopy];
                [att addObjectsFromArray:savedPaths];
                self.activeThread.attachmentPaths = [att copy];
                [self saveActiveThread];
                [self persistImagePath:firstPath prompt:savedPrompt];
                // Preserve prompt metadata for every variation so sharing any
                // result from the gallery can include its original prompt.
                NSMutableDictionary *promptMap = [[[NSUserDefaults standardUserDefaults]
                    dictionaryForKey:@"EZGalleryImagePrompts"] mutableCopy] ?: [NSMutableDictionary dictionary];
                for (NSString *path in savedPaths) promptMap[path] = savedPrompt ?: @"";
                [[NSUserDefaults standardUserDefaults] setObject:promptMap forKey:@"EZGalleryImagePrompts"];

                // Was previously missing entirely — image generation memory
                // entries (this and the edit-mode one below) were only ever
                // wired to DALL-E-3's now-removed download path.
                NSString *answer = [NSString stringWithFormat:
                    @"Generated %lu image(s) for: %@", (unsigned long)savedPaths.count, savedPrompt];
                createMemoryFromCompletion(savedPrompt ?: @"", answer, token,
                                           self.activeThread.threadID, [savedPaths copy],
                ^(NSString *entry) {
                    if (entry) EZLogf(EZLogLevelInfo, @"MEMORY", @"Saved (image gen): %lu chars",
                                      (unsigned long)entry.length);
                });
            }
            if (savedPaths.count > 0) {
                [self appendImageGridToChat:[savedPaths copy]
                                     prompt:savedPrompt isError:NO errorText:nil];
            } else {
                NSString *errMsg = @"Image generated but could not be saved.";
                [self appendImageGridToChat:@[] prompt:savedPrompt isError:YES errorText:errMsg];
            }
            [self updateCoinBalanceDisplay];
        });
    }];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Image Edit (gpt-image-1/1.5/mini/2/2.5-flare/2.5-sunburst)
// ─────────────────────────────────────────────────────────────────────────────

- (void)callImageEdit:(NSString *)prompt imagePath:(NSString *)imagePath {
    if (!imagePath) {
        self.sendButton.enabled = YES;
        [self appendToChat:@"[Error: No image attached for editing]"]; return;
    }
    [self appendToChat:[NSString stringWithFormat:
        @"[System: Editing image with %@...]", self.preEditModeModel ?: @"gpt-image-1"]];
    EZLog(EZLogLevelInfo, @"IMGEDIT", @"Sending image edit request via ez-image");

    NSString *token = [EZAuthManager shared].accessToken;
    if (!token) { [self handleAPIError:@"Not signed in"]; return; }

    NSData *imageData = [NSData dataWithContentsOfFile:imagePath]
                     ?: [NSData dataWithContentsOfURL:[NSURL fileURLWithPath:imagePath]];
    if (!imageData) {
        self.sendButton.enabled = YES;
        [self appendToChat:@"[Error: Could not read image for editing]"]; return;
    }
    UIImage *img = [UIImage imageWithData:imageData];
    if (!img) { self.sendButton.enabled = YES; [self appendToChat:@"[Error: Could not decode image for editing]"]; return; }
    NSData *pngData = UIImagePNGRepresentation(img);
    if (!pngData) { self.sendButton.enabled = YES; [self appendToChat:@"[Error: Could not convert image to PNG]"]; return; }

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *editSize = [d stringForKey:@"imgSize"]        ?: @"1024x1024";
    NSString *editQual = [d stringForKey:@"imgQuality"]     ?: @"auto";
    NSString *editFmt  = [d stringForKey:@"imgFormat"]      ?: @"png";
    NSString *editBg   = [d stringForKey:@"imgBackground"]  ?: @"auto";
    NSString *editMod  = [d stringForKey:@"imgModeration"]  ?: @"low";
    NSString *editExtension = [editFmt isEqualToString:@"jpeg"] ? @"jpg" : editFmt;
    NSInteger editN    = [d integerForKey:@"imgVariations"];
    if (editN < 1 || editN > 4) editN = 1;

    NSString *b64Image = [pngData base64EncodedStringWithOptions:0];

    NSDictionary *body = @{
        @"action":        @"edit",
        // Was hardcoded to gpt-image-1 regardless of what the user picked —
        // now sends whatever enterImageEditModeFromCurrentSelection
        // remembered as the real model active before edit mode started.
        @"model":         self.preEditModeModel ?: @"gpt-image-1",
        @"prompt":        prompt,
        @"image_b64":     b64Image,
        @"n":             @(editN),
        @"size":          editSize,
        @"quality":       editQual,
        @"output_format": editFmt,
        @"background":    editBg,
        @"moderation":    editMod,
    };

    [self showImageGenStatusBanner];
    [self postToEZFunction:@"ez-image" token:token body:body
                completion:^(NSDictionary *json, NSError *error) {
        [self hideStatusBanner];
        if (error) { [self handleAPIError:error.localizedDescription]; return; }
        id errObj = json[@"error"];
        if (errObj && ![errObj isKindOfClass:[NSNull class]]) {
            NSString *errMsg = [errObj isKindOfClass:[NSString class]] ? errObj : @"Image edit error";
            // See the generation error path's comment above (callGptImage1)
            // for why this matters.
            NSString *reason = json[@"reason"];
            NSString *fullMsg = reason.length ? [NSString stringWithFormat:@"%@ %@", errMsg, reason] : errMsg;
            [self handleAPIError:fullMsg];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendImageGridToChat:@[] prompt:prompt isError:YES errorText:fullMsg];
            });
            return;
        }

        id balanceObj = json[@"balance"];
        if (balanceObj && ![balanceObj isKindOfClass:[NSNull class]])
            [[EZEntitlementManager shared] applyKnownBalance:[balanceObj integerValue]];

        NSArray *images = json[@"images"];
        if (!images.count) {
            NSString *errMsg = @"No image in edit response";
            [self handleAPIError:errMsg];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendImageGridToChat:@[] prompt:prompt isError:YES errorText:errMsg];
            });
            return;
        }

        NSMutableArray<NSString *> *savedPaths = [NSMutableArray array];
        for (NSDictionary *imgObj in images) {
            NSString *signedURL = imgObj[@"url"];
            if (!signedURL.length) continue;
            NSData *imgData = [NSData dataWithContentsOfURL:[NSURL URLWithString:signedURL]];
            if (!imgData) continue;
            NSString *fname = [NSString stringWithFormat:@"edit_%lu.%@",
                               (unsigned long)savedPaths.count + 1, editExtension];
            NSString *path = EZPhotoGallerySave(imgData, fname);
            if (path) [savedPaths addObject:path];
        }

        NSString *firstPath = savedPaths.firstObject;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.lastImagePrompt = prompt;
            self.selectedModel   = @"gpt-image-1-edit";
            [self.modelButton setTitle:[NSString stringWithFormat:@"Model: %@ (edit mode)",
                                         self.preEditModeModel ?: @"gpt-image-1"]
                              forState:UIControlStateNormal];
            [self appendToChat:@"[System: Edit complete — still in edit mode. Attach a new image or type another edit prompt.]"];
            if (firstPath) {
                self.lastImageLocalPath = firstPath;
                self.activeThread.lastImageLocalPath = firstPath;
                NSMutableArray *att = [self.activeThread.attachmentPaths mutableCopy];
                [att addObjectsFromArray:savedPaths];
                self.activeThread.attachmentPaths = [att copy];
                [self saveActiveThread];
                [self persistImagePath:firstPath prompt:prompt];
                NSMutableDictionary *promptMap = [[[NSUserDefaults standardUserDefaults]
                    dictionaryForKey:@"EZGalleryImagePrompts"] mutableCopy] ?: [NSMutableDictionary dictionary];
                for (NSString *path in savedPaths) promptMap[path] = prompt ?: @"";
                [[NSUserDefaults standardUserDefaults] setObject:promptMap forKey:@"EZGalleryImagePrompts"];

                // Was previously missing entirely, same as generation —
                // see the comment above the other createMemoryFromCompletion
                // call site in this file.
                NSString *answer = [NSString stringWithFormat:
                    @"Edited the attached image per: %@", prompt];
                createMemoryFromCompletion(prompt ?: @"", answer, token,
                                           self.activeThread.threadID, [savedPaths copy],
                ^(NSString *entry) {
                    if (entry) EZLogf(EZLogLevelInfo, @"MEMORY", @"Saved (image edit): %lu chars",
                                      (unsigned long)entry.length);
                });
            }
            if (savedPaths.count > 0) {
                [self appendImageGridToChat:[savedPaths copy] prompt:prompt isError:NO errorText:nil];
            } else {
                NSString *errMsg = @"Edit produced no image output.";
                [self appendImageGridToChat:@[] prompt:prompt isError:YES errorText:errMsg];
            }
            [self updateCoinBalanceDisplay];
        });
    }];
}

/* ═══════════════════════════════════════════════════════════════════════════
   SORA — commented out, not deleted, per request. User removed Sora from
   Settings on their own; OpenAI's Sora API is also scheduled for shutdown
   2026-09-24 regardless, so this needed to come out either way.

   Kept as a block comment rather than deleted because Sora's call shape —
   submit a prompt as an async job, poll a status endpoint until it's ready,
   download the finished asset — is close to how most other video-gen APIs
   work too (Runway, Luma Dream Machine, Kling, Veo via Vertex/Gemini). The
   exact endpoints/field names below are Sora-specific and would need real
   rewriting for a different provider, but the polling loop shape, the
   backgrounded-job-resume pattern, and the refund-on-failure handling may
   be worth adapting rather than rebuilding from scratch if/when a
   replacement video API gets added.

   To fully remove instead of just disabling: this comment block, its
   forward declarations (downloadAndShowVideo: above, and the earlier
   callSora:/property/model-list/dispatch spots — search this file for
   "SORA —" to find all of them), and the pendingVideoURL/lastVideoPrompt
   properties can all come out together.
   ═══════════════════════════════════════════════════════════════════════════

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Sora Text-to-Video (always async job)
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// Sora 2 API spec:
//   sora-2:     "seconds" param as STRING — "4" | "8" | "12" | "16"
//   sora-2-pro: "seconds" param as STRING — "5" | "10" | "15" | "20"
//   "size" param: "480p" | "720p" | "1080p"
// Endpoint: POST /v1/videos  →  async job {id, status:"queued"}
// Poll:     GET  /v1/videos/{id}
// Content:  GET  /v1/videos/{id}/content
// ─────────────────────────────────────────────────────────────────────────────

- (void)callSora:(NSString *)prompt {
    [self appendToChat:@"[System: Submitting Sora 2 video job...]"];
    EZLog(EZLogLevelInfo, @"SORA", @"Sending request via ez-sora");

    NSString *token = [EZAuthManager shared].accessToken;
    if (!token) { [self handleAPIError:@"Not signed in"]; return; }

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *videoModel = [d stringForKey:@"soraModel"] ?: @"sora-2";
    NSString *resolution = [d stringForKey:@"soraSize"]  ?: @"720p";
    NSInteger rawDur     = [d integerForKey:@"soraDuration"] ?: 4;

    NSString *secondsStr;
    BOOL isPro = [videoModel isEqualToString:@"sora-2-pro"];
    if (isPro) {
        NSArray<NSNumber *> *valid = @[@5, @10, @15, @20];
        NSInteger best = 5, bestDiff = NSIntegerMax;
        for (NSNumber *v in valid) {
            NSInteger diff = ABS(rawDur - v.integerValue);
            if (diff < bestDiff) { bestDiff = diff; best = v.integerValue; }
        }
        secondsStr = [NSString stringWithFormat:@"%ld", (long)best];
    } else {
        NSArray<NSNumber *> *valid = @[@4, @8, @12, @16];
        NSInteger best = 4, bestDiff = NSIntegerMax;
        for (NSNumber *v in valid) {
            NSInteger diff = ABS(rawDur - v.integerValue);
            if (diff < bestDiff) { bestDiff = diff; best = v.integerValue; }
        }
        secondsStr = [NSString stringWithFormat:@"%ld", (long)best];
    }

    NSArray<NSString *> *validRes = @[@"1280x720", @"720x1280", @"1024x1792", @"1792x1024"];
    if (![validRes containsObject:resolution]) {
        NSDictionary *resMap = @{
            @"480p": @"1280x720", @"720p": @"1280x720", @"1080p": @"1792x1024",
            @"portrait": @"720x1280", @"landscape": @"1280x720",
            @"1280x720": @"1280x720", @"1920x1080": @"1792x1024"
        };
        resolution = resMap[resolution] ?: @"1280x720";
    }

    if (rawDur != secondsStr.integerValue) {
        [self appendToChat:[NSString stringWithFormat:
            @"[System: Duration snapped to %@s (valid for %@)]", secondsStr, videoModel]];
    }

    NSDictionary *body = @{
        @"action":   @"create",
        @"model":    videoModel,
        @"prompt":   prompt,
        @"size":     resolution,
        @"seconds":  secondsStr,
    };

    [self postToEZFunction:@"ez-sora" token:token body:body
                completion:^(NSDictionary *json, NSError *error) {
        if (error) { [self handleAPIError:error.localizedDescription]; return; }
        id errObj = json[@"error"];
        if (errObj && ![errObj isKindOfClass:[NSNull class]]) {
            [self handleAPIError:[errObj isKindOfClass:[NSString class]] ? errObj : @"Sora error"];
            return;
        }

        NSString *jobId = json[@"job_id"];
        if (!jobId.length) { [self handleAPIError:@"Sora returned no job ID"]; return; }

        id balanceObj = json[@"balance"];
        if (balanceObj && ![balanceObj isKindOfClass:[NSNull class]])
            [[EZEntitlementManager shared] applyKnownBalance:[balanceObj integerValue]];

        [[NSUserDefaults standardUserDefaults] setObject:jobId forKey:@"soraActivejobId"];
        [[NSUserDefaults standardUserDefaults] setObject:json[@"log_id"] ?: @"" forKey:@"soraActiveLogId"];
        [[NSUserDefaults standardUserDefaults] synchronize];

        EZLogf(EZLogLevelInfo, @"SORA", @"Job created: %@  status: %@", jobId, json[@"status"] ?: @"?");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendToChat:[NSString stringWithFormat:
                @"[Sora: Job queued (%@) — polling for completion...]", jobId]];
        });
        [self pollSoraJob:jobId token:token];
    }];
}

- (void)pollSoraJob:(NSString *)jobId token:(NSString *)token {
    __block NSInteger attempts = 0;
    dispatch_queue_t q = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    __block __weak void (^weakPoll)(void);
    void (^poll)(void);
    poll = ^{
        void (^strongPoll)(void) = weakPoll;
        if (!strongPoll) return;
        attempts++;
        if (attempts > 36) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendToChat:@"[Sora: Generation is taking unusually long. "
                 "Check platform.openai.com/storage for your video.]"];
            });
            return;
        }
        NSTimeInterval delay = (attempts <= 6) ? 5.0 : 10.0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), q, ^{
            NSDictionary *pollBody = @{ @"action": @"poll", @"job_id": jobId };
            [self postToEZFunction:@"ez-sora" token:token body:pollBody
                        completion:^(NSDictionary *jd, NSError *err) {
                void (^s)(void) = weakPoll;
                if (err || !jd) { if (s) s(); return; }

                NSString *status = jd[@"status"] ?: @"";
                EZLogf(EZLogLevelInfo, @"SORA", @"Poll %ld — status: %@", (long)attempts, status);

                static NSString *lastShownStatus = nil;
                if (![status isEqualToString:lastShownStatus]) {
                    lastShownStatus = [status copy];
                    NSString *emoji = [status isEqualToString:@"queued"]     ? @"⏳" :
                                      [status isEqualToString:@"processing"] ? @"⚙️" :
                                      ([status isEqualToString:@"completed"] ||
                                       [status isEqualToString:@"succeeded"] ||
                                       [status isEqualToString:@"ready"])    ? @"✅" :
                                      ([status isEqualToString:@"failed"] ||
                                       [status isEqualToString:@"error"])    ? @"❌" : @"🔄";
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self appendToChat:[NSString stringWithFormat:@"[Sora: %@ %@]", emoji, status]];
                    });
                }

                if ([status isEqualToString:@"failed"] || [status isEqualToString:@"error"]) {
                    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"soraActivejobId"];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self appendToChat:@"[Sora failed: video generation error]"];
                    });
                    return;
                }

                BOOL done = ([status isEqualToString:@"completed"] ||
                             [status isEqualToString:@"succeeded"] ||
                             [status isEqualToString:@"ready"]);
                if (done) {
                    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"soraActivejobId"];
                    EZLogf(EZLogLevelInfo, @"SORA", @"Job complete — fetching content");
                    NSString *logId = [[NSUserDefaults standardUserDefaults] stringForKey:@"soraActiveLogId"];
                    [self fetchSoraContent:jobId logId:logId token:token];
                    return;
                }
                if (s) s();
            }];
        });
    };
    weakPoll = poll;
    poll();
}

- (void)resumePendingSoraJobIfNeeded {
    if (!self.isViewLoaded || !self.view.window) return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *jobId   = [d stringForKey:@"soraActivejobId"];
    NSString *token   = [EZAuthManager shared].accessToken;
    if (!jobId.length || !token.length) return;
    EZLogf(EZLogLevelInfo, @"SORA", @"Resuming poll for job: %@", jobId);
    [self appendToChat:[NSString stringWithFormat:@"[Sora: Resuming poll for job %@...]", jobId]];
    [self pollSoraJob:jobId token:token];
}

- (void)fetchSoraContent:(NSString *)jobId logId:(NSString *)logId token:(NSString *)token {
    NSMutableDictionary *fetchBody = [@{ @"action": @"fetch", @"job_id": jobId } mutableCopy];
    if (logId.length) fetchBody[@"log_id"] = logId;

    [self postToEZFunction:@"ez-sora" token:token body:fetchBody
                completion:^(NSDictionary *json, NSError *error) {
        if (error) { [self handleAPIError:error.localizedDescription]; return; }
        id errObj = json[@"error"];
        if (errObj && ![errObj isKindOfClass:[NSNull class]]) {
            [self handleAPIError:[errObj isKindOfClass:[NSString class]] ? errObj : @"Sora fetch error"];
            return;
        }

        // ez-sora returns a signed URL — download directly from Supabase Storage
        NSString *signedURL = json[@"url"];
        if (signedURL.length) {
            [self downloadAndShowVideo:signedURL];
        } else {
            [self handleAPIError:@"Could not retrieve Sora video URL"];
        }
    }];
}

// MARK: - Image Download / Save / QuickLook
// ─────────────────────────────────────────────────────────────────────────────

- (void)downloadAndShowVideo:(NSString *)urlString {
    EZLog(EZLogLevelInfo, @"SORA", @"Downloading video...");
    [[[NSURLSession sharedSession] downloadTaskWithURL:[NSURL URLWithString:urlString]
        completionHandler:^(NSURL *location, NSURLResponse *resp, NSError *err) {
        if (!location) { [self handleAPIError:@"Video download failed"]; return; }
        NSURL *tmp = [NSURL fileURLWithPath:
            [NSTemporaryDirectory() stringByAppendingPathComponent:@"sora_gen.mp4"]];
        [[NSFileManager defaultManager] removeItemAtURL:tmp error:nil];
        [[NSFileManager defaultManager] copyItemAtURL:location toURL:tmp error:nil];

        NSData *videoData = [NSData dataWithContentsOfURL:tmp];
        if (videoData) {
            NSString *savedPath = EZAttachmentSave(videoData, @"sora_video.mp4");
            if (savedPath) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.activeThread.lastVideoLocalPath = savedPath;
                    [self saveActiveThread];
                });
            }
        }

        EZLog(EZLogLevelInfo, @"SORA", @"Video ready");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendToChat:@"[Sora: Video ready ✓]"];
            if (self.view.window) {
                self.previewURL = tmp;
                QLPreviewController *ql = [[QLPreviewController alloc] init];
                ql.dataSource = self;
                [self presentViewController:ql animated:YES completion:nil];
                EZLog(EZLogLevelInfo, @"SORA", @"Video presented immediately");
            } else {
                self.pendingVideoURL = tmp;
                EZLog(EZLogLevelInfo, @"SORA", @"Video deferred — app backgrounded");
            }
        });
    }] resume];
}
   ═══════ END SORA ══════════════════════════════════════════════════════ */

- (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)c { return 1; }
- (id<QLPreviewItem>)previewController:(QLPreviewController *)c previewItemAtIndex:(NSInteger)i {
    return self.previewURL;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Whisper
// ─────────────────────────────────────────────────────────────────────────────

- (void)transcribeAudio:(NSURL *)fileURL {
    [self appendToChat:@"[System: Whisper uploading...]"];
    EZLog(EZLogLevelInfo, @"WHISPER", @"Starting transcription via ez-whisper");

    NSString *token = [EZAuthManager shared].accessToken;
    if (!token) { [self appendToChat:@"[Error: Not signed in]"]; return; }

    NSData *audioData = [NSData dataWithContentsOfURL:fileURL];
    if (!audioData) {
        EZLog(EZLogLevelError, @"WHISPER", @"Could not read audio file");
        [self appendToChat:@"[Error: Could not read audio file]"]; return;
    }

    NSString *b64Audio   = [audioData base64EncodedStringWithOptions:0];
    NSString *filename   = fileURL.lastPathComponent ?: @"recording.m4a";
    NSDictionary *body   = @{ @"audio_b64": b64Audio, @"filename": filename };

    [self postToEZFunction:@"ez-whisper" token:token body:body
                completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            EZLogf(EZLogLevelError, @"WHISPER", @"Failed: %@", error.localizedDescription); return;
        }
        id errObj = json[@"error"];
        if (errObj && ![errObj isKindOfClass:[NSNull class]]) {
            EZLogf(EZLogLevelError, @"WHISPER", @"API error: %@", errObj); return;
        }

        id balanceObj = json[@"balance"];
        if (balanceObj && ![balanceObj isKindOfClass:[NSNull class]])
            [[EZEntitlementManager shared] applyKnownBalance:[balanceObj integerValue]];

        NSString *formatted = [self formatWhisperTranscript:json[@"text"]];
        EZLogf(EZLogLevelInfo, @"WHISPER", @"Done (%lu chars)", (unsigned long)formatted.length);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.messageTextField.text = formatted;
            [self appendToChat:[NSString stringWithFormat:@"[Whisper]: %@", formatted]];
            [self updateCoinBalanceDisplay];
        });
    }];
}

- (NSString *)formatWhisperTranscript:(NSString *)raw {
    if (!raw) return @"";
    return [[[raw stringByReplacingOccurrencesOfString:@". " withString:@".\n"]
                  stringByReplacingOccurrencesOfString:@"! " withString:@"!\n"]
                  stringByReplacingOccurrencesOfString:@"? " withString:@"?\n"];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Misc
// ─────────────────────────────────────────────────────────────────────────────

/// Returns YES for any model that goes to /v1/images/generations (not chat)
- (BOOL)isGptImage1Family:(NSString *)model {
    return [model hasPrefix:@"gpt-image-"] || [model isEqualToString:@"chatgpt-image-latest"];
}

// Call this at every point that switches selectedModel to the
// "gpt-image-1-edit" mode flag, instead of setting selectedModel/modelButton
// directly — it's what makes callImageEdit/callGptImage1 actually use the
// model the user had picked instead of always falling back to gpt-image-1.
//
// preEditModeModel is sticky: it only gets overwritten when the CURRENT
// selection is a real edit-capable model. If the user switches to a chat
// model (or any future non-edit-capable image model) and then attaches an
// image without picking an image model again first, whatever was last
// remembered carries over rather than resetting — e.g. "picked
// gpt-image-1.5 for editing, switched to gpt-5 to chat, attached another
// image" still edits with gpt-image-1.5. Falls back to gpt-image-1 only the
// first time this is ever called with nothing remembered yet.
- (void)enterImageEditModeFromCurrentSelection {
    static NSSet<NSString *> *editCapableModels;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        editCapableModels = [NSSet setWithObjects:
            @"gpt-image-1", @"gpt-image-1-mini", @"gpt-image-1.5",
            @"gpt-image-2", @"gpt-image-2.5-flare", @"gpt-image-2.5-sunburst",
            @"chatgpt-image-latest", nil];
    });
    if ([editCapableModels containsObject:self.selectedModel]) {
        self.preEditModeModel = self.selectedModel;
    } else if (self.preEditModeModel.length == 0) {
        self.preEditModeModel = @"gpt-image-1"; // sensible default, matches old hardcoded behavior
    }
    self.selectedModel = @"gpt-image-1-edit";
    [self.modelButton setTitle:[NSString stringWithFormat:@"Model: %@ (edit mode)", self.preEditModeModel]
                      forState:UIControlStateNormal];
}

// Return to the real image model once intent routing chose a non-edit action.
// This prevents the edit-mode UI state from leaking into later generations or
// image reopens after a previous edit has completed.
- (void)exitImageEditModeIfNeeded {
    if (![self.selectedModel isEqualToString:@"gpt-image-1-edit"]) return;

    NSString *model = self.preEditModeModel.length ? self.preEditModeModel : @"gpt-image-1";
    self.selectedModel = model;
    [self.modelButton setTitle:[NSString stringWithFormat:@"Model: %@", model]
                      forState:UIControlStateNormal];
}

- (BOOL)modelSupportsVision:(NSString *)model {
    // gpt-5.x and gpt-4.1.x all support vision via the Responses API.
    // Prefix checks cover all variants (gpt-5, gpt-5.1-mini, gpt-4.1, gpt-4.1-mini, etc.)
    if ([model hasPrefix:@"gpt-5"] || [model isEqualToString:@"gpt-6-astra"]) return YES;
    if ([model hasPrefix:@"gpt-4.1"]) return YES;
    if ([model hasPrefix:@"o3"])      return YES;
    if ([model hasPrefix:@"o4"])      return YES;
    NSSet *visionModels = [NSSet setWithObjects:
        @"gpt-4o", @"gpt-4o-mini", @"gpt-4-turbo", @"gpt-4",
        @"gpt-image-1", nil];
    return [visionModels containsObject:model];
}

/// Decodes the base64 data URLs in a vision message's content array back
/// into real local files, for restoring attachment bubbles when a thread
/// loads. The full base64 data survives in chatContext/thread persistence
/// (sanitizedContextForAPI only ever produces a derived copy for the
/// outgoing request — self.chatContext itself is never mutated, so this
/// works retroactively for any already-saved thread, not just future ones).
/// Returns the recovered local paths in order; images that fail to decode
/// are skipped rather than aborting the whole message's recovery.
- (NSArray<NSString *> *)ez_recoverImagePathsFromVisionContent:(NSArray *)contentBlocks {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSDictionary *block in contentBlocks) {
        NSString *type = block[@"type"];
        if (![type isEqualToString:@"image_url"] && ![type isEqualToString:@"input_image"]) continue;
        id imageValue = block[@"image_url"];
        NSString *dataURL = [imageValue isKindOfClass:[NSDictionary class]] ? imageValue[@"url"]
            : [imageValue isKindOfClass:[NSString class]] ? imageValue : nil;
        // Responses API's persisted form can hold raw base64 + media type.
        if (!dataURL.length && [block[@"data"] isKindOfClass:[NSString class]]) {
            dataURL = [NSString stringWithFormat:@"data:%@;base64,%@",
                       block[@"media_type"] ?: @"image/jpeg", block[@"data"]];
        }
        if (![dataURL hasPrefix:@"data:"]) continue; // skip real http(s) URLs, nothing to recover

        NSRange base64Marker = [dataURL rangeOfString:@";base64,"];
        if (base64Marker.location == NSNotFound) continue;
        NSString *mime = [[dataURL substringWithRange:NSMakeRange(5, base64Marker.location - 5)]
                           stringByReplacingOccurrencesOfString:@"image/" withString:@""];
        NSString *base64 = [dataURL substringFromIndex:base64Marker.location + base64Marker.length];
        NSData *imageData = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
        if (!imageData) continue;

        // Reuse the original attachment file when it is available.  Apart from
        // avoiding needless copies, this lets the legacy attachment fallback
        // recognize that the image was already restored.
        NSString *matchingPath = nil;
        for (NSString *candidate in self.activeThread.attachmentPaths) {
            NSString *resolved = EZAttachmentPath(candidate);
            NSData *candidateData = resolved.length ? [NSData dataWithContentsOfFile:resolved] : nil;
            if (candidateData && [candidateData isEqualToData:imageData]) {
                matchingPath = resolved;
                break;
            }
        }
        if (matchingPath) {
            [paths addObject:matchingPath];
            continue;
        }

        NSString *ext = mime.length > 0 ? mime : @"jpg";
        NSString *name = [NSString stringWithFormat:@"restored_%@.%@", [NSUUID UUID].UUIDString, ext];
        NSString *savedPath = EZPhotoGallerySave(imageData, name);
        if (savedPath) [paths addObject:savedPath];
    }
    return [paths copy];
}

- (NSArray *)sanitizedContextForAPI:(NSArray *)context
               modelSupportsVision:(BOOL)supportsVision
                   useResponsesAPI:(BOOL)useResponsesAPI
{
    NSInteger lastVisionIdx = -1;

    // Find newest image attachment
    for (NSInteger i = (NSInteger)context.count - 1; i >= 0; i--) {
        NSDictionary *msg = context[(NSUInteger)i];

        if ([msg[@"_isVisionAttachment"] boolValue]) {
            lastVisionIdx = i;
            break;
        }

        id content = msg[@"content"];
        if ([content isKindOfClass:[NSArray class]]) {
            for (NSDictionary *block in (NSArray *)content) {
                NSString *type = [block[@"type"] description];

                if ([type isEqualToString:@"image_url"] ||
                    [type isEqualToString:@"input_image"]) {
                    lastVisionIdx = i;
                    break;
                }
            }
        }

        if (lastVisionIdx >= 0) {
            break;
        }
    }

    NSMutableArray *result = [NSMutableArray array];

    for (NSUInteger i = 0; i < context.count; i++) {

        NSDictionary *msg = context[i];

        // Ordered image-grid records are for reconstruction of the local UI;
        // they are not chat turns and must never be sent to an API model.
        if ([msg[@"_uiOnly"] boolValue]) continue;

        // Strip internal metadata keys
        NSMutableDictionary *clean =
            [NSMutableDictionary dictionary];

        for (NSString *key in msg) {
            if ([key hasPrefix:@"_"]) {
                continue;
            }
            clean[key] = msg[key];
        }

        id content = clean[@"content"];

        // ─────────────────────────────────────────────────────────────
        // Multimodal message handling
        // ─────────────────────────────────────────────────────────────
        if ([content isKindOfClass:[NSArray class]]) {

            NSArray *blocks = (NSArray *)content;
            BOOL hasImage = NO;

            for (NSDictionary *block in blocks) {
                NSString *type =
                    [block[@"type"] description];

                if ([type isEqualToString:@"image_url"] ||
                    [type isEqualToString:@"input_image"]) {
                    hasImage = YES;
                    break;
                }
            }

            // =========================================================
            // Image-containing message
            // =========================================================
            if (hasImage) {

                BOOL isLatest =
                    ((NSInteger)i == lastVisionIdx);

                BOOL sendInline =
                    isLatest && supportsVision;

                // Only resend newest image attachment
                if (sendInline) {

                    NSMutableArray *convertedBlocks =
                        [NSMutableArray array];

                    for (NSDictionary *block in blocks) {

                        NSString *type =
                            [block[@"type"] description];

                        // ─────────────────────────────
                        // IMAGE BLOCK
                        // ─────────────────────────────
                        if ([type isEqualToString:@"image_url"] ||
                            [type isEqualToString:@"input_image"]) {

                            NSString *dataURL = nil;
                            id imgURLVal =
                                block[@"image_url"];

                            // Old format:
                            // image_url: { url: ... }
                            if ([imgURLVal isKindOfClass:[NSDictionary class]]) {
                                dataURL =
                                    ((NSDictionary *)imgURLVal)[@"url"];
                            }
                            // New/simple format:
                            // image_url: "data:image..."
                            else if ([imgURLVal isKindOfClass:[NSString class]]) {
                                dataURL =
                                    (NSString *)imgURLVal;
                            }

                            if (!dataURL.length) {
                                continue;
                            }

                            if (useResponsesAPI) {

                                // GPT-5 / Responses API format
                                [convertedBlocks addObject:@{
                                    @"type": @"input_image",
                                    @"image_url": dataURL
                                }];

                            } else {

                                // Chat Completions format
                                [convertedBlocks addObject:@{
                                    @"type": @"image_url",
                                    @"image_url": @{
                                        @"url": dataURL
                                    }
                                }];
                            }

                            continue;
                        }

                        // ─────────────────────────────
                        // TEXT BLOCK
                        // ─────────────────────────────
                        if ([type isEqualToString:@"text"] ||
                            [type isEqualToString:@"input_text"]) {

                            NSString *text =
                                block[@"text"] ?: @"";

                            // Skip placeholder
                            if ([text isEqualToString:
                                 @"[image attached — await user question]"]) {
                                continue;
                            }

                            if (useResponsesAPI) {

                                [convertedBlocks addObject:@{
                                    @"type": @"input_text",
                                    @"text": text
                                }];

                            } else {

                                [convertedBlocks addObject:@{
                                    @"type": @"text",
                                    @"text": text
                                }];
                            }

                            continue;
                        }

                        // Unknown block passthrough
                        [convertedBlocks addObject:block];
                    }

                    if (convertedBlocks.count > 0) {
                        clean[@"content"] =
                            [convertedBlocks copy];

                        [result addObject:clean];
                    }

                } else {

                    // Convert old image messages to text
                    // so we don't resend giant base64 blobs
                    NSMutableString *textContent =
                        [NSMutableString string];

                    for (NSDictionary *block in blocks) {

                        NSString *type =
                            [block[@"type"] description];

                        if ([type isEqualToString:@"text"] ||
                            [type isEqualToString:@"input_text"]) {

                            NSString *text =
                                block[@"text"] ?: @"";

                            if (![text isEqualToString:
                                 @"[image attached — await user question]"]) {

                                [textContent appendString:text];
                            }
                        }
                    }

                    if (textContent.length == 0) {
                        [textContent appendString:
                            @"[image attached]"];
                    }

                    [result addObject:@{
                        @"role":
                            clean[@"role"] ?: @"user",
                        @"content":
                            [textContent copy]
                    }];
                }

                continue;
            }

            // =========================================================
            // Non-image multimodal conversion
            // =========================================================
            if (useResponsesAPI) {

                NSMutableArray *convertedBlocks =
                    [NSMutableArray array];

                for (NSDictionary *block in blocks) {

                    NSString *type =
                        [block[@"type"] description];

                    if ([type isEqualToString:@"text"]) {

                        [convertedBlocks addObject:@{
                            @"type": @"input_text",
                            @"text":
                                block[@"text"] ?: @""
                        }];

                    } else {

                        [convertedBlocks addObject:block];
                    }
                }

                clean[@"content"] =
                    [convertedBlocks copy];

                [result addObject:clean];
                continue;
            }
        }

        // Plain text passthrough
        [result addObject:clean];
    }

    return [result copy];
}

- (NSString *)featureLabel:(EZFeature)feature {
    switch (feature) {
        case EZFeatureImageLow:    return @"image_low";
        case EZFeatureImageMedium: return @"image_medium";
        case EZFeatureImageHigh:   return @"image_high";
        default:                   return @"image_medium";
    }
}

- (void)handleAPIError:(NSString *)msg {
    EZLogf(EZLogLevelError, @"API", @"Error: %@", msg);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self hideGPT5StatusBanner];  // ← ADD THIS
        self.sendButton.enabled = YES;

        // ── Friendly message for OpenAI rate limit errors ─────────────────
        NSString *display = msg;
        if ([msg containsString:@"Rate limit"] ||
            [msg containsString:@"rate_limit"] ||
            [msg containsString:@"tokens per min"] ||
            [msg containsString:@"429"]) {
            display = @"OpenAI rate limit reached — the request was too large "
                       "or too many requests were sent at once. Please wait a "
                       "moment and try again.";
        }

        [self appendToChat:[NSString stringWithFormat:@"[API Error]: %@", display]];
    });
}


- (void)keyboardWillChange:(NSNotification *)notification {
    CGRect kbFrame  = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    double duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    BOOL isHiding   = [notification.name isEqualToString:UIKeyboardWillHideNotification];
    self.containerBottomConstraint.constant = isHiding
        ? 0 : -(kbFrame.size.height - self.view.safeAreaInsets.bottom);
    [UIView animateWithDuration:duration animations:^{ [self.view layoutIfNeeded]; }];
}

- (void)setupKeyboardObservers {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillShowNotification       object:nil];
    [nc addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillHideNotification       object:nil];
    [nc addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillChangeFrameNotification object:nil];
}

- (void)newChat {
    [self saveActiveThread];
    [self _resetConversation];
    [self appendToChat:@"[System: New chat started ✓]"];
    EZLog(EZLogLevelInfo, @"APP", @"New chat started by user");
}

- (void)deleteCurrentChat {
    if (self.chatContext.count == 0) return;
    UIAlertController *confirm = [UIAlertController
        alertControllerWithTitle:@"Delete This Chat?"
                         message:@"This conversation will be permanently deleted."
                  preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Delete"
                                               style:UIAlertActionStyleDestructive
                                             handler:^(UIAlertAction *a) {
        if (self.activeThread.threadID.length > 0) {
            EZThreadDelete(self.activeThread.threadID);
        }
        [self _resetConversation];
        [self appendToChat:@"[System: Chat deleted]"];
        EZLog(EZLogLevelInfo, @"APP", @"Chat deleted by user");
    }]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                               style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)_resetConversation {
    [self.chatContext removeAllObjects];
    [self.displayMessages removeAllObjects];
    [self.chatTableView reloadData];
    self.lastAIResponse     = nil;
    self.lastUserPrompt     = nil;
    self.lastImagePrompt    = nil;
    self.lastImageLocalPath = nil;
    [self.pendingFiles removeAllObjects];
    [self.pendingImagePaths removeAllObjects];
    [self startNewThread];
    [self updateThreadTitleLabel];
}

- (void)clearConversation {
    [self saveActiveThread];
    [self _resetConversation];
    EZLog(EZLogLevelInfo, @"APP", @"Conversation cleared — new thread started");
}

- (void)copyLastResponse {
    if (!self.lastAIResponse) return;
    [UIPasteboard generalPasteboard].string = self.lastAIResponse;
    EZLog(EZLogLevelInfo, @"APP", @"Last response copied to clipboard");

    UIImage *checkImg = [UIImage systemImageNamed:@"checkmark.circle.fill"];
    UIImage *origImg  = [UIImage systemImageNamed:@"doc.on.doc"];
    [self.clipboardButton setImage:checkImg forState:UIControlStateNormal];
    [self.clipboardButton setTintColor:[UIColor systemGreenColor]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self.clipboardButton setImage:origImg forState:UIControlStateNormal];
        [self.clipboardButton setTintColor:nil];
    });
}

- (void)showModelPicker {
    EZModelPickerViewController *picker = [[EZModelPickerViewController alloc]
        initWithModels:self.models selectedModel:self.selectedModel];
    __weak typeof(self) ws = self;
    picker.onModelSelected = ^(NSString *model) {
        ws.selectedModel = model;
        [ws.modelButton setTitle:[NSString stringWithFormat:@"Model: %@", model]
                        forState:UIControlStateNormal];
        [[NSUserDefaults standardUserDefaults] setObject:model forKey:@"selectedModel"];
        ws.imageSettingsButton.hidden = ![ws isGptImage1Family:model];
        EZLogf(EZLogLevelInfo, @"APP", @"Model → %@", model);
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:picker];
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = nav.sheetPresentationController;
        sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent,
                          UISheetPresentationControllerDetent.largeDetent];
        sheet.prefersGrabberVisible = YES;
    }
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)persistImagePath:(NSString *)path prompt:(NSString *)prompt {
    if (!path.length) return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:path   forKey:@"lastImageLocalPath"];
    [d setObject:prompt ?: @"" forKey:@"lastImagePrompt"];
    NSMutableDictionary *promptMap = [[d dictionaryForKey:@"EZGalleryImagePrompts"] mutableCopy]
        ?: [NSMutableDictionary dictionary];
    promptMap[path] = prompt ?: @"";
    [d setObject:promptMap forKey:@"EZGalleryImagePrompts"];
    [d synchronize];
    EZLogf(EZLogLevelInfo, @"IMAGE", @"Persisted path: %@", path.lastPathComponent);
}

- (void)classifyImageIntent:(NSString *)prompt
              hasLocalImage:(BOOL)hasLocalImage
                 completion:(void(^)(NSString *intent))completion {

    NSString *lower = prompt.lowercaseString;

    NSArray *reopenSignals = @[
        @"again", @"reopen", @"re-open", @"pull up", @"pull it up",
        @"see it again",
        @"missed it", @"didn't see", @"can't see", @"lost it",
        @"bring it back", @"show me again", @"display again",
        @"open it again", @"show that image", @"that image again",
        @"previous image", @"last image", @"the image again"
    ];

    NSArray *generateSignals = @[
        @"create", @"generate", @"make", @"draw", @"paint",
        @"a picture of", @"an image of", @"image of", @"picture of",
        @"new image"];

    NSArray *editSignals = @[
        @"edit", @"change", @"modify", @"adjust", @"alter",
        @"add to", @"remove from", @"make it", @"turn it into"
    ];
    NSArray *textSignals = @[
        @"explain", @"write", @"rewrite", @"summarize", @"summarise",
        @"translate", @"email", @"document", @"letter", @"essay",
        @"what is", @"how do", @"help me", @"code", @"calculate"
    ];

    NSInteger reopenScore = 0, generateScore = 0, editScore = 0, textScore = 0;
    for (NSString *s in reopenSignals)   if ([lower containsString:s]) reopenScore++;
    for (NSString *s in generateSignals) if ([lower containsString:s]) generateScore++;
    for (NSString *s in editSignals)     if ([lower containsString:s]) editScore++;
    for (NSString *s in textSignals)     if ([lower containsString:s]) textScore++;

    EZLogf(EZLogLevelDebug, @"IMAGE",
           @"Intent scores — reopen:%ld generate:%ld edit:%ld hasLocal:%d",
           (long)reopenScore, (long)generateScore, (long)editScore, hasLocalImage);

    if (reopenScore >= 2 && reopenScore > generateScore && hasLocalImage) {
        EZLogf(EZLogLevelInfo, @"IMAGE", @"Tier 1: reopen (score %ld)", (long)reopenScore);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(@"reopen"); });
        return;
    }
    if (generateScore >= 2 && generateScore > reopenScore) {
        EZLogf(EZLogLevelInfo, @"IMAGE", @"Tier 1: generate (score %ld)", (long)generateScore);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(@"generate"); });
        return;
    }
    if (editScore >= 2 && editScore > reopenScore && hasLocalImage) {
        EZLogf(EZLogLevelInfo, @"IMAGE", @"Tier 1: edit (score %ld)", (long)editScore);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(@"edit"); });
        return;
    }

    // A question about an attached image is a first-class intent. Do not send
    // it to an image generator merely because a local source exists.
    if (hasLocalImage && textScore > 0 && textScore >= generateScore && textScore >= editScore) {
        EZLogf(EZLogLevelInfo, @"IMAGE", @"Tier 1: chat (score %ld)", (long)textScore);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(@"chat"); });
        return;
    }

    if (!hasLocalImage) {
        // With no source image, recognizable text work should never become a
        // drawing just because an image model was left selected.
        dispatch_async(dispatch_get_main_queue(), ^{ completion(textScore > 0 ? @"chat" : @"generate"); });
        return;
    }

    // Tier 2 — ambiguous: use ez-helper for classification
    NSString *token = [EZAuthManager shared].accessToken;
    if (!token) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(@"generate"); });
        return;
    }

    NSString *sys =
        @"You classify user intent for an AI image app. The user may want to:\n"
         "  REOPEN — view/display a previously generated image they already have\n"
         "  GENERATE — create a brand new image from a description\n"
         "  EDIT — modify/edit a previously generated image\n"
         "  CHAT — answer a question about the attached image\n\n"
         "Reply with exactly one word: REOPEN, GENERATE, EDIT, or CHAT. Nothing else.";
    NSString *msg = [NSString stringWithFormat:
        @"User prompt: \"%@\"\nContext: User has a previously generated image available.",
        prompt];

    NSDictionary *body = @{ @"system": sys, @"message": msg, @"max_tokens": @10 };
    [self postToEZFunction:@"ez-helper" token:token body:body
                completion:^(NSDictionary *json, NSError *error) {
        NSString *raw    = json[@"result"] ?: @"";
        NSString *result = [[raw uppercaseString]
                            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        EZLogf(EZLogLevelInfo, @"IMAGE", @"Tier 2 classifier: %@ → %@", prompt, result);

        NSString *intent = @"generate";
        if ([result isEqualToString:@"REOPEN"]) intent = @"reopen";
        else if ([result isEqualToString:@"EDIT"]) intent = @"edit";
        else if ([result isEqualToString:@"CHAT"]) intent = @"chat";
        dispatch_async(dispatch_get_main_queue(), ^{ completion(intent); });
    }];
}

- (void)checkReplyForLocalFilePaths:(NSString *)reply {
    NSString *docsDir = [NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (!docsDir) return;

    // Match any path under /var/mobile/ with any extension — fixes .ips, .json, etc.
    NSRegularExpression *pathRegex = [NSRegularExpression
        regularExpressionWithPattern:@"(/var/mobile/[^\\s\"'<>]+\\.\\w+)"
                             options:NSRegularExpressionCaseInsensitive error:nil];
    NSArray *matches = [pathRegex matchesInString:reply
                                          options:0
                                            range:NSMakeRange(0, reply.length)];
    for (NSTextCheckingResult *match in matches) {
        NSString *path = [reply substringWithRange:[match rangeAtIndex:1]];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            EZLogf(EZLogLevelInfo, @"ATTACH", @"Model referenced local file: %@", path);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self offerToOpenLocalFile:path];
            });
            break;
        }
    }
}

- (void)reopenAttachmentFromMemory:(NSString *)keyword {
    NSArray<NSDictionary *> *allMemories = EZMemoryLoadAll();
    NSString *lowerKeyword = keyword.lowercaseString;

    for (NSDictionary *entry in allMemories.reverseObjectEnumerator) {
        NSArray *paths = entry[@"attachmentPaths"];
        for (NSString *path in paths) {
            if ([path.lastPathComponent.lowercaseString containsString:lowerKeyword] ||
                [[entry[@"summary"] lowercaseString] containsString:lowerKeyword]) {
                if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
                    EZLogf(EZLogLevelInfo, @"ATTACH", @"Reopening from memory: %@", path);
                    [self offerToOpenLocalFile:path];
                    return;
                }
            }
        }
    }
    EZLogf(EZLogLevelInfo, @"ATTACH", @"No matching file found in memory for: %@", keyword);
}

- (void)offerToOpenLocalFile:(NSString *)path {
    self.previewURL = [NSURL fileURLWithPath:path];
    QLPreviewController *ql = [[QLPreviewController alloc] init];
    ql.dataSource = self;
    [self presentViewController:ql animated:YES completion:nil];
    [self appendToChat:[NSString stringWithFormat:@"[System: Opening %@]", path.lastPathComponent]];
    NSString *ext = path.pathExtension.lowercaseString;
    if ([@[@"jpg",@"jpeg",@"png",@"gif",@"webp",@"heic"] containsObject:ext])
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.7*NSEC_PER_SEC)),dispatch_get_main_queue(),^{[self offerSaveToPhotos:path];});
}

- (NSString *)fileExtensionForLanguage:(NSString *)lang {
    NSString *normalized = [[[lang lowercaseString]
                             stringByReplacingOccurrencesOfString:@"-" withString:@""]
                            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSDictionary *map = @{
        @"python":        @"py",    @"py":           @"py",
        @"javascript":    @"js",    @"js":           @"js",
        @"typescript":    @"ts",    @"ts":           @"ts",
        @"swift":         @"swift",
        @"objc":          @"m",     @"objectivec":   @"m",
        @"objectivecpp":  @"mm",    @"objcpp":       @"mm",
        @"c":             @"c",
        @"cpp":           @"cpp",   @"c++":          @"cpp", @"cxx": @"cpp",
        @"java":          @"java",  @"kotlin":       @"kt",
        @"ruby":          @"rb",    @"go":           @"go",
        @"rust":          @"rs",    @"shell":        @"sh",
        @"bash":          @"sh",    @"sh":           @"sh",  @"zsh": @"sh",
        @"html":          @"html",  @"css":          @"css",
        @"json":          @"json",  @"xml":          @"xml",
        @"yaml":          @"yaml",  @"yml":          @"yaml",
        @"sql":           @"sql",   @"markdown":     @"md",  @"md": @"md",
        @"plaintext":     @"txt",   @"text":         @"txt", @"plain": @"txt",
        @"diff":          @"diff",  @"makefile":     @"mk",
        @"dart":          @"dart",  @"php":          @"php",
        @"cs":            @"cs",    @"csharp":       @"cs",
        @"r":             @"r",     @"matlab":       @"m",
        @"scala":         @"scala", @"lua":          @"lua",
        @"perl":          @"pl",    @"haskell":      @"hs",
    };
    NSString *ext = map[normalized];
    if (!ext) {
        NSCharacterSet *safe = [NSCharacterSet alphanumericCharacterSet];
        NSString *candidate = normalized.length > 6
            ? [normalized substringToIndex:6] : normalized;
        BOOL isSafe = YES;
        for (NSUInteger i = 0; i < candidate.length; i++) {
            if (![safe characterIsMember:[candidate characterAtIndex:i]]) { isSafe = NO; break; }
        }
        ext = (isSafe && candidate.length > 0) ? candidate : @"txt";
    }
    return ext;
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Real generated files (EZPDF / EZDOCX / EZXCEL fences)
// ─────────────────────────────────────────────────────────────────────────────
// Same detection mechanism as code blocks (processReplyWithCodeBlocks below) —
// a fence whose language is EZPDF/EZDOCX/EZXCEL, optionally with a filename
// on the fence line exactly like ```python foo.py — but instead of saving the
// raw fenced text as a plain-text snippet, this actually generates a real
// file: a genuine PDF, an RTF (opens natively in Word/Pages — true .docx is a
// ZIP+XML format iOS has no built-in support for; RTF gets the same practical
// result — a real document the user can open — without hand-rolling a ZIP
// writer), and a real CSV (same reasoning vs. true .xlsx). Extension is
// always forced to the real format regardless of what the model or fence
// filename suggests, so a file is never shipped with a misleading extension.
//
// Content conventions (also needs to go in the system prompt so models know
// to write in this shape):
//   EZPDF / EZDOCX body — a small markdown subset, not full markdown:
//     # Heading            -> large bold line
//     ## Subheading        -> medium bold line
//     **bold text**        -> inline bold
//     blank line           -> paragraph break
//     anything else        -> plain body text
//   EZXCEL body — one row per line, fields separated by | (pipe), not comma:
//     Name|Age|City
//     Ana|29|Boston
//     (Pipe instead of comma specifically so the model doesn't have to worry
//     about CSV quoting/escaping — this code handles proper CSV escaping,
//     including commas or quotes WITHIN a field, when converting.)

/// Parses the small markdown subset documented above into an NSAttributedString.
/// Deliberately not a general markdown parser — keeping the supported syntax
/// small is what makes it easy to document accurately and easy to keep
/// correct. Extend the supported syntax deliberately, not accidentally.
- (NSAttributedString *)ez_attributedStringFromSimpleMarkdown:(NSString *)markdown {
    NSMutableAttributedString *result = [[NSMutableAttributedString alloc] init];
    UIFont *bodyFont     = [UIFont systemFontOfSize:12];
    UIFont *boldBodyFont = [UIFont boldSystemFontOfSize:12];
    UIFont *h1Font       = [UIFont boldSystemFontOfSize:20];
    UIFont *h2Font       = [UIFont boldSystemFontOfSize:16];

    NSArray<NSString *> *lines = [markdown componentsSeparatedByString:@"\n"];
    for (NSUInteger lineIdx = 0; lineIdx < lines.count; lineIdx++) {
        NSString *line = lines[lineIdx];
        UIFont *lineFont = bodyFont;
        UIFont *lineBoldFont = boldBodyFont;
        if ([line hasPrefix:@"## "]) {
            lineFont = h2Font; lineBoldFont = h2Font;
            line = [line substringFromIndex:3];
        } else if ([line hasPrefix:@"# "]) {
            lineFont = h1Font; lineBoldFont = h1Font;
            line = [line substringFromIndex:2];
        }

        // Toggle bold on each **-delimited segment — a simple state machine,
        // not a real inline-markdown parser. Odd-indexed segments (1st, 3rd,
        // ...) are the text BETWEEN pairs of ** markers.
        NSArray<NSString *> *segments = [line componentsSeparatedByString:@"**"];
        for (NSUInteger i = 0; i < segments.count; i++) {
            BOOL isBold = (i % 2) == 1;
            NSDictionary *attrs = @{ NSFontAttributeName: isBold ? lineBoldFont : lineFont };
            [result appendAttributedString:
                [[NSAttributedString alloc] initWithString:segments[i] attributes:attrs]];
        }
        if (lineIdx < lines.count - 1) {
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"
                attributes:@{NSFontAttributeName: bodyFont}]];
        }
    }
    return [result copy];
}

/// Renders the markdown subset to a real, properly paginated PDF. Draws with
/// CoreText directly rather than relying on UIGraphicsPDFRenderer's own
/// layout, specifically so long content correctly flows onto additional
/// pages instead of being silently clipped to one page.
- (NSData *)ez_pdfDataFromSimpleMarkdown:(NSString *)markdown {
    NSAttributedString *attrString = [self ez_attributedStringFromSimpleMarkdown:markdown];
    if (attrString.length == 0) return nil;

    CGRect pageBounds = CGRectMake(0, 0, 612, 792); // US Letter @ 72dpi
    UIEdgeInsets margins = UIEdgeInsetsMake(54, 54, 54, 54); // 0.75in margins
    CGRect textBounds = UIEdgeInsetsInsetRect(pageBounds, margins);

    UIGraphicsPDFRendererFormat *format = [[UIGraphicsPDFRendererFormat alloc] init];
    UIGraphicsPDFRenderer *renderer = [[UIGraphicsPDFRenderer alloc] initWithBounds:pageBounds
                                                                              format:format];

    CTFramesetterRef framesetter =
        CTFramesetterCreateWithAttributedString((CFAttributedStringRef)attrString);

    NSData *pdfData = [renderer PDFDataWithActions:^(UIGraphicsPDFRendererContext *context) {
        CFIndex totalLength = (CFIndex)attrString.length;
        CFRange currentRange = CFRangeMake(0, 0);
        // Safety cap — a pathological input shouldn't be able to hang here
        // or produce an unbounded-size file.
        NSInteger pagesDrawn = 0, maxPages = 500;

        while (currentRange.location < totalLength && pagesDrawn < maxPages) {
            [context beginPage];
            CGMutablePathRef path = CGPathCreateMutable();
            CGPathAddRect(path, NULL, textBounds);
            CTFrameRef frame = CTFramesetterCreateFrame(framesetter, currentRange, path, NULL);

            CGContextRef ctx = context.CGContext;
            CGContextSaveGState(ctx);
            // CoreText's coordinate space is flipped relative to UIKit's —
            // without this, text draws upside down / off the bottom of the page.
            CGContextTranslateCTM(ctx, 0, pageBounds.size.height);
            CGContextScaleCTM(ctx, 1.0, -1.0);
            CTFrameDraw(frame, ctx);
            CGContextRestoreGState(ctx);

            CFRange visibleRange = CTFrameGetVisibleStringRange(frame);
            CFRelease(frame);
            CGPathRelease(path);

            if (visibleRange.length == 0) break; // nothing more fit — avoid an infinite loop
            currentRange = CFRangeMake(visibleRange.location + visibleRange.length, 0);
            pagesDrawn++;
        }
    }];
    CFRelease(framesetter);
    return pdfData;
}

/// Renders the markdown subset to RTF data via NSAttributedString's built-in
/// RTF export — genuinely native, no hand-rolled format handling needed.
- (NSData *)ez_rtfDataFromSimpleMarkdown:(NSString *)markdown {
    NSAttributedString *attrString = [self ez_attributedStringFromSimpleMarkdown:markdown];
    if (attrString.length == 0) return nil;
    NSError *err = nil;
    NSData *rtfData = [attrString
        dataFromRange:NSMakeRange(0, attrString.length)
   documentAttributes:@{NSDocumentTypeDocumentAttribute: NSRTFTextDocumentType}
                error:&err];
    if (err) {
        EZLogf(EZLogLevelError, @"EZDOCX", @"RTF generation failed: %@", err);
        return nil;
    }
    return rtfData;
}

/// Converts pipe-delimited rows into a real, properly escaped CSV. The model
/// writes plain pipe-separated fields (see the content convention comment
/// above) specifically so it never has to get CSV quoting/escaping right
/// itself — this does that part, including quoting fields that themselves
/// contain a comma, a quote, or a newline, per the CSV spec.
- (NSData *)ez_csvDataFromPipeDelimitedRows:(NSString *)pipeContent {
    NSArray<NSString *> *lines = [pipeContent componentsSeparatedByString:@"\n"];
    NSMutableString *csv = [NSMutableString string];
    NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];

    for (NSString *rawLine in lines) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:ws];
        if (line.length == 0) continue; // skip blank lines rather than emit an empty CSV row

        NSArray<NSString *> *fields = [line componentsSeparatedByString:@"|"];
        NSMutableArray<NSString *> *escaped = [NSMutableArray arrayWithCapacity:fields.count];
        for (NSString *rawField in fields) {
            NSString *field = [rawField stringByTrimmingCharactersInSet:ws];
            BOOL needsQuoting = [field containsString:@","] || [field containsString:@"\""]
                              || [field containsString:@"\n"];
            if (needsQuoting) {
                NSString *doubled = [field stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""];
                field = [NSString stringWithFormat:@"\"%@\"", doubled];
            }
            [escaped addObject:field];
        }
        [csv appendString:[escaped componentsJoinedByString:@","]];
        [csv appendString:@"\r\n"]; // CRLF per the CSV spec (RFC 4180)
    }
    if (csv.length == 0) return nil;
    return [csv dataUsingEncoding:NSUTF8StringEncoding];
}

/// Forces path to end in the given extension regardless of what it currently
/// has — used so a model- or fence-line-suggested filename (which might say
/// "report.docx" even though this code generates RTF, not true DOCX) never
/// results in a file shipped with a misleading extension.
- (NSString *)ez_filename:(NSString *)suggested forcedExtension:(NSString *)ext {
    NSString *base = suggested.length > 0 ? suggested.stringByDeletingPathExtension : @"document";
    if (base.length == 0) base = @"document";
    return [base stringByAppendingPathExtension:ext];
}

- (NSString *)processReplyWithCodeBlocks:(NSString *)reply
                            savedPaths:(NSMutableArray<NSString *> *)savedPaths {
    return [self processReplyWithCodeBlocks:reply savedPaths:savedPaths isRestore:NO];
}

- (NSString *)processReplyWithCodeBlocks:(NSString *)reply
                            savedPaths:(NSMutableArray<NSString *> *)savedPaths
                             isRestore:(BOOL)isRestore {
    NSError *regexErr;
    // Group 1: language token (```python). Group 2: anything else on that
    // same fence line — a filename annotation (```python foo.py), which the
    // old pattern couldn't handle at all: it only tolerated whitespace
    // between the language token and the newline, so a fence line with a
    // trailing filename failed the WHOLE match, silently skipping the code
    // block entirely instead of rendering it. Group 3: the code body itself
    // (was group 2 in the old 2-group pattern — shifted down by one).
    NSRegularExpression *codeBlockRegex = [NSRegularExpression
        regularExpressionWithPattern:@"```([a-zA-Z0-9+#._-]*)[ \\t]*([^\\n]*)\\n([\\s\\S]+?)\\n[ \\t]*```"
                             options:0
                               error:&regexErr];
    if (regexErr || !codeBlockRegex) return reply;

    NSArray *matches = [codeBlockRegex matchesInString:reply
                                               options:0
                                                 range:NSMakeRange(0, reply.length)];
    if (matches.count == 0) return reply;

    NSMutableString *processed = [NSMutableString stringWithString:reply];
    NSInteger offset = 0;

    for (NSTextCheckingResult *match in matches) {
        NSRange langRange = [match rangeAtIndex:1];
        NSRange fenceInfoRange = [match rangeAtIndex:2];
        NSRange codeRange = [match rangeAtIndex:3];
        if (langRange.location == NSNotFound || codeRange.location == NSNotFound) continue;

        NSString *lang = [reply substringWithRange:langRange];
        NSString *fenceInfo = fenceInfoRange.location != NSNotFound
            ? [[reply substringWithRange:fenceInfoRange] stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceCharacterSet]]
            : @"";
        NSString *code = [reply substringWithRange:codeRange];

        if (code.length < 5) continue;

        // ── Real generated files (EZPDF / EZDOCX / EZXCEL) ─────────────────
        // Checked before the generic code-snippet path below — these
        // languages produce an actual PDF/RTF/CSV instead of saving the
        // fenced text as a plain-text snippet. See the comment block above
        // ez_attributedStringFromSimpleMarkdown for the full design and the
        // content convention the system prompt needs to teach the model.
        NSString *langUpper = [lang uppercaseString];
        if ([langUpper isEqualToString:@"EZPDF"] ||
            [langUpper isEqualToString:@"EZDOCX"] ||
            [langUpper isEqualToString:@"EZXCEL"]) {

            NSData *fileData = nil;
            NSString *realExt = nil;
            NSString *cellLabel = nil;
            if ([langUpper isEqualToString:@"EZPDF"]) {
                fileData = [self ez_pdfDataFromSimpleMarkdown:code];
                realExt = @"pdf"; cellLabel = @"PDF";
            } else if ([langUpper isEqualToString:@"EZDOCX"]) {
                fileData = [self ez_rtfDataFromSimpleMarkdown:code];
                realExt = @"rtf"; cellLabel = @"RTF";
            } else {
                fileData = [self ez_csvDataFromPipeDelimitedRows:code];
                realExt = @"csv"; cellLabel = @"CSV";
            }

            if (!fileData) {
                // Generation failed (e.g. empty/unparseable content) — leave
                // the original fence in the reply untouched rather than
                // silently dropping it, so at minimum the raw text survives.
                continue;
            }

            NSString *fileName = [self ez_filename:fenceInfo forcedExtension:realExt];
            NSString *savedPath = EZAttachmentSave(fileData, fileName);
            if (savedPath) {
                NSMutableArray *att = [self.activeThread.attachmentPaths mutableCopy];
                if (![att containsObject:savedPath]) [att addObject:savedPath];
                self.activeThread.attachmentPaths = [att copy];
                if (!isRestore) [savedPaths addObject:savedPath];
                EZLogf(EZLogLevelInfo, @"EZFILE", @"Generated %@: %@", cellLabel, savedPath);
            }

            NSString *filePlaceholder = savedPath
                ? [NSString stringWithFormat:@"\n[CODE:%@:%@]\n", cellLabel, savedPath]
                : [NSString stringWithFormat:@"\n[System: Failed to save generated %@]\n", cellLabel];

            NSRange fileOriginalRange = [match range];
            NSRange fileAdjustedRange = NSMakeRange(
                (NSUInteger)((NSInteger)fileOriginalRange.location + offset),
                fileOriginalRange.length);
            [processed replaceCharactersInRange:fileAdjustedRange withString:filePlaceholder];
            offset += (NSInteger)filePlaceholder.length - (NSInteger)fileOriginalRange.length;
            continue;
        }

        NSError *fnErr;
        NSRegularExpression *fnRegex = [NSRegularExpression
            regularExpressionWithPattern:@"[\\w.+-]+\\.(?:m|h|mm|swift|py|js|ts|sh|bash|rb|go|rs|kt|java|c|cpp|cxx|cs|html|css|json|xml|yaml|yml|sql|md|txt|mk|makefile|gradle|plist|entitlements|pbxproj)"
                                 options:NSRegularExpressionCaseInsensitive error:&fnErr];

        // A filename right on the fence line (```python foo.py) is a
        // deliberate annotation, not a heuristic guess — check it first and
        // prefer it over scanning the code body's first two lines below.
        NSString *detectedName = nil;
        if (!fnErr && fenceInfo.length > 0) {
            NSTextCheckingResult *fenceNameMatch = [fnRegex firstMatchInString:fenceInfo
                options:0 range:NSMakeRange(0, fenceInfo.length)];
            if (fenceNameMatch) detectedName = [fenceInfo substringWithRange:fenceNameMatch.range];
        }
        NSArray<NSString *> *firstLines = [[code componentsSeparatedByString:@"\n"]
                                           subarrayWithRange:NSMakeRange(0, MIN(2, [[code componentsSeparatedByString:@"\n"] count]))];
        if (!fnErr && detectedName.length == 0) {
            for (NSString *line in firstLines) {
                NSRange lineRange = NSMakeRange(0, line.length);
                NSTextCheckingResult *fnMatch = [fnRegex firstMatchInString:line options:0 range:lineRange];
                if (fnMatch) {
                    detectedName = [line substringWithRange:fnMatch.range];
                    break;
                }
            }
        }

        NSString *ext;
        NSString *label;
        if (detectedName.length > 0) {
            label = detectedName;
            ext   = detectedName.pathExtension.length > 0 ? detectedName.pathExtension : @"txt";
        } else {
            ext   = [self fileExtensionForLanguage:lang];
            label = lang.length > 0 ? lang : ext;
        }

        NSString *savedPath = nil;
        NSString *fileName  = detectedName.length > 0 ? detectedName
            : [NSString stringWithFormat:@"snippet.%@", ext];

        if (isRestore) {
            for (NSString *existingPath in self.activeThread.attachmentPaths) {
                if ([existingPath.lastPathComponent hasSuffix:[@"_" stringByAppendingString:fileName]] ||
                    [existingPath.lastPathComponent hasSuffix:fileName]) {
                    if ([[NSFileManager defaultManager] fileExistsAtPath:existingPath]) {
                        savedPath = existingPath;
                        break;
                    }
                }
            }
        }

        if (!savedPath) {
            NSData *codeData = [code dataUsingEncoding:NSUTF8StringEncoding];
            savedPath = codeData ? EZAttachmentSave(codeData, fileName) : nil;
            if (savedPath && !isRestore) {
                [savedPaths addObject:savedPath];
                NSMutableArray *att = [self.activeThread.attachmentPaths mutableCopy];
                if (![att containsObject:savedPath]) [att addObject:savedPath];
                self.activeThread.attachmentPaths = [att copy];
            }
            if (savedPath) EZLogf(EZLogLevelInfo, @"CODE", @"Saved %@ snippet: %@", label, savedPath);
        }

        NSString *placeholder = savedPath
            ? [NSString stringWithFormat:@"\n[CODE:%@:%@]\n", label, savedPath]
            : [NSString stringWithFormat:@"\n[CODE:%@]\n%@\n[/CODE]\n", label, code];

        NSRange originalRange  = [match range];
        NSRange adjustedRange  = NSMakeRange((NSUInteger)((NSInteger)originalRange.location + offset),
                                              originalRange.length);
        [processed replaceCharactersInRange:adjustedRange withString:placeholder];
        offset += (NSInteger)placeholder.length - (NSInteger)originalRange.length;
    }
    return [processed copy];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Chat display helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Primary append entry point. Detects role from prefix ("You: ", "AI: "),
/// splits [CODE:] markers into separate code cells, and reloads the table.
- (void)appendToChat:(NSString *)rawText {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self appendToChat:rawText]; });
        return;
    }
    NSString *role = @"system";
    NSString *text = rawText;
    if ([rawText hasPrefix:@"You: "]) { role = @"user";      text = [rawText substringFromIndex:5]; }
    else if ([rawText hasPrefix:@"AI: "]) { role = @"assistant"; text = [rawText substringFromIndex:4]; }

    // Stamp timestamp + thread metadata so bubble cells can show them on swipe.
    static NSDateFormatter *_ezFmt;

    static dispatch_once_t _ezFmtOnce;
    dispatch_once(&_ezFmtOnce, ^{
        _ezFmt = [[NSDateFormatter alloc] init];
        _ezFmt.dateFormat = @"MMM d, h:mm a";
    });
    NSString *_ts = [_ezFmt stringFromDate:[NSDate date]];
    NSString *_ck    = self.activeThread.threadID ?: @"";
    NSString *_tid   = self.activeThread.threadID ?: @"";

    if ([text containsString:@"[CODE:"]) {
        [self addMessageSegments:text defaultRole:role];
    } else {
        [self.displayMessages addObject:@{
            @"role":     role,
            @"text":     text,
            @"timestamp": _ts,
            @"chatKey":  _ck,
            @"threadID": _tid,
        }];
        [self reloadAndScrollTable];
    }
}

/// Splits text containing [CODE:lang:path] / [CODE:lang]...[/CODE] markers
/// into alternating text + code entries in displayMessages.
- (void)addMessageSegments:(NSString *)text defaultRole:(NSString *)role {
    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:
            @"\\[CODE:([^:]+):([^\\]]+)\\]|\\[CODE:([^\\]]+)\\]([\\s\\S]*?)\\[/CODE\\]"
                             options:0 error:nil];
    if (!re) {
        [self.displayMessages addObject:@{@"role": role, @"text": text}];
        [self reloadAndScrollTable]; return;
    }
    NSArray *matches = [re matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    NSInteger lastEnd = 0;
    for (NSTextCheckingResult *match in matches) {
        // Plain text before this code block
        NSRange before = NSMakeRange((NSUInteger)lastEnd,
                                     match.range.location - (NSUInteger)lastEnd);
        if (before.length > 0) {
            NSString *seg = [[text substringWithRange:before]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (seg.length) [self.displayMessages addObject:@{@"role": role, @"text": seg}];
        }
        // Code block
        NSRange r1=[match rangeAtIndex:1], r2=[match rangeAtIndex:2];
        NSRange r3=[match rangeAtIndex:3], r4=[match rangeAtIndex:4];
        NSString *lang=@"", *savedPath=nil, *code=nil;
        if (r1.location != NSNotFound) {
            lang = [text substringWithRange:r1];
            savedPath = [text substringWithRange:r2];
            NSString *pathExt = [savedPath.pathExtension lowercaseString];
            if ([pathExt isEqualToString:@"pdf"] || [pathExt isEqualToString:@"rtf"]) {
                // These come from EZPDF/EZDOCX fences (see
                // processReplyWithCodeBlocks) — real generated binary/rich-
                // text files, not plain-text snippets. Reading a PDF as
                // UTF8 fails outright (returns nil below); RTF "succeeds"
                // but returns raw escape-sequence markup, not the readable
                // document text — neither is useful to show in the code
                // view or copy as text. Show a friendly description
                // instead; EZCodeBlockCell's Copy button separately knows
                // to copy the actual file data for these two extensions
                // rather than this description string (see its _copyTapped).
                NSString *kind = [pathExt isEqualToString:@"pdf"] ? @"PDF" : @"Word document (RTF)";
                code = [NSString stringWithFormat:@"📄 %@ generated — use Share to open or send it.", kind];
            } else {
                code = [NSString stringWithContentsOfFile:savedPath
                                                 encoding:NSUTF8StringEncoding error:nil];
            }
        } else if (r3.location != NSNotFound) {
            lang = [text substringWithRange:r3];
            code = r4.location != NSNotFound ? [text substringWithRange:r4] : @"";
        }
        if (!code) code = @"(code unavailable)";
        NSMutableDictionary *entry = [@{@"role":@"code",
                                        @"text": code,
                                        @"language": lang.length ? lang : @"code"} mutableCopy];
        if (savedPath) entry[@"savedPath"] = savedPath;
        [self.displayMessages addObject:[entry copy]];
        lastEnd = (NSInteger)(match.range.location + match.range.length);
    }
    // Remaining text after last code block
    if ((NSUInteger)lastEnd < text.length) {
        NSString *tail = [[text substringFromIndex:(NSUInteger)lastEnd]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (tail.length) [self.displayMessages addObject:@{@"role": role, @"text": tail}];
    }
    [self reloadAndScrollTable];
}

- (void)reloadAndScrollTable {
    [self.chatTableView reloadData];
    [self scrollChatToBottom];
}

/// Legacy name kept so all existing call sites compile unchanged.
- (void)appendToOldChat:(NSString *)text { [self appendToChat:text]; }

// ── Inline image grid insertion ───────────────────────────────────────────────

/// Inserts an image grid cell into the chat for one or more generated/edited images.
/// On success, imagePaths contains 1–4 local EZAttachments paths.
/// On error, isError = YES and errorText describes what went wrong.
/// Also persists to NSUserDefaults so image cells survive thread restore.
- (void)appendImageGridToChat:(NSArray<NSString *> *)imagePaths
                       prompt:(NSString *)prompt
                      isError:(BOOL)isError
                    errorText:(nullable NSString *)errorText {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendImageGridToChat:imagePaths prompt:prompt isError:isError errorText:errorText];
        });
        return;
    }

    NSMutableDictionary *entry = [@{
        @"role":       @"imagegrid",
        @"imagePaths": imagePaths ?: @[],
        @"prompt":     prompt ?: @"",
        @"isError":    @(isError),
    } mutableCopy];
    if (errorText) entry[@"errorText"] = errorText;

    [self.displayMessages addObject:[entry copy]];
    [self reloadAndScrollTable];

    // Persist the visual event in the same ordered thread timeline as its
    // prompt/result. UserDefaults remains only as a backwards-compatible
    // recovery path for threads created before this change.
    if (self.activeThread) {
        NSMutableDictionary *timelineEvent = [@{
            @"role": @"_ui_imagegrid",
            @"imagePaths": imagePaths ?: @[],
            @"prompt": prompt ?: @"",
            @"isError": @(isError),
            @"_uiOnly": @YES,
        } mutableCopy];
        if (errorText) timelineEvent[@"errorText"] = errorText;
        [self.chatContext addObject:[timelineEvent copy]];
        [self saveActiveThread];
    }

    // Persist image cells keyed by threadID so they survive restore
    [self persistImageGridCells];
}

/// Appends the saved imagegrid cells for this threadID to NSUserDefaults.
- (void)persistImageGridCells {
    NSString *threadID = self.activeThread.threadID;
    if (!threadID.length) return;
    NSString *key = [NSString stringWithFormat:@"EZImageCells_%@", threadID];
    NSMutableArray *cells = [NSMutableArray array];
    for (NSDictionary *msg in self.displayMessages) {
        if ([msg[@"role"] isEqualToString:@"imagegrid"]) [cells addObject:msg];
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:cells options:0 error:nil];
    if (data) [[NSUserDefaults standardUserDefaults] setObject:data forKey:key];
}

/// Restores image grid cells after a thread is loaded and displayMessages rebuilt.
- (void)restoreImageGridCellsForThread:(NSString *)threadID {
    if (!threadID.length) return;
    NSString *key  = [NSString stringWithFormat:@"EZImageCells_%@", threadID];
    NSData   *data = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    if (!data) return;
    NSArray *saved = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![saved isKindOfClass:[NSArray class]]) return;
    for (NSDictionary *cell in saved) {
        if (![cell[@"role"] isEqualToString:@"imagegrid"]) continue;
        // Do not append a side-cache duplicate of a grid already restored
        // from the thread timeline.
        NSArray *candidatePaths = cell[@"imagePaths"] ?: @[];
        BOOL alreadyRestored = NO;
        for (NSDictionary *shown in self.displayMessages) {
            if (![shown[@"role"] isEqualToString:@"imagegrid"]) continue;
            if ([shown[@"imagePaths"] isEqualToArray:candidatePaths]) {
                alreadyRestored = YES;
                break;
            }
        }
        if (alreadyRestored) continue;
        // Only restore cells whose images still exist on disk
        NSArray<NSString *> *paths = candidatePaths;
        NSMutableArray *validPaths = [NSMutableArray array];
        for (NSString *p in paths) {
            NSString *resolved = EZAttachmentPath(p);
            if (resolved.length > 0) [validPaths addObject:resolved];
        }
        if (validPaths.count == 0 && ![cell[@"isError"] boolValue]) continue;
        NSMutableDictionary *entry = [cell mutableCopy];
        entry[@"imagePaths"] = [validPaths copy];
        [self.displayMessages addObject:[entry copy]];
    }
    [self reloadAndScrollTable];
}

/// Shows an inline attachment preview bubble when the user attaches an image.
- (void)appendAttachmentBubble:(NSString *)imagePath {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self appendAttachmentBubble:imagePath];
        });
        return;
    }
    if (!imagePath.length) return;
    [self.displayMessages addObject:@{
        @"role":      @"attachment",
        @"imagePath": imagePath,
    }];
    [self reloadAndScrollTable];
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - UITableViewDataSource / UITableViewDelegate
// ─────────────────────────────────────────────────────────────────────────────

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.displayMessages.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *msg = self.displayMessages[(NSUInteger)indexPath.row];
    NSString *role    = msg[@"role"] ?: @"system";
    if ([role isEqualToString:@"imagegrid"]) {
        NSArray *paths = msg[@"imagePaths"] ?: @[];
        BOOL isError   = [msg[@"isError"] boolValue];
        return [EZImageGridCell heightForImageCount:(NSInteger)paths.count
                                        tableWidth:tableView.bounds.size.width
                                           isError:isError];
    }
    if ([role isEqualToString:@"attachment"]) {
        return [EZAttachmentPreviewCell heightForTableWidth:tableView.bounds.size.width];
    }
    return UITableViewAutomaticDimension;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *msg = self.displayMessages[(NSUInteger)indexPath.row];
    NSString *role    = msg[@"role"] ?: @"system";

    if ([role isEqualToString:@"imagegrid"]) {
        EZImageGridCell *cell = [tableView dequeueReusableCellWithIdentifier:@"EZImageGrid"
                                                                forIndexPath:indexPath];
        [cell configureWithImagePaths:msg[@"imagePaths"] ?: @[]
                               prompt:msg[@"prompt"] ?: @""
                              isError:[msg[@"isError"] boolValue]
                            errorText:msg[@"errorText"]
                 presentingController:self];
        return cell;
    }

    if ([role isEqualToString:@"attachment"]) {
        EZAttachmentPreviewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"EZAttachment"
                                                                        forIndexPath:indexPath];
        [cell configureWithImagePath:msg[@"imagePath"] ?: @""];
        [self ez_attachTapToExpandToCellIfNeeded:cell];
        return cell;
    }

    if ([role isEqualToString:@"code"]) {
        EZCodeBlockCell *cell = [tableView dequeueReusableCellWithIdentifier:@"EZCodeBlock"
                                                                forIndexPath:indexPath];
        [cell configureWithCode:msg[@"text"]
                       language:msg[@"language"]
                      savedPath:msg[@"savedPath"]
                 viewController:self];
        return cell;
    } else if ([role isEqualToString:@"user"] || [role isEqualToString:@"assistant"]) {
        EZBubbleCell *cell = [tableView dequeueReusableCellWithIdentifier:@"EZBubble"
                                                             forIndexPath:indexPath];
        [cell configureWithText:msg[@"text"] ?: @""
                         isUser:[role isEqualToString:@"user"]
                      timestamp:msg[@"timestamp"]
                        chatKey:msg[@"chatKey"]
                       threadID:msg[@"threadID"]];
        [self ez_attachCopyInteractionToCellIfNeeded:cell];
        return cell;
    } else {
        EZSystemCell *cell = [tableView dequeueReusableCellWithIdentifier:@"EZSystem"
                                                             forIndexPath:indexPath];
        cell.messageLabel.text = msg[@"text"] ?: @"";
        return cell;
    }
}

// ── Long-press-to-copy for chat bubbles (user prompts + AI completions) ─────
// Attached once per EZBubbleCell instance from cellForRowAtIndexPath, guarded
// below against re-attaching on every reuse/scroll. A single interaction
// instance stays correct across cell reuse because it resolves *which*
// message it belongs to at invocation time — by walking from the
// interaction's view up to its enclosing UITableViewCell and asking the
// table view for that cell's current indexPath — rather than capturing the
// message text once at attach time. This means it works without needing
// anything from EZBubbleCell's own header/implementation.
- (void)ez_attachCopyInteractionToCellIfNeeded:(UITableViewCell *)cell {
    for (id<UIInteraction> existing in cell.contentView.interactions) {
        if ([existing isKindOfClass:[UIContextMenuInteraction class]]) return;
    }
    UIContextMenuInteraction *interaction =
        [[UIContextMenuInteraction alloc] initWithDelegate:self];
    [cell.contentView addInteraction:interaction];
}

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
                         configurationForMenuAtLocation:(CGPoint)location {
    // interaction.view is the contentView we attached to in
    // ez_attachCopyInteractionToCellIfNeeded:. Its direct superview is the
    // owning UITableViewCell for a standard cell layout; walk up defensively
    // in case EZBubbleCell nests an extra container between them.
    UIView *walker = interaction.view;
    while (walker && ![walker isKindOfClass:[UITableViewCell class]]) {
        walker = walker.superview;
    }
    UITableViewCell *cell = (UITableViewCell *)walker;
    if (!cell) return nil;

    NSIndexPath *indexPath = [self.chatTableView indexPathForCell:cell];
    if (!indexPath || (NSUInteger)indexPath.row >= self.displayMessages.count) return nil;

    NSString *textToCopy = self.displayMessages[(NSUInteger)indexPath.row][@"text"];
    if (textToCopy.length == 0) return nil;

    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                     previewProvider:nil
                                                      actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        UIAction *copyAction = [UIAction actionWithTitle:@"Copy"
                                                    image:[UIImage systemImageNamed:@"doc.on.doc"]
                                               identifier:nil
                                                  handler:^(__kindof UIAction *action) {
            [UIPasteboard generalPasteboard].string = textToCopy;
            [self appendToChat:@"[System: Copied ✓]"];
        }];
        return [UIMenu menuWithTitle:@"" children:@[copyAction]];
    }];
}

// ── Tap-to-expand for attachment bubbles ────────────────────────────────────
// EZAttachmentPreviewCell (source not in context, like EZBubbleCell earlier)
// had no tap handling at all — added here the same way as the copy
// interaction above: attach a gesture from cellForRowAtIndexPath, resolve
// which row it's actually showing at tap time via indexPathForCell:, rather
// than needing anything from the cell class's own internals. Reuses the
// previewURL/QLPreviewControllerDataSource plumbing that already exists in
// this file for Sora and other file previews — no new preview
// infrastructure needed.
- (void)ez_attachTapToExpandToCellIfNeeded:(UITableViewCell *)cell {
    for (UIGestureRecognizer *existing in cell.contentView.gestureRecognizers) {
        if ([existing isKindOfClass:[UITapGestureRecognizer class]]) return;
    }
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(_attachmentBubbleTapped:)];
    cell.contentView.userInteractionEnabled = YES;
    [cell.contentView addGestureRecognizer:tap];
}

- (void)_attachmentBubbleTapped:(UITapGestureRecognizer *)gesture {
    UIView *walker = gesture.view;
    while (walker && ![walker isKindOfClass:[UITableViewCell class]]) {
        walker = walker.superview;
    }
    UITableViewCell *cell = (UITableViewCell *)walker;
    if (!cell) return;

    NSIndexPath *indexPath = [self.chatTableView indexPathForCell:cell];
    if (!indexPath || (NSUInteger)indexPath.row >= self.displayMessages.count) return;

    NSString *imagePath = self.displayMessages[(NSUInteger)indexPath.row][@"imagePath"];
    if (!imagePath.length || ![[NSFileManager defaultManager] fileExistsAtPath:imagePath]) return;

    self.previewURL = [NSURL fileURLWithPath:imagePath];
    QLPreviewController *ql = [[QLPreviewController alloc] init];
    ql.dataSource = self;
    [self presentViewController:ql animated:YES completion:nil];
}


- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateCoinBalanceDisplay];
    // SORA — commented out with the rest of the Sora code (see the big
    // commented block earlier in this file).
    // if (self.pendingVideoURL) {
    //     NSURL *url           = self.pendingVideoURL;
    //     self.pendingVideoURL = nil;
    //     self.previewURL      = url;
    //     QLPreviewController *ql = [[QLPreviewController alloc] init];
    //     ql.dataSource = self;
    //     [self presentViewController:ql animated:YES completion:nil];
    //     EZLog(EZLogLevelInfo, @"SORA", @"Deferred Sora video presented on viewWillAppear");
    // }
}

// ── One-time terms acceptance check ─────────────────────────────────────────
// Static flag prevents re-presenting on subsequent viewDidAppear calls
// (e.g. after the user dismisses a child modal during the same session).
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    static BOOL termsCheckPerformed = NO;
    if (!termsCheckPerformed) {
        termsCheckPerformed = YES;
        if (![EZTermsAcceptanceViewController hasUserAcceptedCurrentTerms]) {
            EZTermsAcceptanceViewController *acceptanceVC =
                [EZTermsAcceptanceViewController new];
            acceptanceVC.modalPresentationStyle = UIModalPresentationOverFullScreen;
            acceptanceVC.modalTransitionStyle   = UIModalTransitionStyleCrossDissolve;
            [self presentViewController:acceptanceVC animated:YES completion:nil];
        }
    }
}

- (void)codeBlockCopyTapped:(UIButton *)sender {
    NSString *code = objc_getAssociatedObject(sender, "EZCodeContent");
    if (code) {
        [UIPasteboard generalPasteboard].string = code;
        NSString *original = [sender titleForState:UIControlStateNormal];
        [sender setTitle:@"✓ Copied!" forState:UIControlStateNormal];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [sender setTitle:original forState:UIControlStateNormal];
        });
        EZLog(EZLogLevelInfo, @"CODE", @"Code copied to clipboard");
    }
}

- (void)codeBlockFileTapped:(UIButton *)sender {
    NSString *path = objc_getAssociatedObject(sender, "EZCodePath");
    if (path && [[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [self offerToOpenLocalFile:path];
    }
}

- (void)scrollChatToBottom {
    NSUInteger count = self.displayMessages.count;
    if (count == 0) return;
    NSIndexPath *last = [NSIndexPath indexPathForRow:(NSInteger)(count - 1) inSection:0];
    [self.chatTableView scrollToRowAtIndexPath:last
                             atScrollPosition:UITableViewScrollPositionBottom
                                     animated:YES];
}

// appendToOldChat: implemented above as a wrapper around appendToChat:

- (void)showGPT5StatusBanner {
    [self showStatusBannerWithMessages:@[
        @"GPT-5 is thinking…", @"Processing your request…",
        @"Still working — GPT-5 can take up to 3 min", @"Reasoning through your prompt…",
        @"Almost there — complex requests take longer", @"Hang tight, GPT-5 is thorough",
        @"Working hard on your answer…",
    ]];
}
- (void)hideGPT5StatusBanner {
    [self hideStatusBanner];
}

- (void)showImageGenStatusBanner {
    [self showStatusBannerWithMessages:@[
        @"Working on your request…",
        @"Do not leave the page while generating",
        @"Still generating — this can take a moment",
        @"Almost done…",
    ]];
}

// ── Generic status banner — shared by GPT-5's long-reasoning wait and image
// generation/editing. Same UIView/spinner/timer either way; only the
// message set (statusBannerMessages) changes, cycled by tickStatusBanner.
// Was GPT-5-only until image generation needed the identical spinner +
// cycling-text UX — rather than build a second parallel banner, this pulled
// the message array out of tickStatusBanner into a property so any caller
// can supply its own set. showGPT5StatusBanner/hideGPT5StatusBanner above
// are now thin wrappers kept for their existing call sites; behavior for
// GPT-5 is unchanged.
- (void)showStatusBannerWithMessages:(NSArray<NSString *> *)messages {
    // The status banner is the user-visible source of truth for a long
    // generation/reasoning operation.  Tie screen wakefulness to it instead
    // of the broad send action, whose many early-return paths could leave the
    // old reference count unbalanced.
    @try { [self ezcui_beginLongOperation:@"Visible long operation"]; } @catch (NSException *e) {
        EZLogf(EZLogLevelWarning, @"EZKeepAwake", @"begin failed for status banner: %@", e);
    }
    self.statusBannerMessages = messages.count ? messages : @[@"Working…"];
    self.statusBannerPhase = 0; [self.statusBannerSpinner startAnimating]; [self tickStatusBanner];
    self.statusBannerTimer = [NSTimer scheduledTimerWithTimeInterval:4.0 target:self
        selector:@selector(tickStatusBanner) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.statusBannerTimer forMode:NSRunLoopCommonModes];
    [UIView animateWithDuration:0.3 animations:^{ self.statusBannerView.alpha = 1.0; }];
}
- (void)hideStatusBanner {
    [self.statusBannerTimer invalidate]; self.statusBannerTimer = nil;
    [UIView animateWithDuration:0.3 animations:^{ self.statusBannerView.alpha = 0.0; }
     completion:^(BOOL _) {
        [self.statusBannerSpinner stopAnimating];
        @try { [self ezcui_endLongOperation]; } @catch (NSException *e) {
            EZLogf(EZLogLevelWarning, @"EZKeepAwake", @"end failed for status banner: %@", e);
        }
    }];
}
- (void)tickStatusBanner {
    NSArray<NSString *> *m = self.statusBannerMessages.count ? self.statusBannerMessages : @[@"Working…"];
    [UIView transitionWithView:self.statusBannerLabel duration:0.4
        options:UIViewAnimationOptionTransitionCrossDissolve
        animations:^{ self.statusBannerLabel.text = m[self.statusBannerPhase % m.count]; } completion:nil];
    self.statusBannerPhase++;
}
- (void)openSettings {
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:[[SettingsViewController alloc] init]];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)openBrainRot {
    BrainRotViewController *brainRot = [[BrainRotViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:brainRot];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:NO completion:nil];
}

- (void)presentCoinStoreForFeature:(NSString * _Nullable)featureName {
    // Save the current prompt so the user doesn't lose it when returning from the store
    NSString *pendingPrompt = self.messageTextField.text;

    EZCoinStoreViewController *store = [[EZCoinStoreViewController alloc] init];
    store.showLowCoinsWarning   = (featureName != nil);
    store.triggeringFeatureName = featureName ?: @"this feature";
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:store];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];

    // Restore the prompt when the store is dismissed
    if (pendingPrompt.length > 0) {
        __weak typeof(self) weakSelf = self;
        __weak UINavigationController *weakNav = nav;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __block NSInteger checks = 0;
            __block __weak void (^weakCheck)(void);
            void (^checkDismissed)(void);
            checkDismissed = ^{
                checks++;
                if (checks > 600) return;
                __strong UINavigationController *strongNav = weakNav;
                if (!strongNav || strongNav.presentingViewController == nil) {
                    __strong typeof(weakSelf) s = weakSelf;
                    if (s && s.messageTextField.text.length == 0) {
                        s.messageTextField.text = pendingPrompt;
                        [s appendToChat:
                            @"[System: Your prompt has been restored — tap Send when ready]"];
                    }
                    return;
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), weakCheck);
            };
            weakCheck = checkDismissed;
            checkDismissed();
        });
    }
}

- (void)openSupport {
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:[[SupportRequestViewController alloc] init]];
    [self presentViewController:nav animated:YES completion:nil];
}
- (void)openMemories {
    if (self.drawerOpen) {
        [self closeDrawer];
    }
    if (self.memoriesDrawerOpen) {
        [self closeMemoriesDrawerWithCompletion:nil];
        return;
    }

    if (!self.memoriesDrawerContainerView) {
        CGFloat drawerWidth = self.view.bounds.size.width * 0.75;

        self.memoriesDrawerDimView = [[UIView alloc] init];
        self.memoriesDrawerDimView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
        self.memoriesDrawerDimView.alpha = 0;
        self.memoriesDrawerDimView.hidden = YES;
        self.memoriesDrawerDimView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:self.memoriesDrawerDimView];
        [NSLayoutConstraint activateConstraints:@[
            [self.memoriesDrawerDimView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
            [self.memoriesDrawerDimView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
            [self.memoriesDrawerDimView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [self.memoriesDrawerDimView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        ]];
        UITapGestureRecognizer *dimTap = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(closeMemoriesDrawer)];
        [self.memoriesDrawerDimView addGestureRecognizer:dimTap];

        self.memoriesDrawerContainerView = [[UIView alloc] init];
        self.memoriesDrawerContainerView.backgroundColor = [UIColor systemBackgroundColor];
        self.memoriesDrawerContainerView.translatesAutoresizingMaskIntoConstraints = NO;
        self.memoriesDrawerContainerView.layer.shadowColor = [UIColor blackColor].CGColor;
        self.memoriesDrawerContainerView.layer.shadowOpacity = 0.22;
        self.memoriesDrawerContainerView.layer.shadowRadius = 14;
        self.memoriesDrawerContainerView.layer.shadowOffset = CGSizeMake(-6, 0);
        [self.view addSubview:self.memoriesDrawerContainerView];

        self.memoriesDrawerTrailingConstraint = [self.memoriesDrawerContainerView.trailingAnchor
            constraintEqualToAnchor:self.view.trailingAnchor constant:drawerWidth];
        [NSLayoutConstraint activateConstraints:@[
            self.memoriesDrawerTrailingConstraint,
            [self.memoriesDrawerContainerView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
            [self.memoriesDrawerContainerView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
            [self.memoriesDrawerContainerView.widthAnchor constraintEqualToConstant:drawerWidth],
        ]];

        MemoriesViewController *memoriesVC = [[MemoriesViewController alloc] init];
        __weak typeof(self) weakSelf = self;
        memoriesVC.closeRequestHandler = ^(dispatch_block_t completion) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) {
                if (completion) completion();
                return;
            }
            [strongSelf closeMemoriesDrawerWithCompletion:completion];
        };

        self.memoriesDrawerNavController = [[UINavigationController alloc]
            initWithRootViewController:memoriesVC];
        [self addChildViewController:self.memoriesDrawerNavController];
        self.memoriesDrawerNavController.view.translatesAutoresizingMaskIntoConstraints = NO;
        [self.memoriesDrawerContainerView addSubview:self.memoriesDrawerNavController.view];
        [NSLayoutConstraint activateConstraints:@[
            [self.memoriesDrawerNavController.view.topAnchor constraintEqualToAnchor:self.memoriesDrawerContainerView.topAnchor],
            [self.memoriesDrawerNavController.view.bottomAnchor constraintEqualToAnchor:self.memoriesDrawerContainerView.bottomAnchor],
            [self.memoriesDrawerNavController.view.leadingAnchor constraintEqualToAnchor:self.memoriesDrawerContainerView.leadingAnchor],
            [self.memoriesDrawerNavController.view.trailingAnchor constraintEqualToAnchor:self.memoriesDrawerContainerView.trailingAnchor],
        ]];
        [self.memoriesDrawerNavController didMoveToParentViewController:self];
        [self.view layoutIfNeeded];
    }

    self.memoriesDrawerOpen = YES;
    self.memoriesDrawerDimView.hidden = NO;
    self.memoriesDrawerTrailingConstraint.constant = 0;
    [UIView animateWithDuration:0.32
                          delay:0
         usingSpringWithDamping:0.88
          initialSpringVelocity:0.4
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.memoriesDrawerDimView.alpha = 1.0;
        [self.view layoutIfNeeded];
    } completion:nil];
}

- (void)openTTS {
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:[[TextToSpeechViewController alloc] init]];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)openCloning {
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:[[ElevenLabsCloneViewController alloc] init]];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)openGallery {
    EZPhotoGalleryViewController *gallery = [EZPhotoGalleryViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:gallery];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15, *)) {
        UISheetPresentationController *sheet = nav.sheetPresentationController;
        sheet.detents = @[UISheetPresentationControllerDetent.largeDetent];
        sheet.prefersGrabberVisible = YES;
    }
    [self presentViewController:nav animated:YES completion:nil];
}

/// Called when user taps "Ask a Question" in the gallery detail view.
/// Attaches the image to the chat input so the user can type their question.
- (void)handleAttachImageToChat:(NSNotification *)notification {
    NSString *incomingPath = [notification.userInfo[@"filePath"] isKindOfClass:[NSString class]]
        ? notification.userInfo[@"filePath"] : nil;
    if (incomingPath.length && [[NSFileManager defaultManager] fileExistsAtPath:incomingPath]) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kPendingExternalImageAskPath];
        [self attachImage:[NSURL fileURLWithPath:incomingPath]];
        [self.messageTextField becomeFirstResponder];
        return;
    }

    UIImage *image = notification.userInfo[@"image"];
    if (!image) return;

    // Use a temporary handoff file. attachImage: persists the real image into
    // EZPhotoGallery, keeping EZAttachments reserved for non-image files.
    NSString *dir = NSTemporaryDirectory();
    NSString *filename = [NSString stringWithFormat:@"gallery_ask_%@.jpg",
                          [NSUUID UUID].UUIDString];
    NSString *path = [dir stringByAppendingPathComponent:filename];
    if (![UIImageJPEGRepresentation(image, 0.92) writeToFile:path atomically:YES]) {
        [self appendToChat:@"[Error: Could not save Gallery image]"];
        return;
    }

    // Use the normal attachment pipeline. It creates the thumbnail bubble and
    // records a base64 vision block in chatContext; merely adding a path to
    // pendingImagePaths made the UI claim an image was attached while the
    // actual chat request contained no image at all.
    [self attachImage:[NSURL fileURLWithPath:path]];
    [self.messageTextField becomeFirstResponder];
}

/// Called when user taps "Edit with AI" in the gallery detail view.
/// Attaches the image and pre-fills the input with an edit prompt.
- (void)handleEditImageInChat:(NSNotification *)notification {
    NSString *incomingPath = [notification.userInfo[@"filePath"] isKindOfClass:[NSString class]]
        ? notification.userInfo[@"filePath"] : nil;
    if (incomingPath.length && [[NSFileManager defaultManager] fileExistsAtPath:incomingPath]) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"EZPendingExternalImageEditPath"];
        [self attachImage:[NSURL fileURLWithPath:incomingPath]];
        [[NSFileManager defaultManager] removeItemAtPath:incomingPath error:nil];
    } else {
    UIImage *image = notification.userInfo[@"image"];
    if (!image) return;

    // The attachment pipeline below stores the permanent copy in
    // EZPhotoGallery; this is only a short-lived handoff file.
    NSString *dir = NSTemporaryDirectory();
    NSString *filename = [NSString stringWithFormat:@"gallery_edit_%@.jpg",
                          [NSUUID UUID].UUIDString];
    NSString *path = [dir stringByAppendingPathComponent:filename];
    if (![UIImageJPEGRepresentation(image, 0.92) writeToFile:path atomically:YES]) {
        [self appendToChat:@"[Error: Could not save Gallery image]"];
        return;
    }

    // Keep edit attachments on the same complete path as ordinary image
    // attachments, including the visible bubble and the model-readable vision
    // message. callImageEdit still uses pendingImagePaths.lastObject below.
    [self attachImage:[NSURL fileURLWithPath:path]];
    }

    // Switch to edit mode — gpt-image-1-edit takes the direct path (see the
    // "Image edit mode" dispatch in the send flow above) which uses
    // pendingImagePaths.lastObject. Do NOT use a generation model here or
    // the intent classifier will be called and will ignore pendingImagePaths.
    // (Was previously a dead conditional here that computed whether
    // selectedModel was an image model but never did anything with the
    // result — enterImageEditModeFromCurrentSelection replaces it with the
    // real logic: remember selectedModel if it's edit-capable, else default.)
    [self enterImageEditModeFromCurrentSelection];

    self.messageTextField.text = @"Edit this image: ";
    [self.messageTextField becomeFirstResponder];
    // Move cursor to end
    UITextRange *end = [self.messageTextField textRangeFromPosition:self.messageTextField.endOfDocument
                                                         toPosition:self.messageTextField.endOfDocument];
    self.messageTextField.selectedTextRange = end;
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    @try {
        [self ezcui_endLongOperation];
    } @catch (NSException *e) {
        EZLogf(EZLogLevelWarning, @"EZKeepAwake", @"viewWillDisappear end failed: %@", e);
    }
}


- (void)dealloc {
    @try {
        [self ezcui_endLongOperation];
    } @catch (NSException *e) {
        EZLogf(EZLogLevelWarning, @"EZKeepAwake", @"dealloc end failed: %@", e);
    }
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}

@end

@interface ViewController (EZTitleFix)
@end
@implementation ViewController (EZTitleFix)
    - (void)setTitle:(NSString *)title {
        [super setTitle:title];
        // If the top-buttons category is present, let it sync its label.
        if ([self respondsToSelector:@selector(ezcui_setTopTitle:)]) {
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [self performSelector:@selector(ezcui_setTopTitle:) withObject:(title ?: @"")];
    #pragma clang diagnostic pop
        }
    }
@end
