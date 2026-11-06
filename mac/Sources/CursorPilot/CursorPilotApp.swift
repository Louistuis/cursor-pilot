import AppKit
import SwiftUI

@main
struct CursorPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.phase == .idle ? "cursorarrow.rays"
                  : model.backgroundWork ? "terminal" : "cursorarrow.motionlines")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            if let path = UserDefaults.standard.string(forKey: "CPRenderInkPreview") {
                let renderer = ImageRenderer(content: InkPreview())
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                }
                NSApp.terminate(nil)
                return
            }
            if let path = UserDefaults.standard.string(forKey: "CPRenderArrowPreview") {
                let view = HStack(spacing: 40) {
                    PilotArrow(flipped: false).scaleEffect(6).frame(width: 200, height: 220)
                    HStack(spacing: 24) {
                        PilotArrow(flipped: false)
                        PilotArrow(flipped: true)
                    }
                    .padding(30)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(40)
                .background(Color(white: 0.16))
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let image = renderer.cgImage,
                   let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                }
                NSApp.terminate(nil)
                return
            }
            // `-CPRenderTrailPreview out.png`: the buddy at rest and moving
            // ever faster, then its click ring, in each colour.
            if let path = UserDefaults.standard.string(forKey: "CPRenderTrailPreview") {
                let speeds: [CGVector] = [.zero, CGVector(dx: 600, dy: 250), CGVector(dx: 1500, dy: 600),
                                          CGVector(dx: 2600, dy: -900)]
                let view = VStack(alignment: .leading, spacing: 10) {
                    ForEach(BuddyTint.allCases) { tint in
                        HStack(spacing: 0) {
                            ForEach(speeds.indices, id: \.self) { i in
                                ZStack(alignment: .topLeading) {
                                    MotionTrail(motion: speeds[i], flipped: false, tint: tint)
                                    PilotArrow(flipped: false, active: i > 0, tint: tint)
                                }
                                .frame(width: 20, height: 23)
                                .scaleEffect(2.2)
                                .frame(width: 150, height: 70)
                            }
                            ClickRing(at: Date().addingTimeInterval(-0.12), tint: tint)
                                .scaleEffect(2)
                                .frame(width: 150, height: 70)
                        }
                    }
                }
                .padding(30)
                .background(Color(white: 0.2))
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let image = renderer.cgImage,
                   let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                }
                NSApp.terminate(nil)
                return
            }
            // `-CPRenderCaptionPreview out.png`: the read-along caption at a
            // few points of a long sentence.
            if let path = UserDefaults.standard.string(forKey: "CPRenderCaptionPreview") {
                let sentence = "Open the File menu, choose Export as PDF, then pick the Desktop folder and press Save to finish."
                let ns = sentence as NSString
                let view = VStack(alignment: .leading, spacing: 16) {
                    ForEach(["File", "PDF,", "Desktop", "finish."], id: \.self) { word in
                        KaraokeCaption(spoken: SpokenWord(sentence: sentence, word: ns.range(of: word)))
                            .padding(.horizontal, 13).padding(.vertical, 9)
                            .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                .padding(24)
                .background(Color(white: 0.3))
                .environment(\.colorScheme, .dark)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let image = renderer.cgImage,
                   let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                }
                NSApp.terminate(nil)
                return
            }
            // `-CPRenderHelperPreview out.png`: each helper's cursor at work,
            // one finished and one near the right edge.
            if let path = UserDefaults.standard.string(forKey: "CPRenderHelperPreview") {
                let steps = ["Opened Safari", "Reading the timetable", "Filled in a field in Numbers",
                             "Searching for hotels in Bergen", "Done"]
                let view = VStack(alignment: .leading, spacing: 0) {
                    ForEach(helperNames.indices, id: \.self) { i in
                        let state = HelperCursorState(name: helperNames[i], status: steps[i])
                        let _ = { if i == 4 { state.finished = true }; if i == 3 { state.flipped = true } }()
                        HelperCursorView(state: state)
                            .frame(width: HelperLayout.size.width, height: 70, alignment: .topLeading)
                    }
                }
                .background(Color(white: 0.55))
                .environment(\.colorScheme, .dark)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let image = renderer.cgImage,
                   let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                }
                NSApp.terminate(nil)
                return
            }
            if let path = UserDefaults.standard.string(forKey: "CPRenderGlowPreview") {
                let size = CGSize(width: 1512, height: 982)
                for mode in [GlowController.Mode.listening, .thinking, .sketching] {
                    let file = path.replacingOccurrences(of: ".png", with: "-\(mode).png")
                    if let image = GlowController.preview(size: size, mode: mode),
                       let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: file))
                    }
                }
                NSApp.terminate(nil)
                return
            }
            let model = AppModel.shared
            model.start()
            Task {
                if await TestHooks.run() {
                    NSApp.terminate(nil)
                    return
                }
                await model.loadAPIKey()
                // The menu bar icon is easy to miss (or hidden by the notch),
                // so first run walks through setup and a missing key opens Home.
                if !UserDefaults.standard.bool(forKey: "onboarded") {
                    OnboardingWindow.shared.show()
                } else if !model.hasAPIKey {
                    HomeWindow.shared.show()
                }
                // `-CPAsk "question"` asks a typed question at launch (for testing the agent).
                if let question = UserDefaults.standard.string(forKey: "CPAsk"), !question.isEmpty {
                    await model.ask(question, includeScreen: false)
                }
            }
            // `-CPBuddyDemo listening|thinking|answering` holds the buddy in that state (for UI work).
            if let demo = UserDefaults.standard.string(forKey: "CPBuddyDemo") {
                let buddy = model.overlay
                buddy.autoHide = false
                switch demo {
                case "listening":
                    buddy.state.mode = .listening
                    buddy.state.level = 0.6
                    buddy.state.caption = "What does this button do?"
                case "thinking":
                    buddy.state.mode = .thinking
                case _:
                    buddy.state.mode = .answering
                    buddy.state.caption = "That's the export button. Click it, then pick PDF in the menu that opens."
                }
            }
            // `-CPOpenHome settings|drawings|chat` opens Home on that page (for UI work).
            switch UserDefaults.standard.string(forKey: "CPOpenHome") {
            case "settings": HomeWindow.shared.show(.settings)
            case "drawings": HomeWindow.shared.show(.drawings)
            case "chat": HomeWindow.shared.show()
            default: break
            }
            if UserDefaults.standard.bool(forKey: "CPShaderGallery") {
                let w = NSWindow(contentViewController: NSHostingController(rootView: ShaderGallery()))
                w.title = "Shader Gallery"
                w.isReleasedWhenClosed = false
                w.center()
                w.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Opening the app again (Finder, Spotlight, `open`) brings up Home.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { HomeWindow.shared.show() }
        return true
    }
}

/// The Home window, owned here rather than as a SwiftUI scene so the app can
/// open it from anywhere. While it is open Cursor Pilot is a regular app
/// (Dock icon, ⌘-Tab); when it closes it goes back to living in the menu bar.
@MainActor
final class HomeWindow: NSObject, NSWindowDelegate {
    static let shared = HomeWindow()
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    func show(_ destination: HomeDestination? = nil) {
        if let destination { HomeNavigation.shared.destination = destination }
        if window == nil {
            let host = NSHostingController(rootView: HomeView(model: .shared))
            host.sceneBridgingOptions = [.toolbars, .title]
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.toolbarStyle = .unified
            w.title = "Cursor Pilot"
            w.setContentSize(NSSize(width: 980, height: 660))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            w.setFrameAutosaveName("CursorPilotHome")
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

private struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Button("Open Cursor Pilot") { HomeWindow.shared.show() }
        .keyboardShortcut("o")
        Button("Ask About My Screen") {
            Task { await model.ask("", includeScreen: true) }
        }
        if model.phase != .idle {
            Button("Stop") { model.interrupt() }
        }
        Button("Draw on Screen (⌃⌥D)") { model.toggleSketch() }
        Button("New Chat") {
            model.newConversation()
            HomeWindow.shared.show(.chat(model.currentConversationID))
        }
        Divider()
        Text("Hold \(model.talkDisplay) to talk")
        Button("Settings…") { HomeWindow.shared.show(.settings) }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Cursor Pilot") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
