//! What Claude remembers about the user between conversations: short facts
//! it saves with the `memory` tool, kept in `<data_dir>/memory.json` and
//! listed in Settings, where the user can remove them.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// Oldest facts go first beyond this.
const MAX_FACTS: usize = 200;
const MAX_CHARS: usize = 300;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Fact {
    pub id: String,
    pub text: String,
    /// When it was saved, as YYYY-MM-DD.
    pub date: String,
}

pub struct Memory {
    path: PathBuf,
    lock: Mutex<()>,
}

impl Memory {
    pub fn new(data_dir: &Path) -> Self {
        Self {
            path: data_dir.join("memory.json"),
            lock: Mutex::new(()),
        }
    }

    pub fn list(&self) -> Vec<Fact> {
        let _guard = self.lock.lock().unwrap();
        self.read()
    }

    fn read(&self) -> Vec<Fact> {
        fs::read(&self.path)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    }

    fn write(&self, facts: &[Fact]) -> std::io::Result<()> {
        if let Some(dir) = self.path.parent() {
            fs::create_dir_all(dir)?;
        }
        let tmp = self.path.with_extension("json.tmp");
        fs::write(&tmp, serde_json::to_vec_pretty(facts).unwrap_or_default())?;
        fs::rename(tmp, &self.path)
    }

    /// Saves a fact; a fact already saved isn't saved twice.
    pub fn remember(&self, text: &str, today: &str) -> Result<String, String> {
        let text: String = text.trim().chars().take(MAX_CHARS).collect();
        if text.is_empty() {
            return Err("Nothing to remember: text is empty.".into());
        }
        let _guard = self.lock.lock().unwrap();
        let mut facts = self.read();
        if let Some(f) = facts.iter().find(|f| f.text.eq_ignore_ascii_case(&text)) {
            return Ok(format!("Already remembered as {}.", f.id));
        }
        let id = format!("m{}", next_number(&facts));
        facts.push(Fact {
            id: id.clone(),
            text,
            date: today.into(),
        });
        let overflow = facts.len().saturating_sub(MAX_FACTS);
        facts.drain(..overflow);
        self.write(&facts)
            .map_err(|e| format!("Couldn't save: {e}"))?;
        Ok(format!("Remembered as {id}."))
    }

    /// Removes the fact with this id, or every fact containing this text.
    /// Returns how many went.
    pub fn forget(&self, what: &str) -> usize {
        let what = what.trim();
        if what.is_empty() {
            return 0;
        }
        let _guard = self.lock.lock().unwrap();
        let mut facts = self.read();
        let before = facts.len();
        let needle = what.to_lowercase();
        facts.retain(|f| f.id != what && !f.text.to_lowercase().contains(&needle));
        let gone = before - facts.len();
        if gone > 0 {
            let _ = self.write(&facts);
        }
        gone
    }

    pub fn clear(&self) {
        let _guard = self.lock.lock().unwrap();
        let _ = fs::remove_file(&self.path);
    }

    /// Runs a `memory` tool call.
    pub fn run(&self, input: &Value, today: &str) -> (Value, bool) {
        let text = input["text"].as_str().unwrap_or("");
        match input["action"].as_str().unwrap_or("") {
            "remember" => match self.remember(text, today) {
                Ok(s) => (json!(s), false),
                Err(e) => (json!(e), true),
            },
            "forget" => {
                let what = input["id"]
                    .as_str()
                    .filter(|s| !s.is_empty())
                    .unwrap_or(text);
                match self.forget(what) {
                    0 => (json!("Nothing matched, so nothing was forgotten."), true),
                    1 => (json!("Forgot 1 fact."), false),
                    n => (json!(format!("Forgot {n} facts.")), false),
                }
            }
            other => (json!(format!("Unknown memory action: {other}")), true),
        }
    }

    /// The system prompt's memory section.
    pub fn prompt(&self) -> String {
        let facts = self.list();
        let mut s = String::from(
            "\n\nYou remember things between conversations with the memory tool. When the user tells you \
something about themselves, their work or how they like things done that will matter in later \
conversations, or asks you to remember something, save it as one short fact in the third person \
(\"Prefers short answers.\"), without saying much about it. Don't save passwords, keys, card numbers \
or other secrets, or passing details of the current task. Forget a fact when the user asks or it is no \
longer true.",
        );
        if !facts.is_empty() {
            s.push_str("\nWhat you remember about the user (use it naturally, don't recite it):");
            for f in &facts {
                s.push_str(&format!("\n- [{}] {}", f.id, f.text));
            }
        }
        s
    }
}

fn next_number(facts: &[Fact]) -> u64 {
    facts
        .iter()
        .filter_map(|f| f.id.strip_prefix('m')?.parse::<u64>().ok())
        .max()
        .unwrap_or(0)
        + 1
}

/// The `memory` tool: available even with Mac access off, since it only
/// touches Cursor Pilot's own data.
pub fn tool() -> Value {
    json!({
        "name": "memory",
        "description": "Save or remove a fact you remember about the user across conversations. \
    Saved facts appear in your instructions in every later conversation, and the user can see and \
    delete them in Settings.",
        "input_schema": {
            "type": "object",
            "properties": {
                "action": {"type": "string", "enum": ["remember", "forget"]},
                "text": {"type": "string", "description": "remember: the fact, one short sentence. forget: text the fact contains."},
                "id": {"type": "string", "description": "forget: the fact's id, like m3."}
            },
            "required": ["action"]
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp() -> (Memory, PathBuf) {
        let dir = std::env::temp_dir().join(format!("cp-memory-{}", uuid::Uuid::new_v4()));
        (Memory::new(&dir), dir)
    }

    #[test]
    fn remembers_forgets_and_dedupes() {
        let (m, dir) = temp();
        assert!(m.prompt().contains("memory tool"));
        assert_eq!(
            m.remember("Name is Louis.", "2026-11-06").unwrap(),
            "Remembered as m1."
        );
        assert!(m
            .remember("name is louis.", "2026-11-06")
            .unwrap()
            .contains("Already"));
        m.remember("Prefers Norwegian replies.", "2026-11-06")
            .unwrap();
        assert!(m.prompt().contains("- [m2] Prefers Norwegian replies."));
        assert_eq!(m.forget("norwegian"), 1);
        assert_eq!(m.forget("m1"), 1);
        assert!(m.list().is_empty());
        m.remember("Uses DaVinci Resolve.", "2026-11-06").unwrap();
        assert_eq!(m.list()[0].id, "m1");
        m.clear();
        assert!(m.list().is_empty());
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn tool_calls() {
        let (m, dir) = temp();
        let (out, err) = m.run(
            &json!({"action": "remember", "text": "Has two monitors."}),
            "2026-11-06",
        );
        assert!(!err && out.as_str().unwrap().contains("m1"));
        let (_, err) = m.run(&json!({"action": "forget", "id": "m9"}), "2026-11-06");
        assert!(err);
        let (_, err) = m.run(&json!({"action": "forget", "id": "m1"}), "2026-11-06");
        assert!(!err);
        let _ = fs::remove_dir_all(dir);
    }
}
