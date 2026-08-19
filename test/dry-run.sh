#!/usr/bin/env bash
#
# Dry-run harness for navigate.sh — exercises the full smart-focus logic
# (geometry, preferred-coordinate selection, bounded walk, state-file write)
# against a FAKE herdr so your real session is never touched.
#
# Layout simulated:  A (left, full height) | B (top-right) | C (bottom-right)
#
#   ┌───────────┬───────────┐
#   │           │     B     │
#   │     A     ├───────────┤
#   │           │     C     │
#   └───────────┴───────────┘
#
# Usage:  ./test/dry-run.sh
# Watch the logged `pane focus` calls + the state file after each move.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
state_dir="$work/state"
fake_herdr="$work/herdr"
mkdir -p "$state_dir"

# --- Fake herdr: serves `pane layout`, `pane process-info`, and `pane focus`.
# `pane focus` just moves a cursor in an in-memory model and logs the call.
cat > "$fake_herdr" <<'PY'
#!/usr/bin/env python3
import sys, json, os, pathlib
STATE = pathlib.Path(os.environ["FAKE_HERDR_STATE"])
model = json.loads(STATE.read_text() or "{}")
# Layout: A | B / C
PANES = {
    "A": {"x":0,  "y":0,  "width":100, "height":50},
    "B": {"x":100,"y":0,  "width":100, "height":25},
    "C": {"x":100,"y":25, "width":100, "height":25},
}
def layout_json():
    f = model.get("focused", "A")
    return json.dumps({"result":{"layout":{
        "focused_pane_id": f, "tab_id":"w:t1", "zoomed": False,
        "panes":[{"pane_id":p,"rect":r,"focused":p==f} for p,r in PANES.items()]}}})
def process_info_json():
    # Report a non-Vim foreground so navigate.sh takes the direct-focus path.
    return json.dumps({"result":{"process_info":{"foreground_processes":[{"name":"bash"}]}}})
def focus(direction, pane):
    f = pane if pane else model.get("focused","A")
    x,y = PANES[f]["x"], PANES[f]["y"]
    w,h = PANES[f]["width"], PANES[f]["height"]
    cx, cy = x+w/2, y+h/2
    cands = []
    for pid,r in PANES.items():
        if pid==f: continue
        rx,ry,rw,rh = r["x"],r["y"],r["width"],r["height"]
        if direction=="left"  and rx+rw<=x:           bey=True
        elif direction=="right" and rx>=x+w:          bey=True
        elif direction=="up"   and ry+rh<=y:          bey=True
        elif direction=="down" and ry>=y+h:           bey=True
        else: bey=False
        if not bey: continue
        if direction in ("left","right"):
            ov = (ry < y+h) and (y < ry+rh)
        else:
            ov = (rx < x+w) and (x < rx+rw)
        if ov: cands.append(pid)
    if not cands:
        print(f"[fake herdr] focus {direction} from {f}: NO NEIGHBOR (no-op)", file=sys.stderr); return
    # deterministic pick: nearest cross-axis center (mimics herdr's single neighbor)
    new = cands[0]
    model["focused"]=new
    STATE.write_text(json.dumps(model))
    print(f"[fake herdr] focus {direction} from {f} -> {new}", file=sys.stderr)
args = sys.argv[1:]
if args[:2]==["pane","layout"]:
    print(layout_json())
elif args[:2]==["pane","process-info"]:
    print(process_info_json())
elif args[:2]==["pane","focus"]:
    direction=None; pane=None; i=2
    while i<len(args):
        if args[i]=="--direction": direction=args[i+1]; i+=2
        elif args[i]=="--pane": pane=args[i+1]; i+=2
        elif args[i]=="--current": pane=model.get("focused","A"); i+=1
        else: i+=1
    focus(direction, pane)
elif args[:2]==["pane","send-keys"]:
    print(f"[fake herdr] send-keys {args[2:]} (Vim path)", file=sys.stderr)
else:
    print(f"[fake herdr] unhandled: {args}", file=sys.stderr)
PY
chmod +x "$fake_herdr"

echo "FAKE_HERDR_STATE=$work/model.json" > "$work/env"
printf '{"focused":"C"}\n' > "$work/model.json"

export HERDR_BIN_PATH="$fake_herdr"
export FAKE_HERDR_STATE="$work/model.json"
export HERDR_PANE_ID="C"
export HERDR_NAV_STATE_DIR="$state_dir"

run() {
  echo
  echo ">>> navigate.sh $1   (focused before: $(jq -r .focused "$work/model.json"))"
  # In real herdr, HERDR_PANE_ID is always the pane that had focus when the key
  # fired — i.e. the currently focused pane. Mirror that per move.
  export HERDR_PANE_ID="$(jq -r .focused "$work/model.json")"
  bash "$root/navigate.sh" "$1"
  echo "    focused after : $(jq -r .focused "$work/model.json")"
  echo "    state file    : $(cat "$state_dir/w_t1.json" 2>/dev/null || echo '(none)')"
}

echo "=== Scenario: C -> left -> A -> right (should return to C, not B) ==="
run left     # C -> A   (seeds preferred_y from C's row)
run right    # A -> ?   (uses stored preferred_y to pick C over B)
run left     # C -> A
run right    # A -> C   again

echo
echo "=== Now from B, move down (should stay in right column, land on C) ==="
printf '{"focused":"B"}\n' > "$work/model.json"
rm -f "$state_dir/w_t1.json"
run down     # B -> C   (seeds preferred_x from B's column)
run up       # C -> B
run down     # B -> C

echo
echo "=== Cleanup ==="
rm -rf "$work"
echo "done. (temp dir $work removed)"
