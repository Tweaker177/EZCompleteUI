# EZCompleteUI

EZCompleteUI is a native iOS AI workspace built with Objective-C and Theos. It combines coin-metered AI chat, a gallery-first image studio, AI music, sound generation, voice tools, a file explorer, local thread history, searchable memories, and the Brainrot arcade — slots and custom games — in one app.

EZCompleteUI targets iOS 15.0 and later. See [CHANGELOG.md](CHANGELOG.md) for
release notes.

## Website

[ezcompleteai.wordpress.com](https://ezcompleteai.wordpress.com) — subscription
plans and coin top-ups, FAQ, privacy policy, and terms of service.

## Install

- **TestFlight (beta):** install the TestFlight app from the App Store, then
  open the beta link —
  [testflight.apple.com/join/cKdEWqsU](https://testflight.apple.com/join/cKdEWqsU) —
  and tap Install. No jailbreak or computer needed.
- **AltStore / SideStore:** add the source
  `https://raw.githubusercontent.com/Tweaker177/EZCompleteUI/main/apps.json`
  and install from there. See [ALTSTORE_SETUP.md](ALTSTORE_SETUP.md) for how the source is maintained.
- **Jailbroken devices:** install the rootless `.deb` (package `com.i0stweak3r.ezcompleteui`) from the author's repo on YouRepo.

**Plans and coin top-ups:** subscribe or top up on the website,
[ezcompleteai.wordpress.com](https://ezcompleteai.wordpress.com). Check out with
the PayPal account whose email matches your app account so your coins land
automatically, then open the app and check your balance.

## What it includes

- Authenticated, coin-based access with a coin store, balance display, and a user usage ledger that records every credit and deduction.
- Persistent chats with local thread restore, inline image attachments, generated-image grids, code blocks, and Quick Look previews, plus shareable file creations (PDF, CSV, RTF, and more) with inline previews.
- **Fast Mode:** a four-position response-speed setting — Flex (slower, half the coins), Normal, Fast (2× coins), and Ultrafast (6× coins) on supported models.
- AI memory: conversations are summarized, searchable, and editable across all chats, and can retain attachment references. Facts you mark important are kept verbatim in their own list, ride along with new chats, and can be reviewed in the Memory Summary screen; forgetting something shows a preview of what matches and asks you to confirm before anything is removed.
- Gallery-first image studio: generated, imported, and edited images live together in a polished visual workspace. Open an image to compare, zoom, ask about it, edit it with AI, download it, share it, delete it, or pass it into the custom game workflow.
- Multi-image gallery edits: start with an image and add up to three more references from Photos or Files. The editor previews multi-image work as an animated 2×2 grid, retains the original, and saves every result as a new gallery asset.
- Artist-friendly controls: a large, keyboard-aware edit prompt, configurable size, quality, output format, background, moderation, and variation settings — keep refining from the gallery without losing the source material.
- Resilient gallery generation: transient network failures retry automatically, progress stays visible, and results are saved as sibling images rather than overwriting the original.
- Presentation-ready export: download the clean result, share a branded image with the prompt and gradient border, or create looping before/after GIF exports. Image models can also generate animated GIFs directly from a prompt.
- **Adults-only image generation** (`seahorse-image`, 18+): a separate generator gated by a one-time government-ID check — an AI reads the date of birth, the server does the 18+ math, and the ID itself is never stored — plus a likeness check for reference photos against your enrollment. A flat 50 coins per image.
- File and vision workflows for images, PDFs, ePub, text, HTML, RTF, CSV, and JSON files.
- **AI Music:** create songs from a text description — instrumental or vocal, chosen duration, variants — and keep them in a dedicated music library. A full-screen player shows the cover art at full width with lyrics, favorites, and a play queue, and playback continues on the lock screen. Chat can also turn a music request into a generated song directly in the conversation, and songs the chat model writes keep their lyrics in the player.
- **Sounds:** generate any sound you can describe, up to 30 seconds, with an optional seamless loop — rain, ambience, effects, background beds. Sounds live in their own library with a built-in clip editor (trim, insert silence, normalize, speed, pitch/reverb/echo/EQ effects), and any sound can be mixed under a video or used as the background bed for a text-to-speech scene.
- Text-to-speech with Apple voices and ElevenLabs voices, ElevenLabs voice cloning and clone management, and a TTS library where generations can be replayed, exported, re-ordered, edited, volume-maximized, effect-treated, and combined.
- Transcription with Whisper, and Apple speech dictation.
- **File explorer:** browse and search the app's storage, preview and share files, edit text files, create and extract ZIP, TAR, and Debian package archives, and manage a trash with restore — all without leaving the app.
- Web search toggle with an optional location hint.
- **GitHub in chat:** connect a GitHub account and the chat can read your repositories for you. With write access switched on, it can also propose file changes and pull requests — every write is previewed and needs your in-app approval before it runs.
- **Brainrot slots:** seven machines — Classic, Penny, Plunder Bay, Golden Mandarin, Phoenix Pavilion, Penguin Parade, and Starlight Odyssey — with animated win celebrations, scatter free spins, and a card-pick bonus that sets your free-spin multiplier on Penguin Parade, Golden Mandarin, Phoenix Pavilion, and Starlight Odyssey. VIP mode (unlocked at Silver VIP, or with any active subscription) raises the bet ladder and improves the line pays. Every machine has a live player lounge with profiles, photos, and status lines, plus daily and all-time leaderboards. Coins are the only currency: no real-money wagering and no cash-out. Plus the Maze and Ricochet arcade games, the Brainrot custom-game creation engine, a game library/picker, community-shared games, and admin tools.
- Free coins can be claimed regularly from the coin store — claims can also award free spins — plus a 100-coin welcome bonus with 15 free spins for new accounts, periodic buy-one-get-one promotions, and a referral program: share your code and you and each friend who signs up with it get 200 free coins.
- The interface is localized in 17 languages.
- In-app Terms, Privacy, Refund, and Support/Feedback screens.

## Model picker

The picker is the source of truth for models exposed by the app.

| Group | Models |
| --- | --- |
| Chat | `gpt-6.2-astra`, `gpt-6-astra`, `gpt-6.2-sol`, `gpt-6.1-sol`, `gpt-6.1-terra`, `gpt-6-luna`, `gpt-5-mini`, `gpt-4o`, `gpt-4o-mini` |
| Image generation | `gpt-image-2.6-sunburst`, `gpt-image-2.6-flare`, `gpt-image-2.5-sunburst`, `gpt-image-2.5-flare`, `gpt-image-2`, `gpt-image-1-mini`, `seahorse-image` (NSFW, 18+) |
| Audio transcription | `whisper-1` |

The GPT-6 family: the Astra models for the most demanding reasoning and coding work, the Sol models for a near-Astra intelligence/cost balance, `gpt-6.1-terra` as the everyday balanced choice, and `gpt-6-luna` for fast, high-volume work. Pick **Auto** and the app chooses a model per request; picking a model yourself runs exactly that model. Astra and Sol models require a prior EZCompleteUI purchase; the others do not, although every request uses coins.

Every chat model can hand off an image request to the app's GPT Image workflow, so asking for a picture does not need a separate model change: the selected chat model interprets the request while GPT Image renders the result using the active image settings and normal image charges. The `gpt-image-*` family can also be selected directly for image generation and attachment-driven editing. `whisper-1` is transcription-only.

## Coins and subscriptions

Everything AI in the app runs on coins. Subscriptions credit coins monthly (annual plans credit the full year up front) and unlock VIP mode in the slot lounges; one-time coin packs are also available. Current plans, prices, and promotions live on the website — [ezcompleteai.wordpress.com](https://ezcompleteai.wordpress.com) — and in the in-app coin store. Free coins can be claimed regularly from the store, claims can award free spins for the slot machines, and the store runs periodic buy-one-get-one promotions on packs and subscriptions.

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
| `EZMusic/` | Generated music files and references |
| `BRGames/` | Saved custom-game data |
| `ezui_memory.json` | Memory summaries and attachment references |
| `ezui_important_memories.json` | Important facts kept verbatim |
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
├── BR*SlotViewController.m / BRPlunderBayViewController.m  # Five-reel machines and Plunder Bay
├── BRSlotChatBar.m                          # Slot lounges, player profiles, win celebrations
├── BRSlotGamePickerViewController.m         # Slot game picker and leaderboards
├── EZMusicViewController.m                  # Music library, creation, full-screen player
├── EZMediaPlayerManager.m                   # Shared audio playback (background + lock screen)
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
