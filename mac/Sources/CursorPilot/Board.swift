import AppKit
import SwiftUI

/// Something Claude puts on the whiteboard, in board units (1000 × 600,
/// top-left origin).
enum BoardItem {
    case open(title: String)
    case card(id: String, at: CGPoint, text: String, icon: String)
    case link(from: String, to: String, text: String)
    case write(at: CGPoint, text: String, size: String)
    case point(CGPoint, label: String)
    case mark(InkShape, label: String)
}

/// A board Claude drew, kept so it can be opened again from the chat: the
/// board events as they came, replayed.
struct BoardRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var conversation: String
    var title: String
    var at: Date
    var items: [String]
}

/// Boards drawn in every conversation, newest last (boards.json).
enum BoardStore {
    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cursor Pilot/boards.json")
    }

    static func load() -> [BoardRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([BoardRecord].self, from: data)) ?? []
    }

    static func save(_ records: [BoardRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(records.suffix(300)) { try? data.write(to: url, options: .atomic) }
    }
}

/// One thing drawn on the board.
struct BoardElement: Identifiable {
    enum Kind {
        case card(rect: CGRect, text: String, icon: String, tint: Color)
        case link(from: CGPoint, to: CGPoint, text: String)
        case write(center: CGPoint, text: String, size: String)
        case mark(InkShape, label: String)
    }

    let id = UUID()
    var kind: Kind
    var duration: Double
}

@MainActor
final class BoardState: ObservableObject {
    @Published var title = ""
    @Published var elements: [BoardElement] = []
    /// Points per board unit.
    @Published var scale: CGFloat = 1
    @Published var shown = false
}

/// A whiteboard over the user's screen, where Claude draws an explanation
/// while it talks: cards, arrows between them, handwriting and any of its
/// marks. The buddy holds the pen. It stays until the user closes it.
@MainActor
final class BoardController {
    static let units = CGSize(width: 1000, height: 600)
    /// Room for the title above the drawing area, and around it.
    static let header: CGFloat = 58
    static let pad: CGFloat = 22

    let state = BoardState()
    private var panel: NSPanel?
    /// Cards by the id Claude gave them, for links.
    private var cards: [String: CGRect] = [:]
    private var keyMonitor: Any?
    private var closing: Task<Void, Never>?

    var isOpen: Bool { panel?.isVisible == true }
    var windowNumber: Int? { isOpen ? panel?.windowNumber : nil }

    /// Opens a fresh board (or clears the open one) on the screen with the pointer.
    func open(title: String) {
        closing?.cancel()
        cards.removeAll()
        state.elements.removeAll()
        state.title = title
        if isOpen { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let width = min(visible.width * 0.74, (visible.height * 0.8 - Self.header - Self.pad) * Self.units.width / Self.units.height)
        state.scale = width / Self.units.width
        let size = CGSize(width: width + 2 * Self.pad,
                          height: width * Self.units.height / Self.units.width + Self.header + Self.pad)
        let frame = CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                           width: size.width, height: size.height)
        let panel = BoardPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = FirstMouseHostingView(rootView: BoardView(state: state) { [weak self] in self?.close() })
        panel.applyRecordingVisibility()
        panel.orderFrontRegardless()
        self.panel = panel
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { state.shown = true }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return } // Escape
            MainActor.assumeIsolated { self?.close() }
        }
    }

    /// Closes the board once the explanation is over and it's been there a
    /// while to look at, but never while the pointer is on it.
    func closeSoon(after seconds: Double = 14) {
        guard isOpen else { return }
        closing?.cancel()
        closing = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            while !Task.isCancelled, let panel = self?.panel, panel.frame.contains(NSEvent.mouseLocation) {
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    /// Draws a saved board again, quickly and without the pen.
    func replay(_ record: BoardRecord) {
        open(title: record.title)
        state.title = record.title
        Task {
            for raw in record.items {
                guard let item = boardItem(json: raw) else { continue }
                if case .open = item { continue }
                await add(item, overlay: nil)
                try? await Task.sleep(for: .seconds(0.12))
            }
        }
    }

    func close() {
        closing?.cancel()
        guard let panel else { return }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        withAnimation(.easeIn(duration: 0.2)) { state.shown = false }
        self.panel = nil
        Task {
            try? await Task.sleep(for: .seconds(0.25))
            panel.orderOut(nil)
        }
    }

    /// Board units → global top-left points, wherever the board was dragged.
    func global(_ p: CGPoint) -> CGPoint {
        guard let panel else { return p }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let topLeft = CGPoint(x: panel.frame.minX, y: primaryHeight - panel.frame.maxY)
        return CGPoint(x: topLeft.x + Self.pad + p.x * state.scale, y: topLeft.y + Self.header + p.y * state.scale)
    }

    /// Draws an item with the buddy as the pen. Opens a board first if
    /// Claude drew on one without saying so.
    /// With no overlay (a replay) it draws quickly, without the buddy.
    func add(_ item: BoardItem, overlay: OverlayController?) async {
        if case .open(let title) = item { return open(title: title) }
        if !isOpen { open(title: "") }
        closing?.cancel()
        let kind: BoardElement.Kind
        let path: Path
        switch item {
        case .open:
            return
        case .point(let p, let label):
            overlay?.point(atTopLeft: global(p), label: label)
            return
        case .card(let id, let at, let text, let icon):
            let w = min(max(CGFloat(text.count) * 11 + (icon.isEmpty ? 56 : 92), 130), 300)
            let rect = CGRect(x: at.x - w / 2, y: at.y - 34, width: w, height: 68)
            cards[id.lowercased()] = rect
            kind = .card(rect: rect, text: text, icon: icon, tint: Self.tints[cards.count % Self.tints.count])
            path = Path(roundedRect: rect, cornerRadius: 16)
        case .link(let from, let to, let text):
            guard let a = cards[from.lowercased()], let b = cards[to.lowercased()] else { return }
            let (p, q) = Self.edges(a, b)
            kind = .link(from: p, to: q, text: text)
            path = MarkPath(shape: .arrow(from: p, to: q), seed: 2).path(in: .zero)
        case .write(let at, let text, let size):
            let width = CGFloat(text.count) * Self.fontSize(size) * 0.52
            kind = .write(center: at, text: text, size: size)
            // The pen runs along the line as the words appear.
            var p = Path()
            p.move(to: CGPoint(x: at.x - width / 2, y: at.y + 4))
            p.addLine(to: CGPoint(x: at.x + width / 2, y: at.y + 2))
            path = p
        case .mark(let shape, let label):
            kind = .mark(shape, label: label)
            path = shape.penPath
        }
        let (points, duration) = samplePen(path, fallback: .zero)
        guard let overlay else {
            state.elements.append(BoardElement(kind: kind, duration: min(duration, 0.45)))
            return
        }
        await overlay.draw(along: points.map(global), duration: duration, ink: InkPalette.marker) {
            state.elements.append(BoardElement(kind: kind, duration: duration))
        }
    }

    static let tints: [Color] = Array(pilotRainbow.dropLast())

    /// Text size in board units.
    static func fontSize(_ size: String) -> CGFloat {
        switch size {
        case "title": 44
        case "small": 20
        default: 27
        }
    }

    /// Where an arrow from card `a` to card `b` leaves and arrives: on their
    /// edges, along the line between their centres, with a little air.
    private static func edges(_ a: CGRect, _ b: CGRect) -> (CGPoint, CGPoint) {
        func exit(_ r: CGRect, toward t: CGPoint) -> CGPoint {
            let c = CGPoint(x: r.midX, y: r.midY)
            let dx = t.x - c.x, dy = t.y - c.y
            guard dx != 0 || dy != 0 else { return c }
            let k = min(abs(dx) > 0 ? (r.width / 2 + 10) / abs(dx) : .infinity,
                        abs(dy) > 0 ? (r.height / 2 + 10) / abs(dy) : .infinity)
            return CGPoint(x: c.x + dx * k, y: c.y + dy * k)
        }
        let ca = CGPoint(x: a.midX, y: a.midY), cb = CGPoint(x: b.midX, y: b.midY)
        return (exit(a, toward: cb), exit(b, toward: ca))
    }
}

final class BoardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

// MARK: - Views

struct BoardView: View {
    @ObservedObject var state: BoardState
    /// False draws everything finished at once (previews).
    var animated = true
    var close: () -> Void

    var body: some View {
        let k = state.scale
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(AngularGradient(colors: pilotRainbow, center: .center))
                    .frame(width: 10, height: 10)
                Text(state.title.isEmpty ? "Whiteboard" : state.title)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .contentTransition(.opacity)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 26, height: 26)
                        .background(.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Close the board (Esc)")
            }
            .padding(.horizontal, BoardController.pad)
            .frame(height: BoardController.header)
            ZStack(alignment: .topLeading) {
                ForEach(state.elements) { e in
                    BoardElementView(element: e, scale: k, animated: animated)
                }
            }
            .frame(width: BoardController.units.width * k, height: BoardController.units.height * k, alignment: .topLeading)
            .padding(.horizontal, BoardController.pad)
            .padding(.bottom, BoardController.pad)
        }
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Color(white: 0.06).opacity(0.72))
                DotGrid().clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.12))
            }
            .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
        }
        .environment(\.colorScheme, .dark)
        .scaleEffect(state.shown ? 1 : 0.96)
        .opacity(state.shown ? 1 : 0)
        .padding(0)
    }
}

/// The faint dots of a whiteboard's grid.
private struct DotGrid: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 26
            var y: CGFloat = step / 2
            while y < size.height {
                var x: CGFloat = step / 2
                while x < size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8)),
                             with: .color(.white.opacity(0.07)))
                    x += step
                }
                y += step
            }
        }
        .allowsHitTesting(false)
    }
}

/// One element, drawn on over its duration like the pen draws it.
struct BoardElementView: View {
    let element: BoardElement
    let scale: CGFloat
    var animated = true
    @State private var progress: CGFloat = 0

    var body: some View {
        content
            .onAppear {
                guard animated else { progress = 1; return }
                withAnimation(.linear(duration: element.duration)) { progress = 1 }
            }
    }

    @ViewBuilder private var content: some View {
        let k = scale
        switch element.kind {
        case .card(let rect, let text, let icon, let tint):
            let r = CGRect(x: rect.minX * k, y: rect.minY * k, width: rect.width * k, height: rect.height * k)
            ZStack {
                RoundedRectangle(cornerRadius: 16 * k, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .opacity(Double(max(0, progress - 0.5) * 2))
                RoundedRectangle(cornerRadius: 16 * k, style: .continuous)
                    .trim(from: 0, to: progress)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .shadow(color: tint.opacity(0.45), radius: 6)
                HStack(spacing: 10 * k) {
                    if !icon.isEmpty {
                        Image(systemName: icon)
                            .font(.system(size: 26 * k, weight: .medium))
                            .foregroundStyle(tint)
                    }
                    Text(text)
                        .font(.system(size: 22 * k, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                }
                .padding(.horizontal, 14 * k)
                .opacity(Double(max(0, progress - 0.4) / 0.6))
            }
            .frame(width: r.width, height: r.height)
            .position(x: r.midX, y: r.midY)
        case .link(let a, let b, let text):
            let p = CGPoint(x: a.x * k, y: a.y * k), q = CGPoint(x: b.x * k, y: b.y * k)
            MarkPath(shape: .arrow(from: p, to: q), seed: 2)
                .trim(from: 0, to: progress)
                .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 15 * k, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Color(white: 0.16), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
                    .fixedSize()
                    .position(labelSpot(p, q, text: text, k: k))
                    .opacity(Double(progress))
            }
        case .write(let c, let text, let size):
            Text(text)
                .font(.system(size: BoardController.fontSize(size) * k,
                              weight: size == "title" ? .bold : .medium, design: .rounded))
                .foregroundStyle(size == "small" ? .white.opacity(0.7) : .white)
                .fixedSize()
                // Written on from the left, as the pen moves along.
                .mask(alignment: .leading) {
                    GeometryReader { g in Rectangle().frame(width: g.size.width * progress) }
                }
                .position(x: c.x * k, y: c.y * k)
        case .mark(let shape, let label):
            MarkView(shape: shape.scaled(k), label: label, seed: element.id.hashValue,
                     duration: element.duration, animated: animated)
        }
    }
}

/// Where a link's words go: on the arrow's middle, or above it when the
/// arrow is too short for them to sit on it without hiding it.
private func labelSpot(_ p: CGPoint, _ q: CGPoint, text: String, k: CGFloat) -> CGPoint {
    let mid = CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
    let length = hypot(q.x - p.x, q.y - p.y)
    let width = CGFloat(text.count) * 8.5 * k + 24
    guard length < width + 40 else { return CGPoint(x: mid.x, y: mid.y - 2) }
    // Off to the side of the arrow, upwards for one that runs across.
    let nx = -(q.y - p.y) / max(length, 1), ny = (q.x - p.x) / max(length, 1)
    let side: CGFloat = ny > 0 ? -1 : 1
    return CGPoint(x: mid.x + nx * side * 24, y: mid.y + ny * side * 24)
}

/// A finished sample board, rendered with `-CPRenderBoardPreview out.png`.
struct BoardPreview: View {
    var body: some View {
        let state = BoardState()
        state.title = "How DNS finds a website"
        state.scale = 0.9
        state.shown = true
        let mac = CGRect(x: 60, y: 236, width: 200, height: 68)
        let resolver = CGRect(x: 400, y: 236, width: 220, height: 68)
        let root = CGRect(x: 760, y: 90, width: 190, height: 68)
        let site = CGRect(x: 760, y: 380, width: 190, height: 68)
        let tints = BoardController.tints
        state.elements = [
            BoardElement(kind: .card(rect: mac, text: "Your Mac", icon: "laptopcomputer", tint: tints[0]), duration: 0),
            BoardElement(kind: .card(rect: resolver, text: "DNS resolver", icon: "server.rack", tint: tints[1]), duration: 0),
            BoardElement(kind: .card(rect: root, text: "Name servers", icon: "globe", tint: tints[2]), duration: 0),
            BoardElement(kind: .card(rect: site, text: "apple.com", icon: "applelogo", tint: tints[3]), duration: 0),
            BoardElement(kind: .link(from: CGPoint(x: 270, y: 270), to: CGPoint(x: 390, y: 270), text: "where is apple.com?"), duration: 0),
            BoardElement(kind: .link(from: CGPoint(x: 600, y: 226), to: CGPoint(x: 760, y: 150), text: "asks"), duration: 0),
            BoardElement(kind: .link(from: CGPoint(x: 600, y: 314), to: CGPoint(x: 760, y: 400), text: "17.253.144.10"), duration: 0),
            BoardElement(kind: .write(center: CGPoint(x: 330, y: 470), text: "The answer is cached, so the next visit is instant", size: "body"), duration: 0),
            BoardElement(kind: .mark(.step(CGPoint(x: 70, y: 220), 1), label: ""), duration: 0),
            BoardElement(kind: .mark(.underline(from: CGPoint(x: 110, y: 492), width: 210), label: ""), duration: 0),
        ]
        return ZStack {
            LinearGradient(colors: [Color(red: 0.25, green: 0.3, blue: 0.45), Color(red: 0.55, green: 0.4, blue: 0.5)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            BoardView(state: state, animated: false) {}
                .frame(width: BoardController.units.width * 0.9 + 2 * BoardController.pad)
        }
        .frame(width: 1040, height: 700)
    }
}
