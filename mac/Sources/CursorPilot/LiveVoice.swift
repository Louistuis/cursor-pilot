@preconcurrency import AVFoundation
import Foundation

/// OpenAI's gpt-realtime-2.1 as Cursor Pilot's voice: one live connection
/// that hears you and talks back with very little delay, and that you can
/// cut in on. It doesn't do the work itself: anything that needs the Mac,
/// the screen or real thinking goes to Claude (the model chosen in Settings)
/// through the `cursor_pilot` tool, and the voice says Claude's progress and
/// answer as they come.
///
/// Audio goes both ways through one engine with voice processing on, so the
/// Mac's own voice is taken out of the microphone (echo cancellation).
@MainActor
final class LiveVoice {
    static let shared = LiveVoice()
    /// The full model, or the mini one at about a third of the price.
    static let models = [("gpt-realtime-2.1", "gpt-realtime-2.1 · best"), ("gpt-realtime-2.1-mini", "gpt-realtime-2.1-mini · about a third of the price")]
    static var model: String { UserDefaults.standard.string(forKey: "liveModel") ?? models[0].0 }
    static let voices = ["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"]
    static var voice: String { UserDefaults.standard.string(forKey: "liveVoice") ?? "marin" }

    enum Event {
        /// What you said, written down.
        case heard(String)
        /// What it's saying in this reply so far, and how much of it (UTF-16
        /// characters) has been heard: the caption follows the voice.
        case saying(String, heard: Int)
        /// How loud you are, 0...1, while the mic is open.
        case level(Float)
        case speakingStarted
        case speakingEnded
        /// Something for Claude to do: the request, and the call to answer.
        case task(callID: String, request: String)
        case error(String)
    }

    var onEvent: ((Event) -> Void)?
    /// Listening all the time (the model hears when you start and stop)
    /// instead of only while the talk key is held.
    var handsFree = false

    private(set) var connected = false
    private var socket: URLSessionWebSocketTask?
    private let gate = AudioGate()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    private var audioRunning = false
    private var lastAudioError: String?
    private var steps: [String] = []
    private var configObserver: NSObjectProtocol?

    /// A reply is being generated; further replies wait for it.
    private var responseActive = false
    /// That reply was cut off (you talked over it, or pressed Stop): what
    /// still arrives of it is neither played nor shown.
    private var cutOff = false
    /// Counts presses of the talk key, so the end of one press can't close
    /// the mic on the next.
    private var talkPress = 0
    private var pending: [Pending] = []
    private enum Pending { case line(String), answer(callID: String, output: String) }

    // What's playing, to cut it off at the right place when you talk over it.
    private var playingItem: String?
    private var itemStartSample: AVAudioFramePosition = 0
    private var buffersOut = 0
    private var speaking = false
    /// Each spoken reply's words and how much of its audio is queued and
    /// played, in the order they're heard, for the caption.
    private struct Said { var text = ""; var scheduled = 0; var played = 0 }
    private var said: [String: Said] = [:]
    private var saidOrder: [String] = []
    /// When the last buffer finished (or playback started from silence).
    private var boundary: CFTimeInterval = 0
    private var captionTimer: Timer?

    /// The mic as one channel at its own rate, once audio is running: the
    /// format `micSink` gets.
    private(set) var micFormat: AVAudioFormat?
    /// Gets a copy of the mic while it's open (for the live caption of what
    /// you say); set and cleared on the main thread, read on the audio thread.
    var micSink: (@Sendable (AVAudioPCMBuffer) -> Void)? {
        get { gate.sink }
        set { gate.sink = newValue }
    }

    /// The server already said what went wrong; the closed socket after it
    /// needs no second message.
    private var reportedError = false
    /// For diagnostics: the mic's format and how much audio came and went.
    func diagnostics() -> [String: Any] {
        let f = engine.inputNode.outputFormat(forBus: 0)
        var d = gate.stats
        d["inputRate"] = f.sampleRate
        d["inputChannels"] = f.channelCount
        d["inputCommon"] = f.commonFormat.rawValue
        d["voiceProcessing"] = engine.inputNode.isVoiceProcessingEnabled
        d["audioRunning"] = audioRunning
        d["engineRunning"] = engine.isRunning
        d["error"] = lastAudioError ?? ""
        d["steps"] = steps
        return d
    }

    /// For diagnostics: holds the talk key for `seconds` without a connection.
    func micCheck(seconds: Double) async -> [String: Any] {
        // After the app's own start-up (which closes the live voice until the key is read).
        try? await Task.sleep(for: .seconds(2))
        startAudio()
        gate.open = true
        try? await Task.sleep(for: .seconds(seconds))
        gate.open = false
        return diagnostics()
    }

    /// For tests: every event type that came in, in order.
    private(set) var log: [String] = []

    // MARK: Connection

    func connect(key: String) {
        guard socket == nil, !key.isEmpty else { return }
        var request = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?model=\(Self.model)")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        reportedError = false
        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 16 << 20
        socket = task
        gate.task = task
        task.resume()
        receive(on: task)
    }

    /// Closes the connection (a new voice or setting takes effect on the next one).
    func disconnect() {
        steps.append("disconnect")
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        gate.task = nil
        gate.open = false
        connected = false
        responseActive = false
        cutOff = false
        pending = []
        stopPlayback(truncate: false)
        stopAudio()
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.socket === task else { return }
                switch result {
                case .success(.string(let text)):
                    self.handle(text)
                    self.receive(on: task)
                case .success(.data(let data)):
                    self.handle(String(decoding: data, as: UTF8.self))
                    self.receive(on: task)
                case .success:
                    self.receive(on: task)
                case .failure(let error):
                    NSLog("Cursor Pilot: live voice closed: \(error.localizedDescription)")
                    let wasConnected = self.connected
                    self.disconnect()
                    if !wasConnected, !self.reportedError { self.onEvent?(.error("Couldn't reach OpenAI's live voice: \(error.localizedDescription)")) }
                }
            }
        }
    }

    private func send(_ object: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        socket.send(.string(String(decoding: data, as: UTF8.self))) { error in
            if let error { NSLog("Cursor Pilot: live voice send failed: \(error.localizedDescription)") }
        }
    }

    private func configure() {
        let turn: Any = handsFree
            ? ["type": "semantic_vad", "eagerness": "auto", "create_response": true, "interrupt_response": true] as [String: Any]
            : NSNull()
        send([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "output_modalities": ["audio"],
                "instructions": Self.instructions,
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        // Writes down each committed turn (what you said, for the caption and the chat).
                        "transcription": ["model": "gpt-transcribe"],
                        "turn_detection": turn,
                    ],
                    "output": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "voice": Self.voice,
                    ],
                ],
                "tools": [Self.tool],
                "tool_choice": "auto",
            ] as [String: Any],
        ])
        // OpenAI's advice for long sessions and voice agents, sent on their
        // own so a setting this model doesn't take can't undo the one above:
        // drop the oldest fifth of the conversation when it fills up (cheaper,
        // and the cache stays useful), and think briefly (it only talks).
        send(["type": "session.update", "event_id": "optional_truncation", "session": [
            "type": "realtime",
            "truncation": ["type": "retention_ratio", "retention_ratio": NSDecimalNumber(string: "0.8"),
                           "token_limits": ["post_instructions": 8000]] as [String: Any],
        ] as [String: Any]])
        send(["type": "session.update", "event_id": "optional_reasoning",
              "session": ["type": "realtime", "reasoning": ["effort": "low"]] as [String: Any]])
    }

    /// Laid out the way OpenAI's voice prompting guide suggests: short
    /// sections, bullets, one rule per behaviour.
    private static let instructions = """
    # Role and Objective
    - You are the voice of Cursor Pilot, an assistant that lives on the user's Mac.
    - You talk with the user; a separate agent sees their screen and does the work, through the cursor_pilot tool.

    # Personality and Tone
    - Warm, quick and natural, like a capable friend sitting next to them. Never stiff or formal.

    # Language
    - English is the default response language.
    - Switch to Norwegian (Bokmål) when the user says something substantive in Norwegian, and stay in it until they switch back. An accent alone doesn't change the language.

    # Verbosity
    - Direct answers and small talk: one or two short sentences.
    - Results from cursor_pilot: one or two sentences with what matters, never long lists, file paths or links.

    # Preambles
    - Before calling cursor_pilot, say one short acknowledgement, such as "Sure." or "Klart." Vary it. Don't say what you'll do: the agent will.
    - No preamble for a confirmation or for unclear audio.

    # Tools
    - Call cursor_pilot for anything beyond small talk: anything about what's on the screen, anything to do, open, find, write, send, check or look up, and any fact you aren't sure of.
    - Pass the user's request in full, in their words and language, with anything from the conversation it needs.
    - Only say something is done after cursor_pilot's result says so. If it failed, say so plainly.
    - Don't call cursor_pilot again with the same request after it failed, unless the user asks.

    # Progress updates
    - While cursor_pilot works, its progress arrives as system messages and you'll be asked to say each one. Say just that line, naturally, in the user's language, adding nothing.
    - The user can talk to you any time while it works. Answer questions about how it's going from the progress so far. Anything that adds to or changes the task, or asks it to stop, goes to cursor_pilot too: it's passed to the agent at work.

    # Unclear Audio
    - Only respond to clear audio or text. If you didn't catch it, ask briefly, and don't ask the same way twice.

    # Variety
    - Don't repeat the same opener or phrase in a row. Sample phrases are examples, not a script.

    """

    private static let tool: [String: Any] = [
        "type": "function",
        "name": "cursor_pilot",
        "description": "Hand a request to Cursor Pilot's agent, which sees the user's screen and can work on their "
            + "Mac: apps, files, the web, messages. Returns what it did or found.",
        "parameters": [
            "type": "object",
            "properties": [
                "request": ["type": "string", "description": "The user's request in full, in their words and language."],
            ],
            "required": ["request"],
        ] as [String: Any],
    ]

    // MARK: Talking

    /// The talk key went down: you can talk, and talk over it.
    func pressTalk(key: String) {
        talkPress += 1
        connect(key: key)
        startAudio()
        if speaking || responseActive { cutIn() }
        send(["type": "input_audio_buffer.clear"])
        gate.open = true
    }

    /// The talk key came up: what you said is sent and it answers.
    func releaseTalk() {
        guard gate.open, !handsFree else { return }
        let press = talkPress
        // A moment for the last words to arrive.
        Task {
            try? await Task.sleep(for: .milliseconds(160))
            // The key is down again (or the press was called off): that one
            // decides what happens to the mic now.
            guard press == talkPress else { return }
            gate.open = false
            send(["type": "input_audio_buffer.commit"])
            send(["type": "response.create"])
        }
    }

    /// The talk key turned out to be part of another shortcut: the mic
    /// closes and nothing is sent.
    func cancelTalk() {
        talkPress += 1
        guard gate.open, !handsFree else { return }
        gate.open = false
        send(["type": "input_audio_buffer.clear"])
    }

    /// Stops what it's saying now, and the reply it's working on (Stop).
    func hush() {
        if speaking || responseActive { cutIn() }
    }

    /// Hands-free: the mic stays on and the model hears when you talk.
    func startHandsFree(key: String) {
        handsFree = true
        connect(key: key)
        startAudio()
        gate.open = true
    }

    /// A typed message instead of speech (and for tests).
    func sendText(_ text: String, key: String) {
        connect(key: key)
        startAudio()
        send(["type": "conversation.item.create",
              "item": ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]])
        request(.line(""))
    }

    /// Says one of Claude's progress lines.
    func say(_ line: String) {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        request(.line(line))
    }

    /// Claude is done: its answer goes back to the voice, which tells you.
    func finishTask(callID: String, output: String) {
        request(.answer(callID: callID, output: output))
    }

    private func request(_ p: Pending) {
        guard !responseActive, connected else {
            pending.append(p)
            return
        }
        start(p)
    }

    private func start(_ p: Pending) {
        responseActive = true
        switch p {
        case .line(""):
            send(["type": "response.create"])
        case .line(let line):
            // Part of the conversation, so the voice knows how the work is
            // going when you ask, and says it.
            send(["type": "conversation.item.create",
                  "item": ["type": "message", "role": "system",
                           "content": [["type": "input_text", "text": "Progress from the agent: \(line)"]]] as [String: Any]])
            send(["type": "response.create",
                  "response": ["output_modalities": ["audio"],
                               "instructions": "Say the agent's latest progress line to the user, briefly and naturally, in "
                                   + "the language you're speaking with them, adding nothing."] as [String: Any]])
        case .answer(let callID, let output):
            send(["type": "conversation.item.create",
                  "item": ["type": "function_call_output", "call_id": callID, "output": output]])
            send(["type": "response.create"])
        }
    }

    /// You talked over it: stop the voice where you cut in.
    private func cutIn() {
        if responseActive {
            send(["type": "response.cancel"])
            cutOff = true
        }
        stopPlayback(truncate: true)
    }

    // MARK: Events

    private func handle(_ text: String) {
        guard let event = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = event["type"] as? String else { return }
        if log.count < 400 { log.append(type) }
        switch type {
        case "session.created":
            connected = true
            configure()
            if let first = pending.first, !responseActive {
                pending.removeFirst()
                start(first)
            }
        case "response.created":
            responseActive = true
            cutOff = false
        case "response.output_audio.delta":
            guard !cutOff, let b64 = event["delta"] as? String, let data = Data(base64Encoded: b64) else { return }
            play(data, item: event["item_id"] as? String)
        case "response.output_audio_transcript.delta":
            guard !cutOff, let id = event["item_id"] as? String else { return }
            if said[id] == nil { saidOrder.append(id) }
            said[id, default: Said()].text += event["delta"] as? String ?? ""
        case "conversation.item.input_audio_transcription.completed":
            if let heard = event["transcript"] as? String, !heard.isEmpty { onEvent?(.heard(heard)) }
        case "input_audio_buffer.speech_started":
            if handsFree {
                // The server drops the reply it was giving (interrupt_response);
                // the rest of its audio, already on the way, isn't played.
                if responseActive { cutOff = true }
                stopPlayback(truncate: true)
            }
        case "response.done":
            responseActive = false
            let response = event["response"] as? [String: Any]
            for item in response?["output"] as? [[String: Any]] ?? [] where item["type"] as? String == "function_call" {
                guard item["name"] as? String == "cursor_pilot", let callID = item["call_id"] as? String else { continue }
                let args = (item["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                let request = args?["request"] as? String ?? ""
                onEvent?(.task(callID: callID, request: request))
            }
            if buffersOut == 0, speaking { endSpeaking() }
            if !pending.isEmpty { start(pending.removeFirst()) }
        case "error":
            let error = event["error"] as? [String: Any]
            let code = error?["code"] as? String ?? ""
            let message = error?["message"] as? String ?? "Live voice error"
            NSLog("Cursor Pilot: live voice error \(code): \(message)")
            log.append("error \(error?["event_id"] as? String ?? "-") \(code): \(message)")
            // One of the optional settings isn't taken by this model: fine.
            if (error?["event_id"] as? String)?.hasPrefix("optional_") == true { return }
            // Expected now and then: an empty commit (a tap of the key), a cancel with nothing to cancel.
            if ["input_audio_buffer_commit_empty", "response_cancel_not_active"].contains(code) {
                if code == "input_audio_buffer_commit_empty" { responseActive = false }
                return
            }
            reportedError = true
            if code == "insufficient_quota" {
                onEvent?(.error("Your OpenAI account is out of credits: add some at platform.openai.com › Billing."))
            } else {
                onEvent?(.error(message))
            }
        default:
            break
        }
    }

    // MARK: Audio

    private func startAudio() {
        guard !audioRunning else { return }
        steps.append("start")
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        } catch {
            NSLog("Cursor Pilot: live voice without echo cancellation: \(error.localizedDescription)")
        }
        steps.append("vp")
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outFormat)
        steps.append("player")
        // With voice processing on, the mic can come as several channels
        // (seven on a MacBook), the processed voice in the first: that one
        // is taken as mono, then converted to what OpenAI takes.
        let input = engine.inputNode.outputFormat(forBus: 0)
        guard input.sampleRate > 0, input.channelCount > 0,
              let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: input.sampleRate, channels: 1, interleaved: false),
              let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: mono, to: wire) else {
            lastAudioError = "no converter for \(input)"
            onEvent?(.error("No microphone for the live voice."))
            return
        }
        steps.append("converter")
        micFormat = mono
        let gate = gate
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: input) { buffer, _ in
            gate.noteBuffer(buffer)
            guard gate.open, let src = buffer.floatChannelData?[0],
                  let first = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength) else { return }
            first.frameLength = buffer.frameLength
            first.floatChannelData![0].update(from: src, count: Int(buffer.frameLength))
            gate.sink?(first)
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += src[i] * src[i] }
            let rms = (sum / Float(max(buffer.frameLength, 1))).squareRoot()
            // About -50 dB to -10 dB, as 0...1 (like the other engines' level).
            let level = min(max((20 * log10(max(rms, 1e-6)) + 50) / 40, 0), 1)
            Task { @MainActor [weak self] in self?.onEvent?(.level(level)) }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 24_000 / input.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: wire, frameCapacity: capacity) else { return }
            var fed = false
            converter.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return first
            }
            guard out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return }
            let data = Data(bytes: samples, count: Int(out.frameLength) * 2)
            gate.sendAudio(data.base64EncodedString())
        }
        steps.append("tap")
        do {
            engine.prepare()
            try engine.start()
            steps.append("started")
            player.play()
            audioRunning = true
            watchConfiguration()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            lastAudioError = "start: \(error)"
            onEvent?(.error("Couldn't start the live voice's audio: \(error.localizedDescription)"))
        }
    }

    /// macOS reconfigures the audio device now and then (turning on echo
    /// cancellation does it, so do headphones): the engine stops, and is
    /// started again here so the mic keeps going.
    private func watchConfiguration() {
        guard configObserver == nil else { return }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.audioRunning, !self.engine.isRunning else { return }
                self.steps.append("reconfigured")
                do {
                    try self.engine.start()
                    self.player.play()
                } catch {
                    self.lastAudioError = "restart: \(error)"
                }
            }
        }
    }

    private func stopAudio() {
        guard audioRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioRunning = false
    }

    private func play(_ pcm: Data, item: String?) {
        let count = pcm.count / 2
        guard count > 0, audioRunning, let buffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(count)) else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        let dst = buffer.floatChannelData![0]
        pcm.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<count { dst[i] = Float(Int16(littleEndian: src[i])) / 32768 }
        }
        if let item, item != playingItem {
            playingItem = item
            itemStartSample = playedSample() ?? 0
        }
        if !speaking {
            speaking = true
            onEvent?(.speakingStarted)
            startCaption()
        }
        // Nothing was playing: the voice (re)starts now.
        if buffersOut == 0 { boundary = CACurrentMediaTime() }
        let id = item ?? ""
        if said[id] == nil { saidOrder.append(id) }
        said[id, default: Said()].scheduled += count
        buffersOut += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.said[id] != nil {
                    self.said[id]!.played += count
                    self.boundary = CACurrentMediaTime()
                }
                self.buffersOut = max(0, self.buffersOut - 1)
                if self.buffersOut == 0, !self.responseActive, self.speaking { self.endSpeaking() }
            }
        }
        if !player.isPlaying { player.play() }
    }

    private func playedSample() -> AVAudioFramePosition? {
        guard let node = player.lastRenderTime, let time = player.playerTime(forNodeTime: node) else { return nil }
        return time.sampleTime
    }

    /// Stops the voice now; with `truncate`, the model is told how much of
    /// its reply you actually heard.
    private func stopPlayback(truncate: Bool) {
        if truncate, let item = playingItem, speaking {
            let played = max(0, (playedSample() ?? itemStartSample) - itemStartSample)
            send(["type": "conversation.item.truncate", "item_id": item, "content_index": 0,
                  "audio_end_ms": Int(Double(played) / 24)])
        }
        player.stop()
        buffersOut = 0
        playingItem = nil
        said = [:]
        saidOrder = []
        if audioRunning { player.play() }
        if speaking { endSpeaking() }
    }

    private func endSpeaking() {
        speaking = false
        captionTimer?.invalidate()
        captionTimer = nil
        if let last = saidOrder.last(where: { !(said[$0]?.text.isEmpty ?? true) }), let text = said[last]?.text {
            onEvent?(.saying(text, heard: (text as NSString).length))
        }
        // Words of a reply whose audio is still to come stay for it.
        for id in saidOrder where (said[id]?.scheduled ?? 0) > 0 { said[id] = nil }
        saidOrder.removeAll { said[$0] == nil }
        onEvent?(.speakingEnded)
    }

    /// The caption keeps pace with the voice: the share of the reply's
    /// audio played so far, applied to its words.
    private func startCaption() {
        captionTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickCaption() }
        }
        RunLoop.main.add(t, forMode: .common)
        captionTimer = t
    }

    private func tickCaption() {
        // The reply being heard: the first with audio not yet played.
        guard speaking, let id = saidOrder.first(where: { (said[$0]?.played ?? 0) < (said[$0]?.scheduled ?? 0) }),
              let now = said[id], !now.text.isEmpty else { return }
        var played = now.played
        if buffersOut > 0 { played += Int((CACurrentMediaTime() - boundary) * 24_000) }
        let share = min(Double(played) / Double(now.scheduled), 1)
        let length = (now.text as NSString).length
        onEvent?(.saying(now.text, heard: Int((Double(length) * share).rounded())))
    }
}

/// Whether the mic's audio goes out, and where; read on the audio thread.
private final class AudioGate: @unchecked Sendable {
    private let lock = NSLock()
    private var _open = false
    /// For diagnostics: mic buffers seen, chunks sent, loudest sample.
    var buffersIn = 0, chunksSent = 0, peak: Float = 0
    private var _task: URLSessionWebSocketTask?
    private var _sink: (@Sendable (AVAudioPCMBuffer) -> Void)?

    var sink: (@Sendable (AVAudioPCMBuffer) -> Void)? {
        get { lock.withLock { _sink } }
        set { lock.withLock { _sink = newValue } }
    }

    var open: Bool {
        get { lock.withLock { _open } }
        set { lock.withLock { _open = newValue } }
    }

    func noteBuffer(_ buffer: AVAudioPCMBuffer) {
        var loud: Float = 0
        if let d = buffer.floatChannelData?[0] {
            for i in 0..<Int(buffer.frameLength) { loud = max(loud, abs(d[i])) }
        }
        lock.withLock {
            buffersIn += 1
            peak = max(peak, loud)
        }
    }

    var stats: [String: Any] { lock.withLock { ["buffersIn": buffersIn, "chunksSent": chunksSent, "peak": peak] } }

    var task: URLSessionWebSocketTask? {
        get { lock.withLock { _task } }
        set { lock.withLock { _task = newValue } }
    }

    func sendAudio(_ base64: String) {
        lock.withLock { chunksSent += 1 }
        guard let task else { return }
        task.send(.string("{\"type\":\"input_audio_buffer.append\",\"audio\":\"\(base64)\"}")) { _ in }
    }
}
