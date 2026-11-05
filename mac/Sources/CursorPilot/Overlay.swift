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
    @Published var pointLabel: String?
    /// A short confirmation such as "Saved to Drawings".
    @Published var notice: String?
    /// What the agent is doing right now ("Ran git status").
    @Published var activity: String?
    /// The agent is working in the background (shell, files, web), so the
    /// buddy stays out of the way. It comes back for mouse and keyboard work.
    @Published var backgroundWork = false
    /// Bubble sits left of the buddy when the cursor is near the right edge.
    @Published var flipped = false
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

    static let size = CGSize(width: 380, height: 200)
    /// Inset of the buddy's tip from the panel's top corner.
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

    /// Drops queued points and returns to the cursor.
    func clearPoints() {
        targets.removeAll()
        holdUntil = 0
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

        if let f = flight {
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
            fly(to: followPoint(), duration: 0.35)
        } else if !isPointing {
            let p = followPoint()
            followX.step(to: p.x, dt: dt, omega: 38)
            followY.step(to: p.y, dt: dt, omega: 38)
            anchor = CGPoint(x: followX.x, y: followY.x)
        }
        if flight != nil || isPointing {
            followX = Spring(anchor.x)
            followY = Spring(anchor.y)
        }

        let busy = state.mode != .idle || state.notice != nil || isPointing || flight != nil || !targets.isEmpty
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
        let flipped = anchor.x + Self.size.width > visible.maxX
        if state.flipped != flipped { state.flipped = flipped }
        let x = flipped ? anchor.x - Self.size.width + Self.tipInset : anchor.x - Self.tipInset
        let y = anchor.y - Self.size.height + Self.tipInset
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

struct OverlayView: View {
    @ObservedObject var state: OverlayState

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if state.flipped {
                bubble
                PilotArrow(flipped: true, active: state.mode != .idle)
            } else {
                PilotArrow(flipped: false, active: state.mode != .idle)
                bubble
            }
        }
        .padding(8)
        .frame(width: OverlayController.size.width, height: OverlayController.size.height,
               alignment: state.flipped ? .topTrailing : .topLeading)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: state.mode)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: state.pointLabel)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: state.notice)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: state.activity)
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
                        Text(tail(state.caption))
                            .font(.system(size: 13))
                            .foregroundStyle(state.mode == .error ? Color(red: 1, green: 0.45, blue: 0.45) : Color.primary)
                            .lineLimit(5)
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

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !active)) { tl in
            let spin = active ? tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3 * 360 : 200
            let rim = AngularGradient(colors: pilotRainbow, center: .center, angle: .degrees(spin))
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
