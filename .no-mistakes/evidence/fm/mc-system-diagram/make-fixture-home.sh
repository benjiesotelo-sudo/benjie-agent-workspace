#!/usr/bin/env bash
# Builds the System Map test fixture home (copied from tests/fm-system-map.test.sh setup) at $1 for live driving.
set -u
ROOT=$2
TMP_ROOT=$1
rm -rf "$TMP_ROOT"; mkdir -p "$TMP_ROOT"
FAKEBIN="$TMP_ROOT/fakebin"; mkdir -p "$FAKEBIN"
HOME_DIR="$TMP_ROOT/demoship"
MATE="$TMP_ROOT/garden-mate-home"
RUN="$TMP_ROOT/bridge-run"
AGENT_DIR="$TMP_ROOT/launch-agents"
: # FAKEBIN set above
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
# Extra for live driving: a second mate (bakery), and the Bridge's address for Mission Control.
mkdir -p "$TMP_ROOT/beta-mate-home/data" "$TMP_ROOT/beta-mate-home/state"
cp "$MATE/data/backlog.md" "$TMP_ROOT/beta-mate-home/data/backlog.md"
printf -- '- beta-mate - Persistent second mate for the bakery (home: %s; scope: the bakery: orders; projects: bakery; added 2026-09-02)\n' \
  "$TMP_ROOT/beta-mate-home" >> "$HOME_DIR/data/secondmates.md"
echo "HOME_DIR=$HOME_DIR"
