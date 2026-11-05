# Cursor Pilot

A small helper that lives next to your mouse cursor on macOS. Hold **⌃⌥** (Control + Option),
ask a question out loud, and Cursor Pilot looks at your screens, answers in a
spoken voice, and flies over to point at the thing you need. Give it access
and it works on your Mac like a co-worker: runs shell commands, edits files,
and clicks and types in apps, asking first when you want it to.

Native Swift/SwiftUI app on top of a Rust core. Talks to Claude with your own
Anthropic API key.

## How it fits together

```
cursor-pilot/
├── core/                 Rust: everything that is not UI
│   ├── src/claude.rs        streaming Messages API client (raw HTTP + SSE)
│   ├── src/engine.rs        one request: prompt, screenshots, the agent loop, reply routing
│   ├── src/agent.rs         tools: persistent shell, file editor, risk rules, approvals
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
│       ├── VoiceInput.swift     push-to-talk speech recognition (SpeechAnalyzer on macOS 26)
│       ├── ScreenCapture.swift  ScreenCaptureKit, every display, downscaled JPEG
│       ├── Speaker.swift        spoken replies, best installed voice per sentence language
│       ├── Agent.swift          approval panel, mouse/keyboard/screenshot actions for Claude
│       ├── HotKey.swift         Carbon hot key, no Accessibility permission needed
│       ├── Shortcut.swift       user-chosen shortcut + recorder
│       ├── Notch.swift          panel that drops out of the notch
│       ├── Onboarding.swift     first-run setup
│       ├── Shaders.swift        Metal light effects: wave, fluid dots, Strands orb
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
- **computer** (`computer_toolset_20260801` on the 5.5 models): screenshots,
  clicks, typing, keys, scrolling and drags through CGEvent. Needs
  Accessibility. Cursor Pilot hides its own windows while it works.
- **web_search** on the models that support it.

Shell, file and web work happens out of sight: the buddy hides and the menu
bar and notch show a terminal. The buddy comes back next to the cursor only
when Claude uses the mouse and keyboard. In Home the current step shows
under the typing bubble, and a folded "n steps" line stays under the reply.
Up to 60 tool rounds per request.

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
`~/Applications` (`INSTALL_DIR=` skips that). Put build output elsewhere with
`BUILD_ROOT=/some/folder`.

Signing uses `CODESIGN_IDENTITY`, else your first Apple Development or
Developer ID identity, else a local "Cursor Pilot Development" identity.
Without any of them it signs ad hoc, and macOS asks for Microphone, Speech,
Screen Recording and keychain access again after every rebuild. To stop
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

```bash
open "build/Cursor Pilot.app" --args -CPShaderGallery YES
```

With ad-hoc signing every rebuild is a new app to macOS, so it asks again
for keychain access and privacy permissions. A free Apple Development
certificate (Xcode › Settings › Accounts › Manage Certificates) gives builds
a stable identity; the build script uses it automatically.

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
| Accessibility | only for clicking and typing once you let Cursor Pilot work on your Mac |

Talking needs no Accessibility permission: the shortcut is a Carbon hot key
and the buddy only reads the mouse position.

## Voice

- Speech recognition uses Apple's SpeechAnalyzer model on macOS 26 (fast,
  on-device, punctuated), falling back to SFSpeechRecognizer for languages it
  does not cover. With the language on Automatic, Cursor Pilot listens in the
  first of your preferred languages the new model supports.
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
- **Visuals**: native Metal light effects. A glass orb that follows your
  voice while listening, merging dots while thinking, a chromatic wave while
  speaking. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
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
