import AppKit
import SwiftUI

/// First-run setup: what Cursor Pilot is, the API key, permissions, and a
/// first question.
@MainActor
final class OnboardingWindow {
    static let shared = OnboardingWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let view = OnboardingView(model: .shared) { [weak self] in self?.finish() }
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "onboarded")
        window?.close()
        window = nil
    }
}

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    var onFinish: () -> Void

    enum Step: Int, CaseIterable { case welcome, key, permissions, access, tryIt }
    @State private var step = Step.welcome
    @State private var keyDraft = ""
    @State private var accessChoice = "on"
    @State private var consented = false
    @State private var permissions = PermissionStatus.current()
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .key: keyStep
                case .permissions: permissionsStep
                case .access: accessStep
                case .tryIt: tryIt
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)
            .padding(.top, 36)

            HStack {
                HStack(spacing: 6) {
                    ForEach(Step.allCases, id: \.self) { s in
                        Capsule()
                            .fill(s == step ? pilotAccent : Color.secondary.opacity(0.3))
                            .frame(width: s == step ? 18 : 6, height: 6)
                    }
                }
                Spacer()
                if step != .welcome {
                    Button("Back") { move(-1) }
                }
                Button(step == .tryIt ? "Done" : "Continue") {
                    step == .tryIt ? onFinish() : move(1)
                }
                .keyboardShortcut(.defaultAction)
                .disabled((step == .key && !model.hasAPIKey) || (step == .access && accessChoice != "off" && !consented))
            }
            .padding(20)
        }
        .frame(width: 580, height: 520)
        .animation(.easeInOut(duration: 0.2), value: step)
        .onReceive(refresh) { _ in
            if step == .permissions { permissions = .current() }
        }
    }

    private func move(_ delta: Int) {
        if step == .access && delta > 0 { model.macAccess = accessChoice == "on" }
        step = Step(rawValue: step.rawValue + delta) ?? step
    }

    private var accessStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Let it work on your Mac").font(.title.bold())
            Text("Cursor Pilot can do things for you, not just explain them: run commands, edit files, script apps, and click and type when it has to.")
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                AccessCard(id: "on", title: "Work on My Mac", subtitle: "Recommended. Works in the background with no prompts and says what it's doing.",
                           icon: "bolt", choice: $accessChoice)
                AccessCard(id: "off", title: "Just Talk", subtitle: "Answers and points, but doesn't touch your Mac.",
                           icon: "bubble.left", choice: $accessChoice)
            }
            if accessChoice != "off" {
                Toggle(isOn: $consented) {
                    Text("I understand Cursor Pilot runs commands, changes files and uses my mouse and keyboard on its own, without asking each time.")
                        .font(.callout)
                }
                .toggleStyle(.checkbox)
                HStack {
                    Text(ComputerControl.hasAccessibility ? "Mouse and keyboard: allowed" : "For the mouse and keyboard, macOS also needs Accessibility access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !ComputerControl.hasAccessibility {
                        Button("Allow…") { Permissions.openAccessibility() }.controlSize(.small)
                    }
                }
            }
            Spacer()
        }
        .animation(.easeInOut(duration: 0.2), value: accessChoice)
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            ShaderTile { SpeakingWave() }.frame(width: 150, height: 150)
            Text("Meet Cursor Pilot").font(.largeTitle.bold())
            Text("A helper that lives next to your cursor. Ask out loud about anything on your screen, and it answers, then flies over to point at what you need.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }

    private var keyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect Claude").font(.title.bold())
            Text("Cursor Pilot uses your own Anthropic API key. It is kept in your keychain and only sent to api.anthropic.com.")
                .foregroundStyle(.secondary)
            HStack {
                SecureField("sk-ant-…", text: $keyDraft).textFieldStyle(.roundedBorder)
                Button("Save") {
                    model.apiKey = keyDraft
                    keyDraft = ""
                }
                .disabled(keyDraft.isEmpty)
            }
            if model.hasAPIKey {
                Label("Key saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Link("Create a key in the Anthropic Console →",
                 destination: URL(string: "https://console.anthropic.com/settings/keys")!)
            Spacer()
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Let it listen and look").font(.title.bold())
            Text("Cursor Pilot only listens while you hold the shortcut, and only looks at your screen when you ask something.")
                .foregroundStyle(.secondary)
            if !permissions.everything {
                Button {
                    Task { await Permissions.requestAll(); permissions = .current() }
                } label: {
                    Label("Allow Everything", systemImage: "checkmark.shield").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
            Form {
                PermissionRow(name: "Microphone & Speech", granted: permissions.microphone && permissions.speech) {
                    Task { _ = await VoiceInput.requestPermissions(); permissions = .current() }
                }
                PermissionRow(name: "Screen Recording", granted: permissions.screen) {
                    Permissions.openScreenRecording()
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            if !permissions.screen {
                HStack {
                    Text("Switched on Screen Recording? macOS applies it after a restart.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart Cursor Pilot") { Permissions.relaunch() }.controlSize(.small)
                }
            }
            Spacer()
        }
    }

    private var tryIt: some View {
        VStack(spacing: 16) {
            Text("Try it").font(.title.bold())
            Text("Hold \(model.talkDisplay), ask \u{201C}What am I looking at?\u{201D}, then let go.")
                .multilineTextAlignment(.center)
            TryItOrb(model: model, buddy: model.overlay.state).frame(width: 110, height: 110)
            Text(tryItStatus).foregroundStyle(.secondary)
            if !model.replyText.isEmpty {
                ScrollView {
                    Text(model.replyText).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            Text("You can also hover over the notch at the top of the screen to type a question.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var tryItStatus: String {
        switch model.phase {
        case .idle: model.replyText.isEmpty ? "Waiting for you…" : "Nice. That's all there is to it."
        case .listening: "Listening…"
        case .thinking: "Looking at your screen…"
        case .answering: "Answering…"
        }
    }
}

private struct AccessCard: View {
    var id: String
    var title: String
    var subtitle: String
    var icon: String
    @Binding var choice: String

    var body: some View {
        let selected = choice == id
        Button { choice = id } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .foregroundStyle(selected ? Color.white : pilotAccent)
                    .background(selected ? pilotAccent : pilotAccent.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? pilotAccent : Color.secondary.opacity(0.5))
            }
            .padding(10)
            .contentShape(Rectangle())
            .background(selected ? pilotAccent.opacity(0.10) : Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? pilotAccent.opacity(0.6) : Color.clear))
        }
        .buttonStyle(.plain)
    }
}

/// The wave following the microphone while the user talks, then the dots
/// while Cursor Pilot thinks.
private struct TryItOrb: View {
    @ObservedObject var model: AppModel
    @ObservedObject var buddy: OverlayState

    var body: some View {
        ShaderTile {
            ZStack {
                if model.phase == .thinking {
                    ThinkingBlobs(zoom: 1.6).transition(.opacity.combined(with: .scale(scale: 0.85)))
                } else {
                    SpeakingWave(level: model.phase == .listening ? buddy.level
                                      : model.phase == .idle ? 0.15 : nil)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .animation(.easeInOut(duration: 0.4), value: model.phase == .thinking)
        }
    }
}
