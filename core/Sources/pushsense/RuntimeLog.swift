import Foundation

enum RuntimeLog {
    static let path = "/tmp/pushsense-runtime.log"
    private static let queue = DispatchQueue(label: "pushsense.runtime-log")

    static func write(_ message: String) {
        queue.async {
            let stamp = ISO8601DateFormatter().string(from: Date())
            let line = "\(stamp) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            guard let file = FileHandle(forWritingAtPath: path) else { return }
            defer { try? file.close() }
            do {
                try file.seekToEnd()
                try file.write(contentsOf: data)
            } catch {}
        }
    }
}
