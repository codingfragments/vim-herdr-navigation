#!/usr/bin/env bash
#
# vim-herdr-navigation — herdr side
#
# Invoked by a herdr keybind as: navigate.sh <left|down|up|right>
#
# If the focused pane is running Vim/Neovim in the foreground, hand the matching
# Ctrl chord to that pane so Vim moves between its own splits (and, at a split
# edge, calls back into herdr to cross the pane boundary — see editor/*). The same
# forwarding can be turned on for other TUIs that own Ctrl+h/j/k/l themselves via
# HERDR_NAV_PASSTHROUGH_RE (off by default — see below). For any other foreground
# process, move herdr's pane focus directly.
#
# Smart focus (non-Vim path): instead of a single directional hop, the target
# pane is chosen from the tab's geometry using a per-tab "preferred" coordinate
# so that crossing into a stacked column lands on the row you were last in — not
# always the top pane. State is stored per tab under
#   ${HERDR_NAV_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/vim-herdr-navigation}/<tab_id>.json
# A horizontal move reads preferred_y to pick the row, then writes preferred_x;
# a vertical move reads preferred_x to pick the column, then writes preferred_y.
# If anything is missing/corrupt/no jq, behavior falls back to today's plain
# directional focus.
#
# Requires `jq` for Vim detection and smart focus. Without it, every key just
# moves the herdr pane focus (no Vim awareness, no smart walk).

set -euo pipefail

dir="${1:?usage: navigate.sh <left|down|up|right>}"
herdr="${HERDR_BIN_PATH:-herdr}"
pane="${HERDR_PANE_ID:-}"

case "$dir" in
  left)  key="ctrl+h"; axis=h ;;
  down)  key="ctrl+j"; axis=v ;;
  up)    key="ctrl+k"; axis=v ;;
  right) key="ctrl+l"; axis=h ;;
  *) echo "navigate.sh: unknown direction: $dir" >&2; exit 2 ;;
esac

# Foreground process names that mean "Vim is in control of this pane".
# Same matcher vim-tmux-navigator uses: vi, vim, nvim, view, gvim, *diff, ...
vim_re='^g?(view|l?n?vim?x?)(diff)?$'

# Opt-in passthrough for non-Vim TUIs (see README): HERDR_NAV_PASSTHROUGH_RE is an
# ERE matched against the lower-cased process name. Empty (default) forwards only Vim.
passthrough_re="${HERDR_NAV_PASSTHROUGH_RE:-}"

forward=0
if [ -n "$pane" ] && command -v jq >/dev/null 2>&1; then
  if "$herdr" pane process-info --pane "$pane" 2>/dev/null \
    | jq -e --arg vim "$vim_re" --arg pass "$passthrough_re" \
        '.result.process_info.foreground_processes[]?.name
         | ascii_downcase
         | select(test($vim) or ($pass != "" and (try test($pass) catch false)))' >/dev/null 2>&1; then
    forward=1
  fi
fi

if [ "$forward" -eq 1 ]; then
  exec "$herdr" pane send-keys "$pane" "$key"
fi

# --- Direct herdr-pane focus (non-Vim path) -------------------------------

# Without a pane id or jq we can't be smart: fall back to plain directional focus.
if [ -z "$pane" ] || ! command -v jq >/dev/null 2>&1; then
  if [ -n "$pane" ]; then
    exec "$herdr" pane focus --direction "$dir" --pane "$pane"
  else
    exec "$herdr" pane focus --direction "$dir" --current
  fi
fi

state_dir="${HERDR_NAV_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/vim-herdr-navigation}"

layout_json="$("$herdr" pane layout --pane "$pane" 2>/dev/null || true)"
if [ -z "$layout_json" ]; then
  exec "$herdr" pane focus --direction "$dir" --pane "$pane"
fi

zoomed="$(printf '%s' "$layout_json" | jq -r '.result.layout.zoomed // false')"
if [ "$zoomed" = "true" ]; then
  # Zoomed: only one pane is visible; a smart walk makes no sense.
  exec "$herdr" pane focus --direction "$dir" --pane "$pane"
fi

tab_id="$(printf '%s' "$layout_json" | jq -r '.result.layout.tab_id // empty')"
focused_id="$(printf '%s' "$layout_json" | jq -r '.result.layout.focused_pane_id // empty')"
if [ -z "$tab_id" ] || [ -z "$focused_id" ]; then
  exec "$herdr" pane focus --direction "$dir" --pane "$pane"
fi

# Source pane bounds + center.
read -r cur_x cur_y cur_w cur_h <<EOF
$(printf '%s' "$layout_json" | jq -r --arg id "$focused_id" \
  '.result.layout.panes[] | select(.pane_id == $id) | .rect | "\(.x) \(.y) \(.width) \(.height)"')
EOF
cur_cx=$(( cur_x + cur_w / 2 ))
cur_cy=$(( cur_y + cur_h / 2 ))

# Candidate panes strictly beyond the source in $dir, with cross-axis overlap.
# For left/right: beyond on X, overlap on Y. For up/down: beyond on Y, overlap on X.
candidates_json="$(printf '%s' "$layout_json" | jq -c \
  --arg fid "$focused_id" --arg dir "$dir" \
  --argjson bx "$cur_x" --argjson by "$cur_y" --argjson bw "$cur_w" --argjson bh "$cur_h" '
  def beyond:
    if   $dir == "left"  then (.x + .width)  <= $bx
    elif $dir == "right" then .x             >= ($bx + $bw)
    elif $dir == "up"    then (.y + .height) <= $by
    else                      .y             >= ($by + $bh) end;
  def overlap:
    if ($dir == "left" or $dir == "right")
    then (.y < ($by + $bh)) and ($by < (.y + .height))
    else (.x < ($bx + $bw)) and ($bx < (.x + .width)) end;
  .result.layout.panes[]
  | select(.pane_id != $fid)
  | .rect as $r
  | select($r | beyond and overlap)
  | { pane_id,
      cx: ($r.x + ($r.width  / 2)),
      cy: ($r.y + ($r.height / 2)) }
' 2>/dev/null || true)"

n="$(printf '%s' "$candidates_json" | jq -s 'length' 2>/dev/null || echo 0)"
if [ "$n" -eq 0 ]; then
  # No overlapping candidate (odd/L-shaped layout): don't regress — move plainly.
  exec "$herdr" pane focus --direction "$dir" --pane "$pane"
fi

# Per-tab preferred coordinate on the cross axis (seed from the source center).
mkdir -p "$state_dir"
state_file="$state_dir/$(printf '%s' "$tab_id" | tr ':' '_').json"

if [ "$axis" = "h" ]; then
  pref_key="preferred_y"; cross_field="cy"; seed="$cur_cy"
else
  pref_key="preferred_x"; cross_field="cx"; seed="$cur_cx"
fi
pref_val="$(jq -r --arg k "$pref_key" '.[$k] // empty' "$state_file" 2>/dev/null || true)"
[ -z "$pref_val" ] && pref_val="$seed"

# Target = candidate whose cross-axis center is nearest the preferred coordinate.
target="$(printf '%s' "$candidates_json" | jq -s -r \
  --arg field "$cross_field" --argjson pref "$pref_val" \
  'sort_by(pow((.[$field] - $pref); 2)) | .[0].pane_id')"
read -r target_cx target_cy <<EOF
$(printf '%s' "$candidates_json" | jq -r --arg id "$target" \
  'select(.pane_id == $id) | "\(.cx) \(.cy)"')
EOF

# Walk to the target: one primary-direction hop into the neighbour column/row,
# then cross-axis hops until the focused pane is the target (bounded by pane count).
total_panes="$(printf '%s' "$layout_json" | jq -r '.result.layout.panes | length')"

"$herdr" pane focus --direction "$dir" --pane "$pane" >/dev/null 2>&1 || true

iter=0
while [ "$iter" -lt "$total_panes" ]; do
  iter=$(( iter + 1 ))
  cur_layout="$("$herdr" pane layout --pane "$pane" 2>/dev/null || true)"
  [ -z "$cur_layout" ] && break
  cur_focused="$(printf '%s' "$cur_layout" | jq -r '.result.layout.focused_pane_id // empty')"
  [ -z "$cur_focused" ] && break
  [ "$cur_focused" = "$target" ] && break

  sec="$(printf '%s' "$cur_layout" | jq -r \
    --arg id "$cur_focused" --arg axis "$axis" \
    --argjson tcx "$target_cx" --argjson tcy "$target_cy" '
    .result.layout.panes[] | select(.pane_id == $id) | .rect as $r |
    if $axis == "h"
    then (if $tcy < ($r.y + $r.height/2) then "up"   else "down"  end)
    else     (if $tcx < ($r.x + $r.width/2)  then "left" else "right" end) end
  ')"
  [ -z "$sec" ] && break
  "$herdr" pane focus --direction "$sec" --pane "$cur_focused" >/dev/null 2>&1 || break
done

# Persist both preferred coordinates. Along the moved axis we store the new
# center; across the axis we preserve the preference we just targeted with
# (stored value if any, else the source-pane seed) — so the row/column you're
# conceptually on survives a move on the other axis.
final_layout="$("$herdr" pane layout --pane "$pane" 2>/dev/null || true)"
if [ -n "$final_layout" ]; then
  final_focused="$(printf '%s' "$final_layout" | jq -r '.result.layout.focused_pane_id // empty')"
  read -r fin_cx fin_cy <<EOF
$(printf '%s' "$final_layout" | jq -r --arg id "$final_focused" \
  '.result.layout.panes[] | select(.pane_id == $id) | .rect | "\(.x + .width/2) \(.y + .height/2)"')
EOF
  if [ -n "$fin_cx" ] && [ -n "$fin_cy" ]; then
    if [ "$axis" = "h" ]; then
      along_key="preferred_x"; along_val="$fin_cx"; cross_key="preferred_y"; cross_val="$pref_val"
    else
      along_key="preferred_y"; along_val="$fin_cy"; cross_key="preferred_x"; cross_val="$pref_val"
    fi
    tmp="$state_file.tmp.$$"
    jq --arg ak "$along_key" --argjson av "$along_val" \
       --arg ck "$cross_key" --argjson cv "$cross_val" \
       --arg tab "$tab_id" \
       '. + {($ak): $av, ($ck): $cv, tab_id: $tab, updated: now}' "$state_file" 2>/dev/null > "$tmp" \
      || printf '{"%s":%s,"%s":%s,"tab_id":"%s","updated":%s}\n' \
           "$along_key" "$along_val" "$cross_key" "$cross_val" "$tab_id" "$(date +%s)" > "$tmp"
    mv -f "$tmp" "$state_file"
  fi
fi

exit 0
