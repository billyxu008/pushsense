import Foundation
import CWhisper

/// In-process whisper.cpp transcription. Loads the model once, reuses it.
final class Whisper {
    private let ctx: OpaquePointer

    init?(modelPath: String, threads: Int32 = 6) {
        // Register CPU/Metal backends — required by newer ggml or it aborts.
        Self.loadBackends()

        let cparams = whisper_context_default_params()
        guard let c = whisper_init_from_file_with_params(modelPath, cparams) else {
            return nil
        }
        self.ctx = c
        self.threads = threads
    }

    private let threads: Int32

    deinit { whisper_free(ctx) }

    /// Transcribe 16kHz mono float PCM. `language` = "auto"/"zh"/"en".
    func transcribe(_ pcm: [Float], language: String = "auto") -> String {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.n_threads = threads

        return language.withCString { langPtr -> String in
            params.language = langPtr
            let rc = pcm.withUnsafeBufferPointer { buf in
                whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
            }
            guard rc == 0 else { return "" }

            let n = whisper_full_n_segments(ctx)
            var text = ""
            for s in 0..<n {
                if let seg = whisper_full_get_segment_text(ctx, s) {
                    text += String(cString: seg)
                }
            }
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return Self.toSimplified(cleaned)
        }
    }

    /// Register ggml's compute backends exactly once.
    ///
    /// The backends (Metal GPU, per-chip CPU kernels, BLAS) are separate `.so`
    /// plugins loaded at runtime, NOT linked libraries — they never appear in
    /// `otool -L`. Plain `ggml_backend_load_all()` searches a directory baked in
    /// at compile time (`GGML_BACKEND_DIR`), and the Homebrew build bakes in
    /// `/opt/homebrew/Cellar/ggml/<ver>/libexec`. That directory does not exist on
    /// a user's Mac, and worse, when it DOES exist it always wins: the baked path
    /// is searched first and ties are broken in its favour, so a bundled copy is
    /// silently ignored — which is why this looked fine in development.
    ///
    /// `ggml_backend_load_all_from_path` searches ONLY the directory given, so
    /// pointing it at our own Frameworks skips Homebrew entirely. Falls back to
    /// the default search when there are no bundled plugins (CLI/source builds).
    private static let backendsLoaded: Void = {
        if let frameworks = Bundle.main.privateFrameworksURL,
           let entries = try? FileManager.default.contentsOfDirectory(atPath: frameworks.path),
           entries.contains(where: { $0.hasSuffix(".so") }) {
            RuntimeLog.write("ggml backends from bundle: \(frameworks.path)")
            ggml_backend_load_all_from_path(frameworks.path)
        } else {
            RuntimeLog.write("ggml backends: default search path")
            ggml_backend_load_all()
        }
    }()

    /// Idempotent: registering a backend twice creates duplicate devices, since
    /// ggml dedups only by pointer identity.
    private static func loadBackends() { _ = backendsLoaded }

    /// Force any Traditional Chinese to Simplified using the OS text transform.
    /// Latin/emoji are untouched, so mixed CN/EN stays intact. No opencc needed.
    static func toSimplified(_ s: String) -> String {
        let m = NSMutableString(string: s) as CFMutableString
        CFStringTransform(m, nil, "Traditional-Simplified" as CFString, false)
        return m as String
    }
}
