//! vim-herdr-navigation — herdr side (Rust port of navigate.sh).
//!
//! Invoked by a herdr keybind as: navigate <left|down|up|right>
//!
//! If the focused pane is running Vim/Neovim in the foreground, hand the matching
//! Ctrl chord to that pane so Vim moves between its own splits (and, at a split
//! edge, calls back into herdr to cross the pane boundary — see editor/*). The
//! same forwarding can be turned on for other TUIs that own Ctrl+h/j/k/l
//! themselves via HERDR_NAV_PASSTHROUGH_RE (off by default). For any other
//! foreground process, move herdr's pane focus directly — with smart target
//! selection (per-tab preferred coordinate) and a single focus-by-id call over
//! the herdr socket, falling back to a two-hop directional walk.

mod direction;
mod geometry;
mod herdr;
mod layout;
mod socket;
mod state;
mod tabs;
mod vim;
mod walk;

use std::process::exit;

use direction::{Axis, Direction};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() {
        eprintln!("usage: navigate [--no-forward] [--cross-tabs] <left|down|up|right>");
        exit(2);
    }
    // Flags (may appear before the direction):
    //   --no-forward / -n   skip Vim detection + key forwarding; go straight to
    //                       the herdr pane-focus path. Used by the editor side
    //                       when it has already detected a Vim split edge and
    //                       wants to cross into herdr WITHOUT navigate forwarding
    //                       the chord back into Vim (which would loop).
    //   --cross-tabs / -t   opt in to cross-tab navigation at the horizontal
    //                       edge (overrides HERDR_NAV_CROSS_TABS).
    let mut cross_tabs_override: Option<bool> = None;
    let mut no_forward = false;
    let mut positional: Vec<&str> = Vec::new();
    for a in &args {
        match a.as_str() {
            "--cross-tabs" | "-t" => cross_tabs_override = Some(true),
            "--no-cross-tabs" => cross_tabs_override = Some(false),
            "--no-forward" | "-n" => no_forward = true,
            "--" => {
                // treat the rest as positional
                continue;
            }
            _ if a.starts_with('-') && a.len() > 1 && !positional.is_empty() => {
                // allow the direction to look like a path component; unknown flags after a positional are ignored
                positional.push(a);
            }
            _ => positional.push(a),
        }
    }
    let dir_arg = match positional.first() {
        Some(d) => d,
        None => {
            eprintln!("usage: navigate [--no-forward] [--cross-tabs] <left|down|up|right>");
            exit(2);
        }
    };
    let dir = match Direction::from_str(dir_arg) {
        Ok(d) => d,
        Err(_) => {
            eprintln!("navigate: unknown direction: {dir_arg}");
            exit(2);
        }
    };
    let key = dir.key();
    let axis = dir.axis();
    let dir_name = dir.name();
    let herdr = herdr::herdr_bin();
    let pane = herdr::pane_id();

    // Cross-tab navigation: enabled by `--cross-tabs` flag (overrides env) or
    // by HERDR_NAV_CROSS_TABS=1. Computed once so the no-candidate path can use it.
    let cross_tabs = cross_tabs_override.unwrap_or_else(tabs::env_enabled);

    // --- Vim detection + forward -------------------------------------------
    // Skipped entirely when --no-forward is set (caller is the editor side
    // crossing a Vim split edge; forwarding the chord back would loop).
    let passthrough_re = std::env::var("HERDR_NAV_PASSTHROUGH_RE").unwrap_or_default();
    let mut forward = false;
    if !no_forward {
        if let Some(p) = &pane {
            if let Some(info) = herdr::process_info(&herdr, p) {
                if vim::is_vim_foreground(&info, &passthrough_re) {
                    forward = true;
                }
            }
        }
    }
    if forward {
        // exec herdr pane send-keys <pane> <key>
        herdr::send_keys(&herdr, &pane.unwrap(), key);
    }

    // --- Plain directional focus (no pane id) ------------------------------
    let pane = match pane {
        Some(p) => p,
        None => herdr::focus_direction(&herdr, dir_name, None), // --current, exec
    };

    // --- Layout fetch ------------------------------------------------------
    let layout_val = match herdr::layout(&herdr, &pane) {
        Some(v) => v,
        None => herdr::focus_direction(&herdr, dir_name, Some(&pane)),
    };
    let layout = match layout::parse(&layout_val) {
        Some(l) => l,
        None => herdr::focus_direction(&herdr, dir_name, Some(&pane)),
    };

    if layout.zoomed.unwrap_or(false) {
        herdr::focus_direction(&herdr, dir_name, Some(&pane));
    }
    let tab_id = match &layout.tab_id {
        Some(t) if !t.is_empty() => t.clone(),
        _ => herdr::focus_direction(&herdr, dir_name, Some(&pane)),
    };
    let focused_id = match &layout.focused_pane_id {
        Some(f) if !f.is_empty() => f.clone(),
        _ => herdr::focus_direction(&herdr, dir_name, Some(&pane)),
    };

    // --- Geometry + smart target selection --------------------------------
    let state_file = state::state_file(&tab_id);
    let (target, target_cx, target_cy, pref_val) = match geometry::select(
        &layout,
        &focused_id,
        dir,
        axis,
        &state_file,
    ) {
        Some(r) => r,
        None => {
            // No candidate pane in this direction (we're at an edge). If
            // cross-tab navigation is enabled and this is a horizontal move,
            // switch to the adjacent tab in the same workspace. Otherwise fall
            // back to the plain directional focus (a no-op at the edge).
            if cross_tabs && axis == Axis::H {
                let ws = layout.workspace_id.clone().unwrap_or_default();
                let sock = socket::socket_path();
                if !ws.is_empty()
                    && tabs::cross_tab(&herdr, &sock, &tab_id, &ws, dir)
                {
                    exit(0);
                }
            }
            herdr::focus_direction(&herdr, dir_name, Some(&pane));
        }
    };
    state::ensure_dir();

    // --- Focus by id over the socket (primary path) -----------------------
    let sock_path = socket::socket_path();
    let mut focused_ok = false;
    if socket::focus_by_id(&sock_path, &target) {
        focused_ok = true;
    }

    // --- Fallback: two-hop directional walk --------------------------------
    if !focused_ok {
        let total_panes = layout.panes.len();
        walk::walk(
            &herdr,
            &pane,
            dir_name,
            axis,
            &target,
            target_cx,
            target_cy,
            total_panes,
        );
    }

    // --- Persist preferred coordinates ------------------------------------
    // Along the moved axis: store the new center. Across the axis: preserve the
    // preference we just targeted with (stored value if any, else the seed) — so
    // the row/column you're conceptually on survives a move on the other axis.
    let (fin_cx, fin_cy) = if focused_ok {
        (target_cx, target_cy)
    } else {
        // Re-read to be safe (walk path).
        match herdr::layout(&herdr, &pane).and_then(|v| layout::parse(&v)) {
            Some(l) => match &l.focused_pane_id {
                Some(f) if !f.is_empty() => {
                    match l.panes.iter().find(|p| p.pane_id == *f) {
                        Some(p) => (
                            p.rect.x as f64 + p.rect.width as f64 / 2.0,
                            p.rect.y as f64 + p.rect.height as f64 / 2.0,
                        ),
                        None => (f64::NAN, f64::NAN),
                    }
                }
                _ => (f64::NAN, f64::NAN),
            },
            None => (f64::NAN, f64::NAN),
        }
    };

    if fin_cx.is_finite() && fin_cy.is_finite() {
        let (along_key, along_val, cross_key, cross_val) = match axis {
            Axis::H => ("preferred_x", fin_cx, "preferred_y", pref_val),
            Axis::V => ("preferred_y", fin_cy, "preferred_x", pref_val),
        };
        state::write_state(&state_file, along_key, along_val, cross_key, cross_val, &tab_id);
    }

    exit(0);
}
