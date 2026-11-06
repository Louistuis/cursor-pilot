// Cursor Pilot's light effects as Metal shaders, compiled at runtime from
// source so the Swift package needs no Metal build step.
//
// - wave:       the chromatic voice waveform, while speaking or listening
// - fluidDots:  six metaball dots that merge, scatter and gather, while thinking
//
// Both are ported from GLSL: gl_FragCoord is flipped to Metal's bottom-left
// origin, GLSL mod() keeps its floor semantics (gmod), and pow(x, 2.0) on
// values that can be negative is written as sq(x), since Metal's pow is
// undefined there. Output is premultiplied light, so it adds to whatever is
// behind it, the same as the original on black.

let shaderSource = #"""
#include <metal_stdlib>
using namespace metal;

inline float gmod(float x, float y) { return x - y * floor(x / y); }
inline float sq(float x) { return x * x; }

vertex float4 cp_fullscreen(uint vid [[vertex_id]]) {
    const float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    return float4(p[vid], 0.0, 1.0);
}

/// a: drawable size, seconds, input level 0...1 (or -1 for none).
/// b.x: zoom, so a small canvas can still show the effect large.
struct BasicUniforms { float4 a; float4 b; };

inline float4 lightOut(float3 col) {
    col = clamp(col, 0.0, 1.0);
    return float4(col, max(col.r, max(col.g, col.b)));
}

// MARK: wave

namespace wave {
constant float PI          = 3.14159265359;
constant float AMPLITUDE   = 0.32;
constant float FREQ        = 1.1;
constant float ABER_FREQ   = 1.0;
constant float SPEED       = 2.4;
constant float WAVE_SCALE  = 0.6;
constant float ABERRATION  = 2.6;
constant float THICKNESS   = 3.0;
constant float INTENSITY   = 2.0;
constant float FALLOFF     = 1.7;
constant float EDGE_MASK   = 0.4;
constant float EDGE_INSET  = 0.0;
constant float BAND_FILL   = 30000.0;
constant float BAND_THICK  = 0.08;
constant float SOFTNESS    = 2.5;
constant float LOW_AMP     = 6.0;
constant float LOW_INT     = 1.5;
constant float MID_ABER    = 0.8;
constant float MID_ABAMP   = 0.05;
constant float MID_SOFT    = 0.4;
constant float HIGH_ABER   = 0.5;
constant float HIGH_ABAMP  = 0.06;
constant float RESOLVED    = 1.0;
constant float UNRES_SCALE = 0.14;

inline float3 spectral4(int s) {
    float x = float(s);
    return clamp(float3(abs(x - 3.0) - 1.0, 2.0 - abs(x - 2.0), 2.0 - abs(x - 4.0)), 0.0, 1.0);
}
}

// Four chromatic lines around a main one, swelling in the middle, with low,
// mid and high bands that drift on their own. Given a level, the wave grows
// and shrinks with it.
fragment float4 cp_wave(float4 pos [[position]], constant BasicUniforms& U [[buffer(0)]]) {
    using namespace wave;
    float2 R = U.a.xy;
    float2 fragCoord = float2(pos.x, R.y - pos.y);
    float aspect = R.x / R.y;
    float2 p = (fragCoord + 0.5) * 2.0 / R - 1.0;
    p.x *= aspect;
    p /= U.b.x;
    float yScreen = p.y;
    p /= max(WAVE_SCALE, 0.1);

    float t    = U.a.z;
    float low  = clamp(0.45 + 0.45 * sin(t * 0.8) * sin(t * 0.37 + 1.0), 0.0, 1.0);
    float mid  = clamp(0.40 + 0.40 * sin(t * 1.7 + 2.0) * sin(t * 0.53), 0.0, 1.0);
    float high = clamp(0.30 + 0.30 * sin(t * 2.9 + 4.0) * sin(t * 0.71 + 2.0), 0.0, 1.0);
    float voice = U.a.w < 0.0 ? 1.0 : mix(0.22, 1.2, clamp(U.a.w, 0.0, 1.0));

    float res   = clamp(RESOLVED, 0.0, 1.0);
    float drift = gmod(t, 20.0 * PI) * SPEED;

    float xN  = p.x / max(aspect, 1.0);
    float env = cos(PI * 0.5 * min(abs(0.9 * xN), 1.0));
    env *= env;

    float A1    = (AMPLITUDE + 0.01 * low * LOW_AMP) * voice;
    float A2    = A1 + (mid * MID_ABAMP + high * HIGH_ABAMP) * voice;
    float AB    = (ABERRATION + mid * MID_ABER + high * HIGH_ABER) * res;
    float th    = mix(0.1, 0.01 * THICKNESS, res);
    float inten = mix(0.1, 0.01 * (INTENSITY + low * LOW_INT), res);
    float soft  = 0.01 * res * max(0.0, SOFTNESS + mid * MID_SOFT);

    float dUnres = max(length(p) - mix(0.14, UNRES_SCALE, res), 0.0);
    float yMain = A1 * env * res * sin(p.x * FREQ + drift);

    float bandFillTh = max(BAND_THICK, 1e-4);
    float bandAmt    = 1e-4 * BAND_FILL * inten;
    float3 num = float3(0.0), den = float3(0.0);
    for (int s = 0; s < 4; s++) {
        float3 hue = mix(float3(1.0), spectral4(s), res);
        den += hue;
        float ab = mix(-AB, AB, float(s) / 3.0);
        float yL = A2 * env * res * sin(p.x * ABER_FREQ + drift + ab);
        float d   = mix(dUnres, abs(p.y - yL), res);
        float lor = mix(1.0 / (1.0 + sq(0.02 * d)), 1.0, res);
        float line = inten / (sqrt(d * d + soft * soft) + th);
        float lo = min(yMain, yL), hi = max(yMain, yL);
        float dBand = max(0.0, max(p.y - hi, lo - p.y));
        float band  = bandAmt / (dBand + bandFillTh);
        num += hue * lor * (line + band);
    }
    float3 col = num / den;

    float dM    = mix(dUnres, abs(p.y - yMain), res);
    float lorM  = mix(1.0 / (1.0 + sq(0.02 * dM)), 1.0, res);
    float boost = (1.0 - res) * (14.0 * low + 4.0);
    col += 0.5 * inten * (lorM + boost) / (sqrt(dM * dM + soft * soft) + th);

    col = pow(max(col, 0.0), float3(1.5));
    float emT = clamp((abs(yScreen) - 1.0 + EDGE_INSET) / (-max(EDGE_MASK, 1e-4)), 0.0, 1.0);
    float em  = emT * emT * (3.0 - 2.0 * emT);
    float gauss = exp(-sq(xN * FALLOFF));
    col *= mix(1.0, em * gauss, res);
    col *= res;
    return lightOut(col);
}

// MARK: fluid dots

namespace dots {
constant float TAU = 6.28318530718;
constant int   N   = 6;
constant float SMOOTH_K = 0.08;
constant float INTENSITY  = 0.0025;
constant float FALLOFF_P  = 1.35;
constant float FADE_START = 0.02;
constant float FADE_END   = 0.56;
constant float ABERR = 0.005;
constant float3 SPECTRAL = float3(0.0, 0.5, 1.0) * ABERR;
constant float HUE_SPEED = 0.06;
constant float COLOR_K   = 0.5;
constant float SAT       = 0.01;
constant float HUE_SPAN  = 0.667;
constant float MERGE_PERIOD = 6.0;
constant float STAGGER  = 0.33;
constant float HOLD     = 0.0;
constant float W = 4.6;
constant float L = 3.2;
constant float PIERCE  = 0.12;
constant float RECOIL  = 0.035;
constant float REC_LAG = 0.11;
constant float GATHER_PERIOD = 12.0;
constant float GATHER_START  = 9.2;
constant float GATHER_HOLD   = 0.8;
constant float GATHER_R      = 0.008;
constant float GATHER_DIM    = 0.85;
constant float GATHER_IN     = 1.8;
constant float GATHER_IN_L   = 7.5;
constant float BURST_W = 6.5;
constant float BURST_L = 4.0;
constant float CHARGE_T     = 0.30;
constant float CHARGE_SHRK  = 0.18;
constant float CHARGE_GLOW  = 0.35;
constant float FLASH_GAIN   = 1.2;
constant float FLASH_DECAY  = 7.0;

inline float hash11(float n) { return fract(sin(n * 127.1 + 311.7) * 43758.5453); }

inline float settleWL(float tau, float w, float l) {
    if (tau <= 0.0) return 0.0;
    return 1.0 - exp(-l * tau) * cos(w * tau);
}

inline float settle(float tau) { return settleWL(tau, W, L); }

inline float settleCrit(float tau, float l) {
    if (tau <= 0.0) return 0.0;
    return 1.0 - exp(-l * tau) * (1.0 + l * tau);
}

inline float smin(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

inline float3 hue2rgb(float h) {
    h = fract(h);
    float r = clamp(abs(h * 6.0 - 3.0) - 1.0, 0.0, 1.0);
    float g = clamp(2.0 - abs(h * 6.0 - 2.0), 0.0, 1.0);
    float b = clamp(2.0 - abs(h * 6.0 - 4.0), 0.0, 1.0);
    return float3(r, g, b);
}

inline float dotR(float fi, float seed, float t) {
    return 0.036 + 0.010 * sin(t * 1.3 + seed * TAU) + 0.005 * sin(t * 2.4 + fi * 1.3);
}

inline float dotSD(float2 p, float2 pos, float r, float t, float fi, float shapeDamp) {
    float2 d = p - pos;
    float sq = 0.075 * (0.5 + 0.5 * sin(t * 0.9 + fi * 2.0)) * shapeDamp;
    float ca = cos(t * 0.35 + fi), sa = sin(t * 0.35 + fi);
    d = float2x2(float2(ca, -sa), float2(sa, ca)) * d;
    d *= float2(1.0 + sq, 1.0 - sq);
    return length(d) - r;
}

float3 scene(float2 p, float t) {
    float k  = floor(t / MERGE_PERIOD);
    float u  = fract(t / MERGE_PERIOD);
    float te = u * MERGE_PERIOD;
    float tg = gmod(t, GATHER_PERIOD);
    float g  = settleCrit((tg - GATHER_START) * GATHER_IN, GATHER_IN_L)
             - settleWL(tg - GATHER_START - GATHER_HOLD, BURST_W, BURST_L);
    float gC = clamp(g, 0.0, 1.0);
    float tb     = tg - (GATHER_START + GATHER_HOLD);
    float charge = smoothstep(-CHARGE_T, 0.0, min(tb, 0.0)) * gC;
    float flash  = tb > 0.0 ? exp(-tb * FLASH_DECAY) : 0.0;
    float gBright = mix(1.0, GATHER_DIM, gC) * (1.0 + CHARGE_GLOW * charge + FLASH_GAIN * flash);
    float3 total3 = float3(1e5);
    float3 cAcc   = float3(0.0);
    float  wAcc   = 1e-6;
    for (int i = 0; i < N; i++) {
        float fi   = float(i);
        float seed = hash11(fi);
        float ang = fi / float(N) * TAU + t * 0.35;
        float2 dir = float2(cos(ang), sin(ang));
        float R = 0.17 + 0.010 * sin(t * 1.0) + 0.007 * sin(t * 1.3 + seed * TAU);
        float pairId   = gmod(fi, 3.0);
        float moverLow = gmod(k + pairId, 2.0);
        float isMover  = (fi < 2.5) ? step(moverLow, 0.5) : step(0.5, moverLow);
        float goStart  = pairId * STAGGER;
        float retStart = 3.0 * STAGGER + HOLD + pairId * STAGGER;
        float m   = (settle(te - goStart)           - settle(te - retStart))           * isMover;
        float rec = (settle(te - goStart - REC_LAG) - settle(te - retStart - REC_LAG)) * (1.0 - isMover);
        float rSelf = dotR(fi, seed, t);
        rSelf = mix(rSelf, 0.036, gC);
        rSelf *= 1.0 - CHARGE_SHRK * charge;
        float fj    = gmod(fi + 3.0, 6.0);
        float rPart = dotR(fj, hash11(fj), t);
        float deep   = -(R + RECOIL) - PIERCE * rPart;
        float radial = mix(R, deep, m) + RECOIL * rec;
        radial = mix(radial, GATHER_R, g);
        float2 pos = radial * dir;
        float sdR = dotSD(p - SPECTRAL.r * dir, pos, rSelf, t, fi, 1.0 - gC);
        float sdG = dotSD(p - SPECTRAL.g * dir, pos, rSelf, t, fi, 1.0 - gC);
        float sdB = dotSD(p - SPECTRAL.b * dir, pos, rSelf, t, fi, 1.0 - gC);
        total3 = float3(smin(total3.r, sdR, SMOOTH_K),
                        smin(total3.g, sdG, SMOOTH_K),
                        smin(total3.b, sdB, SMOOTH_K));
        float hue = fract(fi / float(N) + t * HUE_SPEED) * HUE_SPAN;
        float3 dotCol = mix(float3(1.0), hue2rgb(hue), SAT);
        float w = exp(-sdG * COLOR_K);
        cAcc += w * dotCol;
        wAcc += w;
    }
    float3 sd3    = max(total3, float3(0.0)) + 1e-4;
    float3 core3  = clamp(INTENSITY / pow(sd3, float3(FALLOFF_P)), 0.0, 1.0);
    float3 edge3  = 1.0 - smoothstep(float3(FADE_START), float3(FADE_END), sd3);
    float3 bright = core3 * edge3 * gBright;
    return bright * (cAcc / wAcc);
}
}

// Six dots circling that pair up and pierce each other, then every twelve
// seconds gather into one point and burst out again.
fragment float4 cp_fluid_dots(float4 pos [[position]], constant BasicUniforms& U [[buffer(0)]]) {
    float2 res = U.a.xy;
    float2 fragCoord = float2(pos.x, res.y - pos.y);
    float2 p = (2.0 * fragCoord - res) / min(res.x, res.y) / U.b.x;
    float t = U.a.z;
    p /= 1.0 + 0.03 * sin(t * 1.0);
    float3 col = dots::scene(p, t);
    col *= 1.0 + 0.05 * sin(t * 1.0 + 1.0);
    col = pow(max(col, 0.0), float3(1.0 / 1.2));
    col = min(col, 1.0);
    return lightOut(col);
}
"""#
