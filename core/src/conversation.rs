//! Conversation state: the replayable API history for the live session and a
//! lightweight transcript that is saved to disk for the Home window.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// Start a fresh conversation after this much silence.
pub const IDLE_RESET_SECS: u64 = 15 * 60;
/// History is append-only (thinking blocks must be replayed unchanged), so
/// instead of trimming old turns the history is rebuilt from the text of
/// the latest turns once it gets long (see `Session::compact`).
/// Agent tasks add a message pair per tool round, so this is generous.
pub const MAX_API_MESSAGES: usize = 160;
/// Screenshots the history may hold, and their size as sent, before it is
/// rebuilt: every request sends all of them again, so a long talk about
/// the screen would get slower with each question and end up refused.
pub const MAX_HISTORY_IMAGES: usize = 16;
pub const MAX_HISTORY_IMAGE_BYTES: usize = 6 << 20;
/// Turns replayed when a saved conversation is resumed.
const RESUME_TURNS: usize = 20;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Turn {
    pub role: String,
    pub text: String,
    pub at: u64,
    #[serde(default)]
    pub screens: usize,
    #[serde(default)]
    pub points: Vec<String>,
    /// What the agent did while answering ("Ran git status", "Clicked").
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub steps: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Transcript {
    pub id: String,
    pub title: String,
    pub created_at: u64,
    pub updated_at: u64,
    pub turns: Vec<Turn>,
}

#[derive(Debug, Serialize)]
pub struct Summary {
    pub id: String,
    pub title: String,
    pub updated_at: u64,
    pub turn_count: usize,
}

pub struct Session {
    pub api_messages: Vec<Value>,
    pub transcript: Transcript,
    /// The system prompt this conversation is sent with, and the settings
    /// it was written for (see `system_prompt`).
    system: Option<(String, String)>,
}

impl Default for Session {
    fn default() -> Self {
        Self::new()
    }
}

impl Session {
    pub fn new() -> Self {
        let now = now();
        Self {
            api_messages: Vec::new(),
            transcript: Transcript {
                id: uuid::Uuid::new_v4().to_string(),
                title: String::new(),
                created_at: now,
                updated_at: now,
                turns: Vec::new(),
            },
            system: None,
        }
    }

    /// The conversation's system prompt: written by `render` the first time
    /// and returned unchanged after that, for as long as `key` (the settings
    /// it depends on) stays the same. The history's thinking blocks are only
    /// accepted back under the system prompt they were produced with, so
    /// what changes between requests (memory, the date) must not change it.
    pub fn system_prompt(&mut self, key: &str, render: impl FnOnce() -> String) -> String {
        match &self.system {
            Some((k, prompt)) if k == key => prompt.clone(),
            _ => {
                let prompt = render();
                self.system = Some((key.to_string(), prompt.clone()));
                prompt
            }
        }
    }

    /// Picks up a saved conversation. Only the text of each turn is
    /// replayed (screenshots and thinking are not saved), and only the most
    /// recent turns, so there is room to keep talking.
    pub fn resume(mut transcript: Transcript) -> Self {
        let keep = RESUME_TURNS;
        let start = transcript.turns.len().saturating_sub(keep) & !1; // whole user/assistant pairs
        // Turns aren't always question and answer in turn (a background
        // task's report is an assistant turn of its own), but the API wants
        // a user message first and the roles alternating after that.
        let mut api_messages: Vec<Value> = Vec::new();
        for t in &transcript.turns[start..] {
            let text = if !t.text.trim().is_empty() {
                t.text.clone()
            } else if t.role == "user" {
                "(asked about the screen)".to_string()
            } else {
                "(no reply)".to_string()
            };
            match api_messages.last_mut() {
                None if t.role != "user" => {}
                Some(last) if last["role"] == t.role.as_str() => {
                    let joined = format!("{}\n\n{text}", last["content"][0]["text"].as_str().unwrap_or(""));
                    last["content"][0]["text"] = json!(joined);
                }
                _ => api_messages.push(json!({"role": t.role, "content": [{"type": "text", "text": text}]})),
            }
        }
        // Resuming is activity: don't let the idle reset throw it away.
        transcript.updated_at = now();
        Self {
            api_messages,
            transcript,
            system: None,
        }
    }

    pub fn is_stale(&self) -> bool {
        !self.transcript.turns.is_empty()
            && now().saturating_sub(self.transcript.updated_at) > IDLE_RESET_SECS
    }

    /// The history has grown long, or heavy with screenshots.
    pub fn is_long(&self) -> bool {
        if self.api_messages.len() >= MAX_API_MESSAGES {
            return true;
        }
        let (mut images, mut bytes) = (0, 0);
        for m in &self.api_messages {
            weigh(m, &mut images, &mut bytes);
        }
        images > MAX_HISTORY_IMAGES || bytes > MAX_HISTORY_IMAGE_BYTES
    }

    /// Carries the conversation on with a short history: the text of its
    /// latest turns, as when a saved conversation is resumed. Old
    /// screenshots, tool results and thinking go; the chat keeps everything.
    pub fn compact(&mut self) {
        let transcript = std::mem::replace(&mut self.transcript, Session::new().transcript);
        *self = Session::resume(transcript);
    }

    pub fn commit(
        &mut self,
        user_msg: Value,
        assistant_content: Vec<Value>,
        user_turn: Turn,
        assistant_turn: Turn,
    ) {
        let assistant = json!({"role": "assistant", "content": assistant_content});
        self.commit_messages(vec![user_msg, assistant], user_turn, assistant_turn);
    }

    /// Appends every message of one exchange (an agent task adds tool
    /// rounds between the question and the answer) and its transcript turns.
    pub fn commit_messages(&mut self, messages: Vec<Value>, user_turn: Turn, assistant_turn: Turn) {
        self.api_messages.extend(messages);
        self.record(user_turn, assistant_turn);
    }

    /// Adds turns to the transcript only, for an exchange that didn't finish
    /// (its messages can't be replayed, but the user should see it).
    /// Adds a message that wasn't an answer to a question, such as a
    /// background task's report.
    pub fn note(&mut self, turn: Turn) {
        self.transcript.updated_at = now();
        self.transcript.turns.push(turn);
    }

    /// Appends an exchange the user didn't start (the agent reporting back
    /// on a background task): its messages, and only the agent's turn.
    pub fn commit_report(&mut self, messages: Vec<Value>, assistant_turn: Turn, title: &str) {
        self.api_messages.extend(messages);
        if self.transcript.title.is_empty() {
            self.transcript.title = title_from(title);
        }
        self.note(assistant_turn);
    }

    pub fn record(&mut self, user_turn: Turn, assistant_turn: Turn) {
        if self.transcript.title.is_empty() {
            self.transcript.title = title_from(&user_turn.text);
        }
        self.transcript.updated_at = now();
        self.transcript.turns.push(user_turn);
        self.transcript.turns.push(assistant_turn);
    }
}

pub struct Store {
    dir: PathBuf,
}

impl Store {
    pub fn new(data_dir: &Path) -> Self {
        let dir = data_dir.join("conversations");
        let _ = fs::create_dir_all(&dir);
        Self { dir }
    }

    pub fn save(&self, t: &Transcript) -> std::io::Result<()> {
        let path = self
            .path(&t.id)
            .ok_or_else(|| std::io::Error::other("bad id"))?;
        let tmp = path.with_extension("json.tmp");
        fs::write(&tmp, serde_json::to_vec_pretty(t)?)?;
        fs::rename(tmp, path)
    }

    pub fn load(&self, id: &str) -> Option<Transcript> {
        let bytes = fs::read(self.path(id)?).ok()?;
        serde_json::from_slice(&bytes).ok()
    }

    /// Renames a saved conversation; false when it does not exist.
    pub fn rename(&self, id: &str, title: &str) -> bool {
        let Some(mut t) = self.load(id) else {
            return false;
        };
        t.title = title.to_string();
        self.save(&t).is_ok()
    }

    pub fn delete(&self, id: &str) {
        if let Some(p) = self.path(id) {
            let _ = fs::remove_file(p);
        }
    }

    pub fn list(&self) -> Vec<Summary> {
        let mut out: Vec<Summary> = fs::read_dir(&self.dir)
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| e.path().extension().is_some_and(|x| x == "json"))
            .filter_map(|e| serde_json::from_slice::<Transcript>(&fs::read(e.path()).ok()?).ok())
            .map(|t| Summary {
                id: t.id,
                title: t.title,
                updated_at: t.updated_at,
                turn_count: t.turns.len(),
            })
            .collect();
        out.sort_by_key(|s| std::cmp::Reverse(s.updated_at));
        out
    }

    /// Only plain UUID-like ids map to files, so an id can never escape the folder.
    fn path(&self, id: &str) -> Option<PathBuf> {
        let ok = !id.is_empty()
            && id.len() <= 64
            && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-');
        ok.then(|| self.dir.join(format!("{id}.json")))
    }
}

/// Counts the images in a message and the size of their data.
fn weigh(v: &Value, images: &mut usize, bytes: &mut usize) {
    match v {
        Value::Array(items) => items.iter().for_each(|i| weigh(i, images, bytes)),
        Value::Object(map) if map.get("type").and_then(Value::as_str) == Some("image") => {
            *images += 1;
            *bytes += map["source"]["data"].as_str().map_or(0, str::len);
        }
        Value::Object(map) => {
            if let Some(content) = map.get("content") {
                weigh(content, images, bytes);
            }
        }
        _ => {}
    }
}

pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn title_from(text: &str) -> String {
    let t = text.trim();
    if t.is_empty() {
        return "Screen question".into();
    }
    let mut title: String = t.chars().take(60).collect();
    if t.chars().count() > 60 {
        title.push('…');
    }
    title
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn store_round_trip_and_rejects_bad_ids() {
        let dir = std::env::temp_dir().join(format!("cp-test-{}", uuid::Uuid::new_v4()));
        let store = Store::new(&dir);
        let mut s = Session::new();
        let turn = |role: &str| Turn {
            role: role.into(),
            text: "hello".into(),
            at: 1,
            screens: 0,
            points: vec![],
            steps: vec![],
        };
        s.commit(
            json!({"role":"user","content":"hello"}),
            vec![],
            turn("user"),
            turn("assistant"),
        );
        store.save(&s.transcript).unwrap();
        assert_eq!(store.load(&s.transcript.id).unwrap().turns.len(), 2);
        assert_eq!(store.list().len(), 1);
        assert!(store.load("../etc/passwd").is_none());
        assert!(store.rename(&s.transcript.id, "Renamed"));
        assert_eq!(store.load(&s.transcript.id).unwrap().title, "Renamed");
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn resume_replays_whole_text_pairs() {
        let turns: Vec<Turn> = (0..50)
            .map(|i| Turn {
                role: if i % 2 == 0 { "user" } else { "assistant" }.into(),
                text: if i == 48 {
                    String::new()
                } else {
                    format!("t{i}")
                },
                at: 1,
                screens: 0,
                points: vec![],
                steps: vec![],
            })
            .collect();
        let s = Session::resume(Transcript {
            id: "x".into(),
            title: "T".into(),
            created_at: 1,
            updated_at: 1,
            turns,
        });
        assert_eq!(s.api_messages.len(), RESUME_TURNS);
        assert_eq!(s.api_messages[0]["role"], "user");
        assert_eq!(s.api_messages.last().unwrap()["role"], "assistant");
        assert_eq!(
            s.api_messages[s.api_messages.len() - 2]["content"][0]["text"],
            "(asked about the screen)"
        );
        assert!(!s.is_stale());
        assert_eq!(s.transcript.turns.len(), 50);
    }

    #[test]
    fn resume_starts_with_the_user_and_alternates() {
        let turn = |role: &str, text: &str| Turn {
            role: role.into(),
            text: text.into(),
            at: 1,
            screens: 0,
            points: vec![],
            steps: vec![],
        };
        // A background task's report is an assistant turn of its own, so
        // turns stop pairing up; 23 of them make the replayed window start
        // on the report.
        let mut turns = vec![turn("user", "q0"), turn("assistant", "a0"), turn("assistant", "report")];
        for i in 1..=10 {
            turns.push(turn("user", &format!("q{i}")));
            turns.push(turn("assistant", &format!("a{i}")));
        }
        turns.insert(9, turn("assistant", "second report"));
        let s = Session::resume(Transcript { id: "x".into(), title: "T".into(), created_at: 1, updated_at: 1, turns });
        assert_eq!(s.api_messages[0]["role"], "user");
        for pair in s.api_messages.windows(2) {
            assert_ne!(pair[0]["role"], pair[1]["role"]);
        }
        assert_eq!(s.api_messages.last().unwrap()["role"], "assistant");
        // The report isn't lost: it joins the reply before it.
        let all = serde_json::to_string(&s.api_messages).unwrap();
        assert!(all.contains("a3\\n\\nsecond report"), "{all}");
        assert_eq!(s.api_messages[0]["content"][0]["text"], "q2");
    }

    #[test]
    fn a_history_heavy_with_screenshots_is_rebuilt_from_its_text() {
        let turn = |role: &str, text: &str| Turn {
            role: role.into(),
            text: text.into(),
            at: 1,
            screens: 1,
            points: vec![],
            steps: vec![],
        };
        let shot = json!({"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": "abcd"}});
        let mut s = Session::new();
        for i in 0..=MAX_HISTORY_IMAGES {
            assert!(!s.is_long(), "after {i} screenshots");
            // In the question, or in a tool's result.
            let messages = if i % 2 == 0 {
                vec![
                    json!({"role": "user", "content": [shot.clone(), {"type": "text", "text": format!("q{i}")}]}),
                    json!({"role": "assistant", "content": [{"type": "text", "text": format!("a{i}")}]}),
                ]
            } else {
                vec![
                    json!({"role": "user", "content": [{"type": "text", "text": format!("q{i}")}]}),
                    json!({"role": "assistant", "content": [{"type": "tool_use", "id": "t", "name": "computer", "input": {}}]}),
                    json!({"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t", "content": [shot.clone()]}]}),
                    json!({"role": "assistant", "content": [{"type": "text", "text": format!("a{i}")}]}),
                ]
            };
            s.commit_messages(messages, turn("user", &format!("q{i}")), turn("assistant", &format!("a{i}")));
        }
        assert!(s.is_long());
        let (id, turns) = (s.transcript.id.clone(), s.transcript.turns.len());
        s.compact();
        assert!(!s.is_long() && !s.is_stale());
        // The same conversation, with everything still in the chat.
        assert_eq!((s.transcript.id.clone(), s.transcript.turns.len()), (id, turns));
        assert_eq!(s.api_messages.len(), RESUME_TURNS);
        assert!(!serde_json::to_string(&s.api_messages).unwrap().contains("image"));
        assert_eq!(s.api_messages.last().unwrap()["content"][0]["text"], format!("a{MAX_HISTORY_IMAGES}"));
        // One huge screenshot counts by its size.
        let mut s = Session::new();
        let big = json!({"type": "image", "source": {"type": "base64", "data": "x".repeat(MAX_HISTORY_IMAGE_BYTES + 1)}});
        s.commit_messages(vec![json!({"role": "user", "content": [big]})], turn("user", "q"), turn("assistant", "a"));
        assert!(s.is_long());
    }

    #[test]
    fn the_system_prompt_is_written_once_per_setting() {
        let mut s = Session::new();
        assert_eq!(s.system_prompt("a", || "first".into()), "first");
        assert_eq!(s.system_prompt("a", || "second".into()), "first");
        assert_eq!(s.system_prompt("b", || "third".into()), "third");
    }
}
