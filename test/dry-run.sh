#!/usr/bin/env bash
#
# Dry-run harness for navigate.sh — exercises the full smart-focus logic
# (geometry, preferred-coordinate selection, single-call pane.focus over the
# socket, state-file write) against a FAKE herdr so your real session is never
# touched.
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
# Watch the logged focus calls + the state file after each move.
# Look for "[socket]" lines — those are the single pane.focus calls (no walk,
# no flicker). "[walk]" lines only appear if python3/socket is unavailable.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
state_dir="$work/state"
fake_herdr="$work/herdr"
fake_sock="$work/herdr.sock"
model="$work/model.json"
mkdir -p "$state_dir"

# --- Shared model file: {"focused":"<pane_id>"} read/written by both the CLI
# mock and the socket server.
printf '{"focused":"C"}\n' > "$model"

# --- Fake herdr CLI: serves `pane layout` and `pane process-info`.
# (`pane focus` is only used on the fallback walk path; the socket server
#  below handles the primary pane.focus path.)
cat > "$fake_herdr" <<'PY'
#!/usr/bin/env python3
import sys, json, os, pathlib
STATE = pathlib.Path(os.environ["FAKE_HERDR_STATE"])
model = json.loads(STATE.read_text() or "{}")
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
    return json.dumps({"result":{"process_info":{"foreground_processes":[{"name":"bash"}]}}})
def focus(direction, pane):
    f = pane if pane else model.get("focused","A")
    x,y,w,h = PANES[f]["x"],PANES[f]["y"],PANES[f]["width"],PANES[f]["height"]
    cands=[]
    for pid,r in PANES.items():
        if pid==f: continue
        rx,ry,rw,rh = r["x"],r["y"],r["width"],r["height"]
        if direction=="left"  and rx+rw<=x:           bey=True
        elif direction=="right" and rx>=x+w:          bey=True
        elif direction=="up"   and ry+rh<=y:          bey=True
        elif direction=="down" and ry>=y+h:          bey=True
        else: bey=False
        if not bey: continue
        if direction in ("left","right"): ov=(ry<y+h)and(y<ry+rh)
        else: ov=(rx<x+w)and(x<rx+rw)
        if ov: cands.append(pid)
    if not cands:
        print(f"[walk] focus {direction} from {f}: NO NEIGHBOR (no-op)", file=sys.stderr); return
    new=cands[0]; model["focused"]=new; STATE.write_text(json.dumps(model))
    print(f"[walk] focus {direction} from {f} -> {new}", file=sys.stderr)
args=sys.argv[1:]
if args[:2]==["pane","layout"]: print(layout_json())
elif args[:2]==["pane","process-info"]: print(process_info_json())
elif args[:2]==["pane","focus"]:
    d=None;p=None;i=2
    while i<len(args):
        if args[i]=="--direction": d=args[i+1];i+=2
        elif args[i]=="--pane": p=args[i+1];i+=2
        elif args[i]=="--current": p=model.get("focused","A");i+=1
        else: i+=1
    focus(d,p)
elif args[:2]==["pane","send-keys"]:
    print(f"[walk] send-keys {args[2:]} (Vim path)", file=sys.stderr)
else: print(f"[cli] unhandled: {args}", file=sys.stderr)
PY
chmod +x "$fake_herdr"

# --- Fake socket server: handles `pane.focus {pane_id}` — the primary path.
# Sets focused=pane_id in the model, logs the single call, replies with a
# success response shaped like the real API.
cat > "$work/sock_server.py" <<'PY'
#!/usr/bin/env python3
import sys, json, os, socket, pathlib
sock_path = sys.argv[1]
model_path = pathlib.Path(os.environ["FAKE_HERDR_STATE"])
PANES = {
    "A": {"x":0,"y":0,"width":100,"height":50},
    "B": {"x":100,"y":0,"width":100,"height":25},
    "C": {"x":100,"y":25,"width":100,"height":25},
}
if os.path.exists(sock_path): os.unlink(sock_path)
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(sock_path); srv.listen(8)
while True:
    try:
        conn, _ = srv.accept()
    except Exception: break
    try:
        data = b""
        while b"\n" not in data:
            chunk = conn.recv(4096)
            if not chunk: break
            data += chunk
        req = json.loads(data.decode())
        pid = req.get("params",{}).get("pane_id","")
        prev = json.loads(model_path.read_text()).get("focused","?")
        model = json.loads(model_path.read_text())
        model["focused"] = pid
        model_path.write_text(json.dumps(model))
        print(f"[socket] pane.focus {pid}  (was {prev})", file=sys.stderr)
        resp = {"id": req.get("id"), "result": {"type":"pane_info","pane":{"pane_id":pid,"focused":True}}}
        conn.sendall((json.dumps(resp)+"\n").encode())
    except Exception as e:
        print(f"[socket] error: {e}", file=sys.stderr)
    finally:
        conn.close()
PY

export HERDR_BIN_PATH="$fake_herdr"
export HERDR_SOCKET_PATH="$fake_sock"
export FAKE_HERDR_STATE="$model"
export HERDR_NAV_STATE_DIR="$state_dir"

python3 "$work/sock_server.py" "$fake_sock" &
sock_pid=$!
# wait for socket to appear
for _ in $(seq 1 50); do [ -S "$fake_sock" ] && break; sleep 0.02; done

# Binary under test: defaults to the Rust release build; override with
#   NAV_BIN=/path/to/navigate ./test/dry-run.sh        (Rust)
#   NAV_BIN="$PWD/navigate.sh.legacy" ./test/dry-run.sh  (legacy shell, via bash)
nav_bin="${NAV_BIN:-$root/target/release/navigate}"

run() {
  echo
  echo ">>> $(basename "$nav_bin") $1   (focused before: $(jq -r .focused "$model"))"
  export HERDR_PANE_ID="$(jq -r .focused "$model")"
  if [ "${nav_bin##*.}" = "sh" ] || [ "${nav_bin##*.}" = "legacy" ]; then
    bash "$nav_bin" "$1"
  else
    "$nav_bin" "$1"
  fi
  echo "    focused after : $(jq -r .focused "$model")"
  echo "    state file    : $(cat "$state_dir/w_t1.json" 2>/dev/null || echo '(none)')"
}

echo "=== Scenario: C -> left -> A -> right (should return to C, not B) ==="
run left     # C -> A   (seeds preferred_y from C's row)
run right    # A -> ?   (uses stored preferred_y to pick C over B)
run left     # C -> A
run right    # A -> C   again

echo
echo "=== Now from B, move down (should stay in right column, land on C) ==="
printf '{"focused":"B"}\n' > "$model"
rm -f "$state_dir/w_t1.json"
run down     # B -> C   (seeds preferred_x from B's column)
run up       # C -> B
run down     # B -> C

echo
echo "=== Cleanup ==="
kill "$sock_pid" 2>/dev/null || true
rm -rf "$work"
echo "done. (temp dir $work removed)"
