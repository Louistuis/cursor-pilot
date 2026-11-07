import AppKit
import Combine
import QuartzCore
import SwiftUI

/// What the buddy next to the cursor is showing.
@MainActor
final class OverlayState: ObservableObject {
    enum Mode: Equatable { case idle, listening, thinking, answering, error }
    @Published var mode: Mode = .idle
    @Published var level: Float = 0
    @Published var caption = ""
    /// The sentence being spoken and the word in it, for the karaoke caption.
    @Published var spoken: SpokenWord?
    /// Replies are read aloud: the bubble only ever shows the read-along line.
    @Published var readAlong = false
    @Published var pointLabel: String?
    /// A short confirmation such as "Saved to Drawings".
    @Published var notice: String?
    /// What the agent is doing right now ("Ran git status").
    @Published var activity: String?
    /// The agent is working in the background (shell, files, web), so the
    /// buddy stays out of the way. It comes back for mouse and keyboard work.
    @Published var backgroundWork = false
    /// How fast the buddy is moving, in view points per second (y down);
    /// drives the motion blur.
    @Published var motion: CGVector = .zero
    /// When the agent last clicked, for the ring at the tip.
    @Published var clickAt: Date?
    /// Bubble sits left of the buddy when the cursor is near the right edge.
    @Published var flipped = false
    /// The buddy is drawing: its tip carries a dot of this ink.
    @Published var penInk: Color?
}

/// A click-through panel that follows the mouse and flies to points the
/// model asks it to show. It fades away after a few idle seconds and comes
/// back as soon as you talk to it.
@MainActor
final class OverlayController: NSObject {
    let state = OverlayState()
    private let panel: NSPanel
    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    private var stateChanges: AnyCancellable?

    /// The buddy and its bubble.
    static let content = CGSize(width: 380, height: 200)
    /// Room around them for motion trails and click rings.
    static let margin: CGFloat = 72
    static let size = CGSize(width: content.width + 2 * margin, height: content.height + 2 * margin)
    /// Inset of the buddy's tip from the content's top corner.
    private static let tipInset: CGFloat = 6
    /// Where the buddy rests relative to the real cursor.
    private static let followOffset = CGPoint(x: 18, y: -20)
    /// Idle time before the buddy fades away.
    private static let idleHide: CFTimeInterval = 4

    /// Fade away when idle; off keeps the buddy by the cursor all the time.
    var autoHide = true { didSet { wake() } }

    private struct Flight {
        var from: CGPoint
        var to: CGPoint
        var start: CFTimeInterval
        var duration: CFTimeInterval
    }

    private var enabled = false
    private var anchor = CGPoint.zero
    // The resting position trails the cursor on a stiff spring: no lag you
    // can feel, but no jitter either.
    private var followX = Spring(0), followY = Spring(0)
    private var flight: Flight?
    private var targets: [(CGPoint, String)] = []
    private var holdUntil: CFTimeInterval = 0
    private var isPointing = false
    private var lastActive: CFTimeInterval = 0
    private var alpha: CGFloat = 0
    /// The agent is moving the buddy as its own pointer, so it stays where
    /// the agent put it instead of following the user's cursor.
    private var agentDriving = false
    private var lastAnchor = CGPoint.zero
    private var velocity = CGVector.zero

    /// A stroke the buddy is drawing: it moves along these points (Cocoa
    /// coordinates, evenly spaced) at an even pace, as the ink goes on.
    private struct PenStroke {
        var points: [CGPoint]
        var start: CFTimeInterval
        var duration: CFTimeInterval
    }
    private var pen: PenStroke?

    override init() {
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.alphaValue = 0
        panel.canHide = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: OverlayView(state: state))
        panel.applyRecordingVisibility()
        // Anything the buddy has to show counts as activity.
        stateChanges = state.objectWillChange.sink { [weak self] in
            MainActor.assumeIsolated { self?.wake() }
        }
    }

    func show() {
        enabled = true
        wake()
    }

    func hide() {
        enabled = false
        sleep()
        alpha = 0
        panel.alphaValue = 0
    }

    /// Queues a flight to `point`, given in global top-left-origin coordinates.
    func point(atTopLeft p: CGPoint, label: String) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        targets.append((CGPoint(x: p.x, y: primaryHeight - p.y), label))
        wake()
    }

    /// Draws with the buddy as the pen: it flies to where the stroke starts,
    /// calls `begin` (which puts the ink on), and moves along `points`
    /// (global top-left, evenly spaced) for `duration` seconds in step with
    /// it. Returns when the stroke is done. With the buddy off, it only draws.
    func draw(along points: [CGPoint], duration: Double, ink: Color, begin: () -> Void) async {
        guard enabled, let first = points.first else {
            begin()
            return
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoa = points.map { CGPoint(x: $0.x, y: primaryHeight - $0.y) }
        let start = CGPoint(x: first.x, y: primaryHeight - first.y)
        targets.removeAll()
        isPointing = true
        state.pointLabel = nil
        holdUntil = .infinity
        wake()
        let distance = hypot(start.x - anchor.x, start.y - anchor.y)
        if distance > 2 {
            let d = min(0.5, 0.16 + Double(distance) / 3600)
            fly(to: start, duration: d)
            try? await Task.sleep(for: .seconds(d))
        }
        state.penInk = ink
        begin()
        pen = PenStroke(points: cocoa, start: CACurrentMediaTime(), duration: max(duration, 0.05))
        try? await Task.sleep(for: .seconds(duration))
        state.penInk = nil
        // Linger by the drawing a moment, then go home (unless more follows).
        holdUntil = CACurrentMediaTime() + 0.7
    }

    /// Drops queued points and returns to the cursor.
    func clearPoints() {
        targets.removeAll()
        holdUntil = 0
        pen = nil
        state.penInk = nil
    }

    // MARK: The agent's pointer

    /// Flies the buddy to `p` (global top-left points) as the agent's own
    /// pointer, and returns once it's there. The user's cursor doesn't move.
    func agentMove(toTopLeft p: CGPoint) async {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let target = CGPoint(x: p.x, y: primaryHeight - p.y)
        agentDriving = true
        targets.removeAll()
        isPointing = false
        state.pointLabel = nil
        wake()
        let distance = hypot(target.x - anchor.x, target.y - anchor.y)
        guard distance > 1.5 else { return }
        let duration = min(0.6, 0.16 + Double(distance) / 3400)
        fly(to: target, duration: duration)
        try? await Task.sleep(for: .seconds(duration + 0.02))
    }

    /// A ring at the tip where the agent clicked.
    func agentClicked() {
        let at = Date()
        state.clickAt = at
        wake()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(0.7))
            if self?.state.clickAt == at { self?.state.clickAt = nil }
        }
    }

    /// The agent is done with its pointer: back to the user's cursor.
    func agentRelease() {
        guard agentDriving else { return }
        agentDriving = false
        if link != nil, flight == nil, targets.isEmpty { fly(to: followPoint(), duration: 0.45) }
    }

    /// Brings the buddy back (or keeps it) and restarts the idle countdown.
    private func wake() {
        guard enabled else { return }
        lastActive = CACurrentMediaTime()
        guard link == nil else { return }
        // Start the link first: placing the panel updates state, which comes
        // straight back here.
        let link = panel.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        lastFrame = 0
        let p = followPoint()
        anchor = p
        lastAnchor = p
        velocity = .zero
        followX = Spring(p.x)
        followY = Spring(p.y)
        place()
        panel.orderFrontRegardless()
    }

    private func sleep() {
        link?.invalidate()
        link = nil
        panel.orderOut(nil)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = CGFloat(lastFrame == 0 ? 1.0 / 60 : min(max(now - lastFrame, 0), 1.0 / 20))
        lastFrame = now

        if let p = pen {
            let t = min(1, (now - p.start) / p.duration)
            let f = CGFloat(t) * CGFloat(p.points.count - 1)
            let i = min(Int(f), p.points.count - 1), j = min(i + 1, p.points.count - 1)
            let k = f - CGFloat(i)
            anchor = CGPoint(x: p.points[i].x + (p.points[j].x - p.points[i].x) * k,
                             y: p.points[i].y + (p.points[j].y - p.points[i].y) * k)
            if t >= 1 { pen = nil }
        } else if let f = flight {
            let t = min(1, (now - f.start) / f.duration)
            anchor = arc(from: f.from, to: f.to, t: ease(t))
            if t >= 1 { flight = nil }
        } else if now >= holdUntil, !targets.isEmpty {
            let (target, label) = targets.removeFirst()
            fly(to: target, duration: 0.6)
            isPointing = true
            state.pointLabel = label.isEmpty ? nil : label
            holdUntil = now + 0.6 + 2.4
        } else if isPointing, now >= holdUntil {
            isPointing = false
            state.pointLabel = nil
            if !agentDriving { fly(to: followPoint(), duration: 0.35) }
        } else if agentDriving {
            // Stay where the agent left its pointer.
        } else if !isPointing {
            let p = followPoint()
            followX.step(to: p.x, dt: dt, omega: 38)
            followY.step(to: p.y, dt: dt, omega: 38)
            anchor = CGPoint(x: followX.x, y: followY.x)
        }
        if flight != nil || pen != nil || isPointing || agentDriving {
            followX = Spring(anchor.x)
            followY = Spring(anchor.y)
        }
        trackMotion(dt: dt)

        let busy = state.mode != .idle || state.notice != nil || isPointing || flight != nil || pen != nil
            || !targets.isEmpty || agentDriving
        if busy { lastActive = now }
        let visible = !state.backgroundWork && (!autoHide || now - lastActive < Self.idleHide)
        // Quick to appear, slow to leave.
        let rate: CGFloat = visible ? 14 : 3.5
        alpha += ((visible ? 1 : 0) - alpha) * min(1, rate * dt)
        panel.alphaValue = alpha
        if !visible, alpha < 0.01 {
            alpha = 0
            panel.alphaValue = 0
            sleep()
            return
        }
        place()
    }

    /// Measures how fast the buddy moves and publishes it (sparingly) for
    /// the motion blur.
    private func trackMotion(dt: CGFloat) {
        let raw = CGVector(dx: (anchor.x - lastAnchor.x) / dt, dy: (anchor.y - lastAnchor.y) / dt)
        lastAnchor = anchor
        velocity = CGVector(dx: velocity.dx * 0.55 + raw.dx * 0.45, dy: velocity.dy * 0.55 + raw.dy * 0.45)
        let view = CGVector(dx: velocity.dx, dy: -velocity.dy)
        let speed = hypot(view.dx, view.dy)
        let shown = state.motion
        if speed < 140 {
            if shown != .zero { state.motion = .zero }
        } else if hypot(view.dx - shown.dx, view.dy - shown.dy) > 45 {
            state.motion = view
        }
    }

    private func fly(to target: CGPoint, duration: CFTimeInterval) {
        flight = Flight(from: anchor, to: target, start: CACurrentMediaTime(), duration: duration)
    }

    private func followPoint() -> CGPoint {
        let m = NSEvent.mouseLocation
        return CGPoint(x: m.x + Self.followOffset.x, y: m.y + Self.followOffset.y)
    }

    /// Positions the panel so the buddy's tip sits on `anchor`.
    private func place() {
        let screen = NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let flipped = anchor.x + Self.content.width > visible.maxX
        if state.flipped != flipped { state.flipped = flipped }
        let inset = Self.tipInset + Self.margin
        let x = flipped ? anchor.x + inset - Self.size.width : anchor.x - inset
        let y = anchor.y + inset - Self.size.height
        let origin = CGPoint(x: x.rounded(), y: y.rounded())
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }

    private func ease(_ t: Double) -> Double { t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }

    /// Quadratic Bézier with the control point lifted, so flights curve.
    private func arc(from a: CGPoint, to b: CGPoint, t: Double) -> CGPoint {
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let lift = min(140, hypot(b.x - a.x, b.y - a.y) * 0.25)
        let c = CGPoint(x: mid.x, y: mid.y + lift)
        let u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x,
                       y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    }
}

// MARK: - Views

let pilotAccent = Color(red: 0.24, green: 0.52, blue: 1.0)

/// The colours of the screen glow, for rims and highlights.
let pilotRainbow: [Color] = [
    Color(red: 0.35, green: 0.88, blue: 1.0),
    Color(red: 0.42, green: 0.48, blue: 1.0),
    Color(red: 0.72, green: 0.4, blue: 1.0),
    Color(red: 1.0, green: 0.42, blue: 0.82),
    Color(red: 1.0, green: 0.68, blue: 0.36),
    Color(red: 0.35, green: 0.88, blue: 1.0),
]

/// Colours for the buddy (Settings › On screen › Buddy colour); the rainbow
/// matches the screen glow.
enum BuddyTint: String, CaseIterable, Identifiable {
    case rainbow, ocean, violet, rose, sunset, mint, graphite

    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    /// Looping: the last colour is the first, for angular gradients.
    var colors: [Color] {
        func rgb(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }
        let c: [Color] = switch self {
        case .rainbow: Array(pilotRainbow.dropLast())
        case .ocean: [rgb(0.35, 0.88, 1), rgb(0.25, 0.55, 1), rgb(0.3, 0.35, 0.95)]
        case .violet: [rgb(0.78, 0.6, 1), rgb(0.55, 0.38, 1), rgb(0.88, 0.4, 0.95)]
        case .rose: [rgb(1, 0.55, 0.75), rgb(1, 0.4, 0.55), rgb(1, 0.62, 0.5)]
        case .sunset: [rgb(1, 0.72, 0.3), rgb(1, 0.48, 0.38), rgb(1, 0.86, 0.4)]
        case .mint: [rgb(0.45, 0.95, 0.75), rgb(0.25, 0.8, 0.6), rgb(0.35, 0.85, 0.95)]
        case .graphite: [rgb(0.92, 0.92, 0.95), rgb(0.55, 0.57, 0.62), rgb(0.75, 0.76, 0.8)]
        }
        return c + [c[0]]
    }

    static var current: BuddyTint {
        UserDefaults.standard.string(forKey: "buddyTint").flatMap(BuddyTint.init(rawValue:)) ?? .rainbow
    }
}

struct OverlayView: View {
    @ObservedObject var state: OverlayState

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if state.flipped {
                bubble
                buddy
            } else {
                buddy
                bubble
            }
        }
        .padding(8)
        .frame(width: OverlayController.content.width, height: OverlayController.content.height,
               alignment: state.flipped ? .topTrailing : .topLeading)
        .padding(OverlayController.margin)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: state.mode)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: state.pointLabel)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: state.notice)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: state.activity)
    }

    /// The arrow with its motion trail behind it and the click ring at its tip.
    private var buddy: some View {
        ZStack(alignment: state.flipped ? .topTrailing : .topLeading) {
            MotionTrail(motion: state.motion, flipped: state.flipped)
            PilotArrow(flipped: state.flipped, active: state.mode != .idle)
            ClickRing(at: state.clickAt)
            if let ink = state.penInk {
                // The ink at the tip, where the line comes from.
                Circle()
                    .fill(ink)
                    .frame(width: 7, height: 7)
                    .shadow(color: ink.opacity(0.8), radius: 4)
                    .offset(x: state.flipped ? 3.5 : -3.5, y: -3.5)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 20, height: 23, alignment: state.flipped ? .topTrailing : .topLeading)
    }

    @ViewBuilder private var bubble: some View {
        Group {
            if let label = state.pointLabel ?? state.notice {
                GlassCapsule { Text(label).font(.system(size: 12, weight: .semibold)) }
            } else if let activity = state.activity, state.mode != .idle {
                GlassCapsule { ShimmerText(text: activity).lineLimit(1).frame(maxWidth: 280, alignment: .leading) }
            } else {
                switch state.mode {
                case .idle:
                    EmptyView()
                case .listening:
                    GlassCapsule {
                        HStack(spacing: 8) {
                            VoiceBars(level: state.level, live: true)
                            if !state.caption.isEmpty {
                                Text(state.caption).font(.system(size: 12, weight: .medium)).lineLimit(2)
                            }
                        }
                    }
                case .thinking:
                    GlassCapsule { ShimmerText(text: "Thinking") }
                case .answering, .error:
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if state.mode == .answering {
                            VoiceBars(level: 0.55, live: true).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                        }
                        if state.mode == .answering, let spoken = state.spoken {
                            KaraokeCaption(spoken: spoken)
                        } else if state.mode == .answering && state.readAlong {
                            // The voice is about to start: no wall of text first.
                            EmptyView()
                        } else {
                            Text(tail(state.caption))
                                .font(.system(size: 13))
                                .foregroundStyle(state.mode == .error ? Color(red: 1, green: 0.45, blue: 0.45) : Color.primary)
                                .lineLimit(5)
                        }
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .frame(maxWidth: 300, alignment: .leading)
                    .glassBackground(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
        .padding(.top, 12)
        .transition(.scale(scale: 0.85, anchor: state.flipped ? .topTrailing : .topLeading).combined(with: .opacity))
    }

    /// Keeps the bubble to the latest part of a long reply.
    private func tail(_ s: String) -> String {
        s.count > 260 ? "…" + s.suffix(260) : s
    }
}

private struct GlassCapsule<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassBackground(Capsule())
    }
}

extension View {
    /// Liquid Glass where the system has it, frosted material with a lit
    /// edge before that.
    @ViewBuilder func glassBackground<S: Shape>(_ shape: S) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: shape)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.08)],
                                                     startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
        }
    }
}

/// A few rounded bars in the glow's colours that follow your voice.
struct VoiceBars: View {
    var level: Float
    var live: Bool
    private let weights: [Double] = [0.45, 0.8, 1.0, 0.7, 0.4]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !live)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(weights.indices, id: \.self) { i in
                    let wobble = 0.5 + 0.5 * sin(t * 9 + Double(i) * 1.3)
                    let h = 4 + 12 * weights[i] * (0.25 + 0.75 * Double(level)) * (0.55 + 0.45 * wobble)
                    Capsule().frame(width: 3, height: h)
                }
            }
            .frame(height: 16)
            .foregroundStyle(LinearGradient(colors: pilotRainbow, startPoint: .leading, endPoint: .trailing))
            .animation(.easeOut(duration: 0.08), value: level)
        }
    }
}

/// Text with the glow's colours sweeping through it.
struct ShimmerText: View {
    var text: String
    var body: some View {
        TimelineView(.animation) { tl in
            let phase = tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2) / 2.2
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.55))
                .overlay {
                    LinearGradient(colors: [.clear] + pilotRainbow.dropLast() + [.clear],
                                   startPoint: UnitPoint(x: phase * 2 - 1, y: 0.5),
                                   endPoint: UnitPoint(x: phase * 2, y: 0.5))
                        .mask(Text(text).font(.system(size: 12, weight: .semibold)))
                }
        }
    }
}

/// The buddy: a soft glass pointer with the glow's colours caught in its
/// edge. While Cursor Pilot works, the colours turn and the glow brightens.
struct PilotArrow: View {
    var flipped: Bool
    var active: Bool = false
    /// Overrides the colour from Settings (previews).
    var tint: BuddyTint?
    @AppStorage("buddyTint") private var savedTint = BuddyTint.rainbow

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !active)) { tl in
            let spin = active ? tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3 * 360 : 200
            let rim = AngularGradient(colors: (tint ?? savedTint).colors, center: .center, angle: .degrees(spin))
            ZStack {
                // Frosted body: what's behind, blurred, under a milky tint.
                ArrowShape().fill(.ultraThinMaterial)
                ArrowShape().fill(LinearGradient(colors: [.white.opacity(0.92), Color(red: 0.86, green: 0.9, blue: 1).opacity(0.62)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                // Colour caught inside the edge.
                ArrowShape().stroke(rim, lineWidth: 3.5).blur(radius: 1.6).clipShape(ArrowShape())
                // Rainbow rim and a lit top edge.
                ArrowShape().stroke(rim, lineWidth: 1.4)
                ArrowShape().stroke(LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .topLeading, endPoint: .center),
                                    lineWidth: 0.8)
            }
            .frame(width: 20, height: 23)
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
            .background(
                ArrowShape().fill(rim).frame(width: 20, height: 23)
                    .blur(radius: active ? 8 : 5).opacity(active ? 0.85 : 0.5)
            )
        }
        .scaleEffect(x: flipped ? -1 : 1, y: 1)
        .animation(.easeInOut(duration: 0.3), value: active)
    }
}

/// Motion blur for the buddy: fading, softening copies of the arrow along
/// the way it came, the faster it moves the longer.
struct MotionTrail: View {
    var motion: CGVector
    var flipped: Bool
    var tint: BuddyTint?
    @AppStorage("buddyTint") private var savedTint = BuddyTint.rainbow

    var body: some View {
        let speed = hypot(motion.dx, motion.dy)
        // 0 at a stroll, 1 when it flies across the screen.
        let strength = min(1, max(0, (speed - 140) / 2600))
        ZStack {
            if strength > 0 {
                ForEach(1...14, id: \.self) { i in
                    let k = Double(i) / 14
                    // About 30 ms of travel behind the arrow.
                    ArrowShape()
                        .fill(LinearGradient(colors: (tint ?? savedTint).colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 20, height: 23)
                        .scaleEffect(x: flipped ? -1 : 1, y: 1)
                        .offset(x: -motion.dx * 0.03 * k, y: -motion.dy * 0.03 * k)
                        .opacity(strength * 0.26 * (1 - k * 0.85))
                        .blur(radius: 0.8 + 3.2 * k * strength)
                }
            }
        }
        .frame(width: 20, height: 23)
        .animation(.easeOut(duration: 0.12), value: strength > 0)
        .allowsHitTesting(false)
    }
}

/// A rainbow ring that pops out from the tip when the agent clicks.
struct ClickRing: View {
    var at: Date?
    var tint: BuddyTint?
    @AppStorage("buddyTint") private var savedTint = BuddyTint.rainbow

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 120, paused: at == nil)) { tl in
            let t = at.map { min(1, tl.date.timeIntervalSince($0) / 0.5) } ?? 1
            let eased = 1 - pow(1 - t, 3)
            let r = 5 + 21 * eased
            Circle()
                .strokeBorder(AngularGradient(colors: (tint ?? savedTint).colors, center: .center), lineWidth: 0.6 + 2.6 * (1 - t))
                .frame(width: r * 2, height: r * 2)
                .opacity(t < 1 ? 1 - t * t : 0)
                .offset(x: -r + 1, y: -r + 1)
        }
        .frame(width: 0, height: 0, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// A chubby cursor arrow: tip at the top left, a near-upright left edge, a
/// wide wing on the right and a short notched tail, every corner rounded.
struct ArrowShape: Shape {
    /// Corners as fractions of the rect, with their radius as a fraction of
    /// the shorter side.
    static let corners: [(x: CGFloat, y: CGFloat, r: CGFloat)] = [
        (0.02, 0.01, 0.09),  // tip
        (1.00, 0.58, 0.15),  // wing
        (0.45, 0.66, 0.05),  // notch
        (0.13, 1.00, 0.15),  // tail
    ]

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let pts = Self.corners.map { CGPoint(x: rect.minX + rect.width * $0.x, y: rect.minY + rect.height * $0.y) }
        var p = Path()
        let first = pts[0], last = pts[pts.count - 1]
        p.move(to: CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2))
        for i in pts.indices {
            p.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % pts.count],
                     radius: Self.corners[i].r * side)
        }
        p.closeSubpath()
        return p
    }
}

extension NSWindow {
    /// Cursor Pilot's floating windows (buddy, notch, glow) leave screenshots
    /// and screen recordings when Settings says so. Ink stays: it's yours,
    /// and Claude has to see it.
    func applyRecordingVisibility() {
        sharingType = UserDefaults.standard.bool(forKey: "hideFromRecordings") ? .none : .readOnly
    }
}

/// The sentence being read aloud and the word the voice is on.
struct SpokenWord: Equatable {
    var sentence: String
    /// UTF-16 range of the word in `sentence`.
    var word: NSRange
}

/// Spoken replies, read along: the line the voice is on and the next one,
/// with a soft highlight that glides onto each word as it is said and the
/// lines rolling up as the voice moves on.
struct KaraokeCaption: View {
    var spoken: SpokenWord
    @Namespace private var focus
    @AppStorage("buddyTint") private var tint = BuddyTint.rainbow

    private struct Word: Identifiable {
        let id: Int
        let text: String
        let location: Int
    }

    var body: some View {
        let words = Self.words(in: spoken.sentence)
        let lines = Self.lines(words, budget: 32)
        let current = words.last { $0.location <= spoken.word.location }?.id ?? -1
        let row = lines.firstIndex { $0.contains { $0.id == current } } ?? 0
        let shown = Array(lines.indices.filter { $0 >= row && $0 <= row + 1 })
        VStack(alignment: .leading, spacing: 4) {
            ForEach(shown, id: \.self) { i in
                HStack(spacing: 5) {
                    ForEach(lines[i]) { w in
                        Text(w.text)
                            .foregroundStyle(.primary.opacity(w.id == current ? 1 : w.id < current ? 0.62 : 0.4))
                            .background {
                                if w.id == current {
                                    Capsule()
                                        .fill(LinearGradient(colors: tint.colors, startPoint: .leading, endPoint: .trailing))
                                        .opacity(0.28)
                                        .padding(.horizontal, -3)
                                        .padding(.vertical, -1)
                                        .matchedGeometryEffect(id: "focus", in: focus)
                                }
                            }
                    }
                }
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .move(edge: .top).combined(with: .opacity)))
            }
        }
        .font(.system(size: 14, weight: .medium))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .frame(minWidth: 120, maxWidth: 300, minHeight: shown.count > 1 ? 40 : 19, alignment: .topLeading)
        .clipped()
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: current)
        .animation(.spring(response: 0.42, dampingFraction: 0.9), value: row)
        .animation(.easeOut(duration: 0.2), value: spoken.sentence)
    }

    private static func words(in s: String) -> [Word] {
        let ns = s as NSString
        let regex = try? NSRegularExpression(pattern: "\\S+")
        return (regex?.matches(in: s, range: NSRange(location: 0, length: ns.length)) ?? []).enumerated().map {
            Word(id: $0.offset, text: ns.substring(with: $0.element.range), location: $0.element.range.location)
        }
    }

    /// Words packed into lines of about `budget` characters.
    private static func lines(_ words: [Word], budget: Int) -> [[Word]] {
        var out: [[Word]] = [[]]
        var length = 0
        for w in words {
            if length > 0 && length + 1 + w.text.count > budget {
                out.append([])
                length = 0
            }
            out[out.count - 1].append(w)
            length += (length > 0 ? 1 : 0) + w.text.count
        }
        return out
    }
}
