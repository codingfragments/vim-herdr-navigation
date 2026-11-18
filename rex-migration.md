# Rex migration plan: pure-Lua `Ctrl+h/j/k/l` across nvim splits and Rex panes

> **Status: planned, not started.** This is the active plan for this repo.
> Agents: read this file before starting work, follow the phases in order
> (one `phase/rex-N-…` branch and PR per phase, see AGENTS.md), and tick the
> checkboxes and update the "Status" lines as phases land.
>
> Unlike the sister plans (`herdr-zextract`, `herdr-flash`, `herdr-nav`),
> **no Rust binary, no `muxhost` and no mise are involved.** Both sides are
> Lua: Rex config Lua and Neovim Lua. The herdr side (`src/`, the Rust
> `navigate` binary) stays as it is and keeps serving herdr.

## Goal

The same seamless navigation as on herdr, under Rex (superlogical's
terminal multiplexer, `com.superlogical.rex`):

- `Ctrl+h/j/k/l` moves between nvim splits while nvim is focused.
- At an nvim edge it carries on into the neighbouring Rex pane.
- Everywhere else it moves between Rex panes, with smart focus that
  remembers your preferred row and column, and crosses into the next or
  previous tab or session at the layout edge if crossing is turned on.

## Current state (why this is needed)

- The user's Rex config (`~/.config/rex/conf/focus.lua`) binds
  `ctrl+h/j/k/l` globally to `focus_pane` (`~/.config/rex/lib/focus.lua`).
  Rex takes these keys before the terminal does, so **nvim never receives
  them**, and moving between nvim splits with `Ctrl+hjkl` doesn't work
  inside Rex.
- The nvim side (`editor/nvim.lua`, plus the user's copy at
  `~/.config/nvim/lua/scripts/herder_nav.lua`, loaded from
  `lua/config/keymaps.lua`) only acts when `HERDR_PANE_ID` or `TMUX` is
  set, so it does nothing in Rex. The user's copy differs from
  `editor/nvim.lua` in one way: it maps `{ "n", "i" }` instead of `"n"`.

## Design: Rex asks nvim instead of forwarding the key

On herdr, the binary forwards the key into Vim, and at an edge Vim calls
back with `herdr plugin action invoke …-edge`. On Rex that callback would
come from a **CLI client**, and `rex.client.queue` does nothing for CLI
clients. So moving from an nvim edge into another tab or session would
not update the app (see the notes in `~/.config/rex/lib/focus.lua`).
The design is turned around instead:

```
ctrl+h ──► Rex Lua action `vim_nav{direction}`   (started by the app, so ctx.client_id = app)
            │
            ├─ foreground of the focused block (terminal.process)
            │
            ├─ nvim with a rex_nav socket?
            │     timeout 0.25 nvim --clean --server <sock> \
            │       --remote-expr "v:lua.rex_nav.move('left')"
            │        "moved" ─► done          (move = geometry + nvim_set_current_win)
            │        "edge"  ─► fall through to the pane move (same action, app context)
            │        timeout ─► forward the key (rex send-key; blocked nvim = hit-enter etc.)
            │
            ├─ vim / passthrough app / ssh / nvim without a socket?
            │     forward the key (block.event or `rex send-key`); the app handles it
            │
            └─ otherwise / at an nvim edge:
                  smart focus from session.view rects + per-window preferred coordinate
                  at the layout edge: cross (tabs / sessions / both / off) via
                  rex.client.queue(...) and land on the edge pane
```

- **The answer comes back to Lua, so there is no callback, no loop and no
  `--no-forward`.** Crossing works, because the decision is made inside
  the action the app started.
- **Speed:** `nvim --clean --server S --remote-expr …` takes ~10 ms on
  the user's Mac (nvim 0.12.6). The action prologue (view + process via
  `rex.call`) is sub-millisecond; forwarding via CLI `rex send-key`
  ~30 ms.
- **Finding the right nvim:** the socket is named after **`REX_BLOCK`**
  (nvim inherits it in its environment). Neovim 0.12's TUI frontend and
  `--embed` backend have different PIDs, so a pid-named socket cannot be
  found from Rex's `process` info. Nested nvim (`:terminal`) inherits the
  same `REX_BLOCK` — Phase 2 disambiguates (e.g. a block+pid suffix with
  prefix matching, innermost wins).
- **Geometry:** `session.view` already gives every layout node a
  normalized `rect = [x, y, w, h]`. Checked live:
  `windows[].layers[].layout.split.{before,after}.rect`, with layers of
  kind `tiled` or floating, and `windows[].focused_block_id`. Smart focus
  needs no split-ratio maths.

## Decisions (defaults chosen here; the user may revise them)

| # | Decision | Default in this plan | Alternative |
|---|---|---|---|
| D1 | **Where the code lives** | **This repo is the canonical source**: `rex/vim_nav.lua` (Rex side) and `editor/nvim.lua` (gains a Rex branch). The user's dotfiles load or copy them: `~/.config/rex/plugins/vim_nav.lua` and `~/.config/nvim/lua/scripts/herder_nav.lua`. | Dotfiles only, with no copy in this repo |
| D2 | **Crossing axes** | **herdr parity:** left/right go to the previous/next **tab**, up/down to the previous/next **session**. A setting chooses `off` / `tabs` / `sessions` / `both` (default `both` on `ctrl+h/j/k/l`). | The current Rex config: `ctrl+up/down` go to tabs, with no session crossing |
| D3 | **`ctrl+k` clash** | `ctrl+k` belongs to navigate up. The herdr-nav switcher (its plan's Phase R4) has to use another key. Record that in `../herdr-nav/rex-migration.md` when this lands. | Give `ctrl+k` to the switcher and use `alt+h/j/k/l` for navigation |
| D4 | **Preferred-coordinate state** | A Lua table per window, held in memory and **lost on config reload** (it re-seeds from the current pane). It replaces `focus_pane`'s return-to-sender memory, which it covers. | Persist it to `${XDG_STATE_HOME}/vim-rex-navigation/` via `rex.exec` |
| D5 | **Classic Vim** | Forward the key; `editor/vim.vim` crosses out with `rex do vim_nav … no_forward=true`, which moves within the tab only (CLI-client limit). | No Vim support on Rex |

## Phases

### Phase 0: spikes, in `phase/rex-0-spikes`

Status: ☑ done (2026-11-18, throwaway probes in a scratch Rex session;
results below and folded into the Design section)

- [ ] **S1 Blocked nvim:** `--remote-expr` while nvim shows a hit-enter
  prompt, an operator-pending state, an open cmdline, or is busy. Does it
  hang? `rex.exec` is synchronous, so find a timeout: a `rex.exec`
  option, a `perl -e 'alarm …'` wrapper (macOS has no `timeout`), or
  nvim's own RPC timeout. On timeout, fall back to forwarding the key.
- [ ] **S2 Can config Lua send a key straight into a block?** Try
  `rex.call("block.event", …)`, `rex.block.call` and similar. The note in
  `~/.config/rex/lib/env.lua` says config actions cannot call server
  actions. If they really can't, use
  `rex.exec{REX_CLI, "send-key", "-s", S, "-b", B, "ctrl+h"}` and measure
  the delay. Check that nvim and vim receive `<C-h>` as distinct from
  Backspace (kitty keyboard protocol).
- [ ] **S3 Landing after a crossing:** can the action focus the target
  window's edge block on the server (`session.focus_block`) and then
  queue `client.tab.next/previous`, so the app shows that block? For
  sessions, check whether `session.next/previous` or
  `session.select{session_id}` can be queued, and whether a block inside
  another session can be focused first.
- [ ] **S4 Delay per keypress:** the total for the process lookup, the
  nvim call and `session.view` should stay under about 50 ms. Check
  whether `terminal.process` is available from config Lua
  (`rex.block.call`?) or needs the CLI.
- [ ] **S5 nvim side:** `serverstart(path)` with a path named after the
  PID (`/tmp/rex-nvim-$UID/<pid>.sock`, directory mode 0700). Does
  `move()` run correctly from RPC in insert and terminal mode?
  `--clean` on the client side: confirm that no user config loads.
- [ ] **S6 Is `REX_CLI` reachable from inside nvim**, for the
  forwarding fallback's `rex do`? The rex CLI is not on the normal PATH;
  check whether Rex terminals export something usable, or whether Rex
  Lua must export it.

### Phase 1: nvim side, in `phase/rex-1-nvim`

Status: ☐ not started

- [ ] `editor/nvim.lua`: keep the herdr and tmux branches byte-identical.
  When `vim.env.REX_BLOCK` is set:
  - Start the socket (S5 path) and remove it in `VimLeavePre`.
  - Provide a module `rex_nav` (via `package.loaded`, so
    `v:lua.require'rex_nav'` resolves) with `move(dir)`, which runs
    `wincmd` and returns `"moved"` or `"edge"`.
  - `<C-h/j/k/l>` mappings in `{ "n", "i" }` (the user's variant becomes
    the default) for the forwarding fallback. At an edge they call
    `REX_CLI do vim_nav direction=<dir> no_forward=true`.
- [ ] `editor/vim.vim`: a Rex branch for the D5 fallback only.
- [ ] Update the user's `~/.config/nvim/lua/scripts/herder_nav.lua`, in
  the dotfiles repo as its own PR: either `dofile` this repo's
  `editor/nvim.lua`, or copy it. The decision follows D1.

### Phase 2: Rex side, in `phase/rex-2-rex-lua`

Status: ☐ not started

- [ ] `rex/vim_nav.lua`, self-contained apart from optional `lib.env`
  (login PATH, `rex_cli`). The action is
  `vim_nav{ direction, cross = "string?", no_forward = "boolean?" }`:
  1. Find the focused block (`rex.session.view` → `active_window_id` →
     `focused_block_id`). If it's zoomed, do a plain move or nothing.
  2. Unless `no_forward` is set, read the foreground process. If it's
     nvim, its PID's socket exists and the RPC answers `"moved"`, stop.
     If it's vim, a passthrough app, `ssh`, or an RPC timeout, forward
     the key (S2) and stop.
  3. Smart focus: among the tiled-layer blocks of the active window, pick
     the candidates beyond the current rect in that direction, then the
     one whose row (for left/right) or column (for up/down) is nearest
     the window's preferred coordinate. Update that coordinate, mirroring
     herdr's `src/geometry.rs`, and focus the winner with
     `rex.session.focus_block`.
  4. With no candidate, apply the cross scope (D2), using S3's landing
     method and the "edge column / preferred row" rule from
     `src/cross.rs` and `src/tabs.rs`, wrapping at the ends.
     `rex.client.queue` is used only when `ctx.client_id` is an app
     client; otherwise use the server-side fallback, as in today's
     `focus_pane`.
- [ ] Passthrough list: a Lua pattern list on the process name (no regex
  in gopher-lua), default empty, replacing `HERDR_NAV_PASSTHROUGH_RE`.
- [ ] Bindings, inside the file and easy to change: `ctrl+h/j/k/l` and
  `ctrl+left/down/up/right` go to `vim_nav` with `cross = "both"` (D2).
- [ ] Unit-testable core: the geometry and crossing choice are pure Lua
  functions over a `session.view` table. Test them with recorded view
  fixtures (`test/rex/*.json`), run through `rex do` in a selftest
  session.

### Phase 3: wire it into the user's Rex config, in the dotfiles repo (separate PR there)

Status: ☐ not started

- [ ] `~/.config/rex/plugins/vim_nav.lua`: a copy or symlink of
  `rex/vim_nav.lua` (D1); add it to `init.lua`'s plugin list.
- [ ] Remove the `ctrl+h/j/k/l` and `ctrl+arrow` bindings from
  `conf/focus.lua`. The `ctrl+s>h/j/k/l` prefix bindings may stay on
  `focus_pane` or move to `vim_nav` with `cross = "off"`. Retire
  `lib/focus.lua` once nothing uses it.
- [ ] `~/.config/rex/migration-plan.md`: move "vim-herdr-navigation
  (full torus)" and "Full 2D torus" from "impossible" to "done", noting
  any limits found in the spikes.
- [ ] Note the D3 `ctrl+k` decision in `../herdr-nav/rex-migration.md`
  (a docs PR in that repo).

### Phase 4: docs and release `v0.4.0`, in `phase/rex-4-docs` then `release/0.4.0`

Status: ☐ not started

- [ ] README: a "Rex" section (how it works, install for both files,
  cross scopes, limits: classic Vim and ssh-nvim can't cross out, state
  resets on config reload). Consider renaming the repo later to
  something multiplexer-neutral; that is not part of this plan.
- [ ] `herdr-plugin.toml` + `Cargo.toml` version bump, release notes, tag `v0.4.0`. The
  herdr binary itself is unchanged.

## Spike results

| # | Question | Result |
|---|---|---|
| S1 | Blocked nvim and `--remote-expr`: does it hang, and what timeout mechanism works? | ☑ Hangs at a hit-enter prompt and in `getchar`-style input waits. `:sleep 10` does NOT block (nvim 0.12 handles concurrent RPC). Every RPC needs a timeout (GNU `timeout` is on the login PATH, `/opt/homebrew/bin/timeout`); on timeout, forward the key — block-level `rex send-key enter`/`ctrl+h` dismisses hit-enter. |
| S2 | Can config Lua send keys into a block directly? `<C-h>` distinct from BS? | ☑ `rex.call("block.event", …)` works from config Lua, sub-ms, and bypasses Lua bindings (no loop) — but its ctrl-modifier payload did not arrive in nvim as `<C-h>` (shape not pinned down). The CLI `rex send-key ctrl+h` is proven correct: kitty keyboard protocol is active, nvim sees `<C-h>` distinct from `<BS>`. **Forward via the CLI** (~30 ms), not block.event. |
| S3 | Landing on the edge pane after crossing to the next tab or session from config Lua | ◐ Design follows the proven `lib/focus.lua` pattern (server-side `session.focus_block` on the target, then `rex.client.queue("client.tab.…")` from the app-invoked action). Server half verified; the app half needs the user's hands in Phase 2. |
| S4 | Delay per keypress (process, RPC, view) and whether `terminal.process` is reachable from config Lua | ☑ All pieces from config Lua: `session.view` ~0 ms, `rex.call("com.superlogical.terminal.process", …)` ~0 ms (returns the foreground pid/name), nvim RPC ~10 ms, CLI `send-key` ~30 ms. Well under 50 ms. |
| S5 | nvim socket named after its PID; `move()` from RPC in insert and terminal mode; `--clean` client | ☑ with **design changes**: (a) nvim 0.12.6 splits into a TUI frontend + `--embed` **backend** with different PIDs — Rex's `process` pid ≠ nvim's `getpid()` — so the socket is named after **`REX_BLOCK`** (nvim inherits it), not the pid. (b) `wincmd` via RPC gets overridden → `move()` computes the neighbor from window geometry and switches with `nvim_set_current_win` (reliable, persists, works from insert mode). (c) `vim.loop` is gone in 0.12 — use `vim.uv`. (d) `--remote-expr` evaluates **VimL**: use `v:lua.…` (bare `vim.*` fails). `--clean` client loads no user config. |
| S6 | `REX_CLI` reachable inside nvim for the fallback | ☑ Panes export `REX_BIN_DIR` (the rex CLI's directory), `REX_SERVER`, `REX_SESSION`, `REX_BLOCK`. The nvim-side fallback calls `$REX_BIN_DIR/rex do vim_nav …`. |

## Rex facts an agent needs (verified 2026-11, rex 0.1.0-preview.19, api rev 14)

- **Lua config:** `rex.action{name,title,args,run}` with `ctx.session_id`
  and `ctx.client_id`; `rex.bind(key, action, args?)`; `rex.session.view`,
  `rex.session.focus_block`, `rex.session.focus_direction`,
  `rex.session.focus_next_window` / `focus_previous_window`,
  `rex.session.list_clients` (where `info.kind == "app"`);
  `rex.client.queue(action, args?)`, which only works when an app client
  started the action; `rex.exec{argv}`, which is synchronous and returns
  `{code, stdout, stderr}`; `rex.json`. There is no regex and no
  `io.popen`.
- **Client actions** (the app): `client.tab.next/previous/goto`,
  `session.next/previous/switch/select`.
- **Server API:**
  - `block.event` takes `{session_id, block_id, event: {type: "key", payload}}`.
    The event goes straight to the block, so Lua bindings never see it.
  - `client.key` sends a key that Lua bindings see first, so it would loop.
  - `com.superlogical.terminal.process` returns the foreground process
    (`pid`, `name`, `argv0`, `path`), `child` and `ancestors`.
- **CLI:** `rex send-key -s S -b B ctrl+h`, and
  `rex do <action> key=value …` (it runs as a CLI client, where
  `client.queue` does nothing).
- **Environment:** inside a Rex terminal, `REX_SESSION` and `REX_BLOCK`
  are set. The rex CLI lives at
  `~/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex`.
  The Rex server's PATH is launchd's minimal one; the user's
  `lib/env.lua` resolves the login PATH and `rex_cli`.
- **Existing Lua to build on and replace:** `~/.config/rex/lib/focus.lua`
  (`focus_pane` with return-to-sender memory and tab crossing for app
  clients) and `~/.config/rex/conf/focus.lua` (its bindings).
- **Headless test recipe:**
  `rex new selftest && rex do -s selftest selftest.lua && rex session kill selftest`.

## Out of scope

- Changes to the herdr Rust binary (`src/`) or `herdr-plugin.toml`
  actions, apart from the version bump.
- A Rust or `muxhost`-based Rex backend for this tool: there's no need,
  since pure Lua covers it.
- nvim on remote hosts (over `ssh`) crossing out: forwarding only.
