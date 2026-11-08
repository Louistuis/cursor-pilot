@preconcurrency import AVFoundation
import NaturalLanguage
import Speech

/// Push-to-talk speech recognition.
///
/// It can listen for two languages at once, say Norwegian and English: a
/// recognizer for each hears the same audio, and when you let go it keeps the
/// transcript its recognizer was surest of. On macOS 26 each language uses
/// Apple's on-device SpeechAnalyzer models (SpeechTranscriber, or
/// DictationTranscriber for languages only it covers); otherwise
/// SFSpeechRecognizer. Audio is captured from the moment you press, so the
/// first words aren't lost.
@MainActor
final class VoiceInput {
    private let engine = AVAudioEngine()
    /// Everything you say, for the engine that writes the final transcript.
    private let recorder = AudioRecorder()
    private var listeners: [any Listener] = []
    private var texts: [String] = []
    private var isRunning = false

    /// On-device models that are ready, by locale identifier.
    private var models: [String: ModelPlan] = [:]

    /// The language of the last thing you said; its transcript shows live
    /// first next time.
    private(set) var lastLanguage = UserDefaults.standard.string(forKey: "lastHeardLanguage")

    /// 0...1 microphone level, for the waveform.
    var onLevel: ((Float) -> Void)?
    var onPartial: ((String) -> Void)?

    /// Words that should be recognised as written.
    static let vocabulary = ["Cursor Pilot", "Claude", "Anthropic", "macOS", "Finder", "Xcode", "GitHub", "Safari"]

    static func requestPermissions() async -> Bool {
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        return mic && speech
    }

    /// The languages to listen for: the chosen one, or else the first two
    /// languages in the Mac's language list that a recognizer understands.
    static func resolvedLocales(_ chosen: String) async -> [Locale] {
        if !chosen.isEmpty { return [Locale(identifier: chosen)] }
        var found: [Locale] = []
        for l in Locale.preferredLanguages.map({ Locale(identifier: $0) }) {
            guard found.count < 2, let s = await supported(l),
                  !found.contains(where: { $0.language.languageCode == s.language.languageCode })
            else { continue }
            found.append(s)
        }
        return found.isEmpty ? [Locale(identifier: "en-US")] : found
    }

    /// The closest locale some recognizer here understands.
    private static func supported(_ locale: Locale) async -> Locale? {
        if #available(macOS 26, *), let plan = await ModelPlan.find(for: locale) { return plan.locale }
        let legacy = SFSpeechRecognizer.supportedLocales()
        let code = locale.language.languageCode
        return legacy.first { $0.identifier == locale.identifier.replacingOccurrences(of: "-", with: "_") }
            ?? legacy.first { $0.language.languageCode == code && $0.region == locale.region }
            ?? legacy.first { $0.language.languageCode == code }
    }

    /// Gets the on-device models ready for `locales`, downloading them in
    /// the background if needed; until then the older recognizer is used.
    func prepare(locales: [Locale]) async {
        guard #available(macOS 26, *) else { return }
        var ready: [String: ModelPlan] = [:]
        for locale in locales {
            guard let plan = await ModelPlan.find(for: locale), let prepared = await plan.prepared() else { continue }
            ready[locale.identifier] = prepared
        }
        models = ready
    }

    /// `echoCancel`: hands-free, where the Mac may be talking while you do;
    /// voice processing takes its own voice out of the mic as well as it can.
    func start(locales: [Locale], echoCancel: Bool = false) throws {
        if engine.inputNode.isVoiceProcessingEnabled != echoCancel {
            if engine.isRunning { engine.stop() }
            do {
                try engine.inputNode.setVoiceProcessingEnabled(echoCancel)
                if echoCancel {
                    // Don't turn the user's other audio down while listening.
                    engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                        AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
                }
            } catch {
                NSLog("Cursor Pilot: voice processing unavailable: \(error)")
            }
        }
        try start(locales: locales, input: nil)
    }

    /// Writes down audio someone else records (the live voice's mic), for
    /// the live caption: returns where each buffer goes. `onPartial` gets
    /// the words as they come; `endListen()` stops it. Leaves this
    /// recorder's own mic alone.
    func listen(locales: [Locale], format: AVAudioFormat) -> (@Sendable (AVAudioPCMBuffer) -> Void)? {
        endListen()
        let made = makeListeners(locales: locales, format: format)
        guard !made.isEmpty else { return nil }
        listeners = made
        texts = Array(repeating: "", count: made.count)
        isRunning = true
        let sinks = made.map(\.sink)
        return { buffer in for sink in sinks { sink(buffer) } }
    }

    func endListen() {
        guard isRunning else { return }
        isRunning = false
        for l in listeners { l.cancel() }
        listeners = []
    }

    private func makeListeners(locales: [Locale], format: AVAudioFormat) -> [any Listener] {
        var made: [any Listener] = []
        for (i, locale) in locales.enumerated() {
            let onText: @Sendable (String) -> Void = { [weak self] text in
                Task { @MainActor in self?.heard(text, from: i) }
            }
            if #available(macOS 26, *), let plan = models[locale.identifier],
               let listener = try? ModernListener(plan: plan, input: format, onText: onText) {
                made.append(listener)
            } else if let listener = try? LegacyListener(locale: locale, onText: onText) {
                made.append(listener)
            }
        }
        return made
    }

    /// Forgets the audio so far (its own voice, before you cut in); what
    /// you say next is what gets written down.
    func restartRecording() {
        recorder.reset(sampleRate: engine.inputNode.outputFormat(forBus: 0).sampleRate)
    }

    /// Starts listening; with `input` set it reads that format instead of
    /// the microphone (for `transcribe(file:)`).
    private func start(locales: [Locale], input: AVAudioFormat?) throws {
        cancel()
        let format = input ?? engine.inputNode.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw VoiceError.noMicrophone }

        let made = makeListeners(locales: locales, format: format)
        guard !made.isEmpty else { throw VoiceError.unavailable }
        listeners = made
        texts = Array(repeating: "", count: made.count)
        isRunning = true
        recorder.reset(sampleRate: format.sampleRate)
        guard input == nil else { return }

        let sinks = made.map(\.sink)
        let recorder = recorder
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            for sink in sinks { sink(buffer) }
            recorder.append(buffer)
            let level = Self.level(of: buffer)
            Task { @MainActor in self?.onLevel?(level) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            cancel()
            throw error
        }
    }

    /// Stops listening and returns the transcript, waiting briefly for the
    /// recognizers to settle on their final results.
    func stop() async -> String {
        guard isRunning else { return "" }
        isRunning = false
        stopAudio()
        let all = listeners
        listeners = []
        let heard = await withTaskGroup(of: (Int, Heard).self) { group in
            for (i, l) in all.enumerated() { group.addTask { (i, await l.finish()) } }
            var out = [Heard](repeating: Heard(text: "", confidence: nil, language: ""), count: all.count)
            for await (i, h) in group { out[i] = h }
            return out
        }
        let best = Self.pick(heard)
        if let best, heard.count > 1 {
            lastLanguage = heard[best].language
            UserDefaults.standard.set(lastLanguage, forKey: "lastHeardLanguage")
        }
        let quick = best.map { heard[$0].text } ?? ""
        return await finalText(quick: quick, language: best.map { heard[$0].language }, listening: all.count)
    }

    /// The transcript to send: written by MAI-Transcribe or Whisper from
    /// the recording when that engine is on, Apple's live one otherwise or
    /// when it fails.
    private func finalText(quick: String, language: String?, listening: Int) async -> String {
        let audio = recorder.take()
        let seconds = Double(audio.samples.count) / Double(max(audio.rate, 1))
        // Too short, or too quiet to be speech.
        guard seconds >= 0.35, audio.peak > 0.015 else { return quick }
        let engine = SpeechEngine.current
        let started = Date()
        var text: String?
        switch engine {
        case .cloud where CloudSpeech.hasKey:
            // With two languages, the model tells which (and follows a switch mid-sentence).
            let hint = listening == 1 ? LocalSpeech.whisperLanguage(language).map { $0 == "no" ? "nb" : $0 } : nil
            text = try? await withTimeout(10) {
                try await CloudSpeech.transcribe(audio.samples, sampleRate: audio.rate, language: hint)
            }
        case .local:
            if let whisper = LocalSpeech.shared.whisper {
                let hint = LocalSpeech.whisperLanguage(quick.isEmpty ? nil : language)
                text = try? await withTimeout(10) {
                    try await whisper.transcribe(audio.samples, sampleRate: audio.rate, language: hint)
                }
            }
        default:
            break
        }
        guard let text, !text.isEmpty, !(quick.isEmpty && LocalSpeech.isPhantom(text)) else {
            if engine != .apple { NSLog("Cursor Pilot: \(engine.rawValue) transcript unavailable, using Apple's") }
            return quick
        }
        NSLog("Cursor Pilot: \(engine.rawValue) heard “\(text)” in \(String(format: "%.2f", Date().timeIntervalSince(started))) s (Apple: “\(quick)”)")
        return text
    }

    func cancel() {
        isRunning = false
        stopAudio()
        for l in listeners { l.cancel() }
        listeners = []
    }

    private func heard(_ text: String, from index: Int) {
        guard isRunning, texts.indices.contains(index) else { return }
        texts[index] = text
        // Live text comes from the language you spoke last time, until you
        // let go and the surest one is picked.
        let shown = listeners.firstIndex { $0.locale.language.languageCode?.identifier == lastLanguage } ?? 0
        let text = texts.indices.contains(shown) && !texts[shown].isEmpty ? texts[shown] : texts.first { !$0.isEmpty } ?? ""
        onPartial?(text)
    }

    // MARK: Choosing

    /// What one recognizer heard.
    struct Heard: Sendable {
        var text: String
        /// 0...1, how sure the recognizer was, when it says.
        var confidence: Double?
        /// The language code it listened for.
        var language: String
    }

    /// The transcript to keep: the one its recognizer was surest of, nudged
    /// by how much the words read like that recognizer's language.
    static func pick(_ heard: [Heard]) -> Int? {
        let candidates = heard.indices.filter { !heard[$0].text.isEmpty }
        guard candidates.count > 1 else { return candidates.first }
        let languages = heard.map { NLLanguage($0.language) }
        let scores = candidates.map { i -> Double in
            let r = NLLanguageRecognizer()
            r.languageConstraints = languages
            r.processString(heard[i].text)
            let fit = r.languageHypotheses(withMaximum: languages.count)[languages[i]] ?? 0
            return (heard[i].confidence ?? 0.5) * 0.8 + fit * 0.2
        }
        let best = zip(candidates, scores).max { $0.1 < $1.1 }!.0
        NSLog("Cursor Pilot: heard \(zip(candidates, scores).map { "\(heard[$0.0].language) \(String(format: "%.2f", $0.1)) “\(heard[$0.0].text)”" }.joined(separator: " | ")) → \(heard[best].language)")
        return best
    }

    // MARK: Audio

    private func stopAudio() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    private nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(n))
        // Map roughly -50 dB...-10 dB onto 0...1.
        let db = 20 * log10(max(rms, 1e-6))
        return min(max((db + 50) / 40, 0), 1)
    }
}

extension VoiceInput {
    /// Runs an audio file through the same recognizers as the microphone and
    /// reports what each heard (the -CPHear test).
    func transcribe(file url: URL, locales: [Locale]) async throws -> (text: String, heard: [Heard]) {
        let file = try AVAudioFile(forReading: url)
        try start(locales: locales, input: file.processingFormat)
        let sinks = listeners.map(\.sink)
        let recorder = recorder
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { break }
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            for sink in sinks { sink(buffer) }
            recorder.append(buffer)
            // Roughly four times real time, so recognizers keep up.
            try await Task.sleep(for: .seconds(Double(buffer.frameLength) / file.processingFormat.sampleRate / 4))
        }
        isRunning = false
        let all = listeners
        listeners = []
        var heard: [Heard] = []
        for l in all { heard.append(await l.finish()) }
        let best = Self.pick(heard)
        let text = await finalText(quick: best.map { heard[$0].text } ?? "", language: best.map { heard[$0].language },
                                   listening: all.count)
        return (text, heard)
    }
}

// MARK: - Recognizers

/// One recognizer listening for one language. `sink` takes audio buffers on
/// the audio thread.
private protocol Listener: AnyObject, Sendable {
    var locale: Locale { get }
    var sink: @Sendable (AVAudioPCMBuffer) -> Void { get }
    func finish() async -> VoiceInput.Heard
    func cancel()
}

/// Which on-device model handles a language, and the audio it wants.
private struct ModelPlan: @unchecked Sendable {
    enum Kind { case speech, dictation }
    var locale: Locale
    var kind: Kind
    var format: AVAudioFormat?

    /// SpeechTranscriber where it covers the language (it is better with
    /// long, natural speech), else DictationTranscriber.
    @available(macOS 26, *)
    static func find(for locale: Locale) async -> ModelPlan? {
        if SpeechTranscriber.isAvailable, let l = await SpeechTranscriber.supportedLocale(equivalentTo: locale),
           l.language.languageCode == locale.language.languageCode,
           await SpeechTranscriber.supportedLocales.contains(where: { $0.identifier == l.identifier }) {
            return ModelPlan(locale: l, kind: .speech)
        }
        if let l = await DictationTranscriber.supportedLocale(equivalentTo: locale),
           l.language.languageCode == locale.language.languageCode,
           await DictationTranscriber.supportedLocales.contains(where: { $0.identifier == l.identifier }) {
            return ModelPlan(locale: l, kind: .dictation)
        }
        return nil
    }

    @available(macOS 26, *)
    func module() -> any SpeechModule {
        switch kind {
        case .speech:
            SpeechTranscriber(locale: locale, transcriptionOptions: [],
                              reportingOptions: [.volatileResults, .fastResults],
                              attributeOptions: [.transcriptionConfidence])
        case .dictation:
            DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                 reportingOptions: [.volatileResults, .frequentFinalization],
                                 attributeOptions: [.transcriptionConfidence])
        }
    }

    /// Downloads the model if needed and settles the audio format.
    @available(macOS 26, *)
    func prepared() async -> ModelPlan? {
        let module = module()
        do {
            if let install = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await install.downloadAndInstall()
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else { return nil }
            var plan = self
            plan.format = format
            return plan
        } catch {
            NSLog("Cursor Pilot: speech model for \(locale.identifier) unavailable: \(error)")
            return nil
        }
    }
}

/// One utterance through SpeechAnalyzer. Finalized segments are kept and the
/// volatile tail replaced as it firms up.
@available(macOS 26, *)
private final class ModernListener: Listener, @unchecked Sendable {
    let locale: Locale
    let sink: @Sendable (AVAudioPCMBuffer) -> Void
    private let feed: AsyncStream<AnalyzerInput>.Continuation
    private let analyzer: SpeechAnalyzer
    private var results: Task<Void, Never>?
    private let lock = NSLock()
    private var finalized = ""
    private var volatile = ""
    private var sure = (sum: 0.0, weight: 0.0)

    init(plan: ModelPlan, input: AVAudioFormat, onText: @escaping @Sendable (String) -> Void) throws {
        guard let target = plan.format, let converter = AVAudioConverter(from: input, to: target) else {
            throw VoiceError.unavailable
        }
        locale = plan.locale
        let module = plan.module()
        analyzer = SpeechAnalyzer(modules: [module])
        let (stream, feed) = AsyncStream<AnalyzerInput>.makeStream()
        self.feed = feed
        sink = { buffer in
            if let converted = Self.convert(buffer, with: converter, to: target) {
                feed.yield(AnalyzerInput(buffer: converted))
            }
        }
        results = Task { [weak self] in
            do {
                if let t = module as? SpeechTranscriber {
                    for try await r in t.results { self?.take(r.text, final: r.isFinal, onText) }
                } else if let t = module as? DictationTranscriber {
                    for try await r in t.results { self?.take(r.text, final: r.isFinal, onText) }
                }
            } catch {}
        }
        Task { [analyzer] in try? await analyzer.start(inputSequence: stream) }
    }

    private func take(_ text: AttributedString, final: Bool, _ onText: @Sendable (String) -> Void) {
        let t = String(text.characters)
        let joined = lock.withLock {
            if final {
                finalized = Self.join(finalized, t)
                volatile = ""
                for run in text.runs {
                    guard let c = run.transcriptionConfidence else { continue }
                    let w = Double(text[run.range].characters.count)
                    sure.sum += c * w
                    sure.weight += w
                }
            } else {
                volatile = t
            }
            return Self.join(finalized, volatile)
        }
        onText(joined)
    }

    /// Ends the audio and waits (briefly) for the last words.
    func finish() async -> VoiceInput.Heard {
        feed.finish()
        await Self.upTo(0.9) { [analyzer] in try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        await Self.upTo(0.2) { [results] in await results?.value }
        return lock.withLock {
            VoiceInput.Heard(text: Self.join(finalized, volatile).trimmingCharacters(in: .whitespacesAndNewlines),
                             confidence: sure.weight > 0 ? sure.sum / sure.weight : nil,
                             language: locale.language.languageCode?.identifier ?? "")
        }
    }

    func cancel() {
        feed.finish()
        results?.cancel()
        Task { [analyzer] in await analyzer.cancelAndFinishNow() }
    }

    /// Runs `op`, giving up on waiting after `seconds`.
    private static func upTo(_ seconds: Double, _ op: @escaping @Sendable () async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await op() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)) }
            await group.next()
            group.cancelAll()
        }
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter,
                                to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    private static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespaces), b = b.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }
}

/// One utterance through SFSpeechRecognizer.
private final class LegacyListener: Listener, @unchecked Sendable {
    let locale: Locale
    let sink: @Sendable (AVAudioPCMBuffer) -> Void
    private let request: SFSpeechAudioBufferRecognitionRequest
    private var task: SFSpeechRecognitionTask?
    private let lock = NSLock()
    private var latest = ""
    private var sure: Double?
    private var settled = false
    private var waiting: CheckedContinuation<Void, Never>?

    init(locale: Locale, onText: @escaping @Sendable (String) -> Void) throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw VoiceError.unavailable
        }
        self.locale = locale
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Server recognition is noticeably more accurate; on-device is used
        // automatically when offline.
        request.requiresOnDeviceRecognition = false
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.contextualStrings = VoiceInput.vocabulary
        self.request = request
        sink = { buffer in request.append(buffer) }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            let text = self.lock.withLock { () -> String? in
                guard let result else { return nil }
                self.latest = result.bestTranscription.formattedString
                if result.isFinal {
                    let segments = result.bestTranscription.segments
                    let total = segments.reduce(0) { $0 + $1.substring.count }
                    if total > 0 {
                        self.sure = segments.reduce(0.0) { $0 + Double($1.confidence) * Double($1.substring.count) } / Double(total)
                    }
                }
                return self.latest
            }
            if let text { onText(text) }
            if result?.isFinal == true || error != nil { self.settle() }
        }
    }

    func finish() async -> VoiceInput.Heard {
        request.endAudio()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if settled { return true }
                waiting = c
                return false
            }
            if resumeNow { c.resume() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.settle() }
        }
        task = nil
        return lock.withLock {
            VoiceInput.Heard(text: latest.trimmingCharacters(in: .whitespacesAndNewlines), confidence: sure,
                             language: locale.language.languageCode?.identifier ?? "")
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        settle()
    }

    private func settle() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            settled = true
            defer { waiting = nil }
            return waiting
        }
        c?.resume()
    }
}

enum VoiceError: LocalizedError {
    case unavailable, noMicrophone
    var errorDescription: String? {
        switch self {
        case .unavailable: "Speech recognition isn't available right now."
        case .noMicrophone: "No microphone found. Connect one or pick it in System Settings › Sound."
        }
    }
}

extension VoiceInput {
    /// Languages speech recognition supports, sorted by display name.
    static func languages() -> [(id: String, name: String)] {
        SFSpeechRecognizer.supportedLocales()
            .map { ($0.identifier, Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier) }
            .sorted { $0.1.localizedCompare($1.1) == .orderedAscending }
    }
}
