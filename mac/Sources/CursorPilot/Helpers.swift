import AppKit
import Combine
import SwiftUI

/// Helper agents' names in the order the core hands them out
/// (`agent::HELPERS`); each is also the colour of its cursor.
let helperNames = ["Mint", "Sunset", "Rose", "Violet", "Ocean"]

/// Background tasks are agents from 100 (`agent::JOB_BASE`); they outlive
/// the request that started them.
func isJob(_ agent: Int) -> Bool { agent >= 100 }

/// An agent's name and colour: helpers in order, background tasks from the
/// end (`agent::job_name`).
func agentName(_ agent: Int) -> String {
    isJob(agent) ? helperNames[helperNames.count - 1 - (agent - 100) % helperNames.count]
        : helperNames[max(0, min(agent - 1, helperNames.count - 1))]
}

/// A task the agent handed off to work in the background.
struct BackgroundJob: Identifiable, Equatable {
    let id: Int
    var name: String
    var title: String
    /// Its latest step, or its report once it's over.
    var status: String
    /// "running", "done", "failed" or "stopped".
    var state: String
}

/// What one helper's cursor shows.
@MainActor
final class HelperCursorState: ObservableObject {
    let name: String
    let tint: BuddyTint
    /// What it is doing: its latest step or note.
    @Published var status: String
    @Published var clickAt: Date?
    @Published var motion: CGVector = .zero
    /// Near the right edge the tag sits on the left of the arrow.
    @Published var flipped = false
    /// nil while working, then whether it finished its part.
    @Published var finished: Bool?
    /// Working in its own window under the user's windows.
    @Published var behind = false

    init(name: String, status: String) {
        self.name = name
        tint = BuddyTint(rawValue: name.lowercased()) ?? .mint
        self.status = status
    }
}

/// The cursors of the helper agents the main agent sends off: one small
/// glass cursor each, in the helper's colour, flying to what it works on
/// with a quiet name tag saying what it's doing. They appear next to the
/// user's pointer, and fade away when the helper is done.
@MainActor
final class HelperCursors {
    static let shared = HelperCursors()
    private var cursors: [Int: HelperCursor] = [:]

    func start(agent: Int, name: String, status: String) {
        cursor(agent, name: name).state.status = status
    }

    func update(agent: Int, status: String) {
        guard !status.isEmpty else { return }
        cursor(agent).state.status = status
    }

    func move(agent: Int, toTopLeft p: CGPoint) async {
        await cursor(agent).fly(toTopLeft: p)
    }

    func clicked(agent: Int) {
        cursor(agent).click()
    }

    /// The helper works in its own window under the user's windows there:
    /// its cursor fades back so it doesn't sit on top of what they're doing.
    func setBehind(agent: Int, _ behind: Bool) {
        let c = cursor(agent)
        if c.state.behind != behind { c.state.behind = behind }
    }

    func finish(agent: Int, ok: Bool) {
        guard let c = cursors[agent] else { return }
        c.state.finished = ok
        c.state.status = ok ? "Done" : "Couldn't finish"
        c.leave(after: 1.6) { [weak self, weak c] in
            if let c, self?.cursors[agent] === c { self?.cursors[agent] = nil }
        }
    }

    func dismissAll(keeping keep: (Int) -> Bool = { _ in false }) {
        for (n, c) in cursors where !keep(n) {
            c.leave(after: 0, onGone: {})
            cursors[n] = nil
        }
    }

    private func cursor(_ agent: Int, name: String? = nil) -> HelperCursor {
        if let c = cursors[agent] { return c }
        let name = name ?? agentName(agent)
        // Start beside the user's pointer, each helper a step further out.
        let mouse = NSEvent.mouseLocation
        let k = CGFloat(isJob(agent) ? agent - 100 : agent - 1)
        let c = HelperCursor(state: HelperCursorState(name: name, status: "Starting"),
                             at: CGPoint(x: mouse.x + 34 + 26 * k, y: mouse.y - 40 - 26 * k))
        cursors[agent] = c
        return c
    }
}

/// A helper cursor's panel: room for the tag on either side of the tip, and
/// for trails and rings above it.
enum HelperLayout {
    static let side: CGFloat = 270
    static let margin: CGFloat = 40
    static let size = CGSize(width: side * 2, height: 120)
}

/// One helper's cursor: a click-through panel whose tip is the helper's
/// pointer, flying on the same eased arcs as the buddy.
@MainActor
private final class HelperCursor: NSObject {
    let state: HelperCursorState
    private let panel: NSPanel
    private var link: CADisplayLink?
    /// The tip, in Cocoa screen coordinates.
    private var anchor: CGPoint
    private var lastAnchor: CGPoint
    private var velocity = CGVector.zero
    private var flight: (from: CGPoint, to: CGPoint, start: CFTimeInterval, duration: CFTimeInterval)?
    private var alpha: CGFloat = 0
    private var leaving = false
    private var onGone: (() -> Void)?
    private var lastFrame: CFTimeInterval = 0

    init(state: HelperCursorState, at p: CGPoint) {
        self.state = state
        anchor = p
        lastAnchor = p
        panel = NSPanel(contentRect: CGRect(origin: .zero, size: HelperLayout.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // Just under the buddy, which stays on top.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        panel.canHide = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: HelperCursorView(state: state))
        panel.applyRecordingVisibility()
        panel.alphaValue = 0
        place()
        panel.orderFrontRegardless()
        let link = panel.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Flies the tip to `p` (global top-left points) and returns once there.
    func fly(toTopLeft p: CGPoint) async {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let target = CGPoint(x: p.x, y: primaryHeight - p.y)
        let distance = hypot(target.x - anchor.x, target.y - anchor.y)
        guard distance > 1.5 else { return }
        let duration = min(0.6, 0.16 + Double(distance) / 3400)
        flight = (anchor, target, CACurrentMediaTime(), duration)
        try? await Task.sleep(for: .seconds(duration + 0.02))
    }

    func click() {
        let at = Date()
        state.clickAt = at
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.7))
            if self?.state.clickAt == at { self?.state.clickAt = nil }
        }
    }

    func leave(after delay: Double, onGone: @escaping () -> Void) {
        self.onGone = onGone
        Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            self?.leaving = true
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = CGFloat(lastFrame == 0 ? 1.0 / 60 : min(max(now - lastFrame, 0), 1.0 / 20))
        lastFrame = now
        if let f = flight {
            let t = min(1, (now - f.start) / f.duration)
            let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            let mid = CGPoint(x: (f.from.x + f.to.x) / 2, y: (f.from.y + f.to.y) / 2)
            let c = CGPoint(x: mid.x, y: mid.y + min(140, hypot(f.to.x - f.from.x, f.to.y - f.from.y) * 0.25))
            let u = 1 - e
            anchor = CGPoint(x: u * u * f.from.x + 2 * u * e * c.x + e * e * f.to.x,
                             y: u * u * f.from.y + 2 * u * e * c.y + e * e * f.to.y)
            if t >= 1 { flight = nil }
        }
        // Motion blur, published only when it changes enough to show.
        let raw = CGVector(dx: (anchor.x - lastAnchor.x) / dt, dy: -(anchor.y - lastAnchor.y) / dt)
        lastAnchor = anchor
        velocity = CGVector(dx: velocity.dx * 0.55 + raw.dx * 0.45, dy: velocity.dy * 0.55 + raw.dy * 0.45)
        let speed = hypot(velocity.dx, velocity.dy)
        if speed < 140 {
            if state.motion != .zero { state.motion = .zero }
        } else if hypot(velocity.dx - state.motion.dx, velocity.dy - state.motion.dy) > 45 {
            state.motion = velocity
        }

        alpha += ((leaving ? 0 : 1) - alpha) * min(1, (leaving ? 5 : 10) * dt)
        panel.alphaValue = alpha
        if leaving, alpha < 0.01 {
            link.invalidate()
            self.link = nil
            panel.orderOut(nil)
            onGone?()
            onGone = nil
            return
        }
        place()
    }

    private func place() {
        let screen = NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(anchor) } ?? NSScreen.main
        let flipped = anchor.x + 240 > (screen?.visibleFrame.maxX ?? .greatestFiniteMagnitude)
        if state.flipped != flipped { state.flipped = flipped }
        let origin = CGPoint(x: (anchor.x - HelperLayout.side).rounded(),
                             y: (anchor.y + HelperLayout.margin - HelperLayout.size.height).rounded())
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }
}

/// A helper's cursor: its glass arrow in its colour, and a small tag with
/// its name and what it's doing.
struct HelperCursorView: View {
    @ObservedObject var state: HelperCursorState

    var body: some View {
        ZStack(alignment: .topLeading) {
            MotionTrail(motion: state.motion, flipped: false, tint: state.tint)
            PilotArrow(flipped: false, active: state.finished == nil, tint: state.tint)
            ClickRing(at: state.clickAt, tint: state.tint)
            tag
                .frame(width: 230, alignment: state.flipped ? .trailing : .leading)
                .offset(x: state.flipped ? -238 : 14, y: 20)
        }
        .opacity(state.behind ? 0.4 : 1)
        .animation(.easeInOut(duration: 0.3), value: state.behind)
        .offset(x: HelperLayout.side, y: HelperLayout.margin)
        .frame(width: HelperLayout.size.width, height: HelperLayout.size.height, alignment: .topLeading)
    }

    private var tag: some View {
        HStack(spacing: 5) {
            if let ok = state.finished {
                Image(systemName: ok ? "checkmark" : "exclamationmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: state.tint.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            } else {
                Circle()
                    .fill(LinearGradient(colors: state.tint.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 7, height: 7)
            }
            Text(state.name).fontWeight(.semibold)
            Text(state.status)
                .foregroundStyle(.white.opacity(0.68))
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.opacity)
        }
        .font(.system(size: 11))
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 4.5)
        // A quiet dark tag that reads on any background.
        .background(Capsule().fill(Color.black.opacity(0.62)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.6))
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeOut(duration: 0.2), value: state.status)
    }
}
