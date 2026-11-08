import AppKit
import Foundation

/// Launch arguments for testing parts of the app without a person at the
/// keyboard. Run a second copy with `open -n … --args -CP… ` so the one in
/// use keeps running; the test copy quits when it is done.
@MainActor
enum TestHooks {
    /// Runs a test if the launch arguments ask for one. Returns false when
    /// there was none.
    static func run() async -> Bool {
        let defaults = UserDefaults.standard
        if let steps = defaults.string(forKey: "CPRunActions") {
            await runActions(from: steps, to: defaults.string(forKey: "CPOut") ?? steps + ".out.json")
            return true
        }
        if let question = defaults.string(forKey: "CPAsk") {
            await ask(question, to: defaults.string(forKey: "CPOut") ?? "/dev/stdout")
            return true
        }
        // `-CPShow "question" -CPOut frame.png`: asks for real, with the screen,
        // and saves a screenshot every two seconds while it answers (frame-1.png…),
        // to see drawings, the board and 3D views live. Nothing is spoken.
        if let question = defaults.string(forKey: "CPShow") {
            let model = AppModel.shared
            if !model.hasAPIKey { await model.loadAPIKey() }
            let speak = model.speakReplies
            model.speakReplies = false
            defer { model.speakReplies = speak }
            let out = defaults.string(forKey: "CPOut") ?? "/tmp/cpshow.png"
            Task { await model.ask(question, includeScreen: true) }
            let started = Date()
            var frame = 0, doneAt: Date?
            while Date().timeIntervalSince(started) < 150 {
                try? await Task.sleep(for: .seconds(2))
                frame += 1
                let file = out.replacingOccurrences(of: ".png", with: "-\(frame).png")
                let shot = Process()
                shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                shot.arguments = ["-x", "-m", file]
                try? shot.run()
                shot.waitUntilExit()
                if model.requestFinished, doneAt == nil { doneAt = Date() }
                if let doneAt, Date().timeIntervalSince(doneAt) > 8 { break }
            }
            write(["frames": frame, "reply": model.replyText], to: out.replacingOccurrences(of: ".png", with: ".json"))
            return true
        }
        // `-CPPermissions out.json`: what's allowed, checked without asking.
        if let out = defaults.string(forKey: "CPPermissions") {
            let p = PermissionStatus.current()
            write(["microphone": p.microphone, "speech": p.speech, "screen": p.screen,
                   "accessibility": p.accessibility, "full_disk": p.fullDisk, "contacts": p.contacts,
                   "automation": Dictionary(uniqueKeysWithValues: Setup.scripted.map { ($0, Setup.mayScript($0)) }),
                   "everything": p.everything], to: out)
            return true
        }
        // `-CPLiveTest out.json`: connects the live voice with the saved OpenAI
        // key, sends typed lines instead of speech, and writes what came back
        // (events, transcripts, tool calls, errors). Plays its voice.
        if let out = defaults.string(forKey: "CPLiveTest") {
            await liveTest(to: out)
            return true
        }
        if let out = defaults.string(forKey: "CPCursorTest") {
            await cursorTest(to: out)
            return true
        }
        if let text = defaults.string(forKey: "CPSay") {
            await say(text.components(separatedBy: "|"), to: defaults.string(forKey: "CPOut") ?? "/tmp/cpsay")
            return true
        }
        if let files = defaults.string(forKey: "CPHear") {
            await hear(files.components(separatedBy: "|"), to: defaults.string(forKey: "CPOut") ?? "/dev/stdout")
            return true
        }
        return false
    }

    private static func liveTest(to out: String) async {
        let model = AppModel.shared
        await model.loadAPIKey()
        let live = LiveVoice.shared
        var said: [String] = [], heard: [String] = [], tasks: [String] = [], errors: [String] = []
        var spoke = 0
        live.onEvent = { event in
            switch event {
            case .saying(let t): if said.isEmpty { said.append(t) } else { said[said.count - 1] = t }
            case .heard(let t): heard.append(t)
            case .speakingStarted: spoke += 1; said.append("")
            case .speakingEnded: break
            case .task(let id, let request):
                tasks.append(request)
                live.finishTask(callID: id, output: "The biggest file in Downloads is OpenBot-0.53.0-arm64.dmg, 325 MB.")
            case .error(let m): errors.append(m)
            }
        }
        let started = Date()
        live.sendText("Hi! Say hello back in one short sentence.", key: model.openAIKey)
        try? await Task.sleep(for: .seconds(8))
        live.sendText("What's the biggest file in my Downloads folder?", key: model.openAIKey)
        try? await Task.sleep(for: .seconds(14))
        write(["connected": live.connected, "said": said, "heard": heard, "tasks": tasks, "errors": errors,
               "spoke": spoke, "events": live.log, "seconds": Date().timeIntervalSince(started)], to: out)
        live.disconnect()
    }

    /// `-CPAsk "question"` sends one typed question through the whole agent
    /// (without the screen, and without speaking) and writes what happened:
    /// text, steps, helpers and timings in seconds.
    private static func ask(_ question: String, to out: String) async {
        let model = AppModel.shared
        // Tests run before the app reads its key from the Keychain.
        if !model.hasAPIKey { await model.loadAPIKey() }
        ComputerControl.shared.beginTask()
        model.core.attachJobs()
        var log: [[String: Any]] = []
        let started = Date()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            model.core.send(CoreRequest(text: question, screens: [])) { event in
                var entry: [String: Any] = ["t": (Date().timeIntervalSince(started) * 10).rounded() / 10]
                switch event {
                case .text(let s):
                    if let last = log.last?["text"] as? String {
                        log[log.count - 1]["text"] = last + s
                        return
                    }
                    entry["text"] = s
                case .speak(let s): entry["speak"] = s
                case .tool(let step): entry["tool"] = [step.phase, step.kind, step.summary, step.ok] as [Any]
                case .helper(let e):
                    model.handle(helper: e)
                    entry["helper"] = [e.phase, e.agent, e.name, e.text, e.ok] as [Any]
                case .done(let s): entry["done"] = s
                case .error(let kind, let message): entry["error"] = "\(kind): \(message)"
                case .finished:
                    done.resume()
                    return
                default: return
                }
                log.append(entry)
            }
        }
        // Background tasks it started: follow them to the end (ten minutes at most).
        var seen: [String] = []
        while model.jobs.contains(where: { $0.state == "running" }), Date().timeIntervalSince(started) < 600 {
            for j in model.jobs where !seen.contains("\(j.id)|\(j.state)|\(j.status)") {
                seen.append("\(j.id)|\(j.state)|\(j.status)")
                log.append(["t": (Date().timeIntervalSince(started) * 10).rounded() / 10,
                            "job": [j.id, j.name, j.title, j.state, j.status]])
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        for j in model.jobs {
            log.append(["t": (Date().timeIntervalSince(started) * 10).rounded() / 10,
                        "job": [j.id, j.name, j.title, j.state, j.status]])
        }
        // Let the helpers' cursors finish and fade.
        try? await Task.sleep(for: .seconds(2.5))
        ComputerControl.endAll()
        write(["question": question, "events": log], to: out)
    }

    /// `-CPRunActions steps.json` runs the agent's computer and app actions
    /// in order, e.g. `[{"tool": "apps", "input": {"action": "open", "app":
    /// "Calculator"}}, {"tool": "computer", "name": "left_click", "input":
    /// {"coordinate": [100, 200]}}, {"tool": "wait", "seconds": 1}]`, and
    /// writes what each returned; screenshots are saved next to it.
    private static func runActions(from path: String, to out: String) async {
        guard let data = FileManager.default.contents(atPath: path),
              let steps = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return write(["error": "can't read \(path)"], to: out) }
        let control = ComputerControl.shared
        control.beginTask()
        var results: [[String: Any]] = []
        for (i, step) in steps.enumerated() {
            let input = step["input"] as? [String: Any] ?? [:]
            let started = Date()
            var entry: [String: Any] = ["step": i, "tool": step["tool"] ?? ""]
            switch step["tool"] as? String {
            case "apps":
                let r = await control.appControl(input)
                entry["content"] = r.content
                entry["is_error"] = r.isError
                entry["summary"] = r.summary ?? ""
            case "computer":
                let name = step["name"] as? String ?? input["action"] as? String ?? ""
                entry["name"] = name
                let r = await control.perform(name, input: input)
                entry["content"] = describe(r.content, saving: out + ".step\(i)")
                entry["is_error"] = r.isError
                entry["summary"] = r.summary ?? ""
            case "wait":
                try? await Task.sleep(for: .seconds(step["seconds"] as? Double ?? 1))
            default:
                entry["error"] = "unknown tool"
            }
            entry["ms"] = Int(Date().timeIntervalSince(started) * 1000)
            entry["mouse"] = { let p = CGEvent(source: nil)?.location ?? .zero; return [p.x, p.y] }()
            entry["front"] = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            results.append(entry)
        }
        control.endTask()
        write(["steps": results], to: out)
    }

    /// Text stays as is; image blocks are saved as files and named.
    private static func describe(_ content: Any, saving base: String) -> Any {
        guard let blocks = content as? [[String: Any]] else { return content }
        return blocks.enumerated().map { (j, block) -> Any in
            guard let source = block["source"] as? [String: Any], let b64 = source["data"] as? String,
                  let bytes = Data(base64Encoded: b64)
            else { return block["text"] ?? "?" }
            let ext = (source["media_type"] as? String)?.components(separatedBy: "/").last ?? "img"
            let file = "\(base)-\(j).\(ext)"
            FileManager.default.createFile(atPath: file, contents: bytes)
            return "image saved to \(file)"
        }
    }

    /// `-CPCursorTest out` moves the real pointer a little and back like the
    /// agent does, screenshots it (cursor included) while the buddy stands in
    /// for it and after it hands it back, and writes what it saw to out.json.
    private static func cursorTest(to out: String) async {
        let model = AppModel.shared
        model.overlay.show()
        try? await Task.sleep(for: .milliseconds(600))
        let home = HumanInput.location
        let away = CGPoint(x: home.x + 80, y: home.y + 40)
        shot(around: home, to: out + "-0-before.png")
        CursorTakeover.touch()
        try? await Task.sleep(for: .milliseconds(500))
        shot(around: home, to: out + "-1-taken.png")
        await HumanInput.move(to: away)
        try? await Task.sleep(for: .milliseconds(400))
        let during = CursorTakeover.hidden
        shot(around: away, to: out + "-during.png")
        await HumanInput.move(to: home)
        try? await Task.sleep(for: .milliseconds(300))
        let stillDuring = CursorTakeover.hidden
        try? await Task.sleep(for: .seconds(1.8))
        let after = CursorTakeover.hidden
        shot(around: home, to: out + "-after.png")
        let result: [String: Any] = ["hiddenWhileMoving": during, "hiddenAfterReturn": stillDuring, "hiddenAfterLinger": after]
        let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        FileManager.default.createFile(atPath: out + ".json", contents: data)
    }

    /// A screenshot of the area around `p` (global top-left), cursor included.
    private static func shot(around p: CGPoint, to path: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-C", "-R", "\(Int(p.x) - 60),\(Int(p.y) - 60),160,140", path]
        try? task.run()
        task.waitUntilExit()
    }

    /// Waits for the on-device models when that engine is chosen.
    private static func readyLocal() async {
        guard SpeechEngine.current == .local else { return }
        LocalSpeech.shared.prepare()
        for _ in 0..<1800 {
            let s = LocalSpeech.shared
            if case .ready = s.hearing, case .ready = s.speaking { return }
            if case .failed = s.hearing { return }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// `-CPSay "Hello.|Hei på deg."` renders each line with the chosen
    /// speech engine (`-speechEngine cloud|local|apple`) into `<out>-N.wav`,
    /// without playing it, and writes timings to `<out>.json`.
    private static func say(_ lines: [String], to out: String) async {
        await readyLocal()
        let speaker = Speaker()
        var results: [[String: Any]] = []
        for (i, line) in lines.enumerated() {
            let lang = speaker.language(of: line)
            let started = Date()
            let audio = await Speaker.render(line, language: lang, engine: SpeechEngine.current, rate: 1)
            var r: [String: Any] = ["text": line, "language": lang, "engine": SpeechEngine.current.rawValue,
                                    "ms": Int(Date().timeIntervalSince(started) * 1000)]
            if let audio {
                let path = "\(out)-\(i).wav"
                try? AudioMath.wav(audio.samples, sampleRate: KokoroEngine.sampleRate).write(to: URL(fileURLWithPath: path))
                r["file"] = path
                r["seconds"] = Double(audio.samples.count) / Double(KokoroEngine.sampleRate)
            } else {
                r["fallback"] = "apple"
            }
            results.append(r)
        }
        let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        FileManager.default.createFile(atPath: out + ".json", contents: data)
    }

    /// `-CPHear "a.aiff|b.aiff"` runs each file through speech recognition
    /// for the automatic languages and writes what each language heard.
    private static func hear(_ files: [String], to out: String) async {
        await readyLocal()
        let voice = VoiceInput()
        let locales = await VoiceInput.resolvedLocales(UserDefaults.standard.string(forKey: "listenLocale") ?? "")
        await voice.prepare(locales: locales)
        var results: [[String: Any]] = []
        for file in files {
            let started = Date()
            do {
                let (text, heard) = try await voice.transcribe(file: URL(fileURLWithPath: file), locales: locales)
                results.append([
                    "file": file, "chosen": text, "ms": Int(Date().timeIntervalSince(started) * 1000),
                    "heard": heard.map { ["language": $0.language, "text": $0.text, "confidence": $0.confidence ?? -1] },
                ])
            } catch {
                results.append(["file": file, "error": error.localizedDescription])
            }
        }
        write(["locales": locales.map(\.identifier), "results": results], to: out)
    }

    private static func write(_ obj: [String: Any], to path: String) {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        FileManager.default.createFile(atPath: path, contents: data)
    }
}
