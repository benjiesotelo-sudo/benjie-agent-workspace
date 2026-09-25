#!/usr/bin/env bash
# Builds an isolated Mission Control lab from the Bridge fixtures.
set -eu
W=/Users/benjie/.no-mistakes/worktrees/40995176e50b/01M3CZ3DX88QP0TPZXFHYZ3TPY
FIX=$W/tests/assets/bridge
LAB=$(mktemp -d "${TMPDIR:-/tmp}/mc-team-lab.XXXXXX"); LAB=$(cd "$LAB" && pwd -P)
H=$LAB/home; M=$LAB/alpha-mate-home
mkdir -p $H/data $H/state $H/config $H/projects/alpha $M/data $M/state $LAB/wt-alpha $LAB/wt-beta $LAB/wt-mate $LAB/bin
for r in projects backlog done-archive captain learnings; do cp $FIX/$r.fixture $H/data/$r.md; done
sed "s|@MATE_HOME@|$M|" $FIX/secondmates.fixture > $H/data/secondmates.md
cp $FIX/mate-backlog.fixture $M/data/backlog.md
printf '{"first_mate_name": "Denver"}\n' > $H/config/mission-control.json
meta() { printf 'window=fx:%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=claude\nkind=ship\nmode=direct-PR\nyolo=off\n' "$2" "$2" "$3" "$4" > "$1/state/$2.meta"; }
meta $H a1 $LAB/wt-alpha $H/projects/alpha
meta $H q1 $LAB/wt-beta $H/projects/beta
meta $M m2 $LAB/wt-mate $M/projects/elsewhere
jq -n --arg home "$H" --arg mate "$M" --arg wa "$LAB/wt-alpha" '{result:{type:"agent_list",agents:[
 {pane_id:"w1:p1",agent_status:"working",cwd:$home,foreground_cwd:$home},
 {pane_id:"w2:p1",agent_status:"idle",cwd:$mate},
 {pane_id:"w3:p1",agent_status:"working",cwd:"/somewhere",foreground_cwd:$wa}]}}' > $LAB/agents.json
cat > $LAB/bin/herdr <<'H2'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HERDR_LOG"
[ "$1 $2" = "agent list" ] && exec cat "$DRIVE_AGENTS"
exit 0
H2
chmod +x $LAB/bin/herdr
for t in tmux; do printf '#!/usr/bin/env bash\nexit 1\n' > $LAB/bin/$t; chmod +x $LAB/bin/$t; done
echo $LAB
