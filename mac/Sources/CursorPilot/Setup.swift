import AppKit
import AVFoundation
import Contacts
import Network
import Speech

/// The one-time setup: everything Cursor Pilot can need from macOS is asked
/// for here, up front, so nothing prompts while it works. At work it only
/// checks; when something is missing it says so instead of asking.
///
/// macOS doesn't let an app grant itself anything. The dialogs that can
/// appear in place do (microphone, speech, contacts, automation, folders,
/// local network); the rest are switches in System Settings, opened one at a
/// time until they're all on.
enum Setup {
    /// Where the user goes to fix a missing permission.
    static let hint = "Settings › Permissions › Set Up Everything"
    /// Apps Cursor Pilot scripts itself, and the ones its agent may script
    /// from the shell: asked about once here.
    static let scripted = ["com.apple.systemevents", "com.apple.finder", "com.apple.MobileSMS"]

    // MARK: Checking (never prompts)

    static var hasVoice: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            && SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    static var hasContacts: Bool { CNContactStore.authorizationStatus(for: .contacts) == .authorized }

    /// Full Disk Access: Messages' database (or Safari's folder) is readable.
    static var hasFullDiskAccess: Bool {
        let home = NSHomeDirectory()
        for path in [home + "/Library/Messages/chat.db", home + "/Library/Safari/Bookmarks.plist"] {
            let fd = open(path, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return true
            }
        }
        return false
    }

    /// Can Cursor Pilot script `bundleID` without macOS asking? Known from
    /// the app while it runs, and remembered from setup otherwise.
    static func mayScript(_ bundleID: String) -> Bool {
        switch automation(bundleID, ask: false) {
        case noErr:
            UserDefaults.standard.set(true, forKey: "scripts.\(bundleID)")
            return true
        case OSStatus(procNotFound):
            return UserDefaults.standard.bool(forKey: "scripts.\(bundleID)")
        default:
            UserDefaults.standard.set(false, forKey: "scripts.\(bundleID)")
            return false
        }
    }

    static var hasAutomation: Bool { scripted.allSatisfy(mayScript) }

    private static func automation(_ bundleID: String, ask: Bool) -> OSStatus {
        var target = AEAddressDesc()
        let status = bundleID.withCString { id in
            AECreateDesc(DescType(typeApplicationBundleID), id, strlen(id), &target)
        }
        guard status == noErr else { return OSStatus(status) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
    }

    // MARK: Asking (only from the setup buttons)

    /// Asks for everything that can be asked in place, one dialog after the
    /// other, then opens System Settings at the first switch still off.
    @MainActor
    static func run() async {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        }
        if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            _ = try? await CNContactStore().requestAccess(for: .contacts)
        }
        await askToScript()
        if !hasFullDiskAccess { await touchFolders() }
        await askLocalNetwork()
        // These two add Cursor Pilot to their lists in System Settings.
        if !ComputerControl.hasAccessibility { ComputerControl.requestAccessibility() }
        if !ScreenCapture.hasPermission { ScreenCapture.requestPermission() }
        openNextPane()
    }

    /// Opens System Settings at the first permission that is a switch there
    /// and still off. False when they're all on.
    @MainActor
    @discardableResult
    static func openNextPane() -> Bool {
        let pane: String? = !ComputerControl.hasAccessibility ? "Privacy_Accessibility"
            : !ScreenCapture.hasPermission ? "Privacy_ScreenCapture"
            : !hasFullDiskAccess ? "Privacy_AllFiles"
            : nil
        guard let pane else { return false }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
        return true
    }

    /// Asks once to script the apps in `scripted`. Each must be running to
    /// be asked about, so the ones that aren't start hidden and quit again.
    @MainActor
    static func askToScript() async {
        for id in scripted {
            guard automation(id, ask: false) != noErr else { continue }
            var started: NSRunningApplication?
            if NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                config.hides = true
                config.addsToRecentItems = false
                started = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
                try? await Task.sleep(for: .milliseconds(900))
            }
            // The dialog blocks the caller until it's answered.
            let status = await Task.detached { automation(id, ask: true) }.value
            UserDefaults.standard.set(status == noErr, forKey: "scripts.\(id)")
            started?.terminate()
        }
    }

    /// Without Full Disk Access, macOS asks per folder the first time
    /// Cursor Pilot (or a command it runs) looks inside: ask now instead.
    private static func touchFolders() async {
        await Task.detached {
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser
            for name in ["Desktop", "Documents", "Downloads"] {
                _ = try? fm.contentsOfDirectory(atPath: home.appendingPathComponent(name).path)
            }
            for volume in (try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? [] {
                _ = try? fm.contentsOfDirectory(atPath: "/Volumes/" + volume)
            }
        }.value
    }

    /// Devices on the local network (printers, a NAS, a dev server on
    /// another Mac) need a yes once; looking for any asks it.
    @MainActor
    private static func askLocalNetwork() async {
        guard !UserDefaults.standard.bool(forKey: "askedLocalNetwork") else { return }
        UserDefaults.standard.set(true, forKey: "askedLocalNetwork")
        let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: .tcp)
        browser.start(queue: .main)
        try? await Task.sleep(for: .seconds(1.5))
        browser.cancel()
    }
}
