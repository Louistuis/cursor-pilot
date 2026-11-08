import AVFoundation
import Foundation
import KokoroTTS
import WhisperASR

/// Neural speech that runs entirely on this Mac, on the Neural Engine:
/// Whisper large-v3 turbo hears you (Norwegian, English and the rest of
/// Whisper's languages), Kokoro speaks English replies. The models download
/// once, the first time, and nothing leaves the Mac after that. Until they
/// are ready, and for languages they don't cover, Apple's own speech is used.
@MainActor
final class LocalSpeech: ObservableObject {
    static let shared = LocalSpeech()

    enum Status: Equatable {
        case off
        case downloading(Double)
        case loading
        case ready
        case failed(String)

        var label: String {
            switch self {
            case .off: "Off"
            case .downloading(let f): "Downloading… \(Int(f * 100))%"
            case .loading: "Getting ready…"
            case .ready: "Ready"
            case .failed(let why): "Unavailable (\(why))"
            }
        }
    }

    @Published private(set) var hearing: Status = .off
    @Published private(set) var speaking: Status = .off

    private(set) var whisper: WhisperEngine?
    private(set) var kokoro: KokoroEngine?
    private var started = false

    /// Kokoro's English voices worth offering, best first.
    static let voices: [(id: String, name: String)] = [
        ("af_heart", "Heart · US"), ("af_bella", "Bella · US"), ("af_nicole", "Nicole · US"),
        ("am_michael", "Michael · US"), ("am_fenrir", "Fenrir · US"), ("am_puck", "Puck · US"),
        ("bf_emma", "Emma · UK"), ("bm_george", "George · UK"), ("bm_fable", "Fable · UK"),
    ]
    static let defaultVoice = "af_heart"

    /// Downloads (the first time) and loads both models in the background.
    func prepare() {
        guard !started else { return }
        // The models take about 2 GB, plus room for the Neural Engine's
        // compiled copies: don't fill the disk.
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? .max
        if free < 5_000_000_000 && !Self.downloaded {
            let why = "needs 5 GB free disk space"
            hearing = .failed(why)
            speaking = .failed(why)
            return
        }
        started = true
        Task { await loadKokoro() }
        Task { await loadWhisper() }
    }

    /// Whether the models were downloaded before.
    static var downloaded: Bool {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("qwen3-speech/models/aufklarer")
        return FileManager.default.fileExists(atPath: base.appendingPathComponent("Whisper-Large-v3-Turbo-CoreML/manifest.json").path)
    }

    private func loadKokoro() async {
        speaking = .downloading(0)
        do {
            let model = try await KokoroTTSModel.fromPretrained { fraction, _ in
                Task { @MainActor in
                    let s = LocalSpeech.shared
                    s.speaking = fraction < 0.7 ? .downloading(fraction / 0.7) : .loading
                }
            }
            kokoro = KokoroEngine(model: model)
            speaking = .ready
            NSLog("Cursor Pilot: Kokoro ready")
        } catch {
            speaking = .failed(Self.short(error))
            NSLog("Cursor Pilot: Kokoro failed: \(error)")
        }
    }

    private func loadWhisper() async {
        hearing = .downloading(0)
        do {
            let model = try await WhisperASRModel.fromPretrained { fraction, _ in
                Task { @MainActor in
                    let s = LocalSpeech.shared
                    s.hearing = fraction < 0.85 ? .downloading(fraction / 0.85) : .loading
                }
            }
            let engine = WhisperEngine(model: model)
            // The first pass compiles the models for the Neural Engine; do it
            // now rather than on the first thing you say.
            _ = try? await engine.transcribe([Float](repeating: 0, count: 16_000), sampleRate: 16_000, language: "en")
            whisper = engine
            hearing = .ready
            NSLog("Cursor Pilot: Whisper ready")
        } catch {
            hearing = .failed(Self.short(error))
            NSLog("Cursor Pilot: Whisper failed: \(error)")
        }
    }

    private static func short(_ error: Error) -> String {
        let text = (error as NSError).localizedDescription
        return text.count > 60 ? String(text.prefix(60)) + "…" : text
    }

    /// Whisper's code for a language Cursor Pilot listens for.
    static func whisperLanguage(_ code: String?) -> String? {
        guard let code = code?.lowercased(), !code.isEmpty else { return nil }
        let base = String(code.prefix(while: { $0 != "-" && $0 != "_" }))
        return ["nb", "nn", "no"].contains(base) ? "no" : base
    }

    /// Lines Whisper is known to invent out of silence or noise.
    static func isPhantom(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let phantoms = ["thank you", "thanks for watching", "thank you for watching", "you", "bye", "takk for at du så på",
                        "teksting av nicolai winther", "undertekster av ai-media", "subtitles by the amara.org community"]
        return t.isEmpty || phantoms.contains(t) || t.hasPrefix("teksting av") || t.hasPrefix("undertekst")
    }
}

/// Whisper, one transcription at a time.
actor WhisperEngine {
    private let model: WhisperASRModel
    init(model: WhisperASRModel) { self.model = model }

    func transcribe(_ samples: [Float], sampleRate: Int, language: String?) async throws -> String {
        try await model.transcribeAudio(samples, sampleRate: sampleRate, language: language)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Kokoro, one sentence at a time.
actor KokoroEngine {
    static let sampleRate = 24_000
    private let model: KokoroTTSModel
    init(model: KokoroTTSModel) { self.model = model }

    var voices: [String] { model.availableVoices }

    func synthesize(_ text: String, voice: String, speed: Float) throws -> [Float] {
        let v = model.availableVoices.contains(voice) ? voice : LocalSpeech.defaultVoice
        return try model.synthesize(text: text, voice: v, language: "en", speed: speed)
    }
}

/// The microphone's audio while you talk, kept for Whisper. Appended to on
/// the audio thread.
final class AudioRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var rate: Double = 16_000
    private var peak: Float = 0
    /// Two minutes, at most.
    private let limit = 120.0

    func reset(sampleRate: Double) {
        lock.lock(); defer { lock.unlock() }
        samples.removeAll(keepingCapacity: true)
        rate = sampleRate
        peak = 0
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        lock.lock(); defer { lock.unlock() }
        guard Double(samples.count) < rate * limit else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: data, count: n))
        for i in 0..<n { peak = max(peak, abs(data[i])) }
    }

    /// What was recorded, its sample rate and loudest sample; empties it.
    func take() -> (samples: [Float], rate: Int, peak: Float) {
        lock.lock(); defer { lock.unlock() }
        let out = (samples, Int(rate), peak)
        samples = []
        peak = 0
        return out
    }
}

/// Plays neural speech (24 kHz mono), one sentence after the other, sped
/// up without changing pitch when asked.
@MainActor
final class NeuralPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let speed = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(standardFormatWithSampleRate: Double(KokoroEngine.sampleRate), channels: 1)!
    private var wired = false

    /// Plays `samples` and returns when they have been heard (or `stop`).
    func play(_ samples: [Float], rate: Float = 1) async {
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        do {
            if !wired {
                engine.attach(node)
                engine.attach(speed)
                engine.connect(node, to: speed, format: format)
                engine.connect(speed, to: engine.mainMixerNode, format: format)
                wired = true
            }
            speed.rate = max(0.5, min(2, rate))
            if !engine.isRunning { try engine.start() }
        } catch {
            NSLog("Cursor Pilot: audio out failed: \(error)")
            return
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in c.resume() }
            if !node.isPlaying { node.play() }
        }
    }

    func stop() {
        node.stop()
    }
}
