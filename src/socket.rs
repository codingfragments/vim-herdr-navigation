//! Single-call focus-by-id over herdr's unix socket. Mirrors the python3
//! `focus_by_id` in navigate.sh: connect to `$HERDR_SOCKET_PATH`, send a
//! newline-delimited `pane.focus { pane_id }` JSON-RPC request, read until the
//! first newline, and treat success as `result` present and `error` absent.

use std::io::{Read, Write};
use std::os::unix::fs::FileTypeExt;
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::time::Duration;

use serde_json::json;

/// Resolve the socket path: `$HERDR_SOCKET_PATH` or `~/.config/herdr/herdr.sock`.
pub fn socket_path() -> std::path::PathBuf {
    if let Ok(p) = std::env::var("HERDR_SOCKET_PATH") {
        return std::path::PathBuf::from(p);
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    std::path::PathBuf::from(home)
        .join(".config")
        .join("herdr")
        .join("herdr.sock")
}

/// Send `pane.focus { pane_id }` over the socket. Returns true on success
/// (response has `result` and no `error`), false on any failure (missing socket,
/// connect error, timeout, bad JSON) — caller falls back to the walk path.
pub fn focus_by_id(sock_path: &Path, pane_id: &str) -> bool {
    // Only attempt if the path is a socket (mirrors `[ -S "$sock_path" ]`).
    match std::fs::metadata(sock_path) {
        Ok(m) => {
            if !m.file_type().is_socket() {
                return false;
            }
        }
        Err(_) => return false,
    }

    let mut s = match UnixStream::connect(sock_path) {
        Ok(s) => s,
        Err(_) => return false,
    };
    let _ = s.set_read_timeout(Some(Duration::from_secs(2)));
    let _ = s.set_write_timeout(Some(Duration::from_secs(2)));

    let req = json!({
        "id": "nav",
        "method": "pane.focus",
        "params": { "pane_id": pane_id }
    });
    let line = format!("{req}\n");
    if s.write_all(line.as_bytes()).is_err() {
        return false;
    }

    let mut data = Vec::new();
    let mut buf = [0u8; 4096];
    loop {
        match s.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                data.extend_from_slice(&buf[..n]);
                if data.contains(&b'\n') {
                    break;
                }
            }
            Err(_) => return false,
        }
    }

    let resp: serde_json::Value = match serde_json::from_slice(&data) {
        Ok(v) => v,
        Err(_) => return false,
    };
    resp.get("result").is_some() && resp.get("error").is_none()
}
