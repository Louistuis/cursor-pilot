import AppKit
import Carbon

/// The user's own mouse and keyboard, driven the way a person would: the
/// pointer glides on a slightly curved path that eases in and out (quicker
/// for short hops, with a small correction at the end of long ones),
/// clicks are pressed and released, and typing has a human rhythm.
///
/// The user can take over at any moment by moving the mouse or typing:
/// the agent notices the pointer isn't where it left it, and waits until
/// they have been still for a moment before it goes on.
@MainActor
enum HumanInput {
    /// Where the agent last left the pointer; elsewhere means the user moved it.
    private static var placed: CGPoint?

    /// Our events come from their own source, so the user's held modifier
    /// keys don't leak into them and their idle time stays theirs.
    private static let source: CGEventSource? = CGEventSource(stateID: .combinedSessionState)

    static var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    /// Bumped when the task is stopped: text being typed ends where it is
    /// and a wait for the user is over, instead of carrying on after Stop.
    private static var stops = 0
    static func stop() { stops += 1 }

    // MARK: Taking turns

    /// Has the user moved the pointer since the agent last did?
    static var userTookOver: Bool {
        guard let placed else { return false }
        return hypot(location.x - placed.x, location.y - placed.y) > 3
    }

    /// Waits until the user has left the mouse and keyboard alone for a
    /// moment (up to two minutes). False when they kept going.
    static func waitForUser() async -> Bool {
        let overlay = AppModel.shared.overlay
        overlay.state.activity = "You've got it. I'll wait"
        defer { overlay.state.activity = nil }
        let deadline = Date().addingTimeInterval(120)
        let began = stops
        while Date() < deadline, stops == began {
            let idle = [CGEventType.mouseMoved, .leftMouseDown, .keyDown, .scrollWheel, .leftMouseDragged]
                .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
                .min() ?? 99
            if idle > 1.4 {
                placed = location
                return true
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return false
    }

    /// Forgets where the pointer was left, at the start of a task.
    static func reset() { placed = nil }

    // MARK: Pointer

    /// Glides the pointer to `p` (global top-left points). `dragging` moves
    /// with the left button held.
    static func move(to p: CGPoint, dragging: Bool = false) async {
        let a = location
        let d = hypot(p.x - a.x, p.y - a.y)
        guard d > 1 else {
            placed = p
            return
        }
        // A long move aims a touch past or short of the target, then corrects.
        var aim = p
        if d > 320 {
            let k = CGFloat.random(in: -0.025...0.03)
            aim = CGPoint(x: p.x + (p.x - a.x) * k + .random(in: -3...3), y: p.y + (p.y - a.y) * k + .random(in: -3...3))
        }
        await glide(from: a, to: aim, dragging: dragging)
        if aim != p { await glide(from: aim, to: p, dragging: dragging, quick: true) }
        placed = p
    }

    private static func glide(from a: CGPoint, to b: CGPoint, dragging: Bool, quick: Bool = false) async {
        let d = hypot(b.x - a.x, b.y - a.y)
        // Fitts-like: longer moves take longer, but not proportionally.
        let base = quick ? 0.07 + 0.01 * log2(1 + d / 8) : 0.16 + 0.085 * log2(1 + d / 10)
        let duration = min(max(base * Double.random(in: 0.9...1.12), 0.06), 0.85)
        // A gentle arc to one side, as a wrist makes.
        let bend = CGFloat.random(in: -0.12...0.12) * min(d, 500)
        let n = CGPoint(x: -(b.y - a.y) / max(d, 1), y: (b.x - a.x) / max(d, 1))
        let c1 = CGPoint(x: a.x + (b.x - a.x) * 0.3 + n.x * bend, y: a.y + (b.y - a.y) * 0.3 + n.y * bend)
        let c2 = CGPoint(x: a.x + (b.x - a.x) * 0.7 + n.x * bend * 0.6, y: a.y + (b.y - a.y) * 0.7 + n.y * bend * 0.6)
        let start = CACurrentMediaTime()
        while true {
            let t = min(1, (CACurrentMediaTime() - start) / duration)
            // Minimum-jerk easing: the way hands speed up and settle.
            let e = CGFloat(t * t * t * (10 - 15 * t + 6 * t * t))
            let u = 1 - e
            let p = CGPoint(x: u * u * u * a.x + 3 * u * u * e * c1.x + 3 * u * e * e * c2.x + e * e * e * b.x,
                            y: u * u * u * a.y + 3 * u * u * e * c1.y + 3 * u * e * e * c2.y + e * e * e * b.y)
            post(CGEvent(mouseEventSource: source, mouseType: dragging ? .leftMouseDragged : .mouseMoved,
                         mouseCursorPosition: p, mouseButton: .left))
            if t >= 1 { break }
            try? await Task.sleep(for: .milliseconds(8))
        }
    }

    /// Moves to `p` and clicks there like a hand would.
    static func click(at p: CGPoint, button: CGMouseButton = .left, count: Int = 1, flags: CGEventFlags = []) async {
        await move(to: p)
        try? await Task.sleep(for: .milliseconds(Int.random(in: 35...80)))
        let (down, up): (CGEventType, CGEventType) = switch button {
        case .right: (.rightMouseDown, .rightMouseUp)
        case .center: (.otherMouseDown, .otherMouseUp)
        default: (.leftMouseDown, .leftMouseUp)
        }
        for n in 1...max(count, 1) {
            for type in [down, up] {
                let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
                e?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                e?.flags = flags
                post(e)
                if type == down { try? await Task.sleep(for: .milliseconds(Int.random(in: 45...95))) }
            }
            if n < count { try? await Task.sleep(for: .milliseconds(Int.random(in: 70...110))) }
        }
    }

    static func drag(from a: CGPoint, to b: CGPoint, flags: CGEventFlags = []) async {
        await move(to: a)
        try? await Task.sleep(for: .milliseconds(60))
        let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: a, mouseButton: .left)
        down?.flags = flags
        post(down)
        try? await Task.sleep(for: .milliseconds(120))
        await move(to: b, dragging: true)
        try? await Task.sleep(for: .milliseconds(90))
        let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: b, mouseButton: .left)
        up?.flags = flags
        post(up)
    }

    /// Scrolls over `p` in small steps, as a wheel or trackpad does.
    static func scroll(at p: CGPoint, dx: Int, dy: Int, flags: CGEventFlags = []) async {
        await move(to: p)
        let steps = max(abs(dy), abs(dx)) * 3
        for i in 0..<steps {
            let e = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
                            wheel1: Int32(-dy.signum()), wheel2: Int32(-dx.signum()), wheel3: 0)
            e?.flags = flags
            post(e)
            // Quick at first, easing off, like a flick.
            try? await Task.sleep(for: .milliseconds(10 + i * 14 / max(steps, 1)))
        }
    }

    // MARK: Keyboard

    /// Types `text` into the app in front with a person's rhythm, faster
    /// for long text so it never drags on.
    static func type(_ text: String) async {
        let long = text.count > 120
        var sinceBreak = 0
        let began = stops
        for ch in text {
            guard stops == began else { return }
            if ch == "\n" || ch == "\t" {
                tap(ch == "\n" ? kVK_Return : kVK_Tab)
            } else {
                let units = Array(String(ch).utf16)
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                    e?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                    post(e)
                }
            }
            sinceBreak += 1
            var pause = long ? Int.random(in: 8...22) : Int.random(in: 28...85)
            if !long, " ,.!?".contains(ch) { pause += Int.random(in: 20...70) }
            if !long, sinceBreak > Int.random(in: 14...28) {
                pause += Int.random(in: 90...220)
                sinceBreak = 0
            }
            try? await Task.sleep(for: .milliseconds(pause))
        }
    }

    static func tap(_ key: Int, flags: CGEventFlags = []) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: down)
            e?.flags = flags
            post(e)
        }
    }

    /// Brings an app to the front the way switching to it would, for a
    /// click in a window that isn't active.
    static func bringForward(_ pid: pid_t) async {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != pid else { return }
        AXUIElementSetAttributeValue(BackgroundInput.app(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        try? await Task.sleep(for: .milliseconds(160))
    }

    /// Marks the agent's own events, so they can be told from the user's.
    static let marker: Int64 = 0x4350_494C // "CPIL"

    private static func post(_ e: CGEvent?) {
        guard let e else { return }
        e.setIntegerValueField(.eventSourceUserData, value: marker)
        if e.type != .keyDown, e.type != .keyUp, e.type != .flagsChanged { CursorTakeover.touch() }
        e.post(tap: .cghidEventTap)
    }
}

/// While the agent moves the real pointer, the system cursor turns into the
/// buddy: macOS's arrow is hidden and the buddy's tip sits on the pointer.
/// The arrow comes back the moment the user moves the mouse, and once the
/// agent has left the pointer alone for a moment.
@MainActor
enum CursorTakeover {
    private(set) static var hidden = false
    private static var hides = 0
    private static var lastHide: CFTimeInterval = 0
    private static var release: Task<Void, Never>?
    private static var monitor: Any?
    /// How long after the agent's last pointer event the arrow comes back.
    private static let linger: Double = 1.4

    /// The agent is using the pointer now.
    static func touch() {
        release?.cancel()
        release = Task {
            try? await Task.sleep(for: .seconds(linger))
            guard !Task.isCancelled else { return }
            end()
        }
        guard AppModel.shared.showBuddy else { return }
        // Apps in front (a video player, say) show the cursor again on their
        // own as it moves, so keep hiding it while the agent moves it. Every
        // hide is counted and undone when the user gets it back.
        let now = CACurrentMediaTime()
        if hidden {
            if now - lastHide > 0.05 {
                lastHide = now
                CGDisplayHideCursor(CGMainDisplayID())
                hides += 1
            }
            return
        }
        hidden = true
        lastHide = now
        WindowServer.allowCursorHidingInBackground()
        CGDisplayHideCursor(CGMainDisplayID())
        hides = 1
        AppModel.shared.overlay.takeCursor(true)
        // The user's own hand on the mouse gets their arrow back at once.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown,
                                                               .leftMouseDragged, .scrollWheel]) { event in
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != HumanInput.marker else { return }
            Task { @MainActor in end() }
        }
    }

    /// Gives the user back their own arrow.
    static func end() {
        release?.cancel()
        release = nil
        guard hidden else { return }
        hidden = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for _ in 0..<hides { CGDisplayShowCursor(CGMainDisplayID()) }
        hides = 0
        AppModel.shared.overlay.takeCursor(false)
    }
}

/// The window server lets only the app in front hide the cursor, unless the
/// connection says it may from the background (as cursor utilities do).
@_silgen_name("_CGSDefaultConnection") private func cgsDefaultConnection() -> Int32
@_silgen_name("CGSSetConnectionProperty")
private func cgsSetConnectionProperty(_ cid: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

@MainActor
private enum WindowServer {
    private static var done = false
    static func allowCursorHidingInBackground() {
        guard !done else { return }
        done = true
        let cid = cgsDefaultConnection()
        _ = cgsSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}
