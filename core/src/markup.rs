//! Streaming filter that pulls mark-up tags out of the model's reply.
//!
//! The model is asked to show things on screen by writing tags inline, e.g.
//! `<point x="412" y="230" screen="0" label="Save button"/>`,
//! `<circle x="412" y="230" r="40" screen="0"/>`,
//! `<arrow x1="100" y1="80" x2="412" y2="230" screen="0"/>` or
//! `<box x="380" y="210" w="80" h="40" screen="0"/>`, plus `<underline>`,
//! `<highlight>`, `<trace>`, `<note>`, `<spotlight>`, `<check>`, `<cross>`,
//! `<step>` and `<bracket>`. The whiteboard has `<board>`, `<card>`,
//! `<link>` and `<write>` (and takes the other shapes with
//! `screen="board"`); `<focus>` turns the 3D view to one of its parts.
//! Text arrives in arbitrary chunks, so a tag can be split across deltas; the
//! filter holds back anything that might still become a tag and releases it
//! as plain text once it clearly is not one.

use std::collections::HashMap;

/// Longest run we hold back while waiting for a tag to close.
const MAX_TAG_LEN: usize = 600;
const TAG_NAMES: [&str; 18] = [
    "point",
    "circle",
    "arrow",
    "box",
    "underline",
    "highlight",
    "trace",
    "note",
    "spotlight",
    "check",
    "cross",
    "step",
    "bracket",
    "board",
    "card",
    "link",
    "write",
    "focus",
];

/// The `screen` of a mark on the whiteboard: its coordinates are the
/// board's own, `BOARD_W` by `BOARD_H`, not a screenshot's.
pub const BOARD: usize = usize::MAX;
pub const BOARD_W: f64 = 1000.0;
pub const BOARD_H: f64 = 600.0;
/// Most points kept from a trace.
const MAX_TRACE_POINTS: usize = 40;
/// Ring radius, in screenshot pixels, when a circle tag gives none.
const DEFAULT_RADIUS: f64 = 36.0;

/// A shape in screenshot pixel coordinates.
#[derive(Debug, Clone, PartialEq)]
pub enum Shape {
    /// Fly the cursor buddy here.
    Point { x: f64, y: f64 },
    /// Draw a ring around something.
    Circle { x: f64, y: f64, r: f64 },
    /// Draw an arrow from the first point to the second.
    Arrow { x1: f64, y1: f64, x2: f64, y2: f64 },
    /// Highlight a rectangle; x, y is its top-left corner.
    Box { x: f64, y: f64, w: f64, h: f64 },
    /// A marker line under text, from x, y across w.
    Underline { x: f64, y: f64, w: f64 },
    /// A translucent highlighter swipe over a rectangle.
    Highlight { x: f64, y: f64, w: f64, h: f64 },
    /// A freehand line through points, e.g. tracing a route or an outline.
    Trace { points: Vec<(f64, f64)> },
    /// A sticky note with a few words, pinned at x, y.
    Note { x: f64, y: f64, text: String },
    /// Dims everything but a rectangle, to make the eye go there.
    Spotlight { x: f64, y: f64, w: f64, h: f64 },
    /// A tick: this one, or this is right.
    Check { x: f64, y: f64 },
    /// A cross: not this, or this is wrong.
    Cross { x: f64, y: f64 },
    /// A numbered badge, for steps in order.
    Step { x: f64, y: f64, n: u32 },
    /// A curly bracket down the left of a span from y to y + h, grouping it.
    Bracket { x: f64, y: f64, h: f64 },
    /// Opens a fresh whiteboard with a title.
    Board { title: String },
    /// A box with a few words (and an SF Symbol) on the board, which links join.
    Card { id: String, x: f64, y: f64, text: String, icon: String },
    /// An arrow from one card to another, with a few words on it.
    Link { from: String, to: String, text: String },
    /// Handwritten text on the board; size is "title", "body" or "small".
    Write { x: f64, y: f64, text: String, size: String },
    /// Turns the 3D view to one of its parts.
    Focus { id: String },
}

#[derive(Debug, Clone, PartialEq)]
pub struct Mark {
    pub shape: Shape,
    pub screen: usize,
    pub label: String,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Piece {
    Text(String),
    Mark(Mark),
}

#[derive(Default)]
pub struct MarkupFilter {
    held: String,
}

/// How a held run starting with '<' relates to the known tags.
enum Candidate {
    /// Could still become a tag once more text arrives.
    Undecided,
    /// Opens a known tag; wait for its '>'.
    Tag,
    /// Not a tag.
    Text,
}

fn classify(s: &str) -> Candidate {
    let rest = &s[1..];
    for name in TAG_NAMES {
        if name.len() >= rest.len() {
            if name.starts_with(rest) {
                return Candidate::Undecided;
            }
        } else if let Some(after) = rest.strip_prefix(name) {
            let next = after.chars().next().unwrap_or(' ');
            if next.is_whitespace() || next == '/' || next == '>' {
                return Candidate::Tag;
            }
        }
    }
    Candidate::Text
}

impl MarkupFilter {
    pub fn new() -> Self {
        Self::default()
    }

    /// Feeds a chunk and returns the pieces that are now settled.
    pub fn push(&mut self, chunk: &str) -> Vec<Piece> {
        self.held.push_str(chunk);
        let mut out = Vec::new();
        loop {
            let Some(lt) = self.held.find('<') else {
                emit_text(&mut out, std::mem::take(&mut self.held));
                break;
            };
            if lt > 0 {
                let text: String = self.held.drain(..lt).collect();
                emit_text(&mut out, text);
            }
            // `held` now starts with '<'.
            match classify(&self.held) {
                Candidate::Undecided => break,
                Candidate::Text => self.release_one_char(&mut out),
                Candidate::Tag => match self.held.find('>') {
                    Some(gt) => {
                        let tag: String = self.held.drain(..=gt).collect();
                        match parse_mark(&tag) {
                            Some(m) => out.push(Piece::Mark(m)),
                            None => emit_text(&mut out, tag),
                        }
                    }
                    None if self.held.len() > MAX_TAG_LEN => self.release_one_char(&mut out),
                    None => break,
                },
            }
        }
        out
    }

    /// Flushes whatever is still held as plain text.
    pub fn finish(&mut self) -> Vec<Piece> {
        let mut out = Vec::new();
        emit_text(&mut out, std::mem::take(&mut self.held));
        out
    }

    fn release_one_char(&mut self, out: &mut Vec<Piece>) {
        let c = self.held.remove(0);
        emit_text(out, c.to_string());
    }
}

fn emit_text(out: &mut Vec<Piece>, text: String) {
    if text.is_empty() {
        return;
    }
    if let Some(Piece::Text(last)) = out.last_mut() {
        last.push_str(&text);
    } else {
        out.push(Piece::Text(text));
    }
}

fn parse_mark(tag: &str) -> Option<Mark> {
    let body = tag.strip_prefix('<')?;
    let name: String = body
        .chars()
        .take_while(|c| c.is_ascii_alphabetic())
        .collect();
    let attrs = parse_attrs(&body[name.len()..]);
    let num = |k: &str| {
        attrs
            .get(k)
            .and_then(|v| v.trim().parse::<f64>().ok())
            .filter(|v| v.is_finite())
    };
    let text = |k: &str, n: usize| -> Option<String> {
        attrs
            .get(k)
            .map(|t| t.trim().chars().take(n).collect::<String>())
            .filter(|t| !t.is_empty())
    };
    let on_board = attrs.get("screen").is_some_and(|s| s.trim() == "board");
    let shape = match name.as_str() {
        "point" => Shape::Point {
            x: num("x")?,
            y: num("y")?,
        },
        "circle" => Shape::Circle {
            x: num("x")?,
            y: num("y")?,
            r: num("r").filter(|r| *r > 0.0).unwrap_or(DEFAULT_RADIUS),
        },
        "arrow" => Shape::Arrow {
            x1: num("x1")?,
            y1: num("y1")?,
            x2: num("x2")?,
            y2: num("y2")?,
        },
        "box" => Shape::Box {
            x: num("x")?,
            y: num("y")?,
            w: num("w").filter(|w| *w > 0.0)?,
            h: num("h").filter(|h| *h > 0.0)?,
        },
        "underline" => Shape::Underline {
            x: num("x")?,
            y: num("y")?,
            w: num("w").filter(|w| *w > 0.0)?,
        },
        "highlight" => Shape::Highlight {
            x: num("x")?,
            y: num("y")?,
            w: num("w").filter(|w| *w > 0.0)?,
            h: num("h").filter(|h| *h > 0.0)?,
        },
        "trace" => {
            let points: Vec<(f64, f64)> = attrs
                .get("points")?
                .split_whitespace()
                .filter_map(|pair| {
                    let (x, y) = pair.split_once(',')?;
                    Some((x.trim().parse().ok()?, y.trim().parse().ok()?))
                })
                .filter(|(x, y): &(f64, f64)| x.is_finite() && y.is_finite())
                .take(MAX_TRACE_POINTS)
                .collect();
            if points.len() < 2 {
                return None;
            }
            Shape::Trace { points }
        }
        "note" => Shape::Note {
            x: num("x")?,
            y: num("y")?,
            text: attrs
                .get("text")
                .filter(|t| !t.trim().is_empty())?
                .chars()
                .take(120)
                .collect(),
        },
        "spotlight" => Shape::Spotlight {
            x: num("x")?,
            y: num("y")?,
            w: num("w").filter(|w| *w > 0.0)?,
            h: num("h").filter(|h| *h > 0.0)?,
        },
        "check" => Shape::Check {
            x: num("x")?,
            y: num("y")?,
        },
        "cross" => Shape::Cross {
            x: num("x")?,
            y: num("y")?,
        },
        "step" => Shape::Step {
            x: num("x")?,
            y: num("y")?,
            n: num("n").map(|n| n.clamp(1.0, 99.0) as u32).unwrap_or(1),
        },
        "bracket" => Shape::Bracket {
            x: num("x")?,
            y: num("y")?,
            h: num("h").filter(|h| *h > 0.0)?,
        },
        "board" => Shape::Board {
            title: text("title", 80).unwrap_or_default(),
        },
        "card" => Shape::Card {
            id: text("id", 40)?,
            x: num("x")?,
            y: num("y")?,
            text: text("text", 60)?,
            icon: text("icon", 60).unwrap_or_default(),
        },
        "link" => Shape::Link {
            from: text("from", 40)?,
            to: text("to", 40)?,
            text: text("text", 40).unwrap_or_default(),
        },
        "write" => Shape::Write {
            x: num("x")?,
            y: num("y")?,
            text: text("text", 200)?,
            size: text("size", 10).unwrap_or_else(|| "body".into()),
        },
        "focus" => Shape::Focus { id: text("id", 40)? },
        _ => return None,
    };
    let board_only = matches!(
        shape,
        Shape::Board { .. } | Shape::Card { .. } | Shape::Link { .. } | Shape::Write { .. }
    );
    Some(Mark {
        shape,
        screen: if on_board || board_only {
            BOARD
        } else {
            num("screen").map(|s| s.max(0.0) as usize).unwrap_or(0)
        },
        label: attrs.get("label").cloned().unwrap_or_default(),
    })
}

/// Parses `key="value"` / `key='value'` / `key=value` pairs.
fn parse_attrs(s: &str) -> HashMap<String, String> {
    let mut attrs = HashMap::new();
    let chars: Vec<char> = s.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        while i < chars.len() && !chars[i].is_alphanumeric() {
            i += 1;
        }
        let key_start = i;
        while i < chars.len() && (chars[i].is_alphanumeric() || chars[i] == '_') {
            i += 1;
        }
        let key: String = chars[key_start..i].iter().collect();
        while i < chars.len() && chars[i].is_whitespace() {
            i += 1;
        }
        if key.is_empty() || i >= chars.len() || chars[i] != '=' {
            continue;
        }
        i += 1;
        while i < chars.len() && chars[i].is_whitespace() {
            i += 1;
        }
        let value: String = if i < chars.len() && (chars[i] == '"' || chars[i] == '\'') {
            let quote = chars[i];
            i += 1;
            let start = i;
            while i < chars.len() && chars[i] != quote {
                i += 1;
            }
            let v = chars[start..i.min(chars.len())].iter().collect();
            i += 1;
            v
        } else {
            let start = i;
            while i < chars.len() && !chars[i].is_whitespace() && chars[i] != '/' && chars[i] != '>'
            {
                i += 1;
            }
            chars[start..i].iter().collect()
        };
        attrs.insert(key.to_ascii_lowercase(), value);
    }
    attrs
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(chunks: &[&str]) -> Vec<Piece> {
        let mut f = MarkupFilter::new();
        let mut all = Vec::new();
        for c in chunks {
            for p in f.push(c) {
                emit_merge(&mut all, p);
            }
        }
        for p in f.finish() {
            emit_merge(&mut all, p);
        }
        all
    }

    fn emit_merge(all: &mut Vec<Piece>, p: Piece) {
        match p {
            Piece::Text(t) => emit_text(all, t),
            other => all.push(other),
        }
    }

    #[test]
    fn whiteboard_and_new_marks() {
        let got = run(&[
            "<board title=\"How DNS works\"/>A <card id=\"pc\" x=\"120\" y=\"300\" text=\"Your Mac\" icon=\"laptopcomputer\"/>",
            "<link from=\"pc\" to=\"dns\" text=\"asks\"/><circle x=\"500\" y=\"300\" r=\"60\" screen=\"board\"/>",
            "<step x=\"10\" y=\"20\" n=\"2\" screen=\"1\"/><focus id=\"nucleus\"/>",
        ]);
        let marks: Vec<&Mark> = got
            .iter()
            .filter_map(|p| match p {
                Piece::Mark(m) => Some(m),
                _ => None,
            })
            .collect();
        assert_eq!(marks.len(), 6);
        assert_eq!(marks[0].shape, Shape::Board { title: "How DNS works".into() });
        assert_eq!(marks[0].screen, BOARD);
        assert!(matches!(&marks[1].shape, Shape::Card { id, icon, .. } if id == "pc" && icon == "laptopcomputer"));
        assert_eq!(marks[3].screen, BOARD);
        assert_eq!(marks[4].shape, Shape::Step { x: 10.0, y: 20.0, n: 2 });
        assert_eq!(marks[4].screen, 1);
        assert_eq!(marks[5].shape, Shape::Focus { id: "nucleus".into() });
    }

    #[test]
    fn plain_text_passes_through() {
        assert_eq!(
            run(&["Hello ", "there"]),
            vec![Piece::Text("Hello there".into())]
        );
    }

    #[test]
    fn tag_split_across_chunks() {
        let got = run(&[
            "Click it <po",
            "int x=\"10\" y='20' scr",
            "een=\"1\" label=\"Save\"/> now",
        ]);
        assert_eq!(
            got,
            vec![
                Piece::Text("Click it ".into()),
                Piece::Mark(Mark {
                    shape: Shape::Point { x: 10.0, y: 20.0 },
                    screen: 1,
                    label: "Save".into()
                }),
                Piece::Text(" now".into()),
            ]
        );
    }

    #[test]
    fn less_than_that_is_not_a_tag() {
        assert_eq!(
            run(&["a < b and <p>x"]),
            vec![Piece::Text("a < b and <p>x".into())]
        );
    }

    #[test]
    fn malformed_tag_is_kept_as_text() {
        assert_eq!(
            run(&["<point y=\"2\"/>"]),
            vec![Piece::Text("<point y=\"2\"/>".into())]
        );
    }

    #[test]
    fn unclosed_tag_is_flushed_at_end() {
        assert_eq!(
            run(&["see <point x=1"]),
            vec![Piece::Text("see <point x=1".into())]
        );
    }

    #[test]
    fn parses_every_shape() {
        let got = run(&[
            "<circle x=\"5\" y=\"6\" r=\"7\"/>",
            "<arrow x1=\"1\" y1=\"2\" x2=\"3\" y2=\"4\" screen=\"2\" label=\"drag\"/>",
            "<box x=\"1\" y=\"2\" w=\"30\" h=\"40\"/>",
            "<circle x=\"1\" y=\"1\"/>",
        ]);
        let shapes: Vec<_> = got
            .into_iter()
            .map(|p| match p {
                Piece::Mark(m) => (m.shape, m.screen),
                other => panic!("unexpected {other:?}"),
            })
            .collect();
        assert_eq!(
            shapes,
            vec![
                (
                    Shape::Circle {
                        x: 5.0,
                        y: 6.0,
                        r: 7.0
                    },
                    0
                ),
                (
                    Shape::Arrow {
                        x1: 1.0,
                        y1: 2.0,
                        x2: 3.0,
                        y2: 4.0
                    },
                    2
                ),
                (
                    Shape::Box {
                        x: 1.0,
                        y: 2.0,
                        w: 30.0,
                        h: 40.0
                    },
                    0
                ),
                (
                    Shape::Circle {
                        x: 1.0,
                        y: 1.0,
                        r: DEFAULT_RADIUS
                    },
                    0
                ),
            ]
        );
    }

    #[test]
    fn similar_words_stay_text() {
        assert_eq!(
            run(&["<boxes> and <arrows"]),
            vec![Piece::Text("<boxes> and <arrows".into())]
        );
        assert_eq!(run(&["<box w=\"0\" h=\"1\" x=\"1\" y=\"1\"/>"]).len(), 1);
    }

    #[test]
    fn parses_new_drawing_tags() {
        let mut f = MarkupFilter::new();
        let mut pieces = f.push(
            r#"Here <underline x="10" y="20" w="80"/> and <highlight x="1" y="2" w="3" h="4"/>"#,
        );
        pieces.extend(f.push(
            r#" path <trace points="0,0 10,5 20,0"/> <note x="5" y="6" text="Click here first"/>"#,
        ));
        pieces.extend(f.finish());
        let shapes: Vec<Shape> = pieces
            .into_iter()
            .filter_map(|p| match p {
                Piece::Mark(m) => Some(m.shape),
                _ => None,
            })
            .collect();
        assert_eq!(
            shapes,
            vec![
                Shape::Underline {
                    x: 10.0,
                    y: 20.0,
                    w: 80.0
                },
                Shape::Highlight {
                    x: 1.0,
                    y: 2.0,
                    w: 3.0,
                    h: 4.0
                },
                Shape::Trace {
                    points: vec![(0.0, 0.0), (10.0, 5.0), (20.0, 0.0)]
                },
                Shape::Note {
                    x: 5.0,
                    y: 6.0,
                    text: "Click here first".into()
                },
            ]
        );
    }
}
