//! Minimal streaming client for the Claude Messages API.
//!
//! Rust has no official Anthropic SDK, so this speaks the documented raw HTTP
//! and server-sent-events protocol directly. Assistant content blocks (thinking
//! blocks included) are rebuilt from the stream exactly as received so the
//! conversation can be replayed append-only on the next turn.

use std::io::{BufRead, BufReader};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};

const API_VERSION: &str = "2026-10-21";
const FALLBACK_BETA: &str = "server-side-fallback-2026-07-01";
/// Models that accept `fallbacks: "default"` on the Claude API.
const FALLBACK_MODELS: &[&str] = &[
    "claude-fable-5-1",
    "claude-opus-5-5",
    "claude-opus-5",
    "claude-sonnet-5-5",
];

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

    pub fn message(&self) -> String {
        match self {
            ApiError::MissingKey => "Add your Anthropic API key in Settings.".into(),
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
}

pub struct Completion {
    /// Assistant content blocks, ready to append to the history.
    pub content: Vec<Value>,
    pub stop_reason: Option<String>,
    pub usage: Value,
    pub model: Option<String>,
}

pub fn build_body(settings: &Settings, system: &str, messages: &[Value], tools: &[Value]) -> Value {
    let mut body = json!({
        "model": settings.model,
        "max_tokens": settings.max_tokens,
        "stream": true,
        "system": [{"type": "text", "text": system}],
        "messages": messages,
        // Automatic prompt caching: the history prefix is reused turn to turn.
        "cache_control": {"type": "ephemeral"},
    });
    if !tools.is_empty() {
        body["tools"] = json!(tools);
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
fn http() -> &'static ureq::Agent {
    static AGENT: std::sync::OnceLock<ureq::Agent> = std::sync::OnceLock::new();
    AGENT.get_or_init(|| {
        ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(15))
            .timeout_read(Duration::from_secs(180))
            .max_idle_connections_per_host(4)
            .build()
    })
}

/// Opens a connection to the API ahead of the first request (the user just
/// pressed the talk key), so it is ready by the time they finish speaking.
pub fn warm(base_url: &str) {
    let url = base_url.trim_end_matches('/').to_string();
    std::thread::spawn(move || {
        let _ = http().get(&url).timeout(Duration::from_secs(5)).call();
    });
}

pub fn stream(
    settings: &Settings,
    body: &Value,
    cancel: &AtomicBool,
    mut on_event: impl FnMut(StreamEvent),
) -> Result<Completion, ApiError> {
    if settings.api_key.trim().is_empty() {
        return Err(ApiError::MissingKey);
    }
    let agent = http();
    let url = format!("{}/v1/messages", settings.base_url.trim_end_matches('/'));
    let mut req = agent
        .post(&url)
        .set("content-type", "application/json")
        .set("x-api-key", settings.api_key.trim())
        .set("anthropic-version", API_VERSION);
    if body.get("fallbacks").is_some() {
        req = req.set("anthropic-beta", FALLBACK_BETA);
    }

    let resp = match req.send_string(&body.to_string()) {
        Ok(r) => r,
        Err(ureq::Error::Status(status, r)) => {
            let text = r.into_string().unwrap_or_default();
            let message = serde_json::from_str::<Value>(&text)
                .ok()
                .and_then(|v| v["error"]["message"].as_str().map(str::to_string))
                .unwrap_or(text);
            return Err(ApiError::Http { status, message });
        }
        Err(e) => return Err(ApiError::Network(e.to_string())),
    };

    let mut acc = Accumulator::default();
    let reader = BufReader::new(resp.into_reader());
    for line in reader.lines() {
        if cancel.load(Ordering::Relaxed) {
            return Err(ApiError::Cancelled);
        }
        let line = line.map_err(|e| ApiError::Network(e.to_string()))?;
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
        if acc.done {
            break;
        }
    }
    if cancel.load(Ordering::Relaxed) {
        return Err(ApiError::Cancelled);
    }
    if !acc.done {
        return Err(ApiError::Network("stream ended early".into()));
    }
    if acc.stop_reason.as_deref() == Some("refusal") {
        return Err(ApiError::Refusal(acc.refusal_category));
    }
    Ok(Completion {
        content: echoable(acc.blocks),
        stop_reason: acc.stop_reason,
        usage: Value::Object(acc.usage),
        model: acc.model,
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
    done: bool,
}

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
                        block["input"] =
                            serde_json::from_str(json).unwrap_or(Value::Object(Map::new()));
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
                let status = match ev["error"]["type"].as_str() {
                    Some("overloaded_error") => 529,
                    Some("rate_limit_error") => 429,
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
/// replayed. Everything else is kept exactly as received.
fn echoable(blocks: Vec<Value>) -> Vec<Value> {
    let blocks: Vec<Value> = blocks.into_iter().filter(|b| !b.is_null()).collect();
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
}
