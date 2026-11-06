import AppKit
import ApplicationServices

/// The window id behind an Accessibility window element. Private, but long
/// stable and what every window manager for the Mac uses.
@_silgen_name("_AXUIElementGetWindow")
private func axGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// A helper agent's own space on the Mac: the windows it opened, and a
/// browser of its own. Its screenshots show only its current window, even
/// while the user's windows cover it, and its clicks and typing go to that
/// window, so it works next to the user without touching their screen,
/// their tabs or the app they're in. macOS doesn't let apps make desktops
/// (Spaces) of their own, so a workspace is a set of windows instead.
@MainActor
final class Workspace {
    struct Window {
        var id: CGWindowID
        var pid: pid_t
        /// Global top-left points.
        var frame: CGRect
        var appName: String
        var title: String
    }

    let agent: Int
    let name: String
    /// Its windows, oldest first.
    private(set) var windows: [CGWindowID] = []
    /// The window its screenshots show and its clicks go to.
    private(set) var current: CGWindowID?
    /// Its own browser, a separate instance with a private profile.
    private var browser: NSRunningApplication?

    /// Which agent owns each window, so helpers never take each other's.
    private static var owners: [CGWindowID: Int] = [:]

    /// Chromium browsers, in order of preference, for helpers' own browsers:
    /// they can run a second, separate copy with its own profile.
    private static let browsers = ["com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac",
                                   "org.chromium.Chromium", "com.vivaldi.Vivaldi"]

    init(agent: Int, name: String) {
        self.agent = agent
        self.name = name
    }

    // MARK: Windows

    /// Normal app windows other than ours, on screen or not.
    static func allWindows() -> [Window] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let me = getpid()
        return list.compactMap { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict), frame.width > 80, frame.height > 60
            else { return nil }
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            return Window(id: id, pid: pid, frame: frame,
                          appName: NSRunningApplication(processIdentifier: pid)?.localizedName ?? owner,
                          title: w[kCGWindowName as String] as? String ?? "")
        }
    }

    static func window(_ id: CGWindowID) -> Window? {
        guard let w = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              let pid = w[kCGWindowOwnerPID as String] as? pid_t,
              let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: boundsDict)
        else { return nil }
        let owner = w[kCGWindowOwnerName as String] as? String ?? ""
        return Window(id: id, pid: pid, frame: frame,
                      appName: NSRunningApplication(processIdentifier: pid)?.localizedName ?? owner,
                      title: w[kCGWindowName as String] as? String ?? "")
    }

    /// Its current window, if it is still open.
    var currentWindow: Window? {
        windows.removeAll { Self.window($0) == nil }
        if let c = current, !windows.contains(c) { current = windows.last }
        return current.flatMap(Self.window)
    }

    var all: [Window] { windows.compactMap(Self.window) }

    func claim(_ id: CGWindowID) {
        guard Self.owners[id] == nil || Self.owners[id] == agent else { return }
        Self.owners[id] = agent
        if !windows.contains(id) { windows.append(id) }
        current = id
    }

    /// Makes one of its windows the one it works in.
    func select(_ id: CGWindowID) {
        if windows.contains(id) { current = id }
    }

    /// Its window of `app` (a name or bundle id), the current one first.
    func window(ofApp app: String) -> Window? {
        let wanted = app.lowercased()
        guard !wanted.isEmpty else { return nil }
        let mine = all.filter { $0.id == current } + all.filter { $0.id != current }
        return mine.first { w in
            let running = NSRunningApplication(processIdentifier: w.pid)
            return w.appName.lowercased().contains(wanted) || running?.bundleIdentifier?.lowercased() == wanted
                || running?.bundleURL?.deletingPathExtension().lastPathComponent.lowercased().contains(wanted) == true
        }
    }

    /// Claims the windows that appeared since `before` in apps whose pid
    /// `accept` allows, waiting up to `wait` seconds for the first one.
    @discardableResult
    func claimNew(since before: Set<CGWindowID>, wait: Double, accept: (pid_t) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(wait)
        repeat {
            let fresh = Self.allWindows().filter { !before.contains($0.id) && Self.owners[$0.id] == nil && accept($0.pid) }
            if !fresh.isEmpty {
                for w in fresh { claim(w.id) }
                return true
            }
            if wait <= 0 { return false }
            try? await Task.sleep(for: .milliseconds(120))
        } while Date() < deadline
        return false
    }

    /// Some apps bring themselves to the front when they start, even when
    /// opened in the background (Chrome does). For a few seconds, if one
    /// that `took` matches does, hand the front back to the app the user was
    /// in. Through Accessibility, which works without being the active app.
    static func keepFront(_ previous: NSRunningApplication?, seconds: Double = 3, took: @escaping (pid_t) -> Bool) {
        guard let previous, previous.processIdentifier != getpid() else { return }
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if let front = NSWorkspace.shared.frontmostApplication, front != previous,
                   took(front.processIdentifier), !previous.isTerminated {
                    AXUIElementSetAttributeValue(BackgroundInput.app(previous.processIdentifier),
                                                 kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
    }

    /// Is its window the one on top at `p`, so the real pointer would hit it?
    static func isUncovered(_ id: CGWindowID, at p: CGPoint) -> Bool {
        BackgroundInput.window(at: p)?.windowID == id
    }

    // MARK: Its own browser

    /// Opens `url` in the helper's own browser: a separate copy of a
    /// Chromium browser with a private profile, so the user's browser, tabs
    /// and windows are untouched. Nil when no such browser is installed.
    func openInOwnBrowser(_ url: URL) async -> AppControl.Result? {
        let installed = Self.browsers.lazy.compactMap { id in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { (id, $0) }
        }.first
        guard let (_, appURL) = installed else { return nil }
        let profile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cursor Pilot/Helpers/\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let running = browser.map { !$0.isTerminated } ?? false
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        config.createsNewApplicationInstance = true
        // A second launch with the same profile hands the page to the
        // running copy, as a new tab in its window.
        // It works under the user's windows, so it must keep drawing there:
        // Chrome stops painting windows it thinks are hidden.
        config.arguments = ["--user-data-dir=\(profile.path)", "--no-first-run", "--no-default-browser-check",
                            "--disable-features=SigninInterceptBubble,Translate,TranslateUI",
                            "--disable-backgrounding-occluded-windows", "--disable-renderer-backgrounding",
                            "--disable-background-timer-throttling"]
            + (running ? [] : ["--new-window"]) + [url.absoluteString]
        let before = Set(Self.allWindows().map(\.id))
        let front = NSWorkspace.shared.frontmostApplication
        do {
            let app = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
            if !running { browser = app }
            let pid = browser?.processIdentifier
            Self.keepFront(front, seconds: running ? 2 : 5) { $0 == pid || $0 == app.processIdentifier }
        } catch {
            return AppControl.Result(content: "Couldn't open your browser: \(error.localizedDescription)", isError: true)
        }
        guard let pid = browser?.processIdentifier else { return nil }
        await claimNew(since: before, wait: running ? 0.6 : 6) { $0 == pid }
        if let w = all.first(where: { $0.pid == pid }) { select(w.id) }
        try? await Task.sleep(for: .milliseconds(running ? 600 : 900))
        let host = url.host ?? url.absoluteString
        let how = running ? "in a new tab of your own browser window" : "in your own browser window"
        return AppControl.Result(
            content: "Opened \(url.absoluteString) \(how): a private copy of \(appURL.deletingPathExtension().lastPathComponent) only you use, with no sign-ins, separate from the user's browser and tabs. Take a screenshot to see it; use app_control elements (no app needed) to list its links and fields.",
            isError: false, summary: "Opened \(host) in its own browser")
    }

    /// The task is over: its windows are free again and its browser quits.
    func close() {
        for id in windows where Self.owners[id] == agent { Self.owners[id] = nil }
        windows.removeAll()
        current = nil
        browser?.terminate()
        browser = nil
    }

    // MARK: Accessibility

    static func windowID(of axWindow: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return axGetWindow(axWindow, &id) == .success && id != 0 ? id : nil
    }

    /// The Accessibility element of window `id` of app `pid`.
    static func axWindow(pid: pid_t, id: CGWindowID) -> AXUIElement? {
        let windows: [AXUIElement] = BackgroundInput.attribute(BackgroundInput.app(pid), kAXWindowsAttribute) ?? []
        return windows.first { windowID(of: $0) == id }
    }
}
