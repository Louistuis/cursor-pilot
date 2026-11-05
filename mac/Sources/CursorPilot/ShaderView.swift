import AppKit
import MetalKit
import SwiftUI

/// Which light effect a `ShaderCanvas` draws.
enum ShaderKind {
    case wave
    case fluidDots
    case strands

    fileprivate var functionName: String {
        switch self {
        case .wave: "cp_wave"
        case .fluidDots: "cp_fluid_dots"
        case .strands: "cp_strands"
        }
    }
}

/// Inputs a `ShaderCanvas` can be driven by. Unused fields are ignored by
/// effects that do not need them.
struct ShaderInputs: Equatable {
    /// 0...1 audio level (e.g. the microphone), or nil to animate on its own.
    var level: Float?
    /// Strands: simulate someone speaking when no level is given.
    var listening = false
    /// Strands: baseline liveliness, 0 (calm white line) ... 1.
    var energy: Float = 0.65
    /// Strands: draw the glass orb, or the ribbon of light on its own.
    var glass = true
    /// Strands: frosted white glass for light backgrounds.
    var lightMode = false
    /// Strands: how many light ribbons show, 1...3.
    var count = 3
    var speed: Float = 1
    var intensity: Float = 1
    /// Strands: fade and unfold when it first appears.
    var intro = true
}

/// A SwiftUI view that renders one of the light effects with Metal.
struct ShaderCanvas: NSViewRepresentable {
    var kind: ShaderKind
    var inputs = ShaderInputs()
    /// Fraction of the backing resolution to render at; lower is cheaper.
    var renderScale: CGFloat = 1

    func makeNSView(context: Context) -> ShaderMTKView {
        ShaderMTKView(kind: kind, inputs: inputs, renderScale: renderScale)
    }

    func updateNSView(_ view: ShaderMTKView, context: Context) {
        view.renderer?.inputs = inputs
    }
}

final class ShaderMTKView: MTKView {
    fileprivate var renderer: ShaderRenderer?
    private let renderScale: CGFloat

    init(kind: ShaderKind, inputs: ShaderInputs, renderScale: CGFloat) {
        self.renderScale = renderScale
        super.init(frame: .zero, device: ShaderPipelines.shared?.device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        framebufferOnly = true
        preferredFramesPerSecond = 60
        layer?.isOpaque = false
        renderer = ShaderRenderer(kind: kind, inputs: inputs)
        delegate = renderer
        isPaused = true
        enableSetNeedsDisplay = false
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateScale()
        // Only animate while on screen.
        isPaused = window == nil
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
    }

    private func updateScale() {
        layer?.contentsScale = (window?.backingScaleFactor ?? 2) * renderScale
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Compiles the shader library once and caches one pipeline per effect.
final class ShaderPipelines {
    static let shared = ShaderPipelines()

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let library: MTLLibrary
    private var pipelines: [String: MTLRenderPipelineState] = [:]

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        do {
            library = try device.makeLibrary(source: shaderSource, options: nil)
        } catch {
            NSLog("Cursor Pilot: shader compile failed: \(error)")
            return nil
        }
        self.device = device
        self.queue = queue
    }

    func pipeline(for kind: ShaderKind) -> MTLRenderPipelineState? {
        if let p = pipelines[kind.functionName] { return p }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "cp_fullscreen")
        desc.fragmentFunction = library.makeFunction(name: kind.functionName)
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        let p = try? device.makeRenderPipelineState(descriptor: desc)
        pipelines[kind.functionName] = p
        return p
    }
}

// MARK: - Renderer

private struct BasicUniforms {
    var a: SIMD4<Float>
}

private struct StrandsUniforms {
    var u0, u1, u2, u3, u4, u5, u6: SIMD4<Float>
    var colors: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                 SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
}

private final class ShaderRenderer: NSObject, MTKViewDelegate {
    let kind: ShaderKind
    var inputs: ShaderInputs
    private let start = CACurrentMediaTime()
    private var last: CFTimeInterval = 0
    private var strands = StrandsMotion()

    init(kind: ShaderKind, inputs: ShaderInputs) {
        self.kind = kind
        self.inputs = inputs
        if !inputs.intro { strands.intro = 1 }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let shared = ShaderPipelines.shared,
              let pipeline = shared.pipeline(for: kind),
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = shared.queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        let now = CACurrentMediaTime()
        let dt = last == 0 ? 0 : min(0.05, now - last)
        last = now
        let size = SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height))

        encoder.setRenderPipelineState(pipeline)
        switch kind {
        case .wave, .fluidDots:
            var u = BasicUniforms(a: SIMD4(size.x, size.y, Float(now - start) * inputs.speed, inputs.level ?? -1))
            encoder.setFragmentBytes(&u, length: MemoryLayout<BasicUniforms>.stride, index: 0)
        case .strands:
            strands.step(dt: Float(dt), inputs: inputs)
            var u = strands.uniforms(size: size, inputs: inputs)
            encoder.setFragmentBytes(&u, length: MemoryLayout<StrandsUniforms>.stride, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

/// The animation state the Strands effect keeps between frames: how lively
/// it is, a slowly advancing clock, and the intro fade.
private struct StrandsMotion {
    var clock: Float = 0
    var pace: Float = 0
    var activity: Float = 0
    var speechT: Float = 0
    var introT: Float = 0
    var intro: Float = 0

    static let defaultColors = ["#d95b56", "#ba5046", "#ffa24c", "#ffe0b3", "#93f1ff", "#3569fa", "#193d9b"]
    static let palette: [SIMD4<Float>] = {
        let rgb = defaultColors.map(hexToRGB)
        return (0..<8).map { i in i < rgb.count ? SIMD4(rgb[i], 1) : SIMD4(1, 1, 1, 1) }
    }()

    mutating func step(dt: Float, inputs: ShaderInputs) {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if inputs.intro && !reduced {
            introT = min(1, introT + dt / 1.4)
            intro = 1 - pow(1 - introT, 3)
        } else {
            intro = 1
        }
        if inputs.listening && !reduced { speechT += dt }
        let voice: Float = inputs.level.map { min(max($0, 0), 1) }
            ?? (inputs.listening && !reduced ? Self.speech(speechT) : 0)
        let target = min(1.2, max(min(max(inputs.energy, 0), 1), voice))
        activity += (target - activity) * (1 - exp(-dt / (target > activity ? 0.12 : 0.4)))
        pace += (min(1, activity) - pace) * (1 - exp(-dt / 0.8))
        if !reduced { clock += dt * inputs.speed * (0.6 + 1.6 * pace) }
    }

    func uniforms(size: SIMD2<Float>, inputs: ShaderInputs) -> StrandsUniforms {
        let c = clock
        let sway = 0.75 + 0.45 * pace
        let motion = SIMD3<Float>(
            (0.26 * sin(0.53 * c) + 0.1 * sin(1.19 * c + 1.3)) * sway,
            1 + (0.06 * sin(0.71 * c) + 0.035 * sin(1.37 * c + 0.4)) * sway,
            0.06 * sin(0.41 * c + 2) * sway
        )
        let p = Self.palette
        return StrandsUniforms(
            u0: SIMD4(size.x, size.y, min(max(activity, 0), 1), Float(min(max(inputs.count, 1), 3))),
            u1: SIMD4(motion, 1),                        // amplitude
            u2: SIMD4(1, 1, 1, 1),                       // waviness, thickness, glow, taper
            u3: SIMD4(1, 0, inputs.intensity, 1),        // spread, hueShift, intensity, saturation
            u4: SIMD4(1, inputs.glass ? 1 : 0, 0.42, 1), // scale, glass, radius, refraction
            u5: SIMD4(1, 1, 0, 0),                       // dispersion, rim, lean
            u6: SIMD4(intro, 0, inputs.lightMode ? 1 : 0, 1), // intro, pulse, light, opacity
            colors: (p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7])
        )
    }

    /// A made-up speech envelope: phrases, syllables and stress.
    static func speech(_ t: Float) -> Float {
        func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float {
            let k = min(1, max(0, (x - a) / (b - a)))
            return k * k * (3 - 2 * k)
        }
        let phrase = smooth(-0.8, -0.3, 0.6 * sin(t * 2.7) + 0.5 * sin(t * 1.53 + 1.2))
        let syllable = max(0, sin(t * 17 + 1.6 * sin(t * 5.3)))
        let stress = 0.6 + 0.4 * sin(t * 3.7 + 0.7)
        return phrase * (0.35 + 0.65 * syllable) * (0.25 + stress)
    }

    private static func hexToRGB(_ hex: String) -> SIMD3<Float> {
        let v = UInt32(hex.dropFirst(), radix: 16) ?? 0xFFFFFF
        return SIMD3(Float((v >> 16) & 255), Float((v >> 8) & 255), Float(v & 255)) / 255
    }
}

// MARK: - Ready-made visuals

/// Glass orb whose light follows a voice level.
struct VoiceOrb: View {
    var level: Float?
    var listening = false
    var energy: Float = 0.65
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ShaderCanvas(kind: .strands,
                     inputs: ShaderInputs(level: level, listening: listening, energy: energy,
                                          lightMode: scheme == .light))
            .aspectRatio(1, contentMode: .fit)
    }
}

/// Merging dots, shown while Cursor Pilot is thinking.
struct ThinkingBlobs: View {
    var body: some View {
        ShaderCanvas(kind: .fluidDots).aspectRatio(1, contentMode: .fit)
    }
}

/// Chromatic waveform, shown while Cursor Pilot is speaking.
struct SpeakingWave: View {
    var level: Float?
    var body: some View {
        ShaderCanvas(kind: .wave, inputs: ShaderInputs(level: level))
    }
}

/// Every effect side by side; opened with `-CPShaderGallery YES` for design work.
struct ShaderGallery: View {
    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 20) {
                tile("Voice orb") { VoiceOrb(listening: true) }
                tile("Thinking") { ThinkingBlobs() }
                tile("Speaking") { SpeakingWave() }
            }
            HStack(spacing: 20) {
                tile("Speaking, mic level") { SpeakingWave(level: 0.8) }
                tile("Orb, light glass") { VoiceOrb(energy: 0.8).environment(\.colorScheme, .light) }
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .padding(24)
        .background(Color(red: 0.04, green: 0.04, blue: 0.05))
    }

    private func tile<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack {
            content().frame(width: 200, height: 200)
            Text(title).font(.caption).foregroundStyle(.gray)
        }
    }
}
