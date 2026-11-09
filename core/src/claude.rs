//! Minimal streaming client for the Claude Messages API.
//!
//! Rust has no official Anthropic SDK, so this speaks the documented raw HTTP
//! and server-sent-events protocol directly. Assistant content blocks (thinking
//! blocks included) are rebuilt from the stream exactly as received so the
//! conversation can be replayed append-only on the next turn.

use std::io::{BufRead, BufReader};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};

const API_VERSION: &str = "2026-10-21";
/// The version other hosts that speak the Messages API document.
const COMPAT_API_VERSION: &str = "2023-06-01";
/// abliteration.ai models that can't take images.
const TEXT_ONLY_MODELS: &[&str] = &["abliterated-model-large-v2", "abliterated-model-large"];
const FALLBACK_BETA: &str = "server-side-fallback-2026-07-01";
/// Models that accept `fallbacks: "default"` on the Claude API.
const FALLBACK_MODELS: &[&str] = &[
    "claude-fable-5-1",
    "claude-opus-5-5",
    "claude-opus-5",
    "claude-sonnet-5-5",
];
/// A request that fails in a passing way (rate limit, overload, server error,
/// dropped or refused connection) is sent again this many times.
pub(crate) const MAX_RETRIES: u32 = 3;
/// An attempt that had been silent this long when it failed (a connection
/// that timed out, a reply that stalled) is not retried: the user has
/// waited long enough to be told.
const SILENT_LIMIT: Duration = Duration::from_secs(10);
/// A pooled connection is used again only this soon after the last request.
/// One that sat idle longer may be dead without the system knowing (the Mac
/// slept or changed network), and a request on it would hang, so a fresh
/// one is opened instead.
const POOL_IDLE: Duration = Duration::from_secs(30);
/// The wait before the first retry; it doubles each time. (Tests don't
/// wait that long.)
const RETRY_BASE: Duration = Duration::from_millis(if cfg!(test) { 15 } else { 500 });
/// The longest wait the API may ask for (`retry-after`) that is still worth
/// sitting through; beyond it the error goes to the user at once.
const MAX_RETRY_AFTER: Duration = Duration::from_secs(20);
/// How often a waiting request looks at its cancel flag.
const CANCEL_POLL: Duration = Duration::from_millis(100);

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub api_key: String,
    pub model: String,
    pub effort: String,
    pub base_url: String,
    pub max_tokens: u32,
    /// Mac access: "off" or "on" (see `agent::mac_access`).
    pub access: String,
    /// How the main agent works on the Mac: "person" (the user's own mouse
    /// and keyboard) or "background" (its own pointer).
    #[serde(default)]
    pub input: String,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            api_key: String::new(),
            model: "claude-opus-5-5".into(),
            // Replies are spoken aloud, so default to the snappiest effort.
            effort: "low".into(),
            base_url: "https://api.anthropic.com".into(),
            max_tokens: 16_000,
            access: "off".into(),
            input: "person".into(),
        }
    }
}

#[derive(Debug)]
pub enum ApiError {
    MissingKey,
    Cancelled,
    Refusal(Option<String>),
    Http { status: u16, message: String },
    Network(String),
    Protocol(String),
}

impl ApiError {
    pub fn kind(&self) -> &'static str {
        match self {
            ApiError::MissingKey => "missing_key",
            ApiError::Cancelled => "cancelled",
            ApiError::Refusal(_) => "refusal",
            ApiError::Http { status: 401, .. } | ApiError::Http { status: 403, .. } => "auth",
            ApiError::Http { status: 429, .. } => "rate_limited",
            ApiError::Http { status: 529, .. } => "overloaded",
            ApiError::Http { .. } => "http",
            ApiError::Network(_) => "network",
            ApiError::Protocol(_) => "protocol",
        }
    }

    /// Whether sending the same request again may well work: rate limits,
    /// overload, server errors, and anything that went wrong on the wire.
    pub fn is_transient(&self) -> bool {
        match self {
            ApiError::Http { status, .. } => matches!(status, 408 | 409 | 429) || *status >= 500,
            ApiError::Network(_) | ApiError::Protocol(_) => true,
            _ => false,
        }
    }

    pub fn message(&self) -> String {
        match self {
            ApiError::MissingKey => "Add your API key in Settings.".into(),
            ApiError::Cancelled => "Cancelled.".into(),
            ApiError::Refusal(Some(c)) => format!("Claude declined to answer ({c})."),
            ApiError::Refusal(None) => "Claude declined to answer.".into(),
            ApiError::Http { status, message } => format!("API error {status}: {message}"),
            ApiError::Network(m) => format!("Network error: {m}"),
            ApiError::Protocol(m) => format!("Unexpected response: {m}"),
        }
    }
}

/// What the stream reports while it runs.
pub enum StreamEvent<'a> {
    TextDelta(&'a str),
    /// The reply broke off after some of its text had been passed on and is
    /// being asked for again: that text will come again, from the start.
    Restart,
}

pub struct Completion {
    /// Assistant content blocks, ready to append to the history.
    pub content: Vec<Value>,
    pub stop_reason: Option<String>,
    pub usage: Value,
    pub model: Option<String>,
    /// Ids of tool calls whose input didn't arrive as a JSON object (cut off
    /// or malformed). Their `input` is `{}`; they must not be run.
    pub invalid_inputs: Vec<String>,
}

impl Settings {
    /// Whether requests go to Anthropic's own API (rather than another host
    /// that speaks the Messages API, such as abliteration.ai).
    pub fn is_anthropic(&self) -> bool {
        self.base_url.contains("anthropic.com")
    }
}

/// Replaces image blocks (also inside tool results) with a short note, for
/// models that reject images.
fn without_images(value: &Value) -> Value {
    match value {
        Value::Array(items) => Value::Array(items.iter().map(without_images).collect()),
        Value::Object(map) if map.get("type").and_then(Value::as_str) == Some("image") => {
            json!({"type": "text", "text": "[A screenshot was here; this model can't see images.]"})
        }
        Value::Object(map) => Value::Object(map.iter().map(|(k, v)| (k.clone(), without_images(v))).collect()),
        other => other.clone(),
    }
}

pub fn build_body(settings: &Settings, system: &str, messages: &[Value], tools: &[Value]) -> Value {
    let messages: Vec<Value> = if TEXT_ONLY_MODELS.contains(&settings.model.as_str()) {
        messages.iter().map(without_images).collect()
    } else {
        messages.to_vec()
    };
    let mut body = json!({
        "model": settings.model,
        "max_tokens": settings.max_tokens,
        "stream": true,
        "system": [{"type": "text", "text": system}],
        // Automatic prompt caching: the history prefix is reused turn to turn.
        "cache_control": {"type": "ephemeral"},
    });
    // Moved in, not copied again: the history holds screenshots.
    body["messages"] = Value::Array(messages);
    if !tools.is_empty() {
        body["tools"] = Value::Array(tools.to_vec());
    }
    if !settings.effort.is_empty() {
        body["output_config"] = json!({"effort": settings.effort});
    }
    if FALLBACK_MODELS.contains(&settings.model.as_str()) {
        body["fallbacks"] = json!("default");
    }
    body
}

/// One connection pool for the whole app, so a request (and every round of an
/// agent task) reuses a warm TLS connection instead of shaking hands again.
/// A connection only goes back to the pool once its response has been read
/// to the end, so every reader here does that.
fn http() -> ureq::Agent {
    let mut pool = crate::lock(&POOL);
    let now = Instant::now();
    match pool.as_mut() {
        Some((agent, used)) if now.duration_since(*used) < POOL_IDLE => {
            *used = now;
            agent.clone()
        }
        _ => {
            let agent = ureq::AgentBuilder::new()
                .timeout_connect(Duration::from_secs(15))
                .timeout_read(Duration::from_secs(180))
                .max_idle_connections_per_host(4)
                .build();
            *pool = Some((agent.clone(), now));
            agent
        }
    }
}

/// The pool, and when a request last started or finished on it.
static POOL: Mutex<Option<(ureq::Agent, Instant)>> = Mutex::new(None);

/// A request just finished and its connection went back to the pool.
fn pool_used() {
    if let Some((_, used)) = crate::lock(&POOL).as_mut() {
        *used = Instant::now();
    }
}

/// Opens a connection to the API ahead of the first request (the user just
/// pressed the talk key), so it is ready by the time they finish speaking.
pub fn warm(base_url: &str) {
    let url = base_url.trim_end_matches('/').to_string();
    std::thread::spawn(move || {
        // Whatever the answer is, read it to the end: that is what puts the
        // connection in the pool for the request that follows.
        match http().get(&url).timeout(Duration::from_secs(5)).call() {
            Ok(r) | Err(ureq::Error::Status(_, r)) => {
                let _ = r.into_string();
            }
            Err(_) => {}
        }
    });
}

/// Why one attempt at a request failed, and what the server said about
/// trying again.
struct Failure {
    error: ApiError,
    /// The wait the server asked for (`retry-after`).
    retry_after: Option<Duration>,
    /// The server said not to try again (`x-should-retry: false`).
    no_retry: bool,
}

impl From<ApiError> for Failure {
    fn from(error: ApiError) -> Self {
        Failure { error, retry_after: None, no_retry: false }
    }
}

/// What the thread reading the response passes to the request's thread.
enum Wire {
    Line(String),
    Failed(Failure),
}

/// Streams one reply. A failure that is likely to pass (see
/// `ApiError::is_transient`) is retried with a growing wait; if text had
/// already been passed on, `StreamEvent::Restart` says it will come again.
/// Cancelling stops it within `CANCEL_POLL`, also while it connects, waits
/// for the first byte or sits out a retry.
pub fn stream(
    settings: &Settings,
    body: &Value,
    cancel: &AtomicBool,
    mut on_event: impl FnMut(StreamEvent),
) -> Result<Completion, ApiError> {
    if settings.api_key.trim().is_empty() {
        return Err(ApiError::MissingKey);
    }
    let fallbacks = body.get("fallbacks").is_some();
    let body = Arc::new(body.to_string());
    let mut attempt = 0;
    loop {
        let mut passed_on = false;
        // When the attempt last heard from the server.
        let mut alive = Instant::now();
        let failure = match stream_once(settings, &body, fallbacks, cancel, &mut alive, &mut |event| {
            passed_on = true;
            on_event(event);
        }) {
            Ok(done) => return Ok(done),
            Err(f) => f,
        };
        if attempt >= MAX_RETRIES
            || failure.no_retry
            || !failure.error.is_transient()
            || alive.elapsed() > SILENT_LIMIT
        {
            return Err(failure.error);
        }
        let Some(wait) = retry_delay(attempt, failure.retry_after) else {
            return Err(failure.error);
        };
        if !sleep_unless_cancelled(wait, cancel) {
            return Err(ApiError::Cancelled);
        }
        if passed_on {
            on_event(StreamEvent::Restart);
        }
        attempt += 1;
    }
}

/// How long to wait before retry number `attempt` (from 0): what the server
/// asked for, or 0.5 s doubling each time with a little jitter. `None` when
/// the server asks for a longer wait than is worth it.
fn retry_delay(attempt: u32, retry_after: Option<Duration>) -> Option<Duration> {
    if let Some(asked) = retry_after {
        return (asked <= MAX_RETRY_AFTER).then(|| asked.max(Duration::from_millis(100)));
    }
    let base = RETRY_BASE * 2u32.pow(attempt.min(4));
    let nanos = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    Some(base + base.mul_f64(f64::from(nanos % 1000) / 4000.0))
}

/// Sleeps for `wait`; false if the request was cancelled meanwhile.
fn sleep_unless_cancelled(wait: Duration, cancel: &AtomicBool) -> bool {
    let until = Instant::now() + wait;
    loop {
        if cancel.load(Ordering::Relaxed) {
            return false;
        }
        let left = until.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return true;
        }
        std::thread::sleep(left.min(Duration::from_millis(50)));
    }
}

/// `retry-after-ms` or `retry-after` (seconds) of a response, when given
/// as a number.
fn retry_after(resp: &ureq::Response) -> Option<Duration> {
    let secs = |name: &str, scale: f64| {
        resp.header(name)
            .and_then(|v| v.trim().parse::<f64>().ok())
            .filter(|v| v.is_finite() && *v >= 0.0)
            .map(|v| Duration::from_secs_f64((v * scale).min(86_400.0)))
    };
    secs("retry-after-ms", 0.001).or_else(|| secs("retry-after", 1.0))
}

/// Sets its flag when dropped, unless told the response was read to the end.
struct Abandon {
    flag: Arc<AtomicBool>,
    finished: bool,
}

impl Drop for Abandon {
    fn drop(&mut self) {
        if !self.finished {
            self.flag.store(true, Ordering::Relaxed);
        }
    }
}

/// One attempt. The request is sent and its response read on a thread of
/// its own, so this one never sits in a blocking read and can stop the
/// moment it is cancelled.
fn stream_once(
    settings: &Settings,
    body: &Arc<String>,
    fallbacks: bool,
    cancel: &AtomicBool,
    alive: &mut Instant,
    on_event: &mut dyn FnMut(StreamEvent),
) -> Result<Completion, Failure> {
    let url = format!("{}/v1/messages", settings.base_url.trim_end_matches('/'));
    let key = settings.api_key.trim().to_string();
    let version = if settings.is_anthropic() { API_VERSION } else { COMPAT_API_VERSION };
    let (tx, rx) = mpsc::channel::<Wire>();
    let abandoned = Arc::new(AtomicBool::new(false));
    let mut abandon = Abandon { flag: abandoned.clone(), finished: false };
    let body = body.clone();
    std::thread::Builder::new()
        .name("cursor-pilot-stream".into())
        .spawn(move || {
            let mut req = http()
                .post(&url)
                .set("content-type", "application/json")
                .set("x-api-key", &key)
                .set("anthropic-version", version);
            if fallbacks {
                req = req.set("anthropic-beta", FALLBACK_BETA);
            }
            let resp = match req.send_string(&body) {
                Ok(r) => r,
                Err(ureq::Error::Status(status, r)) => {
                    let retry_after = retry_after(&r);
                    let no_retry = r.header("x-should-retry").is_some_and(|v| v.trim() == "false");
                    let text = r.into_string().unwrap_or_default();
                    let message = serde_json::from_str::<Value>(&text)
                        .ok()
                        .and_then(|v| v["error"]["message"].as_str().map(str::to_string))
                        .unwrap_or(text);
                    let error = ApiError::Http { status, message };
                    let _ = tx.send(Wire::Failed(Failure { error, retry_after, no_retry }));
                    return;
                }
                Err(e) => {
                    let _ = tx.send(Wire::Failed(ApiError::Network(e.to_string()).into()));
                    return;
                }
            };
            // Read to the end even when nobody listens any more (the reply
            // is complete after `message_stop`): reaching the end is what
            // returns the connection to the pool. An abandoned request's
            // connection is closed instead.
            for line in BufReader::new(resp.into_reader()).lines() {
                if abandoned.load(Ordering::Relaxed) {
                    return;
                }
                match line {
                    Ok(line) => {
                        let _ = tx.send(Wire::Line(line));
                    }
                    Err(e) => {
                        let _ = tx.send(Wire::Failed(ApiError::Network(e.to_string()).into()));
                        return;
                    }
                }
            }
        })
        .map_err(|e| ApiError::Network(format!("couldn't start the request: {e}")))?;

    let mut acc = Accumulator::default();
    while !acc.done {
        if cancel.load(Ordering::Relaxed) {
            return Err(ApiError::Cancelled.into());
        }
        let line = match rx.recv_timeout(CANCEL_POLL) {
            Ok(Wire::Line(line)) => {
                *alive = Instant::now();
                line
            }
            Ok(Wire::Failed(failure)) => return Err(failure),
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                return Err(ApiError::Network("stream ended early".into()).into())
            }
        };
        let Some(data) = line.strip_prefix("data:") else {
            continue;
        };
        let data = data.trim();
        if data.is_empty() {
            continue;
        }
        let event: Value =
            serde_json::from_str(data).map_err(|e| ApiError::Protocol(e.to_string()))?;
        if let Some(text) = acc.apply(&event)? {
            on_event(StreamEvent::TextDelta(&text));
        }
    }
    if cancel.load(Ordering::Relaxed) {
        return Err(ApiError::Cancelled.into());
    }
    // The body ends right after `message_stop`; give the reader a moment to
    // see that, so the next request finds the connection in the pool.
    let until = Instant::now() + Duration::from_millis(100);
    loop {
        match rx.recv_timeout(until.saturating_duration_since(Instant::now())) {
            Ok(_) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                abandon.finished = true;
                pool_used();
                break;
            }
            Err(mpsc::RecvTimeoutError::Timeout) => break,
        }
    }
    drop(abandon);
    if acc.stop_reason.as_deref() == Some("refusal") {
        return Err(ApiError::Refusal(acc.refusal_category).into());
    }
    Ok(Completion {
        content: echoable(acc.blocks),
        stop_reason: acc.stop_reason,
        usage: Value::Object(acc.usage),
        model: acc.model,
        invalid_inputs: acc.invalid_inputs,
    })
}

#[derive(Default)]
struct Accumulator {
    blocks: Vec<Value>,
    partial_json: Vec<String>,
    stop_reason: Option<String>,
    refusal_category: Option<String>,
    usage: Map<String, Value>,
    model: Option<String>,
    invalid_inputs: Vec<String>,
    done: bool,
}

/// More content blocks than any reply has; an index beyond it is a broken
/// stream, not something to allocate for.
const MAX_BLOCKS: usize = 4096;

impl Accumulator {
    /// Applies one SSE event; returns visible text when the event carried some.
    fn apply(&mut self, ev: &Value) -> Result<Option<String>, ApiError> {
        match ev["type"].as_str().unwrap_or("") {
            "message_start" => {
                self.model = ev["message"]["model"].as_str().map(str::to_string);
                if let Some(u) = ev["message"]["usage"].as_object() {
                    self.usage.extend(u.clone());
                }
            }
            "content_block_start" => {
                let idx = ev["index"].as_u64().unwrap_or(self.blocks.len() as u64) as usize;
                if idx >= MAX_BLOCKS {
                    return Err(ApiError::Protocol("content block index out of range".into()));
                }
                while self.blocks.len() <= idx {
                    self.blocks.push(Value::Null);
                    self.partial_json.push(String::new());
                }
                self.blocks[idx] = ev["content_block"].clone();
                if let Some(t) = ev["content_block"]["text"]
                    .as_str()
                    .filter(|t| !t.is_empty())
                {
                    return Ok(Some(t.to_string()));
                }
            }
            "content_block_delta" => {
                let idx = ev["index"].as_u64().unwrap_or(0) as usize;
                let Some(block) = self.blocks.get_mut(idx) else {
                    return Err(ApiError::Protocol("delta for unknown block".into()));
                };
                let delta = &ev["delta"];
                match delta["type"].as_str().unwrap_or("") {
                    "text_delta" => {
                        let t = delta["text"].as_str().unwrap_or("");
                        append_str(block, "text", t);
                        return Ok(Some(t.to_string()));
                    }
                    "thinking_delta" => {
                        append_str(block, "thinking", delta["thinking"].as_str().unwrap_or(""))
                    }
                    "signature_delta" => {
                        block["signature"] = delta["signature"].clone();
                    }
                    "input_json_delta" => {
                        self.partial_json[idx]
                            .push_str(delta["partial_json"].as_str().unwrap_or(""));
                    }
                    _ => {}
                }
            }
            "content_block_stop" => {
                let idx = ev["index"].as_u64().unwrap_or(0) as usize;
                if let (Some(block), Some(json)) =
                    (self.blocks.get_mut(idx), self.partial_json.get(idx))
                {
                    if !json.is_empty() {
                        // A call cut off at the output limit, or malformed,
                        // has no usable input: it is echoed with `{}` and
                        // reported, so it is answered with an error, not run.
                        block["input"] = match serde_json::from_str::<Value>(json) {
                            Ok(input) if input.is_object() => input,
                            _ => {
                                if block["type"] == "tool_use" {
                                    let id = block["id"].as_str().unwrap_or("").to_string();
                                    self.invalid_inputs.push(id);
                                }
                                Value::Object(Map::new())
                            }
                        };
                    }
                }
            }
            "message_delta" => {
                if let Some(r) = ev["delta"]["stop_reason"].as_str() {
                    self.stop_reason = Some(r.to_string());
                }
                if let Some(c) = ev["delta"]["stop_details"]["category"].as_str() {
                    self.refusal_category = Some(c.to_string());
                }
                if let Some(u) = ev["usage"].as_object() {
                    self.usage.extend(u.clone());
                }
            }
            "message_stop" => self.done = true,
            "error" => {
                let message = ev["error"]["message"]
                    .as_str()
                    .unwrap_or("stream error")
                    .to_string();
                // The status the same error has as an HTTP response, so
                // only the kinds worth retrying are retried.
                let status = match ev["error"]["type"].as_str() {
                    Some("overloaded_error") => 529,
                    Some("rate_limit_error") => 429,
                    Some("invalid_request_error") => 400,
                    Some("authentication_error") => 401,
                    Some("billing_error") => 402,
                    Some("permission_error") => 403,
                    Some("not_found_error") => 404,
                    Some("request_too_large") => 413,
                    _ => 500,
                };
                return Err(ApiError::Http { status, message });
            }
            _ => {} // ping and future event types
        }
        Ok(None)
    }
}

fn append_str(block: &mut Value, key: &str, s: &str) {
    let mut cur = block[key].as_str().unwrap_or("").to_string();
    cur.push_str(s);
    block[key] = Value::String(cur);
}

/// Applies the documented echo rule for replies that switched to a fallback
/// model mid-output: before the last `fallback` marker only text blocks are
/// replayed. Text blocks with nothing in them are left out (the API rejects
/// them when they come back). Everything else is kept exactly as received.
fn echoable(blocks: Vec<Value>) -> Vec<Value> {
    let blocks: Vec<Value> = blocks
        .into_iter()
        .filter(|b| !b.is_null())
        .filter(|b| b["type"] != "text" || b["text"].as_str().is_some_and(|t| !t.trim().is_empty()))
        .collect();
    let Some(boundary) = blocks.iter().rposition(|b| b["type"] == "fallback") else {
        return blocks;
    };
    blocks
        .into_iter()
        .enumerate()
        .filter(|(i, b)| *i > boundary || b["type"] == "text")
        .map(|(_, b)| b)
        .collect()
}

/// Whether a 400 says the history's thinking blocks no longer verify: the
/// system prompt, the tools or an earlier message changed since they were
/// produced (or a signature is damaged). Sending the same history again
/// fails the same way; without its thinking blocks it is accepted.
pub fn is_thinking_binding_error(status: u16, message: &str) -> bool {
    status == 400
        && message.contains("thinking")
        && (message.contains("signature") || message.contains("cannot be modified"))
}

/// Takes every thinking block out of `messages`: the documented way back
/// from `is_thinking_binding_error`. Text and tool calls stay. Returns
/// whether there was anything to take out.
pub fn strip_thinking(messages: &mut [Value]) -> bool {
    let mut stripped = false;
    for message in messages.iter_mut().filter(|m| m["role"] == "assistant") {
        let Some(blocks) = message["content"].as_array_mut() else {
            continue;
        };
        let before = blocks.len();
        blocks.retain(|b| b["type"] != "thinking" && b["type"] != "redacted_thinking");
        stripped |= blocks.len() != before;
        if blocks.is_empty() {
            blocks.push(json!({"type": "text", "text": NO_REPLY}));
        }
    }
    stripped
}

/// Stands in for an assistant message with nothing in it, which the API
/// would reject as soon as another message follows it.
pub const NO_REPLY: &str = "(no reply)";

/// A stand-in for the API on this machine, for tests: it answers each
/// request with the next canned reply and keeps what it was sent.
#[cfg(test)]
pub(crate) mod fake {
    use std::collections::VecDeque;
    use std::io::{BufRead, BufReader, Read, Write};
    use std::net::{TcpListener, TcpStream};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    use serde_json::{json, Value};

    use super::Settings;

    pub enum Reply {
        /// A complete stream of these events.
        Events(Vec<Value>),
        /// These events, then the connection drops.
        Dropped(Vec<Value>),
        /// These events, then nothing for a long time.
        Stalled(Vec<Value>),
        /// An error response with this status, error type and extra headers.
        Status(u16, &'static str, Vec<(&'static str, &'static str)>),
        /// A 400 with this message.
        Refused(&'static str),
    }

    pub struct Api {
        pub url: String,
        /// The body of every request received, in order.
        pub requests: Arc<Mutex<Vec<Value>>>,
        /// Connections accepted so far.
        pub connections: Arc<AtomicUsize>,
    }

    impl Api {
        pub fn start(replies: Vec<Reply>) -> Api {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let url = format!("http://{}", listener.local_addr().unwrap());
            let requests = Arc::new(Mutex::new(Vec::new()));
            let connections = Arc::new(AtomicUsize::new(0));
            let replies = Arc::new(Mutex::new(VecDeque::from(replies)));
            let (seen, count) = (requests.clone(), connections.clone());
            std::thread::spawn(move || {
                for stream in listener.incoming().flatten() {
                    count.fetch_add(1, Ordering::SeqCst);
                    let (seen, replies) = (seen.clone(), replies.clone());
                    std::thread::spawn(move || serve(stream, &seen, &replies));
                }
            });
            Api { url, requests, connections }
        }

        pub fn settings(&self) -> Settings {
            Settings { api_key: "test".into(), base_url: self.url.clone(), ..Settings::default() }
        }

        pub fn request(&self, n: usize) -> Value {
            self.requests.lock().unwrap()[n].clone()
        }

        pub fn request_count(&self) -> usize {
            self.requests.lock().unwrap().len()
        }
    }

    /// Answers requests on one connection until the client closes it.
    fn serve(stream: TcpStream, seen: &Mutex<Vec<Value>>, replies: &Mutex<VecDeque<Reply>>) {
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut stream = stream;
        loop {
            let mut length = 0;
            loop {
                let mut line = String::new();
                if reader.read_line(&mut line).unwrap_or(0) == 0 {
                    return;
                }
                let line = line.trim().to_ascii_lowercase();
                if line.is_empty() {
                    break;
                }
                if let Some(n) = line.strip_prefix("content-length:") {
                    length = n.trim().parse().unwrap_or(0);
                }
            }
            let mut body = vec![0; length];
            if reader.read_exact(&mut body).is_err() {
                return;
            }
            seen.lock().unwrap().push(serde_json::from_slice(&body).unwrap_or(Value::Null));
            let reply = replies.lock().unwrap().pop_front();
            let chunks = |events: &[Value]| {
                let mut out = String::from(
                    "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n",
                );
                for e in events {
                    let data = format!("event: {}\ndata: {e}\n\n", e["type"].as_str().unwrap_or(""));
                    out.push_str(&format!("{:x}\r\n{data}\r\n", data.len()));
                }
                out
            };
            let sent = match reply {
                Some(Reply::Events(events)) => {
                    stream.write_all(format!("{}0\r\n\r\n", chunks(&events)).as_bytes())
                }
                Some(Reply::Dropped(events)) => {
                    let _ = stream.write_all(chunks(&events).as_bytes());
                    return;
                }
                Some(Reply::Stalled(events)) => {
                    let _ = stream.write_all(chunks(&events).as_bytes());
                    std::thread::sleep(Duration::from_secs(20));
                    return;
                }
                Some(Reply::Status(status, kind, headers)) => {
                    let body = json!({"type": "error", "error": {"type": kind, "message": format!("fake {kind}")}}).to_string();
                    let mut head = format!("HTTP/1.1 {status} Error\r\ncontent-type: application/json\r\ncontent-length: {}\r\n", body.len());
                    for (name, value) in headers {
                        head.push_str(&format!("{name}: {value}\r\n"));
                    }
                    stream.write_all(format!("{head}\r\n{body}").as_bytes())
                }
                Some(Reply::Refused(message)) => {
                    let body = json!({"type": "error", "error": {"type": "invalid_request_error", "message": message}}).to_string();
                    stream.write_all(format!("HTTP/1.1 400 Error\r\ncontent-length: {}\r\n\r\n{body}", body.len()).as_bytes())
                }
                // Not transient, so a test that asks for too much fails at once.
                None => stream.write_all(b"HTTP/1.1 400 Error\r\ncontent-length: 2\r\n\r\n{}"),
            };
            if sent.is_err() {
                return;
            }
        }
    }

    /// The events of a reply made of `blocks` that stops for `stop_reason`.
    /// Text arrives as a delta and a tool call's input as JSON text, the way
    /// the API sends them; a tool call with `"partial"` gets that string as
    /// its (cut off) input instead.
    pub fn events(blocks: &[Value], stop_reason: &str) -> Vec<Value> {
        let mut out = vec![json!({"type": "message_start", "message": {"model": "fake", "usage": {"input_tokens": 1}}})];
        for (index, block) in blocks.iter().enumerate() {
            let mut start = block.clone();
            let mut delta = None;
            if block["type"] == "text" {
                start["text"] = json!("");
                delta = Some(json!({"type": "text_delta", "text": block["text"]}));
            } else if let Some(partial) = block.get("partial") {
                start.as_object_mut().unwrap().remove("partial");
                start["input"] = json!({});
                delta = Some(json!({"type": "input_json_delta", "partial_json": partial}));
            } else if let Some(input) = block.get("input") {
                start["input"] = json!({});
                delta = Some(json!({"type": "input_json_delta", "partial_json": input.to_string()}));
            }
            out.push(json!({"type": "content_block_start", "index": index, "content_block": start}));
            if let Some(delta) = delta {
                out.push(json!({"type": "content_block_delta", "index": index, "delta": delta}));
            }
            out.push(json!({"type": "content_block_stop", "index": index}));
        }
        out.push(json!({"type": "message_delta", "delta": {"stop_reason": stop_reason}, "usage": {"output_tokens": 1}}));
        out.push(json!({"type": "message_stop"}));
        out
    }

    pub fn text(text: &str) -> Value {
        json!({"type": "text", "text": text})
    }

    /// A reply that just says `text`.
    pub fn says(text: &str) -> Reply {
        Reply::Events(events(&[self::text(text)], "end_turn"))
    }

    /// A reply that breaks off (as `Dropped` or `Stalled`) after saying `text`.
    pub fn starts(text: &str) -> Vec<Value> {
        let mut events = events(&[self::text(text)], "end_turn");
        events.truncate(3);
        events
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rebuilds_blocks_from_events() {
        let events = [
            json!({"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":5}}}),
            json!({"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}),
            json!({"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}),
            json!({"type":"content_block_stop","index":0}),
            json!({"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}),
            json!({"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hi "}}),
            json!({"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"there"}}),
            json!({"type":"content_block_stop","index":1}),
            json!({"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}),
            json!({"type":"message_stop"}),
        ];
        let mut acc = Accumulator::default();
        let mut text = String::new();
        for e in &events {
            if let Some(t) = acc.apply(e).unwrap() {
                text.push_str(&t);
            }
        }
        assert_eq!(text, "Hi there");
        assert!(acc.done);
        assert_eq!(
            acc.blocks[0],
            json!({"type":"thinking","thinking":"","signature":"sig"})
        );
        assert_eq!(acc.blocks[1], json!({"type":"text","text":"Hi there"}));
        assert_eq!(acc.usage["output_tokens"], 7);
    }

    #[test]
    fn drops_non_text_before_fallback_boundary() {
        let blocks = vec![
            json!({"type":"thinking","thinking":"","signature":"a"}),
            json!({"type":"text","text":"partial"}),
            json!({"type":"fallback","from":{"model":"x"},"to":{"model":"y"}}),
            json!({"type":"thinking","thinking":"","signature":"b"}),
            json!({"type":"text","text":"rest"}),
        ];
        let kept: Vec<_> = echoable(blocks)
            .into_iter()
            .map(|b| b["type"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(kept, ["text", "thinking", "text"]);
    }

    #[test]
    fn fallback_only_for_supported_models() {
        let mut s = Settings::default();
        assert_eq!(build_body(&s, "sys", &[], &[])["fallbacks"], "default");
        s.model = "claude-haiku-5-5".into();
        assert!(build_body(&s, "sys", &[], &[]).get("fallbacks").is_none());
        assert!(build_body(&s, "sys", &[], &[]).get("tools").is_none());
    }

    /// Streams one reply from the fake API, collecting what is passed on
    /// (a restart shows as "<restart>").
    fn ask(api: &fake::Api, cancel: &AtomicBool) -> (Result<Completion, ApiError>, Vec<String>) {
        let settings = api.settings();
        let body = build_body(&settings, "sys", &[json!({"role": "user", "content": "hi"})], &[]);
        let mut seen = Vec::new();
        let result = stream(&settings, &body, cancel, |event| match event {
            StreamEvent::TextDelta(t) => seen.push(t.to_string()),
            StreamEvent::Restart => seen.push("<restart>".into()),
        });
        (result, seen)
    }

    #[test]
    fn passing_failures_are_retried() {
        let overloaded = json!({"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}});
        let api = fake::Api::start(vec![
            fake::Reply::Status(500, "api_error", vec![]),
            fake::Reply::Status(429, "rate_limit_error", vec![("retry-after-ms", "5")]),
            // Overloaded after the response had started.
            fake::Reply::Events(vec![json!({"type": "message_start", "message": {}}), overloaded]),
            fake::says("Hello."),
        ]);
        let (result, seen) = ask(&api, &AtomicBool::new(false));
        assert_eq!(result.unwrap().content, vec![json!({"type": "text", "text": "Hello."})]);
        assert_eq!(seen, ["Hello."]);
        assert_eq!(api.request_count(), 4);
        // Every attempt sends the same request.
        assert_eq!(api.request(0), api.request(3));
        assert!(ApiError::Http { status: 529, message: String::new() }.is_transient());
        assert!(ApiError::Network(String::new()).is_transient());
        assert!(!ApiError::Http { status: 413, message: String::new() }.is_transient());
        assert!(!ApiError::Refusal(None).is_transient());
    }

    #[test]
    fn gives_up_after_the_last_retry() {
        let api = fake::Api::start(
            (0..10).map(|_| fake::Reply::Status(529, "overloaded_error", vec![])).collect(),
        );
        let (result, _) = ask(&api, &AtomicBool::new(false));
        assert_eq!(result.err().map(|e| e.kind()), Some("overloaded"));
        assert_eq!(api.request_count(), MAX_RETRIES as usize + 1);
    }

    #[test]
    fn lasting_failures_are_not_retried() {
        for (reply, kind) in [
            (fake::Reply::Status(400, "invalid_request_error", vec![]), "http"),
            (fake::Reply::Status(401, "authentication_error", vec![]), "auth"),
            // The server says how long to wait, and it is too long.
            (fake::Reply::Status(429, "rate_limit_error", vec![("retry-after", "600")]), "rate_limited"),
            (fake::Reply::Status(503, "api_error", vec![("x-should-retry", "false")]), "http"),
            // An error event in the stream that isn't a passing one.
            (
                fake::Reply::Events(vec![json!({"type": "error", "error": {"type": "invalid_request_error", "message": "no"}})]),
                "http",
            ),
        ] {
            let api = fake::Api::start(vec![reply, fake::says("never asked for")]);
            let (result, _) = ask(&api, &AtomicBool::new(false));
            let error = result.err().expect("an error");
            assert_eq!(error.kind(), kind);
            assert!(!matches!(error, ApiError::Http { status: 500.., .. }) || kind == "http");
            assert_eq!(api.request_count(), 1, "{kind} was retried");
        }
    }

    #[test]
    fn a_dropped_reply_is_asked_for_again() {
        let api = fake::Api::start(vec![fake::Reply::Dropped(fake::starts("Hel")), fake::says("Hello.")]);
        let (result, seen) = ask(&api, &AtomicBool::new(false));
        assert!(result.is_ok());
        assert_eq!(seen, ["Hel", "<restart>", "Hello."]);
    }

    #[test]
    fn cancelling_a_stalled_reply_stops_at_once() {
        let api = fake::Api::start(vec![fake::Reply::Stalled(fake::starts("Thinking about"))]);
        let cancel = Arc::new(AtomicBool::new(false));
        let flag = cancel.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(250));
            flag.store(true, Ordering::Relaxed);
        });
        let started = Instant::now();
        let (result, seen) = ask(&api, &cancel);
        assert!(matches!(result, Err(ApiError::Cancelled)));
        assert_eq!(seen, ["Thinking about"]);
        assert!(started.elapsed() < Duration::from_secs(2), "took {:?}", started.elapsed());
    }

    #[test]
    fn cancelling_stops_the_wait_before_a_retry() {
        let api = fake::Api::start(vec![fake::Reply::Status(429, "rate_limit_error", vec![("retry-after", "15")])]);
        let cancel = Arc::new(AtomicBool::new(false));
        let flag = cancel.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(200));
            flag.store(true, Ordering::Relaxed);
        });
        let started = Instant::now();
        let (result, _) = ask(&api, &cancel);
        assert!(matches!(result, Err(ApiError::Cancelled)));
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn the_connection_is_reused_for_the_next_request() {
        let api = fake::Api::start(vec![fake::says("One."), fake::says("Two."), fake::says("Three.")]);
        for _ in 0..3 {
            assert!(ask(&api, &AtomicBool::new(false)).0.is_ok());
        }
        assert_eq!(api.request_count(), 3);
        assert_eq!(api.connections.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn a_cut_off_tool_input_is_reported_not_guessed() {
        let events = [
            json!({"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"bash","input":{}}}),
            json!({"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"command\": \"echo hel"}}),
            json!({"type":"content_block_stop","index":0}),
            json!({"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_2","name":"bash","input":{}}}),
            json!({"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"command\": \"ls\"}"}}),
            json!({"type":"content_block_stop","index":1}),
        ];
        let mut acc = Accumulator::default();
        for e in &events {
            acc.apply(e).unwrap();
        }
        assert_eq!(acc.invalid_inputs, ["toolu_1"]);
        assert_eq!(acc.blocks[0]["input"], json!({}));
        assert_eq!(acc.blocks[1]["input"], json!({"command": "ls"}));
        // A block index no reply has is a broken stream, not memory to reserve.
        let far = json!({"type":"content_block_start","index":9_000_000_000u64,"content_block":{"type":"text","text":""}});
        assert!(acc.apply(&far).is_err());
    }

    #[test]
    fn empty_text_blocks_are_not_echoed() {
        let kept = echoable(vec![
            json!({"type":"thinking","thinking":"","signature":"a"}),
            json!({"type":"text","text":""}),
            json!({"type":"text","text":"\n\n"}),
            json!({"type":"tool_use","id":"t","name":"bash","input":{}}),
        ]);
        assert_eq!(kept.len(), 2);
        assert_eq!(kept[0]["type"], "thinking");
        assert_eq!(kept[1]["type"], "tool_use");
    }

    #[test]
    fn thinking_is_stripped_for_the_way_back_from_a_binding_error() {
        let refused = "messages.5.content.0: Invalid `signature` in `thinking` block. The block is bound to a \
                       different conversation. Remove the block, or set `thinking.block_binding.prefix_mismatch_behavior` to \"drop_block\".";
        assert!(is_thinking_binding_error(400, refused));
        assert!(!is_thinking_binding_error(400, "max_tokens: must be positive"));
        assert!(!is_thinking_binding_error(500, refused));
        let mut messages = vec![
            json!({"role":"user","content":[{"type":"text","text":"hi"}]}),
            json!({"role":"assistant","content":[
                {"type":"thinking","thinking":"","signature":"s"},
                {"type":"text","text":"On it."},
                {"type":"tool_use","id":"t","name":"bash","input":{}},
            ]}),
            json!({"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"ok"}]}),
            json!({"role":"assistant","content":[{"type":"redacted_thinking","data":"x"}]}),
        ];
        assert!(strip_thinking(&mut messages));
        assert_eq!(messages[1]["content"].as_array().unwrap().len(), 2);
        assert_eq!(messages[1]["content"][1]["type"], "tool_use");
        // A message left with nothing gets a stand-in, never an empty list.
        assert_eq!(messages[3]["content"], json!([{"type":"text","text":NO_REPLY}]));
        assert!(!strip_thinking(&mut messages));
    }

    #[test]
    fn retry_waits_grow_and_respect_the_server() {
        let first = retry_delay(0, None).unwrap();
        let third = retry_delay(2, None).unwrap();
        assert!(first >= RETRY_BASE && first <= RETRY_BASE * 2);
        assert!(third >= RETRY_BASE * 4);
        assert_eq!(retry_delay(0, Some(Duration::from_secs(3))), Some(Duration::from_secs(3)));
        assert_eq!(retry_delay(0, Some(MAX_RETRY_AFTER + Duration::from_secs(1))), None);
    }
}
