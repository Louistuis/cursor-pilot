[← Back to the README](../README.md)

# Roadmap

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
  while you draw (Settings › On screen to turn it off). It is bright for the
  first 3 seconds of an exchange, then eases down to about 40% and stays
  calm; talking again brings it back up. The frame is for when it looks at or uses the screen
  (hearing you, thinking about a screen question, clicking and typing): it
  goes off while the work is in the background, and a task that never
  touched the screen answers without it.
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
- **Explains visually**: the buddy draws with a pen it holds, on screen
  or on a whiteboard it opens for explanations, and shows 3D models you
  can turn, lighting up each part as it talks about it.
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
   notarised releases with auto-update (releases are already built on GitHub; notarising needs an Apple Developer ID).
