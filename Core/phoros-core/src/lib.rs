//! The realtime core behind Phoros 2, behind a C ABI.
//!
//! Sans-IO: the core never touches a socket, a clock or a thread. The Swift side owns all
//! three and drives the core with `feed` (bytes arrived), `poll` (what to do next) and the
//! time it passes in. Every entry point is `extern "C"`, takes a handle, and catches panics
//! at the boundary: a Rust panic becomes an error status, never an unwind into Swift.
//!
//! This is the phase 3 spike (BEAM-52): the toolchain, the boundary, the ownership rules
//! and their tests. The state machine inside is a placeholder that acknowledges what it is
//! fed, with str0m linked in so the real one has somewhere to go.

use std::ffi::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;

/// Status of every call. Zero is success.
pub const PHOROS_OK: i32 = 0;
pub const PHOROS_ERR_NULL: i32 = 1;
pub const PHOROS_ERR_TOO_LARGE: i32 = 2;
pub const PHOROS_ERR_PANIC: i32 = 3;
pub const PHOROS_ERR_POISONED: i32 = 4;
pub const PHOROS_ERR_DESTROYED: i32 = 5;

/// Largest datagram the core accepts. Anything above is refused, not truncated.
pub const PHOROS_MAX_DATAGRAM: usize = 65_535;

/// What `poll` asks the caller to do next.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PhorosPollKind {
    /// Nothing to do until new input or the timeout.
    Idle = 0,
    /// Send `buffer[..len]`. The buffer is owned by the core and valid until the next call
    /// on this handle.
    Transmit = 1,
    /// Call `poll` again no later than `at_us` (the caller's clock, microseconds).
    Timeout = 2,
}

#[repr(C)]
pub struct PhorosPoll {
    pub kind: PhorosPollKind,
    pub buffer: *const u8,
    pub len: usize,
    pub at_us: i64,
}

/// Called on the caller's thread of the call that triggered it, never from a thread the
/// core owns (it owns none). `user` is what was passed at create.
pub type PhorosEventCallback = Option<unsafe extern "C" fn(user: *mut c_void, kind: u32, value: i64)>;

pub const PHOROS_EVENT_FED: u32 = 1;
pub const PHOROS_EVENT_DESTROYING: u32 = 2;

struct Inner {
    user: *mut c_void,
    on_event: PhorosEventCallback,
    fed_bytes: u64,
    fed_datagrams: u64,
    /// Pending acknowledgement, handed out by `poll` and owned by the core.
    outbox: Vec<u8>,
    last_now_us: i64,
    destroyed: bool,
    // str0m linked in and exercised, so an iOS build of it is part of the spike's proof.
    _rtc_built: bool,
}

// The pointer in `user` is opaque to the core; it never dereferences it.
unsafe impl Send for Inner {}

pub struct PhorosCore {
    inner: Mutex<Inner>,
}

static LIVE_HANDLES: AtomicUsize = AtomicUsize::new(0);

fn guard<T>(f: impl FnOnce() -> Result<T, i32>) -> Result<T, i32> {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(r) => r,
        Err(_) => Err(PHOROS_ERR_PANIC),
    }
}

/// The crate version, as a static C string.
#[no_mangle]
pub extern "C" fn phoros_core_version() -> *const u8 {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr()
}

/// Number of handles alive, for leak tests.
#[no_mangle]
pub extern "C" fn phoros_core_live_handles() -> usize {
    LIVE_HANDLES.load(Ordering::SeqCst)
}

/// Creates a core. `user` is passed back to `on_event`. Never null on return; the caller
/// owns the handle and must `destroy` it.
#[no_mangle]
pub extern "C" fn phoros_core_create(user: *mut c_void, on_event: PhorosEventCallback) -> *mut PhorosCore {
    let built = guard(|| {
        // Proves str0m is linked and its builder runs on this target.
        let _ = str0m::Rtc::builder();
        Ok(true)
    })
    .unwrap_or(false);
    let core = Box::new(PhorosCore {
        inner: Mutex::new(Inner {
            user,
            on_event,
            fed_bytes: 0,
            fed_datagrams: 0,
            outbox: Vec::with_capacity(64),
            last_now_us: 0,
            destroyed: false,
            _rtc_built: built,
        }),
    });
    LIVE_HANDLES.fetch_add(1, Ordering::SeqCst);
    Box::into_raw(core)
}

/// Destroys a core. Fires `on_event(DESTROYING)` first, on this thread, so the caller can
/// drop what `user` points at afterwards. Null is a no-op. Double destroy is undefined, as
/// with any free; the Swift wrapper prevents it.
#[no_mangle]
pub unsafe extern "C" fn phoros_core_destroy(core: *mut PhorosCore) {
    if core.is_null() {
        return;
    }
    let core = Box::from_raw(core);
    let _ = guard(|| {
        if let Ok(mut inner) = core.inner.lock() {
            inner.destroyed = true;
            let (cb, user, fed) = (inner.on_event, inner.user, inner.fed_datagrams as i64);
            drop(inner);
            if let Some(cb) = cb {
                cb(user, PHOROS_EVENT_DESTROYING, fed);
            }
        }
        Ok(())
    });
    LIVE_HANDLES.fetch_sub(1, Ordering::SeqCst);
    drop(core);
}

/// Bytes arrived from the network. The core copies what it needs before returning; the
/// caller's buffer is not retained. `len` may be zero (a no-op that still counts).
#[no_mangle]
pub unsafe extern "C" fn phoros_core_feed(core: *mut PhorosCore, bytes: *const u8, len: usize, now_us: i64) -> i32 {
    if core.is_null() || (bytes.is_null() && len > 0) {
        return PHOROS_ERR_NULL;
    }
    if len > PHOROS_MAX_DATAGRAM {
        return PHOROS_ERR_TOO_LARGE;
    }
    let core = &*core;
    match guard(|| {
        let mut inner = core.inner.lock().map_err(|_| PHOROS_ERR_POISONED)?;
        if inner.destroyed {
            return Err(PHOROS_ERR_DESTROYED);
        }
        let slice = if len == 0 { &[][..] } else { std::slice::from_raw_parts(bytes, len) };
        inner.fed_bytes += slice.len() as u64;
        inner.fed_datagrams += 1;
        inner.last_now_us = now_us;
        // Placeholder state machine: acknowledge with a 12-byte header echoing the count.
        inner.outbox.clear();
        inner.outbox.extend_from_slice(b"PHAK");
        inner.outbox.extend_from_slice(&(slice.len() as u32).to_le_bytes());
        let count = (inner.fed_datagrams as u32).to_le_bytes();
        inner.outbox.extend_from_slice(&count);
        let (cb, user, fed) = (inner.on_event, inner.user, slice.len() as i64);
        drop(inner);
        // The callback runs with the lock released: a caller that re-enters the core from
        // it must not deadlock.
        if let Some(cb) = cb {
            cb(user, PHOROS_EVENT_FED, fed);
        }
        Ok(())
    }) {
        Ok(()) => PHOROS_OK,
        Err(e) => e,
    }
}

/// What to do next. Fills `out`. A `Transmit` buffer stays valid until the next call on
/// this handle from any thread.
#[no_mangle]
pub unsafe extern "C" fn phoros_core_poll(core: *mut PhorosCore, now_us: i64, out: *mut PhorosPoll) -> i32 {
    if core.is_null() || out.is_null() {
        return PHOROS_ERR_NULL;
    }
    let core = &*core;
    match guard(|| {
        let mut inner = core.inner.lock().map_err(|_| PHOROS_ERR_POISONED)?;
        if inner.destroyed {
            return Err(PHOROS_ERR_DESTROYED);
        }
        inner.last_now_us = now_us;
        if !inner.outbox.is_empty() {
            (*out).kind = PhorosPollKind::Transmit;
            (*out).buffer = inner.outbox.as_ptr();
            (*out).len = inner.outbox.len();
            (*out).at_us = now_us;
            // Handed out once; the buffer stays allocated (and valid) until the next call.
            inner.outbox.truncate(0);
            // truncate keeps capacity and the bytes stay readable until overwritten.
            return Ok(());
        }
        (*out).kind = PhorosPollKind::Timeout;
        (*out).buffer = std::ptr::null();
        (*out).len = 0;
        (*out).at_us = now_us + 1_000_000;
        Ok(())
    }) {
        Ok(()) => PHOROS_OK,
        Err(e) => e,
    }
}

/// Test hook: makes the next call panic inside the core, to prove the boundary catches it.
#[no_mangle]
pub unsafe extern "C" fn phoros_core_test_panic(core: *mut PhorosCore) -> i32 {
    if core.is_null() {
        return PHOROS_ERR_NULL;
    }
    let core = &*core;
    match guard(|| {
        let _inner = core.inner.lock().map_err(|_| PHOROS_ERR_POISONED)?;
        panic!("phoros_core_test_panic");
    }) {
        Ok(()) => PHOROS_OK,
        Err(e) => e,
    }
}

/// Test hook: a panic while holding the lock poisons it; later calls report POISONED
/// rather than deadlocking or crashing.
#[no_mangle]
pub unsafe extern "C" fn phoros_core_test_poison(core: *mut PhorosCore) -> i32 {
    phoros_core_test_panic(core)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn feed_then_poll_transmits_an_ack() {
        let core = phoros_core_create(std::ptr::null_mut(), None);
        let data = [1u8, 2, 3];
        assert_eq!(unsafe { phoros_core_feed(core, data.as_ptr(), 3, 10) }, PHOROS_OK);
        let mut out = PhorosPoll { kind: PhorosPollKind::Idle, buffer: std::ptr::null(), len: 0, at_us: 0 };
        assert_eq!(unsafe { phoros_core_poll(core, 11, &mut out) }, PHOROS_OK);
        assert_eq!(out.kind, PhorosPollKind::Transmit);
        assert_eq!(out.len, 12);
        assert_eq!(unsafe { phoros_core_poll(core, 12, &mut out) }, PHOROS_OK);
        assert_eq!(out.kind, PhorosPollKind::Timeout);
        unsafe { phoros_core_destroy(core) };
        assert_eq!(phoros_core_live_handles(), 0);
    }

    #[test]
    fn panic_is_contained_and_poisons() {
        let core = phoros_core_create(std::ptr::null_mut(), None);
        assert_eq!(unsafe { phoros_core_test_panic(core) }, PHOROS_ERR_PANIC);
        assert_eq!(unsafe { phoros_core_feed(core, std::ptr::null(), 0, 0) }, PHOROS_ERR_POISONED);
        unsafe { phoros_core_destroy(core) };
    }
}
