// Cursor Pilot's light effects as Metal shaders, compiled at runtime from
// source so the Swift package needs no Metal build step.
//
// - wave:       ribbons of light while speaking (original)
// - fluidDots:  six dots that merge and spread while thinking (original)
// - strands:    glass orb with ribbons of light, ported from the React Bits
//               "Strands" component (MIT + Commons Clause, see
//               THIRD_PARTY_NOTICES.md)
//
// Strands is ported from WebGL: gl_FragCoord is flipped to Metal's top-left origin,
// GLSL mod() keeps its floor semantics (gmod), and pow(x, 2.0) on values that
// can be negative is written as sq(x), since Metal's pow is undefined there.
// Output is premultiplied alpha so the light composites over any background.

let shaderSource = #"""
#include <metal_stdlib>
using namespace metal;

inline float gmod(float x, float y) { return x - y * floor(x / y); }
inline float sq(float x) { return x * x; }

vertex float4 cp_fullscreen(uint vid [[vertex_id]]) {
    const float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    return float4(p[vid], 0.0, 1.0);
}

/// x, y: drawable size; z: seconds; w: input level 0...1, or -1 for none.
struct BasicUniforms { float4 a; };

inline float4 lightOut(float3 col) {
    col = clamp(col, 0.0, 1.0);
    return float4(col, max(col.r, max(col.g, col.b)));
}

// MARK: palette

// The app's rainbow (pilotRainbow in Overlay.swift), looping.
constant float3 RAINBOW[5] = {
    float3(0.35, 0.88, 1.00), float3(0.42, 0.48, 1.00), float3(0.72, 0.40, 1.00),
    float3(1.00, 0.42, 0.82), float3(1.00, 0.68, 0.36)
};

inline float3 rainbow(float t) {
    t = fract(t) * 5.0;
    int i = int(floor(t));
    return mix(RAINBOW[i], RAINBOW[(i + 1) % 5], smoothstep(0.0, 1.0, fract(t)));
}

// MARK: wave

// Three ribbons of light that swell in the middle and lie flat at the ends,
// higher and livelier with the level.
fragment float4 cp_wave(float4 pos [[position]], constant BasicUniforms& U [[buffer(0)]]) {
    float2 size = U.a.xy;
    float t = U.a.z;
    float energy = U.a.w < 0.0 ? 0.55 + 0.25 * sin(t * 1.7) * sin(t * 0.63 + 1.0) : clamp(U.a.w, 0.0, 1.0);
    float2 p = float2((pos.x / size.x) * 2.0 - 1.0, 1.0 - (pos.y / size.y) * 2.0);
    float envelope = sq(clamp(1.0 - p.x * p.x, 0.0, 1.0));

    float3 col = float3(0.0);
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float y = sin(p.x * (2.2 + fi * 1.3) + t * (1.8 + fi * 0.7) + fi * 2.1)
                * (0.35 + 0.5 * energy) * (0.9 - fi * 0.2);
        y += 0.08 * energy * sin(p.x * 7.0 - t * 3.1 + fi);
        float d = abs(p.y - y * envelope);
        float w = 0.012 + 0.02 * energy;
        float glow = sq(w / (d + w)) * (0.6 + 0.4 * envelope);
        col += rainbow(fi * 0.27 + p.x * 0.18 + t * 0.05) * glow * 0.9;
    }
    // A faint resting line where the ribbons flatten out.
    col += rainbow(t * 0.05) * 0.15 * (0.004 / (abs(p.y) + 0.004)) * (1.0 - 0.5 * envelope);
    return lightOut(col);
}

// MARK: fluid dots

// Six dots that circle, drift together until they melt into one blob, then
// spread out again.
fragment float4 cp_fluid_dots(float4 pos [[position]], constant BasicUniforms& U [[buffer(0)]]) {
    float2 size = U.a.xy;
    float t = U.a.z;
    float2 p = float2(pos.x - 0.5 * size.x, 0.5 * size.y - pos.y) / min(size.x, size.y) * 2.0;

    float gather = 0.5 + 0.5 * sin(t * 0.9);
    float field = 0.0;
    float3 tint = float3(0.0);
    float weight = 0.0;
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float a = t * (0.6 + 0.13 * fi) + fi * 1.047;
        float r = mix(0.12, 0.48, gather) * (0.85 + 0.15 * sin(t * 1.3 + fi * 2.0));
        float2 d = p - r * float2(cos(a), sin(a * 1.1));
        float radius = 0.17 + 0.03 * sin(t * 2.1 + fi);
        float f = radius * radius / (dot(d, d) + 1e-4);
        field += f;
        // Cubed, so each dot keeps its own colour instead of blending to white.
        tint += rainbow(fi / 6.0 + t * 0.04) * f * f * f;
        weight += f * f * f;
    }
    float3 base = tint / max(weight, 1e-6);
    float aa = max(fwidth(field), 1e-3);
    float inside = smoothstep(1.0 - aa, 1.0 + aa, field);
    float halo = smoothstep(0.35, 1.0, field) * 0.35;
    float3 col = base * (inside * 0.9 + halo) + inside * smoothstep(2.0, 5.0, field) * 0.1;
    return lightOut(col);
}

// MARK: strands

struct StrandsUniforms {
    float4 u0, u1, u2, u3, u4, u5, u6;
    float4 colors[8];
};

#define uResolution X.u0.xy
#define uLevel X.u0.z
#define uCount int(X.u0.w)
#define uMotion X.u1.xyz
#define uAmplitude X.u1.w
#define uWaviness X.u2.x
#define uThickness X.u2.y
#define uGlow X.u2.z
#define uTaper X.u2.w
#define uSpread X.u3.x
#define uHueShift X.u3.y
#define uIntensity X.u3.z
#define uSaturation X.u3.w
#define uScale X.u4.x
#define uGlass X.u4.y
#define uRadius X.u4.z
#define uRefraction X.u4.w
#define uDispersion X.u5.x
#define uRim X.u5.y
#define uLean X.u5.zw
#define uIntro X.u6.x
#define uPulse X.u6.y
#define uLight X.u6.z
#define uOpacity X.u6.w
#define COL(i) X.colors[i].xyz
#define SU constant StrandsUniforms& X

namespace st {
constant float PI = 3.14159265;

float3 hueRotate(float3 c, float a) {
    const float3x3 toYiq = float3x3(float3(0.299, 0.596, 0.211), float3(0.587, -0.274, -0.523), float3(0.114, -0.322, 0.312));
    const float3x3 toRgb = float3x3(float3(1.0, 1.0, 1.0), float3(0.956, -0.272, -1.106), float3(0.621, -0.647, 1.703));
    float3 yiq = toYiq * c;
    float ca = cos(a);
    float sa = sin(a);
    yiq.yz = float2x2(float2(ca, sa), float2(-sa, ca)) * yiq.yz;
    return max(toRgb * yiq, float3(0.0));
}

float3 grade(float3 c, SU) {
    float g = dot(c, float3(0.2126, 0.7152, 0.0722));
    c = clamp(mix(float3(g), c, 1.5 * uSaturation), 0.0, 1.0);
    return hueRotate(c, uHueShift * 6.2831853);
}

float3 lightInk(float3 L, float halo, float3 body, SU) {
    float3 Lg = grade(L, X);
    float lum = dot(Lg, float3(0.2126, 0.7152, 0.0722));
    float cov = 1.0 - exp(-lum * 2.6);
    float3 hue = Lg / max(max(Lg.r, max(Lg.g, Lg.b)), 1e-4);
    float white = pow(clamp(min(hue.r, min(hue.g, hue.b)), 0.0, 1.0), 1.4);
    float3 ink = pow(hue, float3(2.2)) * 0.88;
    float coreAmt = white * smoothstep(0.05, 2.2, lum) * 0.92;
    float3 cream = mix(mix(COL(3), float3(1.0), 0.3), float3(1.0, 0.985, 0.95), smoothstep(1.2, 3.5, lum));
    float3 c = mix(body, float3(0.66, 0.69, 0.76), halo * 0.32);
    c = mix(c, ink, cov * (1.0 - white));
    return mix(c, cream, clamp(coreAmt, 0.0, 1.0));
}

float sstep(float a, float b, float x) {
    float t = clamp((x - a) / (b - a), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

float erfa(float x) {
    float a = abs(x);
    float t = 1.0 / (1.0 + 0.3275911 * a);
    float y = 1.0 - ((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * exp(-a * a);
    return x < 0.0 ? -y : y;
}

float3 grad4(float3 c0, float3 c1, float3 c2, float3 c3, float p1, float p2, float f) {
    float3 c = mix(c0, c1, sstep(0.0, p1, f));
    c = mix(c, c2, sstep(p1, p2, f));
    return mix(c, c3, sstep(p2, 1.0, f));
}

float2 sheetW(float tt, float H, float sig, float sigB, float ridges, SU) {
    float ew = 0.04 * uThickness;
    float res0 = 0.0;
    float res1 = 0.0;
    for (int pass = 0; pass < 2; pass++) {
        float sg = pass == 0 ? sig : sigB;
        float fill = 0.5 * (erfa(tt / sg) - erfa((tt - H) / sg)) / H;
        float se = sqrt(sg * sg + 0.25 * ew * ew * H * H);
        float de = (tt - H + 0.5 * ew * H) / se;
        float eg = exp(-de * de) / (se * 1.7724539);
        float rgw = sqrt(sg * sg + 0.0025 * H * H);
        float d1 = (tt - 0.45 * H) / rgw;
        float d2 = (tt - 0.241 * H) / rgw;
        float rid = 0.04 * (exp(-d1 * d1) * step(1.5, ridges) + 0.7 * exp(-d2 * d2) * step(2.5, ridges)) / (rgw * 1.7724539);
        float v = 0.6 * fill * (1.0 - 0.55 * uLight) + (1.6 * ew * 0.886 * eg + rid) * (1.0 + 1.3 * uLight);
        if (pass == 0) res0 = v;
        else res1 = v;
    }
    return float2(res0, res1);
}

float axis(float x, SU) {
    float a = uAmplitude;
    return -0.2318 + uLean.y * 0.06 + (-0.2394 + uLean.x * 0.1) * x + 0.2815 * a * x * x + 0.3368 * a * x * x * x;
}

float softp(float z) {
    return 0.03 * log(1.0 + exp(clamp(z / 0.03, -60.0, 60.0)));
}

float3 light(float2 u, float fp, float bend, float level, thread float& halo, SU) {
    float amp = level < 0.65 ? mix(0.25, 1.0, sstep(0.0, 0.65, level)) : mix(1.0, 1.12, (level - 0.65) / 0.35);
    float grow = clamp((amp - 0.25) / 0.75, 0.0, 1.25);
    float x = u.x / uScale;
    float uy = u.y;
    float ya = axis(x, X);
    float taper = max(uTaper, 0.05);
    float bx = 0.0437 + uMotion.z + uLean.x * 0.08;
    float bump = exp(-sq((x - bx) / (0.6879 * taper)));
    float hW = 0.02 + softp(-0.12 + 0.5324 * uAmplitude * grow * uMotion.y * bump - 0.02);
    float k = 1.0 * uWaviness;
    float cphi = cos(0.5 * PI + k * (x + 0.0664) + uMotion.x);
    float envC = (0.0886 + 0.3 * exp(-sq((x - 0.0634) / 0.6873))) * uSpread * grow;
    float hC = -envC * tanh(cphi / 0.6);
    float th = 0.051 * uThickness * exp(-sq(cphi / 0.5));
    float sig = sqrt(sq(0.005 + 0.05 * bend) + fp * fp + th * th);
    float sigB = sqrt(0.0064 * max(uGlow, 0.05) * max(uGlow, 0.05) + fp * fp + th * th);
    float mend = exp(-pow(abs((x + 0.0421) / (0.4235 * taper)), 2.2689));
    float3 red = COL(0);
    float3 orange = COL(1);
    float3 amber = COL(2);
    float3 warmWhite = COL(3);
    float3 cyan = COL(4);
    float3 blue = COL(5);
    float3 deep = COL(6);
    float3 orangeEdge = orange * float3(1.0, 0.85, 0.77);
    float3 coolCore = mix(warmWhite, float3(1.0, 1.0, 0.7), 0.6);
    float3 mint = clamp(mix(cyan, warmWhite, 0.35) * float3(0.92, 1.05, 0.95), 0.0, 1.0);
    float ridges = float(uCount);
    float glow = max(uGlow, 0.0);
    float3 L = float3(0.0);
    float3 Lb = float3(0.0);
    {
        float H = max(abs(hW), 1e-4);
        float tt = uy - ya;
        float2 w = sheetW(tt, H, sig, sigB, ridges, X);
        float f = clamp(tt / H, 0.0, 1.0);
        float3 c = grad4(warmWhite, amber, orange, orangeEdge, 0.2351, 0.5643, f);
        c = mix(c, red, sstep(0.75, 1.0, f) * sstep(0.196, 0.3376, hW));
        float3 mean = (grad4(warmWhite, amber, orange, orangeEdge, 0.2351, 0.5643, 0.1) + grad4(warmWhite, amber, orange, orangeEdge, 0.2351, 0.5643, 0.35) + grad4(warmWhite, amber, orange, orangeEdge, 0.2351, 0.5643, 0.6) + grad4(warmWhite, amber, orange, orangeEdge, 0.2351, 0.5643, 0.9)) * 0.25;
        L += mix(c, mean, sstep(0.3, 1.2, sig / H)) * (w.x * 0.2101 * mend);
        Lb += mix(c, mean, sstep(0.3, 1.2, sigB / H)) * (w.y * 0.2101 * mend);
    }
    {
        float H = max(abs(hC), 1e-4);
        float tt = (uy - ya) * (hC >= 0.0 ? 1.0 : -1.0);
        float2 w = sheetW(tt, H, sig, sigB, 1.0, X);
        float f = clamp(tt / H, 0.0, 1.0);
        float3 c = grad4(coolCore, cyan, blue, deep, 0.15, 0.7931, f);
        float3 mean = (grad4(coolCore, cyan, blue, deep, 0.15, 0.7931, 0.1) + grad4(coolCore, cyan, blue, deep, 0.15, 0.7931, 0.35) + grad4(coolCore, cyan, blue, deep, 0.15, 0.7931, 0.6) + grad4(coolCore, cyan, blue, deep, 0.15, 0.7931, 0.9)) * 0.25;
        L += mix(c, mean, sstep(0.3, 1.2, sig / H)) * (w.x * 0.28 * mend);
        Lb += mix(c, mean, sstep(0.3, 1.2, sigB / H)) * (w.y * 0.28 * mend);
    }
    float3 G = float3(0.0);
    float wh = sqrt(0.0256 + envC * envC * cphi * cphi);
    float dg = (uy - ya) / wh;
    G += float3(1.0, 0.97, 0.92) * (exp(-dg * dg) * 0.0315 / wh * mend * glow);
    float nx = -0.0664 - uMotion.x / k + 0.2168;
    float bxx = (x - nx) / 0.1849;
    float byy = (uy - axis(nx, X) - 0.0333) / (0.0544 * mix(0.7, 1.0, min(amp, 1.0)));
    G += mint * (exp(-bxx * bxx - byy * byy) * 1.4 * glow * sstep(0.0, 0.6, amp));
    float hb = (uy - ya - 0.3 * hW) / (0.07 + 0.45 * hW + 0.3 * envC);
    halo = exp(-hb * hb) * mend * smoothstep(0.0, 0.3, uIntro);
    float3 total = L + 0.16 * glow * Lb + 1.16 * G;
    return total * 2.4 * uIntensity * smoothstep(0.0, 0.3, uIntro) * sstep(uIntro * 1.6, uIntro * 1.6 - 0.5, abs(x));
}

float2 remap(float2 p, float f, thread float& r, thread float& bend, SU) {
    r = min(length(p), 0.9995);
    bend = pow(r, 5.17);
    float k = clamp(uRefraction, 0.0, 1.8);
    float sc = (1.0 - 0.278 * k * (1.0 - bend)) * (1.0 - 0.632 * k * bend) / (1.0 - 0.278 * k);
    return p * sc * f;
}
}

fragment float4 cp_strands(float4 position [[position]], SU [[buffer(0)]]) {
    using namespace st;
    float2 res = uResolution;
    float2 frag = float2(position.x, res.y - position.y);
    float2 p = (frag - 0.5 * res) / min(res.x, res.y);
    float level = clamp(uLevel, 0.0, 1.0);
    float appear = smoothstep(0.0, 0.35, uIntro);

    if (uGlass > 0.5) {
        float R = uRadius * mix(0.94, 1.0, uIntro) * (1.0 + 0.03 * uPulse);
        float px = 1.0 / (min(res.x, res.y) * R);
        float2 pc = p / R;
        float rho = length(pc);
        if (rho > 1.0 + 2.0 * px) {
            float sh = uLight * 0.07 * exp(-sq((rho - 0.985) / 0.07)) * smoothstep(-0.6, 0.4, -pc.y) * appear * uOpacity;
            return float4(0.0, 0.0, 0.0, sh);
        }
        float r;
        float bend;
        float2 u = remap(pc, 1.0, r, bend, X);
        float fp = 0.5 * max(length(dfdx(u)), length(dfdy(u)));
        float halo;
        float skip;
        float3 L = light(u, fp, bend, level, halo, X);
        float ca = 0.02 * uDispersion * bend;
        if (ca > 0.0015) {
            float r2;
            float b2;
            L.r = light(remap(pc, 1.0 - ca, r2, b2, X), fp, bend, level, skip, X).r;
            L.b = light(remap(pc, 1.0 + ca, r2, b2, X), fp, bend, level, skip, X).b;
        }
        float3 col = 1.0 - exp(-L);
        float2 d = pc / max(rho, 1e-6);
        float key = 0.4 * pow(max(0.0, d.x * 0.94 - d.y * 0.34), 6.0) + 0.2 * pow(max(0.0, -d.x * 0.5 + d.y * 0.87), 6.0);
        float ring = exp(-sq((r - 0.985) / 0.011));
        float hzk = 0.25 + 0.7 * pow(max(0.0, -d.x * 0.6 + d.y * 0.8), 2.0) + pow(max(0.0, d.x * 0.8 - d.y * 0.6), 2.0);
        float haze = exp(-sq((1.0 - r) / 0.09)) * hzk * 0.13 * uRim;
        float3 orb;
        if (uLight > 0.5) {
            float lz = dot(d * r, float2(-0.55, 0.83));
            float3 body = mix(float3(0.885, 0.893, 0.915), float3(0.972, 0.975, 0.983), 0.5 + 0.5 * lz);
            float fres = smoothstep(0.8, 1.0, r);
            body = mix(body, float3(0.82, 0.83, 0.86), fres * fres * 0.5);
            orb = lightInk(L, halo, body, X);
            float spec = exp(-sq((r - 0.955) / 0.03)) * pow(max(0.0, dot(d, float2(-0.55, 0.83))), 3.0);
            orb = mix(orb, float3(1.0), clamp(spec * 0.85 * uRim + haze * 0.6, 0.0, 1.0));
            float edge = exp(-sq((1.0 - r) / (0.01 + 1.2 * px)));
            orb *= 1.0 - 0.12 * edge;
        } else {
            orb = float3(0.04) + col * (1.0 + 0.1 * bend * uRim) + ring * key * uRim * (1.0 + 0.4 * level) + haze * float3(1.0, 1.02, 1.04);
            orb = grade(clamp(orb, 0.0, 1.0), X);
        }
        float inside = clamp((1.0 - rho) / px + 0.5, 0.0, 1.0) * appear;
        float3 rgb = orb * inside;
        return float4(rgb, max(inside * mix(0.92, 1.0, uLight), max(max(rgb.r, rgb.g), rgb.b))) * uOpacity;
    } else {
        float span = 0.5 * res.x / min(res.x, res.y);
        float2 u = p * (0.78 / span) + float2(0.0, -0.15);
        float fp = 0.5 * max(length(dfdx(u)), length(dfdy(u)));
        float halo;
        float fade = sstep(0.82, 0.55, abs(u.x));
        float3 L = light(u, fp, 0.0, level, halo, X) * fade;
        float3 col = grade(1.0 - exp(-L), X) * appear;
        if (uLight > 0.5) {
            float3 c = lightInk(L, halo * fade * 0.6, float3(1.0), X);
            float a = clamp(1.0 - min(c.r, min(c.g, c.b)), 0.0, 1.0) * appear;
            return float4((c - (1.0 - a)) * appear, a) * uOpacity;
        }
        return float4(col, max(max(col.r, col.g), col.b)) * uOpacity;
    }
}
"""#
