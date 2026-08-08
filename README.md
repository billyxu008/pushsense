# PushTalk

Push-to-talk dictation for macOS. Hold a key, speak, release — the text is
typed into whatever field you're focused on.

Everything runs on your machine. No cloud, no account, no API key.

![status](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)
![status](https://img.shields.io/badge/build-from%20source-blue)

## Why this exists

I type a lot, and I wanted to talk to my editor instead. The tools I found were
either subscription-priced or sent audio to a server. Speech I dictate all day
is not something I want to hand to a third party, so I built one that doesn't
leave the laptop.

The first version was Electron and shipped as a 230MB app. This is the Swift
rewrite: **4.8MB installed, 2.2MB as a disk image**. Same feature set, no
Chromium.

## How it works

```
Right-Option held  →  record (AVFoundation)
                   →  transcribe (whisper.cpp, Metal GPU)
                   →  type it out (CGEvent unicode)
```

Four small pieces, one per step: `Hotkey.swift`, `Recorder.swift`,
`Whisper.swift`, `Injector.swift`. It lives in the menu bar and shows a halo
overlay while listening.

**Features**

- Any hotkey, any microphone, any Whisper language
- Speech models are downloaded by the app on first run, not baked into the
  bundle
- Silence is discarded rather than typed — Whisper hallucinates confident text
  from near-silent audio, which is worse than typing nothing
- Optional "Smart mode": a local Ollama model reformats the raw transcript
  (opt-in; raw is the default). Cloud LLMs work too, bring your own key
- Settings live in the Keychain

## Install

**There is no signed download yet.** The `.app` I build locally is ad-hoc
signed, which means macOS reports it as damaged on any machine but mine —
worse than unsigned, since Gatekeeper won't let you right-click past it.
Notarization needs a paid Apple Developer account, and I haven't bought one.

So: build it yourself.

```bash
git clone https://github.com/billyxu008/pushtalk-transcriber.git
cd pushtalk-transcriber/core
bash make-app.sh
```

Requires **full Xcode** — Command Line Tools alone cannot produce a `.app`.
The result is `core/PushTalk.app`; drag it to `/Applications`.

On first launch macOS will ask for **Microphone** and **Accessibility**
permission. Accessibility is what lets it type into other apps; without it the
transcript has nowhere to go.

## What I learned building it

The notes I'd have wanted before starting:

- **ggml needs `ggml_backend_load_all()` before `whisper_init`.** Skip it and
  it reports `backends = 0` and aborts, with no hint that a call is missing.
- **Bundling beats depending.** The app used to need Homebrew's libraries at
  runtime — fine on my machine, broken on everyone else's. Every dependency is
  now copied into the bundle.
- **Whisper invents text from silence.** It doesn't return empty; it returns
  something plausible. That has to be filtered explicitly.
- **Ad-hoc signing is worse than no signing** for anything you hand to another
  person.

## History

The Electron original was deleted on 2026-07-27 once this surpassed it. Its
history lived on an `electron-archive` branch sharing no commits with `master`
— the rewrite replaced the repo wholesale rather than building on the old
lineage. That branch has since been removed.

## License

Free to use. Not currently open-licensed for redistribution.
