# Talkloop for iPhone (SwiftUI)

A native iOS version of **Talkloop**, the speaking practice from the web app
([`frontend/src/talkloop/` in Deutsch-Vocab-Trainer-V2](https://github.com/Harsimar17/Deutsch-Vocab-Trainer-V2/tree/main/frontend/src/talkloop)). It talks to the same Spring Boot backend, so your
account, saved AI keys, learnt words, mistake log and speaking schedule are the
same as on the web.

## Install it without a Mac (GitHub Actions + SideStore)

Every push builds an unsigned `Talkloop.ipa` on a GitHub Mac (`.github/workflows/build.yml`):
open the latest run under **Actions**, download **Talkloop-ipa** and unzip it.

1. On Windows, install iTunes (Microsoft Store) and [iloader](https://github.com/nab138/iloader/releases/latest)
   (`iloader-windows-x64.msi`).
2. Plug in the iPhone, sign in to iloader with your Apple ID and install **SideStore (Stable)**.
3. On the iPhone: trust the developer (Settings → General → VPN & Device Management), turn on
   Developer Mode (Settings → Privacy & Security), open SideStore and sign in with the same Apple ID,
   then install **LocalDevVPN** from the App Store and connect it.
4. Copy `Talkloop.ipa` to the iPhone (Files), then in SideStore: **My Apps → +** → pick it.
5. With a free Apple ID apps expire after 7 days: in SideStore, with LocalDevVPN on, tap
   **Refresh All** every few days.

In a call, the 🐞 button shows a debug log of the live voice call (connection, audio route, mic and voice).

## Build it

You need a Mac with Xcode 15 or later (iOS 17 SDK).

```bash
brew install xcodegen
cd talkloop-ios
xcodegen
open Talkloop.xcodeproj
```

Pick your team under *Signing & Capabilities*, then run it on an iPhone. Speech
recognition works in the simulator too, but a real phone is much better.

Without XcodeGen: in Xcode, create a new iOS App called Talkloop (SwiftUI, iOS 17),
delete its generated `ContentView.swift` and `TalkloopApp.swift`, drag in
`Sources/Talkloop`, and add the two usage strings from `project.yml`
(`NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`) to the
target's Info tab.

### On Windows (or Linux), with xtool

[xtool](https://github.com/xtool-org/xtool) builds the same sources as a Swift package
(`Package.swift`, `xtool.yml`, `AppInfo.plist`) and installs the app on a real iPhone over USB.
There is no simulator. On Windows it runs inside WSL.

1. Install WSL (Ubuntu), then [usbipd-win](https://learn.microsoft.com/windows/wsl/connect-usb)
   and check that you can attach the iPhone to WSL (`usbipd list`, `usbipd bind`, `usbipd attach --wsl`).
2. In WSL: install Swift 6.4 for Linux from swift.org, and `sudo apt-get install usbmuxd libimobiledevice-utils`.
3. Install xtool (the `xtool.AppImage` from its GitHub releases, into `/usr/local/bin/xtool`).
4. Download Xcode 27.1 as a `.xip` from developer.apple.com/download (Apple ID login; no Mac needed).
5. `xtool setup`: give it the Xcode `.xip` (it builds the iOS SDK from it) and log in with an Apple ID
   (a free one works with the password option; xtool suggests a spare Apple ID for that).
6. On the iPhone: turn on Developer Mode and tap "Trust" when you connect it.
7. Build and install:

   ```bash
   cd /mnt/g/talkloop-ios
   xtool dev
   ```

   The first time, trust the developer under Settings → General → VPN & Device Management.

If the device connection fails with `AFCClient.Error.muxError`, xtool's install guide describes
relaying the iPhone through iTunes on Windows instead of usbipd. With a free Apple ID the app
stops opening after 7 days; run `xtool dev` again to reinstall it.

`AppInfo.plist` holds the app's own Info.plist keys (permission texts, background audio); keep
it in step with the `info` section of `project.yml`.

### Backend

The backend address is `Backend.baseURL` in `Backend.swift` (the Render deployment
by default).

## What's in it

| File | Ported from (engine.js) |
|---|---|
| `Content.swift` | scenes, partner, topics, themes, role cards, modes, tenses, level guide, connectors |
| `Prompt.swift` | `turnSystemPrompt`, topic and subject hints, "what calls have had lately" |
| `AI.swift` | Groq / OpenAI / Gemini / Cloudflare / Mistral with the same fallbacks, the turn schema, `normalizeTurn` |
| `Learning.swift` | mistake log and its sync, speaking schedule (today's words) and its sync, say-it-again matching, LanguageTool check, streak |
| `SpeechIO.swift` | speech recognition with the 1.5 s pause, spoken replies with word highlighting |
| `PhoneCall.swift` | (iOS only) the live call as a CallKit phone call: lock screen, End, Mute, hold |
| `GeminiLive.swift` | the live voice call: Live API WebSocket, model lookup, 16 kHz mic with the speech gate, gap-free playback, resumption handles |
| `TalkloopEngine.swift` | `startConversation`, `sendTurn`, `chatTurn`, drill, hands-free mic, pause, `endCall`, recap |
| `Views/` | login, key screen, setup, call, mistakes |

All modes except Büro are there: free chat, interview, Mein Leben, Erzähl mal,
discuss a topic, sentence drill, scene role-play, Dolmetscher, Konnektoren and
Rollenkarte, with tense practice, vocab weaving and today's words.

### Live voice call (Gemini Live)

Turn on **Live voice call** on the start screen (it needs a Gemini key, or the optional
Gemini Live key). As on the web:

- Gemini hears you and answers in its own voice (Puck) within about a second; you can talk over it.
- Only speech is sent: the mic is gated against the room's noise floor, with 300 ms before
  and 1.5 s after each stretch of speech, so silence isn't billed.
- The best live model for the key is looked up (Gemini 3.8 Live first) and kept for a day.
- Each sentence is checked on the side (the conversation AI plus LanguageTool) and the
  correction shows under the call; with "Repeat each corrected sentence" on, Gemini asks
  for the repeat itself and the panel closes once you've said it.
- 🎤 mutes and unmutes; pause keeps the call connected; a dropped call reconnects with
  Gemini's resumption handle (up to 3 tries), or from a recap of the last 30 lines.
- Typed messages go to Gemini as text. Free chats name their subjects every 6 turns.
- The phone's echo cancellation (voice processing) keeps Gemini from hearing itself, and
  the call keeps going with the screen locked (background audio).
- It shows as a phone call, like a WhatsApp call (CallKit, `PhoneCall.swift`): on the lock
  screen the iOS call screen shows the partner and the call time with **End** and **Mute**;
  unlocked, the green pill or the Dynamic Island leads back to the app. A real phone call
  coming in puts it on hold; tap ▶ to carry on. These calls stay out of the Phone app's Recents.

## Not ported yet

- The **Büro** mode (colleagues dropping by in a 3D office, on Gemini Live).
- **Piper and Gemini voices**: replies use the best iOS voice installed. For a natural
  German voice, download one under Settings → Accessibility → Spoken Content → Voices → German.
- **Streaming**: replies are fetched whole, so the voice starts after the full answer
  (about a second later than the web on OpenAI and Gemini).
- **Saved topic chats** (history, reopening, sync), the **word explorer** and **bookmarks**,
  the Dolmetscher **sentence deck** (sentences said wrong coming back later), the
  **topic words** panel, the ChatGPT connection card, and resuming a call after the app is killed.
- **Voice resume**: "zwei Minuten" pauses the call as on the web, but resuming is by the ▶ button
  (no "zurück" listener).
- The "what calls have had lately" record stays on the phone (the web syncs it via `/api/talkloop/used`).
