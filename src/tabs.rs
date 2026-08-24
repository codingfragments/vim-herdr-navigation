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

/// Compute the wrapped neighbor index for a horizontal cross-tab move.
/// `Right` -> next (last wraps to 0); `Left` -> prev (0 wraps to last).
/// Returns None if there are fewer than 2 tabs, `cur_idx` is out of range,
/// or `dir` isn't horizontal.
fn wrapped_neighbor(len: usize, cur_idx: usize, dir: Direction) -> Option<usize> {
    if len < 2 || cur_idx >= len {
        return None;
    }
    match dir {
        Direction::Right => Some((cur_idx + 1) % len),
        Direction::Left => Some((cur_idx + len - 1) % len),
        _ => None,
    }
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
    // The destination tab is now active, so read its layout via `--current`
    // (the source pane is in the old tab and would report the old layout).
    let dest_layout_val = match crate::herdr::layout_current(herdr) {
        Some(v) => v,
        None => return true, // tab switched; leave herdr's restored pane
    };
    let dest_layout = match crate::layout::parse(&dest_layout_val) {
        Some(l) => l,
        None => return true,
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

    // --- wrapped_neighbor (cycling) ----------------------------------------

    #[test]
    fn wrapped_right_advances_and_wraps() {
        assert_eq!(wrapped_neighbor(3, 0, Direction::Right), Some(1));
        assert_eq!(wrapped_neighbor(3, 1, Direction::Right), Some(2));
        // last -> first (wrap)
        assert_eq!(wrapped_neighbor(3, 2, Direction::Right), Some(0));
    }

    #[test]
    fn wrapped_left_advances_and_wraps() {
        assert_eq!(wrapped_neighbor(3, 2, Direction::Left), Some(1));
        assert_eq!(wrapped_neighbor(3, 1, Direction::Left), Some(0));
        // first -> last (wrap)
        assert_eq!(wrapped_neighbor(3, 0, Direction::Left), Some(2));
    }

    #[test]
    fn wrapped_two_tabs_cycle() {
        // With 2 tabs, right and left both hop to the only other tab.
        assert_eq!(wrapped_neighbor(2, 0, Direction::Right), Some(1));
        assert_eq!(wrapped_neighbor(2, 1, Direction::Right), Some(0));
        assert_eq!(wrapped_neighbor(2, 1, Direction::Left), Some(0));
        assert_eq!(wrapped_neighbor(2, 0, Direction::Left), Some(1));
    }

    #[test]
    fn wrapped_single_tab_is_none() {
        assert_eq!(wrapped_neighbor(1, 0, Direction::Right), None);
        assert_eq!(wrapped_neighbor(1, 0, Direction::Left), None);
        assert_eq!(wrapped_neighbor(0, 0, Direction::Right), None);
    }

    #[test]
    fn wrapped_vertical_is_none() {
        assert_eq!(wrapped_neighbor(3, 1, Direction::Up), None);
        assert_eq!(wrapped_neighbor(3, 1, Direction::Down), None);
    }

    #[test]
    fn wrapped_out_of_range_is_none() {
        assert_eq!(wrapped_neighbor(3, 3, Direction::Right), None);
        assert_eq!(wrapped_neighbor(3, 5, Direction::Left), None);
    }
}
