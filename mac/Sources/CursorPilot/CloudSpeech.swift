import AVFoundation
import Foundation

/// Which engines hear you and speak the replies.
enum SpeechEngine: String, CaseIterable, Identifiable {
    /// Microsoft's MAI-Transcribe 2 and MAI-Voice 2.1, through OpenRouter.
    case cloud
    /// Whisper and Kokoro on this Mac's Neural Engine.
    case local
    /// macOS's own speech recognition and voices.
    case apple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cloud: "Cloud · Microsoft MAI (OpenRouter)"
        case .local: "On this Mac · Whisper + Kokoro"
        case .apple: "Apple"
        }
    }

    static var current: SpeechEngine {
        if let raw = UserDefaults.standard.string(forKey: "speechEngine"), let e = SpeechEngine(rawValue: raw) { return e }
        // Cloud when there's a key for it, else the local models.
        return CloudSpeech.hasKey ? .cloud : .local
    }
}

/// Cloud speech through OpenRouter, only for hearing and speaking: a
/// transcription model writes down what you say (MAI-Transcribe 2 by
/// default), a voice model reads replies (Microsoft MAI-Voice or ElevenLabs
/// Eleven v4).
enum CloudSpeech {
    static let api = URL(string: "https://openrouter.ai/api/v1")!
    static let sampleRate = 24_000

    struct Model: Identifiable, Hashable {
        let id: String
        let name: String
        let detail: String
    }

    /// Best first, as of November 2026 (FLEURS multilingual and Artificial
    /// Analysis word error rates; all handle Norwegian except where noted).
    /// Ranked by Artificial Analysis word error rate (batch, Nov 2026).
    static let hearingModels: [Model] = [
        Model(id: "microsoft/mai-transcribe-2", name: "Microsoft MAI-Transcribe 2", detail: "Most accurate (2.0% WER), fastest"),
        Model(id: "mistralai/voxtral-small-transcribe-3-0", name: "Mistral Voxtral Small Transcribe 3", detail: "2.1% WER"),
        Model(id: "elevenlabs/scribe-v2", name: "ElevenLabs Scribe v2", detail: "2.2% WER, 90+ languages"),
        Model(id: "google/gemini-3.5-transcribe", name: "Google Gemini 3.5 Transcribe", detail: "2.6% WER, mixed languages"),
        Model(id: "openai/gpt-transcribe", name: "OpenAI GPT Transcribe", detail: "Fallback"),
    ]
    /// Best first for spoken replies: natural, quick to start, Norwegian
    /// (Artificial Analysis Speech Arena and Coval time to first audio, Nov 2026).
    static let voiceModels: [Model] = [
        Model(id: "elevenlabs/eleven-v4-turbo", name: "ElevenLabs Eleven v4 Turbo", detail: "Most natural fast voice, Norwegian"),
        Model(id: "microsoft/mai-voice-2.1-flash", name: "Microsoft MAI-Voice 2.1 Flash", detail: "Fast, real Norwegian voices"),
        Model(id: "microsoft/mai-voice-2.1", name: "Microsoft MAI-Voice 2.1", detail: "Finest Microsoft voice"),
        Model(id: "elevenlabs/eleven-v4", name: "ElevenLabs Eleven v4", detail: "#1 naturalness, slower"),
        Model(id: "google/gemini-3.8-flash-lite-tts", name: "Google Gemini 3.8 Flash Lite TTS", detail: "Expressive, cheapest"),
        Model(id: "google/gemini-3.8-flash-tts", name: "Google Gemini 3.8 Flash TTS", detail: "Expressive, slowest to start"),
    ]

    static var hearingModel: String {
        UserDefaults.standard.string(forKey: "cloudHearingModel") ?? hearingModels[0].id
    }
    static var voiceModel: String {
        UserDefaults.standard.string(forKey: "cloudVoiceModel") ?? voiceModels[0].id
    }
    /// Microsoft's voices are one name in several languages; ElevenLabs' and
    /// Google's voices speak every language themselves.
    static func isMicrosoft(_ model: String) -> Bool { model.hasPrefix("microsoft/") }
    static func defaultVoice(for model: String) -> String {
        isMicrosoft(model) ? "Harper" : model.hasPrefix("google/") ? "Kore" : "sarah"
    }
    /// The chosen voice for `model` (each model remembers its own).
    static func voiceName(for model: String) -> String {
        UserDefaults.standard.string(forKey: "cloudVoice.\(model)") ?? defaultVoice(for: model)
    }
    static func setVoiceName(_ name: String, for model: String) {
        UserDefaults.standard.set(name, forKey: "cloudVoice.\(model)")
    }

    private static let keyLock = NSLock()
    nonisolated(unsafe) private static var cachedKey: String?

    /// The key, read once (Keychain, then the environment, then
    /// ~/.config/openrouter.key).
    static var key: String {
        keyLock.withLock {
            if let cachedKey { return cachedKey }
            let k = Keychain.loadOpenRouterKey()
            cachedKey = k
            return k
        }
    }
    static var hasKey: Bool { !key.isEmpty }
    static func forgetKey() { keyLock.withLock { cachedKey = nil } }

    enum Failure: LocalizedError {
        case noKey, http(Int, String), empty
        var errorDescription: String? {
            switch self {
            case .noKey: "No OpenRouter key"
            case .http(let code, let body): "OpenRouter \(code): \(body.prefix(160))"
            case .empty: "Nothing came back"
            }
        }
    }

    private static func request(_ path: String, body: [String: Any], timeout: TimeInterval) throws -> URLRequest {
        guard hasKey else { throw Failure.noKey }
        var r = URLRequest(url: api.appendingPathComponent(path), timeoutInterval: timeout)
        r.httpMethod = "POST"
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Cursor Pilot", forHTTPHeaderField: "X-Title")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return r
    }

    private static func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse?) {
        let (data, response) = try await URLSession.shared.data(for: r)
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200 else { throw Failure.http(http?.statusCode ?? 0, String(decoding: data, as: UTF8.self)) }
        return (data, http)
    }

    // MARK: Hearing

    /// What was said in `samples`. `language` is a hint (ISO 639-1); nil
    /// lets the model tell, which also handles switching mid-sentence.
    static func transcribe(_ samples: [Float], sampleRate: Int, language: String?) async throws -> String {
        let pcm = AudioMath.resample(samples, from: sampleRate, to: 16_000)
        var body: [String: Any] = [
            "model": hearingModel,
            "input_audio": ["data": AudioMath.wav(pcm, sampleRate: 16_000).base64EncodedString(), "format": "wav"],
        ]
        if let language { body["language"] = language }
        let (data, _) = try await send(request("audio/transcriptions", body: body, timeout: 20))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Speaking

    /// `text` spoken in the chosen voice (Microsoft: its version for
    /// `language`): 24 kHz mono samples.
    static func speak(_ text: String, language: String, model: String? = nil, voice: String? = nil) async throws -> [Float] {
        let model = model ?? voiceModel
        guard let id = await voiceID(for: language, model: model, name: voice ?? voiceName(for: model)) else { throw Failure.empty }
        let body: [String: Any] = ["model": model, "input": text, "voice": id, "response_format": "pcm"]
        let (data, response) = try await send(request("audio/speech", body: body, timeout: 30))
        guard data.count > 2 else { throw Failure.empty }
        let samples = AudioMath.floats(fromInt16: data)
        // "audio/pcm;rate=24000;channels=1"
        let type = response?.value(forHTTPHeaderField: "Content-Type") ?? ""
        let rate = type.split(separator: ";").compactMap { part -> Int? in
            let kv = part.split(separator: "=")
            return kv.count == 2 && kv[0].trimmingCharacters(in: .whitespaces) == "rate" ? Int(kv[1]) : nil
        }.first ?? sampleRate
        return rate == sampleRate ? samples : AudioMath.resample(samples, from: rate, to: sampleRate)
    }

    /// Whether the chosen voice model speaks `language` (two-letter code).
    static func speaks(_ language: String) async -> Bool {
        await voiceID(for: language, model: voiceModel, name: voiceName(for: voiceModel)) != nil
    }

    /// The id to send as `voice`. Microsoft: `nb-NO-Harper:MAI-Voice-2.1-Flash`
    /// for the name in `language`, or another voice of that language.
    /// ElevenLabs: the name as it is.
    static func voiceID(for language: String, model: String, name: String) async -> String? {
        let all = await VoiceCatalog.shared.voices(model: model)
        guard isMicrosoft(model) else {
            return all.isEmpty || all.contains(name) ? name : all.first
        }
        let prefixes = ["nb", "no", "nn"].contains(language) ? ["nb-", "no-"]
            : language == "en" ? ["en-US-", "en-GB-", "en-"] : [language + "-"]
        for p in prefixes {
            if let v = all.first(where: { $0.hasPrefix(p) && $0.contains("-\(name):") }) { return v }
        }
        for p in prefixes {
            if let v = all.first(where: { $0.hasPrefix(p) }) { return v }
        }
        return nil
    }

    /// The voices to offer for `model`, by name. Microsoft's English and
    /// Norwegian ones first (one name speaks both).
    static func voiceNames(model: String) async -> [String] {
        let all = await VoiceCatalog.shared.voices(model: model)
        guard isMicrosoft(model) else { return all }
        func name(_ id: String) -> String? {
            let base = id.split(separator: ":").first.map(String.init) ?? id
            return base.split(separator: "-").last.map(String.init)
        }
        let both = Set(all.filter { $0.hasPrefix("nb-") }.compactMap(name))
        let english = all.filter { $0.hasPrefix("en-") }.compactMap(name)
        var seen = Set<String>()
        let ordered = english.filter { both.contains($0) } + english + all.compactMap(name)
        return ordered.filter { seen.insert($0).inserted }
    }

    /// Whether a Microsoft voice name also has a Norwegian version.
    static func speaksNorwegian(_ name: String, model: String) async -> Bool {
        guard isMicrosoft(model) else { return true }
        return await VoiceCatalog.shared.voices(model: model).contains { $0.hasPrefix("nb-") && $0.contains("-\(name):") }
    }
}

/// OpenRouter's voices per speech model, fetched once.
actor VoiceCatalog {
    static let shared = VoiceCatalog()
    private var lists: [String: [String]] = [:]
    private var loading: Task<Void, Never>?

    func voices(model: String) async -> [String] {
        if let list = lists[model] { return list }
        if loading == nil { loading = Task { await self.load() } }
        await loading?.value
        loading = nil
        return lists[model] ?? []
    }

    private func load() async {
        guard let url = URL(string: "https://openrouter.ai/api/v1/models?output_modalities=speech"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]]
        else { return }
        for m in models {
            if let id = m["id"] as? String, let v = m["supported_voices"] as? [String] { lists[id] = v }
        }
    }
}

/// Small audio conversions shared by the speech engines.
enum AudioMath {
    /// Resamples mono audio with Core Audio's converter.
    static func resample(_ samples: [Float], from: Int, to: Int) -> [Float] {
        guard from != to, !samples.isEmpty,
              let inF = AVAudioFormat(standardFormatWithSampleRate: Double(from), channels: 1),
              let outF = AVAudioFormat(standardFormatWithSampleRate: Double(to), channels: 1),
              let converter = AVAudioConverter(from: inF, to: outF),
              let input = AVAudioPCMBuffer(pcmFormat: inF, frameCapacity: AVAudioFrameCount(samples.count))
        else { return samples }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let capacity = AVAudioFrameCount(Double(samples.count) * Double(to) / Double(from)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outF, frameCapacity: capacity) else { return samples }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil else { return samples }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    /// 16-bit mono WAV.
    static func wav(_ samples: [Float], sampleRate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in samples.indices { pcm[i] = Int16(max(-1, min(1, samples[i])) * 32767) }
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    /// Little-endian 16-bit PCM to floats.
    static func floats(fromInt16 data: Data) -> [Float] {
        let n = data.count / 2
        var out = [Float](repeating: 0, count: n)
        data.withUnsafeBytes { raw in
            for i in 0..<n {
                let v = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                out[i] = Float(v) / 32768
            }
        }
        return out
    }
}

/// Runs `work`, giving up after `seconds`.
func withTimeout<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw CancellationError()
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}
