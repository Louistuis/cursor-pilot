import SwiftUI

/// Where the Home window is: a chat, the drawings, or settings.
enum HomeDestination: Hashable {
    case chat(String)
    case drawings
    case settings
}

/// Shared so the menu bar, the notch and ⌘, can open Home on a page.
@MainActor
final class HomeNavigation: ObservableObject {
    static let shared = HomeNavigation()
    @Published var destination: HomeDestination?
}

/// The main window: chats grouped by date in the sidebar with Drawings and
/// Settings, the open page on the right.
struct HomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var nav: HomeNavigation = .shared
    @State private var search = ""
    @State private var renaming: String?
    @State private var renameDraft = ""
    @State private var pendingDelete: ConversationSummary?
    @FocusState private var renameFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 500)
        .onChange(of: nav.destination) { _, d in
            if case .chat(let id) = d { model.openConversation(id) }
        }
        .onChange(of: model.currentConversationID) { _, id in
            // A question asked from anywhere lands in the conversation it belongs to.
            if case .chat = nav.destination ?? .chat("") { nav.destination = .chat(id) }
        }
        .onAppear {
            if nav.destination == nil { nav.destination = .chat(model.currentConversationID) }
        }
        .confirmationDialog("Delete \u{201C}\(pendingDelete?.displayTitle ?? "")\u{201D}?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let c = pendingDelete { delete(c) }
            }
        } message: {
            Text("This conversation will be removed from this Mac.")
        }
        .background {
            // ⌘N and ⌘, work anywhere in the window.
            Button("") { newChat() }.keyboardShortcut("n").hidden()
            Button("") { nav.destination = .settings }.keyboardShortcut(",").hidden()
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $nav.destination) {
            Section {
                Label("Drawings", systemImage: "scribble.variable").tag(HomeDestination.drawings)
                Label("Settings", systemImage: "gearshape").tag(HomeDestination.settings)
            }
            if model.conversations.isEmpty {
                Text(search.isEmpty ? "No chats yet" : "No matches")
                    .foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
            }
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.items) { chatRow($0) }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: "Search chats")
        .onDeleteCommand {
            if case .chat(let id) = nav.destination, let c = model.conversations.first(where: { $0.id == id }) {
                pendingDelete = c
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            BrandMark()
                .frame(height: 46)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { StatusFooter(model: model).background(.bar) }
        .toolbar {
            ToolbarItem {
                Button(action: newChat) { Label("New Chat", systemImage: "square.and.pencil") }
                    .help("New chat (⌘N)")
            }
        }
    }

    @ViewBuilder private func chatRow(_ c: ConversationSummary) -> some View {
        Group {
            if renaming == c.id {
                TextField("Name", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .focused($renameFocused)
                    .onSubmit { commitRename(c.id) }
                    .onExitCommand { renaming = nil }
                    .onChange(of: renameFocused) { _, focused in if !focused { commitRename(c.id) } }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.displayTitle).lineLimit(1)
                    Text(Date(timeIntervalSince1970: TimeInterval(c.updatedAt)), format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .tag(HomeDestination.chat(c.id))
        .contextMenu {
            Button("Rename") { startRename(c) }
            Button("Delete…", role: .destructive) { pendingDelete = c }
        }
    }

    private var groups: [(title: String, items: [ConversationSummary])] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let items = model.conversations
            .filter { q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) }
            .sorted { $0.updatedAt > $1.updatedAt }
        let cal = Calendar.current
        var out: [(String, [ConversationSummary])] = []
        func add(_ title: String, _ c: ConversationSummary) {
            if out.last?.0 == title { out[out.count - 1].1.append(c) } else { out.append((title, [c])) }
        }
        for c in items {
            let d = Date(timeIntervalSince1970: TimeInterval(c.updatedAt))
            if cal.isDateInToday(d) { add("Today", c) }
            else if cal.isDateInYesterday(d) { add("Yesterday", c) }
            else if d > Date().addingTimeInterval(-7 * 86400) { add("Previous 7 Days", c) }
            else if d > Date().addingTimeInterval(-30 * 86400) { add("Previous 30 Days", c) }
            else { add("Older", c) }
        }
        return out.map { (title: $0.0, items: $0.1) }
    }

    private func newChat() {
        model.newConversation()
        nav.destination = .chat(model.currentConversationID)
    }

    private func startRename(_ c: ConversationSummary) {
        renameDraft = c.displayTitle
        renaming = c.id
        renameFocused = true
    }

    private func commitRename(_ id: String) {
        guard renaming == id else { return }
        model.renameConversation(id, to: renameDraft)
        renaming = nil
    }

    private func delete(_ c: ConversationSummary) {
        let wasOpen = nav.destination == .chat(c.id)
        model.deleteConversation(c.id)
        if wasOpen { nav.destination = .chat(model.currentConversationID) }
        pendingDelete = nil
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        switch nav.destination {
        case .settings:
            SettingsView(model: model)
                .navigationTitle("Settings")
        case .drawings:
            DrawingsView(model: model)
                .navigationTitle("Drawings")
        case .chat, nil:
            ChatView(model: model)
                .navigationTitle(model.openTranscript.map { $0.title.isEmpty ? "New Chat" : $0.title } ?? "New Chat")
        }
    }
}

extension ConversationSummary {
    var displayTitle: String { title.isEmpty ? "New Chat" : title }
}

/// What Cursor Pilot is doing right now, and how to talk to it.
private struct StatusFooter: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.8), radius: model.phase == .idle ? 0 : 4)
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .animation(.easeInOut(duration: 0.2), value: model.phase)
    }

    private var color: Color {
        switch model.phase {
        case .idle: model.hasAPIKey ? .green : .orange
        case .listening: .red
        case .thinking: pilotAccent
        case .answering: .purple
        }
    }

    private var text: String {
        switch model.phase {
        case .idle: model.hasAPIKey ? "Ready · hold \(model.talkDisplay) to talk" : "Add your API key in Settings"
        case .listening: "Listening…"
        case .thinking: model.backgroundWork ? "Working on your Mac…" : "Thinking…"
        case .answering: "Answering…"
        }
    }
}

// MARK: - Chat

/// The open conversation, laid out like a text thread: your messages on the
/// right, Cursor Pilot's on the left, one bubble per thought.
private struct ChatView: View {
    @ObservedObject var model: AppModel
    @State private var draft = ""
    @AppStorage("composerIncludesScreen") private var includeScreen = true
    @FocusState private var composerFocused: Bool

    var body: some View {
        let turns = model.openTranscript?.turns ?? []
        // Once a request is saved it is in `turns`, even while its reply is still spoken.
        let isLive = model.phase == .listening || (model.phase != .idle && !model.requestFinished)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !model.hasAPIKey {
                        APIKeyCard(model: model).padding(.bottom, 16)
                    }
                    if turns.isEmpty && !isLive {
                        ChatEmptyState(model: model).padding(.top, 80)
                    } else {
                        ContactHeader().padding(.bottom, 6)
                    }
                    ForEach(Array(turns.enumerated()), id: \.offset) { i, turn in
                        if i == 0 || turn.at - turns[i - 1].at > 15 * 60 {
                            TimeHeader(date: Date(timeIntervalSince1970: TimeInterval(turn.at)))
                        }
                        MessageGroup(model: model, fromMe: turn.role == "user", text: turn.text,
                                     screens: turn.screens, points: turn.points, live: false,
                                     steps: (turn.steps ?? []).map { StepItem(icon: AgentStep.icon(forSummary: $0), text: $0) },
                                     key: "\(model.openTranscript?.id ?? "")#\(i)",
                                     status: !isLive && turn.role == "user" && i == turns.count - 2 ? "Read" : nil)
                            .padding(.top, i > 0 && turns[i - 1].role == turn.role ? 2 : 10)
                    }
                    if isLive {
                        if !model.heardText.isEmpty || model.phase == .listening {
                            MessageGroup(model: model, fromMe: true,
                                         text: model.heardText.isEmpty ? "…" : model.heardText,
                                         screens: 0, points: [], live: true,
                                         status: model.phase == .listening ? nil
                                             : model.replyText.isEmpty && model.liveSteps.isEmpty ? "Delivered" : "Read")
                                .padding(.top, 10)
                        }
                        if model.phase != .listening {
                            MessageGroup(model: model, fromMe: false, text: model.replyText,
                                         screens: 0, points: [], live: true,
                                         steps: model.liveSteps.map {
                                             StepItem(icon: AgentStep.icon(for: $0.kind), text: $0.summary,
                                                      running: $0.phase == "start", ok: $0.ok)
                                         })
                                .padding(.top, 10)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.replyText) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.heardText) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.liveSteps.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: turns.count) {
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .onAppear { composerFocused = true }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button { includeScreen.toggle() } label: {
                Image(systemName: includeScreen ? "eye.circle.fill" : "eye.slash.circle.fill")
                    .font(.system(size: 24))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(includeScreen ? pilotAccent : .secondary)
            }
            .buttonStyle(.plain)
            .help(includeScreen ? "Cursor Pilot sees your screen when you send" : "Screen not included")

            HStack(alignment: .bottom, spacing: 4) {
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .lineLimit(1...8)
                    .focused($composerFocused)
                    .onSubmit(send)
                    .padding(.vertical, 5)
                trailingButton
            }
            .padding(.leading, 12)
            .padding(.trailing, 3)
            .padding(.vertical, 2)
            .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.secondary.opacity(composerFocused ? 0.45 : 0.28), lineWidth: 0.8))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 740)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    @ViewBuilder private var trailingButton: some View {
        if model.phase == .thinking || model.phase == .answering {
            Button { model.interrupt() } label: {
                Image(systemName: "stop.circle.fill").font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Stop")
            .keyboardShortcut(.escape, modifiers: [])
        } else if canSend {
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white, pilotAccent)
            }
            .buttonStyle(.plain)
            .transition(.scale.combined(with: .opacity))
        } else {
            Button(action: model.toggleListening) {
                Image(systemName: model.phase == .listening ? "waveform.circle.fill" : "mic")
                    .font(.system(size: model.phase == .listening ? 22 : 15, weight: .medium))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(model.phase == .listening ? Color.red : .secondary)
                    .symbolEffect(.variableColor.iterative, isActive: model.phase == .listening)
            }
            .buttonStyle(.plain)
            .help(model.phase == .listening ? "Send what you said" : "Talk (or hold \(model.talkDisplay) anywhere)")
        }
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.hasAPIKey }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        Task { await model.ask(text, includeScreen: includeScreen) }
    }
}

/// "Today 10:42" between messages that are far apart.
private struct TimeHeader: View {
    var date: Date

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    private var label: String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return "Today \(time)" }
        if cal.isDateInYesterday(date) { return "Yesterday \(time)" }
        if let days = cal.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return "\(date.formatted(.dateTime.weekday(.wide))) \(time)"
        }
        return "\(date.formatted(.dateTime.day().month(.abbreviated))) \(time)"
    }
}

/// One side's message: a bubble per paragraph, the last with a tail, and a
/// quiet line underneath for what happened (screens, steps, points).
private struct MessageGroup: View {
    @ObservedObject var model: AppModel
    var fromMe: Bool
    var text: String
    var screens: Int
    var points: [String]
    var live: Bool
    var steps: [StepItem] = []
    /// Identifies the message for tapbacks; live messages have none.
    var key: String?
    /// "Delivered" or "Read" under your latest message.
    var status: String?
    @ObservedObject private var tapbacks = Tapbacks.shared

    var body: some View {
        let parts = paragraphs
        let working = live && !fromMe && (parts.isEmpty || steps.contains { $0.running })
        VStack(alignment: fromMe ? .trailing : .leading, spacing: 2) {
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                let partKey = key.map { "\($0).\(i)" }
                Bubble(text: part, fromMe: fromMe, tail: i == parts.count - 1 && !working,
                       tapback: partKey.flatMap { tapbacks.reactions[$0] })
                    .onTapGesture(count: 2) { if let partKey { tapbacks.toggle("❤️", for: partKey) } }
                    .contextMenu {
                        if let partKey {
                            ControlGroup {
                                ForEach(Tapbacks.choices, id: \.self) { r in
                                    Button(r) { tapbacks.toggle(r, for: partKey) }
                                }
                            }
                        }
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(fromMe ? text : part, forType: .string)
                        }
                        if !fromMe { Button("Read Aloud") { model.speak(part) } }
                    }
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.85, anchor: fromMe ? .bottomTrailing : .bottomLeading).combined(with: .opacity),
                        removal: .opacity))
            }
            if working {
                TypingBubble().transition(.scale(scale: 0.8, anchor: .bottomLeading).combined(with: .opacity))
            }
            if !steps.isEmpty {
                StepList(steps: steps, live: live).padding(.top, 2)
            }
            if fromMe && screens > 0 {
                Caption(text: screens == 1 ? "Saw your screen" : "Saw \(screens) screens")
            }
            if let status {
                Text(status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .transition(.opacity)
            }
            if !points.isEmpty {
                Caption(text: "Pointed at " + points.joined(separator: ", "))
            }
        }
        .frame(maxWidth: .infinity, alignment: fromMe ? .trailing : .leading)
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: parts.count)
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: working)
    }

    /// Cursor Pilot's thoughts come as separate texts; yours stay whole.
    private var paragraphs: [String] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return fromMe ? ["(asked about the screen)"] : [] }
        if fromMe { return [t] }
        return messageParts(t)
    }
}

let bubbleGray = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(white: 0.24, alpha: 1) : NSColor(white: 0.91, alpha: 1)
})

private struct Bubble: View {
    var text: String
    var fromMe: Bool
    var tail: Bool
    var tapback: String?

    var body: some View {
        content
            .overlay(alignment: fromMe ? .topLeading : .topTrailing) {
                if let tapback {
                    Text(tapback)
                        .font(.system(size: 13))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(fromMe ? bubbleGray : pilotAccent))
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                        .offset(x: fromMe ? -14 : 14, y: -14)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: tapback)
            .padding(.top, tapback == nil ? 0 : 10)
            .frame(maxWidth: 460, alignment: fromMe ? .trailing : .leading)
            .padding(fromMe ? .leading : .trailing, 60)
    }

    @ViewBuilder private var content: some View {
        if let emoji = bigEmoji {
            // Like Messages: a few emoji alone come big, without a bubble.
            Text(emoji).font(.system(size: 40)).padding(.vertical, 2)
        } else if let media = MediaPart.parse(text) {
            // Charts, pictures and links come on their own, like in Messages.
            switch media {
            case .chart(let spec): ChartCard(spec: spec)
            case .image(let url, let alt): ImageCard(url: url, alt: alt)
            case .link(let url): LinkCard(url: url)
            }
        } else {
            RichText(text: text, size: 13.5, subtle: fromMe ? .white : .primary)
                .font(.system(size: 13.5))
                .lineSpacing(1.5)
                .textSelection(.enabled)
                .foregroundStyle(fromMe ? Color.white : Color.primary)
                .tint(fromMe ? .white : pilotAccent)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background {
                    ZStack(alignment: fromMe ? .bottomTrailing : .bottomLeading) {
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                        if tail { BubbleTail(fromMe: fromMe).frame(width: 14, height: 16) }
                    }
                    .foregroundStyle(fromMe ? pilotAccent : bubbleGray)
                }
        }
    }

    private var bigEmoji: String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 3,
              t.unicodeScalars.allSatisfy({ $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0x238C || $0.value == 0x200D || $0.value == 0xFE0F })
        else { return nil }
        return t
    }
}

/// Tapback reactions on Cursor Pilot's and your messages, kept on this Mac.
@MainActor
final class Tapbacks: ObservableObject {
    static let shared = Tapbacks()
    static let choices = ["❤️", "👍", "👎", "😂", "‼️", "❓"]
    @Published private(set) var reactions: [String: String]

    private init() {
        reactions = UserDefaults.standard.dictionary(forKey: "tapbacks") as? [String: String] ?? [:]
    }

    func toggle(_ reaction: String, for key: String) {
        reactions[key] = reactions[key] == reaction ? nil : reaction
        UserDefaults.standard.set(reactions, forKey: "tapbacks")
    }
}

/// The top of a conversation, like Messages: who you're texting.
private struct ContactHeader: View {
    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 46, height: 46)
            Text("Cursor Pilot")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }
}

/// The little curl at the bottom corner of the last bubble in a run.
private struct BubbleTail: Shape {
    var fromMe: Bool

    func path(in r: CGRect) -> Path {
        var p = Path()
        // Drawn for the right side, mirrored for the left.
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addCurve(to: CGPoint(x: r.maxX + 4, y: r.maxY),
                   control1: CGPoint(x: r.minX + 6, y: r.maxY - 6),
                   control2: CGPoint(x: r.maxX - 4, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.minX - 8, y: r.maxY - 3),
                   control1: CGPoint(x: r.maxX - 6, y: r.maxY + 1),
                   control2: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        guard !fromMe else { return p }
        return p.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: r.minX + r.maxX, ty: 0))
    }
}

/// Three dots that rise in turn, in a bubble: Cursor Pilot is on it.
private struct TypingBubble: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    let phase = (sin((t * 5.5) - Double(i) * 0.9) + 1) / 2
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 7, height: 7)
                        .opacity(0.35 + 0.5 * phase)
                        .offset(y: -2 * phase)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(bubbleGray, in: Capsule())
        }
    }
}

private struct Caption: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 6)
    }
}

struct StepItem: Hashable {
    var icon: String
    var text: String
    var running = false
    var ok = true
}

/// What the agent did for a reply, as one quiet line under the bubbles:
/// the current step while it works, a count you can open afterwards.
private struct StepList: View {
    var steps: [StepItem]
    var live: Bool
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { open.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: current?.icon ?? steps.last?.icon ?? "terminal")
                        .font(.system(size: 9.5, weight: .semibold))
                    if let current, !open {
                        ShimmerText(text: current.text)
                    } else {
                        Text(steps.count == 1 ? "1 step" : "\(steps.count) steps")
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .lineLimit(1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                        HStack(spacing: 6) {
                            Group {
                                if step.running {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: step.ok ? step.icon : "exclamationmark.circle")
                                        .foregroundStyle(step.ok ? Color.secondary : Color.orange)
                                }
                            }
                            .frame(width: 13)
                            Text(step.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .transition(.opacity)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .padding(.leading, 2)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .frame(maxWidth: 460, alignment: .leading)
        .animation(.easeOut(duration: 0.2), value: steps)
    }

    private var current: StepItem? { live ? steps.last { $0.running } : nil }
}

private struct ChatEmptyState: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 10) {
            ShaderTile { SpeakingWave() }.frame(width: 84, height: 84)
            Text("What can I do for you?").font(.title3.weight(.semibold))
            Text("Text me here, or hold \(model.talkDisplay) anywhere and just talk.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

struct APIKeyCard: View {
    @ObservedObject var model: AppModel
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Connect your Anthropic API key", systemImage: "key.fill").font(.headline)
            Text("Cursor Pilot talks to Claude directly with your own key. It's kept in your keychain and only sent to api.anthropic.com.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                SecureField("sk-ant-…", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if !key.isEmpty { model.apiKey = key } }
                Button("Save") { model.apiKey = key }.disabled(key.isEmpty)
                Link("Get a key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
            }
        }
        .padding()
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Drawings

/// Saved drawings as a grid of thumbnails.
private struct DrawingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.drawings.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "scribble.variable").font(.system(size: 44)).foregroundStyle(.secondary)
                    Text("No drawings yet").font(.headline)
                    Text("Press ⌃⌥D to draw on your screen, then save it from the toolbar.")
                        .foregroundStyle(.secondary)
                    Button("Draw on Screen") { model.toggleSketch() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                        ForEach(model.drawings) { DrawingTile(drawing: $0, model: model) }
                    }
                    .padding(20)
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { model.toggleSketch() } label: { Label("Draw on Screen", systemImage: "pencil.tip") }
                    .help("Draw on your screen (⌃⌥D)")
            }
        }
        .onAppear { model.refreshDrawings() }
    }
}

private struct DrawingTile: View {
    let drawing: DrawingRecord
    @ObservedObject var model: AppModel
    @State private var image: NSImage?

    var body: some View {
        let url = URL(fileURLWithPath: drawing.path)
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.secondary.opacity(0.12)
                }
            }
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
            Text(drawing.title).lineLimit(1)
            Text(Date(timeIntervalSince1970: TimeInterval(drawing.createdAt)), format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button("Delete", role: .destructive) { model.deleteDrawing(drawing.id) }
        }
        .task(id: drawing.id) {
            // Decode off the main thread so scrolling stays smooth.
            image = await Task.detached(priority: .utility) { NSImage(contentsOf: url) }.value
        }
    }
}
