#!/usr/bin/env bash
# Behavior tests for the System Map (bin/fm_system_map.py, served by the
# Bridge): the map built from a fixture home and a fixture second mate home,
# with stand-in tools, hooks, login items and a schedule, has the right nodes
# and lines (each agent's own kit under it, shared tools drawn once), grows
# when an agent, a dependency or a tool is added, says "could not read" when a
# source is missing, never carries a path, link, email address, token or hook
# command, prints its outline and important links, and the Bridge serves the
# page and the map.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIDGE="$ROOT/bin/fm-bridge.sh"
TMP_ROOT=$(fm_test_tmproot fm-system-map)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

HOME_DIR="$TMP_ROOT/demoship"
MATE="$TMP_ROOT/garden-mate-home"
RUN="$TMP_ROOT/bridge-run"
AGENT_DIR="$TMP_ROOT/launch-agents"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
mkdir -p "$HOME_DIR/data/garden-mate" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects/chess" \
  "$HOME_DIR/.claude" "$HOME_DIR/.agents/skills/tidy-up" "$HOME_DIR/.agents/skills/quiet-helper" \
  "$MATE/data" "$MATE/state" "$MATE/projects/garden" "$RUN" "$AGENT_DIR" \
  "$TMP_ROOT/w1-worktree" "$TMP_ROOT/m1-worktree"
HOME_DIR=$(cd "$HOME_DIR" && pwd -P)
MATE=$(cd "$MATE" && pwd -P)
TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789
DRIVE_ID=1Qc6QG6sGeX4s2l-sZeN9gRorsu5_QFM6

cat > "$HOME_DIR/data/projects.md" <<EOF
# Projects

- garden [no-mistakes +yolo] - The garden club's planting planner; public repo octo/garden; token $TOKEN (added 2026-08-01)
- bakery [direct-PR] - The bakery's order sheet, see https://example.com/orders and ops@bakery.example (added 2026-08-02)
- chess [local-only] - The chess league ladder; files in Drive folder $DRIVE_ID and $HOME_DIR/data/chess (added 2026-08-03)
- demoship [no-mistakes-prod-only] - This home's own repository (added 2026-07-01)
EOF
cat > "$HOME_DIR/data/secondmates.md" <<EOF
# Second mates

- garden-mate - Persistent second mate for the garden club planner (home: $MATE; scope: the garden club: its planner and its plots; projects: garden; added 2026-09-01)
EOF
printf '# Backlog\n\n## Queued\n\n## In flight\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
printf '# Backlog\n\n## Queued\n\n## In flight\n\n## Done\n' > "$MATE/data/backlog.md"
printf '# Captain\n\n## Working style\n\n## Projects\n' > "$HOME_DIR/data/captain.md"
printf '# Learnings\n\n## Planner\n' > "$MATE/data/learnings.md"
printf 'The garden mate hosts the planner on Vercel with a Neon database.\n' > "$HOME_DIR/data/garden-mate/brief.md"
printf '{"dependencies": {"next": "15.0.0", "@neondatabase/serverless": "1.0.0"}, "devDependencies": {"vitest": "2.0.0"}}\n' \
  > "$MATE/projects/garden/package.json"
printf 'import matplotlib.pyplot as plt\nfrom pptx import Presentation\n' > "$HOME_DIR/projects/chess/ladder.py"
cat > "$HOME_DIR/AGENTS.md" <<'EOF'
# Firstmate

## 1. Identity and prime directives

You are the captain's only point of contact for all software work.
Other lines follow.
EOF
cat > "$HOME_DIR/.claude/settings.json" <<'EOF'
{"hooks": {
  "SessionStart": [{"hooks": [{"type": "command", "command": "exec \"$CLAUDE_PROJECT_DIR\"/bin/fm-sessionstart-run.sh"}]}],
  "Stop": [{"hooks": [{"type": "command", "command": "exec \"$CLAUDE_PROJECT_DIR\"/bin/fm-turnend-guard.sh --claude"},
                      {"type": "command", "command": "exec \"$CLAUDE_PROJECT_DIR\"/bin/fm-bridge.sh status"}]}]}}
EOF
cat > "$HOME_DIR/.agents/skills/tidy-up/SKILL.md" <<'EOF'
---
name: tidy-up
description: >-
  Tidy the ship when the captain invokes /tidy-up.
  A second sentence that is not shown.
user-invocable: true
---
# tidy-up
EOF
cat > "$HOME_DIR/.agents/skills/quiet-helper/SKILL.md" <<'EOF'
---
name: quiet-helper
description: Agent-only procedure for quiet moments. More words.
---
EOF
cat > "$HOME_DIR/config/mission-control.json" <<'EOF'
{"first_mate_name": "Denver", "names": {"garden": "Garden Club", "chess": "Chess League"},
 "public_page": {"repository": "Octo/crew-office"}}
EOF
printf 'claude\n' > "$HOME_DIR/config/crew-harness"
cat > "$HOME_DIR/config/watched-tools.json" <<'EOF'
{"tools": [{"name": "Sprinkler", "command": "sprinkler"}]}
EOF
cat > "$HOME_DIR/state/w1.meta" <<EOF
window=fx:1
endpoint_task_id=w1
worktree=$TMP_ROOT/w1-worktree
project=$HOME_DIR/projects/chess
harness=claude
kind=ship
mode=local-only
yolo=off
backend=tmux
EOF
printf 'working: reading %s/secret/token.txt and %s\n' "$HOME_DIR" "$TOKEN" > "$HOME_DIR/state/w1.status"
cat > "$MATE/state/m1.meta" <<EOF
window=fx:2
endpoint_task_id=m1
worktree=$TMP_ROOT/m1-worktree
project=$MATE/projects/garden
harness=claude
kind=scout
mode=no-mistakes
yolo=off
backend=tmux
EOF
cat > "$HOME_DIR/state/garden-mate.meta" <<EOF
window=fx:3
endpoint_task_id=garden-mate
worktree=$MATE
project=$MATE
harness=claude
kind=secondmate
mode=secondmate
yolo=off
backend=tmux
home=$MATE
projects=garden
EOF
touch "$HOME_DIR/state/.last-watcher-beat"
printf '#!/bin/sh\n' > "$HOME_DIR/state/contributions.check.sh"
printf 'pr=1\n' > "$HOME_DIR/state/w1.pr-poll"
printf '100.64.0.9 7373 tailscale\n' > "$RUN/bridge.addr"
python3 - "$AGENT_DIR" "$ROOT" <<'PY'
import os, plistlib, sys
d, root = sys.argv[1], sys.argv[2]
def put(name, data):
    with open(os.path.join(d, name + ".plist"), "wb") as fh:
        plistlib.dump(data, fh)
put("com.firstmate.bridge", {"Label": "com.firstmate.bridge",
                             "ProgramArguments": ["/bin/bash", root + "/bin/fm-bridge.sh", "start"]})
put("com.firstmate.publisher", {"Label": "com.firstmate.publisher", "StartInterval": 300,
                                "ProgramArguments": ["/bin/bash", root + "/bin/fm-controls.sh", "frame"]})
put("com.example.unrelated", {"Label": "com.example.unrelated", "ProgramArguments": ["/usr/bin/true"]})
PY

# Stand-in tools. No tmux session answers; Herdr lists the first mate and w1 as
# working; no-mistakes names its steps, one of them new; rclone has one Drive;
# launchctl reports every job loaded; the crontab runs one of this code's scripts.
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/tmux"
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "agent list") printf '{"result":{"agents":[{"pane_id":"p1","agent":"claude","agent_status":"working","cwd":"%s"},{"pane_id":"p2","agent":"claude","agent_status":"working","cwd":"%s"}]}}\n' "$HOME_DIR" "$TMP_ROOT/w1-worktree" ;;
  --version) echo "herdr 9.9.9" ;;
  *) echo "herdr - terminal workspace manager" ;;
esac
EOF
cat > "$FAKEBIN/no-mistakes" <<'EOF'
#!/usr/bin/env bash
[ -n "${NM_BROKEN:-}" ] && exit 1
case "$*" in
  "axi logs --help") printf 'Flags:\n      --step string   step name: intent, review, security, push, pr, ci, or a repository gate step name (required)\n' ;;
  --version) echo "no-mistakes version v1.2.3" ;;
  --help) echo "Local Git proxy that validates code" ;;
  *) exit 1 ;;
esac
EOF
cat > "$FAKEBIN/rclone" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "listremotes --long") printf 'gdrive: drive\nphotos: s3\n' ;;
  --version) echo "rclone v1.0.0" ;;
  *) printf 'Rclone syncs files to and from cloud storage providers as well as\nmounting them.\n' ;;
esac
EOF
cat > "$FAKEBIN/sprinkler" <<'EOF'
#!/usr/bin/env bash
case "$*" in --version) echo "sprinkler 4.5.6" ;; *) echo "Waters the garden on a schedule." ;; esac
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/launchctl"
cat > "$FAKEBIN/crontab" <<EOF
#!/usr/bin/env bash
printf '# a comment\nMAILTO=nobody\n*/30 * * * * %s/bin/fm-bridge.sh status\n0 9 * * * /usr/bin/true\n' "$ROOT"
EOF
cat > "$FAKEBIN/tailscale-down" <<'EOF'
#!/usr/bin/env bash
printf '{"BackendState":"Stopped","Self":{"TailscaleIPs":[]}}\n'
EOF
chmod +x "$FAKEBIN"/*

map() {
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_BRIDGE_STATE_DIR="$RUN" FM_BRIDGE_TAILSCALE="$FAKEBIN/tailscale-down" \
    FM_BRIDGE_AGENT_DIR="$AGENT_DIR" FM_BRIDGE_NOW=2026-09-20T10:00:00 "$BRIDGE" system-map
}
has() {  # <json> <node id>
  jq -e --arg id "$2" 'any(.nodes[]; .id == $id)' <<<"$1" >/dev/null
}
node() {  # <json> <node id> <jq expression on the node>
  jq -r --arg id "$2" ".nodes[] | select(.id == \$id) | $3" <<<"$1"
}
edge() {  # <json> <from> <to> - prints the line's kind, with " live" when it carries work now
  jq -r --arg a "$2" --arg b "$3" '.edges[] | select(.from == $a and .to == $b) | .kind + (if .live then " live" else "" end)' <<<"$1"
}

# --- nodes and lines from the records -------------------------------------

OUT=$(map) || fail "the map did not build: $OUT"
for id in captain channel:chat channel:termius trigger:hook:SessionStart trigger:hook:Stop trigger:watcher \
  trigger:ci trigger:launch:com.firstmate.bridge trigger:launch:com.firstmate.publisher trigger:cron:0 \
  fm model:fm memory:fm mate:garden-mate model:mate:garden-mate memory:mate:garden-mate \
  project:garden project:bakery project:chess project:demoship intern:main:w1 intern:garden-mate:m1 \
  tool:github tool:no-mistakes tool:tasks tool:herdr tool:rclone tool:watched:sprinkler tool:controls tool:playbooks \
  tool:nextjs tool:neon tool:vitest tool:node tool:vercel tool:python tool:matplotlib tool:pptx \
  step:build step:intent step:review step:security step:push step:pr step:ci step:merge path:quick path:local \
  output:bridge output:drive output:github; do
  has "$OUT" "$id" || fail "the map should have node $id; it has: $(jq -r '[.nodes[].id] | join(" ")' <<<"$OUT")"
done
has "$OUT" step:rebase && fail "only the steps no-mistakes names are drawn"
has "$OUT" trigger:launch:com.example.unrelated && fail "a login item that is not this crew's stays off the map"
has "$OUT" trigger:cron:1 && fail "a crontab line that runs nothing of this crew's stays off the map"
[ "$(jq -r '.agents | join(",")' <<<"$OUT")" = "fm,mate:garden-mate" ] || fail "the agents run first mate, then mates"
[ "$(jq -r '.lane | join(",")' <<<"$OUT")" \
  = "step:build,step:intent,step:review,step:security,step:push,step:pr,step:ci,step:merge" ] \
  || fail "the lane runs build, the tool's steps in its order, then merge: $(jq -c .lane <<<"$OUT")"
[ "$(node "$OUT" step:security .card.role)" = "A check no-mistakes runs, named security." ] \
  || fail "a step the map has no words for still gets a plain caption"
jq -e 'all(.nodes[]; .icon | test("^(brand|line):[a-z0-9-]+$"))' <<<"$OUT" >/dev/null \
  || fail "every node names a Simple Icons logo or a Lucide line icon"
[ "$(jq -r '.icons.brand + " " + .icons.line' <<<"$OUT")" \
  = "https://cdn.jsdelivr.net/npm/simple-icons@16.33.0/icons/ https://cdn.jsdelivr.net/npm/lucide-static@1.48.0/icons/" ] \
  || fail "the icon packages are pinned on jsdelivr"
pass "every agent, trigger, project, tool and pipeline step comes from the records, settings and tools"

[ "$(node "$OUT" trigger:hook:Stop .label)" = "Turn end" ] || fail "a Stop hook reads as the turn end"
[ "$(node "$OUT" trigger:hook:Stop .cap)" = "2 scripts" ] || fail "a hook counts the scripts it runs"
node "$OUT" trigger:hook:Stop .card.role | grep -q '^Turn-end guard for any firstmate PRIMARY session' \
  || fail "a hook is described by its scripts' own words: $(node "$OUT" trigger:hook:Stop .card.role)"
[ "$(node "$OUT" trigger:launch:com.firstmate.bridge .label)" = "Bridge at login" ] || fail "a login item is named"
node "$OUT" trigger:launch:com.firstmate.bridge .card.role | grep -q '^Serve the Bridge' \
  || fail "a login item is described by its script's own words"
[ "$(node "$OUT" trigger:launch:com.firstmate.publisher .cap)" = "every 5 minutes" ] \
  || fail "a login item with a start interval is a schedule"
[ "$(node "$OUT" trigger:cron:0 .cap)" = "every 30 minutes" ] || fail "a crontab line reads as a schedule in words"
[ "$(node "$OUT" trigger:watcher .status)" = working ] || fail "a fresh heartbeat shows the watcher awake"
[ "$(node "$OUT" trigger:watcher .cap)" = "1 check" ] || fail "the watcher counts its registered checks"
[ "$(node "$OUT" trigger:ci .cap)" = "1 pull request" ] || fail "GitHub results count the watched pull requests"
[ "$(edge "$OUT" trigger:hook:Stop fm)" = wake ] || fail "a hook wakes the first mate"
pass "hooks, the watcher, GitHub results, login items and schedules each wake the first mate"

[ "$(node "$OUT" fm .label)" = Denver ] || fail "the first mate is named from Mission Control's settings"
[ "$(node "$OUT" fm .card.what)" = "Denver is your only point of contact for all software work." ] \
  || fail "the first mate's caption is the rule book's first sentence: $(node "$OUT" fm .card.what)"
[ "$(node "$OUT" model:fm .label)" = "Claude Code" ] || fail "the first mate's model is the agent Herdr reports"
[ "$(node "$OUT" model:mate:garden-mate .label)" = "Claude Code" ] || fail "a mate's model is its recorded harness"
node "$OUT" memory:fm .card.now | grep -q '^1 page: about you (2 sections)' || fail "the first mate's memory counts pages"
node "$OUT" memory:mate:garden-mate .card.now | grep -q 'lessons learned (1 section)' || fail "a mate's memory is its own"
[ "$(node "$OUT" project:garden .label)" = "Garden Club" ] || fail "projects use Mission Control's display names"
[ "$(node "$OUT" project:garden .owner)" = mate:garden-mate ] || fail "a project hangs under the mate that owns it"
[ "$(node "$OUT" project:chess .owner)" = fm ] || fail "an unowned project hangs under the first mate"
node "$OUT" project:garden .card.role | grep -q 'Denver may merge its green pull requests' \
  || fail "a +yolo project says the first mate may merge"
[ "$(node "$OUT" tool:watched:sprinkler .card.now)" = "Installed, version 4.5.6." ] || fail "a watched tool reports its version"
[ "$(node "$OUT" tool:watched:sprinkler .card.what)" = 'In its own words: "Waters the garden on a schedule."' ] \
  || fail "a tool's caption is its own help line"
node "$OUT" tool:rclone .card.what | grep -q 'as well as mounting them.' || fail "a help paragraph is read whole"
[ "$(node "$OUT" output:drive .card.now)" = "1 Drive account connected." ] || fail "Drive counts rclone's drive remotes"
[ "$(jq -r '.playbooks | map("\(.name)=\(.yours)") | join(",")' <<<"$OUT")" = "quiet-helper=false,tidy-up=true" ] \
  || fail "playbooks come from the skill folders, marked when the captain can start them"
[ "$(jq -r '.playbooks[] | select(.name == "tidy-up") | .text' <<<"$OUT")" \
  = "Tidy the ship when the captain invokes /tidy-up." ] || fail "a playbook's caption is its description's first sentence"
[ "$(jq -r '.playbooks[] | select(.name == "quiet-helper") | .text' <<<"$OUT")" = "Procedure for quiet moments." ] \
  || fail "an agent-only prefix is dropped"
pass "each agent has its own model and memory, and captions come from each node's own source"

# Tools: one agent's are its own, two or more agents' are shared and drawn once.
for id in tool:nextjs tool:neon tool:vitest tool:node tool:vercel; do
  [ "$(node "$OUT" "$id" '.owner // "shared"')" = mate:garden-mate ] || fail "$id is the garden mate's own"
  [ "$(edge "$OUT" mate:garden-mate "$id")" = own ] || fail "$id hangs under the garden mate"
done
for id in tool:matplotlib tool:pptx tool:python tool:quota tool:controls tool:watched:sprinkler; do
  [ "$(node "$OUT" "$id" '.owner // "shared"')" = fm ] || fail "$id is the first mate's own"
done
for id in tool:tasks tool:herdr tool:playbooks tool:github tool:no-mistakes; do
  [ "$(node "$OUT" "$id" '.shared')" = true ] || fail "$id is shared by the first mate and the mate"
  [ "$(edge "$OUT" fm "$id")" = uses ] || fail "the first mate's line to shared $id is a temporary one"
  [ "$(edge "$OUT" mate:garden-mate "$id")" = uses ] || fail "the mate's line to shared $id is a temporary one"
done
[ "$(node "$OUT" tool:neon .card.source)" = "its charter, its package list" ] \
  || fail "a tool found in two places names both: $(node "$OUT" tool:neon .card.source)"
[ "$(node "$OUT" tool:vercel .card.source)" = "its charter" ] || fail "a service named in a charter is the mate's"
pass "a tool only one agent uses hangs under it, and shared tools are drawn once with temporary lines"

[ "$(edge "$OUT" captain channel:chat)" = "flow live" ] || fail "captain to chat is lit while the first mate works"
[ "$(edge "$OUT" fm mate:garden-mate)" = flow ] || fail "the first mate routes to each second mate"
[ "$(edge "$OUT" mate:garden-mate intern:garden-mate:m1)" = flow ] || fail "a mate's helper hangs off that mate"
[ "$(edge "$OUT" fm intern:main:w1)" = "flow live" ] || fail "the first mate's working helper is on a lit line"
[ "$(edge "$OUT" intern:main:w1 step:build)" = at ] || fail "a helper's line to its delivery step shows when picked"
[ "$(node "$OUT" intern:main:w1 .project)" = project:chess ] || fail "a helper knows its project"
[ "$(node "$OUT" fm .status)" = working ] || fail "the first mate glows while its window works"
[ "$(node "$OUT" intern:main:w1 .step)" = build ] || fail "a helper with no validation run sits at build"
[ "$(node "$OUT" step:build .status)" = working ] || fail "the step a working helper is on glows"
[ "$(node "$OUT" intern:garden-mate:m1 .step)" = null ] || fail "a scout is not on the delivery lane"
pass "lines, glow and each helper's place on the lane follow who is working"

tour=$(jq -r '[.tour[].node] | join(",")' <<<"$OUT")
case "$tour" in
  captain,channel:chat,trigger:watcher,fm,mate:garden-mate,model:mate:garden-mate,project:garden,tool:*,step:build,step:intent,*step:merge,output:github*) ;;
  *) fail "the tour follows one request from the captain to the merge: $tour" ;;
esac
[ "$(jq -r '[.tour[] | select(.text == "")] | length' <<<"$OUT")" = 0 ] || fail "every tour hop has a sentence"
pass "the tour walks one request through the real nodes"

outline=$(PATH="$FAKEBIN:$PATH" FM_BRIDGE_STATE_DIR="$RUN" FM_BRIDGE_TAILSCALE="$FAKEBIN/tailscale-down" \
  FM_BRIDGE_AGENT_DIR="$AGENT_DIR" python3 "$ROOT/bin/fm_system_map.py" outline --home "$HOME_DIR" \
  --config-dir "$HOME_DIR/config") || fail "the outline did not print"
for want in '^You$' '^  ways in: Chat with Denver, Termius$' '^  Denver \(first mate\)$' \
  '^    Garden Club \(second mate\)$' '^      own: Claude Code, Memory, Garden Club, ' '^Shared tools: .*Backlog tool' \
  '^Delivery lane: Build > Your words > Review > '; do
  grep -Eq "$want" <<<"$outline" || fail "the outline shows: $want; got: $outline"
done
links=$(FM_BRIDGE_STATE_DIR="$RUN" PYTHONPATH="$ROOT/bin" python3 -c '
import sys, fm_system_map as m
print("|".join("%s=%s" % t for t in m.important_links(sys.argv[1])))' "$HOME_DIR")
[ "$links" = "System Map=http://100.64.0.9:7373/system-map|The Bridge page=http://100.64.0.9:7373/|Public Mission Control page=https://octo.github.io/crew-office/" ] \
  || fail "important links come from the Bridge's address and the public page's repository: $links"
pass "the outline and the important links Mission Control shows come from the same map"

# --- steps from the current state -----------------------------------------

steps=$(PYTHONPATH="$ROOT/bin" python3 - <<'PY'
import fm_system_map as m
cases = [
    {"current_state": {"state": "parked", "source": "run-step", "detail": "parked at review: 2 finding(s)"}},
    {"current_state": {"state": "working", "source": "run-step", "detail": "ci running"}},
    {"current_state": {"state": "done", "source": "run-step", "detail": "checks green: PR ready for review"}},
    {"current_state": {"state": "working", "source": "run-step", "detail": "validating (fixing)"}},
    {"current_state": {"state": "working", "source": "pane", "detail": "harness busy"}},
    {"current_state": {"state": "done", "source": "status-log"}, "pr": {"url": "https://x"}},
    {"kind": "scout", "current_state": {"state": "working", "source": "pane"}},
    {"current_state": {"state": "unknown", "source": "none"}},
]
print(" ".join("%s/%s" % m.worker_step(c) for c in cases))
PY
)
[ "$steps" = "review/None ci/None merge/None None/checks build/None merge/None None/None None/None" ] \
  || fail "each current state maps to its step: $steps"
pass "a parked gate, CI, green checks and a running validation each find their step"

# --- growing and missing sources ------------------------------------------

mkdir -p "$TMP_ROOT/beta-mate-home/data" "$TMP_ROOT/beta-mate-home/state"
cp "$MATE/data/backlog.md" "$TMP_ROOT/beta-mate-home/data/backlog.md"
printf -- '- beta-mate - Persistent second mate for the bakery (home: %s; scope: the bakery: orders; projects: bakery; added 2026-09-02)\n' \
  "$TMP_ROOT/beta-mate-home" >> "$HOME_DIR/data/secondmates.md"
printf '{"dependencies": {"next": "15.0.0", "react": "19.0.0", "@neondatabase/serverless": "1.0.0"}}\n' \
  > "$MATE/projects/garden/package.json"
cat > "$HOME_DIR/config/watched-tools.json" <<'EOF'
{"tools": [{"name": "Sprinkler", "command": "sprinkler"}, {"name": "Weather", "command": "no-such-weather-tool"},
           {"name": "Mystery"}]}
EOF
for task in fin1209-ch1-materials-audit fin1209-ch1-term-visuals-part1; do
  mkdir -p "$TMP_ROOT/$task-worktree"
  sed -e "s|m1|$task|" -e "s|kind=scout|kind=ship|" "$MATE/state/m1.meta" > "$MATE/state/$task.meta"
done
GROWN=$(NM_BROKEN=1 map) || fail "the grown map did not build"
rm -f "$MATE"/state/fin1209-*.meta
for task in fin1209-ch1-materials-audit fin1209-ch1-term-visuals-part1; do
  [ "$(node "$GROWN" "intern:garden-mate:$task" .owner)" = mate:garden-mate ] \
    || fail "a helper with a long task id keeps its own node: $task"
  [ "$(edge "$GROWN" mate:garden-mate "intern:garden-mate:$task")" = flow ] || fail "its mate's line reaches $task"
done
[ "$(jq '[.nodes[].id] | length == (unique | length)' <<<"$GROWN")" = true ] || fail "no two nodes share an id"
has "$GROWN" mate:beta-mate || fail "adding a second mate adds its node"
has "$GROWN" model:mate:beta-mate || fail "the new mate gets its own model"
[ "$(edge "$GROWN" mate:beta-mate project:bakery)" = own ] || fail "the new mate owns its project"
[ "$(edge "$GROWN" fm project:bakery)" = "" ] || fail "an owned project no longer hangs off the first mate"
[ "$(node "$GROWN" tool:react .owner)" = mate:garden-mate ] || fail "a new dependency adds the tool under its user"
has "$OUT" tool:react && fail "the dependency was not there before"
has "$GROWN" tool:vitest && fail "a removed dependency drops its tool"
jq -e 'any(.tracked[]; .key == "mate:beta-mate") and any(.tracked[]; .key == "tool:react")' <<<"$GROWN" >/dev/null \
  || fail "the new mate and tool are tracked for What changed"
[ "$(node "$GROWN" tool:watched:weather .card.what)" = "could not read" ] || fail "a missing tool says could not read"
[ "$(node "$GROWN" tool:watched:weather .status)" = unreadable ] || fail "a missing tool is drawn as unreadable"
[ "$(node "$GROWN" tool:watched:mystery .card.what)" = "could not read" ] || fail "a tool with no command says could not read"
has "$GROWN" step:unread || fail "when no-mistakes cannot name its steps the lane says so"
[ "$(node "$GROWN" step:unread .card.what)" = "could not read" ] || fail "the unread steps say could not read"
[ "$(node "$GROWN" tool:no-mistakes .card.what)" = "A tool on this Mac." ] || fail "a tool whose help fails keeps a plain caption"
pass "adding an agent, a dependency or a tool adds a node, and a missing source says could not read"

mv "$HOME_DIR/AGENTS.md" "$HOME_DIR/AGENTS.away"
printf '{"hooks": ' > "$HOME_DIR/.claude/settings.json"
MISSING=$(map) || fail "the map should build without the rule book"
[ "$(node "$MISSING" fm .card.what)" = "could not read" ] || fail "no rule book: the first mate's caption says could not read"
[ "$(node "$MISSING" trigger:hooks .status)" = unreadable ] || fail "unreadable hook settings say could not read"
mv "$HOME_DIR/AGENTS.away" "$HOME_DIR/AGENTS.md"
pass "a missing rule book or unreadable hook settings say could not read"

# --- nothing private leaves ------------------------------------------------

for out in "$OUT" "$GROWN" "$MISSING"; do
  for secret in "$TMP_ROOT" "$HOME_DIR" "$MATE" "$HOME" "$TOKEN" "$DRIVE_ID" "https://example.com" "ops@bakery.example" \
    "token.txt" "w1.meta" "/secret/" "state/" "data/" "CLAUDE_PROJECT_DIR" "--claude" "com.example.unrelated" \
    "/usr/bin/true" "MAILTO" "gdrive"; do
    case "$(jq -c 'del(.icons)' <<<"$out")" in *"$secret"*) fail "the map must not carry: $secret" ;; esac
  done
done
scrubbed=$(PYTHONPATH="$ROOT/bin" python3 - "$HOME_DIR" "$TOKEN" <<'PY'
import sys
import fm_system_map as m
home, token = sys.argv[1], sys.argv[2]
print(m.scrub("see %s/state/w1.status, ~/notes, data/x.md, run.log, %s, https://a.b/c, me@x.org, /tidy-up" % (home, token),
              [home]))
PY
)
[ "$scrubbed" = "see a local file, a local file, a local file, a local file, (hidden), a web link, an email address, /tidy-up" ] \
  || fail "scrub keeps plain words and slash commands only: $scrubbed"
pass "no paths, links, email addresses, tokens or hook commands reach the map"

# --- the Bridge serves the page and the map ---------------------------------

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_BRIDGE_STATE_DIR="$RUN" FM_BRIDGE_TAILSCALE="$FAKEBIN/tailscale-down" \
  FM_BRIDGE_AGENT_DIR="$AGENT_DIR" "$BRIDGE" start --foreground --port "$PORT" > "$RUN/fg.log" 2>&1 &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null; fm_test_cleanup' EXIT
i=0
until curl -fsS --max-time 2 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; do
  i=$((i + 1)); [ $i -lt 40 ] || fail "the server never answered: $(cat "$RUN/fg.log")"
  sleep 0.25
done
code=$(curl -s -D "$TMP_ROOT/page.head" -o "$TMP_ROOT/page.html" -w '%{http_code}' "http://127.0.0.1:$PORT/system-map")
[ "$code" = 200 ] || fail "GET /system-map should answer 200, got $code"
grep -q '<title>System Map</title>' "$TMP_ROOT/page.html" || fail "GET /system-map serves the page"
grep -q 'How a request travels' "$TMP_ROOT/page.html" || fail "the page offers the guided tour"
grep -qi "connect-src 'self' https://cdn.jsdelivr.net" "$TMP_ROOT/page.head" \
  || fail "the page may fetch its map from the same server and its icons from jsdelivr"
code=$(curl -s -o "$TMP_ROOT/served.json" -w '%{http_code}' "http://127.0.0.1:$PORT/system-map.json")
[ "$code" = 200 ] || fail "GET /system-map.json should answer 200, got $code"
jq -e 'any(.nodes[]; .id == "mate:beta-mate")' "$TMP_ROOT/served.json" >/dev/null \
  || fail "the served map is built from the records"
curl -fsS "http://127.0.0.1:$PORT/" | grep -q 'href="system-map"' || fail "the Bridge links to the System Map"
for path in /system-map/ /system-map.json/x /system-map/../data/backlog.md; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --path-as-is "http://127.0.0.1:$PORT$path")
  [ "$code" = 404 ] || fail "GET $path must be 404, got $code"
done
pass "the Bridge serves the System Map page and its map, and nothing else new"
