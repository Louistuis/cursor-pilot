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

pub const SYSTEM_PROMPT: &str = "\
You are Cursor Pilot, a friendly helper that lives next to the user's mouse cursor on their Mac. \
The user talks to you by voice or texts you from a chat that looks like Messages, and your reply \
is read aloud. Write like a capable friend texting back: short, warm and natural, usually one or two \
short sentences, with no markdown, lists or headings, and no code blocks unless the user asks for code. \
Skip preambles and pleasantries. A blank line between thoughts sends them as separate messages, so use \
one only where a real texter would. Go longer only when the user asks for detail. \
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
}

/// Tool rounds one request may take before it is stopped.
const MAX_ROUNDS: usize = 300;
/// Tool rounds a helper may take for its part.
const HELPER_ROUNDS: usize = 150;

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
    /// Finished tasks' reports, by conversation, for the agent's next turn there.
    job_notes: Mutex<Vec<(String, String)>>,
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
        self.settings.lock().unwrap().base_url.clone()
    }

    pub fn next_request_id(&self) -> (u64, Arc<AtomicBool>) {
        let mut n = self.next_id.lock().unwrap();
        let id = *n;
        *n += 1;
        let flag = Arc::new(AtomicBool::new(false));
        self.in_flight.lock().unwrap().push((id, flag.clone()));
        (id, flag)
    }

    pub fn cancel(&self, id: u64) {
        for (i, flag) in self.in_flight.lock().unwrap().iter() {
            if id == 0 || *i == id {
                flag.store(true, Ordering::Relaxed);
            }
        }
    }

    fn finish_request(&self, id: u64) {
        self.in_flight.lock().unwrap().retain(|(i, _)| *i != id);
    }

    pub fn new_conversation(&self) {
        *self.session.lock().unwrap() = Session::new();
    }

    /// Continues a saved conversation; false when it does not exist.
    pub fn resume_conversation(&self, id: &str) -> bool {
        let mut session = self.session.lock().unwrap();
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
        let mut session = self.session.lock().unwrap();
        if session.transcript.id == id {
            session.transcript.title = title.clone();
        }
        self.store.rename(id, &title);
    }

    pub fn current_conversation_id(&self) -> String {
        self.session.lock().unwrap().transcript.id.clone()
    }

    /// Runs a request to completion on the calling thread, reporting progress
    /// through `emit`. The last event is always `{"type":"finished"}`.
    pub fn run(&self, id: u64, cancel: &AtomicBool, req: Request, emit: Emit) {
        let result = self.run_inner(id, cancel, &req, emit);
        if let Err(e) = result {
            emit(json!({"type": "error", "kind": e.kind(), "message": e.message()}));
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
        let settings = self.settings.lock().unwrap().clone();
        let access = agent::mac_access(&settings.access);
        let mut tools = agent::tool_definitions(&settings);
        tools.push(memory::tool());
        if access {
            tools.push(agent::delegate_tool());
            if self.this.upgrade().is_some() {
                tools.push(agent::background_tool());
            }
        }
        let system = format!(
            "{SYSTEM_PROMPT}{}{}",
            self.memory.prompt(),
            agent::system_addendum(
                &settings,
                &self.home.display().to_string(),
                &agent::date_string(now()),
                settings.input != "background",
            )
        );
        let (conversation_id, history) = {
            let mut session = self.session.lock().unwrap();
            if session.is_stale() {
                *session = Session::new();
            }
            (session.transcript.id.clone(), session.api_messages.clone())
        };
        emit(json!({"type": "started", "id": id, "conversation_id": conversation_id}));

        let mut out = ReplyStream::new(&req.screens);
        let mut messages = history.clone();
        let mut content = user_content(req);
        let notes = self.take_job_notes(&conversation_id);
        if !notes.is_empty() {
            content.insert(0, json!({"type": "text", "text": notes.join("\n")}));
        }
        messages.push(json!({"role": "user", "content": content}));
        let mut steps: Vec<String> = Vec::new();
        let mut finished = None;

        // The agent loop: stream a reply, run the tools it asks for, send the
        // results back, until Claude answers without calling a tool.
        let result = (|| -> Result<(), ApiError> {
            for _ in 0..MAX_ROUNDS {
                let body = claude::build_body(&settings, &system, &messages, &tools);
                let reply = claude::stream(
                    &settings,
                    &body,
                    cancel,
                    |claude::StreamEvent::TextDelta(t)| out.push(t, &mut *emit),
                )?;
                let more = matches!(reply.stop_reason.as_deref(), Some("tool_use" | "pause_turn"));
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
                let stop = reply.stop_reason.clone().unwrap_or_default();
                messages.push(json!({"role": "assistant", "content": reply.content}));
                match stop.as_str() {
                    "tool_use" => {
                        let blocks = messages.last().unwrap()["content"]
                            .as_array()
                            .cloned()
                            .unwrap_or_default();
                        let calls: Vec<Call> = blocks.iter().filter_map(Call::from_block).collect();
                        if calls.is_empty() {
                            break;
                        }
                        let main = Worker { id: 0, shell: &self.shell };
                        let results = self.run_calls(
                            &main,
                            &settings,
                            &calls,
                            access,
                            cancel,
                            &mut steps,
                            &mut *emit,
                        )?;
                        messages.push(json!({"role": "user", "content": results}));
                        // Narration while working is shown, not read aloud.
                        out.quiet = true;
                    }
                    // A server tool (web search) paused a long turn: send it back to continue.
                    "pause_turn" => {}
                    _ => {
                        finished = Some((reply.stop_reason, reply.usage));
                        return Ok(());
                    }
                }
            }
            Err(ApiError::Protocol(format!(
                "stopped after {MAX_ROUNDS} steps; ask me to continue"
            )))
        })();
        out.finish(&mut *emit);

        let user_turn = Turn {
            role: "user".into(),
            text: req.text.clone(),
            at: now(),
            screens: req.screens.len(),
            points: Vec::new(),
            steps: Vec::new(),
        };
        let assistant_turn = Turn {
            role: "assistant".into(),
            text: out.visible.trim().to_string(),
            at: now(),
            screens: 0,
            points: out.labels.clone(),
            steps: steps.clone(),
        };
        {
            let mut session = self.session.lock().unwrap();
            // Another request may have replaced the session meanwhile; then
            // this reply no longer belongs to the live history.
            let same = session.transcript.id == conversation_id
                && session.api_messages.len() == history.len();
            if same {
                if result.is_ok() {
                    let new = messages[history.len()..].to_vec();
                    session.commit_messages(new, user_turn, assistant_turn);
                } else if !steps.is_empty() || !out.visible.trim().is_empty() {
                    // An unfinished task can't be replayed (a tool call may be
                    // unanswered), but the user should still see what happened.
                    session.record(user_turn, assistant_turn);
                }
                let _ = self.store.save(&session.transcript);
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
        access: bool,
        cancel: &AtomicBool,
        steps: &mut Vec<String>,
        emit: Emit,
    ) -> Result<Vec<Value>, ApiError> {
        let host = self.host.lock().unwrap().clone();
        let mut results: Vec<Option<Value>> = vec![None; calls.len()];
        let mut helpers = Vec::new();
        let mut computer_failed = false;
        for (index, call) in calls.iter().enumerate() {
            if cancel.load(Ordering::Relaxed) {
                return Err(ApiError::Cancelled);
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
        *self.job_sink.lock().unwrap() = sink;
    }

    fn job_emit(&self, event: Value) {
        let sink = self.job_sink.lock().unwrap().clone();
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
                            "{name} is on it in the background (task {}). The user sees its pointer and gets its report \
when it's done; you'll be told on their next message. Tell the user in a few words, then carry on.",
                            n - agent::JOB_BASE + 1
                        )),
                        false,
                    ),
                    Err(e) => (json!(e), true),
                }
            }
            "list" => {
                let jobs = self.jobs.lock().unwrap();
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
                if id > 0 && self.stop_job(agent::JOB_BASE + id - 1) {
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
            let mut jobs = self.jobs.lock().unwrap();
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
                let report = engine.run_helper(n, name, &format!("job-{n}"), &task, &settings, &cancel, &tx, true);
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
        if let Some(j) = self.jobs.lock().unwrap().iter_mut().find(|j| j.n == n) {
            if !text.is_empty() {
                j.status = text.clone();
            }
        }
        self.job_emit(json!({"type": "job", "phase": event["phase"], "job": n, "name": event["name"], "text": text, "kind": event["kind"]}));
    }

    /// A background task is over: its report goes to the user and into its
    /// conversation, and the agent hears about it on the next message there.
    fn finish_job(&self, n: usize, report: Result<String, String>) {
        let (name, title, conversation, state, text) = {
            let mut jobs = self.jobs.lock().unwrap();
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
        self.job_emit(json!({"type": "job", "phase": "end", "job": n, "name": name, "title": title, "state": state, "ok": state == "done", "text": text}));
        let turn = Turn {
            role: "assistant".into(),
            text: text.clone(),
            at: now(),
            screens: 0,
            points: Vec::new(),
            steps: vec![format!("{name}: {title}")],
        };
        {
            let mut session = self.session.lock().unwrap();
            if session.transcript.id == conversation {
                session.note(turn);
                let _ = self.store.save(&session.transcript);
            } else if let Some(mut t) = self.store.load(&conversation) {
                t.updated_at = now();
                t.turns.push(turn);
                let _ = self.store.save(&t);
            }
        }
        self.job_notes.lock().unwrap().push((
            conversation,
            format!("[Background task \u{201C}{title}\u{201D} ({name}) {state}. Its report, already shown to the user: {text}]"),
        ));
    }

    fn take_job_notes(&self, conversation: &str) -> Vec<String> {
        let mut notes = self.job_notes.lock().unwrap();
        let (mine, rest): (Vec<_>, Vec<_>) = notes.drain(..).partition(|(c, _)| c == conversation);
        *notes = rest;
        mine.into_iter().map(|(_, n)| n).collect()
    }

    /// Stops a running background task; false when there's none.
    pub fn stop_job(&self, n: usize) -> bool {
        match self.jobs.lock().unwrap().iter().find(|j| j.n == n && j.state == "running") {
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
            messages.push(json!({"role": "assistant", "content": reply.content}));
            match stop.as_str() {
                "tool_use" => {
                    let note = text.trim();
                    if !note.is_empty() {
                        let _ = tx.send(json!({"type": "agent", "phase": "note", "agent": n, "id": call_id, "name": name, "text": agent::clip_words(note, 14)}));
                    }
                    let blocks = messages.last().unwrap()["content"]
                        .as_array()
                        .cloned()
                        .unwrap_or_default();
                    let calls: Vec<Call> = blocks.iter().filter_map(Call::from_block).collect();
                    if calls.is_empty() {
                        return Ok(text.trim().to_string());
                    }
                    let results = self
                        .run_calls(&worker, settings, &calls, true, cancel, &mut steps, &mut emit)
                        .map_err(|e| e.message())?;
                    messages.push(json!({"role": "user", "content": results}));
                }
                "pause_turn" => {}
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
        let mut shell = shell.lock().unwrap();
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
    fn notes_while_working_are_silent_but_the_answer_is_spoken() {
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
        };
        let content = user_content(&req);
        let texts: Vec<_> = content.iter().filter_map(|b| b["text"].as_str()).collect();
        assert!(texts.iter().any(|t| t.starts_with("I drew on my screen")));
        assert_eq!(texts.last(), Some(&"What is this I've marked?"));
    }
}
