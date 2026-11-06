# Cursor Pilot

A small helper that lives next to your mouse cursor on macOS. Hold **⌃⌥** (Control + Option),
ask a question out loud, and Cursor Pilot looks at your screens, answers in a
spoken voice, and flies over to point at the thing you need. Give it access
and it works on your Mac like a co-user: runs shell commands, edits files,
and uses your apps with your own mouse and keyboard the way a person would,
handing them back the moment you move the mouse. (Or, if you prefer, with its
own pointer in the background.)

Native Swift/SwiftUI app on top of a Rust core. Talks to Claude with your own
Anthropic API key.

## How it fits together

```
cursor-pilot/
├── core/                 Rust: everything that is not UI
│   ├── src/claude.rs        streaming Messages API client (raw HTTP + SSE)
│   ├── src/engine.rs        one request: prompt, screenshots, the agent loop, reply routing
│   ├── src/agent.rs         tools: persistent shell, file editor, app control; the agent prompt
│   ├── src/memory.rs        facts Claude remembers about you between chats
│   ├── src/markup.rs        pulls <point/circle/arrow/box …/> tags out of the reply
│   ├── src/drawings.rs      saved drawings (PNG + JSON)
│   ├── src/speech.rs        splits the reply into sentences to speak early
│   ├── src/conversation.rs  live history + saved transcripts
│   ├── src/lib.rs           C ABI (JSON in, JSON events out)
│   └── include/cursor_pilot_core.h
├── mac/                  Swift package for the app
│   └── Sources/CursorPilot/
│       ├── AppModel.swift       hotkey → voice → screenshots → core → speech/overlay
│       ├── Overlay.swift        click-through buddy panel that follows the cursor
│       ├── VoiceInput.swift     push-to-talk speech recognition, two languages at once
│       ├── ScreenCapture.swift  ScreenCaptureKit, every display, downscaled JPEG
│       ├── Speaker.swift        spoken replies, best installed voice per sentence language
│       ├── Agent.swift          screenshots and the computer tool's clicks, typing and keys
│       ├── Pointer.swift        background input and the app_control tool (Accessibility)
│       ├── CoUser.swift         the real mouse and keyboard, moved and typed like a person
│       ├── Setup.swift          one-time permission setup; checks that never prompt
│       ├── Keychain.swift       API key in the login keychain, prompt-free across rebuilds
│       ├── Sounds.swift         quiet system sounds for listen, send, done, error
│       ├── TestHooks.swift      launch flags that test actions and speech without a person
│       ├── HotKey.swift         Carbon hot key, hold ⌃⌥, double-tap ⌃
│       ├── Shortcut.swift       user-chosen shortcut + recorder
│       ├── Notch.swift          panel that drops out of the notch
│       ├── Onboarding.swift     first-run setup
│       ├── Shaders.swift        Metal light effects: voice wave, fluid dots
│       ├── ShaderView.swift     SwiftUI canvas that renders them
│       ├── Ink.swift            Claude's circles/arrows/boxes, the pen, sketch toolbar
│       ├── Glow.swift           neon edge frame shader (from Zero OCR)
│       ├── ScreenGlow.swift     lights the screen edges while Cursor Pilot works
│       ├── HomeView.swift       chat window and history
│       └── SettingsView.swift   key, model, effort, permissions
└── scripts/
    ├── build-app.sh             builds core + app, assembles, signs and installs Cursor Pilot.app
    ├── dev-signing-identity.sh  one-time local signing identity so permissions survive rebuilds
    ├── make-icon.sh             draws the app icon with the glow shader (mac/Resources/AppIcon.icns)
    └── icon/main.swift          the icon drawing itself
```

A request flows like this: Swift captures the displays and sends
`{text, screens[]}` to the core. The core streams Claude's reply and emits
events back: `text` deltas for the bubble, `speak` sentences for the voice,
and `point` events already converted from screenshot pixels to global screen
coordinates. Swift animates the buddy along an arc to each point.

The model shows things by writing tags in its reply, all in screenshot
pixels: `<point x y/>` flies the buddy there, `<circle x y r/>` rings an area,
`<arrow x1 y1 x2 y2/>` shows a direction or drag, `<box x y w h/>` highlights a
rectangle. Each takes `screen` and `label`. Tags are removed from what is
shown and spoken; circles, arrows and boxes are drawn on screen like marker
strokes and fade after 12 seconds.

### Working on your Mac

Turn it on once, in onboarding or Settings › Working on your Mac, and
consent. From then on Cursor Pilot works on its own with no permission
prompts, in the background, and says what it's doing as it goes. It is off
until you turn it on. Tools, all run by the app on your Mac:

- **bash**: one persistent login `zsh` per conversation (`cd` and variables
  carry over), 3-minute timeout per command, stopped when you interrupt.
- **str_replace_based_edit_tool**: view, create and edit files; every edit
  keeps a backup under the app's data folder in `backups/`.
- **app_control** (ours): works with apps by name through Accessibility, in
  the background: list apps, open them without bringing them forward, list
  a window's controls, press buttons, fill in fields, read text, choose menu
  items. A control can be named directly (`press`, app `Calculator`,
  find `7`), so most steps need no screenshot at all.
- **computer** (`computer_toolset_20260801` on the 5.5 models): screenshots,
  clicks, typing, keys, scrolling and drags. Needs Accessibility.
- **memory** (ours, also without Mac access): remembers short facts about you
  between chats.
- **delegate** (ours): sends a helper agent off on part of the task. Up to
  five helpers (Mint, Sunset, Rose, Violet, Ocean) work at once, each with
  its own loop, shell and pointer: a small cursor in its colour with a tag
  saying what it's doing. Their steps stay out of the chat; each shows as one
  step until it reports back. They take turns with the real pointer and
  keyboard when an app needs them.

  Each helper has its own workspace. macOS doesn't let apps make desktops
  (Spaces) of their own, so a workspace is the set of windows the helper
  opened. Its screenshots show only its current window, captured even where
  your windows cover it, with coordinates tied to that window; its clicks,
  typing and scrolling go to that window (Accessibility hit tests are checked
  against it), and the real pointer is only borrowed where the window is
  uncovered. Web pages open in a browser of its own: a separate copy of
  Chrome (or Brave, Edge, Chromium, Vivaldi) with a private profile in
  `~/Library/Application Support/Cursor Pilot/Helpers/<name>`, kept drawing
  while covered, quit when the task ends; `shared: true` uses your browser
  instead. If an app opened in the background brings itself forward, your
  app is put back in front. A helper's cursor fades while it works under
  your windows.
- **background_task** (ours): hands a task to an independent background
  agent that does all of it on its own while you carry on and keep talking.
  It works like a helper (own cursor, shell, windows and private browser)
  but outlives the request: the main agent answers at once, a card in Home
  shows what the task is doing with a stop button, and when it's done you
  hear a sound, its report lands in the chat and is read aloud, and the
  main agent is told on your next message. Up to three run at once.
- **web_search** on the models that support it.

By default the agent works like a person sitting at your Mac (Settings ›
Working on your Mac › It works). It moves your real pointer on a slightly
curved path that speeds up and settles like a hand (Fitts-timed, with a small
correction after long moves), presses and releases clicks, types with a human
rhythm and brings an app forward before using it. app_control presses and
fills in fields by clicking and typing on screen, and falls back to
Accessibility for controls that are off screen. Move the mouse and it hands
over: it notices the pointer isn't where it left it, says "You've got it",
and waits until you have stopped for a moment. Helpers always work in their
own space.

In background mode the agent has its own pointer: the buddy flies to where it clicks (with
motion blur when it moves fast and a ring when it clicks), and the click
goes to the app under it without moving your pointer. Cursor Pilot first
presses, focuses or selects the control there through Accessibility; if
there is none it posts the click to that app's process. Typing goes to the
app it last clicked in, as text inserted through Accessibility or as key
events sent to that app, so you can keep typing elsewhere. A few apps only
react to the real pointer: when a click at the same spot is repeated, and for
drags, Cursor Pilot moves your pointer there for a split second and puts it
back (Settings › Working on your Mac turns that off).

Shell, file and web work happens out of sight: the buddy hides and the menu
bar and notch show a terminal. The buddy comes back only for work in apps.
In Home the current step shows under the typing bubble, and a folded
"n steps" line stays under the reply. Up to 60 tool rounds per request.

### Memory

When you tell Cursor Pilot something worth keeping ("I'm on a German
keyboard", "keep answers short") or say "remember that…", it saves one short
fact to `memory.json` in its data folder and gets those facts in every later
chat. Settings › Memory lists them; remove one or forget everything there.

Home's chat reads like a text thread: your messages on the right, Cursor
Pilot's short replies on the left, one bubble per thought.

Press **⌃⌥D** to draw on the screen yourself. Ask about the drawing from the
toolbar (or hold the talk shortcut): the screenshot then includes your strokes
and Claude is told they are yours. Save keeps a snapshot in Home › Drawings.

## Build

Needs Xcode (Swift 5.10+) and Rust (`rustup`).

```bash
scripts/build-app.sh
```

The app lands in `build/Cursor Pilot.app` and is copied to
`~/Applications` (`INSTALL_DIR=` skips that). To keep it in `/Applications`
instead, copy it there once with your password and make it yours; later
builds then update it in place:

```bash
sudo ditto ~/Applications/"Cursor Pilot.app" "/Applications/Cursor Pilot.app"
sudo chown -R "$USER" "/Applications/Cursor Pilot.app"
```

Put build output elsewhere with `BUILD_ROOT=/some/folder`.

Signing uses `CODESIGN_IDENTITY`, else your first Apple Development or
Developer ID identity, else a local "Cursor Pilot Development" identity.
Without any of them it signs ad hoc, and macOS asks for Microphone, Speech,
Screen Recording and Accessibility again after every rebuild. To stop
that, run this once (it adds a self-signed code-signing certificate to your
login keychain; no admin password, no trust changes):

```bash
scripts/dev-signing-identity.sh
```

Debug launch flags, for design work:

| Flag | Effect |
|---|---|
| `-CPPinNotch YES` | keeps the notch panel open |
| `-CPShaderGallery YES` | opens a window with every light effect |
| `-CPSkipKeychain YES` | does not read the saved API key (no keychain prompt) |
| `-CPOpenHome settings` | opens Home on `settings`, `drawings` or `chat` |
| `-CPBuddyDemo listening` | holds the buddy in `listening`, `thinking` or `answering` |
| `-CPAsk "question"` | asks a typed question at launch, without screenshots |
| `-CPRenderArrowPreview file.png` | renders the buddy arrow large and at real size to a PNG, then quits |
| `-CPRenderInkPreview file.png` | renders sample ink marks and the sketch toolbar to a PNG, then quits |
| `-CPRenderGlowPreview file.png` | renders the screen glow (listening, thinking, sketching) to `file-<mode>.png`, then quits |
| `-CPRenderTrailPreview file.png` | renders the buddy still and moving ever faster, plus its click ring, in every colour, then quits |
| `-CPRunActions steps.json` | runs agent actions (`apps`, `computer`, `wait` steps) like the agent would, writes what each returned to `-CPOut` (default `steps.json.out.json`), then quits |
| `-CPAsk "question"` | sends one typed question through the whole agent (helpers included, no screen, nothing spoken), writes the text, steps, helper events and timings to `-CPOut`, then quits |
| `-CPRenderHelperPreview out.png` | renders the helpers' cursors and tags |
| `-CPRenderChartPreview out.png` | renders the kinds of chart a reply can send |
| `-CPRenderJobsPreview out.png` | renders background tasks' cards, at work and done |
| `-CPPermissions out.json` | writes which permissions are allowed, checked without asking |
| `-CPHear "a.aiff\|b.aiff"` | runs audio files through speech recognition in every automatic language, writes what each heard to `-CPOut`, then quits |

Test flags run best in a second copy, so the one you use keeps running:

```bash
open -n "/Applications/Cursor Pilot.app" --args -CPRunActions ~/steps.json
```

```bash
open "build/Cursor Pilot.app" --args -CPShaderGallery YES
```

With ad-hoc signing every rebuild is a new app to macOS, so it asks again
for privacy permissions. A free Apple Development certificate (Xcode ›
Settings › Accounts › Manage Certificates) gives builds a stable identity;
the build script uses it automatically.

The API key is saved in the login keychain through `/usr/bin/security`,
which owns the item, so the keychain never asks to allow access, not even
after a rebuild. (Keys saved by older builds move over once, with one last
prompt.)

Rust tests and a command-line check of the core:

```bash
cd core && cargo test
ANTHROPIC_API_KEY=sk-ant-… cargo run --example ask -- "Why is the sky blue?"
```

## Permissions

| Permission | Why |
|---|---|
| Microphone, Speech Recognition | push-to-talk questions |
| Screen Recording | screenshots sent with each question |
| Accessibility | only for working in apps (pressing controls, clicking, typing) once you let Cursor Pilot work on your Mac |
| Full Disk Access | reading Messages, and files anywhere without macOS asking per folder |
| Contacts | names instead of numbers in messages |
| Automation (Messages, Finder, System Events) | sending texts, and the few scripts the agent may run |
| Local Network | reaching devices and servers on your network from a task |

Everything is asked for once, up front: Settings › Permissions › **Set Up
Everything** (and the onboarding's Allow Everything) shows the dialogs that
can appear in place one after the other, then opens System Settings at each
switch still off. While it works Cursor Pilot never asks: it only checks,
and when something is missing it says what to set up instead of putting a
dialog in front of you. The agent is told not to script other apps, which
would make macOS ask. macOS doesn't let apps grant themselves permissions,
so the switches stay yours. `-CPPermissions out.json` reports what's
allowed without asking.

If a permission is switched on but Cursor Pilot still can't use it, the
entry was made by an older build signed another way (for example ad hoc,
before you ran `dev-signing-identity.sh`). Reset it and allow it again:

```bash
tccutil reset Accessibility com.louistuis.cursorpilot   # or ScreenCapture
```

Talking needs no Accessibility permission: the shortcut is a Carbon hot key
and the buddy only reads the mouse position.

## Voice

- Speech recognition uses Apple's on-device SpeechAnalyzer models on macOS 26
  (SpeechTranscriber, or DictationTranscriber for languages only it covers,
  such as Norwegian), falling back to SFSpeechRecognizer. With the language on
  Automatic, Cursor Pilot listens for the first two languages in your Mac's
  language list at once, say Norwegian and English: both recognizers hear the
  same audio and the transcript its recognizer was surest of wins. Live text
  shows the language you spoke last.
- Double-tap **⌃** to type a question in the notch instead of saying it.
- Quiet system sounds mark listening, sending, a finished task and errors
  (Settings › On screen › Sound effects).
- Replies are read per sentence in that sentence's language, with the best
  installed voice: Premium, then Enhanced, then the system voice, never the
  novelty or Eloquence voices. For a natural voice, download a Premium one in
  System Settings › Accessibility › Spoken Content › System Voice › Manage
  Voices.

## Claude settings

- Default model `claude-opus-5-5` at `low` effort, because replies are spoken
  and speed matters. Model and effort are in Settings.
- Server-side refusal fallback (`fallbacks: "default"`) is on for the models
  that support it, so a declined request is retried on another model instead
  of failing.
- Automatic prompt caching is on; history is append-only (thinking blocks are
  replayed unchanged) and a conversation starts over after 15 idle minutes or
  20 exchanges.
- Sign-in is by API key only. Anthropic does not allow third-party apps to
  route requests through Claude.ai subscription plans.

## Roadmap

Done:

- **Phase 1**: voice questions, multi-display screenshots, streamed and
  spoken answers, pointing, chat history, settings.
- **Visuals**: native Metal light effects. A chromatic wave that follows
  your voice while listening and speaks with Cursor Pilot, and metaball dots
  that merge, scatter and gather while it thinks. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- **Phase 2**: notch panel (wings show listening / thinking / answering;
  hover the notch for the latest exchange and a quick-ask field), custom
  hold-to-talk shortcut, first-run onboarding.

- **Phase 3, Ink**: Claude circles, arrows and highlights things on screen;
  you can draw on the screen (⌃⌥D) and ask about your drawing; drawings
  are saved to Home.
- **Screen glow**: the colourful frame from Zero OCR lights the edges of
  every display while Cursor Pilot listens, thinks and answers, and softly
  while you draw (Settings › On screen to turn it off).
- **Feel pass**: hold ⌃⌥ alone to talk (no extra permission); the buddy
  follows the cursor on the display's refresh and fades away when idle;
  Home is a native sidebar app (chats by date with search, rename, delete
  and resume; Drawings; Settings with voice, language, speed and
  permissions); type or click the mic to talk in Home, read any reply
  aloud; one-click permissions with a restart button; Screen Recording is
  asked once instead of on every question; app icon.
- **Agent**: shell, file editing, computer use and web search after a
  one-time consent, with no prompts; the buddy only shows for mouse and
  keyboard work; texting-style chat; better speech recognition and voices.
- **Own pointer**: the agent clicks, types and scrolls in apps in the
  background without taking your mouse or keyboard; app_control works with
  apps by name; motion blur and click rings on the buddy; memory between
  chats; Norwegian and English recognised automatically; double-tap ⌃ to
  type; buddy colours; sound effects; an option to keep Cursor Pilot out of
  screenshots and recordings; no keychain prompts after rebuilds.
- **Co-user**: the agent uses your own mouse and keyboard like a person,
  with natural pointer paths, click timing and typing rhythm, and waits when
  you take over; background mode stays as an option.
- **No prompts while working**: one Set Up Everything step asks for every
  permission up front; at work it only checks.
- **Background tasks**: the agent can hand a whole task to an independent
  agent that finishes it on its own while you keep going.
- **Visuals in chat**: replies can send charts (a ```chart JSON block, drawn
  with Swift Charts: bar, line, area, point and pie, growing in, hover for
  values), images (`![alt](path or URL)`, shown like photos in Messages) and
  link preview cards (a link on its own line, via LinkPresentation). None of
  it is read aloud, and the notch shows them too.
- **Helpers**: the agent sends helper agents off in parallel, each with its
  own coloured cursor; works on its own without asking for what it can find
  out; notes while working are shown quietly and only the first line and the
  answer are read aloud; a calm glow during long tasks.

Next phases:

1. **Lessons**: record a step-by-step walkthrough once, replay it later with
   the buddy pointing at each step.
2. **Background jobs**: longer agent tasks in a work folder, with progress
   cards and results in Home.
3. **Polish**: reading the open document for full-file answers, app icon,
   notarised releases with auto-update.

## Website

The landing page lives in `site/` (plain HTML, CSS and JS) and is served at
https://cursorpilot.lou15.com by a static Cloudflare Worker. To deploy:

```bash
npx wrangler@4 deploy
```

## License

MIT, see [LICENSE](LICENSE).
