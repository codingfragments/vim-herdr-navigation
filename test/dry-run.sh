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
# Active tab of the active workspace, and focused pane — the new multi-
# workspace model nests active_tab under .workspaces[.active_workspace].
at() { jq -r '.workspaces[.active_workspace].active_tab' "$model"; }
fp() { jq -r .focused "$model"; }

# Fresh model helpers: active on w1:t1 (m1) or w2:t1 (m2) with the given
# focused pane. The other tabs keep a default last-focused pane.
m1() {  # arg: focused pane on w1:t1
  printf '{"active_workspace":"w1","focused":"%s","workspaces":{"w1":{"active_tab":"w1:t1","tabs":{"w1:t1":{"focused":"%s"},"w1:t2":{"focused":"D"}}},"w2":{"active_tab":"w2:t1","tabs":{"w2:t1":{"focused":"E"}}}}}\n' "$1" "$1" > "$model"
}
m2() {  # arg: focused pane on w2:t1
  printf '{"active_workspace":"w2","focused":"%s","workspaces":{"w1":{"active_tab":"w1:t1","tabs":{"w1:t1":{"focused":"A"},"w1:t2":{"focused":"D"}}},"w2":{"active_tab":"w2:t1","tabs":{"w2:t1":{"focused":"%s"}}}}}\n' "$1" "$1" > "$model"
}


# --- Shared model file read/written by both the CLI mock and the socket server:
#   {"active_workspace":"w1","focused":"C",
#    "workspaces":{"w1":{"active_tab":"w1:t1","tabs":{"w1:t1":{"focused":"C"},"w1:t2":{"focused":"D"}}},
#                   "w2":{"active_tab":"w2:t1","tabs":{"w2:t1":{"focused":"E"}}}}}
# `focused` (top level) mirrors the active workspace/tab's focused pane so the
# harness helper can read it with a single jq. Two workspaces let the vertical
# (cross-workspace) scenarios exercise cycling + edge-row landing.
# Layouts:
#   w1:t1  A (left, full height) | B (top-right) | C (bottom-right)
#   w1:t2  D (full width, single pane)
#   w2:t1  E (left, full height) | F (top-right) | G (bottom-right)
m1 C   # initial: w1 active, w1:t1 focused on C

# --- Fake herdr CLI: serves `pane layout`, `pane process-info`, `pane focus`
# (walk fallback), `tab list`, `tab focus`, `workspace list`, `workspace focus`,
# and `api snapshot` (socket-absent fallback).
cat > "$fake_herdr" <<'PY'
#!/usr/bin/env python3
import sys, json, os, pathlib
STATE = pathlib.Path(os.environ["FAKE_HERDR_STATE"])
def load():
    return json.loads(STATE.read_text() or "{}")
def save(m):
    STATE.write_text(json.dumps(m))

# Two workspaces, each with its own tabs/panes. w1 reuses the classic
# A|B/C + D layout; w2 mirrors it (E|F/G) so edge-row landing + column
# preservation can be exercised across a vertical crossing.
PANES = {
    "w1:t1": {"A":{"x":0,"y":0,"width":100,"height":50},
              "B":{"x":100,"y":0,"width":100,"height":25},
              "C":{"x":100,"y":25,"width":100,"height":25}},
    "w1:t2": {"D":{"x":0,"y":0,"width":200,"height":50}},
    "w2:t1": {"E":{"x":0,"y":0,"width":100,"height":50},
              "F":{"x":100,"y":0,"width":100,"height":25},
              "G":{"x":100,"y":25,"width":100,"height":25}},
}
# workspace_id -> (number, ordered tab_ids)
WORKSPACES = {"w1": (1, ["w1:t1","w1:t2"]), "w2": (2, ["w2:t1"])}
TAB_WS = {tid: ws for ws,(_,ts) in WORKSPACES.items() for tid in ts}

def active_ws(m): return m.get("active_workspace","w1")
def active_tab(m):
    ws = active_ws(m)
    return m.get("workspaces",{}).get(ws,{}).get("active_tab","w1:t1")
def focused_pane(m):
    tab = active_tab(m)
    return m.get("workspaces",{}).get(active_ws(m),{}).get("tabs",{}).get(tab,{}).get("focused","A")
def panes_for(tab): return PANES.get(tab, PANES["w1:t1"])

def layout_json():
    m = load()
    tab = active_tab(m); f = focused_pane(m)
    panes = panes_for(tab)
    return json.dumps({"result":{"layout":{
        "focused_pane_id": f, "tab_id": tab, "workspace_id": active_ws(m), "zoomed": False,
        "panes":[{"pane_id":p,"rect":r,"focused":p==f} for p,r in panes.items()]}}})

def process_info_json():
    return json.dumps({"result":{"process_info":{"foreground_processes":[{"name":"bash"}]}}})

def focus(direction, pane):
    m = load(); tab = active_tab(m)
    panes = panes_for(tab)
    f = pane if pane else focused_pane(m)
    x,y,w,h = panes[f]["x"],panes[f]["y"],panes[f]["width"],panes[f]["height"]
    cands=[]
    for pid,r in panes.items():
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
    new=cands[0]
    m["workspaces"][active_ws(m)]["tabs"][tab]["focused"]=new
    m["focused"]=new; save(m)
    print(f"[walk] focus {direction} from {f} -> {new}", file=sys.stderr)

def tab_list_json():
    m = load(); ws = active_ws(m); at = active_tab(m)
    tabs = []
    for tid in WORKSPACES[ws][1]:
        tabs.append({"tab_id":tid,"workspace_id":ws,"number":WORKSPACES[ws][1].index(tid)+1,
                      "focused":at==tid,"label":str(WORKSPACES[ws][1].index(tid)+1),
                      "pane_count":len(PANES[tid])})
    return json.dumps({"result":{"tabs":tabs}})

def tab_focus(tab_id):
    m = load(); ws = active_ws(m); prev = active_tab(m)
    if tab_id not in WORKSPACES.get(ws,(0,[]))[1]:
        print(f"[cli] tab.focus unknown {tab_id} in ws {ws}", file=sys.stderr); return
    m["workspaces"][ws]["active_tab"]=tab_id
    m["focused"]=m["workspaces"][ws]["tabs"][tab_id].get("focused","A"); save(m)
    print(f"[walk] tab.focus {tab_id}  (was {prev}) -> focused {m['focused']}", file=sys.stderr)

def workspace_focus(ws_id):
    m = load(); prev = active_ws(m)
    if ws_id not in WORKSPACES:
        print(f"[cli] workspace.focus unknown {ws_id}", file=sys.stderr); return
    m["active_workspace"]=ws_id
    at = m["workspaces"][ws_id].get("active_tab", WORKSPACES[ws_id][1][0])
    m["focused"]=m["workspaces"][ws_id]["tabs"].get(at,{}).get("focused","A"); save(m)
    print(f"[walk] workspace.focus {ws_id}  (was {prev}) -> tab {at} focused {m['focused']}", file=sys.stderr)

def workspace_list_json():
    m = load(); aw = active_ws(m)
    ws_list = []
    for ws_id,(num,ts) in WORKSPACES.items():
        at = m.get("workspaces",{}).get(ws_id,{}).get("active_tab",ts[0])
        ws_list.append({"workspace_id":ws_id,"number":num,"focused":aw==ws_id,
                        "label":ws_id,"active_tab_id":at,"pane_count":sum(len(PANES[t]) for t in ts),
                        "tab_count":len(ts)})
    return json.dumps({"result":{"workspaces":ws_list}})

def snapshot_json():
    m = load()
    layouts = []
    for ws_id,(num,ts) in WORKSPACES.items():
        for tid in ts:
            f = m.get("workspaces",{}).get(ws_id,{}).get("tabs",{}).get(tid,{}).get("focused","A")
            layouts.append({"tab_id":tid,"workspace_id":ws_id,"zoomed":False,"focused_pane_id":f,
                "panes":[{"pane_id":p,"rect":r,"focused":p==f} for p,r in PANES[tid].items()]})
    ws_list = []
    for ws_id,(num,ts) in WORKSPACES.items():
        at = m.get("workspaces",{}).get(ws_id,{}).get("active_tab",ts[0])
        ws_list.append({"workspace_id":ws_id,"number":num,"focused":active_ws(m)==ws_id,
                        "label":ws_id,"active_tab_id":at,"pane_count":sum(len(PANES[t]) for t in ts),
                        "tab_count":len(ts)})
    return json.dumps({"result":{"snapshot":{"layouts":layouts,"workspaces":ws_list}}})

args=sys.argv[1:]
if args[:2]==["pane","layout"]: print(layout_json())
elif args[:2]==["pane","process-info"]: print(process_info_json())
elif args[:2]==["pane","focus"]:
    d=None;p=None;i=2
    while i<len(args):
        if args[i]=="--direction": d=args[i+1];i+=2
        elif args[i]=="--pane": p=args[i+1];i+=2
        elif args[i]=="--current": p=focused_pane(load());i+=1
        else: i+=1
    focus(d,p)
elif args[:2]==["tab","list"]: print(tab_list_json())
elif args[:2]==["tab","focus"]: tab_focus(args[2] if len(args)>2 else "")
elif args[:2]==["workspace","list"]: print(workspace_list_json())
elif args[:2]==["workspace","focus"]: workspace_focus(args[2] if len(args)>2 else "")
elif args[:2]==["pane","send-keys"]:
    print(f"[walk] send-keys {args[2:]} (Vim path)", file=sys.stderr)
elif args[:2]==["api","snapshot"]: print(snapshot_json())
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
PANES = {
    "w1:t1": {"A":{"x":0,"y":0,"width":100,"height":50},
              "B":{"x":100,"y":0,"width":100,"height":25},
              "C":{"x":100,"y":25,"width":100,"height":25}},
    "w1:t2": {"D":{"x":0,"y":0,"width":200,"height":50}},
    "w2:t1": {"E":{"x":0,"y":0,"width":100,"height":50},
              "F":{"x":100,"y":0,"width":100,"height":25},
              "G":{"x":100,"y":25,"width":100,"height":25}},
}
WORKSPACES = {"w1": (1, ["w1:t1","w1:t2"]), "w2": (2, ["w2:t1"])}
def load(): return json.loads(model_path.read_text())
def save(m): model_path.write_text(json.dumps(m))
def active_ws(m): return m.get("active_workspace","w1")
def active_tab(m):
    return m.get("workspaces",{}).get(active_ws(m),{}).get("active_tab","w1:t1")
def focused_pane(m):
    tab = active_tab(m)
    return m.get("workspaces",{}).get(active_ws(m),{}).get("tabs",{}).get(tab,{}).get("focused","A")
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
            m = load(); ws = active_ws(m); tab = active_tab(m)
            prev = m.get("focused","?")
            m["focused"]=pid; m["workspaces"][ws]["tabs"][tab]["focused"]=pid; save(m)
            print(f"[socket] pane.focus {pid}  (was {prev})", file=sys.stderr)
            resp = {"id": req.get("id"), "result": {"type":"pane_info","pane":{"pane_id":pid,"focused":True}}}
        elif method == "tab.list":
            m = load(); ws = active_ws(m); at = active_tab(m)
            print(f"[socket] tab.list (ws={ws}, active={at})", file=sys.stderr)
            tabs = [{"tab_id":tid,"workspace_id":ws,"number":WORKSPACES[ws][1].index(tid)+1,
                     "focused":at==tid,"label":str(WORKSPACES[ws][1].index(tid)+1),
                     "pane_count":len(PANES[tid])} for tid in WORKSPACES[ws][1]]
            resp = {"id": req.get("id"), "result": {"tabs":tabs}}
        elif method == "tab.focus":
            tid = params.get("tab_id","")
            m = load(); ws = active_ws(m); prev = active_tab(m)
            m["workspaces"][ws]["active_tab"]=tid
            m["focused"]=m["workspaces"][ws]["tabs"][tid].get("focused","A"); save(m)
            print(f"[socket] tab.focus {tid}  (was {prev}) -> focused {m['focused']}", file=sys.stderr)
            resp = {"id": req.get("id"), "result": {"type":"tab_info","tab":{"tab_id":tid,"focused":True}}}
        elif method == "workspace.focus":
            wid = params.get("workspace_id","")
            m = load(); prev = active_ws(m)
            m["active_workspace"]=wid
            at = m["workspaces"][wid].get("active_tab", WORKSPACES[wid][1][0])
            m["focused"]=m["workspaces"][wid]["tabs"].get(at,{}).get("focused","A"); save(m)
            print(f"[socket] workspace.focus {wid}  (was {prev}) -> tab {at} focused {m['focused']}", file=sys.stderr)
            resp = {"id": req.get("id"), "result": {"type":"workspace_info","workspace":{"workspace_id":wid,"focused":True}}}
        elif method == "session.snapshot":
            m = load()
            print(f"[socket] session.snapshot (ws={active_ws(m)}, tab={active_tab(m)})", file=sys.stderr)
            layouts = []
            for ws_id,(num,ts) in WORKSPACES.items():
                for tid in ts:
                    f = m.get("workspaces",{}).get(ws_id,{}).get("tabs",{}).get(tid,{}).get("focused","A")
                    layouts.append({"tab_id":tid,"workspace_id":ws_id,"zoomed":False,"focused_pane_id":f,
                        "panes":[{"pane_id":p,"rect":r,"focused":p==f} for p,r in PANES[tid].items()]})
            ws_list = [{"workspace_id":ws_id,"number":num,"focused":active_ws(m)==ws_id,"label":ws_id,
                        "active_tab_id":m.get("workspaces",{}).get(ws_id,{}).get("active_tab",ts[0]),
                        "pane_count":sum(len(PANES[t]) for t in ts),"tab_count":len(ts)}
                       for ws_id,(num,ts) in WORKSPACES.items()]
            resp = {"id": req.get("id"), "result": {"snapshot": {"layouts":layouts,"workspaces":ws_list}}}
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
# Ensure the background socket server is ALWAYS reaped — even if a scenario
# fails under `set -e` (or the user hits Ctrl-C). Without this, an early exit
# orphaned the server, which blocks forever on accept() and holds the
# terminal's stdout/stderr pipe open, making the script appear to hang.
cleanup() {
  [[ -n "${sock_pid:-}" ]] && kill "$sock_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT
for _ in $(seq 1 50); do [ -S "$fake_sock" ] && break; sleep 0.02; done

nav_bin="${NAV_BIN:-$root/target/release/navigate}"

# Print every per-tab state file (cross-tab now writes the *destination* tab's
# state, so we want to see both w_t1 and w_t2).
show_states() {
  local first=1
  for f in "$state_dir"/*.json; do
    [[ -f "$f" ]] || continue
    if [[ $first -eq 1 ]]; then first=0; else echo; fi
    printf '    %-12s : %s' "$(basename "$f")" "$(cat "$f")"
  done
  if [[ $first -eq 1 ]]; then echo '    state files  : (none)'; fi
}

run() {
  echo
  echo ">>> $(basename "$nav_bin") $1   (focused before: $(fp), ws: $(jq -r .active_workspace "$model"), tab: $(at))"
  export HERDR_PANE_ID="$(fp)"
  if [[ "$nav_bin" == *.sh || "$nav_bin" == *.legacy ]]; then
    bash "$nav_bin" "$1"
  else
    "$nav_bin" "$1"
  fi
  echo "    focused after : $(fp), ws: $(jq -r .active_workspace "$model"), tab: $(at)"
  show_states; echo
}

# Like run(), but passes --cross-tabs (CLI flag path) and force-unsets the env
# var so we verify the flag overrides independently of HERDR_NAV_CROSS_TABS.
run_cross() {
  echo
  echo ">>> $(basename "$nav_bin") --cross-tabs $1   (focused before: $(fp), ws: $(jq -r .active_workspace "$model"), tab: $(at))"
  export HERDR_PANE_ID="$(fp)"
  if [[ "$nav_bin" == *.sh || "$nav_bin" == *.legacy ]]; then
    echo "    (legacy shell script ignores --cross-tabs; skipping)"
  else
    env -u HERDR_NAV_CROSS_TABS "$nav_bin" --cross-tabs "$1"
  fi
  echo "    focused after : $(fp), ws: $(jq -r .active_workspace "$model"), tab: $(at)"
  show_states; echo
}

echo "=== Scenario 1: C -> left -> A -> right (smart focus, should return to C, not B) ==="
export HERDR_NAV_CROSS_TABS=0
m1 C
rm -f "$state_dir"/*.json
run left     # C -> A   (seeds preferred_y from C's row)
run right    # A -> ?   (uses stored preferred_y to pick C over B)
run left     # C -> A
run right    # A -> C   again

echo
echo "=== Scenario 2: from B, move down (should stay in right column, land on C) ==="
m1 B
rm -f "$state_dir"/*.json
run down     # B -> C   (seeds preferred_x from B's column)
run up       # C -> B
run down     # B -> C

echo
# Layout reminder for the cross-tab scenarios:
#   Tab 1 (w:t1):  A (left, full height) | B (top-right) | C (bottom-right)
#   Tab 2 (w:t2):  D (full width, single pane)
# Edge-column landing: moving right lands on the destination's LEFTMOST column;
# moving left lands on the RIGHTMOST column, at the row nearest preferred_y
# (seeded from the source pane's center-y). The tab index WRAPS, so right on
# the last tab cycles to the first, and left on the first cycles to the last.
echo "=== Scenario 3: cross-tab with cycling + edge-column landing (HERDR_NAV_CROSS_TABS=1) ==="
export HERDR_NAV_CROSS_TABS=1
m1 C
rm -f "$state_dir"/*.json
echo "--- C -> right (right edge of tab 1) => switch to tab 2, land on leftmost col (D) ---"
run right    # C at right edge -> cross-tab -> w:t2, leftmost col {D} -> D
echo "--- D -> left (left edge of tab 2) => switch to tab 1, land on rightmost col (B, nearest row) ---"
run left     # D at left edge -> cross-tab -> w:t1, rightmost col {B,C}; seed cy=25 -> tie -> B
echo "--- B -> down (within tab 1, smart-focus) => C ---"
run down     # B -> C (within tab 1; preferred_x seeded from B's column)
echo "--- C -> right (right edge) => switch to tab 2, land on D ---"
run right    # C at right edge -> cross-tab -> w:t2 (D)
echo "--- D -> right (right edge, LAST tab) => WRAP to tab 1, land on leftmost col (A) ---"
run right    # D at right edge, last tab -> wrap -> w:t1, leftmost col {A} -> A
echo "--- A -> left (left edge, FIRST tab) => WRAP to tab 2, land on rightmost col (D) ---"
run left     # A at left edge, first tab -> wrap -> w:t2, rightmost col {D} -> D

echo
echo "=== Scenario 4: cross-tab DISABLED at edge => no-op (existing behavior) ==="
export HERDR_NAV_CROSS_TABS=0
m1 C
run right    # C at right edge, cross-tab off -> [walk] NO NEIGHBOR, stays on C/tab 1

echo
echo "=== Scenario 5: --cross-tabs CLI flag (env var unset) ============== "
# Verify the flag enables cross-tab (with cycling + edge-column landing) even
# with HERDR_NAV_CROSS_TABS unset.
stdbuf -oL env -u HERDR_NAV_CROSS_TABS true  # sanity: env -u works on this host
m1 C
rm -f "$state_dir"/*.json
echo "--- C -> right --cross-tabs (edge) => switch to tab 2, land on leftmost col (D) ---"
run_cross right    # C at right edge, flag set -> cross-tab -> w:t2, leftmost col {D} -> D
echo "--- D -> right --cross-tabs (edge, LAST tab) => WRAP to tab 1, land on leftmost col (A) ---"
run_cross right    # D at right edge, last tab, flag set -> wrap -> w:t1, leftmost col {A} -> A
echo "--- A -> left --cross-tabs (edge, FIRST tab) => WRAP to tab 2, land on rightmost col (D) ---"
run_cross left     # A at left edge, first tab, flag set -> wrap -> w:t2, rightmost col {D} -> D

echo
echo "=== Scenario 6: Vim edge-cross via --no-forward (no loop, smart-focus+cross-tab) ==="
# Simulates the editor side hitting a Vim split edge: nvim.lua invokes the
# `*-edge` action, which runs `navigate --no-forward --cross-tabs <dir>`.
# --no-forward MUST skip Vim detection (no send-keys / no loop) and go straight
# to the herdr focus path: smart-focus + cross-tab + state-persist.
# We run it directly (the edge action is just this command) and assert no
# `[walk] send-keys` line appears (that would mean it forwarded into Vim).
m1 C
rm -f "$state_dir"/*.json
echo "--- C -> right --no-forward --cross-tabs (Vim edge) => tab 2 (D), NO send-keys ---"
env -u HERDR_NAV_CROSS_TABS "$nav_bin" --no-forward --cross-tabs right 2>&1 | tee /tmp/vhnav_edge.log
if grep -q 'send-keys' /tmp/vhnav_edge.log; then
  echo "FAIL: --no-forward still forwarded the chord (loop risk)!"; exit 1
fi
echo "    focused after : $(fp), ws: $(jq -r .active_workspace "$model"), tab: $(at)"
echo "    (edge-cross writes the DESTINATION tab's state, so the preferred coord persists)"
show_states; echo
# Note: the edge-cross now lands on the destination's edge column and writes
# that tab's state (preferred_x/preferred_y), mirroring an in-tab move.

echo
# Layout reminder for the cross-workspace scenarios:
#   w1:t1  A (left, full height) | B (top-right) | C (bottom-right)
#   w1:t2  D (full width, single pane)
#   w2:t1  E (left, full height) | F (top-right) | G (bottom-right)
# Edge-row landing: moving down lands on the destination active tab's TOPMOST
# row; moving up lands on the BOTTOMMOST row, at the column nearest preferred_x
# (seeded from the source pane's center-x). The workspace index WRAPS, so down
# on the last workspace cycles to the first, and up on the first cycles to the
# last. Gated by --cross workspaces|both (or HERDR_NAV_CROSS=workspaces|both).
echo "=== Scenario 7: cross-workspace with cycling + edge-row landing (--cross both) ==="
echo "--- C -> down (bottom edge of w1:t1) => switch to w2, topmost row, col nearest C's cx=150 => F ---"
m1 C; rm -f "$state_dir"/*.json
env -u HERDR_NAV_CROSS_TABS "$nav_bin" --cross both down
echo "    focused after : $(fp), ws: $(jq -r .active_workspace "$model"), tab: $(at)"
echo "--- F -> up (top edge of w2:t1) => switch to w1, bottommost row, col nearest F's cx=150 => C ---"
m2 F; rm -f "$state_dir"/*.json
env -u HERDR_NAV_CROSS_TABS "$nav_bin" --cross both up
echo "    focused after : $(fp), ws: $(jq -r .active_workspace "$model"), tab: $(at)"
echo "--- A -> down (A spans full height => at bottom edge) => switch to w2, topmost row, col nearest A's cx=50 => E ---"
m1 A; rm -f "$state_dir"/*.json
env -u HERDR_NAV_CROSS_TABS "$nav_bin" --cross both down
echo "    focused after : $(fp), ws: $(jq -r .active_workspace "$model"), tab: $(at)"
echo "--- E -> down (E spans full height, LAST workspace) => WRAP to w1, topmost row, col nearest E's cx=50 => A ---"
m2 E; rm -f "$state_dir"/*.json
env -u HERDR_NAV_CROSS_TABS "$nav_bin" --cross both down
echo "    focused after : $(fp), ws: $(jq -r .active_workspace "$model"), tab: $(at)"
echo "--- A -> up (A spans full height, FIRST workspace) => WRAP to w2, bottommost row, col nearest A's cx=50 => E ---"
m1 A; rm -f "$state_dir"/*.json
env -u HERDR_NAV_CROSS_TABS "$nav_bin" --cross both up
echo "    focused after : $(fp), ws: $(jq -r .active_workspace "$model"), tab: $(at)"
show_states; echo

echo
echo "=== Scenario 8: --cross workspaces (vertical only; left/right no-op at edge) ==="
echo "--- C -> right --cross workspaces (horizontal move, scope=workspaces) => NO-OP (stays on C, w1:t1) ---"
m1 C; rm -f "$state_dir"/*.json
env -u HERDR_NAV_CROSS_TABS "$nav_bin" --cross workspaces right 2>&1 | tee /tmp/vhnav_ws_h.log
echo "    focused after : $(fp), ws: $(jq -r .active_workspace "$model"), tab: $(at)"
if grep -q 'workspace.focus\|tab.focus' /tmp/vhnav_ws_h.log; then
  echo "FAIL: --cross workspaces crossed on a horizontal move!"; exit 1
fi
echo "--- C -> down --cross workspaces (vertical move) => switch to w2, topmost row, col nearest C's cx=150 => F ---"
m1 C; rm -f "$state_dir"/*.json
env -u HERDR_NAV_CROSS_TABS "$nav_bin" --cross workspaces down
echo "    focused after : $(fp), ws: $(jq -r .active_workspace "$model"), tab: $(at)"
show_states; echo

echo
echo "=== Scenario 9: cross DISABLED at vertical edge => no-op (existing behavior) ==="
m1 C; rm -f "$state_dir"/*.json
env -u HERDR_NAV_CROSS_TABS "$nav_bin" down 2>&1 | tee /tmp/vhnav_nocross.log
echo "    focused after : $(fp), ws: $(jq -r .active_workspace "$model"), tab: $(at)"
if grep -q 'workspace.focus' /tmp/vhnav_nocross.log; then
  echo "FAIL: down crossed workspaces with no --cross flag!"; exit 1
fi
show_states; echo

echo
echo "=== Cleanup ==="
# Socket server + temp dir are reaped by the EXIT trap (set above). The trap
# runs on normal exit, `set -e` failures, and interrupts, so the server can
# never be orphaned. Reset the trap's rm so the final "done" message prints
# after a clean temp removal.
trap - EXIT
kill "$sock_pid" 2>/dev/null || true
rm -rf "$work"
echo "done. (temp dir $work removed)"
