//! Unix-socket JSON-RPC client for herdr. Used for the single-call focus-by-id
//! (`pane.focus`), tab listing (`tab.list`), and tab focus (`tab.focus`).
//! Mirrors the python3 `focus_by_id` in the legacy navigate.sh: connect to
//! `$HERDR_SOCKET_PATH`, send a newline-delimited JSON-RPC request, read until
//! the first newline, parse the response.

use std::io::{Read, Write};
use std::os::unix::fs::FileTypeExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{json, Value};

/// Resolve the socket path: `$HERDR_SOCKET_PATH` or `~/.config/herdr/herdr.sock`.
pub fn socket_path() -> PathBuf {
    if let Ok(p) = std::env::var("HERDR_SOCKET_PATH") {
        return PathBuf::from(p);
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    PathBuf::from(home)
        .join(".config")
        .join("herdr")
        .join("herdr.sock")
}

/// True iff the resolved socket path exists and is a unix socket.
fn is_socket(sock_path: &Path) -> bool {
    std::fs::metadata(sock_path)
        .map(|m| m.file_type().is_socket())
        .unwrap_or(false)
}

/// Send a JSON-RPC request and read the (first) newline-delimited response.
/// Returns None on any I/O, timeout, or JSON failure.
fn call(sock_path: &Path, method: &str, params: Value) -> Option<Value> {
    if !is_socket(sock_path) {
        return None;
    }
    let mut s = UnixStream::connect(sock_path).ok()?;
    let _ = s.set_read_timeout(Some(Duration::from_secs(2)));
    let _ = s.set_write_timeout(Some(Duration::from_secs(2)));

    let req = json!({ "id": "nav", "method": method, "params": params });
    let line = format!("{req}\n");
    s.write_all(line.as_bytes()).ok()?;

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
            Err(_) => return None,
        }
    }
    serde_json::from_slice(&data).ok()
}

/// `pane.focus { pane_id }` over the socket. Success = `result` present and
/// `error` absent (mirrors the legacy python3 check).
pub fn focus_by_id(sock_path: &Path, pane_id: &str) -> bool {
    let resp = match call(sock_path, "pane.focus", json!({ "pane_id": pane_id })) {
        Some(r) => r,
        None => return false,
    };
    resp.get("result").is_some() && resp.get("error").is_none()
}

/// `tab.list { workspace_id }` over the socket → the `result.tabs` array, or
/// None on failure.
pub fn list_tabs(sock_path: &Path, workspace_id: &str) -> Option<Vec<Value>> {
    let resp = call(
        sock_path,
        "tab.list",
        json!({ "workspace_id": workspace_id }),
    )?;
    resp.get("result")
        .and_then(|r| r.get("tabs"))
        .and_then(|t| t.as_array())
        .cloned()
}

/// `tab.focus { tab_id }` over the socket. Success = `result` present and
/// `error` absent.
pub fn focus_tab(sock_path: &Path, tab_id: &str) -> bool {
    let resp = match call(sock_path, "tab.focus", json!({ "tab_id": tab_id })) {
        Some(r) => r,
        None => return false,
    };
    resp.get("result").is_some() && resp.get("error").is_none()
}
