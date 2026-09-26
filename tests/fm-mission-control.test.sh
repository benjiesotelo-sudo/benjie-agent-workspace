#!/usr/bin/env bash
# Behavior tests for Mission Control (bin/fm-mission-control.sh over
# bin/fm_mission_control.py): one-frame snapshots from fixture records and a
# saved `herdr agent list`, asserting desks, working and asleep states, interns
# beside the right person in charge, the second-floor sign at seven mates, the
# inbox count, the task columns, the project cards and the calendar's week,
# month and year (completions, due dates, what always runs, the tappable
# control bar); then the live screen in a
# pseudo-terminal, which must redraw only what changed, pick project cards
# with up/down, and restore the terminal on q and on SIGTERM. The record
# parsers themselves are covered by fm-bridge.test.sh.
# Fixtures are the Bridge's, in tests/assets/bridge/.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MC="$ROOT/bin/fm-mission-control.sh"
FIX="$ROOT/tests/assets/bridge"
TMP_ROOT=$(fm_test_tmproot fm-mission-control)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

HOME_DIR="$TMP_ROOT/homeship"
MATE="$TMP_ROOT/alpha-mate-home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects/alpha" \
  "$MATE/data" "$MATE/state" "$TMP_ROOT/wt-alpha" "$TMP_ROOT/wt-beta" "$TMP_ROOT/wt-mate"
HOME_DIR=$(cd "$HOME_DIR" && pwd)
MATE=$(cd "$MATE" && pwd)
for record in projects backlog done-archive captain learnings; do
  cp "$FIX/$record.fixture" "$HOME_DIR/data/$record.md"
done
sed "s|@MATE_HOME@|$MATE|" "$FIX/secondmates.fixture" > "$HOME_DIR/data/secondmates.md"
cp "$FIX/mate-backlog.fixture" "$MATE/data/backlog.md"
printf '{"first_mate_name": "Denver"}\n' > "$HOME_DIR/config/mission-control.json"

meta() {  # <home> <id> <worktree> <project> [extra lines...]
  local home=$1 id=$2 wt=$3 project=$4
  shift 4
  {
    printf 'window=%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\n' "${WINDOW:-fx:$id}" "$id" "$wt" "$project"
    printf 'harness=claude\nkind=ship\nmode=direct-PR\nyolo=off\n'
    printf '%s\n' "$@"
  } > "$home/state/$id.meta"
}
# An alpha worker in this home belongs beside the alpha mate; a beta worker
# beside the first mate; a worker launched in the mate's own home beside the mate.
meta "$HOME_DIR" a1 "$TMP_ROOT/wt-alpha" "$HOME_DIR/projects/alpha"
meta "$HOME_DIR" q1 "$TMP_ROOT/wt-beta" "$HOME_DIR/projects/beta"
meta "$MATE" m2 "$TMP_ROOT/wt-mate" "$MATE/projects/elsewhere"
for tool in tmux herdr; do
  printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/$tool"
  chmod +x "$FAKEBIN/$tool"
done

AGENTS="$TMP_ROOT/agents.json"
jq -n --arg home "$HOME_DIR" --arg mate "$MATE" --arg wa "$TMP_ROOT/wt-alpha" '
  {result: {type: "agent_list", agents: [
    {pane_id: "w1:p1", agent_status: "working", cwd: $home, foreground_cwd: $home},
    {pane_id: "w2:p1", agent_status: "idle", cwd: $mate},
    {pane_id: "w3:p1", agent_status: "working", cwd: "/somewhere", foreground_cwd: $wa}]}}' > "$AGENTS"

mc() {  # <home> <args...>
  local home=$1
  shift
  PATH="$FAKEBIN:$PATH" FM_HOME="$home" FM_BRIDGE_NOW=2026-09-20T10:00:00 FM_MC_HERDR="$FAKEBIN/herdr" "$MC" "$@"
}

# --- the office ------------------------------------------------------------

J=$(mc "$HOME_DIR" frame --agents "$AGENTS" --format json) || fail "frame --format json failed: $J"
actor() {  # <key> <field>
  jq -r --arg k "$1" --arg f "$2" '.actors[] | select(.key == $k) | .[$f]' <<<"$J"
}
desk() {  # <key> - prints "x y w"
  jq -r --arg k "$1" '.desks[] | select(.key == $k) | "\(.x) \(.y) \(.w)"' <<<"$J"
}

[ "$(desk fm)" = "34 13 21" ] || fail "the first mate's desk is at the top, got $(desk fm)"
[ "$(desk mate:alpha-mate)" = "1 33 13" ] || fail "the mate's desk opens the mate row, got $(desk mate:alpha-mate)"
[ "$(jq -r '.desks | length' <<<"$J")" = 2 ] || fail "one desk each: the first mate and one registered mate"
[ "$(actor fm state)" = work ] || fail "the first mate's pane is working, so it sits working"
[ "$(actor mate:alpha-mate state)" = sleep ] || fail "the mate's pane is idle, so it sleeps"
pass "desks come from the crew and states come from the agent list"

[ "$(actor intern:main:a1 lead)" = mate:alpha-mate ] || fail "an alpha worker's person in charge is the alpha mate"
[ "$(actor intern:main:a1 state)" = work ] || fail "the alpha worker's pane is matched by its worktree and is working"
[ "$(actor intern:main:q1 lead)" = fm ] || fail "a worker on an unowned project stands with the first mate"
[ "$(actor intern:main:q1 state)" = idle ] || fail "a worker with no working pane holds an idle laptop"
[ "$(actor intern:alpha-mate:m2 lead)" = mate:alpha-mate ] || fail "a worker launched in the mate's home is its intern"
slot_x() {  # <key> - expected x beside its lead's desk
  local lead x w slot
  lead=$(actor "$1" lead)
  slot=$(actor "$1" slot)
  read -r x _ w <<<"$(desk "$lead")"
  echo $((x + w + 1 + 7 * slot))
}
for key in intern:main:a1 intern:main:q1 intern:alpha-mate:m2; do
  [ "$(actor "$key" x)" = "$(slot_x "$key")" ] || fail "$key stands beside its person in charge"
done
[ "$(actor intern:main:a1 slot)" != "$(actor intern:alpha-mate:m2 slot)" ] \
  || fail "two interns of one mate take different places"
[ "$(actor intern:main:q1 feet)" = 24 ] && [ "$(actor intern:main:a1 feet)" = 44 ] \
  || fail "interns stand at their lead's desk row"
pass "every worker is an intern beside the right person in charge"

T=$(mc "$HOME_DIR" frame --agents "$AGENTS") || fail "frame text failed"
[ "$(jq -r .inbox <<<"$J")" = 4 ] || fail "the inbox counts what waits on the captain"
grep -q 'inbox 4' <<<"$T" || fail "the inbox label shows the real count"
for word in Denver working asleep; do
  grep -q "$word" <<<"$T" || fail "desk labels name the first mate and say working and asleep: $word"
done
grep -q "Alpha's intern" <<<"$T" || fail "the team list names the intern's person in charge"
grep -q 'projects/alpha' <<<"$T" || fail "the team list shows the project path"
grep -q 'LIVE ACTIVITY' <<<"$T" || fail "the activity column has its heading"
grep -q 'Alpha finished Chapter' <<<"$T" \
  || fail "the activity column starts with this month's completions, each with a verb"
[ "$(jq -r '.team[0].name' <<<"$J")" = Denver ] || fail "config/mission-control.json names the first mate"
grep -q "$TMP_ROOT" <<<"$T" && fail "no raw path may reach the screen"
grep -Eq '\b(a1|q1|m2|d1)\b' <<<"$T" && fail "no task id may reach the screen"
pass "the office text layer: inbox, labels, team list and activity in plain words"

# --- pane matching by recorded Herdr endpoint -----------------------------

WINDOW=default:w9:p4 meta "$HOME_DIR" a1 "$TMP_ROOT/wt-alpha" "$HOME_DIR/projects/alpha" backend=herdr \
  herdr_session=default herdr_pane_id=w9:p4 herdr_workspace_id=w9 herdr_tab_id=w9:t1
jq -n '{result: {agents: [{pane_id: "w9:p4", agent_status: "working", cwd: "/unrelated"}]}}' > "$TMP_ROOT/pane.json"
JP=$(mc "$HOME_DIR" frame --agents "$TMP_ROOT/pane.json" --format json) || fail "frame with a Herdr worker failed"
[ "$(jq -r '.actors[] | select(.key == "intern:main:a1") | .state' <<<"$JP")" = work ] \
  || fail "a worker's recorded Herdr pane matches even when its cwd differs"
[ "$(jq -r '.actors[] | select(.key == "fm") | .state' <<<"$JP")" = sleep ] \
  || fail "a worker's pane never counts as the first mate"
meta "$HOME_DIR" a1 "$TMP_ROOT/wt-alpha" "$HOME_DIR/projects/alpha"
pass "workers match by their recorded Herdr pane"

# --- the task board --------------------------------------------------------

B=$(mc "$HOME_DIR" frame --agents "$AGENTS" --view tasks) || fail "tasks frame failed"
[ "$(jq -c .columns <<<"$J")" = '{"waiting":4,"queued":5,"in_flight":1,"done":3}' ] \
  || fail "task columns count like the Bridge's board, got $(jq -c .columns <<<"$J")"
for stat in '4 waiting on you' '5 queued' '1 in flight' '3 done this month'; do
  grep -q "$stat" <<<"$B" || fail "the stats line carries the four counts: $stat"
done
for head in 'WAITING ON YOU ─4' 'QUEUED ─5' 'IN FLIGHT ─1' 'DONE THIS MONTH ─3'; do
  grep -q " $head" <<<"$B" || fail "column header: $head"
done
grep -q '■ setup' <<<"$B" || fail "the ship's own items carry the setup tag"
grep -q 'oldest decision waiting: 29 Aug' <<<"$B" || fail "the oldest waiting decision is dated"
grep -q 'A body line that the Bridge never shows' <<<"$B" && fail "backlog bodies must never be printed"
pass "the Tasks view shows four columns with the Bridge's counts"

# --- the projects view -----------------------------------------------------

P=$(mc "$HOME_DIR" frame --agents "$AGENTS" --view projects --size 170x50) || fail "projects frame failed"
PJ=$(mc "$HOME_DIR" frame --agents "$AGENTS" --view projects --format json) || fail "projects json failed"
card() {  # <name> <jq path>
  jq -r --arg n "$1" ".projects[] | select(.name == \$n) | $2" <<<"$PJ"
}
[ "$(jq -r '[.projects[].name] | join(",")' <<<"$PJ")" = "alpha,beta,The setup itself" ] \
  || fail "one card per registered project in registry order, the home's own repository folded into the setup card"
grep -Eq '^ 2 projects +1 active +0 parked +1 quiet' <<<"$P" || fail "the header counts projects by status"
[ "$(card alpha .status)" = active ] || fail "a project with a working agent and work in flight is active, even when parked"
[ "$(card beta .status)" = quiet ] || fail "a project with nothing moving is quiet"
[ "$(card alpha .lead)" = Alpha ] || fail "a project a second mate has registered is in its charge"
[ "$(card beta .lead)" = Denver ] || fail "a project no second mate has registered is in the first mate's charge"
[ "$(card "The setup itself" .lead)" = Denver ] || fail "the setup itself is in the first mate's charge"
[ "$(card alpha '.counts | [.waiting, .queued, .in_flight, .done] | join(" ")')" = "2 2 1 2" ] \
  || fail "alpha's four counts come from the Bridge's buckets, got $(card alpha .counts)"
[ "$(card "The setup itself" '.counts | [.waiting, .queued] | join(" ")')" = "1 1" ] \
  || fail "items with no project, and the home's own, count on the setup card"
for want in '│ alpha +Active  │' '│ beta +Quiet  │' '│ The setup itself +Quiet  │' \
  '│ 2 waiting on you +2 queued ' '│ 1 in flight +2 done this month ' '━ 29%  2/7 │' \
  '│ ■ Alpha in charge ' '│ ■ Denver in charge ' '│ Alpha course materials for a class; decks and notes'; do
  grep -Eq "$want" <<<"$P" || fail "a project card shows: $want"
done
grep -q 'octo/alpha-repo' <<<"$P" && fail "the card description leaves out the repository"
grep -q ' WAITING ON YOU FOR ALPHA ' <<<"$P" || fail "the first card is picked and its decisions show underneath"
grep -Eq '^   do +Choose the quiz format +2 Sep *$' <<<"$P" || fail "a picked card lists what waits on the captain"
grep -Eq '^   decide +Decide the chapter five review point +8 Sep *$' <<<"$P" || fail "a held decision reads decide"
grep -q "$TMP_ROOT" <<<"$P" && fail "no raw path may reach the projects view"
grep -Eq '\b(a1|c1|m1|q1|s1)\b' <<<"$P" && fail "no task id may reach the projects view"
grep -q '—' <<<"$P" && fail "the projects view never shows an em dash"

MANY="$TMP_ROOT/manyship"
mkdir -p "$MANY/data" "$MANY/state" "$MANY/config"
cp "$FIX/projects.fixture" "$MANY/data/projects.md"
for n in 1 2 3 4 5 6; do
  echo "- extra$n [local-only] - Extra project number $n (added 2026-09-01)" >> "$MANY/data/projects.md"
done
printf '# Backlog\n\n## In flight\n## Queued\n## Done\n' > "$MANY/data/backlog.md"
PM=$(mc "$MANY" frame --view projects --size 96x36) || fail "many-project frame failed"
grep -Eq '^ 9 projects +0 active +1 parked +8 quiet' <<<"$PM" || fail "the header counts every project"
grep -Eq '│ alpha +Parked  │' <<<"$PM" || fail "a project its registry note parks, with nothing moving, is parked"
grep -Eq '│ homeship +Quiet  │' <<<"$PM" || fail "another home's repository is an ordinary project"
grep -q 'more below' <<<"$PM" || fail "cards past the pane's height are announced"
grep -q 'extra6' <<<"$PM" && fail "a short pane shows only the rows that fit"
grep -q 'Nothing waits on you here.' <<<"$PM" || fail "a picked card with no decisions says so"
PYTHONPATH="$ROOT/bin" FM_BRIDGE_NOW=2026-09-20T10:00:00 PATH="$FAKEBIN:$PATH" \
  python3 - "$MANY" <<'PY' || fail "picking the last card scrolls the grid to it"
import os
import sys
import fm_mission_control as mc
home = os.path.realpath(sys.argv[1])
model = mc.bridge.collect(home, home + "/config", mc.bridge._now())
scene, ui = mc.Scene(), mc.UI()
scene.observe(model, mc.build_crew(model, [], home), 36)
ui.view = "projects"
assert mc._pick_project(ui, scene, down=False) and ui.project == "", ui.project
text = mc.compose(scene, mc.Renderer(), ui, 96, 36, mc.bridge._now())[0].text()
assert "more above" in text and "The setup itself" in text and "WAITING ON YOU FOR THE SETUP ITSELF" in text, text
assert "│ alpha " not in text, text
assert mc._pick_project(ui, scene, down=True) and ui.project == "alpha", ui.project
PY

# A working mate with two registered projects cannot say which one it is on;
# a working mate with one registered project is on that one.
TWO="$TMP_ROOT/twoship"
mkdir -p "$TWO/data" "$TWO/state" "$TWO/config" "$TMP_ROOT/pair/data" "$TMP_ROOT/pair/state" \
  "$TMP_ROOT/solo/data" "$TMP_ROOT/solo/state"
cp "$MANY/data/projects.md" "$MANY/data/backlog.md" "$TWO/data/"
for m in pair solo; do
  printf '# Backlog\n\n## In flight\n## Queued\n## Done\n' > "$TMP_ROOT/$m/data/backlog.md"
done
{
  echo "# Second mates"
  echo "- pair-mate - Two projects (home: $TMP_ROOT/pair; scope: alpha and beta; projects: alpha, beta; added 2026-09-01)"
  echo "- solo-mate - One project (home: $TMP_ROOT/solo; scope: extra one; projects: extra1; added 2026-09-01)"
} > "$TWO/data/secondmates.md"
jq -n --arg pair "$TMP_ROOT/pair" --arg solo "$TMP_ROOT/solo" '{result: {agents: [
  {pane_id: "w1:p1", agent_status: "working", cwd: $pair},
  {pane_id: "w2:p1", agent_status: "working", cwd: $solo}]}}' > "$TMP_ROOT/two.json"
TJ=$(mc "$TWO" frame --agents "$TMP_ROOT/two.json" --view projects --format json) || fail "two-mate json failed"
two() {  # <name> <jq path>
  jq -r --arg n "$1" ".projects[] | select(.name == \$n) | $2" <<<"$TJ"
}
[ "$(two alpha .lead)" = PAIR ] && [ "$(two beta .lead)" = PAIR ] || fail "both projects are in the pair mate's charge"
[ "$(two alpha .status)" = parked ] || fail "a working mate with two projects does not make its parked one active"
[ "$(two beta .status)" = quiet ] || fail "a working mate with two projects does not make its quiet one active"
[ "$(two extra1 .status)" = active ] || fail "a working mate with one project makes that project active"
pass "the Projects view shows one card per project with status, person in charge, counts and decisions"

# --- approvals -------------------------------------------------------------

A=$(mc "$HOME_DIR" frame --agents "$AGENTS" --view approvals) || fail "approvals frame failed"
[ "$(jq -c '[.approvals[].count] | add' <<<"$J")" = "$(jq -r .inbox <<<"$J")" ] \
  || fail "the approvals total equals the office inbox, got $(jq -c .approvals <<<"$J")"
[ "$(jq -c .approvals <<<"$J")" = '[{"name":"Denver","count":3},{"name":"Alpha","count":1}]' ] \
  || fail "one group per agent holding decisions, first mate first, got $(jq -c .approvals <<<"$J")"
grep -q '4 decisions wait on you, with 2 agents' <<<"$A" || fail "the header counts decisions and agents"
grep -q 'oldest since 29 Aug, 22 days ago' <<<"$A" || fail "the header dates the oldest decision"
grep -q '─ Denver 3 ─' <<<"$A" || fail "the first mate's group is named from the settings file, with its count"
grep -q '─ Alpha 1 ─' <<<"$A" || fail "the second mate's group carries its count"
rows=$(grep -E '^ .* days +■ ' <<<"$A")
[ "$(sed -E 's/.*■ ([a-z]+) +(.*)/\1: \2/' <<<"$rows")" = "setup: Tick a profile setting only the captain can reach
alpha: Choose the quiz format
beta: Approve the module outline
alpha: Decide the chapter five review point" ] || fail "rows run oldest first within each agent, with tags, got: $rows"
grep -Eq '^ ▸ +22 days +■ setup +Tick a profile' <<<"$A" || fail "the oldest decision starts highlighted, with its age"
grep -q ' THE DECISION ' <<<"$A" || fail "the detail panel has its heading"
grep -q "asked 29 Aug, 22 days ago, sits with Denver, the ship's own setup" <<<"$A" \
  || fail "the panel says when it was asked and who holds it"
grep -q 'A body line that the Bridge never shows.' <<<"$A" || fail "the panel shows the decision's note"
grep -Eq 'Revisit the venue|Build the quiz once' <<<"$A" && fail "deferred and blocked items are not waiting"
grep -Eq '\b(c1|c2|s1|m1)\b' <<<"$A" && fail "no task id may reach the approvals screen"
grep -q 'answers happen in chat' <<<"$A" || fail "the key line says the view is read only"

LONG="$TMP_ROOT/longship"
mkdir -p "$LONG/data" "$LONG/state" "$LONG/config"
cp "$FIX/projects.fixture" "$LONG/data/projects.md"
{
  printf '# Backlog\n\n## In flight\n## Queued\n'
  printf -- '- [ ] l1 - Decide whether the settings in ~/.config/tool/secret.yml stay'
  for n in 1 2 3 4 5 6 7 8 9; do printf ' and whether option %d is kept for the next module' "$n"; done
  printf ' (kind: captain) (since 2026-09-20)\n'
  printf '  See %s/notes.md for the long story.\n' "$TMP_ROOT"
  printf -- '- [ ] l2 - Pick the second option (kind: task) (since 2026-09-19) (hold: the audit asks) (hold-kind: captain)\n'
  printf '  Origin: l2-audit-origin\n  Decision key: l2-decision-key\n  State: awaiting captain decision.\n## Done\n'
} > "$LONG/data/backlog.md"
AL=$(mc "$LONG" frame --view approvals --size 120x40) || fail "long-title approvals frame failed"
grep -q '2 decisions wait on you, with 1 agent' <<<"$AL" || fail "one agent reads in the singular"
grep -q 'oldest since 19 Sep, 1 day ago' <<<"$AL" || fail "a one-day-old decision is dated"
grep -Eq ' today +■ setup +Decide whether' <<<"$AL" || fail "a decision asked today reads today"
grep -q 'the audit asks' <<<"$AL" || fail "a note of only bookkeeping lines falls back to the hold reason"
grep -Eq 'l2-audit-origin|l2-decision-key|awaiting captain decision' <<<"$AL" \
  && fail "bookkeeping lines never reach the panel"
long=$(grep -A2 ' today  *■ setup  *Decide whether' <<<"$AL")
[ "$(sed -n 2p <<<"$long" | grep -Ec '^ {30,}for the next module .*\.\.\.$')" = 1 ] \
  || fail "a long question wraps to a second line that ends in an ellipsis, got: $long"
[ -z "$(sed -n 3p <<<"$long")" ] || fail "a long question takes at most two lines, got: $long"
grep -q 'a local file' <<<"$AL" || fail "a path in a title or note reads as a local file"
grep -Eq '\.config|secret\.yml|notes\.md' <<<"$AL" && fail "no raw path may reach the approvals screen"
grep -q "$TMP_ROOT" <<<"$AL" && fail "no temporary path may reach the approvals screen"

MANY="$TMP_ROOT/manyship"
mkdir -p "$MANY/data" "$MANY/state" "$MANY/config"
cp "$FIX/projects.fixture" "$MANY/data/projects.md"
{
  printf '# Backlog\n\n## In flight\n## Queued\n'
  for n in $(seq 10 39); do printf -- '- [ ] q%d - Settle question number %d (kind: captain) (since 2026-08-%02d)\n' "$n" "$n" "$((n - 9))"; done
  printf '## Done\n'
} > "$MANY/data/backlog.md"
AM=$(mc "$MANY" frame --view approvals) || fail "many-decision approvals frame failed"
grep -Eq '^┌─ THE DECISION ─+ 3 more below ─┐$' <<<"$AM" \
  || fail "the decisions past the fold are counted on the panel's top border, got: $(grep 'THE DECISION' <<<"$AM")"
[ "$(grep -c 'Settle question number' <<<"$AM")" = 28 ] || fail "27 list rows and the panel title show in full"
[ "$(grep -c 'more below' <<<"$AM")" = 1 ] || fail "no list row carries the more-below label"
{
  printf '# Backlog\n\n## In flight\n## Queued\n'
  for n in $(seq 10 35); do printf -- '- [ ] q%d - Settle question number %d (kind: captain) (since 2026-08-%02d)\n' "$n" "$n" "$((n - 9))"; done
  printf -- '- [ ] q99 - Settle the last question, which runs long enough that its words wrap onto a second line of the list (kind: captain) (since 2026-08-30)\n'
  printf '## Done\n'
} > "$MANY/data/backlog.md"
AM=$(mc "$MANY" frame --view approvals) || fail "cut-decision approvals frame failed"
grep -q 'Settle the last question' <<<"$AM" || fail "the last decision starts on the bottom list row"
grep -q 'more below' <<<"$AM" && fail "a decision whose first line shows is not counted below the fold"

pass "the Approvals view groups what waits on the captain by agent, oldest first, in plain words"

L=$(mc "$HOME_DIR" frame --agents "$AGENTS" --view system)
grep -q 'System is coming next' <<<"$L" || fail "a later view shows its coming-next note"
grep -q ' 9 System ' <<<"$L" || fail "the tab bar shows all nine views"
S=$(mc "$HOME_DIR" frame --agents "$AGENTS" --size 80x24)
[ "$(printf '%s\n' "$S" | grep -c .)" = 1 ] || fail "a too-small pane gets exactly one line"
grep -q 'Make this pane bigger' <<<"$S" || fail "a too-small pane asks for more room"
pass "later views and a too-small pane each get one line"

# --- the calendar ----------------------------------------------------------

# A week from Sunday 20 to Saturday 26 September, seen on Wednesday 23.
CAL="$TMP_ROOT/calship"
mkdir -p "$CAL/data" "$CAL/state" "$CAL/config"
cp "$HOME_DIR/data/projects.md" "$HOME_DIR/data/secondmates.md" "$CAL/data/"
cat > "$CAL/data/backlog.md" <<'MD'
# Backlog

## In flight
## Queued
- [ ] h1 - Book the lecture room (repo: beta) (kind: task) (since 2026-09-10) (hold: after the dean replies) (hold-kind: future) (hold-until: 2026-09-25)
- [ ] t1 - Send the grades by Saturday 26 September (repo: alpha) (kind: task) (since 2026-09-11)
- [ ] t2 - Hand in the marks on Sunday 27 September (repo: beta) (kind: task) (since 2026-09-11)
- [ ] t3 - Review the syllabus Friday 27 September (repo: beta) (kind: task) (since 2026-09-11)
- [ ] t4 - Compare the 24 September and 25 September drafts (repo: beta) (kind: task) (since 2026-09-11)
- [ ] t5 - Plan the 25/09 staff meeting (repo: beta) (kind: task) (since 2026-09-11)
- [ ] t6 - Recap of the 21 September session (repo: beta) (kind: task) (since 2026-09-11)
- [ ] t7 - Due Sat 26 Sep the seminar notes (repo: beta) (kind: task) (since 2026-09-11)
- [ ] t8 - Print the 25th September handouts (repo: beta) (kind: task) (since 2026-09-11)
- [ ] t9 - Ask Jan 3 questions (repo: beta) (kind: task) (since 2026-09-11)
- [ ] t10 - Rota for Fri 24 September (repo: beta) (kind: task) (since 2026-09-11)
- [ ] t11 - Lab check Mon September 25 (repo: beta) (kind: task) (since 2026-09-11)
## Done
- [x] w1 - Chapter five slides (repo: alpha) (kind: ship) (merged 2026-09-21)
- [x] w2 - Tidy the ship's scripts (kind: task) (done 2026-09-23)
- [x] w3 - Wrap the September module (repo: beta) (kind: ship) (done 2026-09-30)
- [x] w4 - An older handout (repo: beta) (kind: ship) (done 2026-09-12)
- [x] b1 - Busy day beta one (repo: beta) (kind: ship) (done 2026-09-15)
- [x] b2 - Busy day beta two (repo: beta) (kind: ship) (done 2026-09-15)
- [x] b3 - Busy day beta three (repo: beta) (kind: ship) (done 2026-09-15)
- [x] b4 - Busy day beta four (repo: beta) (kind: ship) (done 2026-09-15)
- [x] b5 - Busy day beta five (repo: beta) (kind: ship) (done 2026-09-15)
- [x] b6 - Busy day alpha one (repo: alpha) (kind: ship) (done 2026-09-15)
- [x] b7 - Busy day alpha two (repo: alpha) (kind: ship) (done 2026-09-15)
- [x] b8 - Busy day alpha three (repo: alpha) (kind: ship) (done 2026-09-15)
MD
cat > "$FAKEBIN/launchctl" <<SH
#!/usr/bin/env bash
[ -e "$TMP_ROOT/bridge-up" ] || exit 113
printf 'gui/501/com.firstmate.bridge = {\n\tstate = running\n}\n'
SH
chmod +x "$FAKEBIN/launchctl"
touch "$TMP_ROOT/bridge-up"
cal() {  # <now> <size> [keys] [format]
  PATH="$FAKEBIN:$PATH" FM_HOME="$CAL" FM_BRIDGE_NOW="$1" "$MC" frame --agents "$AGENTS" --view calendar \
    --size "$2" --keys "${3:-}" --format "${4:-text}"
}
day_of() {  # <frame text> <needle> - prints the day heading above the column holding <needle>
  python3 - "$1" "$2" <<'PY'
import re, sys
lines = sys.argv[1].split("\n")
day = r"\b(?:Sun|Mon|Tue|Wed|Thu|Fri|Sat) \d{1,2}(?![\d:])"
head = next(ln for ln in lines if re.search(day, ln))
starts = [(m.start(), m.group(0)) for m in re.finditer(day, head)]
hit = next((ln.index(sys.argv[2]) for ln in lines if sys.argv[2] in ln), None)
print("" if hit is None else [name for c, name in starts if c <= hit][-1])
PY
}
# Week is the third mode: v goes Month, Year, Week.
K=$(cal 2026-09-23T10:00:00 170x50 vv) || fail "calendar frame failed: $K"
grep -Eq '◂ +20 to 26 September +▸' <<<"$K" || fail "the calendar heads its week between the arrows"
grep -q ' this week ' <<<"$K" || fail "the calendar says it shows this week"
for d in 'Sun 20' 'Mon 21' 'Tue 22' 'Wed 23' 'Thu 24' 'Fri 25' 'Sat 26'; do
  grep -q "$d" <<<"$K" || fail "a wide pane shows the whole week: $d"
done
[ "$(day_of "$K" ' today ')" = 'Wed 23' ] || fail "today's column is marked today"
[ "$(day_of "$K" 'Chapter five')" = 'Mon 21' ] || fail "a past completion sits on its day"
[ "$(day_of "$K" 'Tidy the ship')" = 'Wed 23' ] || fail "today's completion sits on today"
[ "$(day_of "$K" 'Book the lecture')" = 'Fri 25' ] || fail "a hold-until date makes an item due that day"
[ "$(day_of "$K" 'Send the grades')" = 'Sat 26' ] || fail "a date written in a title makes it due that day"
grep -q '─ due ┐' <<<"$K" || fail "scheduled items are marked due"
grep -q '─ done ┐' <<<"$K" || fail "completions are marked done"
grep -q '┌ alpha ' <<<"$K" || fail "blocks carry their project tag"
grep -q '┌ setup ' <<<"$K" || fail "the ship's own items carry the setup tag"
for skip in 'Review the syllabus' 'Compare the' 'staff meeting' 'Recap of' 'Due Sat' 'Print the' 'Ask Jan' \
    'Rota for' 'Lab check' 'An older handout' 'Wrap the'; do
  grep -q "$skip" <<<"$K" && fail "a guessed, past or other-week date stays off the grid: $skip"
done
grep -q '2 done, 2 due' <<<"$K" || fail "the control bar counts the week's blocks"
grep -q 'Busy day' <<<"$K" && fail "another week's completions stay off the week"
grep -q 'ALWAYS RUNNING' <<<"$K" || fail "the always-running strip has its heading"
for chip in '● Bridge running' '● Mission Control off' '● Alpha asleep'; do
  grep -q "$chip" <<<"$K" || fail "the always-running strip reads the real state: $chip"
done
grep -Eq '\b(h1|t[1-9]|t1[01]|w[1-4])\b' <<<"$K" && fail "no task id may reach the calendar"
grep -q "$TMP_ROOT" <<<"$K" && fail "no raw path may reach the calendar"
# Without a saved list, frame asks Herdr itself: a live mate window is asleep,
# and with Herdr silent a mate is unknown rather than closed.
cat > "$FAKEBIN/herdr-cal" <<SH
#!/usr/bin/env bash
[ -e "$TMP_ROOT/herdr-cal-down" ] && exit 1
[ "\$1 \$2" = "agent list" ] && exec cat "$AGENTS"
exit 1
SH
chmod +x "$FAKEBIN/herdr-cal"
herdr_cal() {
  PATH="$FAKEBIN:$PATH" FM_HOME="$CAL" FM_BRIDGE_NOW=2026-09-23T10:00:00 FM_MC_HERDR="$FAKEBIN/herdr-cal" \
    "$MC" frame --view calendar --size 170x50
}
K=$(herdr_cal) || fail "calendar frame without a saved agent list failed: $K"
grep -q '● Alpha asleep' <<<"$K" || fail "frame reads a live mate window from Herdr"
touch "$TMP_ROOT/herdr-cal-down"
K=$(herdr_cal) || fail "calendar frame with Herdr silent failed: $K"
rm -f "$TMP_ROOT/herdr-cal-down"
grep -q '● Alpha unknown' <<<"$K" || fail "with Herdr silent a mate's window is unknown"
grep -q 'Alpha closed' <<<"$K" && fail "with Herdr silent no mate is called closed"
rm -f "$TMP_ROOT/bridge-up"
K=$(cal 2026-10-01T10:00:00 170x50 vv) || fail "calendar frame failed: $K"
grep -q '27 September to 3 October' <<<"$K" || fail "a week across two months names both"
[ "$(day_of "$K" 'Wrap the')" = 'Wed 30' ] || fail "last month's completions still show"
grep -q '● Bridge off' <<<"$K" || fail "a Bridge with no LaunchAgent is off"
K=$(cal 2026-09-23T10:00:00 96x40 vv) || fail "narrow calendar frame failed: $K"
grep -q 'Tue 22' <<<"$K" && fail "a narrow pane starts at today"
[ "$(day_of "$K" 'Hand in the')" = 'Sun 27' ] || fail "a narrow pane shows today and the next few days"
pass "the Calendar shows the week's completions, due dates and what always runs"

# Month (the first mode) and Year, their control bar, and moving with keys and taps.
PATH="$FAKEBIN:$PATH" FM_HOME="$CAL" python3 - "$MC" "$AGENTS" <<'PY' || fail "the Calendar's Month and Year read like real calendars"
import os, re, subprocess, sys
MC, AGENTS = sys.argv[1:]
INK, DIM, DIMMER, GREEN = (0xd9, 0xe0, 0xe8), (0x7f, 0x89, 0x95), (0x5d, 0x67, 0x73), (0x35, 0xd0, 0x7f)
ALPHA = (0x3f, 0xb6, 0xc9)   # the alpha mate's colour, worn by its project


def frame(size, keys="", fmt="text", now="2026-09-23T10:00:00"):
    env = dict(os.environ, FM_BRIDGE_NOW=now)
    return subprocess.run([MC, "frame", "--agents", AGENTS, "--view", "calendar", "--size", size,
                           "--keys", keys, "--format", fmt], env=env, check=True,
                          capture_output=True, text=True).stdout


def cells(ansi):
    """[(char, fg, bg)] per row of an ansi frame."""
    rows = []
    for line in ansi.split("\n"):
        row, fg, bg = [], INK, None
        for m in re.finditer(r"\x1b\[([0-9;]*)m|([^\x1b])", line):
            if m.group(2) is not None:
                row.append((m.group(2), fg, bg))
                continue
            a = [int(x) for x in m.group(1).split(";") if x]
            if len(a) == 11:
                fg, bg = tuple(a[3:6]), tuple(a[8:11])
        rows.append(row)
    return rows


def weeks(text):
    """Each week row of the Month grid: (line index, [(day label, first col, last col)])."""
    out = []
    for i, ln in enumerate(text.split("\n")):
        if i > 8 and ln.startswith(("┌", "├")):
            seps = [j for j, ch in enumerate(ln) if ch in "┌┬┼├┐┤"]
            row = []
            for a, b in zip(seps, seps[1:]):
                m = re.match(r" (\d+(?: [A-Z][a-z]{2})?) ", ln[a + 1:b])
                row.append((m.group(1) if m else None, a, b))
            out.append((i, row))
    return out


def labels(text):
    return [lab for _, row in weeks(text) for lab, _, _ in row]


def cells_of(text, needle):
    """The days whose cells show needle."""
    out = set()
    for i, ln in enumerate(text.split("\n")):
        for m in re.finditer(re.escape(needle), ln):
            _, row = [w for w in weeks(text) if w[0] < i][-1]
            out |= {lab for lab, a, b in row if a < m.start() < b}
    return out


def color_of(text, ansi, label, occurrence=0):
    """fg and bg of a day number on the Month grid's border rows."""
    hits = [(i, a) for i, row in weeks(text) for lab, a, _ in row if lab == label]
    i, a = hits[occurrence]
    return cells(ansi)[i][a + 2][1:]


def tap(text, needle, nth=0, dx=1):
    lines = text.split("\n")
    found = [(i, m.start()) for i, ln in enumerate(lines) for m in re.finditer(re.escape(needle), ln)]
    i, j = found[nth]
    return "\x1b[<0;%d;%dM" % (j + 1 + dx, i + 1)


def bar(text):
    return text.split("\n")[3]


for size, lines in (("170x50", 6), ("132x44", 5), ("96x36", 3)):
    T = frame(size)
    assert re.search(r"Week │ Month │ Year +◂ +September 2026 +▸ +this month", bar(T)), (size, bar(T))
    want = ["30", "31"] + [str(d) for d in range(1, 31)] + ["1 Oct", "2", "3"]
    assert labels(T) == want, (size, labels(T))
    assert all(len(row) == 7 for _, row in weeks(T)), size
    # A narrow pane shortens item lines to a few letters but keeps every day.
    n = {"170x50": 14, "132x44": 10, "96x36": 4}[size]
    for needle, day in (("Chapter five slides", "21"), ("Tidy the ship's", "23"), ("Book the lecture", "25"),
                        ("Send the grades", "26"), ("Hand in the marks", "27"), ("Wrap the September", "30")):
        assert day in cells_of(T, needle[:n]), (size, needle)
    assert cells_of(T, "+%d more" % (8 - (lines - 1))) == {"15"}, (size, T)
    assert "left/right earlier or later   t today   v week, month or year" in T, size
    assert not re.search(r"\b(h1|t[1-9]|t1[01]|w[1-4]|b[1-8])\b", T), size
A = frame("132x44", fmt="ansi")
T = frame("132x44")
assert color_of(T, A, "30") == (DIMMER, (0x0c, 0x0e, 0x12)), color_of(T, A, "30")
assert color_of(T, A, "1 Oct")[0] == DIMMER
assert color_of(T, A, "1")[0] == INK and color_of(T, A, "29")[0] == INK
assert color_of(T, A, "23") == ((0x0c, 0x0e, 0x12), GREEN), color_of(T, A, "23")
assert re.search(r"┼ 23 today ─", T), T
row = cells(A)[3]
seg = "".join(c for c, _, _ in row)
k = seg.index(" Month ")
assert row[k + 1][2] == GREEN and row[seg.index(" Week ") + 1][2] != GREEN, "the active mode is lit"
# A done item wears its project's colour, dimmed; a due item is bright.
i = next(i for i, ln in enumerate(T.split("\n")) if "Chapter fi" in ln)
j = T.split("\n")[i].index("Chapter fi")
fg = cells(A)[i][j][1]
assert fg != INK and fg[2] > fg[0], fg
i = next(i for i, ln in enumerate(T.split("\n")) if "Send the g" in ln)
j = T.split("\n")[i].index("Send the g")
assert cells(A)[i][j - 2][0] == "●" and cells(A)[i][j - 2][1] == (0xff, 0xb4, 0x54), "due items are marked"

# February 2026 fills five rows; August 2026 needs six.
T = frame("132x44", "\x1b[D" * 7)
assert "February 2026" in bar(T) and "7 months ago" in bar(T) and "back to today" in bar(T), bar(T)
assert labels(T) == [str(d) for d in range(1, 29)] + ["1 Mar"] + [str(d) for d in range(2, 8)], labels(T)
T = frame("132x44", "\x1b[D")
assert "August 2026" in bar(T) and "last month" in bar(T), bar(T)
assert labels(T) == ["26", "27", "28", "29", "30", "31"] + [str(d) for d in range(1, 32)] + \
    ["1 Sep", "2", "3", "4", "5"], labels(T)
assert len(weeks(T)) == 6, "six week rows"

# Year: twelve months, days with items in their project's colour, today lit.
T, A = frame("170x50", "v"), frame("170x50", "v", "ansi")
assert re.search(r"Week │ Month │ Year +◂ +2026 +▸ +this year", bar(T)), bar(T)
months = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
          "October", "November", "December"]
lines = T.split("\n")
for mname in months:
    assert sum(ln.count(mname) for ln in lines) == 1 + (mname in bar(T)), mname
grid = cells(A)


def year_day(mname, day):
    ti, tj = next((i, ln.index(mname)) for i, ln in enumerate(lines) if mname in ln and i > 5)
    nexts = [m.start() for m in re.finditer(r"[A-Z][a-z]+", lines[ti]) if m.start() > tj]
    end = nexts[0] if nexts else len(lines[ti]) + 40
    for i in range(ti + 2, ti + 8):
        for m in re.finditer(r"(?<!\d)%d(?!\d)" % day, lines[i][:end]):
            if m.start() >= tj - 2:
                return grid[i][m.start()][1:]
    raise AssertionError((mname, day))


assert year_day("September", 21)[0] == ALPHA, year_day("September", 21)
beta = year_day("September", 25)[0]
assert beta not in (ALPHA, DIM, INK), beta
assert year_day("September", 15)[0] == beta, "a day takes the colour of its busiest project"
assert year_day("September", 23)[1] == GREEN, "today is lit"
assert year_day("September", 22)[0] == DIM and year_day("March", 3)[0] == DIM, "a quiet day is plain"
seg = "".join(c for c, _, _ in grid[3])
assert grid[3][seg.index("■ beta")][1] == beta and grid[3][seg.index("■ alpha")][1] == ALPHA, "the legend names colours"
assert re.search(r"September +13 done, 3 due", T) and "13 done, 3 due" in bar(T), T
for size in ("132x44", "96x36"):
    Y = frame(size, "v")
    assert all(m in Y for m in months), (size, Y)

# Keys: left and right move one period in each mode, t comes back, v cycles.
assert "October 2026" in bar(frame("132x44", "\x1b[C")) and "next month" in bar(frame("132x44", "\x1b[C"))
assert "this month" in bar(frame("132x44", "\x1b[C\x1b[Ct"))
assert "2027" in bar(frame("132x44", "v\x1b[C")) and "next year" in bar(frame("132x44", "v\x1b[C"))
assert re.search(r"13 to 19 September +▸ +last week", bar(frame("132x44", "vv\x1b[D")))
assert re.search(r"◂ +September 2026 +▸ +this month", bar(frame("132x44", "vvv")))
assert re.search(r"◂ +September 2027 +▸", bar(frame("132x44", "v\x1b[Cvv"))), "Year to Week to Month keeps the period"
N = bar(frame("96x36", "\x1b[Cvv", now="2026-09-26T10:00:00"))
assert "next week" in N and "back to today" in N, "a narrow week starting after today's week is next week"
N = bar(frame("96x36", "\x1b[Cvv\x1b[D", now="2026-09-26T10:00:00"))
assert "this week" in N and "back to today" not in N, N

# Taps: every change is on the control bar, and a month in Year opens it.
T = frame("132x44")
assert re.search(r"◂ +2026 +▸", bar(frame("132x44", tap(T, " Year ")))), "tapping Year"
assert re.search(r"20 to 26 September", bar(frame("132x44", tap(T, " Week ")))), "tapping Week"
assert "August 2026" in bar(frame("132x44", tap(T, " ◂ "))), "tapping the left arrow"
assert "October 2026" in bar(frame("132x44", tap(T, " ▸ "))), "tapping the right arrow"
L = frame("132x44", "\x1b[D\x1b[D")
assert "July 2026" in bar(L)
assert "this month" in bar(frame("132x44", "\x1b[D\x1b[D" + tap(L, " back to today "))), "tapping back to today"
assert "July 2026" in bar(frame("132x44", "\x1b[D\x1b[D" + tap(L, " 2 months ago "))), "the relative label is not a button"
Y = frame("132x44", "v")
F = frame("132x44", "v" + tap(Y, "February", dx=3))
assert re.search(r"Month │ Year +◂ +February 2026 +▸", bar(F)), bar(F)
assert labels(F)[0] == "1", labels(F)
PY
pass "Month and Year show whole months, marked days and today, and every control works by key and by tap"

# --- seven mates: a second floor ------------------------------------------

BIG="$TMP_ROOT/bigship"
mkdir -p "$BIG/data" "$BIG/state" "$BIG/config"
cp "$FIX/projects.fixture" "$BIG/data/projects.md"
printf '# Backlog\n\n## In flight\n## Queued\n## Done\n' > "$BIG/data/backlog.md"
{
  echo "# Second mates"
  for n in 1 2 3 4 5 6 7; do
    mkdir -p "$TMP_ROOT/m$n/data" "$TMP_ROOT/m$n/state"
    printf '# Backlog\n\n## In flight\n## Queued\n## Done\n' > "$TMP_ROOT/m$n/data/backlog.md"
    echo "- m$n-mate - Mate number $n (home: $TMP_ROOT/m$n; scope: area $n; projects: p$n; added 2026-09-01)"
  done
} > "$BIG/data/secondmates.md"
jq -n --arg m7 "$TMP_ROOT/m7" '{result: {agents: [{pane_id: "w7:p1", agent_status: "working", cwd: $m7}]}}' \
  > "$TMP_ROOT/big.json"
J7=$(mc "$BIG" frame --agents "$TMP_ROOT/big.json" --size 132x60 --format json) || fail "seven-mate frame failed"
[ "$(jq -r '.desks | length' <<<"$J7")" = 7 ] || fail "a tall pane holds six mate desks plus the first mate's"
[ "$(jq -r '.upstairs.count' <<<"$J7")" = 1 ] || fail "the seventh mate works upstairs"
[ "$(jq -r '.desks | map(.key) | index("mate:m7-mate") != null' <<<"$J7")" = true ] \
  || fail "the busiest mate stays downstairs"
[ "$(jq -r '.room_height' <<<"$J7")" = 84 ] || fail "two rows of mate desks make a taller room"
T7=$(mc "$BIG" frame --agents "$TMP_ROOT/big.json" --size 132x60) || fail "seven-mate text failed"
grep -q '1 upstairs, 0 working' <<<"$T7" || fail "the second-floor sign counts who is upstairs"
J3=$(mc "$BIG" frame --agents "$TMP_ROOT/big.json" --size 132x44 --format json)
[ "$(jq -r '.upstairs.count' <<<"$J3")" = 4 ] || fail "a shorter pane keeps three downstairs and sends four up"
[ "$(jq -r '.team[0].name' <<<"$J3")" = "First mate" ] || fail "without the settings file the first mate is First mate"
pass "seven mates open a second floor with a sign, busiest downstairs"

AE=$(mc "$BIG" frame --agents "$TMP_ROOT/big.json" --view approvals) || fail "empty approvals frame failed"
grep -q 'Nothing waits on you.' <<<"$AE" || fail "with nothing waiting the view is a calm empty state"
grep -q 'THE DECISION' <<<"$AE" && fail "an empty approvals view has no detail panel"
pass "the Approvals view is calm when nothing waits on the captain"

# --- the live screen in a pseudo-terminal ----------------------------------

cat > "$FAKEBIN/herdr-list" <<SH
#!/usr/bin/env bash
[ -e "$TMP_ROOT/herdr-down" ] && exit 1
[ "\$1 \$2" = "agent list" ] && exec cat "\$DRIVE_AGENTS"
exit 0
SH
chmod +x "$FAKEBIN/herdr-list"
drive() {  # <out-prefix> <actions> - runs the screen at 132x44; actions: "<seconds>=<keys|TERM>,..."
  # Writes <out-prefix>.raw (every byte written) and <out-prefix>.screens (the
  # emulated screen text just before each action), and prints the exit code.
  # DRIVE_HOME, DRIVE_AGENTS and DRIVE_ROWS replace the home, the agent list and the height;
  # DRIVE_NOW pins the Bridge clock for that run, else the real clock dates things.
  PATH="$FAKEBIN:$PATH" FM_HOME="${DRIVE_HOME:-$HOME_DIR}" DRIVE_AGENTS="${DRIVE_AGENTS:-$AGENTS}" \
    FM_MC_HERDR="$FAKEBIN/herdr-list" FM_MC_COLORS=truecolor ${DRIVE_NOW:+env FM_BRIDGE_NOW=$DRIVE_NOW} python3 - "$MC" "$1" "$2" "${DRIVE_ROWS:-44}" <<'PY'
import os, pty, re, sys, struct, fcntl, termios, time, select, signal
mc, prefix, actions, rows = sys.argv[1:]
plan = sorted((float(t), a) for t, a in (x.split("=", 1) for x in actions.split(",")))
COLS, ROWS = 132, int(rows)
grid = [[" "] * COLS for _ in range(ROWS)]
pos = [0, 0]
tok = re.compile(r"\x1b\[([0-9;?]*)([A-Za-z])|\x1b.|[\s\S]")


def feed(text):
    for m in tok.finditer(text):
        t = m.group(0)
        if m.group(2) == "H":
            a = m.group(1).split(";") + ["1", "1"]
            pos[:] = [int(a[0] or 1) - 1, int(a[1] or 1) - 1]
        elif m.group(2) == "J":
            for row in grid:
                row[:] = [" "] * COLS
        elif not t.startswith("\x1b") and t not in "\r\n":
            if 0 <= pos[0] < ROWS and 0 <= pos[1] < COLS:
                grid[pos[0]][pos[1]] = t
            pos[1] += 1


pid, fd = pty.fork()
if pid == 0:
    os.execvp(mc, [mc, "run"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
os.kill(pid, signal.SIGWINCH)
raw, marks, t0, done = bytearray(), [], time.time(), None
while time.time() - t0 < 20:
    r, _, _ = select.select([fd], [], [], 0.05)
    if r:
        try:
            chunk = os.read(fd, 1 << 16)
        except OSError:
            chunk = b""
        if not chunk:
            break
        raw += chunk
    while plan and plan[0][0] <= time.time() - t0:
        # SH:<command> waits until the office has been drawn once.
        if plan[0][1].startswith("SH:") and b"ACTIVITY" not in raw:
            break
        _, act = plan.pop(0)
        marks.append(len(raw))
        if act == "TERM":
            os.kill(pid, signal.SIGTERM)
        elif act.startswith("SH:"):
            os.system(act[3:])
        else:
            os.write(fd, act.encode())
    got, status = os.waitpid(pid, os.WNOHANG)
    if got:
        done = status
        break
if done is None:
    os.kill(pid, signal.SIGKILL)
    _, done = os.waitpid(pid, 0)
open(prefix + ".raw", "wb").write(bytes(raw))
screens = []
for mark in marks:
    for row in grid:
        row[:] = [" "] * COLS
    feed(bytes(raw[:mark]).decode("utf-8", "replace"))
    screens.append("\n".join("".join(row) for row in grid))
open(prefix + ".screens", "w").write("\n=====\n".join(screens) + "\n")
print(os.WEXITSTATUS(done) if os.WIFEXITED(done) else 128 + os.WTERMSIG(done))
PY
}
screen() {  # <prefix> <n> - the emulated screen before action n (1-based)
  awk -v n="$2" 'BEGIN { k = 1 } /^=====$/ { k++; next } k == n' "$1.screens"
}
RESTORE=$'\e[0m\e[?1000l\e[?1006l\e[?7h\e[?25h\e[?1049l'
# Over the "2 Tasks" tab: a wheel scroll is not a tap, a left press is.
WHEEL=$'\e[<64;31;1M'
TAP=$'\e[<0;31;1M'
code=$(drive "$TMP_ROOT/q" "4=$WHEEL,4.5=2,5.5=1,6=$TAP,7=1,7.5=p,9=q") || fail "the pty driver failed"
[ "$code" = 0 ] || fail "q quits cleanly, got exit $code"
grep -q $'\e\\[?1049h' "$TMP_ROOT/q.raw" || fail "the screen enters the alternate screen"
grep -q $'\e\\[?1006h' "$TMP_ROOT/q.raw" || fail "the screen asks for SGR mouse reporting"
[ "$(tail -c ${#RESTORE} "$TMP_ROOT/q.raw")" = "$RESTORE" ] || fail "q restores the terminal last"
screen "$TMP_ROOT/q" 1 | grep -q 'LIVE ACTIVITY' || fail "the office is drawn live"
screen "$TMP_ROOT/q" 1 | grep -q 'inbox 4' || fail "the live office shows the inbox count"
screen "$TMP_ROOT/q" 2 | grep -q 'LIVE ACTIVITY' || fail "a wheel scroll over a tab does not switch views"
screen "$TMP_ROOT/q" 3 | grep -q 'WAITING ON YOU' || fail "key 2 switches to the task board"
screen "$TMP_ROOT/q" 4 | grep -q 'LIVE ACTIVITY' || fail "key 1 switches back to the office"
screen "$TMP_ROOT/q" 5 | grep -q 'WAITING ON YOU' || fail "tapping a tab switches to it"
screen "$TMP_ROOT/q" 7 | grep -q ' PAUSED ' || fail "p pauses the animation"
python3 - "$TMP_ROOT/q.raw" <<'PY' || fail "a paused screen writes almost nothing"
import sys
data = open(sys.argv[1], "rb").read()
i = data.rfind(b"PAUSED")
j = data.rfind(b"\x1b[0m\x1b[?1000l")
# Between the pause banner and the exit, at most the clock changes.
sys.exit(0 if 0 <= i < j and j - i < 400 else 1)
PY
# Up and down move the Approvals highlight; Enter answers nothing.
UP=$'\e[A'
DOWN=$'\e[B'
ENTER=$'\r'
code=$(DRIVE_NOW=2026-09-20T10:00:00 drive "$TMP_ROOT/ap" "4=3,5=$DOWN,6=$DOWN$DOWN$DOWN,7=$UP,8=$ENTER,9=q") || fail "the pty driver failed"
[ "$code" = 0 ] || fail "the approvals run quits cleanly, got exit $code"
screen "$TMP_ROOT/ap" 2 | grep -q 'sits with Denver, the ship' || fail "key 3 opens Approvals on the oldest decision"
screen "$TMP_ROOT/ap" 3 | grep -Eq '^ ▸ .*Choose the quiz format' || fail "down highlights the next decision"
screen "$TMP_ROOT/ap" 3 | grep -q 'asked 2 Sep, 18 days ago, sits with Denver, project alpha' \
  || fail "the panel follows the highlight"
screen "$TMP_ROOT/ap" 4 | grep -q 'sits with Alpha, project alpha' || fail "down crosses into the next agent and stops at the end"
screen "$TMP_ROOT/ap" 5 | grep -Eq '^ ▸ .*Approve the module outline' || fail "up moves back"
screen "$TMP_ROOT/ap" 6 | grep -Eq '^ ▸ .*Approve the module outline' || fail "enter leaves the view and the pick alone"
screen "$TMP_ROOT/ap" 6 | grep -q 'moving your view' && fail "enter on Approvals moves no pane"
pass "up and down read each decision on the live Approvals view, and no key acts on one"

# A captain item filed while the screen runs reads "<name> asks you <title>".
cp "$HOME_DIR/data/backlog.md" "$TMP_ROOT/backlog.saved"
cat > "$TMP_ROOT/file-ask.sh" <<SH
#!/usr/bin/env bash
sed '/^## Done/i\\
- [ ] c9 - Pick the deck colour (kind: captain) (since 2026-09-19)
' "$TMP_ROOT/backlog.saved" > "$HOME_DIR/data/backlog.md"
SH
code=$(drive "$TMP_ROOT/term" "1=SH:bash $TMP_ROOT/file-ask.sh,12=TERM") || fail "the pty driver failed"
cp "$TMP_ROOT/backlog.saved" "$HOME_DIR/data/backlog.md"
[ "$(tail -c ${#RESTORE} "$TMP_ROOT/term.raw")" = "$RESTORE" ] || fail "SIGTERM restores the terminal"
screen "$TMP_ROOT/term" 2 | grep -q 'Denver asks you Pick' || fail "a newly filed captain item reads as the owner asking you"
pass "the live screen switches views, quits on q and SIGTERM, and restores the terminal"

UP=$'\e[A'
DOWN=$'\e[B'
code=$(drive "$TMP_ROOT/pick" "4=4,5=$DOWN,6=$UP$UP,7=q") || fail "the pty driver failed"
[ "$code" = 0 ] || fail "the projects run quits cleanly, got exit $code"
screen "$TMP_ROOT/pick" 2 | grep -q 'WAITING ON YOU FOR ALPHA' || fail "key 4 opens the projects with the first card picked"
screen "$TMP_ROOT/pick" 3 | grep -q 'WAITING ON YOU FOR BETA' || fail "down picks the next card"
screen "$TMP_ROOT/pick" 3 | grep -q 'Approve the module outline' || fail "the picked card's decisions show underneath"
screen "$TMP_ROOT/pick" 4 | grep -q 'WAITING ON YOU FOR THE SETUP ITSELF' || fail "up from the first card wraps to the last"
screen "$TMP_ROOT/pick" 4 | grep -q 'LIVE ACTIVITY' && fail "up/down on the projects stays on the projects"
pass "up and down pick a project card on the live screen"

# A second mate home that cannot be read for a while invents no events.
BACKLOG_M="$MATE/data/backlog.md"
code=$(drive "$TMP_ROOT/lost" \
  "1=SH:chmod 000 $BACKLOG_M && touch $BACKLOG_M,8=SH:chmod 644 $BACKLOG_M && touch $BACKLOG_M,15=q") \
  || fail "the pty driver failed"
chmod 644 "$BACKLOG_M"
[ "$code" = 0 ] || fail "the unreadable-home run quits cleanly, got exit $code"
screen "$TMP_ROOT/lost" 2 | grep -q 'its records could not be read' || fail "the unreadable mate home is disclosed"
screen "$TMP_ROOT/lost" 3 | grep -q 'its records could not be read' && fail "the mate home reads again"
for n in 2 3; do
  screen "$TMP_ROOT/lost" "$n" | grep -Eq 'goes home|calls in an intern|asks you|left a question' \
    && fail "an unreadable read is not a change (screen $n)"
  [ -z "$(screen "$TMP_ROOT/lost" "$n" | grep -o 'Alpha finished.*' | sort | uniq -d)" ] \
    || fail "a completion is logged once, not again after a failed read (screen $n)"
  [ "$(screen "$TMP_ROOT/lost" "$n" | grep -c "Alpha's intern")" = 2 ] \
    || fail "the mate's interns stay through a failed read (screen $n)"
done
pass "a second mate home that cannot be read keeps its last good read"

# A mate home unreadable from the start reads as history once it can be read.
chmod 000 "$BACKLOG_M"
code=$(drive "$TMP_ROOT/late" "4=SH:chmod 644 $BACKLOG_M && touch $BACKLOG_M,12=q") || fail "the pty driver failed"
chmod 644 "$BACKLOG_M"
[ "$code" = 0 ] || fail "the late-read run quits cleanly, got exit $code"
screen "$TMP_ROOT/late" 1 | grep -q 'its records could not be read' || fail "the mate home starts unreadable"
screen "$TMP_ROOT/late" 2 | grep -q 'its records could not be read' && fail "the mate home becomes readable"
[ "$(screen "$TMP_ROOT/late" 2 | grep -c "Alpha's intern")" = 2 ] || fail "the mate's interns are placed on its first read"
screen "$TMP_ROOT/late" 2 | grep -Eq 'Alpha (finished|asks you|calls in an intern|left a question)' \
  && fail "a mate's first readable records are history, not news"
pass "a second mate home first read late adds no invented events"

# Herdr stops answering after one good read: the notice says what is shown.
code=$(drive "$TMP_ROOT/down" "1=SH:touch $TMP_ROOT/herdr-down,6=q") || fail "the pty driver failed"
rm -f "$TMP_ROOT/herdr-down"
screen "$TMP_ROOT/down" 2 | grep -q 'showing what it' || fail "the Herdr notice says the last states are shown"
screen "$TMP_ROOT/down" 2 | grep -q 'everyone looks asleep' && fail "the Herdr notice must not claim everyone is asleep"
screen "$TMP_ROOT/down" 2 | grep -q 'working' || fail "the last known working state stays on screen"
pass "a Herdr outage keeps the last states and says so"

# The live calendar opens on this month, moves a month at a time, t brings it
# back, v and a tap on the control bar change the mode.
RIGHT=$'\e[C'
LEFT=$'\e[D'
WEEK_TAP=$'\e[<0;4;4M'
code=$(DRIVE_HOME="$CAL" FM_BRIDGE_NOW=2026-09-23T10:00:00 \
  drive "$TMP_ROOT/cal" "1=SH:true,4=5,6=$RIGHT,8=$LEFT$LEFT,10=t,12=v,14=$WEEK_TAP,16=q") || fail "the pty driver failed"
[ "$code" = 0 ] || fail "the calendar run quits cleanly, got exit $code"
screen "$TMP_ROOT/cal" 3 | grep -Eq 'September 2026 +▸ +this month' || fail "key 5 opens this month's calendar"
screen "$TMP_ROOT/cal" 3 | grep -q '● Mission Control running' || fail "the running screen counts itself as running"
screen "$TMP_ROOT/cal" 4 | grep -Eq 'October 2026 +▸ +next month' || fail "right shows the next month"
screen "$TMP_ROOT/cal" 5 | grep -Eq 'August 2026 +▸ +last month' || fail "left goes back a month at a time"
screen "$TMP_ROOT/cal" 6 | grep -Eq 'September 2026 +▸ +this month' || fail "t returns to this month"
screen "$TMP_ROOT/cal" 7 | grep -Eq '2026 +▸ +this year' || fail "v turns the month into the year"
screen "$TMP_ROOT/cal" 8 | grep -Eq '20 to 26 September +▸ +this week' || fail "tapping Week shows this week"
pass "the live Calendar moves by month, returns to today, and changes mode by key and by tap"

# A mate seated upstairs that leaves the registry still retires.
cp "$BIG/data/secondmates.md" "$TMP_ROOT/big-mates.saved"
code=$(DRIVE_HOME="$BIG" DRIVE_AGENTS="$TMP_ROOT/big.json" DRIVE_ROWS=60 \
  drive "$TMP_ROOT/up" "5=SH:sed -i.bak /m6-mate/d $BIG/data/secondmates.md,14=q") || fail "the pty driver failed"
cp "$TMP_ROOT/big-mates.saved" "$BIG/data/secondmates.md"
screen "$TMP_ROOT/up" 1 | grep -q '1 upstairs, 0 working' || fail "the sixth mate starts upstairs"
screen "$TMP_ROOT/up" 2 | grep -Eq '□ M6 +second mate +retired' || fail "the upstairs mate has a retired row"
screen "$TMP_ROOT/up" 2 | grep -q 'M6 retires' || fail "the activity column shows the retirement"
screen "$TMP_ROOT/up" 2 | grep -q 'upstairs,' && fail "nobody is left upstairs"
pass "a mate that leaves the registry from upstairs goes on the alumni wall"

# A pane that stops working keeps its desk lit for SLEEP_AFTER seconds, and
# the team list agrees with the desk.
PYTHONPATH="$ROOT/bin" FM_BRIDGE_NOW=2026-09-20T10:00:00 PATH="$FAKEBIN:$PATH" \
  python3 - "$HOME_DIR" <<'PY' || fail "the sleep timer settles working and asleep together"
import os
import sys
import fm_mission_control as mc
home = os.path.realpath(sys.argv[1])
model = mc.bridge.collect(home, home + "/config", mc.bridge._now())
timer, scene = mc.SleepTimer(), mc.Scene()


def at(t, status):
    agents = [{"pane": "w1:p1", "status": status, "cwds": {home}}]
    crew = mc.build_crew(model, timer.apply(agents, t), home)
    scene.observe(model, crew, 44)
    return crew[0], scene.actors["fm"]


fm, a = at(0, "working")
assert fm["status"] == "work" and a.state == "work"
fm, a = at(2, "idle")
assert timer.due() == 2 + mc.SLEEP_AFTER, timer.due()
fm, a = at(1 + mc.SLEEP_AFTER, "idle")
assert fm["status"] == "work" and fm["doing"].startswith("working") and a.state == "work", (fm, a.state)
fm, a = at(2 + mc.SLEEP_AFTER, "idle")
assert fm["status"] == "sleep" and fm["doing"].startswith("standing by") and a.state == "sleep", (fm, a.state)
assert timer.due() is None
assert scene.feed[0]["text"] == "falls asleep", scene.feed[0]
PY
pass "an idle pane falls asleep after SLEEP_AFTER seconds, on the desk and the team list alike"

bash -n "$MC" || fail "fm-mission-control.sh has a syntax error"
pass "fm-mission-control.sh parses"
