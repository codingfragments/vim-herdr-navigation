//! Wrappers around the `herdr` CLI subprocess. Mirrors the `herdr` invocations
//! in navigate.sh: `pane process-info`, `pane layout`, `pane send-keys`,
//! `pane focus --direction`.

use std::path::Path;
use std::process::{Command, ExitStatus, Stdio};

use serde_json::Value;

/// Resolved herdr binary path: `$HERDR_BIN_PATH` or `herdr`.
pub fn herdr_bin() -> String {
    std::env::var("HERDR_BIN_PATH").unwrap_or_else(|_| "herdr".to_string())
}

/// `$HERDR_PANE_ID` if set and non-empty.
pub fn pane_id() -> Option<String> {
    std::env::var("HERDR_PANE_ID")
        .ok()
        .filter(|s| !s.is_empty())
}

/// `herdr pane process-info --pane <pane>` → parsed JSON, or None on failure.
pub fn process_info(herdr: &str, pane: &str) -> Option<Value> {
    let out = Command::new(herdr)
        .args(["pane", "process-info", "--pane", pane])
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    serde_json::from_slice(&out.stdout).ok()
}

/// `herdr pane layout --pane <pane>` → parsed JSON, or None on failure / empty.
pub fn layout(herdr: &str, pane: &str) -> Option<Value> {
    let out = Command::new(herdr)
        .args(["pane", "layout", "--pane", pane])
        .stderr(Stdio::null())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&out.stdout);
    if stdout.trim().is_empty() {
        return None;
    }
    serde_json::from_str(&stdout).ok()
}

/// Run a herdr subcommand inheriting stdio and return its exit status.
/// Used for fire-and-forget calls inside the walk fallback.
fn run_inherit(herdr: &str, args: &[&str]) -> bool {
    Command::new(herdr)
        .args(args)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .stdin(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// `herdr pane focus --direction <dir> [--pane <pane> | --current]` (silent).
pub fn focus_direction_silent(herdr: &str, dir: &str, pane: Option<&str>) -> bool {
    match pane {
        Some(p) => run_inherit(herdr, &["pane", "focus", "--direction", dir, "--pane", p]),
        None => run_inherit(herdr, &["pane", "focus", "--direction", dir, "--current"]),
    }
}

/// `exec herdr pane send-keys <pane> <key>` — replaces the process.
pub fn send_keys(herdr: &str, pane: &str, key: &str) -> ! {
    let status = Command::new(herdr)
        .args(["pane", "send-keys", pane, key])
        .status()
        .unwrap_or_else(|_| ExitStatus::default());
    std::process::exit(status.code().unwrap_or(1));
}

/// `exec herdr pane focus --direction <dir> [--pane <pane> | --current]` —
/// replaces the process (matches the shell's `exec` on the fallback paths).
pub fn focus_direction(herdr: &str, dir: &str, pane: Option<&str>) -> ! {
    let status = match pane {
        Some(p) => Command::new(herdr)
            .args(["pane", "focus", "--direction", dir, "--pane", p])
            .status()
            .unwrap_or_else(|_| ExitStatus::default()),
        None => Command::new(herdr)
            .args(["pane", "focus", "--direction", dir, "--current"])
            .status()
            .unwrap_or_else(|_| ExitStatus::default()),
    };
    std::process::exit(status.code().unwrap_or(1));
}

/// Run a command and report success, swallowing all output. Kept for symmetry
/// with the walk path's `>/dev/null 2>&1 || true` calls.
#[allow(dead_code)]
pub fn _run_quiet(_herdr: &str, _args: &[&str], _pane: &str, _path: &Path) -> bool {
    false
}
