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
        if let files = defaults.string(forKey: "CPHear") {
            await hear(files.components(separatedBy: "|"), to: defaults.string(forKey: "CPOut") ?? "/dev/stdout")
            return true
        }
        return false
    }

    /// `-CPAsk "question"` sends one typed question through the whole agent
    /// (without the screen, and without speaking) and writes what happened:
    /// text, steps, helpers and timings in seconds.
    private static func ask(_ question: String, to out: String) async {
        let model = AppModel.shared
        // Tests run before the app reads its key from the Keychain.
        if !model.hasAPIKey { await model.loadAPIKey() }
        ComputerControl.shared.beginTask()
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

    /// `-CPHear "a.aiff|b.aiff"` runs each file through speech recognition
    /// for the automatic languages and writes what each language heard.
    private static func hear(_ files: [String], to out: String) async {
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
