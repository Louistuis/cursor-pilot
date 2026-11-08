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
    static let model = "gpt-realtime-2.1"
    static let voices = ["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"]
    static var voice: String { UserDefaults.standard.string(forKey: "liveVoice") ?? "marin" }

    enum Event {
        /// What you said, written down.
        case heard(String)
        /// What it's saying so far in this reply.
        case saying(String)
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

    /// A reply is being generated; further replies wait for it.
    private var responseActive = false
    private var pending: [Pending] = []
    private enum Pending { case line(String), answer(callID: String, output: String) }

    // What's playing, to cut it off at the right place when you talk over it.
    private var playingItem: String?
    private var itemStartSample: AVAudioFramePosition = 0
    private var buffersOut = 0
    private var transcript = ""
    private var speaking = false

    /// The server already said what went wrong; the closed socket after it
    /// needs no second message.
    private var reportedError = false
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
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        gate.task = nil
        gate.open = false
        connected = false
        responseActive = false
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
                        "transcription": ["model": "gpt-4o-transcribe"],
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
    }

    private static let instructions = """
    You are the voice of Cursor Pilot, an assistant that lives on the user's Mac. Talk with the user the way a \
    quick, warm person would, in the language they speak (Norwegian or English), in short spoken sentences.
    You can't see the screen or do anything on the Mac yourself. A capable agent does that for you through the \
    cursor_pilot tool. For anything beyond small talk (questions about what's on screen, anything to do, find, \
    open, write, send or look up, and facts you aren't sure of), call cursor_pilot right away with the user's \
    request in full, in their words and language, plus anything from the conversation it needs. As you call it, \
    say a very short acknowledgement ("Sure, one sec." or "Klart, et øyeblikk.").
    While it works you may be asked to say a progress line: say just that, briefly and naturally.
    When its result comes back, tell the user in a sentence or two in your own voice, keeping names and numbers \
    exact. Don't read out long lists, file paths or links. If the user interrupts, stop and listen.
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
        connect(key: key)
        startAudio()
        if speaking || responseActive { cutIn() }
        send(["type": "input_audio_buffer.clear"])
        gate.open = true
    }

    /// The talk key came up: what you said is sent and it answers.
    func releaseTalk() {
        guard gate.open, !handsFree else { return }
        // A moment for the last words to arrive.
        Task {
            try? await Task.sleep(for: .milliseconds(160))
            gate.open = false
            send(["type": "input_audio_buffer.commit"])
            send(["type": "response.create"])
        }
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
            // Said without becoming part of the conversation.
            send(["type": "response.create",
                  "response": ["conversation": "none", "output_modalities": ["audio"],
                               "instructions": "Say this progress update to the user, briefly and naturally, in the "
                                   + "language you're speaking with them, adding nothing: \(line)"] as [String: Any]])
        case .answer(let callID, let output):
            send(["type": "conversation.item.create",
                  "item": ["type": "function_call_output", "call_id": callID, "output": output]])
            send(["type": "response.create"])
        }
    }

    /// You talked over it: stop the voice where you cut in.
    private func cutIn() {
        if responseActive { send(["type": "response.cancel"]) }
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
            transcript = ""
        case "response.output_audio.delta":
            guard let b64 = event["delta"] as? String, let data = Data(base64Encoded: b64) else { return }
            play(data, item: event["item_id"] as? String)
        case "response.output_audio_transcript.delta":
            transcript += event["delta"] as? String ?? ""
            onEvent?(.saying(transcript))
        case "conversation.item.input_audio_transcription.completed":
            if let heard = event["transcript"] as? String, !heard.isEmpty { onEvent?(.heard(heard)) }
        case "input_audio_buffer.speech_started":
            if handsFree { stopPlayback(truncate: true) }
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
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        } catch {
            NSLog("Cursor Pilot: live voice without echo cancellation: \(error.localizedDescription)")
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outFormat)
        let input = engine.inputNode.outputFormat(forBus: 0)
        guard input.sampleRate > 0, input.channelCount > 0,
              let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: input, to: wire) else {
            onEvent?(.error("No microphone for the live voice."))
            return
        }
        let gate = gate
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: input) { buffer, _ in
            guard gate.open else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 24_000 / input.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: wire, frameCapacity: capacity) else { return }
            var fed = false
            converter.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return }
            let data = Data(bytes: samples, count: Int(out.frameLength) * 2)
            gate.sendAudio(data.base64EncodedString())
        }
        do {
            engine.prepare()
            try engine.start()
            player.play()
            audioRunning = true
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            onEvent?(.error("Couldn't start the live voice's audio: \(error.localizedDescription)"))
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
        }
        buffersOut += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
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
        if audioRunning { player.play() }
        if speaking { endSpeaking() }
    }

    private func endSpeaking() {
        speaking = false
        onEvent?(.speakingEnded)
    }
}

/// Whether the mic's audio goes out, and where; read on the audio thread.
private final class AudioGate: @unchecked Sendable {
    private let lock = NSLock()
    private var _open = false
    private var _task: URLSessionWebSocketTask?

    var open: Bool {
        get { lock.withLock { _open } }
        set { lock.withLock { _open = newValue } }
    }

    var task: URLSessionWebSocketTask? {
        get { lock.withLock { _task } }
        set { lock.withLock { _task = newValue } }
    }

    func sendAudio(_ base64: String) {
        guard let task else { return }
        task.send(.string("{\"type\":\"input_audio_buffer.append\",\"audio\":\"\(base64)\"}")) { _ in }
    }
}
