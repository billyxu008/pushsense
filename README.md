# PushTalk — Native (macOS)

Native Swift rewrite of PushTalk, the push-to-talk dictation tool. Goal: tiny
binary (~10–20MB vs the Electron build's ~230MB), low memory, no Chromium.

## Two codebases, one product

| Version | Location | Platform | Role |
|---------|----------|----------|------|
| **Native (this)** | `StartUp/PushTalkNative/` | macOS only | Primary. Swift + SwiftUI + in-process whisper.cpp. |
| **Electron** | `StartUp/transcriber/` | cross-platform | Kept as the **Windows branch** for later. Same product idea; its main-process-orchestrator + sidecar architecture ports to Windows (Win32 `RegisterHotKey` + `SendInput` replacing the macOS Swift helpers). |

Decision (2026-07-19): Mac goes native for a first-class, lightweight product;
the Electron version is preserved — not retired — as the future Windows base.

## Status — phased rewrite

- [x] **Phase 0** — verified Swift can link `libwhisper.dylib` and transcribe
      in-process (Metal GPU). Key gotcha: must call `ggml_backend_load_all()`
      before `whisper_init`, or ggml reports `backends = 0` and aborts. See
      `whisper-probe/`.
- [ ] **Phase 1** — minimal working chain: hotkey (CGEventTap) → record
      (AVFoundation) → whisper → inject (CGEvent unicode). CLI / no UI.
- [ ] **Phase 2** — menubar app (SwiftUI/AppKit) + status.
- [ ] **Phase 3** — halo-bloom overlay (SwiftUI) + halo icon.
- [ ] **Phase 4** — menus: change hotkey, pick mic, language.
- [ ] **Phase 5** — package `.app`, measure size vs Electron.

## Reuse from the Electron version

The Electron build already has working Swift implementations we can lift:
- `transcriber/src/native/hotkey-tap.swift` — CGEventTap Right-Option watcher.
- `transcriber/src/native/type-unicode.swift` — `CGEventKeyboardSetUnicodeString`
  injection (handles CN/EN/emoji, no clipboard).

The one genuinely new native piece for Phase 1 is **AVFoundation recording**
(replacing the browser `getUserMedia` path).

## Build

Requires full Xcode (Command Line Tools alone can't build a `.app`). This repo
uses Xcode-beta via `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.
