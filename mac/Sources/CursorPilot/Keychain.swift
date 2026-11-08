import Foundation
import Security

/// Stores the Anthropic API key in the login keychain.
///
/// The item is saved and read through /usr/bin/security, which owns it, so
/// macOS never asks to allow access, not even after a rebuild changes the
/// app's signature. (An item the app owns itself is tied to the exact build
/// that saved it, so every new build had to be allowed again.) Earlier
/// versions saved the key that way; it moves over once.
enum Keychain {
    private static let service = "com.louistuis.cursorpilot.api-key"
    private static let account = "anthropic"
    private static let legacyService = "com.louistuis.cursorpilot"
    private static let legacyAccount = "anthropic-api-key"

    /// Call it off the main thread: it runs a short process, and the one-time
    /// move from the old item may wait for the user to allow it.
    static func loadAPIKey() -> String {
        let key = security(["find-generic-password", "-s", service, "-a", account, "-w"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { return key }
        let legacy = loadLegacy()
        if !legacy.isEmpty {
            saveAPIKey(legacy)
            SecItemDelete(legacyQuery as CFDictionary)
        }
        return legacy
    }

    static func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            _ = security(["delete-generic-password", "-s", service, "-a", account])
            SecItemDelete(legacyQuery as CFDictionary)
            return
        }
        // Sent as hex through interactive mode, so the key never shows up in
        // a process listing.
        let hex = Data(trimmed.utf8).map { String(format: "%02x", $0) }.joined()
        _ = security(["-i"], input: "add-generic-password -U -s \(service) -a \(account) -X \(hex)\n")
    }

    private static var legacyQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: legacyService,
         kSecAttrAccount as String: legacyAccount]
    }

    private static func loadLegacy() -> String {
        var query = legacyQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else {
            if status != errSecItemNotFound {
                NSLog("Cursor Pilot: reading the old API key failed: %d (%@)", status,
                      (SecCopyErrorMessageString(status, nil) as String?) ?? "")
            }
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: OpenRouter

    private static let openRouterService = "com.louistuis.cursorpilot.openrouter"

    /// The OpenRouter key for cloud speech: the one saved in Settings, else
    /// $OPENROUTER_API_KEY, else the first line of ~/.config/openrouter.key
    /// (where other tools on this Mac keep it). Call it off the main thread.
    static func loadOpenRouterKey() -> String {
        let saved = security(["find-generic-password", "-s", openRouterService, "-a", "openrouter", "-w"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !saved.isEmpty { return saved }
        if let env = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty { return env }
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/openrouter.key")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    static func saveOpenRouterKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            _ = security(["delete-generic-password", "-s", openRouterService, "-a", "openrouter"])
            return
        }
        let hex = Data(trimmed.utf8).map { String(format: "%02x", $0) }.joined()
        _ = security(["-i"], input: "add-generic-password -U -s \(openRouterService) -a openrouter -X \(hex)\n")
    }

    // MARK: abliteration.ai

    private static let abliterationService = "com.louistuis.cursorpilot.abliteration"

    /// The abliteration.ai key: the one saved in Settings, else $ABLIT_KEY.
    /// Call it off the main thread.
    static func loadAbliterationKey() -> String {
        let saved = security(["find-generic-password", "-s", abliterationService, "-a", "abliteration", "-w"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !saved.isEmpty { return saved }
        return ProcessInfo.processInfo.environment["ABLIT_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func saveAbliterationKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            _ = security(["delete-generic-password", "-s", abliterationService, "-a", "abliteration"])
            return
        }
        let hex = Data(trimmed.utf8).map { String(format: "%02x", $0) }.joined()
        _ = security(["-i"], input: "add-generic-password -U -s \(abliterationService) -a abliteration -X \(hex)\n")
    }

    // MARK: OpenAI

    private static let openAIService = "com.louistuis.cursorpilot.openai"

    /// The OpenAI key, for the live voice: the one saved in Settings, else
    /// $OPENAI_API_KEY. Call it off the main thread.
    static func loadOpenAIKey() -> String {
        let saved = security(["find-generic-password", "-s", openAIService, "-a", "openai", "-w"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !saved.isEmpty { return saved }
        return ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func saveOpenAIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            _ = security(["delete-generic-password", "-s", openAIService, "-a", "openai"])
            return
        }
        let hex = Data(trimmed.utf8).map { String(format: "%02x", $0) }.joined()
        _ = security(["-i"], input: "add-generic-password -U -s \(openAIService) -a openai -X \(hex)\n")
    }

    /// Runs /usr/bin/security and returns what it printed.
    private static func security(_ arguments: [String], input: String? = nil) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = arguments
        let out = Pipe(), stdin = Pipe()
        task.standardOutput = out
        task.standardError = FileHandle.nullDevice
        task.standardInput = input == nil ? FileHandle.nullDevice : stdin
        do {
            try task.run()
        } catch {
            NSLog("Cursor Pilot: can't run security: \(error)")
            return ""
        }
        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return task.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : ""
    }
}
