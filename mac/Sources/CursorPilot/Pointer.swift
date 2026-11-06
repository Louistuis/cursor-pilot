import AppKit
import ApplicationServices
import Carbon

// MARK: - Background input

/// Delivers the agent's clicks, typing and scrolling straight to the app
/// under its own pointer, without moving the user's pointer or bringing the
/// app to the front. It prefers Accessibility actions (pressing the button
/// itself, focusing the field, moving the scroll bar) and falls back to
/// events posted to that one process. Points are global Quartz points (top
/// left origin), the space of CGWindowList, CGEvent and Accessibility.
@MainActor
enum BackgroundInput {
    /// The app window under a point.
    struct Target {
        var pid: pid_t
        var windowID: CGWindowID
        var appName: String
    }

    /// How a click was carried out, for the tool result and the step list.
    enum Outcome {
        /// An Accessibility action on a control, e.g. pressing a button.
        case pressed(String)
        /// A text field or row was focused or selected directly.
        case focused(String)
        /// Events were sent to the app; whether it reacted is unknown.
        case posted
    }

    /// Our own source, so background events don't pick up the modifier keys
    /// the user is holding (and theirs don't pick up ours).
    private static let source: CGEventSource? = {
        let s = CGEventSource(stateID: .privateState)
        s?.localEventsSuppressionInterval = 0
        return s
    }()

    // MARK: Finding things

    /// The frontmost window at `p` that belongs to another app. Menu bar and
    /// other system-owned spots resolve to the frontmost app, whose menu bar
    /// it is.
    static func window(at p: CGPoint) -> Target? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        // Ours, including other copies of the app, are never in the way.
        let mine = Set(NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .map(\.processIdentifier) + [getpid()])
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, !mine.contains(pid),
                  let alpha = w[kCGWindowAlpha as String] as? Double, alpha > 0.01,
                  let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict), bounds.contains(p)
            else { continue }
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            if owner == "Window Server" || owner == "Wallpaper" {
                guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
                return Target(pid: front.processIdentifier, windowID: 0, appName: front.localizedName ?? "the app")
            }
            // The Dock keeps a clear window over the whole screen; it is only
            // in the way where the Dock itself is.
            if owner == "Dock", bounds.width >= 400, bounds.height >= 400, pidAt(p) != pid { continue }
            let id = w[kCGWindowNumber as String] as? CGWindowID ?? 0
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? owner
            return Target(pid: pid, windowID: id, appName: name)
        }
        return nil
    }

    /// The app whose element is at `p`, as Accessibility sees it.
    static func pidAt(_ p: CGPoint) -> pid_t? {
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &el) == .success,
              let el else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(el, &pid) == .success ? pid : nil
    }

    static func app(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.8)
        // Chromium and Electron apps only build their accessibility tree when
        // asked to; harmless for everything else.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return app
    }

    /// The element of `pid` under `p`.
    static func element(at p: CGPoint, pid: pid_t) -> AXUIElement? {
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app(pid), Float(p.x), Float(p.y), &el) == .success else { return nil }
        return el
    }

    /// The element under `p` in the target's own window. Accessibility hit
    /// testing finds the app's top window there, which may be another of
    /// its windows (the user's, over a helper's): then the target window is
    /// searched instead.
    static func element(at p: CGPoint, in target: Target) -> AXUIElement? {
        let hit = element(at: p, pid: target.pid)
        guard target.windowID != 0 else { return hit }
        if let hit, let win: AXUIElement = attribute(hit, kAXWindowAttribute),
           Workspace.windowID(of: win) == target.windowID {
            return hit
        }
        guard let win = Workspace.axWindow(pid: target.pid, id: target.windowID) else { return hit }
        return deepest(at: p, in: win, depth: 0)
    }

    /// The deepest element containing `p`, front-most children first.
    private static func deepest(at p: CGPoint, in el: AXUIElement, depth: Int) -> AXUIElement {
        guard depth < 30 else { return el }
        let children: [AXUIElement] = attribute(el, "AXVisibleChildren") ?? attribute(el, kAXChildrenAttribute) ?? []
        for child in children.reversed() where frame(child)?.contains(p) == true {
            return deepest(at: p, in: child, depth: depth + 1)
        }
        return el
    }

    static func attribute<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    static func role(_ el: AXUIElement) -> String { attribute(el, kAXRoleAttribute) ?? "" }

    static func actions(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    static func isSettable(_ el: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(el, name as CFString, &settable) == .success && settable.boolValue
    }

    /// The element's frame in global points.
    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let pos: AXValue = attribute(el, kAXPositionAttribute),
              let size: AXValue = attribute(el, kAXSizeAttribute)
        else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos, .cgPoint, &p)
        AXValueGetValue(size, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    /// A short, human name for an element: its title, description, value or
    /// role, quoted.
    static func describe(_ el: AXUIElement) -> String {
        let text = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, "AXPlaceholderValue", kAXHelpAttribute]
            .lazy.compactMap { (attribute(el, $0) as String?)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let kind = roleName(role(el))
        guard let text else { return kind }
        return "\u{201C}\(text.count > 40 ? text.prefix(40) + "…" : Substring(text))\u{201D} \(kind)"
    }

    static func roleName(_ role: String) -> String {
        switch role {
        case kAXButtonRole, "AXMenuButton": "button"
        case kAXPopUpButtonRole: "pop-up menu"
        case kAXCheckBoxRole: "checkbox"
        case kAXRadioButtonRole: "option"
        case "AXLink": "link"
        case kAXMenuItemRole: "menu item"
        case kAXMenuBarItemRole: "menu"
        case kAXTextFieldRole, "AXSearchField": "text field"
        case kAXTextAreaRole: "text area"
        case kAXComboBoxRole: "combo box"
        case kAXRowRole, "AXOutlineRow": "row"
        case kAXCellRole: "cell"
        case "AXDockItem": "Dock item"
        case "AXTab": "tab"
        default: role.hasPrefix("AX") ? String(role.dropFirst(2)).lowercased() : role
        }
    }

    private static let pressRoles: Set<String> = [
        kAXButtonRole, "AXMenuButton", kAXPopUpButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, "AXLink",
        kAXMenuItemRole, kAXMenuBarItemRole, "AXDisclosureTriangle", "AXDockItem", "AXTab", "AXIncrementor",
        "AXColorWell", "AXSegment",
    ]
    static let textRoles: Set<String> = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"]
    private static let selectRoles: Set<String> = [kAXRowRole, "AXOutlineRow", kAXCellRole]

    /// The control a click at this element would really hit: the element or
    /// a close ancestor that can be pressed, focused or selected.
    private static func control(from el: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = el
        for _ in 0..<4 {
            guard let c = current else { return nil }
            let r = role(c)
            if pressRoles.contains(r) || textRoles.contains(r) || selectRoles.contains(r) { return c }
            if ["AXWindow", "AXWebArea", "AXScrollArea", "AXApplication", "AXSheet"].contains(r) { return nil }
            current = attribute(c, kAXParentAttribute)
        }
        return nil
    }

    // MARK: Clicking

    /// A plain left click at `p` in the background: an Accessibility action
    /// when the control under the point has one, events posted to the app
    /// otherwise. `semanticOnly` stops before posting events.
    static func click(at p: CGPoint, in target: Target, semanticOnly: Bool = false) -> Outcome? {
        if let hit = element(at: p, in: target), let c = control(from: hit) {
            let r = role(c)
            let name = describe(c)
            if textRoles.contains(r), isSettable(c, kAXFocusedAttribute) {
                AXUIElementSetAttributeValue(c, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                return .focused(name)
            }
            if selectRoles.contains(r), isSettable(c, kAXSelectedAttribute) {
                AXUIElementSetAttributeValue(c, kAXSelectedAttribute as CFString, kCFBooleanTrue)
                return .focused(name)
            }
            if actions(c).contains(kAXPressAction), AXUIElementPerformAction(c, kAXPressAction as CFString) == .success {
                return .pressed(name)
            }
        }
        if semanticOnly { return nil }
        postClick(at: p, button: .left, count: 1, flags: [], to: target)
        return .posted
    }

    /// A right click: the control's own menu when it has one.
    static func rightClick(at p: CGPoint, in target: Target) -> Outcome {
        if let hit = element(at: p, in: target) {
            var el: AXUIElement? = hit
            for _ in 0..<3 {
                guard let e = el else { break }
                if actions(e).contains(kAXShowMenuAction), AXUIElementPerformAction(e, kAXShowMenuAction as CFString) == .success {
                    return .pressed(describe(e))
                }
                el = attribute(e, kAXParentAttribute)
            }
        }
        postClick(at: p, button: .right, count: 1, flags: [], to: target)
        return .posted
    }

    /// Browsers and Electron apps ignore clicks sent to their process, and
    /// their web pages report Accessibility presses that do nothing, so they
    /// get the real pointer for the moment of each click.
    static func needsRealPointer(_ pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        let id = app.bundleIdentifier?.lowercased() ?? ""
        let browsers = ["com.google.chrome", "com.brave.browser", "com.microsoft.edgemac", "company.thebrowser",
                        "org.mozilla.firefox", "com.operasoftware.opera", "com.vivaldi.vivaldi", "org.chromium.chromium",
                        "app.zen-browser", "com.openai.atlas"]
        if browsers.contains(where: id.hasPrefix) { return true }
        guard let url = app.bundleURL else { return false }
        let frameworks = url.appendingPathComponent("Contents/Frameworks")
        return ["Electron Framework.framework", "Chromium Embedded Framework.framework"].contains {
            FileManager.default.fileExists(atPath: frameworks.appendingPathComponent($0).path)
        }
    }

    /// Mouse down/up pairs sent only to the target app. The pointer stays put.
    static func postClick(at p: CGPoint, button: CGMouseButton, count: Int, flags: CGEventFlags, to target: Target) {
        let (down, up): (CGEventType, CGEventType) = switch button {
        case .right: (.rightMouseDown, .rightMouseUp)
        case .center: (.otherMouseDown, .otherMouseUp)
        default: (.leftMouseDown, .leftMouseUp)
        }
        for n in 1...max(count, 1) {
            for type in [down, up] {
                guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
                else { continue }
                e.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                if target.windowID != 0 {
                    e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(target.windowID))
                    e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(target.windowID))
                }
                e.flags = flags
                e.postToPid(target.pid)
            }
        }
    }

    /// A drag sent only to the target app.
    static func postDrag(from a: CGPoint, to b: CGPoint, flags: CGEventFlags, to target: Target) async {
        func send(_ type: CGEventType, _ p: CGPoint) {
            guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
            else { return }
            if target.windowID != 0 {
                e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(target.windowID))
                e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(target.windowID))
            }
            e.flags = flags
            e.postToPid(target.pid)
        }
        send(.leftMouseDown, a)
        for i in 1...16 {
            let t = CGFloat(i) / 16
            send(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            try? await Task.sleep(for: .milliseconds(12))
        }
        send(.leftMouseUp, b)
    }

    // MARK: Scrolling

    /// Scrolls the scroll area under `p` by moving its scroll bar, falling
    /// back to scroll-wheel events sent to the app. `lines` is signed: down
    /// and right are positive.
    static func scroll(at p: CGPoint, in target: Target, dx: Int, dy: Int) -> Bool {
        if let hit = element(at: p, in: target) {
            var el: AXUIElement? = hit
            for _ in 0..<12 {
                guard let e = el else { break }
                if role(e) == kAXScrollAreaRole {
                    var moved = false
                    for (amount, bar) in [(dy, kAXVerticalScrollBarAttribute), (dx, kAXHorizontalScrollBarAttribute)] where amount != 0 {
                        guard let scrollBar: AXUIElement = attribute(e, bar),
                              let value: NSNumber = attribute(scrollBar, kAXValueAttribute),
                              isSettable(scrollBar, kAXValueAttribute)
                        else { continue }
                        // A notch of the wheel is a few lines; move about a
                        // tenth of the page per notch, scaled by content size.
                        let next = min(1, max(0, value.doubleValue + Double(amount) * 0.06))
                        moved = AXUIElementSetAttributeValue(scrollBar, kAXValueAttribute as CFString, next as CFNumber) == .success || moved
                    }
                    if moved { return true }
                    break
                }
                el = attribute(e, kAXParentAttribute)
            }
        }
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
                              wheel1: Int32(-dy * 3), wheel2: Int32(-dx * 3), wheel3: 0)
        else { return false }
        e.location = p
        if target.windowID != 0 {
            e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(target.windowID))
        }
        e.postToPid(target.pid)
        return false
    }

    // MARK: Typing

    /// Types into the focused field of `pid`: inserted through Accessibility
    /// where the field allows it (checked by reading it back), keystrokes sent
    /// to the app otherwise. Newlines and tabs are real key presses.
    static func type(_ text: String, pid: pid_t) async {
        var segment = ""
        func flush() async {
            guard !segment.isEmpty else { return }
            if !insert(segment, pid: pid) { await postText(segment, pid: pid) }
            segment = ""
        }
        for ch in text {
            if ch == "\n" || ch == "\t" {
                await flush()
                postKey(ch == "\n" ? kVK_Return : kVK_Tab, flags: [], pid: pid)
                try? await Task.sleep(for: .milliseconds(30))
            } else {
                segment.append(ch)
            }
        }
        await flush()
    }

    private static func insert(_ text: String, pid: pid_t) -> Bool {
        guard let focused: AXUIElement = attribute(app(pid), kAXFocusedUIElementAttribute),
              isSettable(focused, kAXSelectedTextAttribute)
        else { return false }
        let before: String = attribute(focused, kAXValueAttribute) ?? ""
        guard AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        else { return false }
        // Some fields (web content) accept the call and ignore it.
        let after: String = attribute(focused, kAXValueAttribute) ?? ""
        return after != before
    }

    private static func postText(_ text: String, pid: pid_t) async {
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 16, units.count)])
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                e?.postToPid(pid)
            }
            i += 16
            try? await Task.sleep(for: .milliseconds(8))
        }
    }

    /// One key press sent to `pid`, or to whatever is in front when nil.
    static func postKey(_ code: Int, flags: CGEventFlags, pid: pid_t?) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)
            e?.flags = flags
            if let pid { e?.postToPid(pid) } else { e?.post(tap: .cghidEventTap) }
        }
    }

    // MARK: Borrowing the real pointer

    /// Runs `body` with the user's real pointer at `p`, then puts the pointer
    /// back where it was. For the rare app that ignores background input.
    static func withRealPointer(at p: CGPoint, _ body: () async -> Void) async {
        await RealInput.acquire()
        defer { RealInput.release() }
        let home = CGEvent(source: nil)?.location ?? p
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(25))
        await body()
        try? await Task.sleep(for: .milliseconds(25))
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: home, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }
}

/// The user's one real pointer and keyboard, taken in turn: helpers working
/// at the same time must not borrow them over each other.
@MainActor
enum RealInput {
    private static var busy = false
    private static var waiting: [CheckedContinuation<Void, Never>] = []

    static func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    static func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }

    static func exclusive<T>(_ body: () async -> T) async -> T {
        await acquire()
        defer { release() }
        return await body()
    }
}

// MARK: - App control tool

/// The `app_control` tool: works with apps through their accessibility
/// trees, so Claude can press buttons, fill in fields and choose menu items
/// by name, in the background, without the screen or the mouse.
@MainActor
final class AppControl {
    /// The agent this belongs to, whose screen its positions are given in.
    private let agent: Int

    init(agent: Int) { self.agent = agent }

    struct Result {
        var content: String
        var isError: Bool
        var summary: String?
        /// Where the buddy should fly to show what was used (global points).
        var point: CGPoint?
    }

    /// Elements from the latest listing, by the number Claude refers to them with.
    private var elements: [Int: (element: AXUIElement, app: String)] = [:]
    private var nextID = 1

    func reset() {
        elements.removeAll()
        nextID = 1
    }

    func perform(_ input: [String: Any]) async -> Result {
        let action = input["action"] as? String ?? ""
        switch action {
        case "apps": return listApps()
        case "open": return await open(input)
        case "activate": return activate(input)
        case "elements": return listElements(input)
        case "press": return press(input)
        case "set_value": return setValue(input)
        case "read": return read(input)
        case "menu": return menu(input)
        default:
            return Result(content: "Unknown action \u{201C}\(action)\u{201D}. Use apps, open, activate, elements, press, set_value, read or menu.", isError: true)
        }
    }

    // MARK: Apps

    private func runningApp(_ name: String) -> NSRunningApplication? {
        let n = name.lowercased()
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        // On a Mac in another language, "Calculator" runs as "Kalkulator":
        // the bundle's file name stays English.
        func fileName(_ app: NSRunningApplication) -> String? {
            app.bundleURL?.deletingPathExtension().lastPathComponent.lowercased()
        }
        return apps.first { $0.bundleIdentifier?.lowercased() == n }
            ?? apps.first { $0.localizedName?.lowercased() == n || fileName($0) == n }
            ?? apps.first { $0.localizedName?.lowercased().contains(n) == true || fileName($0)?.contains(n) == true }
    }

    private func listApps() -> Result {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var lines: [String] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != getpid() {
            let ax = BackgroundInput.app(app.processIdentifier)
            let windows: [AXUIElement] = BackgroundInput.attribute(ax, kAXWindowsAttribute) ?? []
            let titles = windows.prefix(6).map { (BackgroundInput.attribute($0, kAXTitleAttribute) as String?) ?? "" }
                .map { $0.isEmpty ? "untitled" : "\u{201C}\($0)\u{201D}" }
            var line = "\(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "no bundle id"))"
            if app.processIdentifier == front { line += ", frontmost" }
            if app.isHidden { line += ", hidden" }
            line += titles.isEmpty ? ", no windows" : ", windows: " + titles.joined(separator: ", ")
            lines.append(line)
        }
        return Result(content: lines.joined(separator: "\n"), isError: false, summary: "Checked the open apps")
    }

    private func open(_ input: [String: Any]) async -> Result {
        let front = input["front"] as? Bool ?? false
        let config = NSWorkspace.OpenConfiguration()
        config.activates = front
        let target = input["target"] as? String ?? ""
        let appName = input["app"] as? String ?? ""
        var appURL: URL?
        if !appName.isEmpty {
            appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appName)
                ?? runningApp(appName)?.bundleURL
                ?? findApp(named: appName)
            if appURL == nil { return Result(content: "No app called \u{201C}\(appName)\u{201D} is installed.", isError: true) }
        }
        do {
            if !target.isEmpty {
                let url = target.contains("://") ? URL(string: target) : URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
                guard let url else { return Result(content: "That isn't a valid path or URL.", isError: true) }
                if let appURL {
                    _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
                } else {
                    _ = try await NSWorkspace.shared.open(url, configuration: config)
                }
            } else if let appURL {
                _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
            } else {
                return Result(content: "open needs app, target or both.", isError: true)
            }
        } catch {
            return Result(content: "Couldn't open it: \(error.localizedDescription)", isError: true)
        }
        try? await Task.sleep(for: .milliseconds(500))
        let name = appName.isEmpty ? (target as NSString).lastPathComponent : appName
        return Result(content: "Opened \(name)\(front ? "" : " in the background (it is not in front; use activate to bring it forward if the user should see it)").",
                      isError: false, summary: "Opened \(name)")
    }

    private func findApp(named name: String) -> URL? {
        let fm = FileManager.default
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    "\(NSHomeDirectory())/Applications", "/Applications/Utilities"]
        for dir in dirs {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name.hasSuffix(".app") ? name : name + ".app")
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private func activate(_ input: [String: Any]) -> Result {
        guard let app = runningApp(input["app"] as? String ?? "") else {
            return Result(content: "That app isn't running. Open it first.", isError: true)
        }
        app.unhide()
        app.activate()
        return Result(content: "\(app.localizedName ?? "The app") is now in front.", isError: false,
                      summary: "Brought \(app.localizedName ?? "the app") to the front")
    }

    // MARK: Elements

    private static let listedRoles: Set<String> = [
        kAXButtonRole, "AXMenuButton", kAXPopUpButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, "AXLink",
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField", kAXSliderRole, "AXIncrementor",
        kAXRowRole, "AXOutlineRow", kAXCellRole, "AXTab", "AXDisclosureTriangle", kAXMenuItemRole,
        kAXStaticTextRole, "AXHeading", kAXImageRole, "AXSegment", "AXColorWell",
    ]

    /// The app an action is about: a helper's own window's app (`_pid`, set
    /// by its workspace), the named app, or else the frontmost one.
    private func resolveApp(_ input: [String: Any]) -> NSRunningApplication? {
        if let pid = input["_pid"] as? Int { return NSRunningApplication(processIdentifier: pid_t(pid)) }
        let appName = input["app"] as? String ?? ""
        return appName.isEmpty ? NSWorkspace.shared.frontmostApplication : runningApp(appName)
    }

    private func listElements(_ input: [String: Any]) -> Result {
        guard let app = resolveApp(input) else {
            return Result(content: "That app isn't running. Check apps, or open it first.", isError: true)
        }
        let ax = BackgroundInput.app(app.processIdentifier)
        let windows: [AXUIElement] = BackgroundInput.attribute(ax, kAXWindowsAttribute) ?? []
        let wanted = (input["window"] as? String ?? "").lowercased()
        let own = (input["_window"] as? Int).flatMap { id in windows.first { Workspace.windowID(of: $0) == CGWindowID(id) } }
        let window = own ?? windows.first { wanted.isEmpty == false && ((BackgroundInput.attribute($0, kAXTitleAttribute) as String?)?.lowercased().contains(wanted) ?? false) }
            ?? (BackgroundInput.attribute(ax, kAXFocusedWindowAttribute) as AXUIElement?)
            ?? (BackgroundInput.attribute(ax, kAXMainWindowAttribute) as AXUIElement?)
            ?? windows.first
        guard let window else {
            return Result(content: "\(app.localizedName ?? "That app") has no open window.", isError: true)
        }
        let find = (input["find"] as? String ?? "").lowercased()
        let limit = min(max(input["limit"] as? Int ?? 120, 10), 300)
        let name = app.localizedName ?? "the app"

        var lines: [String] = []
        var visited = 0
        let deadline = Date().addingTimeInterval(2.0)
        func walk(_ el: AXUIElement, depth: Int) {
            guard visited < 4000, lines.count < limit, depth < 40, Date() < deadline else { return }
            visited += 1
            let role = BackgroundInput.role(el)
            if Self.listedRoles.contains(role), let line = describeLine(el, role: role, app: name, find: find) {
                lines.append(line)
            }
            // Don't descend into closed menus or giant tables beyond what's visible.
            let children: [AXUIElement] = BackgroundInput.attribute(el, "AXVisibleChildren")
                ?? BackgroundInput.attribute(el, kAXChildrenAttribute) ?? []
            for child in children { walk(child, depth: depth + 1) }
        }
        walk(window, depth: 0)
        let title: String = BackgroundInput.attribute(window, kAXTitleAttribute) ?? ""
        var header = "\(name), window \u{201C}\(title)\u{201D}"
        if !find.isEmpty { header += ", matching \u{201C}\(find)\u{201D}" }
        header += ". Use the numbers with press, set_value or read. Positions are [x, y] in screenshot pixels."
        if lines.isEmpty {
            return Result(content: header + "\nNothing found. The app may not expose its controls; take a screenshot and use the computer tools instead.",
                          isError: false, summary: "Looked at \(name)")
        }
        let more = lines.count >= limit ? "\n(More elements exist; narrow it with find.)" : ""
        return Result(content: header + "\n" + lines.joined(separator: "\n") + more, isError: false,
                      summary: "Looked at \(name)")
    }

    private func describeLine(_ el: AXUIElement, role: String, app: String, find: String) -> String? {
        func text(_ attr: String) -> String {
            ((BackgroundInput.attribute(el, attr) as String?) ?? "")
                .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        }
        let title = text(kAXTitleAttribute), desc = text(kAXDescriptionAttribute)
        var value = text(kAXValueAttribute)
        if value.isEmpty, let n: NSNumber = BackgroundInput.attribute(el, kAXValueAttribute) { value = n.stringValue }
        let placeholder = text("AXPlaceholderValue")
        let label = [title, desc].first { !$0.isEmpty } ?? ""
        // Text and images without words aren't worth a line.
        if (role == kAXStaticTextRole || role == kAXImageRole || role == "AXHeading") && label.isEmpty && value.isEmpty { return nil }
        if role == kAXCellRole || role == kAXRowRole || role == "AXOutlineRow", label.isEmpty, value.isEmpty { return nil }
        if !find.isEmpty {
            let hay = [label, value, placeholder, role].joined(separator: " ").lowercased()
            guard hay.contains(find) else { return nil }
        }
        guard let frame = BackgroundInput.frame(el), frame.width > 0, frame.height > 0 else { return nil }
        let id = nextID
        nextID += 1
        elements[id] = (el, app)
        var line = "[\(id)] \(BackgroundInput.roleName(role))"
        if !label.isEmpty { line += " \u{201C}\(clip(label, 60))\u{201D}" }
        if !value.isEmpty, value != label { line += " value \u{201C}\(clip(value, 80))\u{201D}" }
        if !placeholder.isEmpty, value.isEmpty { line += " placeholder \u{201C}\(clip(placeholder, 40))\u{201D}" }
        if (BackgroundInput.attribute(el, kAXEnabledAttribute) as Bool?) == false { line += " (disabled)" }
        if (BackgroundInput.attribute(el, kAXFocusedAttribute) as Bool?) == true { line += " (focused)" }
        if (BackgroundInput.attribute(el, kAXSelectedAttribute) as Bool?) == true { line += " (selected)" }
        let c = ComputerControl.forAgent(agent).imagePoint(CGPoint(x: frame.midX, y: frame.midY))
        line += " at [\(Int(c.x)), \(Int(c.y))]"
        return line
    }

    private func clip(_ s: String, _ n: Int) -> String { s.count > n ? s.prefix(n) + "…" : s }

    /// The element `id` names, or else the first control in `app` whose text
    /// is `find` (exactly, or failing that containing it).
    private func element(_ input: [String: Any]) -> (AXUIElement, String)? {
        if let id = input["id"] as? Int { return elements[id] }
        guard let find = input["find"] as? String, !find.isEmpty else { return nil }
        let first = nextID
        var listing = input
        listing["limit"] = 40
        _ = listElements(listing)
        let found = (first..<nextID).compactMap { elements[$0] }
        let wanted = find.lowercased()
        func label(_ el: AXUIElement) -> String {
            [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
                .lazy.compactMap { BackgroundInput.attribute(el, $0) as String? }
                .first { !$0.isEmpty }?.lowercased() ?? ""
        }
        return found.first { label($0.element) == wanted } ?? found.first
    }

    /// Where an element is, for clicking it on screen like a person.
    struct Spot {
        var point: CGPoint
        var role: String
        var name: String
        var pid: pid_t
    }

    func locate(_ input: [String: Any]) -> Spot? {
        guard let (el, _) = element(input), let c = center(el) else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        return Spot(point: c, role: BackgroundInput.role(el), name: BackgroundInput.describe(el), pid: pid)
    }

    private static let missing = Result(content: "No such element. List elements again (ids change with each listing), or name it with find.", isError: true)

    private func center(_ el: AXUIElement) -> CGPoint? {
        BackgroundInput.frame(el).map { CGPoint(x: $0.midX, y: $0.midY) }
    }

    private func press(_ input: [String: Any]) -> Result {
        guard let (el, app) = element(input) else { return Self.missing }
        let name = BackgroundInput.describe(el)
        let available = BackgroundInput.actions(el)
        let action = [kAXPressAction, kAXConfirmAction, "AXPick", kAXShowMenuAction].first { available.contains($0) }
        if let action, AXUIElementPerformAction(el, action as CFString) == .success {
            return Result(content: "Pressed \(name) in \(app).", isError: false, summary: "Pressed \(name)", point: center(el))
        }
        let role = BackgroundInput.role(el)
        if BackgroundInput.textRoles.contains(role) || BackgroundInput.isSettable(el, kAXFocusedAttribute) {
            AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            return Result(content: "Focused \(name) in \(app).", isError: false, summary: "Focused \(name)", point: center(el))
        }
        if BackgroundInput.isSettable(el, kAXSelectedAttribute) {
            AXUIElementSetAttributeValue(el, kAXSelectedAttribute as CFString, kCFBooleanTrue)
            return Result(content: "Selected \(name) in \(app).", isError: false, summary: "Selected \(name)", point: center(el))
        }
        return Result(content: "\(name) can't be pressed. Click it with the computer tools instead, at its position from the listing.",
                      isError: true, point: center(el))
    }

    private func setValue(_ input: [String: Any]) -> Result {
        guard let (el, app) = element(input) else { return Self.missing }
        let value = input["value"] as? String ?? ""
        let name = BackgroundInput.describe(el)
        if BackgroundInput.isSettable(el, kAXFocusedAttribute) {
            AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        var ok = false
        if BackgroundInput.isSettable(el, kAXValueAttribute) {
            ok = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, value as CFString) == .success
        }
        if ok, (BackgroundInput.attribute(el, kAXValueAttribute) as String?) == value {
            return Result(content: "Set \(name) in \(app) to \u{201C}\(clip(value, 60))\u{201D}.", isError: false,
                          summary: "Filled in \(name)", point: center(el))
        }
        // Web fields often ignore AXValue: replace the text through the selection instead.
        if BackgroundInput.isSettable(el, kAXSelectedTextRangeAttribute), BackgroundInput.isSettable(el, kAXSelectedTextAttribute) {
            let length = ((BackgroundInput.attribute(el, kAXValueAttribute) as String?) ?? "").utf16.count
            var range = CFRange(location: 0, length: length)
            if let all = AXValueCreate(.cfRange, &range) {
                AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, all)
            }
            if AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, value as CFString) == .success {
                return Result(content: "Replaced the text of \(name) in \(app) with \u{201C}\(clip(value, 60))\u{201D}.", isError: false,
                              summary: "Filled in \(name)", point: center(el))
            }
        }
        return Result(content: ok ? "Set \(name), but it didn't take the new value. Click it and type instead." : "\(name) can't be set directly. Click it and type instead.",
                      isError: true, point: center(el))
    }

    private func read(_ input: [String: Any]) -> Result {
        guard let (el, app) = element(input) else { return Self.missing }
        let value: String = BackgroundInput.attribute(el, kAXValueAttribute) ?? ""
        let title: String = BackgroundInput.attribute(el, kAXTitleAttribute) ?? ""
        let desc: String = BackgroundInput.attribute(el, kAXDescriptionAttribute) ?? ""
        let text = [value, title, desc].first { !$0.isEmpty } ?? ""
        let shown = text.count > 6000 ? text.prefix(6000) + "\n…(cut)" : Substring(text)
        return Result(content: shown.isEmpty ? "It has no text." : String(shown), isError: false,
                      summary: "Read \(BackgroundInput.describe(el)) in \(app)")
    }

    // MARK: Menus

    private func menu(_ input: [String: Any]) -> Result {
        let path = (input["path"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let app = resolveApp(input) else {
            return Result(content: "That app isn't running.", isError: true)
        }
        guard path.count >= 2 else {
            return Result(content: "menu needs a path such as [\"File\", \"Export…\"].", isError: true)
        }
        let ax = BackgroundInput.app(app.processIdentifier)
        guard let menuBar: AXUIElement = BackgroundInput.attribute(ax, kAXMenuBarAttribute) else {
            return Result(content: "\(app.localizedName ?? "That app") has no menu bar.", isError: true)
        }
        func norm(_ s: String) -> String {
            s.lowercased().replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        func children(_ el: AXUIElement) -> [AXUIElement] { BackgroundInput.attribute(el, kAXChildrenAttribute) ?? [] }
        // The menu bar holds menu bar items; each item, and each item with a
        // submenu, holds one AXMenu whose children are the items.
        var container = menuBar
        var item: AXUIElement?
        for (depth, step) in path.enumerated() {
            let items = children(container)
            let titles = items.map { (BackgroundInput.attribute($0, kAXTitleAttribute) as String?) ?? "" }
            guard let i = titles.firstIndex(where: { norm($0) == norm(step) })
                ?? titles.firstIndex(where: { norm($0).hasPrefix(norm(step)) })
            else {
                let options = titles.filter { !$0.isEmpty }.prefix(40).joined(separator: ", ")
                return Result(content: "No \u{201C}\(step)\u{201D} there. Available: \(options)", isError: true)
            }
            item = items[i]
            if depth < path.count - 1 {
                guard let sub = children(items[i]).first(where: { BackgroundInput.role($0) == kAXMenuRole }) else {
                    return Result(content: "\u{201C}\(titles[i])\u{201D} has no submenu.", isError: true)
                }
                container = sub
            }
        }
        guard let item else { return Result(content: "Nothing to choose.", isError: true) }
        if (BackgroundInput.attribute(item, kAXEnabledAttribute) as Bool?) == false {
            return Result(content: "\(path.joined(separator: " › ")) is greyed out right now.", isError: true)
        }
        guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else {
            return Result(content: "Couldn't choose \(path.joined(separator: " › ")).", isError: true)
        }
        let label = path.joined(separator: " › ")
        return Result(content: "Chose \(label) in \(app.localizedName ?? "the app").", isError: false, summary: "Chose \(label)")
    }
}
