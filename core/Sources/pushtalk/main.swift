import AppKit

// The app must always launch, even with no model installed — otherwise a fresh
// install would die before it could show the menubar UI that offers the
// download. A nil path just means "not set up yet"; AppDelegate shows a
// "Download model…" prompt instead of a hotkey.
//
// argv[1] still wins, for CLI use and dev overrides.
func resolveModelPath() -> String? {
    let args = CommandLine.arguments
    if args.count >= 2, FileManager.default.fileExists(atPath: args[1]) { return args[1] }
    return ModelStore.resolveActiveModelPath()
}

let app = NSApplication.shared
let delegate = AppDelegate(modelPath: resolveModelPath())
app.delegate = delegate
app.run()
