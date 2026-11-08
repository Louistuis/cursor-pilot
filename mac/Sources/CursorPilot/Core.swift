import CCursorPilotCore
import Foundation

/// Settings handed to the Rust core. Field names match `claude::Settings`.
struct CoreSettings: Encodable {
    var apiKey: String
    /// Where the Messages API is: Anthropic's, or another host that speaks it.
    var baseURL: String
    var model: String
    var effort: String
    /// Mac access: "off" or "on".
    var access: String
    /// How it works on the Mac: "person" or "background".
    var input: String

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case baseURL = "base_url"
        case model, effort, access, input
    }
}

/// One captured display, in the shape `engine::ScreenShot` expects.
struct ScreenShotPayload: Encodable {
    struct Frame: Encodable { var x, y, w, h: Double }
    var label: String
    var hasCursor: Bool
    var frame: Frame
    var imageW: Double
    var imageH: Double
    var jpegB64: String

    enum CodingKeys: String, CodingKey {
        case label, frame
        case hasCursor = "has_cursor"
        case imageW = "image_w"
        case imageH = "image_h"
        case jpegB64 = "jpeg_b64"
    }
}

struct CoreRequest: Encodable {
    var text: String
    var screens: [ScreenShotPayload]
    /// The user drew on the screen before asking.
    var sketch = false
}

struct DrawingRecord: Decodable, Identifiable, Hashable {
    var id: String
    var title: String
    var createdAt: Int
    var path: String

    enum CodingKeys: String, CodingKey {
        case id, title, path
        case createdAt = "created_at"
    }
}

enum CoreEvent {
    case started(conversationID: String)
    case text(String)
    case speak(String)
    /// Global coordinates with a top-left origin on the primary display.
    case point(x: Double, y: Double, label: String)
    /// A circle, arrow or box to draw, in the same coordinates.
    case mark(InkShape, label: String)
    /// Something for the whiteboard, in its own units (1000 × 600), and the
    /// event as it came, to keep the board and open it again later.
    case board(BoardItem, raw: String)
    /// Turn the 3D view to one of its parts.
    case focus(String)
    /// An agent step: "start" or "end".
    case tool(AgentStep)
    /// A helper agent started, did a step, left a note or finished.
    case helper(HelperEvent)
    case done(text: String)
    case error(kind: String, message: String)
    case finished
}

struct HelperEvent {
    /// "start", "step", "note" or "end".
    var phase: String
    /// 1 for the first helper; each has its own pointer.
    var agent: Int
    /// The `delegate` call that sent it, which is its step in the chat.
    var callID: String
    /// "Mint", "Sunset"…: also the colour of its cursor.
    var name: String
    var text: String
    var ok: Bool
}

/// What a background task reports (the core's `job` events), outside any request.
struct JobEvent {
    /// "start", "step", "note" or "end".
    var phase: String
    /// Its agent number, from 100; its pointer and workspace go by it.
    var job: Int
    var name: String
    /// Its title at the start, its latest step, or its report at the end.
    var text: String
    /// At the end: "done", "failed" or "stopped".
    var state: String
}

struct AgentStep: Identifiable, Equatable {
    let id = UUID()
    /// The tool call this step belongs to, so its end replaces its start.
    var callID = ""
    var phase: String
    /// "shell", "file", "computer", "app" or "web".
    var kind: String
    var summary: String
    var ok: Bool

    static func icon(for kind: String) -> String {
        switch kind {
        case "shell": "terminal"
        case "file": "doc.text"
        case "computer": "cursorarrow.click.2"
        case "app": "macwindow"
        case "memory": "brain"
        case "messages": "message"
        case "web": "globe"
        case "agent": "person.2"
        default: "sparkles"
        }
    }

    /// The icon for a saved step, from its wording.
    static func icon(forSummary s: String) -> String {
        if s.hasPrefix("Texted") || s.hasPrefix("Read messages") || s.hasSuffix("your messages") { return "message" }
        if helperNames.contains(where: { s.hasPrefix($0 + ":") }) || s.hasPrefix("Started in the background")
            || s.hasPrefix("Stopped a background") || s.hasPrefix("Checked the background") { return "person.2" }
        let app = ["Pressed", "Chose", "Opened", "Looked", "Filled", "Brought", "Checked", "Focused", "Selected",
                   "Used", "Read text"]
        if app.contains(where: s.hasPrefix) { return "macwindow" }
        if s.hasPrefix("Ran") || s.hasPrefix("Restarted") { return "terminal" }
        if s.hasPrefix("Read") || s.hasPrefix("Wrote") || s.hasPrefix("Edited") { return "doc.text" }
        if s.hasPrefix("Searched") { return "globe" }
        if s.hasPrefix("Remembered") || s.hasPrefix("Forgot") { return "brain" }
        return "cursorarrow.click.2"
    }
}

/// Something Claude remembers about the user between chats.
struct MemoryFact: Decodable, Identifiable, Hashable {
    var id: String
    var text: String
    var date: String
}

struct ConversationSummary: Decodable, Identifiable, Hashable {
    var id: String
    var title: String
    var updatedAt: Int
    var turnCount: Int

    enum CodingKeys: String, CodingKey {
        case id, title
        case updatedAt = "updated_at"
        case turnCount = "turn_count"
    }
}

struct TranscriptTurn: Decodable, Hashable {
    var role: String
    var text: String
    var at: Int
    var screens: Int
    var points: [String]
    var steps: [String]?
}

struct Transcript: Decodable {
    var id: String
    var title: String
    var turns: [TranscriptTurn]
}

/// Swift face of the Rust core (core/src/lib.rs).
final class Core: @unchecked Sendable {
    private let handle: OpaquePointer

    init?(dataDirectory: URL) {
        let config = ["data_dir": dataDirectory.path]
        guard let json = try? JSONSerialization.data(withJSONObject: config),
              let h = String(decoding: json, as: UTF8.self).withCString({ cp_core_new($0) })
        else { return nil }
        handle = h
    }

    deinit { cp_core_free(handle) }

    static var version: String { String(cString: cp_core_version()) }

    func configure(_ settings: CoreSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        _ = String(decoding: data, as: UTF8.self).withCString { cp_core_configure(handle, $0) }
    }

    /// Starts a request. `onEvent` is called on the main queue; `.finished`
    /// is always the last event.
    @discardableResult
    func send(_ request: CoreRequest, onEvent: @escaping @MainActor (CoreEvent) -> Void) -> UInt64 {
        let box = Unmanaged.passRetained(EventBox(onEvent)).toOpaque()
        let json = (try? JSONEncoder().encode(request)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return json.withCString { cp_core_send(handle, $0, coreEventCallback, box) }
    }

    func cancel(_ id: UInt64 = 0) { cp_core_cancel(handle, id) }

    /// Lets the agent use the screen, mouse and keyboard.
    func attachAgentHost() { cp_core_set_host(handle, coreHostCallback, nil) }

    /// Background tasks' progress and reports go to `AppModel.handle(job:)`.
    func attachJobs() { cp_core_set_job_callback(handle, coreJobCallback, nil) }

    func stopJob(_ job: Int) { _ = cp_core_stop_job(handle, UInt64(job)) }

    func newConversation() { cp_core_new_conversation(handle) }

    var currentConversationID: String {
        (try? JSONDecoder().decode(String.self, from: take(cp_core_current_conversation(handle)))) ?? ""
    }

    func conversations() -> [ConversationSummary] {
        (try? JSONDecoder().decode([ConversationSummary].self, from: take(cp_core_list_conversations(handle)))) ?? []
    }

    func transcript(id: String) -> Transcript? {
        let data = id.withCString { take(cp_core_load_conversation(handle, $0)) }
        return try? JSONDecoder().decode(Transcript?.self, from: data)
    }

    func deleteConversation(id: String) {
        id.withCString { cp_core_delete_conversation(handle, $0) }
    }

    /// Makes a saved conversation the live one, so the next question continues it.
    @discardableResult
    func resumeConversation(id: String) -> Bool {
        id.withCString { cp_core_resume_conversation(handle, $0) }
    }

    func renameConversation(id: String, title: String) {
        id.withCString { i in title.withCString { cp_core_rename_conversation(handle, i, $0) } }
    }

    func saveDrawing(png: Data, title: String) -> DrawingRecord? {
        let data = png.withUnsafeBytes { buf in
            title.withCString { t in
                take(cp_core_save_drawing(handle, buf.bindMemory(to: UInt8.self).baseAddress, buf.count, t))
            }
        }
        return try? JSONDecoder().decode(DrawingRecord?.self, from: data)
    }

    func drawings() -> [DrawingRecord] {
        (try? JSONDecoder().decode([DrawingRecord].self, from: take(cp_core_list_drawings(handle)))) ?? []
    }

    func deleteDrawing(id: String) {
        id.withCString { cp_core_delete_drawing(handle, $0) }
    }

    /// Opens the connection to Claude ahead of a question.
    func warm() { cp_core_warm(handle) }

    /// What Claude remembers about the user, oldest first.
    func memory() -> [MemoryFact] {
        (try? JSONDecoder().decode([MemoryFact].self, from: take(cp_core_list_memory(handle)))) ?? []
    }

    /// Forgets one fact, or everything when `id` is nil.
    func forgetMemory(id: String?) {
        if let id {
            id.withCString { cp_core_forget_memory(handle, $0) }
        } else {
            cp_core_forget_memory(handle, nil)
        }
    }

    private func take(_ p: UnsafeMutablePointer<CChar>?) -> Data {
        guard let p else { return Data("null".utf8) }
        defer { cp_string_free(p) }
        return Data(String(cString: p).utf8)
    }
}

private final class EventBox {
    let handler: @MainActor (CoreEvent) -> Void
    init(_ handler: @escaping @MainActor (CoreEvent) -> Void) { self.handler = handler }
}

private let coreJobCallback: CPEventCallback = { _, json in
    guard let json,
          let obj = try? JSONSerialization.jsonObject(with: Data(String(cString: json).utf8)) as? [String: Any]
    else { return }
    let event = JobEvent(phase: obj["phase"] as? String ?? "", job: obj["job"] as? Int ?? 0,
                         name: obj["name"] as? String ?? "", text: obj["text"] as? String ?? "",
                         state: obj["state"] as? String ?? "")
    Task { @MainActor in AppModel.shared.handle(job: event) }
}

private let coreEventCallback: CPEventCallback = { ctx, json in
    guard let ctx, let json else { return }
    let event = parseEvent(String(cString: json))
    let box = Unmanaged<EventBox>.fromOpaque(ctx)
    let handler = box.takeUnretainedValue().handler
    if case .finished = event {
        // No more events will arrive for this request; drop our retain once
        // the handler has run.
        DispatchQueue.main.async {
            handler(.finished)
            box.release()
        }
    } else if let event {
        DispatchQueue.main.async { handler(event) }
    }
}

/// What a `board` event puts on the whiteboard.
func boardItem(_ obj: [String: Any]) -> BoardItem? {
    let str = { (k: String) in obj[k] as? String ?? "" }
    let n = { (k: String) in CGFloat(obj[k] as? Double ?? 0) }
    switch str("shape") {
    case "open": return .open(title: str("title"))
    case "card": return .card(id: str("id"), at: CGPoint(x: n("x"), y: n("y")), text: str("text"), icon: str("icon"))
    case "link": return .link(from: str("from"), to: str("to"), text: str("text"))
    case "write": return .write(at: CGPoint(x: n("x"), y: n("y")), text: str("text"), size: str("size"))
    case "point": return .point(CGPoint(x: n("x"), y: n("y")), label: str("label"))
    default: return inkShape(obj).map { .mark($0, label: str("label")) }
    }
}

func boardItem(json: String) -> BoardItem? {
    (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]).flatMap(boardItem)
}

/// A drawing from a `mark` or `board` event.
private func inkShape(_ obj: [String: Any]) -> InkShape? {
    let n = { (k: String) in CGFloat(obj[k] as? Double ?? 0) }
    let at = CGPoint(x: n("x"), y: n("y"))
    let rect = CGRect(x: n("x"), y: n("y"), width: n("w"), height: n("h"))
    switch obj["shape"] as? String ?? "" {
    case "circle": return .circle(center: at, radius: n("r"))
    case "arrow": return .arrow(from: CGPoint(x: n("x1"), y: n("y1")), to: CGPoint(x: n("x2"), y: n("y2")))
    case "box": return .box(rect)
    case "underline": return .underline(from: at, width: n("w"))
    case "highlight": return .highlight(rect)
    case "spotlight": return .spotlight(rect)
    case "trace":
        let pts = (obj["points"] as? [[Double]] ?? []).compactMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        return pts.count >= 2 ? .trace(pts) : nil
    case "note": return .note(at: at, text: obj["text"] as? String ?? "")
    case "check": return .check(at)
    case "cross": return .cross(at)
    case "step": return .step(at, obj["n"] as? Int ?? 1)
    case "bracket": return .bracket(top: at, height: n("h"))
    default: return nil
    }
}

private func parseEvent(_ json: String) -> CoreEvent? {
    guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
          let type = obj["type"] as? String
    else { return nil }
    let str = { (k: String) in obj[k] as? String ?? "" }
    switch type {
    case "started": return .started(conversationID: str("conversation_id"))
    case "text": return .text(str("text"))
    case "speak": return .speak(str("text"))
    case "point":
        guard let x = obj["x"] as? Double, let y = obj["y"] as? Double else { return nil }
        return .point(x: x, y: y, label: str("label"))
    case "mark":
        guard let shape = inkShape(obj) else { return nil }
        return .mark(shape, label: str("label"))
    case "board":
        return boardItem(obj).map { .board($0, raw: json) }
    case "focus": return .focus(str("id"))
    case "tool":
        return .tool(AgentStep(callID: str("id"), phase: str("phase"), kind: str("kind"), summary: str("summary"),
                               ok: obj["ok"] as? Bool ?? true))
    case "agent":
        return .helper(HelperEvent(phase: str("phase"), agent: obj["agent"] as? Int ?? 0, callID: str("id"),
                                   name: str("name"), text: str("text"), ok: obj["ok"] as? Bool ?? true))
    case "done": return .done(text: str("text"))
    case "error": return .error(kind: str("kind"), message: str("message"))
    case "finished": return .finished
    default: return nil
    }
}
