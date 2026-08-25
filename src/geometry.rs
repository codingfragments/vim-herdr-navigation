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
use crate::layout::{Layout, Pane, Rect};

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

/// Select the edge-column pane of `layout` for a cross-tab arrival in `dir`.
/// `Right` lands on the leftmost column (min `x`); `Left` lands on the
/// rightmost column (max `x + width`). Within that column the pane whose
/// center-y is nearest the preferred y is chosen — stored value if any, else
/// `seed_cy` — so the row you were on survives the tab crossing. Vertical
/// directions never cross tabs and return None. Returns
/// `(pane_id, cx, cy, pref_val)` or None if the layout has no panes / no edge
/// column / a non-horizontal direction.
pub fn select_edge_column(
    layout: &Layout,
    dir: Direction,
    state_file: &Path,
    seed_cy: f64,
) -> Option<(String, f64, f64, f64)> {
    if layout.panes.is_empty() {
        return None;
    }
    // Edge column: Right -> leftmost (min x); Left -> rightmost (max x+width).
    let edge_panes: Vec<&Pane> = match dir {
        Direction::Right => {
            let min_x = layout.panes.iter().map(|p| p.rect.x).min()?;
            layout.panes.iter().filter(|p| p.rect.x == min_x).collect()
        }
        Direction::Left => {
            let max_xw = layout
                .panes
                .iter()
                .map(|p| p.rect.x + p.rect.width)
                .max()?;
            layout
                .panes
                .iter()
                .filter(|p| p.rect.x + p.rect.width == max_xw)
                .collect()
        }
        _ => return None, // vertical never crosses tabs
    };
    if edge_panes.is_empty() {
        return None;
    }
    let pref_val = crate::state::read_pref(state_file, "preferred_y").unwrap_or(seed_cy);
    let target = edge_panes.iter().min_by(|a, b| {
        let da = (a.rect.y as f64 + a.rect.height as f64 / 2.0 - pref_val).powi(2);
        let db = (b.rect.y as f64 + b.rect.height as f64 / 2.0 - pref_val).powi(2);
        da.partial_cmp(&db).unwrap_or(std::cmp::Ordering::Equal)
    })?;
    let tcx = target.rect.x as f64 + target.rect.width as f64 / 2.0;
    let tcy = target.rect.y as f64 + target.rect.height as f64 / 2.0;
    Some((target.pane_id.clone(), tcx, tcy, pref_val))
}

/// Select the edge-row pane of `layout` for a cross-workspace arrival in `dir`.
/// `Down` lands on the topmost row (min `y`); `Up` lands on the bottommost row
/// (max `y + height`). Within that row the pane whose center-x is nearest the
/// preferred x is chosen — stored value if any, else `seed_cx` — so the column
/// you were on survives the workspace crossing. Horizontal directions never
/// cross workspaces and return None. Returns `(pane_id, cx, cy, pref_val)` or
/// None if the layout has no panes / no edge row / a non-vertical direction.
pub fn select_edge_row(
    layout: &Layout,
    dir: Direction,
    state_file: &Path,
    seed_cx: f64,
) -> Option<(String, f64, f64, f64)> {
    if layout.panes.is_empty() {
        return None;
    }
    // Edge row: Down -> topmost (min y); Up -> bottommost (max y+height).
    let edge_panes: Vec<&Pane> = match dir {
        Direction::Down => {
            let min_y = layout.panes.iter().map(|p| p.rect.y).min()?;
            layout.panes.iter().filter(|p| p.rect.y == min_y).collect()
        }
        Direction::Up => {
            let max_yh = layout
                .panes
                .iter()
                .map(|p| p.rect.y + p.rect.height)
                .max()?;
            layout
                .panes
                .iter()
                .filter(|p| p.rect.y + p.rect.height == max_yh)
                .collect()
        }
        _ => return None, // horizontal never crosses workspaces
    };
    if edge_panes.is_empty() {
        return None;
    }
    let pref_val = crate::state::read_pref(state_file, "preferred_x").unwrap_or(seed_cx);
    let target = edge_panes.iter().min_by(|a, b| {
        let da = (a.rect.x as f64 + a.rect.width as f64 / 2.0 - pref_val).powi(2);
        let db = (b.rect.x as f64 + b.rect.width as f64 / 2.0 - pref_val).powi(2);
        da.partial_cmp(&db).unwrap_or(std::cmp::Ordering::Equal)
    })?;
    let tcx = target.rect.x as f64 + target.rect.width as f64 / 2.0;
    let tcy = target.rect.y as f64 + target.rect.height as f64 / 2.0;
    Some((target.pane_id.clone(), tcx, tcy, pref_val))
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

    // --- cross-tab edge-column selection (select_edge_column) ---------------

    // Tab 2 layout for the wrap target: D spans the full width (single pane).
    const D_ONLY: &[(&str, i64, i64, i64, i64)] = &[("D", 0, 0, 200, 50)];

    #[test]
    fn edge_column_right_lands_on_leftmost() {
        // Moving Right into tab 1 -> leftmost column = {A}.
        let l = layout(ABC, "B"); // focused pane irrelevant for edge selection
        let (target, _, _, _) =
            select_edge_column(&l, Direction::Right, Path::new("/nonexistent.json"), 25.0).unwrap();
        assert_eq!(target, "A");
    }

    #[test]
    fn edge_column_left_lands_on_rightmost_nearest_row() {
        // Moving Left into tab 1 -> rightmost column = {B, C}. seed_cy = 25 is
        // equidistant from B(cy=12.5) and C(cy=37.5); tie -> first in layout
        // order (B).
        let l = layout(ABC, "A");
        let (target, _, _, pref) =
            select_edge_column(&l, Direction::Left, Path::new("/nonexistent.json"), 25.0).unwrap();
        assert_eq!(target, "B");
        assert_eq!(pref, 25.0);
    }

    #[test]
    fn edge_column_left_uses_stored_preferred_y() {
        // Stored preferred_y = 37.5 (C's row) -> moving Left lands on C.
        let l = layout(ABC, "A");
        let tmp = std::env::temp_dir().join("vhnav_edge_state.json");
        std::fs::write(&tmp, r#"{"preferred_y":37.5}"#).unwrap();
        let (target, _, _, _) =
            select_edge_column(&l, Direction::Left, &tmp, 25.0).unwrap();
        assert_eq!(target, "C");
        let _ = std::fs::remove_file(&tmp);
    }

    #[test]
    fn edge_column_single_pane_lands_on_it() {
        // Tab 2 has only D; both directions land on D.
        let l = layout(D_ONLY, "D");
        let (t_right, _, _, _) =
            select_edge_column(&l, Direction::Right, Path::new("/x"), 25.0).unwrap();
        let (t_left, _, _, _) =
            select_edge_column(&l, Direction::Left, Path::new("/x"), 25.0).unwrap();
        assert_eq!(t_right, "D");
        assert_eq!(t_left, "D");
    }

    #[test]
    fn edge_column_vertical_returns_none() {
        let l = layout(ABC, "A");
        assert!(select_edge_column(&l, Direction::Up, Path::new("/x"), 25.0).is_none());
        assert!(select_edge_column(&l, Direction::Down, Path::new("/x"), 25.0).is_none());
    }

    #[test]
    fn edge_column_empty_layout_returns_none() {
        let l = layout(&[], "A");
        assert!(select_edge_column(&l, Direction::Right, Path::new("/x"), 25.0).is_none());
    }

    // --- cross-workspace edge-row selection (select_edge_row) ---------------
    // Vertical mirror of select_edge_column. ABC layout:
    //   A (left, full height) | B (top-right) | C (bottom-right)
    //   A: x=0,  y=0,  w=100, h=50  -> cx=50,  cy=25
    //   B: x=100,y=0,  w=100, h=25  -> cx=150, cy=12.5
    //   C: x=100,y=25, w=100, h=25  -> cx=150, cy=37.5

    #[test]
    fn edge_row_down_lands_on_topmost() {
        // Down into tab 1 -> topmost row = {A, B} (y=0). seed_cx = 50 (A's
        // column) -> nearest is A (cx=50) over B (cx=150).
        let l = layout(ABC, "C");
        let (target, _, _, _) =
            select_edge_row(&l, Direction::Down, Path::new("/nonexistent.json"), 50.0).unwrap();
        assert_eq!(target, "A");
    }

    #[test]
    fn edge_row_up_lands_on_bottommost_nearest_col() {
        // Up into tab 1 -> bottommost row = {A, C} (A spans full height, so
        // y+h=50; C ends at y+h=50). seed_cx = 150 (right column) -> nearest
        // is C (cx=150) over A (cx=50).
        let l = layout(ABC, "B");
        let (target, _, _, pref) =
            select_edge_row(&l, Direction::Up, Path::new("/nonexistent.json"), 150.0).unwrap();
        assert_eq!(target, "C");
        assert_eq!(pref, 150.0);
    }

    #[test]
    fn edge_row_up_uses_stored_preferred_x() {
        // Stored preferred_x = 50 (A's column) -> Up lands on A.
        let l = layout(ABC, "B");
        let tmp = std::env::temp_dir().join("vhnav_edge_row_state.json");
        std::fs::write(&tmp, r#"{"preferred_x":50}"#).unwrap();
        let (target, _, _, _) =
            select_edge_row(&l, Direction::Up, &tmp, 150.0).unwrap();
        assert_eq!(target, "A");
        let _ = std::fs::remove_file(&tmp);
    }

    #[test]
    fn edge_row_single_pane_lands_on_it() {
        let l = layout(D_ONLY, "D");
        let (t_down, _, _, _) =
            select_edge_row(&l, Direction::Down, Path::new("/x"), 25.0).unwrap();
        let (t_up, _, _, _) =
            select_edge_row(&l, Direction::Up, Path::new("/x"), 25.0).unwrap();
        assert_eq!(t_down, "D");
        assert_eq!(t_up, "D");
    }

    #[test]
    fn edge_row_horizontal_returns_none() {
        let l = layout(ABC, "A");
        assert!(select_edge_row(&l, Direction::Left, Path::new("/x"), 25.0).is_none());
        assert!(select_edge_row(&l, Direction::Right, Path::new("/x"), 25.0).is_none());
    }

    #[test]
    fn edge_row_empty_layout_returns_none() {
        let l = layout(&[], "A");
        assert!(select_edge_row(&l, Direction::Down, Path::new("/x"), 25.0).is_none());
    }
}
