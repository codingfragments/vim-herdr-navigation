//! Cross-tab navigation: when a horizontal move (left/right) hits the pane edge
//! (no candidate panes beyond in that direction), switch to the adjacent tab
//! in the same workspace instead of no-op'ing. `right` -> next tab, `left` ->
//! previous tab, ordered by the tab's `number` within its workspace.
//!
//! Opt-in, gated by `HERDR_NAV_CROSS_TABS=1` (default off) so existing edge
//! behavior is unchanged. The new tab's last-focused pane is restored by herdr
//! (we just call `tab.focus <tab_id>`); we do not write navigation state on a
//! cross-tab move.
//!
//! Socket is preferred (consistent with pane focus-by-id); the `herdr tab list`
//! / `herdr tab focus <tab_id>` CLI is the fallback.

use std::path::Path;

use serde::Deserialize;
use serde_json::Value;

use crate::direction::{Axis, Direction};
use crate::socket;

#[derive(Debug, Deserialize)]
pub struct TabInfo {
    pub tab_id: String,
    #[serde(default)]
    pub workspace_id: Option<String>,
    #[serde(default)]
    pub number: Option<u64>,
    #[serde(default)]
    #[allow(dead_code)]
    pub focused: Option<bool>,
}

/// Is cross-tab navigation enabled via the env var? `HERDR_NAV_CROSS_TABS`
/// in {1, true, yes, on}. (The `--cross-tabs` CLI flag overrides this; see
/// main.rs.)
pub fn env_enabled() -> bool {
    match std::env::var("HERDR_NAV_CROSS_TABS") {
        Ok(v) => matches!(
            v.trim().to_ascii_lowercase().as_str(),
            "1" | "true" | "yes" | "on"
        ),
        Err(_) => false,
    }
}

/// Parse a `tab.list` result array into typed `TabInfo`s.
fn parse_tabs(arr: &[Value]) -> Vec<TabInfo> {
    arr.iter()
        .filter_map(|v| serde_json::from_value::<TabInfo>(v.clone()).ok())
        .collect()
}

/// Fetch the tabs of `workspace_id`, ordered by `number` (stable on ties by
/// list order, which reflects the tab bar). Returns None on failure.
fn tabs_for_workspace(
    herdr: &str,
    sock_path: &Path,
    workspace_id: &str,
) -> Option<Vec<TabInfo>> {
    // Prefer the socket.
    if let Some(arr) = socket::list_tabs(sock_path, workspace_id) {
        let mut tabs = parse_tabs(&arr);
        tabs.sort_by_key(|t| t.number.unwrap_or(0));
        return Some(tabs);
    }
    // Fallback: `herdr tab list` CLI, filter client-side.
    let out = std::process::Command::new(herdr)
        .args(["tab", "list"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let v: Value = serde_json::from_slice(&out.stdout).ok()?;
    let arr = v
        .get("result")
        .and_then(|r| r.get("tabs"))
        .and_then(|t| t.as_array())?;
    let mut tabs: Vec<TabInfo> = parse_tabs(arr)
        .into_iter()
        .filter(|t| t.workspace_id.as_deref() == Some(workspace_id))
        .collect();
    tabs.sort_by_key(|t| t.number.unwrap_or(0));
    Some(tabs)
}

/// Focus the adjacent tab in `dir` (only horizontal moves cross tabs).
/// Returns true if a tab switch was performed, false otherwise (no neighbor,
/// not a horizontal move, or any lookup failure — caller falls back).
pub fn cross_tab(
    herdr: &str,
    sock_path: &Path,
    current_tab_id: &str,
    workspace_id: &str,
    dir: Direction,
) -> bool {
    if dir.axis() != Axis::H {
        return false;
    }
    let tabs = match tabs_for_workspace(herdr, sock_path, workspace_id) {
        Some(t) => t,
        None => return false,
    };
    let cur_idx = tabs.iter().position(|t| t.tab_id == current_tab_id);
    let cur_idx = match cur_idx {
        Some(i) => i,
        None => return false,
    };
    let neighbor = match dir {
        Direction::Right => cur_idx.checked_add(1),
        Direction::Left => cur_idx.checked_sub(1),
        _ => return false,
    };
    let neighbor = match neighbor {
        Some(i) if i < tabs.len() => i,
        _ => return false, // already at the last/first tab
    };
    let target_id = &tabs[neighbor].tab_id;

    // Prefer the socket; fall back to `herdr tab focus <tab_id>`.
    if socket::focus_tab(sock_path, target_id) {
        return true;
    }
    std::process::Command::new(herdr)
        .args(["tab", "focus", target_id])
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn enabled_defaults_off() {
        // Not set in test env.
        std::env::remove_var("HERDR_NAV_CROSS_TABS");
        assert!(!env_enabled());
    }

    #[test]
    fn enabled_truthy_values() {
        for v in ["1", "true", "TRUE", "yes", "on", " On "] {
            std::env::set_var("HERDR_NAV_CROSS_TABS", v);
            assert!(env_enabled(), "should be enabled for {v}");
        }
        for v in ["0", "false", "no", "off", "", "maybe"] {
            std::env::set_var("HERDR_NAV_CROSS_TABS", v);
            assert!(!env_enabled(), "should be disabled for {v}");
        }
        std::env::remove_var("HERDR_NAV_CROSS_TABS");
    }

    #[test]
    fn parse_tabs_extracts_fields() {
        let arr = serde_json::json!([
            { "tab_id": "w:t1", "workspace_id": "w", "number": 1, "focused": true },
            { "tab_id": "w:t2", "workspace_id": "w", "number": 2 }
        ]);
        let tabs = parse_tabs(arr.as_array().unwrap());
        assert_eq!(tabs.len(), 2);
        assert_eq!(tabs[0].tab_id, "w:t1");
        assert_eq!(tabs[0].number, Some(1));
        assert_eq!(tabs[1].focused, None);
    }
}
