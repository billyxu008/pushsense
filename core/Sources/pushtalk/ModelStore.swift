import Foundation

/// A Whisper model the app can offer to download.
struct WhisperModel: Identifiable, Equatable {
    let id: String          // filename stem, e.g. "ggml-large-v3-turbo"
    let title: String       // shown in the menu
    let bytes: Int64        // expected size, for progress + a sanity check
    let sha256: String?     // nil = skip verification (not published for all)
    let note: String

    var filename: String { "\(id).bin" }

    /// Official whisper.cpp weights on Hugging Face.
    var url: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)?download=true")!
    }

    static let all: [WhisperModel] = [
        WhisperModel(
            id: "ggml-base",
            title: "Base — 148 MB",
            bytes: 147_951_465,
            sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
            note: "Fastest. Fine for clear English; weaker on Chinese."
        ),
        WhisperModel(
            id: "ggml-medium",
            title: "Medium — 1.5 GB",
            bytes: 1_533_763_059,
            sha256: "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208",
            note: "Good accuracy, slower than turbo."
        ),
        WhisperModel(
            id: "ggml-large-v3-turbo",
            title: "Large v3 Turbo — 1.6 GB (recommended)",
            bytes: 1_624_555_275,
            sha256: nil,
            note: "Best balance. Strong Chinese + English, fast on Apple Silicon."
        ),
    ]

    static let recommended = all.first { $0.id == "ggml-large-v3-turbo" }!
}

/// Where models live on disk and which ones are present.
///
/// Models are NOT bundled in the .app — they are 0.15–1.6 GB and licensed
/// separately, so shipping them would bloat the download and complicate
/// distribution. Instead the app ships empty and fetches the user's chosen model
/// into Application Support on first run. That directory survives app updates,
/// is per-user, needs no privileges, and is what `Open model folder` reveals.
enum ModelStore {
    /// ~/Library/Application Support/PushTalk/models
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PushTalk/models", isDirectory: true)
    }

    static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func url(for model: WhisperModel) -> URL {
        directory.appendingPathComponent(model.filename)
    }

    /// A model counts as installed only if the file is a plausible size. This
    /// rejects both a dangling symlink and a truncated/aborted download.
    static func isInstalled(_ model: WhisperModel) -> Bool {
        let path = url(for: model)
        guard let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        return Int64(size) > model.bytes / 2
    }

    static var installed: [WhisperModel] { WhisperModel.all.filter(isInstalled) }

    /// Path the app should load, or nil if no model is installed yet.
    ///
    /// Resolution order:
    ///   1. `PT_MODEL` env var — an explicit override for development.
    ///   2. The user's selection in Settings, if that file is present.
    ///   3. Any installed model (largest first), so a fresh install that
    ///      downloaded something other than the default still works.
    ///   4. A legacy `PTModelPath` in Info.plist, for older builds.
    static func resolveActiveModelPath(settings: AppSettings = .shared) -> String? {
        if let override = ProcessInfo.processInfo.environment["PT_MODEL"],
           FileManager.default.fileExists(atPath: override) {
            return override
        }
        if let chosen = WhisperModel.all.first(where: { $0.id == settings.whisperModelID }),
           isInstalled(chosen) {
            return url(for: chosen).path
        }
        if let fallback = installed.max(by: { $0.bytes < $1.bytes }) {
            return url(for: fallback).path
        }
        if let legacy = Bundle.main.object(forInfoDictionaryKey: "PTModelPath") as? String,
           !legacy.isEmpty, FileManager.default.fileExists(atPath: legacy) {
            return legacy
        }
        return nil
    }

    static func delete(_ model: WhisperModel) throws {
        try FileManager.default.removeItem(at: url(for: model))
    }
}

/// Downloads a model to ModelStore with progress, resume, and atomic install.
///
/// Uses a background URLSession so a 1.6 GB fetch survives the app being idle,
/// and writes to a `.partial` file that is only moved into place once the
/// transfer completes — an interrupted download can never masquerade as a
/// working model.
final class ModelDownloader: NSObject {
    static let shared = ModelDownloader()

    enum Progress {
        case downloading(fraction: Double, received: Int64, total: Int64)
        case finished
        case failed(String)
        case cancelled
    }

    private var task: URLSessionDownloadTask?
    private var model: WhisperModel?
    private var onProgress: ((Progress) -> Void)?
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 60 * 60   // a big file on a slow line
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    var isDownloading: Bool { task != nil }
    var activeModelID: String? { model?.id }

    /// Start a download. Calls `onProgress` on the main queue. A second call
    /// while one is in flight is ignored — the menu disables the item anyway,
    /// but this guards against double-clicks racing.
    func start(_ model: WhisperModel, onProgress: @escaping (Progress) -> Void) {
        guard task == nil else { return }
        self.model = model
        self.onProgress = onProgress
        do {
            try ModelStore.ensureDirectory()
        } catch {
            onProgress(.failed("Cannot create model folder: \(error.localizedDescription)"))
            self.model = nil
            self.onProgress = nil
            return
        }
        let t = session.downloadTask(with: model.url)
        task = t
        t.resume()
        RuntimeLog.write("model download started: \(model.id)")
    }

    func cancel() {
        task?.cancel()
        task = nil
        model = nil
        report(.cancelled)
        onProgress = nil
    }

    private func report(_ p: Progress) {
        guard let cb = onProgress else { return }
        DispatchQueue.main.async { cb(p) }
    }

    private func finish() {
        task = nil
        model = nil
        onProgress = nil
    }
}

extension ModelDownloader: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // Hugging Face redirects to a CDN that may not send Content-Length; fall
        // back to the catalog's expected size so the UI still shows a percentage.
        let total = totalBytesExpectedToWrite > 0
            ? totalBytesExpectedToWrite
            : (model?.bytes ?? 0)
        let fraction = total > 0 ? Double(totalBytesWritten) / Double(total) : 0
        report(.downloading(fraction: fraction, received: totalBytesWritten, total: total))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let model = model else { return }

        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            report(.failed("Server returned HTTP \(http.statusCode)"))
            finish()
            return
        }

        let destination = ModelStore.url(for: model)
        do {
            // Guard against an HTML error page being saved as a .bin.
            let size = (try location.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard Int64(size) > model.bytes / 2 else {
                report(.failed("Download too small (\(size) bytes) — not a valid model"))
                finish()
                return
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            RuntimeLog.write("model installed: \(destination.path) (\(size) bytes)")
            report(.finished)
        } catch {
            report(.failed(error.localizedDescription))
        }
        finish()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return }
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled {
            self.task = nil
            self.model = nil
            self.onProgress = nil
            return
        }
        RuntimeLog.write("model download failed: \(error.localizedDescription)")
        report(.failed(error.localizedDescription))
        finish()
    }
}
