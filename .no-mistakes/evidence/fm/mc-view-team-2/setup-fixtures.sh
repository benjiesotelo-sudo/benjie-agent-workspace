#!/usr/bin/env bash
# Builds the Team view fixtures (mirrors tests/fm-mission-control.test.sh) under $1.
set -eu
WT=$2; FIX="$WT/tests/assets/bridge"; T=$1
HOME_DIR="$T/homeship"; MATE="$T/alpha-mate-home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects/alpha" \
  "$MATE/data" "$MATE/state" "$T/wt-alpha" "$T/wt-beta" "$T/wt-mate" "$T/fakebin"
for r in projects backlog done-archive captain learnings; do cp "$FIX/$r.fixture" "$HOME_DIR/data/$r.md"; done
sed "s|@MATE_HOME@|$MATE|" "$FIX/secondmates.fixture" > "$HOME_DIR/data/secondmates.md"
cp "$FIX/mate-backlog.fixture" "$MATE/data/backlog.md"
printf '{"first_mate_name": "Denver"}\n' > "$HOME_DIR/config/mission-control.json"
meta() { local home=$1 id=$2 wt=$3 project=$4
  printf 'window=fx:%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=claude\nkind=ship\nmode=direct-PR\nyolo=off\n' "$id" "$id" "$wt" "$project" > "$home/state/$id.meta"; }
meta "$HOME_DIR" a1 "$T/wt-alpha" "$HOME_DIR/projects/alpha"
meta "$HOME_DIR" q1 "$T/wt-beta" "$HOME_DIR/projects/beta"
meta "$MATE" m2 "$T/wt-mate" "$MATE/projects/elsewhere"
for tool in tmux herdr; do printf '#!/usr/bin/env bash\nexit 1\n' > "$T/fakebin/$tool"; chmod +x "$T/fakebin/$tool"; done
jq -n --arg home "$HOME_DIR" --arg mate "$MATE" --arg wa "$T/wt-alpha" '
  {result: {type: "agent_list", agents: [
    {pane_id: "w1:p1", agent_status: "working", cwd: $home, foreground_cwd: $home},
    {pane_id: "w2:p1", agent_status: "idle", cwd: $mate},
    {pane_id: "w3:p1", agent_status: "working", cwd: "/somewhere", foreground_cwd: $wa}]}}' > "$T/agents.json"
printf '#!/usr/bin/env bash\n[ "$1 $2" = "agent list" ] && exec cat "$DRIVE_AGENTS"\nexit 0\n' > "$T/fakebin/herdr-list"; chmod +x "$T/fakebin/herdr-list"
# Row of five mates, one remote, one with many waiting items.
ROW="$T/rowship"; mkdir -p "$ROW/data" "$ROW/state" "$ROW/config"
cp "$FIX/projects.fixture" "$ROW/data/projects.md"
printf '# Backlog\n\n## In flight\n## Queued\n## Done\n' > "$ROW/data/backlog.md"
printf '{"first_mate_name": "Denver"}\n' > "$ROW/config/mission-control.json"
{ echo "# Second mates"
  for n in 1 2 3 4 5; do
    if [ "$n" = 2 ]; then echo "- r2-mate - Mate number 2 (host: box; root: /srv/r2; home: /srv/r2/home; scope: area 2; projects: alpha; added 2026-09-01)"; continue; fi
    mkdir -p "$T/r$n/data" "$T/r$n/state"; cp "$FIX/mate-backlog.fixture" "$T/r$n/data/backlog.md"
    echo "- r$n-mate - Mate number $n (home: $T/r$n; scope: area $n; projects: alpha; added 2026-09-01)"
  done } > "$ROW/data/secondmates.md"
{ printf '# Backlog\n\n## In flight\n## Queued\n'
  for n in $(seq 10 19); do printf -- '- [ ] w%d - Wait %d (kind: task) (since 2026-09-08) (hold: the call) (hold-kind: captain)\n' "$n" "$n"; done
  for n in 20 21; do printf -- '- [ ] w%d - Task %d (kind: task) (since 2026-09-09)\n' "$n" "$n"; done
  printf '## Done\n'; } > "$T/r3/data/backlog.md"
