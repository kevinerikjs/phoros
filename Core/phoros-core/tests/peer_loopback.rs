//! Two peers over real UDP on loopback, each owning its socket (design B), through the C ABI.
use phoros_core::peer::*;
use std::ffi::{c_void, CString};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

struct Side { connected: AtomicBool, open: AtomicUsize, received: AtomicUsize, last: std::sync::Mutex<Vec<u8>>, echo: std::sync::atomic::AtomicPtr<PhorosPeer> }

unsafe extern "C" fn on_event(user: *mut c_void, kind: u32, value: i64) {
    let side = &*(user as *const Side);
    if kind == PHOROS_PEER_EVENT_CONNECTED { side.connected.store(true, Ordering::SeqCst); }
    if kind == PHOROS_PEER_EVENT_CHANNEL_OPEN { side.open.fetch_add(1, Ordering::SeqCst); let _ = value; }
}
unsafe extern "C" fn on_data(user: *mut c_void, channel: u32, bytes: *const u8, len: usize) {
    let side = &*(user as *const Side);
    side.received.fetch_add(1, Ordering::SeqCst);
    *side.last.lock().unwrap() = std::slice::from_raw_parts(bytes, len).to_vec();
    // echo from inside the callback: must not deadlock
    let echo = side.echo.load(Ordering::SeqCst);
    if !echo.is_null() { phoros_peer_send(echo, channel, bytes, len); }
}

#[test]
fn two_peers_connect_and_exchange_on_both_channels() {
    let host_side = Arc::new(Side { connected: AtomicBool::new(false), open: AtomicUsize::new(0), received: AtomicUsize::new(0), last: Default::default(), echo: Default::default() });
    let client_side = Arc::new(Side { connected: AtomicBool::new(false), open: AtomicUsize::new(0), received: AtomicUsize::new(0), last: Default::default(), echo: Default::default() });
    let host_addr = CString::new("127.0.0.1:39001").unwrap();
    let client_addr = CString::new("127.0.0.1:39002").unwrap();
    unsafe {
        let host = phoros_peer_create(Arc::as_ptr(&host_side) as *mut c_void, Some(on_event), Some(on_data), true, host_addr.as_ptr());
        let client = phoros_peer_create(Arc::as_ptr(&client_side) as *mut c_void, Some(on_event), Some(on_data), false, client_addr.as_ptr());
        assert!(!host.is_null() && !client.is_null());
        let mut buf = vec![0i8; 512];
        assert!(phoros_peer_local_info(host, buf.as_mut_ptr(), buf.len()) > 0);
        let host_info = CString::from_vec_with_nul(buf.iter().take_while(|b| **b != 0).map(|b| *b as u8).chain(std::iter::once(0)).collect()).unwrap();
        assert!(phoros_peer_local_info(client, buf.as_mut_ptr(), buf.len()) > 0);
        let client_info = CString::from_vec_with_nul(buf.iter().take_while(|b| **b != 0).map(|b| *b as u8).chain(std::iter::once(0)).collect()).unwrap();
        host_side.echo.store(host, Ordering::SeqCst);
        assert_eq!(phoros_peer_run_own_socket(host), 0);
        assert_eq!(phoros_peer_run_own_socket(client), 0);
        assert_eq!(phoros_peer_set_remote(host, client_info.as_ptr(), client_addr.as_ptr(), 0), 0);
        assert_eq!(phoros_peer_set_remote(client, host_info.as_ptr(), host_addr.as_ptr(), 0), 0);

        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline && !(host_side.connected.load(Ordering::SeqCst) && client_side.connected.load(Ordering::SeqCst)) {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(host_side.connected.load(Ordering::SeqCst), "host connected");
        assert!(client_side.connected.load(Ordering::SeqCst), "client connected");

        // channels are pre-negotiated (out of band); wait for the association to open them
        let deadline = Instant::now() + Duration::from_secs(5);
        let msg = b"hello over sctp".to_vec();
        let mut sent = false;
        while Instant::now() < deadline {
            if !sent && phoros_peer_send(client, PHOROS_CHANNEL_RELIABLE, msg.as_ptr(), msg.len()) == 0 { sent = true; }
            if host_side.received.load(Ordering::SeqCst) > 0 { break; }
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(sent, "reliable send accepted");
        assert_eq!(*host_side.last.lock().unwrap(), msg, "host received the message");

        // realtime channel, host to client, 200 messages; measure the round trip of an echo
        let t0 = Instant::now();
        for i in 0..200u32 {
            let m = i.to_le_bytes();
            assert_eq!(phoros_peer_send(host, PHOROS_CHANNEL_REALTIME, m.as_ptr(), m.len()), 0);
            std::thread::sleep(Duration::from_micros(500));
        }
        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline && client_side.received.load(Ordering::SeqCst) < 200 { std::thread::sleep(Duration::from_millis(2)); }
        let got = client_side.received.load(Ordering::SeqCst);
        println!("realtime channel: {got}/200 received in {:?}", t0.elapsed());
        assert!(got >= 190, "unordered channel delivered most messages: {got}");
        // client sends 100 more; the host echoes each from its callback; the client gets them
        let before = client_side.received.load(Ordering::SeqCst);
        for i in 0..100u32 { let m = i.to_le_bytes(); phoros_peer_send(client, PHOROS_CHANNEL_REALTIME, m.as_ptr(), m.len()); std::thread::sleep(Duration::from_micros(500)); }
        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline && client_side.received.load(Ordering::SeqCst) < before + 90 { std::thread::sleep(Duration::from_millis(2)); }
        println!("echoed: {}/100", client_side.received.load(Ordering::SeqCst) - before);
        assert!(client_side.received.load(Ordering::SeqCst) >= before + 90, "echo from inside a callback works");
        phoros_peer_destroy(client);
        phoros_peer_destroy(host);
    }
}
