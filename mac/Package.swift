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
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CCursorPilotCore",
            path: "Sources/CCursorPilotCore"
        ),
        .executableTarget(
            name: "CursorPilot",
            dependencies: ["CCursorPilotCore"],
            path: "Sources/CursorPilot",
            linkerSettings: [
                .unsafeFlags(["-L", coreLibDir]),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Security"),
                .linkedFramework("Speech"),
                .linkedFramework("WebKit"),
            ]
        ),
    ]
)
