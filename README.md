# EZCompleteUI

EZCompleteUI is a native iOS AI workspace built with Objective-C and Theos. It combines coin-metered AI chat, a gallery-first image studio, transcription, voice tools, local thread history, searchable memories, and a custom game-creation area in one app.

The current release is **7.0.9** and targets iOS 15.0 and later.

## What it includes

- Authenticated, coin-based access with a coin store, balance display, user usage ledger.
- Persistent chats with local thread restore, inline image attachments, generated-image grids, code blocks, and Quick Look previews, as well as shareable file creations including pdf, csv, rtf, with inline previews.
- AI memory: conversations are summarized, searchable, editable, and can retain attachment references.
- Gallery-first image studio: generated, imported, and edited images live together in a polished visual workspace. Open an image to compare, zoom, ask about it, edit it with AI, download it, share it, delete it, or pass it into the custom game workflow.
- Multi-image gallery edits: start with an image and add up to three more references from Photos or Files. The editor previews multi-image work as an animated 2×2 grid, while retaining the original image and saving every result as a new gallery asset.
- Artist-friendly controls: use a large, keyboard-aware edit prompt, configurable size, quality, output format, background, moderation, and variation settings, then keep refining from the gallery without losing the source material.
- Resilient gallery generation: transient network failures automatically retry, progress stays visible in the editor, and successful results are saved as sibling images rather than overwriting or removing the original.
- Presentation-ready export: download the clean result; share a branded image with the prompt, gradient border, and optional before card; or create looping before/after GIF exports.
- File and vision workflows for images, PDFs, ePub, text, HTML, RTF, CSV, and JSON files.
- Apple speech dictation, Whisper transcription, Apple text-to-speech, ElevenLabs text-to-speech, and ElevenLabs voice-clone management.
- Text to Speech library where all your TTS generations live.  You can replay or export them, re-order them, and even edit the audio files, maximizing volume, adding effects like reverb and echo, and you can combine multiple files into one.
- Web search toggle with an optional location hint.
- BrainRot custom-game creation, saved games, game library/picker, and community/admin game tools.
- In-app Terms, Privacy, Refund, and Support/Feedback screens.

## Model picker

The picker is the source of truth for models exposed by the app.

| Group | Models |
| --- | --- |
| Frontier reasoning | `gpt-6-astra`, `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`, `gpt-5-pro`, `gpt-5`, `gpt-5-mini` |
| GPT-4 chat | `gpt-4o`, `gpt-4o-mini`, `gpt-4-turbo`, `gpt-4`, `gpt-3.5-turbo` |
| Image generation | `gpt-image-2.5-flare`, `gpt-image-2.5-sunburst`, `gpt-image-2`, `gpt-image-1.5`, `gpt-image-1`, `gpt-image-1-mini`, `chatgpt-image-latest` |
| Audio transcription | `whisper-1` |

`gpt-6-astra` is shown as the newest frontier model. The GPT-5.6 variants are presented as full, balanced, and fast/cheap choices. Image models can generate new images; the `gpt-image-*` family also supports the app’s attachment-driven editing flow. `whisper-1` is transcription-only and is not used as a chat model.

## Using the app

1. Sign in and accept the in-app terms.
2. Add coins or manage your subscription from Settings or the coin balance control.
3. Choose a model from the model button. 
4. For a new image, choose an image model and adjust size, variations, quality, moderation, background, and file type from the image settings control.
5. For the best editing experience, open **Photo Gallery**, choose an image, tap **Edit with AI**, and describe the change. Add up to three more image references from Photos or Files/cloud providers when the idea needs multiple sources.
6. The gallery keeps the original safe and saves the completed edit as a separate image. If a connection is briefly interrupted, the gallery editor retries eligible transient failures automatically.
7. Chat attachments can still be edited directly in the conversation when that is the fastest path; the gallery is the more visual, focused workspace for artists and detailed multi-image edits.
8. Use the history drawer to restore chats and the Memories view to search or edit retained summaries.

Image attachments are stored locally and reconstructed in their original thread position when a thread is restored. Imported, generated, and edited images are kept in the photo gallery.

## Local data

The app keeps its local working data in the app Documents directory:

| Path | Purpose |
| --- | --- |
| `EZThreads/` | Saved conversation JSON files |
| `EZAttachments/` | Non-image attachments and exported files |
| `EZPhotoGallery/` | Imported, generated, and edited images; originals are retained beside new edit results |
| `ezui_memory.json` | Memory summaries and attachment references |
| `ezui_system.log` | System diagnostic log |
| `ezui_helper.log` | Helper/routing diagnostic log |

Authenticated requests, entitlement checks, billing, and usage logging are handled through the project’s Supabase edge functions. All coin deductions annd credits are recorded in a detailed usage ledger, accessible from the coin store. 

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
├── ViewController.m                         # Main chat UI, model routing, attachments
├── helpers.m                                # Threads, memory, attachments, logging, context routing
├── EZModelPickerViewController.m            # Current model picker sections and labels
├── EZImageGridCell.m                        # Inline generated-image presentation
├── EZPhotoGalleryViewController.m           # Gallery-first image editor, imports, retries, and exports
├── MemoriesViewController.m                 # Searchable/editable memory browser
├── EZCoin*.m / EZEntitlementManager.*       # Coin store, ledgers, and entitlement client
├── TextToSpeechViewController.m             # Text-to-speech UI
├── ElevenLabsCloneViewController.m          # Voice clone management
├── BrainRotViewController.m                 # Custom game workflow entry point
├── BR*.m                                    # Game editor, model, library, and related views
├── Resources/Info.plist                     # Bundle metadata
├── Makefile                                 # Theos target and source list
└── build.sh                                 # IPA and rootless .deb packaging workflow
```

## Troubleshooting

**A feature says there are not enough coins**

Open the coin store, add coins or manage the subscription, then retry. The user usage ledger shows credits and deductions.

**API Error: The token is invalid**
Close the app and reopen it, or sign out and sign back in from settings.

**The network request timed out. **
For gallery edits, brief connection interruptions retry automatically. If the retry cannot recover, check your connection and submit the edit again; the original image remains untouched.


**Dictation is unavailable**

Enable Microphone and Speech Recognition access for EZCompleteUI in iOS Settings.

**A file cannot be previewed**

Confirm it was fully saved under `EZAttachments/`, then reopen the associated chat or memory entry. Quick Look is used for supported previews.

## License

MIT License — see [LICENSE](LICENSE).
