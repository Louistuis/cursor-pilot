import SwiftUI

/// Where you write: a glass box that floats over the end of the chat, with
/// files to send along, drawing, the voice switch, the model, and the
/// commands you get by typing a slash. Every message goes with the screen,
/// and Cursor Pilot hands work to background agents by itself: neither is a
/// switch, because the app is built around both.
struct Composer: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var ui = ChatUI.shared
    @State private var draft = ""
    @State private var files: [URL] = []
    @State private var selected = 0
    @State private var dropping = false
    @FocusState private var focused: Bool

    private var busy: Bool { model.phase == .thinking || model.phase == .answering }

    var body: some View {
        let commands = SlashCommand.matching(draft)
        let pick = commands.isEmpty ? nil : commands[min(selected, commands.count - 1)]
        VStack(spacing: 8) {
            if !model.jobs.isEmpty {
                VStack(spacing: 6) {
                    ForEach(model.jobs) { job in
                        JobCard(job: job) { model.stopJob(job.id) }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.jobs)
            }
            box(pick: pick, menuOpen: !commands.isEmpty, count: commands.count)
        }
        // The menu and the feedback line open upward over the thread, so they
        // don't push the conversation around.
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if let toast = ui.toast {
                    Text(toast)
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .glassBackground(Capsule())
                        .transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
                }
                if !commands.isEmpty {
                    SlashMenu(commands: commands, selected: min(selected, commands.count - 1), run: run)
                        .frame(maxWidth: 440)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.scale(scale: 0.96, anchor: .bottomLeading).combined(with: .opacity))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .alignmentGuide(.top) { $0[.bottom] + 8 }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: 740)
        .frame(maxWidth: .infinity)
        .background(alignment: .bottom) {
            // The thread fades out behind the composer instead of stopping at a bar.
            LinearGradient(colors: [Color(nsColor: .windowBackgroundColor).opacity(0),
                                    Color(nsColor: .windowBackgroundColor).opacity(0.92)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 96)
                .allowsHitTesting(false)
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: commands.isEmpty)
        .onAppear {
            draft = ChatDrafts.shared[model.currentConversationID]
            focused = true
        }
        .onChange(of: model.currentConversationID) { old, new in
            ChatDrafts.shared[old] = draft
            draft = ChatDrafts.shared[new]
            files = []
            focused = true
        }
        .onChange(of: draft) { _, text in
            // A command being typed isn't a draft worth keeping.
            ChatDrafts.shared[model.currentConversationID] = SlashCommand.matching(text).isEmpty ? text : ""
            selected = 0
        }
        .onChange(of: ui.prefill) { _, text in
            guard let text else { return }
            draft = text
            ui.prefill = nil
            focused = true
        }
    }

    private func box(pick: SlashCommand?, menuOpen: Bool, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if !files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(files, id: \.self) { url in
                            AttachmentChip(url: url) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { files.removeAll { $0 == url } }
                            }
                        }
                    }
                }
                if !model.macAccess {
                    Text("Cursor Pilot opens files itself, so this needs Mac access turned on in Settings.")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
            TextField(dropping ? "Drop files to send them along" : "Message, or / for commands", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .lineLimit(1...10)
                .focused($focused)
                .onSubmit { if let pick { run(pick) } else { send() } }
                .onKeyPress(.upArrow) {
                    if menuOpen { selected = max(min(selected, count - 1) - 1, 0); return .handled }
                    // Up in an empty box brings back what you last asked.
                    if draft.isEmpty, let last = model.openTranscript?.turns.last(where: { $0.role == "user" })?.text, !last.isEmpty {
                        draft = last
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(.downArrow) {
                    guard menuOpen else { return .ignored }
                    selected = min(selected + 1, count - 1)
                    return .handled
                }
                .onKeyPress(.tab) {
                    guard let pick else { return .ignored }
                    run(pick)
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard menuOpen else { return .ignored }
                    draft = ""
                    return .handled
                }
                .padding(.horizontal, 4)
                .padding(.top, 2)
            HStack(spacing: 6) {
                Button(action: pickFiles) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 24)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PressButtonStyle())
                .help("Attach files (or drop them here)")
                Button { model.toggleSketch() } label: {
                    Image(systemName: "pencil.tip")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 24)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PressButtonStyle())
                .help("Draw on your screen, then ask about it (⌃⌥D)")
                ComposerChip(icon: model.speakReplies ? "speaker.wave.2.fill" : "speaker.slash", label: "Voice", on: model.speakReplies,
                             help: model.speakReplies ? "Replies are read aloud (click to turn off)"
                                 : "Replies stay silent (click to have them read aloud)") {
                    model.speakReplies.toggle()
                }
                Spacer(minLength: 4)
                modelMenu
                trailingButton
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .glassBackground(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(pilotAccent.opacity(dropping ? 0.9 : focused ? 0.28 : 0), lineWidth: dropping ? 2 : 1)
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.18), value: focused)
        .animation(.easeOut(duration: 0.15), value: dropping)
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: files)
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return !urls.isEmpty
        } isTargeted: { dropping = $0 }
    }

    /// The model answering, and how hard it thinks, one click away.
    private var modelMenu: some View {
        Menu {
            Picker("Model", selection: $model.model) {
                ForEach(AppModel.models, id: \.self) { Text(SettingsView.modelName($0)).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("Thinking", selection: $model.effort) {
                ForEach(AppModel.efforts, id: \.self) { Text(Self.effortName($0)).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 3) {
                Text(Self.shortName(model.model))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Model: \(SettingsView.modelName(model.model)), thinking \(Self.effortName(model.effort).lowercased())")
    }

    static func shortName(_ id: String) -> String {
        var name = SettingsView.modelName(id)
        if let paren = name.firstIndex(of: "(") { name = String(name[..<paren]) }
        return name.replacingOccurrences(of: "Claude ", with: "").trimmingCharacters(in: .whitespaces)
    }

    static func effortName(_ id: String) -> String {
        switch id {
        case "xhigh": "Extra high"
        case "max": "Maximum"
        default: id.prefix(1).uppercased() + id.dropFirst()
        }
    }

    @ViewBuilder private var trailingButton: some View {
        ZStack {
            if busy {
                round("stop.fill", fill: Color.secondary.opacity(0.22), glyph: .primary) { model.interrupt() }
                    .help("Stop (esc)")
                    .keyboardShortcut(.escape, modifiers: [])
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            } else if canSend {
                round("arrow.up", fill: pilotAccent, glyph: .white, action: send)
                    .help("Send (↩)")
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            } else {
                round(model.phase == .listening ? "waveform" : "mic.fill",
                      fill: model.phase == .listening ? Color.red : Color.secondary.opacity(0.1),
                      glyph: model.phase == .listening ? .white : .primary, action: model.toggleListening)
                    .symbolEffect(.variableColor.iterative, isActive: model.phase == .listening)
                    .help(model.phase == .listening ? "Send what you said" : "Talk (or hold \(model.talkDisplay) anywhere)")
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .frame(width: 28, height: 28)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: canSend)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: model.phase)
    }

    private func round(_ name: String, fill: Color, glyph: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(glyph)
                .frame(width: 28, height: 28)
                .background(fill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressButtonStyle())
    }

    private var canSend: Bool {
        guard model.hasAPIKey, SlashCommand.matching(draft).isEmpty else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty
    }

    private func send() {
        var text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !files.isEmpty else { return }
        if text.isEmpty { text = files.count == 1 ? "Take a look at this file." : "Take a look at these files." }
        if !files.isEmpty {
            text += "\n\nAttached files:\n" + files.map { "- " + $0.path }.joined(separator: "\n")
        }
        draft = ""
        files = []
        Task { await model.ask(text, includeScreen: true) }
    }

    private func run(_ command: SlashCommand) {
        draft = ""
        selected = 0
        switch command.action {
        case .newChat:
            model.newConversation()
            HomeNavigation.shared.destination = .chat(model.currentConversationID)
        case .attach:
            pickFiles()
        case .draw:
            model.toggleSketch()
        case .voice:
            model.speakReplies.toggle()
            ui.say(model.speakReplies ? "Replies are read aloud" : "Replies stay silent")
        case .stop:
            model.interrupt()
        case .export:
            if let t = model.openTranscript, !t.turns.isEmpty { ChatExport.save(t) } else { ui.say("Nothing to save yet") }
        case .find:
            ui.startFind()
        case .settings:
            HomeNavigation.shared.destination = .settings
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
        focused = true
    }

    private func add(_ urls: [URL]) {
        for url in urls where url.isFileURL && !files.contains(url) && files.count < 12 { files.append(url) }
    }
}
