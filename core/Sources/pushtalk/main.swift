import AppKit

// Model path comes from argv[1] (CLI) or the bundle's PTModelPath (double-click).
func resolveModelPath() -> String? {
    let args = CommandLine.arguments
    if args.count >= 2 { return args[1] }
    if let p = Bundle.main.object(forInfoDictionaryKey: "PTModelPath") as? String, !p.isEmpty {
        return p
    }
    return nil
}

guard let modelPath = resolveModelPath() else {
    FileHandle.standardError.write("no model path (argv or PTModelPath)\n".data(using: .utf8)!)
    exit(1)
}

let app = NSApplication.shared
let delegate = AppDelegate(modelPath: modelPath)
app.delegate = delegate
app.run()
