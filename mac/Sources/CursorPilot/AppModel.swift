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
    /// Tasks running in the background, and ones that just finished.
    @Published private(set) var jobs: [BackgroundJob] = []
    var hasRunningJobs: Bool { jobs.contains { $0.state == "running" } }
    /// Whiteboards Claude drew, to open again from the chat.
    @Published private(set) var boards: [BoardRecord] = BoardStore.load()
    /// The board being drawn in this reply.
    private var boardLog: BoardRecord?

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
    /// The OpenAI key, for the live voice (GPT-Live).
    @Published var openAIKey: String {
        didSet {
            if !isLoadingKey {
                let key = openAIKey
                Task.detached { Keychain.saveOpenAIKey(key) }
            }
            if SpeechEngine.current == .live {
                LiveVoice.shared.disconnect()
                applyLiveVoice()
            }
        }
    }
    /// The abliteration.ai key, for the abliterated models.
    @Published var abliterationKey: String {
        didSet {
            if !isLoadingKey {
                let key = abliterationKey
                Task.detached { Keychain.saveAbliterationKey(key) }
            }
            configureCore()
        }
    }
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
    /// Talk back and forth without the key: after an answer the mic stays
    /// open for a reply, and you can cut in while it talks.
    @Published var handsFree: Bool {
        didSet {
            defaults.set(handsFree, forKey: "handsFree")
            if !handsFree { endHandsFree() }
            if SpeechEngine.current == .live {
                LiveVoice.shared.disconnect()
                applyLiveVoice()
            }
        }
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
    @Published var backgroundWork = false {
        didSet {
            overlay.state.backgroundWork = backgroundWork
            if backgroundWork != oldValue { parkBuddy() }
        }
    }
    /// A request is under way (from sending it until it finishes).
    private var requestActive = false
    /// A sentence is being read aloud right now.
    /// Its voice is playing (any engine); the caption shows wherever the buddy is.
    private var speakingNow = false { didSet { overlay.state.talking = speakingNow } }
    /// The answer is being read: the task's work is over.
    /// This task looked at or used the screen (screenshots, clicks, typing).
    private var usedScreen = false
    private var parkTask: Task<Void, Never>?
    /// Whether Cursor Pilot may work on the Mac by itself (consented in onboarding or Settings).
    @Published var macAccess: Bool { didSet { defaults.set(macAccess ? "on" : "off", forKey: "accessLevel"); configureCore() } }
    /// "person": it uses your own mouse and keyboard. "background": its own pointer.
    @Published var inputMode: String { didSet { defaults.set(inputMode, forKey: "inputMode"); configureCore() } }
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

    static let claudeModels = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"]
    /// abliteration.ai's models, which speak the same Messages API.
    static let abliterationModels = ["abliterated-model-large-flash", "abliterated-model", "abliterated-model-large-v2"]
    static let models = claudeModels + abliterationModels

    static func isAbliteration(_ model: String) -> Bool { model.hasPrefix("abliterated-") }
    var usesAbliteration: Bool { Self.isAbliteration(model) }
    /// The key the chosen model needs.
    var activeKey: String { usesAbliteration ? abliterationKey : apiKey }
    var providerName: String { usesAbliteration ? "abliteration.ai" : "Anthropic" }
    static let efforts = ["low", "medium", "high", "xhigh", "max"]

    let core: Core
    let overlay = OverlayController()
    let ink = InkController()
    let glow = GlowController()
    /// The whiteboard Claude draws explanations on.
    let board = BoardController()
    /// The 3D view of what Claude explains.
    let scenes = SceneController()
    /// Drawings, board pieces and pointing, one after another: the buddy
    /// holds the pen, so it does one thing at a time.
    private var drawQueue: Task<Void, Never>?
    /// ```scene blocks in this reply already opened.
    private var scenesShown = 0
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
    /// Sentences sent to the voice in this reply, and the one being spoken.
    private var sentencesQueued = 0
    private var sentenceSpoken = -1
    /// Pointing and drawings waiting for the voice to reach their sentence.
    private var heldVisuals: [(sentence: Int, show: () -> Void)] = []
    private var activeRequest: UInt64?
    /// Bumped whenever what's running is stopped or replaced. A request's
    /// events still on their way after that (the core confirms a cancel a
    /// moment later) must not touch what came next.
    private var requestSerial = 0
    /// The last request is over and saved (its reply may still be playing).
    @Published private(set) var requestFinished = true
    private var resetTask: Task<Void, Never>?

    var hasAPIKey: Bool { !activeKey.trimmingCharacters(in: .whitespaces).isEmpty }

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cursor Pilot", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        guard let core = Core(dataDirectory: support) else { fatalError("Cursor Pilot core failed to start") }
        self.core = core

        apiKey = ""
        abliterationKey = ""
        openAIKey = ""
        model = defaults.string(forKey: "model") ?? Self.models[0]
        effort = defaults.string(forKey: "effort") ?? "low"
        speakReplies = defaults.object(forKey: "speakReplies") as? Bool ?? true
        showBuddy = defaults.object(forKey: "showBuddy") as? Bool ?? true
        showNotch = defaults.object(forKey: "showNotch") as? Bool ?? true
        showGlow = defaults.object(forKey: "showGlow") as? Bool ?? true
        hideFromRecordings = defaults.bool(forKey: "hideFromRecordings")
        doubleTapToType = defaults.object(forKey: "doubleTapToType") as? Bool ?? true
        handsFree = defaults.object(forKey: "handsFree") as? Bool ?? false
        hideBuddyWhenIdle = defaults.object(forKey: "hideBuddyWhenIdle") as? Bool ?? true
        talkKey = defaults.string(forKey: "talkKey").flatMap(TalkKey.init(rawValue:)) ?? .controlOption
        listenLocale = defaults.string(forKey: "listenLocale") ?? ""
        voiceID = defaults.string(forKey: "voiceID") ?? ""
        speechRate = defaults.object(forKey: "speechRate") as? Double ?? 1.0
        macAccess = (defaults.string(forKey: "accessLevel") ?? "off") != "off"
        inputMode = defaults.string(forKey: "inputMode") ?? "person"
        shortcut = defaults.data(forKey: "shortcut").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
            ?? .default

        voice.onLevel = { [weak self] level in
            guard let self else { return }
            if bargeWatch {
                if level > Self.voiceLevel { lastVoiceAt = Date() }
                return
            }
            overlay.state.level = level
            glow.level = level
            if openMic { followOpenMic(level: level) }
        }
        voice.onPartial = { [weak self] text in
            guard let self else { return }
            if bargeWatch {
                if isUserTalking(over: text) { bargeIn() }
                return
            }
            heardText = text
            if requestActive {
                // Talking while it works: your words show where the buddy is.
                hearingClear?.cancel()
                overlay.state.hearing = text
            } else {
                overlay.state.caption = text
            }
        }
        speaker.onIdle = { [weak self] in
            guard let self else { return }
            speakingNow = false
            stopBargeWatch()
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
            speakingNow = true
            recentlySaid = Array((recentlySaid + [text]).suffix(4))
            startBargeWatch()
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
        prepareSpeechEngine()
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
        let (key, ablit, openai) = await Task.detached {
            (Keychain.loadAPIKey(), Keychain.loadAbliterationKey(), Keychain.loadOpenAIKey())
        }.value
        isLoadingKey = true
        apiKey = key
        abliterationKey = ablit
        openAIKey = openai
        isLoadingKey = false
    }

    func start() {
        configureCore()
        core.attachAgentHost()
        core.attachJobs()
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
        core.configure(CoreSettings(apiKey: activeKey,
                                    baseURL: usesAbliteration ? "https://api.abliteration.ai" : "https://api.anthropic.com",
                                    model: model, effort: effort, access: macAccess ? "on" : "off", input: inputMode))
    }

    /// Gets the chosen speech engine ready: the cloud's key and voice list,
    /// or the on-device models (downloaded the first time).
    func prepareSpeechEngine() {
        Task.detached {
            if CloudSpeech.hasKey { _ = await VoiceCatalog.shared.voices(model: CloudSpeech.voiceModel) }
            let engine = SpeechEngine.current
            if engine == .local { await MainActor.run { LocalSpeech.shared.prepare() } }
            await MainActor.run { AppModel.shared.applyLiveVoice() }
        }
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
    /// Counts the times you start talking, so a transcript that comes back
    /// after you've started again doesn't cut in on that.
    private var listenTurn = 0
    /// The talk key is down, from the press until it comes up or is called off.
    private var wantsToListen = false

    func beginListening(open: Bool = false) {
        if usesLiveVoice {
            beginLiveTalk()
            return
        }
        listenTurn += 1
        // It's working: talk to it without stopping the work.
        if requestActive, activeRequest != nil {
            beginTalkingOverTask(open: open)
            return
        }
        interrupt()
        wantsToListen = true
        openMic = open
        openMicSince = Date()
        heardSpeechAt = nil
        lastVoiceAt = nil
        core.warm()
        if ScreenCapture.hasPermission, !ink.hasStrokes {
            precapture = (Task { (try? await ScreenCapture.captureAll(includingWindows: [])) ?? [] }, Date())
        }
        Task {
            guard Setup.hasVoice else {
                showError("Cursor Pilot can't hear you yet: run \(Setup.hint).")
                return
            }
            // The key came up before this ran (a tap while the app was
            // busy): starting now would leave the mic open with no key held.
            guard wantsToListen else { return }
            do {
                heardText = ""
                try voice.start(locales: resolvedListenLocales, echoCancel: handsFree)
                setPhase(.listening)
                if !open { Sounds.play(.listen) }
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    /// The talk chord was part of another shortcut: drop it quietly.
    func cancelListening() {
        if usesLiveVoice {
            // The live voice's mic was opened too: close it, and send nothing.
            LiveVoice.shared.cancelTalk()
            LiveVoice.shared.micSink = nil
            voice.endListen()
            overlay.state.hearing = nil
            if phase == .listening { setPhase(.idle) }
            return
        }
        wantsToListen = false
        voice.cancel()
        guard phase == .listening else { return }
        if talkingOverTask {
            // It was working when the key went down: back to that, not to idle.
            talkingOverTask = false
            overlay.state.hearing = nil
            setPhase(requestActive ? phaseBeforeTalk : .idle)
            refreshWorking()
        } else {
            setPhase(.idle)
        }
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
        if usesLiveVoice {
            LiveVoice.shared.releaseTalk()
            LiveVoice.shared.micSink = nil
            voice.endListen()
            clearHearing()
            if phase == .listening {
                setPhase(.thinking)
                // Nothing may come back (a tap of the key, a dropped
                // connection): it doesn't stay thinking for ever.
                resetTask?.cancel()
                resetTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(8))
                    guard !Task.isCancelled, let self, self.phase == .thinking, !self.requestActive,
                          !self.speakingNow else { return }
                    self.setPhase(.idle)
                }
            }
            return
        }
        wantsToListen = false
        guard phase == .listening else { return }
        openMic = false
        if talkingOverTask {
            await endTalkingOverTask()
            return
        }
        let turn = listenTurn
        let text = await voice.stop()
        // The key went down again meanwhile: that's the question now.
        guard turn == listenTurn else { return }
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
        // The live voice keeps talking: this may be its own request.
        interrupt(hushLive: false)
        let serial = requestSerial
        let call = liveCall
        guard hasAPIKey else {
            showError("Add your \(providerName) API key in Cursor Pilot's Settings first.")
            return
        }
        Sounds.play(.send)
        overlay.state.readAlong = speakReplies && liveCall == nil
        heardText = text
        replyText = ""
        scenesShown = 0
        lastError = nil
        liveSteps = []
        requestActive = true
        usedScreen = false
        lastScreenStepAt = nil
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
                    // The board and 3D view stay in the picture, for questions about them.
                    let open = [board.windowNumber, scenes.windowNumber].compactMap { $0 }
                    screens = try await ScreenCapture.captureAll(includingWindows: (sketch ? ink.windowNumbers : []) + open)
                } catch {
                    NSLog("Cursor Pilot: screen capture failed: \(error)")
                }
            } else {
                flashNotice("Can't see your screen: run \(Setup.hint)")
            }
        }

        // Stopped, or something else was asked, while the screen was captured.
        guard serial == requestSerial else {
            dropLiveCall(call)
            return
        }
        requestFinished = false
        let id = core.send(CoreRequest(text: text, screens: screens, sketch: sketch && !screens.isEmpty)) { [weak self] event in
            guard let self else { return }
            if serial == requestSerial { handle(event) } else { handleStale(event, liveCall: call) }
        }
        activeRequest = id
    }

    /// An event from a request that was stopped or replaced: nothing of it
    /// shows or is said any more. What it saved is picked up when it ends.
    private func handleStale(_ event: CoreEvent, liveCall call: String?) {
        guard case .finished = event else { return }
        dropLiveCall(call)
        refreshConversations()
        reloadOpenTranscript()
        refreshMemory()
        if ink.hasStrokes { ink.fadeStrokes(after: 20) }
    }

    /// The live voice's request was stopped before Claude answered it: the
    /// voice is told, so it isn't left waiting for the answer.
    private func dropLiveCall(_ call: String?) {
        guard let call, call == liveCall else { return }
        LiveVoice.shared.finishTask(callID: call, output: "It couldn't finish: it was stopped.")
        liveCall = nil
        liveLines = []
        liveFailure = nil
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
            overlay.state.caption = captionText(replyText)
            // A 3D model opens as soon as its block is complete, before it's talked about.
            if t.contains("`") {
                let blocks = SceneSpec.blocks(in: replyText)
                if blocks.count > scenesShown {
                    scenesShown = blocks.count
                    if let spec = SceneSpec.parse(blocks[blocks.count - 1]) { scenes.show(spec) }
                }
            }
        case .speak(let sentence):
            // The live voice says Claude's lines itself: progress before a
            // step, and the answer at the end.
            if liveCall != nil {
                liveLines.append(sentence)
                return
            }
            if speakReplies {
                speaker.speak(sentence, number: sentencesQueued)
                sentencesQueued += 1
            }
        case .point(let x, let y, let label):
            showInTime { [weak self] in
                self?.enqueueDraw { [weak self] in
                    self?.overlay.point(atTopLeft: CGPoint(x: x, y: y), label: label)
                    try? await Task.sleep(for: .seconds(1.1))
                }
            }
        case .mark(let shape, let label):
            showInTime { [weak self] in
                self?.enqueueDraw { [weak self] in
                    guard let self else { return }
                    let (points, duration) = shape.penStroke()
                    let ink: Color = if case .check = shape { InkPalette.check } else { InkPalette.marker }
                    await overlay.draw(along: points, duration: duration, ink: ink) {
                        self.ink.add(InkMark(shape: shape, label: label, duration: duration))
                    }
                }
            }
        case .board(let item, let raw):
            if case .open(let title) = item {
                keepBoard()
                boardLog = BoardRecord(conversation: currentConversationID, title: title, at: Date(), items: [])
            } else if boardLog == nil {
                boardLog = BoardRecord(conversation: currentConversationID, title: "", at: Date(), items: [])
            }
            boardLog?.items.append(raw)
            showInTime { [weak self] in
                self?.enqueueDraw { [weak self] in
                    guard let self else { return }
                    await board.add(item, overlay: overlay)
                }
            }
        case .focus(let id):
            showInTime { [weak self] in
                self?.enqueueDraw { [weak self] in
                    guard let self, let (at, label) = await scenes.focus(id) else { return }
                    overlay.point(atTopLeft: at, label: label)
                    try? await Task.sleep(for: .seconds(1.2))
                }
            }
        case .tool(let step):
            switch step.phase {
            case "start":
                liveSteps.append(step)
                if liveCall != nil, !liveLines.isEmpty {
                    LiveVoice.shared.say(liveLines.joined(separator: " "))
                    liveLines = []
                }
                // What's running shows quietly by the thinking dots (a
                // command as typed) and stays until the next step replaces it.
                overlay.state.activityIcon = AgentStep.icon(for: step.kind)
                overlay.state.activityIsCommand = step.kind == "shell" && step.summary.hasPrefix("Ran ")
                overlay.state.activity = overlay.state.activityIsCommand ? String(step.summary.dropFirst(4)) : step.summary
                if step.kind == "computer" || (step.kind == "app" && Self.isOnScreen(step)) { usedScreen = true }
            default:
                if let i = liveSteps.lastIndex(where: { $0.phase == "start" && ($0.callID.isEmpty ? $0.summary == step.summary : $0.callID == step.callID) }) {
                    liveSteps[i] = step
                } else {
                    liveSteps.append(step)
                }
            }
            refreshWorking()
        case .helper(let e):
            handle(helper: e)
        case .heardWhileWorking(let text):
            if let i = notesForAgent.firstIndex(of: text) { notesForAgent.remove(at: i) }
        case .done(let text):
            replyText = text
            overlay.state.caption = captionText(text)
        case .error(let kind, let message):
            if liveCall != nil { liveFailure = message }
            if kind != "cancelled" { showError(message) }
        case .finished:
            if let call = liveCall {
                let answer = liveLines.joined(separator: " ")
                let output = liveFailure.map { "It couldn't finish: \($0)" } ?? (answer.isEmpty ? replyText : answer)
                LiveVoice.shared.finishTask(callID: call, output: output.isEmpty ? "Done." : output)
                liveCall = nil
                liveLines = []
                liveFailure = nil
            }
            requestActive = false
            backgroundWork = false
            overlay.state.activity = nil
            overlay.state.activityIcon = nil
            if !speaker.isSpeaking { releaseVisuals(upTo: .max) }
            ComputerControl.endAll()
            if lastError == nil, !liveSteps.isEmpty {
                Sounds.play(.done)
                overlay.state.doneBump += 1
            }
            requestFinished = true
            activeRequest = nil
            keepBoard()
            refreshConversations()
            reloadOpenTranscript()
            refreshMemory()
            settleIfDone()
            if ink.hasStrokes { ink.fadeStrokes(after: 20) }
            // Said too late for the task to read: it's the next question.
            if !notesForAgent.isEmpty {
                let leftover = notesForAgent.joined(separator: " ")
                notesForAgent = []
                Task { await self.ask(leftover, includeScreen: true) }
            }
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

    /// A background task's progress, and its report when it's over: a sound,
    /// the report in the chat, and read aloud unless something else is going on.
    func handle(job e: JobEvent) {
        let cursors = HelperCursors.shared
        let i = jobs.firstIndex { $0.id == e.job }
        switch e.phase {
        case "start":
            jobs.removeAll { $0.id == e.job }
            jobs.append(BackgroundJob(id: e.job, name: e.name, title: e.text, status: "Starting", state: "running"))
            cursors.start(agent: e.job, name: e.name, status: e.text)
        case "end":
            if let i {
                jobs[i].state = e.state
                jobs[i].status = e.text
            }
            cursors.finish(agent: e.job, ok: e.state == "done")
            ComputerControl.end(agent: e.job)
            Sounds.play(e.state == "failed" ? .error : .done)
            refreshConversations()
            reloadOpenTranscript()
            if e.state != "stopped", phase == .idle, speakReplies, !speaker.isSpeaking {
                speak(captionText(e.text))
            }
            // The card stays a moment so the report can be read, then goes.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(12))
                self?.jobs.removeAll { $0.id == e.job && $0.state != "running" }
            }
        default:
            guard let i, !e.text.isEmpty else { return }
            jobs[i].status = e.text
            cursors.update(agent: e.job, status: e.text)
        }
    }

    func stopJob(_ id: Int) { core.stopJob(id) }

    /// Returns to idle once the reply has streamed and been spoken, leaving
    /// the bubble up for a moment so it can be read.
    private func settleIfDone() {
        guard requestFinished, !speaker.isSpeaking, phase == .answering || phase == .thinking else { return }
        resetTask?.cancel()
        // Hands-free: the mic opens for a reply, like a pause in a conversation.
        if handsFree, lastError == nil, speakReplies, !usesLiveVoice {
            resetTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, let self, self.requestFinished, !self.speaker.isSpeaking,
                      self.phase == .answering else { return }
                self.beginListening(open: true)
            }
            return
        }
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            // Not while you're talking again (the live voice's talk key
            // doesn't go through `interrupt`).
            guard !Task.isCancelled, let self, self.requestFinished, !self.speaker.isSpeaking,
                  self.phase != .listening else { return }
            self.setPhase(.idle)
            // Explained: the board and 3D view go after a while to look at them.
            self.board.closeSoon()
            self.scenes.closeSoon()
        }
    }

    /// Saves the board drawn in this reply, for the chat.
    private func keepBoard() {
        guard var record = boardLog, record.items.count > 1 else { return boardLog = nil }
        boardLog = nil
        record.at = Date()
        boards.append(record)
        BoardStore.save(boards)
    }

    /// Boards drawn while answering one message: after the reply before it,
    /// up to a minute after this reply was saved.
    func boards(in conversation: String, after: Int, until: Int) -> [BoardRecord] {
        boards.filter {
            let t = Int($0.at.timeIntervalSince1970)
            return $0.conversation == conversation && t > after && t <= until + 60
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

    /// Runs `job` after the drawings before it are done.
    private func enqueueDraw(_ job: @escaping @MainActor () async -> Void) {
        let previous = drawQueue
        drawQueue = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled else { return }
            await job()
        }
    }

    /// A visible action waits until what was just said about it has started
    /// playing, so it's said before it's done (at most 2.5 s).
    func narrationStarted() async {
        let deadline = Date().addingTimeInterval(2.5)
        while speakReplies, sentencesQueued > 0, sentenceSpoken < sentencesQueued - 1, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    func interrupt(keepingVoice: Bool = false, hushLive: Bool = true) {
        // Whatever the stopped request still sends is ignored from here on,
        // and typing under way ends where it is.
        requestSerial += 1
        HumanInput.stop()
        // Stop means the live voice goes quiet too.
        if hushLive { LiveVoice.shared.hush() }
        CursorTakeover.end()
        drawQueue?.cancel()
        drawQueue = nil
        heldVisuals.removeAll()
        sentencesQueued = 0
        sentenceSpoken = -1
        overlay.state.spoken = nil
        resetTask?.cancel()
        if let id = activeRequest { core.cancel(id) }
        ComputerControl.endAll()
        overlay.state.activity = nil
        overlay.state.activityIcon = nil
        activeRequest = nil
        requestActive = false
        requestFinished = true
        // What was said for the stopped task goes with it, and a board it
        // was drawing is kept as far as it got.
        notesForAgent = []
        talkingOverTask = false
        keepBoard()
        speakingNow = false
        backgroundWork = false
        overlay.state.hearing = nil
        speaker.stop()
        if !keepingVoice {
            voice.cancel()
            bargeWatch = false
            openMic = false
        }
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
            flashNotice("Can't capture the screen: run \(Setup.hint)")
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

    /// A short sample of the chosen voice, in English and, when you speak
    /// it, Norwegian too.
    func previewVoice(named name: String) {
        speaker.stop()
        speaker.speak("Hi, I'm \(name). This is how I'll sound when I answer you.")
        if resolvedListenLocales.contains(where: { ["nb", "nn", "no"].contains($0.language.languageCode?.identifier ?? "") }) {
            speaker.speak("Og sånn høres jeg ut på norsk.")
        }
    }

    func stopSpeaking() {
        speaker.stop()
        // `stop` doesn't report idle, so what follows the last sentence is
        // done here: the caption goes, the mic closes, the phase settles.
        speakingNow = false
        stopBargeWatch()
        releaseVisuals(upTo: .max)
        settleIfDone()
    }

    var isSpeaking: Bool { speaker.isSpeaking }

    private func flashNotice(_ text: String) {
        overlay.state.notice = text
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(text.count > 40 ? 4 : 2))
            if self?.overlay.state.notice == text { self?.overlay.state.notice = nil }
        }
    }

    /// While a task is under way the buddy stays the thinking dots, the
    /// work going on in the background; it turns back into the arrow for the
    /// answer or to use the pointer.
    private func refreshWorking() {
        let pointer = liveSteps.contains { $0.phase == "start" && ($0.kind == "computer" || ($0.kind == "app" && Self.isOnScreen($0))) }
        if pointer { lastScreenStepAt = Date() }
        // Between clicks it stays down by the pointer: only after a while
        // without using the screen does it go back up into the notch.
        let recent = lastScreenStepAt.map { Date().timeIntervalSince($0) < Self.screenLinger } ?? false
        if recent, !pointer, requestActive {
            workingRecheck?.cancel()
            workingRecheck = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.screenLinger + 0.1))
                guard !Task.isCancelled else { return }
                self?.refreshWorking()
            }
        }
        // It talks as it works (saying each step before it does it) without
        // leaving the notch; it comes down for the answer or to use the pointer.
        let working = requestActive && !liveSteps.isEmpty && !pointer && !recent
        if backgroundWork != working { backgroundWork = working }
        // Also when only the steps changed: the frame calms down once the
        // first step is under way, whether or not the buddy moved.
        refreshGlow()
    }

    private var lastScreenStepAt: Date?
    private var workingRecheck: Task<Void, Never>?
    /// How long it stays by the pointer after using the screen.
    private static let screenLinger: TimeInterval = 10

    /// app_control mostly works unseen; pressing and filling in click and type on screen.
    private static func isOnScreen(_ step: AgentStep) -> Bool {
        step.summary.hasPrefix("Pressed") || step.summary.hasPrefix("Filled")
    }

    /// While the work goes on in the background the buddy flies up into the
    /// notch, which lights up; it comes back down to talk or click. A change
    /// has to last a moment first, so it never bounces.
    private func parkBuddy() {
        parkTask?.cancel()
        let up = backgroundWork && showNotch
        parkTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(up ? 0.35 : 0.2))
            guard !Task.isCancelled, let self else { return }
            overlay.park(at: up ? notch?.parkingSpot : nil)
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

    // MARK: Talking while it works

    /// You're talking while a task runs: what you say goes to the agent
    /// mid-task (it reads it with its next step) instead of starting over.
    private var talkingOverTask = false
    private var phaseBeforeTalk: Phase = .thinking
    /// Told to the agent but not read yet; asked as a new question if the
    /// task ends first.
    private var notesForAgent: [String] = []

    private func beginTalkingOverTask(open: Bool) {
        guard Setup.hasVoice else { return }
        silenceSpeech()
        stopBargeWatch()
        openMic = open
        openMicSince = Date()
        heardSpeechAt = nil
        lastVoiceAt = nil
        do {
            heardText = ""
            try voice.start(locales: resolvedListenLocales, echoCancel: handsFree)
            talkingOverTask = true
            phaseBeforeTalk = phase == .listening ? .thinking : phase
            setPhase(.listening)
            if !open { Sounds.play(.listen) }
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func endTalkingOverTask() async {
        talkingOverTask = false
        clearHearing()
        let turn = listenTurn
        let text = await voice.stop()
        if turn == listenTurn {
            // The task may have ended while you talked: with nothing said,
            // there's nothing left to listen for or show.
            if requestActive { setPhase(phaseBeforeTalk) } else if text.isEmpty { setPhase(.idle) }
            refreshWorking()
        }
        // Talking again already, and the task is over: that's the question now.
        guard !text.isEmpty, turn == listenTurn || requestActive else { return }
        passToAgent(text)
    }

    /// Hands what you said to the running task, or asks it fresh if the task
    /// just finished.
    private func passToAgent(_ text: String) {
        if requestActive, let id = activeRequest, core.tell(id, text) {
            notesForAgent.append(text)
            Sounds.play(.send)
            flashNotice("Got it")
        } else {
            Task { await ask(text, includeScreen: true) }
        }
    }

    /// Stops what's being read aloud now, without stopping the work.
    private func silenceSpeech() {
        speaker.stop()
        speakingNow = false
        // Actions waiting for a line to start playing go ahead.
        sentenceSpoken = sentencesQueued - 1
    }

    // MARK: Live voice

    /// gpt-realtime-2.1 hears and talks; Claude does the work behind it.
    var usesLiveVoice: Bool { SpeechEngine.current == .live && !openAIKey.isEmpty }
    /// The live voice's request Claude is working on, and Claude's lines so far.
    private var liveCall: String?
    private var liveLines: [String] = []
    private var liveFailure: String?

    private func beginLiveTalk() {
        guard Setup.hasVoice else {
            showError("Cursor Pilot can't hear you yet: run \(Setup.hint).")
            return
        }
        wireLiveVoice()
        let live = LiveVoice.shared
        live.handsFree = handsFree
        live.pressTalk(key: openAIKey)
        // Cutting in on its answer starts the countdown back to idle: not now.
        resetTask?.cancel()
        overlay.state.caption = ""
        overlay.state.spoken = nil
        if requestActive {
            hearingClear?.cancel()
            overlay.state.hearing = ""
        }
        // Apple's on-device recognizer writes down what you say as you say
        // it, from the same mic; OpenAI's transcript replaces it when it comes.
        if let format = live.micFormat, let feed = voice.listen(locales: resolvedListenLocales, format: format) {
            live.micSink = feed
        }
        if !requestActive {
            setPhase(.listening)
            Sounds.play(.listen)
        }
    }

    /// `-CPNotchDemo caption|chat`: fills the notch for design work.
    func notchDemo(_ kind: String) {
        if kind == "caption" {
            let line = "I found three invoices from March. I'm putting them in one folder on your desktop now."
            backgroundWork = true
            overlay.state.backgroundWork = true
            overlay.state.docked = true
            overlay.state.dock = 1
            overlay.state.spoken = Self.karaoke(line, heard: 30)
            overlay.state.talking = true
            setPhase(.thinking)
        } else {
            heardText = "What's the biggest file in my Downloads folder?"
            replyText = "The biggest file in **Downloads** is `OpenBot-0.53.0-arm64.dmg` at 325 MB. Want me to move it to the Trash?"
        }
    }

    /// A caption of the live voice: what you're saying, or what it's saying.
    struct LiveCaption: Equatable {
        var you: Bool
        var spoken: SpokenWord
    }
    private var hearingClear: Task<Void, Never>?

    /// Your words stay a moment after you let go, then go.
    private func clearHearing() {
        hearingClear?.cancel()
        hearingClear = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            self?.overlay.state.hearing = nil
        }
    }

    /// The sentence `heard` (UTF-16 characters into `text`) has reached, and
    /// the word it's on, for the read-along caption.
    static func karaoke(_ text: String, heard: Int) -> SpokenWord {
        let ns = text as NSString
        let at = min(max(heard, 0), ns.length)
        var sentence = NSRange(location: 0, length: ns.length)
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.bySentences, .substringNotRequired]) { _, r, _, stop in
            if r.location <= max(at - 1, 0) { sentence = r } else { stop.pointee = true }
        }
        let line = ns.substring(with: sentence).trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = (ns.substring(with: sentence) as NSString).range(of: line).location
        let inLine = max(0, at - sentence.location - (lead == NSNotFound ? 0 : lead))
        var word = NSRange(location: 0, length: 0)
        (line as NSString).enumerateSubstrings(in: NSRange(location: 0, length: (line as NSString).length),
                                               options: [.byWords, .substringNotRequired]) { _, r, _, stop in
            if r.location < max(inLine, 1) { word = r } else { stop.pointee = true }
        }
        return SpokenWord(sentence: line, word: word)
    }

    /// Connects the live voice's events to the buddy and to Claude, once.
    private func wireLiveVoice() {
        let live = LiveVoice.shared
        guard live.onEvent == nil else { return }
        live.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .heard(let text):
                heardText = text
                if phase == .listening { overlay.state.caption = text }
            case .level(let level):
                // Only while the waveform shows (hands-free, the mic is open
                // all through a task: publishing every buffer then would
                // redraw the buddy and the notch some 20 times a second).
                guard phase == .listening || talkingOverTask || overlay.state.hearing != nil else { return }
                overlay.state.level = level
                glow.level = level
            case .speakingStarted:
                overlay.state.readAlong = false
                overlay.state.spoken = nil
                speakingNow = true
                if !requestActive, phase != .answering {
                    requestFinished = false
                    setPhase(.answering)
                }
            case .saying(let text, let heard):
                guard !text.isEmpty else { return }
                // This comes 20 times a second; the word moves on about
                // three times a second. Only a change is published.
                let spoken = Self.karaoke(text, heard: heard)
                if overlay.state.spoken != spoken { overlay.state.spoken = spoken }
                if !requestActive {
                    let caption = captionText(text)
                    if overlay.state.caption != caption { overlay.state.caption = caption }
                }
            case .speakingEnded:
                speakingNow = false
                if !requestActive {
                    requestFinished = true
                    settleIfDone()
                }
            case .task(let callID, let request) where requestActive && liveCall != nil:
                // Already working: it's passed on, and the voice says so.
                let text = request.isEmpty ? heardText : request
                if let id = activeRequest, core.tell(id, text) {
                    notesForAgent.append(text)
                    LiveVoice.shared.finishTask(callID: callID, output: "Passed on to the agent, which is still working on "
                        + "the earlier request; it will take this into account and answer. Tell the user in a few words.")
                } else {
                    LiveVoice.shared.finishTask(callID: callID, output: "The agent just finished; ask the user to say it again.")
                }
            case .task(let callID, let request):
                liveCall = callID
                liveLines = []
                liveFailure = nil
                Task { await self.ask(request.isEmpty ? self.heardText : request, includeScreen: true) }
            case .error(let message):
                showError(message)
            }
        }
    }

    /// Gets the live voice ready (connected, listening if hands-free) or
    /// closes it when another engine is chosen.
    func applyLiveVoice() {
        if usesLiveVoice {
            wireLiveVoice()
            LiveVoice.shared.handsFree = handsFree
            if handsFree { LiveVoice.shared.startHandsFree(key: openAIKey) }
        } else {
            LiveVoice.shared.disconnect()
        }
    }

    // MARK: Hands-free

    /// Mic level (0...1, about -36 dB) that counts as someone talking.
    private static let voiceLevel: Float = 0.35
    /// Listening without the key: opened after an answer, or by cutting in.
    private var openMic = false
    private var openMicSince = Date()
    private var heardSpeechAt: Date?
    private var lastVoiceAt: Date?
    /// The mic listens while it talks, for you cutting in.
    private var bargeWatch = false
    /// The last few sentences it said, to tell its own voice from yours.
    private var recentlySaid: [String] = []

    /// The open mic ends itself: after you stop talking, or if you don't
    /// say anything.
    private func followOpenMic(level: Float) {
        let now = Date()
        if level > Self.voiceLevel {
            lastVoiceAt = now
            if heardSpeechAt == nil {
                heardSpeechAt = now
                refreshGlow()
            }
        }
        if let last = lastVoiceAt, heardSpeechAt != nil, now.timeIntervalSince(last) > 0.9 {
            openMic = false
            Task { await endListening() }
        } else if heardSpeechAt == nil, now.timeIntervalSince(openMicSince) > 7 {
            openMic = false
            cancelListening()
        }
    }

    /// While it talks, the mic listens too (with echo cancellation), so you
    /// can cut in just by talking.
    private func startBargeWatch() {
        guard handsFree, !bargeWatch, phase != .listening, Setup.hasVoice else { return }
        do {
            try voice.start(locales: resolvedListenLocales, echoCancel: true)
            bargeWatch = true
        } catch {
            bargeWatch = false
        }
    }

    private func stopBargeWatch() {
        guard bargeWatch else { return }
        bargeWatch = false
        voice.cancel()
    }

    /// Whether what the mic hears is you rather than its own voice: several
    /// words it isn't saying, heard while the mic is loud.
    private func isUserTalking(over heard: String) -> Bool {
        func words(_ s: String) -> [String] {
            s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 }
        }
        let said = Set(recentlySaid.flatMap(words))
        let new = words(heard).filter { !said.contains($0) }
        guard let last = lastVoiceAt, Date().timeIntervalSince(last) < 0.6 else { return false }
        return new.count >= 3 && Double(new.count) >= 0.6 * Double(max(words(heard).count, 1))
    }

    /// You started talking over it: it stops, drops what it was doing in
    /// front (background tasks carry on) and listens.
    private func bargeIn() {
        bargeWatch = false
        listenTurn += 1
        voice.restartRecording()
        if requestActive, activeRequest != nil {
            // It's working: it stops talking and listens; the work carries on.
            silenceSpeech()
            talkingOverTask = true
            phaseBeforeTalk = phase == .listening ? .thinking : phase
        } else {
            interrupt(keepingVoice: true)
        }
        openMic = true
        openMicSince = Date()
        heardSpeechAt = Date()
        lastVoiceAt = Date()
        heardText = ""
        setPhase(.listening)
    }

    private func endHandsFree() {
        stopBargeWatch()
        if openMic {
            openMic = false
            cancelListening()
        }
    }

    /// The screen frame follows the phase; between questions it glows softly
    /// while you draw.
    /// The frame is for when Cursor Pilot looks at or uses the screen:
    /// hearing you, thinking about what's on it, clicking and typing. Work in
    /// the background lights the notch instead.
    private func refreshGlow(sketching: Bool? = nil) {
        let offScreen = backgroundWork || (!liveSteps.isEmpty && !usedScreen)
        switch phase {
        // An open mic waiting for a reply stays quiet until you talk.
        case .listening: glow.mode = openMic && heardSpeechAt == nil ? .off : .listening
        case .thinking: glow.mode = offScreen ? .off : liveSteps.isEmpty ? .thinking : .answering
        case .answering: glow.mode = lastError == nil && !offScreen ? .answering : .off
        case .idle: glow.mode = (sketching ?? ink.state.sketching) ? .sketching : .off
        }
    }

    private func showError(_ message: String) {
        Sounds.play(.error)
        overlay.state.errorBump += 1
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
