//! A str0m peer behind the C ABI: ICE (lite on the host), DTLS, SCTP, two data channels
//! (one reliable and ordered, one unordered with a 50 ms lifetime), driven sans-IO by the
//! caller, or with a socket of its own for the ownership benchmark (BEAM-53).

use std::ffi::{c_char, c_void, CStr};
use std::net::{SocketAddr, UdpSocket};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use str0m::channel::{ChannelConfig, ChannelId, Reliability};
use str0m::ice::IceCreds;
use str0m::media::{MediaKind, MediaTime, Mid};
use str0m::net::{DatagramRecv, Protocol, Receive};
use str0m::rtp::Ssrc;
use str0m::bwe::Bitrate;
use str0m::{Candidate, Event, Input, Output, Rtc};

use crate::{PHOROS_ERR_BUSY, PHOROS_ERR_NULL, PHOROS_ERR_PANIC, PHOROS_ERR_POISONED, PHOROS_ERR_TOO_LARGE, PHOROS_MAX_DATAGRAM, PHOROS_OK};

pub const PHOROS_PEER_EVENT_CONNECTED: u32 = 10;
pub const PHOROS_PEER_EVENT_CHANNEL_OPEN: u32 = 11;
pub const PHOROS_PEER_EVENT_ICE_STATE: u32 = 12;
pub const PHOROS_PEER_EVENT_DISCONNECTED: u32 = 13;

pub const PHOROS_CHANNEL_RELIABLE: u32 = 0;
pub const PHOROS_CHANNEL_REALTIME: u32 = 1;
/// `on_data` channel for a decoded RTP video frame: 8 bytes of RTP time in microseconds,
/// 1 byte keyframe, 1 byte contiguous (0 = packets were lost before it), then Annex B.
pub const PHOROS_CHANNEL_VIDEO: u32 = 100;
/// `on_event` value: the host's bandwidth estimate in bits per second (TWCC).
pub const PHOROS_PEER_EVENT_BANDWIDTH: u32 = 14;

pub const PHOROS_CODEC_H264: u32 = 0;
pub const PHOROS_CODEC_H265: u32 = 1;
const VIDEO_SSRC: u32 = 0x5048_4F52;
const VIDEO_RTX_SSRC: u32 = 0x5048_4F53;
const PT_H264: u8 = 96;
const PT_H264_RTX: u8 = 97;
const PT_H265: u8 = 98;
const PT_H265_RTX: u8 = 99;

/// Called for every message received on a data channel. `channel` is 0 (reliable) or 1
/// (realtime). The bytes are valid for the duration of the call.
pub type PhorosDataCallback = Option<unsafe extern "C" fn(user: *mut c_void, channel: u32, bytes: *const u8, len: usize)>;
pub type PhorosEventCallback = crate::PhorosEventCallback;

struct Inner {
    rtc: Rtc,
    user: *mut c_void,
    on_event: PhorosEventCallback,
    on_data: PhorosDataCallback,
    is_host: bool,
    local_addr: SocketAddr,
    remote_addr: Option<SocketAddr>,
    base_instant: Instant,
    base_us: Option<i64>,
    channels: Vec<ChannelId>,
    outbox: Vec<u8>,
    outbox_to: Option<SocketAddr>,
    connected: bool,
    /// When str0m last asked to be polled again.
    next_timeout: Option<Instant>,
    /// TWCC has produced an estimate at least once.
    bwe_reported: bool,
}
unsafe impl Send for Inner {}

impl Inner {
    /// `next_timeout` on the caller's clock, in microseconds.
    fn next_timeout_us(&self, now_us: i64) -> i64 {
        match self.next_timeout {
            Some(at) => {
                let from_now = at.saturating_duration_since(self.base_instant + Duration::from_micros(now_us.saturating_sub(self.base_us.unwrap_or(now_us)).max(0) as u64));
                now_us + from_now.as_micros() as i64
            }
            None => now_us + 5_000,
        }
    }
}

pub struct PhorosPeer {
    inner: Arc<Mutex<Inner>>,
    /// Design B: the core owns the socket and a thread.
    socket_thread: Mutex<Option<JoinHandle<()>>>,
    stop: Arc<AtomicBool>,
    /// Design B: a send from another thread pokes the loop out of `recv_from` with one
    /// byte to its own socket, so a transmit never waits for the read timeout.
    poke: Mutex<Option<(UdpSocket, SocketAddr)>>,
    /// Harness stats: when the last send was called (micros since `stats_base`), the delay
    /// send -> datagram on the wire for the last send and the worst one, and the socket's
    /// service class (0 best effort, 3 video, 4 voice), applied at bind.
    stats_base: Instant,
    last_send_us: Arc<std::sync::atomic::AtomicI64>,
    wire_delay_last_us: Arc<std::sync::atomic::AtomicI64>,
    wire_delay_max_us: Arc<std::sync::atomic::AtomicI64>,
    /// When the last datagram was read off the socket (micros since `stats_base`).
    last_recv_us: Arc<std::sync::atomic::AtomicI64>,
    service_class: std::sync::atomic::AtomicI32,
}

impl Inner {
    fn instant(&mut self, now_us: i64) -> Instant {
        let base = *self.base_us.get_or_insert(now_us);
        self.base_instant + Duration::from_micros(now_us.saturating_sub(base).max(0) as u64)
    }

    /// Runs the state machine until it asks for a timeout or has something to send.
    /// Returns true when a transmit is waiting in `outbox`. Events are queued in `pending`
    /// and dispatched by the caller after the lock is released: a callback that calls back
    /// into the peer (an echo, a reply) must not deadlock.
    fn pump(&mut self, pending: &mut Vec<Pending>) -> Result<bool, i32> {
        loop {
            match self.rtc.poll_output().map_err(|_| PHOROS_ERR_PANIC)? {
                Output::Timeout(at) => { self.next_timeout = Some(at); return Ok(false) }
                Output::Transmit(t) => {
                    self.outbox.clear();
                    self.outbox.extend_from_slice(&t.contents);
                    self.outbox_to = Some(t.destination);
                    return Ok(true);
                }
                Output::Event(event) => self.handle(event, pending),
            }
        }
    }

    fn handle(&mut self, event: Event, pending: &mut Vec<Pending>) {
        match event {
            Event::Connected => {
                self.connected = true;
                pending.push(Pending::Event(PHOROS_PEER_EVENT_CONNECTED, 0));
            }
            Event::IceConnectionStateChange(state) => pending.push(Pending::Event(PHOROS_PEER_EVENT_ICE_STATE, state as i64)),
            Event::ChannelOpen(id, _label) => {
                if !self.channels.contains(&id) { self.channels.push(id); }
                let index = self.channels.iter().position(|c| *c == id).unwrap_or(0);
                pending.push(Pending::Event(PHOROS_PEER_EVENT_CHANNEL_OPEN, index as i64));
            }
            Event::ChannelData(data) => {
                let index = self.channels.iter().position(|c| *c == data.id).unwrap_or(0) as u32;
                pending.push(Pending::Data(index, data.data));
            }
            Event::MediaData(media) => {
                let keyframe = match media.codec_extra {
                    str0m::format::CodecExtra::H264(e) => e.is_keyframe,
                    str0m::format::CodecExtra::H265(e) => e.is_keyframe,
                    _ => false,
                };
                let micros = (media.time.as_seconds() * 1_000_000.0) as i64;
                let mut buf = Vec::with_capacity(10 + media.data.len());
                buf.extend_from_slice(&micros.to_le_bytes());
                buf.push(keyframe as u8);
                buf.push(media.contiguous as u8);
                buf.extend_from_slice(&media.data);
                pending.push(Pending::Data(PHOROS_CHANNEL_VIDEO, buf));
            }
            Event::EgressBitrateEstimate(kind) => {
                self.bwe_reported = true;
                let bps = match kind { str0m::bwe::BweKind::Twcc(b) => b.as_u64(), str0m::bwe::BweKind::Remb(_, b) => b.as_u64(), _ => return };
                pending.push(Pending::Event(PHOROS_PEER_EVENT_BANDWIDTH, bps as i64));
            }
            _ => {}
        }
    }

    fn callbacks(&self) -> (PhorosEventCallback, PhorosDataCallback, *mut c_void) {
        (self.on_event, self.on_data, self.user)
    }
}

enum Pending {
    Event(u32, i64),
    Data(u32, Vec<u8>),
}

/// Dispatches queued events with no lock held.
unsafe fn dispatch(pending: Vec<Pending>, on_event: PhorosEventCallback, on_data: PhorosDataCallback, user: *mut c_void) {
    for p in pending {
        match p {
            Pending::Event(kind, value) => { if let Some(cb) = on_event { cb(user, kind, value) } }
            Pending::Data(channel, data) => { if let Some(cb) = on_data { cb(user, channel, data.as_ptr(), data.len()) } }
        }
    }
}

fn guard<T>(f: impl FnOnce() -> Result<T, i32>) -> Result<T, i32> {
    match catch_unwind(AssertUnwindSafe(f)) { Ok(r) => r, Err(_) => Err(PHOROS_ERR_PANIC) }
}

unsafe fn cstr(p: *const c_char) -> Option<String> {
    if p.is_null() { return None; }
    CStr::from_ptr(p).to_str().ok().map(|s| s.to_string())
}

/// Creates a peer bound (logically) to `local_addr` ("ip:port"). A host runs ICE lite and
/// answers DTLS; a client controls ICE and starts DTLS. `owns_socket` = design B: the core
/// binds the address itself and runs its own thread; feed and poll are then not used.
#[no_mangle]
pub unsafe extern "C" fn phoros_peer_create(
    user: *mut c_void, on_event: PhorosEventCallback, on_data: PhorosDataCallback,
    is_host: bool, local_addr: *const c_char,
) -> *mut PhorosPeer {
    let Some(addr) = cstr(local_addr).and_then(|s| s.parse::<SocketAddr>().ok()) else { return std::ptr::null_mut() };
    let built = guard(|| {
        let provider = Arc::new(str0m_apple_crypto::default_provider());
        // NACKs go out as soon as a gap is seen (str0m's default waits up to 33 ms); the
        // interval is a phoros patch on the vendored crate. PHOROS_NACK_MS overrides.
        let nack_ms: u64 = std::env::var("PHOROS_NACK_MS").ok().and_then(|v| v.parse().ok()).unwrap_or(5);
        let mut builder = Rtc::builder()
            .set_crypto_provider(provider)
            .set_nack_min_interval(Duration::from_millis(nack_ms))
            .set_ice_lite(is_host)
            .set_local_ice_credentials(IceCreds::new())
            .clear_codecs();
        // H.264 (packetization mode 1, high profile) and H.265, each with an RTX stream, so
        // str0m packetizes the Annex B frames the encoder produces and can resend on NACK.
        builder.codec_config().add_h264(PT_H264.into(), Some(PT_H264_RTX.into()), true, 0x64_00_1f);
        builder.codec_config().add_h265(PT_H265.into(), Some(PT_H265_RTX.into()), 1, 0, 120);
        // The bandwidth estimator is on: its estimate drives the encoder through the
        // BANDWIDTH event. Its pacer is neutered in the vendored str0m (packets leave as
        // they exist); paced at the estimate it held frames for hundreds of ms.
        // PHOROS_BWE=0 turns the estimator off for experiments.
        let bwe = std::env::var("PHOROS_BWE").map(|v| v != "0").unwrap_or(true);
        if is_host && bwe { builder = builder.enable_bwe(Some(Bitrate::kbps(4_000))); }
        let mut rtc = builder.build(Instant::now());
        rtc.direct_api().set_ice_controlling(!is_host);
        let candidate = Candidate::host(addr, Protocol::Udp).map_err(|_| PHOROS_ERR_NULL)?;
        rtc.add_local_candidate(candidate);
        Ok(rtc)
    });
    let Ok(rtc) = built else { return std::ptr::null_mut() };
    let peer = Box::new(PhorosPeer {
        inner: Arc::new(Mutex::new(Inner {
            rtc, user, on_event, on_data, is_host, local_addr: addr, remote_addr: None,
            base_instant: Instant::now(), base_us: None, channels: Vec::new(),
            outbox: Vec::with_capacity(2048), outbox_to: None, connected: false, next_timeout: None, bwe_reported: false,
        })),
        socket_thread: Mutex::new(None),
        stop: Arc::new(AtomicBool::new(false)),
        poke: Mutex::new(None),
        stats_base: Instant::now(),
        last_send_us: Arc::new(std::sync::atomic::AtomicI64::new(-1)),
        wire_delay_last_us: Arc::new(std::sync::atomic::AtomicI64::new(0)),
        wire_delay_max_us: Arc::new(std::sync::atomic::AtomicI64::new(0)),
        last_recv_us: Arc::new(std::sync::atomic::AtomicI64::new(-1)),
        service_class: std::sync::atomic::AtomicI32::new(3),
    });
    Box::into_raw(peer)
}

#[no_mangle]
pub unsafe extern "C" fn phoros_peer_destroy(peer: *mut PhorosPeer) {
    if peer.is_null() { return; }
    let peer = Box::from_raw(peer);
    peer.stop.store(true, Ordering::SeqCst);
    if let Ok(mut t) = peer.socket_thread.lock() {
        if let Some(handle) = t.take() { let _ = handle.join(); }
    }
    drop(peer);
}

/// Writes "ufrag\npass\nfingerprint-hex" into `out`, NUL terminated. Returns the length
/// needed, or an error status. What the bootstrap carries to the other side.
#[no_mangle]
pub unsafe extern "C" fn phoros_peer_local_info(peer: *mut PhorosPeer, out: *mut c_char, capacity: usize) -> i32 {
    if peer.is_null() || out.is_null() { return PHOROS_ERR_NULL; }
    let peer = &*peer;
    match guard(|| {
        let mut inner = peer.inner.lock().map_err(|_| PHOROS_ERR_POISONED)?;
        let creds = inner.rtc.direct_api().local_ice_credentials();
        let fp = inner.rtc.direct_api().local_dtls_fingerprint().clone();
        let hex: String = fp.bytes.iter().map(|b| format!("{:02x}", b)).collect();
        let text = format!("{}\n{}\n{}", creds.ufrag, creds.pass, hex);
        let bytes = text.as_bytes();
        if bytes.len() + 1 > capacity { return Err(PHOROS_ERR_TOO_LARGE); }
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), out as *mut u8, bytes.len());
        *out.add(bytes.len()) = 0;
        Ok(bytes.len() as i32)
    }) { Ok(n) => n, Err(e) => e }
}

/// The other side's info, from the bootstrap, and its address. Starts ICE, DTLS and SCTP.
#[no_mangle]
pub unsafe extern "C" fn phoros_peer_set_remote(peer: *mut PhorosPeer, info: *const c_char, remote_addr: *const c_char, now_us: i64) -> i32 {
    if peer.is_null() { return PHOROS_ERR_NULL; }
    let (Some(info), Some(addr)) = (cstr(info), cstr(remote_addr).and_then(|s| s.parse::<SocketAddr>().ok())) else { return PHOROS_ERR_NULL };
    let peer = &*peer;
    match guard(|| {
        let mut inner = peer.inner.lock().map_err(|_| PHOROS_ERR_POISONED)?;
        let mut lines = info.split('\n');
        let (ufrag, pass, hex) = (lines.next().unwrap_or("").to_string(), lines.next().unwrap_or("").to_string(), lines.next().unwrap_or("").to_string());
        let bytes: Vec<u8> = (0..hex.len() / 2).filter_map(|i| u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).ok()).collect();
        let is_host = inner.is_host;
        inner.remote_addr = Some(addr);
        {
            let mut api = inner.rtc.direct_api();
            api.set_remote_ice_credentials(IceCreds { ufrag, pass });
            api.set_remote_fingerprint(str0m::config::Fingerprint { hash_func: "sha-256".into(), bytes });
            api.start_dtls(!is_host).map_err(|_| PHOROS_ERR_PANIC)?;
            api.start_sctp(!is_host);
            if is_host {
                let reliable = api.create_data_channel(ChannelConfig { label: "reliable".into(), ordered: true, reliability: Reliability::Reliable, negotiated: Some(0), protocol: String::new() });
                let realtime = api.create_data_channel(ChannelConfig { label: "realtime".into(), ordered: false, reliability: Reliability::MaxPacketLifetime { lifetime: 50 }, negotiated: Some(1), protocol: String::new() });
                inner.channels = vec![reliable, realtime];
            } else {
                let reliable = api.create_data_channel(ChannelConfig { label: "reliable".into(), ordered: true, reliability: Reliability::Reliable, negotiated: Some(0), protocol: String::new() });
                let realtime = api.create_data_channel(ChannelConfig { label: "realtime".into(), ordered: false, reliability: Reliability::MaxPacketLifetime { lifetime: 50 }, negotiated: Some(1), protocol: String::new() });
                inner.channels = vec![reliable, realtime];
            }
        }
        // One video media line, one stream each way, fixed SSRCs both sides know.
        let mid: Mid = "0".into();
        inner.rtc.direct_api().declare_media(mid, MediaKind::Video);
        if is_host {
            inner.rtc.direct_api().declare_stream_tx(Ssrc::from(VIDEO_SSRC), Some(Ssrc::from(VIDEO_RTX_SSRC)), mid, None);
        } else {
            inner.rtc.direct_api().expect_stream_rx(Ssrc::from(VIDEO_SSRC), Some(Ssrc::from(VIDEO_RTX_SSRC)), mid, None);
            inner.rtc.direct_api().enable_twcc_feedback();
        }
        let candidate = Candidate::host(addr, Protocol::Udp).map_err(|_| PHOROS_ERR_NULL)?;
        inner.rtc.add_remote_candidate(candidate);
        let at = inner.instant(now_us);
        inner.rtc.handle_input(Input::Timeout(at)).map_err(|_| PHOROS_ERR_PANIC)?;
        Ok(())
    }) { Ok(()) => PHOROS_OK, Err(e) => e }
}

/// A datagram arrived from `source` ("ip:port"). Design A only.
#[no_mangle]
pub unsafe extern "C" fn phoros_peer_feed(peer: *mut PhorosPeer, bytes: *const u8, len: usize, source: *const c_char, now_us: i64) -> i32 {
    if peer.is_null() || bytes.is_null() { return PHOROS_ERR_NULL; }
    if len > PHOROS_MAX_DATAGRAM { return PHOROS_ERR_TOO_LARGE; }
    let peer = &*peer;
    let source = cstr(source).and_then(|s| s.parse::<SocketAddr>().ok());
    match guard(|| {
        let mut inner = peer.inner.lock().map_err(|_| PHOROS_ERR_POISONED)?;
        let source = source.or(inner.remote_addr).ok_or(PHOROS_ERR_NULL)?;
        let slice = std::slice::from_raw_parts(bytes, len);
        let at = inner.instant(now_us);
        let contents = DatagramRecv::try_from(slice).map_err(|_| PHOROS_ERR_TOO_LARGE)?;
        let destination = inner.local_addr;
        inner.rtc.handle_input(Input::Receive(at, Receive { proto: Protocol::Udp, source, destination, contents })).map_err(|_| PHOROS_ERR_PANIC)?;
        Ok(())
    }) { Ok(()) => PHOROS_OK, Err(e) => e }
}

/// Runs the state machine at `now_us`. Fills `out` like `phoros_core_poll`: a transmit (to
/// the remote address) or a timeout. Call until it returns a timeout. Design A only.
#[no_mangle]
pub unsafe extern "C" fn phoros_peer_poll(peer: *mut PhorosPeer, now_us: i64, out: *mut crate::PhorosPoll) -> i32 {
    if peer.is_null() || out.is_null() { return PHOROS_ERR_NULL; }
    let peer = &*peer;
    match guard(|| {
        let mut pending = Vec::new();
        let (on_event, on_data, user);
        {
            let mut inner = peer.inner.lock().map_err(|_| PHOROS_ERR_POISONED)?;
            let at = inner.instant(now_us);
            inner.rtc.handle_input(Input::Timeout(at)).map_err(|_| PHOROS_ERR_PANIC)?;
            if inner.pump(&mut pending)? {
                (*out).kind = crate::PhorosPollKind::Transmit;
                (*out).buffer = inner.outbox.as_ptr();
                (*out).len = inner.outbox.len();
                (*out).at_us = now_us;
            } else {
                (*out).kind = crate::PhorosPollKind::Timeout;
                (*out).buffer = std::ptr::null();
                (*out).len = 0;
                (*out).at_us = inner.next_timeout_us(now_us);
            }
            (on_event, on_data, user) = inner.callbacks();
        }
        dispatch(pending, on_event, on_data, user);
        Ok(())
    }) { Ok(()) => PHOROS_OK, Err(e) => e }
}

/// Sends `bytes` on channel 0 (reliable) or 1 (realtime). Returns an error before the
/// channel is open.
#[no_mangle]
pub unsafe extern "C" fn phoros_peer_send(peer: *mut PhorosPeer, channel: u32, bytes: *const u8, len: usize) -> i32 {
    if peer.is_null() || bytes.is_null() { return PHOROS_ERR_NULL; }
    let peer = &*peer;
    match guard(|| {
        let mut inner = peer.inner.lock().map_err(|_| PHOROS_ERR_POISONED)?;
        let id = *inner.channels.get(channel as usize).ok_or(PHOROS_ERR_NULL)?;
        let slice = std::slice::from_raw_parts(bytes, len);
        let mut ch = inner.rtc.channel(id).ok_or(PHOROS_ERR_NULL)?;
        // false: the association's send buffer (128 KB across streams) cannot take it now.
        // The caller queues and retries; the core never buffers beyond what SCTP will.
        if !ch.write(true, slice).map_err(|_| PHOROS_ERR_PANIC)? { return Err(PHOROS_ERR_BUSY); }
        drop(inner);
        peer.last_send_us.store(peer.stats_base.elapsed().as_micros() as i64, Ordering::Relaxed);
        if let Ok(p) = peer.poke.lock() {
            if let Some((sock, to)) = p.as_ref() { let _ = sock.send_to(&[0u8], to); }
        }
        Ok(())
    }) { Ok(()) => PHOROS_OK, Err(e) => e }
}

/// One encoded video frame, Annex B, at `pts_us` on the media clock. str0m packetizes it
/// (FU-A for H.264, FU for H.265) and pacing, NACK and TWCC apply. Host only.
#[no_mangle]
pub unsafe extern "C" fn phoros_peer_send_video(peer: *mut PhorosPeer, bytes: *const u8, len: usize, pts_us: i64, codec: u32, is_keyframe: bool) -> i32 {
    if peer.is_null() || bytes.is_null() { return PHOROS_ERR_NULL; }
    let peer = &*peer;
    match guard(|| {
        let mut inner = peer.inner.lock().map_err(|_| PHOROS_ERR_POISONED)?;
        let slice = std::slice::from_raw_parts(bytes, len);
        let pt = if codec == PHOROS_CODEC_H265 { PT_H265 } else { PT_H264 };
        let mid: Mid = "0".into();
        let rtp_time = MediaTime::from_90khz((pts_us.max(0) as u64) * 9 / 100);
        let wallclock = inner.base_instant + Duration::from_micros(pts_us.max(0) as u64);
        let _ = is_keyframe;
        let writer = inner.rtc.writer(mid).ok_or(PHOROS_ERR_NULL)?;
        writer.write(pt.into(), wallclock, rtp_time, slice).map_err(|_| PHOROS_ERR_BUSY)?;
        drop(inner);
        if let Ok(p) = peer.poke.lock() {
            if let Some((sock, to)) = p.as_ref() { let _ = sock.send_to(&[0u8], to); }
        }
        Ok(())
    }) { Ok(()) => PHOROS_OK, Err(e) => e }
}

/// Asks the host's bandwidth estimator to aim for this bitrate; what it reports through
/// PHOROS_PEER_EVENT_BANDWIDTH is what the link allows. Host only.
#[no_mangle]
pub unsafe extern "C" fn phoros_peer_set_desired_bitrate(peer: *mut PhorosPeer, bits_per_second: u64) -> i32 {
    if peer.is_null() { return PHOROS_ERR_NULL; }
    let peer = &*peer;
    match guard(|| {
        let mut inner = peer.inner.lock().map_err(|_| PHOROS_ERR_POISONED)?;
        inner.rtc.bwe().set_desired_bitrate(Bitrate::bps(bits_per_second));
        // Until TWCC has reported once the estimate is str0m's 4 Mbps default, and the pacer
        // drains a 1080p keyframe at that rate. Start from what the preset asks for.
        if !inner.bwe_reported { inner.rtc.bwe().reset(Bitrate::bps(bits_per_second)); }
        Ok(())
    }) { Ok(()) => PHOROS_OK, Err(e) => e }
}

/// Design B: the core binds `local_addr` itself and runs the loop on its own thread until
/// destroy. Callbacks then arrive on that thread.
#[no_mangle]
pub unsafe extern "C" fn phoros_peer_run_own_socket(peer: *mut PhorosPeer) -> i32 {
    if peer.is_null() { return PHOROS_ERR_NULL; }
    let peer = &*peer;
    let inner = Arc::clone(&peer.inner);
    let stop = Arc::clone(&peer.stop);
    let local = match inner.lock() { Ok(i) => i.local_addr, Err(_) => return PHOROS_ERR_POISONED };
    let socket = match UdpSocket::bind(local) { Ok(s) => s, Err(_) => return PHOROS_ERR_NULL };
    let _ = socket.set_read_timeout(Some(Duration::from_millis(2)));
    set_service_class(&socket, peer.service_class.load(Ordering::Relaxed));
    let (last_send_us, wire_delay_last, wire_delay_max, stats_base, last_recv_us) =
        (Arc::clone(&peer.last_send_us), Arc::clone(&peer.wire_delay_last_us), Arc::clone(&peer.wire_delay_max_us), peer.stats_base, Arc::clone(&peer.last_recv_us));
    let poke_addr = match UdpSocket::bind((local.ip(), 0)) {
        Ok(p) => { let a = p.local_addr().ok(); if let Ok(mut slot) = peer.poke.lock() { *slot = a.map(|_| (p, local)); } a }
        Err(_) => None,
    };
    let handle = std::thread::Builder::new().name("phoros-peer".into()).spawn(move || {
        raise_thread_priority();
        let mut buf = vec![0u8; 2000];
        let start = Instant::now();
        let drop_percent: u32 = std::env::var("PHOROS_DROP").ok().and_then(|v| v.parse().ok()).unwrap_or(0);
        let mut drop_seed: u32 = 7;
        while !stop.load(Ordering::SeqCst) {
            // drain outbound, then dispatch what the state machine produced, lock released
            let mut pending = Vec::new();
            let callbacks;
            loop {
                let mut inner = match inner.lock() { Ok(i) => i, Err(_) => return };
                let now_us = start.elapsed().as_micros() as i64;
                let at = inner.instant(now_us);
                if inner.rtc.handle_input(Input::Timeout(at)).is_err() { return; }
                match inner.pump(&mut pending) {
                    Ok(true) => {
                        // PHOROS_DROP=<percent>: a harness switch, drops that share of the
                        // media-sized datagrams on the floor to exercise NACK and RTX.
                        let dropped = drop_percent > 0 && inner.outbox.len() > 200 && (drop_seed.wrapping_mul(1103515245).wrapping_add(12345) >> 16) % 100 < drop_percent;
                        drop_seed = drop_seed.wrapping_mul(1103515245).wrapping_add(12345);
                        if let Some(to) = inner.outbox_to { if !dropped { let _ = socket.send_to(&inner.outbox, to); } }
                        let sent_at = last_send_us.swap(-1, Ordering::Relaxed);
                        if sent_at >= 0 {
                            let d = stats_base.elapsed().as_micros() as i64 - sent_at;
                            wire_delay_last.store(d, Ordering::Relaxed);
                            wire_delay_max.fetch_max(d, Ordering::Relaxed);
                        }
                    }
                    Ok(false) => { callbacks = inner.callbacks(); break; }
                    Err(_) => return,
                }
            }
            dispatch(pending, callbacks.0, callbacks.1, callbacks.2);
            // sleep until str0m's next timeout, or a datagram
            {
                let wait = match inner.lock() {
                    Ok(i) => i.next_timeout.map(|at| at.saturating_duration_since(Instant::now())).unwrap_or(Duration::from_millis(5)),
                    Err(_) => return,
                };
                let _ = socket.set_read_timeout(Some(wait.max(Duration::from_micros(100)).min(Duration::from_millis(50))));
            }
            match socket.recv_from(&mut buf) {
                Ok((_, from)) if Some(from) == poke_addr => {}   // a poke: loop and drain
                Ok((n, from)) => {
                    last_recv_us.store(stats_base.elapsed().as_micros() as i64, Ordering::Relaxed);
                    let mut inner = match inner.lock() { Ok(i) => i, Err(_) => return };
                    let now_us = start.elapsed().as_micros() as i64;
                    let at = inner.instant(now_us);
                    let destination = inner.local_addr;
                    if let Ok(contents) = DatagramRecv::try_from(&buf[..n]) {
                        let _ = inner.rtc.handle_input(Input::Receive(at, Receive { proto: Protocol::Udp, source: from, destination, contents }));
                    }
                }
                Err(_) => {}
            }
        }
    });
    match handle {
        Ok(h) => { if let Ok(mut t) = peer.socket_thread.lock() { *t = Some(h); } PHOROS_OK }
        Err(_) => PHOROS_ERR_NULL,
    }
}

/// Sets SO_NET_SERVICE_TYPE on the socket: 0 best effort, 3 video (NET_SERVICE_TYPE_VI, the
/// class the TCP stream uses), 4 voice (NET_SERVICE_TYPE_VO). On Wi-Fi this picks the WMM
/// access category, which decides how long a datagram waits for airtime.
#[cfg(any(target_os = "macos", target_os = "ios"))]
fn set_service_class(socket: &UdpSocket, class: i32) {
    use std::os::fd::AsRawFd;
    const SOL_SOCKET: i32 = 0xffff;
    const SO_NET_SERVICE_TYPE: i32 = 0x1116;
    extern "C" { fn setsockopt(fd: i32, level: i32, name: i32, value: *const c_void, len: u32) -> i32; }
    if class <= 0 { return; }
    unsafe { setsockopt(socket.as_raw_fd(), SOL_SOCKET, SO_NET_SERVICE_TYPE, &class as *const i32 as *const c_void, 4); }
}
#[cfg(not(any(target_os = "macos", target_os = "ios")))]
fn set_service_class(_socket: &UdpSocket, _class: i32) {}

/// Chooses the socket's service class before `phoros_peer_run_own_socket`: 0 best effort,
/// 3 video (default), 4 voice.
#[no_mangle]
pub unsafe extern "C" fn phoros_peer_set_service_class(peer: *mut PhorosPeer, class: i32) -> i32 {
    if peer.is_null() { return PHOROS_ERR_NULL; }
    (*peer).service_class.store(class, Ordering::Relaxed);
    PHOROS_OK
}

/// Harness stats: `out[0]` = last send -> wire delay in micros, `out[1]` = the worst so far
/// (reset to 0 on read), `out[2]` = micros since the last datagram was read off the socket.
#[no_mangle]
pub unsafe extern "C" fn phoros_peer_stats(peer: *mut PhorosPeer, out: *mut i64) -> i32 {
    if peer.is_null() || out.is_null() { return PHOROS_ERR_NULL; }
    let peer = &*peer;
    *out.add(0) = peer.wire_delay_last_us.load(Ordering::Relaxed);
    *out.add(1) = peer.wire_delay_max_us.swap(0, Ordering::Relaxed);
    // out[2]: micros since the last datagram was read off the socket (-1 before any)
    let r = peer.last_recv_us.load(Ordering::Relaxed);
    *out.add(2) = if r < 0 { -1 } else { peer.stats_base.elapsed().as_micros() as i64 - r };
    PHOROS_OK
}

/// The socket thread runs at user-interactive QoS: on iOS a default-priority thread wakes
/// 1-5 ms late under load (harness: send -> wire p90 4 ms on the phone, 0.2 ms simulator).
#[cfg(any(target_os = "macos", target_os = "ios"))]
fn raise_thread_priority() {
    const QOS_CLASS_USER_INTERACTIVE: u32 = 0x21;
    extern "C" { fn pthread_set_qos_class_self_np(qos_class: u32, relative_priority: i32) -> i32; }
    unsafe { pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0); }
}
#[cfg(not(any(target_os = "macos", target_os = "ios")))]
fn raise_thread_priority() {}
