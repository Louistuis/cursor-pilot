// The only place the URL lives: every [data-github] link and the clone
// command are filled from it.
const GITHUB_URL = 'https://github.com/Louistuis/cursor-pilot';

const root = document.documentElement;
const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');
const darkScheme = matchMedia('(prefers-color-scheme: dark)');

/* ---------- Links and small bits ---------- */

for (const a of document.querySelectorAll('[data-github]')) {
  a.href = GITHUB_URL;
  a.rel = 'noopener';
}
for (const el of document.querySelectorAll('[data-github-clone]')) {
  // Let the URL wrap after slashes on narrow screens instead of mid-word.
  el.replaceChildren();
  `${GITHUB_URL}.git`.split(/(?<=\/)/).forEach((part, i) => {
    if (i) el.append(document.createElement('wbr'));
    el.append(part);
  });
}

// App icon: show the gradient fallback if the PNG is missing.
for (const img of document.querySelectorAll('.app-icon img')) {
  const fail = () => img.parentElement.classList.add('is-missing');
  if (img.complete && img.naturalWidth === 0) fail();
  else img.addEventListener('error', fail, { once: true });
}

// Copy buttons copy the commands without the "$ " prompts.
for (const btn of document.querySelectorAll('[data-copy]')) {
  btn.addEventListener('click', async () => {
    const src = document.getElementById(btn.dataset.copy);
    if (!src) return;
    const clone = src.cloneNode(true);
    clone.querySelectorAll('.c-prompt').forEach((n) => n.remove());
    try {
      await navigator.clipboard.writeText(clone.textContent.trim());
      btn.textContent = 'Copied';
    } catch {
      btn.textContent = 'Select and copy';
    }
    setTimeout(() => { btn.textContent = 'Copy'; }, 1800);
  });
}

/* ---------- Scroll reveal ---------- */

const reveals = document.querySelectorAll('.reveal');
if ('IntersectionObserver' in window && !reduceMotion.matches) {
  // Stagger siblings that reveal together (cards in a grid).
  const groups = new Map();
  for (const el of reveals) {
    const list = groups.get(el.parentElement) || [];
    list.push(el);
    groups.set(el.parentElement, list);
  }
  for (const list of groups.values()) {
    list.forEach((el, i) => el.style.setProperty('--d', `${Math.min(i, 5) * 70}ms`));
  }
  const io = new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (e.isIntersecting) {
        e.target.classList.add('is-in');
        io.unobserve(e.target);
      }
    }
  }, { rootMargin: '0px 0px -8% 0px', threshold: 0.08 });
  reveals.forEach((el) => io.observe(el));
} else {
  reveals.forEach((el) => el.classList.add('is-in'));
}
root.classList.add('ready');

/* ---------- Hero demo ---------- */

const mock = document.querySelector('.mock');
const canvas = document.getElementById('glow-hero');
const stage = document.getElementById('buddy-stage');
const chatLog = mock?.querySelector('[data-chat-log]');
const notchLabel = mock?.querySelector('[data-notch-label]');

const SCRIPT = [
  {
    q: "where's the export button?",
    a: 'Top right, next to Share. Click it and pick PDF.',
    target: '[data-target="export"]',
    label: 'Export',
  },
  {
    q: 'which file did I download last?',
    a: "Invoice-Nov.pdf. It's the one on your desktop.",
    target: '[data-target="file"]',
    label: 'Invoice-Nov.pdf',
  },
];

const NOTCH_TEXT = { listening: 'Listening', thinking: 'Thinking', answering: 'Answering', idle: '' };

let glow = null;
let buddy = null;
let visible = false;
let resumeWaiters = [];

function setVisible(v) {
  visible = v;
  if (v) {
    resumeWaiters.forEach((r) => r());
    resumeWaiters = [];
  }
}

// Sleeps for `ms` of on-screen time: the clock stops while the hero is off-screen.
async function sleep(ms) {
  let left = ms;
  while (left > 0) {
    if (!visible) await new Promise((r) => resumeWaiters.push(r));
    const t0 = performance.now();
    await new Promise((r) => setTimeout(r, Math.min(left, 120)));
    left -= performance.now() - t0;
  }
}

function setState(state) {
  mock.dataset.state = state;
  if (NOTCH_TEXT[state]) notchLabel.textContent = NOTCH_TEXT[state];
  try { glow?.setMode(state); } catch { /* effect is optional */ }
}

function addBubble(kind, text = '') {
  const b = document.createElement('div');
  b.className = `bubble bubble--${kind} is-new`;
  if (kind === 'typing') {
    b.className = 'bubble bubble--bot bubble--typing is-new';
    b.innerHTML = '<i></i><i></i><i></i>';
  } else {
    b.textContent = text;
  }
  chatLog.append(b);
  // Keep the log short so it never needs to scroll.
  while (chatLog.children.length > 4) chatLog.firstElementChild.remove();
  return b;
}

function pointFor(el) {
  const s = stage.getBoundingClientRect();
  const t = el.getBoundingClientRect();
  // Aim the tip just inside the lower middle of the target.
  return { x: t.left - s.left + t.width * 0.55, y: t.top - s.top + t.height * 0.62 };
}

function restPoint() {
  const s = stage.getBoundingClientRect();
  const chat = mock.querySelector('.mock-chat').getBoundingClientRect();
  return { x: chat.left - s.left + chat.width * 0.35, y: chat.top - s.top - s.height * 0.06 };
}

// Never let a missing or slow effect stall the loop.
function capped(promise, ms) {
  return Promise.race([Promise.resolve(promise).catch(() => {}), new Promise((r) => setTimeout(r, ms))]);
}

let currentTarget = null;

async function runExchange({ q, a, target, label }) {
  const targetEl = mock.querySelector(target);

  setState('idle');
  await sleep(900);

  // Listening: the question appears word by word as it's spoken.
  setState('listening');
  const words = q.split(' ');
  const me = addBubble('me', words[0]);
  for (let i = 1; i < words.length; i++) {
    await sleep(240);
    me.textContent += ` ${words[i]}`;
  }
  await sleep(700);

  // Thinking.
  setState('thinking');
  const typing = addBubble('typing');
  try { buddy.say('Thinking'); } catch {}
  await sleep(1500);

  // The buddy flies to the target and points.
  try { buddy.say(''); } catch {}
  const p = pointFor(targetEl);
  currentTarget = targetEl;
  await capped(buddy.moveTo(p.x, p.y, { label }), 2200);
  targetEl.classList.add('is-target');

  // Answering.
  setState('answering');
  typing.remove();
  addBubble('bot', a);
  await sleep(3000);

  // Pause, then head back to rest.
  setState('idle');
  targetEl.classList.remove('is-target');
  currentTarget = null;
  const r = restPoint();
  await capped(buddy.moveTo(r.x, r.y), 1600);
  await sleep(1600);
}

async function loop() {
  chatLog.replaceChildren();
  const r = restPoint();
  await capped(buddy.moveTo(r.x, r.y), 50);
  try { buddy.show(); } catch {}
  for (let i = 0; ; i = (i + 1) % SCRIPT.length) {
    await runExchange(SCRIPT[i]);
  }
}

// Reduced motion: one still frame of the answer, no loop.
async function stillFrame() {
  const { a, q, target, label } = SCRIPT[0];
  chatLog.replaceChildren();
  addBubble('me', q).classList.remove('is-new');
  addBubble('bot', a).classList.remove('is-new');
  const el = mock.querySelector(target);
  el.classList.add('is-target');
  currentTarget = el;
  setState('answering');
  const p = pointFor(el);
  try { buddy.show(); } catch {}
  await capped(buddy.moveTo(p.x, p.y, { label }), 2000);
}

/* Fallback buddy with the same API as buddy.js, used if the module is missing. */
function createFallbackBuddy(container) {
  const el = document.createElement('div');
  el.className = 'fb-buddy';
  el.innerHTML = `
    <svg viewBox="0 0 24 28" width="24" height="28" aria-hidden="true">
      <defs>
        <linearGradient id="fbRim" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stop-color="#59E0FF"/><stop offset=".3" stop-color="#6B7AFF"/>
          <stop offset=".55" stop-color="#B866FF"/><stop offset=".8" stop-color="#FF6BD1"/>
          <stop offset="1" stop-color="#FFAD5C"/>
        </linearGradient>
      </defs>
      <path d="M3.2 2.6c0-.9 1-1.4 1.7-.8l16 13.1c.7.6.3 1.8-.6 1.8h-6.6c-.4 0-.8.2-1 .5l-3.8 5.6c-.6.8-1.8.5-1.8-.5Z"
        fill="rgba(255,255,255,.55)" stroke="url(#fbRim)" stroke-width="1.8" stroke-linejoin="round"/>
    </svg>
    <span class="fb-label"></span>`;
  const labelEl = el.querySelector('.fb-label');
  container.append(el);
  const ARROW_TIP = 3; // px from the svg's top left to its tip
  return {
    el,
    moveTo(x, y, { label } = {}) {
      labelEl.classList.remove('is-shown');
      el.style.setProperty('--x', `${x - ARROW_TIP}px`);
      el.style.setProperty('--y', `${y - ARROW_TIP}px`);
      return new Promise((resolve) => {
        setTimeout(() => {
          if (label) {
            labelEl.textContent = label;
            labelEl.classList.add('is-shown');
          }
          resolve();
        }, reduceMotion.matches ? 0 : 900);
      });
    },
    say(text) {
      labelEl.textContent = text;
      labelEl.classList.toggle('is-shown', Boolean(text));
    },
    show() { el.classList.add('is-shown'); },
    hide() { el.classList.remove('is-shown'); },
  };
}

function glowRadius() {
  const screen = canvas.parentElement;
  return parseFloat(getComputedStyle(screen).borderTopLeftRadius) || 18;
}

function mountGlowSafely(mod) {
  try {
    glow = mod.mountGlow(canvas, { mode: mock.dataset.state || 'idle', radius: glowRadius() });
    mock.classList.add('has-glow');
  } catch {
    glow = null;
    mock.classList.remove('has-glow');
  }
}

async function startHero() {
  if (!mock || !canvas || !stage || !chatLog) return;

  let glowMod = null;
  try {
    glowMod = await import('./glow.js');
    if (typeof glowMod.mountGlow === 'function') mountGlowSafely(glowMod);
  } catch { /* the CSS frame stays as the fallback */ }

  try {
    const { createBuddy } = await import('./buddy.js');
    const size = Math.round(Math.max(18, Math.min(28, stage.clientWidth * 0.024)));
    buddy = createBuddy(stage, { size, theme: darkScheme.matches ? 'dark' : 'light' });
  } catch {
    buddy = null;
  }
  if (!buddy) buddy = createFallbackBuddy(stage);

  // Run only while the hero is on screen; stop the glow's frames when it isn't.
  const onVisibility = (onScreen) => {
    const v = onScreen && !document.hidden;
    if (v === visible) return;
    setVisible(v);
    if (!glowMod) return;
    if (v && !glow) mountGlowSafely(glowMod);
    if (!v && glow) {
      try { glow.destroy(); } catch {}
      glow = null;
    }
  };
  let onScreen = false;
  new IntersectionObserver(([e]) => {
    onScreen = e.isIntersecting;
    onVisibility(onScreen);
  }, { threshold: 0.05 }).observe(mock);
  document.addEventListener('visibilitychange', () => onVisibility(onScreen));

  // Keep the buddy on its target if the layout changes size.
  let resizeRaf = 0;
  new ResizeObserver(() => {
    cancelAnimationFrame(resizeRaf);
    resizeRaf = requestAnimationFrame(() => {
      if (currentTarget) {
        const p = pointFor(currentTarget);
        capped(buddy.moveTo(p.x, p.y), 50);
      }
    });
  }).observe(stage);

  if (reduceMotion.matches) stillFrame();
  else loop();
}

startHero();
