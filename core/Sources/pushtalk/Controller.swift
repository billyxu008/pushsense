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
        let language = settings.language.whisperCode
        let pasteMode = settings.pasteMode
        let trailingSpace = settings.trailingSpace
        RuntimeLog.write("recording stopped; pcmSamples=\(pcm.count)")
        setState(.transcribing)
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            RuntimeLog.write("Whisper started")
            let text = self.whisper.transcribe(pcm, language: language)
            RuntimeLog.write("Whisper finished; characters=\(text.count)")
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
