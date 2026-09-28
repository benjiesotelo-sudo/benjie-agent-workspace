#!/usr/bin/env bash
# Behavior tests for Mission Control's naming step (bin/fm-mission-control.sh
# names over bin/fm_herdr_names.py): from fixture records and a stand-in Herdr
# that keeps its spaces and windows in JSON files, assert which spaces get
# which display name, which agent windows get which who and job display
# values, that nothing is ever renamed (the captain's own window names and
# firstmate's fm-, 2ndmate-, firstmate and └ names all stay) and nothing is
# moved, closed or created, that the one-off command run from the first mate's
# own window still finds the first mate there, that a second pass changes
# nothing, that older firstmate/<job> and 2ndmate-<id>/<job> helper spaces
# read like └ ones, that a restart's lost display values come back, a refused
# change, and the running screen's Keeper putting lost values back on
# its own while leaving out its own window.
# Fixtures are the Bridge's, in tests/assets/bridge/.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MC="$ROOT/bin/fm-mission-control.sh"
FIX="$ROOT/tests/assets/bridge"
TMP_ROOT=$(fm_test_tmproot fm-mission-control-names)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

HOME_DIR="$TMP_ROOT/benjie-agent-workspace"
MATE="$TMP_ROOT/alpha-mate-home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
HX="$TMP_ROOT/herdr"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects/alpha" \
  "$MATE/data" "$MATE/state" "$TMP_ROOT/wt-alpha" "$TMP_ROOT/wt-beta" "$TMP_ROOT/wt-mate" "$HX"
HOME_DIR=$(cd "$HOME_DIR" && pwd)
MATE=$(cd "$MATE" && pwd)
for record in projects backlog done-archive captain learnings; do
  cp "$FIX/$record.fixture" "$HOME_DIR/data/$record.md"
done
sed "s|@MATE_HOME@|$MATE|" "$FIX/secondmates.fixture" > "$HOME_DIR/data/secondmates.md"
cp "$FIX/mate-backlog.fixture" "$MATE/data/backlog.md"
printf '{"first_mate_name": "Denver", "names": {"alpha": "Alpha"}}\n' > "$HOME_DIR/config/mission-control.json"

meta() {  # <home> <id> <worktree> <project>
  printf 'window=fx:%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=claude\nkind=ship\nmode=direct-PR\nyolo=off\n' \
    "$2" "$2" "$3" "$4" > "$1/state/$2.meta"
}
meta "$HOME_DIR" a1 "$TMP_ROOT/wt-alpha" "$HOME_DIR/projects/alpha"
meta "$HOME_DIR" q1 "$TMP_ROOT/wt-beta" "$HOME_DIR/projects/beta"
meta "$MATE" m2 "$TMP_ROOT/wt-mate" "$MATE/projects/elsewhere"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/tmux"
chmod +x "$FAKEBIN/tmux"

# The stand-in Herdr: lists come from $HX/*.json, every other call is logged
# to $HX/calls.log, and the two display-value calls update the JSON as Herdr
# would; any other call fails.
# $HX/refuse makes every change fail.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-} ${2:-}" in
  "workspace list") cat "$HX/spaces.json"; exit 0 ;;
  "pane list") cat "$HX/windows.json"; exit 0 ;;
  "agent list") cat "$HX/agents.json"; exit 0 ;;
esac
printf '%s\n' "$*" >> "$HX/calls.log"
[ -e "$HX/refuse" ] && exit 1
token() { while [ $# -gt 0 ]; do [ "$1" = --token ] && { printf '%s' "$2"; return; }; shift; done; }
case "${1:-} ${2:-}" in
  "workspace report-metadata")
    t=$(token "$@")
    jq --arg id "$3" --arg k "${t%%=*}" --arg v "${t#*=}" \
      '(.result.workspaces[] | select(.workspace_id == $id)).tokens[$k] = $v' "$HX/spaces.json" > "$HX/s.tmp" \
      && mv "$HX/s.tmp" "$HX/spaces.json" ;;
  "pane report-metadata")
    t=$(token "$@")
    jq --arg id "$3" --arg k "${t%%=*}" --arg v "${t#*=}" \
      '(.result.panes[] | select(.pane_id == $id)).tokens[$k] = $v' "$HX/windows.json" > "$HX/w.tmp" \
      && mv "$HX/w.tmp" "$HX/windows.json" ;;
  *) exit 1 ;;
esac
echo '{"result":{}}'
SH
chmod +x "$FAKEBIN/herdr"
export HX

jq -n --arg home "$HOME_DIR" --arg mate "$MATE" --arg root "$TMP_ROOT" '
  {result: {type: "agent_list", agents: [
    {pane_id: "w1:p1", agent_status: "working", cwd: $home},
    {pane_id: "w1:p3", agent_status: "idle", cwd: ($home + "/projects/alpha"),
     terminal_title_stripped: "Sorting a local file"},
    {pane_id: "w2:p1", agent_status: "idle", cwd: $mate},
    {pane_id: "w2:p2", agent_status: "working", cwd: ($root + "/wt-alpha")},
    {pane_id: "w2:p3", agent_status: "working", cwd: ($root + "/wt-mate")},
    {pane_id: "w3:p1", agent_status: "working", cwd: ($root + "/wt-beta")},
    {pane_id: "w6:p1", agent_status: "idle", cwd: "/somewhere", terminal_title_stripped: "An old chat"}]}}' \
  > "$HX/agents.json"

space() {  # <id> <label> [name token]
  if [ -n "${3:-}" ]; then
    jq -n --arg id "$1" --arg l "$2" --arg n "$3" '{workspace_id: $id, label: $l, tokens: {name: $n}}'
  else
    jq -n --arg id "$1" --arg l "$2" '{workspace_id: $id, label: $l}'
  fi
}
window() {  # <pane> [label]
  jq -n --arg id "$1" --arg l "${2:-}" \
    '{pane_id: $id, workspace_id: ($id | split(":")[0]), tab_id: (($id | split(":")[0]) + ":t1")}
     + (if $l == "" then {} else {label: $l} end)'
}
fresh_herdr() {
  {
    space w1 benjie-agent-workspace
    space w2 2ndmate-alpha-mate
    space w3 "└ q1 · p:urXKPBo5LgWV2rrMCPavcQ"
    space w4 mission-control
    space w5 controls
    space w6 scratch scratch
    space w7 "└ gone-job · p:BBSs2qp1b2ZGaqvRB5eeXg"
    space w8 firstmate
    space w9 2ndmate-unknown-mate
  } | jq -s '{result: {type: "workspace_list", workspaces: .}}' > "$HX/spaces.json"
  {
    window w1:p1 temporary
    window w1:p2
    window w1:p3 fm-fin1209-quiz1
    window w2:p1
    window w2:p2
    window w2:p3 "└ m2"
    window w3:p1
    window w4:p1
    window w6:p1 2ndmate-left-over
  } | jq -s '{result: {type: "pane_list", panes: .}}' > "$HX/windows.json"
  : > "$HX/calls.log"
  rm -f "$HX/refuse"
}

names() {
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_BRIDGE_NOW=2026-09-20T10:00:00 FM_MC_HERDR="$FAKEBIN/herdr" \
    HERDR_SESSION=default HERDR_PANE_ID=w1:p1 "$MC" names
}
space_name() { jq -r --arg id "$1" '.result.workspaces[] | select(.workspace_id == $id) | .tokens.name // ""' "$HX/spaces.json"; }
window_name() { jq -r --arg id "$1" '.result.panes[] | select(.pane_id == $id) | .label // ""' "$HX/windows.json"; }
window_who() { jq -r --arg id "$1" '.result.panes[] | select(.pane_id == $id) | .tokens.who // ""' "$HX/windows.json"; }
window_job() { jq -r --arg id "$1" '.result.panes[] | select(.pane_id == $id) | .tokens.job // ""' "$HX/windows.json"; }

# --- the first pass -----------------------------------------------------------

fresh_herdr
OUT=$(names) || fail "names failed: $OUT"

for pair in "w1|Denver" "w2|Alpha" "w3|Denver's intern · Print the handouts" "w4|Mission Control" \
  "w5|controls" "w6|scratch" "w7|gone-job" "w8|Denver's interns" "w9|2ndmate-unknown-mate"; do
  id=${pair%%|*} want=${pair#*|}
  [ "$(space_name "$id")" = "$want" ] || fail "space $id should show '$want', shows '$(space_name "$id")'"
done
pass "every space shows its plain name: the first mate's, a mate's, a helper space's intern and job, Mission Control's, and a left-over controls space its own"

for triple in "w1:p1|Denver|first mate" "w2:p1|Alpha|second mate" "w2:p2|Alpha's intern|Build chapter four" \
  "w3:p1|Denver's intern|Print the handouts"; do
  IFS='|' read -r id who job <<<"$triple"
  [ "$(window_who "$id")" = "$who" ] || fail "window $id should show who '$who', shows '$(window_who "$id")'"
  [ "$(window_job "$id")" = "$job" ] || fail "window $id should show job '$job', shows '$(window_job "$id")'"
done
pass "every agent window shows who it is and its job, the first mate's own window included"

for pair in "w1:p1|temporary" "w1:p3|fm-fin1209-quiz1" "w2:p3|└ m2" "w6:p1|2ndmate-left-over" "w2:p1|"; do
  id=${pair%%|*} want=${pair#*|}
  [ "$(window_name "$id")" = "$want" ] || fail "window $id must keep its name '$want', is '$(window_name "$id")'"
done
[ "$(window_job w1:p3)" = "Sorting a local file" ] && [ -n "$(window_who w1:p3)" ] \
  || fail "a window firstmate named still shows who and job as display values"
[ -z "$(window_who w1:p2)" ] || fail "a window with no agent gets no display value"
pass "every window keeps its own name: the captain's and firstmate's names stay"

grep -Ev '^(workspace report-metadata w[0-9]+ --source mission-control --token name=|pane report-metadata w[0-9]+:p[0-9]+ --source mission-control --token (who|job)=)' \
  "$HX/calls.log" && fail "names made a call other than a display value"
grep -q 'w6 ' "$HX/calls.log" && fail "a space already showing its name was sent it again"
pass "names only sets display values: no rename, move, close, create or focus"

fresh_herdr
jq '(.result.workspaces[] | select(.workspace_id == "w1")).label = "firstmate"' "$HX/spaces.json" > "$HX/s.tmp" \
  && mv "$HX/s.tmp" "$HX/spaces.json"
OUT=$(names) || fail "names failed: $OUT"
[ "$(space_name w1)" = Denver ] || fail "a firstmate space holding the first mate's window should show 'Denver', shows '$(space_name w1)'"
[ "$(space_name w8)" = "Denver's interns" ] || fail "the other firstmate space should show \"Denver's interns\", shows '$(space_name w8)'"
pass "only the space holding the first mate's window reads the first mate's name"

fresh_herdr
jq '(.result.workspaces[] | select(.workspace_id == "w3")).label = "firstmate/q1 · p:urXKPBo5LgWV2rrMCPavcQ"
    | (.result.workspaces[] | select(.workspace_id == "w7")).label = "2ndmate-alpha-mate/gone-job · p:BBSs2qp1b2ZGaqvRB5eeXg"' \
  "$HX/spaces.json" > "$HX/s.tmp" && mv "$HX/s.tmp" "$HX/spaces.json"
OUT=$(names) || fail "names failed: $OUT"
[ "$(space_name w3)" = "Denver's intern · Print the handouts" ] \
  || fail "an older firstmate/<job> helper space should show its intern and job, shows '$(space_name w3)'"
[ "$(space_name w7)" = gone-job ] \
  || fail "an older 2ndmate-<id>/<job> helper space should show its job, shows '$(space_name w7)'"
pass "older firstmate/<job> and 2ndmate-<id>/<job> helper spaces read like └ ones"

# --- again, after a restart, refused ---------------------------------------

: > "$HX/calls.log"
OUT=$(names) || fail "the second pass failed: $OUT"
[ ! -s "$HX/calls.log" ] || fail "a second pass changed something: $(cat "$HX/calls.log")"
grep -q 'every name already shows' <<<"$OUT" || fail "the second pass says nothing needed doing: $OUT"
pass "a second pass changes nothing"

jq '.result.workspaces[] |= del(.tokens)' "$HX/spaces.json" > "$HX/s.tmp" && mv "$HX/s.tmp" "$HX/spaces.json"
jq '.result.panes[] |= del(.tokens)' "$HX/windows.json" > "$HX/w.tmp" && mv "$HX/w.tmp" "$HX/windows.json"
OUT=$(names) || fail "the pass after a restart failed: $OUT"
[ "$(space_name w2)" = Alpha ] && [ "$(window_who w2:p1)" = Alpha ] && [ "$(window_job w2:p1)" = "second mate" ] \
  || fail "the display values a restart lost come back"
pass "after a Herdr restart the lost display values are sent again"

fresh_herdr
touch "$HX/refuse"
if OUT=$(names 2>&1); then fail "names succeeded although Herdr refused every change"; fi
grep -q "refused: window w1:p1 shows who Denver" <<<"$OUT" || fail "names reports what Herdr refused: $OUT"
pass "a change Herdr refuses is reported and names exits non-zero"

# --- the running screen's Keeper --------------------------------------------

fresh_herdr
PATH="$FAKEBIN:$PATH" FM_BRIDGE_NOW=2026-09-20T10:00:00 python3 - "$ROOT/bin" "$HOME_DIR" "$FAKEBIN/herdr" "$HX" <<'PY' \
  || fail "the Keeper did not keep the names"
import json
import os
import sys
import time
sys.path.insert(0, sys.argv[1])
import fm_herdr_names as names
import fm_mission_control as mc
home, herdr, hx = os.path.realpath(sys.argv[2]), sys.argv[3], sys.argv[4]
names.NAMES_EVERY = 0.2
model = mc.bridge.collect(home, home + "/config", mc.bridge._now())
with open(hx + "/agents.json", encoding="utf-8") as fh:
    agents = mc.parse_agents(fh.read())
keeper = names.Keeper(lambda: (model, agents), home, home + "/config", [herdr], "default", "w6:p1")


def spaces():
    with open(hx + "/spaces.json", encoding="utf-8") as fh:
        return {w["workspace_id"]: (w.get("tokens") or {}).get("name") for w in json.load(fh)["result"]["workspaces"]}


def whos():
    with open(hx + "/windows.json", encoding="utf-8") as fh:
        return {w["pane_id"]: (w.get("tokens") or {}).get("who") for w in json.load(fh)["result"]["panes"]}


def wait_for(ok):
    end = time.time() + 10
    while time.time() < end:
        if ok():
            return True
        time.sleep(0.1)
    return False


keeper.start()
assert wait_for(lambda: spaces().get("w1") == "Denver"), spaces()
assert wait_for(lambda: whos().get("w1:p1") == "Denver"), whos()
assert whos().get("w6:p1") is None, whos()
with open(hx + "/spaces.json", encoding="utf-8") as fh:
    data = json.load(fh)
for w in data["result"]["workspaces"]:
    w.pop("tokens", None)
with open(hx + "/spaces.tmp", "w", encoding="utf-8") as fh:
    json.dump(data, fh)
os.replace(hx + "/spaces.tmp", hx + "/spaces.json")
assert wait_for(lambda: spaces().get("w1") == "Denver" and spaces().get("w4") == "Mission Control"), spaces()
keeper.stop.set()
PY
pass "the running screen's Keeper names everything but its own window and puts lost display values back on its own"
