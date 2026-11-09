import SwiftUI

/// What the chat window is doing besides the conversation: finding, the ⌘K
/// palette, a line of feedback, and text handed to the composer.
@MainActor
final class ChatUI: ObservableObject {
    static let shared = ChatUI()
    @Published var palette = false
    @Published var finding = false
    @Published var findQuery = ""
    /// Which match is in view, counted back from the newest.
    @Published var findIndex = 0
    /// Bumped to put the caret back in the find field.
    @Published private(set) var findFocus = 0
    /// Text for the composer to take over (edit and send again).
    @Published var prefill: String?
    @Published private(set) var toast: String?
    private var toastTask: Task<Void, Never>?

    func startFind(_ query: String? = nil) {
        if let query { findQuery = query }
        findIndex = 0
        findFocus += 1
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) { finding = true }
    }

    func endFind() {
        withAnimation(.easeOut(duration: 0.18)) { finding = false }
        findQuery = ""
        findIndex = 0
    }

    func step(_ by: Int, of count: Int) {
        guard count > 0 else { return }
        findIndex = ((findIndex + by) % count + count) % count
    }

    /// `-CPHomeDemo chat:0,find:word,palette,slash,hover,side` puts Home in a
    /// state (for UI work): open the Nth newest chat, find a word, open ⌘K, open
    /// the slash menu, show every message's buttons, scroll the sidebar to its end.
    private(set) var demoHover = false
    @Published private(set) var demoSidebarEnd = 0

    func demo(_ spec: String, model: AppModel) {
        Task {
            for part in spec.split(separator: ",").map(String.init) {
                try? await Task.sleep(for: .milliseconds(500))
                let arg = part.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
                switch part.prefix(while: { $0 != ":" }) {
                case "chat":
                    let chats = model.conversations.sorted { $0.updatedAt > $1.updatedAt }
                    if let i = Int(arg), chats.indices.contains(i) { HomeNavigation.shared.destination = .chat(chats[i].id) }
                case "find": startFind(arg)
                case "palette": palette = true
                case "slash": prefill = "/" + arg
                case "hover": demoHover = true; objectWillChange.send()
                case "say": say(arg)
                case "side": demoSidebarEnd += 1
                default: break
                }
            }
        }
    }

    /// A short line above the composer that goes away by itself.
    func say(_ text: String) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { toast = text }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { toast = nil }
        }
    }
}

// MARK: - Chat

/// The open conversation, laid out like a text thread: your messages on the
/// right, Cursor Pilot's on the left, one bubble per thought, with the
/// composer floating over the bottom.
struct ChatView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var ui = ChatUI.shared
    @ObservedObject private var pins = ChatPins.shared
    @State private var atBottom = true

    var body: some View {
        let turns = model.openTranscript?.turns ?? []
        // Once a request is saved it is in `turns`, even while its reply is still spoken.
        let isLive = model.phase == .listening || (model.phase != .idle && !model.requestFinished)
        let matches = ui.finding ? findMatches(in: turns) : []
        let current: Int? = matches.isEmpty ? nil : matches[matches.count - 1 - min(ui.findIndex, matches.count - 1)]
        ScrollViewReader { proxy in
            ScrollView {
                thread(turns: turns, isLive: isLive, matches: Set(matches), current: current)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                    .frame(maxWidth: 720)
                    .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .hardTopScrollEdge()
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 140
            } action: { _, near in
                atBottom = near
            }
            // Follow the reply only while you're reading the end of it.
            .onChange(of: model.replyText) { if atBottom { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: model.heardText) { if atBottom { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: model.liveSteps.count) { if atBottom { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: turns.count) {
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: model.jobs.count) { if atBottom { proxy.scrollTo("bottom", anchor: .bottom) } }
            // Wait for the thread to lay out (a chat may have just opened),
            // then again in case the lazy rows above changed height.
            .task(id: FindTarget(chat: model.currentConversationID, index: current)) {
                guard let i = current else { return }
                try? await Task.sleep(for: .milliseconds(90))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo("m\(i)", anchor: .center) }
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                proxy.scrollTo("m\(i)", anchor: .center)
            }
            // Floats over the top of the thread, so the toolbar's own scroll
            // edge stays as the system draws it.
            .overlay(alignment: .top) {
                if ui.finding {
                    FindBar(ui: ui, count: matches.count)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // The jump button floats above the composer rather than
                // sitting in the inset: an inset that changed height with the
                // scroll position would move the thread it is measuring.
                Composer(model: model)
                    .overlay(alignment: .top) {
                        ZStack {
                            if !atBottom {
                                Button {
                                    withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("bottom", anchor: .bottom) }
                                } label: {
                                    Image(systemName: "arrow.down")
                                        .font(.system(size: 11.5, weight: .bold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 30, height: 30)
                                        .glassBackground(Circle())
                                        .contentShape(Circle())
                                }
                                .buttonStyle(PressButtonStyle())
                                .help("Jump to the latest message")
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                            }
                        }
                        .alignmentGuide(.top) { $0[.bottom] }
                        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: atBottom)
                    }
            }
            // A chat opens at its end, also once the lazy rows have their
            // real heights (unless it opened to show a search match).
            .task {
                for wait in [60, 260] {
                    try? await Task.sleep(for: .milliseconds(wait))
                    guard !Task.isCancelled, current == nil else { return }
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        // Each chat gets a scroll view of its own, so it opens at its end
        // instead of travelling there from where the last one was.
        .id(model.currentConversationID)
        .onChange(of: model.currentConversationID) { atBottom = true }
        .toolbar {
            ToolbarItemGroup {
                Button { ui.startFind() } label: { Label("Find", systemImage: "magnifyingglass") }
                    .help("Find in this chat (⌘F)")
                    .disabled(turns.isEmpty)
                Menu {
                    Button("Save as Markdown…") { if let t = model.openTranscript { ChatExport.save(t) } }
                    Button("Copy as Markdown") {
                        if let t = model.openTranscript { ChatExport.copy(t); ui.say("Copied the chat") }
                    }
                    Divider()
                    Button(pins.contains(model.currentConversationID) ? "Unpin Chat" : "Pin Chat") {
                        pins.toggle(model.currentConversationID)
                    }
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .help("Save, copy or pin this chat")
                .disabled(turns.isEmpty)
                Button { ui.palette = true } label: { Label("Jump", systemImage: "command") }
                    .help("Jump to a chat or run an action (⌘K)")
            }
        }
    }

    @ViewBuilder
    private func thread(turns: [TranscriptTurn], isLive: Bool, matches: Set<Int>, current: Int?) -> some View {
        let chatID = model.openTranscript?.id ?? ""
        LazyVStack(spacing: 0) {
            if !model.hasAPIKey {
                APIKeyCard(model: model).padding(.bottom, 16)
            }
            if turns.isEmpty && !isLive {
                ChatEmptyState(model: model, ask: ask).padding(.top, 22)
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
                             key: "\(chatID)#\(i)",
                             status: !isLive && turn.role == "user" && i == turns.count - 2 ? "Read" : nil,
                             highlight: current == i ? 2 : matches.contains(i) ? 1 : 0,
                             actions: actions(for: i, in: turns))
                    .id("m\(i)")
                    .padding(.top, i > 0 && turns[i - 1].role == turn.role ? 2 : 10)
                if turn.role == "assistant" {
                    let before = turns[..<i].last { $0.role == "assistant" }?.at ?? 0
                    ForEach(model.boards(in: chatID, after: before, until: turn.at)) { record in
                        BoardChip(record: record) { model.board.replay(record) }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                }
            }
            if !isLive, model.hasAPIKey, let last = turns.last, last.role == "assistant" {
                QuickReplies(replies: quickReplies(to: last), send: ask)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
                    .padding(.leading, 2)
                    .transition(.opacity)
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
    }

    private func ask(_ text: String) {
        Task { await model.ask(text, includeScreen: true) }
    }

    private func findMatches(in turns: [TranscriptTurn]) -> [Int] {
        let q = ui.findQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return turns.indices.filter {
            turns[$0].text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// What floats beside a saved message under the pointer.
    private func actions(for i: Int, in turns: [TranscriptTurn]) -> [HoverActions.Item] {
        let turn = turns[i]
        var items = [HoverActions.Item(icon: "doc.on.doc", help: "Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(turn.text, forType: .string)
        }]
        if turn.role == "user" {
            if !turn.text.isEmpty {
                items.append(.init(icon: "pencil", help: "Edit and send again") { ui.prefill = turn.text })
            }
        } else {
            items.append(.init(icon: "speaker.wave.2", help: "Read aloud") { model.speak(captionText(turn.text)) })
            if let question = turns[..<i].last(where: { $0.role == "user" })?.text, !question.isEmpty {
                items.append(.init(icon: "arrow.clockwise", help: "Ask again") { ask(question) })
            }
        }
        return items
    }

    /// Replies that fit the answer: yes or no to a question, "do it" after
    /// instructions, shorter after a long one.
    private func quickReplies(to answer: TranscriptTurn) -> [String] {
        let text = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("?") { return ["Yes", "No", "Tell me more"] }
        var out: [String] = []
        let didWork = !(answer.steps ?? []).isEmpty
        let listsSteps = text.range(of: #"(?m)^\s*(1[.)]|[-•*]) "#, options: .regularExpression) != nil
        if didWork {
            out.append("What did you change?")
        } else if listsSteps && model.macAccess {
            out.append("Do it for me")
        }
        if text.contains("```") {
            out.append("Explain the code")
        } else if answer.points.isEmpty && !didWork {
            out.append("Show me where")
        }
        out.append(text.count > 420 ? "Shorter, please" : "Tell me more")
        return out
    }
}

/// The match the thread should be showing.
private struct FindTarget: Hashable {
    var chat: String
    var index: Int?
}

extension View {
    /// A bar pinned over the top of a list that the rows never show through.
    @ViewBuilder func pinnedTopBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(macOS 26, *) {
            self.safeAreaBar(edge: .top, spacing: 0, content: bar)
                .scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            self.safeAreaInset(edge: .top, spacing: 0) { bar().frame(maxWidth: .infinity).background(.bar) }
        }
    }

    /// A clean line under the toolbar, so messages don't run into the title.
    @ViewBuilder func hardTopScrollEdge() -> some View {
        if #available(macOS 26, *) {
            self.scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            self
        }
    }
}

/// The strip under the toolbar for finding words in the open chat.
private struct FindBar: View {
    @ObservedObject var ui: ChatUI
    var count: Int
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Find in this chat", text: $ui.findQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit { ui.step(1, of: count) }
                .onKeyPress(.escape) { ui.endFind(); return .handled }
            Text(label)
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
            Divider().frame(height: 14)
            Button { ui.step(1, of: count) } label: { Image(systemName: "chevron.up") }
                .help("Earlier match (↩)")
                .disabled(count < 2)
            Button { ui.step(-1, of: count) } label: { Image(systemName: "chevron.down") }
                .help("Later match")
                .disabled(count < 2)
            Button("Done") { ui.endFind() }
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 13)
        .frame(height: 34)
        .frame(maxWidth: 440)
        .glassBackground(Capsule())
        .padding(.top, 8)
        .padding(.horizontal, 16)
        .onAppear { focused = true }
        .onChange(of: ui.findFocus) { focused = true }
        .onChange(of: ui.findQuery) { ui.findIndex = 0 }
    }

    private var label: String {
        if ui.findQuery.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        if count == 0 { return "No matches" }
        return "\(min(ui.findIndex, count - 1) + 1) of \(count)"
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
    /// 0 for none, 1 for a find match, 2 for the match in view.
    var highlight = 0
    /// Buttons that float beside the message under the pointer.
    var actions: [HoverActions.Item] = []
    @ObservedObject private var tapbacks = Tapbacks.shared
    @State private var hover = false

    var body: some View {
        let parts = paragraphs
        let working = live && !fromMe && (parts.isEmpty || steps.contains { $0.running })
        VStack(alignment: fromMe ? .trailing : .leading, spacing: 2) {
            ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                let partKey = key.map { "\($0).\(i)" }
                Bubble(text: part, fromMe: fromMe, tail: i == parts.count - 1 && !working,
                       tapback: partKey.flatMap { tapbacks.reactions[$0] },
                       side: i == 0 && showActions ? HoverActions(items: actions) : nil)
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
        // The whole row counts as hovered, so the pointer can travel from the
        // bubble to the buttons beside it.
        .frame(maxWidth: .infinity, alignment: fromMe ? .trailing : .leading)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .background {
            if highlight > 0 {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.yellow.opacity(highlight == 2 ? 0.24 : 0.09))
                    .padding(.horizontal, -8)
                    .padding(.vertical, -4)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: parts.count)
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: working)
        .animation(.easeOut(duration: 0.14), value: hover)
        .animation(.easeOut(duration: 0.2), value: highlight)
    }

    private var showActions: Bool { (hover || ChatUI.shared.demoHover) && !actions.isEmpty }

    /// Cursor Pilot's thoughts come as separate texts; yours stay whole.
    private var paragraphs: [String] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return fromMe ? ["(asked about the screen)"] : [] }
        if fromMe { return [t] }
        return messageParts(t)
    }
}

/// An empty chat: what Cursor Pilot is for, four things to try, and the keys.
private struct ChatEmptyState: View {
    @ObservedObject var model: AppModel
    var ask: (String) -> Void

    private let starters: [(icon: String, title: String, detail: String, prompt: String)] = [
        ("eye", "What am I looking at?", "Explains what's on your screen right now.", "What am I looking at?"),
        ("text.alignleft", "Summarise this", "The page or document in front, in a few lines.", "Summarise what's on my screen in a few lines."),
        ("lightbulb", "What's my next step?", "Looks at where you are and says what to do.", "Look at my screen. What should I do next here?"),
        ("rectangle.and.pencil.and.ellipsis", "Sketch how it works", "Draws it on a whiteboard and talks you through it.", "Explain what's on my screen on a whiteboard."),
    ]

    var body: some View {
        VStack(spacing: 14) {
            ShaderTile { SpeakingWave() }.frame(width: 60, height: 60)
                .shadow(color: pilotAccent.opacity(0.25), radius: 18, y: 6)
            VStack(spacing: 6) {
                Text("What should we do?").font(.system(size: 22, weight: .semibold))
                Text("Cursor Pilot sees your screen and works on your Mac.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            if model.hasAPIKey {
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach([0, 2], id: \.self) { row in
                        GridRow {
                            ForEach(starters[row..<row + 2], id: \.title) { s in
                                StarterCard(icon: s.icon, title: s.title, detail: s.detail) { ask(s.prompt) }
                            }
                        }
                    }
                }
                .frame(maxWidth: 470)
                .padding(.top, 4)
            }
            HStack(spacing: 7) {
                Text("Hold")
                HStack(spacing: 4) {
                    ForEach(Array(TalkHint.caps(model.talkDisplay).enumerated()), id: \.offset) { _, cap in KeyCap(label: cap) }
                }
                Text("anywhere and talk, or type")
                KeyCap(label: "/")
                Text("for commands.")
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
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

let bubbleGray = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(white: 0.24, alpha: 1) : NSColor(white: 0.91, alpha: 1)
})

private struct Bubble: View {
    var text: String
    var fromMe: Bool
    var tail: Bool
    var tapback: String?
    /// Buttons that sit just outside the bubble, toward the middle of the window.
    var side: HoverActions?

    var body: some View {
        content
            .overlay(alignment: fromMe ? .topLeading : .topTrailing) {
                // The guide is on a stack of its own: on the conditional view
                // itself it would be lost.
                ZStack {
                    if let side {
                        side
                            .fixedSize()
                            .padding(.top, tapback == nil ? 4 : 20)
                            .transition(.scale(scale: 0.85, anchor: fromMe ? .trailing : .leading).combined(with: .opacity))
                    }
                }
                .alignmentGuide(fromMe ? .leading : .trailing) { d in
                    fromMe ? d[.trailing] + 6 : d[.leading] - 6
                }
            }
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
            .padding(fromMe ? .leading : .trailing, 84)
    }

    @ViewBuilder private var content: some View {
        if let emoji = bigEmoji {
            // Like Messages: a few emoji alone come big, without a bubble.
            Text(emoji).font(.system(size: 40)).padding(.vertical, 2)
        } else if let media = MediaPart.parse(text) {
            // Charts, pictures and links come on their own, like in Messages.
            switch media {
            case .chart(let spec): ChartCard(spec: spec)
            case .scene(let spec): SceneCard(spec: spec)
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
