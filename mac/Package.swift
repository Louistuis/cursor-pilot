// swift-tools-version:5.10
import Foundation
import PackageDescription

// The Rust core is built first (see scripts/build-app.sh) as a static
// library. CP_CORE_LIB_DIR points at the folder holding libcursor_pilot_core.a;
// by default that is core/target/release.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let coreLibDir = ProcessInfo.processInfo.environment["CP_CORE_LIB_DIR"]
    ?? packageDir.appendingPathComponent("../core/target/release").standardized.path

let package = Package(
    name: "CursorPilot",
    platforms: [.macOS("15.0")],
    dependencies: [
        // On-device speech: Whisper (hearing) and Kokoro (speaking) on the
        // Neural Engine. Only these CoreML targets are built.
        .package(url: "https://github.com/soniqo/speech-swift", revision: "a57702e6f523fa36ac5532d2bdc5f35f701a052c"),
    ],
    targets: [
        .target(
            name: "CCursorPilotCore",
            path: "Sources/CCursorPilotCore"
        ),
        .executableTarget(
            name: "CursorPilot",
            dependencies: [
                "CCursorPilotCore",
                .product(name: "WhisperASR", package: "speech-swift"),
                .product(name: "KokoroTTS", package: "speech-swift"),
            ],
            path: "Sources/CursorPilot",
            linkerSettings: [
                .unsafeFlags(["-L", coreLibDir]),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("Charts"),
                .linkedFramework("LinkPresentation"),
                .linkedFramework("SceneKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Security"),
                .linkedFramework("Speech"),
                .linkedFramework("WebKit"),
            ]
        ),
    ]
)
