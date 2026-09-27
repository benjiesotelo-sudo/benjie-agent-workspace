#!/usr/bin/env bash
# setup.sh <worktree> <tmp> - build an isolated first-mate home from the repo's Bridge fixtures,
# a fake herdr that serves $DRIVE_AGENTS and logs `agent focus`, and two agent lists.
set -eu
ROOT=$1; T=$2; FIX="$ROOT/tests/assets/bridge"
H="$T/homeship"; M="$T/alpha-mate-home"; FB="$T/fakebin"
mkdir -p "$H/data" "$H/state" "$H/config" "$H/projects/alpha" "$M/data" "$M/state" "$T/wt-alpha" "$T/wt-beta" "$T/wt-mate" "$FB"
for r in projects backlog done-archive captain learnings; do cp "$FIX/$r.fixture" "$H/data/$r.md"; done
sed "s|@MATE_HOME@|$M|" "$FIX/secondmates.fixture" > "$H/data/secondmates.md"
cp "$FIX/mate-backlog.fixture" "$M/data/backlog.md"
printf '{"first_mate_name": "Denver", "names": {"alpha": "Alpha"}}\n' > "$H/config/mission-control.json"
meta() { printf 'window=fx:%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=claude\nkind=ship\nmode=direct-PR\nyolo=off\n' "$2" "$2" "$3" "$4" > "$1/state/$2.meta"; }
meta "$H" a1 "$T/wt-alpha" "$H/projects/alpha"
meta "$H" q1 "$T/wt-beta" "$H/projects/beta"
meta "$M" m2 "$T/wt-mate" "$M/projects/elsewhere"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FB/tmux"; chmod +x "$FB/tmux"
cat > "$FB/herdr" <<SH
#!/usr/bin/env bash
[ "\$1 \$2" = "agent list" ] && exec cat "\$DRIVE_AGENTS"
[ "\$1 \$2" = "agent focus" ] && printf '%s\n' "\$3" >> "$T/focus.log"
exit 0
SH
chmod +x "$FB/herdr"
jq -n --arg home "$H" --arg mate "$M" --arg wa "$T/wt-alpha" '
  {result: {type: "agent_list", agents: [
    {pane_id: "w1:p1", agent_status: "working", cwd: $home, foreground_cwd: $home},
    {pane_id: "w2:p1", agent_status: "idle", cwd: $mate},
    {pane_id: "w3:p1", agent_status: "working", cwd: "/somewhere", foreground_cwd: $wa}]}}' > "$T/agents.json"
jq --arg home "$H" '.result.agents += [
    {pane_id: "w4:p1", agent_status: "working", cwd: ($home + "/projects/alpha"),
     terminal_title_stripped: "Quiz one for chapter two"}]' "$T/agents.json" > "$T/agents2.json"
# flip: w1 and w3 go idle (would fall asleep after SLEEP_AFTER), w2 wakes up
jq '(.result.agents[] | select(.pane_id == "w1:p1" or .pane_id == "w3:p1") | .agent_status) = "idle"
  | (.result.agents[] | select(.pane_id == "w2:p1") | .agent_status) = "working"' "$T/agents.json" > "$T/flip.json"
cp "$T/agents.json" "$T/live.json"
