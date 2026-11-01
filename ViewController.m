// ViewController.m
// EZCompleteUI v9.7
//
// Changes from v9.6:
//   - Chat song cards are now real inline players. Play no longer opens Quick
//     Look: EZMusicBubbleCell plays through the app-wide EZMediaPlayerManager
//     (background audio, lock-screen controls, scrubber). This file only passes
//     the card the song's length (display key "durationSeconds") so the total
//     time shows before playback.
//
// Changes from v9.5:
//   - Chat models can now create songs. The app tells ez-chat it supports the
//     tool (music_tools: YES). When the model calls it, ez-chat returns a
//     "music_request" (description, optional title/lyrics, instrumental flag,
//     length) and -performChatMusicRequest: takes over:
//       1. Loads current limits from ez-music (EZMusicService) and clamps the
//          length to what the server allows, never above 2 minutes in chat
//          and always a single version, which keeps one chat song at or under
//          60 coins at the current price.
//       2. Starts the song right away through EZMusicService (no confirmation
//          dialog, by request). Pricing, charging, refunds and the limit on
//          songs composing at once all stay in the ez-music Edge Function.
//          A system line tells the user the song was started and what it
//          reserved.
//       3. Polls until the song is finished and keeps the MP3 on the device
//          through EZMusicLibraryManager.
//       4. Adds a song card (EZMusicBubbleCell, display role "music") with
//          an inline player and Share, plus a UI-only "_ui_music" event in the thread so
//          the card survives a restore and the model knows what happened
//          (summarized in sanitizedContextForAPI, like image results). If you
//          switched to another chat while the song composed, the card is saved
//          into the chat that asked for it.
//   - Known limits: polling runs inside this screen. If the app is closed
//     while a song is composing, it still finishes on the server and shows up
//     in AI Music, but its card is not added to the chat afterward. Song
//     cards are not selectable for thread export yet.
//
// Changes from v9.4:
//   - Added the AI Music entry point: the history drawer's new "music" action
//     calls -openMusic, which presents EZMusicViewController (ElevenLabs
//     text-to-music, backed by the ez-music Edge Function) in a navigation
//     controller, the same way -openTTS presents Text to Speech.
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
#import "EZModelPickerViewController.h"
#import "EZImageSettingsViewController.h"
#import "EZAttachMenuViewController.h"
#import "ViewController+EZKeepAwake.h"
#import "ElevenLabsCloneViewController.h"
#import "EZCoinStoreViewController.h"
#import "EZFirstRunTutorialViewController.h"
#import "EZPhotoGalleryViewController.h"
#import "EZCoinPotView.h"
#import "TextToSpeechViewController.h"
#import "EZMusicViewController.h"
#import "EZMusicService.h"
#import "EZMusicLibraryManager.h"
#import "EZMusicBubbleCell.h"
#import "MemoriesViewController.h"
#import "SupportRequestViewController.h"
#import "BrainRotViewController.h"
#import "BRRicochetViewController.h"
#import "BRGameModePickerViewController.h"
#import "BRSlotMachineViewController.h"
#import "BRSlotGamePickerViewController.h"
#import "EZBubbleCell.h"
#import "EZSystemCell.h"
#import "EZCodeBlockCell.h"
#import "EZImageGridCell.h"
#import "EZEntitlementManager.h"
#import "EZAuthManager.h"         // needed for [EZAuthManager shared].accessToken (edge function JWT)
#import "EZSupabaseConfig.h"
#import "EZTermsAcceptanceViewController.h"
#import "HelperLogViewController.h"
#import "EZImageAttachmentPreparer.h"
#import <CommonCrypto/CommonDigest.h>

NSNotificationName const EZAttachExternalDocumentToChat = @"EZAttachExternalDocumentToChat";
static NSString *const kPendingExternalDocumentPath = @"EZPendingExternalDocumentPath";
static NSString *const kPendingExternalImageAskPath = @"EZPendingExternalImageAskPath";
static NSString *const kElevenLabsTTSModelID = @"eleven_v4";
// Image bytes become ~33% larger when base64-embedded in the ez-chat JSON.
// This leaves enough room under the edge function's 25 MiB request ceiling.
static const NSUInteger kEZChatImageAttachmentBudget = 17 * 1024 * 1024;
static const NSUInteger kEZMaximumImagesPerChatTurn = 15;

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

typedef void (^EZImageStreamEventBlock)(NSDictionary *event);
typedef void (^EZImageStreamCompletionBlock)(NSDictionary * _Nullable result, NSError * _Nullable error);

static BOOL EZIsImageTransportError(NSError *error) {
    if (!error) return NO;
    return error.code == NSURLErrorTimedOut ||
           error.code == NSURLErrorNetworkConnectionLost ||
           error.code == NSURLErrorCannotConnectToHost ||
           error.code == NSURLErrorNotConnectedToInternet;
}

static NSString *EZFriendlyImageTransportMessage(NSError *error) {
    if (EZIsImageTransportError(error)) {
        return @"The live preview connection was interrupted. Your image may still finish and appear in Gallery; the server will record the completed result or any refund.";
    }
    return error.localizedDescription.length ? error.localizedDescription : @"Image generation could not be completed.";
}

/// Small SSE client dedicated to ez-image. It parses complete SSE frames as
/// bytes arrive so partial image previews appear before the final response.
@interface EZImageEventStream : NSObject <NSURLSessionDataDelegate>
- (instancetype)initWithToken:(NSString *)token
                          body:(NSDictionary *)body
                         event:(EZImageStreamEventBlock)event
                    completion:(EZImageStreamCompletionBlock)completion;
- (void)start;
@end

@interface EZImageEventStream ()
@property (nonatomic, copy) NSString *token;
@property (nonatomic, copy) NSDictionary *body;
@property (nonatomic, copy) EZImageStreamEventBlock eventHandler;
@property (nonatomic, copy) EZImageStreamCompletionBlock completionHandler;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableData *pendingBytes;
@property (nonatomic, strong) NSMutableData *httpErrorBytes;
@property (nonatomic, assign) NSUInteger frameSearchOffset;
@property (nonatomic, assign) NSInteger httpStatus;
@property (nonatomic, strong) NSDictionary *finalResult;
@property (nonatomic, assign) BOOL finished;
@end

@implementation EZImageEventStream
- (instancetype)initWithToken:(NSString *)token body:(NSDictionary *)body
                         event:(EZImageStreamEventBlock)event
                    completion:(EZImageStreamCompletionBlock)completion {
    if ((self = [super init])) {
        _token = [token copy];
        _body = [body copy];
        _eventHandler = [event copy];
        _completionHandler = [completion copy];
        _pendingBytes = [NSMutableData data];
        _httpErrorBytes = [NSMutableData data];
    }
    return self;
}

- (void)start {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/functions/v1/ez-image", EZSupabaseURL]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = 300;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"text/event-stream" forHTTPHeaderField:@"Accept"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", self.token] forHTTPHeaderField:@"Authorization"];
    NSError *jsonError = nil;
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:self.body options:0 error:&jsonError];
    if (jsonError) {
        [self finishWithResult:nil error:jsonError];
        return;
    }
    NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
    delegateQueue.name = @"com.ezcompleteui.image-stream";
    delegateQueue.maxConcurrentOperationCount = 1;
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    self.session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:delegateQueue];
    [[self.session dataTaskWithRequest:request] resume];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
 didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) self.httpStatus = ((NSHTTPURLResponse *)response).statusCode;
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    if (self.httpStatus >= 400) {
        [self.httpErrorBytes appendData:data];
        return;
    }
    [self.pendingBytes appendData:data];
    [self consumeCompleteFrames];
}

- (void)consumeCompleteFrames {
    while (self.pendingBytes.length) {
        const uint8_t *bytes = self.pendingBytes.bytes;
        NSUInteger length = self.pendingBytes.length;
        NSUInteger frameEnd = NSNotFound;
        NSUInteger delimiterLength = 0;
        for (NSUInteger i = MIN(self.frameSearchOffset, length); i < length; i++) {
            if (i + 1 < length && bytes[i] == '\n' && bytes[i + 1] == '\n') {
                frameEnd = i; delimiterLength = 2; break;
            }
            if (i + 3 < length && bytes[i] == '\r' && bytes[i + 1] == '\n' &&
                bytes[i + 2] == '\r' && bytes[i + 3] == '\n') {
                frameEnd = i; delimiterLength = 4; break;
            }
        }
        if (frameEnd == NSNotFound) {
            self.frameSearchOffset = length > 3 ? length - 3 : 0;
            return;
        }
        NSData *frame = [self.pendingBytes subdataWithRange:NSMakeRange(0, frameEnd)];
        [self.pendingBytes replaceBytesInRange:NSMakeRange(0, frameEnd + delimiterLength) withBytes:NULL length:0];
        self.frameSearchOffset = 0;
        [self consumeFrame:frame];
    }
}

- (void)consumeFrame:(NSData *)frame {
    NSString *text = [[NSString alloc] initWithData:frame encoding:NSUTF8StringEncoding];
    if (!text.length) return;
    NSMutableArray<NSString *> *dataLines = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        if ([line hasPrefix:@"data:"]) {
            NSString *value = [line substringFromIndex:5];
            if ([value hasPrefix:@" "]) value = [value substringFromIndex:1];
            [dataLines addObject:value];
        }
    }
    if (!dataLines.count) return;
    NSString *payload = [dataLines componentsJoinedByString:@"\n"];
    if ([payload isEqualToString:@"[DONE]"]) return;
    NSData *jsonData = [payload dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *event = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:nil];
    if (![event isKindOfClass:[NSDictionary class]]) return;
    NSString *type = [event[@"type"] isKindOfClass:[NSString class]] ? event[@"type"] : @"";
    // The edge function has used a few terminal event names over time.  Also
    // accept a result payload with images even if an intermediary/proxy drops
    // its type field, so a successful edit is never discarded at EOF.
    if ([type isEqualToString:@"complete"] || [type isEqualToString:@"completed"] ||
        [type isEqualToString:@"done"] || [type isEqualToString:@"result"] ||
        [type isEqualToString:@"final"] ||
        [event[@"images"] isKindOfClass:[NSArray class]]) {
        self.finalResult = event;
    } else if ([type isEqualToString:@"error"] || [type isEqualToString:@"failed"]) {
        NSString *message = [event[@"error"] isKindOfClass:[NSString class]] ? event[@"error"] : @"Image generation failed";
        self.finalResult = @{ @"error": message, @"reason": event[@"reason"] ?: @"" };
    }
    EZImageStreamEventBlock handler = self.eventHandler;
    if (handler) dispatch_async(dispatch_get_main_queue(), ^{ handler(event); });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
 didCompleteWithError:(NSError *)error {
    if (self.finished) return;
    if (error) {
        [self finishWithResult:nil error:error];
        return;
    }
    if (self.httpStatus >= 400) {
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:self.httpErrorBytes options:0 error:nil];
        NSString *message = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] :
            [[NSString alloc] initWithData:self.httpErrorBytes encoding:NSUTF8StringEncoding];
        NSString *reason = [json[@"reason"] isKindOfClass:[NSString class]] ? json[@"reason"] : nil;
        NSString *description = reason.length ? [NSString stringWithFormat:@"%@ %@", message ?: @"Image request failed", reason]
                                               : (message.length ? message : @"Image request failed");
        if (self.httpStatus == 401) {
            [self finishWithResult:nil error:[NSError errorWithDomain:@"EZImageStreamHTTP" code:401
                userInfo:@{NSLocalizedDescriptionKey: description, @"HTTPStatus": @(self.httpStatus)}]];
            return;
        }
        self.finalResult = @{ @"error": description, @"HTTPStatus": @(self.httpStatus) };
        [self finishWithResult:self.finalResult error:nil];
        return;
    }
    if (!self.finalResult && self.pendingBytes.length) {
        NSData *frame = [self.pendingBytes copy];
        [self.pendingBytes setLength:0];
        [self consumeFrame:frame];
    }
    if (self.finalResult) [self finishWithResult:self.finalResult error:nil];
    else [self finishWithResult:nil error:[NSError errorWithDomain:@"EZImageStream" code:NSURLErrorNetworkConnectionLost
        userInfo:@{NSLocalizedDescriptionKey: @"Image stream connection closed early; retrying."}]];
}

- (void)finishWithResult:(NSDictionary *)result error:(NSError *)error {
    if (self.finished) return;
    self.finished = YES;
    [self.session finishTasksAndInvalidate];
    EZImageStreamCompletionBlock completion = self.completionHandler;
    self.completionHandler = nil;
    self.eventHandler = nil;
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(result, error); });
}

- (void)cancel {
    if (self.finished) return;
    self.finished = YES;
    self.completionHandler = nil;
    self.eventHandler = nil;
    [self.session invalidateAndCancel];
}
@end


typedef NS_ENUM(NSInteger, EZAttachMode) {
    EZAttachModeNone,
    EZAttachModeWhisper,
    EZAttachModeAnalyze,
};

// Defined with the chat music code further down; needed earlier by thread restore.
static NSDictionary *EZChatMusicDisplayMessage(NSDictionary *event);

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
@property (nonatomic, strong) UIButton      *threadSelectionButton;
@property (nonatomic, assign) BOOL          threadSelectionActive;
@property (nonatomic, strong) NSMutableIndexSet *selectedThreadMessageIndexes;
@property (nonatomic, strong) UIView        *threadSelectionBar;
@property (nonatomic, strong) UILabel       *threadSelectionCountLabel;
@property (nonatomic, strong) NSArray<UIButton *> *threadSelectionActionButtons;
@property (nonatomic, strong) UIView        *threadActionOverlay;
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


@property (nonatomic, strong) UIView        *statusBannerView;
@property (nonatomic, strong) UILabel       *statusBannerLabel;
@property (nonatomic, strong) UIActivityIndicatorView *statusBannerSpinner;
@property (nonatomic, strong) UIView        *imageProgressView;
@property (nonatomic, strong) UIImageView   *imagePreviewImageView;
@property (nonatomic, strong) CAShapeLayer  *imageProgressTrackRing;
@property (nonatomic, strong) CAShapeLayer  *imageProgressRing;
@property (nonatomic, strong) UILabel       *imageProgressLabel;
@property (nonatomic, assign) CGFloat        imageGenerationProgress;
@property (nonatomic, strong) EZImageEventStream *imageEventStream;
@property (nonatomic, strong) NSLayoutConstraint *imageProgressWidthConstraint;
@property (nonatomic, strong) NSLayoutConstraint *imageProgressHeightConstraint;
@property (nonatomic, strong) NSLayoutConstraint *imageBannerHeightConstraint;
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
@property (nonatomic, copy) NSString *chatImageSourcePath;
// Songs a chat model asked for that are still composing, keyed by generation
// ID, so each one is polled exactly once. Created on first use.
@property (nonatomic, strong) NSMutableDictionary<NSString *, EZMusicPollToken *> *chatMusicPollTokens;

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
- (void)handleImageGenerationStreamEvent:(NSDictionary *)event;
- (void)startImageGenerationStreamWithToken:(NSString *)token
                                        body:(NSDictionary *)body
                                       event:(EZImageStreamEventBlock)event
                                  completion:(EZImageStreamCompletionBlock)completion;
- (void)startImageGenerationStreamWithToken:(NSString *)token
                                        body:(NSDictionary *)body
                                       event:(EZImageStreamEventBlock)event
                                  completion:(EZImageStreamCompletionBlock)completion
                                  retryCount:(NSInteger)retryCount;
- (void)enterImageEditModeFromCurrentSelection;
- (void)exitImageEditModeIfNeeded;
- (void)handleAPIError:(NSString *)msg;
- (void)checkReplyForLocalFilePaths:(NSString *)reply;
- (NSArray *)sanitizedContextForAPI:(NSArray *)context
                  modelSupportsVision:(BOOL)supportsVision
                      useResponsesAPI:(BOOL)useResponsesAPI;
- (NSDictionary *)loggableChatRequestBody:(NSDictionary *)body;
// - (void)downloadAndShowVideo:(NSString *)urlString;   // SORA — see the big commented block
- (void)appendImageGridToChat:(NSArray<NSString *> *)imagePaths
                       prompt:(NSString *)prompt
                      isError:(BOOL)isError
                    errorText:(nullable NSString *)errorText;
- (void)persistImagePath:(NSString *)path prompt:(NSString *)prompt;
- (void)performChatImageRequest:(NSDictionary *)imageRequest sourcePath:(NSString *)sourcePath;
- (void)performChatMusicRequest:(NSDictionary *)musicRequest;
- (NSString *)ez_chatMusicSummaryForEvent:(NSDictionary *)event;
- (void)callGptImage1:(NSString *)prompt model:(NSString *)imageModel;
- (void)callImageEdit:(NSString *)prompt imagePath:(NSString *)imagePath
               model:(NSString *)imageModel preserveChatModel:(BOOL)preserveChatModel;
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
- (void)completeHelperDirectAnswer:(NSString *)answer
                     originalPrompt:(NSString *)prompt
                              token:(NSString *)token
                           threadID:(NSString *)threadID;
- (void)presentGalleryForChatAttachments;

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
    [self consumePendingSharedImageQuestions];
    [self consumePendingExternalDocument];
    [[EZEntitlementManager shared] refreshBalanceWithCompletion:^(NSInteger balance) {
        [self updateCoinBalanceDisplay];
    }];
    [self recoverUndeliveredGalleryImagesIfNeeded];

}

- (void)consumePendingSharedImageQuestions {
    NSArray *paths = [[NSUserDefaults standardUserDefaults] objectForKey:@"EZPendingSharedImageAskPaths"];
    if (![paths isKindOfClass:[NSArray class]] || !paths.count) return;
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"EZPendingSharedImageAskPaths"];
    [self handleAttachImageToChat:[NSNotification notificationWithName:EZAttachImageToChat
                                                                  object:nil
                                                                userInfo:@{ @"filePaths": paths }]];
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
           @"gpt-6.1-sol", @"gpt-6.1-terra", @"gpt-6-luna",
           @"gpt-5-pro", @"gpt-5", @"gpt-5-mini",
           @"gpt-4o", @"gpt-4o-mini",
           // ── Image Generation & Edit ───────────────────────────────────────
           @"gpt-image-2.5-sunburst", // recommended precision image editing — low/medium/high/xhigh/max
           @"gpt-image-2.5-flare",    // newest, fastest — low/medium/high/xhigh/max
           @"gpt-image-2",          // low/medium/high only
           @"gpt-image-1-mini",     // faster/cheaper image generation
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
    // Retired picker choices can remain in a user's saved preference. Move
    // them to their current equivalents before the first request is made.
    if ([self.selectedModel isEqualToString:@"gpt-6-sol"] ||
        [self.selectedModel isEqualToString:@"gpt-5.6-sol"]) {
        self.selectedModel = @"gpt-6.1-sol";
    } else if ([self.selectedModel isEqualToString:@"gpt-5.6-luna"]) {
        self.selectedModel = @"gpt-6-luna";
    } else if ([self.selectedModel isEqualToString:@"gpt-5.6-terra"]) {
        self.selectedModel = @"gpt-6.1-terra";
    } else if ([self.selectedModel isEqualToString:@"gpt-image-1"] ||
               [self.selectedModel isEqualToString:@"gpt-image-1.5"] ||
               [self.selectedModel isEqualToString:@"chatgpt-image-latest"]) {
        self.selectedModel = @"gpt-image-2";
    } else if ([self.selectedModel isEqualToString:@"gpt-4"] ||
               [self.selectedModel isEqualToString:@"gpt-4-turbo"]) {
        self.selectedModel = @"gpt-4o";
    } else if ([self.selectedModel isEqualToString:@"gpt-3.5-turbo"]) {
        self.selectedModel = @"gpt-4o-mini";
    }
    [[NSUserDefaults standardUserDefaults] setObject:self.selectedModel forKey:@"selectedModel"];
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
    NSString *defaultThreadTitle = NSLocalizedString(@"EZThread.NewConversation", nil);
    if ([self.activeThread.title isEqualToString:defaultThreadTitle] ||
        [self.activeThread.title isEqualToString:@"New Conversation"] ||
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

                // Memory context is internal routing metadata, not a title.
                if ([text hasPrefix:@"[Memories with possible relevance:"] ||
                    [text hasPrefix:@"[Possibly relevant memories:"]) {
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

        // Songs a chat model created are UI-only timeline events too. A failed
        // song has no card (its error line was a transient system message), so
        // only successful ones are rebuilt.
        if ([role isEqualToString:@"_ui_music"]) {
            NSString *songEntryID = [msg[@"entryID"] isKindOfClass:[NSString class]] ? msg[@"entryID"] : @"";
            if (![msg[@"isError"] boolValue] && songEntryID.length > 0) {
                [self.displayMessages addObject:EZChatMusicDisplayMessage(msg)];
            }
            continue;
        }

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
                    @"timestamp": msg[@"timestamp"] ?: @"time unavailable",
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
        } else if ([role isEqualToString:@"system"] &&
                   ([msg[@"isUserAuthoredSystemMessage"] boolValue] ||
                    [msg[@"isCustomInstruction"] boolValue])) {
            // A user-saved custom instruction is distinct from our internal
            // prompt/status plumbing and may be selected/exported.
            [self.displayMessages addObject:@{
                @"role": @"system",
                @"text": text,
                @"isUserAuthoredSystemMessage": @YES,
            }];
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
    self.supportRequestButton = [self _iconButton:@"questionmark.circle.fill" tint:[UIColor systemRedColor] action:@selector(openTutorial)];
    self.supportRequestButton.accessibilityLabel = @"Tutorial";
    // One compact entry point for app navigation and recent chats.
    self.historyButton   = [self _iconButton:@"line.3.horizontal" tint:nil
                                      action:@selector(openHistory)];
    self.historyButton.accessibilityLabel = @"Navigation and recent chats";
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

    // Keep Memories and multi-select as separate, discoverable actions.
    self.memoriesButton = [self _iconButton:@"brain.head.profile" tint:[UIColor systemTealColor]
                                     action:@selector(openMemories)];
    self.memoriesButton.accessibilityLabel = @"Memories";
    self.threadSelectionButton = [self _iconButton:@"checkmark.circle" tint:[UIColor systemBlueColor]
                                            action:@selector(toggleThreadSelection)];
    [self.threadSelectionButton setTitle:@"SEL" forState:UIControlStateNormal];
    self.threadSelectionButton.titleLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
    self.threadSelectionButton.accessibilityLabel = @"Select parts of this thread";
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

    // Keep navigation and response actions on the left, the balance centered,
    // and distinct selection/memory actions on the right.
    UIView *topStack = [[UIView alloc] init];
    topStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:topStack];
    [topStack addSubview:self.historyButton];
    [topStack addSubview:self.coinPotView];
    [topStack addSubview:self.clipboardButton];
    [topStack addSubview:self.speakButton];
    [topStack addSubview:self.threadSelectionButton];
    [topStack addSubview:self.memoriesButton];
    [topStack addSubview:self.supportRequestButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.coinPotView.widthAnchor constraintEqualToConstant:48],
        [self.coinPotView.heightAnchor constraintEqualToConstant:52],
        [self.coinPotView.centerXAnchor constraintEqualToAnchor:topStack.centerXAnchor],
        [self.coinPotView.topAnchor constraintEqualToAnchor:topStack.topAnchor],
        [self.coinPotView.bottomAnchor constraintEqualToAnchor:topStack.bottomAnchor],
        [self.historyButton.leadingAnchor constraintEqualToAnchor:topStack.leadingAnchor],
        [self.historyButton.centerYAnchor constraintEqualToAnchor:self.coinPotView.centerYAnchor],
        [self.clipboardButton.leadingAnchor constraintEqualToAnchor:self.historyButton.trailingAnchor constant:8],
        [self.clipboardButton.centerYAnchor constraintEqualToAnchor:self.coinPotView.centerYAnchor],
        [self.speakButton.leadingAnchor constraintEqualToAnchor:self.clipboardButton.trailingAnchor constant:8],
        [self.speakButton.centerYAnchor constraintEqualToAnchor:self.coinPotView.centerYAnchor],
        [self.memoriesButton.trailingAnchor constraintEqualToAnchor:topStack.trailingAnchor],
        [self.threadSelectionButton.trailingAnchor constraintEqualToAnchor:self.memoriesButton.leadingAnchor constant:-8],
        [self.supportRequestButton.trailingAnchor constraintEqualToAnchor:self.threadSelectionButton.leadingAnchor constant:-8],
        [self.supportRequestButton.centerYAnchor constraintEqualToAnchor:self.coinPotView.centerYAnchor],
        [self.threadSelectionButton.centerYAnchor constraintEqualToAnchor:self.coinPotView.centerYAnchor],
        [self.memoriesButton.centerYAnchor constraintEqualToAnchor:self.coinPotView.centerYAnchor],
        [self.speakButton.trailingAnchor constraintLessThanOrEqualToAnchor:self.coinPotView.leadingAnchor constant:-8],
        [self.supportRequestButton.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.coinPotView.trailingAnchor constant:8],
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
    self.threadTitleLabel.text            = NSLocalizedString(@"EZThread.NewConversation", nil);
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
    [self.chatTableView registerClass:[EZMusicBubbleCell class] forCellReuseIdentifier:@"EZMusic"];
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
    self.imageProgressView = [[UIView alloc] init];
    self.imageProgressView.translatesAutoresizingMaskIntoConstraints = NO;
    self.imageProgressView.hidden = YES;
    [self.statusBannerView addSubview:self.imageProgressView];
    self.imagePreviewImageView = [[UIImageView alloc] init];
    self.imagePreviewImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.imagePreviewImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.imagePreviewImageView.clipsToBounds = YES;
    self.imagePreviewImageView.layer.cornerRadius = 12;
    self.imagePreviewImageView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.16];
    [self.imageProgressView addSubview:self.imagePreviewImageView];
    self.imageProgressTrackRing = [CAShapeLayer layer];
    self.imageProgressTrackRing.fillColor = UIColor.clearColor.CGColor;
    self.imageProgressTrackRing.strokeColor = [self.view.tintColor colorWithAlphaComponent:0.25].CGColor;
    self.imageProgressTrackRing.lineWidth = 5.0;
    [self.imageProgressView.layer addSublayer:self.imageProgressTrackRing];
    self.imageProgressRing = [CAShapeLayer layer];
    self.imageProgressRing.fillColor = UIColor.clearColor.CGColor;
    self.imageProgressRing.strokeColor = self.view.tintColor.CGColor;
    self.imageProgressRing.lineWidth = 5.0;
    self.imageProgressRing.lineCap = kCALineCapRound;
    self.imageProgressRing.strokeEnd = 0;
    [self.imageProgressView.layer addSublayer:self.imageProgressRing];
    self.imageProgressLabel = [[UILabel alloc] init];
    self.imageProgressLabel.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightBold];
    self.imageProgressLabel.textColor = UIColor.whiteColor;
    self.imageProgressLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.65];
    self.imageProgressLabel.layer.cornerRadius = 12;
    self.imageProgressLabel.clipsToBounds = YES;
    self.imageProgressLabel.textAlignment = NSTextAlignmentCenter;
    self.imageProgressLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.imageProgressView addSubview:self.imageProgressLabel];
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

    // These toggles belong with the message being composed, rather than in the
    // app navigation bar. Keeping them adjacent makes their scope obvious.
    [self.inputContainer addSubview:self.webSearchButton];
    [self.inputContainer addSubview:self.helperDirectAnswersButton];
    
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
        [self.chatTableView.topAnchor constraintEqualToAnchor:self.threadTitleLabel.bottomAnchor constant:8],
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
        [self.attachButton.widthAnchor constraintEqualToConstant:32],
        [self.attachButton.heightAnchor constraintEqualToConstant:32],
        [self.dictateButton.leadingAnchor constraintEqualToAnchor:self.attachButton.trailingAnchor constant:6],
        [self.dictateButton.centerYAnchor constraintEqualToAnchor:self.attachButton.centerYAnchor],
        [self.dictateButton.widthAnchor constraintEqualToConstant:32],
        [self.dictateButton.heightAnchor constraintEqualToConstant:32],
        [self.webSearchButton.leadingAnchor constraintEqualToAnchor:self.attachButton.leadingAnchor],
        [self.webSearchButton.topAnchor constraintEqualToAnchor:self.attachButton.bottomAnchor constant:4],
        [self.webSearchButton.widthAnchor constraintEqualToConstant:30],
        [self.webSearchButton.heightAnchor constraintEqualToConstant:30],
        [self.helperDirectAnswersButton.leadingAnchor constraintEqualToAnchor:self.dictateButton.leadingAnchor],
        [self.helperDirectAnswersButton.centerYAnchor constraintEqualToAnchor:self.webSearchButton.centerYAnchor],
        [self.helperDirectAnswersButton.widthAnchor constraintEqualToConstant:30],
        [self.helperDirectAnswersButton.heightAnchor constraintEqualToConstant:30],
        [inputWrapper.leadingAnchor constraintEqualToAnchor:self.helperDirectAnswersButton.trailingAnchor constant:8],
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
        [self.imageProgressView.leadingAnchor constraintEqualToAnchor:self.statusBannerView.leadingAnchor constant:10],
        [self.imageProgressView.centerYAnchor constraintEqualToAnchor:self.statusBannerView.centerYAnchor],
        [self.statusBannerSpinner.leadingAnchor constraintEqualToAnchor:self.statusBannerView.leadingAnchor constant:12],
        [self.statusBannerSpinner.centerYAnchor constraintEqualToAnchor:self.statusBannerView.centerYAnchor],
        [self.statusBannerLabel.leadingAnchor constraintEqualToAnchor:self.imageProgressView.trailingAnchor constant:8],
        [self.statusBannerLabel.trailingAnchor constraintEqualToAnchor:self.statusBannerView.trailingAnchor constant:-12],
        [self.statusBannerLabel.topAnchor constraintEqualToAnchor:self.statusBannerView.topAnchor constant:10],
        [self.statusBannerLabel.bottomAnchor constraintEqualToAnchor:self.statusBannerView.bottomAnchor constant:-10],
    ]];
    self.imageProgressWidthConstraint = [self.imageProgressView.widthAnchor constraintEqualToConstant:22];
    self.imageProgressHeightConstraint = [self.imageProgressView.heightAnchor constraintEqualToConstant:22];
    self.imageProgressWidthConstraint.active = YES;
    self.imageProgressHeightConstraint.active = YES;
    [NSLayoutConstraint activateConstraints:@[
        [self.imagePreviewImageView.leadingAnchor constraintEqualToAnchor:self.imageProgressView.leadingAnchor],
        [self.imagePreviewImageView.trailingAnchor constraintEqualToAnchor:self.imageProgressView.trailingAnchor],
        [self.imagePreviewImageView.topAnchor constraintEqualToAnchor:self.imageProgressView.topAnchor],
        [self.imagePreviewImageView.bottomAnchor constraintEqualToAnchor:self.imageProgressView.bottomAnchor],
        [self.imageProgressLabel.widthAnchor constraintEqualToConstant:48],
        [self.imageProgressLabel.heightAnchor constraintEqualToConstant:24],
        [self.imageProgressLabel.centerXAnchor constraintEqualToAnchor:self.imageProgressView.centerXAnchor],
        [self.imageProgressLabel.centerYAnchor constraintEqualToAnchor:self.imageProgressView.centerYAnchor],
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
    [self installThreadSelectionBar];
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
    b.translatesAutoresizingMaskIntoConstraints = NO;
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

// A validated helper answer is a completed chat turn, not merely a routing
// hint. Keep its persistence/display path equivalent to a main-model reply so
// the thread and memory stores remain internally consistent.
- (void)completeHelperDirectAnswer:(NSString *)answer
                     originalPrompt:(NSString *)prompt
                              token:(NSString *)token
                           threadID:(NSString *)threadID {
    if (answer.length == 0) return;
    if (threadID.length > 0 && ![self.activeThread.threadID isEqualToString:threadID]) {
        self.sendButton.enabled = YES;
        EZLog(EZLogLevelInfo, @"TRIAGE", @"Discarded helper direct answer after conversation changed");
        return;
    }

    self.sendButton.enabled = YES;
    self.lastAIResponse = answer;
    [self.chatContext addObject:@{ @"role": @"assistant", @"content": answer }];

    NSMutableArray<NSString *> *codePaths = [NSMutableArray array];
    NSString *displayAnswer = [self processReplyWithCodeBlocks:answer savedPaths:codePaths];
    [self appendToChat:[NSString stringWithFormat:@"AI: %@", displayAnswer]];
    [self appendToChat:@"[System: Answered directly by helper model ⚡]"];
    [self saveActiveThread];
    [self checkReplyForLocalFilePaths:answer];
    [self updateCoinBalanceDisplay];

    EZLogf(EZLogLevelInfo, @"TRIAGE", @"Displayed helper direct answer (%lu chars)",
           (unsigned long)answer.length);
    createMemoryFromCompletion(prompt ?: @"", answer, token, threadID, @[],
    ^(NSString *entry) {
        if (entry) EZLogf(EZLogLevelInfo, @"MEMORY", @"Saved helper answer memory (%lu chars)",
                          (unsigned long)entry.length);
    });
}

    // ─────────────────────────────────────────────────────────────────────────────
// MARK: - Thread Title Editing
// ─────────────────────────────────────────────────────────────────────────────

/// Syncs the visible threadTitleLabel with the active thread's current title.
- (void)updateThreadTitleLabel {
    NSString *title = self.activeThread.title;
    if (!title.length || [title isEqualToString:NSLocalizedString(@"EZThread.NewConversation", nil)] ||
        [title isEqualToString:@"New Conversation"]) {
        self.threadTitleLabel.text      = NSLocalizedString(@"EZThread.NewConversation", nil);
        self.threadTitleLabel.textColor = [UIColor tertiaryLabelColor];
    } else {
        self.threadTitleLabel.text      = title;
        self.threadTitleLabel.textColor = [UIColor secondaryLabelColor];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Styled Thread Menus
// ─────────────────────────────────────────────────────────────────────────────

- (void)dismissThreadActionOverlay {
    UIView *overlay = self.threadActionOverlay;
    self.threadActionOverlay = nil;
    [UIView animateWithDuration:0.18 animations:^{ overlay.alpha = 0; }
                     completion:^(__unused BOOL finished) { [overlay removeFromSuperview]; }];
}

- (UIView *)presentThreadActionCardWithTitle:(NSString *)title detail:(NSString *)detail {
    [self dismissThreadActionOverlay];
    UIView *overlay = [[UIView alloc] initWithFrame:self.view.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.60];
    overlay.alpha = 0;
    self.threadActionOverlay = overlay;
    [self.view addSubview:overlay];

    UIView *card = [UIView new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor colorWithRed:0.035 green:0.075 blue:0.14 alpha:1.0];
    card.layer.cornerRadius = 24;
    card.layer.borderWidth = 1;
    card.layer.borderColor = [UIColor colorWithRed:0.15 green:0.78 blue:1.0 alpha:0.70].CGColor;
    [overlay addSubview:card];
    UILabel *titleLabel = [UILabel new];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = title;
    titleLabel.textColor = UIColor.whiteColor;
    titleLabel.font = [UIFont systemFontOfSize:21 weight:UIFontWeightBold];
    [card addSubview:titleLabel];
    UILabel *detailLabel = [UILabel new];
    detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    detailLabel.text = detail;
    detailLabel.textColor = [UIColor colorWithWhite:0.72 alpha:1];
    detailLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    detailLabel.numberOfLines = 0;
    [card addSubview:detailLabel];
    [NSLayoutConstraint activateConstraints:@[
        [card.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor constant:20],
        [card.trailingAnchor constraintEqualToAnchor:overlay.trailingAnchor constant:-20],
        [card.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:22],
        [titleLabel.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:22],
        [titleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-22],
        [detailLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:5],
        [detailLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [detailLabel.trailingAnchor constraintEqualToAnchor:titleLabel.trailingAnchor],
    ]];
    [UIView animateWithDuration:0.20 animations:^{ overlay.alpha = 1; }];
    return card;
}

- (UIButton *)threadActionButtonWithTitle:(NSString *)title symbol:(NSString *)symbol color:(UIColor *)color {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    UIButtonConfiguration *configuration = [UIButtonConfiguration filledButtonConfiguration];
    configuration.title = title;
    configuration.image = [UIImage systemImageNamed:symbol];
    configuration.imagePadding = 10;
    configuration.baseForegroundColor = color;
    configuration.baseBackgroundColor = [color colorWithAlphaComponent:0.16];
    configuration.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(14, 16, 14, 16);
    configuration.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey,id> * _Nonnull(NSDictionary<NSAttributedStringKey,id> * _Nonnull attributes) {
        NSMutableDictionary *styled = [attributes mutableCopy];
        styled[NSFontAttributeName] = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
        return styled;
    };
    button.configuration = configuration;
    return button;
}

/// Presents an in-app replacement for the generic system rename alert.
- (void)renameThread {
    NSString *current = self.activeThread.title.length > 0
        ? self.activeThread.title : @"";
    UIView *card = [self presentThreadActionCardWithTitle:@"Rename thread"
                                                   detail:@"Give this conversation a name you will recognize later."];
    UITextField *field = [UITextField new];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.text = current;
    field.placeholder = @"Thread name";
    field.textColor = UIColor.whiteColor;
    field.attributedPlaceholder = [[NSAttributedString alloc] initWithString:field.placeholder
        attributes:@{ NSForegroundColorAttributeName: [UIColor colorWithWhite:0.48 alpha:1] }];
    field.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    field.layer.cornerRadius = 13;
    field.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 13, 1)];
    field.leftViewMode = UITextFieldViewModeAlways;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.returnKeyType = UIReturnKeyDone;
    field.autocapitalizationType = UITextAutocapitalizationTypeSentences;
    [card addSubview:field];
    UIButton *cancel = [self threadActionButtonWithTitle:@"Cancel" symbol:@"xmark"
                                                    color:[UIColor colorWithWhite:0.78 alpha:1]];
    UIButton *save = [self threadActionButtonWithTitle:@"Save name" symbol:@"checkmark"
                                                  color:[UIColor colorWithRed:0.12 green:0.82 blue:1.0 alpha:1]];
    [card addSubview:cancel]; [card addSubview:save];
    __weak typeof(self) ws = self;
    [cancel addAction:[UIAction actionWithHandler:^(__unused UIAction *action) { [ws dismissThreadActionOverlay]; }]
      forControlEvents:UIControlEventTouchUpInside];
    [save addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
        NSString *newTitle = [field.text
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!newTitle.length) return;
        ws.activeThread.title = newTitle;
        [ws updateThreadTitleLabel];
        [ws saveActiveThread];
        [ws dismissThreadActionOverlay];
        EZLogf(EZLogLevelInfo, @"THREAD", @"Renamed to: %@", newTitle);
    }] forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[
        [field.topAnchor constraintEqualToAnchor:card.topAnchor constant:86],
        [field.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [field.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [field.heightAnchor constraintEqualToConstant:52],
        [cancel.topAnchor constraintEqualToAnchor:field.bottomAnchor constant:16],
        [cancel.leadingAnchor constraintEqualToAnchor:field.leadingAnchor],
        [save.topAnchor constraintEqualToAnchor:cancel.topAnchor],
        [save.leadingAnchor constraintEqualToAnchor:cancel.trailingAnchor constant:10],
        [save.trailingAnchor constraintEqualToAnchor:field.trailingAnchor],
        [cancel.widthAnchor constraintEqualToAnchor:save.widthAnchor],
        [cancel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18],
        [save.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18],
    ]];
    [field becomeFirstResponder];
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
        __weak typeof(self) weakSelf = self;
        historyVC.closeHandler = ^{
            [weakSelf closeDrawer];
        };
        historyVC.navigationActionHandler = ^(NSString *action) {
            [weakSelf closeDrawer];
            // Let the drawer begin its exit animation before presenting another
            // controller, which prevents a new sheet from inheriting its frame.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if ([action isEqualToString:@"newChat"]) [weakSelf newChat];
                else if ([action isEqualToString:@"gallery"]) [weakSelf openGallery];
                else if ([action isEqualToString:@"tts"]) [weakSelf openTTS];
                else if ([action isEqualToString:@"music"]) [weakSelf openMusic];
                else if ([action isEqualToString:@"cloning"]) [weakSelf openCloning];
                else if ([action isEqualToString:@"brainRot"]) [weakSelf openBrainRot];
                else if ([action isEqualToString:@"memories"]) [weakSelf openMemories];
                else if ([action isEqualToString:@"coinStore"]) [weakSelf presentCoinStoreForFeature:nil];
                else if ([action isEqualToString:@"settings"]) [weakSelf openSettings];
            });
        };
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
    vc.onGallery     = ^{ [ws presentGalleryForChatAttachments]; };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = nav.sheetPresentationController;
        sheet.detents = @[UISheetPresentationControllerDetent.mediumDetent];
        sheet.prefersGrabberVisible = YES;
    }
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)presentGalleryForChatAttachments {
    NSUInteger currentCount = self.pendingImagePaths.count;
    NSUInteger remaining = currentCount >= kEZMaximumImagesPerChatTurn
        ? 0 : kEZMaximumImagesPerChatTurn - currentCount;
    if (remaining == 0) {
        [self appendToChat:@"[System: This message already has the maximum of 15 attached images.]" ];
        return;
    }

    EZPhotoGalleryViewController *gallery = [EZPhotoGalleryViewController new];
    gallery.chatAttachmentSelectionMode = YES;
    gallery.chatAttachmentSelectionLimit = remaining;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:gallery];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = nav.sheetPresentationController;
        sheet.detents = @[UISheetPresentationControllerDetent.largeDetent];
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
                  [UTType typeWithIdentifier:@"org.openxmlformats.wordprocessingml.document"],
                  [UTType typeWithIdentifier:@"com.microsoft.word.doc"],
                  [UTType typeWithIdentifier:@"org.openxmlformats.spreadsheetml.sheet"],
                  [UTType typeWithIdentifier:@"com.microsoft.excel.xls"],
                  [UTType typeWithIdentifier:@"public.comma-separated-values-text"],
                  [UTType typeWithIdentifier:@"public.json"],
                  [UTType typeWithIdentifier:@"public.xml"],
                  [UTType typeWithIdentifier:@"com.i0stweak3r.ezcompleteui.apple-incident-report"],
                  [UTType typeWithIdentifier:@"com.i0stweak3r.ezcompleteui.typescript"],
                  [UTType typeWithIdentifier:@"com.i0stweak3r.ezcompleteui.objective-c-source"],
                  [UTType typeWithIdentifier:@"com.i0stweak3r.ezcompleteui.objective-c-header"],
                  [UTType typeWithIdentifier:@"com.i0stweak3r.ezcompleteui.objective-cpp-source"],
                  [UTType typeWithIdentifier:@"com.i0stweak3r.ezcompleteui.solidity-source"],
                  [UTType typeWithIdentifier:@"com.i0stweak3r.ezcompleteui.common-source-code"]];
    }
    [self presentFilePickerForMode:mode forceTypes:types];
}

- (void)presentFilePickerForMode:(EZAttachMode)mode forceTypes:(NSArray *)types {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = (mode == EZAttachModeAnalyze);
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
    if (urls.count == 0) return;

    // Retrieve mode from associated object — fall back to analyze
    NSNumber *modeNum = objc_getAssociatedObject(controller, "EZAttachMode");
    EZAttachMode mode = modeNum ? (EZAttachMode)modeNum.integerValue : EZAttachModeAnalyze;

    if (mode == EZAttachModeWhisper) {
        [self transcribeAudio:urls.firstObject];
    } else {
        NSArray<NSURL *> *selection = urls.count > kEZMaximumImagesPerChatTurn
            ? [urls subarrayWithRange:NSMakeRange(0, kEZMaximumImagesPerChatTurn)] : urls;
        if (urls.count > selection.count) {
            [self appendToChat:@"[System: Only the first 15 attachments were selected.]"];
        }
        for (NSURL *fileURL in selection) {
            NSString *ext = fileURL.pathExtension.lowercaseString;
            BOOL isImage = [@[@"jpg",@"jpeg",@"png",@"gif",@"webp",@"heic"] containsObject:ext];
            if (isImage) [self attachImage:fileURL];
            else [self analyzeFile:fileURL];
        }
    }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    EZLog(EZLogLevelInfo, @"FILE", @"Document picker cancelled by user");
}

- (void)presentPhotoLibraryPicker {
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] initWithPhotoLibrary:[PHPhotoLibrary sharedPhotoLibrary]];
    cfg.filter = [PHPickerFilter imagesFilter]; cfg.selectionLimit = kEZMaximumImagesPerChatTurn;
    PHPickerViewController *p = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    p.delegate = self; [self presentViewController:p animated:YES completion:nil];
}
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    for (PHPickerResult *r in results) {
        NSItemProvider *pv = r.itemProvider;
        if ([pv hasItemConformingToTypeIdentifier:UTTypeImage.identifier]) {
            [pv loadFileRepresentationForTypeIdentifier:UTTypeImage.identifier completionHandler:^(NSURL *url, NSError *e) {
                if (!url) { dispatch_async(dispatch_get_main_queue(), ^{ [self appendToChat:@"[Error: Could not load photo]"]; }); return; }
                NSString *fileName = [NSString stringWithFormat:@"%@-%@", NSUUID.UUID.UUIDString, url.lastPathComponent];
                NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
                NSError *ce; [[NSFileManager defaultManager] copyItemAtURL:url toURL:[NSURL fileURLWithPath:tmp] error:&ce];
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (ce) { [self appendToChat:@"[Error: Could not copy photo]"]; return; }
                    [self attachImage:[NSURL fileURLWithPath:tmp]];
                });
            }];
        } else if ([pv canLoadObjectOfClass:[UIImage class]]) {
            [pv loadObjectOfClass:[UIImage class] completionHandler:^(UIImage *img, NSError *e) {
                if (!img) return;
                NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-photo_pick.jpg", NSUUID.UUID.UUIDString]];
                [UIImageJPEGRepresentation(img, 0.92) writeToFile:tmp atomically:YES];
                dispatch_async(dispatch_get_main_queue(), ^{ [self attachImage:[NSURL fileURLWithPath:tmp]]; });
            }];
        }
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
    if (self.pendingImagePaths.count >= kEZMaximumImagesPerChatTurn) {
        [self appendToChat:@"[System: A chat message can include up to 15 images. Send these before attaching more.]"];
        return;
    }
    NSData *rawData = [NSData dataWithContentsOfURL:fileURL];
    if (!rawData) {
        [self appendToChat:@"[Error: Could not read image]"]; return;
    }

    NSString *name = fileURL.lastPathComponent;
    NSString *ext  = fileURL.pathExtension.lowercaseString;
    NSMutableArray<NSString *> *oldPaths = [NSMutableArray array];
    NSMutableArray<NSData *> *sourceData = [NSMutableArray array];
    NSMutableArray<NSString *> *extensions = [NSMutableArray array];
    for (NSString *path in self.pendingImagePaths) {
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (data) {
            [oldPaths addObject:path];
            [sourceData addObject:data];
            [extensions addObject:path.pathExtension ?: @"jpg"];
        }
    }
    [sourceData addObject:rawData];
    [extensions addObject:ext ?: @"jpg"];

    NSError *prepareError = nil;
    NSArray<NSDictionary<NSString *, id> *> *prepared =
        [EZImageAttachmentPreparer preparedImagesFromData:sourceData
                                                extensions:extensions
                                     maximumTotalByteCount:kEZChatImageAttachmentBudget
                                                     error:&prepareError];
    if (!prepared) {
        [self appendToChat:[NSString stringWithFormat:@"[Error: %@]", prepareError.localizedDescription ?: @"Could not prepare image."]];
        return;
    }

    NSUInteger inputBytes = 0, outputBytes = 0;
    BOOL transformedAny = NO;
    for (NSUInteger i = 0; i < prepared.count; i++) {
        inputBytes += sourceData[i].length;
        outputBytes += [prepared[i][@"data"] length];
        transformedAny |= [prepared[i][@"didTransform"] boolValue];
    }

    // Save transformed versions so future sends, restoration, and image edit
    // all point at exactly the bytes placed in the request.
    NSMutableArray<NSString *> *resolvedPaths = [NSMutableArray array];
    for (NSUInteger i = 0; i < prepared.count; i++) {
        NSDictionary *item = prepared[i];
        NSData *imageData = item[@"data"];
        BOOL transformed = [item[@"didTransform"] boolValue];
        NSString *path = nil;
        if (i < oldPaths.count && !transformed) path = oldPaths[i];
        if (i == prepared.count - 1 && !transformed) {
            NSString *galleryDirectory = EZPhotoGalleryDirectory().stringByStandardizingPath;
            NSString *sourcePath = fileURL.path.stringByStandardizingPath;
            if ([sourcePath hasPrefix:[galleryDirectory stringByAppendingString:@"/"]]) path = sourcePath;
        }
        if (!path.length || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            NSString *baseName = (i < oldPaths.count) ? oldPaths[i].lastPathComponent : name;
            NSString *saveName = transformed
                ? [[baseName stringByDeletingPathExtension] stringByAppendingPathExtension:@"jpg"] : baseName;
            path = EZPhotoGallerySave(imageData, saveName);
        }
        if (!path.length) { [self appendToChat:@"[Error: Could not save prepared image]"]; return; }
        [resolvedPaths addObject:path];
    }

    [self.pendingImagePaths removeAllObjects];
    [self.pendingImagePaths addObjectsFromArray:resolvedPaths];
    NSString *thisPath = resolvedPaths.lastObject;
    // A gallery selection is already stored in the permanent image library.
    [self appendAttachmentBubble:thisPath];

    NSMutableArray *att = [self.activeThread.attachmentPaths mutableCopy];
    [att addObject:thisPath];
    self.activeThread.attachmentPaths = [att copy];

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
            @"[System: Image %@ attached. Ask a question, describe an edit, or request a new image.]", name]];
    }
    if (transformedAny) {
        [self appendToChat:[NSString stringWithFormat:
            @"[System: Prepared %lu images for upload: %.1f MB → %.1f MB (kept below the chat request limit).]",
            (unsigned long)prepared.count, inputBytes / 1048576.0, outputBytes / 1048576.0]];
    }

    // Rebuild the one pending vision message from the prepared bytes. This is
    // important: prior attachments may have been recompressed after a later
    // image pushed the collection over the request budget.
    NSMutableArray *blocks = [NSMutableArray array];
    for (NSDictionary *item in prepared) {
        NSString *base64 = [item[@"data"] base64EncodedStringWithOptions:0];
        NSString *dataURL = [NSString stringWithFormat:@"data:%@;base64,%@", item[@"mimeType"], base64];
        [blocks addObject:@{@"type": @"image_url", @"image_url": @{@"url": dataURL}}];
    }
    [blocks addObject:@{@"type": @"text", @"text": @"[image attached — await user question]"}];
    NSDictionary *lastMsg = self.chatContext.lastObject;
    if ([lastMsg[@"_isVisionAttachment"] boolValue]) {
        NSMutableDictionary *mergedMsg = [lastMsg mutableCopy];
        mergedMsg[@"content"] = [blocks copy];
        [self.chatContext removeLastObject];
        [self.chatContext addObject:[mergedMsg copy]];
    } else {
        NSDictionary *visionMsg = @{
            @"role":     @"user",
            @"content":  [blocks copy],
            @"_isVisionAttachment": @YES
        };
        [self.chatContext addObject:visionMsg];
    }

    EZLogf(EZLogLevelInfo, @"ATTACH", @"Image batch ready: count=%lu input=%lu output=%lu",
           (unsigned long)prepared.count, (unsigned long)inputBytes, (unsigned long)outputBytes);
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
    NSError *sessionError = nil;
    if (!EZActivatePlaybackAudioSession(&sessionError)) {
        EZLogf(EZLogLevelError, @"TTS", @"Could not activate Apple TTS audio session: %@", sessionError.localizedDescription);
        return;
    }
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

    // Eleven v4 (the model ez-elevenlabs uses) hard-caps requests
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
        @"model_id":   kElevenLabsTTSModelID,
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
            NSError *sessionError = nil;
            if (!EZActivatePlaybackAudioSession(&sessionError)) {
                EZLogf(EZLogLevelError, @"TTS", @"Could not activate ElevenLabs playback audio session: %@", sessionError.localizedDescription);
                [self appendToChat:@"[TTS Error: Could not activate audio playback]"];
                return;
            }
            NSError *playerErr = nil;
            self.audioPlayer = [[AVAudioPlayer alloc] initWithData:audioData error:&playerErr];
            if (playerErr) {
                EZLogf(EZLogLevelError, @"TTS", @"AVAudioPlayer error: %@",
                       playerErr.localizedDescription);
                [self speakWithApple:text];
                return;
            }
            [self.audioPlayer prepareToPlay];
            if (![self.audioPlayer play]) {
                EZLog(EZLogLevelError, @"TTS", @"ElevenLabs AVAudioPlayer refused to start playback");
                [self appendToChat:@"[TTS Error: Audio playback could not start]"];
                return;
            }

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

- (BOOL)selectedModelRequiresPurchase {
    return [self.selectedModel isEqualToString:@"gpt-6-astra"] ||
           [self.selectedModel isEqualToString:@"gpt-6.1-sol"];
}

- (void)showPurchaseRequiredForSelectedModel {
    NSString *model = self.selectedModel;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Purchase required"
                         message:[NSString stringWithFormat:@"%@ is a paid model. Make a purchase to unlock it, then return to this thread.", model]
                  preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"View Store"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [weakSelf presentCoinStoreForFeature:nil];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

// Denial warning for the one-free-song paywall in chat, then the coin store.
- (void)showSongPurchaseRequiredAlert {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Purchase required"
                         message:@"You've made your free song. Make any purchase to keep creating songs, then ask again."
                  preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"View Store"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [weakSelf presentCoinStoreForFeature:@"AI music"];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Not Now"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)handleSend {
    if (!self.sendButton.enabled || self.messageTextField.text.length == 0) return;
    if (![self selectedModelRequiresPurchase]) {
        [self handleSendAfterModelPurchaseGate];
        return;
    }

    // The picker gate is useful UX, but this second gate is authoritative:
    // it also protects a persisted/default frontier-model choice and any
    // future route that changes selectedModel without opening the picker.
    self.sendButton.enabled = NO;
    __weak typeof(self) weakSelf = self;
    [[EZEntitlementManager shared] refreshSubscriptionStatusWithCompletion:
        ^(__unused BOOL refreshed, __unused NSInteger balance) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self) return;
                if (![EZEntitlementManager shared].hasEverPurchased) {
                    self.sendButton.enabled = YES;
                    [self showPurchaseRequiredForSelectedModel];
                    return;
                }
                self.sendButton.enabled = YES;
                [self handleSendAfterModelPurchaseGate];
            });
        }];
}

- (void)handleSendAfterModelPurchaseGate {
    if (!self.sendButton.enabled) return;
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
        NSString *apiModel = isEdit ? (self.preEditModeModel ?: @"gpt-image-1-mini") : self.selectedModel;

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
    NSString *requestThreadID = [self.activeThread.threadID copy];

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
    // Chat models now choose analysis/generation/editing with an actual tool
    // call. Keep the legacy classifier only for explicit image-model mode.
    if (isImageModel) {
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
                    self.selectedModel = @"gpt-6-luna";
                    [self.modelButton setTitle:@"Model: gpt-6-luna" forState:UIControlStateNormal];
                    [self appendToChat:@"[System: Switched to gpt-6-luna to discuss the attached image]"];
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
    // Give the helper the same current-turn attachment material it needs to
    // safely short-circuit: extracted file text is already in fullPrompt, and
    // prepared images are sent as vision data URLs. These are the same prepared
    // bytes used by the main chat request, not separate originals.
    NSMutableArray<NSString *> *helperImageDataURLs = [NSMutableArray array];
    for (NSString *path in self.pendingImagePaths) {
        NSData *imageData = [NSData dataWithContentsOfFile:path];
        if (!imageData.length) continue;
        NSString *extension = path.pathExtension.lowercaseString;
        NSString *mimeType = [extension isEqualToString:@"png"] ? @"image/png"
            : [extension isEqualToString:@"webp"] ? @"image/webp"
            : [extension isEqualToString:@"gif"] ? @"image/gif" : @"image/jpeg";
        [helperImageDataURLs addObject:[NSString stringWithFormat:@"data:%@;base64,%@",
            mimeType, [imageData base64EncodedStringWithOptions:0]]];
    }

    [self fetchRelevantMemories:fullPrompt completion:^(NSString *memories) {
        analyzePromptForContextWithImages(fullPrompt, memories, helperImageDataURLs,
        jwtToken, self.activeThread.threadID,
        ^(EZContextResult *result) {
            EZLogf(EZLogLevelInfo, @"SEND",
                   @"Tier %ld — conf=%.2f tokens≈%ld reason: %@",
                   (long)result.tier, result.confidence,
                   (long)result.estimatedTokens, result.reason);

            BOOL hasAttachedFileContext = ![fullPrompt isEqualToString:text];

            // The helper has the file text and current images, so those no
            // longer suppress a validated direct answer. Live web search is
            // the one remaining exception: the helper cannot invoke that tool.
            if (result.shortCircuitAnswer.length > 0 && !self.webSearchEnabled) {
                [self completeHelperDirectAnswer:result.shortCircuitAnswer
                                   originalPrompt:text
                                            token:jwtToken
                                         threadID:requestThreadID];
                return;
            }

            // Triage/memory routing enriches the short typed question. When a
            // file was attached, replace that trailing question with the full
            // expanded prompt so the attached file's extracted text reaches
            // ez-chat instead of being silently discarded by this replacement.
            NSString *promptForMainModel = result.finalPrompt;
            if (result.shortCircuitAnswer.length > 0 && self.webSearchEnabled) {
                // Preserve the helper/ranker result as context for the model
                // that will perform the live lookup. Previously it was simply
                // discarded, which caused the model to claim it had no memory.
                promptForMainModel = [NSString stringWithFormat:
                    @"[Validated helper answer — verify or update with web search:]\n%@\n\n[User message]\n%@",
                    result.shortCircuitAnswer, fullPrompt];
                if (self.chatContext.count > 0) [self.chatContext removeLastObject];
                [self.chatContext addObject:@{ @"role": @"user", @"content": promptForMainModel }];
                [self appendToChat:@"[System: Helper answer included for web verification ✓]"];
                [self callChatCompletions];
                return;
            }
            if (hasAttachedFileContext && result.tier >= EZRoutingTierMemory &&
                [result.finalPrompt rangeOfString:@"[Attached file:"].location == NSNotFound) {
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

- (void)startImageGenerationStreamWithToken:(NSString *)token
                                        body:(NSDictionary *)body
                                       event:(EZImageStreamEventBlock)event
                                  completion:(EZImageStreamCompletionBlock)completion {
    [self startImageGenerationStreamWithToken:token body:body event:event completion:completion retryCount:0];
}

- (void)startImageGenerationStreamWithToken:(NSString *)token
                                        body:(NSDictionary *)body
                                       event:(EZImageStreamEventBlock)event
                                  completion:(EZImageStreamCompletionBlock)completion
                                  retryCount:(NSInteger)retryCount {
    NSString *model = [body[@"model"] isKindOfClass:[NSString class]] ? body[@"model"] : @"";
    BOOL supportsImageStreaming = [model hasPrefix:@"gpt-image-"] || [model isEqualToString:@"chatgpt-image-latest"];
    if (!supportsImageStreaming) {
        [self postToEZFunction:@"ez-image" token:token body:body completion:completion];
        return;
    }
    NSMutableDictionary *streamBody = [body mutableCopy];
    streamBody[@"stream"] = @YES;
    if (!streamBody[@"partial_images"]) streamBody[@"partial_images"] = @1;
    EZImageEventStream *client = [[EZImageEventStream alloc] initWithToken:token body:streamBody event:event
        completion:^(NSDictionary *result, NSError *error) {
            self.imageEventStream = nil;
            if ([error.userInfo[@"HTTPStatus"] integerValue] == 401 && retryCount < 1) {
                [[EZAuthManager shared] refreshSessionIfNeeded:^(NSString *newAccessToken, NSError *authError) {
                    if (!authError && newAccessToken.length) {
                        [self startImageGenerationStreamWithToken:newAccessToken body:body event:event
                            completion:completion retryCount:retryCount + 1];
                    } else {
                        completion(nil, authError ?: error);
                    }
                }];
                return;
            }
            completion(result, error);
        }];
    self.imageEventStream = client;
    [client start];
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

    // GPT-4 Turbo cannot use the Responses web-search tool. Keep a search
    // request useful by moving to the next higher compatible chat choice in
    // the picker (GPT-4o), rather than silently dropping search or failing the
    // whole request. This happens before context, token, and billing setup so
    // every downstream decision uses the actual model being sent.
    if (self.webSearchEnabled && [self.selectedModel isEqualToString:@"gpt-4-turbo"]) {
        self.selectedModel = @"gpt-4o";
        [self.modelButton setTitle:@"Model: gpt-4o" forState:UIControlStateNormal];
        [defaults setObject:self.selectedModel forKey:@"selectedModel"];
        [self appendToChat:@"[System: GPT-4 Turbo does not support web search — switched to GPT-4o for this request.]"];
        EZLog(EZLogLevelInfo, @"WEBSEARCH", @"GPT-4 Turbo → GPT-4o for web search");
    }

    // GPT-5.x models and GPT-6 family models use the Responses API.
    // "gpt-5-pro" is a ChatGPT subscription tier name, not an API model string —
    // sending it to the API returns a model-not-found error. Remove it from
    // any model picker. Real API strings: gpt-5, gpt-5-mini, gpt-5.4, gpt-5.4-mini,
    // gpt-5.4-nano, gpt-5.5, gpt-5.6-sol. The gpt-5.x strings are
    // matched by hasPrefix:@"gpt-5"; the GPT-6 family is matched by
    // the explicit equality checks in isGPT5 below.
    BOOL isGPT5 = [self.selectedModel hasPrefix:@"gpt-5"] ||
                  [self.selectedModel isEqualToString:@"gpt-6-astra"] ||
                  [self.selectedModel isEqualToString:@"gpt-6.1-sol"] ||
                  [self.selectedModel isEqualToString:@"gpt-6.1-terra"] ||
                  [self.selectedModel isEqualToString:@"gpt-6-luna"];
    // Web search works on gpt-5.x (via Responses API), gpt-4.1.x, and listed gpt-4o models.
    // Prefix checks cover all sub-variants without needing to enumerate each.
    BOOL modelSupportsWebSearch = isGPT5
        || [self.selectedModel hasPrefix:@"gpt-4.1"]
        || [self.selectedModel hasPrefix:@"o3"]
        || [self.selectedModel hasPrefix:@"o4"]
        || [self.selectedModel isEqualToString:@"gpt-4o"]
        || [self.selectedModel isEqualToString:@"gpt-4o-mini"];
    BOOL useWebSearch    = self.webSearchEnabled && modelSupportsWebSearch;
    // gpt-4.1 family uses the Responses API natively.
    BOOL isGPT41       = [self.selectedModel hasPrefix:@"gpt-4.1"];
    // Web search must not flip the payload shape by itself: ez-chat serves
    // gpt-4o / gpt-4o-mini through Chat Completions even with search on, and
    // Responses-shaped blocks (input_image / input_text) are rejected there.
    BOOL useResponsesAPI = isGPT5 || isGPT41 || [self.selectedModel hasPrefix:@"o"];

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
    if ([self.selectedModel isEqualToString:@"gpt-6.1-sol"] ||
        [self.selectedModel isEqualToString:@"gpt-6.1-terra"]) {
        featureTier = @"chat_standard";
    } else if ([self.selectedModel hasPrefix:@"o1"] || [self.selectedModel hasPrefix:@"o3"]) {
        featureTier = @"chat_premium"; // reasoning models
    } else if (isGPT5) {
        // gpt-5, gpt-5.4, gpt-5.5 = premium; mini/nano variants = mini.
        // gpt-5.6 broke the suffix convention (sol/terra instead of
        // base/-mini/-nano), so it needs an explicit name check rather than
        // hasSuffix — a future gpt-5.7 etc. renamed the same way will need
        // its own line here too.
        static NSSet<NSString *> *cheapGPT56Tiers;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            cheapGPT56Tiers = [NSSet setWithObject:@"gpt-6-luna"];
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
    if (retryCount == 0) {
        // Never borrow a persisted image from a different conversation.
        NSString *candidate = self.pendingImagePaths.lastObject;
        if (!candidate.length) {
            // A follow-up can edit an earlier upload even if the preceding
            // turn merely analyzed it. Prefer the newest image event in this
            // thread, not an older generated image or another thread's cache.
            for (NSDictionary *message in self.chatContext.reverseObjectEnumerator) {
                if ([message[@"role"] isEqualToString:@"_ui_imagegrid"] && ![message[@"isError"] boolValue]) {
                    NSArray *paths = [message[@"imagePaths"] isKindOfClass:[NSArray class]] ? message[@"imagePaths"] : nil;
                    candidate = paths.firstObject;
                    if (candidate.length) break;
                }
                if ([message[@"_isVisionAttachment"] boolValue] && [message[@"content"] isKindOfClass:[NSArray class]]) {
                    candidate = [self ez_recoverImagePathsFromVisionContent:message[@"content"]].lastObject;
                    if (candidate.length) break;
                }
            }
        }
        if (!candidate.length) candidate = self.activeThread.lastImageLocalPath;
        NSString *resolved = candidate.length ? EZAttachmentPath(candidate) : nil;
        self.chatImageSourcePath = resolved.length && [[NSFileManager defaultManager] fileExistsAtPath:resolved]
            ? resolved : nil;
    }
    NSString *capturedImageSource = self.chatImageSourcePath;
    [self.pendingImagePaths removeAllObjects];

    if (isGPT5) { dispatch_async(dispatch_get_main_queue(), ^{ [self showGPT5StatusBanner]; }); }

    // Build ez-chat request body
    NSMutableDictionary *ezBody = [NSMutableDictionary dictionary];
    ezBody[@"model"]            = self.selectedModel;
    ezBody[@"messages"]         = cleanContext;
    ezBody[@"estimated_tokens"] = @(totalEstimate);
    ezBody[@"max_tokens"]        = @(maxCompletionTokens);
    ezBody[@"feature_tier"]     = featureTier;
    NSString *fastMode = [defaults stringForKey:@"fastMode"];
    if ([fastMode isEqualToString:@"flex"] || [fastMode isEqualToString:@"fast"] || [fastMode isEqualToString:@"ultrafast"]) {
        ezBody[@"fast_mode"] = fastMode;
    }
    ezBody[@"image_tools"] = @YES;
    // Lets ez-chat offer the model its create_music tool. The server only ever
    // returns a music_request; it never generates or charges for a song.
    ezBody[@"music_tools"] = @YES;
    ezBody[@"image_source_available"] = @(capturedImageSource.length > 0);
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
    BOOL isHeavyReasoningModel = [self.selectedModel isEqualToString:@"gpt-6.1-sol"] ||
                                  [self.selectedModel isEqualToString:@"gpt-6-astra"];
    // Leave headroom beyond ez-chat's server-side OpenAI deadline. Previously
    // the 90s/180s client deadlines could cancel a request the server was still
    // legitimately processing, producing the misleading local timeout error.
    if ((isGPT5 && useWebSearch) || isHeavyReasoningModel) request.timeoutInterval = 350;
    else if (isGPT5)                                        request.timeoutInterval = 350;
    else                                                     request.timeoutInterval = 250;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    NSError *requestEncodingError = nil;
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:ezBody options:0 error:&requestEncodingError];
    if (!request.HTTPBody.length) {
        [self handleAPIError:requestEncodingError.localizedDescription ?: @"Couldn't encode the chat request."];
        return;
    }

    // Record the actual bytes handed to NSURLSession for debugging. Keep the
    // bearer credential out of the System Log: anyone with that token can act
    // as this user, while the endpoint, headers, and JSON body are sufficient
    // to reproduce request-shape issues.
    NSDictionary *logBody = [self loggableChatRequestBody:ezBody];
    NSData *logBodyData = [NSJSONSerialization dataWithJSONObject:logBody options:0 error:nil];
    NSString *requestBody = [[NSString alloc] initWithData:logBodyData encoding:NSUTF8StringEncoding] ?: @"<non-UTF-8 JSON>";
    EZLogf(EZLogLevelInfo, @"API",
           @"Outgoing request:\nPOST %@\nContent-Type: application/json\nAuthorization: [REDACTED]\nBody: %@",
           request.URL.absoluteString ?: @"<missing URL>", requestBody);

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
            // Daily limit on a capped frontier model — returned by ez-chat
            // for Unlimited Chat subscribers BEFORE anything is spent, only
            // for gpt-6-astra / gpt-6.1-sol. Continue the same send on the
            // unlimited fallback model instead of surfacing an error: switch
            // the selected model (same updates the picker performs), note it
            // once in the transcript, and resend. The isEqualToString checks
            // against the two capped models are the loop guard — a
            // daily_limit_reached response about any other model falls
            // through to normal error handling below.
            if ([errMsg isEqualToString:@"daily_limit_reached"] ||
                [json[@"reason"] isEqualToString:@"daily_limit_reached"]) {
                NSString *cappedModel = [json[@"model"] isKindOfClass:[NSString class]]
                    ? json[@"model"] : self.selectedModel;
                NSString *fallbackModel = [json[@"fallback_model"] isKindOfClass:[NSString class]]
                    ? json[@"fallback_model"] : @"gpt-6.1-terra";
                if (([cappedModel isEqualToString:@"gpt-6-astra"] ||
                     [cappedModel isEqualToString:@"gpt-6.1-sol"]) &&
                    ![fallbackModel isEqualToString:cappedModel]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        self.selectedModel = fallbackModel;
                        [self.modelButton setTitle:[NSString stringWithFormat:@"Model: %@", fallbackModel]
                                          forState:UIControlStateNormal];
                        [[NSUserDefaults standardUserDefaults] setObject:fallbackModel
                                                                  forKey:@"selectedModel"];
                        [self appendToChat:[NSString stringWithFormat:
                            @"[System: %@ daily limit reached — continuing with %@, which is unlimited on your plan.]",
                            cappedModel, fallbackModel]];
                        [self callChatCompletionsWithRetryCount:retryCount + 1];
                    });
                    return;
                }
            }
            // Insufficient coins — show store
            if ([errMsg isEqualToString:@"Insufficient coins"] ||
                [json[@"reason"] isEqualToString:@"Insufficient coins"]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.sendButton.enabled = YES;
                    [self presentCoinStoreForFeature:featureTier];
                });
            } else {
                [self handleAPIError:errMsg];
            }
            return;
        }

        NSDictionary *imageRequest = [json[@"image_request"] isKindOfClass:[NSDictionary class]]
            ? json[@"image_request"] : nil;
        if (imageRequest) {
            dispatch_async(dispatch_get_main_queue(), ^{
                id imageBalance = json[@"balance"];
                if ([imageBalance respondsToSelector:@selector(integerValue)]) {
                    [[EZEntitlementManager shared] applyKnownBalance:[imageBalance integerValue]];
                }
                [self updateCoinBalanceDisplay];
                if (![self.activeThread.threadID isEqualToString:capturedThreadID]) {
                    self.sendButton.enabled = YES;
                    [self appendToChat:@"[System: Image request stopped because the conversation changed. Please resend it in the original chat.]"];
                    return;
                }
                [self performChatImageRequest:imageRequest sourcePath:capturedImageSource];
            });
            return;
        }

        NSDictionary *musicRequest = [json[@"music_request"] isKindOfClass:[NSDictionary class]]
            ? json[@"music_request"] : nil;
        if (musicRequest) {
            NSString *introReply = [json[@"reply"] isKindOfClass:[NSString class]] ? json[@"reply"] : @"";
            dispatch_async(dispatch_get_main_queue(), ^{
                id musicBalance = json[@"balance"];
                if ([musicBalance respondsToSelector:@selector(integerValue)]) {
                    [[EZEntitlementManager shared] applyKnownBalance:[musicBalance integerValue]];
                }
                [self updateCoinBalanceDisplay];
                self.sendButton.enabled = YES;
                if (![self.activeThread.threadID isEqualToString:capturedThreadID]) {
                    [self appendToChat:@"[System: Song request stopped because the conversation changed. Please resend it in the original chat.]"];
                    return;
                }
                // If the model said something before calling the tool, keep it.
                if (introReply.length > 0) {
                    [self.chatContext addObject:@{@"role": @"assistant", @"content": introReply}];
                    [self appendToChat:[NSString stringWithFormat:@"AI: %@", introReply]];
                }
                [self performChatMusicRequest:musicRequest];
            });
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

- (void)performChatImageRequest:(NSDictionary *)imageRequest sourcePath:(NSString *)sourcePath {
    NSString *action = [imageRequest[@"action"] isKindOfClass:[NSString class]] ? imageRequest[@"action"] : nil;
    NSString *prompt = [imageRequest[@"prompt"] isKindOfClass:[NSString class]] ? imageRequest[@"prompt"] : nil;
    BOOL isEdit = [action isEqualToString:@"edit"];
    if ((!isEdit && ![action isEqualToString:@"generate"]) || !prompt.length || prompt.length > 32000) {
        [self handleAPIError:@"The image request was incomplete. Please try again."];
        return;
    }
    if (isEdit && (!sourcePath.length || ![[NSFileManager defaultManager] fileExistsAtPath:sourcePath])) {
        [self handleAPIError:@"Please attach the image you want to edit and send your request again."];
        return;
    }

    // Keep billing/quality enforcement in the same pipeline as direct images.
    // Do not accept a renderer, price or source path supplied by a chat model.
    NSString *imageModel = @"gpt-image-2.5-flare";
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *quality = [defaults stringForKey:@"imgQuality"] ?: @"auto";
    NSString *size = [defaults stringForKey:@"imgSize"] ?: @"1024x1024";
    NSInteger count = [defaults integerForKey:@"imgVariations"];
    if (count < 1 || count > 4) count = 1;
    EZFeature feature = [quality isEqualToString:@"low"] ? EZFeatureImageLow
        : [quality isEqualToString:@"high"] ? EZFeatureImageHigh : EZFeatureImageMedium;
    NSInteger quantity = (NSInteger)ceil(count * ([size isEqualToString:@"1024x1024"] ? 1.0 : 1.25));
    NSString *threadID = self.activeThread.threadID;
    self.sendButton.enabled = NO;
    [self appendToChat:@"[System: Using GPT Image 2.5 Flare for this image request. Your chat model stays selected. Normal image charges apply in addition to chat tokens.]"];
    [[EZEntitlementManager shared] checkEntitlementForFeature:feature quantity:quantity
        prompt:prompt model:imageModel quality:quality size:size isEdit:isEdit
        completion:^(BOOL allowed, NSInteger balance, NSString *reason) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self.activeThread.threadID isEqualToString:threadID]) {
                self.sendButton.enabled = YES;
                return;
            }
            if (!allowed) {
                self.sendButton.enabled = YES;
                if ([reason isEqualToString:@"Insufficient coins"] || [reason isEqualToString:@"No account found"]) {
                    [self presentCoinStoreForFeature:nil];
                } else {
                    [self handleAPIError:reason ?: @"Image generation is not available."];
                }
                return;
            }
            if (isEdit) {
                [self callImageEdit:prompt imagePath:sourcePath model:imageModel preserveChatModel:YES];
            } else {
                [self callGptImage1:prompt model:imageModel];
            }
        });
    }];
}

- (void)callGptImage1:(NSString *)prompt {
    NSString *model = self.selectedModel;
    if ([model isEqualToString:@"gpt-image-1-edit"]) model = self.preEditModeModel ?: @"gpt-image-1-mini";
    [self callGptImage1:prompt model:model];
}

// Explicit model argument lets a chat tool render without changing the picker.
- (void)callGptImage1:(NSString *)prompt model:(NSString *)imageModel {
    self.sendButton.enabled = NO;
    EZLog(EZLogLevelInfo, @"GPTIMAGE", @"Sending generation request via ez-image");

    NSString *token = [EZAuthManager shared].accessToken;
    if (!token) { [self handleAPIError:@"Not signed in"]; return; }

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *imgSize    = [d stringForKey:@"imgSize"]       ?: @"1024x1024";
    NSString *imgQuality = [d stringForKey:@"imgQuality"]    ?: @"auto";
    NSString *imgFormat  = [d stringForKey:@"imgFormat"]     ?: @"png";
    NSString *imgBg      = [d stringForKey:@"imgBackground"] ?: @"auto";
    NSString *imgExtension = [imgFormat isEqualToString:@"jpeg"] ? @"jpg" : imgFormat;
    NSString *imgModel   = imageModel;
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
    [self updateImageGenerationProgress:0.14]; // request body accepted locally
    [self startImageGenerationStreamWithToken:token body:body
        event:^(NSDictionary *event) { [self handleImageGenerationStreamEvent:event]; }
        completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            [self recoverUndeliveredGalleryImagesIfNeeded];
            BOOL isTransportError = EZIsImageTransportError(error);
            if (isTransportError) {
                __weak typeof(self) weakSelf = self;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [weakSelf recoverUndeliveredGalleryImagesIfNeeded];
                });
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [weakSelf recoverUndeliveredGalleryImagesIfNeeded];
                });
            }
            NSString *message = EZFriendlyImageTransportMessage(error);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self hideStatusBanner];
                [self handleAPIError:message];
                if (!isTransportError) [self appendImageGridToChat:@[] prompt:savedPrompt isError:YES errorText:message];
            });
            return;
        }
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
                [self hideStatusBanner];
                [self appendImageGridToChat:@[] prompt:savedPrompt isError:YES errorText:fullMsg];
            });
            return;
        }

        id balanceObj = json[@"balance"];
        if (balanceObj && ![balanceObj isKindOfClass:[NSNull class]])
            [[EZEntitlementManager shared] applyKnownBalance:[balanceObj integerValue]];

        NSArray *images = [json[@"images"] copy];
        if (!images.count) {
            NSString *errMsg = @"No image in response";
            [self handleAPIError:errMsg];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self hideStatusBanner];
                [self appendImageGridToChat:@[] prompt:savedPrompt isError:YES errorText:errMsg];
            });
            return;
        }

        // Download each signed URL and save locally
        [self updateImageGenerationProgress:0.92];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSMutableArray<NSString *> *savedPaths = [NSMutableArray array];
            for (NSUInteger imageIndex = 0; imageIndex < images.count; imageIndex++) {
                NSDictionary *imgObj = images[imageIndex];
                NSString *signedURL = imgObj[@"url"];
                if (!signedURL.length) continue;
                NSData *imgData = [NSData dataWithContentsOfURL:[NSURL URLWithString:signedURL]];
                if (!imgData) continue;
                NSString *fname = [NSString stringWithFormat:@"gptimage_%lu.%@",
                                   (unsigned long)savedPaths.count + 1, imgExtension];
                NSString *path = EZPhotoGallerySave(imgData, fname);
                if (path) [savedPaths addObject:path];
                CGFloat downloadProgress = 0.92 + (0.06 * ((CGFloat)(imageIndex + 1) / (CGFloat)images.count));
                dispatch_async(dispatch_get_main_queue(), ^{ [self updateImageGenerationProgress:downloadProgress]; });
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
                [self updateImageGenerationProgress:1.0];
                [self hideStatusBanner];
                self.sendButton.enabled = YES;
            });
        });
    }];
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Image Edit (gpt-image-1/1.5/mini/2/2.5-flare/2.5-sunburst)
// ─────────────────────────────────────────────────────────────────────────────

- (void)callImageEdit:(NSString *)prompt imagePath:(NSString *)imagePath {
    [self callImageEdit:prompt imagePath:imagePath model:self.preEditModeModel ?: @"gpt-image-1-mini"
     preserveChatModel:NO];
}

- (void)callImageEdit:(NSString *)prompt imagePath:(NSString *)imagePath
               model:(NSString *)imageModel preserveChatModel:(BOOL)preserveChatModel {
    self.sendButton.enabled = NO;
    if (!imagePath) {
        self.sendButton.enabled = YES;
        [self appendToChat:@"[Error: No image attached for editing]"]; return;
    }
    [self appendToChat:[NSString stringWithFormat:
        @"[System: Editing image with %@...]", imageModel]];
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
        @"model":         imageModel,
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
    [self updateImageGenerationProgress:0.14]; // edit request accepted locally
    [self startImageGenerationStreamWithToken:token body:body
        event:^(NSDictionary *event) { [self handleImageGenerationStreamEvent:event]; }
        completion:^(NSDictionary *json, NSError *error) {
        if (error) {
            [self recoverUndeliveredGalleryImagesIfNeeded];
            BOOL isTransportError = EZIsImageTransportError(error);
            if (isTransportError) {
                __weak typeof(self) weakSelf = self;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [weakSelf recoverUndeliveredGalleryImagesIfNeeded];
                });
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [weakSelf recoverUndeliveredGalleryImagesIfNeeded];
                });
            }
            NSString *message = EZFriendlyImageTransportMessage(error);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self hideStatusBanner];
                [self handleAPIError:message];
                if (!isTransportError) [self appendImageGridToChat:@[] prompt:prompt isError:YES errorText:message];
            });
            return;
        }
        id errObj = json[@"error"];
        if (errObj && ![errObj isKindOfClass:[NSNull class]]) {
            NSString *errMsg = [errObj isKindOfClass:[NSString class]] ? errObj : @"Image edit error";
            // See the generation error path's comment above (callGptImage1)
            // for why this matters.
            NSString *reason = json[@"reason"];
            NSString *fullMsg = reason.length ? [NSString stringWithFormat:@"%@ %@", errMsg, reason] : errMsg;
            [self handleAPIError:fullMsg];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self hideStatusBanner];
                [self appendImageGridToChat:@[] prompt:prompt isError:YES errorText:fullMsg];
            });
            return;
        }

        id balanceObj = json[@"balance"];
        if (balanceObj && ![balanceObj isKindOfClass:[NSNull class]])
            [[EZEntitlementManager shared] applyKnownBalance:[balanceObj integerValue]];

        NSArray *images = [json[@"images"] copy];
        if (!images.count) {
            NSString *errMsg = @"No image in edit response";
            [self handleAPIError:errMsg];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self hideStatusBanner];
                [self appendImageGridToChat:@[] prompt:prompt isError:YES errorText:errMsg];
            });
            return;
        }

        [self updateImageGenerationProgress:0.92];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSMutableArray<NSString *> *savedPaths = [NSMutableArray array];
            for (NSUInteger imageIndex = 0; imageIndex < images.count; imageIndex++) {
                NSDictionary *imgObj = images[imageIndex];
                NSString *signedURL = imgObj[@"url"];
                if (!signedURL.length) continue;
                NSData *imgData = [NSData dataWithContentsOfURL:[NSURL URLWithString:signedURL]];
                if (!imgData) continue;
                NSString *fname = [NSString stringWithFormat:@"edit_%lu.%@",
                                   (unsigned long)savedPaths.count + 1, editExtension];
                NSString *path = EZPhotoGallerySave(imgData, fname);
                if (path) [savedPaths addObject:path];
                CGFloat downloadProgress = 0.92 + (0.06 * ((CGFloat)(imageIndex + 1) / (CGFloat)images.count));
                dispatch_async(dispatch_get_main_queue(), ^{ [self updateImageGenerationProgress:downloadProgress]; });
            }

            NSString *firstPath = savedPaths.firstObject;
            dispatch_async(dispatch_get_main_queue(), ^{
                self.lastImagePrompt = prompt;
                if (!preserveChatModel) {
                    self.selectedModel = @"gpt-image-1-edit";
                    [self.modelButton setTitle:[NSString stringWithFormat:@"Model: %@ (edit mode)", imageModel]
                                      forState:UIControlStateNormal];
                    [self appendToChat:@"[System: Edit complete — still in edit mode. Attach a new image or type another edit prompt.]"];
                }
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
                [self updateImageGenerationProgress:1.0];
                [self hideStatusBanner];
                self.sendButton.enabled = YES;
            });
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

    [self postToEZFunction:@"whisper-1" token:token body:body
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
            @"gpt-image-1-mini",
            @"gpt-image-2", @"gpt-image-2.5-flare", @"gpt-image-2.5-sunburst", nil];
    });
    if ([editCapableModels containsObject:self.selectedModel]) {
        self.preEditModeModel = self.selectedModel;
    } else if (self.preEditModeModel.length == 0) {
        self.preEditModeModel = @"gpt-image-2.5-sunburst"; // recommended default for image editing
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

    NSString *model = self.preEditModeModel.length ? self.preEditModeModel : @"gpt-image-2.5-sunburst";
    self.selectedModel = model;
    [self.modelButton setTitle:[NSString stringWithFormat:@"Model: %@", model]
                      forState:UIControlStateNormal];
}

- (BOOL)modelSupportsVision:(NSString *)model {
    // gpt-5.x and gpt-4.1.x all support vision via the Responses API.
    // Prefix checks cover all variants (gpt-5, gpt-5.1-mini, gpt-4.1, gpt-4.1-mini, etc.)
    if ([model hasPrefix:@"gpt-5"] || [model isEqualToString:@"gpt-6-astra"] ||
        [model isEqualToString:@"gpt-6.1-sol"] || [model isEqualToString:@"gpt-6.1-terra"] ||
        [model isEqualToString:@"gpt-6-luna"]) return YES;
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
        NSString *name = [NSString stringWithFormat:@"restored-image.%@", ext];
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

        // Preserve the result as text context (not the UI dictionary) so the
        // chat model knows whether rendering succeeded before a follow-up.
        if ([msg[@"_uiOnly"] boolValue]) {
            if ([msg[@"role"] isEqualToString:@"_ui_imagegrid"]) {
                BOOL failed = [msg[@"isError"] boolValue];
                NSString *summary = [NSString stringWithFormat:@"Image rendering %@. Request: %@%@",
                    failed ? @"failed" : @"completed; the image is displayed in chat and saved in the gallery",
                    msg[@"prompt"] ?: @"", failed ? [NSString stringWithFormat:@". Error: %@", msg[@"errorText"] ?: @"Unknown error"] : @""];
                [result addObject:@{@"role": @"assistant", @"content": summary}];
            } else if ([msg[@"role"] isEqualToString:@"_ui_music"]) {
                [result addObject:@{@"role": @"assistant",
                                    @"content": [self ez_chatMusicSummaryForEvent:msg]}];
            }
            continue;
        }

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

/// Produces a diagnostic copy of the request body. It keeps the exact request
/// shape and all ordinary text, while collapsing embedded image bytes so one
/// attachment cannot fill the System Log with megabytes of Base64.
- (NSDictionary *)loggableChatRequestBody:(NSDictionary *)body {
    NSMutableDictionary *logBody = [body mutableCopy] ?: [NSMutableDictionary dictionary];
    NSArray *messages = [body[@"messages"] isKindOfClass:NSArray.class] ? body[@"messages"] : nil;
    if (!messages) return [logBody copy];

    NSMutableArray *logMessages = [NSMutableArray arrayWithCapacity:messages.count];
    for (NSDictionary *message in messages) {
        if (![message isKindOfClass:NSDictionary.class]) { [logMessages addObject:message ?: @{}]; continue; }
        NSMutableDictionary *logMessage = [message mutableCopy];
        NSArray *content = [message[@"content"] isKindOfClass:NSArray.class] ? message[@"content"] : nil;
        if (!content) { [logMessages addObject:logMessage]; continue; }

        NSMutableArray *logContent = [NSMutableArray arrayWithCapacity:content.count];
        for (NSDictionary *block in content) {
            if (![block isKindOfClass:NSDictionary.class]) { [logContent addObject:block ?: @{}]; continue; }
            NSMutableDictionary *logBlock = [block mutableCopy];
            NSString *type = [block[@"type"] isKindOfClass:NSString.class] ? block[@"type"] : @"";
            if ([type isEqualToString:@"image_url"]) {
                id imageURL = block[@"image_url"];
                NSString *url = [imageURL isKindOfClass:NSDictionary.class] ? imageURL[@"url"]
                    : [imageURL isKindOfClass:NSString.class] ? imageURL : nil;
                if ([url hasPrefix:@"data:"]) {
                    NSRange marker = [url rangeOfString:@";base64,"];
                    NSString *mime = marker.location == NSNotFound ? @"image" : [url substringWithRange:NSMakeRange(5, marker.location - 5)];
                    NSUInteger chars = marker.location == NSNotFound ? url.length : url.length - NSMaxRange(marker);
                    logBlock[@"image_url"] = @{ @"url": [NSString stringWithFormat:@"<%@ Base64 omitted: %lu chars>", mime, (unsigned long)chars] };
                }
            } else if ([type isEqualToString:@"input_image"] && [block[@"data"] isKindOfClass:NSString.class]) {
                NSString *data = block[@"data"];
                NSString *mime = [block[@"media_type"] isKindOfClass:NSString.class] ? block[@"media_type"] : @"image";
                logBlock[@"data"] = [NSString stringWithFormat:@"<%@ Base64 omitted: %lu chars>", mime, (unsigned long)data.length];
            }
            [logContent addObject:logBlock];
        }
        logMessage[@"content"] = logContent;
        [logMessages addObject:logMessage];
    }
    logBody[@"messages"] = logMessages;
    return [logBody copy];
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

/// Finds a generated file saved under either naming scheme. Older files have
/// a UUID prefix; new files retain their requested name and use `-2`, `-3`,
/// etc. only when a name collision occurs. This keeps restore/re-rendering of
/// a saved thread from creating a duplicate code attachment.
- (BOOL)ez_storedFileName:(NSString *)storedName matchesRequestedName:(NSString *)requestedName {
    if (storedName.length == 0 || requestedName.length == 0) return NO;
    if ([storedName isEqualToString:requestedName] ||
        [storedName hasSuffix:[@"_" stringByAppendingString:requestedName]]) return YES;

    NSString *storedExtension = storedName.pathExtension.lowercaseString;
    NSString *requestedExtension = requestedName.pathExtension.lowercaseString;
    if (![storedExtension isEqualToString:requestedExtension]) return NO;

    NSString *storedStem = storedName.stringByDeletingPathExtension;
    NSString *requestedStem = requestedName.stringByDeletingPathExtension;
    if ([storedStem isEqualToString:requestedStem]) return YES;
    NSString *prefix = [requestedStem stringByAppendingString:@"-"];
    if (![storedStem hasPrefix:prefix]) return NO;
    NSString *numericSuffix = [storedStem substringFromIndex:prefix.length];
    return numericSuffix.length > 0 &&
        [[NSCharacterSet decimalDigitCharacterSet] isSupersetOfSet:
            [NSCharacterSet characterSetWithCharactersInString:numericSuffix]];
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
                if ([self ez_storedFileName:existingPath.lastPathComponent matchesRequestedName:fileName]) {
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

// MARK: - Thread selection and export

static NSInteger const kEZThreadSelectionDotTag = 9411;

static NSString *EZThreadExportTimestampNow(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"MMM d, yyyy h:mm a";
    });
    return [formatter stringFromDate:[NSDate date]];
}

- (void)installThreadSelectionBar {
    self.selectedThreadMessageIndexes = [NSMutableIndexSet indexSet];
    UIView *bar = [UIView new];
    bar.hidden = YES;
    bar.backgroundColor = [UIColor colorWithRed:0.08 green:0.22 blue:0.30 alpha:0.98];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.inputContainer addSubview:bar];
    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:self.inputContainer.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:self.inputContainer.trailingAnchor],
        [bar.topAnchor constraintEqualToAnchor:self.inputContainer.topAnchor],
        [bar.bottomAnchor constraintEqualToAnchor:self.inputContainer.bottomAnchor],
    ]];
    self.threadSelectionBar = bar;

    UILabel *count = [UILabel new];
    count.textColor = UIColor.whiteColor;
    count.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightBold];
    count.textAlignment = NSTextAlignmentCenter;
    count.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:count];
    self.threadSelectionCountLabel = count;

    NSArray<NSString *> *titles = @[ @"All", @"Delete", @"Translate", @"Export", @"Done" ];
    NSArray<NSString *> *symbols = @[ @"checkmark.circle", @"trash", @"character.bubble", @"doc.badge.arrow.up", @"xmark.circle" ];
    NSArray<UIColor *> *colors = @[ UIColor.systemTealColor, UIColor.systemRedColor,
                                    UIColor.systemPurpleColor, UIColor.systemOrangeColor,
                                    UIColor.whiteColor ];
    NSArray<NSString *> *selectors = @[ NSStringFromSelector(@selector(selectAllThreadItems)),
                                        NSStringFromSelector(@selector(deleteSelectedThreadItems)),
                                        NSStringFromSelector(@selector(translateSelectedThreadItems)),
                                        NSStringFromSelector(@selector(exportSelectedThreadItems)),
                                        NSStringFromSelector(@selector(toggleThreadSelection)) ];
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.spacing = 2;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    for (NSUInteger i = 0; i < titles.count; i++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        UIColor *color = colors[i];
        UIButtonConfiguration *config = [UIButtonConfiguration filledButtonConfiguration];
        config.title = titles[i];
        config.image = [UIImage systemImageNamed:symbols[i]];
        config.imagePlacement = NSDirectionalRectEdgeTop;
        config.imagePadding = 5;
        config.baseForegroundColor = color;
        config.baseBackgroundColor = [color colorWithAlphaComponent:(i == 5 ? 0.22 : 0.16)];
        config.cornerStyle = UIButtonConfigurationCornerStyleMedium;
        config.contentInsets = NSDirectionalEdgeInsetsMake(7, 3, 7, 3);
        config.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey,id> * _Nonnull(NSDictionary<NSAttributedStringKey,id> * _Nonnull attributes) {
            NSMutableDictionary *result = [attributes mutableCopy];
            result[NSFontAttributeName] = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
            return result;
        };
        button.configuration = config;
        [button addTarget:self action:NSSelectorFromString(selectors[i]) forControlEvents:UIControlEventTouchUpInside];
        [stack addArrangedSubview:button];
        [buttons addObject:button];
    }
    self.threadSelectionActionButtons = buttons;
    [bar addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [count.topAnchor constraintEqualToAnchor:bar.topAnchor constant:5],
        [count.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:8],
        [count.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-8],
        [stack.topAnchor constraintEqualToAnchor:count.bottomAnchor constant:1],
        [stack.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:4],
        [stack.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-4],
        [stack.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor constant:-4],
    ]];
}

- (BOOL)isThreadExportableMessage:(NSDictionary *)message {
    NSString *role = message[@"role"] ?: @"";
    if ([role isEqualToString:@"system"]) {
        // System status lines and internal instructions are app plumbing, not
        // part of a user's public thread.  This leaves a deliberate escape
        // hatch for a future/user-created custom instruction row.
        return [message[@"isUserAuthoredSystemMessage"] boolValue] ||
               [message[@"isCustomInstruction"] boolValue];
    }
    return [@[ @"user", @"assistant", @"code", @"attachment", @"imagegrid" ] containsObject:role];
}

- (void)toggleThreadSelection {
    self.threadSelectionActive = !self.threadSelectionActive;
    if (!self.threadSelectionActive) [self.selectedThreadMessageIndexes removeAllIndexes];
    self.threadSelectionBar.hidden = !self.threadSelectionActive;
    [self.threadSelectionButton setTitle:self.threadSelectionActive ? @"DONE" : @"SEL"
                         forState:UIControlStateNormal];
    [self updateThreadSelectionUI];
}

- (void)updateThreadSelectionUI {
    NSUInteger selectedCount = self.selectedThreadMessageIndexes.count;
    self.threadSelectionCountLabel.text = selectedCount
        ? [NSString stringWithFormat:@"%lu selected", (unsigned long)selectedCount]
        : @"Choose parts of this thread";
    for (NSUInteger i = 0; i < self.threadSelectionActionButtons.count; i++) {
        // All and Done remain useful before any item is selected.
        self.threadSelectionActionButtons[i].enabled = (i == 0 || i == 4 || selectedCount > 0);
        self.threadSelectionActionButtons[i].alpha = self.threadSelectionActionButtons[i].enabled ? 1.0 : 0.38;
    }
    [self.chatTableView reloadData];
}

- (void)selectAllThreadItems {
    [self.selectedThreadMessageIndexes removeAllIndexes];
    [self.displayMessages enumerateObjectsUsingBlock:^(NSDictionary *message, NSUInteger index, BOOL *stop) {
        if ([self isThreadExportableMessage:message])
            [self.selectedThreadMessageIndexes addIndex:index];
    }];
    [self updateThreadSelectionUI];
}

- (void)threadSelectionDotTapped:(UIButton *)sender {
    UIView *view = sender;
    while (view && ![view isKindOfClass:[UITableViewCell class]]) view = view.superview;
    NSIndexPath *path = view ? [self.chatTableView indexPathForCell:(UITableViewCell *)view] : nil;
    if (!path) return;
    if ([self.selectedThreadMessageIndexes containsIndex:(NSUInteger)path.row])
        [self.selectedThreadMessageIndexes removeIndex:(NSUInteger)path.row];
    else
        [self.selectedThreadMessageIndexes addIndex:(NSUInteger)path.row];
    [self updateThreadSelectionUI];
}

- (void)configureThreadSelectionDotForCell:(UITableViewCell *)cell indexPath:(NSIndexPath *)indexPath {
    UIButton *dot = [cell.contentView viewWithTag:kEZThreadSelectionDotTag];
    if (!dot) {
        dot = [UIButton buttonWithType:UIButtonTypeCustom];
        dot.tag = kEZThreadSelectionDotTag;
        dot.frame = CGRectMake(8, 8, 28, 28);
        dot.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
        dot.layer.cornerRadius = 14;
        dot.layer.borderWidth = 2;
        [dot addTarget:self action:@selector(threadSelectionDotTapped:) forControlEvents:UIControlEventTouchUpInside];
        [cell.contentView addSubview:dot];
    }
    BOOL selected = [self.selectedThreadMessageIndexes containsIndex:(NSUInteger)indexPath.row];
    [dot setImage:selected ? [UIImage systemImageNamed:@"checkmark"] : nil forState:UIControlStateNormal];
    dot.tintColor = UIColor.whiteColor;
    dot.backgroundColor = selected ? self.view.tintColor : [UIColor.systemBackgroundColor colorWithAlphaComponent:0.92];
    dot.layer.borderColor = (selected ? self.view.tintColor : UIColor.systemGrayColor).CGColor;
    dot.hidden = !self.threadSelectionActive;
    [cell.contentView bringSubviewToFront:dot];
}

- (NSArray<NSDictionary *> *)selectedThreadMessages {
    NSMutableArray *items = [NSMutableArray array];
    [self.selectedThreadMessageIndexes enumerateIndexesUsingBlock:^(NSUInteger index, BOOL *stop) {
        if (index < self.displayMessages.count) [items addObject:self.displayMessages[index]];
    }];
    return items;
}

- (NSString *)selectedThreadText {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSDictionary *message in [self selectedThreadMessages]) {
        NSString *role = message[@"role"] ?: @"";
        NSString *when = message[@"timestamp"] ?: @"time unavailable";
        if ([role isEqualToString:@"code"]) {
            [parts addObject:[NSString stringWithFormat:@"CODE (%@) — Added %@:\n%@", message[@"language"] ?: @"code", when, message[@"text"] ?: @""]];
        } else if ([role isEqualToString:@"attachment"]) {
            [parts addObject:[NSString stringWithFormat:@"IMAGE — Added %@: %@", when, [message[@"imagePath"] lastPathComponent] ?: @"attachment"]];
        } else if ([role isEqualToString:@"imagegrid"]) {
            [parts addObject:[NSString stringWithFormat:@"GENERATED IMAGES — Added %@ — %@", when, message[@"prompt"] ?: @""]];
        } else {
            NSString *speaker = [role isEqualToString:@"user"] ? @"YOU" :
                ([role isEqualToString:@"system"] ? @"SYSTEM" : @"ASSISTANT");
            [parts addObject:[NSString stringWithFormat:@"%@ — Added %@:\n%@", speaker, when, message[@"text"] ?: @""]];
        }
    }
    return [parts componentsJoinedByString:@"\n\n"];
}

- (NSArray<NSURL *> *)selectedThreadImageURLs {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (NSDictionary *message in [self selectedThreadMessages]) {
        NSString *role = message[@"role"];
        NSArray *paths = [role isEqualToString:@"imagegrid"] ? message[@"imagePaths"] :
            [role isEqualToString:@"attachment"] ? @[message[@"imagePath"] ?: @""] : @[];
        for (NSString *path in paths) {
            NSString *resolved = EZAttachmentPath(path) ?: path;
            if ([[NSFileManager defaultManager] fileExistsAtPath:resolved])
                [urls addObject:[NSURL fileURLWithPath:resolved]];
        }
    }
    return urls;
}

- (void)shareSelectedThreadItems {
    NSMutableArray *items = [NSMutableArray arrayWithObject:[self selectedThreadText] ?: @""];
    [items addObjectsFromArray:[self selectedThreadImageURLs]];
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        share.popoverPresentationController.sourceView = self.threadSelectionBar;
        share.popoverPresentationController.sourceRect = self.threadSelectionBar.bounds;
    }
    [self presentViewController:share animated:YES completion:nil];
}

- (void)translateSelectedThreadItems {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Translate selection"
        message:@"This sends the selected text to your active chat model." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = @"Language (for example, Spanish)"; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Translate" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *language = alert.textFields.firstObject.text.length ? alert.textFields.firstObject.text : @"English";
        NSString *text = [self selectedThreadText];
        [self toggleThreadSelection];
        [self setInputText:[NSString stringWithFormat:@"Translate the following selected thread excerpts into %@. Preserve code blocks exactly and do not add commentary:\n\n%@", language, text]];
        [self handleSend];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)deleteSelectedThreadItems {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Delete selected parts?"
        message:@"This removes the selected messages and media from this thread view." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [self.selectedThreadMessageIndexes enumerateIndexesWithOptions:NSEnumerationReverse usingBlock:^(NSUInteger index, BOOL *stop) {
            if (index < self.displayMessages.count) [self.displayMessages removeObjectAtIndex:index];
        }];
        [self persistImageGridCells];
        [self toggleThreadSelection];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSString *)threadExportFilenameFromName:(NSString *)name extension:(NSString *)extension {
    NSString *base = [[name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
        stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    if (!base.length) base = self.activeThread.title.length ? self.activeThread.title : @"EZCompleteUI Thread";
    return [[base stringByReplacingOccurrencesOfString:@"." withString:@"-"] stringByAppendingPathExtension:extension];
}

- (NSData *)threadPDFDataWithSelectedMessages:(NSArray<NSDictionary *> *)messages title:(NSString *)title {
    CGRect page = CGRectMake(0, 0, 612, 792);
    UIGraphicsPDFRenderer *renderer = [[UIGraphicsPDFRenderer alloc] initWithBounds:page];
    return [renderer PDFDataWithActions:^(UIGraphicsPDFRendererContext *context) {
        NSDictionary *titleAttrs = @{ NSFontAttributeName: [UIFont boldSystemFontOfSize:18], NSForegroundColorAttributeName: UIColor.blackColor };
        NSDictionary *metaAttrs = @{ NSFontAttributeName: [UIFont systemFontOfSize:9 weight:UIFontWeightSemibold], NSForegroundColorAttributeName: UIColor.darkGrayColor };
        NSDictionary *bodyAttrs = @{ NSFontAttributeName: [UIFont systemFontOfSize:11], NSForegroundColorAttributeName: UIColor.blackColor };
        __block CGFloat y = 0;
        __block NSInteger pageNumber = 0;
        void (^startPage)(void) = ^{
            [context beginPage]; pageNumber++;
            [[UIColor colorWithWhite:0.96 alpha:1] setFill];
            UIRectFill(CGRectMake(0, 0, 612, 792));
            [title drawInRect:CGRectMake(36, 28, 450, 24) withAttributes:titleAttrs];
            [[NSString stringWithFormat:@"Thread export  •  %ld", (long)pageNumber]
                drawInRect:CGRectMake(470, 34, 106, 16) withAttributes:metaAttrs];
            y = 68;
        };
        void (^needSpace)(CGFloat) = ^(CGFloat height) {
            if (y + height > 752) startPage();
        };
        startPage();
        for (NSDictionary *message in messages) {
            NSString *role = message[@"role"] ?: @"assistant";
            BOOL attachment = [role isEqualToString:@"attachment"];
            BOOL grid = [role isEqualToString:@"imagegrid"];
            BOOL code = [role isEqualToString:@"code"];
            BOOL userSide = [role isEqualToString:@"user"] || attachment;
            NSString *speaker = [role isEqualToString:@"user"] ? @"You" : code ? @"Code" : attachment ? @"Image attached" : grid ? @"Generated images" : @"Assistant";
            NSString *when = message[@"timestamp"] ?: @"time unavailable";
            NSString *text = grid ? (message[@"prompt"] ?: @"") : (message[@"text"] ?: @"");
            NSArray *paths = grid ? message[@"imagePaths"] : attachment ? @[message[@"imagePath"] ?: @""] : @[];

            if (grid) {
                NSUInteger imageCount = paths.count;
                CGFloat gridHeight = 40 + (text.length ? 32 : 0) + ceil(MAX(imageCount, 1) / 2.0) * 148 + 10;
                needSpace(gridHeight + 10);
                CGRect card = CGRectMake(66, y, 480, gridHeight);
                [[UIColor whiteColor] setFill]; UIBezierPath *cardPath = [UIBezierPath bezierPathWithRoundedRect:card cornerRadius:14]; [cardPath fill];
                [[NSString stringWithFormat:@"%@  •  Added %@", speaker, when] drawInRect:CGRectMake(82, y + 10, 448, 15) withAttributes:metaAttrs];
                CGFloat gridY = y + 31;
                if (text.length) { [text drawInRect:CGRectMake(82, gridY, 448, 28) withAttributes:bodyAttrs]; gridY += 35; }
                for (NSUInteger index = 0; index < paths.count; index++) {
                    NSString *resolved = EZAttachmentPath(paths[index]) ?: paths[index];
                    UIImage *image = [UIImage imageWithContentsOfFile:resolved]; if (!image) continue;
                    CGFloat x = 82 + (index % 2) * 222, iy = gridY + (index / 2) * 148;
                    CGRect slot = CGRectMake(x, iy, 212, 138);
                    [[UIColor colorWithWhite:0.91 alpha:1] setFill]; [[UIBezierPath bezierPathWithRoundedRect:slot cornerRadius:9] fill];
                    CGFloat scale = MIN(slot.size.width / image.size.width, slot.size.height / image.size.height);
                    CGSize size = CGSizeMake(image.size.width * scale, image.size.height * scale);
                    [image drawInRect:CGRectMake(CGRectGetMidX(slot) - size.width / 2, CGRectGetMidY(slot) - size.height / 2, size.width, size.height)];
                }
                y += gridHeight + 10;
                continue;
            }

            if (attachment) {
                NSString *path = paths.firstObject;
                UIImage *image = [UIImage imageWithContentsOfFile:EZAttachmentPath(path) ?: path];
                CGFloat imageHeight = image ? MIN(155, MAX(84, image.size.height * MIN(190 / image.size.width, 155 / image.size.height))) : 84;
                CGFloat cardHeight = imageHeight + 35;
                needSpace(cardHeight + 10);
                CGRect card = CGRectMake(346, y, 230, cardHeight);
                [[UIColor colorWithRed:0.84 green:0.93 blue:1 alpha:1] setFill]; [[UIBezierPath bezierPathWithRoundedRect:card cornerRadius:14] fill];
                [[NSString stringWithFormat:@"%@  •  %@", speaker, when] drawInRect:CGRectMake(358, y + 9, 205, 14) withAttributes:metaAttrs];
                if (image) {
                    CGRect slot = CGRectMake(358, y + 27, 206, imageHeight);
                    CGFloat scale = MIN(slot.size.width / image.size.width, slot.size.height / image.size.height);
                    CGSize size = CGSizeMake(image.size.width * scale, image.size.height * scale);
                    [image drawInRect:CGRectMake(CGRectGetMidX(slot) - size.width / 2, CGRectGetMidY(slot) - size.height / 2, size.width, size.height)];
                }
                y += cardHeight + 10;
                continue;
            }

            if (code) {
                // Code is intentionally not clipped to the visible height of
                // its chat cell.  Paginate it in-place, then continue with the
                // next thread row so exports remain a complete transcript.
                NSDictionary *codeAttrs = @{ NSFontAttributeName: [UIFont monospacedSystemFontOfSize:8.5 weight:UIFontWeightRegular], NSForegroundColorAttributeName: UIColor.blackColor };
                NSMutableArray<NSString *> *lines = [NSMutableArray array];
                for (NSString *rawLine in [text componentsSeparatedByString:@"\n"]) {
                    if (rawLine.length == 0) { [lines addObject:@" "]; continue; }
                    for (NSUInteger offset = 0; offset < rawLine.length; offset += 78) {
                        NSUInteger length = MIN((NSUInteger)78, rawLine.length - offset);
                        [lines addObject:[rawLine substringWithRange:NSMakeRange(offset, length)]];
                    }
                }
                if (lines.count == 0) [lines addObject:@" "];
                NSUInteger offset = 0;
                while (offset < lines.count) {
                    if (y + 52 > 752) startPage();
                    NSUInteger linesThatFit = MAX((NSUInteger)1, (NSUInteger)floor((752 - y - 34) / 11));
                    NSUInteger count = MIN(linesThatFit, lines.count - offset);
                    CGFloat cardHeight = 30 + count * 11;
                    CGRect card = CGRectMake(52, y, 508, cardHeight);
                    [[UIColor colorWithWhite:0.88 alpha:1] setFill];
                    [[UIBezierPath bezierPathWithRoundedRect:card cornerRadius:10] fill];
                    NSString *heading = offset == 0 ?
                        [NSString stringWithFormat:@"Code  •  Added %@", when] : @"Code  •  continued";
                    [heading drawInRect:CGRectMake(64, y + 8, 484, 14) withAttributes:metaAttrs];
                    for (NSUInteger i = 0; i < count; i++) {
                        [lines[offset + i] drawInRect:CGRectMake(64, y + 24 + i * 11, 484, 11)
                                           withAttributes:codeAttrs];
                    }
                    y += cardHeight + 10;
                    offset += count;
                }
                continue;
            }

            CGFloat width = 360;
            CGFloat x = userSide ? 216 : 36;
            CGSize measured = [text boundingRectWithSize:CGSizeMake(width - 28, 260) options:NSStringDrawingUsesLineFragmentOrigin attributes:bodyAttrs context:nil].size;
            CGFloat cardHeight = MAX(44, MIN(285, ceil(measured.height) + 36));
            needSpace(cardHeight + 10);
            CGRect card = CGRectMake(x, y, width, cardHeight);
            UIColor *fill = userSide ? [UIColor colorWithRed:0.84 green:0.93 blue:1 alpha:1] : UIColor.whiteColor;
            [fill setFill]; [[UIBezierPath bezierPathWithRoundedRect:card cornerRadius:14] fill];
            [[NSString stringWithFormat:@"%@  •  Added %@", speaker, when] drawInRect:CGRectMake(x + 14, y + 9, width - 28, 14) withAttributes:metaAttrs];
            [text drawInRect:CGRectMake(x + 14, y + 27, width - 28, cardHeight - 34) withAttributes:bodyAttrs];
            y += cardHeight + 10;
        }
    }];
}

- (void)performThreadExportFormat:(NSString *)format name:(NSString *)name {
    NSString *text = [self selectedThreadText];
    NSArray *images = [self selectedThreadImageURLs];
    NSData *data = nil;
    if ([format isEqualToString:@"pdf"]) {
        data = [self threadPDFDataWithSelectedMessages:[self selectedThreadMessages]
                                                 title:name.length ? name : @"EZCompleteUI Thread"];
    } else if ([format isEqualToString:@"rtf"]) {
        NSAttributedString *attributed = [[NSAttributedString alloc] initWithString:text
            attributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:12] }];
        data = [attributed dataFromRange:NSMakeRange(0, text.length)
                      documentAttributes:@{ NSDocumentTypeDocumentAttribute: NSRTFTextDocumentType }
                                   error:nil];
    } else {
        data = [text dataUsingEncoding:NSUTF8StringEncoding];
    }
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory()
        stringByAppendingPathComponent:[self threadExportFilenameFromName:name extension:format]]];
    [data writeToURL:url atomically:YES];
    NSMutableArray *items = [NSMutableArray arrayWithObject:url];
    if ([format isEqualToString:@"txt"]) [items addObjectsFromArray:images];
    UIActivityViewController *share = [[UIActivityViewController alloc]
        initWithActivityItems:items applicationActivities:nil];
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        share.popoverPresentationController.sourceView = self.threadSelectionBar;
        share.popoverPresentationController.sourceRect = self.threadSelectionBar.bounds;
    }
    [self presentViewController:share animated:YES completion:nil];
}

- (void)presentThreadExportFormatMenuWithName:(NSString *)name {
    UIView *card = [self presentThreadActionCardWithTitle:@"Export selection"
                                                   detail:@"Choose how to package the selected conversation."];
    NSArray<NSArray<NSString *> *> *options = @[
        @[ @"PDF", @"doc.richtext", @"Text, cards, and images in one document", @"pdf" ],
        @[ @"Rich Text", @"text.document", @"Editable .rtf document", @"rtf" ],
        @[ @"Text + images", @"photo.on.rectangle", @"Plain text plus the original image files", @"txt" ],
    ];
    UIStackView *stack = [UIStackView new];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    [card addSubview:stack];
    __weak typeof(self) weakSelf = self;
    for (NSArray<NSString *> *option in options) {
        UIButton *button = [self threadActionButtonWithTitle:option[0] symbol:option[1]
                                                        color:[UIColor colorWithRed:0.12 green:0.82 blue:1.0 alpha:1]];
        button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        [button addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
            [weakSelf dismissThreadActionOverlay];
            [weakSelf performThreadExportFormat:option[3] name:name];
        }] forControlEvents:UIControlEventTouchUpInside];
        [stack addArrangedSubview:button];
    }
    UIButton *cancel = [self threadActionButtonWithTitle:@"Cancel" symbol:@"xmark"
                                                    color:[UIColor colorWithWhite:0.78 alpha:1]];
    [cancel addAction:[UIAction actionWithHandler:^(__unused UIAction *action) { [weakSelf dismissThreadActionOverlay]; }]
      forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:cancel];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:88],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [cancel.topAnchor constraintEqualToAnchor:stack.bottomAnchor constant:14],
        [cancel.leadingAnchor constraintEqualToAnchor:stack.leadingAnchor],
        [cancel.trailingAnchor constraintEqualToAnchor:stack.trailingAnchor],
        [cancel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18],
    ]];
}

- (void)exportSelectedThreadItems {
    UIView *card = [self presentThreadActionCardWithTitle:@"Export thread"
                                                   detail:@"Name this selection, then choose its export format."];
    UITextField *field = [UITextField new];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.text = self.activeThread.title ?: @"EZCompleteUI Thread";
    field.placeholder = @"Export name";
    field.textColor = UIColor.whiteColor;
    field.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    field.layer.cornerRadius = 13;
    field.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 13, 1)];
    field.leftViewMode = UITextFieldViewModeAlways;
    [card addSubview:field];
    UIButton *cancel = [self threadActionButtonWithTitle:@"Cancel" symbol:@"xmark"
                                                    color:[UIColor colorWithWhite:0.78 alpha:1]];
    UIButton *continueButton = [self threadActionButtonWithTitle:@"Choose format" symbol:@"arrow.right"
                                                            color:[UIColor colorWithRed:0.12 green:0.82 blue:1.0 alpha:1]];
    [card addSubview:cancel]; [card addSubview:continueButton];
    __weak typeof(self) weakSelf = self;
    [cancel addAction:[UIAction actionWithHandler:^(__unused UIAction *action) { [weakSelf dismissThreadActionOverlay]; }]
      forControlEvents:UIControlEventTouchUpInside];
    [continueButton addAction:[UIAction actionWithHandler:^(__unused UIAction *action) {
        NSString *name = [field.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [weakSelf presentThreadExportFormatMenuWithName:name.length ? name : @"EZCompleteUI Thread"];
    }] forControlEvents:UIControlEventTouchUpInside];
    [NSLayoutConstraint activateConstraints:@[
        [field.topAnchor constraintEqualToAnchor:card.topAnchor constant:86],
        [field.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [field.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [field.heightAnchor constraintEqualToConstant:52],
        [cancel.topAnchor constraintEqualToAnchor:field.bottomAnchor constant:16],
        [cancel.leadingAnchor constraintEqualToAnchor:field.leadingAnchor],
        [continueButton.topAnchor constraintEqualToAnchor:cancel.topAnchor],
        [continueButton.leadingAnchor constraintEqualToAnchor:cancel.trailingAnchor constant:10],
        [continueButton.trailingAnchor constraintEqualToAnchor:field.trailingAnchor],
        [cancel.widthAnchor constraintEqualToAnchor:continueButton.widthAnchor],
        [cancel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18],
        [continueButton.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18],
    ]];
    [field becomeFirstResponder];
}

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

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Chat music (create_music tool)
// ─────────────────────────────────────────────────────────────────────────────
// Flow: ez-chat returns a music_request -> performChatMusicRequest: validates
// and clamps it -> EZMusicService starts the song (the server charges) ->
// pollGenerationWithID: waits for it -> the MP3 is kept on the device -> a
// song card and a _ui_music thread event are added. Nothing here decides a
// price; see the header comment at the top of this file.

/// The longest song a chat model may ask for. ez-chat clamps the same number;
/// ez-music enforces its own limits no matter what either one sends.
static NSInteger const kEZChatMusicMaxSeconds = 120;

/// How a song looks in the chat's UI-only thread timeline.
static NSDictionary *EZChatMusicEvent(NSString *entryID, NSString *title, NSString *prompt,
                                      NSInteger durationSeconds, BOOL isError, NSString *errorText,
                                      NSString *timestamp) {
    return @{
        @"role": @"_ui_music",
        @"entryID": entryID ?: @"",
        @"title": title ?: @"",
        @"prompt": prompt ?: @"",
        @"durationSeconds": @(durationSeconds),
        @"isError": @(isError),
        @"errorText": errorText ?: @"",
        @"timestamp": timestamp ?: @"time unavailable",
        @"_uiOnly": @YES,
    };
}

/// Turns a stored _ui_music event into the display row the song card draws.
static NSDictionary *EZChatMusicDisplayMessage(NSDictionary *event) {
    NSInteger seconds = [event[@"durationSeconds"] respondsToSelector:@selector(integerValue)]
        ? [event[@"durationSeconds"] integerValue] : 0;
    return @{
        @"role": @"music",
        @"entryID": event[@"entryID"] ?: @"",
        @"title": event[@"title"] ?: @"AI song",
        @"subtitle": @"AI song",
        // The card shows the length (and plays it) itself; see EZMusicBubbleCell.
        @"durationSeconds": @(MAX(seconds, 0)),
        @"timestamp": event[@"timestamp"] ?: @"time unavailable",
    };
}

- (void)performChatMusicRequest:(NSDictionary *)musicRequest {
    // One free song, same rule as the AI Music screen: a never-purchased
    // user who already has a finished song hits the paywall instead of
    // starting another. Refresh the purchase flag before denying so a
    // just-completed purchase is never blocked by a stale cached flag.
    if (![EZEntitlementManager shared].hasEverPurchased &&
        [EZMusicLibraryManager sharedManager].createdSongCount >= 1) {
        __weak typeof(self) weakSelf = self;
        [[EZEntitlementManager shared] refreshSubscriptionStatusWithCompletion:^(__unused BOOL refreshed, __unused NSInteger balance) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                if ([EZEntitlementManager shared].hasEverPurchased) {
                    [strongSelf performChatMusicRequest:musicRequest];
                    return;
                }
                [strongSelf appendToChat:@"[System: You've made your free song. Song creation needs a purchase — any purchase unlocks it.]"];
                [strongSelf showSongPurchaseRequiredAlert];
            });
        }];
        return;
    }
    NSString *prompt = [musicRequest[@"prompt"] isKindOfClass:[NSString class]]
        ? [musicRequest[@"prompt"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
    NSString *title = [musicRequest[@"title"] isKindOfClass:[NSString class]]
        ? [musicRequest[@"title"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
    NSString *lyrics = [musicRequest[@"lyrics"] isKindOfClass:[NSString class]]
        ? [musicRequest[@"lyrics"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : @"";
    BOOL instrumental = [musicRequest[@"instrumental"] respondsToSelector:@selector(boolValue)]
        && [musicRequest[@"instrumental"] boolValue];
    NSInteger requestedSeconds = [musicRequest[@"duration_seconds"] respondsToSelector:@selector(integerValue)]
        ? [musicRequest[@"duration_seconds"] integerValue] : 60;

    if (prompt.length == 0 || prompt.length > 4100 || lyrics.length > 6100) {
        [self handleAPIError:@"The song request was incomplete. Please try again."];
        return;
    }
    if (title.length > 120) title = [title substringToIndex:120];
    // Lyrics and an instrumental flag contradict each other; keep the lyrics.
    if (lyrics.length > 0) instrumental = NO;

    NSString *threadID = self.activeThread.threadID;
    NSString *timestamp = EZThreadExportTimestampNow();
    self.sendButton.enabled = NO;
    [self appendToChat:@"[System: Preparing your song...]"];

    __weak typeof(self) weakSelf = self;
    [[EZMusicService sharedService] fetchConfigWithCompletion:^(NSDictionary *config, NSError *configError) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.sendButton.enabled = YES;

        if (!config) {
            [strongSelf handleAPIError:[NSString stringWithFormat:@"Couldn't reach AI Music: %@",
                configError.localizedDescription ?: @"please try again."]];
            return;
        }
        if (![config[@"enabled"] boolValue]) {
            [strongSelf appendToChat:@"[System: AI Music is temporarily unavailable. Please try again later.]"];
            return;
        }

        // Clamp to what the server allows, and to the shorter chat limit.
        NSInteger minimumSeconds = [config[@"minimum_song_duration_seconds"] integerValue];
        NSInteger maximumSeconds = [config[@"max_song_duration_seconds"] integerValue];
        if (minimumSeconds <= 0) minimumSeconds = 10;
        if (maximumSeconds <= 0) maximumSeconds = kEZChatMusicMaxSeconds;
        maximumSeconds = MIN(maximumSeconds, kEZChatMusicMaxSeconds);
        NSInteger seconds = MAX(minimumSeconds, MIN(requestedSeconds, maximumSeconds));

        // Quote only for the "not enough coins" check and the status line. The
        // server recomputes the real charge from its own rules.
        double coinsPerMinute = [config[@"coins_per_minute"] doubleValue];
        NSInteger minimumCharge = [config[@"minimum_generation_charge"] integerValue];
        NSInteger quotedCoins = MAX(minimumCharge, (NSInteger)ceil(((double)seconds / 60.0) * coinsPerMinute));
        NSNumber *knownBalance = [EZEntitlementManager shared].coinBalance;
        if (knownBalance && knownBalance.integerValue < quotedCoins) {
            [strongSelf appendToChat:[NSString stringWithFormat:
                @"[System: This song needs about %ld coins and you have %ld.]",
                (long)quotedCoins, (long)knownBalance.integerValue]];
            [strongSelf presentCoinStoreForFeature:@"AI music"];
            return;
        }

        [[EZMusicService sharedService]
            startGenerationWithPrompt:prompt
                               lyrics:(lyrics.length > 0 ? lyrics : nil)
                         referenceURL:nil
                        referenceMode:nil
                                title:title
                      durationSeconds:seconds
                         variantCount:1
                    forceInstrumental:instrumental
                           completion:^(NSString *generationID, NSArray<NSDictionary *> *startedEntries,
                                        NSInteger balanceAfter, NSError *startError) {
            __strong typeof(weakSelf) innerSelf = weakSelf;
            if (!innerSelf) return;
            if (startError) { [innerSelf handleChatMusicStartError:startError]; return; }

            // Remember the written lyrics under the generation id so they
            // are saved with the song when it lands (see
            // -[EZMusicLibraryManager noteLyrics:forGenerationID:]).
            [[EZMusicLibraryManager sharedManager] noteLyrics:lyrics forGenerationID:generationID];
            [innerSelf updateCoinBalanceDisplay];
            NSString *shownTitle = title.length > 0 ? title : @"your song";
            [innerSelf appendToChat:[NSString stringWithFormat:
                @"[System: Composing \"%@\" (about %ld sec, up to %ld coins). It will appear here when it's ready; unfinished songs are refunded automatically.]",
                shownTitle, (long)seconds, (long)quotedCoins]];
            [innerSelf trackChatMusicGenerationID:generationID title:title prompt:prompt
                                  requestedSeconds:seconds threadID:threadID timestamp:timestamp];
        }];
    }];
}

/// Explains a failed start in chat and, for the cases that have an obvious next
/// step, offers it (coin store).
- (void)handleChatMusicStartError:(NSError *)error {
    NSString *serverCode = [error.userInfo[EZMusicServiceServerCodeKey] isKindOfClass:[NSString class]]
        ? error.userInfo[EZMusicServiceServerCodeKey] : @"";
    if ([serverCode isEqualToString:@"insufficient_coins"]) {
        [self appendToChat:@"[System: You don't have enough coins for this song.]"];
        [self presentCoinStoreForFeature:@"AI music"];
    } else if ([serverCode isEqualToString:@"too_many_active"]) {
        [self appendToChat:@"[System: You already have songs being created. Wait for them to finish, then ask again.]"];
    } else if (error.code == EZMusicServiceErrorNetwork || error.code == EZMusicServiceErrorBadResponse) {
        // The server may have accepted the request even though we never heard back.
        [self appendToChat:@"[System: The connection dropped before we heard back about your song. Check AI Music: if it isn't there, you weren't charged and you can ask again.]"];
    } else {
        [self appendToChat:[NSString stringWithFormat:@"[System: Couldn't start the song: %@]",
            error.localizedDescription ?: @"please try again."]];
    }
}

/// Watches one chat song until it finishes, then adds its card.
- (void)trackChatMusicGenerationID:(NSString *)generationID
                             title:(NSString *)requestedTitle
                            prompt:(NSString *)prompt
                  requestedSeconds:(NSInteger)requestedSeconds
                          threadID:(NSString *)threadID
                         timestamp:(NSString *)timestamp {
    if (generationID.length == 0) return;
    if (!self.chatMusicPollTokens) self.chatMusicPollTokens = [NSMutableDictionary dictionary];
    if (self.chatMusicPollTokens[generationID]) return;

    __weak typeof(self) weakSelf = self;
    EZMusicPollToken *pollToken = [[EZMusicService sharedService]
        pollGenerationWithID:generationID
                    progress:nil
                  completion:^(NSArray<NSDictionary *> *finalEntries, NSError *pollError) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.chatMusicPollTokens removeObjectForKey:generationID];

        NSDictionary *finishedEntry = nil;
        NSString *failureText = nil;
        for (NSDictionary *entry in finalEntries) {
            if ([entry[@"status"] isEqual:@"complete"]) { finishedEntry = entry; break; }
            if (!failureText && [entry[@"status"] isEqual:@"failed"] &&
                [entry[@"error_text"] isKindOfClass:[NSString class]]) {
                failureText = entry[@"error_text"];
            }
        }
        [[EZEntitlementManager shared] refreshBalanceWithCompletion:^(NSInteger balance) {}];

        if (!finishedEntry) {
            NSString *reason = failureText.length > 0 ? failureText
                : (pollError.localizedDescription ?: @"The song couldn't be created.");
            BOOL refunded = (failureText.length > 0);
            NSString *message = refunded
                ? [NSString stringWithFormat:@"%@ Your coins for this song were refunded.", reason]
                : [NSString stringWithFormat:@"%@ If it finishes, it will be in AI Music.", reason];
            [strongSelf deliverChatMusicEvent:EZChatMusicEvent(@"", requestedTitle, prompt, requestedSeconds,
                                                                YES, message, timestamp)
                                     toThread:threadID];
            return;
        }

        NSString *entryID = [finishedEntry[@"id"] isKindOfClass:[NSString class]] ? finishedEntry[@"id"] : @"";
        NSString *finalTitle = [finishedEntry[@"title"] isKindOfClass:[NSString class]] && [finishedEntry[@"title"] length] > 0
            ? finishedEntry[@"title"] : (requestedTitle.length > 0 ? requestedTitle : @"AI song");
        NSInteger actualSeconds = [finishedEntry[@"duration_actual_ms"] respondsToSelector:@selector(integerValue)]
            ? (NSInteger)llround([finishedEntry[@"duration_actual_ms"] doubleValue] / 1000.0) : 0;
        NSInteger shownSeconds = actualSeconds > 0 ? actualSeconds : requestedSeconds;

        // Keep the MP3 on the device so Play and Share work offline. If this
        // fails the card is still added; its buttons download the file on demand.
        [[EZMusicService sharedService] fetchPlaybackURLForEntryID:entryID forDownload:NO
                                                        completion:^(NSURL *remoteURL, NSError *linkError) {
            void (^addCard)(void) = ^{
                __strong typeof(weakSelf) innerSelf = weakSelf;
                if (!innerSelf) return;
                [innerSelf deliverChatMusicEvent:EZChatMusicEvent(entryID, finalTitle, prompt, shownSeconds,
                                                                   NO, nil, timestamp)
                                        toThread:threadID];
            };
            if (!remoteURL) {
                EZLogf(EZLogLevelWarning, @"Music", @"No download link for chat song %@: %@",
                       entryID, linkError.localizedDescription);
                addCard();
                return;
            }
            [[EZMusicLibraryManager sharedManager] retainSongFromRemoteURL:remoteURL entry:finishedEntry
                                                                completion:^(NSURL *localURL, NSError *saveError) {
                if (saveError) {
                    EZLogf(EZLogLevelWarning, @"Music", @"Could not keep chat song %@ locally: %@",
                           entryID, saveError.localizedDescription);
                }
                addCard();
            }];
        }];
    }];
    self.chatMusicPollTokens[generationID] = pollToken;
}

/// Puts a finished (or failed) song into the chat that asked for it. If that
/// chat is on screen the card appears right away; otherwise the event is
/// written into the saved thread so it is there when the user returns.
- (void)deliverChatMusicEvent:(NSDictionary *)event toThread:(NSString *)threadID {
    BOOL isError = [event[@"isError"] boolValue];

    if ([self.activeThread.threadID isEqualToString:threadID]) {
        if (isError) {
            [self appendToChat:[NSString stringWithFormat:@"[System: %@]", event[@"errorText"] ?: @"The song couldn't be created."]];
        } else {
            [self.displayMessages addObject:EZChatMusicDisplayMessage(event)];
            [self reloadAndScrollTable];
        }
        [self.chatContext addObject:event];
        [self saveActiveThread];
        [self indexCompletedChatMusicEvent:event threadID:threadID];
        return;
    }

    // The user is in a different chat now: add the event to the saved thread.
    EZChatThread *originalThread = threadID.length > 0 ? EZThreadLoad(threadID) : nil;
    if (!originalThread) {
        EZLogf(EZLogLevelWarning, @"Music", @"Song finished but its chat %@ no longer exists", threadID);
        return;
    }
    NSMutableArray *context = [originalThread.chatContext mutableCopy] ?: [NSMutableArray array];
    [context addObject:event];
    originalThread.chatContext = [context copy];
    EZThreadSave(originalThread, nil);
    [self indexCompletedChatMusicEvent:event threadID:threadID];
}

/// A completed chat song is a real assistant outcome, not just a decorative
/// timeline card. Index it after it has been written to its source thread so
/// memory search can find the song title and scene/style prompt later.
- (void)indexCompletedChatMusicEvent:(NSDictionary *)event threadID:(NSString *)threadID {
    if ([event[@"isError"] boolValue]) return;
    NSString *token = [EZAuthManager shared].accessToken;
    NSString *prompt = [event[@"prompt"] isKindOfClass:NSString.class] ? event[@"prompt"] : @"";
    NSString *title = [event[@"title"] isKindOfClass:NSString.class] ? event[@"title"] : @"AI song";
    NSString *entryID = [event[@"entryID"] isKindOfClass:NSString.class] ? event[@"entryID"] : @"";
    if (!token.length || !prompt.length) {
        EZLog(EZLogLevelWarning, @"MEMORY", @"Skipped chat music memory: missing session token or song prompt");
        return;
    }
    NSString *assistantReply = [NSString stringWithFormat:
        @"Created the AI song \"%@\" and saved it in AI Music. Song ID: %@. The track is available in this chat with Play and Share controls.",
        title, entryID.length ? entryID : @"unavailable"];
    EZCreateSongMemory(prompt, assistantReply, token, threadID, entryID, ^(NSString *entry) {
        if (entry) {
            EZLogf(EZLogLevelInfo, @"MEMORY", @"Indexed completed chat song %@", entryID.length ? entryID : title);
        }
    });
}

/// Text the chat model sees for a song event, so follow-ups like "make it
/// faster" know what already happened.
- (NSString *)ez_chatMusicSummaryForEvent:(NSDictionary *)event {
    if ([event[@"isError"] boolValue]) {
        return [NSString stringWithFormat:@"Song creation failed. Request: %@. Error: %@",
                event[@"prompt"] ?: @"", event[@"errorText"] ?: @"Unknown error"];
    }
    return [NSString stringWithFormat:
        @"Song \"%@\" completed; it is shown in chat with Play and Share buttons and saved in AI Music. Request: %@",
        event[@"title"] ?: @"AI song", event[@"prompt"] ?: @""];
}

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
        @"timestamp":  EZThreadExportTimestampNow(),
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
            @"timestamp": entry[@"timestamp"],
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
        @"timestamp": EZThreadExportTimestampNow(),
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
        [self configureThreadSelectionDotForCell:cell indexPath:indexPath];
        return cell;
    }

    if ([role isEqualToString:@"music"]) {
        EZMusicBubbleCell *cell = [tableView dequeueReusableCellWithIdentifier:@"EZMusic"
                                                                  forIndexPath:indexPath];
        [cell configureWithTitle:msg[@"title"] ?: @"AI song"
                        subtitle:msg[@"subtitle"] ?: @"AI song"
                 durationSeconds:[msg[@"durationSeconds"] integerValue]
                         entryID:msg[@"entryID"] ?: @""
            presentingController:self];
        return cell;
    }

    if ([role isEqualToString:@"attachment"]) {
        EZAttachmentPreviewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"EZAttachment"
                                                                        forIndexPath:indexPath];
        [cell configureWithImagePath:msg[@"imagePath"] ?: @""];
        [self ez_attachTapToExpandToCellIfNeeded:cell];
        [self configureThreadSelectionDotForCell:cell indexPath:indexPath];
        return cell;
    }

    if ([role isEqualToString:@"code"]) {
        EZCodeBlockCell *cell = [tableView dequeueReusableCellWithIdentifier:@"EZCodeBlock"
                                                                forIndexPath:indexPath];
        [cell configureWithCode:msg[@"text"]
                       language:msg[@"language"]
                      savedPath:msg[@"savedPath"]
                 viewController:self];
        [self configureThreadSelectionDotForCell:cell indexPath:indexPath];
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
        [self configureThreadSelectionDotForCell:cell indexPath:indexPath];
        return cell;
    } else {
        EZSystemCell *cell = [tableView dequeueReusableCellWithIdentifier:@"EZSystem"
                                                             forIndexPath:indexPath];
        cell.messageLabel.text = msg[@"text"] ?: @"";
        if ([self isThreadExportableMessage:msg])
            [self configureThreadSelectionDotForCell:cell indexPath:indexPath];
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
            return;
        }
    }
    // After accepting updated terms, viewDidAppear is invoked again. Keeping
    // this outside the one-time terms check makes the tutorial appear in that
    // same first verified session without ever stacking two modals at once.
    if (!self.presentedViewController && [EZFirstRunTutorialViewController shouldShowTutorial]) {
        EZFirstRunTutorialViewController *tutorial = [EZFirstRunTutorialViewController new];
        tutorial.modalPresentationStyle = UIModalPresentationFullScreen;
        tutorial.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        [self presentViewController:tutorial animated:YES completion:nil];
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
    self.imageGenerationProgress = 0.08;
    self.imagePreviewImageView.image = nil;
    self.imageProgressWidthConstraint.constant = 88;
    self.imageProgressHeightConstraint.constant = 88;
    if (!self.imageBannerHeightConstraint) {
        self.imageBannerHeightConstraint = [self.statusBannerView.heightAnchor constraintGreaterThanOrEqualToConstant:108];
    }
    self.imageBannerHeightConstraint.active = YES;
    self.statusBannerSpinner.hidden = YES;
    self.imageProgressView.hidden = NO;
    [self.statusBannerView layoutIfNeeded];
    [self updateImageGenerationProgress:self.imageGenerationProgress];
    [self showStatusBannerWithMessages:@[
        NSLocalizedStringWithDefaultValue(@"EZImageGen.Status.Working", nil, NSBundle.mainBundle,
                                          @"Working on your request…", @"Image generation progress"),
        NSLocalizedStringWithDefaultValue(@"EZImageGen.Status.Stay", nil, NSBundle.mainBundle,
                                          @"Do not leave the page while generating", @"Image generation progress"),
        NSLocalizedStringWithDefaultValue(@"EZImageGen.Status.StillWorking", nil, NSBundle.mainBundle,
                                          @"Still generating — this can take a moment", @"Image generation progress"),
        NSLocalizedStringWithDefaultValue(@"EZImageGen.Status.AlmostDone", nil, NSBundle.mainBundle,
                                          @"Almost done…", @"Image generation progress"),
    ]];
    [self.statusBannerSpinner stopAnimating];
}
- (void)handleImageGenerationStreamEvent:(NSDictionary *)event {
    NSString *type = [event[@"type"] isKindOfClass:[NSString class]] ? event[@"type"] : @"";
    if ([type isEqualToString:@"progress"] || [type isEqualToString:@"partial_image"]) {
        [self updateImageGenerationProgress:[event[@"progress"] doubleValue]];
    }
    if ([type isEqualToString:@"partial_image"]) {
        NSString *base64 = [event[@"image_b64"] isKindOfClass:[NSString class]] ? event[@"image_b64"] : nil;
        if (base64.length) {
            static dispatch_queue_t previewDecodeQueue;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                previewDecodeQueue = dispatch_queue_create("com.ezcompleteui.image-preview-decode", DISPATCH_QUEUE_SERIAL);
            });
            __weak typeof(self) weakSelf = self;
            dispatch_async(previewDecodeQueue, ^{
                NSData *imageData = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
                UIImage *preview = imageData ? [UIImage imageWithData:imageData] : nil;
                if (!preview) return;
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) self = weakSelf;
                    if (self && !self.imageProgressView.hidden) self.imagePreviewImageView.image = preview;
                });
            });
        }
    }
}
- (void)updateImageGenerationProgress:(CGFloat)progress {
    progress = MAX(self.imageGenerationProgress, MAX(0, MIN(progress, 1)));
    self.imageGenerationProgress = progress;
    [self.imageProgressView layoutIfNeeded];
    CGRect bounds = self.imageProgressView.bounds;
    CGFloat radius = MIN(bounds.size.width, bounds.size.height) / 2.0 - 3.0;
    CGPathRef ringPath = [UIBezierPath bezierPathWithArcCenter:CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds))
                                                         radius:radius startAngle:-(CGFloat)M_PI_2
                                                       endAngle:(CGFloat)(M_PI * 1.5) clockwise:YES].CGPath;
    self.imageProgressTrackRing.frame = bounds;
    self.imageProgressTrackRing.path = ringPath;
    self.imageProgressRing.frame = bounds;
    self.imageProgressRing.path = ringPath;
    self.imageProgressRing.strokeEnd = progress;
    self.imageProgressLabel.text = [NSString stringWithFormat:@"%ld%%", (long)llround(progress * 100)];
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
    if (!self.statusBannerTimer) {
        @try { [self ezcui_beginLongOperation:@"Visible long operation"]; } @catch (NSException *e) {
            EZLogf(EZLogLevelWarning, @"EZKeepAwake", @"begin failed for status banner: %@", e);
        }
    }
    [self.statusBannerTimer invalidate];
    self.statusBannerMessages = messages.count ? messages : @[@"Working…"];
    self.statusBannerPhase = 0; [self.statusBannerSpinner startAnimating]; [self tickStatusBanner];
    self.statusBannerTimer = [NSTimer scheduledTimerWithTimeInterval:4.0 target:self
        selector:@selector(tickStatusBanner) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.statusBannerTimer forMode:NSRunLoopCommonModes];
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionBeginFromCurrentState
        animations:^{ self.statusBannerView.alpha = 1.0; } completion:nil];
}
- (void)hideStatusBanner {
    BOOL wasActive = self.statusBannerTimer != nil;
    [self.statusBannerTimer invalidate]; self.statusBannerTimer = nil;
    [self.statusBannerSpinner stopAnimating];
    self.statusBannerSpinner.hidden = NO;
    if (!self.imageProgressView.hidden) {
        self.imageProgressView.hidden = YES;
        self.imagePreviewImageView.image = nil;
        self.imageProgressWidthConstraint.constant = 22;
        self.imageProgressHeightConstraint.constant = 22;
        self.imageBannerHeightConstraint.active = NO;
    }
    // Release the old operation now, not in an animation completion that can
    // fire after a chat-to-image handoff has already started the next spinner.
    if (wasActive) {
        @try { [self ezcui_endLongOperation]; } @catch (NSException *e) {
            EZLogf(EZLogLevelWarning, @"EZKeepAwake", @"end failed for status banner: %@", e);
        }
    }
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionBeginFromCurrentState
        animations:^{ self.statusBannerView.alpha = 0.0; } completion:nil];
}
- (void)tickStatusBanner {
    NSArray<NSString *> *m = self.statusBannerMessages.count ? self.statusBannerMessages : @[@"Working…"];
    [UIView transitionWithView:self.statusBannerLabel duration:0.4
        options:UIViewAnimationOptionTransitionCrossDissolve
        animations:^{ self.statusBannerLabel.text = m[self.statusBannerPhase % m.count]; } completion:nil];
    self.statusBannerPhase++;
    // The image API emits partial/completed events, not a numeric percentage.
    // Advance a monotonic estimate between those server-reported phases.
    if (!self.imageProgressView.hidden && self.imageGenerationProgress < 0.90) {
        CGFloat remaining = 0.90 - self.imageGenerationProgress;
        [self updateImageGenerationProgress:MIN(0.90, self.imageGenerationProgress + MAX(0.002, remaining * 0.08))];
    }
}
- (void)openSettings {
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:[[SettingsViewController alloc] init]];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)openBrainRot {
    BRGameModePickerViewController *picker = [BRGameModePickerViewController new];
    __weak typeof(self) weakSelf = self;
    picker.onMazeSelected = ^{
        BrainRotViewController *maze = [BrainRotViewController new];
        maze.onReturnToBrainRotMenu = ^{
            [weakSelf dismissViewControllerAnimated:YES completion:^{ [weakSelf openBrainRot]; }];
        };
        [weakSelf presentGameController:maze];
    };
    picker.onRicochetSelected = ^{
        BRRicochetViewController *ricochet = [BRRicochetViewController ricochetController];
        ricochet.onReturnToBrainRotMenu = ^{
            [weakSelf dismissViewControllerAnimated:YES completion:^{ [weakSelf openBrainRot]; }];
        };
        [weakSelf presentGameController:ricochet];
    };
    picker.onSlotsSelected = ^{
        BRSlotGamePickerViewController *slots = [BRSlotGamePickerViewController new];
        slots.onReturnToBrainRotMenu = ^{
            [weakSelf dismissViewControllerAnimated:YES completion:^{ [weakSelf openBrainRot]; }];
        };
        [weakSelf presentGameController:slots];
    };
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)presentGameController:(UIViewController *)gameController {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:gameController];
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

- (void)openTutorial {
    EZFirstRunTutorialViewController *tutorial = [EZFirstRunTutorialViewController new];
    tutorial.modalPresentationStyle = UIModalPresentationFullScreen;
    tutorial.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [self presentViewController:tutorial animated:YES completion:nil];
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

- (void)openMusic {
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:[[EZMusicViewController alloc] init]];
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
    id incomingPaths = notification.userInfo[@"filePaths"];
    if ([incomingPaths isKindOfClass:[NSArray class]]) {
        NSUInteger attachedCount = 0;
        for (id value in (NSArray *)incomingPaths) {
            if (![value isKindOfClass:[NSString class]]) continue;
            NSString *path = (NSString *)value;
            if (!path.length || ![[NSFileManager defaultManager] fileExistsAtPath:path]) continue;
            [self attachImage:[NSURL fileURLWithPath:path]];
            attachedCount += 1;
        }
        if (attachedCount > 0) [self.messageTextField becomeFirstResponder];
        return;
    }

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
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"gallery-handoff-%@", NSUUID.UUID.UUIDString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:@"gallery-image.jpg"];
    if (![UIImageJPEGRepresentation(image, 0.92) writeToFile:path atomically:YES]) {
        [self appendToChat:@"[Error: Could not save Gallery image]"];
        return;
    }

    // Use the normal attachment pipeline. It creates the thumbnail bubble and
    // records a base64 vision block in chatContext; merely adding a path to
    // pendingImagePaths made the UI claim an image was attached while the
    // actual chat request contained no image at all.
    [self attachImage:[NSURL fileURLWithPath:path]];
    [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
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
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"gallery-handoff-%@", NSUUID.UUID.UUIDString]];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:@"gallery-image.jpg"];
    if (![UIImageJPEGRepresentation(image, 0.92) writeToFile:path atomically:YES]) {
        [self appendToChat:@"[Error: Could not save Gallery image]"];
        return;
    }

    // Keep edit attachments on the same complete path as ordinary image
    // attachments, including the visible bubble and the model-readable vision
    // message. callImageEdit still uses pendingImagePaths.lastObject below.
    [self attachImage:[NSURL fileURLWithPath:path]];
    [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
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
