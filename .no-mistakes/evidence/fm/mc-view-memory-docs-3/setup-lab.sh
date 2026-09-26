#!/usr/bin/env bash
# Builds an isolated Mission Control home from the Bridge fixtures (mirrors tests/fm-mission-control.test.sh setup).
set -eu
ROOT=$1 LAB=$2
FIX="$ROOT/tests/assets/bridge"
rm -rf "$LAB"; mkdir -p "$LAB"
H="$LAB/homeship" M="$LAB/alpha-mate-home" FB="$LAB/fakebin"
mkdir -p "$H/data" "$H/state" "$H/config" "$H/projects/alpha" "$M/data" "$M/state" "$FB" "$LAB/wt-alpha"
for r in projects backlog done-archive captain learnings; do cp "$FIX/$r.fixture" "$H/data/$r.md"; done
sed "s|@MATE_HOME@|$M|" "$FIX/secondmates.fixture" > "$H/data/secondmates.md"
cp "$FIX/mate-backlog.fixture" "$M/data/backlog.md"
printf '{"first_mate_name": "Denver"}\n' > "$H/config/mission-control.json"
mkdir -p "$H/data/d4" "$H/data/lone-study" "$H/data/q2" "$H/data/loose-key" "$H/data/q1"
{ cat "$FIX/report.fixture"; for n in $(seq 1 80); do echo "- Detail line $n"; done; } > "$H/data/d4/report.md"
printf '# A study with no task\n\nShort.\n' > "$H/data/lone-study/report.md"
cp "$FIX/decision.fixture" "$H/data/q2/decision-quiz.md"
printf '# Decision: loose-key - ACTION: FIX, option (b)\n\nDone.\n' > "$H/data/loose-key/decision-extra.md"
printf '# Brief: secret instructions\n\nNever listed.\n' > "$H/data/q1/brief.md"
printf '# Lessons\n\n## Decks\nKeep them short.\n' > "$M/data/learnings.md"
jq -n '{links: [{project: "alpha", label: "class Drive folder", url: "https://drive.example.org/folders/abc"},
  {project: null, label: "status page", url: "https://status.example.org/"}]}' > "$H/config/bridge.json"
touch -t 202609200700 "$H/data/captain.md"
touch -t 202609191200 "$H/data/d4/report.md"
touch -t 202609181200 "$H/data/q2/decision-quiz.md"
touch -t 202609171200 "$H/data/lone-study/report.md"
touch -t 202609161200 "$H/data/loose-key/decision-extra.md"
jq -n --arg home "$H" --arg mate "$M" '{result: {type: "agent_list", agents: [
  {pane_id: "w1:p1", agent_status: "working", cwd: $home, foreground_cwd: $home},
  {pane_id: "w2:p1", agent_status: "idle", cwd: $mate}]}}' > "$LAB/agents.json"
cat > "$FB/herdr-list" <<SH
#!/usr/bin/env bash
[ "\$1 \$2" = "agent list" ] && exec cat "$LAB/agents.json"
exit 0
SH
chmod +x "$FB/herdr-list"
for t in tmux herdr; do printf '#!/usr/bin/env bash\nexit 1\n' > "$FB/$t"; chmod +x "$FB/$t"; done
