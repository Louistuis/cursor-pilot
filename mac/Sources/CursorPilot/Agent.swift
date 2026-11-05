import AppKit
import ApplicationServices
import CCursorPilotCore
import Carbon
import SwiftUI

// MARK: - Host

/// Answers the core's agent requests (`agent::Host` in Rust). Called on the
/// request's background thread; it blocks there while an action runs on the
/// main thread.
final class AgentHost: @unchecked Sendable {
    static let shared = AgentHost()

    func handle(_ json: String) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let type = obj["type"] as? String
        else { return "{}" }
        switch type {
        case "computer":
            let name = obj["name"] as? String ?? ""
            let input = obj["input"] as? [String: Any] ?? [:]
            let result = waitOnMain { await ComputerControl.shared.perform(name, input: input) }
            return encode(["content": result.content, "is_error": result.isError])
        default:
            return "{}"
        }
    }

    /// Runs `work` on the main actor and blocks this (background) thread
    /// until it finishes.
    private func waitOnMain<T>(_ work: @escaping @MainActor () async -> T) -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            box.value = await work()
            done.signal()
        }
        done.wait()
        return box.value!
    }

    private func encode(_ obj: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: obj)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

let coreHostCallback: CPHostCallback = { _, json in
    guard let json else { return nil }
    return strdup(AgentHost.shared.handle(String(cString: json)))
}

// MARK: - Computer control

/// Carries out the computer toolset's actions on one display: screenshots
/// through ScreenCaptureKit, mouse and keyboard through CGEvent (which needs
/// Accessibility permission). Coordinates are pixels of the screenshots it
/// returns.
@MainActor
final class ComputerControl {
    static let shared = ComputerControl()

    /// Longest edge of screenshots sent to Claude.
    static let maxEdge: CGFloat = 1456

    private var screen: NSScreen?
    private var askedForAccessibility = false

    struct Result {
        var content: Any
        var isError: Bool
    }

    /// A new task works on the display the pointer is on.
    func beginTask() { screen = nil }

    nonisolated static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private func activeScreen() -> NSScreen {
        if let screen, NSScreen.screens.contains(screen) { return screen }
        let mouse = NSEvent.mouseLocation
        let s = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        screen = s
        return s
    }

    /// Screenshot size in pixels for `screen`, the coordinate space Claude uses.
    private func imageSize(_ s: NSScreen) -> CGSize {
        let px = CGSize(width: s.frame.width * s.backingScaleFactor, height: s.frame.height * s.backingScaleFactor)
        let k = min(1, Self.maxEdge / max(px.width, px.height))
        return CGSize(width: (px.width * k).rounded(), height: (px.height * k).rounded())
    }

    /// Screenshot pixels → global Quartz points (top-left origin).
    private func toGlobal(_ x: Double, _ y: Double) -> CGPoint {
        let s = activeScreen()
        let size = imageSize(s)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? s.frame.height
        let top = primaryHeight - s.frame.maxY
        let cx = min(max(x, 0), Double(size.width - 1)), cy = min(max(y, 0), Double(size.height - 1))
        return CGPoint(x: s.frame.minX + cx * s.frame.width / size.width,
                       y: top + cy * s.frame.height / size.height)
    }

    private func toImage(_ p: CGPoint) -> CGPoint {
        let s = activeScreen()
        let size = imageSize(s)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? s.frame.height
        let top = primaryHeight - s.frame.maxY
        return CGPoint(x: ((p.x - s.frame.minX) * size.width / s.frame.width).rounded(),
                       y: ((p.y - top) * size.height / s.frame.height).rounded())
    }

    func perform(_ name: String, input: [String: Any]) async -> Result {
        // Our own windows aren't in the screenshots, so they must not be in
        // the way of clicks either: step aside while the agent works.
        if NSApp.isActive || HomeWindow.shared.isVisible { NSApp.hide(nil) }

        switch name {
        case "screenshot":
            return await screenshot()
        case "zoom":
            return await zoom(input["region"] as? [Double] ?? [])
        case "cursor_position":
            let p = toImage(Self.mouseLocation())
            return Result(content: "X=\(Int(p.x)), Y=\(Int(p.y))", isError: false)
        case "wait":
            let d = min(max(input["duration"] as? Double ?? 1, 0), 30)
            try? await Task.sleep(for: .seconds(d))
            return ok()
        default:
            break
        }

        guard Self.hasAccessibility else {
            if !askedForAccessibility {
                askedForAccessibility = true
                Self.requestAccessibility()
            }
            return Result(content: "Cursor Pilot needs Accessibility permission to use the mouse and keyboard. Tell the user to allow it in System Settings › Privacy & Security › Accessibility, then try again.",
                          isError: true)
        }

        let point = (input["coordinate"] as? [Double]).flatMap { $0.count == 2 ? toGlobal($0[0], $0[1]) : nil }
        let mods = Self.flags(input["text"] as? String ?? "")
        switch name {
        case "mouse_move":
            guard let point else { return fail("mouse_move needs a coordinate.") }
            Self.move(to: point)
        case "left_click", "right_click", "middle_click", "double_click", "triple_click":
            let target = point ?? Self.mouseLocation()
            let button: CGMouseButton = name == "right_click" ? .right : name == "middle_click" ? .center : .left
            let count = name == "double_click" ? 2 : name == "triple_click" ? 3 : 1
            Self.move(to: target)
            try? await Task.sleep(for: .milliseconds(30))
            await Self.click(at: target, button: button, count: count, flags: mods)
        case "left_click_drag":
            guard let start = (input["start_coordinate"] as? [Double]).flatMap({ $0.count == 2 ? toGlobal($0[0], $0[1]) : nil }),
                  let end = point
            else { return fail("left_click_drag needs start_coordinate and coordinate.") }
            await Self.drag(from: start, to: end, flags: mods)
        case "left_mouse_down", "left_mouse_up":
            let p = Self.mouseLocation()
            let type: CGEventType = name == "left_mouse_down" ? .leftMouseDown : .leftMouseUp
            Self.post(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left))
        case "scroll":
            if let point { Self.move(to: point) }
            let amount = Int32(min(max(input["scroll_amount"] as? Int ?? 3, 1), 30)) * 3
            let dir = input["scroll_direction"] as? String ?? "down"
            let dy: Int32 = dir == "up" ? amount : dir == "down" ? -amount : 0
            let dx: Int32 = dir == "left" ? amount : dir == "right" ? -amount : 0
            let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
            e?.flags = mods
            Self.post(e)
        case "type":
            await Self.type(input["text"] as? String ?? "")
        case "key":
            let combo = input["text"] as? String ?? ""
            let times = min(max(input["repeat"] as? Int ?? 1, 1), 100)
            for _ in 0..<times {
                guard await Self.press(combo) else { return fail("Unknown key: \(combo)") }
            }
        case "hold_key":
            let combo = input["text"] as? String ?? ""
            let d = min(max(input["duration"] as? Double ?? 1, 0), 10)
            guard await Self.press(combo, hold: d) else { return fail("Unknown key: \(combo)") }
        default:
            return fail("Unknown computer action: \(name)")
        }
        // Let the app on screen react before the next action or screenshot.
        try? await Task.sleep(for: .milliseconds(140))
        return ok()
    }

    private func ok() -> Result { Result(content: "OK", isError: false) }
    private func fail(_ s: String) -> Result { Result(content: s, isError: true) }

    private func screenshot() async -> Result {
        guard ScreenCapture.hasPermission else {
            return fail("Cursor Pilot doesn't have Screen Recording permission. Tell the user to allow it in Cursor Pilot's Settings › Permissions.")
        }
        let s = activeScreen()
        do {
            try? await Task.sleep(for: .milliseconds(60)) // let a hide/animation finish
            guard let image = try await ScreenCapture.captureImage(of: s, maxEdge: Self.maxEdge, includingWindows: [], showsCursor: true)
            else { return fail("Couldn't capture the screen.") }
            return Result(content: [Self.imageBlock(image)], isError: false)
        } catch {
            return fail("Couldn't capture the screen: \(error.localizedDescription)")
        }
    }

    private func zoom(_ region: [Double]) async -> Result {
        guard region.count == 4, region[2] > region[0], region[3] > region[1] else {
            return fail("zoom needs region [x0, y0, x1, y1] with x1 > x0 and y1 > y0.")
        }
        let s = activeScreen()
        let size = imageSize(s)
        do {
            guard let full = try await ScreenCapture.captureImage(of: s, maxEdge: 6000, includingWindows: [], showsCursor: true)
            else { return fail("Couldn't capture the screen.") }
            let k = CGFloat(full.width) / size.width
            let rect = CGRect(x: region[0] * k, y: region[1] * k, width: (region[2] - region[0]) * k, height: (region[3] - region[1]) * k)
                .intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
            guard let crop = full.cropping(to: rect.integral) else { return fail("That region is off the screen.") }
            return Result(content: [Self.imageBlock(Self.fit(crop, maxEdge: Self.maxEdge))], isError: false)
        } catch {
            return fail("Couldn't capture the screen: \(error.localizedDescription)")
        }
    }

    private static func imageBlock(_ image: CGImage) -> [String: Any] {
        let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.82]) ?? Data()
        return ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]]
    }

    private static func fit(_ image: CGImage, maxEdge: CGFloat) -> CGImage {
        let k = min(1, maxEdge / CGFloat(max(image.width, image.height)))
        guard k < 1 else { return image }
        let w = Int(CGFloat(image.width) * k), h = Int(CGFloat(image.height) * k)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    // MARK: Events

    private static func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap) }

    /// Current pointer position in global Quartz points.
    private static func mouseLocation() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private static func move(to p: CGPoint) {
        post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left))
    }

    private static func click(at p: CGPoint, button: CGMouseButton, count: Int, flags: CGEventFlags) async {
        let (down, up): (CGEventType, CGEventType) = switch button {
        case .right: (.rightMouseDown, .rightMouseUp)
        case .center: (.otherMouseDown, .otherMouseUp)
        default: (.leftMouseDown, .leftMouseUp)
        }
        for n in 1...count {
            for type in [down, up] {
                let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)
                e?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                e?.flags = flags
                post(e)
            }
            if n < count { try? await Task.sleep(for: .milliseconds(40)) }
        }
    }

    private static func drag(from a: CGPoint, to b: CGPoint, flags: CGEventFlags) async {
        move(to: a)
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: a, mouseButton: .left)
        down?.flags = flags
        post(down)
        let steps = 16
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            let e = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)
            e?.flags = flags
            post(e)
            try? await Task.sleep(for: .milliseconds(15))
        }
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: b, mouseButton: .left)
        up?.flags = flags
        post(up)
    }

    private static func type(_ text: String) async {
        // Newlines and tabs as real key presses; everything else as Unicode
        // in small chunks, so any character and keyboard layout works.
        var chunk: [UniChar] = []
        func flush() {
            guard !chunk.isEmpty else { return }
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                post(e)
            }
            chunk.removeAll()
        }
        for ch in text {
            if ch == "\n" || ch == "\t" {
                flush()
                tap(key: ch == "\n" ? kVK_Return : kVK_Tab, flags: [])
            } else {
                chunk.append(contentsOf: Array(String(ch).utf16))
                if chunk.count >= 16 { flush() }
            }
            if chunk.isEmpty { try? await Task.sleep(for: .milliseconds(8)) }
        }
        flush()
    }

    private static func tap(key: Int, flags: CGEventFlags) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: down)
            e?.flags = flags
            post(e)
        }
    }

    /// Presses an xdotool-style combination such as "Return", "ctrl+s" or
    /// "super+shift+4", optionally holding it. False when a key is unknown.
    private static func press(_ combo: String, hold: Double = 0) async -> Bool {
        let parts = combo.split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, let key = keyCode(last) else { return false }
        var flags: CGEventFlags = []
        var modKeys: [(Int, CGEventFlags)] = []
        for p in parts.dropLast() {
            guard let m = modifier(p) else { return false }
            flags.insert(m.1)
            modKeys.append((m.0, flags))
        }
        for (code, f) in modKeys {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true)
            e?.flags = f
            post(e)
        }
        let down = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: true)
        down?.flags = flags
        post(down)
        if hold > 0 { try? await Task.sleep(for: .seconds(hold)) }
        let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: false)
        up?.flags = flags
        post(up)
        for (code, _) in modKeys.reversed() {
            post(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: false))
        }
        try? await Task.sleep(for: .milliseconds(20))
        return true
    }

    static func flags(_ text: String) -> CGEventFlags {
        var f: CGEventFlags = []
        for p in text.split(separator: "+") {
            if let m = modifier(String(p).trimmingCharacters(in: .whitespaces)) { f.insert(m.1) }
        }
        return f
    }

    private static func modifier(_ name: String) -> (Int, CGEventFlags)? {
        switch name.lowercased() {
        case "ctrl", "control", "control_l", "control_r": (kVK_Control, .maskControl)
        case "alt", "option", "opt", "alt_l", "alt_r": (kVK_Option, .maskAlternate)
        case "shift", "shift_l", "shift_r": (kVK_Shift, .maskShift)
        case "super", "cmd", "command", "meta", "super_l", "super_r", "win": (kVK_Command, .maskCommand)
        case "fn": (kVK_Function, .maskSecondaryFn)
        default: nil
        }
    }

    private static func keyCode(_ name: String) -> Int? {
        if name.count == 1, let c = name.lowercased().first, let code = charCodes[c] { return code }
        return namedCodes[name.lowercased()]
    }

    private static let charCodes: [Character: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
        ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
        "/": kVK_ANSI_Slash, "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave, " ": kVK_Space,
    ]

    private static let namedCodes: [String: Int] = [
        "return": kVK_Return, "enter": kVK_Return, "kp_enter": kVK_ANSI_KeypadEnter, "tab": kVK_Tab,
        "space": kVK_Space, "backspace": kVK_Delete, "delete": kVK_ForwardDelete, "escape": kVK_Escape,
        "esc": kVK_Escape, "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow,
        "down": kVK_DownArrow, "home": kVK_Home, "end": kVK_End, "page_up": kVK_PageUp, "pageup": kVK_PageUp,
        "prior": kVK_PageUp, "page_down": kVK_PageDown, "pagedown": kVK_PageDown, "next": kVK_PageDown,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6, "f7": kVK_F7,
        "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
        "minus": kVK_ANSI_Minus, "equal": kVK_ANSI_Equal, "comma": kVK_ANSI_Comma, "period": kVK_ANSI_Period,
        "slash": kVK_ANSI_Slash, "semicolon": kVK_ANSI_Semicolon, "apostrophe": kVK_ANSI_Quote,
        "bracketleft": kVK_ANSI_LeftBracket, "bracketright": kVK_ANSI_RightBracket, "grave": kVK_ANSI_Grave,
        "backslash": kVK_ANSI_Backslash, "capslock": kVK_CapsLock, "caps_lock": kVK_CapsLock,
        "volumeup": kVK_VolumeUp, "volumedown": kVK_VolumeDown, "mute": kVK_Mute,
    ]
}
