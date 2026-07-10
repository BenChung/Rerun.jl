//! `rerun_query` — a C-ABI shim over Rerun's dataframe query engine
//! (`rerun::dataframe`), returning results as Arrow C Data Interface arrays for
//! zero-copy transfer into the `Rerun.jl` binding. See DESIGN.md.
//!
//! Phase 1 (this file): in-process `QueryEngine` over an in-memory `ChunkStore`.
//! Streaming forward cursor — `load → select → reader`, one batch per `next`.

use std::ffi::{CStr, CString, c_char};
use std::os::raw::c_int;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;

use arrow::array::{Array, StructArray};
use arrow::ffi::{FFI_ArrowArray, FFI_ArrowSchema};

use rerun::dataframe::{
    AbsoluteTimeRange, ChunkStoreConfig, EntityPath, QueryEngine, QueryExpression, QueryHandle,
    SparseFillStrategy, StorageEngine, TimelineName, ViewContentsSelector,
};

/// Coalescing bounds for a single `next` batch (whichever is hit first).
const MAX_BATCH_ROWS: usize = 65_536;
const MAX_BATCH_BYTES: usize = 256 * 1024 * 1024;

// ---------------------------------------------------------------------------
// error reporting — inline buffer, no allocation (mirrors rerun_c's rr_error)
// ---------------------------------------------------------------------------
pub const RRQ_OK: u32 = 0;
pub const RRQ_ERR_GENERIC: u32 = 1;
pub const RRQ_ERR_PANIC: u32 = 2;

#[repr(C)]
pub struct RrqError {
    pub code: u32,
    pub description: [c_char; 512],
}

fn set_error(err: *mut RrqError, code: u32, msg: &str) {
    if err.is_null() {
        return;
    }
    // SAFETY: caller-provided, non-null per the check above.
    let err = unsafe { &mut *err };
    err.code = code;
    let bytes = msg.as_bytes();
    let mut n = bytes.len().min(err.description.len() - 1);
    while n > 0 && !msg.is_char_boundary(n) {
        n -= 1; // don't truncate mid-codepoint
    }
    for i in 0..n {
        err.description[i] = bytes[i] as c_char;
    }
    err.description[n] = 0;
}

// ---------------------------------------------------------------------------
// opaque handles
// ---------------------------------------------------------------------------
pub struct RrqEngine {
    engine: QueryEngine<StorageEngine>,
    summary: CString, // one-line description for pretty-printing
    timelines: Vec<(CString, u32)>, // (name, RRQ_TIMELINE_* kind), engine-lifetime
}

pub struct RrqQuery {
    expr: QueryExpression,
}

pub struct RrqReader {
    handle: QueryHandle<StorageEngine>,
    schema: FFI_ArrowSchema, // owned; lent to the caller by `rrq_reader_schema`
}

// ---------------------------------------------------------------------------
/// Returns the crate version (NUL-terminated, `'static`). Borrowed — do not free.
#[no_mangle]
pub extern "C" fn rrq_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr() as *const c_char
}

// ---------------------------------------------------------------------------
// load
// ---------------------------------------------------------------------------
fn load_impl(path: &str) -> anyhow::Result<*mut RrqEngine> {
    let engines = QueryEngine::from_rrd_filepath(&ChunkStoreConfig::DEFAULT, path)?;
    let n = engines.len();
    if n != 1 {
        anyhow::bail!("expected exactly one recording in {path:?}, found {n}");
    }
    let engine = engines.into_values().next().expect("len checked == 1");
    let summary = describe(&engine);
    let timelines = timelines_of(&engine);
    Ok(Box::into_raw(Box::new(RrqEngine {
        engine,
        summary,
        timelines,
    })))
}

/// Timeline kind codes for `rrq_timeline_kind`.
pub const RRQ_TIMELINE_SEQUENCE: u32 = 0;
pub const RRQ_TIMELINE_DURATION: u32 = 1; // nanoseconds
pub const RRQ_TIMELINE_TIMESTAMP: u32 = 2; // nanoseconds since Unix epoch

fn timelines_of(engine: &QueryEngine<StorageEngine>) -> Vec<(CString, u32)> {
    use re_query::StorageEngineLike as _;
    use rerun::dataframe::external::re_log_types::TimeType;
    engine.engine.with(|store, _cache| {
        store
            .schema()
            .timelines()
            .values()
            .map(|tl| {
                let kind = match tl.typ() {
                    TimeType::Sequence => RRQ_TIMELINE_SEQUENCE,
                    TimeType::DurationNs => RRQ_TIMELINE_DURATION,
                    TimeType::TimestampNs => RRQ_TIMELINE_TIMESTAMP,
                };
                let name = CString::new(tl.name().to_string())
                    .unwrap_or_else(|_| CString::new("timeline").expect("no NUL"));
                (name, kind)
            })
            .collect()
    })
}

/// One-line recording description: `"app_id" (recording_id) — N entities, M timelines: ...`.
fn describe(engine: &QueryEngine<StorageEngine>) -> CString {
    use re_query::StorageEngineLike as _;
    let text = engine.engine.with(|store, _cache| {
        let id = store.id();
        let timelines = store.schema().timelines();
        let names: Vec<String> = timelines.keys().map(|t| t.to_string()).collect();
        format!(
            "{:?} ({}) — {} entities, {} timelines: {}",
            id.application_id().as_str(),
            id.recording_id().as_str(),
            store.all_entities().len(),
            names.len(),
            if names.is_empty() { "(none)".to_owned() } else { names.join(", ") },
        )
    });
    CString::new(text).unwrap_or_else(|_| CString::new("recording").expect("no NUL"))
}

/// Loads an `.rrd` and returns a handle to its single recording's query engine.
/// Returns null on error (e.g. file missing, or not exactly one recording).
#[no_mangle]
pub extern "C" fn rrq_load_recording(path: *const c_char, err: *mut RrqError) -> *mut RrqEngine {
    let res = catch_unwind(AssertUnwindSafe(|| -> anyhow::Result<*mut RrqEngine> {
        anyhow::ensure!(!path.is_null(), "null path");
        let path = unsafe { CStr::from_ptr(path) }.to_str()?;
        load_impl(path)
    }));
    match res {
        Ok(Ok(p)) => p,
        Ok(Err(e)) => {
            set_error(err, RRQ_ERR_GENERIC, &format!("{e:#}"));
            ptr::null_mut()
        }
        Err(_) => {
            set_error(err, RRQ_ERR_PANIC, "panic in rrq_load_recording");
            ptr::null_mut()
        }
    }
}

/// Borrows the recording's one-line summary (valid for the engine's lifetime).
#[no_mangle]
pub extern "C" fn rrq_recording_summary(engine: *const RrqEngine) -> *const c_char {
    match unsafe { engine.as_ref() } {
        Some(e) => e.summary.as_ptr(),
        None => ptr::null(),
    }
}

/// Number of index timelines in the recording.
#[no_mangle]
pub extern "C" fn rrq_timeline_count(engine: *const RrqEngine) -> usize {
    unsafe { engine.as_ref() }.map_or(0, |e| e.timelines.len())
}

/// Borrows the name of timeline `i` (valid for the engine's lifetime), or
/// null when `i` is out of range.
#[no_mangle]
pub extern "C" fn rrq_timeline_name(engine: *const RrqEngine, i: usize) -> *const c_char {
    match unsafe { engine.as_ref() }.and_then(|e| e.timelines.get(i)) {
        Some((name, _)) => name.as_ptr(),
        None => ptr::null(),
    }
}

/// Kind of timeline `i` (`RRQ_TIMELINE_*`), or `u32::MAX` when `i` is out of range.
#[no_mangle]
pub extern "C" fn rrq_timeline_kind(engine: *const RrqEngine, i: usize) -> u32 {
    match unsafe { engine.as_ref() }.and_then(|e| e.timelines.get(i)) {
        Some((_, kind)) => *kind,
        None => u32::MAX,
    }
}

#[no_mangle]
pub extern "C" fn rrq_engine_free(engine: *mut RrqEngine) {
    if !engine.is_null() {
        // SAFETY: produced by Box::into_raw in rrq_load_recording.
        drop(unsafe { Box::from_raw(engine) });
    }
}

// ---------------------------------------------------------------------------
// query builder
// ---------------------------------------------------------------------------
#[no_mangle]
pub extern "C" fn rrq_query_new() -> *mut RrqQuery {
    Box::into_raw(Box::new(RrqQuery {
        expr: QueryExpression::default(),
    }))
}

#[no_mangle]
pub extern "C" fn rrq_query_free(query: *mut RrqQuery) {
    if !query.is_null() {
        drop(unsafe { Box::from_raw(query) });
    }
}

/// Sets the index timeline that drives row generation.
#[no_mangle]
pub extern "C" fn rrq_query_set_index(query: *mut RrqQuery, timeline: *const c_char) {
    let Some(query) = (unsafe { query.as_mut() }) else { return };
    if timeline.is_null() {
        return;
    }
    let name = unsafe { CStr::from_ptr(timeline) }.to_string_lossy();
    query.expr.filtered_index = Some(TimelineName::new(name.as_ref()));
}

/// Restricts the view to the given entity paths (all components each).
/// `n == 0` selects everything.
#[no_mangle]
pub extern "C" fn rrq_query_set_contents(
    query: *mut RrqQuery,
    paths: *const *const c_char,
    n: usize,
) {
    let Some(query) = (unsafe { query.as_mut() }) else { return };
    if n == 0 || paths.is_null() {
        query.expr.view_contents = None;
        return;
    }
    let slice = unsafe { std::slice::from_raw_parts(paths, n) };
    let vcs: ViewContentsSelector = slice
        .iter()
        .filter(|&&p| !p.is_null())
        .map(|&p| {
            let s = unsafe { CStr::from_ptr(p) }.to_string_lossy();
            (EntityPath::parse_forgiving(s.as_ref()), None)
        })
        .collect();
    query.expr.view_contents = Some(vcs);
}

/// Restricts rows to the inclusive index range `[lo, hi]` on the index timeline.
#[no_mangle]
pub extern "C" fn rrq_query_filter_range(query: *mut RrqQuery, lo: i64, hi: i64) {
    let Some(query) = (unsafe { query.as_mut() }) else { return };
    query.expr.filtered_index_range = Some(AbsoluteTimeRange::new(lo, hi));
}

/// Forward-fills each column with its latest value at every index row.
#[no_mangle]
pub extern "C" fn rrq_query_fill_latest_at(query: *mut RrqQuery) {
    let Some(query) = (unsafe { query.as_mut() }) else { return };
    query.expr.sparse_fill_strategy = SparseFillStrategy::LatestAtGlobal;
}

// ---------------------------------------------------------------------------
// execute -> streaming reader
// ---------------------------------------------------------------------------
fn select_impl(engine: &RrqEngine, query: &RrqQuery) -> anyhow::Result<*mut RrqReader> {
    let handle = engine.engine.query(query.expr.clone());
    let schema = FFI_ArrowSchema::try_from(handle.schema().as_ref())?;
    Ok(Box::into_raw(Box::new(RrqReader { handle, schema })))
}

/// Runs the query and returns a forward cursor over result batches.
#[no_mangle]
pub extern "C" fn rrq_engine_select(
    engine: *const RrqEngine,
    query: *const RrqQuery,
    err: *mut RrqError,
) -> *mut RrqReader {
    let res = catch_unwind(AssertUnwindSafe(|| -> anyhow::Result<*mut RrqReader> {
        let engine = unsafe { engine.as_ref() }.ok_or_else(|| anyhow::anyhow!("null engine"))?;
        let query = unsafe { query.as_ref() }.ok_or_else(|| anyhow::anyhow!("null query"))?;
        select_impl(engine, query)
    }));
    match res {
        Ok(Ok(p)) => p,
        Ok(Err(e)) => {
            set_error(err, RRQ_ERR_GENERIC, &format!("{e:#}"));
            ptr::null_mut()
        }
        Err(_) => {
            set_error(err, RRQ_ERR_PANIC, "panic in rrq_engine_select");
            ptr::null_mut()
        }
    }
}

/// Borrows the result schema (struct of columns). Valid for the reader's life;
/// do not release it.
#[no_mangle]
pub extern "C" fn rrq_reader_schema(reader: *const RrqReader) -> *const FFI_ArrowSchema {
    match unsafe { reader.as_ref() } {
        Some(r) => &r.schema as *const FFI_ArrowSchema,
        None => ptr::null(),
    }
}

/// Writes the next batch (a struct array of columns) through `out` and returns 0.
/// Returns 1 at end of stream, or a negative code on error. Ownership of the
/// written array transfers to the caller (release it when done).
#[no_mangle]
pub extern "C" fn rrq_reader_next(
    reader: *mut RrqReader,
    out: *mut FFI_ArrowArray,
    err: *mut RrqError,
) -> c_int {
    let res = catch_unwind(AssertUnwindSafe(|| -> anyhow::Result<c_int> {
        let reader = unsafe { reader.as_mut() }.ok_or_else(|| anyhow::anyhow!("null reader"))?;
        anyhow::ensure!(!out.is_null(), "null out pointer");
        // Coalesce many engine rows into one batch (the engine otherwise emits
        // one row per index value).
        let batch = reader.handle.next_n_rows(MAX_BATCH_ROWS, MAX_BATCH_BYTES);
        if batch.num_rows == 0 {
            return Ok(1); // end of stream
        }
        let fields = reader.handle.schema().fields().clone();
        let array = StructArray::try_new(fields, batch.columns, None)?;
        // SAFETY: `out` is caller-allocated, uninitialized; move into it.
        unsafe { ptr::write(out, FFI_ArrowArray::new(&array.into_data())) };
        Ok(0)
    }));
    match res {
        Ok(Ok(code)) => code,
        Ok(Err(e)) => {
            set_error(err, RRQ_ERR_GENERIC, &format!("{e:#}"));
            -1
        }
        Err(_) => {
            set_error(err, RRQ_ERR_PANIC, "panic in rrq_reader_next");
            -1
        }
    }
}

#[no_mangle]
pub extern "C" fn rrq_reader_free(reader: *mut RrqReader) {
    if !reader.is_null() {
        drop(unsafe { Box::from_raw(reader) });
    }
}
