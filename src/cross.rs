//! Unified cross-surface navigation scope + the shared cycling primitive.
//!
//! Herdr is a recursive 2D torus: pane grid (the focused tab) → tab strip
//! (horizontal, wraps) → workspace stack (vertical, wraps). A crossing always
//! lands on the destination's edge and preserves the cross-axis coordinate.
//!
//! This module owns:
//! - [`Scope`]: which surfaces a move may cross (`off` / `tabs` / `workspaces`
//!   / `both`), resolved once from the CLI flags + env.
//! - [`wrapped_neighbor`]: the modular index step shared by tab and workspace
//!   cycling (last → first on `Right`/`Down`, first → last on `Left`/`Up`).

use crate::direction::Direction;

/// Which surfaces a navigation move is allowed to cross at an edge.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scope {
    /// No crossing — a move at an edge is a no-op (the default).
    Off,
    /// Cross tabs at the horizontal edge (left/right).
    Tabs,
    /// Cross workspaces at the vertical edge (up/down).
    Workspaces,
    /// Full 2D torus: tabs horizontally, workspaces vertically.
    Both,
}

impl Scope {
    /// May a move on `axis` cross to the adjacent surface at the edge?
    pub fn crosses(self, axis: crate::direction::Axis) -> bool {
        match (self, axis) {
            (Scope::Off, _) => false,
            (Scope::Tabs, crate::direction::Axis::H) => true,
            (Scope::Workspaces, crate::direction::Axis::V) => true,
            (Scope::Both, _) => true,
            _ => false,
        }
    }
}

/// Resolve the cross scope from a `--cross <scope>` override (already parsed by
/// the caller) and the `HERDR_NAV_CROSS` env var. The legacy `--cross-tabs` /
/// `HERDR_NAV_CROSS_TABS=1` opt-in maps to [`Scope::Tabs`] for back-compat.
///
/// Precedence: explicit `--cross` > legacy `--cross-tabs`/`HERDR_NAV_CROSS_TABS`
/// > `HERDR_NAV_CROSS` > [`Scope::Off`].
pub fn resolve_scope(cross_override: Option<Scope>, legacy_cross_tabs: Option<bool>) -> Scope {
    if let Some(s) = cross_override {
        return s;
    }
    if let Some(on) = legacy_cross_tabs {
        return if on { Scope::Tabs } else { Scope::Off };
    }
    match std::env::var("HERDR_NAV_CROSS") {
        Ok(v) => match v.trim().to_ascii_lowercase().as_str() {
            "off" | "0" | "false" | "no" | "none" => Scope::Off,
            "tabs" | "tab" => Scope::Tabs,
            "workspaces" | "workspace" | "ws" => Scope::Workspaces,
            "both" | "all" | "1" | "true" | "yes" | "on" => Scope::Both,
            _ => Scope::Off, // unknown value → safe default
        },
        Err(_) => {
            // Legacy env var, still honored for back-compat.
            if crate::tabs::env_enabled() {
                Scope::Tabs
            } else {
                Scope::Off
            }
        }
    }
}

/// Parse a `--cross <scope>` argument value into a [`Scope`]. Returns None on
/// an unrecognized value (the caller reports the usage error).
pub fn parse_scope(s: &str) -> Option<Scope> {
    match s.trim().to_ascii_lowercase().as_str() {
        "off" | "0" | "false" | "no" | "none" => Some(Scope::Off),
        "tabs" | "tab" => Some(Scope::Tabs),
        "workspaces" | "workspace" | "ws" => Some(Scope::Workspaces),
        "both" | "all" | "1" | "true" | "yes" | "on" => Some(Scope::Both),
        _ => None,
    }
}

/// Compute the wrapped neighbor index for a cross-surface move. `Right`/`Down`
/// → next (last wraps to 0); `Left`/`Up` → prev (0 wraps to last). Returns
/// None if there are fewer than 2 surfaces, `cur_idx` is out of range, or the
/// direction isn't one of the four cardinals.
pub fn wrapped_neighbor(len: usize, cur_idx: usize, dir: Direction) -> Option<usize> {
    if len < 2 || cur_idx >= len {
        return None;
    }
    match dir {
        Direction::Right | Direction::Down => Some((cur_idx + 1) % len),
        Direction::Left | Direction::Up => Some((cur_idx + len - 1) % len),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::direction::Axis;

    #[test]
    fn scope_crosses() {
        assert!(!Scope::Off.crosses(Axis::H));
        assert!(!Scope::Off.crosses(Axis::V));
        assert!(Scope::Tabs.crosses(Axis::H));
        assert!(!Scope::Tabs.crosses(Axis::V));
        assert!(Scope::Workspaces.crosses(Axis::V));
        assert!(!Scope::Workspaces.crosses(Axis::H));
        assert!(Scope::Both.crosses(Axis::H));
        assert!(Scope::Both.crosses(Axis::V));
    }

    #[test]
    fn resolve_explicit_override_wins() {
        std::env::set_var("HERDR_NAV_CROSS", "both");
        assert_eq!(resolve_scope(Some(Scope::Off), None), Scope::Off);
        assert_eq!(resolve_scope(Some(Scope::Workspaces), None), Scope::Workspaces);
        std::env::remove_var("HERDR_NAV_CROSS");
    }

    #[test]
    fn resolve_legacy_cross_tabs() {
        std::env::remove_var("HERDR_NAV_CROSS");
        assert_eq!(resolve_scope(None, Some(true)), Scope::Tabs);
        assert_eq!(resolve_scope(None, Some(false)), Scope::Off);
    }

    #[test]
    fn resolve_env_cross() {
        std::env::remove_var("HERDR_NAV_CROSS_TABS");
        for (v, exp) in [
            ("off", Scope::Off),
            ("tabs", Scope::Tabs),
            ("workspaces", Scope::Workspaces),
            ("both", Scope::Both),
            ("ALL", Scope::Both),
            ("garbage", Scope::Off),
        ] {
            std::env::set_var("HERDR_NAV_CROSS", v);
            assert_eq!(resolve_scope(None, None), exp, "HERDR_NAV_CROSS={v}");
        }
        std::env::remove_var("HERDR_NAV_CROSS");
    }

    #[test]
    fn resolve_legacy_env_falls_back() {
        std::env::remove_var("HERDR_NAV_CROSS");
        std::env::set_var("HERDR_NAV_CROSS_TABS", "1");
        assert_eq!(resolve_scope(None, None), Scope::Tabs);
        std::env::remove_var("HERDR_NAV_CROSS_TABS");
        assert_eq!(resolve_scope(None, None), Scope::Off);
    }

    #[test]
    fn parse_scope_recognizes_values() {
        assert_eq!(parse_scope("tabs"), Some(Scope::Tabs));
        assert_eq!(parse_scope("WS"), Some(Scope::Workspaces));
        assert_eq!(parse_scope("both"), Some(Scope::Both));
        assert_eq!(parse_scope("off"), Some(Scope::Off));
        assert_eq!(parse_scope("nonsense"), None);
    }

    #[test]
    fn wrapped_vertical_wraps() {
        // Down advances and wraps; Up retreats and wraps.
        assert_eq!(wrapped_neighbor(3, 0, Direction::Down), Some(1));
        assert_eq!(wrapped_neighbor(3, 2, Direction::Down), Some(0));
        assert_eq!(wrapped_neighbor(3, 0, Direction::Up), Some(2));
        assert_eq!(wrapped_neighbor(3, 1, Direction::Up), Some(0));
    }
}
