import AppKit
import QuartzCore

/// Lights the edges of every display with the Zero OCR neon frame while
/// Cursor Pilot is working: it breathes with your voice while listening,
/// pulses while thinking, settles while answering and glows softly while you
/// draw. Click-through, and left out of the screenshots sent to Claude like
/// every other Cursor Pilot window.
@MainActor
final class GlowController {
    enum Mode: Equatable { case off, listening, thinking, answering, sketching }

    var mode: Mode = .off { didSet { if mode != oldValue { update() } } }
    /// Voice level, 0...1, while listening.
    var level: Float = 0
    var enabled = true { didSet { update() } }

    private var stages: [CGDirectDisplayID: GlowStage] = [:]
    private var screensObserver: NSObjectProtocol?

    init() {
        screensObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stages.values.forEach { $0.close() }
                self?.stages.removeAll()
                self?.update()
            }
        }
    }

    private var target: Mode { enabled ? mode : .off }

    private func update() {
        guard target != .off else { return } // running stages fade out and close themselves
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            if let stage = stages[id], stage.isOpen { continue }
            let stage = GlowStage(screen: screen) { [weak self] in
                (self?.target ?? .off, self?.level ?? 0)
            }
            stage.onClose = { [weak self, weak stage] in
                if let stage, self?.stages[id] === stage { self?.stages[id] = nil }
            }
            stages[id] = stage
            stage.show()
        }
    }

    /// One frame of the glow around a screen of `size`, for `-CPRenderGlowPreview`.
    static func preview(size: CGSize, mode: Mode) -> CGImage? {
        let gain: Float = mode == .thinking ? 0.98 : mode == .sketching ? 0.45 : 0.7
        let r = GlowStage.cornerRadius(notched: true)
        return GlowView.image(of: GlowState(rect: CGRect(origin: .zero, size: size), radii: (r, r, r, r),
                                            gain: gain, fill: 0, outer: 0, rot: 0.3,
                                            notch: CGRect(x: size.width / 2 - 276, y: 0, width: 552, height: 240),
                                            notchRadius: 26),
                              size: size)
    }
}

/// The frame around one display: a borderless, click-through panel drawn by
/// GlowView on the display link.
@MainActor
private final class GlowStage: NSObject {
    let screen: NSScreen
    private let panel: NSPanel
    private let glow: GlowView
    private let read: () -> (GlowController.Mode, Float)
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var clock: CGFloat = 0
    private var rot: CGFloat = 0
    private var gain = Spring(0)
    private var spin = Spring(0.14)
    private(set) var isOpen = true
    var onClose: (() -> Void)?

    /// The camera notch in this view's top-left points, with a little air around it.
    private lazy var hardwareNotch: CGRect? = {
        guard screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }
        let width = screen.frame.width - left.width - right.width
        return CGRect(x: left.width - 2, y: 0, width: width + 4, height: screen.safeAreaInsets.top + 2)
    }()
    /// The cutout's edges and corner, following the island as it opens,
    /// grows wings and closes, on the island's own spring.
    private var cut: (x: Spring, w: Spring, h: Spring, r: Spring)?

    /// The cutout this frame: the island's outline (where it is heading,
    /// eased the way SwiftUI eases the island), never smaller than the notch.
    private func notchCut(dt: CGFloat) -> (CGRect, CGFloat)? {
        var target = hardwareNotch.map { ($0, CGFloat(12)) }
        if let island = AppModel.shared.notch?.island, island.screen.frame == screen.frame {
            // The black body sits 6 pt in from the flared top corners; leave 2 pt of air.
            let body = CGRect(x: island.rect.minX + 4, y: 0, width: island.rect.width - 8,
                              height: island.rect.height > 0 ? island.rect.height + 2 : 0)
            if let hw = hardwareNotch {
                if body.width > hw.width || body.height > hw.height { target = (body.union(hw), island.radius + 2) }
            } else {
                target = (body, island.radius + 2)
            }
        }
        guard let (rect, radius) = target else {
            cut = nil
            return nil
        }
        guard var c = cut else {
            cut = (Spring(rect.minX), Spring(rect.width), Spring(rect.height), Spring(radius))
            return rect.height > 0.5 ? (rect, radius) : nil
        }
        let omega: CGFloat = 2 * .pi / 0.38
        c.x.step(to: rect.minX, dt: dt, omega: omega, damping: 0.82)
        c.w.step(to: rect.width, dt: dt, omega: omega, damping: 0.82)
        c.h.step(to: rect.height, dt: dt, omega: omega, damping: 0.82)
        c.r.step(to: radius, dt: dt, omega: omega, damping: 0.82)
        cut = c
        guard c.h.x > 0.5, c.w.x > 0.5 else { return nil }
        return (CGRect(x: c.x.x, y: 0, width: c.w.x, height: c.h.x), max(c.r.x, 0))
    }

    /// Built-in displays with a notch have rounded corners; the frame follows them.
    static func cornerRadius(notched: Bool) -> CGFloat { notched ? 10 : 0 }

    init(screen: NSScreen, read: @escaping () -> (GlowController.Mode, Float)) {
        self.screen = screen
        self.read = read
        panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false, screen: screen)
        glow = GlowView(frame: CGRect(origin: .zero, size: screen.frame.size))
        super.init()
        panel.setFrame(screen.frame, display: false)
        // Below the ink (screenSaver - 1) so pen strokes draw over the light.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 2)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.canHide = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.applyRecordingVisibility()
        panel.isReleasedWhenClosed = false
        glow.autoresizingMask = [.width, .height]
        panel.contentView = glow
    }

    func show() {
        panel.orderFrontRegardless()
        let link = panel.displayLink(target: self, selector: #selector(tick(_:)))
        // Soft light needs no ProMotion; 60 fps keeps a full-screen pass cheap.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        link?.invalidate()
        link = nil
        panel.orderOut(nil)
        onClose?()
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = CGFloat(last == 0 ? 1 / 60 : min(max(now - last, 0), 1 / 20))
        last = now
        clock += dt

        let (mode, level) = read()
        switch mode {
        case .off:
            gain.step(to: 0, dt: dt, omega: 7)
            spin.step(to: 0.14, dt: dt, omega: 4)
            if gain.x < 0.01, gain.v <= 0 { close(); return }
        case .listening:
            gain.step(to: 0.5 + CGFloat(min(max(level, 0), 1)) * 0.7, dt: dt, omega: 14)
            spin.step(to: 0.14, dt: dt, omega: 4)
        case .thinking:
            gain.step(to: 0.8 + 0.18 * sin(clock * 3.4), dt: dt, omega: 10)
            spin.step(to: 0.36, dt: dt, omega: 3)
        case .answering:
            gain.step(to: 0.62 + 0.06 * sin(clock * 1.7), dt: dt, omega: 6)
            spin.step(to: 0.14, dt: dt, omega: 3)
        case .sketching:
            gain.step(to: 0.42, dt: dt, omega: 8)
            spin.step(to: 0.08, dt: dt, omega: 3)
        }
        rot += spin.x * dt

        let r = Self.cornerRadius(notched: screen.safeAreaInsets.top > 0)
        let cut = notchCut(dt: dt)
        glow.state = GlowState(rect: glow.bounds, radii: (r, r, r, r),
                               gain: Float(max(gain.x, 0)), fill: 0, outer: 0,
                               rot: Float(rot.truncatingRemainder(dividingBy: 4)),
                               notch: cut?.0, notchRadius: cut?.1 ?? 12)
        glow.render()
    }
}
