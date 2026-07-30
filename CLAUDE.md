# CLAUDE.md

Guidance for Claude Code when working in this repo.

## What this is

macOS meeting recorder (SwiftUI, `ZecaAI/`) plus a static landing page (`site/`).
UI strings are **English**; code comments are Portuguese (sem acentos). User-facing
conversation happens in Portuguese.

## Build, run, deploy

```bash
# build (BUILD SUCCEEDED is the only check; there are no tests)
xcodebuild -project ZecaAI.xcodeproj -scheme ZecaAI -configuration Debug build

# run the built app
open ~/Library/Developer/Xcode/DerivedData/ZecaAI-*/Build/Products/Debug/ZecaAI.app

# site (no build step, pure HTML/CSS + one inline script)
npx wrangler pages deploy site --project-name zeca
```

The project uses Xcode 16 synchronized folders: any file added under `ZecaAI/`
is picked up automatically — no pbxproj editing for new sources.

## Hard rules

- **NEVER kill/rebuild the app without checking for an active recording first.**
  A `pkill` during recording corrupts the m4a files (no moov atom). Check:
  the menu bar item title is `MenuBarIcon` when idle; anything else = recording.
  (This mistake was made once; recovery required building untrunc from source.)
- Deployment target is macOS 15. Anything newer (Liquid Glass `glassEffect`,
  FoundationModels) must go through `#available(macOS 26.0, *)` — the helpers in
  `Theme.swift` (`zecaGlass`, `zecaGlassButton`) already do this for glass.
- Old recordings carry Portuguese speaker labels (`Voce`, `Falante N`) in
  `transcript.json`. `SpeakerStyle` and `Turn.label` must keep accepting them.

## Architecture map

| File | Owns |
|---|---|
| `Recorder.swift` | `Recording` model, ScreenCaptureKit capture, pause, delete, auto-title hook |
| `AudioSink.swift` | SCStream output → AAC files + 16kHz mono chunks for live transcription |
| `LiveSession.swift` | Live pipeline: silence-based sentence segmentation (Hex-style whole-utterance decode), levels, per-minute live summary |
| `Transcriber.swift` | `Turn`/`Speaker` types, offline Parakeet transcription, shared model loader (reentrant) |
| `SpeakerLabeler.swift` | Diarization of the system track → `Speaker N` labels |
| `Summarizer.swift` | Claude API + Apple Intelligence providers, summary/notes/title/translation prompts, output-language setting |
| `GoogleCalendar.swift` | OAuth PKCE + loopback server, event fetch, `DayEvent` |
| `Dashboard.swift` | Overview screen: agenda (EventKit + Google merged) and weekly stats |
| `ContentView.swift` | Sidebar (Overview + grouped recordings), meeting detail cards, new-meeting flow |
| `SettingsView.swift` | Sidebar-tab settings (Transcription / Summary / Calendar) |
| `Theme.swift` | Monochrome palette + Liquid Glass fallback helpers |

Key invariant: live transcription uses **whole utterances** (buffer until ~0.7s of
silence, fresh decoder state per utterance, 1.5s minimum clip). Fixed-size chunking
destroys Parakeet quality — do not reintroduce it.

## Testing without a human

There are no unit tests; features are verified by driving the real app:

- Speak into a recording with `say -v Luciana "..."` (system audio is captured as
  "Others"; the mic picks it up too). Two different voices test diarization.
- Drive the UI via `osascript` System Events (window 1 → `splitter group 1` →
  sidebar outline / detail scroll area). AX titles are mostly `missing value`;
  find buttons by `description`.
- Verify results by reading the recording folder (`transcript.json`, `summary.md`).
- Screen must be unlocked for AX/screenshots; check
  `CGSessionCopyCurrentDictionary`'s `CGSSessionScreenIsLocked` when both fail.

## Site

`site/index.html` is self-contained (inline CSS/JS, no dependencies). Apple-style:
44px translucent navbar, hero entrance animation, IntersectionObserver reveals,
rAF parallax, `prefers-reduced-motion` respected. Assets in `site/assets/` are
generated from `bitmap.svg` (master logo, traced by the user in Inkscape).
