//! Cross-workspace navigation: when a vertical move (up/down) hits the pane edge
//! (no candidate panes beyond in that direction), switch to the adjacent
//! workspace in the same session instead of no-op'ing. `down` -> next
//! workspace, `up` -> previous workspace, ordered by the workspace's `number`
//! (sidebar order) — and the index **wraps**: `down` on the last workspace
//! cycles to the first, `up` on the first cycles to the last, so the workspace
//! stack behaves like the vertical leg of one continuous 2D torus.
//!
//! On arrival, the destination workspace's **active tab** is used (workspaces
//! have differing tab counts/labels, so we don't try to preserve "tab N"), and
//! within that tab the **edge row** is selected (topmost row for a `down` move,
//! bottommost for an `up` move) at the column nearest the destination tab's
//! stored `preferred_x` (seeded from the source pane's center-x). That pane is
//! focused by id over the socket, and the destination tab's preferred
//! coordinates are then persisted — mirroring an in-tab vertical move.
//!
//! Opt-in, gated by the cross-workspace scope (see [`crate::cross::Scope`]).
//!
//! Race-free destination geometry: the workspace list AND the destination tab's
//! layout are both read from a single `session.snapshot` taken BEFORE the
//! `workspace.focus` — a tab's layout is independent of focus, so there's no
//! dependence on the switch having "committed" (the same approach that fixed
//! the cross-tab `pane layout --current` race). Socket preferred; `herdr api
//! snapshot` CLI fallback.

use std::path::Path;

use serde_json::Value;

use crate::cross::wrapped_neighbor;
use crate::direction::{Axis, Direction};
use crate::socket;

/// Cross the workspace boundary in `dir` (vertical only) with wraparound, then
/// land on the destination workspace's active tab at its edge row, in the
/// column nearest the preferred x. `seed_cx` is the source pane's center-x,
/// used to seed the destination tab's `preferred_x` when it has no stored
/// value. Returns true if a workspace switch was performed (the caller then
/// exits); false lets the caller fall back to the plain directional focus.
pub fn cross_workspace(
    herdr: &str,
    sock_path: &Path,
    current_workspace_id: &str,
    dir: Direction,
    seed_cx: f64,
) -> bool {
    if dir.axis() != Axis::V {
        return false;
    }

    // --- Read the session snapshot (race-free) ---------------------------
    // One read serves both the ordered workspace list and the destination
    // tab's layout. Socket preferred; `herdr api snapshot` CLI fallback.
    let snapshot = socket::session_snapshot(sock_path).or_else(|| {
        let out = std::process::Command::new(herdr)
            .args(["api", "snapshot"])
            .output()
            .ok()?;
        if !out.status.success() {
            return None;
        }
        let v: Value = serde_json::from_slice(&out.stdout).ok()?;
        Some(v)
    });
    let snapshot = match snapshot {
        Some(s) => s,
        None => return false,
    };
    let workspaces = match crate::layout::snapshot_workspaces(&snapshot) {
        Some(w) => w,
        None => return false,
    };
    let cur_idx = match workspaces.iter().position(|w| w.workspace_id == current_workspace_id) {
        Some(i) => i,
        None => return false,
    };
    let neighbor = match wrapped_neighbor(workspaces.len(), cur_idx, dir) {
        Some(i) => i,
        None => return false, // fewer than 2 workspaces — nothing to cycle to
    };
    let dest_ws = &workspaces[neighbor];
    let dest_tab_id = &dest_ws.active_tab_id;

    // Destination tab's layout, from the same snapshot (race-free).
    let dest_layout = match crate::layout::find_snapshot_layout(&snapshot, dest_tab_id) {
        Some(l) => l,
        None => return false, // can't read geometry — don't switch blind
    };

    // --- Switch workspaces: socket preferred, CLI fallback ----------------
    let switched = if socket::workspace_focus(sock_path, &dest_ws.workspace_id) {
        true
    } else {
        std::process::Command::new(herdr)
            .args(["workspace", "focus", &dest_ws.workspace_id])
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
    };
    if !switched {
        return false;
    }

    // --- Land on the destination tab's edge row ---------------------------
    let dest_state_file = crate::state::state_file(dest_tab_id);
    let (target_pane, _tcx, tcy, pref_val) = match crate::geometry::select_edge_row(
        &dest_layout,
        dir,
        &dest_state_file,
        seed_cx,
    ) {
        Some(r) => r,
        None => return true, // workspace switched; couldn't pick an edge pane
    };

    // Focus the edge pane by id over the socket. The directional walk fallback
    // doesn't apply across a workspace switch (the source pane is in the old
    // workspace), so if the socket is unavailable we leave the restored pane.
    if socket::focus_by_id(sock_path, &target_pane) {
        // Persist the destination tab's preferred coordinates, mirroring an
        // in-tab vertical move: along = new row (preferred_y), across = the
        // column we targeted (preferred_x).
        crate::state::ensure_dir();
        crate::state::write_state(
            &dest_state_file,
            "preferred_y",
            tcy,
            "preferred_x",
            pref_val,
            dest_tab_id,
        );
    }
    true
}

#[cfg(test)]
mod tests {
    // cross_workspace is exercised end-to-end by test/dry-run.sh against a fake
    // herdr + socket. The cycling primitive (wrapped_neighbor) and the
    // edge-row selection (select_edge_row) have their own unit tests in
    // src/cross.rs and src/geometry.rs respectively.
}
