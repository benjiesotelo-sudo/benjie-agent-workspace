#!/usr/bin/env bash
# Build an isolated fixture home for Mission Control (mirrors tests/fm-mission-control.test.sh setup).
set -eu
ROOT=$1; T=$2
rm -rf "$T"; mkdir -p "$T"
FIX="$ROOT/tests/assets/bridge"
H="$T/homeship"; MATE="$T/alpha-mate-home"; FB="$T/fakebin"
mkdir -p "$H/data" "$H/state" "$H/config" "$H/projects/alpha" "$MATE/data" "$MATE/state" "$T/wt-alpha" "$T/wt-beta" "$T/wt-mate" "$FB"
for r in projects backlog done-archive captain learnings; do cp "$FIX/$r.fixture" "$H/data/$r.md"; done
sed "s|@MATE_HOME@|$MATE|" "$FIX/secondmates.fixture" > "$H/data/secondmates.md"
cp "$FIX/mate-backlog.fixture" "$MATE/data/backlog.md"
printf '{"first_mate_name": "Denver"}\n' > "$H/config/mission-control.json"
meta() { printf 'window=fx:%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=claude\nkind=ship\nmode=direct-PR\nyolo=off\n' "$2" "$2" "$3" "$4" > "$1/state/$2.meta"; }
meta "$H" a1 "$T/wt-alpha" "$H/projects/alpha"; meta "$H" q1 "$T/wt-beta" "$H/projects/beta"; meta "$MATE" m2 "$T/wt-mate" "$MATE/projects/elsewhere"
for tool in tmux herdr; do printf '#!/usr/bin/env bash\nexit 1\n' > "$FB/$tool"; chmod +x "$FB/$tool"; done
cat > "$FB/herdr-list" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$T/herdr-calls.log"
[ "\$1 \$2" = "agent list" ] && exec cat "$T/agents.json"
exit 0
SH
chmod +x "$FB/herdr-list"
jq -n --arg home "$H" --arg mate "$MATE" --arg wa "$T/wt-alpha" '{result: {type: "agent_list", agents: [
  {pane_id: "w1:p1", agent_status: "working", cwd: $home, foreground_cwd: $home},
  {pane_id: "w2:p1", agent_status: "idle", cwd: $mate},
  {pane_id: "w3:p1", agent_status: "working", cwd: "/somewhere", foreground_cwd: $wa}]}}' > "$T/agents.json"
mkdir -p "$H/data/d4" "$H/data/lone-study" "$H/data/q2" "$H/data/loose-key" "$H/data/q1"
{ cat "$FIX/report.fixture"; for n in $(seq 1 80); do echo "- Detail line $n"; done; } > "$H/data/d4/report.md"
printf '# A study with no task\n\nShort.\n' > "$H/data/lone-study/report.md"
cp "$FIX/decision.fixture" "$H/data/q2/decision-quiz.md"
printf '# Decision: loose-key - ACTION: FIX, option (b)\n\nDone.\n' > "$H/data/loose-key/decision-extra.md"
printf '# Brief: secret instructions\n\nNever listed.\n' > "$H/data/q1/brief.md"
printf 'status: working on secret status\n' > "$H/data/q1/status.md"
printf '# Lessons\n\n## Decks\nKeep them short.\n' > "$MATE/data/learnings.md"
jq -n '{links: [{project: "alpha", label: "class Drive folder", url: "https://drive.example.org/folders/abc"},
  {project: null, label: "status page", url: "https://status.example.org/"}]}' > "$H/config/bridge.json"
touch -t 202609200700 "$H/data/captain.md"; touch -t 202609191200 "$H/data/d4/report.md"
touch -t 202609181200 "$H/data/q2/decision-quiz.md"; touch -t 202609171200 "$H/data/lone-study/report.md"
touch -t 202609161200 "$H/data/loose-key/decision-extra.md"
