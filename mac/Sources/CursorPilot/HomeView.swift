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

/// The main window: pinned chats and the rest by date in the sidebar with
/// Drawings and Settings, the open page on the right, and ⌘K over all of it.
struct HomeView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var nav: HomeNavigation = .shared
    @ObservedObject private var ui = ChatUI.shared
    @ObservedObject private var pins = ChatPins.shared
    @State private var search = ""
    /// Chats whose messages hold the search words, with the words around them.
    @State private var hits: [String: String] = [:]
    @State private var renaming: String?
    @State private var renameDraft = ""
    @State private var pendingDelete: ConversationSummary?
    @FocusState private var renameFocused: Bool

    private var onChat: Bool {
        if case .chat = nav.destination ?? .chat("") { return true }
        return false
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 500)
        .overlay {
            if ui.palette {
                CommandPalette(model: model, isPresented: $ui.palette, actions: paletteActions) { id in
                    nav.destination = .chat(id)
                }
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: ui.palette)
        .onChange(of: nav.destination) { _, d in
            guard case .chat(let id) = d else {
                if ui.finding { ui.endFind() }
                return
            }
            model.openConversation(id)
            // Picked from a search of the messages: show where the words are.
            let q = search.trimmingCharacters(in: .whitespaces)
            if !q.isEmpty, hits[id] != nil { ui.startFind(q) } else if ui.finding { ui.endFind() }
        }
        .onChange(of: model.currentConversationID) { _, id in
            // A question asked from anywhere lands in the conversation it belongs to.
            if onChat { nav.destination = .chat(id) }
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
            // These work anywhere in the window.
            Button("") { newChat() }.keyboardShortcut("n").hidden()
            Button("") { nav.destination = .settings }.keyboardShortcut(",").hidden()
            Button("") { ui.palette.toggle() }.keyboardShortcut("k").hidden()
            Button("") { if onChat { ui.startFind() } }.keyboardShortcut("f").hidden()
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        let q = search.trimmingCharacters(in: .whitespaces)
        return ScrollViewReader { proxy in
            sidebarList(q)
                .onChange(of: ui.demoSidebarEnd) {
                    if let last = model.conversations.min(by: { $0.updatedAt < $1.updatedAt }) { proxy.scrollTo(last.id) }
                }
        }
    }

    private func sidebarList(_ q: String) -> some View {
        List(selection: $nav.destination) {
            Section {
                Label("Drawings", systemImage: "scribble.variable").tag(HomeDestination.drawings)
                Label("Settings", systemImage: "gearshape").tag(HomeDestination.settings)
            }
            if !q.isEmpty {
                let found = results(q)
                Section(found.isEmpty ? "No matches" : found.count == 1 ? "1 chat" : "\(found.count) chats") {
                    ForEach(found) { chatRow($0, snippet: hits[$0.id]) }
                }
            } else {
                if model.conversations.isEmpty {
                    Text("No chats yet")
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                }
                let pinned = pins.ids.compactMap { id in model.conversations.first { $0.id == id } }
                if !pinned.isEmpty {
                    Section("Pinned") {
                        ForEach(pinned) { chatRow($0) }
                    }
                }
                ForEach(groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.items) { chatRow($0) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: "Search all chats")
        .task(id: search) { await searchMessages() }
        .onDeleteCommand {
            if case .chat(let id) = nav.destination, let c = model.conversations.first(where: { $0.id == id }) {
                pendingDelete = c
            }
        }
        // The name stays put above the chats, on a bar of its own that the
        // list is cut off under, like the search field above it.
        .pinnedTopBar {
            BrandMark()
                .frame(height: 46)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StatusFooter(model: model) { ui.palette = true }.background(.bar)
        }
        .toolbar {
            ToolbarItem {
                Button(action: newChat) { Label("New Chat", systemImage: "square.and.pencil") }
                    .help("New chat (⌘N)")
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: pins.ids)
    }

    @ViewBuilder private func chatRow(_ c: ConversationSummary, snippet: String? = nil) -> some View {
        let pinned = pins.contains(c.id)
        Group {
            if renaming == c.id {
                TextField("Name", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .focused($renameFocused)
                    .onSubmit { commitRename(c.id) }
                    .onExitCommand { renaming = nil }
                    .onChange(of: renameFocused) { _, focused in if !focused { commitRename(c.id) } }
            } else {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.displayTitle).lineLimit(1)
                        Text(snippet ?? rowDetail(c))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(snippet == nil ? 1 : 2)
                    }
                    Spacer(minLength: 0)
                    // The chat that's being answered right now.
                    if c.id == model.currentConversationID && model.phase != .idle {
                        ProgressView().controlSize(.mini)
                    }
                }
            }
        }
        .tag(HomeDestination.chat(c.id))
        .contextMenu {
            Button(pinned ? "Unpin" : "Pin") { pins.toggle(c.id) }
            Button("Rename") { startRename(c) }
            Divider()
            Button("Save as Markdown…") { if let t = model.core.transcript(id: c.id) { ChatExport.save(t) } }
            Button("Copy as Markdown") { if let t = model.core.transcript(id: c.id) { ChatExport.copy(t) } }
            Divider()
            Button("Delete…", role: .destructive) { pendingDelete = c }
        }
        .swipeActions(edge: .leading) {
            Button { pins.toggle(c.id) } label: { Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") }
                .tint(.orange)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { pendingDelete = c } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func rowDetail(_ c: ConversationSummary) -> String {
        let when = Date(timeIntervalSince1970: TimeInterval(c.updatedAt)).formatted(.relative(presentation: .named))
        guard c.turnCount > 0 else { return when }
        return "\(when) · \(c.turnCount) \(c.turnCount == 1 ? "message" : "messages")"
    }

    /// Chats found by name or by what was said in them, newest first.
    private func results(_ q: String) -> [ConversationSummary] {
        model.conversations
            .filter { $0.title.localizedCaseInsensitiveContains(q) || hits[$0.id] != nil }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Reads every chat for the search words, off the main thread, once the
    /// typing pauses.
    private func searchMessages() async {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else {
            hits = [:]
            return
        }
        try? await Task.sleep(for: .milliseconds(220))
        guard !Task.isCancelled else { return }
        let core = model.core
        let ids = model.conversations.map(\.id)
        let found = await Task.detached(priority: .userInitiated) { () -> [String: String] in
            var out: [String: String] = [:]
            for id in ids {
                guard let turn = core.transcript(id: id)?.turns.last(where: {
                    $0.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }) else { continue }
                out[id] = chatSnippet(turn.text, around: q)
            }
            return out
        }.value
        guard !Task.isCancelled else { return }
        hits = found
    }

    private var groups: [(title: String, items: [ConversationSummary])] {
        let items = model.conversations
            .filter { !pins.contains($0.id) }
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
        pins.forget(c.id)
        ChatDrafts.shared[c.id] = ""
        if wasOpen { nav.destination = .chat(model.currentConversationID) }
        pendingDelete = nil
    }

    /// What ⌘K offers besides the chats themselves.
    private var paletteActions: [CommandPalette.Entry] {
        var out: [CommandPalette.Entry] = []
        if model.phase == .thinking || model.phase == .answering {
            out.append(.init(id: "stop", icon: "stop.fill", title: "Stop what it's doing", detail: "esc") { model.interrupt() })
        }
        out.append(.init(id: "new", icon: "square.and.pencil", title: "New chat", detail: "⌘N", run: newChat))
        if onChat, !(model.openTranscript?.turns.isEmpty ?? true) {
            out.append(.init(id: "find", icon: "magnifyingglass", title: "Find in this chat", detail: "⌘F") { ui.startFind() })
            out.append(.init(id: "export", icon: "square.and.arrow.up", title: "Save this chat as Markdown", detail: "") {
                if let t = model.openTranscript { ChatExport.save(t) }
            })
            let pinned = pins.contains(model.currentConversationID)
            out.append(.init(id: "pin", icon: pinned ? "pin.slash" : "pin", title: pinned ? "Unpin this chat" : "Pin this chat", detail: "") {
                pins.toggle(model.currentConversationID)
            })
        }
        out.append(.init(id: "draw", icon: "pencil.tip", title: "Draw on your screen", detail: "⌃⌥D") { model.toggleSketch() })
        out.append(.init(id: "voice", icon: model.speakReplies ? "speaker.slash" : "speaker.wave.2",
                         title: model.speakReplies ? "Stop reading replies aloud" : "Read replies aloud", detail: "") {
            model.speakReplies.toggle()
        })
        out.append(.init(id: "drawings", icon: "scribble.variable", title: "Open Drawings", detail: "") { nav.destination = .drawings })
        out.append(.init(id: "settings", icon: "gearshape", title: "Open Settings", detail: "⌘,") { nav.destination = .settings })
        for id in AppModel.models where id != model.model {
            out.append(.init(id: "model-" + id, icon: "cpu", title: "Answer with " + Composer.shortName(id), detail: "Model") {
                model.model = id
            })
        }
        return out
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
            let count = model.openTranscript?.turns.count ?? 0
            ChatView(model: model)
                .navigationTitle(model.openTranscript.map { $0.title.isEmpty ? "New Chat" : $0.title } ?? "New Chat")
                .navigationSubtitle(count == 0 ? "" : count == 1 ? "1 message" : "\(count) messages")
        }
    }
}

extension ConversationSummary {
    var displayTitle: String { title.isEmpty ? "New Chat" : title }
}

/// What Cursor Pilot is doing right now, how to talk to it, and ⌘K.
private struct StatusFooter: View {
    @ObservedObject var model: AppModel
    var jump: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.8), radius: model.phase == .idle ? 0 : 4)
            Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Button(action: jump) {
                Text("⌘K")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressButtonStyle())
            .help("Jump to a chat or run an action")
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

struct APIKeyCard: View {
    @ObservedObject var model: AppModel
    @State private var key = ""

    private var ablit: Bool { model.usesAbliteration }

    private func save() {
        guard !key.isEmpty else { return }
        if ablit { model.abliterationKey = key } else { model.apiKey = key }
        key = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Connect your \(model.providerName) API key", systemImage: "key.fill").font(.headline)
            Text(ablit
                 ? "\(SettingsView.modelName(model.model)) runs on abliteration.ai with your own key. It's kept in your keychain and only sent to api.abliteration.ai."
                 : "Cursor Pilot talks to Claude directly with your own key. It's kept in your keychain and only sent to api.anthropic.com.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                SecureField(ablit ? "ak_…" : "sk-ant-…", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Save", action: save).disabled(key.isEmpty)
                Button("Paste") {
                    key = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    save()
                }
                .disabled(!key.isEmpty)
                Link("Get a key", destination: URL(string: ablit ? "https://abliteration.ai/console" : "https://console.anthropic.com/settings/keys")!)
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

/// A task working in the background: its colour, what it's doing, and a
/// way to stop it. Once it's over it shows its report for a moment.
struct JobCard: View {
    let job: BackgroundJob
    let stop: () -> Void
    @State private var pulse = false

    private var running: Bool { job.state == "running" }

    var body: some View {
        let colors = (BuddyTint(rawValue: job.name.lowercased()) ?? .mint).colors
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 9, height: 9)
                if running {
                    Circle()
                        .stroke(colors[0].opacity(0.5), lineWidth: 1.5)
                        .frame(width: 9, height: 9)
                        .scaleEffect(pulse ? 2.2 : 1)
                        .opacity(pulse ? 0 : 1)
                }
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(running ? job.status : captionText(job.status))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(running ? 1 : 2)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: job.status)
            }
            Spacer(minLength: 8)
            if running {
                Text(job.name)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                Button(action: stop) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 17))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Stop this task")
            } else {
                Image(systemName: job.state == "done" ? "checkmark.circle.fill"
                      : job.state == "stopped" ? "stop.circle" : "exclamationmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(job.state == "done" ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.vertical, 7)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.6))
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

/// A whiteboard from this reply, to open again.
struct BoardChip: View {
    let record: BoardRecord
    var open: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 9) {
                Image(systemName: "rectangle.and.pencil.and.ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AngularGradient(colors: pilotRainbow, center: .center))
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.title.isEmpty ? "Whiteboard" : record.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text("Whiteboard · open again")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(hover ? 0.16 : 0.09), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.secondary.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}
