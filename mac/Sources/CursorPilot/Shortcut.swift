import AppKit
import Carbon
import SwiftUI

/// A user-chosen hold-to-talk shortcut, stored as Carbon key code + modifiers.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var keyName: String

    static let `default` = Shortcut(keyCode: UInt32(kVK_Space),
                                    carbonModifiers: UInt32(controlKey | optionKey),
                                    keyName: "Space")
    /// Toggles drawing on the screen.
    static let draw = Shortcut(keyCode: UInt32(kVK_ANSI_D),
                               carbonModifiers: UInt32(controlKey | optionKey),
                               keyName: "D")

    var display: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyName
    }

    /// Builds a shortcut from a key press. Needs Control, Option or Command,
    /// so ordinary typing can never trigger it.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        guard mods & UInt32(controlKey | optionKey | cmdKey) != 0 else { return nil }
        let code = Int(event.keyCode)
        let name = Self.specialKeyNames[code]
            ?? event.charactersIgnoringModifiers?.uppercased().trimmingCharacters(in: .whitespaces)
        guard let name, !name.isEmpty else { return nil }
        self.init(keyCode: UInt32(code), carbonModifiers: mods, keyName: name)
    }

    init(keyCode: UInt32, carbonModifiers: UInt32, keyName: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keyName = keyName
    }

    private static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}

/// A button that records the next shortcut pressed. Escape cancels.
struct ShortcutRecorder: View {
    @ObservedObject var model: AppModel
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: toggle) {
                    Text(model.isRecordingShortcut ? "Press a shortcut…" : model.shortcut.display)
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .frame(minWidth: 120)
                }
                if model.shortcut != .default && !model.isRecordingShortcut {
                    Button("Reset") { model.shortcut = .default }
                }
            }
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            } else if !model.hotKeyRegistered {
                Text("Another app is using this shortcut. Pick a different one.")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .onDisappear(perform: stop)
    }

    private func toggle() {
        model.isRecordingShortcut ? stop() : start()
    }

    private func start() {
        hint = nil
        model.isRecordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
            } else if let shortcut = Shortcut(event: event) {
                model.shortcut = shortcut
                stop()
            } else {
                hint = "Include ⌃, ⌥ or ⌘."
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if model.isRecordingShortcut { model.isRecordingShortcut = false }
    }
}
