#!/usr/bin/env bash
#
# Dry-run harness for navigate (Rust) — exercises the full smart-focus logic
# (geometry, preferred-coordinate selection, single-call pane.focus over the
# socket, state-file write) AND cross-tab navigation (tab.list / tab.focus over
# the socket) against a FAKE herdr so your real session is never touched.
#
# Layout simulated:
#   Tab 1 (w:t1):  A (left, full height) | B (top-right) | C (bottom-right)
#   Tab 2 (w:t2):  D (full width, single pane)
#
#   ┌───────────┬───────────┐
#   │           │     B     │   tab 1
#   │     A     ├───────────┤
#   │           │     C     │
#   └───────────┴───────────┘
#   ┌───────────────────────┐
#   │           D           │           tab 2 (single pane)
#   └───────────────────────┘
#
# Usage:  ./test/dry-run.sh
# Env:    NAV_BIN=/path/to/navigate  (default: target/release/navigate)
#         NAV_CROSS_TABS=1           (set automatically for the cross-tab scenario)
#
# Watch the logged focus calls + the state file after each move.
# Look for "[socket]" lines — those are the single pane.focus / tab.focus calls.
# "[walk]" lines only appear if the socket is unavailable.

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
state_dir="$work/state"
fake_herdr="$work/herdr"
fake_sock="$work/herdr.sock"
model="$work/model.json"
mkdir -p "$state_dir"

# --- Shared model file read/written by both the CLI mock and the socket server:
#   {"focused":"C","active_tab":"w:t1","tabs":{"w:t1":{"focused":"C"},"w:t2":{"focused":"D"}}}
# `focused` (top level) mirrors the active tab's focused pane so the harness
# helper can read it with a single jq.
printf '{"focused":"C","active_tab":"w:t1","tabs":{"w:t1":{"focused":"C"},"w:t2":{"focused":"D"}}}\n' > "$model"

# --- Fake herdr CLI: serves `pane layout`, `pane process-info`, `pane focus`
# (walk fallback), `tab list`, and `tab focus` (socket-absent fallback).
cat > "$fake_herdr" <<'PY'
#!/usr/bin/env python3
import sys, json, os, pathlib
STATE = pathlib.Path(os.environ["FAKE_HERDR_STATE"])
def load():
    return json.loads(STATE.read_text() or "{}")
def save(m):
    STATE.write_text(json.dumps(m))
PANES_T1 = {
    "A": {"x":0,  "y":0,  "width":100, "height":50},
    "B": {"x":100,"y":0,  "width":100, "height":25},
    "C": {"x":100,"y":25, "width":100, "height":25},
}
PANES_T2 = {
    "D": {"x":0,  "y":0,  "width":200, "height":50},
}
TABS = {"w:t1": PANES_T1, "w:t2": PANES_T2}
def panes_for(tab):
    return TABS.get(tab, PANES_T1)
def layout_json():
    m = load()
    tab = m.get("active_tab","w:t1")
    f = m.get("focused","A")
    panes = panes_for(tab)
    return json.dumps({"result":{"layout":{
        "focused_pane_id": f, "tab_id": tab, "workspace_id": "w", "zoomed": False,
        "panes":[{"pane_id":p,"rect":r,"focused":p==f} for p,r in panes.items()]}}})
def process_info_json():
    return json.dumps({"result":{"process_info":{"foreground_processes":[{"name":"bash"}]}}})
def focus(direction, pane):
    m = load(); tab = m.get("active_tab","w:t1")
    panes = panes_for(tab)
    f = pane if pane else m.get("focused","A")
    x,y,w,h = panes[f]["x"],panes[f]["y"],panes[f]["width"],panes[f]["height"]
    cands=[]
    for pid,r in panes.items():
        if pid==f: continue
        rx,ry,rw,rh = r["x"],r["y"],r["width"],r["height"]
        if direction=="left"  and rx+rw<=x:           bey=True
        elif direction=="right" and rx>=x+w:          bey=True
        elif direction=="up"   and ry+rh<=y:          bey=True
        elif direction=="down" and ry>=y+h:           bey=True
        else: bey=False
        if not bey: continue
        if direction in ("left","right"): ov=(ry<y+h)and(y<ry+rh)
        else: ov=(rx<x+w)and(x<rx+rw)
        if ov: cands.append(pid)
    if not cands:
        print(f"[walk] focus {direction} from {f}: NO NEIGHBOR (no-op)", file=sys.stderr); return
    new=cands[0]; m["focused"]=new; m["tabs"][tab]["focused"]=new; save(m)
    print(f"[walk] focus {direction} from {f} -> {new}", file=sys.stderr)
def tab_list_json():
    m = load(); active = m.get("active_tab","w:t1")
    return json.dumps({"result":{"tabs":[
        {"tab_id":"w:t1","workspace_id":"w","number":1,"focused":active=="w:t1","label":"1","pane_count":3},
        {"tab_id":"w:t2","workspace_id":"w","number":2,"focused":active=="w:t2","label":"2","pane_count":1},
    ]}})
def tab_focus(tab_id):
    m = load(); prev = m.get("active_tab","?")
    if tab_id not in m.get("tabs",{}):
        print(f"[cli] tab.focus unknown {tab_id}", file=sys.stderr); return
    m["active_tab"] = tab_id
    m["focused"] = m["tabs"][tab_id].get("focused","A")
    save(m)
    print(f"[walk] tab.focus {tab_id}  (was {prev}) -> focused {m['focused']}", file=sys.stderr)
args=sys.argv[1:]
if args[:2]==["pane","layout"]: print(layout_json())
elif args[:2]==["pane","process-info"]: print(process_info_json())
elif args[:2]==["pane","focus"]:
    d=None;p=None;i=2
    while i<len(args):
        if args[i]=="--direction": d=args[i+1];i+=2
        elif args[i]=="--pane": p=args[i+1];i+=2
        elif args[i]=="--current": p=load().get("focused","A");i+=1
        else: i+=1
    focus(d,p)
elif args[:2]==["tab","list"]: print(tab_list_json())
elif args[:2]==["tab","focus"]: tab_focus(args[2] if len(args)>2 else "")
elif args[:2]==["pane","send-keys"]:
    print(f"[walk] send-keys {args[2:]} (Vim path)", file=sys.stderr)
else: print(f"[cli] unhandled: {args}", file=sys.stderr)
PY
chmod +x "$fake_herdr"

# --- Fake socket server: handles `pane.focus {pane_id}`, `tab.list
# {workspace_id}`, and `tab.focus {tab_id}` — the primary paths.
cat > "$work/sock_server.py" <<'PY'
#!/usr/bin/env python3
import sys, json, os, socket, pathlib
sock_path = sys.argv[1]
model_path = pathlib.Path(os.environ["FAKE_HERDR_STATE"])
PANES_T1 = {"A":{"x":0,"y":0,"width":100,"height":50},
            "B":{"x":100,"y":0,"width":100,"height":25},
            "C":{"x":100,"y":25,"width":100,"height":25}}
PANES_T2 = {"D":{"x":0,"y":0,"width":200,"height":50}}
TABS = {"w:t1": PANES_T1, "w:t2": PANES_T2}
def load(): return json.loads(model_path.read_text())
def save(m): model_path.write_text(json.dumps(m))
if os.path.exists(sock_path): os.unlink(sock_path)
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(sock_path); srv.listen(8)
while True:
    try: conn, _ = srv.accept()
    except Exception: break
    try:
        data = b""
        while b"\n" not in data:
            chunk = conn.recv(4096)
            if not chunk: break
            data += chunk
        req = json.loads(data.decode())
        method = req.get("method","")
        params = req.get("params",{})
        if method == "pane.focus":
            pid = params.get("pane_id","")
            m = load(); tab = m.get("active_tab","w:t1")
            prev = m.get("focused","?")
            m["focused"] = pid; m["tabs"][tab]["focused"] = pid; save(m)
            print(f"[socket] pane.focus {pid}  (was {prev})", file=sys.stderr)
            resp = {"id": req.get("id"), "result": {"type":"pane_info","pane":{"pane_id":pid,"focused":True}}}
        elif method == "tab.list":
            m = load(); active = m.get("active_tab","w:t1")
            print(f"[socket] tab.list (active={active})", file=sys.stderr)
            resp = {"id": req.get("id"), "result": {"tabs":[
                {"tab_id":"w:t1","workspace_id":"w","number":1,"focused":active=="w:t1","label":"1","pane_count":3},
                {"tab_id":"w:t2","workspace_id":"w","number":2,"focused":active=="w:t2","label":"2","pane_count":1},
            ]}}
        elif method == "tab.focus":
            tid = params.get("tab_id","")
            m = load(); prev = m.get("active_tab","?")
            m["active_tab"] = tid; m["focused"] = m["tabs"][tid].get("focused","A"); save(m)
            print(f"[socket] tab.focus {tid}  (was {prev}) -> focused {m['focused']}", file=sys.stderr)
            resp = {"id": req.get("id"), "result": {"type":"tab_info","tab":{"tab_id":tid,"focused":True}}}
        else:
            print(f"[socket] unknown method {method}", file=sys.stderr)
            resp = {"id": req.get("id"), "error": {"code":-32601,"message":"method not found"}}
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
for _ in $(seq 1 50); do [ -S "$fake_sock" ] && break; sleep 0.02; done

nav_bin="${NAV_BIN:-$root/target/release/navigate}"

run() {
  echo
  echo ">>> $(basename "$nav_bin") $1   (focused before: $(jq -r .focused "$model"), tab: $(jq -r .active_tab "$model"))"
  export HERDR_PANE_ID="$(jq -r .focused "$model")"
  if [[ "$nav_bin" == *.sh || "$nav_bin" == *.legacy ]]; then
    bash "$nav_bin" "$1"
  else
    "$nav_bin" "$1"
  fi
  echo "    focused after : $(jq -r .focused "$model"), tab: $(jq -r .active_tab "$model")"
  echo "    state file    : $(cat "$state_dir/w_t1.json" 2>/dev/null || echo '(none)')"
}

echo "=== Scenario 1: C -> left -> A -> right (smart focus, should return to C, not B) ==="
export HERDR_NAV_CROSS_TABS=0
printf '{"focused":"C","active_tab":"w:t1","tabs":{"w:t1":{"focused":"C"},"w:t2":{"focused":"D"}}}\n' > "$model"
rm -f "$state_dir/w_t1.json"
run left     # C -> A   (seeds preferred_y from C's row)
run right    # A -> ?   (uses stored preferred_y to pick C over B)
run left     # C -> A
run right    # A -> C   again

echo
echo "=== Scenario 2: from B, move down (should stay in right column, land on C) ==="
printf '{"focused":"B","active_tab":"w:t1","tabs":{"w:t1":{"focused":"B"},"w:t2":{"focused":"D"}}}\n' > "$model"
rm -f "$state_dir/w_t1.json"
run down     # B -> C   (seeds preferred_x from B's column)
run up       # C -> B
run down     # B -> C

echo
echo "=== Scenario 3: cross-tab (HERDR_NAV_CROSS_TABS=1) ===================="
export HERDR_NAV_CROSS_TABS=1
# Start on C (rightmost pane of tab 1). Moving right hits the edge -> next tab.
printf '{"focused":"C","active_tab":"w:t1","tabs":{"w:t1":{"focused":"C"},"w:t2":{"focused":"D"}}}\n' > "$model"
rm -f "$state_dir/w_t1.json"
echo "--- C -> right (edge) => should switch to tab 2 (D) ---"
run right    # C at right edge -> cross-tab -> w:t2 (D)
echo "--- D -> left (edge) => should switch back to tab 1 (C, last-focused) ---"
run left     # D at left edge -> cross-tab -> w:t1 (C restored)
echo "--- C -> right -> right again: second right from D (only pane) stays on tab 2 ---"
run right    # C -> tab 2 (D)
run right    # D at right edge, no next tab -> no-op (stays on tab 2, D)

echo
echo "=== Scenario 4: cross-tab DISABLED at edge => no-op (existing behavior) ==="
export HERDR_NAV_CROSS_TABS=0
printf '{"focused":"C","active_tab":"w:t1","tabs":{"w:t1":{"focused":"C"},"w:t2":{"focused":"D"}}}\n' > "$model"
run right    # C at right edge, cross-tab off -> [walk] NO NEIGHBOR, stays on C/tab 1

echo
echo "=== Cleanup ==="
kill "$sock_pid" 2>/dev/null || true
rm -rf "$work"
echo "done. (temp dir $work removed)"
