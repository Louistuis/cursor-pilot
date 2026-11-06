import AppKit
import Contacts
import SQLite3

/// The `messages` tool: reads the user's conversations from Messages'
/// database and sends texts through the Messages app.
///
/// Reading needs Full Disk Access (macOS keeps ~/Library/Messages private);
/// sending asks once to control Messages.
@MainActor
enum MessagesTool {
    struct Result {
        var content: String
        var isError: Bool
        var summary: String?
    }

    static func perform(_ input: [String: Any]) async -> Result {
        let action = input["action"] as? String ?? ""
        switch action {
        case "chats": return chats(limit: min(max(input["limit"] as? Int ?? 15, 1), 50))
        case "read": return read(input["with"] as? String ?? "", limit: min(max(input["limit"] as? Int ?? 20, 1), 100))
        case "send": return await send(to: input["to"] as? String ?? "", text: input["text"] as? String ?? "")
        default:
            return Result(content: "Unknown action \u{201C}\(action)\u{201D}. Use chats, read or send.", isError: true)
        }
    }

    // MARK: Reading

    private static let database = NSHomeDirectory() + "/Library/Messages/chat.db"

    private static var noAccess: Result {
        Result(content: "Can't read Messages: Cursor Pilot needs Full Disk Access. Tell the user to run Cursor Pilot's \(Setup.hint) once. Sending still works without it.",
               isError: true, summary: "Needs Full Disk Access for Messages")
    }

    private struct Chat {
        var id: Int64
        var guid: String
        var identifier: String
        var displayName: String
    }

    private struct Row {
        var fromMe: Bool
        var text: String
        var date: Date
        var sender: String
    }

    private static func open() -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(database)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              sqlite3_exec(db, "SELECT 1 FROM message LIMIT 1", nil, nil, nil) == SQLITE_OK
        else {
            sqlite3_close(db)
            return nil
        }
        return db
    }

    private static func query(_ db: OpaquePointer?, _ sql: String, _ bind: [Any] = [],
                              row: (OpaquePointer?) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in bind.enumerated() {
            if let n = value as? Int64 { sqlite3_bind_int64(stmt, Int32(i + 1), n) }
            if let n = value as? Int { sqlite3_bind_int64(stmt, Int32(i + 1), Int64(n)) }
        }
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }

    private static func string(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        sqlite3_column_text(stmt, col).map { String(cString: $0) } ?? ""
    }

    /// The message's words: `text`, or on newer systems the archived
    /// attributed string in `attributedBody`.
    private static func body(_ stmt: OpaquePointer?, text col: Int32, archive acol: Int32) -> String {
        let t = string(stmt, col)
        if !t.isEmpty { return t }
        guard let bytes = sqlite3_column_blob(stmt, acol) else { return "" }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, acol)))
        if let s = (NSUnarchiver.unarchiveObject(with: data) as? NSAttributedString)?.string { return s }
        return ""
    }

    private static func date(_ stmt: OpaquePointer?, _ col: Int32) -> Date {
        let raw = Double(sqlite3_column_int64(stmt, col))
        // Nanoseconds since 2001 on current systems, seconds on old ones.
        return Date(timeIntervalSinceReferenceDate: raw > 1e12 ? raw / 1e9 : raw)
    }

    private static func chats(limit: Int) -> Result {
        guard let db = open() else { return noAccess }
        defer { sqlite3_close(db) }
        var lines: [String] = []
        query(db, """
            SELECT c.ROWID, c.guid, c.chat_identifier, IFNULL(c.display_name, ''), m.text, m.attributedBody, m.date, m.is_from_me
            FROM chat c
            JOIN message m ON m.ROWID = (SELECT MAX(message_id) FROM chat_message_join WHERE chat_id = c.ROWID)
            ORDER BY m.date DESC LIMIT ?
            """, [limit]) { s in
            let chat = Chat(id: sqlite3_column_int64(s, 0), guid: string(s, 1), identifier: string(s, 2),
                            displayName: string(s, 3))
            let text = body(s, text: 4, archive: 5)
            let fromMe = sqlite3_column_int(s, 7) == 1
            lines.append("\(name(of: chat)): \(fromMe ? "You: " : "")\(clip(text, 90)) (\(when(date(s, 6))))")
        }
        return Result(content: lines.isEmpty ? "No conversations." : lines.joined(separator: "\n"),
                      isError: false, summary: "Checked your messages")
    }

    private static func read(_ with: String, limit: Int) -> Result {
        guard let db = open() else { return noAccess }
        defer { sqlite3_close(db) }
        guard let chat = findChat(with, db: db) else {
            return Result(content: "No conversation matches \u{201C}\(with)\u{201D}. Use chats to see recent ones.", isError: true)
        }
        var rows: [Row] = []
        query(db, """
            SELECT m.text, m.attributedBody, m.date, m.is_from_me, IFNULL(h.id, '')
            FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE j.chat_id = ? ORDER BY m.date DESC LIMIT ?
            """, [chat.id, limit]) { s in
            let text = body(s, text: 0, archive: 1)
            guard !text.isEmpty else { return }
            rows.append(Row(fromMe: sqlite3_column_int(s, 3) == 1, text: text, date: date(s, 2),
                            sender: contactName(for: string(s, 4)) ?? string(s, 4)))
        }
        let group = chat.identifier.hasPrefix("chat")
        let lines = rows.reversed().map { r in
            "[\(when(r.date))] \(r.fromMe ? "You" : group ? r.sender : "Them"): \(r.text.replacingOccurrences(of: "\u{FFFC}", with: "[attachment]"))"
        }
        return Result(content: "Conversation with \(name(of: chat)):\n" + lines.joined(separator: "\n"),
                      isError: false, summary: "Read your messages with \(name(of: chat))")
    }

    /// A chat by its name, a contact's name, a number or an address.
    private static func findChat(_ with: String, db: OpaquePointer?) -> Chat? {
        let wanted = with.lowercased().trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return nil }
        let digits = wanted.filter(\.isNumber)
        var best: Chat?
        query(db, """
            SELECT c.ROWID, c.guid, c.chat_identifier, IFNULL(c.display_name, '')
            FROM chat c JOIN message m ON m.ROWID = (SELECT MAX(message_id) FROM chat_message_join WHERE chat_id = c.ROWID)
            ORDER BY m.date DESC LIMIT 400
            """) { s in
            guard best == nil else { return }
            let chat = Chat(id: sqlite3_column_int64(s, 0), guid: string(s, 1), identifier: string(s, 2),
                            displayName: string(s, 3))
            let hay = [chat.displayName, chat.identifier, name(of: chat)].map { $0.lowercased() }
            if hay.contains(where: { $0.contains(wanted) })
                || (digits.count >= 6 && chat.identifier.filter(\.isNumber).hasSuffix(String(digits.suffix(8)))) {
                best = chat
            }
        }
        return best
    }

    // MARK: Sending

    private static func send(to: String, text: String) async -> Result {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty, !text.isEmpty else { return Result(content: "send needs to and text.", isError: true) }
        // Scripting Messages without the user's yes from setup would stop to ask.
        guard Setup.mayScript("com.apple.MobileSMS") else {
            return Result(content: "Cursor Pilot isn't allowed to control Messages yet, so it can't send. Tell the user to run Cursor Pilot's \(Setup.hint) once.",
                          isError: true, summary: "Needs permission to send texts")
        }
        // An existing conversation by name keeps group chats and the right
        // service; otherwise a number, address or contact name.
        var target: String
        if let db = open(), let chat = findChat(to, db: db) {
            sqlite3_close(db)
            target = "chat id \"\(escape(chat.guid))\""
        } else if let handle = handle(forName: to) ?? (to.contains("@") || to.filter(\.isNumber).count >= 6 ? to : nil) {
            target = "participant \"\(escape(handle))\" of (1st account whose service type = iMessage)"
        } else {
            return Result(content: "Couldn't find \u{201C}\(to)\u{201D} in Messages or Contacts. Ask for their number or address.",
                          isError: true)
        }
        let script = "tell application \"Messages\" to send \"\(escape(text))\" to \(target)"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            return Result(content: "Messages couldn't send it: \(error[NSAppleScript.errorMessage] ?? error)", isError: true)
        }
        return Result(content: "Sent to \(to): \u{201C}\(text)\u{201D}", isError: false, summary: "Texted \(to)")
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: Names

    private static var contacts: [String: String]?
    /// Each contact's name (lowercased) to a number or address to text.
    private static var reachable: [String: String] = [:]

    /// Phone numbers (last 8 digits) and addresses to names, when Contacts
    /// access is allowed.
    private static func contactIndex() -> [String: String] {
        if let contacts { return contacts }
        var index: [String: String] = [:]
        let store = CNContactStore()
        if CNContactStore.authorizationStatus(for: .contacts) == .authorized {
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey]
            let request = CNContactFetchRequest(keysToFetch: keys as [CNKeyDescriptor])
            try? store.enumerateContacts(with: request) { c, _ in
                let name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                guard !name.isEmpty else { return }
                for p in c.phoneNumbers { index[String(p.value.stringValue.filter(\.isNumber).suffix(8))] = name }
                for e in c.emailAddresses { index[(e.value as String).lowercased()] = name }
                if let first = c.phoneNumbers.first?.value.stringValue ?? c.emailAddresses.first.map({ $0.value as String }) {
                    reachable[name.lowercased()] = first
                }
            }
            contacts = index
        }
        return index
    }

    private static func contactName(for handle: String) -> String? {
        guard !handle.isEmpty else { return nil }
        let index = contactIndex()
        return handle.contains("@") ? index[handle.lowercased()] : index[String(handle.filter(\.isNumber).suffix(8))]
    }

    private static func handle(forName name: String) -> String? {
        let wanted = name.lowercased()
        _ = contactIndex()
        return reachable[wanted] ?? reachable.first { $0.key.contains(wanted) }?.value
    }

    private static func name(of chat: Chat) -> String {
        if !chat.displayName.isEmpty { return chat.displayName }
        return contactName(for: chat.identifier) ?? chat.identifier
    }

    private static func when(_ d: Date) -> String {
        let cal = Calendar.current
        let time = d.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(d) { return time }
        if cal.isDateInYesterday(d) { return "yesterday \(time)" }
        return d.formatted(.dateTime.day().month(.abbreviated)) + " " + time
    }

    private static func clip(_ s: String, _ n: Int) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        return one.count > n ? one.prefix(n) + "…" : one
    }
}
