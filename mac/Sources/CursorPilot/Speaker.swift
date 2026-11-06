import AVFoundation
import NaturalLanguage

/// Reads reply sentences aloud as they stream in, each in a voice that
/// speaks the sentence's language.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var pending = 0
    var onIdle: (() -> Void)?
    /// A specific voice; nil picks the best installed one per language.
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

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String, number: Int = -1) {
        let lang = language(of: text)
        let u = AVSpeechUtterance(string: text)
        if let id = voiceID, let chosen = AVSpeechSynthesisVoice(identifier: id), chosen.language.hasPrefix(lang) {
            u.voice = chosen
        } else {
            u.voice = voice(for: lang)
        }
        u.rate = min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * 1.02 * rate)
        u.pitchMultiplier = 1.0
        u.postUtteranceDelay = 0.04
        pending += 1
        numbers[ObjectIdentifier(u)] = number
        synth.speak(u)
    }

    func stop() {
        pending = 0
        numbers.removeAll()
        synth.stopSpeaking(at: .immediate)
    }

    /// Two-letter language of `text`, sticking with the last one for short bits.
    private func language(of text: String) -> String {
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
        Task { @MainActor in self.numbers[id] = nil }
        Task { @MainActor in self.finishedOne() }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.finishedOne() }
    }

    private func finishedOne() {
        guard pending > 0 else { return }
        pending -= 1
        if pending == 0 { onIdle?() }
    }
}
