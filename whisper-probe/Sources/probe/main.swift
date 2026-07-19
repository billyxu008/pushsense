// Phase-0 probe: link libwhisper, transcribe a 16kHz mono WAV, print text.
// Usage: probe <model.bin> <audio.wav>

import Foundation
import CWhisper

func die(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

// --- read a 16-bit PCM mono WAV into [Float] normalized to [-1, 1] ---
func readWavPCM(_ path: String) -> [Float] {
    guard let data = FileManager.default.contents(atPath: path) else {
        die("cannot read \(path)")
    }
    // find "data" chunk
    let bytes = [UInt8](data)
    var i = 12 // skip RIFF header
    var dataOffset = -1
    var dataSize = 0
    while i + 8 <= bytes.count {
        let id = String(bytes: bytes[i..<i+4], encoding: .ascii) ?? ""
        let sz = Int(bytes[i+4]) | Int(bytes[i+5])<<8 | Int(bytes[i+6])<<16 | Int(bytes[i+7])<<24
        if id == "data" {
            dataOffset = i + 8
            dataSize = sz
            break
        }
        i += 8 + sz + (sz & 1)
    }
    if dataOffset < 0 { die("no data chunk in WAV") }

    let sampleCount = dataSize / 2
    var out = [Float](repeating: 0, count: sampleCount)
    data.withUnsafeBytes { raw in
        let p = raw.baseAddress!.advanced(by: dataOffset).assumingMemoryBound(to: Int16.self)
        for n in 0..<sampleCount {
            out[n] = Float(p[n]) / 32768.0
        }
    }
    return out
}

let args = CommandLine.arguments
guard args.count == 3 else { die("usage: probe <model.bin> <audio.wav>") }
let modelPath = args[1]
let wavPath = args[2]

let pcm = readWavPCM(wavPath)
FileHandle.standardError.write("loaded \(pcm.count) samples\n".data(using: .utf8)!)

// Register the CPU/Metal backends. Newer ggml requires this explicit call —
// without it whisper reports "backends = 0" and aborts.
ggml_backend_load_all()

var cparams = whisper_context_default_params()
guard let ctx = whisper_init_from_file_with_params(modelPath, cparams) else {
    die("whisper_init failed")
}
defer { whisper_free(ctx) }

var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
params.print_realtime = false
params.print_progress = false
params.print_timestamps = false
params.n_threads = 6
"auto".withCString { params.language = $0 }

let rc = pcm.withUnsafeBufferPointer { buf in
    whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
}
if rc != 0 { die("whisper_full failed rc=\(rc)") }

let n = whisper_full_n_segments(ctx)
var text = ""
for s in 0..<n {
    if let seg = whisper_full_get_segment_text(ctx, s) {
        text += String(cString: seg)
    }
}
print(text.trimmingCharacters(in: .whitespacesAndNewlines))
