// swift-tools-version:5.9
import PackageDescription

// Homebrew whisper-cpp + ggml locations (Apple Silicon).
let whisperInclude = "/opt/homebrew/opt/whisper-cpp/include"
let whisperLib = "/opt/homebrew/opt/whisper-cpp/lib"
let ggmlInclude = "/opt/homebrew/opt/ggml/include"
let ggmlLib = "/opt/homebrew/opt/ggml/lib"

let package = Package(
    name: "whisper-probe",
    targets: [
        .systemLibrary(name: "CWhisper", path: "Sources/CWhisper"),
        .executableTarget(
            name: "probe",
            dependencies: ["CWhisper"],
            cSettings: [
                .unsafeFlags(["-I", whisperInclude, "-I", ggmlInclude])
            ],
            swiftSettings: [
                .unsafeFlags(["-I", whisperInclude, "-I", ggmlInclude])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L", whisperLib, "-lwhisper",
                    "-L", ggmlLib, "-lggml", "-lggml-base",
                    // Force the ggml backends (CPU/Metal) to register at load;
                    // otherwise the linker strips their static initializers and
                    // whisper reports "backends = 0" and crashes.
                    "-Xlinker", "-force_load", "-Xlinker", "\(ggmlLib)/libggml.dylib",
                ])
            ]
        ),
    ]
)
