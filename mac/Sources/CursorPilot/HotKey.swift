import AppKit
import Carbon
import Foundation

/// A system-wide hold-to-talk shortcut built on Carbon hot keys, which need
/// no Accessibility or Input Monitoring permission.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private var isDown = false
    private let id: UInt32

    /// False when another app already owns the shortcut.
    private(set) var isRegistered = false

    /// `id` tells several hot keys apart; each must be unique in the app.
    init(_ shortcut: Shortcut, id: UInt32 = 1, onPress: @escaping () -> Void, onRelease: @escaping () -> Void = {}) {
        self.id = id
        self.onPress = onPress
        self.onRelease = onRelease

        var events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            // Every hot key's handler sees every hot key event; pass on the
            // ones that belong to another HotKey.
            guard pressed.id == hotKey.id else { return OSStatus(eventNotHandledErr) }
            hotKey.handle(kind: GetEventKind(event))
            return noErr
        }, events.count, &events, selfPtr, &handlerRef)

        let hotKeyID = EventHotKeyID(signature: OSType(0x4350_4C54), id: id) // "CPLT"
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        isRegistered = status == noErr
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    private func handle(kind: UInt32) {
        switch Int(kind) {
        case kEventHotKeyPressed where !isDown:
            isDown = true
            onPress()
        case kEventHotKeyReleased where isDown:
            isDown = false
            onRelease()
        default:
            break // key repeat while held
        }
    }
}

/// Hold-to-talk on modifier keys alone: hold ⌃⌥, talk, let go.
///
/// Carbon hot keys need a non-modifier key and event taps need Input
/// Monitoring, so this reads the global modifier and key state instead,
/// which needs no permission. A chord only counts once it has been held a
/// moment with nothing else pressed, so shortcuts such as ⌃⌥D don't start
/// listening; if another key joins right after, the press is cancelled.
@MainActor
final class ModifierHold {
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    /// The chord turned out to be part of another shortcut.
    var onCancel: () -> Void = {}

    private let chord: NSEvent.ModifierFlags = [.control, .option]
    private static let considered: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
    /// How long the chord must be held alone before listening starts.
    private static let holdDelay: CFTimeInterval = 0.18
    /// After starting, another key this soon means it was a shortcut after all.
    private static let cancelWindow: CFTimeInterval = 0.35

    private var timer: Timer?
    private var heldSince: CFTimeInterval?
    private var pressedAt: CFTimeInterval?
    private var spoiled = false

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if pressedAt != nil { onCancel() }
        heldSince = nil
        pressedAt = nil
        spoiled = false
    }

    private func tick() {
        let flags = NSEvent.modifierFlags.intersection(Self.considered)
        let now = CACurrentMediaTime()

        if let pressedAt {
            if !flags.isSuperset(of: chord) {
                self.pressedAt = nil
                heldSince = nil
                onRelease()
            } else if now - pressedAt < Self.cancelWindow, flags != chord || Self.somethingElsePressed() {
                self.pressedAt = nil
                spoiled = true
                onCancel()
            }
            return
        }

        guard flags == chord else {
            heldSince = nil
            spoiled = false
            return
        }
        if heldSince == nil { heldSince = now }
        if spoiled || Self.somethingElsePressed() {
            spoiled = true
        } else if let since = heldSince, now - since >= Self.holdDelay {
            pressedAt = now
            onPress()
        }
    }

    /// Any non-modifier key or mouse button down right now.
    private static func somethingElsePressed() -> Bool {
        if NSEvent.pressedMouseButtons != 0 { return true }
        for code in 0..<0x7F where !(0x36...0x3F).contains(code) {
            if CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(code)) { return true }
        }
        return false
    }
}
