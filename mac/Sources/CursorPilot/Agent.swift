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
        // 0 is the main agent; helpers have their own pointers.
        let agent = obj["agent"] as? Int ?? 0
        switch type {
        case "computer":
            let name = obj["name"] as? String ?? ""
            let input = obj["input"] as? [String: Any] ?? [:]
            let result = waitOnMain { await ComputerControl.forAgent(agent).perform(name, input: input) }
            var reply: [String: Any] = ["content": result.content, "is_error": result.isError]
            if let summary = result.summary { reply["summary"] = summary }
            return encode(reply)
        case "messages":
            let input = obj["input"] as? [String: Any] ?? [:]
            let result = waitOnMain { await MessagesTool.perform(input) }
            var reply: [String: Any] = ["content": result.content, "is_error": result.isError]
            if let summary = result.summary { reply["summary"] = summary }
            return encode(reply)
        case "apps":
            let input = obj["input"] as? [String: Any] ?? [:]
            let result = waitOnMain { await ComputerControl.forAgent(agent).appControl(input) }
            var reply: [String: Any] = ["content": result.content, "is_error": result.isError]
            if let summary = result.summary { reply["summary"] = summary }
            return encode(reply)
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

/// Carries out the computer toolset's actions on one display. Screenshots
/// come from ScreenCaptureKit. The mouse is the agent's own: the buddy flies
/// to each point and clicks, typing and scrolling go straight to the app
/// there (`BackgroundInput`), so the user's pointer and keyboard stay theirs.
/// Coordinates are pixels of the screenshots it returns.
///
/// Each agent has one: the main agent's pointer is the buddy, and every
/// helper it sends off gets its own coloured cursor (`HelperCursors`).
@MainActor
final class ComputerControl {
    static let shared = ComputerControl(agent: 0)
    private static var helpers: [Int: ComputerControl] = [:]

    static func forAgent(_ n: Int) -> ComputerControl {
        if n == 0 { return shared }
        if let c = helpers[n] { return c }
        let c = ComputerControl(agent: n)
        helpers[n] = c
        return c
    }

    /// The task is over: every pointer goes home and the helpers' cursors leave.
    static func endAll() {
        shared.endTask()
        helpers.removeAll()
        HelperCursors.shared.dismissAll()
    }

    let agent: Int
    /// This agent's own app_control listing, so helpers' element numbers
    /// don't clash.
    let apps: AppControl

    private init(agent: Int) {
        self.agent = agent
        apps = AppControl(agent: agent)
    }

    /// Longest edge of screenshots sent to Claude.
    static let maxEdge: CGFloat = 1456

    private var screen: NSScreen?
    private var askedForAccessibility = false
    /// Where the agent's pointer is, in global points (nil: where the user's is).
    private var pointer: CGPoint?
    /// The app the agent last clicked in; typing and keys go there.
    private var target: BackgroundInput.Target?
    /// The last click that was posted as events (its effect unknown), so a
    /// repeat at the same spot can fall back to the real pointer.
    private var lastPosted: (point: CGPoint, time: Date)?
    /// Apps that needed the real pointer this task.
    private var realPointerApps: Set<pid_t> = []

    struct Result {
        var content: Any
        var isError: Bool
        var summary: String?
    }

    /// May the agent briefly use the real pointer when an app ignores
    /// background clicks? (Settings › Working on your Mac.)
    static var mayBorrowPointer: Bool { UserDefaults.standard.object(forKey: "borrowPointer") as? Bool ?? true }

    /// A new task works on the display the pointer is on, from the user's cursor.
    func beginTask() {
        screen = nil
        pointer = nil
        target = nil
        lastPosted = nil
        realPointerApps = []
        apps.reset()
    }

    /// The task is over: the buddy goes back to the user's cursor.
    func endTask() {
        if agent == 0 { AppModel.shared.overlay.agentRelease() }
    }

    /// Moves this agent's cursor: the buddy, or the helper's own.
    private func cursorMove(_ p: CGPoint) async {
        if agent == 0 {
            await AppModel.shared.overlay.agentMove(toTopLeft: p)
        } else {
            await HelperCursors.shared.move(agent: agent, toTopLeft: p)
        }
    }

    private func cursorClicked() {
        if agent == 0 { AppModel.shared.overlay.agentClicked() } else { HelperCursors.shared.clicked(agent: agent) }
    }

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

    /// A global point in the screenshot pixels Claude sees.
    func imagePoint(_ p: CGPoint) -> CGPoint { toImage(p) }

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
            let p = toImage(pointer ?? Self.mouseLocation())
            return Result(content: "X=\(Int(p.x)), Y=\(Int(p.y))", isError: false)
        case "wait":
            let d = min(max(input["duration"] as? Double ?? 1, 0), 30)
            try? await Task.sleep(for: .seconds(d))
            return ok()
        default:
            break
        }

        guard Self.hasAccessibility else { return accessibilityMissing() }

        let point = (input["coordinate"] as? [Double]).flatMap { $0.count == 2 ? toGlobal($0[0], $0[1]) : nil }
        let mods = Self.flags(input["text"] as? String ?? "")
        var summary: String?
        var note = "OK"
        switch name {
        case "mouse_move":
            guard let point else { return fail("mouse_move needs a coordinate.") }
            await fly(to: point)
            note = "Moved Cursor Pilot's pointer (the user's pointer didn't move)."
        case "left_click", "right_click", "middle_click", "double_click", "triple_click":
            let at = point ?? pointer ?? Self.mouseLocation()
            await fly(to: at)
            cursorClicked()
            (note, summary) = await click(name, at: at, flags: mods)
        case "left_click_drag":
            guard let start = (input["start_coordinate"] as? [Double]).flatMap({ $0.count == 2 ? toGlobal($0[0], $0[1]) : nil }),
                  let end = point
            else { return fail("left_click_drag needs start_coordinate and coordinate.") }
            await fly(to: start)
            if let win = BackgroundInput.window(at: start) { target = win }
            if Self.mayBorrowPointer {
                // Drags rarely work in the background: borrow the pointer briefly.
                async let flight: Void = cursorMove(end)
                await BackgroundInput.withRealPointer(at: start) { await Self.drag(from: start, to: end, flags: mods) }
                await flight
                note = "Dragged using the real pointer for a moment; it is back where the user left it."
            } else if let win = target {
                async let flight: Void = cursorMove(end)
                await BackgroundInput.postDrag(from: start, to: end, flags: mods, to: win)
                await flight
                note = "Dragged in the background. Check with a screenshot; some apps ignore background drags."
            }
            pointer = end
            summary = "Dragged in \(target?.appName ?? "the app")"
        case "left_mouse_down", "left_mouse_up":
            // Press-and-hold needs the real button; rare enough to borrow it.
            let p = pointer ?? Self.mouseLocation()
            let type: CGEventType = name == "left_mouse_down" ? .leftMouseDown : .leftMouseUp
            if name == "left_mouse_down" { Self.move(to: p) }
            Self.post(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left))
            note = "Used the real pointer for the mouse button."
        case "scroll":
            let at = point ?? pointer ?? Self.mouseLocation()
            await fly(to: at)
            let amount = min(max(input["scroll_amount"] as? Int ?? 3, 1), 30)
            let dir = input["scroll_direction"] as? String ?? "down"
            let dy = dir == "down" ? amount : dir == "up" ? -amount : 0
            let dx = dir == "right" ? amount : dir == "left" ? -amount : 0
            guard let win = BackgroundInput.window(at: at) else { return fail("Nothing to scroll there.") }
            target = win
            if Self.mayBorrowPointer, BackgroundInput.needsRealPointer(win.pid) { realPointerApps.insert(win.pid) }
            if !mods.isEmpty || realPointerApps.contains(win.pid) {
                await BackgroundInput.withRealPointer(at: at) {
                    let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                                    wheel1: Int32(-dy * 3), wheel2: Int32(-dx * 3), wheel3: 0)
                    e?.flags = mods
                    Self.post(e)
                }
            } else if !BackgroundInput.scroll(at: at, in: win, dx: dx, dy: dy) {
                note = "Scrolled in the background with wheel events; check with a screenshot that it moved."
            }
            summary = "Scrolled \(dir) in \(win.appName)"
        case "type":
            let text = input["text"] as? String ?? ""
            if let pid = keyboardTarget() {
                await BackgroundInput.type(text, pid: pid)
                note = "Typed into \(target?.appName ?? "the app") in the background."
            } else {
                await RealInput.exclusive { await Self.type(text) }
            }
        case "key", "hold_key":
            let combo = input["text"] as? String ?? ""
            let times = name == "key" ? min(max(input["repeat"] as? Int ?? 1, 1), 100) : 1
            let hold = name == "hold_key" ? min(max(input["duration"] as? Double ?? 1, 0), 10) : 0
            // System shortcuts (Spotlight, app switching, spaces, screenshots)
            // belong to macOS, not the app: they need the real keyboard.
            let pid = Self.isSystemShortcut(combo) ? nil : keyboardTarget()
            for _ in 0..<times {
                let pressed: Bool
                if let pid {
                    pressed = await Self.press(combo, hold: hold, pid: pid)
                } else {
                    pressed = await RealInput.exclusive { await Self.press(combo, hold: hold, pid: nil) }
                }
                guard pressed else { return fail("Unknown key: \(combo)") }
            }
        default:
            return fail("Unknown computer action: \(name)")
        }
        // Let the app react before the next action or screenshot.
        try? await Task.sleep(for: .milliseconds(140))
        return Result(content: note, isError: false, summary: summary)
    }

    /// The `app_control` tool, with the buddy flying to what it used.
    func appControl(_ input: [String: Any]) async -> AppControl.Result {
        guard Self.hasAccessibility else {
            let r = accessibilityMissing()
            return AppControl.Result(content: r.content as? String ?? "", isError: true)
        }
        if NSApp.isActive || HomeWindow.shared.isVisible { NSApp.hide(nil) }
        let result = await apps.perform(input)
        if let p = result.point, NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -2, dy: -2).contains(NSPoint(x: p.x, y: (NSScreen.screens.first?.frame.height ?? 0) - p.y)) }) {
            await fly(to: p)
            if !result.isError { cursorClicked() }
            if let win = BackgroundInput.window(at: p) { target = win }
        }
        return result
    }

    private func accessibilityMissing() -> Result {
        if !askedForAccessibility {
            askedForAccessibility = true
            Self.requestAccessibility()
        }
        return Result(content: "Cursor Pilot needs Accessibility permission to use the mouse and keyboard. Tell the user to allow it in System Settings › Privacy & Security › Accessibility. If Cursor Pilot is already switched on there, that entry belongs to an older build: they should remove it with the minus button, then allow Cursor Pilot again. Then try again.",
                      isError: true)
    }

    /// Moves the agent's pointer (the buddy) to `p`.
    private func fly(to p: CGPoint) async {
        if pointer == nil { pointer = Self.mouseLocation() }
        await cursorMove(p)
        pointer = p
    }

    /// Where typing goes: the app the agent works in, in the background.
    /// Nil when that app is in front anyway (or unknown), so the real
    /// keyboard is used, which every app understands.
    private func keyboardTarget() -> pid_t? {
        guard let pid = target?.pid, pid != NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return pid
    }

    /// One click by the agent. Background first: an Accessibility action on
    /// the control, or events sent to the app. A repeat at the same spot
    /// after posted events (which an app may ignore) borrows the real pointer.
    private func click(_ name: String, at p: CGPoint, flags: CGEventFlags) async -> (String, String?) {
        guard let win = BackgroundInput.window(at: p) else {
            await realClick(name, at: p, flags: flags)
            return ("Clicked with the real pointer (no app window there).", "Clicked")
        }
        target = win
        if Self.mayBorrowPointer, BackgroundInput.needsRealPointer(win.pid) { realPointerApps.insert(win.pid) }
        let repeated = lastPosted.map { hypot($0.point.x - p.x, $0.point.y - p.y) < 8 && Date().timeIntervalSince($0.time) < 45 } ?? false
        let plain = name == "left_click" && flags.isEmpty

        if plain, !realPointerApps.contains(win.pid), let outcome = BackgroundInput.click(at: p, in: win, semanticOnly: true) {
            lastPosted = nil
            return describe(outcome, in: win)
        }
        if Self.mayBorrowPointer && (repeated || realPointerApps.contains(win.pid)) {
            if repeated { realPointerApps.insert(win.pid) }
            lastPosted = nil
            await realClick(name, at: p, flags: flags)
            return ("Clicked in \(win.appName) using the real pointer for a moment (it ignores background clicks); the pointer is back where the user left it.",
                    "Clicked in \(win.appName)")
        }
        let outcome: BackgroundInput.Outcome
        switch name {
        case "right_click":
            outcome = BackgroundInput.rightClick(at: p, in: win)
        case "left_click" where flags.isEmpty:
            outcome = BackgroundInput.click(at: p, in: win) ?? .posted
        default:
            let button: CGMouseButton = name == "middle_click" ? .center : .left
            let count = name == "double_click" ? 2 : name == "triple_click" ? 3 : 1
            BackgroundInput.postClick(at: p, button: button, count: count, flags: flags, to: win)
            outcome = .posted
        }
        if case .posted = outcome { lastPosted = (p, Date()) } else { lastPosted = nil }
        return describe(outcome, in: win)
    }

    private func describe(_ outcome: BackgroundInput.Outcome, in win: BackgroundInput.Target) -> (String, String?) {
        switch outcome {
        case .pressed(let what):
            return ("Pressed the \(what) in \(win.appName), in the background.", "Clicked the \(what)")
        case .focused(let what):
            return ("Clicked into the \(what) in \(win.appName); typing goes there now.", "Clicked the \(what)")
        case .posted:
            let borrow = Self.mayBorrowPointer
                ? " If a screenshot shows it had no effect, click the same spot again: the second try uses the real pointer."
                : ""
            return ("Clicked in \(win.appName) in the background, without moving the user's pointer.\(borrow)",
                    "Clicked in \(win.appName)")
        }
    }

    private func realClick(_ name: String, at p: CGPoint, flags: CGEventFlags) async {
        let button: CGMouseButton = name == "right_click" ? .right : name == "middle_click" ? .center : .left
        let count = name == "double_click" ? 2 : name == "triple_click" ? 3 : 1
        await BackgroundInput.withRealPointer(at: p) {
            await Self.click(at: p, button: button, count: count, flags: flags)
        }
    }

    private static func isSystemShortcut(_ combo: String) -> Bool {
        let c = combo.lowercased().replacingOccurrences(of: " ", with: "")
        let system = ["cmd+space", "super+space", "command+space", "cmd+tab", "super+tab", "command+tab",
                      "ctrl+left", "ctrl+right", "ctrl+up", "ctrl+down", "control+left", "control+right",
                      "control+up", "control+down", "cmd+shift+3", "cmd+shift+4", "cmd+shift+5",
                      "super+shift+3", "super+shift+4", "super+shift+5", "ctrl+cmd+q", "ctrl+super+q"]
        return system.contains(c)
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
            guard let image = try await ScreenCapture.captureImage(of: s, maxEdge: Self.maxEdge, includingWindows: [], showsCursor: false)
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
            guard let full = try await ScreenCapture.captureImage(of: s, maxEdge: 6000, includingWindows: [], showsCursor: false)
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
    /// "super+shift+4", optionally holding it, on the real keyboard or (with
    /// `pid`) sent only to that app. False when a key is unknown.
    private static func press(_ combo: String, hold: Double = 0, pid: pid_t? = nil) async -> Bool {
        let parts = combo.split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, let key = keyCode(last) else { return false }
        var flags: CGEventFlags = []
        var modKeys: [(Int, CGEventFlags)] = []
        for p in parts.dropLast() {
            guard let m = modifier(p) else { return false }
            flags.insert(m.1)
            modKeys.append((m.0, flags))
        }
        // Background keys use a private source so the user's own modifier
        // keys don't leak into them.
        let source = pid == nil ? nil : CGEventSource(stateID: .privateState)
        func send(_ code: Int, down: Bool, _ f: CGEventFlags) {
            let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)
            e?.flags = f
            if let pid { e?.postToPid(pid) } else { e?.post(tap: .cghidEventTap) }
        }
        for (code, f) in modKeys { send(code, down: true, f) }
        send(key, down: true, flags)
        if hold > 0 { try? await Task.sleep(for: .seconds(hold)) }
        send(key, down: false, flags)
        for (code, _) in modKeys.reversed() { send(code, down: false, []) }
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
