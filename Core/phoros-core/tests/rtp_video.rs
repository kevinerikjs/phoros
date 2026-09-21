//! Video frames over RTP between two peers on loopback: str0m packetizes Annex B H.264,
//! the receiver gets whole frames back with the keyframe flag and RTP time.
use phoros_core::peer::*;
use std::ffi::{c_void, CString};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

struct Side { connected: AtomicBool, frames: AtomicUsize, last: Mutex<Vec<u8>>, bandwidth: AtomicUsize }

unsafe extern "C" fn on_event(user: *mut c_void, kind: u32, value: i64) {
    let side = &*(user as *const Side);
    if kind == PHOROS_PEER_EVENT_CONNECTED { side.connected.store(true, Ordering::SeqCst); }
    if kind == PHOROS_PEER_EVENT_BANDWIDTH { side.bandwidth.store(value as usize, Ordering::SeqCst); }
}
unsafe extern "C" fn on_data(user: *mut c_void, channel: u32, bytes: *const u8, len: usize) {
    if channel != PHOROS_CHANNEL_VIDEO { return; }
    let side = &*(user as *const Side);
    side.frames.fetch_add(1, Ordering::SeqCst);
    *side.last.lock().unwrap() = std::slice::from_raw_parts(bytes, len).to_vec();
}

/// An Annex B "frame": one NAL of the requested size (type 5 for IDR, 1 for a slice).
fn annexb(size: usize, idr: bool) -> Vec<u8> {
    let mut v = vec![0, 0, 0, 1, if idr { 0x65 } else { 0x41 }];
    v.extend((0..size).map(|i| (i % 251) as u8 + 1));
    v
}

#[test]
fn h264_frames_cross_as_rtp_with_keyframe_flag_and_time() {
    let host_side = Arc::new(Side { connected: AtomicBool::new(false), frames: AtomicUsize::new(0), last: Default::default(), bandwidth: AtomicUsize::new(0) });
    let client_side = Arc::new(Side { connected: AtomicBool::new(false), frames: AtomicUsize::new(0), last: Default::default(), bandwidth: AtomicUsize::new(0) });
    let host_addr = CString::new("127.0.0.1:39051").unwrap();
    let client_addr = CString::new("127.0.0.1:39052").unwrap();
    unsafe {
        let host = phoros_peer_create(Arc::as_ptr(&host_side) as *mut c_void, Some(on_event), Some(on_data), true, host_addr.as_ptr());
        let client = phoros_peer_create(Arc::as_ptr(&client_side) as *mut c_void, Some(on_event), Some(on_data), false, client_addr.as_ptr());
        let mut buf = vec![0i8; 512];
        phoros_peer_local_info(host, buf.as_mut_ptr(), buf.len());
        let host_info = CString::from_vec_with_nul(buf.iter().take_while(|b| **b != 0).map(|b| *b as u8).chain(std::iter::once(0)).collect()).unwrap();
        phoros_peer_local_info(client, buf.as_mut_ptr(), buf.len());
        let client_info = CString::from_vec_with_nul(buf.iter().take_while(|b| **b != 0).map(|b| *b as u8).chain(std::iter::once(0)).collect()).unwrap();
        assert_eq!(phoros_peer_run_own_socket(host), 0);
        assert_eq!(phoros_peer_run_own_socket(client), 0);
        assert_eq!(phoros_peer_set_remote(host, client_info.as_ptr(), client_addr.as_ptr(), 0), 0);
        assert_eq!(phoros_peer_set_remote(client, host_info.as_ptr(), host_addr.as_ptr(), 0), 0);
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline && !(host_side.connected.load(Ordering::SeqCst) && client_side.connected.load(Ordering::SeqCst)) {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(client_side.connected.load(Ordering::SeqCst));
        std::thread::sleep(Duration::from_millis(100));

        // a 300 KB keyframe, then 120 delta frames of 30 KB at 120 fps
        let key = annexb(300_000, true);
        assert_eq!(phoros_peer_send_video(host, key.as_ptr(), key.len(), 1_000_000, PHOROS_CODEC_H264, true), 0);
        let mut sent = 1;
        for i in 0..120u64 {
            let delta = annexb(30_000, false);
            let pts = 1_000_000 + (i + 1) * 8_333;
            let status = phoros_peer_send_video(host, delta.as_ptr(), delta.len(), pts as i64, PHOROS_CODEC_H264, false);
            if status == 0 { sent += 1; }
            std::thread::sleep(Duration::from_micros(8_333));
        }
        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline && client_side.frames.load(Ordering::SeqCst) < sent { std::thread::sleep(Duration::from_millis(5)); }
        let got = client_side.frames.load(Ordering::SeqCst);
        println!("rtp video: sent {sent}, received {got}, host bandwidth estimate {} kbps", host_side.bandwidth.load(Ordering::SeqCst) / 1000);
        assert!(got >= sent - 2, "frames received: {got} of {sent}");
        let last = client_side.last.lock().unwrap().clone();
        let micros = i64::from_le_bytes(last[0..8].try_into().unwrap());
        assert!(micros > 1_000_000, "rtp time carried: {micros}");
        assert_eq!(last[8], 0, "last frame is a delta");
        assert_eq!(&last[10..], &annexb(30_000, false)[..], "the Annex B frame comes back byte for byte");
        phoros_peer_destroy(client);
        phoros_peer_destroy(host);
    }
}
