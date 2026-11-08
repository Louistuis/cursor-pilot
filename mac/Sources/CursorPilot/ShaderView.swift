import AppKit
import MetalKit
import SwiftUI

/// Which light effect a `ShaderCanvas` draws.
enum ShaderKind {
    case wave
    case fluidDots

    fileprivate var functionName: String {
        switch self {
        case .wave: "cp_wave"
        case .fluidDots: "cp_fluid_dots"
        }
    }
}

/// Inputs a `ShaderCanvas` can be driven by.
struct ShaderInputs: Equatable {
    /// 0...1 audio level (e.g. the microphone), or nil to animate on its own.
    var level: Float?
    var speed: Float = 1
    /// Above 1 shows the effect larger than its canvas, for small places.
    var zoom: Float = 1
    /// Colours the fluid dots (sRGB); zero leaves them white, a negative
    /// red makes them a rainbow.
    var tint: SIMD3<Float> = .zero
    /// 0...1: a soft dark shadow behind the fluid dots, for light backgrounds.
    var shadow: Float = 0
    /// Restarts the effect's clock at this time (seconds) whenever it
    /// changes, to play a chosen moment of it (the dots gathering, say).
    var clock: Float?
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
    var b: SIMD4<Float>
    var c: SIMD4<Float>
}

private final class ShaderRenderer: NSObject, MTKViewDelegate {
    let kind: ShaderKind
    var inputs: ShaderInputs {
        didSet {
            if let clock = inputs.clock, clock != oldValue.clock {
                start = CACurrentMediaTime() - Double(clock / max(inputs.speed, 0.01))
            }
        }
    }
    private var start = CACurrentMediaTime()
    private var last: CFTimeInterval = 0
    /// The level actually drawn, eased toward the input so the wave glides
    /// between the voice and its own motion instead of jumping.
    private var level: Float?

    /// What the wave draws at with no level, as a level.
    private static let ownLevel: Float = 0.8

    init(kind: ShaderKind, inputs: ShaderInputs) {
        self.kind = kind
        self.inputs = inputs
        if let clock = inputs.clock { start -= Double(clock / max(inputs.speed, 0.01)) }
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
        let dt = Float(last == 0 ? 0 : min(0.05, now - last))
        last = now
        let target = inputs.level ?? Self.ownLevel
        let eased = level.map { $0 + (target - $0) * (1 - exp(-dt * 10)) } ?? target
        level = eased
        let size = SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height))

        encoder.setRenderPipelineState(pipeline)
        var u = BasicUniforms(a: SIMD4(size.x, size.y, Float(now - start) * inputs.speed, eased),
                              b: SIMD4(max(inputs.zoom, 0.01), inputs.tint.x, inputs.tint.y, inputs.tint.z),
                              c: SIMD4(inputs.shadow, 0, 0, 0))
        encoder.setFragmentBytes(&u, length: MemoryLayout<BasicUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

// MARK: - Ready-made visuals

/// Merging dots, shown while Cursor Pilot is thinking.
struct ThinkingBlobs: View {
    var zoom: Float = 1
    var tint: SIMD3<Float> = .zero
    var shadow: Float = 0
    var clock: Float?
    var body: some View {
        ShaderCanvas(kind: .fluidDots, inputs: ShaderInputs(zoom: zoom, tint: tint, shadow: shadow, clock: clock))
            .aspectRatio(1, contentMode: .fit)
    }
}

/// Chromatic waveform, shown while Cursor Pilot is speaking, or following
/// the microphone while listening.
struct SpeakingWave: View {
    var level: Float?
    var body: some View {
        ShaderCanvas(kind: .wave, inputs: ShaderInputs(level: level))
    }
}

/// An effect on its own black tile, for light backgrounds: the light adds
/// to what is behind it, so it needs the dark to show.
struct ShaderTile<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .background(.black)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// Every effect side by side; opened with `-CPShaderGallery YES` for design work.
struct ShaderGallery: View {
    var body: some View {
        HStack(spacing: 20) {
            tile("Thinking") { ThinkingBlobs() }
            tile("Speaking") { SpeakingWave() }
            tile("Listening, quiet") { SpeakingWave(level: 0.1) }
            tile("Listening, loud") { SpeakingWave(level: 0.9) }
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
