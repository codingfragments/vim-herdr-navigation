# vim-herdr-navigation

Navigate [herdr](https://herdr.dev) panes and Vim/Neovim splits as if they were
one app. `Ctrl+h/j/k/l` moves between Vim splits while you're in Vim, and falls
through to move between herdr panes when Vim hits an edge — and the same keys
move between herdr panes everywhere else. It's
[`vim-tmux-navigator`](https://github.com/christoomey/vim-tmux-navigator),
ported to herdr's CLI.

## How it works

Two cooperating sides, like `vim-tmux-navigator`:

- **herdr side** (`navigate`, a Rust binary built from `src/`): a herdr keybind
  binds `Ctrl+h/j/k/l` to a plugin action. On each press the action checks the
  focused pane's _foreground_ process via `herdr pane process-info`. If it's
  Vim/Neovim it forwards the key into that pane with `herdr pane send-keys`;
  otherwise it moves herdr's focus. Focus is **smart**: rather than a single
  directional hop, the target pane is chosen from the tab's geometry using a
  per-tab preferred coordinate so that crossing into a stacked column lands on
  the row you were last in — not always the top pane. The focus itself is a
  single `pane.focus` call over herdr's socket (focus-by-id), so there's no
  intermediate render of the pane in between. See [Smart focus](#smart-focus)
  below.
- **editor side** (`editor/nvim.lua`, `editor/vim.vim`): maps the same keys to
  `wincmd h/j/k/l`. If the window didn't change (Vim is at an edge), it calls
  `herdr pane focus --direction` to cross into the neighbouring herdr pane. Vim
  finds its own pane through the `$HERDR_PANE_ID` herdr injects into every pane.

## Requirements

- herdr `>= 0.7.0`
- A Rust toolchain (to build the `navigate` binary — run `make install` or
  `cargo build --release` once after linking)
- Tested on Linux or macOS

## Install

```bash
herdr plugin link /path/to/vim-herdr-navigation   # local checkout
make install                                       # builds target/release/navigate
# (or: cargo build --release)
herdr plugin action list --plugin vim-herdr-navigation
```

If you use [`just`](https://github.com/casey/just), the bundled justfile wraps
the common workflows: `just build`, `just link`, `just unlink`, `just relink`,
`just test`, `just replace-gh` (swap the local link for the published GitHub
version).

### 1. Bind the keys in herdr

Add to `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "ctrl+h"
type = "plugin_action"
command = "vim-herdr-navigation.left"
description = "navigate left (vim/herdr)"

[[keys.command]]
key = "ctrl+j"
type = "plugin_action"
command = "vim-herdr-navigation.down"
description = "navigate down (vim/herdr)"

[[keys.command]]
key = "ctrl+k"
type = "plugin_action"
command = "vim-herdr-navigation.up"
description = "navigate up (vim/herdr)"

[[keys.command]]
key = "ctrl+l"
type = "plugin_action"
command = "vim-herdr-navigation.right"
description = "navigate right (vim/herdr)"
```

Reload herdr's config (`prefix+shift+r`) or restart.

### 2. Wire up your editor

**Neovim** — load `editor/nvim.lua` after your plugins so it wins over any other
`<C-h/j/k/l>` mapping. With lazy.nvim, fold it into the `vim-tmux-navigator`
spec (disable its mappings, then load this one — single source of truth):

```lua
{
  "christoomey/vim-tmux-navigator",
  lazy = false,
  init = function()
    vim.g.tmux_navigator_no_mappings = 1
  end,
  config = function()
    dofile(vim.fn.expand("~/src/personal/vim-herdr-navigation/editor/nvim.lua"))
  end,
}
```

No plugin manager? Drop it in `after/plugin` instead:
`cp editor/nvim.lua ~/.config/nvim/after/plugin/herdr_nav.lua`.

It falls back to tmux (if `$TMUX` is set) or plain `wincmd` when you're not in a
herdr pane, so an existing tmux setup keeps working — no need to remove
`vim-tmux-navigator`.

**Vim** — from your `vimrc`:

```vim
source /path/to/vim-herdr-navigation/editor/vim.vim
```

or, simply copy and pasta.

## Notes & tradeoffs

- **Other TUIs that use `Ctrl+h/j/k/l`** ([vi-sql](https://github.com/kopecmaciej/vi-sql),
  `lazygit`, `k9s`). By default every non-Vim pane just moves herdr focus. To let
  one of these handle the chord itself, name it in `HERDR_NAV_PASSTHROUGH_RE` — a
  regex on the lower-cased process name, anchored (`^…$`) for an exact match. Set
  it where you launch herdr:

  ```bash
  export HERDR_NAV_PASSTHROUGH_RE='^(vi-sql|lazygit)$'
  ```

  Unlike Vim, these apps don't cross _out_ at an edge — use `prefix+h/j/k/l` to
  leave the pane.
- **Cross-tab at the horizontal edge.** By default, moving `left`/`right` when
  you're already at the leftmost/rightmost pane of the tab is a no-op. There are
  two ways to opt in to crossing into the adjacent tab at the edge:

  - **Second action set (recommended).** This plugin ships a second set of
    actions (`left-cross`/`down-cross`/`up-cross`/`right-cross`) that pass
    `--cross-tabs` to the binary. Bind them to a second chord (e.g.
    `Alt+h/j/k/l`) in `config.toml` so both behaviors coexist on separate keys:

    ```toml
    [[keys.command]]
    key = "alt+h"
    type = "plugin_action"
    command = "vim-herdr-navigation.left-cross"

    [[keys.command]]
    key = "alt+j"
    type = "plugin_action"
    command = "vim-herdr-navigation.down-cross"

    [[keys.command]]
    key = "alt+k"
    type = "plugin_action"
    command = "vim-herdr-navigation.up-cross"

    [[keys.command]]
    key = "alt+l"
    type = "plugin_action"
    command = "vim-herdr-navigation.right-cross"
    ```

    Now `Ctrl+h/j/k/l` stays within the tab (no-op at the edge), and
    `Alt+h/j/k/l` crosses to the adjacent tab when you hit the left/right edge.
    Up/down are unaffected on either set.
  - **Global env var.** `export HERDR_NAV_CROSS_TABS=1` makes _every_ navigation
    cross tabs at the edge (so `Ctrl+h/j/k/l` itself crosses). No second key
    set; simpler but you lose the same-tab-only behavior.

  In both cases: `right` at the right edge -> next tab, `left` at the left edge
  -> previous tab (ordered by the tab's position in the bar); the new tab's
  last-focused pane is restored; no-op if you're already on the last/first tab;
  up/down never cross tabs. The `--cross-tabs` flag takes precedence over the
  env var.

  (Only the non-Vim path crosses tabs today. The Vim edge-cross goes through
  the editor side; wiring that through `navigate` too is a planned follow-up.)
- **`Ctrl+l` / `Ctrl+k` in shells.** Binding these globally shadows readline's
  `Ctrl+L` (clear screen) and `Ctrl+K` (kill line) inside non-Vim panes. This is
  the same tradeoff as `vim-tmux-navigator`. If you want them back, bind clear to
  something like `prefix+l` or pick `alt+h/j/k/l` for navigation instead.
- **`Ctrl+H` vs Backspace.** `Ctrl+H` and Backspace share a byte (`0x08`) unless
  the kitty keyboard protocol is active. Neovim ≥ 0.10 enables it automatically
  in herdr panes, keeping `<C-h>` distinct. On older Vim you may need to map
  `<BS>` separately if it starts navigating.
## Smart focus

When you move between herdr panes (the non-Vim path), `navigate` doesn't just
hop one pane in the requested direction. It reads the tab layout, finds the
panes beyond you in that direction, and picks the one whose row (for left/right)
or column (for up/down) matches the one you were last in — a per-tab preferred
coordinate.

```
  ┌───────────┬───────────┐
  │           │     B     │   move A -> right  ->  lands on C (not B),
  │     A     ├───────────┤   because you were last in C's row
  │           │     C     │
  └───────────┴───────────┘
```

A horizontal move updates the preferred _column_ and keeps the preferred _row_;
a vertical move does the mirror. So the row/column you're conceptually on
survives a move on the other axis, and crossing back returns you to the pane you
left rather than always the top-most one.

State is stored per tab under
`${XDG_STATE_HOME:-~/.local/state}/vim-herdr-navigation/<tab_id>.json`
(overridable via `HERDR_NAV_STATE_DIR`). `tab_id` already embeds the workspace,
so state is isolated per tab _and_ per workspace. Delete the directory and the
preference simply re-seeds from the current pane on the next move.

The focus itself is a single `pane.focus { pane_id }` call over herdr's unix
socket (`$HERDR_SOCKET_PATH`, injected by herdr into every pane) — focus-by-id,
which the CLI doesn't expose for terminal panes. One call means no intermediate
render of the pane in between, so no flicker. If the socket is unavailable,
`navigate` falls back to a two-hop directional walk (`pane focus --direction`
twice), which may briefly render the intermediate pane.

## Notes & tradeoffs

- The editor maps are normal-mode only. Add `t`/`i` modes yourself if you want
  to navigate out of terminal/insert mode.
