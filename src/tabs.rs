//! Cross-tab navigation: when a horizontal move (left/right) hits the pane edge
//! (no candidate panes beyond in that direction), switch to the adjacent tab
//! in the same workspace instead of no-op'ing. `right` -> next tab, `left` ->
//! previous tab, ordered by the tab's `number` within its workspace — and the
//! index **wraps**: `right` on the last tab cycles to the first, `left` on the
//! first tab cycles to the last, so the tabs behave like one continuous
//! horizontal strip.
//!
//! On arrival, the destination tab's **edge column** is selected (leftmost
//! column for a `right` move, rightmost for a `left` move) at the row nearest
//! the destination tab's stored `preferred_y` (seeded from the source pane's
//! center-y), and that pane is focused by id over the socket. The destination
//! tab's preferred coordinates are then persisted, mirroring an in-tab move.
//!
//! Opt-in, gated by `HERDR_NAV_CROSS_TABS=1` (default off) so existing edge
//! behavior is unchanged.
//!
//! Socket is preferred (consistent with pane focus-by-id); the `herdr tab list`
//! / `herdr tab focus <tab_id>` CLI is the fallback for the tab switch. The
//! edge-pane focus itself needs focus-by-id (the directional walk fallback
//! doesn't apply cleanly across a tab switch — the source pane lives in the old
//! tab), so if the socket is unavailable the tab still switches and herdr's
//! restored pane is left as-is.

use std::path::Path;

use serde::Deserialize;
use serde_json::Value;

use crate::cross::wrapped_neighbor;
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

/// Cross the tab boundary in `dir` (horizontal only) with wraparound, then
/// land on the destination tab's edge column at the preferred row. `seed_cy`
/// is the source pane's center-y, used to seed the destination tab's
/// `preferred_y` when it has no stored value. Returns true if a tab switch was
/// performed (the caller then exits); false lets the caller fall back to the
/// plain directional focus.
pub fn cross_tab(
    herdr: &str,
    sock_path: &Path,
    current_tab_id: &str,
    workspace_id: &str,
    dir: Direction,
    seed_cy: f64,
) -> bool {
    if dir.axis() != Axis::H {
        return false;
    }
    let tabs = match tabs_for_workspace(herdr, sock_path, workspace_id) {
        Some(t) => t,
        None => return false,
    };
    let cur_idx = match tabs.iter().position(|t| t.tab_id == current_tab_id) {
        Some(i) => i,
        None => return false,
    };
    let neighbor = match wrapped_neighbor(tabs.len(), cur_idx, dir) {
        Some(i) => i,
        None => return false, // fewer than 2 tabs — nothing to cycle to
    };
    let target_id = &tabs[neighbor].tab_id;

    // --- Read the destination tab's geometry (race-free) ------------------
    // A tab's pane layout is independent of focus, so read it from the session
    // snapshot BEFORE switching. `pane layout --current` can't be used here:
    // it resolves to the source pane's tab via `$HERDR_PANE_ID`, which would
    // hand us the *source* tab's layout and the subsequent focus-by-id would
    // yank focus back to the source tab (the "briefly in tab 2, then back to
    // tab 1" race). Socket preferred; `herdr api snapshot` CLI fallback.
    let dest_layout = socket::session_snapshot(sock_path)
        .and_then(|s| crate::layout::find_snapshot_layout(&s, target_id))
        .or_else(|| {
            let out = std::process::Command::new(herdr)
                .args(["api", "snapshot"])
                .output()
                .ok()?;
            if !out.status.success() {
                return None;
            }
            let v: Value = serde_json::from_slice(&out.stdout).ok()?;
            crate::layout::find_snapshot_layout(&v, target_id)
        });

    // --- Switch tabs: socket preferred, CLI fallback ----------------------
    let switched = if socket::focus_tab(sock_path, target_id) {
        true
    } else {
        std::process::Command::new(herdr)
            .args(["tab", "focus", target_id])
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
    };
    if !switched {
        return false;
    }

    // --- Land on the destination tab's edge column -----------------------
    let dest_layout = match dest_layout {
        Some(l) => l,
        None => return true, // tab switched; couldn't read geometry — leave restored pane
    };
    let dest_tab_id = match &dest_layout.tab_id {
        Some(t) if !t.is_empty() => t.clone(),
        _ => target_id.clone(),
    };
    let dest_state_file = crate::state::state_file(&dest_tab_id);
    let (target_pane, tcx, _tcy, pref_val) = match crate::geometry::select_edge_column(
        &dest_layout,
        dir,
        &dest_state_file,
        seed_cy,
    ) {
        Some(r) => r,
        None => return true, // tab switched; couldn't pick an edge pane
    };

    // Focus the edge pane by id over the socket. The directional walk
    // fallback doesn't apply across a tab switch (the source pane is in the
    // old tab), so if the socket is unavailable we leave the restored pane.
    if socket::focus_by_id(sock_path, &target_pane) {
        // Persist the destination tab's preferred coordinates, mirroring an
        // in-tab horizontal move: along = new column (preferred_x), across =
        // the row we targeted (preferred_y).
        crate::state::ensure_dir();
        crate::state::write_state(
            &dest_state_file,
            "preferred_x",
            tcx,
            "preferred_y",
            pref_val,
            &dest_tab_id,
        );
    }
    true
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

    // wrapped_neighbor cycling is tested in src/cross.rs (shared primitive).
}
