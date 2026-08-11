import Foundation
import AVFoundation

/// Orchestrates the push-to-talk pipeline: hotkey → record → transcribe →
/// inject. UI-agnostic; the menubar app observes `onStateChange` to update the
/// icon/menu.
final class Controller {
    enum State { case idle, recording, transcribing }

    private let whisper: Whisper
    private let recorder = Recorder()
    private var hotkey: Hotkey
    private let settings: AppSettings
    private(set) var state: State = .idle

    var onStateChange: ((State) -> Void)?
    var onLevel: ((Float) -> Void)?

    init?(modelPath: String, settings: AppSettings = .shared) {
        guard let w = Whisper(modelPath: modelPath) else { return nil }
        self.whisper = w
        self.settings = settings
        self.hotkey = Hotkey(keycode: settings.hotkey.keycode, flagMask: settings.hotkey.flagMask)
        self.recorder.deviceID = settings.microphoneID
        recorder.onLevel = { [weak self] lvl in
            DispatchQueue.main.async { self?.onLevel?(lvl) }
        }
    }

    func requestMic(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { done(granted) }
        }
    }

    func start() -> Bool {
        configureHotkey()
        recorder.deviceID = settings.microphoneID
        return hotkey.start()
    }

    func refreshRecordingSettings() {
        recorder.deviceID = settings.microphoneID
    }

    func restartHotkey() -> Bool {
        hotkey.stop()
        hotkey = Hotkey(keycode: settings.hotkey.keycode, flagMask: settings.hotkey.flagMask)
        configureHotkey()
        return hotkey.start()
    }

    private func configureHotkey() {
        hotkey.onDown = { [weak self] in
            RuntimeLog.write("Controller received hotkey DOWN")
            self?.beginRecording()
        }
        hotkey.onUp = { [weak self] in
            RuntimeLog.write("Controller received hotkey UP")
            self?.endRecording()
        }
    }

    private func setState(_ s: State) {
        state = s
        onStateChange?(s)
    }

    private func beginRecording() {
        guard state == .idle else {
            RuntimeLog.write("begin ignored; state=\\(state)")
            return
        }
        do {
            try recorder.start()
            setState(.recording)
            RuntimeLog.write("recording state entered")
        } catch {
            RuntimeLog.write("record start error: \\(error)")
            NSLog("record start error: \(error)")
        }
    }

    private func endRecording() {
        guard state == .recording else {
            RuntimeLog.write("end ignored; state=\\(state)")
            return
        }
        let pcm = recorder.stop()
        let loudness = recorder.lastLoudness
        let language = settings.language.whisperCode
        let pasteMode = settings.pasteMode
        let trailingSpace = settings.trailingSpace
        let outputMode = settings.outputMode
        RuntimeLog.write("recording stopped; pcmSamples=\(pcm.count)")

        // Muted or dead microphone: there is nothing to transcribe, and running
        // Whisper on silence is exactly what produces a bogus "Thank you." in the
        // user's document. Bail out before the model, type nothing, and go
        // straight back to idle.
        if SilenceGuard.isSilent(peak: loudness.peak, rms: loudness.rms, sampleCount: pcm.count) {
            RuntimeLog.write(String(
                format: "silent take — skipping Whisper (peak=%.5f rms=%.5f samples=%d)",
                loudness.peak, loudness.rms, pcm.count
            ))
            setState(.idle)
            return
        }

        setState(.transcribing)
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            RuntimeLog.write("Whisper started")
            var text = self.whisper.transcribe(pcm, language: language)
            RuntimeLog.write("Whisper RAW: \(text)")

            // Had signal but no speech (room tone, a click, a breath): Whisper
            // still emits caption filler. Drop it before the AI stage so Smart
            // mode isn't handed a hallucination to expand on.
            if SilenceGuard.isHallucinatedPhrase(text) {
                RuntimeLog.write("hallucination filtered: \(text)")
                DispatchQueue.main.async { self.setState(.idle) }
                return
            }

            // Optional AI reformat (local LLM) per output mode. Fails safe: on
            // any error the original transcript is used.
            if outputMode.usesAI && !text.isEmpty {
                let model = self.settings.correctionModel
                RuntimeLog.write("AI reformat mode=\(outputMode.rawValue) model=\(model.isEmpty ? "(default)" : model)")
                let out = Corrector.process(text, systemPrompt: outputMode.systemPrompt, config: Corrector.config(model: model))
                RuntimeLog.write("AI OUTPUT: \(out)")
                text = out
            }

            DispatchQueue.main.async {
                if !text.isEmpty {
                    RuntimeLog.write("Injector posting text")
                    Injector.insert(text, mode: pasteMode, trailingSpace: trailingSpace)
                } else {
                    RuntimeLog.write("Injector skipped empty transcript")
                }
                self.setState(.idle)
            }
        }
    }
}
