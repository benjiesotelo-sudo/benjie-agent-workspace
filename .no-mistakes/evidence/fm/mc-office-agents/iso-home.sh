#!/usr/bin/env bash
# Builds an isolated home: first mate working, one second mate (alpha) whose
# home has its own worker, and panes no record claims (a helper beside each).
set -eu
ROOT=$1; T=$2; FIX=$ROOT/tests/assets/bridge
rm -rf "$T"; H=$T/home; M=$T/mate
mkdir -p "$H/data" "$H/state" "$H/config" "$H/projects/alpha" "$H/projects/beta" "$M/data" "$M/state" "$T/wt-m"
H=$(cd "$H" && pwd); M=$(cd "$M" && pwd)
for r in projects backlog done-archive captain learnings; do cp "$FIX/$r.fixture" "$H/data/$r.md"; done
sed "s|@MATE_HOME@|$M|" "$FIX/secondmates.fixture" > "$H/data/secondmates.md"
cp "$FIX/mate-backlog.fixture" "$M/data/backlog.md"
printf '{"first_mate_name": "Denver"}\n' > "$H/config/mission-control.json"
printf 'window=fx:m2\nendpoint_task_id=m2\nworktree=%s\nproject=%s\nharness=claude\nkind=ship\nmode=direct-PR\nyolo=off\n' "$T/wt-m" "$M/projects/elsewhere" > "$M/state/m2.meta"
jq -n --arg h "$H" --arg m "$M" --arg wm "$T/wt-m" '{result: {agents: [
 {pane_id: "w1:p1", agent_status: "working", cwd: $h},
 {pane_id: "w2:p1", agent_status: "idle", cwd: $m},
 {pane_id: "w3:p1", agent_status: "working", cwd: $wm},
 {pane_id: "w4:p1", agent_status: "working", cwd: ($h + "/projects/beta"), terminal_title: "✳ Grading /Users/x/quiz.md", terminal_title_stripped: "Grading /Users/x/quiz.md"},
 {pane_id: "w4:p2", agent_status: "idle", cwd: ($h + "/projects/alpha")}]}}' > "$T/agents.json"
echo "$H"
