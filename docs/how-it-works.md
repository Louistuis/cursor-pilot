[← Back to the README](../README.md)

# How it works

A native Swift and SwiftUI app on top of a Rust core. The Swift side owns
everything you see and hear; the core talks to the model and runs the agent.

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
│       ├── Speaker.swift        spoken replies, in order, per sentence language and engine
│       ├── CloudSpeech.swift    OpenRouter speech: MAI / Scribe / GPT hearing, MAI-Voice / Eleven v4 voices
│       ├── LocalSpeech.swift    Whisper and Kokoro on the Neural Engine, audio queue and recorder
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
│       ├── Board.swift          the whiteboard Claude draws explanations on
│       ├── Scene3D.swift        3D models from scene blocks, the 3D panel and chat card
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
rectangle, and `<underline>`, `<highlight>`, `<trace>`, `<note>`,
`<spotlight>` (dims all but one spot), `<step n>` (numbered badges),
`<check>`, `<cross>` and `<bracket>` do what they say. Each takes `screen`
and `label`. Tags are removed from what is shown and spoken.

The buddy holds the pen. Drawings go on one after another as the voice
reaches them: the buddy flies to where each one starts and moves along the
stroke at an even pace while the ink appears (a dot of ink at its tip), so
it looks drawn by hand. Marks stay pinned to what they mark: to a nearby
piece of content found through Accessibility (a line of text, an image, a
control, never the page or a big container), followed at 60 fps, so they
move with a web page or document as it scrolls and hide when it scrolls
away; where there's no such element they follow the scroll wheel over
their window. They fade after 12 seconds.

While it thinks, the buddy's arrow turns into the notch's merging dots in
a small dark orb, lit in the buddy's colour, and springs back to the arrow
when it answers. The caption by the cursor reads along with the voice and
grows and shrinks with its words.

**Whiteboard.** To explain something (how it works, the steps, how ideas
relate) Claude can open a glass whiteboard over your screen with
`<board title/>` and draw on it while it talks: `<card id x y text icon/>`
boxes with an SF Symbol, `<link from to text/>` arrows between them,
`<write x y text size/>` handwriting, and any mark above with
`screen="board"`, in board units (1000 × 600). It works without
screenshots and is included in the next screenshot, so you can ask about
it. When the explanation is over it closes by itself after a while (never
while the pointer is on it), or with ✕ or Esc; every board is kept
(boards.json) and shows under its reply in Home, to open again.

**3D.** For something physical or spatial Claude can send a ```scene block
of JSON (spheres, boxes, cylinders, cones, tori, rings, capsules,
pyramids and planes, with colours, labels, spin, orbits, parents and links).
It opens as a model you can turn in a floating glass panel as soon as the
block is complete, closes by itself a while after the answer, and stays in
the chat as a small 3D card that opens it again. `<focus id/>`
then lights up a part, swings the camera to it and sends the buddy to point
at it, in time with the voice.

## Working on your Mac

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
  shows what the task is doing with a stop button. It never talks to you:
  when it's done you hear a sound and its report goes back to the main
  agent (a request with `handback` set, sent as soon as nothing else is
  being asked or said), which tells you what came of it in its own words
  and voice, the live voice included. A report that arrives while you're
  asking something, or while the agent is at work, rides along with that
  instead; if the agent can't be reached, the report shows in the chat as
  written. Up to three run at once.
- **web_search** and **web_fetch** (reads a page in full) on the models
  that support them.
- **plan** (ours): a checklist Claude keeps for tasks with several steps;
  the step in progress shows by the buddy ("Step 2 of 4: …").

The system prompt asks it to work like an engineer in a terminal: do the work
in the background with the shell, files, app_control and the web, use the
pointer only for what has no other way, plan bigger tasks, look before
changing things and check each change, and make independent calls in one
turn. A request may take up to 300 rounds (helpers 150), and a shell command
up to 5 minutes.

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

While the agent has your pointer, macOS's arrow turns into the buddy: the
system cursor is hidden (the window server lets a background app do this once
its connection sets `SetsCursorInBackground`) and the buddy's tip sits exactly
on the pointer. The agent's events carry a marker in `eventSourceUserData`, so
the first movement of your own hand brings your arrow straight back, as does
1.4 s without the agent touching the pointer. Apps that show the cursor
themselves as it moves (video players) are countered by hiding it again on
each move; every hide is counted and undone.

While a task works in the background (shell, files, web, app_control
reading), the buddy flies up into the notch and melts into the notch's
thinking dots, and the notch lights up: the buddy's colours turn slowly
around its edge with a glow spilling out, the step's icon pulses in the left
wing and the command shows in its header when open. The screen frame is off
meanwhile. The buddy flies back down to the cursor to talk, or to click and
type on screen (computer steps, app_control presses and fields). Each change
has to last a moment (0.35 s up, 0.2 s down, and 0.25/0.45 s for the dots)
so quick steps and pauses between sentences never make it bounce. With the
notch turned off, the buddy stays by the cursor as the thinking dots, with a
capsule beside it showing the latest step. A background agent at work also
lights the notch. Helpers and background agents work the same way: their
cursors wait unseen in the notch and fly out only to click and type on
screen, then go back up after 3.5 s without on-screen work.

Every change of state is animated so it reads at a glance: the buddy shrinks
and fades as it flies into the notch (its words go first) and the notch's
dots take a gulp as it lands, then it grows back out on the way down; each
new step slides up in place of the last one, by the buddy and in the notch's
header, and step icons morph into each other; a finished task pops a green
check into the notch's left wing; an error shakes the bubble like a "no".

It talks as it works, like a person next to you: before each action or
group of actions it says in one short sentence what it's about to do
("Opening your Downloads."), read aloud while the buddy stays in the notch.
Visible actions (clicks, typing, app_control) wait until that line has
started playing (at most 2.5 s), so it's said before it's done.

**Talk any time while it works**, with every speech engine: holding the
talk key (or cutting in, hands-free) during a task stops what it's saying
but not the work. What you say goes to the running agent with the result of
its current step (`cp_core_tell`, an inbox per request), the way a note is
passed to someone mid-task: it can add to the task, change it, ask how it's
going, or stop it, and the agent answers in a few words and carries on.
Background agents keep running throughout. Said too late to be read (the
agent was already answering), it becomes the next question. With the live
voice, the realtime model hears you while Claude works, answers "how's it
going?" from the progress it has been told, and passes anything for the
task to the agent the same way. `-CPAsk … -CPTell "text"` tests it.

**Hands-free conversation** (Settings › Talking, off by default; hold the talk key otherwise): after an
answer the mic stays open for up to 7 seconds so you can just reply; it ends
itself 0.9 s after you stop talking, and the screen frame stays off until
you actually speak. While it talks the mic listens too, with voice
processing (echo cancellation) on, and you can cut in by talking: three or
more words it isn't saying itself, heard while the mic is loud, stop it and
it listens to you (background tasks carry on). The talk key works as before.

The agent you talk to stays free: anything that takes more than a few quick
steps (research, building or fixing something, going through many files or
pages) goes to a background agent right away, and it answers in a line, so
you can keep talking to it while the work goes on.

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

## Memory

When you tell Cursor Pilot something worth keeping ("I'm on a German
keyboard", "keep answers short") or say "remember that…", it saves one short
fact to `memory.json` in its data folder and gets those facts in every later
chat. Settings › Memory lists them; remove one or forget everything there.

Home's chat reads like a text thread: your messages on the right, Cursor
Pilot's short replies on the left, one bubble per thought.

Press **⌃⌥D** to draw on the screen yourself. Ask about the drawing from the
toolbar (or hold the talk shortcut): the screenshot then includes your strokes
and Claude is told they are yours. Save keeps a snapshot in Home › Drawings.
