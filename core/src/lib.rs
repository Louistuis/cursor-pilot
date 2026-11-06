//! Cursor Pilot core, exposed to the Swift app over a small C ABI.
//!
//! Everything crosses the boundary as UTF-8 JSON strings. Requests run on a
//! background thread and report back through a callback; the final event of
//! every request is `{"type":"finished"}`, after which the callback is never
//! called again for that request, so the caller can release its context.
//!
//! # Safety
//!
//! Every pointer argument must be null or valid for the duration of the call:
//! `core` must come from `cp_core_new` and not yet be freed, and strings must
//! be NUL-terminated UTF-8.
#![allow(clippy::missing_safety_doc)]

pub mod agent;
pub mod claude;
pub mod conversation;
pub mod drawings;
pub mod engine;
pub mod markup;
pub mod memory;
pub mod speech;

use std::ffi::{c_char, c_void, CStr, CString};
use std::path::PathBuf;
use std::sync::Arc;

use claude::Settings;
use engine::{Engine, Request};
use serde_json::{json, Value};

pub type EventCallback = extern "C" fn(ctx: *mut c_void, event_json: *const c_char);

pub struct CPCore {
    engine: Arc<Engine>,
}

struct SendPtr(*mut c_void);
// The Swift side owns the context and guarantees it outlives the request.
unsafe impl Send for SendPtr {}
unsafe impl Sync for SendPtr {}

impl SendPtr {
    /// Through a method, so closures capture the whole (sendable) wrapper.
    fn get(&self) -> *mut c_void {
        self.0
    }
}

unsafe fn str_arg<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() {
        None
    } else {
        CStr::from_ptr(p).to_str().ok()
    }
}

fn into_c(s: String) -> *mut c_char {
    CString::new(s.replace('\0', ""))
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}

/// `config_json`: `{"data_dir": "/path"}`. Returns null on bad input.
#[no_mangle]
pub unsafe extern "C" fn cp_core_new(config_json: *const c_char) -> *mut CPCore {
    let Some(v) = str_arg(config_json).and_then(|s| serde_json::from_str::<Value>(s).ok()) else {
        return std::ptr::null_mut();
    };
    let Some(dir) = v["data_dir"].as_str() else {
        return std::ptr::null_mut();
    };
    Box::into_raw(Box::new(CPCore {
        engine: Engine::shared(PathBuf::from(dir)),
    }))
}

#[no_mangle]
pub unsafe extern "C" fn cp_core_free(core: *mut CPCore) {
    if !core.is_null() {
        drop(Box::from_raw(core));
    }
}

/// Replaces the settings (api_key, model, effort, base_url, max_tokens).
/// Returns false on bad JSON.
#[no_mangle]
pub unsafe extern "C" fn cp_core_configure(
    core: *mut CPCore,
    settings_json: *const c_char,
) -> bool {
    let (Some(core), Some(s)) = (core.as_ref(), str_arg(settings_json)) else {
        return false;
    };
    let Ok(settings) = serde_json::from_str::<Settings>(s) else {
        return false;
    };
    *core.engine.settings.lock().unwrap() = settings;
    true
}

/// Starts a request; returns its id (0 on bad input, after reporting an
/// error and `finished` through the callback).
#[no_mangle]
pub unsafe extern "C" fn cp_core_send(
    core: *mut CPCore,
    request_json: *const c_char,
    callback: EventCallback,
    ctx: *mut c_void,
) -> u64 {
    let emit_now = |v: Value| {
        let c = CString::new(v.to_string()).unwrap_or_default();
        callback(ctx, c.as_ptr());
    };
    let Some(core) = core.as_ref() else {
        emit_now(json!({"type": "error", "kind": "protocol", "message": "core is null"}));
        emit_now(json!({"type": "finished", "id": 0}));
        return 0;
    };
    let request = match str_arg(request_json).map(serde_json::from_str::<Request>) {
        Some(Ok(r)) => r,
        _ => {
            emit_now(json!({"type": "error", "kind": "protocol", "message": "bad request JSON"}));
            emit_now(json!({"type": "finished", "id": 0}));
            return 0;
        }
    };
    let engine = core.engine.clone();
    let (id, cancel) = engine.next_request_id();
    let ctx = SendPtr(ctx);
    std::thread::Builder::new()
        .name(format!("cursor-pilot-request-{id}"))
        .spawn(move || {
            let ctx = ctx;
            let mut emit = |v: Value| {
                let c = CString::new(v.to_string()).unwrap_or_default();
                callback(ctx.0, c.as_ptr());
            };
            engine.run(id, &cancel, request, &mut emit);
        })
        .expect("spawn request thread");
    id
}

/// Registers the app's agent host (screen, mouse and keyboard), or
/// removes it when `host` is null. See `agent::HostFn` for the protocol.
#[no_mangle]
pub unsafe extern "C" fn cp_core_set_host(
    core: *mut CPCore,
    host: Option<agent::HostFn>,
    ctx: *mut c_void,
) {
    if let Some(core) = core.as_ref() {
        *core.engine.host.lock().unwrap() = host.map(|f| Arc::new(agent::Host { f, ctx }));
    }
}

/// Background tasks report through `callback` (null: nowhere) as `job`
/// events: `start`, `step`, `note` and `end` (with the report), outside any
/// request and on any thread.
#[no_mangle]
pub unsafe extern "C" fn cp_core_set_job_callback(
    core: *mut CPCore,
    callback: Option<EventCallback>,
    ctx: *mut c_void,
) {
    let Some(core) = core.as_ref() else { return };
    let sink = callback.map(|callback| {
        let ctx = SendPtr(ctx);
        Arc::new(move |v: Value| {
            let c = CString::new(v.to_string()).unwrap_or_default();
            callback(ctx.get(), c.as_ptr());
        }) as engine::JobSink
    });
    core.engine.set_job_sink(sink);
}

/// Stops a background task by its agent number; false when none is running.
#[no_mangle]
pub unsafe extern "C" fn cp_core_stop_job(core: *mut CPCore, job: u64) -> bool {
    core.as_ref().is_some_and(|c| c.engine.stop_job(job as usize))
}

/// Cancels one request, or every running request when `id` is 0.
#[no_mangle]
pub unsafe extern "C" fn cp_core_cancel(core: *mut CPCore, id: u64) {
    if let Some(core) = core.as_ref() {
        core.engine.cancel(id);
    }
}

#[no_mangle]
pub unsafe extern "C" fn cp_core_new_conversation(core: *mut CPCore) {
    if let Some(core) = core.as_ref() {
        core.engine.new_conversation();
    }
}

/// JSON string of the live conversation id. Free with `cp_string_free`.
#[no_mangle]
pub unsafe extern "C" fn cp_core_current_conversation(core: *mut CPCore) -> *mut c_char {
    match core.as_ref() {
        Some(core) => into_c(json!(core.engine.current_conversation_id()).to_string()),
        None => std::ptr::null_mut(),
    }
}

/// JSON array of saved conversation summaries, newest first.
#[no_mangle]
pub unsafe extern "C" fn cp_core_list_conversations(core: *mut CPCore) -> *mut c_char {
    match core.as_ref() {
        Some(core) => into_c(
            serde_json::to_string(&core.engine.store().list()).unwrap_or_else(|_| "[]".into()),
        ),
        None => std::ptr::null_mut(),
    }
}

/// JSON transcript for `id`, or `null` when it does not exist.
#[no_mangle]
pub unsafe extern "C" fn cp_core_load_conversation(
    core: *mut CPCore,
    id: *const c_char,
) -> *mut c_char {
    let (Some(core), Some(id)) = (core.as_ref(), str_arg(id)) else {
        return std::ptr::null_mut();
    };
    let t = core.engine.store().load(id);
    into_c(serde_json::to_string(&t).unwrap_or_else(|_| "null".into()))
}

#[no_mangle]
pub unsafe extern "C" fn cp_core_delete_conversation(core: *mut CPCore, id: *const c_char) {
    if let (Some(core), Some(id)) = (core.as_ref(), str_arg(id)) {
        if core.engine.current_conversation_id() == id {
            core.engine.new_conversation();
        }
        core.engine.store().delete(id);
    }
}

/// Makes the saved conversation `id` the live one, so the next question
/// continues it. Returns false when it does not exist.
#[no_mangle]
pub unsafe extern "C" fn cp_core_resume_conversation(core: *mut CPCore, id: *const c_char) -> bool {
    match (core.as_ref(), str_arg(id)) {
        (Some(core), Some(id)) => core.engine.resume_conversation(id),
        _ => false,
    }
}

#[no_mangle]
pub unsafe extern "C" fn cp_core_rename_conversation(
    core: *mut CPCore,
    id: *const c_char,
    title: *const c_char,
) {
    if let (Some(core), Some(id), Some(title)) = (core.as_ref(), str_arg(id), str_arg(title)) {
        core.engine.rename_conversation(id, title);
    }
}

/// Saves `len` bytes of PNG as a drawing; returns its JSON record, or `null`.
#[no_mangle]
pub unsafe extern "C" fn cp_core_save_drawing(
    core: *mut CPCore,
    png: *const u8,
    len: usize,
    title: *const c_char,
) -> *mut c_char {
    let Some(core) = core.as_ref() else {
        return std::ptr::null_mut();
    };
    if png.is_null() {
        return into_c("null".into());
    }
    let bytes = std::slice::from_raw_parts(png, len);
    let saved = core
        .engine
        .drawings()
        .save(bytes, str_arg(title).unwrap_or(""));
    into_c(
        saved
            .ok()
            .and_then(|d| serde_json::to_string(&d).ok())
            .unwrap_or_else(|| "null".into()),
    )
}

/// JSON array of saved drawings, newest first.
#[no_mangle]
pub unsafe extern "C" fn cp_core_list_drawings(core: *mut CPCore) -> *mut c_char {
    match core.as_ref() {
        Some(core) => into_c(
            serde_json::to_string(&core.engine.drawings().list()).unwrap_or_else(|_| "[]".into()),
        ),
        None => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn cp_core_delete_drawing(core: *mut CPCore, id: *const c_char) {
    if let (Some(core), Some(id)) = (core.as_ref(), str_arg(id)) {
        core.engine.drawings().delete(id);
    }
}

/// Opens a connection to the API in the background, ahead of a request.
#[no_mangle]
pub unsafe extern "C" fn cp_core_warm(core: *mut CPCore) {
    if let Some(core) = core.as_ref() {
        claude::warm(&core.engine.base_url());
    }
}

/// JSON array of facts Claude remembers about the user, oldest first.
#[no_mangle]
pub unsafe extern "C" fn cp_core_list_memory(core: *mut CPCore) -> *mut c_char {
    match core.as_ref() {
        Some(core) => into_c(
            serde_json::to_string(&core.engine.memory().list()).unwrap_or_else(|_| "[]".into()),
        ),
        None => std::ptr::null_mut(),
    }
}

/// Forgets the fact `id`, or every fact when `id` is null.
#[no_mangle]
pub unsafe extern "C" fn cp_core_forget_memory(core: *mut CPCore, id: *const c_char) {
    let Some(core) = core.as_ref() else { return };
    match str_arg(id) {
        Some(id) => {
            core.engine.memory().forget(id);
        }
        None => core.engine.memory().clear(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn cp_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}

#[no_mangle]
pub extern "C" fn cp_core_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr() as *const c_char
}
