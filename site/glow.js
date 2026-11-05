// Cursor Pilot's neon edge frame, ported from the app's Metal shader
// (mac/Sources/CursorPilot/Glow.swift, `fmain`) to WebGL1. The mode
// dynamics follow GlowStage.tick in ScreenGlow.swift.
//
//   import { mountGlow } from './glow.js';
//   const glow = mountGlow(canvas, { mode: 'thinking', radius: 18 });
//   glow.setMode('answering');   // 'idle' | 'listening' | 'thinking' | 'answering' | 'sketching'
//   glow.setLevel(0.6);          // optional voice level 0..1 for 'listening' (synthesised if never set)
//   glow.destroy();
//
// The canvas is a transparent overlay (premultiplied light that adds to the
// page under it). Give it a CSS size; the drawing buffer follows it.

// Per perimeter stop (clockwise from the top left corner): light of the bright
// inner edge and of the wide falloff, as in Glow.swift.
const NEAR = [0.258, 0.071, 1.701, 0.376, 0.343, 1.939, 0.241, 0.847, 1.322, 0.373, 1.388, 2.261,
  0.32, 0.848, 1.213, 0.372, 1.192, 1.557, 0.223, 0.909, 1.847, 0.353, 0.3, 2.404,
  0.496, 0.172, 1.566, 1.198, 0.305, 0.463, 1.073, 0.968, 0.174, 1.354, 1.019, 0.291,
  0.785, 0.586, 0.096, 1.285, 1.079, 0.231, 1.212, 0.433, 0.642, 0.722, 0.151, 1.718];
const FAR = [0.61, 0.242, 1.219, 0.246, 0.279, 1.033, 0.155, 0.503, 1.166, 0.257, 1.041, 1.446,
  0.284, 0.949, 1.3, 0.166, 0.304, 0.828, 0.133, 0.289, 0.87, 0.2, 0.202, 0.986,
  0.453, 0.166, 1.063, 0.649, 0.21, 0.29, 0.931, 0.304, 0.113, 1.476, 0.533, 0.126,
  1.217, 0.456, 0.14, 0.974, 0.189, 0.256, 0.989, 0.303, 0.53, 0.713, 0.23, 0.645];

const SAMPLES = 256;  // perimeter samples in the stop texture (64 per side)
const SCALE = 3;      // stop light is stored divided by this to fit in 8 bits

const PALETTE = ['#59E0FF', '#6B7AFF', '#B866FF', '#FF6BD1', '#FFAD5C'];

const VERT = `
attribute vec2 aPos;
void main() { gl_Position = vec4(aPos, 0.0, 1.0); }
`;

const FRAG = `
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
uniform vec2 uRes;      // drawing buffer, px
uniform vec4 uRect;     // frame: x, y (top left), w, h, px
uniform vec4 uRadii;    // tl, tr, br, bl, points
uniform float uRot, uGain, uK, uFk, uOuter;
uniform sampler2D uStops; // row 0: near, row 1: far; Catmull-Rom sampled around the perimeter

// Edge profile in points: inner line gain and decay, falloff gain and decay, wash gain and decay.
const float P0 = 3.3614, P1 = 5.07, P2 = 1.3328, P3 = 24.0, P4 = 0.1, P5 = 63.0;
const float HALF = ${(0.5 / SAMPLES).toFixed(8)};

vec3 nearAt(float p) { return texture2D(uStops, vec2(p * 0.25 + HALF, 0.25)).rgb * ${SCALE.toFixed(1)}; }
vec3 farAt(float p)  { return texture2D(uStops, vec2(p * 0.25 + HALF, 0.75)).rgb * ${SCALE.toFixed(1)}; }

float perimeter(vec2 lp, float W, float H, vec4 r) {
  float x = clamp(lp.x, 0.0, W), y = clamp(lp.y, 0.0, H);
  bool left = x < W * 0.5, top = y < H * 0.5;
  float rr = min(left ? (top ? r.x : r.w) : (top ? r.y : r.z), min(W, H) * 0.5);
  float cx = left ? rr : W - rr, cy = top ? rr : H - rr;
  if (rr > 0.0 && (left ? x < cx : x > cx) && (top ? y < cy : y > cy)) {
    float t = atan(abs(x - cx), abs(y - cy)) / 1.5707963;
    if (top && !left) return mix((W - rr) / W, 1.0 + rr / H, t);
    if (!top && !left) return mix(2.0 + rr / W, 1.0 + (H - rr) / H, t);
    if (!top && left) return mix(3.0 - rr / W, 3.0 + rr / H, t);
    return mix(4.0 + rr / W, 4.0 - rr / H, t);
  }
  float et = y, er = W - x, eb = H - y, el = x;
  float em = min(min(et, er), min(eb, el));
  return em == et ? x / W : em == er ? 1.0 + y / H : em == eb ? 3.0 - x / W : 4.0 - y / H;
}

float sdBox(vec2 p, vec2 b, vec4 r) {
  float rr = p.x < 0.0 ? (p.y < 0.0 ? r.x : r.w) : (p.y < 0.0 ? r.y : r.z);
  rr = min(rr, min(b.x, b.y));
  vec2 q = abs(p) - b + rr;
  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - rr;
}

void main() {
  float k = uK, fk = uFk;
  float W = max(uRect.z / k, 0.5), H = max(uRect.w / k, 0.5);
  vec2 px = vec2(gl_FragCoord.x, uRes.y - gl_FragCoord.y);
  vec2 lp = (px - uRect.xy) / k;
  float sd = sdBox(lp - vec2(W, H) * 0.5, vec2(W, H) * 0.5, uRadii);
  float inside = clamp(0.5 - sd * k, 0.0, 1.0);
  vec3 light = vec3(0.0);
  if (inside > 0.0) {
    float x = clamp(lp.x, 0.0, W), y = clamp(lp.y, 0.0, H);
    float d = max(-sd, 0.0);
    float p = perimeter(lp, W, H, uRadii) + uRot;
    light = nearAt(p) * P0 * exp(-d / (P1 * fk)) + farAt(p) * P2 * exp(-d / (P3 * fk));
    float wd = P5 * fk;
    light += P4 * (farAt(x / W + uRot) * exp(-y / wd) + farAt(1.0 + y / H + uRot) * exp(-(W - x) / wd)
                 + farAt(3.0 - x / W + uRot) * exp(-(H - y) / wd) + farAt(4.0 - y / H + uRot) * exp(-x / wd));
    light *= inside;
  }
  if (uOuter > 0.0 && inside < 1.0) {
    float dt = lp.y, dr = W - lp.x, db = H - lp.y, dl = lp.x;
    float m = min(min(dt, dr), min(db, dl));
    float per = m == dt ? clamp(lp.x / W, 0.0, 1.0) : m == dr ? 1.0 + clamp(lp.y / H, 0.0, 1.0)
              : m == db ? 3.0 - clamp(lp.x / W, 0.0, 1.0) : 4.0 - clamp(lp.y / H, 0.0, 1.0);
    float o = max(sd, 0.0);
    light += (nearAt(per + uRot) * 0.6 + farAt(per + uRot)) * uOuter * (1.0 - inside)
           * (exp(-o / (5.0 * fk + 2.0)) * 0.9 + exp(-o / (22.0 * fk + 6.0)) * 0.35);
  }
  light *= uGain;
  vec3 col = 1.0 - exp(-max(light, 0.0));
  float a = max(col.r, max(col.g, col.b)) * 0.82;
  gl_FragColor = vec4(col, a);
}
`;

/** The 16 stops as cyclic Catmull-Rom splines, sampled around the perimeter into RGBA8. */
function stopTexels() {
  const out = new Uint8Array(SAMPLES * 2 * 4);
  const at = (a, i, c) => a[(((i % 16) + 16) % 16) * 3 + c];
  [NEAR, FAR].forEach((a, row) => {
    for (let j = 0; j < SAMPLES; j++) {
      const f = (j / SAMPLES) * 16, i = Math.floor(f), u = f - i;
      const u2 = u * u, u3 = u2 * u;
      const w = [-0.5 * u3 + u2 - 0.5 * u, 1.5 * u3 - 2.5 * u2 + 1, -1.5 * u3 + 2 * u2 + 0.5 * u, 0.5 * u3 - 0.5 * u2];
      for (let c = 0; c < 3; c++) {
        const v = at(a, i - 1, c) * w[0] + at(a, i, c) * w[1] + at(a, i + 1, c) * w[2] + at(a, i + 2, c) * w[3];
        out[(row * SAMPLES + j) * 4 + c] = Math.round(Math.min(Math.max(v / SCALE, 0), 1) * 255);
      }
      out[(row * SAMPLES + j) * 4 + 3] = 255;
    }
  });
  return out;
}

/** Critically damped spring stepped in small slices, as in Glow.swift. */
class Spring {
  constructor(x) { this.x = x; this.v = 0; }
  step(target, dt, omega, damping = 1) {
    let left = dt;
    while (left > 0) {
      const h = Math.min(left, 1 / 480);
      const a = omega * omega * (target - this.x) - 2 * damping * omega * this.v;
      this.v += a * h;
      this.x += this.v * h;
      left -= h;
    }
  }
}

const MODES = ['idle', 'listening', 'thinking', 'answering', 'sketching'];

/** Gain a still frame uses for each mode (reduced motion, Canvas2D fallback). */
const STILL_GAIN = { idle: 0, listening: 0.72, thinking: 0.86, answering: 0.64, sketching: 0.45 };

/**
 * Mounts the edge glow on `canvas`.
 * @param {HTMLCanvasElement} canvas
 * @param {{mode?: 'idle'|'listening'|'thinking'|'answering'|'sketching', radius?: number, inset?: number, outer?: number, maxDpr?: number, still?: {gain?: number, rot?: number}}} [opts]
 * @returns {{ setMode(mode: string): void, setLevel(level: number): void, destroy(): void }}
 */
export function mountGlow(canvas, { mode = 'thinking', radius = 18, inset = 0, outer = 0, maxDpr = 2, still = null } = {}) {
  let current = MODES.includes(mode) ? mode : 'thinking';
  let level = null; // null: synthesise a speaking voice
  let destroyed = false;
  let raf = 0, last = 0, clock = 0, rot = 0.3;
  const gain = new Spring(0), spin = new Spring(0.14);
  let cssW = 0, cssH = 0, dpr = 1;
  let visible = true, onScreen = true;

  const reduceQuery = window.matchMedia ? window.matchMedia('(prefers-reduced-motion: reduce)') : null;
  // `still: { gain, rot }` draws one fixed frame (for posters and comparisons).
  let reduced = !!still || !!(reduceQuery && reduceQuery.matches);

  // ---- WebGL ---------------------------------------------------------------
  let gl = null, prog = null, buf = null, tex = null, loc = {};
  const glOpts = { alpha: true, premultipliedAlpha: true, antialias: false, depth: false, stencil: false,
    preserveDrawingBuffer: false, powerPreference: 'low-power' };
  try { gl = canvas.getContext('webgl', glOpts) || canvas.getContext('experimental-webgl', glOpts); } catch { gl = null; }

  function initGL() {
    const sh = (type, src) => {
      const s = gl.createShader(type);
      gl.shaderSource(s, src);
      gl.compileShader(s);
      if (!gl.getShaderParameter(s, gl.COMPILE_STATUS) && !gl.isContextLost()) {
        throw new Error('glow shader: ' + gl.getShaderInfoLog(s));
      }
      return s;
    };
    prog = gl.createProgram();
    gl.attachShader(prog, sh(gl.VERTEX_SHADER, VERT));
    gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, FRAG));
    gl.linkProgram(prog);
    if (!gl.getProgramParameter(prog, gl.LINK_STATUS) && !gl.isContextLost()) {
      throw new Error('glow program: ' + gl.getProgramInfoLog(prog));
    }
    gl.useProgram(prog);
    buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    const aPos = gl.getAttribLocation(prog, 'aPos');
    gl.enableVertexAttribArray(aPos);
    gl.vertexAttribPointer(aPos, 2, gl.FLOAT, false, 0, 0);
    tex = gl.createTexture();
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, SAMPLES, 2, 0, gl.RGBA, gl.UNSIGNED_BYTE, stopTexels());
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    for (const n of ['uRes', 'uRect', 'uRadii', 'uRot', 'uGain', 'uK', 'uFk', 'uOuter', 'uStops']) {
      loc[n] = gl.getUniformLocation(prog, n);
    }
    gl.uniform1i(loc.uStops, 0);
    gl.disable(gl.BLEND);
    gl.clearColor(0, 0, 0, 0);
  }

  if (gl) {
    try { initGL(); } catch (e) { console.warn(e); gl = null; }
  }

  function drawGL(g, r) {
    if (gl.isContextLost()) return;
    const w = canvas.width, h = canvas.height;
    gl.viewport(0, 0, w, h);
    gl.clear(gl.COLOR_BUFFER_BIT);
    if (g <= 0.001) return;
    const ins = inset * dpr;
    const rw = Math.max(w - 2 * ins, 1), rh = Math.max(h - 2 * ins, 1);
    const area = (rw / dpr) * (rh / dpr);
    const fk = Math.min(1.3, Math.max(0.28, Math.sqrt(area / (736 * 414))));
    const rr = Math.min(radius, Math.min(rw, rh) / dpr / 2);
    gl.uniform2f(loc.uRes, w, h);
    gl.uniform4f(loc.uRect, ins, ins, rw, rh);
    gl.uniform4f(loc.uRadii, rr, rr, rr, rr);
    gl.uniform1f(loc.uRot, r);
    gl.uniform1f(loc.uGain, g);
    gl.uniform1f(loc.uK, dpr);
    gl.uniform1f(loc.uFk, fk);
    gl.uniform1f(loc.uOuter, outer);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }

  // ---- Canvas2D fallback ---------------------------------------------------
  let ctx2d = null;
  if (!gl) ctx2d = canvas.getContext('2d');

  function roundRectPath(c, x, y, w, h, r) {
    c.beginPath();
    c.moveTo(x + r, y);
    c.arcTo(x + w, y, x + w, y + h, r);
    c.arcTo(x + w, y + h, x, y + h, r);
    c.arcTo(x, y + h, x, y, r);
    c.arcTo(x, y, x + w, y, r);
    c.closePath();
  }

  function draw2D(g, r) {
    const c = ctx2d;
    if (!c) return;
    const w = canvas.width, h = canvas.height;
    c.setTransform(1, 0, 0, 1, 0, 0);
    c.clearRect(0, 0, w, h);
    if (g <= 0.001) return;
    c.scale(dpr, dpr);
    const W = cssW - 2 * inset, H = cssH - 2 * inset;
    const fk = Math.min(1.3, Math.max(0.28, Math.sqrt((W * H) / (736 * 414))));
    const rr = Math.min(radius, Math.min(W, H) / 2);
    let grad;
    if (c.createConicGradient) {
      grad = c.createConicGradient(-Math.PI / 2 + (r / 4) * Math.PI * 2, inset + W / 2, inset + H / 2);
      PALETTE.concat(PALETTE[0]).forEach((col, i) => grad.addColorStop(i / PALETTE.length, col));
    } else {
      grad = c.createLinearGradient(inset, inset, inset + W, inset + H);
      PALETTE.forEach((col, i) => grad.addColorStop(i / (PALETTE.length - 1), col));
    }
    c.save();
    roundRectPath(c, inset, inset, W, H, rr);
    c.clip();
    c.globalCompositeOperation = 'lighter';
    c.strokeStyle = grad;
    const canBlur = 'filter' in c;
    const layers = [[70, 0.12], [36, 0.18], [18, 0.24], [8, 0.36], [3, 0.55], [1.2, 0.9]];
    for (const [lw, a] of layers) {
      const width = lw * (lw > 3 ? fk : 1);
      if (canBlur) c.filter = `blur(${Math.max(width * 0.45, 0.4)}px)`;
      c.globalAlpha = Math.min(1, a * g * 1.25);
      c.lineWidth = width * 2;
      roundRectPath(c, inset, inset, W, H, rr);
      c.stroke();
    }
    c.restore();
  }

  // ---- Sizing --------------------------------------------------------------
  function resize() {
    const rect = canvas.getBoundingClientRect();
    cssW = Math.max(rect.width, 1);
    cssH = Math.max(rect.height, 1);
    dpr = Math.min(window.devicePixelRatio || 1, maxDpr);
    const w = Math.max(1, Math.round(cssW * dpr)), h = Math.max(1, Math.round(cssH * dpr));
    if (canvas.width !== w || canvas.height !== h) {
      canvas.width = w;
      canvas.height = h;
    }
    paintStill();
  }

  function draw(g, r) {
    if (gl) drawGL(g, r);
    else draw2D(g, r);
  }

  // A still frame: used with reduced motion, by the fallback and right after a resize.
  function paintStill() {
    if (still) draw(still.gain ?? STILL_GAIN[current], still.rot ?? 0.3);
    else if (reduced || !gl) draw(STILL_GAIN[current], 0.3);
    else draw(Math.max(gain.x, 0), rot);
  }

  // ---- Animation (GlowStage.tick) ------------------------------------------
  function voice(t) {
    if (level != null) return level;
    // A speaking voice: syllables riding on slower phrases.
    const phrase = 0.5 + 0.5 * Math.sin(t * 0.9) * Math.sin(t * 0.37 + 1.3);
    const syl = Math.abs(Math.sin(t * 7.3) * Math.sin(t * 3.1 + 0.6));
    return Math.min(1, Math.max(0, 0.1 + phrase * 0.55 + syl * 0.35 * phrase));
  }

  function tick(now) {
    raf = 0;
    if (destroyed) return;
    const dt = last === 0 ? 1 / 60 : Math.min(Math.max((now - last) / 1000, 0), 1 / 20);
    last = now;
    clock += dt;
    switch (current) {
      case 'idle':
        gain.step(0, dt, 7);
        spin.step(0.14, dt, 4);
        break;
      case 'listening':
        gain.step(0.5 + voice(clock) * 0.7, dt, 14);
        spin.step(0.14, dt, 4);
        break;
      case 'thinking':
        gain.step(0.8 + 0.18 * Math.sin(clock * 3.4), dt, 10);
        spin.step(0.36, dt, 3);
        break;
      case 'answering':
        gain.step(0.62 + 0.06 * Math.sin(clock * 1.7), dt, 6);
        spin.step(0.14, dt, 3);
        break;
      case 'sketching':
        gain.step(0.42, dt, 8);
        spin.step(0.08, dt, 3);
        break;
    }
    rot = (rot + spin.x * dt) % 4;
    draw(Math.max(gain.x, 0), rot);
    if (current === 'idle' && gain.x < 0.01 && gain.v <= 0) {
      gain.x = 0; gain.v = 0;
      draw(0, rot);
      return; // settled dark; setMode wakes it
    }
    schedule();
  }

  function running() { return !!gl && !reduced && visible && onScreen && !destroyed; }

  function schedule() {
    if (!raf && running()) raf = requestAnimationFrame(tick);
  }

  function wake() {
    if (raf || !running()) return;
    last = 0;
    schedule();
  }

  function stop() {
    if (raf) cancelAnimationFrame(raf);
    raf = 0;
  }

  // ---- Observers -----------------------------------------------------------
  const ro = typeof ResizeObserver !== 'undefined' ? new ResizeObserver(() => resize()) : null;
  if (ro) ro.observe(canvas);
  else window.addEventListener('resize', resize);

  let io = null;
  if (typeof IntersectionObserver !== 'undefined') {
    io = new IntersectionObserver((entries) => {
      onScreen = entries[entries.length - 1].isIntersecting;
      if (onScreen) wake(); else stop();
    });
    io.observe(canvas);
  }

  const onVisibility = () => {
    visible = document.visibilityState !== 'hidden';
    if (visible) wake(); else stop();
  };
  document.addEventListener('visibilitychange', onVisibility);

  const onReduce = () => {
    reduced = !!still || reduceQuery.matches;
    if (reduced) { stop(); paintStill(); } else wake();
  };
  if (reduceQuery) {
    if (reduceQuery.addEventListener) reduceQuery.addEventListener('change', onReduce);
    else reduceQuery.addListener(onReduce);
  }

  // Window moved to a display with a different pixel ratio.
  let dprQuery = null;
  const onDpr = () => { resize(); watchDpr(); };
  function watchDpr() {
    if (!window.matchMedia) return;
    if (dprQuery) dprQuery.removeEventListener?.('change', onDpr);
    dprQuery = window.matchMedia(`(resolution: ${window.devicePixelRatio || 1}dppx)`);
    dprQuery.addEventListener?.('change', onDpr);
  }
  watchDpr();

  const onLost = (e) => { e.preventDefault(); stop(); };
  const onRestored = () => {
    try { initGL(); } catch (err) { console.warn(err); return; }
    paintStill();
    wake();
  };
  canvas.addEventListener('webglcontextlost', onLost);
  canvas.addEventListener('webglcontextrestored', onRestored);

  resize();
  visible = document.visibilityState !== 'hidden';
  wake();

  return {
    setMode(next) {
      if (!MODES.includes(next) || destroyed) return;
      current = next;
      if (reduced || !gl) paintStill();
      else wake();
    },
    setLevel(v) {
      level = v == null ? null : Math.min(1, Math.max(0, +v || 0));
    },
    destroy() {
      if (destroyed) return;
      destroyed = true;
      stop();
      ro?.disconnect();
      if (!ro) window.removeEventListener('resize', resize);
      io?.disconnect();
      document.removeEventListener('visibilitychange', onVisibility);
      if (reduceQuery) {
        if (reduceQuery.removeEventListener) reduceQuery.removeEventListener('change', onReduce);
        else reduceQuery.removeListener(onReduce);
      }
      dprQuery?.removeEventListener?.('change', onDpr);
      canvas.removeEventListener('webglcontextlost', onLost);
      canvas.removeEventListener('webglcontextrestored', onRestored);
      if (gl && !gl.isContextLost()) {
        gl.clear(gl.COLOR_BUFFER_BIT);
        gl.deleteBuffer(buf);
        gl.deleteTexture(tex);
        gl.deleteProgram(prog);
      } else if (ctx2d) {
        ctx2d.setTransform(1, 0, 0, 1, 0, 0);
        ctx2d.clearRect(0, 0, canvas.width, canvas.height);
      }
    },
  };
}
