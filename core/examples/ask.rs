//! Asks Claude a question through the core, printing every event.
//!
//!   ANTHROPIC_API_KEY=sk-ant-… cargo run --example ask -- "Why is the sky blue?"

use std::sync::atomic::AtomicBool;

use cursor_pilot_core::claude::Settings;
use cursor_pilot_core::engine::{Engine, Request};

fn main() {
    let question = std::env::args().skip(1).collect::<Vec<_>>().join(" ");
    let engine = Engine::new(std::env::temp_dir().join("cursor-pilot-example"));
    *engine.settings.lock().unwrap() = Settings {
        api_key: std::env::var("ANTHROPIC_API_KEY").unwrap_or_default(),
        model: std::env::var("CP_MODEL").unwrap_or_else(|_| Settings::default().model),
        ..Settings::default()
    };
    let (id, _) = engine.next_request_id();
    let request = Request {
        text: question,
        screens: Vec::new(),
        sketch: false,
    };
    engine.run(id, &AtomicBool::new(false), request, &mut |event| {
        println!("{event}")
    });
}
