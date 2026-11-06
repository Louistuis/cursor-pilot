import AppKit
import SwiftUI

/// Layout and interaction state for the notch panel.
@MainActor
final class NotchState: ObservableObject {
    @Published var expanded = false
    @Published var draft = ""
    @Published var inputFocused = false
    /// Bumped to put the cursor in the ask field (double-tap Control).
    @Published var focusRequest = 0
    @Published var includeScreen = true
    /// Size of the hardware notch, or of a stand-in on screens without one.
    @Published var notchSize = CGSize(width: 200, height: 32)
    @Published var hasNotch = false

    static let wing: CGFloat = 76
    static let expandedSize = CGSize(width: 560, height: 236)

    var activeSize: CGSize { CGSize(width: notchSize.width + Self.wing * 2, height: notchSize.height) }
    var expandedSize: CGSize {
        CGSize(width: max(Self.expandedSize.width, activeSize.width + 40),
               height: notchSize.height + Self.expandedSize.height - 32)
    }
}

/// Lets the borderless panel take keyboard focus for the text field
/// without activating the app.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// A panel that drops out of the notch: wings show what Cursor Pilot is
/// doing, hovering opens the latest exchange and a quick-ask field.
@MainActor
final class NotchController {
    let state = NotchState()
    private let model: AppModel
    private let panel: NotchPanel
    private var timer: Timer?
    /// `-CPPinNotch YES` keeps the panel open, for screenshots and design work.
    private let pinned = UserDefaults.standard.bool(forKey: "CPPinNotch")
    private var hoverStart: CFTimeInterval?
    private var leftAt: CFTimeInterval?
    private var screenObserver: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.canHide = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.contentView = NSHostingView(rootView: NotchRootView(model: model, state: state,
                                                                  buddy: model.overlay.state))
        panel.applyRecordingVisibility()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.layout() } }
    }

    func show() {
        layout()
        panel.orderFrontRegardless()
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        if pinned { setExpanded(true) }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        setExpanded(false)
        panel.orderOut(nil)
    }

    /// The built-in display if it has a notch, otherwise the main display.
    private var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    private func layout() {
        guard let screen else { return }
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            state.hasNotch = true
            state.notchSize = CGSize(width: screen.frame.width - left.width - right.width,
                                     height: screen.safeAreaInsets.top)
        } else {
            state.hasNotch = false
            state.notchSize = CGSize(width: 180, height: max(24, screen.frame.maxY - screen.visibleFrame.maxY))
        }
        // The window always has room for the expanded panel; the visible
        // shape inside it animates, and clicks pass through unless expanded.
        let size = state.expandedSize
        panel.setFrame(CGRect(x: (screen.frame.midX - size.width / 2).rounded(),
                              y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }

    private func tick() {
        guard let screen else { return }
        let mouse = NSEvent.mouseLocation
        let now = CACurrentMediaTime()
        let top = screen.frame.maxY
        if state.expanded {
            let size = state.expandedSize
            let rect = CGRect(x: screen.frame.midX - size.width / 2, y: top - size.height,
                              width: size.width, height: size.height).insetBy(dx: -12, dy: -12)
            if pinned || rect.contains(mouse) || state.inputFocused || !state.draft.isEmpty {
                leftAt = nil
            } else if let t = leftAt {
                if now - t > 0.5 { setExpanded(false) }
            } else {
                leftAt = now
            }
        } else {
            // On a notch screen the notch itself is the target; elsewhere a
            // thin strip at the very top centre, so menus keep working.
            let width = state.hasNotch ? state.notchSize.width + 12 : state.notchSize.width
            let height = state.hasNotch ? state.notchSize.height : 3
            let rect = CGRect(x: screen.frame.midX - width / 2, y: top - height, width: width, height: height + 1)
            if rect.contains(mouse) {
                if let t = hoverStart {
                    if now - t > 0.15 { setExpanded(true) }
                } else {
                    hoverStart = now
                }
            } else {
                hoverStart = nil
            }
        }
    }

    /// Opens the panel with the cursor in the ask field, to type a question.
    func openForTyping() {
        if timer == nil { show() }
        setExpanded(true)
        panel.makeKey()
        state.focusRequest &+= 1
    }

    func setExpanded(_ expanded: Bool) {
        guard state.expanded != expanded else { return }
        hoverStart = nil
        leftAt = nil
        state.expanded = expanded
        panel.ignoresMouseEvents = !expanded
        if !expanded {
            state.inputFocused = false
            if panel.isKeyWindow { panel.resignKey() }
        }
    }
}

// MARK: - Views

/// Notch silhouette: flat top that curves outward into the menu bar, and
/// rounded bottom corners.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var topRadius: CGFloat = 6

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in r: CGRect) -> Path {
        let t = topRadius, b = min(bottomRadius, (r.height - t) / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: NotchState
    @ObservedObject var buddy: OverlayState

    private var isActive: Bool { model.phase != .idle }

    private var shapeSize: CGSize {
        if state.expanded { return state.expandedSize }
        if isActive { return state.activeSize }
        return state.hasNotch ? state.notchSize : CGSize(width: state.notchSize.width, height: 0)
    }

    var body: some View {
        let size = shapeSize
        ZStack(alignment: .top) {
            NotchShape(bottomRadius: state.expanded ? 24 : 10)
                .fill(.black)
                .shadow(color: .black.opacity(state.expanded ? 0.35 : 0), radius: 16, y: 6)
            if state.expanded {
                NotchExpandedView(model: model, state: state, buddy: buddy)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            } else if isActive {
                wings
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .opacity(size.height > 0 ? 1 : 0)
        .frame(width: state.expandedSize.width, height: state.expandedSize.height, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: state.expanded)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: isActive)
        .environment(\.colorScheme, .dark)
    }

    private var wings: some View {
        HStack {
            if buddy.backgroundWork {
                Image(systemName: "terminal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .symbolEffect(.pulse, isActive: true)
                    .transition(.scale.combined(with: .opacity))
            } else {
                PilotArrow(flipped: false).scaleEffect(0.8)
                    .transition(.scale.combined(with: .opacity))
            }
            Spacer()
            PhaseIndicator(phase: model.phase, level: buddy.level)
        }
        .padding(.horizontal, 18)
        .frame(height: state.notchSize.height)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: buddy.backgroundWork)
    }
}

/// Small live indicator: waveform while listening, dots while thinking,
/// a speaker while answering.
struct PhaseIndicator: View {
    var phase: AppModel.Phase
    var level: Float

    var body: some View {
        switch phase {
        case .idle: EmptyView()
        case .listening: VoiceOrb(level: level).frame(width: 30, height: 30).frame(height: 24)
        case .thinking: ThinkingBlobs().frame(width: 34, height: 34).frame(height: 24)
        case .answering: SpeakingWave().frame(width: 56, height: 24)
        }
    }
}

private struct NotchExpandedView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: NotchState
    @ObservedObject var buddy: OverlayState
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            exchange
            Spacer(minLength: 0)
            composer
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 16)
        .foregroundStyle(.white)
        .onChange(of: focused) { _, f in state.inputFocused = f }
        .onChange(of: state.focusRequest) { _, _ in focused = true }
    }

    /// Sits beside the notch, in the same row.
    private var header: some View {
        HStack(spacing: 8) {
            PilotArrow(flipped: false).scaleEffect(0.8)
            Text(statusText).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7))
            PhaseIndicator(phase: model.phase, level: buddy.level)
            Spacer(minLength: state.notchSize.width + 12)
            iconButton("pencil.tip", help: "Draw on screen (⌃⌥D)") { model.toggleSketch() }
            iconButton("plus.bubble", help: "New conversation") { model.newConversation() }
            iconButton("house", help: "Open Home") { HomeWindow.shared.show() }
            iconButton("gearshape", help: "Settings") { openSettings() }
        }
        .frame(height: state.notchSize.height)
    }

    private var statusText: String {
        switch model.phase {
        case .idle: "Cursor Pilot"
        case .listening: "Listening"
        case .thinking: "Looking"
        case .answering: model.lastError == nil ? "Answering" : "Problem"
        }
    }

    @ViewBuilder private var exchange: some View {
        if let error = model.lastError {
            Text(error).font(.system(size: 13)).foregroundStyle(.red.opacity(0.9))
        } else if model.replyText.isEmpty && model.heardText.isEmpty {
            Text("Hold \(model.talkDisplay) and talk, or type a question below.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.55))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if !model.heardText.isEmpty {
                            Text(model.heardText)
                                .font(.system(size: 12.5))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(pilotAccent, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .padding(.leading, 60)
                        }
                        ForEach(Array(messageParts(model.replyText).enumerated()), id: \.offset) { _, part in
                            RichText(text: part, size: 12.5, subtle: .white)
                                .font(.system(size: 12.5))
                                .foregroundStyle(.white)
                                .tint(Color(red: 0.55, green: 0.75, blue: 1))
                                .textSelection(.enabled)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                                .padding(.trailing, 40)
                        }
                        if model.phase == .thinking || (model.replyText.isEmpty && model.phase == .answering) {
                            NotchTypingDots()
                        }
                        if let step = model.liveSteps.last(where: { $0.phase == "start" }) {
                            Label(step.summary, systemImage: AgentStep.icon(for: step.kind))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.replyText.count / 40)
                }
                .scrollIndicators(.never)
                .onChange(of: model.replyText) { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            Button { state.includeScreen.toggle() } label: {
                Image(systemName: state.includeScreen ? "display" : "display.trianglebadge.exclamationmark")
                    .foregroundStyle(state.includeScreen ? pilotAccent : .white.opacity(0.4))
            }
            .buttonStyle(.plain)
            .help(state.includeScreen ? "Screenshots included" : "Screenshots off")
            TextField("", text: $state.draft, prompt: Text("Ask Cursor Pilot…").foregroundStyle(.white.opacity(0.4)))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit(send)
                .onExitCommand {
                    focused = false
                    state.draft = ""
                }
            if model.phase == .idle {
                iconButton("arrow.up.circle.fill", help: "Send", action: send)
                    .disabled(state.draft.trimmingCharacters(in: .whitespaces).isEmpty)
            } else {
                iconButton("stop.circle.fill", help: "Stop") { model.interrupt() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 14)).frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.8))
        .help(help)
    }

    private func send() {
        let text = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        state.draft = ""
        focused = false
        Task { await model.ask(text, includeScreen: state.includeScreen) }
    }
}

@MainActor
func openSettings() {
    HomeWindow.shared.show(.settings)
}

/// Three dots in a dark bubble while the reply is on its way.
private struct NotchTypingDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3) { i in
                    let phase = (sin(t * 5.5 - Double(i) * 0.9) + 1) / 2
                    Circle().fill(.white).frame(width: 5, height: 5).opacity(0.3 + 0.5 * phase)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.white.opacity(0.12), in: Capsule())
        }
    }
}
