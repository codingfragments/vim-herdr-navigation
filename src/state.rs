//! Per-tab preferred-coordinate state. Mirrors the state-file read/write in
//! navigate.sh: `${HERDR_NAV_STATE_DIR:-${XDG_STATE_HOME:-~/.local/state}/vim-herdr-navigation}/<tab_id with ':'→'_'>.json`
//! with `preferred_x`, `preferred_y`, `tab_id`, `updated`.
//!
//! Numbers are serialized jq-style: integral floats print without a trailing
//! `.0` (e.g. `25`, not `25.0`), matching jq's number formatting so state files
//! stay byte-compatible with the legacy shell version.

use std::fs;
use std::path::{Path, PathBuf};

use serde_json::{Map, Number, Value};

/// Resolve the state directory from env, matching the shell's expansion.
pub fn state_dir() -> PathBuf {
    if let Ok(d) = std::env::var("HERDR_NAV_STATE_DIR") {
        return PathBuf::from(d);
    }
    let base = std::env::var("XDG_STATE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
            PathBuf::from(home).join(".local").join("state")
        });
    base.join("vim-herdr-navigation")
}

/// `<state_dir>/<tab_id with ':'→'_'>.json`. Only `:` is sanitized.
pub fn state_file(tab_id: &str) -> PathBuf {
    let name = tab_id.replace(':', "_");
    state_dir().join(format!("{name}.json"))
}

/// Ensure the state directory exists (`mkdir -p`).
pub fn ensure_dir() {
    let _ = fs::create_dir_all(state_dir());
}

/// Read `preferred_x` / `preferred_y` from the state file as f64. Returns None
/// if the file is missing/corrupt or the key is absent (mirrors jq `// empty`).
pub fn read_pref(state_file: &Path, key: &str) -> Option<f64> {
    let txt = fs::read_to_string(state_file).ok()?;
    let v: Value = serde_json::from_str(&txt).ok()?;
    v.get(key)?.as_f64()
}

/// jq-style number: integral floats serialize as integers (no `.0`).
fn num(v: f64) -> Number {
    if v.is_finite() && v.fract() == 0.0 && v.abs() < 9_007_199_254_740_992.0 {
        Number::from(v as i64)
    } else {
        match Number::from_f64(v) {
            Some(n) => n,
            None => Number::from(0),
        }
    }
}

/// Persist both preferred coordinates + tab_id + updated. Mirrors the shell's
/// `jq '. + {…}'` merge (preserving any extra keys) with a printf fallback when
/// the file is missing/corrupt. Writes via a temp file + atomic rename.
pub fn write_state(
    state_file: &Path,
    along_key: &str,
    along_val: f64,
    cross_key: &str,
    cross_val: f64,
    tab_id: &str,
) {
    // `updated`: jq path (existing valid file) writes float `now`; the printf
    // fallback (missing/corrupt) writes integer seconds. Replicate both.
    let now_secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0);
    let had_existing = fs::read_to_string(state_file)
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .map(|v| v.is_object())
        .unwrap_or(false);

    let mut obj: Map<String, Value> = if had_existing {
        match serde_json::from_str::<Value>(&fs::read_to_string(state_file).unwrap_or_default())
            .ok()
        {
            Some(Value::Object(m)) => m,
            _ => Map::new(),
        }
    } else {
        Map::new()
    };
    obj.insert(along_key.to_string(), Value::Number(num(along_val)));
    obj.insert(cross_key.to_string(), Value::Number(num(cross_val)));
    obj.insert("tab_id".to_string(), Value::String(tab_id.to_string()));
    obj.insert(
        "updated".to_string(),
        Value::Number(if had_existing {
            num(now_secs)
        } else {
            Number::from(now_secs as i64)
        }),
    );

    // jq pretty-prints on the merge path (existing valid file) and the printf
    // fallback emits compact single-line JSON. Match both.
    let body = if had_existing {
        serde_json::to_string_pretty(&Value::Object(obj)).unwrap_or_default()
    } else {
        serde_json::to_string(&Value::Object(obj)).unwrap_or_default()
    };

    // Atomic write: <file>.tmp.<pid> then rename.
    let tmp = state_file.with_extension(format!(
        "tmp.{}",
        std::process::id()
    ));
    if fs::write(&tmp, format!("{body}\n")).is_ok() {
        let _ = fs::rename(&tmp, state_file);
    } else {
        let _ = fs::remove_file(&tmp);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_pref() {
        let dir = std::env::temp_dir().join("vhnav_state_test");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let f = dir.join("w_t1.json");
        write_state(&f, "preferred_x", 150.0, "preferred_y", 25.0, "w:t1");
        assert_eq!(read_pref(&f, "preferred_x"), Some(150.0));
        assert_eq!(read_pref(&f, "preferred_y"), Some(25.0));
        // jq-style: integral floats have no trailing .0
        let body = fs::read_to_string(&f).unwrap();
        assert!(body.contains("\"preferred_x\":150,"), "body was: {body}");
        assert!(body.contains("\"preferred_y\":25,"));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn fractional_pref_preserved() {
        let dir = std::env::temp_dir().join("vhnav_state_test2");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let f = dir.join("w_t1.json");
        write_state(&f, "preferred_x", 37.5, "preferred_y", 12.5, "w:t1");
        assert_eq!(read_pref(&f, "preferred_x"), Some(37.5));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn missing_file_returns_none() {
        assert!(read_pref(Path::new("/nonexistent/xyz.json"), "preferred_x").is_none());
    }
}
