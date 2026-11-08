[← Back to the README](../README.md)

# Voice, models and keys

Settings › Speech picks the engine that hears you and reads replies:

| Engine | Hears you | Speaks |
| --- | --- | --- |
| **Cloud** (OpenRouter) | Microsoft MAI-Transcribe 2, ElevenLabs Scribe v2, Google Gemini 3.5 Transcribe, Mistral Voxtral Small Transcribe 3 or OpenAI GPT Transcribe | Microsoft MAI-Voice 2.1 (Flash or full), ElevenLabs Eleven v4 (Turbo or full) or Google Gemini 3.8 Flash TTS (Lite or full) |
| **On this Mac** | Whisper large-v3 turbo on the Neural Engine | Kokoro-82M for English, Apple's voices otherwise |
| **Apple** | SpeechAnalyzer / SFSpeechRecognizer | the best installed system voice |

- Cloud is the default when an OpenRouter key is found: the one saved in
  Settings, else `$OPENROUTER_API_KEY`, else the first line of
  `~/.config/openrouter.key`. Cloud is only used for speech; recordings and
  reply sentences go to OpenRouter.
- The lists are ordered best first as of November 2026. Hearing, by
  Artificial Analysis word error rate: MAI-Transcribe 2 (2.0%), Voxtral
  Small Transcribe 3 (2.1%), Scribe v2 (2.2%), Gemini 3.5 Transcribe (2.6%).
  Voices: Eleven v4 Turbo is the most natural fast voice (Speech Arena Elo
  1335, about 190 ms to first audio at the source, 0.7–1.0 s a sentence
  through OpenRouter here) and speaks Norwegian; MAI-Voice 2.1 Flash is
  close (0.6–1.7 s here); Gemini's voices take 1.4–2.7 s. OpenRouter's speech
  endpoints are batch only: streaming recognition (MAI-Transcribe 2
  Streaming, about 0.13 s to a final transcript; ElevenLabs Scribe v2
  Realtime, about 0.15 s) needs those providers' own WebSocket APIs and keys.
- Each voice model keeps its own voice. Microsoft's voices are one name in
  several languages (Harper and Grant speak English and Norwegian); ElevenLabs
  voices speak every language themselves. Picking a voice plays a sample, in
  Norwegian too when you speak it.
- Apple's recognizers always run while you talk, for the live caption. When
  you let go, the chosen engine writes the transcript from the recording; if
  it fails or times out, Apple's is used. Whisper's known phantom lines out of
  silence are dropped.
- Reply sentences are rendered in order, the next while the one before
  plays, and played through one audio queue; the caption follows the words by
  their length. A sentence a neural voice can't speak (or a failed request)
  falls back to an Apple voice.
- The local models (about 2 GB) download once, the first time that engine is
  picked, and only with 5 GB free on the disk. MLX models such as Chatterbox
  (which speaks Norwegian) need Xcode's Metal toolchain to build, so they are
  not included.
- With the language on Automatic, Cursor Pilot listens for the first two
  languages in your Mac's language list at once, say Norwegian and English.
  Live text shows the language you spoke last.
- Double-tap **⌃** to type a question in the notch instead of saying it.
- Quiet system sounds mark listening, sending, a finished task and errors
  (Settings › On screen › Sound effects).

## Models and keys

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
- abliteration.ai models (`abliterated-model-large-flash`, `abliterated-model`,
  `abliterated-model-large-v2`) are in the same model picker, with their own
  key (keychain service `com.louistuis.cursorpilot.abliteration`, or
  `$ABLIT_KEY`). abliteration.ai speaks the Messages API, so the same client
  is used against `https://api.abliteration.ai` with
  `anthropic-version: 2023-06-01`. Claude's built-in tool types are not sent
  there: bash and the file editor go as plain tools with the same input shape,
  and computer use and web search are left out. `abliterated-model-large-v2`
  is text only, so screenshots are replaced by a short note.
- An OpenAI key (keychain service `com.louistuis.cursorpilot.openai`, or
  `$OPENAI_API_KEY`) is kept for the live voice.
- **Live voice** (Settings › Speech › Live voice): OpenAI's
  `gpt-realtime-2.1` over its Realtime WebSocket
  (`wss://api.openai.com/v1/realtime`) hears you and talks back in one
  connection, PCM16 at 24 kHz both ways through one AVAudioEngine with voice
  processing (echo cancellation). It doesn't do the work: anything beyond
  small talk goes to Claude (the model chosen above) through its
  `cursor_pilot` tool. Claude's lines before each step are said as
  out-of-band responses (`conversation: "none"`), and its answer goes back as
  the tool's output for the voice to tell. Hold the talk key to talk (audio is
  committed on release), or turn on hands-free for semantic VAD with cut-in;
  talking over it truncates its reply where you cut in. OpenRouter has no
  realtime model or WebSocket, so this needs the OpenAI key and credits.
  `-CPLiveTest out.json` checks the connection with typed lines.
  Following OpenAI's voice guidance: the prompt uses its sections (Role and
  Objective, Personality and Tone, Language with English default and Norwegian
  on a substantive Norwegian utterance, Verbosity, Preambles, Tools, Unclear
  Audio, Variety); instructions and tools never change mid-session so the
  cache holds; turns are written down by `gpt-transcribe`; long sessions keep
  80% when full (`truncation: retention_ratio 0.8`) and reasoning is `low`,
  both sent as separate optional updates whose errors are ignored. Settings
  also offers `gpt-realtime-2.1-mini`. Cost: user audio is 600 tokens a minute,
  its speech 1,200 a minute, and every reply re-reads the conversation
  (mostly cached), so a conversation runs about $0.05–0.10 a minute on 2.1.
- Each key row in Settings has a Paste button that saves the key on the
  clipboard without showing it.
