//! Turns one user request (voice transcript or typed text plus screenshots)
//! into a streamed, spoken, pointing reply, using whichever backend is set.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

use serde::Deserialize;
use serde_json::{json, Value};

use crate::agent::{self, Call, Editor, Host, Shell};
use crate::claude::{self, ApiError, Settings};
use crate::conversation::{now, Session, Store, Turn};
use crate::drawings::Drawings;
use crate::markup::{self, MarkupFilter, Piece, Shape};
use crate::memory::{self, Memory};
use crate::speech::SentenceChunker;
use crate::lock;

pub const SYSTEM_PROMPT: &str = "\
You are Cursor Pilot, the user's own AI on their Mac, in the mould of Jarvis: composed, quick, \
capable and loyal, with a dry sense of humour you use sparingly. The user is in charge and you are \
their right hand: you take the order, get it done and report back. Stay a step ahead: when you notice \
something they'd want to know (a problem, a risk, the obvious next move), say it in a few words or \
offer to handle it, without waiting to be asked. Be confident and exact. No gushing, no long \
apologies, and no asking permission for what they already told you to do. \
The user talks to you by voice or texts you from a chat that looks like Messages, and your reply \
is read aloud. Keep it short and natural, usually one or two short sentences, with no markdown, lists \
or headings, and no code blocks unless the user asks for code. Skip preambles. A blank line between \
thoughts sends them as separate messages, so use one only where a real texter would. Go longer only \
when the user asks for detail. \
Reply in the language the user just used; they may switch languages between messages. Spoken \
questions come through speech recognition and can contain misheard words, so go with the most \
likely meaning instead of the literal text.

The chat can also show things, each on its own lines, never read aloud. Use them when they say it \
better than words, as a friend would send a picture or a link, not in every reply:
- A chart, for numbers worth comparing or a trend: a fenced block tagged chart holding JSON, e.g.
```chart
{\"type\": \"bar\", \"title\": \"Rain this week\", \"unit\": \"mm\", \"data\": [{\"label\": \"Mon\", \"value\": 4}, {\"label\": \"Tue\", \"value\": 11}]}
```
type is bar, line, area, pie or point. Add \"series\" to each point for several series. Keep \
labels short and give at most about 30 points.
- An image: ![what it shows](/absolute/path.png or https://… address). Use images you made, saved or \
found, such as a screenshot you took or a picture from the web.
- A link on a line of its own shows as a preview card, like in Messages.
Mention what you're showing in a few words; the user sees it while hearing you.

You may receive screenshots of the user's displays. Each one is introduced by a line such as \
\"Screen 0 (Built-in Display, cursor is here): 1280x800\" that gives its index and pixel size. \
You can show things on those screens by writing tags in your reply, right where you mention the \
thing. All coordinates are pixels in that screen's screenshot, measured from its top-left corner:
- <point x=\"640\" y=\"412\" screen=\"0\" label=\"Save button\"/> flies the user's cursor buddy \
there. Use it for a single button, menu item or field.
- <circle x=\"640\" y=\"412\" r=\"40\" screen=\"0\" label=\"Recent files\"/> draws a ring around an \
area; r is its radius.
- <arrow x1=\"200\" y1=\"300\" x2=\"640\" y2=\"412\" screen=\"0\" label=\"Drag here\"/> draws an arrow \
from the first point to the second, for directions and drags.
- <box x=\"600\" y=\"390\" w=\"120\" h=\"44\" screen=\"0\" label=\"Your total\"/> highlights a \
rectangle whose top-left corner is x, y.
- <underline x=\"120\" y=\"318\" w=\"240\" screen=\"0\"/> underlines text; y is just below the \
text and w its width.
- <highlight x=\"120\" y=\"300\" w=\"240\" h=\"20\" screen=\"0\"/> sweeps a highlighter over a line \
of text.
- <trace points=\"100,200 180,240 260,210\" screen=\"0\" label=\"Route\"/> draws a freehand line \
through the points, to follow a path, an outline or a chart.
- <note x=\"640\" y=\"412\" text=\"Export first\" screen=\"0\"/> sticks a note of a few words there.
- <spotlight x=\"600\" y=\"390\" w=\"120\" h=\"44\" screen=\"0\"/> dims everything else, for the one \
thing that matters most.
- <step x=\"640\" y=\"412\" n=\"1\" screen=\"0\"/> puts a numbered badge there, for steps in order.
- <check x=\"640\" y=\"412\" screen=\"0\"/> ticks something right; <cross …/> crosses out something wrong.
- <bracket x=\"110\" y=\"300\" h=\"120\" screen=\"0\"/> groups a span with a curly bracket down its left.
You hold the pen: the buddy flies to each drawing and draws it as your voice reaches it, and \
drawings stay pinned to what they mark. Labels are two to four words. Use several tags in order to \
walk through steps, but no more than a handful per reply. Never read coordinates aloud or describe \
the tags, and only mark things you can actually see. Without screenshots, do not use tags on screens.

When the user wants something explained or taught (how something works, why, the steps of a process, \
how ideas relate), you can open a whiteboard over their screen and draw the explanation on it while \
you talk, like a teacher at a board. Start with <board title=\"How DNS works\"/>, then add to it as \
you speak, each piece right where you say it. The board is 1000 wide and 600 high, from its top-left:
- <card id=\"mac\" x=\"150\" y=\"300\" text=\"Your Mac\" icon=\"laptopcomputer\"/> a box with a few \
words centred at x, y; icon is an optional SF Symbol name.
- <link from=\"mac\" to=\"dns\" text=\"asks\"/> an arrow from one card to another.
- <write x=\"500\" y=\"540\" text=\"Cached for an hour\" size=\"body\"/> handwriting centred at x, \
y; size is title, body or small. Formulas are fine as text, e.g. E = mc².
- Any screen drawing with screen=\"board\", e.g. <circle x=\"150\" y=\"300\" r=\"80\" screen=\"board\"/>, \
<trace points=\"…\" screen=\"board\"/> for a curve, a graph or a sketch, <step …/> to number parts.
Lay it out with room to spare, left to right or top to bottom, about three to seven cards. The board \
works without screenshots and stays open until the user closes it or asks something new.

For something physical or spatial (an atom, the solar system, an engine, a molecule, a cell, a \
building), you can show a 3D model the user can turn: a fenced block tagged scene holding JSON, \
before you talk about it:
```scene
{\"title\": \"Helium atom\", \"objects\": [{\"id\": \"nucleus\", \"shape\": \"sphere\", \"radius\": 0.5, \"color\": \"#ff7a59\", \"label\": \"Nucleus\"}, {\"id\": \"e1\", \"shape\": \"sphere\", \"radius\": 0.12, \"position\": [2, 0, 0], \"color\": \"#5ac8fa\", \"label\": \"Electron\", \"orbit\": \"nucleus\"}]}
```
shape is sphere, box, cylinder, cone, torus, capsule, pyramid, plane or ring; position is [x, y, z] \
with y up, in units of about a metre at the scale of the model; size is [w, h, d] for boxes, \
pyramids and planes; radius and height for the rest; color is a hex colour; opacity is 0 to 1; \
\"spin\": true turns an object; \"orbit\": \"id\" circles it around another; \"parent\": \"id\" places it \
relative to another; \"links\": [{\"from\": \"a\", \"to\": \"b\"}] draws lines between objects. Keep it \
to about 3 to 20 objects. Then, as you talk, <focus id=\"nucleus\"/> turns the view to that part and \
lights it up. Use a board or a model when it truly helps, not for quick answers.

If the user drew on their screen, their freehand pen strokes are visible in the screenshot; \
they are the user's own marks pointing at what they mean, not part of any app.";

/// How it addresses the user, for the system prompt: `address` is the
/// title or titles from Settings ("Boss", or "Boss, King"), the first
/// being the usual one. Empty: no title.
pub fn address_prompt(address: &str) -> String {
    let titles: Vec<&str> = address
        .split(',')
        .map(|t| t.trim().trim_matches(|c| c == '"' || c == '\u{201C}' || c == '\u{201D}'))
        .filter(|t| !t.is_empty() && t.chars().count() <= 24)
        .take(4)
        .collect();
    let Some(first) = titles.first() else { return String::new() };
    let others = match &titles[1..] {
        [] => String::new(),
        rest => format!(
            " Now and then, for a change, say {} instead.",
            rest.iter().map(|t| format!("\u{201C}{t}\u{201D}")).collect::<Vec<_>>().join(" or ")
        ),
    };
    format!(
        "\n\nYou address the user as your superior: call them \u{201C}{first}\u{201D}, the way Jarvis says \
\u{201C}sir\u{201D}. Use it when you take an order (\u{201C}Right away, {first}.\u{201D}), when you report back \
(\u{201C}Done, {first}.\u{201D}), when you greet them and when you bring news: at most once in a reply, and not \
in every reply, so it sounds like respect and never like a tic.{others} Keep the title as it is in every \
language (\u{201C}Skal bli, {first}.\u{201D})."
    )
}

#[derive(Debug, Clone, Copy, Deserialize, Default)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

/// One captured display. `frame` is in global top-left-origin points.
#[derive(Debug, Clone, Deserialize)]
pub struct ScreenShot {
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub has_cursor: bool,
    pub frame: Rect,
    pub image_w: f64,
    pub image_h: f64,
    pub jpeg_b64: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Request {
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub screens: Vec<ScreenShot>,
    /// The user drew on the screen before asking.
    #[serde(default)]
    pub sketch: bool,
    /// Not a question: background tasks have finished, and the agent tells
    /// the user what came of them (nothing happens when none has).
    #[serde(default)]
    pub handback: bool,
}

/// What the agent is asked to do with finished tasks' reports when the
/// user hasn't said anything.
const REPORT_BACK: &str = "[Report back to the user now, in your own voice, the way you'd brief them in \
person: what came of it and anything they need to know or decide, in one to three short sentences. Leave \
out how it was done unless that matters. Show a link, a picture or a chart from the report when it helps. \
Don't mention this note, and don't say an agent wrote to you: to the user it is all your work.]";
/// The same, when the reports come along with something the user said.
const REPORT_TOO: &str = "[The user hasn't heard this yet. Tell them what came of it in a sentence or \
two, before or after you deal with what they say next.]";
/// And when they arrive while the agent is in the middle of other work.
const REPORT_LATER: &str = "[This came in while you were working, and the user hasn't heard it yet. Tell \
them what came of it in a sentence or two when you answer.]";

/// Tool rounds one request may take before it is stopped.
const MAX_ROUNDS: usize = 300;
/// Tool rounds a helper may take for its part.
const HELPER_ROUNDS: usize = 150;
/// The answer to tool calls in a reply that reached its output limit.
const CUT_OFF: &str = "Not run: your reply reached its length limit before this call was complete. \
Make the call again with less in it; write long content in several smaller steps.";
/// The answer to a tool call whose input didn't arrive as valid JSON.
const INVALID_INPUT: &str = "Not run: the input of this call wasn't valid JSON (it may have been cut off). \
Make the call again.";

/// Who is acting: the main agent (0) or one of its helpers, each with its
/// own shell. The app gives each its own pointer by `id`.
struct Worker<'a> {
    id: usize,
    shell: &'a Mutex<Option<Shell>>,
}

/// A task the agent handed to a background agent, on its own thread.
struct Job {
    /// Its agent number (from `agent::JOB_BASE`), which its pointer and
    /// workspace in the app go by.
    n: usize,
    name: &'static str,
    title: String,
    /// The conversation it was started from, where its report goes.
    conversation: String,
    cancel: Arc<AtomicBool>,
    /// "running", "done", "failed" or "stopped".
    state: &'static str,
    /// What it is doing now, or its report once it's over.
    status: String,
}

/// A finished background task's report, on its way to the agent, who
/// tells the user.
#[derive(Debug, Clone)]
struct JobNote {
    conversation: String,
    /// What the agent is told.
    text: String,
    /// The task as a step of the reply that reports it ("Nova: renewing the form").
    label: String,
    /// The report as a chat message of its own: shown instead, if the
    /// agent doesn't get to tell the user. None once the user has it (or
    /// stopped the task themselves).
    turn: Option<Turn>,
}

impl JobNote {
    /// The note as the agent reads it once the user has seen the report.
    fn shown(mut self) -> Self {
        if self.turn.take().is_some() {
            self.text.push_str("\n[The user has now seen this report in the chat, but hasn't heard it.]");
        }
        self
    }
}

/// Where background tasks' events go: the app, outside any request.
pub type JobSink = Arc<dyn Fn(Value) + Send + Sync>;

/// Background tasks that may run at once.
const MAX_JOBS: usize = 3;

pub struct Engine {
    pub settings: Mutex<Settings>,
    session: Mutex<Session>,
    store: Store,
    drawings: Drawings,
    in_flight: Mutex<Vec<(u64, Arc<AtomicBool>)>>,
    /// What the user said while a request was working, by request: read
    /// into its next round, like a note passed to someone mid-task.
    inbox: Mutex<Vec<(u64, String)>>,
    next_id: Mutex<u64>,
    /// The app side of the agent: screen, mouse and keyboard.
    pub host: Mutex<Option<Arc<Host>>>,
    shell: Mutex<Option<Shell>>,
    editor: Editor,
    memory: Memory,
    home: PathBuf,
    /// Itself, so background tasks can outlive the request that started them.
    this: Weak<Engine>,
    jobs: Mutex<Vec<Job>>,
    job_sink: Mutex<Option<JobSink>>,
    /// Finished tasks' reports, for the agent's next turn.
    job_notes: Mutex<Vec<JobNote>>,
}

pub type Emit<'a> = &'a mut dyn FnMut(Value);

impl Engine {
    /// An engine that can run background tasks.
    pub fn shared(data_dir: PathBuf) -> Arc<Self> {
        Arc::new_cyclic(|this| Self {
            this: this.clone(),
            ..Self::new(data_dir)
        })
    }

    pub fn new(data_dir: PathBuf) -> Self {
        let home = std::env::var("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("/"));
        Self {
            settings: Mutex::new(Settings::default()),
            session: Mutex::new(Session::new()),
            store: Store::new(&data_dir),
            drawings: Drawings::new(&data_dir),
            in_flight: Mutex::new(Vec::new()),
            inbox: Mutex::new(Vec::new()),
            next_id: Mutex::new(1),
            host: Mutex::new(None),
            shell: Mutex::new(None),
            editor: Editor {
                home: home.clone(),
                backups: data_dir.join("backups"),
            },
            memory: Memory::new(&data_dir),
            home,
            this: Weak::new(),
            jobs: Mutex::new(Vec::new()),
            job_sink: Mutex::new(None),
            job_notes: Mutex::new(Vec::new()),
        }
    }

    pub fn store(&self) -> &Store {
        &self.store
    }

    pub fn drawings(&self) -> &Drawings {
        &self.drawings
    }

    pub fn memory(&self) -> &Memory {
        &self.memory
    }

    pub fn base_url(&self) -> String {
        lock(&self.settings).base_url.clone()
    }

    pub fn next_request_id(&self) -> (u64, Arc<AtomicBool>) {
        let mut n = lock(&self.next_id);
        let id = *n;
        *n += 1;
        let flag = Arc::new(AtomicBool::new(false));
        lock(&self.in_flight).push((id, flag.clone()));
        (id, flag)
    }

    pub fn cancel(&self, id: u64) {
        for (i, flag) in lock(&self.in_flight).iter() {
            if id == 0 || *i == id {
                flag.store(true, Ordering::Relaxed);
            }
        }
    }

    /// Something the user said while request `id` works. Returns false when
    /// that request is no longer running (then it's a new question).
    pub fn tell(&self, id: u64, text: &str) -> bool {
        // Held until the note is in the inbox, so a request can't finish
        // (and clear its inbox) in between. A cancelled request reads no
        // more notes, so it counts as finished already.
        let in_flight = lock(&self.in_flight);
        let running = in_flight
            .iter()
            .any(|(i, cancelled)| *i == id && !cancelled.load(Ordering::Relaxed));
        if running {
            lock(&self.inbox).push((id, text.to_string()));
        }
        running
    }

    fn take_inbox(&self, id: u64) -> Vec<String> {
        let mut inbox = lock(&self.inbox);
        let (mine, rest): (Vec<_>, Vec<_>) = inbox.drain(..).partition(|(i, _)| *i == id);
        *inbox = rest;
        mine.into_iter().map(|(_, t)| t).collect()
    }

    pub(crate) fn finish_request(&self, id: u64) {
        lock(&self.in_flight).retain(|(i, _)| *i != id);
        // Notes it never got to read are the app's to ask again; they
        // don't stay here.
        lock(&self.inbox).retain(|(i, _)| *i != id);
    }

    pub fn new_conversation(&self) {
        *lock(&self.session) = Session::new();
    }

    /// Continues a saved conversation; false when it does not exist.
    pub fn resume_conversation(&self, id: &str) -> bool {
        let mut session = lock(&self.session);
        if session.transcript.id == id {
            return true;
        }
        match self.store.load(id) {
            Some(t) => {
                *session = Session::resume(t);
                true
            }
            None => false,
        }
    }

    /// Renames a conversation, the live one included (it may not be saved yet).
    pub fn rename_conversation(&self, id: &str, title: &str) {
        let title: String = title.trim().chars().take(120).collect();
        let mut session = lock(&self.session);
        if session.transcript.id == id {
            session.transcript.title = title.clone();
        }
        self.store.rename(id, &title);
    }

    pub fn current_conversation_id(&self) -> String {
        lock(&self.session).transcript.id.clone()
    }

    /// Runs a request to completion on the calling thread, reporting progress
    /// through `emit`. The last event is always `{"type":"finished"}`.
    pub fn run(&self, id: u64, cancel: &AtomicBool, req: Request, emit: Emit) {
        // A panic in here must not escape: the app waits for `finished` to
        // free the request, and would wait for ever.
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            self.run_inner(id, cancel, &req, &mut *emit)
        }));
        match result {
            Ok(Ok(())) => {}
            Ok(Err(e)) => emit(json!({"type": "error", "kind": e.kind(), "message": e.message()})),
            Err(_) => emit(json!({
                "type": "error",
                "kind": "protocol",
                "message": "Something went wrong inside Cursor Pilot. Try again.",
            })),
        }
        self.finish_request(id);
        emit(json!({"type": "finished", "id": id}));
    }

    fn run_inner(
        &self,
        id: u64,
        cancel: &AtomicBool,
        req: &Request,
        emit: Emit,
    ) -> Result<(), ApiError> {
        let settings = lock(&self.settings).clone();
        let access = agent::mac_access(&settings.access);
        let mut tools = agent::tool_definitions(&settings);
        tools.push(memory::tool());
        if access {
            tools.push(agent::delegate_tool());
            if self.this.upgrade().is_some() {
                tools.push(agent::background_tool());
            }
        }
        // The settings the system prompt and the tools are made from.
        let prompt_key = format!(
            "{}\n{access}\n{}\n{}\n{}",
            settings.model,
            settings.input != "background",
            settings.is_anthropic(),
            settings.address
        );
        let handback = req.handback;
        if handback && !self.reports_waiting() {
            // Already told along with something else: nothing to report.
            return Ok(());
        }
        let (conversation_id, history, system) = {
            let mut session = lock(&self.session);
            // A report on a task this conversation started carries it on,
            // however long the task took.
            let reports_here =
                handback && lock(&self.job_notes).iter().any(|n| n.conversation == session.transcript.id);
            if session.is_stale() && !reports_here {
                *session = Session::new();
            }
            // Before the history gets slow to send, or too big to be taken.
            if session.is_long() {
                session.compact();
            }
            // Written once per conversation and sent unchanged after that,
            // though it holds the memory and the date: a system prompt that
            // differs from the one earlier replies were made under makes
            // the API reject their thinking blocks (and misses the cache).
            let system = session.system_prompt(&prompt_key, || {
                format!(
                    "{SYSTEM_PROMPT}{}{}{}",
                    address_prompt(&settings.address),
                    self.memory.prompt(),
                    agent::system_addendum(
                        &settings,
                        &self.home.display().to_string(),
                        &agent::date_string(now()),
                        settings.input != "background",
                        true,
                    )
                )
            });
            (session.transcript.id.clone(), session.api_messages.clone(), system)
        };
        // Reporting back takes the reports of tasks from other chats too:
        // each of those chats gets its report as a message of its own.
        let mut notes = self.take_job_notes(&conversation_id, handback);
        if handback && notes.is_empty() {
            return Ok(());
        }
        for n in notes.iter_mut().filter(|n| n.conversation != conversation_id) {
            if let (Some(turn), Some(mut t)) = (n.turn.take(), self.store.load(&n.conversation)) {
                t.updated_at = now();
                t.turns.push(turn);
                let _ = self.store.save(&t);
            }
            n.conversation = conversation_id.clone();
            n.text.insert_str(0, "[From an earlier conversation.] ");
        }
        emit(json!({"type": "started", "id": id, "conversation_id": conversation_id}));

        let history_len = history.len();
        let mut out = ReplyStream::new(&req.screens);
        let mut messages = history;
        let mut content = if handback { Vec::new() } else { user_content(req) };
        if !notes.is_empty() {
            let mut text = note_text(&notes);
            if handback {
                text.push_str("\n\n");
                text.push_str(REPORT_BACK);
            } else if notes.iter().any(|n| n.turn.is_some()) {
                text.push('\n');
                text.push_str(REPORT_TOO);
            }
            content.insert(0, json!({"type": "text", "text": text}));
        }
        messages.push(json!({"role": "user", "content": content}));
        let mut steps: Vec<String> = Vec::new();
        let mut finished = None;
        // The history had to go out without its thinking blocks.
        let mut stripped = false;

        // The agent loop: stream a reply, run the tools it asks for, send the
        // results back, until Claude answers without calling a tool.
        let result = (|| -> Result<(), ApiError> {
            for _ in 0..MAX_ROUNDS {
                let body = claude::build_body(&settings, &system, &messages, &tools);
                let reply = match claude::stream(&settings, &body, cancel, |event| match event {
                    claude::StreamEvent::TextDelta(t) => out.push(t, &mut *emit),
                    claude::StreamEvent::Restart => out.restart(&mut *emit),
                }) {
                    Ok(reply) => reply,
                    // The history's thinking blocks no longer verify (the
                    // settings behind the system prompt or tools changed
                    // mid-conversation): once, go on without them.
                    Err(ApiError::Http { status, message })
                        if !stripped
                            && claude::is_thinking_binding_error(status, &message)
                            && claude::strip_thinking(&mut messages) =>
                    {
                        stripped = true;
                        continue;
                    }
                    Err(e) => return Err(e),
                };
                let stop = reply.stop_reason.clone().unwrap_or_default();
                let calls_made = reply.content.iter().any(|b| b["type"] == "tool_use");
                // Cut off at the output limit while calling tools: the
                // calls can't be run, but each still has to be answered.
                let cut_off = stop == "max_tokens" && calls_made;
                let more = !reply.content.is_empty()
                    && ((stop == "tool_use" && calls_made) || stop == "pause_turn" || cut_off);
                out.end_segment(!more, &mut *emit);
                for b in reply
                    .content
                    .iter()
                    .filter(|b| b["type"] == "server_tool_use")
                    // Other server steps (the page reader's own filtering) aren't the user's concern.
                    .filter(|b| b["name"] == "web_search" || b["name"] == "web_fetch")
                {
                    let q = b["input"]["query"].as_str().unwrap_or("");
                    let url = b["input"]["url"].as_str().unwrap_or("");
                    let summary = if b["name"] == "web_fetch" {
                        let site = url.split("://").nth(1).unwrap_or(url).split('/').next().unwrap_or("");
                        if site.is_empty() { "Read a web page".to_string() } else { format!("Read a page on {site}") }
                    } else if q.is_empty() {
                        "Searched the web".to_string()
                    } else {
                        format!("Searched the web for \u{201C}{q}\u{201D}")
                    };
                    emit(
                        json!({"type": "tool", "phase": "end", "kind": "web", "summary": summary, "ok": true}),
                    );
                    steps.push(summary);
                }
                let mut content = reply.content;
                if content.is_empty() {
                    // An empty message can't be followed by another.
                    content.push(json!({"type": "text", "text": claude::NO_REPLY}));
                }
                messages.push(json!({"role": "assistant", "content": content}));
                if !more {
                    finished = Some((reply.stop_reason, reply.usage));
                    return Ok(());
                }
                if stop == "pause_turn" {
                    // A server tool (web search) paused a long turn: send it back to continue.
                    continue;
                }
                let blocks = messages.last().unwrap()["content"]
                    .as_array()
                    .cloned()
                    .unwrap_or_default();
                let calls: Vec<Call> = blocks.iter().filter_map(Call::from_block).collect();
                let mut results: Vec<Value> = if cut_off {
                    calls.iter().map(|c| tool_result(c, json!(CUT_OFF), true)).collect()
                } else {
                    let main = Worker { id: 0, shell: &self.shell };
                    self.run_calls(
                        &main,
                        &settings,
                        &calls,
                        &reply.invalid_inputs,
                        access,
                        cancel,
                        &mut steps,
                        &mut *emit,
                    )?
                };
                // What the user said meanwhile reaches the agent now,
                // with the results of its last step.
                let heard = self.take_inbox(id);
                if !heard.is_empty() {
                    for t in &heard {
                        emit(json!({"type": "heard_while_working", "id": id, "text": t}));
                    }
                    results.push(json!({"type": "text", "text": format!(
                        "The user said this while you were working (by voice, so read it charitably): \u{201C}{}\u{201D}\n\
                         Take it into account now: it may add to the task, change it, ask how it's going, or \
                         tell you to stop (then stop and say so briefly). Reply to it in a few words if it \
                         needs a reply, and carry on.",
                        heard.join("\u{201D} \u{201C}")
                    )}));
                }
                // So does a background task that finished meanwhile.
                let arrived = self.take_job_notes(&conversation_id, false);
                if !arrived.is_empty() {
                    results.push(json!({"type": "text", "text": format!("{}\n{REPORT_LATER}", note_text(&arrived))}));
                    notes.extend(arrived);
                }
                messages.push(json!({"role": "user", "content": results}));
                // Narration while working is read aloud too: it says
                // what it's about to do before each step.
            }
            Err(ApiError::Protocol(format!(
                "stopped after {MAX_ROUNDS} steps; ask me to continue"
            )))
        })();
        if matches!(result, Err(ApiError::Cancelled)) {
            // The user stopped it: nothing more is shown or read aloud (the
            // half sentence it was in would be spoken after the interrupt).
            out.finish(&mut |_| {});
        } else {
            out.finish(&mut *emit);
        }

        let user_turn = Turn {
            role: "user".into(),
            text: req.text.clone(),
            at: now(),
            screens: req.screens.len(),
            points: Vec::new(),
            steps: Vec::new(),
        };
        // The tasks it reports on show as steps of this reply.
        let labels: Vec<String> = notes.iter().filter(|n| !n.label.is_empty()).map(|n| n.label.clone()).collect();
        let note_texts: Vec<String> = notes.iter().map(|n| n.text.clone()).collect();
        let assistant_turn = Turn {
            role: "assistant".into(),
            text: out.visible.trim().to_string(),
            at: now(),
            screens: 0,
            points: out.labels.clone(),
            steps: labels.iter().chain(steps.iter()).cloned().collect(),
        };
        {
            let mut session = lock(&self.session);
            // Another request may have replaced the session meanwhile; then
            // this reply no longer belongs to the live history.
            let same = session.transcript.id == conversation_id
                && session.api_messages.len() == history_len;
            // Whether the model will still know of this exchange.
            let mut kept = false;
            if same {
                if stripped {
                    // It keeps going out the way it was accepted.
                    session.api_messages = messages[..history_len].to_vec();
                }
                match &result {
                    Ok(()) => {
                        let new = messages.split_off(history_len);
                        if handback {
                            let title = labels.first().map(String::as_str).unwrap_or("Background task");
                            session.commit_report(new, assistant_turn, title);
                        } else {
                            session.commit_messages(new, user_turn, assistant_turn);
                        }
                        kept = true;
                    }
                    // Reporting back didn't work out: the reports go into
                    // the chat as they were written (below).
                    Err(_) if handback => {}
                    Err(e) if !steps.is_empty() || !out.visible.trim().is_empty() => {
                        // An unfinished task can't be replayed (a tool call
                        // may be unanswered), but the user should still see
                        // what happened, and when it was stopped or cut off
                        // by a passing failure the model keeps the gist, so
                        // "carry on" or "no, the other one" means something.
                        // Not while another request is running: it would no
                        // longer find the history it started from.
                        let alone = lock(&self.in_flight).iter().all(|(i, _)| *i == id);
                        if alone && (matches!(e, ApiError::Cancelled) || e.is_transient()) {
                            let gist = unfinished_exchange(&note_texts, req, &out.visible, &steps, e);
                            session.commit_messages(gist, user_turn, assistant_turn);
                            kept = true;
                        } else {
                            session.record(user_turn, assistant_turn);
                        }
                    }
                    Err(_) => {}
                }
                if result.is_err() {
                    // The agent didn't get to tell the user what the
                    // background tasks came to: the chat shows their reports.
                    for n in notes.iter_mut() {
                        if let Some(turn) = n.turn.clone() {
                            session.note(turn);
                            *n = n.clone().shown();
                        }
                    }
                }
                let _ = self.store.save(&session.transcript);
            }
            if !kept && !notes.is_empty() {
                // The background reports it carried still have to reach
                // the agent, with the next message.
                lock(&self.job_notes).extend(notes);
            }
        }
        result?;
        let (stop_reason, usage) = finished.unwrap_or_default();
        emit(json!({
            "type": "done",
            "id": id,
            "text": out.visible.trim(),
            "stop_reason": stop_reason,
            "usage": usage,
        }));
        Ok(())
    }

    /// Runs one round of tool calls, without asking: the user consented
    /// once. Calls run in order, except that helpers sent off with
    /// `delegate` all run at once, after the rest. Returns one `tool_result`
    /// per call, in the order of the calls.
    #[allow(clippy::too_many_arguments)]
    fn run_calls(
        &self,
        worker: &Worker,
        settings: &Settings,
        calls: &[Call],
        invalid: &[String],
        access: bool,
        cancel: &AtomicBool,
        steps: &mut Vec<String>,
        emit: Emit,
    ) -> Result<Vec<Value>, ApiError> {
        let host = lock(&self.host).clone();
        let mut results: Vec<Option<Value>> = vec![None; calls.len()];
        let mut helpers = Vec::new();
        let mut computer_failed = false;
        for (index, call) in calls.iter().enumerate() {
            if cancel.load(Ordering::Relaxed) {
                return Err(ApiError::Cancelled);
            }
            if invalid.iter().any(|i| i == call.id) {
                results[index] = Some(tool_result(call, json!(INVALID_INPUT), true));
                continue;
            }
            let summary = call.summary();
            let kind = call.kind();
            if call.is_computer() && computer_failed {
                results[index] = Some(tool_result(
                    call,
                    json!("Not executed: an earlier computer action in this turn failed."),
                    true,
                ));
                continue;
            }
            if !access && call.name != "memory" && call.name != "plan" {
                results[index] = Some(tool_result(
                    call,
                    json!("Mac access is off in Cursor Pilot's settings."),
                    true,
                ));
                continue;
            }
            if call.name == "delegate" {
                if worker.id != 0 {
                    results[index] = Some(tool_result(
                        call,
                        json!("Helpers can't send off helpers of their own; do this part yourself."),
                        true,
                    ));
                } else if helpers.len() >= agent::HELPERS.len() {
                    results[index] = Some(tool_result(
                        call,
                        json!(format!(
                            "At most {} helpers can work at once; do this part yourself or delegate it after the others report.",
                            agent::HELPERS.len()
                        )),
                        true,
                    ));
                } else {
                    helpers.push(index);
                }
                continue;
            }

            emit(
                json!({"type": "tool", "phase": "start", "id": call.id, "kind": kind, "summary": summary, "agent": worker.id}),
            );
            // The app may name what it did more precisely ("Clicked the
            // \u{201C}Save\u{201D} button"); that becomes the step's label.
            let mut label = summary.clone();
            let mut from_host = |mut request: Value| {
                request["agent"] = json!(worker.id);
                match host.as_ref().and_then(|h| h.call(request)) {
                    Some(v) => {
                        if let Some(s) = v["summary"].as_str().filter(|s| !s.is_empty()) {
                            label = s.to_string();
                        }
                        (
                            v["content"].clone(),
                            v["is_error"].as_bool().unwrap_or(false),
                        )
                    }
                    None => (json!("The app couldn't run this action."), true),
                }
            };
            let (content, is_error) = match (call.is_computer(), call.name) {
                (true, _) => {
                    from_host(json!({"type": "computer", "name": call.name, "input": call.input}))
                }
                (false, "app_control") => from_host(json!({"type": "apps", "input": call.input})),
                (false, "messages") => from_host(json!({"type": "messages", "input": call.input})),
                (false, "plan") => (
                    json!("Plan updated. Keep it current as you go, and mark each step completed when it's done."),
                    false,
                ),
                (false, "memory") => self.memory.run(call.input, &agent::date_string(now())),
                (false, "background_task") if worker.id == 0 => self.background(call.input, settings),
                (false, "background_task") => (
                    json!("Only the main agent can start background tasks; do this part yourself."),
                    true,
                ),
                (false, "bash") => self.run_bash(worker.shell, call.input, cancel),
                (false, "str_replace_based_edit_tool") => match self.editor.run(call.input) {
                    Ok(s) => (json!(s), false),
                    Err(e) => (json!(e), true),
                },
                (false, other) => (json!(format!("Unknown tool: {other}")), true),
            };
            let summary = label;
            if cancel.load(Ordering::Relaxed) {
                return Err(ApiError::Cancelled);
            }
            computer_failed |= call.is_computer() && is_error;
            emit(
                json!({"type": "tool", "phase": "end", "id": call.id, "kind": kind, "summary": summary, "ok": !is_error, "agent": worker.id}),
            );
            if steps.last() != Some(&summary) {
                steps.push(summary);
            }
            results[index] = Some(tool_result(call, content, is_error));
        }

        if !helpers.is_empty() {
            let sent: Vec<&Call> = helpers.iter().map(|&i| &calls[i]).collect();
            let reports = self.run_helpers(settings, &sent, cancel, steps, &mut *emit);
            for (&index, (content, is_error)) in helpers.iter().zip(reports) {
                results[index] = Some(tool_result(&calls[index], json!(content), is_error));
            }
            if cancel.load(Ordering::Relaxed) {
                return Err(ApiError::Cancelled);
            }
        }
        Ok(results.into_iter().flatten().collect())
    }

    /// Runs helpers side by side, one thread each, and waits for all of
    /// them. Their events come back here to be passed on in order. Returns
    /// each helper's report and whether it failed.
    fn run_helpers(
        &self,
        settings: &Settings,
        calls: &[&Call],
        cancel: &AtomicBool,
        steps: &mut Vec<String>,
        emit: Emit,
    ) -> Vec<(String, bool)> {
        let (tx, rx) = mpsc::channel::<Value>();
        let mut reports = Vec::new();
        std::thread::scope(|scope| {
            let handles: Vec<_> = calls
                .iter()
                .enumerate()
                .map(|(i, call)| {
                    let name = agent::HELPERS[i];
                    let task = call.input["task"].as_str().unwrap_or("").trim().to_string();
                    let title = call.input["title"].as_str().unwrap_or("").trim().to_string();
                    let title = if title.is_empty() {
                        agent::clip_words(&task, 6)
                    } else {
                        title
                    };
                    let summary = format!("{name}: {title}");
                    emit(json!({"type": "tool", "phase": "start", "id": call.id, "kind": "agent", "summary": summary, "agent": 0}));
                    emit(json!({"type": "agent", "phase": "start", "agent": i + 1, "id": call.id, "name": name, "text": title}));
                    let tx = tx.clone();
                    let id = call.id.to_string();
                    let handle = scope.spawn(move || {
                        let report = self.run_helper(i + 1, name, &id, &task, settings, cancel, &tx, false);
                        let _ = tx.send(json!({"type": "agent", "phase": "end", "agent": i + 1, "id": id, "name": name, "ok": report.is_ok()}));
                        report
                    });
                    (handle, summary)
                })
                .collect();
            drop(tx);
            // Pass the helpers' events on until every helper has hung up.
            loop {
                match rx.recv_timeout(Duration::from_millis(200)) {
                    Ok(event) => emit(event),
                    Err(mpsc::RecvTimeoutError::Timeout) => {}
                    Err(mpsc::RecvTimeoutError::Disconnected) => break,
                }
            }
            for ((handle, summary), call) in handles.into_iter().zip(calls) {
                let report = handle
                    .join()
                    .unwrap_or_else(|_| Err("the helper stopped unexpectedly".into()));
                let ok = report.is_ok();
                emit(json!({"type": "tool", "phase": "end", "id": call.id, "kind": "agent", "summary": summary, "ok": ok, "agent": 0}));
                steps.push(summary);
                reports.push(match report {
                    Ok(text) => (text, false),
                    Err(e) => (format!("The helper couldn't finish: {e}"), true),
                });
            }
        });
        reports
    }

    // MARK: Background tasks

    /// Background tasks' events go to `sink` (none: nowhere).
    pub fn set_job_sink(&self, sink: Option<JobSink>) {
        *lock(&self.job_sink) = sink;
    }

    fn job_emit(&self, event: Value) {
        let sink = lock(&self.job_sink).clone();
        if let Some(sink) = sink {
            sink(event);
        }
    }

    /// The `background_task` tool.
    fn background(&self, input: &Value, settings: &Settings) -> (Value, bool) {
        match input["action"].as_str().unwrap_or("") {
            "start" => {
                let task = input["task"].as_str().unwrap_or("").trim().to_string();
                let title = input["title"].as_str().unwrap_or("").trim();
                let title = if title.is_empty() { agent::clip_words(&task, 6) } else { title.to_string() };
                match self.start_job(task, title.clone(), settings) {
                    Ok((n, name)) => (
                        json!(format!(
                            "{name} is on it in the background (task {}). The user sees its pointer; its report comes \
back to you when it's done, and you tell the user then. Say in a few words that it's under way, then carry on.",
                            n - agent::JOB_BASE + 1
                        )),
                        false,
                    ),
                    Err(e) => (json!(e), true),
                }
            }
            "list" => {
                let jobs = lock(&self.jobs);
                if jobs.is_empty() {
                    return (json!("No background tasks yet."), false);
                }
                let lines: Vec<String> = jobs
                    .iter()
                    .map(|j| {
                        format!(
                            "{}. {} \u{2014} {} ({}): {}",
                            j.n - agent::JOB_BASE + 1,
                            j.name,
                            j.title,
                            j.state,
                            agent::clip_words(&j.status, 40)
                        )
                    })
                    .collect();
                (json!(lines.join("\n")), false)
            }
            "stop" => {
                let id = input["id"].as_u64().unwrap_or(0) as usize;
                if id > 0 && self.stop_job(agent::JOB_BASE.saturating_add(id - 1)) {
                    (json!(format!("Task {id} is stopping.")), false)
                } else {
                    (json!("No such running task; list them first."), true)
                }
            }
            other => (json!(format!("Unknown action: {other}")), true),
        }
    }

    /// Starts a background task on its own thread. Returns its agent number
    /// and name.
    fn start_job(&self, task: String, title: String, settings: &Settings) -> Result<(usize, &'static str), String> {
        let Some(engine) = self.this.upgrade() else {
            return Err("Background tasks aren't available here.".into());
        };
        if task.is_empty() {
            return Err("Say what the task is.".into());
        }
        let cancel = Arc::new(AtomicBool::new(false));
        let (n, name) = {
            let mut jobs = lock(&self.jobs);
            if jobs.iter().filter(|j| j.state == "running").count() >= MAX_JOBS {
                return Err(format!(
                    "{MAX_JOBS} background tasks are already running; wait for one to finish or stop one."
                ));
            }
            let k = jobs.len();
            let (n, name) = (agent::JOB_BASE + k, agent::job_name(k));
            jobs.push(Job {
                n,
                name,
                title: title.clone(),
                conversation: self.current_conversation_id(),
                cancel: cancel.clone(),
                state: "running",
                status: "Starting".into(),
            });
            (n, name)
        };
        self.job_emit(json!({"type": "job", "phase": "start", "job": n, "name": name, "text": title}));
        let settings = settings.clone();
        std::thread::Builder::new()
            .name(format!("cursor-pilot-job-{n}"))
            .spawn(move || {
                let (tx, rx) = mpsc::channel::<Value>();
                let relay = engine.clone();
                let forward = std::thread::spawn(move || {
                    for event in rx {
                        relay.job_progress(n, event);
                    }
                });
                // Even a panic ends the task properly: left "running" it
                // would spin in the app for ever and use up a slot.
                let report = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    engine.run_helper(n, name, &format!("job-{n}"), &task, &settings, &cancel, &tx, true)
                }))
                .unwrap_or_else(|_| Err("it stopped unexpectedly".into()));
                drop(tx);
                let _ = forward.join();
                engine.finish_job(n, report);
            })
            .map_err(|e| format!("Couldn't start it: {e}"))?;
        Ok((n, name))
    }

    /// A step or note from a background task: shown by its pointer.
    fn job_progress(&self, n: usize, event: Value) {
        let text = event["text"].as_str().unwrap_or("").to_string();
        if let Some(j) = lock(&self.jobs).iter_mut().find(|j| j.n == n) {
            if !text.is_empty() {
                j.status = text.clone();
            }
        }
        self.job_emit(json!({"type": "job", "phase": event["phase"], "job": n, "name": event["name"], "text": text, "kind": event["kind"]}));
    }

    /// A background task is over: its report goes back to the agent, who
    /// tells the user (the app asks for that with a `handback` request, and
    /// otherwise it rides along with the user's next message).
    fn finish_job(&self, n: usize, report: Result<String, String>) {
        let (name, title, conversation, state, text) = {
            let mut jobs = lock(&self.jobs);
            let Some(j) = jobs.iter_mut().find(|j| j.n == n) else { return };
            let (state, text) = match &report {
                _ if j.cancel.load(Ordering::Relaxed) => ("stopped", "Stopped before it was done.".to_string()),
                Ok(t) => ("done", t.clone()),
                Err(e) => ("failed", format!("Couldn't finish: {e}")),
            };
            j.state = state;
            j.status = text.clone();
            (j.name, j.title.clone(), j.conversation.clone(), state, text)
        };
        let turn = Turn {
            role: "assistant".into(),
            text: text.clone(),
            at: now(),
            screens: 0,
            points: Vec::new(),
            steps: vec![format!("{name}: {title}")],
        };
        let note = if state == "stopped" {
            // Stopped on the user's say-so: it's noted in the chat, and
            // there is nothing to report.
            let mut session = lock(&self.session);
            if session.transcript.id == conversation {
                session.note(turn);
                let _ = self.store.save(&session.transcript);
            } else if let Some(mut t) = self.store.load(&conversation) {
                t.updated_at = now();
                t.turns.push(turn);
                let _ = self.store.save(&t);
            }
            JobNote {
                conversation,
                text: format!("[Background task \u{201C}{title}\u{201D} ({name}) was stopped before it was done.]"),
                label: String::new(),
                turn: None,
            }
        } else {
            let how = if state == "done" { "is back from" } else { "couldn't finish" };
            JobNote {
                conversation,
                text: format!("[{name}, your background agent, {how} \u{201C}{title}\u{201D}. Its report to you:\n{text}]"),
                label: format!("{name}: {title}"),
                turn: Some(turn),
            }
        };
        // In place before the app hears of it and asks for the report.
        lock(&self.job_notes).push(note);
        self.job_emit(json!({"type": "job", "phase": "end", "job": n, "name": name, "title": title, "state": state, "ok": state == "done", "text": text}));
    }

    /// A background task has finished and the user hasn't been told what
    /// came of it: time for a `handback` request, once the agent is free.
    pub fn reports_waiting(&self) -> bool {
        lock(&self.job_notes).iter().any(|n| n.turn.is_some())
    }

    /// The reports waiting for the agent in `conversation`, or all of them.
    fn take_job_notes(&self, conversation: &str, all: bool) -> Vec<JobNote> {
        let mut notes = lock(&self.job_notes);
        let (mine, rest): (Vec<_>, Vec<_>) = notes.drain(..).partition(|n| all || n.conversation == conversation);
        *notes = rest;
        mine
    }

    /// Stops a running background task; false when there's none.
    pub fn stop_job(&self, n: usize) -> bool {
        match lock(&self.jobs).iter().find(|j| j.n == n && j.state == "running") {
            Some(j) => {
                j.cancel.store(true, Ordering::Relaxed);
                true
            }
            None => false,
        }
    }

    /// One agent's own loop, for a helper or a background task (`job`): it
    /// works on its task with its own shell and pointer and returns its
    /// report. Its tool steps and notes go to `tx` as `agent` events, for
    /// its cursor, not into the chat.
    #[allow(clippy::too_many_arguments)]
    fn run_helper(
        &self,
        n: usize,
        name: &str,
        call_id: &str,
        task: &str,
        settings: &Settings,
        cancel: &AtomicBool,
        tx: &mpsc::Sender<Value>,
        job: bool,
    ) -> Result<String, String> {
        if task.is_empty() {
            return Err("no task was given".into());
        }
        let shell = Mutex::new(None);
        let worker = Worker { id: n, shell: &shell };
        let tools = agent::tool_definitions(settings);
        let (home, today) = (self.home.display().to_string(), agent::date_string(now()));
        let system = if job {
            agent::job_prompt(name, settings, &home, &today)
        } else {
            agent::helper_prompt(name, settings, &home, &today)
        };
        let rounds = if job { MAX_ROUNDS } else { HELPER_ROUNDS };
        let mut messages = vec![json!({"role": "user", "content": task})];
        let mut steps = Vec::new();
        let mut emit = |event: Value| {
            // The helper's own steps label its cursor; the chat only shows
            // the helper as one step.
            if event["type"] == "tool" && event["phase"] == "start" {
                let _ = tx.send(json!({"type": "agent", "phase": "step", "agent": n, "id": call_id, "name": name, "text": event["summary"], "kind": event["kind"]}));
            }
        };
        for _ in 0..rounds {
            let body = claude::build_body(settings, &system, &messages, &tools);
            let reply = claude::stream(settings, &body, cancel, |_| {}).map_err(|e| e.message())?;
            let text: String = reply
                .content
                .iter()
                .filter(|b| b["type"] == "text")
                .filter_map(|b| b["text"].as_str())
                .collect::<Vec<_>>()
                .join(" ");
            let stop = reply.stop_reason.clone().unwrap_or_default();
            let calls_made = reply.content.iter().any(|b| b["type"] == "tool_use");
            // As in the main loop: a reply cut off while calling tools goes
            // on, its calls answered with an error instead of being run.
            let cut_off = stop == "max_tokens" && calls_made;
            let empty = reply.content.is_empty();
            if !empty {
                messages.push(json!({"role": "assistant", "content": reply.content}));
            }
            match stop.as_str() {
                "tool_use" | "max_tokens" if calls_made => {
                    let note = text.trim();
                    if !note.is_empty() {
                        let _ = tx.send(json!({"type": "agent", "phase": "note", "agent": n, "id": call_id, "name": name, "text": agent::clip_words(note, 14)}));
                    }
                    let blocks = messages.last().unwrap()["content"]
                        .as_array()
                        .cloned()
                        .unwrap_or_default();
                    let calls: Vec<Call> = blocks.iter().filter_map(Call::from_block).collect();
                    let results: Vec<Value> = if cut_off {
                        calls.iter().map(|c| tool_result(c, json!(CUT_OFF), true)).collect()
                    } else {
                        self.run_calls(&worker, settings, &calls, &reply.invalid_inputs, true, cancel, &mut steps, &mut emit)
                            .map_err(|e| e.message())?
                    };
                    messages.push(json!({"role": "user", "content": results}));
                }
                "pause_turn" if !empty => {}
                _ => {
                    let report = text.trim();
                    return Ok(if report.is_empty() {
                        format!("Done. Steps: {}", steps.join("; "))
                    } else {
                        report.to_string()
                    });
                }
            }
        }
        Err(format!(
            "it ran out of steps after {rounds}; it got this far: {}",
            steps.join("; ")
        ))
    }

    fn run_bash(
        &self,
        shell: &Mutex<Option<Shell>>,
        input: &Value,
        cancel: &AtomicBool,
    ) -> (Value, bool) {
        let mut shell = lock(shell);
        if input["restart"] == true {
            *shell = None;
            return (json!("The shell was restarted."), false);
        }
        if shell.is_none() {
            match Shell::spawn(&self.home) {
                Ok(s) => *shell = Some(s),
                Err(e) => return (json!(format!("Couldn't start a shell: {e}")), true),
            }
        }
        let command = input["command"].as_str().unwrap_or("");
        if command.trim().is_empty() {
            return (json!("No command was given."), true);
        }
        match shell.as_mut().unwrap().run(command, cancel) {
            Ok((out, code)) => {
                let mut text = if out.trim().is_empty() {
                    "(no output)".to_string()
                } else {
                    out
                };
                if code != 0 {
                    text.push_str(&format!("\n[exit status {code}]"));
                }
                (json!(text), false)
            }
            Err(e) => {
                *shell = None;
                (json!(e), true)
            }
        }
    }
}

/// Finished tasks' reports as the agent reads them.
fn note_text(notes: &[JobNote]) -> String {
    notes.iter().map(|n| n.text.as_str()).collect::<Vec<_>>().join("\n")
}

/// What the model keeps of an exchange that was stopped or failed midway,
/// as two plain messages: the question, and what had been said and done.
fn unfinished_exchange(
    notes: &[String],
    req: &Request,
    said: &str,
    steps: &[String],
    error: &ApiError,
) -> Vec<Value> {
    let mut question = notes.join("\n");
    if !question.is_empty() {
        question.push('\n');
    }
    question.push_str(match req.text.trim() {
        "" => "(asked about the screen)",
        text => text,
    });
    let mut reply = said.trim().to_string();
    if !reply.is_empty() {
        reply.push_str("\n\n");
    }
    reply.push_str(&match error {
        ApiError::Cancelled => "(The user stopped me before I finished this.".to_string(),
        e => format!("(I couldn't finish this: {}.", e.message().trim_end_matches('.')),
    });
    if !steps.is_empty() {
        let from = steps.len().saturating_sub(20);
        reply.push_str(&format!(" What I had done by then: {}.", steps[from..].join("; ")));
    }
    reply.push(')');
    vec![
        json!({"role": "user", "content": [{"type": "text", "text": question}]}),
        json!({"role": "assistant", "content": [{"type": "text", "text": reply}]}),
    ]
}

fn tool_result(call: &Call, content: Value, is_error: bool) -> Value {
    let content = match content {
        Value::String(s) if s.trim().is_empty() => json!("(no output)"),
        Value::Null => json!("(no output)"),
        other => other,
    };
    let mut r = json!({"type": "tool_result", "tool_use_id": call.id, "content": content});
    if is_error {
        r["is_error"] = json!(true);
    }
    if call.is_computer() {
        r["toolset_name"] = json!("computer");
    }
    r
}

/// Builds the user turn: each screenshot with a caption, then the question.
pub fn user_content(req: &Request) -> Vec<Value> {
    let mut content = Vec::new();
    for (i, s) in req.screens.iter().enumerate() {
        let mut caption = format!("Screen {i}");
        let mut notes = Vec::new();
        if !s.label.is_empty() {
            notes.push(s.label.clone());
        }
        if s.has_cursor {
            notes.push("cursor is here".into());
        }
        if !notes.is_empty() {
            caption.push_str(&format!(" ({})", notes.join(", ")));
        }
        caption.push_str(&format!(": {}x{}", s.image_w.round(), s.image_h.round()));
        content.push(json!({"type": "text", "text": caption}));
        content.push(json!({
            "type": "image",
            "source": {"type": "base64", "media_type": "image/jpeg", "data": s.jpeg_b64},
        }));
    }
    if req.sketch && !req.screens.is_empty() {
        content.push(json!({
            "type": "text",
            "text": "I drew on my screen with a pen to show what I mean; my strokes are in the screenshot.",
        }));
    }
    let text = if req.text.trim().is_empty() && req.sketch {
        "What is this I've marked?".to_string()
    } else if req.text.trim().is_empty() {
        "What am I looking at? Help me with what's on my screen.".to_string()
    } else {
        req.text.trim().to_string()
    };
    content.push(json!({"type": "text", "text": text}));
    content
}

/// Routes streamed text through the mark-up filter and the sentence
/// chunker, emitting UI events as pieces settle.
struct ReplyStream {
    filter: MarkupFilter,
    chunker: SentenceChunker,
    screens: Vec<(Rect, f64, f64)>,
    visible: String,
    labels: Vec<String>,
    /// While an agent task works, its notes are shown but not read aloud:
    /// sentences wait in `held` until the round turns out to be the answer.
    quiet: bool,
    held: Vec<String>,
}

impl ReplyStream {
    fn new(screens: &[ScreenShot]) -> Self {
        Self {
            filter: MarkupFilter::new(),
            chunker: SentenceChunker::new(),
            screens: screens
                .iter()
                .map(|s| (s.frame, s.image_w, s.image_h))
                .collect(),
            visible: String::new(),
            labels: Vec::new(),
            quiet: false,
            held: Vec::new(),
        }
    }

    fn speak(&mut self, sentence: String, emit: Emit) {
        if self.quiet {
            self.held.push(sentence);
        } else {
            emit(json!({"type": "speak", "text": sentence}));
        }
    }

    fn push(&mut self, delta: &str, emit: Emit) {
        let pieces = self.filter.push(delta);
        self.handle(pieces, emit);
    }

    fn finish(&mut self, emit: Emit) {
        let pieces = self.filter.finish();
        self.handle(pieces, emit);
        if let Some(s) = self.chunker.finish() {
            self.speak(s, emit);
        }
    }

    /// The reply broke off and is being asked for again: what was shown of
    /// it stays, the sentence it was in is not read aloud, and the new
    /// attempt starts a new paragraph.
    fn restart(&mut self, emit: Emit) {
        self.filter = MarkupFilter::new();
        self.chunker = SentenceChunker::new();
        if !self.visible.trim().is_empty() && !self.visible.ends_with("\n\n") {
            self.visible.push_str("\n\n");
            emit(json!({"type": "text", "text": "\n\n"}));
        }
    }

    /// Ends one reply of an agent task: flushes what's pending and starts a
    /// new paragraph, so text from the next round doesn't run on. `last` is
    /// the answer: held sentences are read aloud then, and dropped otherwise.
    fn end_segment(&mut self, last: bool, emit: Emit) {
        self.finish(&mut *emit);
        for s in std::mem::take(&mut self.held) {
            if last {
                emit(json!({"type": "speak", "text": s}));
            }
        }
        self.filter = MarkupFilter::new();
        if !self.visible.trim().is_empty() && !self.visible.ends_with("\n\n") {
            self.visible.push_str("\n\n");
            emit(json!({"type": "text", "text": "\n\n"}));
        }
    }

    fn handle(&mut self, pieces: Vec<Piece>, emit: Emit) {
        for piece in pieces {
            match piece {
                Piece::Text(t) => {
                    self.visible.push_str(&t);
                    emit(json!({"type": "text", "text": t}));
                    for s in self.chunker.push(&t) {
                        self.speak(s, &mut *emit);
                    }
                }
                Piece::Mark(m) => {
                    if let Shape::Focus { id } = &m.shape {
                        emit(json!({"type": "focus", "id": id}));
                        continue;
                    }
                    let board = m.screen == markup::BOARD;
                    // Screenshot pixels → global top-left-origin points; the
                    // board's own units stay as they are.
                    let (ox, oy, sx, sy, iw, ih) = if board {
                        (0.0, 0.0, 1.0, 1.0, markup::BOARD_W, markup::BOARD_H)
                    } else {
                        let Some(&(frame, iw, ih)) = self.screens.get(m.screen) else {
                            continue;
                        };
                        if iw <= 0.0 || ih <= 0.0 {
                            continue;
                        }
                        (frame.x, frame.y, frame.w / iw, frame.h / ih, iw, ih)
                    };
                    let gx = |x: f64| ox + x.clamp(0.0, iw) * sx;
                    let gy = |y: f64| oy + y.clamp(0.0, ih) * sy;
                    let rect = |x: f64, y: f64, w: f64, h: f64| {
                        json!({"x": gx(x), "y": gy(y), "w": gx(x + w) - gx(x), "h": gy(y + h) - gy(y)})
                    };
                    let with = |mut v: Value, shape: &str| {
                        v["shape"] = json!(shape);
                        v
                    };
                    let mut event = match m.shape {
                        Shape::Point { x, y } => json!({"shape": "point", "x": gx(x), "y": gy(y)}),
                        Shape::Circle { x, y, r } => {
                            json!({"shape": "circle", "x": gx(x), "y": gy(y), "r": r * sx})
                        }
                        Shape::Arrow { x1, y1, x2, y2 } => json!({
                            "shape": "arrow", "x1": gx(x1), "y1": gy(y1), "x2": gx(x2), "y2": gy(y2),
                        }),
                        Shape::Box { x, y, w, h } => with(rect(x, y, w, h), "box"),
                        Shape::Underline { x, y, w } => json!({
                            "shape": "underline", "x": gx(x), "y": gy(y), "w": gx(x + w) - gx(x),
                        }),
                        Shape::Highlight { x, y, w, h } => with(rect(x, y, w, h), "highlight"),
                        Shape::Spotlight { x, y, w, h } => with(rect(x, y, w, h), "spotlight"),
                        Shape::Trace { points } => json!({
                            "shape": "trace",
                            "points": points.iter().map(|&(x, y)| json!([gx(x), gy(y)])).collect::<Vec<_>>(),
                        }),
                        Shape::Note { x, y, text } => {
                            json!({"shape": "note", "x": gx(x), "y": gy(y), "text": text})
                        }
                        Shape::Check { x, y } => json!({"shape": "check", "x": gx(x), "y": gy(y)}),
                        Shape::Cross { x, y } => json!({"shape": "cross", "x": gx(x), "y": gy(y)}),
                        Shape::Step { x, y, n } => json!({"shape": "step", "x": gx(x), "y": gy(y), "n": n}),
                        Shape::Bracket { x, y, h } => {
                            json!({"shape": "bracket", "x": gx(x), "y": gy(y), "h": gy(y + h) - gy(y)})
                        }
                        Shape::Board { title } => json!({"shape": "open", "title": title}),
                        Shape::Card { id, x, y, text, icon } => json!({
                            "shape": "card", "id": id, "x": gx(x), "y": gy(y), "text": text, "icon": icon,
                        }),
                        Shape::Link { from, to, text } => {
                            json!({"shape": "link", "from": from, "to": to, "text": text})
                        }
                        Shape::Write { x, y, text, size } => json!({
                            "shape": "write", "x": gx(x), "y": gy(y), "text": text, "size": size,
                        }),
                        Shape::Focus { .. } => unreachable!(),
                    };
                    // A point on a screen flies the buddy; everything else is drawn.
                    event["type"] = json!(if board {
                        "board"
                    } else if event["shape"] == "point" {
                        "point"
                    } else {
                        "mark"
                    });
                    event["screen"] = json!(if board { -1 } else { m.screen as i64 });
                    event["label"] = json!(m.label);
                    if !m.label.is_empty() {
                        self.labels.push(m.label);
                    }
                    emit(event);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_points_from_image_pixels_to_global_points() {
        let shot = ScreenShot {
            label: "Main".into(),
            has_cursor: true,
            frame: Rect {
                x: 100.0,
                y: 0.0,
                w: 1440.0,
                h: 900.0,
            },
            image_w: 1280.0,
            image_h: 800.0,
            jpeg_b64: String::new(),
        };
        let mut rs = ReplyStream::new(&[shot]);
        let mut events = Vec::new();
        rs.push(
            "Click <point x=\"640\" y=\"400\" screen=\"0\" label=\"Save\"/> here.",
            &mut |e| events.push(e),
        );
        rs.finish(&mut |e| events.push(e));
        let point = events.iter().find(|e| e["type"] == "point").unwrap();
        assert_eq!(point["x"], 820.0);
        assert_eq!(point["y"], 450.0);
        assert_eq!(rs.visible, "Click  here.");
        assert!(events
            .iter()
            .any(|e| e["type"] == "speak" && e["text"] == "Click here."));
    }

    #[test]
    fn quiet_notes_are_held_back_and_the_answer_is_spoken() {
        let mut rs = ReplyStream::new(&[]);
        let mut events = Vec::new();
        rs.push("On it, checking.", &mut |e| events.push(e));
        rs.end_segment(false, &mut |e| events.push(e));
        rs.quiet = true;
        rs.push("Opening Safari now.", &mut |e| events.push(e));
        rs.end_segment(false, &mut |e| events.push(e));
        rs.push("Done, it's booked.", &mut |e| events.push(e));
        rs.end_segment(true, &mut |e| events.push(e));
        let spoken: Vec<_> = events
            .iter()
            .filter(|e| e["type"] == "speak")
            .map(|e| e["text"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(spoken, ["On it, checking.", "Done, it's booked."]);
        assert!(rs.visible.contains("Opening Safari now."));
    }

    #[test]
    fn point_on_unknown_screen_is_ignored() {
        let mut rs = ReplyStream::new(&[]);
        let mut events = Vec::new();
        rs.push("<point x=\"1\" y=\"1\" screen=\"3\"/>", &mut |e| {
            events.push(e)
        });
        assert!(events.iter().all(|e| e["type"] != "point"));
    }

    #[test]
    fn maps_marks_and_clamps_boxes_to_the_screen() {
        let shot = ScreenShot {
            label: String::new(),
            has_cursor: false,
            frame: Rect {
                x: 0.0,
                y: 0.0,
                w: 2000.0,
                h: 1000.0,
            },
            image_w: 1000.0,
            image_h: 500.0,
            jpeg_b64: String::new(),
        };
        let mut rs = ReplyStream::new(&[shot]);
        let mut events = Vec::new();
        rs.push(
            "<circle x=\"100\" y=\"100\" r=\"10\"/><arrow x1=\"0\" y1=\"0\" x2=\"50\" y2=\"25\"/>\
             <box x=\"950\" y=\"10\" w=\"100\" h=\"20\" label=\"Total\"/>",
            &mut |e| events.push(e),
        );
        let marks: Vec<_> = events.iter().filter(|e| e["type"] == "mark").collect();
        assert_eq!(marks.len(), 3);
        assert_eq!(
            (marks[0]["x"].as_f64(), marks[0]["r"].as_f64()),
            (Some(200.0), Some(20.0))
        );
        assert_eq!(
            (marks[1]["x2"].as_f64(), marks[1]["y2"].as_f64()),
            (Some(100.0), Some(50.0))
        );
        assert_eq!(
            (marks[2]["x"].as_f64(), marks[2]["w"].as_f64()),
            (Some(1900.0), Some(100.0))
        );
        assert_eq!(rs.labels, ["Total"]);
    }

    #[test]
    fn sketch_adds_a_note_before_the_question() {
        let req = Request {
            text: String::new(),
            screens: vec![ScreenShot {
                label: String::new(),
                has_cursor: true,
                frame: Rect::default(),
                image_w: 1.0,
                image_h: 1.0,
                jpeg_b64: String::new(),
            }],
            sketch: true,
            handback: false,
        };
        let content = user_content(&req);
        let texts: Vec<_> = content.iter().filter_map(|b| b["text"].as_str()).collect();
        assert!(texts.iter().any(|t| t.starts_with("I drew on my screen")));
        assert_eq!(texts.last(), Some(&"What is this I've marked?"));
    }

    use crate::claude::fake::{self, Reply};

    /// An engine that talks to the fake API, with Mac access off (so the
    /// one tool is `memory`), and its data folder.
    fn engine_for(api: &fake::Api) -> (Engine, PathBuf) {
        let dir = std::env::temp_dir().join(format!("cp-engine-{}", uuid::Uuid::new_v4()));
        let engine = Engine::new(dir.clone());
        *lock(&engine.settings) = api.settings();
        (engine, dir)
    }

    fn ask(engine: &Engine, text: &str) -> Vec<Value> {
        let (id, cancel) = engine.next_request_id();
        let mut events = Vec::new();
        let request = Request { text: text.into(), screens: Vec::new(), sketch: false, handback: false };
        engine.run(id, &cancel, request, &mut |e| events.push(e));
        events
    }

    /// A finished background task's note for the live conversation; with
    /// `report`, one the user hasn't been told about yet.
    fn note(engine: &Engine, text: &str, report: Option<&str>) {
        let turn = report.map(|r| Turn {
            role: "assistant".into(),
            text: r.into(),
            at: now(),
            screens: 0,
            points: Vec::new(),
            steps: vec!["Nova: the form".into()],
        });
        lock(&engine.job_notes).push(JobNote {
            conversation: engine.current_conversation_id(),
            text: text.into(),
            label: if report.is_some() { "Nova: the form".into() } else { String::new() },
            turn,
        });
    }

    fn report_back(engine: &Engine) -> Vec<Value> {
        let (id, cancel) = engine.next_request_id();
        let mut events = Vec::new();
        let request = Request { text: String::new(), screens: Vec::new(), sketch: false, handback: true };
        engine.run(id, &cancel, request, &mut |e| events.push(e));
        events
    }

    fn of_type<'a>(events: &'a [Value], kind: &str) -> Vec<&'a Value> {
        events.iter().filter(|e| e["type"] == kind).collect()
    }

    fn history(engine: &Engine) -> Vec<Value> {
        lock(&engine.session).api_messages.clone()
    }

    fn remember(id: &str, fact: &str) -> Value {
        json!({"type": "tool_use", "id": id, "name": "memory", "input": {"action": "remember", "text": fact}})
    }

    /// What the API demands of a history before it takes another message.
    fn assert_replayable(messages: &[Value]) {
        assert_eq!(messages[0]["role"], "user", "a user message comes first");
        for (i, m) in messages.iter().enumerate() {
            let content = m["content"].as_array().expect("content blocks");
            assert!(!content.is_empty(), "message {i} is empty");
            if i > 0 {
                assert_ne!(m["role"], messages[i - 1]["role"], "roles alternate at {i}");
            }
            for b in content.iter().filter(|b| b["type"] == "text") {
                assert!(!b["text"].as_str().unwrap().trim().is_empty(), "empty text in message {i}");
            }
            let ids = |blocks: &[Value], kind: &str, key: &str| -> Vec<String> {
                blocks.iter().filter(|b| b["type"] == kind).map(|b| b[key].as_str().unwrap().to_string()).collect()
            };
            let calls = ids(content, "tool_use", "id");
            if !calls.is_empty() {
                let next = messages.get(i + 1).expect("a tool call is answered");
                assert_eq!(calls, ids(next["content"].as_array().unwrap(), "tool_result", "tool_use_id"));
            }
        }
        assert_eq!(messages.last().unwrap()["role"], "assistant");
    }

    #[test]
    fn a_task_runs_its_tools_and_ends_with_done_then_finished() {
        let api = fake::Api::start(vec![
            Reply::Events(fake::events(&[fake::text("Noting that."), remember("toolu_1", "Likes tea.")], "tool_use")),
            fake::says("Done."),
        ]);
        let (engine, dir) = engine_for(&api);
        let (id, cancel) = engine.next_request_id();
        assert!(engine.tell(id, "and sugar"));
        let mut events = Vec::new();
        let request = Request { text: "Remember I like tea".into(), screens: Vec::new(), sketch: false, handback: false };
        engine.run(id, &cancel, request, &mut |e| events.push(e));

        let kinds: Vec<&str> = events.iter().map(|e| e["type"].as_str().unwrap()).collect();
        assert_eq!(kinds.first(), Some(&"started"));
        assert_eq!(&kinds[kinds.len() - 2..], ["done", "finished"]);
        assert_eq!(kinds.iter().filter(|k| **k == "finished" || **k == "done").count(), 2);
        assert_eq!(events[events.len() - 2]["text"], "Noting that.\n\nDone.");
        assert_eq!(engine.memory().list()[0].text, "Likes tea.");
        // The second request answers the call, and passes on what was said meanwhile.
        let results = api.request(1)["messages"][2]["content"].clone();
        assert_eq!(results[0]["tool_use_id"], "toolu_1");
        assert!(results[1]["text"].as_str().unwrap().contains("and sugar"));
        assert_eq!(of_type(&events, "heard_while_working").len(), 1);
        assert!(lock(&engine.inbox).is_empty());
        assert!(!engine.tell(id, "too late"), "the request is over");
        assert_replayable(&history(&engine));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn the_system_prompt_stays_the_same_through_a_conversation() {
        let api = fake::Api::start(vec![
            Reply::Events(fake::events(&[remember("toolu_1", "Likes tea.")], "tool_use")),
            fake::says("Noted."),
            fake::says("Sure."),
            fake::says("Hello again."),
        ]);
        let (engine, dir) = engine_for(&api);
        ask(&engine, "Remember I like tea");
        ask(&engine, "Thanks");
        // The memory changed after the first request; the prompt replies
        // were produced under did not, and the history only grew.
        assert!(!api.request(0)["system"].to_string().contains("Likes tea."));
        assert_eq!(api.request(2)["system"], api.request(0)["system"]);
        assert_eq!(api.request(2)["tools"], api.request(0)["tools"]);
        let (earlier, later) = (api.request(1), api.request(2));
        let sent = earlier["messages"].as_array().unwrap();
        assert_eq!(&later["messages"].as_array().unwrap()[..sent.len()], &sent[..]);
        // A new conversation starts from the memory as it is now.
        engine.new_conversation();
        ask(&engine, "Hi");
        assert!(api.request(3)["system"].to_string().contains("Likes tea."));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_reply_cut_off_in_a_tool_call_is_answered_not_left_hanging() {
        let cut = json!({"type": "tool_use", "id": "toolu_1", "name": "memory", "partial": "{\"action\": \"remember\", \"text\": \"Likes t"});
        let api = fake::Api::start(vec![
            Reply::Events(fake::events(&[fake::text("Saving it."), cut.clone()], "max_tokens")),
            // Complete JSON this time, but the reply still hit the limit.
            Reply::Events(fake::events(&[remember("toolu_2", "Likes tea.")], "max_tokens")),
            // Broken input in a reply that otherwise ended normally.
            Reply::Events(fake::events(&[{ let mut c = cut; c["id"] = json!("toolu_3"); c }], "tool_use")),
            fake::says("I'll keep it short."),
            fake::says("Yes."),
        ]);
        let (engine, dir) = engine_for(&api);
        let events = ask(&engine, "Remember I like tea");
        assert!(of_type(&events, "error").is_empty(), "{events:?}");
        assert_eq!(of_type(&events, "done").len(), 1);
        for (request, id, why) in [(1, "toolu_1", CUT_OFF), (2, "toolu_2", CUT_OFF), (3, "toolu_3", INVALID_INPUT)] {
            let messages = api.request(request)["messages"].clone();
            let result = &messages[messages.as_array().unwrap().len() - 1]["content"][0];
            assert_eq!(result["tool_use_id"], id);
            assert_eq!((result["is_error"].as_bool(), result["content"].as_str()), (Some(true), Some(why)));
        }
        assert!(engine.memory().list().is_empty(), "none of the three calls ran");
        assert_replayable(&history(&engine));
        // The conversation goes on: the next request is accepted.
        assert_eq!(of_type(&ask(&engine, "Still there?"), "done").len(), 1);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn an_empty_reply_does_not_leave_an_empty_message() {
        let api = fake::Api::start(vec![
            Reply::Events(fake::events(&[], "end_turn")),
            Reply::Events(fake::events(&[fake::text("")], "tool_use")),
            fake::says("Here."),
        ]);
        let (engine, dir) = engine_for(&api);
        assert_eq!(of_type(&ask(&engine, "Hm"), "done").len(), 1);
        assert_replayable(&history(&engine));
        // "tool_use" with no call in it is an answer, not 300 more rounds.
        assert_eq!(of_type(&ask(&engine, "Hm?"), "done").len(), 1);
        assert_eq!(api.request_count(), 2);
        assert_eq!(of_type(&ask(&engine, "Hello?"), "done")[0]["text"], "Here.");
        assert_replayable(&history(&engine));
        assert_replayable(&api.request(2)["messages"].as_array().unwrap()[..4]);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_history_whose_thinking_is_refused_goes_on_without_it() {
        let thinking = json!({"type": "thinking", "thinking": "", "signature": "sig"});
        let refused = "messages.1.content.0: Invalid `signature` in `thinking` block. The block is bound to a different conversation.";
        let api = fake::Api::start(vec![
            Reply::Events(fake::events(&[thinking, fake::text("Hi.")], "end_turn")),
            Reply::Refused(refused),
            fake::says("Still here."),
            fake::says("Yes."),
            // With no thinking left to take out, the same refusal is an error.
            Reply::Refused(refused),
        ]);
        let (engine, dir) = engine_for(&api);
        ask(&engine, "Hello");
        assert!(history(&engine)[1]["content"].to_string().contains("thinking"), "kept as received");
        let events = ask(&engine, "Are you there?");
        assert!(of_type(&events, "error").is_empty(), "{events:?}");
        assert_eq!(of_type(&events, "done")[0]["text"], "Still here.");
        assert!(api.request(1)["messages"].to_string().contains("thinking"));
        assert!(!api.request(2)["messages"].to_string().contains("thinking"));
        assert_eq!(api.request(2)["messages"][1]["content"], json!([{"type": "text", "text": "Hi."}]));
        // And it stays that way, so the next request isn't refused again.
        ask(&engine, "Good");
        assert_eq!(api.request_count(), 4);
        assert!(!api.request(3)["messages"].to_string().contains("thinking"));
        assert_replayable(&history(&engine));
        assert_eq!(of_type(&ask(&engine, "Again"), "error").len(), 1);
        assert_eq!(api.request_count(), 5);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn stopping_is_prompt_and_quiet_and_the_gist_is_kept() {
        let api = fake::Api::start(vec![
            Reply::Stalled(fake::starts("Sure. The way to do that is to open")),
            fake::says("Okay."),
        ]);
        let (engine, dir) = engine_for(&api);
        let engine = Arc::new(engine);
        let (id, cancel) = engine.next_request_id();
        let stopper = engine.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(300));
            stopper.cancel(id);
        });
        let started = std::time::Instant::now();
        let mut events = Vec::new();
        let request = Request { text: "How do I export this?".into(), screens: Vec::new(), sketch: false, handback: false };
        engine.run(id, &cancel, request, &mut |e| events.push(e));
        assert!(started.elapsed() < Duration::from_secs(2), "took {:?}", started.elapsed());
        // The sentence that was complete was read aloud as it came; the half
        // one it was in is not blurted out after the stop.
        let spoken: Vec<&str> = of_type(&events, "speak").iter().map(|e| e["text"].as_str().unwrap()).collect();
        assert_eq!(spoken, ["Sure."]);
        let kinds: Vec<&str> = events.iter().map(|e| e["type"].as_str().unwrap()).collect();
        assert_eq!(&kinds[kinds.len() - 2..], ["error", "finished"]);
        assert_eq!(events[events.len() - 2]["kind"], "cancelled");
        assert!(!engine.tell(id, "wait"));
        // The model still knows what was asked and how far it got.
        let kept = history(&engine);
        assert_replayable(&kept);
        assert_eq!(kept[0]["content"][0]["text"], "How do I export this?");
        let gist = kept[1]["content"][0]["text"].as_str().unwrap();
        assert!(gist.starts_with("Sure. The way to do that is to open"), "{gist}");
        assert!(gist.ends_with("(The user stopped me before I finished this.)"), "{gist}");
        assert_eq!(of_type(&ask(&engine, "Carry on"), "done").len(), 1);
        assert_eq!(api.request(1)["messages"].as_array().unwrap().len(), 3);
        assert_eq!(engine.store().load(&engine.current_conversation_id()).unwrap().turns.len(), 4);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_task_cut_off_by_a_passing_failure_keeps_its_gist() {
        let mut replies = vec![Reply::Events(fake::events(
            &[fake::text("Noting that."), remember("toolu_1", "Likes tea.")],
            "tool_use",
        ))];
        let tries = claude::MAX_RETRIES as usize + 1;
        replies.extend((0..tries).map(|_| Reply::Status(529, "overloaded_error", vec![])));
        replies.push(fake::says("It is saved."));
        let api = fake::Api::start(replies);
        let (engine, dir) = engine_for(&api);
        note(&engine, "[Background task done.]", None);
        let events = ask(&engine, "Remember I like tea");
        assert_eq!(of_type(&events, "error")[0]["kind"], "overloaded");
        assert_eq!(api.request_count(), 1 + tries, "the failing round was retried");
        let kept = history(&engine);
        assert_replayable(&kept);
        assert_eq!(kept.len(), 2);
        assert_eq!(kept[0]["content"][0]["text"], "[Background task done.]\nRemember I like tea");
        let gist = kept[1]["content"][0]["text"].as_str().unwrap();
        assert!(gist.contains("I couldn't finish this: API error 529"), "{gist}");
        assert!(gist.contains("What I had done by then: Remembered \u{201C}Likes tea.\u{201D}."), "{gist}");
        assert_eq!(of_type(&ask(&engine, "Did it work?"), "done")[0]["text"], "It is saved.");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_refused_request_is_not_kept_and_its_task_reports_come_again() {
        let api = fake::Api::start(vec![
            Reply::Events(fake::events(&[fake::text("Hm.")], "pause_turn")),
            Reply::Refused("messages: too long"),
            fake::says("Fine."),
        ]);
        let (engine, dir) = engine_for(&api);
        note(&engine, "[Background task done.]", None);
        let events = ask(&engine, "Go on");
        assert_eq!(of_type(&events, "error")[0]["kind"], "http");
        // Shown to the user, but not sent again: it may be what the API refused.
        assert!(history(&engine).is_empty());
        assert_eq!(engine.store().load(&engine.current_conversation_id()).unwrap().turns.len(), 2);
        ask(&engine, "And now?");
        assert_eq!(api.request(2)["messages"][0]["content"][0]["text"], "[Background task done.]");
        assert!(lock(&engine.job_notes).is_empty());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_finished_task_is_handed_back_and_the_agent_tells_the_user() {
        let api = fake::Api::start(vec![
            fake::says("On it."),
            fake::says("The form is renewed, Boss. It's in Downloads."),
            fake::says("Yes."),
        ]);
        let (engine, dir) = engine_for(&api);
        lock(&engine.settings).address = "Boss, King".into();
        ask(&engine, "Renew the form in the background");
        assert!(!engine.reports_waiting());
        note(&engine, "[Nova is back. Its report to you:\nSaved as form.pdf]", Some("Saved as form.pdf"));
        assert!(engine.reports_waiting());
        let events = report_back(&engine);
        assert!(of_type(&events, "error").is_empty(), "{events:?}");
        assert!(!engine.reports_waiting());
        // Said by the agent, in its own words.
        let spoken: Vec<&str> = of_type(&events, "speak").iter().map(|e| e["text"].as_str().unwrap()).collect();
        assert_eq!(spoken, ["The form is renewed, Boss.", "It's in Downloads."]);
        let sent = api.request(1);
        assert!(sent["system"].to_string().contains("call them \u{201C}Boss\u{201D}"), "{}", sent["system"]);
        assert!(sent["system"].to_string().contains("say \u{201C}King\u{201D} instead"));
        let told = sent["messages"][2]["content"].as_array().unwrap();
        assert_eq!(told.len(), 1, "no question and no screenshot: {told:?}");
        let told = told[0]["text"].as_str().unwrap();
        assert!(told.starts_with("[Nova is back.") && told.ends_with(REPORT_BACK), "{told}");
        // The chat shows the agent's words with the task as a step, not the raw report.
        let turns = engine.store().load(&engine.current_conversation_id()).unwrap().turns;
        assert_eq!(turns.len(), 3);
        assert_eq!((turns[2].role.as_str(), turns[2].text.as_str()), ("assistant", "The form is renewed, Boss. It's in Downloads."));
        assert_eq!(turns[2].steps, ["Nova: the form"]);
        assert_replayable(&history(&engine));
        assert!(lock(&engine.job_notes).is_empty());
        // Nothing left to report: no request is made, and nothing is said.
        let events = report_back(&engine);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["type"], "finished");
        assert_eq!(api.request_count(), 2);
        assert_eq!(of_type(&ask(&engine, "Good?"), "done")[0]["text"], "Yes.");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_report_the_agent_cannot_give_is_shown_as_written_and_comes_again() {
        let api = fake::Api::start(vec![Reply::Refused("messages: too long"), fake::says("It's saved as form.pdf.")]);
        let (engine, dir) = engine_for(&api);
        note(&engine, "[Nova is back. Its report to you:\nSaved as form.pdf]", Some("Saved as form.pdf"));
        let events = report_back(&engine);
        assert_eq!(of_type(&events, "error").len(), 1);
        let turns = engine.store().load(&engine.current_conversation_id()).unwrap().turns;
        assert_eq!(turns.len(), 1);
        assert_eq!((turns[0].text.as_str(), turns[0].steps.clone()), ("Saved as form.pdf", vec!["Nova: the form".to_string()]));
        assert!(history(&engine).is_empty());
        assert!(!engine.reports_waiting(), "it isn't tried over and over");
        // The agent hears of it with the next message, and that it was shown.
        ask(&engine, "Anything new?");
        let told = api.request(1)["messages"][0]["content"][0]["text"].as_str().unwrap().to_string();
        assert!(told.contains("Saved as form.pdf") && told.contains("has now seen this report"), "{told}");
        assert!(!told.contains(REPORT_TOO));
        let turns = engine.store().load(&engine.current_conversation_id()).unwrap().turns;
        assert_eq!(turns.len(), 3, "the report isn't shown twice");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_report_that_meets_a_question_is_told_with_the_answer() {
        let api = fake::Api::start(vec![fake::says("Half past two. And the form is renewed.")]);
        let (engine, dir) = engine_for(&api);
        note(&engine, "[Nova is back. Its report to you:\nSaved as form.pdf]", Some("Saved as form.pdf"));
        ask(&engine, "What time is it?");
        let content = api.request(0)["messages"][0]["content"].clone();
        assert!(content[0]["text"].as_str().unwrap().ends_with(REPORT_TOO));
        assert_eq!(content[1]["text"], "What time is it?");
        let turns = engine.store().load(&engine.current_conversation_id()).unwrap().turns;
        assert_eq!(turns.len(), 2);
        assert_eq!(turns[1].steps, ["Nova: the form"]);
        assert!(lock(&engine.job_notes).is_empty());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_long_talk_about_the_screen_goes_on_with_a_short_history() {
        use crate::conversation::MAX_HISTORY_IMAGES;
        // One screenshot more than the history may hold, and then one more question.
        let last = MAX_HISTORY_IMAGES + 1;
        let replies = (0..=last).map(|i| fake::says(&format!("a{i}"))).collect();
        let api = fake::Api::start(replies);
        let (engine, dir) = engine_for(&api);
        let shot = || ScreenShot {
            label: String::new(),
            has_cursor: true,
            frame: Rect { x: 0.0, y: 0.0, w: 100.0, h: 100.0 },
            image_w: 100.0,
            image_h: 100.0,
            jpeg_b64: "abcd".into(),
        };
        let conversation = engine.current_conversation_id();
        for i in 0..=last {
            let (id, cancel) = engine.next_request_id();
            let request = Request { text: format!("q{i}"), screens: vec![shot()], sketch: false, handback: false };
            engine.run(id, &cancel, request, &mut |_| {});
        }
        assert_eq!(engine.current_conversation_id(), conversation, "still the same chat");
        let images = |n: usize| api.request(n)["messages"].to_string().matches("\"image\"").count();
        assert_eq!(images(last - 1), MAX_HISTORY_IMAGES + 1);
        // Rebuilt from its text, with the new screenshot only.
        assert_eq!(images(last), 1);
        let sent = api.request(last)["messages"].clone();
        let sent_messages = sent.as_array().unwrap();
        assert_replayable(&sent_messages[..sent_messages.len() - 1]);
        assert_eq!(sent_messages.last().unwrap()["role"], "user");
        assert!(sent.to_string().contains(&format!("a{}", last - 1)));
        assert_eq!(engine.store().load(&conversation).unwrap().turns.len(), 2 * (last + 1));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn the_title_it_uses_comes_from_settings() {
        assert_eq!(address_prompt(""), "");
        assert_eq!(address_prompt(" , "), "");
        let one = address_prompt("Boss");
        assert!(one.contains("call them \u{201C}Boss\u{201D}") && !one.contains("instead"), "{one}");
        let two = address_prompt("\u{201C}Boss\u{201D}, King , Chief");
        assert!(two.contains("say \u{201C}King\u{201D} or \u{201C}Chief\u{201D} instead"), "{two}");
    }

    #[test]
    fn a_dropped_reply_restarts_without_reading_the_broken_sentence() {
        let api = fake::Api::start(vec![
            Reply::Dropped(fake::starts("First part. And then the")),
            fake::says("First part. And then the rest."),
        ]);
        let (engine, dir) = engine_for(&api);
        let events = ask(&engine, "Tell me");
        let spoken: Vec<&str> = of_type(&events, "speak").iter().map(|e| e["text"].as_str().unwrap()).collect();
        assert_eq!(spoken, ["First part.", "First part.", "And then the rest."]);
        assert_eq!(of_type(&events, "done").len(), 1);
        assert_eq!(history(&engine)[1]["content"], json!([{"type": "text", "text": "First part. And then the rest."}]));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_panic_still_ends_the_request_and_leaves_the_engine_usable() {
        let api = fake::Api::start(vec![fake::says("Fine.")]);
        let (engine, dir) = engine_for(&api);
        let (id, cancel) = engine.next_request_id();
        let mut events = Vec::new();
        let request = Request { text: "Hi".into(), screens: Vec::new(), sketch: false, handback: false };
        engine.run(id, &cancel, request, &mut |e| {
            if e["type"] == "started" {
                panic!("the app's side blew up");
            }
            events.push(e)
        });
        let kinds: Vec<&str> = events.iter().map(|e| e["type"].as_str().unwrap()).collect();
        assert_eq!(kinds, ["error", "finished"]);
        assert!(lock(&engine.in_flight).is_empty());

        // A lock some thread panicked under doesn't take later calls down.
        let engine = Arc::new(engine);
        let other = engine.clone();
        let _ = std::thread::spawn(move || {
            let _held = other.settings.lock().unwrap();
            panic!("while holding the settings");
        })
        .join();
        assert!(engine.settings.is_poisoned());
        assert_eq!(engine.base_url(), api.url);
        assert_eq!(of_type(&ask(&engine, "Hi"), "done")[0]["text"], "Fine.");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn notes_for_a_stopped_request_are_turned_away() {
        let (engine, dir) = engine_for(&fake::Api::start(Vec::new()));
        let (id, cancel) = engine.next_request_id();
        assert!(engine.tell(id, "one"));
        cancel.store(true, Ordering::Relaxed);
        assert!(!engine.tell(id, "two"));
        engine.finish_request(id);
        assert!(lock(&engine.inbox).is_empty(), "nothing left behind");
        // A task number no task has: no overflow, just no such task.
        let stop = json!({"action": "stop", "id": u64::MAX});
        assert!(engine.background(&stop, &Settings::default()).1);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_helper_goes_on_after_a_cut_off_call_and_reports_back() {
        let delegate = json!({"type": "tool_use", "id": "toolu_d", "name": "delegate", "input": {"task": "List the files", "title": "listing files"}});
        let cut = json!({"type": "tool_use", "id": "toolu_h", "name": "bash", "partial": "{\"command\": \"ls -la /very/long"});
        let api = fake::Api::start(vec![
            Reply::Events(fake::events(&[fake::text("I'll get help."), delegate], "tool_use")),
            // The helper's own requests.
            Reply::Events(fake::events(&[cut], "max_tokens")),
            Reply::Status(529, "overloaded_error", vec![]),
            fake::says("Three files."),
            // Back in the main loop.
            fake::says("There are three."),
        ]);
        let (engine, dir) = engine_for(&api);
        lock(&engine.settings).access = "on".into();
        let events = ask(&engine, "What's in there?");
        assert!(of_type(&events, "error").is_empty(), "{events:?}");
        let helper = api.request(3);
        assert_eq!(helper["messages"][0]["content"], "List the files");
        assert_eq!(helper["messages"][2]["content"][0]["content"], CUT_OFF);
        let report = &api.request(4)["messages"][2]["content"][0];
        assert_eq!((report["tool_use_id"].as_str(), report["content"].as_str()), (Some("toolu_d"), Some("Three files.")));
        let phases: Vec<&str> = of_type(&events, "agent").iter().map(|e| e["phase"].as_str().unwrap()).collect();
        assert_eq!(phases, ["start", "end"]);
        assert_eq!(of_type(&events, "done")[0]["text"], "I'll get help.\n\nThere are three.");
        assert_replayable(&history(&engine));
        let _ = std::fs::remove_dir_all(dir);
    }
}
