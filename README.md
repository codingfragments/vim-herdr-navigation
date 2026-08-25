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
  `wincmd h/j/k/l`. If the window didn't change (Vim is at an edge), it invokes
  the plugin's `*-edge` action (`herdr plugin action invoke vim-herdr-navigation.<dir>-edge`),
  which runs `navigate --no-forward --cross-tabs <dir>`. `--no-forward` tells
  `navigate` to skip Vim detection (it would otherwise forward the chord back
  into Vim and loop) and go straight to the herdr pane-focus path — so the
  Vim edge-cross gets the **same** smart-focus target selection, cross-tab
  navigation, and per-tab preferred-coordinate persistence as the non-Vim path.
  Vim finds its own pane through the `$HERDR_PANE_ID` herdr injects into every
  pane.

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
- **Cross-surface navigation at the edge.** Herdr is a recursive 2D torus:
  pane grid → tab strip (horizontal, wraps) → workspace stack (vertical,
  wraps). By default, a move that hits an edge is a no-op. You opt in to
  crossing into the adjacent surface with a **scope** — `off` (default) /
  `tabs` (cycle tabs horizontally) / `workspaces` (cycle workspaces
  vertically) / `both` (the full 2D torus). There are three ways to set it:

  - **Action set (recommended).** This plugin ships three opt-in action sets,
    each bound to its own chord so the behaviors coexist on separate keys:

    | Action set | Flag | Crosses |
    |---|---|---|
    | `*-cross` | `--cross-tabs` | tabs horizontally (left/right) |
    | `*-cross-both` | `--cross both` | tabs horizontally + workspaces vertically |
    | `*-edge` | `--no-forward --cross both` | (Vim edge-cross; both axes) |

    Bind `*-cross-both` to your main chord (e.g. `Ctrl+h/j/k/l`) for the full
    torus, or `*-cross` if you only want horizontal tab cycling:

    ```toml
    [[keys.command]]
    key = ["ctrl+left", "ctrl+h"]
    type = "plugin_action"
    command = "vim-herdr-navigation.left-cross-both"

    [[keys.command]]
    key = ["ctrl+down", "ctrl+j"]
    type = "plugin_action"
    command = "vim-herdr-navigation.down-cross-both"

    [[keys.command]]
    key = ["ctrl+up", "ctrl+k"]
    type = "plugin_action"
    command = "vim-herdr-navigation.up-cross-both"

    [[keys.command]]
    key = ["ctrl+right", "ctrl+l"]
    type = "plugin_action"
    command = "vim-herdr-navigation.right-cross-both"
    ```

  - **`--cross <scope>` flag.** Any action can pass `--cross off|tabs|workspaces|both`
    (it overrides `HERDR_NAV_CROSS`; `--cross-tabs` is a back-compat alias for
    `--cross tabs`).
  - **Global env var.** `export HERDR_NAV_CROSS=both` makes _every_ navigation
    cross at the edge on both axes (so the default `Ctrl+h/j/k/l` actions
    cross). `HERDR_NAV_CROSS_TABS=1` is a back-compat alias for `tabs`. No
    second key set; simpler but you lose the same-tab-only behavior.

  How crossings land:
  - **Tabs (left/right):** `right` at the right edge -> next tab, `left` at
    the left edge -> previous tab (ordered by tab bar position); the index
    **wraps** (last -> first, first -> last). On arrival the destination tab's
    **edge column** is selected (leftmost for `right`, rightmost for `left`) at
    the row nearest its stored `preferred_y` (seeded from the row you left),
    and that pane is focused; the destination tab's preferred coordinates are
    then persisted, just like an in-tab move.
  - **Workspaces (up/down):** `down` at the bottom edge -> next workspace,
    `up` at the top edge -> previous workspace (ordered by sidebar position);
    the index **wraps**. The destination workspace's **active tab** is used
    (workspaces have differing tab layouts, so tab N isn't preserved), and
    within it the **edge row** is selected (topmost for `down`, bottommost for
    `up`) at the column nearest its stored `preferred_x` (seeded from the
    column you left); that pane is focused and the destination tab's preferred
    coordinates are persisted.

  `--cross workspaces` crosses only on vertical moves (left/right stay
  no-ops at the edge); `--cross both` crosses on both axes. The Vim edge-cross
  (the `*-edge` actions, invoked by `editor/nvim.lua` / `editor/vim.vim`)
  uses `--no-forward --cross both` so a Vim split can cross out on BOTH axes —
  left/right into the next tab, up/down into the next workspace — and gets the
  same smart-focus + edge-landing + persistence as the non-Vim path. `--no-forward`
  skips Vim detection so `navigate` doesn't re-forward the chord into Vim and loop.
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
