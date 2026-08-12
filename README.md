<div align="center">
  <img src=".github/icon.png" width="128" alt="Zeca app icon">
  <h1>Zeca</h1>
  <p>Meeting recorder for <strong>macOS</strong>. Records, transcribes and summarizes on your Mac, with any meeting app. Named after a real dog.</p>

  [![release](https://img.shields.io/github/v/release/eduardoborges/zeca)](https://github.com/eduardoborges/zeca/releases)
  [![platform](https://img.shields.io/badge/platform-macOS%2015%2B-blue)](#requirements)
  [![swift](https://img.shields.io/badge/Swift-SwiftUI-orange)](ZecaAI/)

</div>

---

**[Site](https://zeca.eduardoborges.dev)** · **[Benchmark](BENCHMARK.md)** · **[Changelog](CHANGELOG.md)**

## What it does

- Records your microphone and the system audio as separate tracks (ScreenCaptureKit), so it works with Zoom, Meet, Teams or anything else that makes sound.
- Transcribes live while you talk. Parakeet TDT v3 runs on the Neural Engine and cuts sentences on silence, in whatever language the meeting happens to be in.
- Keeps speakers simple: your microphone is "You", everything else is "Others". No diarization guesswork. Double-click a name to rename it.
- Writes a quick recap with next steps, plus a longer point-by-point account in reported speech. Each document remembers which model wrote it.
- Lets you pick the summary model: Claude API, your Claude Code login (no API key), any OpenAI-compatible API, a bundled on-device model (MLX), or Apple Intelligence.
- Exports and imports meetings as `.zeca` files: audio, transcript and summaries in one archive, with author and export date in a manifest. Double-click one to preview it before importing.
- Creates meetings from a pasted transcript. If you have a `.vtt` from Zoom or plain "Name: sentence" lines, paste them and you get the same summaries, just without audio.
- Ships an on-device model catalog picked by measurement, not marketing: every candidate ran both tasks on a real 36-minute meeting and had its output read for faithfulness. Method and results in [BENCHMARK.md](BENCHMARK.md).
- Translates the transcript, summary and notes on demand, with a cache per language.
- Shows your day on a dashboard: today's events from macOS Calendar and Google Calendar (OAuth), one click to join a call with recording already running, weekly stats.
- Plus the small stuff: automatic titles for unnamed meetings, a pause that really cuts the audio, a menu bar timer with controls, and a warning when your mic and speakers are different devices (echo cancellation only works well on the same device).

## Storage

Everything is plain files under `~/Library/Application Support/ZecaAI/Recordings/<timestamp>/`:

```
mic.m4a  system.m4a         audio tracks (absent in imported meetings)
meeting.m4a                 combined mix (created on first play)
transcript.json             turns with speaker, start/end, text
summary.md  notes.md        generated documents
summary.model.txt           which model generated each document
notes.model.txt
title.txt  offsets.json     metadata
translation-<lang>.json     cached transcript translations
summary-<lang>.md           cached document translations
notes-<lang>.md
zeca.json                   import manifest (only in imported meetings)
```

## Requirements

- macOS 15+ (Liquid Glass UI on macOS 26; on-device summaries need macOS 26 with Apple Intelligence)
- Xcode 16+
- Optional: Anthropic API key or the Claude Code CLI (summaries), Google OAuth client (calendar)

## Build

```sh
xcodebuild -project ZecaAI.xcodeproj -scheme ZecaAI -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation build
```

The skip flags approve mlx-swift's build plugin and macros for command-line builds. If the build complains about a missing Metal toolchain after an Xcode update, run `xcodebuild -downloadComponent MetalToolchain` once.

You can also open `ZecaAI.xcodeproj` in Xcode and run. First launch downloads the Parakeet model (~650 MB) and asks for screen-recording, microphone and calendar permissions.

## Repository layout

```
ZecaAI/            macOS app (SwiftUI)
ZecaAI.xcodeproj/
site/              landing page (static HTML/CSS, deployed to Cloudflare Pages)
bitmap.svg         master logo (Inkscape)
```

Deploy the site with:

```sh
npx wrangler pages deploy site --project-name zeca
```
