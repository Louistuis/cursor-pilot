//! Splits streamed reply text into sentences the app can speak as soon as
//! each one is complete, instead of waiting for the whole reply.

#[derive(Default)]
pub struct SentenceChunker {
    buf: String,
}

impl SentenceChunker {
    pub fn new() -> Self {
        Self::default()
    }

    /// Adds visible text and returns every sentence that is now complete.
    pub fn push(&mut self, text: &str) -> Vec<String> {
        self.buf.push_str(text);
        let mut out = Vec::new();
        while let Some(end) = sentence_end(&self.buf) {
            let sentence: String = self.buf.drain(..end).collect();
            if let Some(s) = clean(&sentence) {
                out.push(s);
            }
        }
        out
    }

    pub fn finish(&mut self) -> Option<String> {
        clean(&std::mem::take(&mut self.buf))
    }
}

/// Byte index just past the first sentence terminator that is followed by
/// whitespace (so "3.5" and "e.g.x" do not split), or past a newline.
fn sentence_end(s: &str) -> Option<usize> {
    let mut iter = s.char_indices().peekable();
    while let Some((i, c)) = iter.next() {
        if c == '\n' {
            return Some(i + 1);
        }
        if matches!(c, '.' | '!' | '?' | '…') {
            // Swallow runs like "?!" or "...".
            let mut end = i + c.len_utf8();
            while let Some(&(j, n)) = iter.peek() {
                if matches!(n, '.' | '!' | '?' | '…' | '"' | '\'' | ')' | '”' | '’') {
                    end = j + n.len_utf8();
                    iter.next();
                } else {
                    break;
                }
            }
            match iter.peek() {
                Some(&(_, n))
                    if n.is_whitespace()
                    // Require a little substance so "1. " list markers stay attached.
                    && s[..end].trim().chars().filter(|c| c.is_alphabetic()).count() >= 2 =>
                {
                    return Some(end);
                }
                _ => {}
            }
        }
    }
    None
}

/// Strips markdown punctuation that sounds odd when read aloud.
fn clean(s: &str) -> Option<String> {
    let mut t = s.trim().to_string();
    for prefix in ["- ", "* ", "• "] {
        if let Some(rest) = t.strip_prefix(prefix) {
            t = rest.to_string();
        }
    }
    let t: String = t
        .chars()
        .filter(|c| !matches!(c, '*' | '`' | '#' | '_'))
        .collect();
    let t = t.trim();
    if t.chars().any(|c| c.is_alphanumeric()) {
        Some(t.to_string())
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_on_sentence_boundaries() {
        let mut c = SentenceChunker::new();
        assert_eq!(c.push("Open the menu. Then cli"), vec!["Open the menu."]);
        assert_eq!(c.push("ck **Save**! Done"), vec!["Then click Save!"]);
        assert_eq!(c.finish().as_deref(), Some("Done"));
    }

    #[test]
    fn keeps_decimals_together() {
        let mut c = SentenceChunker::new();
        assert!(c.push("Version 3.5 is out").is_empty());
        assert_eq!(c.finish().as_deref(), Some("Version 3.5 is out"));
    }

    #[test]
    fn newline_ends_a_chunk() {
        let mut c = SentenceChunker::new();
        assert_eq!(c.push("- first step\n- second"), vec!["first step"]);
    }
}
