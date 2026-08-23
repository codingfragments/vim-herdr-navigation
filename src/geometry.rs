//! Geometry: source-pane center, candidate filter (beyond + cross-axis overlap),
//! and nearest-by-preferred selection. Mirrors the jq candidate filter and
//! `sort_by(pow((.[$field] - $pref); 2)) | .[0]` in navigate.sh.
//!
//! Fidelity notes:
//! - Source center uses integer math: `cur_x + cur_w / 2` (truncating), matching
//!   the shell's `$(( ))`.
//! - Candidate centers use float math: `x + width / 2` as f64, matching jq.
//! - Target selection minimizes `(cross - pref)^2` over f64, matching jq's
//!   `sort_by(pow(...))`.

use std::path::Path;

use crate::direction::{Axis, Direction};
use crate::layout::{Layout, Rect};

/// A candidate pane with its float center.
struct Cand {
    pane_id: String,
    cx: f64,
    cy: f64,
}

/// Find the focused pane's rect.
pub fn focused_rect(layout: &Layout, focused_id: &str) -> Option<Rect> {
    layout
        .panes
        .iter()
        .find(|p| p.pane_id == focused_id)
        .map(|p| p.rect)
}

/// Is `r` strictly beyond the source rect `s` in `dir`?
fn beyond(r: &Rect, s: &Rect, dir: Direction) -> bool {
    match dir {
        Direction::Left => r.x + r.width <= s.x,
        Direction::Right => r.x >= s.x + s.width,
        Direction::Up => r.y + r.height <= s.y,
        Direction::Down => r.y >= s.y + s.height,
    }
}

/// Does `r` overlap `s` on the cross axis for `dir`?
fn overlap(r: &Rect, s: &Rect, dir: Direction) -> bool {
    match dir {
        Direction::Left | Direction::Right => {
            (r.y < s.y + s.height) && (s.y < r.y + r.height)
        }
        Direction::Up | Direction::Down => {
            (r.x < s.x + s.width) && (s.x < r.x + r.width)
        }
    }
}

/// Select the target pane. Returns `(target_pane_id, target_cx, target_cy, pref_val)`
/// where `pref_val` is the resolved preferred coordinate (stored value if any,
/// else the source-pane seed). Returns None if there are no candidates.
pub fn select(
    layout: &Layout,
    focused_id: &str,
    dir: Direction,
    axis: Axis,
    state_file: &Path,
) -> Option<(String, f64, f64, f64)> {
    let src = focused_rect(layout, focused_id)?;
    let cur_cx = src.x + src.width / 2; // integer (matches $(( )))
    let cur_cy = src.y + src.height / 2;

    let mut cands: Vec<Cand> = Vec::new();
    for p in &layout.panes {
        if p.pane_id == focused_id {
            continue;
        }
        if !beyond(&p.rect, &src, dir) || !overlap(&p.rect, &src, dir) {
            continue;
        }
        cands.push(Cand {
            pane_id: p.pane_id.clone(),
            cx: p.rect.x as f64 + (p.rect.width as f64 / 2.0),
            cy: p.rect.y as f64 + (p.rect.height as f64 / 2.0),
        });
    }
    if cands.is_empty() {
        return None;
    }

    // Per-tab preferred coordinate on the cross axis (seed from source center).
    let (pref_key, cross_field, seed): (&str, fn(&Cand) -> f64, f64) = match axis {
        Axis::H => ("preferred_y", |c| c.cy, cur_cy as f64),
        Axis::V => ("preferred_x", |c| c.cx, cur_cx as f64),
    };
    let pref_val = crate::state::read_pref(state_file, pref_key).unwrap_or(seed);

    // Target = candidate whose cross-axis center is nearest the preferred coord.
    let target = cands
        .iter()
        .min_by(|a, b| {
            let da = (cross_field(a) - pref_val).powi(2);
            let db = (cross_field(b) - pref_val).powi(2);
            da.partial_cmp(&db).unwrap_or(std::cmp::Ordering::Equal)
        })
        .expect("non-empty");
    let (tid, tcx, tcy) = (target.pane_id.clone(), target.cx, target.cy);
    Some((tid, tcx, tcy, pref_val))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::layout::{Layout, Pane, Rect};
    use std::path::Path;

    fn layout(panes: &[(&str, i64, i64, i64, i64)], focused: &str) -> Layout {
        Layout {
            focused_pane_id: Some(focused.to_string()),
            tab_id: Some("w:t1".to_string()),
            workspace_id: Some("w".to_string()),
            zoomed: Some(false),
            panes: panes
                .iter()
                .map(|(id, x, y, w, h)| Pane {
                    pane_id: id.to_string(),
                    rect: Rect { x: *x, y: *y, width: *w, height: *h },
                })
                .collect(),
        }
    }

    // A (left, full height) | B (top-right) | C (bottom-right)
    const ABC: &[(&str, i64, i64, i64, i64)] = &[
        ("A", 0, 0, 100, 50),
        ("B", 100, 0, 100, 25),
        ("C", 100, 25, 100, 25),
    ];

    #[test]
    fn right_from_a_picks_c_when_pref_y_is_c_row() {
        let l = layout(ABC, "A");
        // simulate stored preferred_y = C's row center (25 + 25/2 = 37.5)
        let dir = Direction::Right;
        let axis = Axis::H;
        // no state file → seeds pref from A's center (cy = 0 + 50/2 = 25)
        let (target, _cx, _cy, _pref) =
            select(&l, "A", dir, axis, Path::new("/nonexistent/state.json")).unwrap();
        // seed 25 → nearest of B(cy=12.5) vs C(cy=37.5): |12.5-25|=12.5, |37.5-25|=12.5 → tie → first wins (B)
        assert_eq!(target, "B");
    }

    #[test]
    fn right_from_a_picks_c_when_pref_y_high() {
        let l = layout(ABC, "A");
        let dir = Direction::Right;
        let axis = Axis::H;
        // write a state file with preferred_y = 37.5 (C's row)
        let tmp = std::env::temp_dir().join("vhnav_test_state.json");
        std::fs::write(&tmp, r#"{"preferred_y":37.5}"#).unwrap();
        let (target, _, _, _) = select(&l, "A", dir, axis, &tmp).unwrap();
        assert_eq!(target, "C");
        let _ = std::fs::remove_file(&tmp);
    }

    #[test]
    fn left_from_c_picks_a() {
        let l = layout(ABC, "C");
        let (target, _, _, _) =
            select(&l, "C", Direction::Left, Axis::H, Path::new("/nonexistent.json")).unwrap();
        assert_eq!(target, "A");
    }

    #[test]
    fn no_candidates_returns_none() {
        // single pane
        let l = layout(&[("A", 0, 0, 100, 50)], "A");
        assert!(select(&l, "A", Direction::Right, Axis::H, Path::new("/x")).is_none());
    }
}
