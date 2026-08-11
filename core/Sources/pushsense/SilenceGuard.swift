import Foundation

/// Decides whether a take should produce any text at all.
///
/// Whisper's training data was full of YouTube captions, so over silence it
/// confidently emits filler like "Thank you." or "谢谢观看". Typing that into the
/// user's document is worse than typing nothing — it looks like the app is
/// broken. PushSense is in a stronger position than a file-based transcriber: it
/// owns the microphone, so it can measure the actual signal and refuse to
/// transcribe silence in the first place.
///
/// Two independent layers, in order of confidence:
///
///  1. **Signal gate** (`isSilent`) — runs BEFORE Whisper. If the raw audio
///     never rose above the noise floor, the mic was muted, hardware-off, or
///     capturing a dead channel. There is nothing to transcribe, so we skip the
///     model entirely: faster, and no hallucination is possible.
///
///  2. **Phrase filter** (`isHallucinatedPhrase`) — runs AFTER Whisper, for
///     takes that had *some* signal (room tone, a keyboard click, a breath) but
///     no speech. Only bare, exact filler phrases are dropped, so a real
///     "thank you" dictated on purpose survives.
enum SilenceGuard {

    // MARK: - Layer 1: signal gate

    /// Peak amplitude at or below this is indistinguishable from a muted input.
    ///
    /// Reference points on the raw 16kHz mono signal (i.e. before the overlay's
    /// 2.2×/6× amplification):
    ///   - muted / hardware-off mic:  peak ≈ 0.0000–0.0002
    ///   - quiet room, mic live:      peak ≈ 0.001–0.01
    ///   - normal speech:             peak ≈ 0.05–0.30
    ///
    /// 0.005 sits well above digital silence and well below even quiet speech,
    /// so a muted mic is caught without ever rejecting a soft talker.
    static let peakFloor: Float = 0.005

    /// RMS at or below this means no sustained energy — room tone at most.
    /// Speech, even quiet, carries RMS well above this over a held hotkey.
    static let rmsFloor: Float = 0.0015

    /// Shorter than this and the user almost certainly tapped the hotkey by
    /// accident. Whisper on a fraction of a second is pure guesswork.
    static let minimumDurationSeconds: Double = 0.20
    static let sampleRate: Double = 16_000

    /// True when this take carries no transcribable audio, judged only from the
    /// signal — no model involved.
    ///
    /// Both loudness tests must fail to call it silent: a single loud click can
    /// lift `peak` while `rms` stays at the floor, and a steady hum can do the
    /// reverse. Requiring both keeps a real utterance from being discarded.
    static func isSilent(peak: Float, rms: Float, sampleCount: Int) -> Bool {
        let duration = Double(sampleCount) / sampleRate
        if duration < minimumDurationSeconds { return true }
        return peak <= peakFloor && rms <= rmsFloor
    }

    // MARK: - Layer 2: phrase filter

    /// Exact phrases Whisper produces over silence. Matched only as the ENTIRE
    /// transcript — a sentence that merely contains "thank you" is real speech.
    ///
    /// Mirrors the list validated in the notetaker project against real
    /// recordings; both apps use whisper large-v3-turbo and hallucinate alike.
    private static let fillerPhrases: Set<String> = [
        "you",
        "thank you",
        "thank you.",
        "thanks for watching",
        "thanks for watching.",
        "thanks for watching!",
        "thank you for watching",
        "thank you for watching.",
        "thank you very much",
        "thank you very much.",
        "please subscribe",
        "please subscribe.",
        "bye",
        "bye.",
        "bye-bye",
        "okay",
        "okay.",
        "oh",
        "oh.",
        "谢谢",
        "谢谢。",
        "谢谢观看",
        "谢谢观看。",
        "谢谢大家",
        "谢谢大家。",
        "请订阅",
        "字幕由amara.org社区提供",
        "字幕由亚马逊工作室提供",
    ]

    /// Characters stripped before comparing, so "Thank you!!" and "（谢谢）" match
    /// their bare forms. Deliberately does not strip letters/digits.
    private static let trimmable = CharacterSet(charactersIn: " \t\n\r.,!?;:…、。，！？；：\"'“”‘’()（）[]【】-—~")

    /// True when the transcript consists solely of a known silence filler.
    static func isHallucinatedPhrase(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: trimmable)
            .lowercased()
            .trimmingCharacters(in: trimmable)
        if normalized.isEmpty { return true }
        if fillerPhrases.contains(normalized) { return true }

        // Whisper also repeats one filler token: "you you you", "谢谢 谢谢".
        let parts = normalized.split(separator: " ").map(String.init)
        if parts.count > 1, parts.count <= 8, Set(parts).count == 1,
           fillerPhrases.contains(parts[0]) {
            return true
        }
        return false
    }
}
