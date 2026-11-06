//! Turns one user request (voice transcript or typed text plus screenshots)
//! into a streamed, spoken, pointing reply, using whichever backend is set.

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use serde::Deserialize;
use serde_json::{json, Value};

use crate::agent::{self, Call, Editor, Host, Shell};
use crate::claude::{self, ApiError, Settings};
use crate::conversation::{now, Session, Store, Turn};
use crate::drawings::Drawings;
use crate::markup::{MarkupFilter, Piece, Shape};
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
Drawings appear as your voice reaches them and stay pinned to what they mark. Labels are two to \
four words. Use several tags in order to walk through steps, but no more than a handful per reply. Never read coordinates aloud or describe the tags, and only mark things you \
can actually see. Without screenshots, do not use tags.

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
const MAX_ROUNDS: usize = 60;

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
}

pub type Emit<'a> = &'a mut dyn FnMut(Value);

impl Engine {
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
        let system = format!(
            "{SYSTEM_PROMPT}{}{}",
            self.memory.prompt(),
            agent::system_addendum(
                &settings,
                &self.home.display().to_string(),
                &agent::date_string(now())
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
        messages.push(json!({"role": "user", "content": user_content(req)}));
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
                out.end_segment(&mut *emit);
                for b in reply
                    .content
                    .iter()
                    .filter(|b| b["type"] == "server_tool_use")
                {
                    let q = b["input"]["query"].as_str().unwrap_or("");
                    let summary = if q.is_empty() {
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
                        let results =
                            self.run_calls(&calls, access, cancel, &mut steps, &mut *emit)?;
                        messages.push(json!({"role": "user", "content": results}));
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

    /// Runs one round of tool calls in order, without asking: the user
    /// consented once. Returns one `tool_result` per call.
    fn run_calls(
        &self,
        calls: &[Call],
        access: bool,
        cancel: &AtomicBool,
        steps: &mut Vec<String>,
        emit: Emit,
    ) -> Result<Vec<Value>, ApiError> {
        let host = self.host.lock().unwrap().clone();
        let mut results = Vec::new();
        let mut computer_failed = false;
        for call in calls {
            if cancel.load(Ordering::Relaxed) {
                return Err(ApiError::Cancelled);
            }
            let summary = call.summary();
            let kind = call.kind();
            if call.is_computer() && computer_failed {
                results.push(tool_result(
                    call,
                    json!("Not executed: an earlier computer action in this turn failed."),
                    true,
                ));
                continue;
            }
            if !access && call.name != "memory" {
                results.push(tool_result(
                    call,
                    json!("Mac access is off in Cursor Pilot's settings."),
                    true,
                ));
                continue;
            }

            emit(
                json!({"type": "tool", "phase": "start", "id": call.id, "kind": kind, "summary": summary}),
            );
            // The app may name what it did more precisely ("Clicked the
            // \u{201C}Save\u{201D} button"); that becomes the step's label.
            let mut label = summary.clone();
            let mut from_host = |request: Value| match host.as_ref().and_then(|h| h.call(request)) {
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
            };
            let (content, is_error) = match (call.is_computer(), call.name) {
                (true, _) => {
                    from_host(json!({"type": "computer", "name": call.name, "input": call.input}))
                }
                (false, "app_control") => from_host(json!({"type": "apps", "input": call.input})),
                (false, "messages") => from_host(json!({"type": "messages", "input": call.input})),
                (false, "memory") => self.memory.run(call.input, &agent::date_string(now())),
                (false, "bash") => self.run_bash(call.input, cancel),
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
                json!({"type": "tool", "phase": "end", "id": call.id, "kind": kind, "summary": summary, "ok": !is_error}),
            );
            if steps.last() != Some(&summary) {
                steps.push(summary);
            }
            results.push(tool_result(call, content, is_error));
        }
        Ok(results)
    }

    fn run_bash(&self, input: &Value, cancel: &AtomicBool) -> (Value, bool) {
        let mut shell = self.shell.lock().unwrap();
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
            emit(json!({"type": "speak", "text": s}));
        }
    }

    /// Ends one reply of an agent task: flushes what's pending and starts a
    /// new paragraph, so text from the next round doesn't run on.
    fn end_segment(&mut self, emit: Emit) {
        self.finish(&mut *emit);
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
                        emit(json!({"type": "speak", "text": s}));
                    }
                }
                Piece::Mark(m) => {
                    let Some(&(frame, iw, ih)) = self.screens.get(m.screen) else {
                        continue;
                    };
                    if iw <= 0.0 || ih <= 0.0 {
                        continue;
                    }
                    // Screenshot pixels → global top-left-origin points.
                    let (sx, sy) = (frame.w / iw, frame.h / ih);
                    let gx = |x: f64| frame.x + x.clamp(0.0, iw) * sx;
                    let gy = |y: f64| frame.y + y.clamp(0.0, ih) * sy;
                    let mut event = match m.shape {
                        Shape::Point { x, y } => json!({"type": "point", "x": gx(x), "y": gy(y)}),
                        Shape::Circle { x, y, r } => {
                            json!({"type": "mark", "shape": "circle", "x": gx(x), "y": gy(y), "r": r * sx})
                        }
                        Shape::Arrow { x1, y1, x2, y2 } => json!({
                            "type": "mark", "shape": "arrow",
                            "x1": gx(x1), "y1": gy(y1), "x2": gx(x2), "y2": gy(y2),
                        }),
                        Shape::Box { x, y, w, h } => json!({
                            "type": "mark", "shape": "box",
                            "x": gx(x), "y": gy(y),
                            "w": (x.clamp(0.0, iw) + w).min(iw) * sx - x.clamp(0.0, iw) * sx,
                            "h": (y.clamp(0.0, ih) + h).min(ih) * sy - y.clamp(0.0, ih) * sy,
                        }),
                        Shape::Underline { x, y, w } => json!({
                            "type": "mark", "shape": "underline",
                            "x": gx(x), "y": gy(y), "w": gx(x + w) - gx(x),
                        }),
                        Shape::Highlight { x, y, w, h } => json!({
                            "type": "mark", "shape": "highlight",
                            "x": gx(x), "y": gy(y), "w": gx(x + w) - gx(x), "h": gy(y + h) - gy(y),
                        }),
                        Shape::Trace { points } => json!({
                            "type": "mark", "shape": "trace",
                            "points": points.iter().map(|&(x, y)| json!([gx(x), gy(y)])).collect::<Vec<_>>(),
                        }),
                        Shape::Note { x, y, text } => json!({
                            "type": "mark", "shape": "note", "x": gx(x), "y": gy(y), "text": text,
                        }),
                    };
                    event["screen"] = json!(m.screen);
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
            .any(|e| e["type"] == "speak" && e["text"] == "Click  here."));
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
