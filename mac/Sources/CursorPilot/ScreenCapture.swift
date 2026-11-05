import AppKit
import ScreenCaptureKit

/// Captures every display (cursor display first in importance, all marked)
/// as downscaled JPEGs, leaving Cursor Pilot's own windows out of the shot.
enum ScreenCapture {
    /// Longest edge of each screenshot sent to Claude.
    static let maxEdge: CGFloat = 1280
    static let maxScreens = 3

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// `includingWindows`: Cursor Pilot windows to keep in the shot (the ink
    /// windows when the user drew something); all its others are left out.
    static func captureAll(includingWindows: [Int] = []) async throws -> [ScreenShotPayload] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let keep = content.windows.filter { includingWindows.contains(Int($0.windowID)) }
        let mouse = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0

        var shots: [ScreenShotPayload] = []
        for screen in NSScreen.screens.prefix(maxScreens) {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  let display = content.displays.first(where: { $0.displayID == number })
            else { continue }

            let frame = screen.frame
            let scale = min(1, maxEdge / max(frame.width, frame.height))
            let config = SCStreamConfiguration()
            config.width = Int((frame.width * scale).rounded())
            config.height = Int((frame.height * scale).rounded())
            config.showsCursor = true
            let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: keep)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard let jpeg = jpegData(image) else { continue }

            shots.append(ScreenShotPayload(
                label: screen.localizedName,
                hasCursor: frame.contains(mouse),
                frame: .init(x: frame.minX, y: primaryHeight - frame.maxY, w: frame.width, h: frame.height),
                imageW: Double(image.width),
                imageH: Double(image.height),
                jpegB64: jpeg.base64EncodedString()
            ))
        }
        return shots
    }

    /// One display at up to `maxEdge` pixels, for saving drawings.
    static func captureImage(of screen: NSScreen, maxEdge: CGFloat, includingWindows: [Int],
                             showsCursor: Bool = false) async throws -> CGImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { return nil }
        let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let keep = content.windows.filter { includingWindows.contains(Int($0.windowID)) }
        let pixels = CGSize(width: screen.frame.width * screen.backingScaleFactor,
                            height: screen.frame.height * screen.backingScaleFactor)
        let scale = min(1, maxEdge / max(pixels.width, pixels.height))
        let config = SCStreamConfiguration()
        config.width = Int((pixels.width * scale).rounded())
        config.height = Int((pixels.height * scale).rounded())
        config.showsCursor = showsCursor
        let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: keep)
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    private static func jpegData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }
}
