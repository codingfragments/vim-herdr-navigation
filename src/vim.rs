//! Vim/Neovim foreground detection + opt-in passthrough for other TUIs.
//! Mirrors the jq filter in navigate.sh:
//!   .result.process_info.foreground_processes[]?.name
//!     | ascii_downcase
//!     | select(test($vim) or ($pass != "" and (try test($pass) catch false)))

use fancy_regex::Regex;
use serde_json::Value;

/// Same matcher vim-tmux-navigator uses: vi, vim, nvim, view, gvim, *diff, ...
const VIM_RE: &str = r"^g?(view|l?n?vim?x?)(diff)?$";

/// Lower-cased process name matches Vim, or (if a passthrough regex is set and
/// valid) matches that too. An invalid passthrough regex is treated as no-match,
/// matching jq's `try test($pass) catch false`.
pub fn is_vim_foreground(process_info: &Value, passthrough_re: &str) -> bool {
    let vim = match Regex::new(VIM_RE) {
        Ok(r) => r,
        Err(_) => return false,
    };
    let pass = if passthrough_re.is_empty() {
        None
    } else {
        match Regex::new(passthrough_re) {
            Ok(r) => Some(r),
            Err(_) => None, // invalid → behaves as no-match (jq `catch false`)
        }
    };

    let procs = process_info
        .get("result")
        .and_then(|r| r.get("process_info"))
        .and_then(|p| p.get("foreground_processes"))
        .and_then(|f| f.as_array());

    let procs = match procs {
        Some(a) => a,
        None => return false,
    };

    for entry in procs {
        // `[]?` — null/missing entries are skipped.
        let name = match entry.get("name").and_then(|n| n.as_str()) {
            Some(n) => n,
            None => continue,
        };
        let lower = name.to_ascii_lowercase(); // jq `ascii_downcase` is ASCII-only
        if vim.is_match(&lower).unwrap_or(false) {
            return true;
        }
        if let Some(p) = &pass {
            if p.is_match(&lower).unwrap_or(false) {
                return true;
            }
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn info(names: &[&str]) -> Value {
        json!({
            "result": {
                "process_info": {
                    "foreground_processes": names.iter().map(|n| json!({"name": n})).collect::<Vec<_>>()
                }
            }
        })
    }

    #[test]
    fn detects_vim_variants() {
        for n in &["vim", "nvim", "view", "gvim", "vimdiff", "nvimdiff", "vi", "VIM", "Nvim"] {
            assert!(is_vim_foreground(&info(&[n]), ""), "failed for {n}");
        }
    }

    #[test]
    fn ignores_non_vim() {
        assert!(!is_vim_foreground(&info(&["bash"]), ""));
        assert!(!is_vim_foreground(&info(&["lazygit"]), ""));
    }

    #[test]
    fn passthrough_matches() {
        assert!(is_vim_foreground(&info(&["lazygit"]), r"^(vi-sql|lazygit)$"));
        assert!(is_vim_foreground(&info(&["vi-sql"]), r"^(vi-sql|lazygit)$"));
        assert!(!is_vim_foreground(&info(&["bash"]), r"^(vi-sql|lazygit)$"));
    }

    #[test]
    fn invalid_passthrough_is_no_match() {
        // unbalanced group — jq `catch false` → no match, no crash.
        assert!(!is_vim_foreground(&info(&["lazygit"]), r"^(vi-sql"));
    }

    #[test]
    fn missing_foreground_processes() {
        assert!(!is_vim_foreground(&json!({"result":{"process_info":{}}}), ""));
        assert!(!is_vim_foreground(&json!({}), ""));
    }
}
