import AppKit
import SceneKit
import SwiftUI

// MARK: - What a scene is

/// A 3D model Claude describes in a ```scene block: simple shapes the user
/// can turn, each with a label, some spinning or orbiting.
struct SceneSpec: Equatable {
    struct Object: Equatable {
        var id: String
        var shape: String
        var position: SCNVector3
        var size: [CGFloat]
        var radius: CGFloat
        var height: CGFloat
        var color: NSColor
        var opacity: CGFloat
        var label: String
        var spin: Bool
        var orbit: String
        var parent: String

        static func == (a: Object, b: Object) -> Bool {
            a.id == b.id && a.shape == b.shape && a.label == b.label && SCNVector3EqualToVector3(a.position, b.position)
        }
    }

    var title: String
    var objects: [Object]
    var links: [(String, String)]

    static func == (a: SceneSpec, b: SceneSpec) -> Bool {
        a.title == b.title && a.objects == b.objects && a.links.count == b.links.count
    }

    /// Lenient: anything missing gets a sensible default.
    static func parse(_ json: String) -> SceneSpec? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let list = obj["objects"] as? [[String: Any]], !list.isEmpty
        else { return nil }
        func num(_ v: Any?) -> CGFloat? { (v as? NSNumber).map { CGFloat($0.doubleValue) } }
        func nums(_ v: Any?) -> [CGFloat] { (v as? [Any])?.compactMap(num) ?? [] }
        var objects: [Object] = []
        for (i, o) in list.prefix(40).enumerated() {
            let p = nums(o["position"])
            objects.append(Object(
                id: (o["id"] as? String) ?? "part\(i)",
                shape: ((o["shape"] as? String) ?? "sphere").lowercased(),
                position: SCNVector3(p.count > 0 ? p[0] : 0, p.count > 1 ? p[1] : 0, p.count > 2 ? p[2] : 0),
                size: nums(o["size"]),
                radius: num(o["radius"]) ?? 0.5,
                height: num(o["height"]) ?? 1,
                color: NSColor(hex: o["color"] as? String ?? "") ?? Self.palette[i % Self.palette.count],
                opacity: min(max(num(o["opacity"]) ?? 1, 0.05), 1),
                label: o["label"] as? String ?? "",
                spin: o["spin"] as? Bool ?? false,
                orbit: o["orbit"] as? String ?? "",
                parent: o["parent"] as? String ?? ""))
        }
        let links = ((obj["links"] as? [[String: Any]]) ?? []).compactMap { l -> (String, String)? in
            guard let a = l["from"] as? String, let b = l["to"] as? String else { return nil }
            return (a, b)
        }
        return SceneSpec(title: obj["title"] as? String ?? "", objects: objects, links: links)
    }

    /// The bodies of the ```scene blocks finished so far in a streamed reply.
    static func blocks(in text: String) -> [String] {
        var out: [String] = []
        var body: [String]?
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if body != nil {
                if t.hasPrefix("```") {
                    out.append(body!.joined(separator: "\n"))
                    body = nil
                } else {
                    body!.append(line)
                }
            } else if t.lowercased().hasPrefix("```scene") {
                body = []
            }
        }
        return out
    }

    static let palette: [NSColor] = pilotRainbow.dropLast().map { NSColor($0) }
}

extension NSColor {
    /// "#ff7a59" or "ff7a59".
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}

// MARK: - Building it

/// A spec made into a lit SceneKit scene, with a camera framing all of it.
@MainActor
final class SceneModel {
    let spec: SceneSpec
    let scene = SCNScene()
    let camera = SCNNode()
    /// Turns slowly, so the model reads as 3D without touching it.
    let turntable = SCNNode()
    private(set) var nodes: [String: SCNNode] = [:]
    /// Where the camera looks, and how far away it sits.
    private(set) var center = SCNVector3Zero
    private(set) var radius: CGFloat = 1

    init(spec: SceneSpec, turning: Bool = true) {
        self.spec = spec
        scene.rootNode.addChildNode(turntable)
        for o in spec.objects {
            let node = SCNNode(geometry: Self.geometry(o))
            node.name = o.id
            node.position = o.position
            node.opacity = o.opacity
            if o.spin {
                node.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 6)))
            }
            nodes[o.id] = node
        }
        // Parents first, then orbits (on a pivot at what they circle).
        for o in spec.objects {
            guard let node = nodes[o.id] else { continue }
            if let parent = nodes[o.parent], parent !== node {
                parent.addChildNode(node)
            } else if let center = nodes[o.orbit], center !== node {
                let pivot = SCNNode()
                pivot.position = center.position
                node.position = SCNVector3(o.position.x - center.position.x, o.position.y - center.position.y,
                                           o.position.z - center.position.z)
                let distance = Double(hypot(node.position.x, node.position.z))
                pivot.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 3 + distance * 2.2)))
                pivot.addChildNode(node)
                turntable.addChildNode(pivot)
            } else {
                turntable.addChildNode(node)
            }
        }
        for (a, b) in spec.links {
            guard let p = nodes[a]?.worldPosition, let q = nodes[b]?.worldPosition else { continue }
            turntable.addChildNode(Self.line(from: p, to: q))
        }
        light()
        frame()
        if turning {
            turntable.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 48)))
        }
    }

    private static func geometry(_ o: SceneSpec.Object) -> SCNGeometry {
        let r = max(o.radius, 0.01), h = max(o.height, 0.01)
        let s = o.size.count >= 3 ? o.size : [r * 2, r * 2, r * 2]
        let g: SCNGeometry = switch o.shape {
        case "box", "cube": SCNBox(width: s[0], height: s[1], length: s[2], chamferRadius: min(s[0], s[1], s[2]) * 0.08)
        case "cylinder": SCNCylinder(radius: r, height: h)
        case "cone": SCNCone(topRadius: 0, bottomRadius: r, height: h)
        case "torus": SCNTorus(ringRadius: r, pipeRadius: max(r * 0.12, 0.01))
        case "ring": SCNTube(innerRadius: r * 0.94, outerRadius: r, height: max(r * 0.02, 0.005))
        case "capsule": SCNCapsule(capRadius: r, height: max(h, r * 2))
        case "pyramid": SCNPyramid(width: s[0], height: s[1], length: s[2])
        case "plane": SCNPlane(width: s[0], height: s[1])
        default:
            {
                let sphere = SCNSphere(radius: r)
                sphere.segmentCount = 72
                return sphere
            }()
        }
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = o.color
        m.roughness.contents = 0.38
        m.metalness.contents = 0.08
        m.isDoubleSided = o.shape == "plane" || o.shape == "ring"
        if o.opacity < 1 { m.transparencyMode = .dualLayer }
        g.materials = [m]
        return g
    }

    /// A thin glowing rod between two points.
    private static func line(from p: SCNVector3, to q: SCNVector3) -> SCNNode {
        let d = SCNVector3(q.x - p.x, q.y - p.y, q.z - p.z)
        let length = sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
        let rod = SCNCylinder(radius: 0.018, height: length)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor.white.withAlphaComponent(0.55)
        rod.materials = [m]
        let node = SCNNode(geometry: rod)
        node.position = SCNVector3((p.x + q.x) / 2, (p.y + q.y) / 2, (p.z + q.z) / 2)
        node.look(at: q, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 1, 0))
        return node
    }

    private func light() {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = 380
        let key = SCNNode()
        key.light = SCNLight()
        key.light!.type = .directional
        key.light!.intensity = 1100
        key.eulerAngles = SCNVector3(-0.7, 0.6, 0)
        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light!.type = .directional
        rim.light!.intensity = 520
        rim.light!.color = NSColor(red: 0.55, green: 0.7, blue: 1, alpha: 1)
        rim.eulerAngles = SCNVector3(0.4, .pi * 0.85, 0)
        for n in [ambient, key, rim] { scene.rootNode.addChildNode(n) }
    }

    /// Puts the camera where all of it fits, from a little above.
    private func frame() {
        let (c, r) = turntable.boundingSphere
        center = c
        radius = max(CGFloat(r), 0.2)
        camera.camera = SCNCamera()
        camera.camera!.fieldOfView = 38
        camera.camera!.zNear = 0.01
        camera.camera!.zFar = Double(radius) * 40
        camera.camera!.wantsHDR = true
        camera.camera!.bloomIntensity = 0.35
        let distance = radius * 3.0
        camera.position = SCNVector3(c.x + distance * 0.32, c.y + distance * 0.36, c.z + distance * 0.88)
        camera.look(at: c)
        scene.rootNode.addChildNode(camera)
    }

    /// Lights up one part, fades the rest back and swings the camera to it.
    func focus(_ id: String, animated: Bool = true) {
        guard let target = nodes[id] else { return }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated ? 0.9 : 0
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        for (key, node) in nodes {
            let spec = spec.objects.first { $0.id == key }
            node.opacity = key == id ? 1 : (spec?.opacity ?? 1) * 0.28
            node.geometry?.firstMaterial?.emission.contents = key == id
                ? (spec?.color ?? .white).withAlphaComponent(1).blended(withFraction: 0.78, of: .black)
                : NSColor.black
        }
        let p = target.presentation.worldPosition
        let r = max(CGFloat(target.boundingSphere.radius), radius * 0.18)
        // From the side the camera is on now (the user may have turned it).
        let from = camera.position
        var dir = SCNVector3(from.x - p.x, from.y - p.y, from.z - p.z)
        var len = sqrt(dir.x * dir.x + dir.y * dir.y + dir.z * dir.z)
        if len < 0.01 {
            dir = SCNVector3(0.32, 0.36, 0.88)
            len = sqrt(0.32 * 0.32 + 0.36 * 0.36 + 0.88 * 0.88)
        }
        dir = SCNVector3(dir.x / len, dir.y / len, dir.z / len)
        // Close enough to be about this part, far enough to keep its surroundings.
        let distance = max(r * 6.5, radius * 1.7)
        camera.position = SCNVector3(p.x + dir.x * distance, p.y + dir.y * distance, p.z + dir.z * distance)
        camera.look(at: p)
        SCNTransaction.commit()
    }

    /// Every part back to how it was.
    func unfocus() {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.6
        for (key, node) in nodes {
            node.opacity = spec.objects.first { $0.id == key }?.opacity ?? 1
            node.geometry?.firstMaterial?.emission.contents = NSColor.black
        }
        SCNTransaction.commit()
    }
}

// MARK: - The floating 3D view

@MainActor
final class SceneLabels: ObservableObject {
    struct Tag: Identifiable, Equatable {
        var id: String
        var text: String
        var at: CGPoint
        var lit: Bool
        var behind: Bool
    }

    @Published var tags: [Tag] = []
    @Published var title = ""
    @Published var shown = false
}

/// A floating glass window with a 3D model the user can turn with the
/// mouse. Labels ride on the parts; `focus` swings to one of them and the
/// buddy points at it.
@MainActor
final class SceneController: NSObject {
    static let size = CGSize(width: 560, height: 470)
    static let header: CGFloat = 52

    private var panel: NSPanel?
    private var view: SCNView?
    private var model: SceneModel?
    private let labels = SceneLabels()
    private var link: CADisplayLink?
    private var focused: String?
    private var keyMonitor: Any?

    var isOpen: Bool { panel?.isVisible == true }
    var windowNumber: Int? { isOpen ? panel?.windowNumber : nil }
    var spec: SceneSpec? { model?.spec }

    func show(_ spec: SceneSpec) {
        if spec == model?.spec, isOpen { return }
        let model = SceneModel(spec: spec)
        self.model = model
        focused = nil
        labels.title = spec.title
        if let view {
            view.scene = model.scene
            view.pointOfView = model.camera
            return
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let frame = CGRect(x: visible.maxX - Self.size.width - 28, y: visible.midY - Self.size.height / 2,
                           width: Self.size.width, height: Self.size.height)
        let panel = BoardPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = true

        let root = NSView(frame: CGRect(origin: .zero, size: Self.size))
        let chrome = NSHostingView(rootView: SceneChrome(labels: labels) { [weak self] in self?.close() })
        chrome.frame = root.bounds
        chrome.autoresizingMask = [.width, .height]
        root.addSubview(chrome)
        let scn = SCNView(frame: CGRect(x: 12, y: 12, width: Self.size.width - 24, height: Self.size.height - Self.header - 12))
        scn.backgroundColor = .clear
        scn.antialiasingMode = .multisampling4X
        scn.allowsCameraControl = true
        scn.scene = model.scene
        scn.pointOfView = model.camera
        scn.rendersContinuously = true
        scn.wantsLayer = true
        scn.layer?.cornerRadius = 18
        scn.layer?.masksToBounds = true
        root.addSubview(scn)
        let tags = PassThroughHostingView(rootView: SceneTagsView(labels: labels))
        tags.frame = scn.frame
        root.addSubview(tags)
        panel.contentView = root
        panel.applyRecordingVisibility()
        panel.orderFrontRegardless()
        self.panel = panel
        view = scn
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { labels.shown = true }
        let link = scn.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return } // Escape
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        guard let panel else { return }
        link?.invalidate()
        link = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        withAnimation(.easeIn(duration: 0.2)) { labels.shown = false }
        self.panel = nil
        view = nil
        model = nil
        Task {
            try? await Task.sleep(for: .seconds(0.25))
            panel.orderOut(nil)
        }
    }

    /// Turns to a part and lights it up; returns where it is on screen
    /// (global top-left) and its label, for the buddy to point at.
    func focus(_ id: String) async -> (CGPoint, String)? {
        guard let model, model.nodes[id] != nil else { return nil }
        model.turntable.removeAllActions()
        focused = id
        model.focus(id)
        try? await Task.sleep(for: .seconds(0.95))
        guard let view, let panel, let node = model.nodes[id] else { return nil }
        let p = view.projectPoint(node.presentation.worldPosition)
        let inWindow = view.convert(CGPoint(x: CGFloat(p.x), y: CGFloat(p.y)), to: nil)
        let onScreen = panel.convertPoint(toScreen: inWindow)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let label = model.spec.objects.first { $0.id == id }?.label ?? ""
        return (CGPoint(x: onScreen.x, y: primaryHeight - onScreen.y), label)
    }

    /// Keeps each label on its part as the model turns.
    @objc private func tick() {
        guard let view, let model else { return }
        var tags: [SceneLabels.Tag] = []
        for o in model.spec.objects where !o.label.isEmpty {
            guard let node = model.nodes[o.id] else { continue }
            let world = node.presentation.worldPosition
            let top = SCNVector3(world.x, world.y + CGFloat(node.boundingSphere.radius) * 1.15, world.z)
            let p = view.projectPoint(top)
            guard p.z > 0, p.z < 1 else { continue }
            // SceneKit's y goes up; SwiftUI's down.
            let at = CGPoint(x: CGFloat(p.x).rounded(), y: (view.bounds.height - CGFloat(p.y)).rounded())
            let behind = focused != nil && focused != o.id
            tags.append(.init(id: o.id, text: o.label, at: at, lit: focused == o.id, behind: behind))
        }
        if tags != labels.tags { labels.tags = tags }
    }
}

/// A hosting view the mouse goes through, for labels over the 3D view.
final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct SceneChrome: View {
    @ObservedObject var labels: SceneLabels
    var close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AngularGradient(colors: pilotRainbow, center: .center))
                Text(labels.title.isEmpty ? "3D view" : labels.title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                Text("Drag to turn")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 24, height: 24)
                        .background(.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .frame(height: SceneController.header)
            Spacer()
        }
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(RadialGradient(colors: [Color(white: 0.16).opacity(0.8), Color(white: 0.04).opacity(0.9)],
                                         center: .center, startRadius: 20, endRadius: 420))
                RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.12))
            }
            .shadow(color: .black.opacity(0.35), radius: 28, y: 12)
        }
        .environment(\.colorScheme, .dark)
        .scaleEffect(labels.shown ? 1 : 0.95)
        .opacity(labels.shown ? 1 : 0)
    }
}

private struct SceneTagsView: View {
    @ObservedObject var labels: SceneLabels

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(labels.tags) { tag in
                Text(tag.text)
                    .font(.system(size: tag.lit ? 12.5 : 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(tag.lit ? AnyShapeStyle(InkPalette.marker) : AnyShapeStyle(Color.black.opacity(0.55)),
                                in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(tag.lit ? 0 : 0.18)))
                    .fixedSize()
                    .opacity(tag.behind ? 0.35 : labels.shown ? 1 : 0)
                    .position(x: tag.at.x, y: tag.at.y - 10)
                    .animation(.easeOut(duration: 0.25), value: tag.lit)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - In the chat

/// A scene in the chat: a small model you can turn, and a button to open it
/// big next to your work.
struct SceneCard: View {
    let spec: SceneSpec
    @State private var model: SceneModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RadialGradient(colors: [Color(white: 0.17), Color(white: 0.05)], center: .center, startRadius: 10, endRadius: 260)
                if let model {
                    SceneView(scene: model.scene, pointOfView: model.camera,
                              options: [.allowsCameraControl, .rendersContinuously])
                }
            }
            .frame(height: 220)
            HStack {
                Image(systemName: "cube.transparent").foregroundStyle(.secondary)
                Text(spec.title.isEmpty ? "3D model" : spec.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Button("Open") { AppModel.shared.scenes.show(spec) }
                    .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.background.opacity(0.6))
        }
        .frame(width: 320)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.secondary.opacity(0.2)))
        .onAppear { if model == nil { model = SceneModel(spec: spec) } }
    }
}

/// Renders a scene still, for `-CPRenderScenePreview`.
@MainActor
enum ScenePreview {
    static let sample = """
    {"title": "Helium atom", "objects": [
      {"id": "nucleus", "shape": "sphere", "radius": 0.45, "color": "#ff7a59", "label": "Nucleus"},
      {"id": "p1", "shape": "sphere", "radius": 0.2, "position": [0.15, 0.1, 0.05], "color": "#ff5e7a", "parent": "nucleus"},
      {"id": "orbit1", "shape": "ring", "radius": 2.0, "color": "#5ac8fa", "opacity": 0.35},
      {"id": "orbit2", "shape": "torus", "radius": 1.4, "color": "#a78bfa", "opacity": 0.25},
      {"id": "e1", "shape": "sphere", "radius": 0.13, "position": [2, 0, 0], "color": "#5ac8fa", "label": "Electron", "orbit": "nucleus"},
      {"id": "e2", "shape": "sphere", "radius": 0.13, "position": [-1.4, 0, 0], "color": "#a78bfa", "label": "Electron", "orbit": "nucleus"}
    ]}
    """

    static func image(size: CGSize, focus: String?) -> CGImage? {
        guard let spec = SceneSpec.parse(sample) else { return nil }
        let model = SceneModel(spec: spec, turning: false)
        if let focus { model.focus(focus, animated: false) }
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        model.scene.background.contents = NSColor(white: 0.07, alpha: 1)
        renderer.scene = model.scene
        renderer.pointOfView = model.camera
        let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
