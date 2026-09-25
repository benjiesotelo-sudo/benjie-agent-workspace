#!/usr/bin/env bash
# Build an isolated fixture home (crew records, one local second mate, two task metas) plus a fake herdr.
set -eu
W=$1; T=$2
FIX="$W/tests/assets/bridge"
rm -rf "$T"; mkdir -p "$T"
T=$(cd "$T" && pwd)
H="$T/homeship"; M="$T/alpha-mate-home"; FB="$T/bin"
mkdir -p "$H/data" "$H/state" "$H/config" "$H/projects/alpha" "$M/data" "$M/state" "$T/wt-alpha" "$T/wt-beta" "$FB"
for r in projects backlog done-archive captain learnings; do cp "$FIX/$r.fixture" "$H/data/$r.md"; done
sed "s|@MATE_HOME@|$M|" "$FIX/secondmates.fixture" > "$H/data/secondmates.md"
cp "$FIX/mate-backlog.fixture" "$M/data/backlog.md"
printf '{"first_mate_name": "Denver"}\n' > "$H/config/mission-control.json"
for id in a1 q1; do
  printf 'window=fx:%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=claude\nkind=ship\nmode=direct-PR\nyolo=off\n' \
    $id $id "$T/wt-alpha" "$H/projects/alpha" > "$H/state/$id.meta"
done
touch "$H/state/.last-watcher-beat"
printf 'x\ny\n' > "$H/state/.wake-queue"
jq -n --arg home "$H" --arg mate "$M" --arg wa "$T/wt-alpha" '
  {result: {type: "agent_list", agents: [
    {pane_id: "w1:p1", agent_status: "idle", cwd: $home, foreground_cwd: $home},
    {pane_id: "w2:p1", agent_status: "idle", cwd: $mate},
    {pane_id: "w3:p1", agent_status: "working", cwd: "/somewhere", foreground_cwd: $wa}]}}' > "$T/agents.json"
REAL_HERDR=$(command -v herdr || true)
# Fake herdr: agent list from the fixture, --version from the real binary, anything else fails
# (so no call ever reaches the captain's live Herdr session besides a version read).
cat > "$FB/herdr-fake" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$T/herdr-calls.log"
[ -e "$T/herdr-down" ] && exit 1
case "\$1 \${2:-}" in
  "agent list") exec cat "\${FAKE_AGENTS:-$T/agents.json}" ;;
  "workspace list") echo '{"result":{"workspaces":[{"workspace_id":"w9","label":"mission-control"}]}}'; exit 0 ;;
  "pane list") echo '{"result":{"panes":[{"pane_id":"w9:p1"}]}}'; exit 0 ;;
  "pane process-info") echo '{"result":{"process_info":{"foreground_processes":[{"cmdline":"python3 bin/fm_mission_control.py run --home x"}]}}}'; exit 0 ;;
esac
[ "\$1" = --version ] && [ -n "$REAL_HERDR" ] && exec "$REAL_HERDR" --version
exit 1
EOF
chmod +x "$FB/herdr-fake"
echo "$T"
