@preconcurrency import AVFoundation
import Speech

/// Push-to-talk speech recognition.
///
/// On macOS 26 it uses SpeechAnalyzer with SpeechTranscriber, Apple's newer
/// on-device model, which is far more accurate for long, natural speech;
/// elsewhere (or for languages it doesn't cover) SFSpeechRecognizer. Audio
/// is captured from the moment you press, and buffered while the recognizer
/// warms up, so the first words aren't lost.
@MainActor
final class VoiceInput {
    private let engine = AVAudioEngine()
    private var latest = ""
    private var finalContinuation: CheckedContinuation<String, Never>?

    // SFSpeechRecognizer path
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    // SpeechAnalyzer path (type-erased so the class builds for macOS 14)
    private var modern: AnyObject?
    private var isRunning = false

    /// The locale the modern model is ready for, once `prepare` found one.
    private(set) var modernLocale: Locale?
    private var modernFormat: AVAudioFormat?

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

    /// The language to listen for: the chosen one, or else the first of the
    /// user's languages that the best available recognizer understands.
    static func resolvedLocale(_ chosen: String) async -> Locale {
        if !chosen.isEmpty { return Locale(identifier: chosen) }
        let preferred = Locale.preferredLanguages.map { Locale(identifier: $0) }
        if #available(macOS 26, *), SpeechTranscriber.isAvailable {
            let supported = Set(await SpeechTranscriber.supportedLocales.map(\.identifier))
            for l in preferred {
                if let s = await SpeechTranscriber.supportedLocale(equivalentTo: l), supported.contains(s.identifier) { return s }
            }
        }
        let legacy = Set(SFSpeechRecognizer.supportedLocales().map(\.identifier))
        return preferred.first { legacy.contains($0.identifier) || legacy.contains($0.identifier.replacingOccurrences(of: "-", with: "_")) }
            ?? Locale(identifier: "en-US")
    }

    /// Gets the modern model ready for `locale`, downloading it in the
    /// background if needed; until then the older recognizer is used.
    func prepare(locale: Locale) async {
        modernLocale = nil
        guard #available(macOS 26, *), SpeechTranscriber.isAvailable,
              let l = await SpeechTranscriber.supportedLocale(equivalentTo: locale),
              await SpeechTranscriber.supportedLocales.contains(where: { $0.identifier == l.identifier })
        else { return }
        let transcriber = SpeechTranscriber(locale: l, preset: .progressiveTranscription)
        do {
            if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await install.downloadAndInstall()
            }
            modernFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            modernLocale = modernFormat == nil ? nil : l
        } catch {
            NSLog("Cursor Pilot: speech model for \(l.identifier) unavailable: \(error)")
        }
    }

    func start(locale: Locale) throws {
        cancel()
        latest = ""
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw VoiceError.noMicrophone }

        if #available(macOS 26, *), let l = modernLocale, let target = modernFormat,
           l.language.languageCode == locale.language.languageCode {
            try startModern(locale: l, input: format, target: target)
        } else {
            try startLegacy(locale: locale, input: format)
        }
        isRunning = true
    }

    /// Stops listening and returns the transcript, waiting briefly for the
    /// recognizer to settle on its final result.
    func stop() async -> String {
        guard isRunning else { return latest }
        isRunning = false
        stopAudio()
        if #available(macOS 26, *), let session = modern as? ModernSession {
            modern = nil
            let text = await session.finish()
            if !text.isEmpty { latest = text }
            return latest.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        request?.endAudio()
        let text = await withCheckedContinuation { c in
            finalContinuation = c
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.resolveFinal() }
        }
        task = nil
        request = nil
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        isRunning = false
        stopAudio()
        if #available(macOS 26, *), let session = modern as? ModernSession { session.cancel() }
        modern = nil
        task?.cancel()
        task = nil
        request = nil
        resolveFinal()
    }

    // MARK: Modern

    @available(macOS 26, *)
    private func startModern(locale: Locale, input: AVAudioFormat, target: AVAudioFormat) throws {
        let session = ModernSession(locale: locale, target: target) { [weak self] text in
            Task { @MainActor in
                guard let self, self.isRunning || !text.isEmpty else { return }
                self.latest = text
                self.onPartial?(text)
            }
        }
        guard let converter = AVAudioConverter(from: input, to: target) else { throw VoiceError.unavailable }
        let feed = session.feed
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: input) { [weak self] buffer, _ in
            let level = Self.level(of: buffer)
            Task { @MainActor in self?.onLevel?(level) }
            if let converted = Self.convert(buffer, with: converter, to: target) {
                feed.yield(AnalyzerInput(buffer: converted))
            }
        }
        engine.prepare()
        try engine.start()
        session.begin()
        modern = session
    }

    private nonisolated static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter,
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

    // MARK: Legacy

    private func startLegacy(locale: Locale, input format: AVAudioFormat) throws {
        let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else { throw VoiceError.unavailable }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Server recognition is noticeably more accurate; on-device is used
        // automatically when offline.
        request.requiresOnDeviceRecognition = false
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.contextualStrings = Self.vocabulary
        self.request = request

        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let level = Self.level(of: buffer)
            Task { @MainActor in self?.onLevel?(level) }
        }
        engine.prepare()
        try engine.start()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            Task { @MainActor in
                guard let self else { return }
                if let text {
                    self.latest = text
                    self.onPartial?(text)
                }
                if isFinal || error != nil { self.resolveFinal() }
            }
        }
    }

    private func resolveFinal() {
        finalContinuation?.resume(returning: latest)
        finalContinuation = nil
    }

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

/// One push-to-talk utterance through SpeechAnalyzer. Audio goes into
/// `feed` from the first buffer; the analyzer starts reading it as soon as
/// it is set up. Finalized segments are kept and the volatile tail replaced
/// as it firms up.
@available(macOS 26, *)
private final class ModernSession: @unchecked Sendable {
    let feed: AsyncStream<AnalyzerInput>.Continuation
    private let stream: AsyncStream<AnalyzerInput>
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let onText: (String) -> Void
    private var finalized = ""
    private var volatile = ""
    private var results: Task<Void, Never>?
    private var running: Task<Void, Never>?
    private let lock = NSLock()

    init(locale: Locale, target: AVAudioFormat, onText: @escaping (String) -> Void) {
        transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        analyzer = SpeechAnalyzer(modules: [transcriber])
        (stream, feed) = AsyncStream<AnalyzerInput>.makeStream()
        self.onText = onText
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return Self.join(finalized, volatile)
    }

    func begin() {
        results = Task { [weak self, transcriber] in
            do {
                for try await r in transcriber.results {
                    guard let self else { return }
                    let t = String(r.text.characters)
                    self.lock.withLock {
                        if r.isFinal {
                            self.finalized = Self.join(self.finalized, t)
                            self.volatile = ""
                        } else {
                            self.volatile = t
                        }
                    }
                    self.onText(self.text)
                }
            } catch {}
        }
        running = Task { [analyzer, stream] in
            try? await analyzer.start(inputSequence: stream)
        }
    }

    /// Ends the audio and waits (briefly) for the last words.
    func finish() async -> String {
        feed.finish()
        await Self.upTo(1.5) { [analyzer] in try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        await Self.upTo(0.3) { [results] in await results?.value }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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

    func cancel() {
        feed.finish()
        results?.cancel()
        Task { [analyzer] in await analyzer.cancelAndFinishNow() }
    }

    private static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespaces), b = b.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
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
