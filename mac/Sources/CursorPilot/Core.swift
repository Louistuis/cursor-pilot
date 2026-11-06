import CCursorPilotCore
import Foundation

/// Settings handed to the Rust core. Field names match `claude::Settings`.
struct CoreSettings: Encodable {
    var apiKey: String
    var model: String
    var effort: String
    /// Mac access: "off" or "on".
    var access: String

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case model, effort, access
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
    /// An agent step: "start" or "end".
    case tool(AgentStep)
    case done(text: String)
    case error(kind: String, message: String)
    case finished
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
        case "web": "globe"
        default: "sparkles"
        }
    }

    /// The icon for a saved step, from its wording.
    static func icon(forSummary s: String) -> String {
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
        let n = { (k: String) in CGFloat(obj[k] as? Double ?? 0) }
        let shape: InkShape
        switch str("shape") {
        case "circle": shape = .circle(center: CGPoint(x: n("x"), y: n("y")), radius: n("r"))
        case "arrow": shape = .arrow(from: CGPoint(x: n("x1"), y: n("y1")), to: CGPoint(x: n("x2"), y: n("y2")))
        case "box": shape = .box(CGRect(x: n("x"), y: n("y"), width: n("w"), height: n("h")))
        default: return nil
        }
        return .mark(shape, label: str("label"))
    case "tool":
        return .tool(AgentStep(callID: str("id"), phase: str("phase"), kind: str("kind"), summary: str("summary"),
                               ok: obj["ok"] as? Bool ?? true))
    case "done": return .done(text: str("text"))
    case "error": return .error(kind: str("kind"), message: str("message"))
    case "finished": return .finished
    default: return nil
    }
}
