// swift-tools-version:5.9
import PackageDescription

let whisperInclude = "/opt/homebrew/opt/whisper-cpp/include"
let whisperLib = "/opt/homebrew/opt/whisper-cpp/lib"
let ggmlInclude = "/opt/homebrew/opt/ggml/include"
let ggmlLib = "/opt/homebrew/opt/ggml/lib"

let package = Package(
    name: "pushtalk",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(name: "CWhisper", path: "Sources/CWhisper"),
        .executableTarget(
            name: "pushtalk",
            dependencies: ["CWhisper"],
            exclude: ["Resources"],
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
                    "-Xlinker", "-force_load", "-Xlinker", "\(ggmlLib)/libggml.dylib",
                ]),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AppKit"),
            ]
        ),
    ]
)
