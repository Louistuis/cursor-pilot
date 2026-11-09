import SwiftUI
import UniformTypeIdentifiers

// The pieces around the chat thread: pinned chats, drafts, export, the
// composer's slash commands, quick replies, and the ⌘K command palette.

// MARK: - Pins and drafts

/// Chats kept at the top of the sidebar, remembered on this Mac.
@MainActor
final class ChatPins: ObservableObject {
    static let shared = ChatPins()
    @Published private(set) var ids: [String]

    private init() { ids = UserDefaults.standard.stringArray(forKey: "pinnedChats") ?? [] }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    func toggle(_ id: String) {
        if let i = ids.firstIndex(of: id) { ids.remove(at: i) } else { ids.insert(id, at: 0) }
        UserDefaults.standard.set(ids, forKey: "pinnedChats")
    }

    func forget(_ id: String) {
        guard contains(id) else { return }
        toggle(id)
    }
}

/// What you had typed in each chat, so switching chats doesn't lose it.
@MainActor
final class ChatDrafts {
    static let shared = ChatDrafts()
    private var drafts: [String: String] = UserDefaults.standard.dictionary(forKey: "chatDrafts") as? [String: String] ?? [:]

    subscript(id: String) -> String {
        get { drafts[id] ?? "" }
        set {
            let text = newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : newValue
            guard drafts[id] != text else { return }
            drafts[id] = text
            UserDefaults.standard.set(drafts, forKey: "chatDrafts")
        }
    }
}

/// The words around the first place `query` appears in `text`, on one line.
func chatSnippet(_ text: String, around query: String) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: " ")
    guard let r = flat.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
        return String(flat.prefix(80))
    }
    let start = flat.index(r.lowerBound, offsetBy: -28, limitedBy: flat.startIndex) ?? flat.startIndex
    let end = flat.index(r.upperBound, offsetBy: 60, limitedBy: flat.endIndex) ?? flat.endIndex
    return (start > flat.startIndex ? "…" : "") + flat[start..<end].trimmingCharacters(in: .whitespaces) + (end < flat.endIndex ? "…" : "")
}

// MARK: - Export

enum ChatExport {
    /// The conversation as Markdown: a heading, then each message under who said it.
    static func markdown(_ t: Transcript) -> String {
        var out = "# \(t.title.isEmpty ? "Chat with Cursor Pilot" : t.title)\n"
        for turn in t.turns {
            let who = turn.role == "user" ? "You" : "Cursor Pilot"
            let when = Date(timeIntervalSince1970: TimeInterval(turn.at)).formatted(date: .abbreviated, time: .shortened)
            out += "\n**\(who)** · \(when)\n\n\(turn.text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
            if let steps = turn.steps, !steps.isEmpty {
                out += "\n" + steps.map { "- \($0)" }.joined(separator: "\n") + "\n"
            }
        }
        return out
    }

    @MainActor static func save(_ t: Transcript) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        let name = t.title.isEmpty ? "Cursor Pilot chat" : t.title
        panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "-") + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? markdown(t).write(to: url, atomically: true, encoding: .utf8)
    }

    @MainActor static func copy(_ t: Transcript) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown(t), forType: .string)
    }
}

// MARK: - Slash commands

/// Something the composer does when you type its name after a slash.
struct SlashCommand: Identifiable, Hashable {
    enum Action: Hashable { case newChat, draw, voice, stop, export, find, settings, attach }
    var name: String
    var title: String
    var icon: String
    var action: Action
    var id: String { name }

    static let all: [SlashCommand] = [
        .init(name: "new", title: "Start a new chat", icon: "square.and.pencil", action: .newChat),
        .init(name: "attach", title: "Attach files", icon: "paperclip", action: .attach),
        .init(name: "draw", title: "Draw on your screen, then ask", icon: "pencil.tip", action: .draw),
        .init(name: "voice", title: "Read replies aloud, or stop", icon: "speaker.wave.2", action: .voice),
        .init(name: "find", title: "Find in this chat", icon: "magnifyingglass", action: .find),
        .init(name: "export", title: "Save this chat as Markdown", icon: "square.and.arrow.up", action: .export),
        .init(name: "stop", title: "Stop what it's doing", icon: "stop.fill", action: .stop),
        .init(name: "settings", title: "Open Settings", icon: "gearshape", action: .settings),
    ]

    /// The commands a draft is asking for: only while it is a slash and a word.
    static func matching(_ draft: String) -> [SlashCommand] {
        guard draft.hasPrefix("/"), !draft.contains(" "), !draft.contains("\n") else { return [] }
        let q = draft.dropFirst().lowercased()
        return q.isEmpty ? all : all.filter { $0.name.hasPrefix(q) }
    }
}

/// The list that opens above the composer while you type a slash.
struct SlashMenu: View {
    var commands: [SlashCommand]
    var selected: Int
    var run: (SlashCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(commands.enumerated()), id: \.element.id) { i, c in
                Button { run(c) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: c.icon)
                            .font(.system(size: 11.5, weight: .medium))
                            .frame(width: 18)
                            .foregroundStyle(i == selected ? Color.white : Color.secondary)
                        Text("/" + c.name).font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                        Text(c.title).font(.system(size: 12.5)).opacity(0.75).lineLimit(1)
                        Spacer(minLength: 0)
                        if i == selected { Text("↩").font(.system(size: 11, weight: .semibold)).opacity(0.8) }
                    }
                    .foregroundStyle(i == selected ? Color.white : Color.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(i == selected ? pilotAccent : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .glassBackground(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .animation(.easeOut(duration: 0.12), value: selected)
    }
}

// MARK: - Chips

/// A small rounded toggle in the composer's tool row.
struct ComposerChip: View {
    var icon: String
    var label: String
    var on: Bool
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10.5, weight: .semibold)).contentTransition(.symbolEffect(.replace))
                Text(label).font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(on ? pilotAccent : Color.secondary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background((on ? pilotAccent.opacity(0.14) : Color.secondary.opacity(0.1)), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressButtonStyle())
        .help(help)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: on)
    }
}

/// A file waiting to go with the next message.
struct AttachmentChip: View {
    var url: URL
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 16, height: 16)
            Text(url.lastPathComponent).font(.system(size: 11.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .padding(.leading, 7)
        .padding(.trailing, 9)
        .frame(height: 26)
        .frame(maxWidth: 220)
        .background(Color.secondary.opacity(0.12), in: Capsule())
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }
}

/// One-tap replies under the latest answer.
struct QuickReplies: View {
    var replies: [String]
    var send: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(replies, id: \.self) { r in
                Button { send(r) } label: {
                    Text(r)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(pilotAccent)
                        .padding(.horizontal, 11)
                        .frame(height: 26)
                        .background(pilotAccent.opacity(0.1), in: Capsule())
                        .overlay(Capsule().strokeBorder(pilotAccent.opacity(0.25), lineWidth: 0.8))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressButtonStyle())
            }
        }
    }
}

/// A starting point on an empty chat: what to ask, and whether it looks at the screen.
struct StarterCard: View {
    var icon: String
    var title: String
    var detail: String
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AngularGradient(colors: pilotRainbow, center: .center))
                Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(hover ? 0.14 : 0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.secondary.opacity(0.16), lineWidth: 0.8))
            .scaleEffect(hover ? 1.015 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressButtonStyle())
        .onHover { hover = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hover)
    }
}

/// The small row of buttons that floats by a message while the pointer is on it.
struct HoverActions: View {
    struct Item: Identifiable {
        var icon: String
        var help: String
        var action: () -> Void
        var id: String { icon }
    }
    var items: [Item]
    @State private var done: String?

    var body: some View {
        HStack(spacing: 1) {
            ForEach(items) { item in
                Button {
                    item.action()
                    done = item.icon
                    Task { try? await Task.sleep(for: .seconds(1.1)); if done == item.icon { done = nil } }
                } label: {
                    Image(systemName: done == item.icon ? "checkmark" : item.icon)
                        .font(.system(size: 10.5, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.help)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.22), lineWidth: 0.6))
        .shadow(color: .black.opacity(0.1), radius: 5, y: 2)
    }
}

// MARK: - Command palette

/// ⌘K: jump to any chat or run an action by typing a few letters.
struct CommandPalette: View {
    struct Entry: Identifiable {
        var id: String
        var icon: String
        var title: String
        var detail: String
        var run: () -> Void
    }

    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    var actions: [Entry]
    var open: (String) -> Void
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    private var entries: [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let chats = model.conversations
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { c in
                Entry(id: "chat-" + c.id, icon: "bubble.left", title: c.displayTitle,
                      detail: Date(timeIntervalSince1970: TimeInterval(c.updatedAt)).formatted(.relative(presentation: .named)),
                      run: { open(c.id) })
            }
        let all = actions + chats
        guard !q.isEmpty else { return Array(all.prefix(40)) }
        return all.filter { $0.title.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        let list = entries
        ZStack(alignment: .top) {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Jump to a chat or run an action", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .focused($focused)
                        .onSubmit { run(list) }
                        .onKeyPress(.downArrow) { selected = min(selected + 1, max(list.count - 1, 0)); return .handled }
                        .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
                        .onKeyPress(.escape) { isPresented = false; return .handled }
                    KeyCap(label: "esc")
                }
                .padding(.horizontal, 16)
                .frame(height: 50)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            if list.isEmpty {
                                Text("Nothing matches").foregroundStyle(.secondary).padding(.vertical, 22)
                            }
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, e in
                                Button { e.run(); isPresented = false } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: e.icon).frame(width: 20)
                                            .foregroundStyle(i == selected ? Color.white : Color.secondary)
                                        Text(e.title).lineLimit(1)
                                        Spacer(minLength: 8)
                                        Text(e.detail).font(.system(size: 11.5)).opacity(0.65).lineLimit(1)
                                    }
                                    .font(.system(size: 13))
                                    .foregroundStyle(i == selected ? Color.white : Color.primary)
                                    .padding(.horizontal, 10)
                                    .frame(height: 32)
                                    .background(i == selected ? pilotAccent : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(e.id)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: selected) { _, i in
                        if list.indices.contains(i) { proxy.scrollTo(list[i].id) }
                    }
                }
            }
            .frame(width: 540)
            .glassBackground(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 40, y: 18)
            .padding(.top, 90)
            .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
        }
        .onAppear { focused = true }
        .onChange(of: query) { selected = 0 }
    }

    private func run(_ list: [Entry]) {
        guard list.indices.contains(selected) else { return }
        list[selected].run()
        isPresented = false
    }
}
