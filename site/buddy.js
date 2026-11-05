// Cursor Pilot's buddy: the frosted-glass pilot arrow with the glow's rainbow
// caught in its rim. Shape from ArrowShape / PilotArrow in
// mac/Sources/CursorPilot/Overlay.swift; glass details from the icon
// (scripts/icon/main.swift). Flights follow OverlayController's arc()
// and ease().
//
//   import { createBuddy } from './buddy.js';
//   const buddy = createBuddy(container);          // container: any element; px are relative to it
//   await buddy.moveTo(320, 140, { label: 'Click Share' });
//   buddy.say('Thinking');  buddy.say('');
//   buddy.show(); buddy.hide();

const PREFIX = 'cp-buddy';
const PALETTE = ['#59E0FF', '#6B7AFF', '#B866FF', '#FF6BD1', '#FFAD5C'];

/** ArrowShape corners: fractions of the rect, radius as a fraction of the shorter side. */
const CORNERS = [
  [0.02, 0.01, 0.09], // tip
  [1.00, 0.58, 0.15], // wing
  [0.45, 0.66, 0.05], // notch
  [0.13, 1.00, 0.15], // tail
];

const STYLE = `
@property --${PREFIX}-spin { syntax: '<angle>'; inherits: true; initial-value: 290deg; }
.${PREFIX} {
  --${PREFIX}-ring: conic-gradient(from var(--${PREFIX}-spin) at 50% 50%, ${PALETTE.join(', ')}, ${PALETTE[0]});
  --${PREFIX}-glass: rgba(24, 24, 32, 0.52);
  --${PREFIX}-glass-edge-top: rgba(255, 255, 255, 0.42);
  --${PREFIX}-glass-edge-bottom: rgba(255, 255, 255, 0.07);
  --${PREFIX}-ink: #f4f5fa;
  position: absolute; left: 0; top: 0; z-index: 30;
  pointer-events: none; user-select: none; -webkit-user-select: none;
  will-change: transform;
  opacity: 0; visibility: hidden;
  transition: opacity .42s ease, visibility 0s linear .42s;
}
.${PREFIX}.${PREFIX}--light {
  --${PREFIX}-glass: rgba(255, 255, 255, 0.62);
  --${PREFIX}-glass-edge-top: rgba(255, 255, 255, 0.9);
  --${PREFIX}-glass-edge-bottom: rgba(255, 255, 255, 0.25);
  --${PREFIX}-ink: #16161d;
}
.${PREFIX}.is-shown { opacity: 1; visibility: visible; transition: opacity .14s ease, visibility 0s; }
.${PREFIX}.is-active { animation: ${PREFIX}-spin 3s linear infinite; }
@keyframes ${PREFIX}-spin { from { --${PREFIX}-spin: 290deg; } to { --${PREFIX}-spin: 650deg; } }

.${PREFIX}__arrow { position: absolute; left: 0; top: 0; }
.${PREFIX}.is-flipped .${PREFIX}__arrow { transform: scaleX(-1); }
.${PREFIX}__layer { position: absolute; left: 0; top: 0; }
.${PREFIX}__halo { filter: blur(var(--${PREFIX}-halo-blur)); opacity: .5;
  transition: opacity .3s ease, filter .3s ease; }
.${PREFIX}.is-active .${PREFIX}__halo { filter: blur(var(--${PREFIX}-halo-blur-active)); opacity: .85; }
.${PREFIX}__halo > div { width: 100%; height: 100%; background: var(--${PREFIX}-ring); clip-path: var(--${PREFIX}-clip); }
.${PREFIX}__shadow { filter: blur(var(--${PREFIX}-shadow-blur)); transform: translateY(var(--${PREFIX}-shadow-y)); }
.${PREFIX}__shadow > div { width: 100%; height: 100%; background: rgba(0, 0, 0, .48); clip-path: var(--${PREFIX}-clip); }
.${PREFIX}__frost {
  /* A mask, not clip-path: Chrome can drop clip-path on a backdrop-filter layer and frost the whole box. */
  -webkit-mask: var(--${PREFIX}-mask-fill) center / 100% 100% no-repeat; mask: var(--${PREFIX}-mask-fill) center / 100% 100% no-repeat;
  -webkit-backdrop-filter: blur(var(--${PREFIX}-frost)) saturate(1.6) brightness(1.08);
  backdrop-filter: blur(var(--${PREFIX}-frost)) saturate(1.6) brightness(1.08);
  background:
    radial-gradient(circle at 26% 22%, rgba(255, 255, 255, .3), rgba(255, 255, 255, 0) 30%),
    linear-gradient(135deg, rgba(255, 255, 255, .8) 8%, rgba(228, 234, 255, .66) 52%, rgba(214, 224, 255, .56) 92%);
}
@supports not ((backdrop-filter: blur(1px)) or (-webkit-backdrop-filter: blur(1px))) {
  .${PREFIX}__frost { background:
    radial-gradient(circle at 24% 20%, rgba(255, 255, 255, .4), rgba(255, 255, 255, 0) 34%),
    linear-gradient(135deg, rgba(236, 240, 255, .86) 8%, rgba(190, 200, 235, .66) 92%); }
}
.${PREFIX}__inner { clip-path: var(--${PREFIX}-clip); }
.${PREFIX}__inner > div { width: 100%; height: 100%; filter: blur(var(--${PREFIX}-inner-blur)); }
.${PREFIX}__inner > div > div { width: 100%; height: 100%; background: var(--${PREFIX}-ring);
  -webkit-mask: var(--${PREFIX}-mask-inner) center / 100% 100% no-repeat; mask: var(--${PREFIX}-mask-inner) center / 100% 100% no-repeat; }
.${PREFIX}__rim { background: var(--${PREFIX}-ring);
  -webkit-mask: var(--${PREFIX}-mask-rim) center / 100% 100% no-repeat; mask: var(--${PREFIX}-mask-rim) center / 100% 100% no-repeat; }
.${PREFIX}__lit { overflow: visible; }

.${PREFIX}__bubble {
  position: absolute; top: 0; left: 0;
  display: inline-flex; align-items: center; gap: 6px;
  max-width: 280px; width: max-content;
  padding: 7px 12px; border-radius: 999px;
  font: 600 12px/1.25 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Inter", "Segoe UI", system-ui, sans-serif;
  letter-spacing: -0.005em;
  color: var(--${PREFIX}-ink);
  white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
  background: var(--${PREFIX}-glass);
  -webkit-backdrop-filter: blur(18px) saturate(1.8);
  backdrop-filter: blur(18px) saturate(1.8);
  box-shadow: 0 4px 12px rgba(0, 0, 0, .24), 0 0 0 .5px rgba(0, 0, 0, .12);
  transform-origin: 0 0;
  opacity: 0; transform: scale(.85);
  transition: opacity .2s ease, transform .32s cubic-bezier(.3, 1.35, .5, 1);
}
.${PREFIX}__bubble::before {
  content: ''; position: absolute; inset: 0; border-radius: inherit; padding: .8px; pointer-events: none;
  background: linear-gradient(to bottom, var(--${PREFIX}-glass-edge-top), var(--${PREFIX}-glass-edge-bottom));
  -webkit-mask: linear-gradient(#000 0 0) content-box, linear-gradient(#000 0 0);
  -webkit-mask-composite: xor; mask: linear-gradient(#000 0 0) content-box exclude, linear-gradient(#000 0 0);
}
.${PREFIX}.is-flipped .${PREFIX}__bubble { transform-origin: 100% 0; }
.${PREFIX}__bubble.is-on { opacity: 1; transform: scale(1); }
@media (prefers-reduced-motion: reduce) {
  .${PREFIX}.is-active { animation: none; }
  .${PREFIX}__bubble { transition: opacity .2s ease; transform: none; }
}
`;

function injectStyles() {
  if (document.getElementById(`${PREFIX}-styles`)) return;
  const el = document.createElement('style');
  el.id = `${PREFIX}-styles`;
  el.textContent = STYLE;
  document.head.appendChild(el);
}

/**
 * ArrowShape's outline, with each corner rounded like CGPath.addArc(tangent1End:tangent2End:radius:).
 * Coordinates are offset by `pad` so strokes and blur have room. Returns the SVG path and the
 * visible tip (the middle of the tip's arc).
 */
function arrowPath(W, H, pad) {
  const side = Math.min(W, H);
  const pts = CORNERS.map(([fx, fy]) => [pad + fx * W, pad + fy * H]);
  const f = (n) => +n.toFixed(3);
  const start = [(pts[0][0] + pts[3][0]) / 2, (pts[0][1] + pts[3][1]) / 2];
  let d = `M${f(start[0])} ${f(start[1])}`;
  let prev = start, tip = null;
  for (let i = 0; i < 4; i++) {
    const p1 = pts[i], p2 = pts[(i + 1) % 4], r = CORNERS[i][2] * side;
    const n = (v) => { const l = Math.hypot(v[0], v[1]); return [v[0] / l, v[1] / l]; };
    const v1 = n([prev[0] - p1[0], prev[1] - p1[1]]);
    const v2 = n([p2[0] - p1[0], p2[1] - p1[1]]);
    const theta = Math.acos(Math.min(1, Math.max(-1, v1[0] * v2[0] + v1[1] * v2[1])));
    const dist = r / Math.tan(theta / 2);
    const t1 = [p1[0] + v1[0] * dist, p1[1] + v1[1] * dist];
    const t2 = [p1[0] + v2[0] * dist, p1[1] + v2[1] * dist];
    // Turning right on screen (y down) sweeps clockwise.
    const cross = (p1[0] - prev[0]) * (p2[1] - p1[1]) - (p1[1] - prev[1]) * (p2[0] - p1[0]);
    d += ` L${f(t1[0])} ${f(t1[1])} A${f(r)} ${f(r)} 0 0 ${cross > 0 ? 1 : 0} ${f(t2[0])} ${f(t2[1])}`;
    if (i === 0) {
      const u = n([v1[0] + v2[0], v1[1] + v2[1]]);
      const k = r / Math.sin(theta / 2) - r;
      tip = [p1[0] + u[0] * k - pad, p1[1] + u[1] * k - pad];
    }
    prev = t2;
  }
  return { d: d + ' Z', tip };
}

const svgUrl = (inner, w, h) =>
  `url("data:image/svg+xml,${encodeURIComponent(
    `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}">${inner}</svg>`)}")`;

/** OverlayController.ease: cubic ease in-out. */
const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);

/** OverlayController.arc: quadratic Bézier with the control point lifted (y down here). */
function arc(a, b, t) {
  const mid = [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2];
  const lift = Math.min(140, Math.hypot(b[0] - a[0], b[1] - a[1]) * 0.25);
  const c = [mid[0], mid[1] - lift];
  const u = 1 - t;
  return [u * u * a[0] + 2 * u * t * c[0] + t * t * b[0], u * u * a[1] + 2 * u * t * c[1] + t * t * b[1]];
}

/**
 * Creates the buddy inside `container`.
 * @param {HTMLElement} container
 * @param {{size?: number, theme?: 'dark'|'light'}} [opts] size: arrow width in px (the app's is 20pt)
 * @returns {{ el: HTMLElement, moveTo(x: number, y: number, opts?: {label?: string}): Promise<void>,
 *             say(text: string): void, show(): void, hide(): void }}
 */
export function createBuddy(container, { size = 26, theme = 'dark' } = {}) {
  injectStyles();
  if (getComputedStyle(container).position === 'static') container.style.position = 'relative';

  const W = size, H = Math.round(size * 1.15 * 100) / 100, s = size / 20;
  const pad = Math.ceil(14 * s);
  const BW = W + pad * 2, BH = H + pad * 2;
  const { d, tip } = arrowPath(W, H, pad);
  const reduceQuery = window.matchMedia ? window.matchMedia('(prefers-reduced-motion: reduce)') : null;
  const reduced = () => !!(reduceQuery && reduceQuery.matches);

  const el = document.createElement('div');
  el.className = `${PREFIX}${theme === 'light' ? ` ${PREFIX}--light` : ''}`;
  el.setAttribute('aria-hidden', 'true');
  el.style.setProperty(`--${PREFIX}-clip`, `path('${d}')`);
  el.style.setProperty(`--${PREFIX}-mask-inner`, svgUrl(
    `<path d="${d}" fill="none" stroke="#fff" stroke-width="${(3.5 * s).toFixed(2)}" stroke-linejoin="round"/>`, BW, BH));
  el.style.setProperty(`--${PREFIX}-mask-fill`, svgUrl(`<path d="${d}" fill="#fff"/>`, BW, BH));
  el.style.setProperty(`--${PREFIX}-mask-rim`, svgUrl(
    `<path d="${d}" fill="none" stroke="#fff" stroke-width="${(1.4 * s).toFixed(2)}" stroke-linejoin="round"/>`, BW, BH));
  el.style.setProperty(`--${PREFIX}-halo-blur`, `${(6.5 * s).toFixed(2)}px`);
  el.style.setProperty(`--${PREFIX}-halo-blur-active`, `${(10 * s).toFixed(2)}px`);
  el.style.setProperty(`--${PREFIX}-shadow-blur`, `${(1.5 * s).toFixed(2)}px`);
  el.style.setProperty(`--${PREFIX}-shadow-y`, `${(1 * s).toFixed(2)}px`);
  el.style.setProperty(`--${PREFIX}-inner-blur`, `${(1.6 * s).toFixed(2)}px`);
  el.style.setProperty(`--${PREFIX}-frost`, `${Math.max(3, 4 * s).toFixed(1)}px`);

  const gid = `${PREFIX}-lit-${Math.random().toString(36).slice(2, 8)}`;
  const box = `style="width:${BW}px;height:${BH}px;left:${-pad}px;top:${-pad}px"`;
  el.innerHTML = `
    <div class="${PREFIX}__arrow" style="width:${W}px;height:${H}px">
      <div class="${PREFIX}__layer ${PREFIX}__halo" ${box}><div></div></div>
      <div class="${PREFIX}__layer ${PREFIX}__shadow" ${box}><div></div></div>
      <div class="${PREFIX}__layer ${PREFIX}__frost" ${box}></div>
      <div class="${PREFIX}__layer ${PREFIX}__inner" ${box}><div><div></div></div></div>
      <div class="${PREFIX}__layer ${PREFIX}__rim" ${box}></div>
      <svg class="${PREFIX}__layer ${PREFIX}__lit" ${box} viewBox="0 0 ${BW} ${BH}" width="${BW}" height="${BH}">
        <defs><linearGradient id="${gid}" gradientUnits="userSpaceOnUse"
          x1="${pad}" y1="${pad}" x2="${pad + W * 0.62}" y2="${pad + H * 0.62}">
          <stop offset="0" stop-color="#fff" stop-opacity="1"/>
          <stop offset=".55" stop-color="#fff" stop-opacity=".28"/>
          <stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient>
          <clipPath id="${gid}-c"><path d="${d}"/></clipPath></defs>
        <path d="${d}" fill="none" stroke="url(#${gid})" stroke-width="${(1.6 * s).toFixed(2)}" clip-path="url(#${gid}-c)"/>
      </svg>
    </div>
    <div class="${PREFIX}__bubble" role="status"></div>`;
  container.appendChild(el);

  const arrowEl = el.querySelector(`.${PREFIX}__arrow`);
  const bubble = el.querySelector(`.${PREFIX}__bubble`);
  // Bubble beside the arrow, as OverlayView's HStack: 6pt spacing, 12pt down.
  const GAP = Math.round(6 * s), DROP = Math.round(10 * s);

  let pos = null;          // tip position, container px
  let flipped = false;
  let labelText = '', sayText = '';
  let flight = null;       // { raf, resolve }
  let shown = false;

  function place([x, y]) {
    pos = [x, y];
    const tx = flipped ? W - tip[0] : tip[0];
    el.style.transform = `translate3d(${(x - tx).toFixed(2)}px, ${(y - tip[1]).toFixed(2)}px, 0)`;
  }

  function layoutBubble() {
    bubble.style.top = `${DROP}px`;
    // Flipped: the bubble's right edge sits GAP left of the arrow.
    bubble.style.left = flipped ? `${-GAP}px` : `${W + GAP}px`;
    bubble.style.translate = flipped ? '-100% 0' : '0 0';
  }

  function setFlipped(f) {
    if (f === flipped) return;
    flipped = f;
    el.classList.toggle('is-flipped', f);
    layoutBubble();
    if (pos) place(pos);
  }

  let bubbleW = 0; // measured once per text change, not per frame
  function setText(text) {
    if (bubble.textContent !== text) {
      bubble.textContent = text;
      bubbleW = text ? Math.min(280, bubble.scrollWidth || text.length * 7 + 24) : 0;
    }
  }

  /** Bubble flips left of the arrow when it would run past the container's right edge
   *  (as OverlayController.place does at the screen edge), with a little hysteresis. */
  function wantFlip(x) {
    const room = container.clientWidth - (x + W + GAP + 8);
    if (!(labelText || sayText)) return flipped && room < 24;
    return room < bubbleW + (flipped ? 24 : 0);
  }

  function refreshBubble() {
    const text = labelText || sayText;
    if (text) {
      setText(text);
      bubble.classList.add('is-on');
    } else {
      bubble.classList.remove('is-on');
    }
    el.classList.toggle('is-active', !!text || !!flight);
  }

  layoutBubble();
  place([container.clientWidth * 0.5, container.clientHeight * 0.5]);

  // A hidden tab runs no animation frames: land at once so the promise still settles.
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden' && flight && flight.to) {
      cancelAnimationFrame(flight.raf);
      const f = flight; flight = null;
      setFlipped(wantFlip(f.to[0]));
      place(f.to);
      refreshBubble();
      f.resolve();
    }
  });

  function cancelFlight() {
    if (!flight) return;
    cancelAnimationFrame(flight.raf);
    clearTimeout(flight.timer);
    const { resolve } = flight;
    flight = null;
    resolve();
  }

  function moveTo(x, y, { label } = {}) {
    cancelFlight();
    labelText = label ? String(label) : '';
    if (labelText) setText(labelText);
    const from = pos.slice(), to = [x, y];
    return new Promise((resolve) => {
      const dist = Math.hypot(to[0] - from[0], to[1] - from[1]);
      if (!shown) show();
      if (reduced() || dist < 0.5 || document.visibilityState === 'hidden') {
        // No flight: fade out, move, fade back in.
        if (dist < 0.5 || document.visibilityState === 'hidden') {
          setFlipped(wantFlip(x));
          place(to);
          refreshBubble();
          resolve();
          return;
        }
        flight = { raf: 0, resolve, timer: 0 };
        el.style.transition = 'opacity .16s ease';
        el.style.opacity = '0';
        flight.timer = setTimeout(() => {
          setFlipped(wantFlip(x));
          place(to);
          refreshBubble();
          el.style.opacity = '';
          flight.timer = setTimeout(() => {
            el.style.transition = '';
            const f = flight; flight = null; refreshBubble(); f.resolve();
          }, 170);
        }, 170);
        return;
      }
      // The app flies 0.6s to a point; long trips on a big page get a little longer.
      const duration = Math.min(1100, 600 + Math.max(0, dist - 500) * 0.35);
      setFlipped(wantFlip(x));
      flight = { raf: 0, resolve, timer: 0, to };
      refreshBubble();
      let start = 0;
      const step = (now) => {
        if (!start) start = now;
        const t = Math.min(1, (now - start) / duration);
        const p = arc(from, to, ease(t));
        setFlipped(wantFlip(p[0]));
        place(p);
        if (t < 1) {
          flight.raf = requestAnimationFrame(step);
        } else {
          const f = flight; flight = null;
          refreshBubble();
          f.resolve();
        }
      };
      flight.raf = requestAnimationFrame(step);
    });
  }

  function say(text) {
    sayText = text ? String(text) : '';
    if (sayText && !labelText) setText(sayText);
    if (!labelText && pos) setFlipped(wantFlip(pos[0]));
    refreshBubble();
  }

  function show() {
    shown = true;
    el.classList.add('is-shown');
  }

  function hide() {
    shown = false;
    el.classList.remove('is-shown');
  }

  return { el, moveTo, say, show, hide };
}
