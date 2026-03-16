# EZCompleteUI

> A feature-rich AI chat client for iOS — works on **any iPhone running iOS 15.0 through iOS 26**, with no subscription and no App Store required.

EZCompleteUI was built with a simple goal: bring a genuinely capable, modern AI chat experience to iPhones that mainstream AI apps have abandoned. Whether you're on an iPhone 8 running iOS 15 or the latest device on the iOS 26 developer beta, EZCompleteUI runs natively and supports the same full feature set. Chat with GPT models, generate images, edit images, transcribe audio, generate video with Sora, and more — all from one app with persistent chat history and intelligent memory.

---

## Features

### 🤖 AI Chat
- Full conversation support with **GPT-5 Pro, GPT-5, GPT-5 Mini, GPT-4o, GPT-4o Mini, GPT-4 Turbo, GPT-4, and GPT-3.5 Turbo**
- **4-tier intelligent routing** — simple questions are answered instantly by a lightweight helper model without burning tokens on a full API call; complex queries with memory needs automatically inject the right context
- **Web search** powered by OpenAI's Responses API — toggle with the 🌐 button, optionally set a location hint in Settings
- Persistent **AI memory** — key facts from every conversation are summarized and recalled automatically in future chats
- **Full chat history** — every conversation is saved to disk and can be browsed, restored, or deleted from the history panel

### 🖼 Image Generation & Editing
- **DALL-E 3** text-to-image generation
- **DALL-E 2 image editing** — attach any image and describe changes; the app routes to the edit API automatically
- Smart follow-up awareness — "try that again but darker" correctly references the previous image prompt
- Generated images saved locally for session persistence

### 🎬 Text-to-Video (Sora 2)
- **Sora 2** and **Sora 2 Pro** video generation
- Configurable resolution (`1280x720`, `1792x1024`, `720x1280`, `1024x1792`) and duration
- Async job polling with live status updates in chat — survives app backgrounding and resumes on return
- Generated videos saved locally and presented via QuickLook

### 🎙 Voice & Audio
- **Voice dictation** using Apple's on-device Speech Recognition framework
- **Whisper transcription** — attach any audio or video file for accurate AI transcription
- **Text-to-speech** via Apple TTS (built-in, no key needed) or **ElevenLabs** for high-quality voices

### 📄 File Analysis
- **PDF** text extraction and analysis via PDFKit
- **ePub** reading and Q&A
- **Plain text, HTML, RTF, CSV, JSON** file analysis
- **Vision** — attach images for GPT-4o visual analysis
- All attached files saved locally for session replay

### 🔧 Developer / Power User
- **Shake to debug** — shake the device to view helper stats, routing tier breakdown, and recent log entries; tap Copy to grab the full log to clipboard
- Detailed logging to `Documents/ezui_helpers.log` with automatic rotation at 512 KB
- Per-conversation thread files stored in `Documents/EZThreads/`
- Attachments stored in `Documents/EZAttachments/`

---

## Requirements

- iPhone running **iOS 15.0 through iOS 26** (including the iOS 26 developer beta)
- Installation via any of the methods below — no jailbreak required
- An **OpenAI API key** (required)
- An **ElevenLabs API key** (optional, for premium TTS voices)
---

## Installation

EZCompleteUI can be installed several ways depending on your device and iOS version. No jailbreak is required for any of the primary methods.

### TrollStore (iOS 14–17, recommended for older devices)
The easiest no-jailbreak option for supported iOS versions.
1. Install [TrollStore](https://github.com/opa334/TrollStore) on your device
2. Build the IPA using the instructions below, or download a pre-built release
3. Open TrollStore, tap **+**, and select the `.ipa` file
4. Tap **Install**

### LiveContainer (iOS 26 developer beta)
Run EZCompleteUI as a containerized app alongside other sideloaded apps without using an additional signing slot.
1. Install [LiveContainer](https://github.com/khanhduytran0/LiveContainer) on your device
2. Import the `.ipa` into LiveContainer
3. Launch from the LiveContainer home screen

### AltStore / SideStore (any iOS, 7-day free signing)
Works on any iPhone without a paid developer account — re-signs automatically every 7 days.
1. Install [AltStore](https://altstore.io) or [SideStore](https://sidestore.io) on your device
2. Open AltStore/SideStore and tap **+**
3. Select the `.ipa` file
4. App installs and is valid for 7 days; AltStore re-signs automatically when on the same Wi-Fi as your Mac

### Sideloadly / Xcode (any iOS, requires Apple ID)
1. Open [Sideloadly](https://sideloadly.io) or Xcode on your Mac
2. Connect your iPhone
3. Drag the `.ipa` in and sign with your Apple ID
4. Trust the developer certificate in **Settings → General → VPN & Device Management**

### Jailbreak (.deb — Dopamine, palera1n, etc.)
```bash
make package
scp packages/*.deb mobile@<device-ip>:/tmp/
ssh mobile@<device-ip> "dpkg -i /tmp/*.deb; uicache"
```

---

## Building from Source

### Prerequisites
- macOS with **Xcode** and **Xcode Command Line Tools**
- [Theos](https://theos.dev/docs/installation) installed
- iPhone SDK (iPhoneOS16.2 or later)
- Python 3 (included with macOS)

### Build
```bash
git clone https://github.com/tweaker177/EZCompleteUI.git
cd EZCompleteUI
./build.sh
```

The `build.sh` script runs `make clean && make stage`, injects required permission keys into the Info.plist, packages everything into `EZCompleteUI.ipa`, and prints `EZCompleteUI.ipa ready` when done.

---

## Setup & First Use

### 1. Get an OpenAI API Key
1. Go to [platform.openai.com](https://platform.openai.com)
2. Sign in or create an account
3. Navigate to **API Keys** and create a new key
4. Copy the key — it starts with `sk-`

> ⚠️ API usage is billed to your OpenAI account. Set a spending limit at platform.openai.com/account/limits to avoid surprises.

### 2. Configure the App
1. Open EZCompleteUI
2. Tap the **⚙️ gear icon** in the top bar
3. Paste your OpenAI API key into the **API Key** field
4. Optionally set a **System Message** (e.g. "You are a helpful assistant")
5. Tap **Done**

### 3. Start Chatting
- Type a message and tap **Send**
- Tap the **model name button** to switch between GPT models
- Tap the **🌐 globe** to toggle web search on/off
- Tap the **📎 paperclip** to attach files, images, or audio

---

## ElevenLabs TTS (Optional)

For high-quality AI voices instead of Apple's built-in TTS:

1. Create a free account at [elevenlabs.io](https://elevenlabs.io)
2. Go to **Profile → API Key** and copy your key
3. In EZCompleteUI Settings, paste it into **ElevenLabs API Key**
4. Tap **Get Voices** next to the Voice ID field to browse and select a voice
5. Tap the **🔊 speaker button** after any AI response to hear it spoken

If no ElevenLabs key is set, the app falls back to Apple TTS automatically.

---

## Sora Text-to-Video (Optional)

1. Ensure your OpenAI account has Sora API access
2. In Settings, choose your **Sora model** (`sora-2` or `sora-2-pro`), **resolution**, and **duration**
3. Select `sora-2` or `sora-2-pro` from the model picker
4. Type a video prompt and tap **Send**
5. Watch the status update in chat: ⏳ queued → ⚙️ processing → ✅ completed
6. The video opens in QuickLook when ready — tap Share to save to Photos

**Duration constraints:**
| Model | Valid durations |
|-------|----------------|
| sora-2 | 4s, 8s, 12s, 16s |
| sora-2-pro | 5s, 10s, 15s, 20s |

The app automatically snaps your selected duration to the nearest valid value.

---

## Top Bar Buttons

| Button | Action |
|--------|--------|
| ✏️ Green pencil | Save current chat and start a new one |
| 🕐 Clock | Browse and restore past conversations |
| 📋 Copy | Copy the last AI response to clipboard |
| 🔊 Speaker | Speak the last AI response aloud |
| 🌐 Globe | Toggle web search (green = on) |
| ⚙️ Gear | Open Settings |
| 🗑 Trash | Delete the current chat (confirms before deleting) |

---

## Privacy

- All conversation data is stored **locally on your device** in the app's Documents directory
- Your API key is stored in `NSUserDefaults` on-device only — it is never transmitted anywhere except directly to OpenAI's and ElevenLabs' APIs
- AI memory summaries are stored in `Documents/ezui_memory.log` — clear them anytime from Settings → Clear All Memories
- No analytics, no tracking, no third-party SDKs

---

## Project Structure

```
EZCompleteUI/
├── ViewController.m          # Main UI, all API calls, routing
├── helpers.h / helpers.m     # Logging, memory, thread store, context routing
├── ChatHistoryViewController.h / .m  # Past conversations browser
├── AppDelegate.h / .m        # App lifecycle, Sora job resume on foreground
├── Info.plist                # Bundle metadata and permission descriptions
├── entitlements.plist        # Code signing entitlements
├── Makefile                  # Theos build configuration
└── build.sh                  # One-command IPA builder
```

---

## Troubleshooting

**App crashes on launch**
- Ensure `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription` are present in the bundled `Info.plist`. Run `./build.sh` — the script injects these automatically.

**"No API Key" error**
- Open Settings (⚙️) and paste your OpenAI key starting with `sk-`

**Sora returns an error**
- Verify your OpenAI account has Sora API access at platform.openai.com
- Check that duration matches the model's valid values (see table above)
- Sora jobs can take 1–5 minutes — the app polls automatically and resumes if you background it

**Dictation button does nothing**
- Go to iOS Settings → Privacy → Microphone and ensure EZCompleteUI is enabled
- Go to iOS Settings → Privacy → Speech Recognition and ensure EZCompleteUI is enabled

**Shake gesture not working**
- The shake gesture requires the app to be the active first responder — tap anywhere in the chat first

---

## Contributing

Pull requests welcome. The codebase is intentionally kept in a small number of files to stay auditable and easy to modify on-device.

---

## License

MIT License — see [LICENSE](LICENSE) for details.

---

## Support

If EZCompleteUI saves you time or you just want to say thanks:

[![Donate via PayPal](https://img.shields.io/badge/Donate-PayPal-blue.svg)](https://paypal.me/i0stweak3r)

---

*Built to bring modern AI to every iPhone — from iOS 15 to iOS 26 and beyond.*
