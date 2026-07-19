import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

/// Microphone recorder using AVAudioEngine. Captures the input, converts to
/// 16kHz mono Float (what whisper wants), and accumulates until stop().
final class Recorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private var recording = false
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    /// Called on each buffer with a 0..1 loudness (for the overlay later).
    var onLevel: ((Float) -> Void)?
    var deviceID: AudioDeviceID?

    func start() throws {
        let selectedDevice = deviceID.map { String($0) } ?? "default"
        RuntimeLog.write("Recorder.start deviceID=\(selectedDevice) mainThread=\(Thread.isMainThread)")
        samples.removeAll(keepingCapacity: true)
        let input = engine.inputNode
        if let deviceID {
            guard let audioUnit = input.audioUnit else {
                throw NSError(domain: "PushTalk", code: 1, userInfo: [NSLocalizedDescriptionKey: "The audio input is unavailable."])
            }
            var selectedDevice = deviceID
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &selectedDevice,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not select the requested microphone."])
            }
        }
        let inFormat = input.inputFormat(forBus: 0)

        converter = AVAudioConverter(from: inFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }

        engine.prepare()
        try engine.start()
        recording = true
        RuntimeLog.write("AVAudioEngine running=\(engine.isRunning) format=\(inFormat)")
    }

    /// Stops and returns accumulated 16kHz mono float PCM.
    func stop() -> [Float] {
        guard recording else { return samples }
        recording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let out = samples
        samples.removeAll()
        RuntimeLog.write("Recorder.stop samples=\(out.count)")
        return out
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard recording, let converter = converter else { return }

        // convert this buffer to 16kHz mono
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outCap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap) else { return }

        var fed = false
        var err: NSError?
        converter.convert(to: outBuf, error: &err) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if err != nil { return }

        guard let ch = outBuf.floatChannelData else { return }
        let n = Int(outBuf.frameLength)
        var peak: Float = 0
        var sumSq: Float = 0
        for i in 0..<n {
            let s = ch[0][i]
            samples.append(s)
            let a = abs(s)
            if a > peak { peak = a }
            sumSq += s * s
        }
        // Speech peaks are small (~0.05–0.2). Blend peak + RMS and amplify hard
        // so the overlay clearly reacts to normal speaking volume.
        let rms = n > 0 ? (sumSq / Float(n)).squareRoot() : 0
        let level = min(1, (peak * 2.2 + rms * 6.0))
        onLevel?(level)
    }
}
