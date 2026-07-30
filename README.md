# PushTalk — Native (macOS)

Native Swift rewrite of PushTalk, the push-to-talk dictation tool. Hold
Right-Option, speak, release — the transcript is typed into whatever text field
you're focused on. Fully local (whisper.cpp), no cloud, no API keys.

Tiny binary (~10–20MB vs the old Electron build's ~230MB), low memory, no
Chromium.

## The only codebase

This is PushTalk. The original Electron build (formerly `StartUp/transcriber/`)
was deleted on 2026-07-27 — the native rewrite had surpassed it, and its Swift
helpers had already been lifted across.

Its history is preserved on the `electron-archive` branch of this repo. Note
that branch shares **no common history** with `master`: the native rewrite
replaced the repo contents wholesale rather than building on the Electron
lineage, so the two are disjoint. To read it:

```bash
git log origin/electron-archive
```

Decision (2026-07-19, revised 2026-07-27): Mac goes native. The Electron tree
was initially kept as a future Windows base; that was dropped, since a Windows
port would start from this codebase's current logic rather than a frozen tree,
and the macOS-specific pieces are exactly the ones that don't port anyway.

## Status — rewrite complete

- [x] **Phase 0** — verified Swift can link `libwhisper.dylib` and transcribe
      in-process (Metal GPU). Key gotcha: must call `ggml_backend_load_all()`
      before `whisper_init`, or ggml reports `backends = 0` and aborts.
- [x] **Phase 1** — hotkey (CGEventTap) → record (AVFoundation) → whisper →
      inject (CGEvent unicode). See `Hotkey.swift`, `Recorder.swift`,
      `Whisper.swift`, `Injector.swift`.
- [x] **Phase 2** — menubar app + status (`AppDelegate.swift`).
- [x] **Phase 3** — halo-bloom overlay + halo icon (`Overlay.swift`,
      `HaloIcon.swift`).
- [x] **Phase 4** — menus: change hotkey, pick mic, language (`Settings.swift`).
- [x] **Phase 5** — packaged `.app` (`core/make-app.sh` → `core/PushTalk.app`).

Beyond the original plan: AI Smart mode via local Ollama (`Corrector.swift`)
and Keychain-backed settings (`Keychain.swift`) — neither existed in Electron.

## Build

Requires full Xcode (Command Line Tools alone can't build a `.app`). This repo
uses Xcode-beta via `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.
