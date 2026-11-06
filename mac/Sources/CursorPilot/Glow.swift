import AppKit
import Metal
import QuartzCore

/// What the glow frame looks like this frame. Points, in the view's flipped (top-left) space.
struct GlowState {
    var rect: CGRect
    var radii: (tl: CGFloat, tr: CGFloat, br: CGFloat, bl: CGFloat)
    var gain: Float = 1      // overall light
    var fill: Float = 0      // black body inside the frame (the island)
    var outer: Float = 0.35  // halo outside the frame
    var rot: Float = 0       // colours turning around the perimeter, 0..4 per turn
    /// The camera notch or the island grown out of it, relative to `rect`:
    /// the frame bends around it instead of running behind it.
    var notch: CGRect?
    /// Radius of the cutout's bottom corners.
    var notchRadius: CGFloat = 12
}

/// The neon edge frame from Zero OCR (MIT, Louis Nordbø), drawn with Metal over the whole screen.
///
/// The light model follows the Neon Hello frame: for every pixel inside the box, each of the four
/// edges adds a bright inner line and two wider falloffs, coloured by 16 stops around the
/// perimeter, and the sum is tone mapped with 1 - exp(-light) so the edges burn toward white.
/// Outside the box a soft halo continues the nearest edge's colour, and `fill` turns the inside
/// into a black body so the same frame can be the notch island. Output is premultiplied light,
/// so it adds to whatever is on screen.
final class GlowView: NSView {
    var state: GlowState?

    private let metal = CAMetalLayer()
    /// On Intel Macs with two GPUs, the integrated one, so the neon never wakes the discrete GPU.
    private static let device: MTLDevice? = {
        #if arch(x86_64)
        if let low = MTLCopyAllDevices().first(where: \.isLowPower) { return low }
        #endif
        return MTLCreateSystemDefaultDevice()
    }()
    private static let pipeline: MTLRenderPipelineState? = {
        guard let device, let lib = try? device.makeLibrary(source: shader, options: nil) else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "vmain")
        d.fragmentFunction = lib.makeFunction(name: "fmain")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: d)
    }()
    private static let queue = device?.makeCommandQueue()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        metal.device = GlowView.device
        metal.pixelFormat = .bgra8Unorm
        metal.isOpaque = false
        metal.framebufferOnly = true
        metal.presentsWithTransaction = false
        layer = metal
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        resize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resize()
    }

    /// Intel Macs draw at 1x: the glow is soft light, and it is a quarter of the pixels.
    private var scale: CGFloat {
        #if arch(x86_64)
        return 1
        #else
        return window?.backingScaleFactor ?? 2
        #endif
    }

    private func resize() {
        metal.contentsScale = scale
        metal.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    func render() {
        guard let queue = GlowView.queue, let drawable = metal.nextDrawable(),
              let cmd = queue.makeCommandBuffer() else { return }
        GlowView.encode(state, scale: Float(scale), into: drawable.texture, cmd: cmd)
        cmd.present(drawable)
        cmd.commit()
    }

    /// Draws one frame off screen, for `-CPRenderGlowPreview`. `size` is in points.
    static func image(of state: GlowState, size: CGSize, scale: CGFloat = 2) -> CGImage? {
        guard let device, let queue, let cmd = queue.makeCommandBuffer() else { return nil }
        let w = Int(size.width * scale), h = Int(size.height * scale)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: d) else { return nil }
        encode(state, scale: Float(scale), into: texture, cmd: cmd)
        cmd.commit()
        cmd.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info.rawValue) else { return nil }
        return ctx.makeImage()
    }

    private static func encode(_ state: GlowState?, scale k: Float, into texture: MTLTexture, cmd: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        if let pipeline, let s = state, s.gain > 0.001 || s.fill > 0.001,
           let enc = cmd.makeRenderCommandEncoder(descriptor: pass) {
            let area = Float(max(s.rect.width * s.rect.height, 1))
            let fk = min(1.3, max(0.28, (area / (736 * 414)).squareRoot()))
            var u: [Float] = [
                Float(texture.width), Float(texture.height),
                Float(s.rect.minX) * k, Float(s.rect.minY) * k, Float(s.rect.width) * k, Float(s.rect.height) * k,
                Float(s.radii.tl), Float(s.radii.tr), Float(s.radii.br), Float(s.radii.bl),
                s.rot, s.gain, s.fill, k, fk, s.outer,
                Float(s.notch?.minX ?? 0), Float(s.notch?.minY ?? 0),
                Float(s.notch?.width ?? 0), Float(s.notch?.height ?? 0), Float(s.notchRadius),
            ]
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentBytes(&u, length: u.count * 4, index: 0)
            var near = GlowView.near, far = GlowView.far
            enc.setFragmentBytes(&near, length: near.count * 4, index: 1)
            enc.setFragmentBytes(&far, length: far.count * 4, index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        } else {
            cmd.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
    }

    // Per perimeter stop (clockwise from the top left corner): light of the bright inner edge and of
    // the wide falloff, as fitted to the Neon Hello reference frame.
    private static let near: [Float] = [0.258, 0.071, 1.701, 0.376, 0.343, 1.939, 0.241, 0.847, 1.322, 0.373, 1.388, 2.261,
                                        0.32, 0.848, 1.213, 0.372, 1.192, 1.557, 0.223, 0.909, 1.847, 0.353, 0.3, 2.404,
                                        0.496, 0.172, 1.566, 1.198, 0.305, 0.463, 1.073, 0.968, 0.174, 1.354, 1.019, 0.291,
                                        0.785, 0.586, 0.096, 1.285, 1.079, 0.231, 1.212, 0.433, 0.642, 0.722, 0.151, 1.718]
    private static let far: [Float] = [0.61, 0.242, 1.219, 0.246, 0.279, 1.033, 0.155, 0.503, 1.166, 0.257, 1.041, 1.446,
                                       0.284, 0.949, 1.3, 0.166, 0.304, 0.828, 0.133, 0.289, 0.87, 0.2, 0.202, 0.986,
                                       0.453, 0.166, 1.063, 0.649, 0.21, 0.29, 0.931, 0.304, 0.113, 1.476, 0.533, 0.126,
                                       1.217, 0.456, 0.14, 0.974, 0.189, 0.256, 0.989, 0.303, 0.53, 0.713, 0.23, 0.645]

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 pos [[position]]; };

    vertex VOut vmain(uint vid [[vertex_id]]) {
        float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        VOut o;
        o.pos = float4(p[vid], 0, 1);
        return o;
    }

    // Edge profile in points: inner line gain and decay, falloff gain and decay, wash gain and decay.
    constant float P[6] = { 3.3614, 5.07, 1.3328, 24.0, 0.1, 63.0 };

    float3 stopAt(constant float *a, int i) {
        i = ((i % 16) + 16) % 16;
        return float3(a[i * 3], a[i * 3 + 1], a[i * 3 + 2]);
    }

    // Cyclic Catmull-Rom weights.
    float4 crw(float u) {
        float u2 = u * u, u3 = u2 * u;
        return float4(-0.5 * u3 + u2 - 0.5 * u, 1.5 * u3 - 2.5 * u2 + 1.0, -1.5 * u3 + 2.0 * u2 + 0.5 * u, 0.5 * u3 - 0.5 * u2);
    }

    void stops(constant float *N, constant float *F, float p, thread float3 &nr, thread float3 &fr) {
        float f = fmod(fmod(p, 4.0) + 4.0, 4.0) * 4.0;
        int i = int(floor(f));
        float4 w = crw(f - floor(f));
        nr = stopAt(N, i + 15) * w.x + stopAt(N, i) * w.y + stopAt(N, i + 1) * w.z + stopAt(N, i + 2) * w.w;
        fr = stopAt(F, i + 15) * w.x + stopAt(F, i) * w.y + stopAt(F, i + 1) * w.z + stopAt(F, i + 2) * w.w;
    }

    // The wide wash from one side; the four sides together fill the middle with colour.
    float3 wash(constant float *N, constant float *F, float p, float d, float fk) {
        float3 nr, fr;
        stops(N, F, p, nr, fr);
        return fr * P[4] * exp(-d / (P[5] * fk));
    }

    // Position along the perimeter (0..4, clockwise from the top left) of the
    // nearest point on the rounded box: straight sides map linearly, and in a
    // corner the position sweeps around the arc, so colours never seam.
    float perimeter(float2 lp, float W, float H, float4 r) {
        float x = clamp(lp.x, 0.0, W), y = clamp(lp.y, 0.0, H);
        bool left = x < W * 0.5, top = y < H * 0.5;
        float rr = min(left ? (top ? r.x : r.w) : (top ? r.y : r.z), min(W, H) * 0.5);
        float cx = left ? rr : W - rr, cy = top ? rr : H - rr;
        if (rr > 0.0 && (left ? x < cx : x > cx) && (top ? y < cy : y > cy)) {
            // 0 facing the top/bottom side, 1 facing the left/right side.
            float t = atan2(abs(x - cx), abs(y - cy)) / 1.5707963;
            if (top && !left) return mix((W - rr) / W, 1.0 + rr / H, t);
            if (!top && !left) return mix(2.0 + rr / W, 1.0 + (H - rr) / H, t);
            if (!top && left) return mix(3.0 - rr / W, 3.0 + rr / H, t);
            return mix(4.0 + rr / W, 4.0 - rr / H, t);
        }
        float et = y, er = W - x, eb = H - y, el = x;
        float em = min(min(et, er), min(eb, el));
        return em == et ? x / W : em == er ? 1.0 + y / H : em == eb ? 3.0 - x / W : 4.0 - y / H;
    }

    // Rounded box, one radius per corner (tl, tr, br, bl), y down; p relative to the centre.
    float sdBox(float2 p, float2 b, float4 r) {
        float rr = p.x < 0.0 ? (p.y < 0.0 ? r.x : r.w) : (p.y < 0.0 ? r.y : r.z);
        rr = min(rr, min(b.x, b.y));
        float2 q = abs(p) - b + rr;
        return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - rr;
    }

    fragment float4 fmain(VOut in [[stage_in]], constant float *U [[buffer(0)]],
                          constant float *N [[buffer(1)]], constant float *F [[buffer(2)]]) {
        float k = U[13], fk = U[14];
        float W = max(U[4] / k, 0.5), H = max(U[5] / k, 0.5);
        float2 lp = (in.pos.xy - float2(U[2], U[3])) / k;
        float sd = sdBox(lp - float2(W, H) * 0.5, float2(W, H) * 0.5, float4(U[6], U[7], U[8], U[9]));
        if (U[18] > 0.0) {
            // Carve the notch out (reaching past the top edge), so the
            // light runs down, around its rounded foot and back up.
            float2 nb = float2(U[18], U[19] + 20.0) * 0.5;
            float2 nc = float2(U[16], U[17] - 20.0) + nb;
            float nr = min(U[20], min(U[18], U[19]) * 0.5);
            sd = max(sd, -sdBox(lp - nc, nb, float4(0.0, 0.0, nr, nr)));
        }
        float inside = clamp(0.5 - sd * k, 0.0, 1.0);
        float rot = U[10];
        float3 light = float3(0);
        if (inside > 0.0) {
            float x = clamp(lp.x, 0.0, W), y = clamp(lp.y, 0.0, H);
            // The bright line and its falloff follow the rounded outline itself
            // (distance to the shape, not to the four straight sides), so the
            // light bends around the corners instead of running into them.
            float d = max(-sd, 0.0);
            float p = perimeter(lp, W, H, float4(U[6], U[7], U[8], U[9]));
            float3 nr, fr;
            stops(N, F, p + rot, nr, fr);
            light = nr * P[0] * exp(-d / (P[1] * fk)) + fr * P[2] * exp(-d / (P[3] * fk));
            light += wash(N, F, x / W + rot, y, fk) + wash(N, F, 1.0 + y / H + rot, W - x, fk)
                   + wash(N, F, 3.0 - x / W + rot, H - y, fk) + wash(N, F, 4.0 - y / H + rot, x, fk);
            light *= inside;
        }
        // Halo outside, in the colour of the nearest edge.
        float dt = lp.y, dr = W - lp.x, db = H - lp.y, dl = lp.x;
        float m = min(min(dt, dr), min(db, dl));
        float per = m == dt ? clamp(lp.x / W, 0.0, 1.0) : m == dr ? 1.0 + clamp(lp.y / H, 0.0, 1.0)
                  : m == db ? 3.0 - clamp(lp.x / W, 0.0, 1.0) : 4.0 - clamp(lp.y / H, 0.0, 1.0);
        float3 nr, fr;
        stops(N, F, per + rot, nr, fr);
        float out = max(sd, 0.0);
        light += (nr * 0.6 + fr) * U[15] * (1.0 - inside) * (exp(-out / (5.0 * fk + 2.0)) * 0.9 + exp(-out / (22.0 * fk + 6.0)) * 0.35);

        light *= U[11];
        float3 col = 1.0 - exp(-max(light, 0.0));
        float body = U[12] * inside;
        float a = max(body, max(col.r, max(col.g, col.b)) * 0.82);
        return float4(col, a);
    }
    """
}

/// Critically or under damped spring, stepped in small slices so any frame time is stable.
struct Spring {
    var x: CGFloat
    var v: CGFloat = 0

    init(_ x: CGFloat) { self.x = x }

    mutating func step(to target: CGFloat, dt: CGFloat, omega: CGFloat, damping: CGFloat = 1) {
        var left = dt
        while left > 0 {
            let h = min(left, 1 / 480)
            let a = omega * omega * (target - x) - 2 * damping * omega * v
            v += a * h
            x += v * h
            left -= h
        }
    }
}
