//! The agent harness: the tools Claude can use on the user's Mac and the bits
//! that run in Rust (a persistent shell and a file editor). Screen, mouse and
//! keyboard actions are handed to the app through a [`Host`]. Nothing asks
//! for approval: the user consents once, in onboarding or Settings.

use std::ffi::{c_char, c_void, CStr, CString};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use crate::claude::Settings;

/// Whether Claude may work on the Mac. "off" turns the tools off; any other
/// value (older builds saved "ask" or "full") means on.
pub fn mac_access(setting: &str) -> bool {
    !setting.is_empty() && setting != "off"
}

/// Models that take the computer toolset on the Claude API.
const COMPUTER_MODELS: &[&str] = &["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"];
/// Models with the dynamic-filtering web search tool.
const WEB_SEARCH_MODELS: &[&str] = &["claude-opus-5-5", "claude-sonnet-5-5", "claude-opus-5"];

/// Output beyond this is cut from the middle.
const MAX_OUTPUT: usize = 30_000;
const BASH_TIMEOUT: Duration = Duration::from_secs(180);

pub fn tool_definitions(settings: &Settings) -> Vec<Value> {
    if !mac_access(&settings.access) {
        return Vec::new();
    }
    let mut tools = vec![
        json!({"type": "bash_20250124", "name": "bash"}),
        json!({"type": "text_editor_20250728", "name": "str_replace_based_edit_tool", "max_characters": 20000}),
    ];
    if COMPUTER_MODELS.contains(&settings.model.as_str()) {
        tools.push(json!({"type": "computer_toolset_20260801"}));
    }
    if WEB_SEARCH_MODELS.contains(&settings.model.as_str()) {
        tools.push(json!({"type": "web_search_20260209", "name": "web_search", "max_uses": 5}));
    }
    tools.push(app_control_tool());
    tools.push(messages_tool());
    tools
}

/// Our tool for the user's iMessages and texts.
fn messages_tool() -> Value {
    json!({
        "name": "messages",
        "description": "The user's Messages app (iMessage and SMS): list recent conversations, read one, \
    or send a text. Send only what the user asked you to send, to whom they asked, in their words or \
    clearly what they meant; if the recipient is ambiguous, read chats first or ask.",
        "input_schema": {
            "type": "object",
            "properties": {
                "action": {"type": "string", "enum": ["chats", "read", "send"],
                           "description": "chats: recent conversations with their last message. read: the latest messages with someone. send: text someone."},
                "with": {"type": "string", "description": "read: a contact's name, a group chat's name, a number or an address."},
                "to": {"type": "string", "description": "send: a contact's name, an existing chat's name, a number or an address."},
                "text": {"type": "string", "description": "send: the message."},
                "limit": {"type": "integer", "description": "chats or read: how many (default 15 or 20)."}
            },
            "required": ["action"]
        }
    })
}

/// Our own tool for working with apps through their accessibility trees, in
/// the background, by name instead of by pixel.
fn app_control_tool() -> Value {
    json!({
        "name": "app_control",
        "description": "Work with the user's Mac apps directly through macOS Accessibility, in the background: \
    list apps, open them without bringing them to the front, list a window's controls, press buttons, \
    fill in fields, read text and choose menu items by name. Nothing here moves the user's pointer or \
    needs the app in front, and it is more exact than clicking pixels, so prefer it for buttons, \
    fields, checkboxes, lists and menus. Typical flow: elements (optionally with find) to get numbered \
    controls, then press / set_value / read with an id; or skip the listing and name the control with \
    app and find (\"press\", app \"Calculator\", find \"7\"). Ids are only valid until the next elements call. \
    If an app lists nothing useful (games, canvases, some cross-platform apps), use the computer tools.",
        "input_schema": {
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "enum": ["apps", "open", "activate", "elements", "press", "set_value", "read", "menu"],
                    "description": "apps: running apps and their windows. open: launch an app and/or open a file or URL, in the background unless front is true. activate: bring an app to the front. elements: numbered controls and text of an app's window, with positions in screenshot pixels. press: press, focus or select element id. set_value: replace the text or value of element id. read: full text of element id. menu: choose a menu bar item by path."
                },
                "app": {"type": "string", "description": "App name or bundle id. Defaults to the frontmost app for elements and menu."},
                "window": {"type": "string", "description": "elements: part of the window title, when the app has several."},
                "find": {"type": "string", "description": "elements: only list controls whose text or role contains this. press, set_value, read without an id: use the control in app with exactly this text (or else the first containing it)."},
                "limit": {"type": "integer", "description": "elements: how many to list (default 120)."},
                "id": {"type": "integer", "description": "press, set_value, read: the element number from the latest elements listing (or give find instead)."},
                "value": {"type": "string", "description": "set_value: the new text or value."},
                "path": {"type": "array", "items": {"type": "string"}, "description": "menu: titles from the menu bar down, e.g. [\"File\", \"Export as PDF…\"]."},
                "target": {"type": "string", "description": "open: a file path or URL to open (in app, if given)."},
                "front": {"type": "boolean", "description": "open: bring the app to the front (default false)."}
            },
            "required": ["action"]
        }
    })
}

pub fn system_addendum(settings: &Settings, home: &str, today: &str) -> String {
    if !mac_access(&settings.access) {
        return String::new();
    }
    format!(
        "\n\nYou can also work on this Mac yourself, like a capable co-worker sitting at it. \
The user turned this on and consented to it: every tool runs right away, with no approval prompts, \
so act on your own judgement and keep going until the task is done. Tools:\n\
- bash runs commands in a persistent zsh shell as the user, starting in their home folder ({home}). \
Use it for files, system information, git and scripts. AppleScript that controls another app \
(osascript tell application …) makes macOS ask the user for permission the first time, so use \
app_control for apps instead and keep AppleScript for what only it can do.\n\
- str_replace_based_edit_tool views, creates and edits files. Use absolute paths.\n\
- app_control works with apps by name through Accessibility: open apps in the background, list a \
window's controls, press buttons, fill in fields, read text, choose menu items. It is exact and \
never needs the app in front.\n\
- The computer tools, when present, see the screen and act on it: take a screenshot, then click, \
type, press keys and scroll. Coordinates are pixels in your latest screenshot. You have your own \
pointer, shown to the user as a small glass cursor: your clicks, typing and scrolling go straight \
to the app under it, in the background, and never move the user's pointer or take their keyboard. \
Typing and keys go to the app you last clicked in. If a click had no visible effect, click the same \
spot once more: the retry briefly borrows the user's real pointer for apps that ignore background \
clicks. Drags use the real pointer for a moment. End each group of actions with a screenshot (or \
an elements listing) to check the result.\n\
- messages reads the user's Messages conversations and sends texts for them.\n\
- web_search, when present, finds current information.\n\
How to work: do what the user asked, completely, the way they asked. Prefer, in order: app_control \
and the shell (fast, exact, invisible), then the computer tools for what has no other way. Open apps in the background (app_control open, or `open -g`) and only bring one to the front \
when the user should see it or the app needs it. Don't stop to ask unless something is truly \
ambiguous or risky; if a step fails, try another way before giving up.\n\
Nobody reviews your actions before they run, so be careful with what can't be undone: never use sudo, \
and never delete, overwrite, send, post or buy anything the user didn't ask for. Move files to the \
Trash with /usr/bin/trash rather than deleting them with rm.\n\
Say what you're doing as you go, like texting a co-worker: before a step or group of steps, write a \
few words about it (\"Checking your Downloads.\"), each as its own short message. When you're done, \
reply with the result in a sentence or two. Don't add pointing tags for things you click yourself.\n\
Today is {today}."
    )
}

/// The app's half of the agent, called from the request thread and allowed
/// to block. Requests and replies are JSON:
/// `{"type":"computer","name":…,"input":…}` → `{"content":…,"is_error":bool}`.
pub type HostFn = extern "C" fn(ctx: *mut c_void, request_json: *const c_char) -> *mut c_char;

pub struct Host {
    pub f: HostFn,
    pub ctx: *mut c_void,
}

// The app keeps the context alive while it is registered and handles calls
// from any thread.
unsafe impl Send for Host {}
unsafe impl Sync for Host {}

extern "C" {
    fn free(p: *mut c_void);
}

impl Host {
    pub fn call(&self, request: Value) -> Option<Value> {
        let c = CString::new(request.to_string()).ok()?;
        let reply = (self.f)(self.ctx, c.as_ptr());
        if reply.is_null() {
            return None;
        }
        // SAFETY: the app returns a NUL-terminated string from malloc (strdup).
        let parsed = unsafe { CStr::from_ptr(reply) }
            .to_str()
            .ok()
            .and_then(|s| serde_json::from_str(s).ok());
        unsafe { free(reply.cast()) };
        parsed
    }
}

/// A tool call Claude made, as a block from its reply.
pub struct Call<'a> {
    pub id: &'a str,
    pub name: &'a str,
    pub toolset: Option<&'a str>,
    pub input: &'a Value,
}

impl<'a> Call<'a> {
    pub fn from_block(b: &'a Value) -> Option<Self> {
        (b["type"] == "tool_use").then(|| Call {
            id: b["id"].as_str().unwrap_or(""),
            name: b["name"].as_str().unwrap_or(""),
            toolset: b["toolset_name"].as_str(),
            input: &b["input"],
        })
    }

    pub fn is_computer(&self) -> bool {
        self.toolset == Some("computer")
    }

    /// Short past-tense description for the UI and the transcript.
    pub fn summary(&self) -> String {
        let i = self.input;
        if self.is_computer() {
            let text = i["text"].as_str().unwrap_or("");
            return match self.name {
                "screenshot" => "Looked at the screen".into(),
                "zoom" => "Zoomed in on the screen".into(),
                "left_click" | "right_click" | "middle_click" => "Clicked".into(),
                "double_click" => "Double-clicked".into(),
                "triple_click" => "Triple-clicked".into(),
                "left_click_drag" => "Dragged".into(),
                "mouse_move" => "Moved the pointer".into(),
                "scroll" => "Scrolled".into(),
                "type" => format!("Typed \u{201C}{}\u{201D}", clip(text, 40)),
                "key" | "hold_key" => format!("Pressed {}", clip(text, 30)),
                "wait" => "Waited".into(),
                other => other.replace('_', " "),
            };
        }
        match self.name {
            "bash" if i["restart"] == true => "Restarted the shell".into(),
            "bash" => format!(
                "Ran {}",
                clip(first_line(i["command"].as_str().unwrap_or("")), 70)
            ),
            "str_replace_based_edit_tool" => {
                let path = short_path(i["path"].as_str().unwrap_or(""));
                match i["command"].as_str().unwrap_or("") {
                    "view" => format!("Read {path}"),
                    "create" => format!("Wrote {path}"),
                    _ => format!("Edited {path}"),
                }
            }
            "app_control" => {
                let app = i["app"].as_str().unwrap_or("");
                let in_app = if app.is_empty() {
                    String::new()
                } else {
                    format!(" in {app}")
                };
                match i["action"].as_str().unwrap_or("") {
                    "apps" => "Checked the open apps".into(),
                    "open" => format!(
                        "Opened {}",
                        if app.is_empty() {
                            short_path(i["target"].as_str().unwrap_or("it"))
                        } else {
                            app.to_string()
                        }
                    ),
                    "activate" => format!("Brought {app} to the front"),
                    "elements" => format!("Looked{in_app}"),
                    "press" => format!("Pressed a control{in_app}"),
                    "set_value" => format!("Filled in a field{in_app}"),
                    "read" => format!("Read text{in_app}"),
                    "menu" => {
                        let path: Vec<&str> = i["path"]
                            .as_array()
                            .map(|a| a.iter().filter_map(Value::as_str).collect())
                            .unwrap_or_default();
                        format!("Chose {}", path.join(" \u{203A} "))
                    }
                    other => format!("Used {other}{in_app}"),
                }
            }
            "memory" => {
                let text = clip(i["text"].as_str().unwrap_or(""), 60);
                match i["action"].as_str().unwrap_or("") {
                    "remember" => format!("Remembered \u{201C}{text}\u{201D}"),
                    _ if text.is_empty() => "Forgot something".into(),
                    _ => format!("Forgot \u{201C}{text}\u{201D}"),
                }
            }
            "messages" => match i["action"].as_str().unwrap_or("") {
                "send" => format!("Texted {}", i["to"].as_str().unwrap_or("someone")),
                "read" => format!(
                    "Read messages with {}",
                    i["with"].as_str().unwrap_or("someone")
                ),
                _ => "Checked your messages".into(),
            },
            other => other.replace('_', " "),
        }
    }

    pub fn kind(&self) -> &'static str {
        if self.is_computer() {
            "computer"
        } else if self.name == "bash" {
            "shell"
        } else if self.name == "app_control" {
            "app"
        } else if self.name == "memory" {
            "memory"
        } else if self.name == "messages" {
            "messages"
        } else {
            "file"
        }
    }
}

// MARK: - Shell

/// One long-lived zsh, so `cd`, variables and activated environments carry
/// over between commands like in a terminal.
pub struct Shell {
    child: Child,
    stdin: ChildStdin,
    lines: Receiver<String>,
}

impl Shell {
    pub fn spawn(home: &Path) -> std::io::Result<Self> {
        use std::os::unix::process::CommandExt;
        let mut child = Command::new("/bin/zsh")
            .arg("-l")
            .current_dir(home)
            .env("TERM", "dumb")
            .env("PAGER", "cat")
            .env("GIT_PAGER", "cat")
            .env("NO_COLOR", "1")
            .env("HOMEBREW_NO_AUTO_UPDATE", "1")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .process_group(0)
            .spawn()?;
        let mut stdin = child.stdin.take().expect("piped stdin");
        let stdout = child.stdout.take().expect("piped stdout");
        let (tx, lines) = mpsc::channel();
        std::thread::Builder::new()
            .name("cursor-pilot-shell".into())
            .spawn(move || {
                for line in BufReader::new(stdout).lines() {
                    let Ok(line) = line else { break };
                    if tx.send(line).is_err() {
                        break;
                    }
                }
            })?;
        writeln!(stdin, "exec 2>&1")?;
        Ok(Self {
            child,
            stdin,
            lines,
        })
    }

    /// Runs `command`, returning its combined output and exit status.
    /// Returns `Err` with a message on timeout or cancel; the shell is then
    /// dead and must be replaced.
    pub fn run(&mut self, command: &str, cancel: &AtomicBool) -> Result<(String, i32), String> {
        let marker = format!("__CP_END_{}__", uuid::Uuid::new_v4().simple());
        // Commands never read our script as their input.
        let script = format!("{{\n{command}\n}} < /dev/null\nprintf '\\n{marker}%s\\n' \"$?\"\n");
        self.stdin
            .write_all(script.as_bytes())
            .and_then(|_| self.stdin.flush())
            .map_err(|e| format!("The shell stopped: {e}"))?;
        let deadline = Instant::now() + BASH_TIMEOUT;
        let mut out: Vec<String> = Vec::new();
        loop {
            if cancel.load(Ordering::Relaxed) {
                self.kill();
                return Err("Cancelled.".into());
            }
            if Instant::now() > deadline {
                self.kill();
                return Err(format!(
                    "Timed out after {} seconds; the shell was restarted. Run long jobs in the background (cmd > /tmp/log 2>&1 &).",
                    BASH_TIMEOUT.as_secs()
                ));
            }
            match self.lines.recv_timeout(Duration::from_millis(100)) {
                Ok(line) => {
                    if let Some(code) = line.strip_prefix(&marker) {
                        if out.last().is_some_and(|l| l.is_empty()) {
                            out.pop(); // the newline printf added
                        }
                        return Ok((cap(&out.join("\n")), code.trim().parse().unwrap_or(-1)));
                    }
                    out.push(line);
                }
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => {
                    return Err(
                        "The shell exited (did a command run `exit`?). It will restart.".into(),
                    )
                }
            }
        }
    }

    pub fn kill(&mut self) {
        let pgid = self.child.id();
        let _ = Command::new("/bin/kill")
            .args(["-9", &format!("-{pgid}")])
            .status();
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Drop for Shell {
    fn drop(&mut self) {
        self.kill();
    }
}

// MARK: - Files

pub struct Editor {
    pub home: PathBuf,
    pub backups: PathBuf,
}

impl Editor {
    fn resolve(&self, raw: &str) -> Result<PathBuf, String> {
        let raw = raw.trim();
        if raw.is_empty() {
            return Err("No path given.".into());
        }
        let p = if let Some(rest) = raw.strip_prefix("~/") {
            self.home.join(rest)
        } else if raw == "~" {
            self.home.clone()
        } else {
            PathBuf::from(raw)
        };
        Ok(if p.is_absolute() {
            p
        } else {
            self.home.join(p)
        })
    }

    pub fn run(&self, input: &Value) -> Result<String, String> {
        let path = self.resolve(input["path"].as_str().unwrap_or(""))?;
        match input["command"].as_str().unwrap_or("") {
            "view" => self.view(&path, &input["view_range"]),
            "create" => {
                let text = input["file_text"].as_str().unwrap_or("");
                self.backup(&path)?;
                if let Some(parent) = path.parent() {
                    std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
                }
                std::fs::write(&path, text).map_err(|e| e.to_string())?;
                Ok(format!("Wrote {} ({} bytes).", path.display(), text.len()))
            }
            "str_replace" => {
                let old = input["old_str"].as_str().unwrap_or("");
                let new = input["new_str"].as_str().unwrap_or("");
                if old.is_empty() {
                    return Err("old_str is empty.".into());
                }
                let text = std::fs::read_to_string(&path)
                    .map_err(|e| format!("{}: {e}", path.display()))?;
                match text.matches(old).count() {
                    0 => Err(format!("No match for old_str in {}.", path.display())),
                    1 => {
                        self.backup(&path)?;
                        std::fs::write(&path, text.replacen(old, new, 1)).map_err(|e| e.to_string())?;
                        Ok(format!("Edited {}.", path.display()))
                    }
                    n => Err(format!("old_str matches {n} places in {}; include more context so it matches once.", path.display())),
                }
            }
            "insert" => {
                let line = input["insert_line"].as_u64().unwrap_or(0) as usize;
                let text = std::fs::read_to_string(&path)
                    .map_err(|e| format!("{}: {e}", path.display()))?;
                let mut lines: Vec<&str> = text.split('\n').collect();
                if line > lines.len() {
                    return Err(format!(
                        "insert_line {line} is past the end ({} lines).",
                        lines.len()
                    ));
                }
                let insert = insert_text(input);
                lines.insert(line, insert);
                self.backup(&path)?;
                std::fs::write(&path, lines.join("\n")).map_err(|e| e.to_string())?;
                Ok(format!("Inserted after line {line} of {}.", path.display()))
            }
            other => Err(format!("Unknown editor command: {other}")),
        }
    }

    fn view(&self, path: &Path, range: &Value) -> Result<String, String> {
        if path.is_dir() {
            let mut out = Vec::new();
            list_dir(path, 0, &mut out);
            if out.is_empty() {
                return Ok(format!("{} is empty.", path.display()));
            }
            return Ok(format!("{}:\n{}", path.display(), out.join("\n")));
        }
        let bytes = std::fs::read(path).map_err(|e| format!("{}: {e}", path.display()))?;
        if bytes.iter().take(8000).any(|&b| b == 0) {
            return Ok(format!(
                "{} is a binary file ({} bytes).",
                path.display(),
                bytes.len()
            ));
        }
        let text = String::from_utf8_lossy(&bytes);
        let lines: Vec<&str> = text.lines().collect();
        let (start, end) = match range.as_array() {
            Some(r) if r.len() == 2 => {
                let s = r[0].as_i64().unwrap_or(1).max(1) as usize;
                let e = r[1].as_i64().unwrap_or(-1);
                (
                    s,
                    if e < 0 {
                        lines.len()
                    } else {
                        (e as usize).min(lines.len())
                    },
                )
            }
            _ => (1, lines.len()),
        };
        let numbered: Vec<String> = lines
            .iter()
            .enumerate()
            .skip(start.saturating_sub(1))
            .take(end.saturating_sub(start.saturating_sub(1)))
            .map(|(i, l)| format!("{:6}\t{l}", i + 1))
            .collect();
        Ok(cap(&numbered.join("\n")))
    }

    /// Keeps the previous version of a file the agent is about to change.
    fn backup(&self, path: &Path) -> Result<(), String> {
        if !path.is_file() {
            return Ok(());
        }
        std::fs::create_dir_all(&self.backups).map_err(|e| e.to_string())?;
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_default();
        let tag = &uuid::Uuid::new_v4().simple().to_string()[..8];
        let dest = self
            .backups
            .join(format!("{}-{tag}-{name}", crate::conversation::now()));
        std::fs::copy(path, dest)
            .map(|_| ())
            .map_err(|e| format!("Couldn't back up {}: {e}", path.display()))
    }
}

fn list_dir(dir: &Path, depth: usize, out: &mut Vec<String>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    let mut entries: Vec<_> = entries.flatten().collect();
    entries.sort_by_key(|e| e.file_name());
    for e in entries {
        if out.len() >= 300 {
            return;
        }
        let name = e.file_name().to_string_lossy().to_string();
        if name.starts_with('.') {
            continue;
        }
        let is_dir = e.path().is_dir();
        out.push(format!(
            "{}{}{}",
            "  ".repeat(depth),
            name,
            if is_dir { "/" } else { "" }
        ));
        if is_dir && depth < 1 {
            list_dir(&e.path(), depth + 1, out);
        }
    }
}

fn insert_text(input: &Value) -> &str {
    input["insert_text"]
        .as_str()
        .or(input["new_str"].as_str())
        .unwrap_or("")
}

// MARK: - Text helpers

pub fn cap(s: &str) -> String {
    if s.len() <= MAX_OUTPUT {
        return s.to_string();
    }
    let head: String = s.chars().take(MAX_OUTPUT / 2).collect();
    let tail: String = s
        .chars()
        .rev()
        .take(MAX_OUTPUT / 2)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect();
    format!(
        "{head}\n\n[… {} characters cut …]\n\n{tail}",
        s.len() - MAX_OUTPUT
    )
}

fn clip(s: &str, n: usize) -> String {
    let s = s.trim();
    if s.chars().count() <= n {
        s.to_string()
    } else {
        format!("{}…", s.chars().take(n).collect::<String>())
    }
}

fn first_line(s: &str) -> &str {
    s.trim().lines().next().unwrap_or("")
}

fn short_path(p: &str) -> String {
    match std::env::var("HOME") {
        Ok(home) if !home.is_empty() && p.starts_with(&home) => format!("~{}", &p[home.len()..]),
        _ => p.to_string(),
    }
}

/// `YYYY-MM-DD` for a Unix time, in UTC.
pub fn date_string(secs: u64) -> String {
    let days = (secs / 86_400) as i64;
    // Howard Hinnant's civil-from-days.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + if m <= 2 { 1 } else { 0 };
    format!("{y:04}-{m:02}-{d:02}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn access_setting() {
        assert!(!mac_access("off"));
        assert!(!mac_access(""));
        assert!(mac_access("on"));
        assert!(mac_access("ask"));
        assert!(mac_access("full"));
    }

    #[test]
    fn shell_keeps_state_between_commands() {
        let home = std::env::temp_dir();
        let mut sh = Shell::spawn(&home).unwrap();
        let cancel = AtomicBool::new(false);
        sh.run("cd /tmp && FOO=bar", &cancel).unwrap();
        let (out, code) = sh.run("pwd; echo $FOO; ls /nonexistent", &cancel).unwrap();
        assert!(
            out.contains("/tmp") || out.contains("/private/tmp"),
            "{out}"
        );
        assert!(out.contains("bar"), "{out}");
        assert!(out.contains("No such file"), "stderr is merged: {out}");
        assert_ne!(code, 0);
        let (out, _) = sh.run("printf 'no newline'", &cancel).unwrap();
        assert_eq!(out, "no newline");
    }

    #[test]
    fn editor_views_edits_and_backs_up() {
        let dir = std::env::temp_dir().join(format!("cp-ed-{}", uuid::Uuid::new_v4()));
        let ed = Editor {
            home: dir.clone(),
            backups: dir.join("backups"),
        };
        let file = dir.join("a.txt");
        let p = file.to_str().unwrap();
        ed.run(&json!({"command": "create", "path": p, "file_text": "one\ntwo\nthree"}))
            .unwrap();
        assert!(ed
            .run(&json!({"command": "view", "path": p}))
            .unwrap()
            .contains("     2\ttwo"));
        ed.run(&json!({"command": "str_replace", "path": p, "old_str": "two", "new_str": "2"}))
            .unwrap();
        assert!(ed
            .run(&json!({"command": "str_replace", "path": p, "old_str": "zzz", "new_str": ""}))
            .is_err());
        ed.run(&json!({"command": "insert", "path": p, "insert_line": 0, "insert_text": "zero"}))
            .unwrap();
        assert_eq!(
            std::fs::read_to_string(&file).unwrap(),
            "zero\none\n2\nthree"
        );
        assert!(std::fs::read_dir(dir.join("backups")).unwrap().count() >= 2);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn formats_dates() {
        assert_eq!(date_string(0), "1970-01-01");
        assert_eq!(date_string(1_793_870_000), "2026-11-05");
    }
}
