-- Geometry tests for rex/vim_nav.lua, run with `rex do test/rex/test.lua`
-- from the repo root (any server will do; the script makes no server
-- calls). Fixtures follow session.view's shape, recorded from live
-- sessions (see tests in herdr-zextract for the source shapes).

_G.REXNAV_TEST = true
local M = dofile("rex/vim_nav.lua")

local passed, failed = 0, 0
local function eq(name, got, want)
  if got == want then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL " .. name .. ": got " .. tostring(got) .. ", want " .. tostring(want))
  end
end

-- Window fixture: two columns, the right one split into two rows.
--   +--------+--------+
--   |        |  top   |
--   |  left  +--------+
--   |        | bottom |
--   +--------+--------+
local function leaf(id, x, y, w, h, label)
  return { id = id, x = x, y = y, w = w, h = h, label = label or id }
end
local blocks = {
  leaf("L", 0, 0, 0.5, 1),
  leaf("RT", 0.5, 0, 0.5, 0.5),
  leaf("RB", 0.5, 0.5, 0.5, 0.5),
}
local pref_store = {}

-- plain neighbour
eq("left→right", M.pick(blocks, "L", "right", "w", pref_store), "RT")
-- preferred row survives: from RT (upper), right-cross then left lands
-- back on L; from RB, a left move from the right column picks the row
-- pane nearest the preferred row
pref_store = {}
M.pick(blocks, "RB", "left", "w2", pref_store)          -- RB → L (seeds pref on L's centre)
eq("return-to-sender", M.pick(blocks, "L", "right", "w2", pref_store), "RB")
-- stacked move
pref_store = {}
eq("top→bottom", M.pick(blocks, "RT", "down", "w3", pref_store), "RB")
eq("bottom→top", M.pick(blocks, "RB", "up", "w3", pref_store), "RT")
-- edge cases
eq("L left is edge", M.pick(blocks, "L", "left", "w4", pref_store), nil)
eq("RB right is edge", M.pick(blocks, "RB", "right", "w4", pref_store), nil)

-- a 2x2 grid: horizontal move keeps the preferred row
--   +----+----+
--   | A  | B  |
--   +----+----+
--   | C  | D  |
--   +----+----+
local grid = {
  leaf("A", 0, 0, 0.5, 0.5), leaf("B", 0.5, 0, 0.5, 0.5),
  leaf("C", 0, 0.5, 0.5, 0.5), leaf("D", 0.5, 0.5, 0.5, 0.5),
}
pref_store = {}
M.pick(grid, "C", "right", "w5", pref_store)             -- C → D (pref row = C's)
eq("row survives", M.pick(grid, "D", "left", "w5", pref_store), "C")
pref_store = {}
M.pick(grid, "C", "up", "w6", pref_store)               -- C → A
eq("col survives", M.pick(grid, "A", "down", "w6", pref_store), "C")

-- edge_block: leftmost / rightmost pane, nearest to a preferred row
eq("edge left of grid", M.edge_block(grid, "left", 0.25), "A")
eq("edge right low row", M.edge_block(grid, "right", 0.75), "D")
eq("edge top right col", M.edge_block(grid, "top", nil, 0.75), "B")

-- leaves(): layout tree → block list (floating layers excluded)
local window = {
  window_id = "w1",
  focused_block_id = "L",
  layers = {
    {
      kind = "tiled",
      blocks = {
        { block_id = "L", label = "shell" },
        { block_id = "RB", label = "shell" },
      },
      layout = {
        rect = { 0, 0, 1, 1 },
        split = {
          direction = "horizontal",
          before = { rect = { 0, 0, 0.5, 1 }, block_id = "L" },
          after = {
            rect = { 0.5, 0, 0.5, 1 },
            split = {
              direction = "vertical",
              before = { rect = { 0.5, 0, 0.5, 0.5 }, block_id = "RT" },
              after = { rect = { 0.5, 0.5, 0.5, 0.5 }, block_id = "RB" },
            },
          },
        },
      },
    },
    {
      kind = "floating",
      blocks = { { block_id = "POPUP", label = "zextract" } },
      layout = { rect = { 0.1, 0.1, 0.8, 0.8 }, block_id = "POPUP" },
    },
  },
}
local leaves = M.leaves(window)
eq("leaves count", #leaves, 3)
local ids = {}
for _, l in ipairs(leaves) do ids[#ids + 1] = l.id end
table.sort(ids)
eq("leaves ids", table.concat(ids, ","), "L,RB,RT")

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
