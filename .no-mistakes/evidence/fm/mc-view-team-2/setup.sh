#!/usr/bin/env bash
# Build an isolated ship home with a first mate (Denver), three local second
# mates, one remote mate, interns, and a fake herdr that logs every call.
set -eu
ROOT=$1; T=$2
FIX=$ROOT/tests/assets/bridge
H=$T/ship; mkdir -p "$H/data" "$H/state" "$H/config" "$H/projects/alpha" "$T/bin"
for r in projects backlog done-archive captain learnings; do cp "$FIX/$r.fixture" "$H/data/$r.md"; done
printf '{"first_mate_name": "Denver"}\n' > "$H/config/mission-control.json"
{
  echo "# Second mates"; echo
  echo "- course-mate - Persistent second mate for the alpha course. It keeps the decks in order at $T/course/notes.md (home: $T/course; scope: the alpha course, its decks and its quizzes; projects: alpha; added 2026-09-01)"
  echo "- ops-mate - Keeps the build machines tidy (home: $T/ops; scope: the build fleet: runners and caches; projects: beta; added 2026-09-02)"
  echo "- far-mate - Mate on the other box (host: box; root: /srv/far; home: /srv/far/home; scope: the far course: its decks; projects: alpha; added 2026-09-03)"
  echo "- docs-mate - Writes the handbooks (home: $T/docs; scope: the handbooks and guides; projects: alpha, beta; added 2026-09-04)"
} > "$H/data/secondmates.md"
for m in course ops docs; do mkdir -p "$T/$m/data" "$T/$m/state" "$T/wt-$m"; cp "$FIX/mate-backlog.fixture" "$T/$m/data/backlog.md"; done
mkdir -p "$T/wt-alpha" "$T/wt-beta"
meta() { printf 'window=fx:%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=claude\nkind=ship\nmode=direct-PR\nyolo=off\n' "$2" "$2" "$3" "$4" > "$1/state/$2.meta"; }
meta "$H" q1 "$T/wt-beta" "$H/projects/beta"
meta "$T/course" m2 "$T/wt-course" "$T/course/projects/alpha"
jq -n --arg h "$H" --arg c "$T/course" --arg o "$T/ops" --arg d "$T/docs" --arg wb "$T/wt-beta" --arg wc "$T/wt-course" '
 {result:{type:"agent_list",agents:[
  {pane_id:"w1:p1",agent_status:"working",cwd:$h,foreground_cwd:$h},
  {pane_id:"w2:p1",agent_status:"idle",cwd:$c},
  {pane_id:"w3:p1",agent_status:"working",cwd:$o},
  {pane_id:"w4:p1",agent_status:"idle",cwd:$d},
  {pane_id:"w5:p1",agent_status:"working",cwd:"/x",foreground_cwd:$wb},
  {pane_id:"w6:p1",agent_status:"working",cwd:"/x",foreground_cwd:$wc}]}}' > "$T/agents.json"
cat > "$T/bin/herdr" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$T/herdr-calls.log"
[ "\$1 \$2" = "agent list" ] && exec cat "$T/agents.json"
exit 0
EOF
chmod +x "$T/bin/herdr"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/bin/tmux"; chmod +x "$T/bin/tmux"
echo "$H"
