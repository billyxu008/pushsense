# Future Improvement — Downloadable Local Model Catalog

> Status: **Parked / do not implement yet**
>
> First priority is to use the current local PushSense build in real work and
> collect concrete friction. Revisit this only when the product benefits from
> sharing, model choice, or a better multilingual model.

## Product goal

Someone should be able to install PushSense from a DMG, grant the required
macOS permissions, and use local dictation without installing Homebrew,
Whisper, Python, or another transcription tool.

The app should later allow users to download, select, update, and remove
locally stored speech models from Settings.

## Intended user experience

1. Install PushSense from DMG.
2. Complete the guided permissions:
   - Microphone
   - Input Monitoring
   - Accessibility
3. In **Settings → Voice Models**, click **Download recommended model**.
4. See download progress, pause/resume, retry, installed size, and the active
   model.
5. Later choose another published model, for example a faster English model or
   a stronger multilingual model, without using Terminal.

## Architecture direction

```text
PushSense.app
├── bundled transcription runtime
│   └── whisper / ggml / libomp dylibs, signed inside Contents/Frameworks
├── TranscriptionEngine protocol
│   ├── WhisperEngine (first implementation)
│   └── future engine adapters (only through an App update)
├── Model catalog
│   └── published model metadata: id, version, languages, size, URL, SHA-256
└── ~/Library/Application Support/PushSense/Models/
    └── versioned, verified downloaded model files
```

### Important boundary

- **Model files** may be downloaded from inside Settings.
- **Executable runtimes / engines** must ship with a signed App update. The app
  must not download arbitrary executable code.
- A new model only works directly when it is compatible with an installed
  engine. A future MLX/Core ML/new-runtime model needs an engine adapter in a
  normal PushSense release first.

## Implementation phases when revisited

### 1. Self-contained DMG

- Bundle all native runtime dylibs; remove the current Homebrew dependency.
- Replace the hard-coded development-machine model path.
- Sign with Developer ID, notarize, and verify on a clean macOS account.

### 2. Single-model installer

- Add `ModelStore` for Application Support paths and installation state.
- Add `ModelInstaller` using resumable downloads.
- Download to a partial file, verify SHA-256, then atomically move it into the
  active model location.
- Preflight disk space and show useful retry/error states.

### 3. Settings → Voice Models

- Start with one recommended multilingual model (currently about 1.5 GB).
- Show installed / downloading / failed / update-available states.
- Support pause, resume, retry, delete, and choose active model.

### 4. Catalog and future choices

- Publish a signed or app-bundled model manifest.
- Each entry needs: model ID, version, URL, size, SHA-256, languages,
  compatible engine version, minimum macOS/hardware, quality/speed notes, and
  license status.
- Add newer models through the catalog once the required engine support has
  shipped in PushSense.

## Verification bar

- No Homebrew or developer files on the test Mac.
- DMG install → model download → all permissions → Right Option dictation →
  text inserted into another app.
- Verify interrupted download recovery, wrong checksum rejection, insufficient
  storage, deleted model, and model update rollback.

## Open decisions

- Model CDN / hosting cost and download analytics policy.
- Model license and redistribution rights.
- Apple Silicon-only versus Intel support.
- Initial models to offer: one high-quality multilingual model only, or a
  fast/small alternative too.
- Whether users may import compatible local model files manually.
