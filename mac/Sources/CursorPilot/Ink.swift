import AppKit
import SwiftUI

/// A shape Claude drew, in global top-left-origin points.
enum InkShape: Equatable {
    case circle(center: CGPoint, radius: CGFloat)
    case arrow(from: CGPoint, to: CGPoint)
    case box(CGRect)
    case underline(from: CGPoint, width: CGFloat)
    case highlight(CGRect)
    case trace([CGPoint])
    case note(at: CGPoint, text: String)

    /// Where the shape sits: which screen shows it, and what it is pinned to.
    var anchor: CGPoint {
        switch self {
        case .circle(let c, _): c
        case .arrow(_, let to): to
        case .box(let r), .highlight(let r): CGPoint(x: r.midX, y: r.midY)
        case .underline(let a, let w): CGPoint(x: a.x + w / 2, y: a.y - 6)
        case .trace(let pts): pts[pts.count / 2]
        case .note(let p, _): p
        }
    }

    func offset(by o: CGPoint) -> InkShape {
        switch self {
        case .circle(let c, let r): .circle(center: c - o, radius: r)
        case .arrow(let a, let b): .arrow(from: a - o, to: b - o)
        case .box(let r): .box(r.offsetBy(dx: -o.x, dy: -o.y))
        case .underline(let a, let w): .underline(from: a - o, width: w)
        case .highlight(let r): .highlight(r.offsetBy(dx: -o.x, dy: -o.y))
        case .trace(let pts): .trace(pts.map { $0 - o })
        case .note(let p, let t): .note(at: p - o, text: t)
        }
    }
}

struct InkMark: Identifiable, Equatable {
    let id = UUID()
    var shape: InkShape
    var label: String
    /// How far what it marks has moved since (scrolled, window dragged).
    var shift: CGPoint = .zero
    /// What it marks is out of sight: scrolled away or covered.
    var hidden = false

    /// Where it is drawn now, in global points.
    var placed: InkShape { shift == .zero ? shape : shape.offset(by: CGPoint(x: -shift.x, y: -shift.y)) }
}

/// A freehand pen stroke, in global top-left-origin points.
struct InkStroke: Identifiable, Equatable {
    let id = UUID()
    var points: [CGPoint]
    var color: Color
}

enum InkPalette {
    /// Claude's marker.
    static let marker = Color(red: 1.0, green: 0.34, blue: 0.24)
    /// Claude's highlighter and sticky notes.
    static let highlighter = Color(red: 1.0, green: 0.86, blue: 0.2)
    /// The user's pens.
    static let pens: [Color] = [
        Color(red: 1.0, green: 0.18, blue: 0.62),
        Color(red: 1.0, green: 0.8, blue: 0.1),
        Color(red: 0.2, green: 0.6, blue: 1.0),
        Color(red: 0.2, green: 0.85, blue: 0.45),
    ]
}

@MainActor
final class InkState: ObservableObject {
    @Published var marks: [InkMark] = []
    @Published var strokes: [InkStroke] = []
    @Published var current: InkStroke?
    @Published var sketching = false
    /// Hidden while a screenshot is taken so it doesn't end up in it.
    @Published var toolbarVisible = true
    @Published var penColor = InkPalette.pens[0]
    @Published var question = ""
    /// The display that shows the sketch toolbar.
    @Published var toolbarScreen: CGDirectDisplayID?
}

/// Owns one transparent window per display, above other apps and below the
/// cursor buddy. Click-through unless the user is sketching.
@MainActor
final class InkController {
    let state = InkState()
    var onAsk: ((String) -> Void)?
    var onSave: (() -> Void)?

    private var panels: [CGDirectDisplayID: InkPanel] = [:]
    private var keyMonitor: Any?
    private var fadeTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.rebuildPanels() } }
        rebuildPanels()
    }

    var hasStrokes: Bool { !state.strokes.isEmpty }

    /// Window numbers of the ink windows, so screenshots can include them.
    var windowNumbers: [Int] { panels.values.map(\.windowNumber) }

    // MARK: Claude's marks

    /// What each mark is pinned to: the element under it when drawn, and
    /// where that element was then.
    private var pins: [UUID: (element: AXUIElement, pid: pid_t, origin: CGPoint)] = [:]
    private var pinTimer: Timer?
    private var pinTicks = 0

    func add(_ mark: InkMark) {
        state.marks.append(mark)
        pin(mark)
        updateVisibility()
        let id = mark.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            withAnimation(.easeOut(duration: 0.6)) { self?.state.marks.removeAll { $0.id == id } }
            try? await Task.sleep(for: .seconds(0.7))
            self?.updateVisibility()
        }
    }

    func clearMarks() {
        withAnimation(.easeOut(duration: 0.25)) { state.marks.removeAll() }
        pins.removeAll()
        updateVisibility()
    }

    // MARK: Pinning

    /// Pins a mark to the control or text under it, so it moves with the
    /// page when it scrolls and with the window when it is dragged.
    private func pin(_ mark: InkMark) {
        guard ComputerControl.hasAccessibility, let win = BackgroundInput.window(at: mark.shape.anchor),
              let element = BackgroundInput.element(at: mark.shape.anchor, pid: win.pid),
              let frame = BackgroundInput.frame(element)
        else { return }
        pins[mark.id] = (element, win.pid, frame.origin)
        if pinTimer == nil {
            let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.followPins() }
            }
            RunLoop.main.add(t, forMode: .common)
            pinTimer = t
        }
    }

    private func followPins() {
        pins = pins.filter { id, _ in state.marks.contains { $0.id == id } }
        guard !pins.isEmpty else {
            pinTimer?.invalidate()
            pinTimer = nil
            return
        }
        pinTicks += 1
        let checkCover = pinTicks % 5 == 0
        for i in state.marks.indices {
            guard let pin = pins[state.marks[i].id] else { continue }
            var mark = state.marks[i]
            if let frame = BackgroundInput.frame(pin.element) {
                let shift = CGPoint(x: frame.minX - pin.origin.x, y: frame.minY - pin.origin.y)
                if hypot(shift.x - mark.shift.x, shift.y - mark.shift.y) > 0.5 { mark.shift = shift }
                if checkCover {
                    // Hidden when another window now covers it, or it
                    // scrolled out from under its own.
                    mark.hidden = BackgroundInput.window(at: mark.placed.anchor)?.pid != pin.pid
                }
            } else {
                mark.hidden = true
            }
            if mark != state.marks[i] {
                withAnimation(mark.hidden != state.marks[i].hidden ? .easeOut(duration: 0.2) : nil) {
                    state.marks[i] = mark
                }
            }
        }
    }

    // MARK: Sketching

    func toggleSketch() {
        state.sketching ? endSketch() : startSketch()
    }

    func startSketch() {
        fadeTask?.cancel()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        state.toolbarScreen = screen?.displayID
        state.toolbarVisible = true
        state.sketching = true
        for panel in panels.values { panel.ignoresMouseEvents = false }
        updateVisibility()
        if let id = state.toolbarScreen, let panel = panels[id] {
            panel.makeKey()
        }
        NSCursor.crosshair.push()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event } // Escape
            self?.endSketch()
            return nil
        }
    }

    /// Leaves sketch mode. Strokes stay when `keepStrokes`, e.g. while
    /// Claude answers a question about them.
    func endSketch(keepStrokes: Bool = false) {
        guard state.sketching else { return }
        state.sketching = false
        state.current = nil
        if !keepStrokes { state.strokes.removeAll() }
        for panel in panels.values {
            panel.ignoresMouseEvents = true
            if panel.isKeyWindow { panel.resignKey() }
        }
        NSCursor.pop()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        updateVisibility()
    }

    /// Fades the user's strokes after a pause, once their question is answered.
    func fadeStrokes(after seconds: Double) {
        fadeTask?.cancel()
        fadeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled, !self.state.sketching else { return }
            withAnimation(.easeOut(duration: 0.6)) { self.state.strokes.removeAll() }
            try? await Task.sleep(for: .seconds(0.7))
            self.updateVisibility()
        }
    }

    /// Hides the toolbar for one screenshot.
    func withoutToolbar<T>(_ body: () async throws -> T) async rethrows -> T {
        state.toolbarVisible = false
        try? await Task.sleep(for: .milliseconds(80))
        defer { state.toolbarVisible = true }
        return try await body()
    }

    // MARK: Windows

    private func rebuildPanels() {
        for panel in panels.values { panel.orderOut(nil) }
        panels.removeAll()
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let panel = InkPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            panel.canHide = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = !state.sketching
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let origin = CGPoint(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY)
            panel.contentView = FirstMouseHostingView(rootView: InkCanvas(
                state: state, displayID: id, origin: origin, size: screen.frame.size,
                ask: { [weak self] text in self?.onAsk?(text) },
                save: { [weak self] in self?.onSave?() },
                done: { [weak self] in self?.endSketch() }
            ))
            panel.setFrame(screen.frame, display: false)
            panels[id] = panel
        }
        updateVisibility()
    }

    private func updateVisibility() {
        let visible = state.sketching || !state.marks.isEmpty || !state.strokes.isEmpty
        for panel in panels.values {
            if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        }
    }
}

final class InkPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Starts a pen stroke on the first click, even on a display whose ink
/// window is not the key window.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

private func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
private func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }

// MARK: - Views

/// Everything drawn on one display.
struct InkCanvas: View {
    @ObservedObject var state: InkState
    let displayID: CGDirectDisplayID
    let origin: CGPoint
    let size: CGSize
    var ask: (String) -> Void
    var save: () -> Void
    var done: () -> Void

    private var bounds: CGRect { CGRect(origin: origin, size: size) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if state.sketching {
                // A faint wash shows sketch mode and makes the window catch
                // the pointer everywhere.
                Color.black.opacity(0.08)
                    .contentShape(Rectangle())
                    .gesture(penGesture)
            }
            strokesLayer.allowsHitTesting(false)
            ForEach(state.marks.filter { bounds.contains($0.placed.anchor) }) { mark in
                MarkView(shape: mark.placed.offset(by: origin), label: mark.label, seed: mark.id.hashValue)
                    .opacity(mark.hidden ? 0 : 1)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            if state.sketching && state.toolbarVisible && state.toolbarScreen == displayID {
                SketchToolbar(state: state, ask: ask, save: save, done: done)
                    .frame(width: size.width)
                    .padding(.top, 54)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(.spring(duration: 0.25), value: state.sketching)
    }

    private var penGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let p = value.location + origin
                if state.current == nil {
                    state.current = InkStroke(points: [p], color: state.penColor)
                } else if let last = state.current?.points.last, hypot(p.x - last.x, p.y - last.y) > 1.5 {
                    state.current?.points.append(p)
                }
            }
            .onEnded { _ in
                if let stroke = state.current { state.strokes.append(stroke) }
                state.current = nil
            }
    }

    private var strokesLayer: some View {
        Canvas { ctx, _ in
            for stroke in state.strokes + (state.current.map { [$0] } ?? []) {
                let pts = stroke.points.map { $0 - origin }
                guard bounds.insetBy(dx: -40, dy: -40).contains(stroke.points[0]) || pts.contains(where: {
                    CGRect(origin: .zero, size: size).contains($0)
                }) else { continue }
                let path = smoothPath(pts)
                ctx.stroke(path, with: .color(stroke.color.opacity(0.35)),
                           style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                ctx.stroke(path, with: .color(stroke.color),
                           style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// Smooths a polyline through the midpoints of its segments.
func smoothPath(_ pts: [CGPoint]) -> Path {
    var path = Path()
    guard let first = pts.first else { return path }
    path.move(to: first)
    if pts.count == 1 {
        path.addLine(to: CGPoint(x: first.x + 0.1, y: first.y))
        return path
    }
    for i in 1..<pts.count {
        let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
        path.addQuadCurve(to: mid, control: pts[i - 1])
    }
    path.addLine(to: pts[pts.count - 1])
    return path
}

/// One of Claude's marks, drawn on like a marker stroke.
struct MarkView: View {
    let shape: InkShape
    let label: String
    let seed: Int
    @State private var progress: CGFloat

    /// `animated: false` draws it complete at once (previews, snapshots).
    init(shape: InkShape, label: String, seed: Int, animated: Bool = true) {
        self.shape = shape
        self.label = label
        self.seed = seed
        _progress = State(initialValue: animated ? 0 : 1)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if case .box(let r) = shape {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.yellow.opacity(0.18 * progress))
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
            }
            if case .highlight(let r) = shape {
                // A highlighter swipe, wiped on from the left.
                RoundedRectangle(cornerRadius: 3)
                    .fill(InkPalette.highlighter.opacity(0.42))
                    .frame(width: r.width + 6, height: r.height + 2)
                    .rotationEffect(.degrees(-0.6))
                    .mask(alignment: .leading) { Rectangle().frame(width: (r.width + 10) * progress) }
                    .offset(x: r.minX - 3, y: r.minY - 1)
            }
            if case .note(let p, let text) = shape {
                Text(text)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(white: 0.12))
                    .frame(maxWidth: 180, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .background(InkPalette.highlighter, in: RoundedRectangle(cornerRadius: 4))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                    .rotationEffect(.degrees(seed % 2 == 0 ? -2.5 : 2))
                    .scaleEffect(0.6 + 0.4 * progress, anchor: .topLeading)
                    .opacity(progress)
                    .offset(x: p.x + 10, y: p.y + 10)
            }
            MarkPath(shape: shape, seed: seed)
                .trim(from: 0, to: progress)
                .stroke(InkPalette.marker, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                .shadow(color: InkPalette.marker.opacity(0.5), radius: 4)
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(InkPalette.marker, in: Capsule())
                    .fixedSize()
                    .position(labelPosition)
                    .opacity(progress)
            }
        }
        .onAppear {
            guard progress < 1 else { return }
            withAnimation(.easeOut(duration: 0.6)) { progress = 1 }
        }
    }

    private var labelPosition: CGPoint {
        switch shape {
        case .circle(let c, let r): CGPoint(x: c.x, y: c.y - r - 18)
        case .arrow(let a, _): CGPoint(x: a.x, y: a.y - 16)
        case .box(let r), .highlight(let r): CGPoint(x: r.midX, y: r.minY - 16)
        case .underline(let a, let w): CGPoint(x: a.x + w / 2, y: a.y + 20)
        case .trace(let pts): CGPoint(x: pts[0].x, y: pts[0].y - 16)
        case .note(let p, _): p
        }
    }
}

/// Hand-drawn looking outlines: a wobbly ring that overshoots its start, a
/// gently curved arrow, a slightly loose box.
struct MarkPath: Shape {
    let shape: InkShape
    let seed: Int

    func path(in _: CGRect) -> Path {
        var p = Path()
        let phase = Double(abs(seed % 628)) / 100
        switch shape {
        case .circle(let c, let r):
            let start = -2.2 + phase * 0.2
            let steps = 72
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                let a = start + t * 2 * .pi * 1.1
                let wobble = 1 + 0.05 * sin(3 * a + phase) + 0.04 * t
                let pt = CGPoint(x: c.x + cos(a) * r * 1.08 * wobble, y: c.y + sin(a) * r * 0.92 * wobble)
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
        case .arrow(let a, let b):
            let dx = b.x - a.x, dy = b.y - a.y
            let len = max(hypot(dx, dy), 1)
            let bendSign: CGFloat = seed % 2 == 0 ? 1 : -1
            let control = CGPoint(x: (a.x + b.x) / 2 - dy / len * len * 0.12 * bendSign,
                                  y: (a.y + b.y) / 2 + dx / len * len * 0.12 * bendSign)
            p.move(to: a)
            p.addQuadCurve(to: b, control: control)
            // Head, along the curve's direction at the tip.
            let tx = b.x - control.x, ty = b.y - control.y
            let tl = max(hypot(tx, ty), 1)
            let ux = tx / tl, uy = ty / tl
            let head = min(18, len * 0.35)
            for side in [-1.0, 1.0] {
                let angle = 0.5 * side
                let hx = ux * cos(angle) - uy * sin(angle)
                let hy = ux * sin(angle) + uy * cos(angle)
                p.move(to: b)
                p.addLine(to: CGPoint(x: b.x - hx * head, y: b.y - hy * head))
            }
        case .underline(let a, let w):
            // A quick marker line with a slight wave, overshooting a little.
            let steps = 24
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let pt = CGPoint(x: a.x - 3 + (w + 6) * t, y: a.y + 3 + sin(t * .pi * 2 + phase) * 1.4 + t * 1.5)
                i == 0 ? p.move(to: pt) : p.addLine(to: pt)
            }
        case .trace(let pts):
            p = smoothPath(pts)
        case .highlight, .note:
            break
        case .box(let r):
            let j: CGFloat = 3
            p.move(to: CGPoint(x: r.minX - j, y: r.minY + 1))
            p.addLine(to: CGPoint(x: r.maxX + 1, y: r.minY - 1))
            p.addLine(to: CGPoint(x: r.maxX - 1, y: r.maxY + 1))
            p.addLine(to: CGPoint(x: r.minX + 1, y: r.maxY - 1))
            p.addLine(to: CGPoint(x: r.minX - 1, y: r.minY - j))
        }
        return p
    }
}

private struct SketchToolbar: View {
    @ObservedObject var state: InkState
    var ask: (String) -> Void
    var save: () -> Void
    var done: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(InkPalette.pens.enumerated()), id: \.offset) { _, color in
                Button { state.penColor = color } label: {
                    Circle()
                        .fill(color)
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(.white, lineWidth: state.penColor == color ? 2.5 : 0))
                }
                .buttonStyle(.plain)
            }
            Divider().frame(height: 20)
            toolButton("arrow.uturn.backward", help: "Undo") { _ = state.strokes.popLast() }
                .disabled(state.strokes.isEmpty)
            toolButton("trash", help: "Clear") { state.strokes.removeAll() }
                .disabled(state.strokes.isEmpty)
            TextField("Ask about your drawing…", text: $state.question)
                .textFieldStyle(.plain)
                .frame(width: 240)
                .focused($focused)
                .onSubmit(send)
            toolButton("arrow.up.circle.fill", help: "Ask") { send() }
            toolButton("square.and.arrow.down", help: "Save drawing") { save() }
                .disabled(state.strokes.isEmpty)
            Button("Done", action: done)
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .environment(\.colorScheme, .dark)
    }

    private func toolButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.system(size: 15)) }
            .buttonStyle(.plain)
            .help(help)
    }

    private func send() {
        let text = state.question.trimmingCharacters(in: .whitespacesAndNewlines)
        state.question = ""
        focused = false
        ask(text)
    }
}

/// Sample marks, strokes and the toolbar on a fake screen. Rendered to a PNG
/// with `-CPRenderInkPreview /path/to/file.png`, for checking the look.
struct InkPreview: View {
    var body: some View {
        let state = InkState()
        state.sketching = true
        state.toolbarScreen = 1
        state.strokes = [
            InkStroke(points: (0...40).map { i in
                let t = Double(i) / 40 * 2 * .pi
                return CGPoint(x: 700 + cos(t) * 70 + sin(t * 3) * 4, y: 420 + sin(t) * 40)
            }, color: InkPalette.pens[0]),
            InkStroke(points: [CGPoint(x: 560, y: 470), CGPoint(x: 600, y: 452), CGPoint(x: 630, y: 440)],
                      color: InkPalette.pens[0]),
        ]
        return ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(white: 0.93), Color(white: 0.85)], startPoint: .top, endPoint: .bottom)
            RoundedRectangle(cornerRadius: 10).fill(.white).frame(width: 760, height: 420).offset(x: 70, y: 120)
                .shadow(radius: 8)
            Text("Quarterly report.xlsx").font(.headline).foregroundStyle(.black).offset(x: 100, y: 140)
            RoundedRectangle(cornerRadius: 6).fill(Color.blue).frame(width: 90, height: 30).offset(x: 160, y: 200)
            MarkView(shape: .circle(center: CGPoint(x: 205, y: 215), radius: 48), label: "Save button", seed: 3, animated: false)
            MarkView(shape: .arrow(from: CGPoint(x: 420, y: 300), to: CGPoint(x: 300, y: 380)), label: "Drag here", seed: 4, animated: false)
            MarkView(shape: .box(CGRect(x: 480, y: 250, width: 200, height: 46)), label: "Your total", seed: 5, animated: false)
            Text("Net revenue grew 14% this quarter").font(.title3).foregroundStyle(.black).offset(x: 100, y: 440)
            MarkView(shape: .highlight(CGRect(x: 100, y: 440, width: 330, height: 26)), label: "", seed: 6, animated: false)
            MarkView(shape: .underline(from: CGPoint(x: 100, y: 470), width: 330), label: "", seed: 7, animated: false)
            MarkView(shape: .trace([CGPoint(x: 120, y: 330), CGPoint(x: 170, y: 300), CGPoint(x: 230, y: 320),
                                    CGPoint(x: 270, y: 290), CGPoint(x: 330, y: 300)]), label: "Route", seed: 8, animated: false)
            MarkView(shape: .note(at: CGPoint(x: 690, y: 160), text: "Export as PDF first, then send it."), label: "", seed: 9, animated: false)
            InkCanvas(state: state, displayID: 1, origin: .zero, size: CGSize(width: 900, height: 600),
                      ask: { _ in }, save: {}, done: {})
        }
        .frame(width: 900, height: 600)
    }
}
