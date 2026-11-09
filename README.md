# EZCompleteUI

EZCompleteUI is a native iOS AI workspace built with Objective-C and Theos. It combines coin-metered AI chat, a gallery-first image studio, AI music, sound generation, voice tools, a file explorer, local thread history, searchable memories, and the Brainrot arcade — slots and custom games — in one app.

The current release is **7.2.0** and targets iOS 15.0 and later. See
[CHANGELOG.md](CHANGELOG.md) for release notes.

## Install

- **AltStore / SideStore:** add the source
  `https://raw.githubusercontent.com/Tweaker177/EZCompleteUI/main/apps.json`
  and install from there. See [ALTSTORE_SETUP.md](ALTSTORE_SETUP.md) for how the source is maintained.
- **Jailbroken devices:** install the rootless `.deb` (package `com.i0stweak3r.ezcompleteui`) from the author's repo on YouRepo.

## What it includes

- Authenticated, coin-based access with a coin store, balance display, and a user usage ledger that records every credit and deduction.
- Persistent chats with local thread restore, inline image attachments, generated-image grids, code blocks, and Quick Look previews, plus shareable file creations (PDF, CSV, RTF, and more) with inline previews.
- **Fast Mode:** a four-position response-speed setting — Flex (slower, half the coins), Normal, Fast (2× coins), and Ultrafast (6× coins) on supported models.
- AI memory: conversations are summarized, searchable, and editable across all chats, and can retain attachment references.
- Gallery-first image studio: generated, imported, and edited images live together in a polished visual workspace. Open an image to compare, zoom, ask about it, edit it with AI, download it, share it, delete it, or pass it into the custom game workflow.
- Multi-image gallery edits: start with an image and add up to three more references from Photos or Files. The editor previews multi-image work as an animated 2×2 grid, retains the original, and saves every result as a new gallery asset.
- Artist-friendly controls: a large, keyboard-aware edit prompt, configurable size, quality, output format, background, moderation, and variation settings — keep refining from the gallery without losing the source material.
- Resilient gallery generation: transient network failures retry automatically, progress stays visible, and results are saved as sibling images rather than overwriting the original.
- Presentation-ready export: download the clean result, share a branded image with the prompt and gradient border, or create looping before/after GIF exports.
- **Adults-only image generation** (`seahorse-image`, 18+): a separate generator gated by a one-time government-ID check — an AI reads the date of birth, the server does the 18+ math, and the ID itself is never stored — plus a likeness check for reference photos against your enrollment. A flat 50 coins per image.
- File and vision workflows for images, PDFs, ePub, text, HTML, RTF, CSV, and JSON files.
- **AI Music:** create songs from a text description — instrumental or vocal, chosen duration, variants — and keep them in a dedicated music library for playback, sharing, and reuse. Chat can also turn a music request into a generated song directly in the conversation.
- **Sounds:** generate any sound you can describe, up to 30 seconds, with an optional seamless loop — rain, ambience, effects, background beds. Sounds live in their own library with a built-in clip editor (trim, insert silence, normalize, speed, pitch/reverb/echo/EQ effects), and any sound can be mixed under a video or used as the background bed for a text-to-speech scene.
- Text-to-speech with Apple voices and ElevenLabs voices, ElevenLabs voice cloning and clone management, and a TTS library where generations can be replayed, exported, re-ordered, edited, volume-maximized, effect-treated, and combined.
- Transcription with Whisper, and Apple speech dictation.
- **File explorer:** browse and search the app's storage, preview and share files, edit text files, create and extract ZIP, TAR, and Debian package archives, and manage a trash with restore — all without leaving the app.
- Web search toggle with an optional location hint.
- **Brainrot slots:** two slot machines (Classic and Penny) with animated win celebrations and free spins, which free-coin claims can also award. Plus the Brainrot custom-game creation engine, a game library/picker, community-shared games, and admin tools.
- Free coins every 6 hours from the coin store, periodic buy-one-get-one promotions, and a referral program: share your code and you and each friend who signs up with it get 200 free coins.
- The interface is localized in 17 languages.
- In-app Terms, Privacy, Refund, and Support/Feedback screens.

## Model picker

The picker is the source of truth for models exposed by the app.

| Group | Models |
| --- | --- |
| Chat | `gpt-6-astra`, `gpt-6.1-sol`, `gpt-6.1-terra`, `gpt-6-luna`, `gpt-5-mini`, `gpt-4o`, `gpt-4o-mini` |
| Image generation | `gpt-image-2.5-sunburst`, `gpt-image-2.5-flare`, `gpt-image-2`, `gpt-image-1-mini`, `seahorse-image` (NSFW, 18+) |
| Audio transcription | `whisper-1` |

The GPT-6 family: `gpt-6-astra` for the most demanding reasoning and coding work, `gpt-6.1-sol` for a near-Astra intelligence/cost balance, `gpt-6.1-terra` as the everyday balanced choice, and `gpt-6-luna` for fast, high-volume work. Astra and Sol require a prior EZCompleteUI purchase; the others do not, although every request uses coins.

Every chat model can hand off an image request to the app's GPT Image workflow, so asking for a picture does not need a separate model change: the selected chat model interprets the request while GPT Image renders the result using the active image settings and normal image charges. The `gpt-image-*` family can also be selected directly for image generation and attachment-driven editing. `whisper-1` is transcription-only.

## Coins and subscriptions

Everything AI in the app runs on coins. Subscriptions credit coins monthly (annual plans credit the full year up front):

| Plan | Price | Coins |
| --- | --- | --- |
| Basic | $5/mo (or $5/wk) | 400 |
| Standard | $10/mo | 900 |
| Pro | $15/mo | 1,600 |
| Ultra | $20/mo | 2,500 |
| Power | $49.99/mo | 6,250 |
| Enterprise | $99.99/mo | 12,500 |

One-time coin packs are also available from $5 (400 coins) to $99.99 (12,500 coins). Free coins can be claimed from the store every 6 hours (5 coins per claim, 10 for subscribers), claims can award free spins for the slot machines, and the store runs periodic buy-one-get-one promotions on packs and subscriptions.

## Using the app

1. Sign in and accept the in-app terms.
2. Add coins or manage your subscription from Settings or the coin balance control.
3. Choose a model from the model button, and a response speed from the Fast Mode setting if you want one.
4. For a new image, choose an image model and adjust size, variations, quality, moderation, background, and file type from the image settings control.
5. For the best editing experience, open **Photo Gallery**, choose an image, tap **Edit with AI**, and describe the change. Add up to three more image references from Photos or Files/cloud providers when the idea needs multiple sources.
6. The gallery keeps the original safe and saves the completed edit as a separate image. If a connection is briefly interrupted, the gallery editor retries eligible transient failures automatically.
7. Chat attachments can still be edited directly in the conversation when that is the fastest path; the gallery is the more visual, focused workspace for artists and detailed multi-image edits.
8. Use the history drawer to restore chats, the Memories view to search or edit retained summaries, and the drawer to jump to Music, Sounds, Files, and the Brainrot arcade.

Image attachments are stored locally and reconstructed in their original thread position when a thread is restored. Imported, generated, and edited images are kept in the photo gallery.

## Local data

The app keeps its local working data in the app Documents directory:

| Path | Purpose |
| --- | --- |
| `EZThreads/` | Saved conversation JSON files |
| `EZAttachments/` | Non-image attachments and exported files |
| `EZPhotoGallery/` | Imported, generated, and edited images; originals are retained beside new edit results |
| `TTSLibrary/` | Text-to-speech clips and their manifest |
| `EZSounds/` | Generated sounds and their manifest |
| `ezui_memory.json` | Memory summaries and attachment references |
| `ezui_system.log` | System diagnostic log |
| `ezui_helper.log` | Helper/routing diagnostic log |

Authenticated requests, entitlement checks, billing, and usage logging are handled through the project's Supabase edge functions. All coin deductions and credits are recorded in a detailed usage ledger, accessible from the coin store.

## Building from source

Requirements:

- macOS with Xcode and Command Line Tools
- [Theos](https://theos.dev/docs/installation)
- iPhoneOS SDK compatible with the configured Theos target

For a development build:

```sh
make
```

For a packaged Debug IPA and rootless `.deb` (the default for local testing):

```sh
./build.sh
```

For a public-facing Release package:

```sh
./build.sh release
```

The build script stages the app, applies the required microphone, speech-recognition, and document-access usage descriptions to the staged plist, creates `EZCompleteUI.ipa`, and packages the rootless Debian archive. Debug is intentional unless `release` is explicitly requested.

## Project layout

```text
EZCompleteUI/
├── ViewController.m                         # Main chat UI, model routing, attachments, Seahorse flow
├── helpers.m                                # Threads, memory, attachments, logging, context routing
├── EZModelPickerViewController.m            # Current model picker sections and labels
├── EZImageGridCell.m                        # Inline generated-image presentation
├── EZPhotoGalleryViewController.m           # Gallery-first image editor, imports, retries, and exports
├── MemoriesViewController.m                 # Searchable/editable memory browser
├── EZCoin*.m / EZEntitlementManager.*       # Coin store, ledgers, and entitlement client
├── TextToSpeechViewController.m             # Text-to-speech UI
├── EZTTSClipEditViewController.m            # TTS/sound clip editor (trim, normalize, effects)
├── EZSoundsViewController.m                 # Sound generator + library
├── EZSoundLibraryManager.m                  # Sound storage and manifest
├── ElevenLabsCloneViewController.m          # Voice clone management
├── EZFileExplorerViewController.m           # File explorer, text editor, archives, trash
├── BrainRotViewController.m                 # Custom game workflow entry point
├── BR*.m                                    # Game editor, model, library, and related views
├── BRSlotMachineViewController.m            # Classic slot machine
├── BRPennySlotViewController.m              # Penny slot machine
├── Resources/Info.plist                     # Bundle metadata
├── Makefile                                 # Theos target and source list
└── build.sh                                 # IPA and rootless .deb packaging workflow
```

## Troubleshooting

**A feature says there are not enough coins**

Open the coin store, add coins or manage the subscription, then retry. The user usage ledger shows credits and deductions.

**API Error: The token is invalid**

Close the app and reopen it, or sign out and sign back in from settings.

**The network request timed out.**

For gallery edits, brief connection interruptions retry automatically. If the retry cannot recover, check your connection and submit the edit again; the original image remains untouched.

**Dictation is unavailable**

Enable Microphone and Speech Recognition access for EZCompleteUI in iOS Settings.

**A file cannot be previewed**

Confirm it was fully saved under `EZAttachments/`, then reopen the associated chat or memory entry. Quick Look is used for supported previews.

## License

MIT License.
