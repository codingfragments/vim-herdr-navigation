-- vim_nav for Rex — seamless ctrl+h/j/k/l across nvim splits and Rex panes.
--
-- The port of vim-herdr-navigation's navigate binary to Rex, in pure
-- Lua (Rex config runtime is Lua 5.1: no regex, no io.popen, no UI
-- widgets — see the repo's rex-migration.md for why this works here).
--
-- Flow (the app invokes this action from the ctrl+h/j/k/l binding, so
-- the app context is available for crossings):
--
--   1. Find the focused block of the active window.
--   2. Unless no_forward: read its foreground process.
--        nvim (no nested vim below it) → ask it over RPC:
--            timeout 0.25 nvim --clean --server <sock> \
--              --remote-expr "v:lua.require'rex_nav'.move('left')"
--          "moved" → done.  "edge" → pane move.  timeout/error
--          (blocked nvim, no socket, remote host) → forward the key.
--        vim / ssh / a nested vim / a passthrough app → forward the key
--        (rex send-key; the app inside handles its own movement).
--   3. Pane move: smart focus over the window's layout rects, with a
--      per-window preferred row/column (the row/column you're
--      conceptually on survives a move on the other axis — so moving
--      back returns to the pane you left, like herdr's navigate).
--   4. At the layout edge, cross (cross = off|tabs|sessions|both,
--      default both — herdr parity: left/right → tabs, up/down →
--      sessions), landing on the target's edge pane.
--
-- Install: copy this file to ~/.config/rex/plugins/vim_nav.lua and add
--   require("plugins.vim_nav")
-- to init.lua. Bindings: ctrl+h/j/k/l and ctrl+arrows.
--
-- Self-contained: uses lib.env (login PATH, rex CLI path) when present,
-- inline fallbacks otherwise.

-- ── Environment helpers (lib/env.lua when present, else inline) ──
local login_path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
local rex_cli = "rex"
do
  local ok, env = pcall(require, "lib.env")
  if ok and env and env.path and env.path ~= "" then login_path = env.path end
  if ok and env and env.rex_cli and env.rex_cli ~= "" then
    rex_cli = env.rex_cli
  else
    local bundle = (os.getenv("HOME") or "") ..
      "/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
    local f = io.open(bundle, "r")
    if f then f:close() rex_cli = bundle end
  end
end

-- Apps that own ctrl+h/j/k/l themselves and get the key forwarded
-- (Lua patterns on the lower-cased process name). ssh and classic vim
-- are always forwarded; nvim is asked via RPC instead.
local PASSTHROUGH = {}

-- Per-window preferred coordinate (D4: in-memory, lost on config
-- reload; re-seeds from the current pane). window_id → {x=…, y=…}.
local pref = {}

local M = {}

-- ── Geometry over session.view ───────────────────────────────────
-- The layout tree: leaves carry {rect = {x, y, w, h}, block_id};
-- splits carry {rect, split = {direction, before, after}}. Rects are
-- fractions of the window.

-- All blocks of `window`'s tiled layers as {id, x, y, w, h, label}.
-- Floating layers (popups like zextract) are left out.
function M.leaves(window)
  local out = {}
  local labels = {}
  for _, layer in ipairs(window.layers or {}) do
    if layer.kind == "tiled" then
      for _, b in ipairs(layer.blocks or {}) do labels[b.block_id] = b.label end
      local function walk(node)
        if not node then return end
        if node.split then
          walk(node.split.before)
          walk(node.split.after)
        elseif node.block_id and node.rect then
          out[#out + 1] = {
            id = node.block_id,
            x = node.rect[1], y = node.rect[2],
            w = node.rect[3], h = node.rect[4],
            label = labels[node.block_id] or "",
          }
        end
      end
      walk(layer.layout)
    end
  end
  return out
end

local function center_y(b) return b.y + b.h / 2 end
local function center_x(b) return b.x + b.w / 2 end

-- The neighbouring pane in `direction` (smart focus): candidates
-- beyond the current rect in that direction, overlapping on the other
-- axis; the one whose off-axis centre is nearest the window's
-- preferred row/column wins (ties by distance). Returns the target
-- block id and updates `pref[window_id]` (seeding it from the current
-- pane on first use). Pure, for testing.
function M.pick(blocks, cur_id, direction, window_id, pref_store)
  pref_store = pref_store or pref
  local cur
  for _, b in ipairs(blocks) do
    if b.id == cur_id then cur = b end
  end
  if not cur then return nil end
  local p = pref_store[window_id]
  if not p then
    p = { x = center_x(cur), y = center_y(cur) }
    pref_store[window_id] = p
  end
  local horizontal = (direction == "left" or direction == "right")
  local best, best_score
  for _, b in ipairs(blocks) do
    if b.id ~= cur_id then
      local dist, aligned, off
      if horizontal then
        dist = (direction == "right") and (b.x - (cur.x + cur.w)) or (cur.x - (b.x + b.w))
        aligned = (b.y < cur.y + cur.h) and (b.y + b.h > cur.y)
        off = center_y(b) - p.y
      else
        dist = (direction == "down") and (b.y - (cur.y + cur.h)) or (cur.y - (b.y + b.h))
        aligned = (b.x < cur.x + cur.w) and (b.x + b.w > cur.x)
        off = center_x(b) - p.x
      end
      -- touching rects (dist == 0) are neighbours; tiny eps for noise
      if dist > -0.001 and aligned then
        local d = (dist < 0) and 0 or dist
        local score = math.abs(off) * 1000 + d
        if not best_score or score < best_score then
          best, best_score = b, score
        end
      end
    end
  end
  if not best then return nil end
  -- the move updates the preferred coordinate on the moved axis only
  if horizontal then
    p.x = center_x(best)
  else
    p.y = center_y(best)
  end
  return best.id
end

-- The edge pane for a crossing: `side` = "left"|"right"|"top"|"bottom"
-- (the side of the window the crossing lands on); among the panes on
-- that edge, the one nearest the window's preferred row/column.
-- Pure, for testing.
function M.edge_block(blocks, side, pref_y, pref_x)
  local best
  for _, b in ipairs(blocks) do
    local pos, off
    if side == "left" or side == "right" then
      pos = (side == "left") and b.x or (b.x + b.w)
      off = pref_y and math.abs(center_y(b) - pref_y) or 0
    else
      pos = (side == "top") and b.y or (b.y + b.h)
      off = pref_x and math.abs(center_x(b) - pref_x) or 0
    end
    if not best then
      best = { pos = pos, off = off, id = b.id }
    else
      -- strictly on the outer edge (eps) wins; then the off-axis match
      local better_pos
      if side == "left" or side == "top" then
        better_pos = pos < best.pos - 0.001
      else
        better_pos = pos > best.pos + 0.001
      end
      local same_pos = math.abs(pos - best.pos) <= 0.001
      if better_pos or (same_pos and off < best.off) then
        best = { pos = pos, off = off, id = b.id }
      end
    end
  end
  return best and best.id or nil
end

-- ── Helpers ──────────────────────────────────────────────────────

local function focused_of(view)
  for _, w in ipairs(view.windows or {}) do
    if w.window_id == view.active_window_id then
      return w, w.focused_block_id
    end
  end
end

-- Is the action's invoker the app (so rex.client.queue reaches it)?
-- From lib/focus.lua's proven pattern.
local function invoker_is_app_client(ctx)
  if not ctx.client_id then return false end
  local ok, res = pcall(rex.session.list_clients, { session_id = ctx.session_id })
  if not ok or type(res) ~= "table" or type(res.clients) ~= "table" then return false end
  for _, c in ipairs(res.clients) do
    if c.client_id == ctx.client_id then
      return c.info ~= nil and c.info.kind == "app"
    end
  end
  return false
end

local function vim_family(name)
  return name == "nvim" or name == "vim" or name == "vi"
end

local function passthrough(name, list)
  if name == "ssh" or name == "vim" or name == "vi" then return true end
  for _, pat in ipairs(list) do
    if name:find(pat) then return true end
  end
  return false
end

local Key = { left = "h", down = "j", up = "k", right = "l" }

local function send_key(sid, block, direction)
  rex.exec{ rex_cli, "send-key", "-s", sid, "-b", block, "ctrl+" .. Key[direction] }
end

-- Ask the focused block's nvim to move its own split. Returns
-- "moved", "edge", or "forward" (nvim didn't answer — blocked, no
-- socket, nested, or on a remote host).
local function ask_nvim(sid, block, direction)
  local sock = "/tmp/rex-nvim/" .. string.gsub(block, "%W", "_") .. ".sock"
  local expr = "v:lua.require'rex_nav'.move('" .. direction .. "')"
  local out = rex.exec{
    "env", "PATH=" .. login_path,
    "timeout", "0.25",
    "nvim", "--clean", "--server", sock, "--remote-expr", expr,
  }
  if out and out.code == 0 and out.stdout then
    local answer = out.stdout:gsub("^%s*", ""):gsub("%s*$", "")
    if answer == "moved" then return "moved" end
    if answer == "edge" then return "edge" end
  end
  return "forward"
end

-- Cross into the neighbouring tab (horizontal) at the layout edge.
-- Lands on the target's edge pane (seeded with this window's preferred
-- row), server-side focus plus the app's tab action when the app
-- invoked us (the tab strip follows client actions, not server focus).
local function cross_tab(ctx, view, window, direction, app_client)
  local windows = view.windows or {}
  local idx
  for i, w in ipairs(windows) do
    if w.window_id == window.window_id then idx = i end
  end
  if not idx or #windows < 1 then return end
  local next_i = (direction == "right") and (idx + 1) or (idx - 1)
  if next_i > #windows then next_i = 1 end
  if next_i < 1 then next_i = #windows end
  local target = windows[next_i]
  local blocks = M.leaves(target)
  local p = pref[window.window_id]
  local side = (direction == "right") and "left" or "right"
  local land = M.edge_block(blocks, side, p and p.y or nil)
  -- seed the target's preferred row with the one we're on
  if land and p then pref[target.window_id] = { x = p.x, y = p.y } end
  if land then
    pcall(rex.call, "session.focus_block", {
      session_id = ctx.session_id, block_id = land,
    })
  else
    pcall(rex.call, "session.focus_window", {
      session_id = ctx.session_id, window_id = target.window_id,
    })
  end
  if app_client then
    rex.client.queue(direction == "right" and "client.tab.next" or "client.tab.previous")
  end
end

-- Cross into the neighbouring session (vertical). Session switching
-- is client-side (the app), so from the app this queues the action;
-- from a CLI context (nvim's fallback) it is a no-op — the documented
-- limit of that path.
local function cross_session(ctx, direction, app_client)
  if not app_client then return end
  rex.client.queue(direction == "down" and "session.next" or "session.previous")
end

local function crosses(scope, direction)
  local horizontal = (direction == "left" or direction == "right")
  if scope == "both" then return true end
  if scope == "tabs" then return horizontal end
  if scope == "sessions" then return not horizontal end
  return false
end

-- ── The action ───────────────────────────────────────────────────

if not _G.REXNAV_TEST then

rex.action{
  name  = "vim_nav",
  title = "Navigate (vim/Rex)",
  description = "ctrl+h/j/k/l across nvim splits and Rex panes: nvim is asked over RPC, other apps get the key forwarded, and at an edge the focus crosses into the neighbouring pane (smart focus), tab or session.",
  args  = {
    direction  = "string",     -- left | down | up | right
    cross      = "string?",   -- off | tabs | sessions | both (default both)
    no_forward = "boolean?",  -- the nvim/vim edge fallback calls this
  },
  run   = function(ctx, args)
    local view = rex.session.view{ session_id = ctx.session_id }
    local window, focus = focused_of(view)
    if not window or not focus then
      error("no focused pane to navigate from", 0)
    end
    local scope = args.cross or "both"
    local app_client = invoker_is_app_client(ctx)

    -- 1. Hand the key to the app inside the pane, if it owns it.
    if not args.no_forward then
      local ok, res = pcall(rex.call, "com.superlogical.terminal.process", {
        session_id = ctx.session_id, block_id = focus,
      })
      local fg = ok and res and res.foreground or nil
      local name = fg and string.lower(fg.name or "") or ""
      if name ~= "" then
        local nested = false
        if name == "nvim" then
          -- a vim *below* this nvim (:terminal nvim) means the socket
          -- serves the outer instance — forward so the inner one
          -- handles its own splits. terminal.process's `child` mirrors
          -- the foreground when nothing is deeper, so compare pids.
          local deep = {}
          if res.child then table.insert(deep, res.child) end
          if res.ancestors then
            for _, a in ipairs(res.ancestors) do table.insert(deep, a) end
          end
          for _, pr in ipairs(deep) do
            if pr and pr.pid ~= fg.pid and vim_family(string.lower(pr.name or "")) then
              nested = true
            end
          end
        end
        if passthrough(name, PASSTHROUGH) or nested or (name ~= "nvim" and vim_family(name)) then
          send_key(ctx.session_id, focus, args.direction)
          return { forwarded = true }
        elseif name == "nvim" then
          local answer = ask_nvim(ctx.session_id, focus, args.direction)
          if answer == "moved" then return { nvim = "moved" } end
          if answer == "forward" then
            send_key(ctx.session_id, focus, args.direction)
            return { forwarded = true }
          end
          -- "edge": fall through to the pane move below
        end
      end
    end

    -- 2. Move between panes (smart focus) / cross at the edge.
    if window.zoomed_block_id then
      -- A zoomed window shows one pane; plain directional focus.
      local _, err = rex.session.focus_direction{
        session_id = ctx.session_id, direction = args.direction,
      }
      if err then error(err, 0) end
      return { zoomed = true }
    end

    local blocks = M.leaves(window)
    local target = M.pick(blocks, focus, args.direction, window.window_id, pref)
    if target then
      local _, err = rex.session.focus_block{
        session_id = ctx.session_id, block_id = target,
      }
      if err then error(err, 0) end
      return { pane = target }
    end

    -- 3. At the layout edge: cross into the next tab / session.
    if crosses(scope, args.direction) then
      local horizontal = (args.direction == "left" or args.direction == "right")
      if horizontal then
        cross_tab(ctx, view, window, args.direction, app_client)
      else
        cross_session(ctx, args.direction, app_client)
      end
      return { crossed = true }
    end
    return { edge = true }
  end,
}

-- ── Bindings (herdr parity: the full 2D torus) ────────────────────
for _, d in ipairs({ "h", "j", "k", "l", "left", "down", "up", "right" }) do
  rex.bind("ctrl+" .. d, "vim_nav", { direction = d })
end

end -- REXNAV_TEST

return M
