//! Two-hop directional walk fallback. Used when the socket focus-by-id is
//! unavailable. Mirrors the walk loop in navigate.sh: issue the initial
//! `pane focus --direction <dir>`, then repeatedly re-read the layout, find the
//! currently focused pane, and step again on the cross axis toward the target
//! center until the target is focused or the pane-count bound is hit.

use crate::direction::Axis;
use crate::herdr;


/// Run the fallback walk toward `target` (whose center is `target_cx`,`target_cy`).
/// `pane` is the original `$HERDR_PANE_ID` used for all layout queries (the shell
/// always re-queries layout with `--pane "$pane"`, not the currently focused id).
pub fn walk(
    herdr: &str,
    pane: &str,
    dir: &str,
    axis: Axis,
    target: &str,
    target_cx: f64,
    target_cy: f64,
    total_panes: usize,
) {
    // Initial directional hop in the requested direction.
    let _ = herdr::focus_direction_silent(herdr, dir, Some(pane));

    let mut iter = 0;
    while iter < total_panes {
        iter += 1;

        let cur_val = match herdr::layout(herdr, pane) {
            Some(v) => v,
            None => break,
        };
        let cur = match crate::layout::parse(&cur_val) {
            Some(l) => l,
            None => break,
        };
        let cur_focused = match &cur.focused_pane_id {
            Some(f) if !f.is_empty() => f.clone(),
            _ => break,
        };
        if cur_focused == target {
            break;
        }

        // Secondary direction on the cross axis toward the target center.
        let rect = match cur.panes.iter().find(|p| p.pane_id == cur_focused) {
            Some(p) => p.rect,
            None => break,
        };
        let sec = match axis {
            Axis::H => {
                if target_cy < (rect.y as f64 + rect.height as f64 / 2.0) {
                    "up"
                } else {
                    "down"
                }
            }
            Axis::V => {
                if target_cx < (rect.x as f64 + rect.width as f64 / 2.0) {
                    "left"
                } else {
                    "right"
                }
            }
        };

        if !herdr::focus_direction_silent(herdr, sec, Some(&cur_focused)) {
            break;
        }
    }
}
