import AppKit
import Combine
import SwiftUI

/// Ties the pieces together: hotkey → voice → screenshots → core → speech,
/// overlay and chat history.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum Phase: Equatable { case idle, listening, thinking, answering }

    // Live state
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var heardText = ""
    @Published private(set) var replyText = ""
    @Published private(set) var lastError: String?
    @Published private(set) var conversations: [ConversationSummary] = []
    @Published private(set) var currentConversationID = ""
    /// Bumped whenever a saved transcript may have changed.
    @Published private(set) var historyRevision = 0
    @Published private(set) var drawings: [DrawingRecord] = []
    /// What Claude remembers about the user (Settings › Memory).
    @Published private(set) var memory: [MemoryFact] = []
    /// The conversation open in Home, cached so typing and streaming never
    /// re-read it from disk.
    @Published private(set) var openTranscript: Transcript?
    /// What the agent has done so far in the running request.
    @Published private(set) var liveSteps: [AgentStep] = []

    // Settings
    @Published var apiKey: String {
        didSet {
            if !isLoadingKey {
                let key = apiKey
                Task.detached { Keychain.saveAPIKey(key) }
            }
            configureCore()
        }
    }
    private var isLoadingKey = false
    @Published var model: String { didSet { defaults.set(model, forKey: "model"); configureCore() } }
    @Published var effort: String { didSet { defaults.set(effort, forKey: "effort"); configureCore() } }
    @Published var speakReplies: Bool { didSet { defaults.set(speakReplies, forKey: "speakReplies") } }
    @Published var showBuddy: Bool { didSet { defaults.set(showBuddy, forKey: "showBuddy"); applyBuddyVisibility() } }
    @Published var showNotch: Bool { didSet { defaults.set(showNotch, forKey: "showNotch"); applyNotchVisibility() } }
    @Published var showGlow: Bool { didSet { defaults.set(showGlow, forKey: "showGlow"); glow.enabled = showGlow } }
    @Published var hideFromRecordings: Bool {
        didSet {
            defaults.set(hideFromRecordings, forKey: "hideFromRecordings")
            for w in NSApp.windows where w is NSPanel && !(w is InkPanel) { w.applyRecordingVisibility() }
        }
    }
    @Published var doubleTapToType: Bool {
        didSet { defaults.set(doubleTapToType, forKey: "doubleTapToType"); applyDoubleTap() }
    }
    @Published var hideBuddyWhenIdle: Bool {
        didSet { defaults.set(hideBuddyWhenIdle, forKey: "hideBuddyWhenIdle"); overlay.autoHide = hideBuddyWhenIdle }
    }
    /// What you hold to talk.
    @Published var talkKey: TalkKey { didSet { defaults.set(talkKey.rawValue, forKey: "talkKey"); registerHotKey() } }
    /// Speech recognition language; empty follows the system.
    @Published var listenLocale: String {
        didSet { defaults.set(listenLocale, forKey: "listenLocale"); refreshVoiceLanguage() }
    }
    /// The language actually listened for (the choice, or the best match
    /// for the user's languages).
    /// The languages "Automatic" listens for, at once.
    @Published private(set) var resolvedListenLocales = [Locale(identifier: "en-US")]
    /// Spoken-reply voice identifier; empty picks the best installed voice.
    @Published var voiceID: String { didSet { defaults.set(voiceID, forKey: "voiceID"); applyVoice() } }
    @Published var speechRate: Double { didSet { defaults.set(speechRate, forKey: "speechRate"); applyVoice() } }
    /// The agent is running commands or editing files rather than using the
    /// screen: the buddy hides and the menu bar and notch show a terminal.
    @Published var backgroundWork = false { didSet { overlay.state.backgroundWork = backgroundWork } }
    /// Whether Cursor Pilot may work on the Mac by itself (consented in onboarding or Settings).
    @Published var macAccess: Bool { didSet { defaults.set(macAccess ? "on" : "off", forKey: "accessLevel"); configureCore() } }
    @Published var shortcut: Shortcut {
        didSet {
            defaults.set(try? JSONEncoder().encode(shortcut), forKey: "shortcut")
            registerHotKey()
        }
    }
    /// While the recorder listens, the global shortcut is released so its
    /// own key combination can be recorded too.
    @Published var isRecordingShortcut = false { didSet { registerHotKey() } }
    @Published private(set) var hotKeyRegistered = true

    enum TalkKey: String, CaseIterable, Identifiable {
        case controlOption, custom
        var id: String { rawValue }
    }

    /// The talk key as shown in hints, e.g. "⌃⌥".
    var talkDisplay: String { talkKey == .controlOption ? "⌃⌥" : shortcut.display }

    static let models = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"]
    static let efforts = ["low", "medium", "high", "xhigh", "max"]

    let core: Core
    let overlay = OverlayController()
    let ink = InkController()
    let glow = GlowController()
    private var subscriptions: Set<AnyCancellable> = []
    private var drawHotKey: HotKey?
    private(set) var notch: NotchController?
    private let voice = VoiceInput()
    private let speaker = Speaker()
    private let defaults = UserDefaults.standard
    private var hotKey: HotKey?
    private let modifierHold = ModifierHold()
    private let doubleTap = DoubleTapControl()
    /// Screen Recording is requested once per launch; after that a missing
    /// permission is explained instead of prompting on every question.
    private var askedForScreen = false
    /// Sentences sent to the voice in this reply, and the one being spoken.
    private var sentencesQueued = 0
    private var sentenceSpoken = -1
    /// Pointing and drawings waiting for the voice to reach their sentence.
    private var heldVisuals: [(sentence: Int, show: () -> Void)] = []
    private var activeRequest: UInt64?
    /// The last request is over and saved (its reply may still be playing).
    @Published private(set) var requestFinished = true
    private var resetTask: Task<Void, Never>?

    var hasAPIKey: Bool { !apiKey.trimmingCharacters(in: .whitespaces).isEmpty }

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cursor Pilot", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        guard let core = Core(dataDirectory: support) else { fatalError("Cursor Pilot core failed to start") }
        self.core = core

        apiKey = ""
        model = defaults.string(forKey: "model") ?? Self.models[0]
        effort = defaults.string(forKey: "effort") ?? "low"
        speakReplies = defaults.object(forKey: "speakReplies") as? Bool ?? true
        showBuddy = defaults.object(forKey: "showBuddy") as? Bool ?? true
        showNotch = defaults.object(forKey: "showNotch") as? Bool ?? true
        showGlow = defaults.object(forKey: "showGlow") as? Bool ?? true
        hideFromRecordings = defaults.bool(forKey: "hideFromRecordings")
        doubleTapToType = defaults.object(forKey: "doubleTapToType") as? Bool ?? true
        hideBuddyWhenIdle = defaults.object(forKey: "hideBuddyWhenIdle") as? Bool ?? true
        talkKey = defaults.string(forKey: "talkKey").flatMap(TalkKey.init(rawValue:)) ?? .controlOption
        listenLocale = defaults.string(forKey: "listenLocale") ?? ""
        voiceID = defaults.string(forKey: "voiceID") ?? ""
        speechRate = defaults.object(forKey: "speechRate") as? Double ?? 1.0
        macAccess = (defaults.string(forKey: "accessLevel") ?? "off") != "off"
        shortcut = defaults.data(forKey: "shortcut").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
            ?? .default

        voice.onLevel = { [weak self] level in
            self?.overlay.state.level = level
            self?.glow.level = level
        }
        voice.onPartial = { [weak self] text in
            self?.heardText = text
            self?.overlay.state.caption = text
        }
        speaker.onIdle = { [weak self] in
            guard let self else { return }
            releaseVisuals(upTo: .max)
            // The last line stays, fully read, until the bubble goes away.
            if let spoken = overlay.state.spoken {
                overlay.state.spoken = SpokenWord(sentence: spoken.sentence,
                                                  word: NSRange(location: (spoken.sentence as NSString).length, length: 0))
            }
            settleIfDone()
        }
        speaker.onSentence = { [weak self] number, text in
            guard let self else { return }
            if number >= 0 {
                sentenceSpoken = number
                releaseVisuals(upTo: number)
            }
            overlay.state.spoken = SpokenWord(sentence: text, word: NSRange(location: 0, length: 0))
        }
        speaker.onWord = { [weak self] range in
            guard let self, let spoken = overlay.state.spoken else { return }
            overlay.state.spoken = SpokenWord(sentence: spoken.sentence, word: range)
        }
        ink.onAsk = { [weak self] text in Task { await self?.ask(text, includeScreen: true) } }
        ink.onSave = { [weak self] in Task { await self?.saveDrawing() } }
        glow.enabled = showGlow
        overlay.autoHide = hideBuddyWhenIdle
        applyVoice()
        doubleTap.onDoubleTap = { [weak self] in self?.openTyping() }
        applyDoubleTap()
        modifierHold.onPress = { [weak self] in self?.beginListening() }
        modifierHold.onRelease = { [weak self] in Task { await self?.endListening() } }
        modifierHold.onCancel = { [weak self] in self?.cancelListening() }
        ink.state.$sketching
            .sink { [weak self] sketching in self?.refreshGlow(sketching: sketching) }
            .store(in: &subscriptions)
    }

    /// Reads the saved key in the background: macOS may show an access
    /// prompt, and the app must stay responsive meanwhile.
    /// `-CPSkipKeychain YES` skips it, for UI work without prompts.
    func loadAPIKey() async {
        guard !defaults.bool(forKey: "CPSkipKeychain") else { return }
        let key = await Task.detached { Keychain.loadAPIKey() }.value
        isLoadingKey = true
        apiKey = key
        isLoadingKey = false
    }

    func start() {
        configureCore()
        core.attachAgentHost()
        registerHotKey()
        drawHotKey = HotKey(.draw, id: 2, onPress: { [weak self] in
            Task { @MainActor in self?.toggleSketch() }
        })
        notch = NotchController(model: self)
        applyBuddyVisibility()
        applyNotchVisibility()
        refreshConversations()
        reloadOpenTranscript()
        refreshDrawings()
        refreshVoiceLanguage()
    }

    private func refreshVoiceLanguage() {
        Task {
            let locales = await VoiceInput.resolvedLocales(listenLocale)
            resolvedListenLocales = locales
            speaker.fallbackLanguage = voice.lastLanguage ?? locales.first?.language.languageCode?.identifier ?? "en"
            await voice.prepare(locales: locales)
        }
    }

    private func registerHotKey() {
        hotKey = nil
        modifierHold.stop()
        guard !isRecordingShortcut else { return }
        guard talkKey == .custom else {
            hotKeyRegistered = true
            modifierHold.start()
            return
        }
        let key = HotKey(
            shortcut,
            onPress: { [weak self] in Task { @MainActor in self?.beginListening() } },
            onRelease: { [weak self] in Task { @MainActor in await self?.endListening() } }
        )
        hotKeyRegistered = key.isRegistered
        hotKey = key
    }

    private func applyNotchVisibility() {
        if showNotch { notch?.show() } else { notch?.hide() }
    }

    private func applyDoubleTap() {
        if doubleTapToType { doubleTap.start() } else { doubleTap.stop() }
    }

    /// Double-tap Control: type a question instead of saying it.
    func openTyping() {
        if showNotch, let notch {
            notch.openForTyping()
        } else {
            HomeWindow.shared.show()
        }
    }

    private func configureCore() {
        core.configure(CoreSettings(apiKey: apiKey, model: model, effort: effort, access: macAccess ? "on" : "off"))
    }

    private func applyVoice() {
        speaker.voiceID = voiceID.isEmpty ? nil : voiceID
        speaker.rate = Float(speechRate)
    }

    private func applyBuddyVisibility() {
        if showBuddy { overlay.show() } else { overlay.hide() }
    }

    // MARK: Voice flow

    /// Screens captured the moment the talk key went down, so the question
    /// leaves the instant you let go instead of waiting for a capture.
    private var precapture: (task: Task<[ScreenShotPayload], Never>, at: Date)?

    func beginListening() {
        interrupt()
        core.warm()
        if ScreenCapture.hasPermission, !ink.hasStrokes {
            precapture = (Task { (try? await ScreenCapture.captureAll(includingWindows: [])) ?? [] }, Date())
        }
        Task {
            guard await VoiceInput.requestPermissions() else {
                showError("Cursor Pilot needs Microphone and Speech Recognition access. Turn them on in System Settings › Privacy & Security.")
                return
            }
            do {
                heardText = ""
                try voice.start(locales: resolvedListenLocales)
                setPhase(.listening)
                Sounds.play(.listen)
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    /// The talk chord was part of another shortcut: drop it quietly.
    func cancelListening() {
        voice.cancel()
        if phase == .listening { setPhase(.idle) }
    }

    /// The microphone button in Home and the notch: click to talk, click
    /// again to send.
    func toggleListening() {
        if phase == .listening {
            Task { await endListening() }
        } else {
            beginListening()
        }
    }

    func endListening() async {
        guard phase == .listening else { return }
        let text = await voice.stop()
        if let language = voice.lastLanguage { speaker.fallbackLanguage = language }
        guard !text.isEmpty else {
            setPhase(.idle)
            return
        }
        await ask(text, includeScreen: true)
    }

    // MARK: Asking

    /// Sends a question, optionally with screenshots of every display.
    func ask(_ text: String, includeScreen: Bool) async {
        interrupt()
        guard hasAPIKey else {
            showError("Add your Anthropic API key in Cursor Pilot's Settings first.")
            return
        }
        Sounds.play(.send)
        overlay.state.readAlong = speakReplies
        heardText = text
        replyText = ""
        lastError = nil
        liveSteps = []
        backgroundWork = false
        requestFinished = false
        ComputerControl.shared.beginTask()
        setPhase(.thinking)

        // A question asked while (or right after) drawing is about the drawing.
        let sketch = includeScreen && ink.hasStrokes
        if ink.state.sketching {
            ink.endSketch(keepStrokes: true)
            try? await Task.sleep(for: .milliseconds(80)) // let the toolbar disappear
        }

        var screens: [ScreenShotPayload] = []
        let early = precapture
        precapture = nil
        if includeScreen {
            if !sketch, let early, Date().timeIntervalSince(early.at) < 25 {
                screens = await early.task.value
            }
            if !screens.isEmpty {
                // Captured when you pressed the talk key.
            } else if ScreenCapture.hasPermission {
                do {
                    screens = try await ScreenCapture.captureAll(includingWindows: sketch ? ink.windowNumbers : [])
                } catch {
                    NSLog("Cursor Pilot: screen capture failed: \(error)")
                }
            } else if !askedForScreen {
                askedForScreen = true
                ScreenCapture.requestPermission()
            } else {
                flashNotice("Can't see your screen: allow Screen Recording in Settings")
            }
        }

        requestFinished = false
        let id = core.send(CoreRequest(text: text, screens: screens, sketch: sketch && !screens.isEmpty)) { [weak self] event in
            self?.handle(event)
        }
        activeRequest = id
    }

    private func handle(_ event: CoreEvent) {
        switch event {
        case .started(let conversationID):
            if conversationID != currentConversationID {
                // Long silence started a fresh conversation.
                currentConversationID = conversationID
                reloadOpenTranscript()
            }
        case .text(let t):
            replyText += t
            if phase == .thinking { setPhase(.answering) }
            overlay.state.caption = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        case .speak(let sentence):
            if speakReplies {
                speaker.speak(sentence, number: sentencesQueued)
                sentencesQueued += 1
            }
        case .point(let x, let y, let label):
            showInTime { [weak self] in self?.overlay.point(atTopLeft: CGPoint(x: x, y: y), label: label) }
        case .mark(let shape, let label):
            showInTime { [weak self] in self?.ink.add(InkMark(shape: shape, label: label)) }
        case .tool(let step):
            switch step.phase {
            case "start":
                liveSteps.append(step)
                overlay.state.activity = step.summary
                // Only work in apps shows next to the cursor, as the agent's
                // own pointer; shell, file and web work stays out of sight.
                backgroundWork = step.kind != "computer" && step.kind != "app"
                // A task at work glows calmly instead of pulsing for minutes.
                if glow.mode == .thinking { glow.mode = .answering }
            default:
                if let i = liveSteps.lastIndex(where: { $0.phase == "start" && ($0.callID.isEmpty ? $0.summary == step.summary : $0.callID == step.callID) }) {
                    liveSteps[i] = step
                } else {
                    liveSteps.append(step)
                }
                overlay.state.activity = nil
            }
        case .helper(let e):
            handle(helper: e)
        case .done(let text):
            replyText = text
            overlay.state.caption = text
        case .error(let kind, let message):
            if kind != "cancelled" { showError(message) }
        case .finished:
            if !speaker.isSpeaking { releaseVisuals(upTo: .max) }
            ComputerControl.endAll()
            if lastError == nil, !liveSteps.isEmpty { Sounds.play(.done) }
            requestFinished = true
            activeRequest = nil
            refreshConversations()
            reloadOpenTranscript()
            refreshMemory()
            settleIfDone()
            if ink.hasStrokes { ink.fadeStrokes(after: 20) }
        }
    }

    /// A helper agent's progress: its cursor shows what it's doing, and its
    /// step in the chat says it too until it reports back.
    func handle(helper e: HelperEvent) {
        let cursors = HelperCursors.shared
        switch e.phase {
        case "start": cursors.start(agent: e.agent, name: e.name, status: e.text)
        case "end": cursors.finish(agent: e.agent, ok: e.ok)
        default:
            cursors.update(agent: e.agent, status: e.text)
            if !e.text.isEmpty,
               let i = liveSteps.lastIndex(where: { $0.callID == e.callID && $0.phase == "start" }) {
                liveSteps[i].summary = "\(e.name): \(e.text)"
            }
        }
    }

    /// Returns to idle once the reply has streamed and been spoken, leaving
    /// the bubble up for a moment so it can be read.
    private func settleIfDone() {
        guard requestFinished, !speaker.isSpeaking, phase == .answering || phase == .thinking else { return }
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, self.requestFinished, !self.speaker.isSpeaking else { return }
            self.setPhase(.idle)
        }
    }

    /// Stops whatever is running: listening, the request, speech, pointing.
    /// Points and draws when the voice reaches the sentence the tag sits in,
    /// so the buddy and the ink move with what is being said. A tag belongs
    /// to the sentence still being written when it arrives.
    private func showInTime(_ show: @escaping () -> Void) {
        let sentence = sentencesQueued
        if !speakReplies || sentence <= sentenceSpoken {
            show()
        } else {
            heldVisuals.append((sentence, show))
        }
    }

    private func releaseVisuals(upTo sentence: Int) {
        let due = heldVisuals.filter { $0.sentence <= sentence }
        heldVisuals.removeAll { $0.sentence <= sentence }
        for v in due { v.show() }
    }

    func interrupt() {
        heldVisuals.removeAll()
        sentencesQueued = 0
        sentenceSpoken = -1
        overlay.state.spoken = nil
        resetTask?.cancel()
        if let id = activeRequest { core.cancel(id) }
        ComputerControl.endAll()
        overlay.state.activity = nil
        activeRequest = nil
        speaker.stop()
        voice.cancel()
        overlay.clearPoints()
        ink.clearMarks()
        if phase != .idle { setPhase(.idle) }
    }

    // MARK: Drawing

    func toggleSketch() {
        ink.toggleSketch()
    }

    /// Saves the display under the sketch toolbar, with the pen strokes, to
    /// the drawings shown in Home.
    func saveDrawing() async {
        guard ScreenCapture.hasPermission else {
            ScreenCapture.requestPermission()
            return
        }
        let screen = NSScreen.screens.first { $0.displayID == ink.state.toolbarScreen } ?? NSScreen.main
        guard let screen else { return }
        do {
            let image = try await ink.withoutToolbar {
                try await ScreenCapture.captureImage(of: screen, maxEdge: 2560, includingWindows: ink.windowNumbers)
            }
            guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            else { return }
            let question = ink.state.question.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = question.isEmpty
                ? "Drawing, " + Date().formatted(date: .abbreviated, time: .shortened)
                : question
            if core.saveDrawing(png: png, title: title) != nil {
                refreshDrawings()
                flashNotice("Saved to Drawings")
            }
        } catch {
            NSLog("Cursor Pilot: saving drawing failed: \(error)")
        }
    }

    func refreshDrawings() {
        drawings = core.drawings()
    }

    func deleteDrawing(_ id: String) {
        core.deleteDrawing(id: id)
        refreshDrawings()
    }

    func refreshMemory() {
        memory = core.memory()
    }

    /// Forgets one fact, or everything when `id` is nil.
    func forgetMemory(_ id: String?) {
        core.forgetMemory(id: id)
        refreshMemory()
    }

    /// Reads a message aloud on request (the speaker button in Home).
    func speak(_ text: String) {
        speaker.stop()
        // Markdown symbols read badly aloud.
        let plain = text.replacingOccurrences(of: "[*_`#>]+", with: "", options: .regularExpression)
        speaker.speak(plain)
    }

    func stopSpeaking() { speaker.stop() }

    var isSpeaking: Bool { speaker.isSpeaking }

    private func flashNotice(_ text: String) {
        overlay.state.notice = text
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(text.count > 40 ? 4 : 2))
            if self?.overlay.state.notice == text { self?.overlay.state.notice = nil }
        }
    }

    private func setPhase(_ p: Phase) {
        phase = p
        switch p {
        case .idle:
            overlay.state.mode = .idle
            overlay.state.caption = ""
            overlay.state.spoken = nil
            overlay.state.level = 0
        case .listening:
            backgroundWork = false
            overlay.state.caption = ""
            overlay.state.mode = .listening
        case .thinking:
            overlay.state.mode = .thinking
        case .answering:
            overlay.state.mode = .answering
        }
        refreshGlow()
    }

    /// The screen frame follows the phase; between questions it glows softly
    /// while you draw.
    private func refreshGlow(sketching: Bool? = nil) {
        switch phase {
        case .listening: glow.mode = .listening
        case .thinking: glow.mode = .thinking
        case .answering: glow.mode = lastError == nil ? .answering : .off
        case .idle: glow.mode = (sketching ?? ink.state.sketching) ? .sketching : .off
        }
    }

    private func showError(_ message: String) {
        Sounds.play(.error)
        lastError = message
        phase = .answering
        requestFinished = true
        overlay.state.caption = message
        overlay.state.mode = .error
        refreshGlow()
        settleIfDone()
    }

    // MARK: History

    func refreshConversations() {
        conversations = core.conversations()
        currentConversationID = core.currentConversationID
        historyRevision += 1
    }

    func newConversation() {
        interrupt()
        core.newConversation()
        replyText = ""
        heardText = ""
        refreshConversations()
        reloadOpenTranscript()
    }

    /// Opens a saved conversation in Home and makes it the live one, so the
    /// next question (typed or spoken) continues it.
    func openConversation(_ id: String) {
        guard id != currentConversationID else {
            reloadOpenTranscript()
            return
        }
        if phase != .idle { interrupt() }
        core.resumeConversation(id: id)
        replyText = ""
        heardText = ""
        currentConversationID = core.currentConversationID
        reloadOpenTranscript()
    }

    func renameConversation(_ id: String, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        core.renameConversation(id: id, title: title)
        refreshConversations()
        reloadOpenTranscript()
    }

    func deleteConversation(_ id: String) {
        if id == currentConversationID { interrupt() }
        core.deleteConversation(id: id)
        refreshConversations()
        reloadOpenTranscript()
    }

    private func reloadOpenTranscript() {
        openTranscript = core.transcript(id: currentConversationID)
    }
}
