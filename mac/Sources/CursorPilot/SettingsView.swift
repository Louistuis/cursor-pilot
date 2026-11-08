import AVFoundation
import Speech
import SwiftUI

/// Everything you can change, as a page in the Home window.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var permissions = PermissionStatus.current()
    @State private var voices: [AVSpeechSynthesisVoice] = []
    @State private var languages: [(id: String, name: String)] = []
    @State private var askingAccess = false
    @AppStorage("borrowPointer") private var borrowPointer = true
    @AppStorage("soundEffects") private var soundEffects = true
    @AppStorage("buddyTint") private var buddyTint = BuddyTint.rainbow
    @AppStorage("cloudVoiceModel") private var cloudVoiceModel = CloudSpeech.voiceModels[0].id
    @AppStorage("cloudHearingModel") private var cloudHearingModel = CloudSpeech.hearingModels[0].id
    @State private var cloudVoice = CloudSpeech.voiceName(for: CloudSpeech.voiceModel)
    @State private var cloudVoiceNames: [String] = []
    @State private var cloudVoiceNorwegian = true
    @AppStorage("kokoroVoice") private var kokoroVoice = LocalSpeech.defaultVoice
    @State private var engine = SpeechEngine.current
    @State private var cloudKeyFound = CloudSpeech.hasKey
    @State private var cloudKeyDraft = ""
    @ObservedObject private var localSpeech = LocalSpeech.shared
    private let refresh = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    private var engineNote: String {
        switch engine {
        case .cloud:
            let hearing = CloudSpeech.hearingModels.first { $0.id == cloudHearingModel }?.name ?? "The cloud model"
            let speaking = CloudSpeech.voiceModels.first { $0.id == cloudVoiceModel }?.name ?? "the voice model"
            let languages = CloudSpeech.isMicrosoft(cloudVoiceModel)
                ? (cloudVoiceNorwegian ? " \(Self.voiceTitle(cloudVoice)) speaks English and Norwegian in the same voice." : " \(Self.voiceTitle(cloudVoice)) has no Norwegian version; Norwegian replies use another Microsoft voice.")
                : " This voice speaks every language itself, Norwegian included."
            return "\(hearing) writes down what you say and \(speaking) reads replies, through your OpenRouter account, so recordings and replies go to OpenRouter." + languages
        case .local: return "Everything stays on this Mac. Whisper understands Norwegian, English and many more; Kokoro reads English replies, and other languages use Apple's voices. The models download once (about 2 GB)."
        case .apple: return "macOS’s own speech recognition and voices."
        }
    }

    /// "sarah" → "Sarah".
    static func voiceTitle(_ name: String) -> String {
        name.prefix(1).uppercased() + name.dropFirst()
    }

    /// The languages "Automatic" listens for, as in "Norsk bokmål + English".
    private var automaticLanguages: String {
        model.resolvedListenLocales
            .map { Locale.current.localizedString(forLanguageCode: $0.language.languageCode?.identifier ?? "") ?? $0.identifier }
            .joined(separator: " + ")
    }

    var body: some View {
        Form {
            Section {
                KeyRow(title: "Anthropic key", prompt: "sk-ant-…", key: $model.apiKey)
                KeyRow(title: "abliteration.ai key", prompt: "ak_…", key: $model.abliterationKey)
                Picker("Model", selection: $model.model) {
                    Section("Claude") {
                        ForEach(AppModel.claudeModels, id: \.self) { Text(Self.modelName($0)).tag($0) }
                    }
                    Section("abliteration.ai") {
                        ForEach(AppModel.abliterationModels, id: \.self) { Text(Self.modelName($0)).tag($0) }
                    }
                }
                Picker("Effort", selection: $model.effort) {
                    ForEach(AppModel.efforts, id: \.self) { Text($0.capitalized).tag($0) }
                }
            } header: {
                Text("Model")
            } footer: {
                Text(modelNote)
            }

            Section {
                Toggle("Let Cursor Pilot work on your Mac", isOn: Binding(
                    get: { model.macAccess },
                    set: { on in
                        if on && !model.macAccess { askingAccess = true } else { model.macAccess = on }
                    }
                ))
                Text(model.macAccess ? AccessInfo.on : AccessInfo.off)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.macAccess {
                    Picker("It works", selection: $model.inputMode) {
                        Text("Like a person, with my mouse and keyboard").tag("person")
                        Text("In the background, with its own pointer").tag("background")
                    }
                    if model.inputMode == "background" {
                        Toggle("Borrow my pointer when an app ignores background clicks", isOn: $borrowPointer)
                    }
                }
            } header: {
                Text("Working on your Mac")
            } footer: {
                if model.macAccess {
                    Text(model.inputMode == "background"
                         ? "A few apps only react to the real pointer. Then it moves yours for a split second and puts it back. Files it edits are backed up first (Show Data Folder › backups). Press Stop or hold ⌃⌥ to interrupt at any time."
                         : "It moves your pointer, clicks and types the way you would. Move the mouse to take over; it waits until you let go. Helpers always work in their own space. Files it edits are backed up first. Press Stop or hold ⌃⌥ to interrupt at any time.")
                }
            }

            Section {
                if model.memory.isEmpty {
                    Text("Nothing yet. Tell it something worth keeping, like “I like short answers”, or say “remember that…”.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.memory) { fact in
                        HStack(alignment: .firstTextBaseline) {
                            Text(fact.text)
                            Spacer()
                            Button { model.forgetMemory(fact.id) } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.tertiary)
                            .help("Forget this")
                        }
                    }
                    Button("Forget Everything", role: .destructive) { model.forgetMemory(nil) }
                }
            } header: {
                Text("Memory")
            } footer: {
                Text("Short facts Cursor Pilot keeps between chats, saved on this Mac and sent to Claude with each question.")
            }

            Section("Talking") {
                Picker("Hold to talk", selection: $model.talkKey) {
                    Text("Control + Option (⌃⌥)").tag(AppModel.TalkKey.controlOption)
                    Text("Custom shortcut").tag(AppModel.TalkKey.custom)
                }
                if model.talkKey == .custom {
                    LabeledContent("Shortcut") { ShortcutRecorder(model: model) }
                }
                Toggle("Double-tap Control to type a question", isOn: $model.doubleTapToType)
                Toggle(isOn: $model.handsFree) {
                    Text("Hands-free conversation")
                    Text("After an answer the mic stays open a few seconds so you can just reply, and you can cut in while it talks.")
                }
                Picker("Language you speak", selection: $model.listenLocale) {
                    Text("Automatic (\(automaticLanguages))").tag("")
                    Divider()
                    ForEach(languages, id: \.id) { Text($0.name).tag($0.id) }
                }
            }

            Section {
                Picker("Speech engine", selection: $engine) {
                    ForEach(SpeechEngine.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: engine) { _, now in
                    UserDefaults.standard.set(now.rawValue, forKey: "speechEngine")
                    model.prepareSpeechEngine()
                }
                switch engine {
                case .cloud:
                    if cloudKeyFound {
                        LabeledContent("OpenRouter") {
                            Label("Key found", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    } else {
                        LabeledContent("OpenRouter key") {
                            HStack {
                                SecureField("sk-or-…", text: $cloudKeyDraft).textFieldStyle(.roundedBorder)
                                Button("Save") {
                                    let key = cloudKeyDraft
                                    cloudKeyDraft = ""
                                    Task.detached {
                                        Keychain.saveOpenRouterKey(key)
                                        CloudSpeech.forgetKey()
                                        let found = CloudSpeech.hasKey
                                        await MainActor.run { cloudKeyFound = found; model.prepareSpeechEngine() }
                                    }
                                }
                                .disabled(cloudKeyDraft.isEmpty)
                            }
                        }
                    }
                    Picker("Hearing", selection: $cloudHearingModel) {
                        ForEach(CloudSpeech.hearingModels) { m in Text("\(m.name) · \(m.detail)").tag(m.id) }
                    }
                    Picker("Voice model", selection: $cloudVoiceModel) {
                        ForEach(CloudSpeech.voiceModels) { m in Text("\(m.name) · \(m.detail)").tag(m.id) }
                    }
                    LabeledContent("Voice") {
                        HStack(spacing: 8) {
                            Picker("Voice", selection: Binding(
                                get: { cloudVoice },
                                set: { name in
                                    cloudVoice = name
                                    CloudSpeech.setVoiceName(name, for: cloudVoiceModel)
                                    model.previewVoice(named: Self.voiceTitle(name))
                                })) {
                                if cloudVoiceNames.isEmpty { Text(Self.voiceTitle(cloudVoice)).tag(cloudVoice) }
                                ForEach(cloudVoiceNames, id: \.self) { Text(Self.voiceTitle($0)).tag($0) }
                            }
                            .labelsHidden()
                            .frame(minWidth: 180)
                            Button {
                                if model.isSpeaking { model.stopSpeaking() } else { model.previewVoice(named: Self.voiceTitle(cloudVoice)) }
                            } label: {
                                Image(systemName: "play.circle.fill").font(.title3)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                            .help("Hear this voice")
                        }
                    }
                    .task(id: cloudVoiceModel) {
                        cloudVoice = CloudSpeech.voiceName(for: cloudVoiceModel)
                        cloudVoiceNames = await CloudSpeech.voiceNames(model: cloudVoiceModel)
                        cloudVoiceNorwegian = await CloudSpeech.speaksNorwegian(cloudVoice, model: cloudVoiceModel)
                    }
                    .onChange(of: cloudVoice) { _, name in
                        Task { cloudVoiceNorwegian = await CloudSpeech.speaksNorwegian(name, model: cloudVoiceModel) }
                    }
                case .local:
                    LabeledContent("Hearing · Whisper large-v3 turbo") { Text(localSpeech.hearing.label).foregroundStyle(.secondary) }
                    LabeledContent("Speaking · Kokoro") { Text(localSpeech.speaking.label).foregroundStyle(.secondary) }
                    Picker("Voice", selection: $kokoroVoice) {
                        ForEach(LocalSpeech.voices, id: \.id) { Text($0.name).tag($0.id) }
                    }
                case .apple:
                    EmptyView()
                }
            } header: {
                Text("Speech")
            } footer: {
                Text(engineNote).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Section("Spoken replies") {
                Toggle("Read replies aloud", isOn: $model.speakReplies)
                Picker(engine == .apple ? "Voice" : "Apple voice (fallback)", selection: $model.voiceID) {
                    Text("Best available").tag("")
                    Divider()
                    ForEach(voices, id: \.identifier) { v in
                        Text("\(v.name) · \(Self.quality(v)) · \(v.language)").tag(v.identifier)
                    }
                }
                .disabled(!model.speakReplies)
                LabeledContent("Speed") {
                    HStack {
                        Image(systemName: "tortoise").foregroundStyle(.secondary)
                        Slider(value: $model.speechRate, in: 0.7...1.5)
                        Image(systemName: "hare").foregroundStyle(.secondary)
                    }
                }
                .disabled(!model.speakReplies)
                if !Speaker.hasNaturalVoice(for: "en") {
                    Label {
                        Text("Only basic voices are installed. For natural speech, add a Premium voice such as Zoe or Ava in System Settings › Accessibility › Spoken Content › System Voice › Manage Voices, then pick it here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "waveform.badge.exclamationmark").foregroundStyle(.orange)
                    }
                }
                HStack {
                    Button("Preview Voice") {
                        model.speak("Hi! I'm Cursor Pilot. Hold Control and Option, ask me anything, and I'll show you where to click.")
                    }
                    Spacer()
                    Button("Get More Voices…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")!)
                    }
                    .buttonStyle(.link)
                }
            }

            Section("On screen") {
                Toggle("Buddy next to the cursor", isOn: $model.showBuddy)
                Toggle("Hide the buddy when idle", isOn: $model.hideBuddyWhenIdle)
                    .disabled(!model.showBuddy)
                Toggle("Notch panel", isOn: $model.showNotch)
                Toggle("Glowing screen edges while working", isOn: $model.showGlow)
                Picker("Buddy colour", selection: $buddyTint) {
                    ForEach(BuddyTint.allCases) { tint in
                        Label {
                            Text(tint.name)
                        } icon: {
                            Image(nsImage: Self.swatch(tint))
                        }
                        .tag(tint)
                    }
                }
                Toggle("Sound effects", isOn: $soundEffects)
                Toggle("Hide from screenshots and screen recordings", isOn: $model.hideFromRecordings)
            }

            Section {
                PermissionRow(name: "Microphone", detail: "To hear your questions", granted: permissions.microphone) {
                    Task { _ = await VoiceInput.requestPermissions(); permissions = .current() }
                }
                PermissionRow(name: "Speech Recognition", detail: "To turn speech into text", granted: permissions.speech) {
                    Task { _ = await VoiceInput.requestPermissions(); permissions = .current() }
                }
                PermissionRow(name: "Screen Recording", detail: "To see what you're asking about", granted: permissions.screen) {
                    Permissions.openScreenRecording()
                }
                PermissionRow(name: "Accessibility", detail: "To use the mouse and keyboard when working on your Mac",
                              granted: permissions.accessibility) {
                    Permissions.openAccessibility()
                }
                PermissionRow(name: "Full Disk Access", detail: "To read your messages and work with any file, without asking per folder",
                              granted: permissions.fullDisk) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
                PermissionRow(name: "Contacts", detail: "To show names instead of numbers in messages", granted: permissions.contacts) {
                    Task { await Setup.run(); permissions = .current() }
                }
                PermissionRow(name: "Automation", detail: "To control Messages, Finder and System Events", granted: permissions.automation) {
                    Task { await Setup.askToScript(); permissions = .current() }
                }
                if !permissions.everything {
                    Button {
                        Task { await Setup.run(); permissions = .current() }
                    } label: {
                        Label("Set Up Everything", systemImage: "checkmark.shield").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                }
                if !permissions.screen {
                    HStack {
                        Text("Allowed it already? macOS applies it after a restart.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Cursor Pilot") { Permissions.relaunch() }
                    }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Cursor Pilot asks for everything here, once, so macOS never stops it to ask while it works; what's missing it just reports. It only listens while you hold the talk key, and only looks at your screen when you ask something.")
            }

            Section {
                LabeledContent("Version", value: "\(Bundle.main.shortVersion) (core \(Core.version))")
                HStack {
                    Button("Run Setup Again…") { OnboardingWindow.shared.show() }
                    Button("Show Data Folder") {
                        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                            .appendingPathComponent("Cursor Pilot", isDirectory: true)
                        NSWorkspace.shared.activateFileViewerSelecting([dir])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
        .onAppear {
            model.refreshMemory()
            permissions = .current()
            if voices.isEmpty { voices = Speaker.availableVoices() }
            if languages.isEmpty { languages = VoiceInput.languages() }
        }
        .alert("Let Cursor Pilot work on your Mac?", isPresented: $askingAccess) {
            Button("Allow") { model.macAccess = true }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(AccessInfo.consent)
        }
        .onReceive(refresh) { _ in
            let now = PermissionStatus.current()
            if now != permissions { permissions = now }
        }
    }

    /// A small dot in the buddy's colours, for the colour picker's menu.
    private static func swatch(_ tint: BuddyTint) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            let colors = tint.colors.dropLast().map { NSColor($0) }
            NSGradient(colors: Array(colors))?.draw(in: NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)), angle: -45)
            return true
        }
        return image
    }

    private var modelNote: String {
        var note = "Lower effort answers faster; higher effort thinks longer about hard questions."
        if model.usesAbliteration {
            note += " abliteration.ai models get your question and screenshots through api.abliteration.ai, with the same tools but without Claude's computer use and web search."
            if model.model == "abliterated-model-large-v2" { note += " This one can't see images, so it doesn't get screenshots." }
            if model.abliterationKey.isEmpty { note += " Add your abliteration.ai key above to use it." }
        }
        return note
    }

    static func modelName(_ id: String) -> String {
        switch id {
        case "claude-opus-5-5": "Claude Opus 5.5"
        case "claude-sonnet-5-5": "Claude Sonnet 5.5"
        case "claude-haiku-5-5": "Claude Haiku 5.5 (fastest)"
        case "claude-fable-5-1": "Claude Fable 5.1"
        case "abliterated-model-large-flash": "Abliterated Large Flash (1M context)"
        case "abliterated-model": "Abliterated"
        case "abliterated-model-large-v2": "Abliterated Large v2 (text only)"
        default: id
        }
    }

    private static func quality(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .premium: "Premium"
        case .enhanced: "Enhanced"
        default: "Standard"
        }
    }
}

struct PermissionRow: View {
    var name: String
    var detail: String? = nil
    var granted: Bool
    var request: () -> Void

    var body: some View {
        LabeledContent {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Allow…", action: request)
            }
        } label: {
            Text(name)
            if let detail { Text(detail) }
        }
    }
}

struct PermissionStatus: Equatable {
    var microphone: Bool
    var speech: Bool
    var screen: Bool
    var accessibility: Bool
    var fullDisk: Bool
    var contacts: Bool
    var automation: Bool

    /// Everything, so nothing ever has to ask while it works.
    var everything: Bool { microphone && speech && screen && accessibility && fullDisk && contacts && automation }

    var all: Bool { microphone && speech && screen }

    static func current() -> PermissionStatus {
        PermissionStatus(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            speech: SFSpeechRecognizer.authorizationStatus() == .authorized,
            screen: ScreenCapture.hasPermission,
            accessibility: ComputerControl.hasAccessibility,
            fullDisk: Setup.hasFullDiskAccess,
            contacts: Setup.hasContacts,
            automation: Setup.hasAutomation
        )
    }
}

enum Permissions {
    /// Asks for everything in one go (`Setup.run`).
    @MainActor
    static func requestAll() async { await Setup.run() }

    static func openScreenRecording() {
        // The request adds Cursor Pilot to the list; the pane is where it's switched on.
        ScreenCapture.requestPermission()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    @MainActor
    static func openAccessibility() {
        ComputerControl.requestAccessibility()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Screen Recording only takes effect in a new process.
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}

enum AccessInfo {
    static let consent = "Cursor Pilot will run commands, read and change files, and work in your apps with its own pointer to do what you ask, on its own and without asking each time, like a co-worker at your Mac. It tells you what it's doing as it goes. You can turn this off any time in Settings."
    static let on = "Cursor Pilot works on its own in the background, with no prompts: it runs commands, edits files and works in your apps with its own pointer, so your mouse and keyboard stay yours. It says what it's doing as it goes."
    static let off = "Cursor Pilot answers, points and draws on your screen, but doesn't run anything on your Mac."
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
}

/// An API key kept in the keychain: type it, or paste it straight from the
/// clipboard without it ever showing on screen.
private struct KeyRow: View {
    let title: String
    let prompt: String
    @Binding var key: String
    @State private var draft = ""
    @State private var pasted = false

    private var saved: Bool { !key.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        LabeledContent(title) {
            HStack {
                SecureField(title, text: $draft, prompt: Text(saved ? "Saved in your keychain" : prompt))
                    .labelsHidden()
                    .frame(minWidth: 200)
                    .onSubmit(save)
                if draft.isEmpty {
                    Button {
                        let text = NSPasteboard.general.string(forType: .string)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { NSSound.beep(); return }
                        key = text
                        withAnimation { pasted = true }
                        Task {
                            try? await Task.sleep(for: .seconds(1.6))
                            withAnimation { pasted = false }
                        }
                    } label: {
                        Label(pasted ? "Saved" : "Paste", systemImage: pasted ? "checkmark" : "doc.on.clipboard")
                    }
                    .help("Saves the key on your clipboard")
                } else {
                    Button("Save", action: save)
                }
                if saved && draft.isEmpty && !pasted {
                    Button("Remove", role: .destructive) { key = "" }
                }
            }
        }
    }

    private func save() {
        guard !draft.isEmpty else { return }
        key = draft
        draft = ""
    }
}
