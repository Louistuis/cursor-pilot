import AVFoundation
import NaturalLanguage

/// Reads reply sentences aloud as they stream in, each in a voice that
/// speaks the sentence's language: Microsoft's MAI-Voice in the cloud,
/// Kokoro on this Mac, or Apple's voices (see `SpeechEngine`). Sentences
/// play in order; the next is rendered while the one before plays.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private let player = NeuralPlayer()
    private var pending = 0
    var onIdle: (() -> Void)?
    /// A specific Apple voice (Apple engine, and the fallback); nil picks
    /// the best installed one per language.
    var voiceID: String?
    /// Multiplier on the default speaking rate.
    var rate: Float = 1
    /// Language assumed when a sentence is too short to tell.
    var fallbackLanguage = "en"
    private var lastLanguage: String?
    private var voiceCache: [String: AVSpeechSynthesisVoice] = [:]

    var isSpeaking: Bool { pending > 0 }
    /// A sentence starts being spoken: its number (from `speak`) and text.
    var onSentence: ((Int, String) -> Void)?
    /// The word about to be spoken, as a UTF-16 range of that sentence.
    var onWord: ((NSRange) -> Void)?
    private var numbers: [ObjectIdentifier: Int] = [:]

    /// Bumped by `stop`, so work from before it is dropped.
    private var epoch = 0
    /// The sentence being rendered last, and the one playing last.
    private var rendering: Task<Void, Never>?
    private var playing: Task<Void, Never>?
    /// Apple utterances waiting to finish.
    private var waiting: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]
    private var wordClock: Timer?

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String, number: Int = -1) {
        let lang = language(of: text)
        let engine = SpeechEngine.current
        let e = epoch
        pending += 1
        let rate = self.rate

        // Render in order, ahead of playback.
        let before = rendering
        let audio = Task<(samples: [Float], rate: Float)?, Never> {
            await before?.value
            guard self.epoch == e else { return nil }
            return await Self.render(text, language: lang, engine: engine, rate: rate)
        }
        rendering = Task { _ = await audio.value }

        let previous = playing
        playing = Task { [weak self] in
            await previous?.value
            guard let self, self.epoch == e else { return }
            if let rendered = await audio.value, !rendered.samples.isEmpty, self.epoch == e {
                await self.play(rendered.samples, playbackRate: rendered.rate, text: text, number: number)
            } else if self.epoch == e {
                await self.speakApple(text, language: lang, number: number)
            }
            guard self.epoch == e else { return }
            self.finishedOne()
        }
    }

    /// Neural audio for `text`, or nil to use an Apple voice. Kokoro speaks
    /// at the chosen rate itself; MAI-Voice's audio is sped up on playback.
    nonisolated static func render(_ text: String, language: String, engine: SpeechEngine, rate: Float) async -> (samples: [Float], rate: Float)? {
        switch engine {
        case .cloud, .live:
            // Live voice speaks for itself; anything read aloud otherwise uses the cloud voice.
            guard CloudSpeech.hasKey, await CloudSpeech.speaks(language) else { return nil }
            do {
                return (try await CloudSpeech.speak(text, language: language), rate)
            } catch {
                NSLog("Cursor Pilot: cloud voice failed, using Apple's: \(error.localizedDescription)")
                return nil
            }
        case .local:
            guard language == "en", let kokoro = await LocalSpeech.shared.kokoro else { return nil }
            let voice = UserDefaults.standard.string(forKey: "kokoroVoice") ?? LocalSpeech.defaultVoice
            return (try? await kokoro.synthesize(text, voice: voice, speed: rate)).map { ($0, 1) }
        case .apple:
            return nil
        }
    }

    /// Plays one rendered sentence, following its words for the caption.
    private func play(_ samples: [Float], playbackRate: Float, text: String, number: Int) async {
        onSentence?(number, text)
        let seconds = Double(samples.count) / Double(KokoroEngine.sampleRate) / Double(max(playbackRate, 0.5))
        followWords(in: text, over: seconds)
        await player.play(samples, rate: playbackRate)
        wordClock?.invalidate()
        wordClock = nil
    }

    /// Neural voices don't say when each word starts, so the caption moves
    /// through the words by their length, with pauses at punctuation.
    private func followWords(in text: String, over seconds: Double) {
        wordClock?.invalidate()
        let ns = text as NSString
        var words: [(range: NSRange, weight: Double)] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { _, r, enclosing, _ in
            let tail = ns.substring(with: NSRange(location: r.upperBound, length: max(0, enclosing.upperBound - r.upperBound)))
            let pause = tail.contains(where: { ".!?".contains($0) }) ? 4.0 : tail.contains(where: { ",;:".contains($0) }) ? 2.0 : 0
            words.append((r, Double(r.length) + 1.5 + pause))
        }
        guard !words.isEmpty else { return }
        let total = words.reduce(0) { $0 + $1.weight }
        // A little lead-in and tail of silence in the audio.
        let spoken = max(0.2, seconds - 0.25)
        var starts: [Double] = []
        var t = 0.1
        for w in words {
            starts.append(t)
            t += w.weight / total * spoken
        }
        let began = Date()
        var shown = -1
        let clock = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            let now = Date().timeIntervalSince(began)
            let i = (starts.lastIndex { $0 <= now }) ?? -1
            guard i != shown, i >= 0 else { return }
            shown = i
            MainActor.assumeIsolated { self?.onWord?(words[i].range) }
        }
        RunLoop.main.add(clock, forMode: .common)
        wordClock = clock
    }

    /// Speaks `text` with an Apple voice and returns when it's done.
    private func speakApple(_ text: String, language lang: String, number: Int) async {
        let u = AVSpeechUtterance(string: text)
        if let id = voiceID, let chosen = AVSpeechSynthesisVoice(identifier: id), chosen.language.hasPrefix(lang) {
            u.voice = chosen
        } else {
            u.voice = voice(for: lang)
        }
        u.rate = min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * 1.02 * rate)
        u.pitchMultiplier = 1.0
        u.postUtteranceDelay = 0.04
        let id = ObjectIdentifier(u)
        numbers[id] = number
        await withCheckedContinuation { c in
            waiting[id] = c
            synth.speak(u)
        }
    }

    func stop() {
        epoch += 1
        pending = 0
        numbers.removeAll()
        rendering = nil
        playing = nil
        wordClock?.invalidate()
        wordClock = nil
        player.stop()
        synth.stopSpeaking(at: .immediate)
        for c in waiting.values { c.resume() }
        waiting.removeAll()
    }

    /// Two-letter language of `text`, sticking with the last one for short bits.
    func language(of text: String) -> String {
        let r = NLLanguageRecognizer()
        r.processString(text)
        let hyp = r.languageHypotheses(withMaximum: 1).first
        if let (lang, p) = hyp, p > 0.6 || text.count > 40 {
            let code = String(lang.rawValue.prefix(2)) == "nn" || lang.rawValue == "nb" ? "nb" : String(lang.rawValue.prefix(2))
            lastLanguage = code
            return code
        }
        return lastLanguage ?? fallbackLanguage
    }

    private func voice(for lang: String) -> AVSpeechSynthesisVoice? {
        if let v = voiceCache[lang] { return v }
        let v = Self.bestVoice(for: lang)
        voiceCache[lang] = v
        return v
    }

    /// Premium, then enhanced, then the system's own default voice for the
    /// language, never the novelty or "Eloquence" voices. Within a quality,
    /// the user's own region wins.
    static func bestVoice(for lang: String) -> AVSpeechSynthesisVoice? {
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { matches($0, lang) && !isNovelty($0) }
        let regions = Locale.preferredLanguages.filter { $0.hasPrefix(lang) }
        let systemDefault = AVSpeechSynthesisVoice(language: regions.first ?? lang)?.identifier
        func score(_ v: AVSpeechSynthesisVoice) -> Int {
            var s = v.quality.rawValue * 100
            if v.identifier == systemDefault { s += 20 }
            if regions.contains(v.language) { s += 10 }
            if v.language == "en-US" || v.language == "en-GB" { s += 2 }
            return s
        }
        return candidates.max { score($0) < score($1) } ?? AVSpeechSynthesisVoice(language: lang)
    }

    private static func matches(_ v: AVSpeechSynthesisVoice, _ lang: String) -> Bool {
        lang == "nb" ? (v.language.hasPrefix("nb") || v.language.hasPrefix("no")) : v.language.hasPrefix(lang)
    }

    private static func isNovelty(_ v: AVSpeechSynthesisVoice) -> Bool {
        v.voiceTraits.contains(.isNoveltyVoice) || v.identifier.contains("eloquence")
            || (v.identifier.contains("speech.synthesis.voice") && v.quality == .default)
    }

    /// Installed voices for the languages you use, best quality first.
    static func availableVoices() -> [AVSpeechSynthesisVoice] {
        let langs = Set((Locale.preferredLanguages + ["en"]).map { String($0.prefix(2)) })
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { langs.contains(String($0.language.prefix(2))) && !isNovelty($0) }
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
    }

    /// Whether a natural-sounding (enhanced or premium) voice is installed for `lang`.
    static func hasNaturalVoice(for lang: String) -> Bool {
        AVSpeechSynthesisVoice.speechVoices().contains { matches($0, lang) && $0.quality != .default }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        let id = ObjectIdentifier(u), text = u.speechString
        Task { @MainActor in self.onSentence?(self.numbers[id] ?? -1, text) }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange,
                                       utterance u: AVSpeechUtterance) {
        Task { @MainActor in self.onWord?(range) }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        let id = ObjectIdentifier(u)
        Task { @MainActor in self.done(id) }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        let id = ObjectIdentifier(u)
        Task { @MainActor in self.done(id) }
    }

    private func done(_ id: ObjectIdentifier) {
        numbers[id] = nil
        waiting.removeValue(forKey: id)?.resume()
    }

    private func finishedOne() {
        guard pending > 0 else { return }
        pending -= 1
        if pending == 0 { onIdle?() }
    }
}
