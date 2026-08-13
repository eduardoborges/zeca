<div align="center">
  <img src=".github/icon.png" width="128" alt="Zeca app icon">
  <h1>🐶 Zeca</h1>
  <p>Meeting recorder for <strong>macOS</strong>. Records, transcribes and summarizes on your Mac, with any meeting app.<br>
  <strong>Private by design:</strong> your audio never leaves the machine, and you own every file it writes. No account, no tracking, no analytics.<br>
  Named after a real dog.</p>

  [![release](https://img.shields.io/github/v/release/eduardoborges/zeca)](https://github.com/eduardoborges/zeca/releases)
  [![platform](https://img.shields.io/badge/platform-macOS%2015%2B-blue)](#requirements)
  [![swift](https://img.shields.io/badge/Swift-SwiftUI-orange)](Zeca/)

</div>

---

**[Site](https://zeca.eduardoborges.dev)** · **[Benchmark](BENCHMARK.md)** · **[Changelog](CHANGELOG.md)**

## What it does

- 🔒 **Nothing leaves your Mac.** Recording and transcription are fully on-device, summaries too unless you deliberately point them at a cloud model. No backend, no telemetry, nothing phones home.
- 🎙 **Works with any meeting app.** Mic and system audio recorded as separate tracks, so Zoom, Meet, Teams or anything else that makes sound just works.
- ⚡ **Live transcription on the Neural Engine.** Parakeet TDT v3 transcribes while you talk, in whatever language the meeting happens to be in.
- 📝 **Summaries by the model you choose.** Quick recap with next steps plus a point-by-point account, written on-device (MLX or Apple Intelligence) or by Claude, your Claude Code login, or any OpenAI-compatible API.
- 📦 **Your data is just files.** Plain m4a, JSON and Markdown on disk. Export a whole meeting as one `.zeca` archive and import it anywhere.

And the rest:

- Day dashboard with macOS and Google Calendar events, one click to join a call with recording already running, weekly stats.
- Paste a Zoom `.vtt` or plain "Name: sentence" lines and get the same summaries, no audio needed.
- Translation of transcript, summary and notes on demand, cached per language.
- Speakers stay simple: "You" and "Others", double-click to rename. No diarization guesswork.
- The bundled model catalog comes from a real benchmark, not vibes: [BENCHMARK.md](BENCHMARK.md).
- Automatic titles, a pause that really cuts the audio, a menu bar timer, and a warning when mic and speakers are different devices (echo cancellation likes them equal).

## Storage

Everything is plain files under `~/Library/Application Support/Zeca/Recordings/<timestamp>/`:

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

## 🛠 Build

```sh
xcodebuild -project Zeca.xcodeproj -scheme Zeca -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation build
```

The skip flags approve mlx-swift's build plugin and macros for command-line builds. If the build complains about a missing Metal toolchain after an Xcode update, run `xcodebuild -downloadComponent MetalToolchain` once.

You can also open `Zeca.xcodeproj` in Xcode and run. First launch downloads the Parakeet model (~650 MB) and asks for screen-recording, microphone and calendar permissions.

## Repository layout

```
Zeca/            macOS app (SwiftUI)
Zeca.xcodeproj/
site/              landing page (static HTML/CSS, deployed to Cloudflare Pages)
bitmap.svg         master logo (Inkscape)
```

Deploy the site with:

```sh
npx wrangler pages deploy site --project-name zeca
```
