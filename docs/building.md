[← Back to the README](../README.md)

# Building from source

Needs macOS 15 or later, Xcode (Swift 5.10+) and Rust (`rustup`).

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
| `-CPHomeDemo chat:0,find:word` | puts Home in a state: `chat:N` opens the Nth newest chat, `find:word`, `palette`, `slash`, `hover`, `side` |
| `-CPLiveTest out.json -CPLiveQuiet YES` | talks to the live voice with typed lines: a hello, a task, a dropped connection, a background report and a question about what was said before; `-CPLiveQuiet` plays it at no volume |
| `-CPBuddyDemo listening` | holds the buddy in `listening`, `thinking` or `answering` |
| `-CPAsk "question"` | asks a typed question at launch, without screenshots |
| `-CPRenderArrowPreview file.png` | renders the buddy arrow large and at real size to a PNG, then quits |
| `-CPRenderInkPreview file.png` | renders sample ink marks and the sketch toolbar to a PNG, then quits |
| `-CPRenderBoardPreview out.png` | renders a finished sample whiteboard |
| `-CPRenderScenePreview out.png` | renders the sample 3D model, whole and in focus (`out-focus.png`) |
| `-CPShow "question" -CPOut f.png` | asks for real with the screen (nothing spoken) and saves a screenshot every two seconds while it answers |
| `-CPRenderGlowPreview file.png` | renders the screen glow (listening, thinking, sketching) to `file-<mode>.png`, then quits |
| `-CPRenderTrailPreview file.png` | renders the buddy still and moving ever faster, plus its click ring, in every colour, then quits |
| `-CPRunActions steps.json` | runs agent actions (`apps`, `computer`, `wait` steps) like the agent would, writes what each returned to `-CPOut` (default `steps.json.out.json`), then quits |
| `-CPAsk "question"` | sends one typed question through the whole agent (helpers included, no screen, nothing spoken), writes the text, steps, helper events and timings to `-CPOut`, then quits |
| `-CPRenderHelperPreview out.png` | renders the helpers' cursors and tags |
| `-CPRenderChartPreview out.png` | renders the kinds of chart a reply can send |
| `-CPRenderJobsPreview out.png` | renders background tasks' cards, at work and done |
| `-CPPermissions out.json` | writes which permissions are allowed, checked without asking |
| `-CPHear "a.aiff\|b.aiff"` | runs audio files through speech recognition in every automatic language, then the chosen engine, writes what each heard to `-CPOut`, then quits |
| `-CPSay "Hello.\|Hei."` | renders each line with the chosen engine (`-speechEngine cloud\|local\|apple`) to `<-CPOut>-N.wav` without playing it, timings in `<-CPOut>.json` |
| `-CPCursorTest out` | moves the real pointer 80 pt and back like the agent, screenshots it (cursor included) as the buddy takes it over and after it hands it back, writes whether the arrow was hidden to `out.json` |
| `-CPMorphPreview out` | plays the buddy turning into the thinking dots and back on white and dark, saving frames as `out-NN.png` |
| `-CPNotchDemo chat\|caption` | fills the notch with a sample exchange or a live caption |

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
