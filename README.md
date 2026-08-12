# PushSense（感应）

Push-to-talk dictation for macOS. Hold a key, speak, release — the text is
typed into whatever field you're focused on. **Mixes Chinese and English in
the same sentence**, no language switch, no settings toggle.

Everything runs on your machine. No cloud, no account, no API key.

![PushSense dictating into Claude, Google and TextEdit](docs/demo-apps.gif)

<sub>Three real screen recordings, end to end. Into Claude: "Hey Claude, help me write
an email to my friend who is coming in two weeks from China. 我朋友过两天会从中国过来,
告诉他我会在家里等他。" — one sentence, two languages, no toggle. Then a Google search
box, then TextEdit. Nothing here is a mockup.</sub>

![platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)
![build](https://img.shields.io/badge/build-from%20source-blue)
![license](https://img.shields.io/badge/license-MIT-green)

[中文说明](README_ZH.md)

![What is shipped, what is wired up, and what is only planned](docs/how-it-fits.gif)

<sub>What exists today, what the pipeline already supports, and what is still just a
plan. The third panel is dashed for a reason: there is no MCP code in this repository
yet.</sub>

## Why this exists

I type a lot, and I switch between Chinese and English mid-thought — "这个
feature 的 latency 有点高" is a completely normal sentence for me. Every
dictation tool I tried picks one language and mangles the other. Most also
send audio to a server, and speech I dictate all day is not something I want
to hand to a third party.

So: local, and it doesn't flinch at a language switch mid-sentence.

Native Swift, **4.8MB installed, 2.2MB as a disk image** — no Electron, no
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

## Features

- **Mixed Chinese/English in one sentence** — Whisper transcribes code-switched
  speech natively; output is forced to Simplified Chinese via the OS text
  transform (`CFStringTransform`), so Traditional-vs-Simplified never bleeds
  through while Latin text and emoji pass through untouched
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
git clone https://github.com/billyxu008/pushsense.git
cd pushsense/core
bash make-app.sh
```

Requires **full Xcode** — Command Line Tools alone cannot produce a `.app`.
The result is `core/PushSense.app`; drag it to `/Applications`.

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

## License

[MIT](LICENSE)

---

Write-up, setup guide and demos: **[billyxu-dev.vercel.app/pushsense.html](https://billyxu-dev.vercel.app/pushsense.html)**
