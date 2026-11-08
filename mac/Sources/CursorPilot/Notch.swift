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

    /// The open panel has a conversation (or work) to show: it drops
    /// further; with nothing yet it stays short.
    @Published var roomy = false
    /// A live caption hangs under the notch.
    @Published var captioned = false

    static let wing: CGFloat = 76
    static let panelWidth: CGFloat = 580
    /// How far the open panel reaches below the notch row.
    static let roomyBody: CGFloat = 238
    static let compactBody: CGFloat = 100
    static let captionWidth: CGFloat = 480
    static let captionBody: CGFloat = 56

    var activeSize: CGSize { CGSize(width: notchSize.width + Self.wing * 2, height: notchSize.height) }
    var expandedSize: CGSize {
        CGSize(width: max(Self.panelWidth, activeSize.width + 40),
               height: notchSize.height + (roomy ? Self.roomyBody : Self.compactBody))
    }
    var captionSize: CGSize {
        CGSize(width: max(Self.captionWidth, activeSize.width), height: notchSize.height + Self.captionBody)
    }
    /// Room for every shape the island takes; the window never changes size.
    var windowSize: CGSize {
        CGSize(width: max(Self.panelWidth, activeSize.width + 40, captionSize.width),
               height: notchSize.height + max(Self.roomyBody, Self.captionBody))
    }

    /// The island's size: the open panel, a caption under the notch, the
    /// wings while working, or the bare notch (nothing on a screen without one).
    func shapeSize(active: Bool) -> CGSize {
        if expanded { return expandedSize }
        if captioned { return captionSize }
        if active { return activeSize }
        return hasNotch ? notchSize : CGSize(width: notchSize.width, height: 0)
    }

    var bottomRadius: CGFloat { expanded ? 26 : captioned ? 22 : 10 }
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

    /// Where the island is heading, in its screen's top-left points, so the
    /// screen glow can bend around it; nil while the panel is hidden.
    var island: (screen: NSScreen, rect: CGRect, radius: CGFloat)? {
        guard timer != nil, let screen else { return nil }
        let size = state.shapeSize(active: model.phase != .idle || model.hasRunningJobs || state.captioned)
        return (screen, CGRect(x: (screen.frame.width - size.width) / 2, y: 0, width: size.width, height: size.height),
                state.bottomRadius)
    }

    /// Where the buddy's tip goes so its thinking dots land on the notch's
    /// own dots, in the right wing (Cocoa coordinates).
    var parkingSpot: CGPoint? {
        guard timer != nil, let screen else { return nil }
        let dots = CGPoint(x: screen.frame.midX + state.notchSize.width / 2 + NotchState.wing - 18 - 28,
                           y: screen.frame.maxY - state.notchSize.height / 2)
        // The buddy's dots sit 10 pt right of and 11.5 pt below its tip.
        return CGPoint(x: dots.x - 10, y: dots.y + 11.5)
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
        // The window always has room for the largest shape; the visible
        // shape inside it animates, and clicks pass through unless expanded.
        let size = state.windowSize
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
    @State private var doneFlash = false

    private var isActive: Bool { model.phase != .idle || model.hasRunningJobs || doneFlash || state.captioned }
    /// Work going on in the background: this task's or a background agent's.
    private var working: Bool { buddy.backgroundWork || model.hasRunningJobs }
    /// The open panel has something to show beyond the hint.
    private var wantsRoom: Bool {
        !model.replyText.isEmpty || !model.heardText.isEmpty || model.lastError != nil || !model.jobs.isEmpty
            || model.phase != .idle
    }
    private static let island = Animation.spring(response: 0.42, dampingFraction: 0.84)

    /// Words go where the buddy is: under the notch only while it's parked
    /// there (on screen they're in its bubble). Yours while you talk over
    /// its work, otherwise its own as it says them.
    private var caption: AppModel.LiveCaption? {
        guard buddy.docked, !state.expanded else { return nil }
        if let hearing = buddy.hearing {
            let text = hearing.isEmpty ? "Listening…" : hearing
            return AppModel.LiveCaption(you: true, spoken: AppModel.karaoke(text, heard: (text as NSString).length))
        }
        if buddy.talking, let spoken = buddy.spoken { return AppModel.LiveCaption(you: false, spoken: spoken) }
        return nil
    }

    var body: some View {
        let size = state.shapeSize(active: isActive)
        ZStack(alignment: .top) {
            if working {
                NotchGlow(bottomRadius: state.bottomRadius)
                    .transition(.opacity)
            }
            NotchShape(bottomRadius: state.bottomRadius)
                .fill(.black)
                .shadow(color: .black.opacity(state.expanded || state.captioned ? 0.4 : 0), radius: 18, y: 8)
            if working {
                NotchGlow(bottomRadius: state.bottomRadius, rim: true)
                    .transition(.opacity)
            }
            if state.expanded {
                NotchExpandedView(model: model, state: state, buddy: buddy)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .top))
                                                .animation(Self.island.delay(0.06)),
                                            removal: .opacity.animation(.easeOut(duration: 0.12))))
            } else if isActive {
                VStack(spacing: 0) {
                    wings
                    if let caption {
                        NotchCaptionLine(caption: caption)
                            .frame(height: NotchState.captionBody, alignment: .top)
                            .transition(.blurReplace)
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .opacity(size.height > 0 ? 1 : 0)
        .frame(width: state.windowSize.width, height: state.windowSize.height, alignment: .top)
        .animation(Self.island, value: state.expanded)
        .animation(Self.island, value: state.roomy)
        .animation(Self.island, value: state.captioned)
        .animation(Self.island, value: isActive)
        .animation(.easeInOut(duration: 0.5), value: working)
        .environment(\.colorScheme, .dark)
        .onChange(of: wantsRoom, initial: true) { _, room in state.roomy = room }
        .onChange(of: caption != nil, initial: true) { _, on in state.captioned = on }
    }

    private var wings: some View {
        HStack {
            if doneFlash {
                // Finished: a green check pops in for a moment.
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white, Color(red: 0.3, green: 0.85, blue: 0.5))
                    .symbolEffect(.bounce, value: doneFlash)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            } else if working {
                Image(systemName: buddy.backgroundWork ? buddy.activityIcon ?? "terminal" : "square.stack.3d.up.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .symbolEffect(.pulse, isActive: true)
                    .contentTransition(.symbolEffect(.replace))
                    .transition(.scale.combined(with: .opacity))
            } else {
                PilotArrow(flipped: false).scaleEffect(0.8)
                    .transition(.scale.combined(with: .opacity))
            }
            Spacer()
            PhaseIndicator(phase: model.phase, level: buddy.level, working: working)
                // The buddy landing in (or leaving) the dots: they take a gulp.
                .keyframeAnimator(initialValue: CGFloat(1), trigger: buddy.docked) { view, k in
                    view.scaleEffect(k)
                } keyframes: { _ in
                    KeyframeTrack {
                        SpringKeyframe(1.35, duration: 0.16, spring: .snappy)
                        SpringKeyframe(1, duration: 0.45, spring: .bouncy)
                    }
                }
        }
        .padding(.horizontal, 18)
        .frame(width: state.activeSize.width, height: state.notchSize.height)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: working)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: buddy.activityIcon)
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: doneFlash)
        .onChange(of: buddy.doneBump) { _, _ in
            doneFlash = true
            Task {
                try? await Task.sleep(for: .seconds(1.8))
                doneFlash = false
            }
        }
    }
}

/// The live voice's words under the notch while the agent works: yours as
/// you say them, then its own, read along as it speaks.
private struct NotchCaptionLine: View {
    var caption: AppModel.LiveCaption

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: caption.you ? "mic.fill" : "waveform")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.45))
                .contentTransition(.symbolEffect(.replace))
            KaraokeCaption(spoken: caption.spoken)
                .id(caption.you)
                .transition(.blurReplace)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: caption.you)
    }
}

/// Small live indicator: the wave following your voice while listening,
/// dots while thinking, the wave again while answering. The two crossfade,
/// and the wave stays the same view from listening to answering so it eases
/// from your level to its own instead of restarting.
struct PhaseIndicator: View {
    var phase: AppModel.Phase
    var level: Float
    /// A command or other background step is running: the thinking dots.
    var working = false

    var body: some View {
        let thinking = phase == .thinking || working
        ZStack {
            if !thinking && (phase == .listening || phase == .answering) {
                SpeakingWave(level: phase == .listening ? level : nil)
                    .frame(width: 56, height: 24)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
            if thinking {
                ThinkingBlobs(zoom: 2.4)
                    .frame(width: 34, height: 34).frame(height: 24)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .frame(width: 56, height: 24)
        .animation(.easeInOut(duration: 0.4), value: phase)
        .animation(.easeInOut(duration: 0.4), value: working)
    }
}

private struct NotchExpandedView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: NotchState
    @ObservedObject var buddy: OverlayState
    @FocusState private var focused: Bool

    private var busy: Bool { model.phase == .thinking || model.phase == .answering }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Group {
                if let error = model.lastError {
                    ErrorLine(text: error)
                        .transition(.blurReplace)
                } else if !state.roomy {
                    TalkHint(keys: model.talkDisplay)
                        .transition(.blurReplace)
                } else {
                    exchange
                        .transition(.blurReplace)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 10)
            composer
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .foregroundStyle(.white)
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: state.roomy)
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: model.lastError)
        .onChange(of: focused) { _, f in state.inputFocused = f }
        .onChange(of: state.focusRequest) { _, _ in focused = true }
    }

    /// Sits beside the notch, in the same row.
    private var header: some View {
        HStack(spacing: 8) {
            PilotArrow(flipped: false).scaleEffect(0.8)
            ZStack(alignment: .leading) {
                if buddy.backgroundWork, let activity = buddy.activity {
                    // What's running, quietly: the command as typed, or the step.
                    HStack(spacing: 5) {
                        Image(systemName: buddy.activityIcon ?? "terminal")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                            .contentTransition(.symbolEffect(.replace))
                        ZStack(alignment: .leading) {
                            ShimmerText(text: activity, command: buddy.activityIsCommand)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .id(activity)
                                .transition(.push(from: .bottom).combined(with: .opacity))
                        }
                        .clipped()
                        .hugWidth(150)
                    }
                    .transition(.blurReplace)
                } else {
                    Text(statusText)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .contentTransition(.interpolate)
                        .transition(.blurReplace)
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: buddy.activity)
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: statusText)
            if model.phase != .idle || buddy.backgroundWork {
                PhaseIndicator(phase: model.phase, level: buddy.level, working: buddy.backgroundWork)
                    .scaleEffect(0.8)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            Spacer(minLength: state.notchSize.width + 12)
            HStack(spacing: 2) {
                iconButton("pencil.tip", help: "Draw on screen (⌃⌥D)") { model.toggleSketch() }
                iconButton("square.and.pencil", help: "New conversation") { model.newConversation() }
                iconButton("macwindow", help: "Open Cursor Pilot") { HomeWindow.shared.show() }
                iconButton("gearshape", help: "Settings") { openSettings() }
            }
        }
        .frame(height: state.notchSize.height)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.phase)
    }

    private var statusText: String {
        switch model.phase {
        case .idle: model.jobs.contains { $0.state == "running" } ? "Working in the background" : "Cursor Pilot"
        case .listening: "Listening"
        case .thinking: buddy.backgroundWork ? "Working" : "Thinking"
        case .answering: model.lastError == nil ? "Answering" : "Something went wrong"
        }
    }

    private var exchange: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !model.heardText.isEmpty {
                        Text(model.heardText)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(model.phase == .listening ? 0.75 : 1))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(pilotAccent.opacity(model.phase == .listening ? 0.6 : 1),
                                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.leading, 70)
                            .contentTransition(.interpolate)
                    }
                    if !model.replyText.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(messageParts(model.replyText).enumerated()), id: \.offset) { _, part in
                                RichText(text: part, size: 13, subtle: .white)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white)
                                    .tint(Color(red: 0.55, green: 0.75, blue: 1))
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                        }
                        .padding(.trailing, 60)
                        .transition(.opacity)
                    }
                    if let step = model.liveSteps.last(where: { $0.phase == "start" }) {
                        HStack(spacing: 7) {
                            Image(systemName: AgentStep.icon(for: step.kind))
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.55))
                                .contentTransition(.symbolEffect(.replace))
                            ShimmerText(text: step.summary).lineLimit(1)
                        }
                        .id(step.summary)
                        .transition(.push(from: .bottom).combined(with: .opacity))
                    } else if model.phase == .thinking || (model.replyText.isEmpty && model.phase == .answering) {
                        NotchTypingDots()
                            .transition(.scale(scale: 0.7, anchor: .leading).combined(with: .opacity))
                    }
                    ForEach(model.jobs) { job in
                        JobCard(job: job) { model.stopJob(job.id) }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.vertical, 4)
                .animation(.spring(response: 0.34, dampingFraction: 0.86), value: model.replyText.count / 40)
                .animation(.spring(response: 0.34, dampingFraction: 0.86), value: model.liveSteps.last?.summary)
                .animation(.spring(response: 0.34, dampingFraction: 0.86), value: model.jobs)
            }
            .scrollIndicators(.never)
            // Words fade out under the top edge instead of being cut.
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                                         .init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .onChange(of: model.replyText) { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: model.liveSteps.count) { proxy.scrollTo("end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            Button { state.includeScreen.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: state.includeScreen ? "eye" : "eye.slash")
                        .contentTransition(.symbolEffect(.replace))
                    Text("Screen")
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(state.includeScreen ? .white : .white.opacity(0.45))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(state.includeScreen ? pilotAccent.opacity(0.45) : .white.opacity(0.07), in: Capsule())
            }
            .buttonStyle(.plain)
            .help(state.includeScreen ? "Cursor Pilot sees your screen when you ask" : "Your screen isn't sent")
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: state.includeScreen)
            TextField("", text: $state.draft, prompt: Text("Ask anything…").foregroundStyle(.white.opacity(0.4)))
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .focused($focused)
                .onSubmit(send)
                .onExitCommand {
                    focused = false
                    state.draft = ""
                }
            trailing
                .frame(width: 26, height: 26)
        }
        .padding(.leading, 6)
        .padding(.trailing, 5)
        .frame(height: 36)
        .background(.white.opacity(focused ? 0.11 : 0.075), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(focused ? 0.2 : 0.08), lineWidth: 1))
        .animation(.easeOut(duration: 0.18), value: focused)
    }

    @ViewBuilder private var trailing: some View {
        ZStack {
            if busy {
                roundButton("stop.fill", help: "Stop", fill: .white.opacity(0.18), glyph: .white) { model.interrupt() }
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            } else if !state.draft.trimmingCharacters(in: .whitespaces).isEmpty {
                roundButton("arrow.up", help: "Ask", fill: .white, glyph: .black, action: send)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            } else {
                roundButton(model.phase == .listening ? "waveform" : "mic.fill",
                            help: model.phase == .listening ? "Send what you said" : "Talk (or hold \(model.talkDisplay))",
                            fill: model.phase == .listening ? Color.red.opacity(0.85) : .white.opacity(0.1), glyph: .white) {
                    model.toggleListening()
                }
                .symbolEffect(.variableColor.iterative, isActive: model.phase == .listening)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: busy)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: state.draft.isEmpty)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: model.phase)
    }

    private func roundButton(_ name: String, help: String, fill: Color, glyph: Color,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(glyph)
                .frame(width: 26, height: 26)
                .background(fill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressButtonStyle())
        .help(help)
    }

    private func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 13, weight: .medium)).frame(width: 28, height: 26)
        }
        .buttonStyle(HoverButtonStyle())
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

/// The empty panel: how to talk to it, with the keys drawn as keys.
struct TalkHint: View {
    var keys: String

    var body: some View {
        HStack(spacing: 8) {
            Text("Hold").foregroundStyle(.white.opacity(0.55))
            HStack(spacing: 4) {
                ForEach(Array(Self.caps(keys).enumerated()), id: \.offset) { _, cap in KeyCap(label: cap) }
            }
            Text("and talk, or type below.").foregroundStyle(.white.opacity(0.55))
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.top, 4)
    }

    /// "⌃⌥" → ["⌃", "⌥"]; modifiers get a key each, the rest one key.
    static func caps(_ keys: String) -> [String] {
        let modifiers = Set("⌃⌥⇧⌘fn")
        var out: [String] = [], rest = ""
        for c in keys where c != " " && c != "+" {
            if modifiers.contains(c) && rest.isEmpty { out.append(String(c)) } else { rest.append(c) }
        }
        if !rest.isEmpty { out.append(rest) }
        return out.isEmpty ? [keys] : out
    }
}

struct KeyCap: View {
    var label: String

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary.opacity(0.9))
            .frame(minWidth: 24, minHeight: 22)
            .padding(.horizontal, label.count > 1 ? 5 : 0)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LinearGradient(colors: [.primary.opacity(0.16), .primary.opacity(0.08)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.35), radius: 0.5, y: 1)
            }
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.primary.opacity(0.14), lineWidth: 0.5))
    }
}

private struct ErrorLine: View {
    var text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(red: 1, green: 0.62, blue: 0.4))
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.88))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }
}

/// Icons in the dark panel: a soft circle comes up under the pointer.
struct HoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        @State private var hover = false
        var body: some View {
            configuration.label
                .foregroundStyle(.white.opacity(hover ? 1 : 0.7))
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(configuration.isPressed ? 0.2 : hover ? 0.11 : 0)))
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .onHover { hover = $0 }
                .animation(.easeOut(duration: 0.14), value: hover)
                .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
        }
    }
}

/// A small press-in for round buttons.
struct PressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
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

/// The notch lit up while work goes on in the background: the buddy's
/// colours turning slowly around its edge, with a glow spilling out. `rim`
/// is the crisp line drawn over the black body; otherwise the halo under it.
struct NotchGlow: View {
    var bottomRadius: CGFloat
    var rim = false
    @AppStorage("buddyTint") private var tint = BuddyTint.rainbow

    var body: some View {
        let colors = tint.colors + [tint.colors[0]]
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let ring = AngularGradient(colors: colors, center: .center, angle: .degrees(t * 70))
            let breath = 0.8 + 0.2 * sin(t * 2.2)
            Group {
                if rim {
                    NotchShape(bottomRadius: bottomRadius).inset(by: 0.75).stroke(ring, lineWidth: 1.5)
                } else {
                    ZStack {
                        NotchShape(bottomRadius: bottomRadius).stroke(ring, lineWidth: 16).blur(radius: 14)
                            .opacity(breath)
                        NotchShape(bottomRadius: bottomRadius).stroke(ring, lineWidth: 5).blur(radius: 3)
                    }
                }
            }
            // Not along the top edge, which runs under the menu bar.
            .mask(Rectangle().padding(.top, 5).padding(.horizontal, -40).padding(.bottom, -40))
        }
        .allowsHitTesting(false)
    }
}

extension NotchShape: InsettableShape {
    func inset(by amount: CGFloat) -> some InsettableShape { InsetNotch(base: self, amount: amount) }
}

struct InsetNotch: InsettableShape {
    var base: NotchShape
    var amount: CGFloat
    func path(in rect: CGRect) -> Path { base.path(in: rect.insetBy(dx: amount, dy: amount)) }
    func inset(by more: CGFloat) -> InsetNotch { InsetNotch(base: base, amount: amount + more) }
}
