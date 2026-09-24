#!/usr/bin/env bash
# Builds the isolated homes used for live driving (mirrors tests/fm-mission-control.test.sh fixtures).
set -eu
W=/Users/benjie/.no-mistakes/evidence/01M38XT85072NVJPSTV0JCRFP9/lab; FIX=/Users/benjie/.no-mistakes/worktrees/40995176e50b/01M38XT85072NVJPSTV0JCRFP9/tests/assets/bridge
H=$W/homeship; MATE=$W/alpha-mate-home
rm -rf "$H" "$MATE" "$W/many" "$W/fakebin"
mkdir -p "$H/data" "$H/state" "$H/config" "$H/projects/alpha" "$MATE/data" "$MATE/state" "$W/wt-alpha" "$W/wt-beta" "$W/wt-mate" "$W/fakebin"
for r in projects backlog done-archive captain learnings; do cp "$FIX/$r.fixture" "$H/data/$r.md"; done
sed "s|@MATE_HOME@|$MATE|" "$FIX/secondmates.fixture" > "$H/data/secondmates.md"
cp "$FIX/mate-backlog.fixture" "$MATE/data/backlog.md"
printf '{"first_mate_name": "Denver"}\n' > "$H/config/mission-control.json"
meta() { printf 'window=fx:%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=claude\nkind=ship\nmode=direct-PR\nyolo=off\n' "$2" "$2" "$3" "$4" > "$1/state/$2.meta"; }
meta "$H" a1 "$W/wt-alpha" "$H/projects/alpha"
meta "$H" q1 "$W/wt-beta" "$H/projects/beta"
meta "$MATE" m2 "$W/wt-mate" "$MATE/projects/elsewhere"
for t in tmux herdr; do printf '#!/usr/bin/env bash\nexit 1\n' > "$W/fakebin/$t"; chmod +x "$W/fakebin/$t"; done
jq -n --arg home "$H" --arg mate "$MATE" --arg wa "$W/wt-alpha" '{result: {type: "agent_list", agents: [
  {pane_id: "w1:p1", agent_status: "working", cwd: $home, foreground_cwd: $home},
  {pane_id: "w2:p1", agent_status: "idle", cwd: $mate},
  {pane_id: "w3:p1", agent_status: "working", cwd: "/somewhere", foreground_cwd: $wa}]}}' > "$W/agents.json"
printf '#!/usr/bin/env bash\ncat "%s"\n' "$W/agents.json" > "$W/fakebin/herdr-list"; chmod +x "$W/fakebin/herdr-list"
# many: 9 projects, a long description, no agents, empty backlog
M=$W/many; mkdir -p "$M/data" "$M/state" "$M/config"
cp "$FIX/projects.fixture" "$M/data/projects.md"
for n in 1 2 3 4 5 6; do echo "- extra$n [local-only] - Extra project number $n (added 2026-09-01)" >> "$M/data/projects.md"; done
echo "- longdesc [local-only] - A deliberately very long description that goes on and on about teaching materials, outreach modules, reviewer notes, slide decks, quizzes and many other things so it cannot fit in two lines of a card (added 2026-09-01)" >> "$M/data/projects.md"
printf '# Backlog\n\n## In flight\n## Queued\n## Done\n' > "$M/data/backlog.md"
