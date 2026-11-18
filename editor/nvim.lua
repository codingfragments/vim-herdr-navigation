-- vim-herdr-navigation — Neovim side
--
-- Seamless <C-h/j/k/l> navigation between Neovim splits and the
-- surrounding multiplexer's panes. Inside herdr, at a split edge the
-- key is handed to herdr's navigate binary (same smart-focus as the
-- non-Vim path). Inside Rex, the pane runs a socket named after the
-- block, the Rex side asks it over RPC whether the move happened, and
-- this file's own maps cover the rare cases where Rex forwards the
-- key instead (blocked nvim, no socket, nested nvim). Outside both it
-- falls back to tmux (if any) or plain wincmd.
--
-- Load it so it wins over other <C-h/j/k/l> mappings (e.g.
-- vim-tmux-navigator): drop it in your config's after/plugin dir
--   cp editor/nvim.lua ~/.config/nvim/after/plugin/herdr_nav.lua
-- or source it from your config after plugins load:
--   dofile("/path/to/vim-herdr-navigation/editor/nvim.lua")

local Wincmd = { left = "h", down = "j", up = "k", right = "l" }

-- Move to the neighbouring split in `dir`, from any mode.
--
-- Neovim 0.12 runs a TUI frontend plus an --embed backend; ex commands
-- driven over RPC (`wincmd`) get overridden by the frontend, so the
-- move is computed from window geometry and applied with
-- nvim_set_current_win — reliable from keymaps (input path) and from
-- the Rex launcher's RPC alike.
local function move_split(dir)
  local cur = vim.api.nvim_get_current_win()
  local wins = vim.api.nvim_list_wins()
  if #wins < 2 then return "edge" end
  local pos = vim.api.nvim_win_get_position(cur)
  local col, row = pos[2], pos[1]
  local width, height = vim.api.nvim_win_get_width(cur), vim.api.nvim_win_get_height(cur)
  local horizontal = (dir == "left" or dir == "right")
  local dcol = (dir == "left") and -1 or (dir == "right") and 1 or 0
  local drow = (dir == "up") and -1 or (dir == "down") and 1 or 0
  local best, bestd
  for _, w in ipairs(wins) do
    if w ~= cur then
      local p = vim.api.nvim_win_get_position(w)
      local dc, dr = p[2] - col, p[1] - row
      local aligned
      if horizontal then
        aligned = dr < height and dr + vim.api.nvim_win_get_height(w) > 0
      else
        aligned = dc < width and dc + vim.api.nvim_win_get_width(w) > 0
      end
      local dist = horizontal and (dc * dcol) or (dr * drow)
      if dist > 0 and aligned and (not bestd or dist < bestd) then
        best, bestd = w, dist
      end
    end
  end
  if not best then return "edge" end
  vim.api.nvim_set_current_win(best)
  return "moved"
end

-- At a split edge: cross into the surrounding multiplexer.

-- herdr: route through the plugin's `*-edge` action (navigate
-- --no-forward), NOT `herdr pane focus` directly — the edge-cross gets
-- the same smart-focus target selection, cross-tab navigation, and
-- per-tab preferred-coordinate persistence as the non-Vim path.
local function herdr_edge(dir)
  local herdr = vim.env.HERDR_BIN_PATH
  if herdr == nil or herdr == "" then herdr = "herdr" end
  vim.fn.system({ herdr, "plugin", "action", "invoke",
                  "vim-herdr-navigation." .. dir .. "-edge" })
end

-- Rex: hand the edge back to the vim_nav action over the CLI. From
-- nvim (a CLI client) it moves panes within the tab server-side;
-- crossing tabs needs the app's context, which a CLI call doesn't
-- have — the documented limit of this fallback path.
local function rex_edge(dir)
  local rexbin = vim.env.REX_BIN_DIR
  if rexbin == nil or rexbin == "" then rexbin = "rex" else rexbin = rexbin .. "/rex" end
  vim.fn.system({ rexbin, "do", "-s", vim.env.REX_SESSION,
                  "vim_nav", "direction=" .. dir, "no_forward=1" })
end

local in_rex = vim.env.REX_BLOCK and vim.env.REX_BLOCK ~= ""

if in_rex then
  -- ── Rex: socket per block, rex_nav module for the RPC ──────────
  -- The socket is named after REX_BLOCK (inherited by nvim): Neovim
  -- 0.12's TUI frontend and --embed backend have different pIDs, so a
  -- pid-named socket can't be found from the multiplexer's process
  -- info. Nested nvim (:terminal nvim) shares the block; the second
  -- serverstart then fails and that instance stays on the map
  -- fallback below.
  local dir_path = "/tmp/rex-nvim"
  -- 0700 via libuv: vim.fn.mkdir's mode argument mangles bits
  do
    local uv = vim.uv or vim.loop
    local ok, stat = pcall(uv.fs_stat, dir_path)
    if not ok or not stat then
      pcall(uv.fs_mkdir, dir_path, tonumber("700", 8))
    end
  end
  local name = string.gsub(vim.env.REX_BLOCK, "%W", "_")
  local sock = dir_path .. "/" .. name .. ".sock"
  local started = ""
  pcall(function() started = vim.fn.serverstart(sock) end)
  if started == "" then
    -- Stale socket from a crashed nvim, or a nested instance: take
    -- the path over (the newest nvim is the one the user works in).
    os.remove(sock)
    pcall(function() started = vim.fn.serverstart(sock) end)
  end
  if started ~= "" then
    vim.api.nvim_create_autocmd("VimLeavePre", {
      callback = function()
        pcall(vim.fn.serverstop, sock)
        os.remove(sock)
      end,
    })
  end
  -- Preloaded so `v:lua.require'rex_nav'.move('left')` resolves over
  -- RPC (--remote-expr evaluates VimL; the module must not load user
  -- config on the calling side — it doesn't, package.loaded is enough).
  package.loaded["rex_nav"] = { move = move_split }
end

local function nav(dir)
  if move_split(dir) == "moved" then return end
  if vim.env.HERDR_PANE_ID and vim.env.HERDR_PANE_ID ~= "" then
    herdr_edge(dir)
  elseif in_rex then
    rex_edge(dir)
  elseif vim.env.TMUX and vim.env.TMUX ~= "" then
    local tmux = { left = "Left", down = "Down", up = "Up", right = "Right" }
    pcall(vim.cmd, "TmuxNavigate" .. tmux[dir])
  end
end

local function map(lhs, dir, desc)
  vim.keymap.set({ "n", "i" }, lhs, function() nav(dir) end,
    { silent = true, noremap = true, desc = desc })
end

map("<C-h>", "left", "Navigate left (vim/multiplexer)")
map("<C-j>", "down", "Navigate down (vim/multiplexer)")
map("<C-k>", "up", "Navigate up (vim/multiplexer)")
map("<C-l>", "right", "Navigate right (vim/multiplexer)")
