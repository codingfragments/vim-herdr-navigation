//! Serde structs for `herdr pane layout` JSON:
//!   {"result":{"layout":{
//!     "focused_pane_id":"…","tab_id":"…","zoomed":false,
//!     "panes":[{"pane_id":"…","rect":{"x":0,"y":0,"width":100,"height":50}, …}]}}}

use serde::Deserialize;
use serde_json::Value;

#[derive(Debug, Deserialize)]
pub struct LayoutResp {
    pub result: LayoutResult,
}

#[derive(Debug, Deserialize)]
pub struct LayoutResult {
    pub layout: Layout,
}

#[derive(Debug, Deserialize)]
pub struct Layout {
    #[serde(default)]
    pub focused_pane_id: Option<String>,
    #[serde(default)]
    pub tab_id: Option<String>,
    #[serde(default)]
    pub workspace_id: Option<String>,
    #[serde(default)]
    pub zoomed: Option<bool>,
    pub panes: Vec<Pane>,
}

#[derive(Debug, Deserialize)]
pub struct Pane {
    pub pane_id: String,
    pub rect: Rect,
}

#[derive(Debug, Deserialize, Clone, Copy)]
pub struct Rect {
    pub x: i64,
    pub y: i64,
    pub width: i64,
    pub height: i64,
}

/// Parse a raw layout JSON value into the typed layout. Returns None if the
/// shape doesn't match (mirrors jq `// empty` falling through to the plain
/// directional focus path).
pub fn parse(v: &Value) -> Option<Layout> {
    let resp: LayoutResp = serde_json::from_value(v.clone()).ok()?;
    Some(resp.result.layout)
}

/// From a `session.snapshot` response, find the pane-layout snapshot whose
/// `tab_id` matches. The snapshot's `layouts[]` entries have the same shape as
/// `pane.layout`'s result layout (extra `area`/`splits`/pane `focused` fields
/// are ignored by serde). Returns None if the snapshot is malformed or the tab
/// isn't present. Used by the cross-tab path to read the destination tab's
/// geometry without relying on `pane layout --current` (which resolves to the
/// source pane's tab via `$HERDR_PANE_ID`).
pub fn find_snapshot_layout(snapshot: &Value, tab_id: &str) -> Option<Layout> {
    let layouts = snapshot
        .get("result")?
        .get("snapshot")?
        .get("layouts")?
        .as_array()?;
    layouts
        .iter()
        .find(|l| l.get("tab_id").and_then(|t| t.as_str()) == Some(tab_id))
        .and_then(|l| serde_json::from_value(l.clone()).ok())
}
