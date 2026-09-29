#!/usr/bin/env bash
# Behavior tests for Mission Control (bin/fm-mission-control.sh over
# bin/fm_mission_control.py): one-frame snapshots from fixture records and a
# saved `herdr agent list`, asserting desks, working and asleep states, interns
# beside the right person in charge, the second-floor sign at seven mates, the
# inbox count, a tapped agent standing up to talk (its lines from its records,
# its answers, and what ends a talk), the office things saying what they are
# in the same box and opening their views,
# the activity column keeping sleep and wake out, the task columns, the project cards, the Approvals groups, the
# calendar's week, month and year (completions, due dates, what always runs,
# the tappable control bar), the Team org chart, the Memory and Docs lists
# with their Markdown reader, the System view's dots, overall line and
# office rack sign from saved readings, and the names map renaming projects
# and second mates in every view, and the Controls tab turning the merge
# switch over; then the live screen in a
# pseudo-terminal, which must redraw only what changed, pick project cards
# with up/down, pick, filter and scroll Memory and Docs pages, and restore the
# terminal on q and on SIGTERM. The record parsers themselves are covered by
# fm-bridge.test.sh.
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
printf '{"first_mate_name": "Denver", "names": {"alpha": "Alpha"}}\n' > "$HOME_DIR/config/mission-control.json"

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
grep -Eq "Alpha's intern .*  Alpha *\$" <<<"$T" || fail "the team list names the project by its display name"
grep -q 'PROJECT (the one it works in)' <<<"$T" || fail "the team list's last column is the project"
grep -q 'LIVE ACTIVITY' <<<"$T" || fail "the activity column has its heading"
grep -q 'Alpha finished Chapter' <<<"$T" \
  || fail "the activity column starts with this month's completions, each with a verb"
[ "$(jq -r '.team[0].name' <<<"$J")" = Denver ] || fail "config/mission-control.json names the first mate"
grep -q "$TMP_ROOT" <<<"$T" && fail "no raw path may reach the screen"
grep -Eq '\b(a1|q1|m2|d1)\b' <<<"$T" && fail "no task id may reach the screen"
# The wall labels sit on the bare floor, never on a sprite: no cell under the
# alumni label takes the green of the corner plant's leaves.
TO=$(mc "$HOME_DIR" frame --agents "$AGENTS" --format ansi) || fail "office ansi failed"
LB=$(python3 -c '
import re, sys
for line in sys.stdin.read().split("\n"):
    cells, bg = [], (0, 0, 0)
    for m in re.finditer(r"\x1b\[([0-9;]*)m|(.)", line):
        if m.group(2) is not None:
            cells.append((m.group(2), bg))
        elif re.search(r"48;2;([0-9]+);([0-9]+);([0-9]+)", m.group(1)):
            bg = tuple(int(v) for v in re.search(r"48;2;([0-9]+);([0-9]+);([0-9]+)", m.group(1)).groups())
    text = "".join(c for c, _b in cells)
    if "alumni" in text:
        i = text.index("alumni")
        print(" ".join("green" if g > r + 20 and g > b + 20 else "floor" for _c, (r, g, b) in cells[i:i + 6]))
' <<<"$TO")
[ "$LB" = "floor floor floor floor floor floor" ] || fail "the alumni label sits on the bare floor, got: $LB"
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

# --- every agent pane shows, with or without a record ------------------------

# A pane no record claims (its task record is gone) still shows, as a helper
# doing its window title: beside the first mate from this home's folders,
# beside the mate from the mate's home.
AGENTS2="$TMP_ROOT/agents2.json"
jq --arg home "$HOME_DIR" --arg mate "$MATE" '.result.agents += [
    {pane_id: "w4:p1", agent_status: "idle", cwd: ($home + "/projects/alpha"),
     terminal_title: "✳ Quiz one for chapter two", terminal_title_stripped: "Quiz one for chapter two"},
    {pane_id: "w4:p2", agent_status: "working", cwd: ($mate + "/scratch"),
     terminal_title_stripped: "Sorting \($mate)/data/notes.md"}]' "$AGENTS" > "$AGENTS2"
HJ=$(mc "$HOME_DIR" frame --agents "$AGENTS2" --format json) || fail "frame with helper panes failed"
[ "$(jq -r '.actors[] | select(.key == "helper:w4:p1") | .lead' <<<"$HJ")" = fm ] \
  || fail "a pane with no record stands beside the first mate"
jq -e '.team[] | select(.role == "Denver'"'"'s helper" and .doing == "idle: Quiz one for chapter two"
  and .path == "Alpha")' <<<"$HJ" >/dev/null || fail "the helper reads its window title and its project"
jq -e '.team[] | select(.role == "Alpha'"'"'s helper" and .doing == "Sorting a local file" and .status == "work")' \
  <<<"$HJ" >/dev/null || fail "a pane in the mate's home is the mate's helper, and its title loses the path"
for size in 132x44 170x50; do
  HT=$(mc "$HOME_DIR" frame --agents "$AGENTS2" --size "$size") || fail "helper office text failed at $size"
  grep -q "Denver's helper .*idle: Quiz one for chapter two" <<<"$HT" || fail "at $size the team list shows the helper"
  grep -q "Alpha's helper .*Sorting a local file" <<<"$HT" || fail "at $size the team list shows the mate's helper"
  grep -Eq 'w4:p|✳' <<<"$HT" && fail "at $size no pane id or title glyph reaches the screen"
  grep -q "$TMP_ROOT" <<<"$HT" && fail "at $size no raw path reaches the screen"
  HM=$(mc "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --view team) || fail "helper team frame failed"
  grep -q '├─ ○ idle: Quiz one for chapter two' <<<"$HM" || fail "at $size the helper branches off the first mate's line"
  grep -q '2 helpers with no record' <<<"$HM" || fail "at $size the Team view counts the helper"
  grep -q 'owns beta, the setup itself' <<<"$HM" \
    || fail "at $size the first mate's card names the projects no second mate owns"
done
HC=$(mc "$HOME_DIR" frame --agents "$AGENTS2" --view calendar --size 170x50) || fail "helper calendar frame failed"
grep -q '● Denver working' <<<"$HC" || fail "the always-running strip shows the first mate"
pass "a pane with no record shows as a helper, in plain words, on every view"

# The first mate's seven places: four right of its desk, three left; the
# eighth intern is counted, and the team lists show every one.
CROWD="$TMP_ROOT/crowdship"
mkdir -p "$CROWD/data" "$CROWD/state" "$CROWD/config"
CROWD=$(cd "$CROWD" && pwd)
cp "$FIX/projects.fixture" "$CROWD/data/projects.md"
printf '# Backlog\n\n## In flight\n## Queued\n## Done\n' > "$CROWD/data/backlog.md"
printf '{"names": {"beta": "Beta Outreach"}}\n' > "$CROWD/config/mission-control.json"
for n in 1 2 3 4 5 6 7 8; do
  meta "$CROWD" "c$n" "$TMP_ROOT/crowd-wt-$n" "$CROWD/projects/beta"
done
jq -n --arg home "$CROWD" '{result: {agents: [{pane_id: "w1:p1", agent_status: "working", cwd: $home}]}}' \
  > "$TMP_ROOT/crowd.json"
CJ=$(mc "$CROWD" frame --agents "$TMP_ROOT/crowd.json" --format json) || fail "crowded frame failed"
[ "$(jq -r '[.actors[] | select(.kind == "intern")] | length' <<<"$CJ")" = 7 ] \
  || fail "the first mate has seven places for interns"
[ "$(jq -r '[.actors[] | select(.kind == "intern") | "\(.slot):\(.x):\(.feet)"] | join(" ")' <<<"$CJ")" \
  = "0:56:24 1:63:24 2:70:24 3:77:24 4:19:24 5:12:24 6:5:24" ] \
  || fail "four places right of the desk, three left, got $(jq -c '[.actors[] | select(.kind == "intern") | [.slot, .x]]' <<<"$CJ")"
CT=$(mc "$CROWD" frame --agents "$TMP_ROOT/crowd.json" --size 170x50) || fail "crowded text failed"
grep -q '+1' <<<"$CT" || fail "the eighth intern is counted beside the desk"
[ "$(grep -c "First mate's intern" <<<"$CT")" = 8 ] || fail "the team list under the office shows all eight"
CS=$(mc "$CROWD" frame --agents "$TMP_ROOT/crowd.json" --size 132x44) || fail "crowded small text failed"
grep -q '^   +2 more' <<<"$CS" || fail "a list with no room for every row counts the rest"
[ "$(grep -c "First mate's intern" <<<"$CS")" = 6 ] || fail "the crowded list takes the note's rows"
grep -q 'Interns stand beside' <<<"$CS" && fail "a crowded list gives up the note"
for size in 132x44 170x50; do
  CM=$(mc "$CROWD" frame --agents "$TMP_ROOT/crowd.json" --size "$size" --view team) || fail "crowded team failed"
  [ "$(grep -c '├─ ○\|└─ ○' <<<"$CM")" = 8 ] || fail "at $size the Team view lists all eight interns"
  grep -Eq 'more (interns?|helpers?)|more:' <<<"$CM" && fail "at $size no intern is folded into a count"
  grep -q 'owns alpha, Beta Outreach, homeship, the setup itself' <<<"$CM" \
    || fail "at $size the first mate's card names its projects by their display names"
done
pass "the first mate's interns fill seven places, and every one is listed"

# --- tapping an agent: it stands up and talks ---------------------------------

# A fake herdr logs every call; a pane it no longer has answers not found.
cat > "$FAKEBIN/herdr-log" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP_ROOT/herdr.log"
[ "\$1 \$2 \$3" = "agent focus w9:gone" ] && exit 1
exit 0
SH
chmod +x "$FAKEBIN/herdr-log"
mct() {  # <home> <args...> - mc through the logging herdr, with an empty log
  local home=$1
  shift
  : > "$TMP_ROOT/herdr.log"
  PATH="$FAKEBIN:$PATH" FM_HOME="$home" FM_BRIDGE_NOW=2026-09-20T10:00:00 FM_MC_HERDR="$FAKEBIN/herdr-log" "$MC" "$@"
}
tap_on() {  # <frame text> <needle> [dx] - the terminal's press on the needle's first cell plus dx
  python3 -c '
import sys
text, needle, dx = sys.argv[1], sys.argv[2], int(sys.argv[3])
for i, ln in enumerate(text.split("\n")):
    j = ln.find(needle)
    if j >= 0:
        sys.stdout.write("\x1b[<0;%d;%dM" % (j + 1 + dx, i + 1))
        break
else:
    sys.exit("no %r on the screen" % needle)' "$1" "$2" "${3:-0}"
}
tap_at() {  # <col> <row>, zero-based screen cells
  printf '\e[<0;%d;%dM' $(($1 + 1)) $(($2 + 1))
}
focused() {  # the panes Herdr was asked to focus, space separated
  tr '\n' ' ' < "$TMP_ROOT/herdr.log" | sed 's/ $//'
}
ESC=$'\e'
UP=$'\e[A'
DOWN=$'\e[B'
RIGHT=$'\e[C'
ENTER=$'\r'
for size in 132x44 170x50; do
  # The office is 96 cells wide at every size: the first mate's desk spans
  # columns 34-54 and rows 5-16; its first place right (x 56) and first place
  # left (x 19) hold sprites on rows 9-14; the mate's desk spans columns 1-13
  # and rows 15-26, and its first intern stands at x 15 on rows 19-24.
  for want in "44 8|fm|w1:p1" "54 16|fm|w1:p1" "66 12|helper:w4:p1|w4:p1" "6 20|mate:alpha-mate|w2:p1" \
    "17 22|intern:main:a1|w3:p1"; do
    IFS='|' read -r at key pane <<<"$want"
    # shellcheck disable=SC2086
    TAP=$(tap_at $at)
    TJ=$(mct "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --keys "$TAP" --format json) \
      || fail "a tap at $at failed at $size"
    [ "$(jq -r .talk.key <<<"$TJ")" = "$key" ] || fail "at $size a tap at $at starts a talk with $key"
    [ -z "$(focused)" ] || fail "at $size a tap on an agent opens no chat by itself, got: $(focused)"
    [ "$(jq -r --arg k "$key" '.actors[] | select(.key == $k) | .pose' <<<"$TJ")" = up ] \
      || fail "at $size the tapped $key stands up"
    jq -e '.talk.line as $l | .talk.lines | index($l)' <<<"$TJ" >/dev/null \
      || fail "at $size the line said is one of $key's lines"
    T=$(mct "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --keys "$TAP") || fail "talk text failed"
    for part in '╭──' '╰──' ' Open chat ' ' What else? ' ' Bye ' 'left/right pick an answer'; do
      grep -qF "$part" <<<"$T" || fail "at $size the talk with $key shows '$part'"
    done
    grep -qFf <(jq -r '.talk.lines[] | split(" ")[0:3] | join(" ")' <<<"$TJ") <<<"$T" \
      || fail "at $size the box shows one of $key's lines"
    T=$(mct "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --keys "$TAP$(tap_on "$T" ' Open chat ')") \
      || fail "open chat failed"
    [ "$(focused)" = "agent focus $pane" ] || fail "at $size Open chat on $key opens $pane's chat, got: $(focused)"
    grep -q "opening .*'s chat" <<<"$T" || fail "at $size the footer says the chat is opening"
    grep -qF ' What else? ' <<<"$T" && fail "at $size Open chat ends the talk"
  done

  # The first mate stands up from its chair beside the desk, and sits back down on Bye.
  O=$(mc "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --format json) || fail "office json failed"
  [ "$(jq -r '.actors[] | select(.key == "fm") | "\(.pose) \(.state)"' <<<"$O")" = "null work" ] \
    || fail "at $size before a tap the first mate sits working"
  grep -q talking <<<"$(mc "$HOME_DIR" frame --agents "$AGENTS2" --size "$size")" && fail "nobody talks before a tap"
  T=$(mct "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --keys "$(tap_at 44 8)") || fail "stand-up frame failed"
  grep -Eq '^ {30,}talking' <<<"$T" || fail "at $size the first mate's desk says talking"
  grep -q '^ *Denver *$' <<<"$T" && fail "at $size the desk's name label gives way to the standing sprite"
  grep -qF 'Denver · first mate' <<<"$T" || fail "at $size the box names the first mate"
  A0=$(mc "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --format ansi | sed -n 8,15p)
  A1=$(mct "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --format ansi --keys "$(tap_at 44 8)" | sed -n 8,15p)
  [ "$A0" != "$A1" ] || fail "at $size the standing first mate is drawn differently from the seated one"
  B=$(mct "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --format json --keys "$(tap_at 44 8)$(tap_on "$T" ' Bye ')") \
    || fail "bye failed"
  [ "$(jq -r '.talk' <<<"$B")" = null ] || fail "at $size Bye ends the talk"
  [ "$(jq -r '.actors[] | select(.key == "fm") | "\(.pose) \(.state)"' <<<"$B")" = "null work" ] \
    || fail "at $size after Bye the first mate sits back down at work"
  [ -z "$(focused)" ] || fail "at $size Bye opens no chat"

  # What else? says another line each time, every line once before any repeats.
  n=$(jq -r '.talk.lines | length' <<<"$(mct "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" \
    --keys "$(tap_at 44 8)" --format json)")
  KEYS=$(tap_at 44 8)
  for _ in $(seq 2 "$n"); do
    KEYS="$KEYS$(tap_on "$T" ' What else? ')"
  done
  W=$(mct "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --keys "$KEYS" --format json) || fail "what else failed"
  [ "$n" -gt 5 ] || fail "at $size the first mate has several lines, got $n"
  jq -e '(.talk.said | length) == (.talk.lines | length) and (.talk.said | unique | length) == (.talk.lines | length)' \
    <<<"$W" >/dev/null || fail "at $size What else? goes through every line once: $(jq -c .talk.said <<<"$W")"
  [ "$(jq -r .talk.answer <<<"$W")" = 'What else?' ] || fail "at $size the answer tapped stays highlighted"

  # Esc, a tap on the floor, or another view ends the talk; a tap on another agent starts theirs.
  for end in "$ESC" "$(tap_at 30 30)" 2; do
    E=$(mct "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --keys "$(tap_at 44 8)$end" --format json) \
      || fail "ending the talk failed"
    [ "$(jq -r '.talk' <<<"$E")" = null ] || fail "at $size '$end' ends the talk"
    [ -z "$(focused)" ] || fail "at $size ending a talk opens no chat"
  done
  E=$(mct "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --keys "$(tap_at 44 8)$(tap_at 6 20)" --format json)
  [ "$(jq -r '.talk.key' <<<"$E")" = mate:alpha-mate ] || fail "at $size a tap on another agent talks to them instead"
  [ "$(jq -r '.actors[] | select(.key == "fm") | .pose' <<<"$E")" = null ] || fail "at $size the first mate sits back down"

  # The keyboard: up/down pick, Enter talks, left/right pick an answer, Enter answers.
  K=$(mct "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --keys "$DOWN$ENTER" --format json)
  [ "$(jq -r '.talk.key' <<<"$K")" = fm ] || fail "at $size Enter on a picked agent starts a talk"
  K=$(mct "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --keys "$DOWN$ENTER$RIGHT$ENTER" --format json)
  [ "$(jq -r '.talk.said | length' <<<"$K")" = 2 ] || fail "at $size right then Enter is What else?"
  mct "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --keys "$DOWN$ENTER$ENTER" >/dev/null
  [ "$(focused)" = "agent focus w1:p1" ] || fail "at $size Enter on Open chat opens the chat, got: $(focused)"
  mct "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --keys "$DOWN$ENTER"$'\t'"$ENTER" >/dev/null
  [ "$(focused)" = "agent focus w1:p1" ] || fail "at $size Tab picks no other answer, got: $(focused)"

  # An intern with no pane talks too; only Open chat says there is nothing to open.
  T=$(mct "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --keys "$(tap_at 59 12)") || fail "tap failed"
  T=$(mct "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --keys "$(tap_at 59 12)$(tap_on "$T" ' Open chat ')")
  [ -z "$(focused)" ] || fail "at $size an intern with no pane asks Herdr nothing, got: $(focused)"
  grep -q "Denver's intern has no open chat to show" <<<"$T" || fail "at $size an intern with no pane says so"
  O=$(mc "$HOME_DIR" frame --agents "$AGENTS2" --size "$size") || fail "office text failed"
  mct "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --keys "$(tap_on "$O" "Denver's helper")" --format json \
    | jq -e '.talk.key == "helper:w4:p1"' >/dev/null || fail "at $size a team list row starts a talk"
  grep -q 'tap an agent or a thing to talk' <<<"$O" || fail "at $size the office footer says a tap talks"

  M=$(mc "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --view team) || fail "team text failed"
  grep -q 'tap an agent to open its chat' <<<"$M" || fail "at $size the Team footer says taps open chats"
  for want in "Chief of staff:w1:p1" "owns Alpha:w2:p1" "idle: Quiz one for chapter two:w4:p1" \
    "Build chapter four:w3:p1"; do
    needle=${want%:*:*}
    pane=${want#"$needle":}
    TJ=$(mct "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --view team --keys "$(tap_on "$M" "$needle")" \
      --format json) || fail "team tap failed"
    [ "$(focused)" = "agent focus $pane" ] || fail "at $size tapping '$needle' opens $pane's chat, got: $(focused)"
    [ "$(jq -r .talk <<<"$TJ")" = null ] || fail "at $size a tap on the Team view starts no talk"
  done
  T=$(mct "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --view team --keys "$DOWN$ENTER") || fail "team enter failed"
  [ "$(focused)" = "agent focus w2:p1" ] || fail "at $size Enter on a picked Team card opens its chat, got: $(focused)"
  grep -q "opening Alpha's chat" <<<"$T" || fail "at $size the Team footer says the chat is opening"
  grep -qF ' What else? ' <<<"$T" && fail "at $size the Team view shows no talk box"
done

# A pane that closed since the last look says so in one line, and nothing fails.
jq '.result.agents[0].pane_id = "w9:gone"' "$AGENTS2" > "$TMP_ROOT/gone.json"
T=$(mct "$HOME_DIR" frame --agents "$TMP_ROOT/gone.json" --keys "$(tap_at 44 8)") || fail "a tap on a closed pane failed"
T=$(mct "$HOME_DIR" frame --agents "$TMP_ROOT/gone.json" --keys "$(tap_at 44 8)$(tap_on "$T" ' Open chat ')")
[ "$(focused)" = "agent focus w9:gone" ] || fail "the closed pane was asked for, got: $(focused)"
grep -q "Denver's chat has closed, so there is nothing to open" <<<"$T" || fail "a closed pane reads as one plain line"
grep -q 'w9:gone' <<<"$T" && fail "no pane id reaches the screen"
pass "tapping an agent stands it up to talk, and only its Open chat answer opens the chat"

# What an agent says comes from its own records, in plain short words.
lines() {  # <home> <tap col> <tap row> - every line the tapped agent may say, one per line
  mc "$1" frame --agents "$AGENTS2" --keys "$(tap_at "$2" "$3")" --format json | jq -r '.talk.lines[]'
}
FM_LINES=$(lines "$HOME_DIR" 44 8)
for want in 'Keeping an eye on the whole crew right now.' 'One of my interns is on Print the handouts.' \
  '3 things wait on you in the inbox. No rush!' 'Finished Chapter three decks on 5 Sep. Felt good!' \
  'Wrapped up Module one handout on 2 Sep.' 'Fun fact: a first mate is second in command, right after the captain.'; do
  grep -qxF "$want" <<<"$FM_LINES" || fail "the first mate may say: $want"
done
MATE_LINES=$(lines "$HOME_DIR" 6 20)
for want in 'Resting between jobs. 2 jobs waiting for me later.' 'Finished Chapter four notes on 12 Sep. Felt good!' \
  'One thing waits on you in the inbox. No rush!' 'Fun fact: the first computer bug was a real moth, found in 1947.'; do
  grep -qxF "$want" <<<"$MATE_LINES" || fail "the alpha mate may say: $want"
done
grep -q 'Chapter three decks' <<<"$MATE_LINES" && fail "a mate talks only about its own finished work"
INTERN_LINES=$(lines "$HOME_DIR" 17 22)
for want in 'Heads down on Build chapter four.' 'Finished Chapter four notes on 12 Sep. Felt good!' \
  'Ticked off an old chapter on 20 Jul.'; do
  grep -qxF "$want" <<<"$INTERN_LINES" || fail "the alpha intern may say: $want"
done
grep -q 'Module one' <<<"$INTERN_LINES" && fail "an intern talks only about its own project's finished work"
ALL="$FM_LINES"$'\n'"$MATE_LINES"$'\n'"$INTERN_LINES"
awk 'length > 80 { exit 1 }' <<<"$ALL" || fail "every line stays within 80 characters"
grep -q '—' <<<"$ALL" && fail "no line has an em dash"
grep -qF '....' <<<"$ALL" && fail "a shortened title never doubles its dots"
grep -Eq "$TMP_ROOT|https?:|\b(a1|q1|m2|m3|d1|d3|d4)\b" <<<"$ALL" && fail "no line carries a path, link or id"
# A project about technical analysis talks about charts and markets.
TOPIC="$TMP_ROOT/topicship"
cp -R "$HOME_DIR" "$TOPIC"
sed -i.bak 's/Alpha course materials for a class/Technical analysis course on charts and markets/' "$TOPIC/data/projects.md"
for at in "6 20" "17 22"; do
  # shellcheck disable=SC2086
  lines "$TOPIC" $at | grep -qxF 'Fun fact: candlestick charts come from Japanese rice traders in the 1700s.' \
    || fail "an agent on a markets project tells a markets fact (tap at $at)"
done
pass "an agent's lines are its work now, its recent finishes and a fun fact for its project"

# The things in the office talk too: a tap opens a box beside the thing with
# one short line saying what it is and the answers Open <view>, What else?
# and Bye; Open opens the corkboard's Tasks, the calendar's Calendar, the
# bookshelf's Memory, the rack's System, the inbox's Approvals and the alumni
# wall's Team. The bare floor opens nothing.
for size in 132x44 170x50; do
  for want in "10 3|team|Alumni wall|Team" "28 3|tasks|Corkboard|Tasks" "63 3|calendar|Wall calendar|Calendar" \
    "78 3|memory|Bookshelf|Memory" "90 10|system|Server rack|System" "12 29|approvals|Inbox|Approvals" \
    "20 30|approvals|Inbox|Approvals"; do
    IFS='|' read -r at view name tab <<<"$want"
    # shellcheck disable=SC2086
    V=$(mct "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --keys "$(tap_at $at)" --format json) \
      || fail "a tap at $at failed"
    [ "$(jq -r '"\(.view) \(.talk.thing) \(.talk.answers | join(","))"' <<<"$V")" = "office $view Open $tab,What else?,Bye" ] \
      || fail "at $size a tap at $at opens the $view thing's box, got $(jq -c '[.view, .talk]' <<<"$V")"
    [ "$(jq -r '.talk.line == .talk.lines[0] and .talk.kinds[0] == "what"' <<<"$V")" = true ] \
      || fail "at $size the $view thing first says what it is, got $(jq -r .talk.line <<<"$V")"
    [ -z "$(focused)" ] || fail "at $size a tap on a thing moves no pane"
    # shellcheck disable=SC2086
    T=$(mct "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --keys "$(tap_at $at)") || fail "thing text failed"
    grep -q "$name" <<<"$T" || fail "at $size the box names the $name"
    grep -q " Open $tab " <<<"$T" || fail "at $size the box shows Open $tab"
    # shellcheck disable=SC2086
    O=$(mct "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --keys "$(tap_at $at)$(tap_on "$T" " Open $tab ")" \
      --format json) || fail "open answer failed"
    [ "$(jq -r '"\(.view) \(.talk)"' <<<"$O")" = "$view null" ] || fail "at $size Open $tab opens $view and closes the box"
  done
  F=$(mct "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --keys "$(tap_at 45 26)" --format json)
  [ "$(jq -r '"\(.view) \(.talk)"' <<<"$F")" = "office null" ] || fail "at $size the bare floor opens nothing"
  T=$(mct "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --keys "$(tap_at 28 3)") || fail "corkboard tap failed"
  B=$(mct "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --keys "$(tap_at 28 3)$ENTER") || fail "corkboard enter failed"
  grep -q 'WAITING ON YOU' <<<"$B" || fail "at $size Enter on the corkboard's first answer opens the task board"
  W=$(mct "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --keys "$(tap_at 28 3)$(tap_on "$T" ' What else? ')" \
    --format json)
  [ "$(jq -r '"\(.view) \(.talk.line == .talk.lines[1]) \(.talk.answer)"' <<<"$W")" = "office true What else?" ] \
    || fail "at $size What else? has the thing say its next line, got $(jq -c .talk <<<"$W")"
  for end in "$(tap_on "$T" ' Bye ')" "$ESC" "$(tap_at 45 26)"; do
    E=$(mct "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --keys "$(tap_at 28 3)$end" --format json)
    [ "$(jq -r '"\(.view) \(.talk)"' <<<"$E")" = "office null" ] || fail "at $size Bye, Esc or a tap elsewhere closes the box"
  done
  E=$(mct "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --keys "$(tap_at 28 3)$(tap_at 28 3)" --format json)
  [ "$(jq -r .talk.thing <<<"$E")" = tasks ] || fail "at $size a second tap on the same thing keeps its box"
  E=$(mct "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --keys "$(tap_at 28 3)$(tap_at 12 29)" --format json)
  [ "$(jq -r .talk.thing <<<"$E")" = approvals ] || fail "at $size a tap on another thing opens its box instead"
  E=$(mct "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --keys "$(tap_at 28 3)$(tap_at 6 20)" --format json)
  [ "$(jq -r '"\(.talk.key) \(.talk.thing)"' <<<"$E")" = "mate:alpha-mate null" ] \
    || fail "at $size a tap on an agent talks to them instead"
  V=$(mct "$HOME_DIR" frame --agents "$AGENTS2" --size "$size" --view team --keys "$(tap_at 10 3)" --format json)
  [ "$(jq -r '"\(.view) \(.talk)"' <<<"$V")" = "team null" ] || fail "at $size the office's things take no taps on the Team view"
done
pass "each thing in the office says what it is in a box, and its Open answer opens its view"

# What each thing says comes only from what its own view shows.
thing_lines() {  # <tap col> <tap row> - every line the tapped thing may say, one per line
  # shellcheck disable=SC2046
  mc "$HOME_DIR" frame --agents "$AGENTS2" --readings "$1" --keys "$(tap_at "$2" "$3")" --format json | jq -r '.talk.lines[]'
}
jq -n '{}' > "$TMP_ROOT/no-readings.json"
L=$(thing_lines "$TMP_ROOT/no-readings.json" 28 3)
[ "$L" = $'The task board: 4 waiting on you, 1 in flight.\n5 jobs queued, 3 jobs done this month.\nEvery job pinned up in four columns, oldest first.' ] \
  || fail "the corkboard counts the task board's columns, got: $L"
L=$(thing_lines "$TMP_ROOT/no-readings.json" 12 29)
[ "$L" = $'The inbox: 4 decisions wait on you.\nThe oldest has waited 22 days.\nYou answer them in chat, never here.' ] \
  || fail "the inbox counts what waits on you and the oldest one's age, got: $L"
L=$(thing_lines "$TMP_ROOT/no-readings.json" 63 3)
head -1 <<<"$L" | grep -qx 'The wall calendar. Today is Sunday 20 September.' || fail "the calendar says today, got: $L"
L=$(thing_lines "$TMP_ROOT/no-readings.json" 78 3)
sed -n 2p <<<"$L" | grep -Eqx '[0-9]+ pages? of long-term memory, [0-9]+ days? in the journal.' \
  || fail "the bookshelf counts its pages, got: $L"
L=$(thing_lines "$TMP_ROOT/no-readings.json" 10 3)
[ "$L" = $'The alumni wall. No one has retired while I\'ve watched.\nThe crew: Denver, 1 second mate and 5 interns.\nRetired mates\' photos go up here, one frame each.' ] \
  || fail "the alumni wall counts who retired and the crew, got: $L"
L=$(thing_lines "$TMP_ROOT/no-readings.json" 90 10)
head -1 <<<"$L" | grep -q '^The server rack: ' || fail "the server rack says the System view's overall line, got: $L"
ALL=$(for at in "10 3" "28 3" "63 3" "78 3" "90 10" "12 29"; do
  # shellcheck disable=SC2086
  thing_lines "$TMP_ROOT/no-readings.json" $at
done)
while IFS= read -r ln; do
  [ "${#ln}" -le 80 ] || fail "a thing's line is short: $ln"
done <<<"$ALL"
grep -Eqi 'handout|chapter|module|deck|/|zz-|\.md' <<<"$ALL" && fail "a thing never says a task title or a path: $ALL"
pass "each thing's lines come only from its view: counts, today, pages, the overall health and the crew"

# Waking up and falling asleep stay on the desks: a burst of flips between
# looks adds nothing to the activity column, while real events still show.
jq '(.result.agents[] | select(.pane_id == "w1:p1" or .pane_id == "w3:p1") | .agent_status) = "idle"
  | (.result.agents[] | select(.pane_id == "w2:p1") | .agent_status) = "working"' "$AGENTS" > "$TMP_ROOT/flip1.json"
jq '(.result.agents[] | select(.pane_id == "w1:p1" or .pane_id == "w3:p1") | .agent_status) = "idle"
  | (.result.agents[] | select(.pane_id == "w2:p1") | .agent_status) = "working"' "$AGENTS2" > "$TMP_ROOT/flip2.json"
F=$(mc "$HOME_DIR" frame --agents "$AGENTS" --agents "$TMP_ROOT/flip1.json" --agents "$AGENTS" \
  --agents "$TMP_ROOT/flip1.json" --agents "$AGENTS2" --agents "$TMP_ROOT/flip2.json" --agents "$AGENTS2" \
  --agents "$TMP_ROOT/flip2.json" --size 170x50 --format json) || fail "a frame over several looks failed"
jq -e '[.feed[].text | select(test("asleep|wakes up|awake"))] | length == 0' <<<"$F" >/dev/null \
  || fail "no sleep or wake line reaches the activity column: $(jq -c '[.feed[].text]' <<<"$F")"
jq -e '[.feed[] | select(.who == "Denver" and .text == "calls in a helper")] | length == 1' <<<"$F" >/dev/null \
  || fail "the helper arriving still shows: $(jq -c '[.feed[] | "\(.who) \(.text)"]' <<<"$F")"
jq -e '[.feed[] | select(.text | startswith("finished "))] | length >= 3' <<<"$F" >/dev/null \
  || fail "the finished work still shows"
[ "$(jq -r '.actors[] | select(.key == "fm") | .state' <<<"$F")" = sleep ] || fail "the desk shows the last look's sleep"
FT=$(mc "$HOME_DIR" frame --agents "$AGENTS" --agents "$TMP_ROOT/flip1.json" --agents "$AGENTS" --size 170x50)
grep -Eq 'falls asleep|wakes up' <<<"$FT" && fail "the activity column never says falls asleep or wakes up"
pass "waking and sleeping stay on the desks, and the activity column keeps real events"

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
[ "$(jq -r '[.projects[].name] | join(",")' <<<"$PJ")" = "Alpha,beta,The setup itself" ] \
  || fail "one card per registered project in registry order, the home's own repository folded into the setup card"
grep -Eq '^ 2 projects +1 active +0 parked +1 quiet' <<<"$P" || fail "the header counts projects by status"
[ "$(card Alpha .status)" = active ] || fail "a project with a working agent and work in flight is active, even when parked"
[ "$(card beta .status)" = quiet ] || fail "a project with nothing moving is quiet"
[ "$(card Alpha .lead)" = Alpha ] || fail "a project a second mate has registered is in its charge"
[ "$(card beta .lead)" = Denver ] || fail "a project no second mate has registered is in the first mate's charge"
[ "$(card "The setup itself" .lead)" = Denver ] || fail "the setup itself is in the first mate's charge"
[ "$(card Alpha '.counts | [.waiting, .queued, .in_flight, .done] | join(" ")')" = "2 2 1 2" ] \
  || fail "alpha's four counts come from the Bridge's buckets, got $(card Alpha .counts)"
[ "$(card "The setup itself" '.counts | [.waiting, .queued] | join(" ")')" = "1 1" ] \
  || fail "items with no project, and the home's own, count on the setup card"
for want in '│ Alpha +Active  │' '│ beta +Quiet  │' '│ The setup itself +Quiet  │' \
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
[ "$(two alpha .lead)" = alpha ] && [ "$(two beta .lead)" = alpha ] \
  || fail "both projects are in the pair mate's charge, named by its first project"
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
[ "$(sed -E 's/.*■ ([A-Za-z]+) +(.*)/\1: \2/' <<<"$rows")" = "setup: Tick a profile setting only the captain can reach
Alpha: Choose the quiz format
beta: Approve the module outline
Alpha: Decide the chapter five review point" ] || fail "rows run oldest first within each agent, with tags, got: $rows"
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

# --- the team -------------------------------------------------------------

TM=$(mc "$HOME_DIR" frame --agents "$AGENTS" --view team --size 170x50) || fail "team frame failed"
line_of() {  # <text> - the first screen row holding it
  grep -n -m1 -F "$1" <<<"$TM" | cut -d: -f1
}
for text in 'You, the captain' '4 things wait on you' 'Denver' 'Chief of staff' 'Alpha' \
  'Alpha course, its decks and its quizzes' 'owns Alpha' '2 listed, 1 for you'; do
  grep -qF "$text" <<<"$TM" || fail "the org chart shows: $text"
done
[ "$(line_of 'You, the captain')" -lt "$(line_of 'Chief of staff')" ] \
  && [ "$(line_of 'Chief of staff')" -lt "$(line_of 'owns Alpha')" ] \
  || fail "the captain sits above the first mate, who sits above the second mates"
grep -Eq 'Denver +● working' <<<"$TM" || fail "the first mate's working pane reads working"
grep -Eq 'Alpha +z asleep' <<<"$TM" || fail "the mate's idle pane reads asleep"
grep -q '├─ ○ state not readable: Print the handouts' <<<"$TM" \
  || fail "the first mate's intern branches off its line"
[ "$(line_of 'Build chapter four')" -gt "$(line_of 'owns Alpha')" ] || fail "the mate's intern is listed under its card"
grep -q 'Add a text layer' <<<"$TM" || fail "the mate's second intern is listed too"
grep -q 'ABOUT ALPHA' <<<"$TM" || fail "the first second mate's card is picked by default"
grep -q '^   Persistent second mate for the alpha course$' <<<"$TM" || fail "the picked card shows its charter's first sentence"
grep -q 'Scope: the alpha course, its decks and its quizzes' <<<"$TM" || fail "the picked card shows its scope"
grep -q ' ALUMNI ' <<<"$TM" || fail "the Team view has an alumni row"
grep -q 'No one has retired yet' <<<"$TM" || fail "the alumni row is empty with no retirements"
grep -q 'up/down pick a second mate' <<<"$TM" || fail "the key line says what up/down does here"
grep -q 'coming next' <<<"$TM" && fail "the Team view replaces its coming-next note"
grep -q "$TMP_ROOT" <<<"$TM" && fail "no raw path may reach the Team view"
grep -Eq '\b(a1|q1|m2|alpha-mate)\b' <<<"$TM" && fail "no id may reach the Team view"
# Each portrait is the office sprite in its agent's shirt colour: the first
# mate's green (#2fbf71) and the mate's teal (#3fb6c9), next to skin (#e2b48f).
TA=$(mc "$HOME_DIR" frame --agents "$AGENTS" --view team --size 170x50 --format ansi) || fail "team ansi failed"
for rgb in '47;191;113' '63;182;201'; do
  sed 1d <<<"$TA" | grep -q "38;2;$rgb;48;2;$rgb" || fail "the portraits draw in the agents' own colours: $rgb"
done
grep -q '8;2;226;180;143' <<<"$TA" || fail "the portraits draw their faces in skin colour"
T96=$(mc "$HOME_DIR" frame --agents "$AGENTS" --view team --size 96x36) || fail "a small team frame failed"
grep -q 'ABOUT ALPHA' <<<"$T96" || fail "the smallest pane still shows the picked card"
grep -q 'No one has retired yet' <<<"$T96" || fail "the smallest pane still shows the alumni row"
pass "the Team view draws the crew as an org chart in plain words"

FAR="$TMP_ROOT/farship"
mkdir -p "$FAR/data" "$FAR/state"
cp "$FIX/projects.fixture" "$FAR/data/projects.md"
printf '# Backlog\n\n## In flight\n## Queued\n## Done\n' > "$FAR/data/backlog.md"
printf '# Second mates\n\n- far-mate - Mate on the other box (host: box; root: /srv/far; home: /srv/far/home; scope: the far course: its decks; projects: alpha; added 2026-09-01)\n' \
  > "$FAR/data/secondmates.md"
TF=$(mc "$FAR" frame --agents "$AGENTS" --view team --size 114x40) || fail "remote team frame failed"
grep -q 'list on another machine' <<<"$TF" || fail "a remote mate's card says its list is on another machine"
grep -q 'could not be read' <<<"$TF" && fail "a remote mate's records are not called unreadable"
grep -Eq 'alpha +away' <<<"$TF" || fail "a remote mate reads away beside its project's name"
grep -q '/srv/far' <<<"$TF" && fail "no remote path may reach the Team view"
pass "a remote mate's card says it works on another machine"

# Three to five cards side by side keep every card line whole, the counts and
# the remote note included.
ROW="$TMP_ROOT/rowship"
mkdir -p "$ROW/data" "$ROW/state"
cp "$FIX/projects.fixture" "$ROW/data/projects.md"
printf '# Backlog\n\n## In flight\n## Queued\n## Done\n' > "$ROW/data/backlog.md"
{
  echo "# Second mates"
  for n in 1 2 3 4 5; do
    if [ "$n" = 2 ]; then
      echo "- r2-mate - Mate number 2 (host: box; root: /srv/r2; home: /srv/r2/home; scope: area 2; projects: alpha; added 2026-09-01)"
      continue
    fi
    mkdir -p "$TMP_ROOT/r$n/data" "$TMP_ROOT/r$n/state"
    cp "$FIX/mate-backlog.fixture" "$TMP_ROOT/r$n/data/backlog.md"
    echo "- r$n-mate - Mate number $n (home: $TMP_ROOT/r$n; scope: area $n; projects: alpha; added 2026-09-01)"
  done
} > "$ROW/data/secondmates.md"
{
  printf '# Backlog\n\n## In flight\n## Queued\n'
  for n in $(seq 10 19); do printf -- '- [ ] w%d - Wait %d (kind: task) (since 2026-09-08) (hold: the call) (hold-kind: captain)\n' "$n" "$n"; done
  for n in 20 21; do printf -- '- [ ] w%d - Task %d (kind: task) (since 2026-09-09)\n' "$n" "$n"; done
  printf '## Done\n'
} > "$TMP_ROOT/r3/data/backlog.md"
for size in 112x40 113x40; do
  TR=$(mc "$ROW" frame --agents "$AGENTS" --view team --size "$size") || fail "a $size team frame failed"
  grep -q '\.\.\.' <<<"$TR" && fail "at $size no card line is clipped: $(grep -F '...' <<<"$TR")"
  grep -qF 'list on another machine' <<<"$TR" || fail "at $size a card reads: list on another machine"
done
for size in 114x40 132x44 170x50 200x50; do
  TR=$(mc "$ROW" frame --agents "$AGENTS" --view team --size "$size") || fail "a $size team frame failed"
  grep -q 'owns alpha.*owns alpha.*owns alpha' <<<"$TR" || fail "at $size three or more cards sit side by side"
  grep -q '\.\.\.' <<<"$TR" && fail "at $size no card line is clipped: $(grep -F '...' <<<"$TR")"
  for text in 'list on another machine' '12 listed, 10 for you' '2 listed, 1 for you'; do
    grep -qF "$text" <<<"$TR" || fail "at $size a card reads: $text"
  done
done
pass "a row of three or more cards clips no card line"

# --- system ----------------------------------------------------------------

GB=1073741824
readings() {  # <file> [jq filter] - a healthy set of System readings, then the filter's changes
  jq -n --argjson gb "$GB" '{
    load: [1.2, 1.1, 1.0], cores: 8,
    memory: {used: (8 * $gb), total: (16 * $gb)}, disk: {free: (100 * $gb), total: (233 * $gb)},
    beat_age: 12, supervision_needed: true, away: false, queued: 2, mates: {"alpha-mate": 180},
    uptime: 432000, tailnet: true, github: true,
    tools: {"no-mistakes": "1.79.0", herdr: "0.8.0", claude: "2.1.282"},
    bridge: {running: true, address: "http://ship.example.ts.net:7373/", local_only: false},
    mission_control: true} | '"${2:-.}" > "$1"
}
sys_frame() {  # <readings> [agents] [format] [view]
  mc "$HOME_DIR" frame --readings "$1" --agents "${2:-$AGENTS}" --view "${4:-system}" --size 170x50 \
    --format "${3:-text}"
}
dot() {  # <json> <card title>
  jq -r --arg t "$2" '.system.cards[] | select(.title == $t) | .dot' <<<"$1"
}
rack() {  # <office text> - the sign under the server rack, office row 28 at x 88
  sed -n "$((2 + 28 / 2 + 1))p" <<<"$1" | cut -c89-93 | tr -d ' '
}

readings "$TMP_ROOT/ok.json"
SJ=$(sys_frame "$TMP_ROOT/ok.json" "" json) || fail "system json failed"
ST=$(sys_frame "$TMP_ROOT/ok.json") || fail "system text failed"
[ "$(jq -r '[.system.cards[].dot] | unique | join(",")' <<<"$SJ")" = green ] \
  || fail "healthy readings give every card a green dot, got $(jq -c '[.system.cards[] | [.title, .dot]]' <<<"$SJ")"
[ "$(jq -r '[.system.cards[].title] | join(",")' <<<"$SJ")" \
  = "This Mac,Crew monitoring,Crew,Second mates,The Bridge page,Mission Control,GitHub,Tools,System Map" ] \
  || fail "the cards come in order"
grep -q '● All systems normal' <<<"$ST" || fail "the overall line says all systems normal"
for want in 'Up since Tue 15 Sep 10:00, 5 days' 'Processor load 1.1 on 8 cores' 'Memory: 8.0 GB of 16 GB in use' \
  'Disk: 100 GB free of 233 GB' 'On the tailnet' 'Monitoring the crew: healthy, last check 12 seconds ago' \
  '2 notifications waiting for the first mate' 'Crew: 1 working, 1 asleep, 3 interns out' \
  'Second mates: all 1 window open' 'Alpha: window open, home changed 3 minutes ago' \
  'http://ship.example.ts.net:7373/' 'Mission Control: running' 'GitHub: signed in' 'no-mistakes 1.79.0' \
  'herdr 0.8.0' 'claude 2.1.282' 'read only'; do
  grep -q "$want" <<<"$ST" || fail "the System view shows: $want"
done
grep -Eq '[0-9]{7,}' <<<"$ST" && fail "sizes read in MB or GB, never in bytes"
grep -q '—' <<<"$ST" && fail "the System view never shows an em dash"
grep -q "$TMP_ROOT" <<<"$ST" && fail "no raw path may reach the System view"
[ "$(jq -r .system.rack <<<"$SJ")" = ok ] || fail "healthy readings leave the rack sign at ok"
[ "$(rack "$(sys_frame "$TMP_ROOT/ok.json" "" text office)")" = ok ] || fail "the office rack reads ok when healthy"
pass "healthy readings: green cards, all systems normal, sizes in GB, the rack says ok"

readings "$TMP_ROOT/busy.json" '.load = [3.0, 9.0, 5.0]'
[ "$(dot "$(sys_frame "$TMP_ROOT/busy.json" "" json)" "This Mac")" = amber ] || fail "a busy processor is amber"
sys_frame "$TMP_ROOT/busy.json" | grep -q 'Processor load 9.0 on 8 cores, busier than it has cores' \
  || fail "the load shown is the one the dot is based on"
readings "$TMP_ROOT/spike.json" '.load = [9.0, 3.0, 5.0]'
sys_frame "$TMP_ROOT/spike.json" | grep -q 'Processor load 3.0 on 8 cores *│' \
  || fail "a brief spike beside a green dot shows the calmer load the dot is based on"
WIDE=$(mc "$HOME_DIR" frame --readings "$TMP_ROOT/ok.json" --agents "$AGENTS" --view system --size 250x50)
TOP=$(grep 'THIS MAC' <<<"$WIDE")
grep -q 'CREW MONITORING' <<<"$TOP" || fail "a wide pane lays three cards a row"
grep -q ' CREW ' <<<"$TOP" || fail "a wide pane lays three cards a row"
grep -q 'SECOND MATES' <<<"$TOP" && fail "no pane lays more than three cards a row"
PYTHONPATH="$ROOT/bin" python3 - <<'PY' || fail "the Bridge card shows the address the Bridge answers on"
import fm_mission_control as mc
def status(*lines):
    return mc._screen_status(["printf", "%s\\n"] + list(lines), None)
ts = "tailscale: running, http://ship.example.ts.net:7373/ (100.64.0.1)"
got = status("running: yes, answering on http://100.64.0.1:7373/ (LaunchAgent x)",
             "address: bound to the Tailscale address only", ts)
assert got == {"running": True, "address": "http://ship.example.ts.net:7373/", "local_only": False}, got
got = status("running: yes, answering on http://192.168.1.20:7373/ (LaunchAgent x)",
             "address: bound to the configured address 192.168.1.20", ts)
assert got["address"] == "http://192.168.1.20:7373/", got
got = status("running: yes, answering on http://127.0.0.1:7373/ (LaunchAgent x)",
             "address: Tailscale was not running at start; bound to 127.0.0.1 only, so the iPad cannot reach it", ts)
assert got["address"] == "http://127.0.0.1:7373/" and got["local_only"], got
PY
pass "the load, three cards a row at most and the Bridge address each match what the card says"

readings "$TMP_ROOT/stale.json" '.beat_age = 1200'
jq '.result.agents |= map(select(.pane_id != "w1:p1"))' "$AGENTS" > "$TMP_ROOT/fm-asleep.json"
SJ=$(sys_frame "$TMP_ROOT/stale.json" "" json) || fail "stale-watcher json failed"
ST=$(sys_frame "$TMP_ROOT/stale.json")
[ "$(dot "$SJ" "Crew monitoring")" = amber ] || fail "a stale beat during the first mate's turn is amber"
grep -q '● 1 thing needs a look: crew monitoring' <<<"$ST" || fail "the overall line counts and names it"
[ "$(jq -r .system.rack <<<"$SJ")" = check ] || fail "a stale watcher turns the rack sign to check"
[ "$(rack "$(sys_frame "$TMP_ROOT/stale.json" "" text office)")" = check ] \
  || fail "the office rack reads check when something needs a look"
readings "$TMP_ROOT/slow.json" '.beat_age = 400'
[ "$(dot "$(sys_frame "$TMP_ROOT/slow.json" "$TMP_ROOT/fm-asleep.json" json)" "Crew monitoring")" = amber ] \
  || fail "a beat past five minutes is amber"
[ "$(dot "$(sys_frame "$TMP_ROOT/stale.json" "$TMP_ROOT/fm-asleep.json" json)" "Crew monitoring")" = red ] \
  || fail "a beat past fifteen minutes with work under way and the first mate asleep is red"
sys_frame "$TMP_ROOT/stale.json" "$TMP_ROOT/fm-asleep.json" | grep -q 'Monitoring the crew: stopped, last check 20 minutes ago' \
  || fail "the stopped watcher is said plainly"
grep -q "paused for the first mate's turn, last check 20 minutes ago" <<<"$ST" \
  || fail "a stale beat during the first mate's own turn says it is paused for that turn"
readings "$TMP_ROOT/rest.json" '.beat_age = 7200 | .supervision_needed = false'
[ "$(dot "$(sys_frame "$TMP_ROOT/rest.json" "" json)" "Crew monitoring")" = green ] \
  || fail "an old beat with no work under way is resting, not stopped"
pass "a stale watcher is amber then red, names itself on the overall line, and turns the rack to check"

readings "$TMP_ROOT/missing.json" '.github = null | .tools.herdr = null | .tailnet = null'
SJ=$(sys_frame "$TMP_ROOT/missing.json" "" json) || fail "missing-command json failed"
ST=$(sys_frame "$TMP_ROOT/missing.json")
for card in GitHub Tools "This Mac"; do
  [ "$(dot "$SJ" "$card")" = amber ] || fail "a reading that could not be taken is amber: $card"
done
for want in 'GitHub: the sign-in could not be checked' 'herdr: could not be checked' 'Tailnet could not be checked' \
  '3 things need a look: the tailnet, the GitHub sign-in, herdr'; do
  grep -q "$want" <<<"$ST" || fail "a missing command reads: $want"
done
# The real read path with no gh, claude, no-mistakes or Tailscale and a Herdr that fails.
# The system dirs are linked in without those tools, since a CI runner ships gh in /usr/bin.
BAREBIN="$TMP_ROOT/barebin"
mkdir -p "$BAREBIN"
for f in /usr/bin/* /bin/*; do
  case ${f##*/} in gh|claude|no-mistakes|tailscale|herdr) continue ;; esac
  [ -e "$BAREBIN/${f##*/}" ] || ln -s "$f" "$BAREBIN/${f##*/}"
done
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/tailscale-down"
chmod +x "$FAKEBIN/tailscale-down"
LT=$(PATH="$FAKEBIN:$BAREBIN" FM_HOME="$HOME_DIR" FM_BRIDGE_NOW=2026-09-20T10:00:00 \
  FM_BRIDGE_TAILSCALE="$FAKEBIN/tailscale-down" "$MC" frame --view system --size 170x50) \
  || fail "the System view read this machine with commands missing and crashed: $LT"
for want in 'GitHub: the sign-in could not be checked' 'claude: could not be checked' 'herdr: could not be checked' \
  'Tailnet could not be checked' 'Mission Control could not be checked'; do
  grep -q "$want" <<<"$LT" || fail "a missing command on the real read path reads: $want"
done
grep -q 'Second mates: windows could not be checked' <<<"$LT" \
  || fail "with Herdr's agent list failing the Second mates head says the windows could not be checked"
grep -q 'Alpha: window could not be checked' <<<"$LT" || fail "with Herdr failing a mate's window could not be checked"
grep -q 'window closed' <<<"$LT" && fail "a failed agent list never reads as a closed window"
cat > "$FAKEBIN/herdr-lab" <<SH
#!/usr/bin/env bash
[ "\$1 \$2" = "run lab1" ] || exit 1
shift 2
case "\$1" in
  --version) echo "herdr 9.9.9" ;;
  agent) cat "$AGENTS" ;;
  workspace) echo '{"result": {"workspaces": []}}' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN/herdr-lab"
LT=$(PATH="$FAKEBIN:$(dirname "$(command -v jq)"):/usr/bin:/bin" FM_HOME="$HOME_DIR" FM_BRIDGE_NOW=2026-09-20T10:00:00 \
  FM_BRIDGE_TAILSCALE="$FAKEBIN/tailscale-down" FM_MC_HERDR="$FAKEBIN/herdr-lab run lab1" \
  "$MC" frame --view system --size 170x50 --format json) || fail "the System view through a lab Herdr failed: $LT"
for want in 'herdr 9.9.9' 'Crew: 1 working, 1 asleep'; do
  grep -q "$want" <<<"$LT" || fail "the live System view reads Herdr through FM_MC_HERDR: $want"
done
pass "a missing or failing command shows could not be checked, never a crash"

[ "$(dot "$LT" "Mission Control")" = amber ] || fail "a screen outside its Herdr space is amber, never red"
[ "$(jq -r '.system.cards[] | select(.title == "Mission Control") | .head' <<<"$LT")" \
  = "Mission Control: running in this terminal, not in its usual Herdr space" ] \
  || fail "with no Mission Control space the card says this screen runs in this terminal"
jq -r .system.overall <<<"$LT" | grep -q 'Mission Control outside its Herdr space' \
  || fail "the overall line names Mission Control outside its Herdr space"
readings "$TMP_ROOT/elsewhere.json" '.mission_control = false'
ST=$(sys_frame "$TMP_ROOT/elsewhere.json")
grep -q 'not running' <<<"$ST" && fail "the System view never says the screen showing it is not running"
grep -q '● 1 thing needs a look: Mission Control outside its Herdr space' <<<"$ST" \
  || fail "a screen outside its Herdr space is the one thing needing a look"
pass "a screen running outside its Herdr space says so in amber, never not running"

jq '.result.agents |= map(select(.pane_id != "w2:p1"))' "$AGENTS" > "$TMP_ROOT/mate-down.json"
SJ=$(sys_frame "$TMP_ROOT/ok.json" "$TMP_ROOT/mate-down.json" json) || fail "mate-down json failed"
ST=$(sys_frame "$TMP_ROOT/ok.json" "$TMP_ROOT/mate-down.json")
[ "$(dot "$SJ" "Second mates")" = red ] || fail "a second mate whose window is closed is red"
[ "$(jq -r '.system.cards[] | select(.title == "Second mates") | .lines[0].dot' <<<"$SJ")" = red ] \
  || fail "the closed mate's own line is red"
grep -q 'Second mates: 1 of 1 windows closed' <<<"$ST" || fail "the card counts the closed windows"
grep -q 'Alpha: window closed, home changed 3 minutes ago' <<<"$ST" || fail "the closed mate is named"
grep -q '● 1 thing needs a look: second mate Alpha' <<<"$ST" || fail "the overall line names the second mate"
[ "$(jq -r .system.rack <<<"$SJ")" = check ] || fail "a mate down turns the rack sign to check"
pass "one second mate down is red and named on the overall line"

printf '{}\n' > "$TMP_ROOT/none.json"
SJ=$(sys_frame "$TMP_ROOT/none.json" "" json) || fail "unread json failed"
[ "$(dot "$SJ" GitHub)" = grey ] || fail "a reading not taken yet is grey"
[ "$(jq -r .system.overall <<<"$SJ")" = "Nothing needs a look so far; still checking" ] \
  || fail "before the first reads the overall line says it is still checking"
[ "$(jq -r .system.rack <<<"$SJ")" = ok ] || fail "unread readings do not raise the rack sign"
[ "$(dot "$SJ" "Second mates")" = grey ] || fail "a second mate's window is grey before the first reads"
[ "$(rack "$(mc "$HOME_DIR" frame --view office --size 170x50)")" = ok ] \
  || fail "the office without an agent list or readings leaves the system unchecked and the rack at ok"
SJ=$(mc "$HOME_DIR" frame --readings "$TMP_ROOT/ok.json" --view system --size 170x50 --format json) \
  || fail "readings before the first agent list failed"
[ "$(dot "$SJ" "Second mates")" = grey ] || fail "a mate's window is grey until Herdr's agent list is read"
[ "$(jq -r '.system.cards[] | select(.title == "Second mates") | .lines[0].text' <<<"$SJ")" \
  = "Alpha: window not checked yet, home changed 3 minutes ago" ] \
  || fail "before the agent list is read a mate's window is not checked yet"
[ "$(jq -r .system.rack <<<"$SJ")" = ok ] || fail "an unread agent list does not raise the rack sign"
PYTHONPATH="$ROOT/bin" python3 - <<'PY' || fail "the Second mates head counts only the windows it checked"
import datetime
import fm_mission_control as mc
crew = [{"kind": "mate", "id": "a", "name": "Alpha", "pane": "w1:p1", "status": "sleep"},
        {"kind": "mate", "id": "b", "name": "Beta", "pane": None, "status": "sleep"}]
model = {"mates": [{"id": "a", "remote": False}, {"id": "b", "remote": False}],
         "team": [{"id": "b", "readable": False}]}
now = datetime.datetime(2026, 9, 20, 10, 0)
def card(agents_ok):
    got = mc.system_cards({"mates": {}}, crew, model, now, agents_ok=agents_ok)
    return next(c for c in got["cards"] if c["title"] == "Second mates"), got["looks"]
got, looks = card(True)
assert got["head"] == "Second mates: all 1 window open", got
assert [d for d, _ in got["lines"]] == ["green", "amber"] and looks == ["second mate Beta"], (got, looks)
crew[0]["pane"] = None
got, looks = card(True)
assert got["head"] == "Second mates: 1 of 1 windows closed", got
got, looks = card(None)
assert got["head"] == "Second mates: not checked yet" and got["lines"][0] == ("grey", "Alpha: window not checked yet"), got
got, looks = card(False)
assert got["head"] == "Second mates: windows could not be checked", got
assert got["lines"][0] == ("amber", "Alpha: window could not be checked"), got
PY
pass "before the first reads the view is grey and calm"


# --- memory and docs -------------------------------------------------------

# A report on an archived item (alpha), a report with no backlog item, a
# decision page on a queued alpha item, a decision page with no item, worker
# instructions that must never be listed, a mate's lessons and two links.
mkdir -p "$HOME_DIR/data/d4" "$HOME_DIR/data/lone-study" "$HOME_DIR/data/q2" "$HOME_DIR/data/loose-key" "$HOME_DIR/data/q1"
{
  cat "$FIX/report.fixture"
  for n in $(seq 1 80); do echo "- Detail line $n"; done
} > "$HOME_DIR/data/d4/report.md"
printf '# A study with no task\n\nShort.\n' > "$HOME_DIR/data/lone-study/report.md"
cp "$FIX/decision.fixture" "$HOME_DIR/data/q2/decision-quiz.md"
printf '# Decision: loose-key - ACTION: FIX, option (b)\n\nDone.\n' > "$HOME_DIR/data/loose-key/decision-extra.md"
printf '# Brief: secret instructions\n\nNever listed.\n' > "$HOME_DIR/data/q1/brief.md"
printf '# Lessons\n\n## Decks\nKeep them short.\n' > "$MATE/data/learnings.md"
jq -n '{links: [{project: "alpha", label: "class Drive folder", url: "https://drive.example.org/folders/abc"},
  {project: null, label: "status page", url: "https://status.example.org/"}]}' > "$HOME_DIR/config/bridge.json"
touch -t 202609200700 "$HOME_DIR/data/captain.md"
touch -t 202609191200 "$HOME_DIR/data/d4/report.md"
touch -t 202609181200 "$HOME_DIR/data/q2/decision-quiz.md"
touch -t 202609171200 "$HOME_DIR/data/lone-study/report.md"
touch -t 202609161200 "$HOME_DIR/data/loose-key/decision-extra.md"

MJ=$(mc "$HOME_DIR" frame --agents "$AGENTS" --format json) || fail "memory json failed"
M=$(mc "$HOME_DIR" frame --agents "$AGENTS" --view memory --size 170x50) || fail "memory frame failed"
[ "$(jq -c '[.memory[] | select(.group == "Long-term memory") | .title]' <<<"$MJ")" \
  = '["What I know about the captain","Lessons learned","Lessons Alpha learned"]' ] \
  || fail "long-term memory is this home's two pages, then each mate's that exist, got $(jq -c .memory <<<"$MJ")"
[ "$(jq -r '.memory[0].sub' <<<"$MJ")" = "22 words, updated 3 hours ago" ] \
  || fail "a long-term page shows its words and when it was updated, got $(jq -r '.memory[0].sub' <<<"$MJ")"
[ "$(jq -r '[.memory[] | select(.group != "Long-term memory") | "\(.group)|\(.title)"] | join(",")' <<<"$MJ")" \
  = "This week|Friday 18 September,September 2026|Saturday 12 September,September 2026|Wednesday 9 September,September 2026|Tuesday 8 September,September 2026|Monday 7 September,September 2026|Sunday 6 September,September 2026|Saturday 5 September,September 2026|Friday 4 September,September 2026|Thursday 3 September,September 2026|Wednesday 2 September,August 2026|Sunday 30 August,August 2026|Saturday 29 August,July 2026|Monday 20 July" ] \
  || fail "the journal has one entry per dated day, newest first, got $(jq -c '[.memory[] | .title]' <<<"$MJ")"
grep -Eq 'Today|Yesterday|Saturday 19 September|Thursday 10 September' <<<"$M" \
  && fail "a day with no records has no journal entry"
for want in '^LONG-TERM MEMORY 3 ' '^▸ What I know about the captain ' '^  22 words, updated 3 hours ago ' \
  '^DAILY JOURNAL 13 ' '^  This week 1 ' '^  September 2026 9 ' '^  Friday 18 September ' '^  1 event, 5 words ' \
  '│ Sunday 20 September 2026, 22 words, updated 3 hours ago' '│ Who the captain is ' \
  '│ A private sentence the Bridge must never print\. ' '│   • Another private sentence\. '; do
  grep -Eq "$want" <<<"$M" || fail "the Memory view shows: $want"
done

PYTHONPATH="$ROOT/bin" FM_BRIDGE_NOW=2026-09-20T10:00:00 PATH="$FAKEBIN:$PATH" \
  python3 - "$HOME_DIR" > "$TMP_ROOT/day.txt" <<'PY' || fail "picking a journal day failed"
import os
import sys
import fm_mission_control as mc
home = os.path.realpath(sys.argv[1])
model = mc.bridge.collect(home, home + "/config", mc.bridge._now())
scene, ui = mc.Scene(), mc.UI()
scene.observe(model, mc.build_crew(model, [], home, fm_name="Denver"), 50)
ui.view = "memory"
now = mc.bridge._now()
mc.compose(scene, mc.Renderer(), ui, 170, 50, now)
assert mc._handle_input(b"\x1b[B" * 4, ui, scene, None) and ui.pages["memory"] == "day:2026-09-12", ui.pages
print(mc.compose(scene, mc.Renderer(), ui, 170, 50, now)[0].text())
PY
D=$(cat "$TMP_ROOT/day.txt")
grep -Eq '^▸ Saturday 12 September ' <<<"$D" || fail "down picks the journal day"
for want in '│ Saturday 12 September 2026, 1 event, 5 words ' '│ alpha ' '│   • alpha finished Chapter four notes\. '; do
  grep -Eq "$want" <<<"$D" || fail "a journal day reads as plain sentences under its project: $want"
done
DJ=$(PYTHONPATH="$ROOT/bin" FM_BRIDGE_NOW=2026-09-20T10:00:00 PATH="$FAKEBIN:$PATH" python3 - "$HOME_DIR" <<'PY'
import os
import sys
import fm_mission_control as mc
home = os.path.realpath(sys.argv[1])
model = mc.bridge.collect(home, home + "/config", mc.bridge._now())
day = next(d for d in mc.journal(model, "Denver") if d["day"] == "2026-09-05")
print(day["text"])
PY
)
[ "$DJ" = "## alpha
- Denver shipped Chapter three decks.

## beta
- Denver queued Print the handouts." ] || fail "a journal day groups its events by project in registry order, got: $DJ"
pass "the Memory view lists long-term pages and a journal built only from dated records"

O=$(mc "$HOME_DIR" frame --agents "$AGENTS" --view docs --size 170x50) || fail "docs frame failed"
[ "$(jq -c .docs.tags <<<"$MJ")" = '{"All":6,"Report":2,"Decision":2,"Link":2}' ] \
  || fail "the tag row counts each kind, got $(jq -c .docs.tags <<<"$MJ")"
[ "$(jq -r '[.docs.rows[] | "\(.kind)|\(.title)|\(.project)"] | join(",")' <<<"$MJ")" \
  = "Link|Class Drive folder|alpha,Link|Status page|null,Report|Scout report: the quiz format in a local file|alpha,Decision|The quiz stays private|alpha,Report|A study with no task|null,Decision|A decision: fix, option (b)|null" ] \
  || fail "saved links are pinned first, then documents newest first, with plain titles, got $(jq -c .docs.rows <<<"$MJ")"
for want in '^  All 6   Report 2   Decision 2   Link 2 ' '^▸ Scout report: the quiz format in\.\.\. +19 Sep  [┌│]' \
  '^   Report   ■ Alpha  [0-9]+ words' '^  The quiz stays private +18 Sep  │' '^   Decision   ■ Alpha  ' \
  '^   Report   [0-9]+ words' '^  A decision: fix, option \(b\) ' '^   Decision   [0-9]+ words' \
  '^   Link   ■ Alpha  drive\.example\.org' '^   Link   ■ setup  status\.example\.org' \
  '│  Report  Scout report: the quiz format in a local file ' \
  '│ Saturday 19 September 2026, [0-9]+ words, project Alpha ' \
  '│ What we found ' '│   • First finding with bold words and a code span ' \
  '│   • Second finding, see the course page \(https://example\.org/course\) ' \
  '│     1\. A nested numbered step ' '│ Option +│ Cost ' '│ Rebuild +│ two days '; do
  grep -Eq "$want" <<<"$O" || fail "the Docs view shows: $want"
done
ON=$(mc "$HOME_DIR" frame --agents "$AGENTS" --view docs --size 96x40) || fail "narrow docs frame failed"
para=$(grep -A6 '│ A long opening paragraph' <<<"$ON")
grep -q 'longer still' <<<"$(head -1 <<<"$para")" && fail "a long paragraph wraps to the reader's width"
grep -q 'longer still' <<<"$para" || fail "the wrapped paragraph carries on, joining its source lines, got: $para"
for V in "$M" "$D" "$O" "$ON"; do
  grep -Eq 'secret instructions|brief\.md|data/|notes\.md' <<<"$V" && fail "no brief and no file path may appear"
  grep -q "$TMP_ROOT" <<<"$V" && fail "no raw path may reach the Memory or Docs views"
  grep -Eq '\b(d4|q2|lone-study|loose-key|loose)\b' <<<"$V" && fail "no task id may reach the Memory or Docs views"
  grep -q '—' <<<"$V" && fail "the Memory and Docs views never show an em dash"
done
pass "the Docs view lists reports, decisions and links with kinds, counts, project tags and a Markdown reader"

PYTHONPATH="$ROOT/bin" FM_BRIDGE_NOW=2026-09-20T10:00:00 PATH="$FAKEBIN:$PATH" python3 - "$HOME_DIR" <<'PY' \
  || fail "decision titles, an empty table or a sideways wheel went wrong"
import os
import sys
import fm_mission_control as mc
keys = {"loose-key", "q2", "follow"}
for heading, want in [("# Decision: sign-in - which provider we use", "Sign-in - which provider we use"),
                      ("# Decision: follow-up plan", "Follow-up plan"), ("# q2-rollout plan", "Q2-rollout plan"),
                      ("# Decision: q2: keep it short", "Keep it short"),
                      ("# Follow-up", "Follow-up"), ("# Decision: q2 - keep it private", "Keep it private"),
                      ("# loose-key", "A decision"),
                      ("# Decision needed on pricing: option A", "Decision needed on pricing: option A"),
                      ("# Decision on the quiz - keep it: yes", "Decision on the quiz - keep it: yes"),
                      ("# Captain's decisions: use the new deck", "Use the new deck"),
                      ("# Decision: API keys for the class site", "API keys for the class site"),
                      ("# AI tutor pilot", "AI tutor pilot"), ("# ACTION: API change", "A decision: API change"),
                      ("# Decision: q2 - ACTION: KEEP the old deck", "A decision: keep the old deck"),
                      ("# Action plan for the rollout", "Action plan for the rollout"),
                      ("# Decision: Action items for Monday", "Action items for Monday"),
                      ("# ACTION:", "A decision"), ("# ACTION FIX the quiz", "A decision: fix the quiz")]:
    got = mc._decision_title(heading + "\n", None, keys)
    assert got == want, (heading, got)
assert mc.render_markdown("|---|---|\n\nAfter.", 40)
home = os.path.realpath(sys.argv[1])
model = mc.bridge.collect(home, home + "/config", mc.bridge._now())
scene, ui = mc.Scene(), mc.UI()
scene.observe(model, mc.build_crew(model, [], home, fm_name="Denver"), 50)
ui.view = "docs"
mc.compose(scene, mc.Renderer(), ui, 170, 50, mc.bridge._now())
assert not mc._handle_input(b"\x1b[<66;80;20M\x1b[<67;80;20M\x1b[<67;5;8M", ui, scene, None), (ui.scroll, ui.pages)
assert mc._handle_input(b"\x1b[<65;80;20M", ui, scene, None) and ui.scroll == 3, ui.scroll
assert not mc._handle_input(b"\x1b[<0;13;4M", ui, scene, None) and ui.doc_tag == 0, ui.doc_tag
PY
pass "decision titles keep real words, an empty table renders, and only the vertical wheel scrolls"

# A report with pictures and HTML reads as plain lines in the Docs reader.
PIC="$TMP_ROOT/picship"
mkdir -p "$PIC/data/pics" "$PIC/state" "$PIC/config"
cat > "$PIC/data/pics/report.md" <<'MD'
# Pictures in a report

![The staff Students table](figures/fig4-flags.png)

A line with a linked picture [![Status board](figures/fig2.png)](https://example.org/board) inline.

## Results &amp; ![logo](figures/logo.png) <b>[today](https://example.org/today)</b>

| Chart | Notes |
|---|---|
| ![Score chart](figures/c.png) | a &amp; b<br>c <b>bold</b> |

<table>
<tr><td align="center"><img src="shots/phone.png" title="Tap to zoom" width="300" alt="Phone screen while offline"></td></tr>
<tr><td align="center">Offline on a phone &amp; still scoring.</td></tr>
</table>

<!-- a note for the author,
spanning two lines -->

<details><summary>build.py</summary>

Keep `<code>` spans and `a < b` as written.

Replace <a path> and <id> before running.

![](figures/blank.png)
MD
P=$(mc "$PIC" frame --agents "$AGENTS" --view docs --size 170x50) || fail "pictures docs frame failed"
for want in '│ picture: The staff Students table +│' \
  '│ A line with a linked picture picture: Status board inline\. +│' \
  '│ picture: Phone screen while offline +│' '│ Offline on a phone & still scoring\. +│' \
  '│ build\.py +│' '│ Keep <code> spans and a < b as written\. +│' '│ picture +│' \
  '│ Replace <a path> and <id> before running\. +│' '│ Results & picture: logo today +│' \
  '│ picture: Score chart │ a & b c bold +│'; do
  grep -Eq "$want" <<<"$P" || fail "the Docs reader shows: $want"
done
grep -Eq '\.png|figures|shots/|<t[dr]|</|<img|<details|<summary|align=|&amp;|note for the author|spanning two' <<<"$P" \
  && fail "no picture file, HTML tag, entity or comment reaches the Docs reader, got: $(grep -E 'png|<|&amp;|note' <<<"$P")"
pass "the Docs reader shows a picture as its caption and drops HTML tags and comments"


# Important links: the System Map and the Bridge from the Bridge's recorded address, the public page from
# its repository setting, then the saved links, pinned above the documents with full addresses to tap.
printf '100.64.0.9 7373 tailscale\n' > "$HOME_DIR/state/bridge.addr"
cp "$HOME_DIR/config/mission-control.json" "$TMP_ROOT/mc-settings.keep" 2>/dev/null || true
jq '. + {public_page: {repository: "Octo/crew-office"}}' "$TMP_ROOT/mc-settings.keep" 2>/dev/null \
  > "$HOME_DIR/config/mission-control.json" || printf '{"public_page": {"repository": "Octo/crew-office"}}\n' \
  > "$HOME_DIR/config/mission-control.json"
IL=$(mc "$HOME_DIR" frame --agents "$AGENTS" --view docs --size 170x50 --keys $'\e[A\e[A\e[A\e[A\e[A\e[A') \
  || fail "docs frame with important links failed"
grep -Eq '^IMPORTANT LINKS 5 ' <<<"$IL" || fail "the Important links group heads the Docs list: $(sed -n 5,7p <<<"$IL")"
grep -A1 '^IMPORTANT LINKS' <<<"$IL" | grep -Eq '^(▸ |  )System Map ' || fail "the System Map is the first important link: $(grep -A3 '^IMPORTANT LINKS' <<<"$IL")"
grep -q '^DOCUMENTS 4 ' <<<"$IL" || fail "the documents follow under their own heading"
grep -q '│ http://100.64.0.9:7373/system-map ' <<<"$IL" || fail "the System Map's full address is printed to tap"
grep -q '│ An important link ' <<<"$IL" || fail "a pinned address says it is an important link"
ILJ=$(mc "$HOME_DIR" frame --agents "$AGENTS" --view docs --size 170x50 --format json) || fail "docs json failed"
[ "$(jq -r '[.docs.rows[] | select(.kind == "Link") | .title] | join(",")' <<<"$ILJ")" \
  = "System Map,The Bridge page,Public Mission Control page,Class Drive folder,Status page" ] \
  || fail "important links run System Map, Bridge, public page, then the saved links: $(jq -c .docs.rows <<<"$ILJ")"
DOC1=$(jq -r '[.docs.rows[] | select(.kind != "Link") | .title][0]' <<<"$ILJ")
DOC2=$(jq -r '[.docs.rows[] | select(.kind != "Link") | .title][1]' <<<"$ILJ")
OPEN=$(mc "$HOME_DIR" frame --agents "$AGENTS" --view docs --size 170x50) || fail "docs frame failed"
grep '^▸' <<<"$OPEN" | grep -qF "▸ ${DOC1:0:20}" || fail "Docs opens on the newest document, $DOC1: $(grep '^▸' <<<"$OPEN")"
DOWN=$(mc "$HOME_DIR" frame --agents "$AGENTS" --view docs --size 170x50 --keys $'\e[B') || fail "docs down failed"
grep '^▸' <<<"$DOWN" | grep -qF "▸ ${DOC2:0:20}" || fail "one Down moves from the newest document to $DOC2: $(grep '^▸' <<<"$DOWN")"
UP=$(mc "$HOME_DIR" frame --agents "$AGENTS" --view docs --size 170x50 --keys $'\e[A') || fail "docs up failed"
grep -q '^▸ Status page ' <<<"$UP" || fail "one Up moves from the newest document to the last important link: $(grep '^▸' <<<"$UP")"
PUB=$(mc "$HOME_DIR" frame --agents "$AGENTS" --view docs --size 170x50 --keys $'\e[A\e[A\e[A\e[A\e[A\e[A\e[B\e[B')
grep -q '│ https://octo.github.io/crew-office/ ' <<<"$PUB" || fail "the public page's address comes from its repository setting"
mv "$TMP_ROOT/mc-settings.keep" "$HOME_DIR/config/mission-control.json" 2>/dev/null || rm -f "$HOME_DIR/config/mission-control.json"
rm -f "$HOME_DIR/state/bridge.addr"
pass "the Docs view pins the System Map, the Bridge, the public page and the saved links first"

SM=$(mc "$HOME_DIR" frame --readings "$TMP_ROOT/ok.json" --agents "$AGENTS" --view system --size 170x50) \
  || fail "system frame with the map card failed"
for want in '● SYSTEM MAP ' 'Open in Safari' '│ http://ship.example.ts.net:7373/system-map '; do
  grep -Eq "$want" <<<"$SM" || fail "the System view's map card shows: $want"
done
[ "$(dot "$(sys_frame "$TMP_ROOT/ok.json" "" json)" "System Map")" = green ] || fail "a running Bridge gives the map a green dot"
readings "$TMP_ROOT/map-unread.json" 'del(.bridge)'
MJ=$(sys_frame "$TMP_ROOT/map-unread.json" "" json)
[ "$(dot "$MJ" "System Map")" = grey ] || fail "the map card is grey while the Bridge is not read yet"
readings "$TMP_ROOT/map-bad.json" '.bridge = null'
MJ=$(sys_frame "$TMP_ROOT/map-bad.json" "" json)
[ "$(dot "$MJ" "System Map")" = amber ] || fail "the map card is amber when the Bridge cannot be checked"
jq -r '.system.cards[] | select(.title == "System Map") | .head' <<<"$MJ" | grep -q 'could not be checked' \
  || fail "the map card says its address could not be checked"
jq -r .system.overall <<<"$MJ" | grep -q 'needs a look' || fail "an unchecked Bridge is reported, not still checking"
readings "$TMP_ROOT/map-down.json" '.bridge = {running: false, address: null, local_only: false}'
MJ=$(sys_frame "$TMP_ROOT/map-down.json" "" json)
[ "$(dot "$MJ" "System Map")" = amber ] || fail "the map card is amber while the Bridge is down"
jq -r '.system.cards[] | select(.title == "System Map") | .head' <<<"$MJ" | grep -q 'once the Bridge page answers' \
  || fail "the map card says it opens once the Bridge answers"
pass "the System view gives the System Map's address, its dot following the Bridge's reading"

[ "$(jq -r '[.system.cards[] | select(.title == "Public page")] | length' <<<"$SJ")" = 0 ] \
  || fail "a home with no public page shows no public page card"
readings "$TMP_ROOT/pub.json" '.public_page = {address: "https://crew-office.pages.dev/"}'
PJ=$(sys_frame "$TMP_ROOT/pub.json" "" json)
[ "$(jq -r '[.system.cards[].title] | .[-2:] | join(",")' <<<"$PJ")" = "System Map,Public page" ] \
  || fail "the public page card sits beside the System Map card: $(jq -c '[.system.cards[].title]' <<<"$PJ")"
[ "$(dot "$PJ" "Public page")" = green ] || fail "a known public address gives a green dot"
PT=$(sys_frame "$TMP_ROOT/pub.json")
grep -q '│ https://crew-office.pages.dev/ ' <<<"$PT" || fail "the public page's full address is printed to tap: $PT"
grep -q 'more below' <<<"$PT" && fail "the public page card fits beside the System Map card"
readings "$TMP_ROOT/pub-none.json" '.public_page = {address: null}'
PJ=$(sys_frame "$TMP_ROOT/pub-none.json" "" json)
[ "$(dot "$PJ" "Public page")" = amber ] || fail "an unknown public address is amber"
jq -r '.system.cards[] | select(.title == "Public page") | .head' <<<"$PJ" | grep -q 'not published yet' \
  || fail "an unknown public address says not published yet, never a guessed link"
jq -r .system.overall <<<"$PJ" | grep -q 'All systems normal' || fail "an unpublished public page is not a fault"
pass "the System view gives the public page's address beside the System Map's, only when the home has one"

LONG=https://octo-example-crew.github.io/mission-control-public-office/
readings "$TMP_ROOT/pub-long.json" '.public_page = {address: "'"$LONG"'"}'
PN=$(mc "$HOME_DIR" frame --readings "$TMP_ROOT/pub-long.json" --agents "$AGENTS" --view system --size 96x60) \
  || fail "narrow system frame failed"
grep -qF "│ $LONG " <<<"$PN" || fail "a long public address stays one unbroken line in a narrow pane: $PN"
grep -q '● SYSTEM MAP ' <<<"$PN" || fail "the other cards still show beside a full-width address card"
pass "a public address too long for a narrow card gets a full-width card and is never broken"

L=$(mc "$HOME_DIR" frame --agents "$AGENTS" --view docs)
grep -q ' 9 System ' <<<"$L" || fail "the tab bar shows all nine views"
S=$(mc "$HOME_DIR" frame --agents "$AGENTS" --size 80x24)
[ "$(printf '%s\n' "$S" | grep -c .)" = 1 ] || fail "a too-small pane gets exactly one line"
grep -q 'Make this pane bigger' <<<"$S" || fail "a too-small pane asks for more room"
pass "the tab bar shows all nine views and a too-small pane gets one line"

# --- the Controls tab ---------------------------------------------------------
# The one place in Mission Control that changes anything: the merge switch,
# turned over on a tap, Enter or space, in a copy of the home.
CH="$TMP_ROOT/controls-home"
cp -R "$HOME_DIR" "$CH"
CH=$(cd "$CH" && pwd)
CSET="$CH/.claude/settings.local.json"
for size in 132x44 170x50; do
  head -1 <<<"$(mc "$CH" frame --agents "$AGENTS" --size "$size")" | grep -q ' 9 System .* 0 Controls ' \
    || fail "at $size the tab bar shows all ten views, Controls last"
done
[ "$(mc "$CH" frame --agents "$AGENTS" --keys 0 --format json | jq -r .view)" = controls ] || fail "key 0 opens Controls"
T=$(mc "$CH" frame --agents "$AGENTS" --size 96x36)
for tab in '1 Office:office' '2 Tasks:tasks' '3 Asks:approvals' '4 Proj:projects' '5 Cal:calendar' \
    '6 Team:team' '7 Mem:memory' '8 Docs:docs' '9 Sys:system' '0 Ctrl:controls'; do
  head -1 <<<"$T" | grep -q " ${tab%%:*} " || fail "at 96 columns the tab bar shows ${tab%%:*}"
  [ "$(mc "$CH" frame --agents "$AGENTS" --size 96x36 --keys "$(tap_on "$T" " ${tab%%:*} ")" --format json \
    | jq -r .view)" = "${tab#*:}" ] || fail "at 96 columns tapping ${tab%%:*} opens ${tab#*:}"
done
T=$(mc "$CH" frame --agents "$AGENTS" --size 170x50)
C=$(mc "$CH" frame --agents "$AGENTS" --keys "$(tap_on "$T" ' 0 Controls ')" --size 170x50 --format json)
[ "$(jq -r .view <<<"$C")" = controls ] || fail "tapping the Controls tab opens it"
T=$(mc "$CH" frame --agents "$AGENTS" --view controls) || fail "the Controls tab failed"
grep -q 'Let Denver merge green pull requests on the workspace: OFF' <<<"$T" || fail "Controls shows the switch OFF"
grep -q 'once every check passes and there are no conflicts' <<<"$T" || fail "Controls says what ON allows, in Controls' own words"
grep -q 'Never changed yet; it starts OFF.' <<<"$T" || fail "Controls says when the switch last changed"
grep -q 'tap the switch or Enter: turn it on' <<<"$T" || fail "the footer says what a tap does"
[ ! -e "$CSET" ] || fail "showing Controls writes nothing"
for view in office tasks approvals projects calendar team memory docs system; do
  mc "$CH" frame --agents "$AGENTS" --view "$view" --keys "$ENTER $ENTER" >/dev/null || fail "keys on $view failed"
done
[ ! -e "$CSET" ] || fail "Enter and space change nothing on any other view"
mc "$CH" frame --agents "$AGENTS" --view controls --size 80x24 --keys "$ENTER $ENTER" >/dev/null \
  || fail "Enter on a too-small Controls failed"
[ ! -e "$CSET" ] || fail "Enter and space change nothing while the switch is not on screen"
CN="$TMP_ROOT/controls-no-records"
cp -R "$HOME_DIR" "$CN"
PYTHONPATH="$ROOT/bin" FM_BRIDGE_NOW=2026-09-20T10:00:00 python3 - "$CN" <<'PY' \
  || fail "Controls shows and turns the switch before the records are read"
import os
import sys
import fm_controls
import fm_mission_control as mc
home = os.path.realpath(sys.argv[1])
scene, ui = mc.Scene(), mc.UI()
ui.view, ui.controls = "controls", fm_controls.Switch(home, home + "/config")
text = mc.compose(scene, mc.Renderer(), ui, 132, 44, mc.bridge._now())[0].text()
assert "workspace: OFF" in text and "Reading the ship's records" not in text, text
mc._handle_input(b"\r", ui, scene, None)
assert ui.controls.sw["state"] == "on", ui.controls.sw
PY
C=$(mc "$CH" frame --agents "$AGENTS" --view controls --keys "$ENTER") || fail "Enter on Controls failed"
grep -q 'Turned ON: Denver may now merge green pull requests on the workspace.' <<<"$C" || fail "Enter turns it ON and says so"
[ "$(jq -r '.permissions.allow | length' "$CSET")" = 2 ] || fail "ON writes the switch's two rules through its owner"
[ "$(mc "$CH" frame --agents "$AGENTS" --view controls --format json | jq -r .controls.state)" = on ] \
  || fail "Controls reads the switch back ON"
T=$(mc "$CH" frame --agents "$AGENTS" --view controls)
grep -q 'workspace: ON' <<<"$T" || fail "Controls shows ON"
[ "$(mc "$CH" frame --agents "$AGENTS" --view controls --keys "$(tap_on "$T" 'the switch is')" --format json \
  | jq -r .controls.state)" = off ] || fail "a tap on the switch turns it OFF"
[ "$(jq -r '.permissions.allow | length' "$CSET")" = 0 ] || fail "OFF removes the two rules"
[ "$(mc "$CH" frame --agents "$AGENTS" --view controls --keys "$(tap_on "$T" 'LAST CHANGED')" --format json \
  | jq -r .controls.state)" = off ] || fail "a tap beside the switch changes nothing"
[ "$(mc "$CH" frame --agents "$AGENTS" --view controls --keys ' ' --format json | jq -r .controls.state)" = on ] \
  || fail "space turns it over too"
PYTHONPATH="$ROOT/bin" python3 -c 'import sys, fm_merge_switch as m; m.switch(sys.argv[1], False)' "$CH"
grep -q 'workspace: OFF' <<<"$(mc "$CH" frame --agents "$AGENTS" --view controls)" \
  || fail "a change made elsewhere shows on Controls"
printf '{not json' > "$CSET"
C=$(mc "$CH" frame --agents "$AGENTS" --view controls --keys "$ENTER") || fail "Enter on a bad file failed"
grep -q 'CANNOT BE READ' <<<"$C" || fail "an unreadable settings file shows plainly"
[ "$(cat "$CSET")" = '{not json' ] || fail "a tap on an unreadable file leaves it untouched"
pass "the Controls tab shows the merge switch in Controls' words and is the one place a tap or Enter changes it"

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
[ "$(day_of "$K" 'alpha: Chapter')" = 'Mon 21' ] || fail "a past completion sits on its day"
[ "$(day_of "$K" 'setup: Tidy the')" = 'Wed 23' ] || fail "today's completion sits on today"
[ "$(day_of "$K" 'beta: Book the')" = 'Fri 25' ] || fail "a hold-until date makes an item due that day"
[ "$(day_of "$K" 'alpha: Send the')" = 'Sat 26' ] || fail "a date written in a title makes it due that day"
grep -q '─ due ┐' <<<"$K" || fail "scheduled items are marked due"
grep -q '─ done ┐' <<<"$K" || fail "completions are marked done"
grep -q '│ alpha: Chapter ' <<<"$K" || fail "blocks start with their project's name"
grep -q '│ setup: Tidy ' <<<"$K" || fail "the ship's own items start with setup"
for skip in 'Review the syllabus' 'Compare the' 'staff meeting' 'Recap of' 'Due Sat' 'Print the' 'Ask Jan' \
    'Rota for' 'Lab check' 'An older handout' 'Wrap the'; do
  grep -q "$skip" <<<"$K" && fail "a guessed, past or other-week date stays off the grid: $skip"
done
grep -q '2 done, 2 due' <<<"$K" || fail "the control bar counts the week's blocks"
grep -q 'Busy day' <<<"$K" && fail "another week's completions stay off the week"
grep -q 'ALWAYS RUNNING' <<<"$K" || fail "the always-running strip has its heading"
for chip in '● Bridge running' '● Mission Control off' '● alpha asleep'; do
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
grep -q '● alpha asleep' <<<"$K" || fail "frame reads a live mate window from Herdr"
touch "$TMP_ROOT/herdr-cal-down"
K=$(herdr_cal) || fail "calendar frame with Herdr silent failed: $K"
rm -f "$TMP_ROOT/herdr-cal-down"
grep -q '● alpha unknown' <<<"$K" || fail "with Herdr silent a mate's window is unknown"
grep -q 'alpha closed' <<<"$K" && fail "with Herdr silent no mate is called closed"
rm -f "$TMP_ROOT/bridge-up"
K=$(cal 2026-10-01T10:00:00 170x50 vv) || fail "calendar frame failed: $K"
grep -q '27 September to 3 October' <<<"$K" || fail "a week across two months names both"
[ "$(day_of "$K" 'Wrap the')" = 'Wed 30' ] || fail "last month's completions still show"
grep -q '● Bridge off' <<<"$K" || fail "a Bridge with no LaunchAgent is off"
K=$(cal 2026-09-23T10:00:00 96x40 vv) || fail "narrow calendar frame failed: $K"
grep -q 'Tue 22' <<<"$K" && fail "a narrow pane starts at today"
[ "$(day_of "$K" 'beta: Hand')" = 'Sun 27' ] || fail "a narrow pane shows today and the next few days"
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
    # Every item starts with its project and a colon; a narrow pane shortens the title,
    # wrapping it under the project, but keeps every day and every project name whole.
    for tag, needle, day in (("alpha", "Chapter five slides", "21"), ("setup", "Tidy the ship's", "23"),
                             ("beta", "Book the lecture", "25"), ("alpha", "Send the grades", "26"),
                             ("beta", "Hand in the marks", "27"), ("beta", "Wrap the September", "30")):
        assert day in cells_of(T, "%s: " % tag if size == "170x50" else "%s:" % tag), (size, tag, needle)
        assert day in cells_of(T, "%s: %s" % (tag, needle[:8]) if size == "170x50" else needle[:4]), (size, needle)
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
i = next(i for i, ln in enumerate(T.split("\n")) if "alpha: Chapter" in ln)
j = T.split("\n")[i].index("alpha: Chapter")
fg = cells(A)[i][j][1]
assert fg != INK and fg[2] > fg[0], fg
assert cells(A)[i][j + 7][1] == fg, "the project name and the title share the project's colour"
i = next(i for i, ln in enumerate(T.split("\n")) if "alpha: Send" in ln)
j = T.split("\n")[i].index("alpha: Send")
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
N = bar(frame("96x36", "\x1b[Cvv", now="2026-09-29T10:00:00"))
assert re.search(r"1 to 5 October +▸ +next week", N) and "back to today" in N, N
N = bar(frame("96x36", "\x1b[Cvv\x1b[D", now="2026-09-29T10:00:00"))
assert re.search(r"24 to 28 September +▸ +last week", N) and "back to today" in N, N
N = bar(frame("96x36", "\x1b[Cvv\x1b[C", now="2026-09-29T10:00:00"))
assert re.search(r"8 to 12 October +▸ +in 2 weeks", N), N
N = bar(frame("96x36", "vv\x1b[D", now="2026-09-29T10:00:00"))
assert re.search(r"▸ +last week", N), N
N = bar(frame("96x36", "vv\x1b[D\x1b[D", now="2026-09-29T10:00:00"))
assert re.search(r"▸ +2 weeks ago", N), N
N = bar(frame("96x36", "\x1b[Cvv\x1b[D\x1b[Dt", now="2026-09-29T10:00:00"))
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

# --- project names ---------------------------------------------------------

# The names map renames a project in every view, matched ignoring case; this
# home's own repository names the setup, and a second mate takes its
# project's name with no "mate" suffix.
NAMES_CFG="$HOME_DIR/config/mission-control.json"
cp "$NAMES_CFG" "$TMP_ROOT/names.saved"
printf '{"first_mate_name": "Denver", "names": {"alpha": "Course A", "BETA": "Outreach", "homeship": "Setup"}}\n' \
  > "$NAMES_CFG"
sed 's/homeship/calship/' "$NAMES_CFG" > "$CAL/config/mission-control.json"
readings "$TMP_ROOT/names-ok.json"
NJ=$(mc "$HOME_DIR" frame --agents "$AGENTS" --format json) || fail "named office json failed"
[ "$(jq -r '[.desks[].name] | join(",")' <<<"$NJ")" = "Denver,Course A" ] \
  || fail "desk labels name the second mate by its project, got $(jq -c '[.desks[].name]' <<<"$NJ")"
[ "$(jq -r '[.team[] | select(.role == "second mate") | .name] | join(",")' <<<"$NJ")" = "Course A" ] \
  || fail "the team list names the second mate by its project"
[ "$(jq -r '[.projects[].name] | join(",")' <<<"$NJ")" = "Course A,Outreach,Setup" ] \
  || fail "project cards take the display names, the setup card included"
[ "$(jq -r '[.approvals[].name] | join(",")' <<<"$NJ")" = "Denver,Course A" ] \
  || fail "Approvals groups name the second mate by its project"
NO=$(mc "$HOME_DIR" frame --agents "$AGENTS" --size 170x50) || fail "named office failed"
grep -Eq "Course A's intern .*  Course A *\$" <<<"$NO" || fail "the team list's project column shows the display name"
grep -Eq 'Denver.s intern .*  Outreach *$' <<<"$NO" || fail "a worker on a renamed project shows its display name"
grep -q 'Course A finished Chapter' <<<"$NO" || fail "the activity column names the second mate by its project"
NB=$(mc "$HOME_DIR" frame --agents "$AGENTS" --view tasks) || fail "named tasks failed"
for tag in '■ Course A' '■ Outreach' '■ Setup'; do
  grep -q "$tag" <<<"$NB" || fail "task tags take the display names: $tag"
done
NP=$(mc "$HOME_DIR" frame --agents "$AGENTS" --view projects --size 170x50) || fail "named projects failed"
grep -Eq '│ Course A  alpha +Active  │' <<<"$NP" || fail "a renamed card keeps its repository name in soft print"
grep -q '■ Course A in charge' <<<"$NP" || fail "a card's person in charge is the second mate's project name"
NA=$(mc "$HOME_DIR" frame --agents "$AGENTS" --view approvals) || fail "named approvals failed"
grep -q '─ Course A 1 ─' <<<"$NA" || fail "an Approvals group names the second mate by its project"
grep -Eq '■ Setup +Tick a profile' <<<"$NA" || fail "the setup's decisions carry the setup's display name"
grep -q 'sits with Denver, project Setup' <<<"$NA" || fail "the decision panel names the setup by its display name"
NT=$(mc "$HOME_DIR" frame --agents "$AGENTS" --view team --size 170x50) || fail "named team failed"
for text in 'Course A' 'owns Course A' 'ABOUT COURSE A'; do
  grep -qF "$text" <<<"$NT" || fail "the Team view shows: $text"
done
NS=$(mc "$HOME_DIR" frame --readings "$TMP_ROOT/names-ok.json" --agents "$AGENTS" --view system --size 170x50) \
  || fail "named system failed"
grep -q 'Course A: window open' <<<"$NS" || fail "the System view names the second mate by its project"
NM=$(mc "$HOME_DIR" frame --agents "$AGENTS" --view memory --size 170x50) || fail "named memory failed"
grep -q 'Lessons Course A learned' <<<"$NM" || fail "Memory names a second mate's pages by its project"
PYTHONPATH="$ROOT/bin" FM_BRIDGE_NOW=2026-09-20T10:00:00 PATH="$FAKEBIN:$PATH" python3 - "$HOME_DIR" <<'PY' \
  || fail "the journal names projects and second mates by the names map"
import os
import sys
import fm_mission_control as mc
home = os.path.realpath(sys.argv[1])
model = mc.with_settings(mc.bridge.collect(home, home + "/config", mc.bridge._now()), mc.read_settings(home + "/config"))
text = "\n".join(d["text"] for d in mc.journal(model, "Denver"))
assert "## Course A" in text and "## Outreach" in text and "- Course A finished Chapter four notes." in text, text
assert "## alpha" not in text and "mate" not in text, text
PY
ND=$(mc "$HOME_DIR" frame --agents "$AGENTS" --view docs --size 170x50) || fail "named docs failed"
for want in '^   Report   ■ Course A  ' '^   Link   ■ Setup  status\.example\.org' \
  '│ Saturday 19 September 2026, [0-9]+ words, project Course A '; do
  grep -Eq "$want" <<<"$ND" || fail "the Docs view takes the display names: $want"
done
# A title that already starts with its project's name does not repeat it.
cp "$CAL/data/backlog.md" "$TMP_ROOT/cal-backlog.saved"
printf '%s\n' '- [x] n1 - Outreach flyer printed (repo: beta) (kind: ship) (done 2026-09-22)' \
  '- [x] n2 - Outreachers lunch booked (repo: beta) (kind: ship) (done 2026-09-22)' >> "$CAL/data/backlog.md"
NK=$(cal 2026-09-23T10:00:00 170x50) || fail "named month with self-named titles failed"
grep -q 'Outreach: flyer' <<<"$NK" || fail "a title's own leading project name is dropped"
grep -q 'Outreach: Outreach ' <<<"$NK" && fail "a Calendar line never repeats its project's name"
grep -q 'Outreach: Outrea' <<<"$NK" || fail "a title that only begins with the same letters keeps them"
printf '%s\n' "- [x] n3 - Outreach's poster hung (repo: beta) (kind: ship) (done 2026-09-24)" \
  '- [x] n4 - Venue booked (repo: beta) (kind: ship) (done 2026-08-14)' \
  '- [x] n5 - Chairs booked (repo: beta) (kind: ship) (done 2026-08-14)' >> "$CAL/data/backlog.md"
NK=$(cal 2026-09-23T10:00:00 170x50 vv) || fail "named week with a possessive title failed"
[ "$(day_of "$NK" "Outreach's pos")" = 'Thu 24' ] || fail "a possessive title keeps its project's name as its subject"
# Six weeks at the smallest pane leave two lines a day: a name that needs both keeps one for "+N more".
NK=$(cal 2026-09-23T10:00:00 96x36 $'\x1b[D') || fail "a six-week month at the smallest pane failed"
grep -q 'August 2026' <<<"$NK" || fail "left goes back to August"
grep -q '+1 more' <<<"$NK" || fail "a day whose first name fills its cell still counts the items it hides"
mv "$TMP_ROOT/cal-backlog.saved" "$CAL/data/backlog.md"
for size in 132x44 170x50; do
  NK=$(cal 2026-09-23T10:00:00 "$size") || fail "named month at $size failed"
  grep -q '● Course A asleep' <<<"$NK" || fail "the always-running strip names the mate by its project at $size"
  for tag in '■ Course A' '■ Outreach' '■ Setup'; do
    grep -q "$tag" <<<"$NK" || fail "the Calendar legend takes the display names at $size: $tag"
  done
  NW=$(cal 2026-09-23T10:00:00 "$size" vv) || fail "named week at $size failed"
  [ "$(day_of "$NW" '│ Course A:')" = 'Mon 21' ] || fail "a Week item starts with its project at $size"
  [ "$(day_of "$NW" '│ Setup:')" = 'Wed 23' ] || fail "the setup's Week item starts with Setup at $size"
  [ "$(day_of "$NW" '│ Outreach:')" = 'Fri 25' ] || fail "a due Week item starts with its project at $size"
done
PATH="$FAKEBIN:$PATH" FM_HOME="$CAL" python3 - "$MC" "$AGENTS" <<'PY' || fail "every Month line starts with its project, whole"
import os, re, subprocess, sys
MC, AGENTS = sys.argv[1:]
for size in ("132x44", "170x50"):
    env = dict(os.environ, FM_BRIDGE_NOW="2026-09-23T10:00:00")
    T = subprocess.run([MC, "frame", "--agents", AGENTS, "--view", "calendar", "--size", size], env=env,
                       check=True, capture_output=True, text=True).stdout
    grid = [ln for ln in T.split("\n")[10:] if ln.startswith("│")]
    items = [m.group(1) for ln in grid for m in re.finditer(r"│ [✓●] ([^│]*?) *(?=│)", ln)]
    assert items, (size, T)
    for it in items:
        assert re.match(r"(Course A|Outreach|Setup):", it), (size, it)
    # 170 columns fit the title beside the name; at 132 it wraps under the name.
    if size == "170x50":
        assert any(it.startswith("Course A: Chap") for it in items), (size, items)
    else:
        lines = T.split("\n")
        hits = [(i, ln.index("✓ Course A: ")) for i, ln in enumerate(lines) if re.search(r"✓ Course A: +│", ln)]
        assert any(lines[i + 1][j + 2:].startswith("Chapter") for i, j in hits), (size, T)
PY
mv "$TMP_ROOT/names.saved" "$NAMES_CFG"
rm -f "$CAL/config/mission-control.json"
pass "the names map renames every project in every view, and second mates by their project"

# Without a names map a project keeps its repository name, and a second mate
# takes that name.
printf '{"first_mate_name": "Denver"}\n' > "$CAL/config/mission-control.json"
DJ=$(mc "$CAL" frame --agents "$AGENTS" --format json) || fail "unnamed office json failed"
[ "$(jq -r '[.projects[].name] | join(",")' <<<"$DJ")" = "alpha,beta,homeship,The setup itself" ] \
  || fail "without a names map the cards keep the repository names"
[ "$(jq -r '[.desks[].name] | join(",")' <<<"$DJ")" = "Denver,alpha" ] \
  || fail "without a names map a second mate takes its repository's name"
DK=$(cal 2026-09-23T10:00:00 132x44) || fail "unnamed month failed"
grep -q '✓ alpha: Chapter' <<<"$DK" || fail "without a names map a Calendar line starts with the repository name"
grep -Eq 'alpha[- ]mate|Alpha mate' <<<"$DK$(mc "$CAL" frame --agents "$AGENTS" --view team --size 170x50)" \
  && fail "a second mate is never shown with a mate suffix"
# A name wider than a Week line breaks inside itself and keeps its colour on every piece.
printf '{"first_mate_name": "Denver", "names": {"alpha": "Telos_FIN1209"}}\n' > "$CAL/config/mission-control.json"
cal 2026-09-23T10:00:00 132x44 vv ansi | python3 -c '
import re, sys
rows = []
for line in sys.stdin.read().split("\n"):
    row, fg = [], None
    for m in re.finditer(r"\x1b\[([0-9;]*)m|([^\x1b])", line):
        if m.group(2) is not None:
            row.append((m.group(2), fg))
        elif len(m.group(1).split(";")) == 11:
            fg = tuple(m.group(1).split(";")[3:6])
    rows.append(row)
text = ["".join(c for c, _ in row) for row in rows]
i = next(i for i, t in enumerate(text) if "│ Telos_FIN120 " in t)
j = text[i].index("Telos_FIN120")
name = [fg for _, fg in rows[i][j:j + 12]] + [fg for _, fg in rows[i + 1][j:j + 2]]
assert text[i + 1][j:].startswith("9: Chapter"), text[i + 1]
assert len(set(name)) == 1 and rows[i + 1][j + 3][1] != name[0], (name, rows[i + 1][j + 3])
' || fail "a Week name split across lines keeps its project colour on every piece"
# A long desk label starts at the office's left edge, and one wider than its desk's room is clipped
# rather than running on under the next desk.
printf '{"first_mate_name": "Denver", "names": {"alpha": "SAP-Management-App"}}\n' > "$CAL/config/mission-control.json"
grep -q '^SAP-Management-A' <<<"$(mc "$CAL" frame --agents "$AGENTS" --size 132x44)" \
  || fail "a long desk label keeps its first letters"
printf '{"first_mate_name": "Denver", "names": {"alpha": "Social Media Marketing Livelihood"}}\n' \
  > "$CAL/config/mission-control.json"
LABEL=$(mc "$CAL" frame --agents "$AGENTS" --size 132x44 | grep -m1 '^Social Media Ma') \
  || fail "a desk label wider than its desk's room keeps its first letters"
[ -z "$(tr -d ' ' <<<"${LABEL:28:68}")" ] || fail "a desk label stays inside its desk's room, got: $LABEL"
rm -f "$CAL/config/mission-control.json"
pass "without a names map projects and second mates keep the repository names"

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

# Eight mates and no interns overflow the office's team list: the count of the rest stays.
BIG8="$TMP_ROOT/big8ship"
mkdir -p "$BIG8/state" "$TMP_ROOT/m8/data" "$TMP_ROOT/m8/state"
cp -R "$BIG/data" "$BIG/config" "$BIG8/"
printf '# Backlog\n\n## In flight\n## Queued\n## Done\n' > "$TMP_ROOT/m8/data/backlog.md"
echo "- m8-mate - Mate number 8 (home: $TMP_ROOT/m8; scope: area 8; projects: p8; added 2026-09-01)" \
  >> "$BIG8/data/secondmates.md"
jq -n '{result: {agents: []}}' > "$TMP_ROOT/none.json"
T8=$(mc "$BIG8" frame --agents "$TMP_ROOT/none.json" --size 132x44) || fail "eight-mate text failed"
grep -q '^   +2 more' <<<"$T8" || fail "a crowded list with no interns still counts the mates it cannot show"
grep -q 'none right now' <<<"$T8" && fail "the no-interns row never covers the count"

# The first mate's hidden team lines are counted as what they are.
meta "$BIG8" b1 "$TMP_ROOT/wt-b1" "$BIG8/projects/beta"
jq -n --arg home "$BIG8" '{result: {agents: [range(1; 10) as $n | {pane_id: "w5:p\($n)", agent_status: "idle",
  cwd: ($home + "/scratch"), terminal_title_stripped: "Job \($n)"}]}}' > "$TMP_ROOT/big8-helpers.json"
TH=$(mc "$BIG8" frame --agents "$TMP_ROOT/big8-helpers.json" --size 132x44 --view team) || fail "team text failed"
grep -q '├─ 4 more helpers' <<<"$TH" || fail "hidden helpers are counted as helpers"
grep -Eq 'more interns?|more:' <<<"$TH" && fail "no helper is counted as an intern"
for n in 2 3 4 5 6 7; do
  meta "$BIG8" "b$n" "$TMP_ROOT/wt-b$n" "$BIG8/projects/beta"
done
TM=$(mc "$BIG8" frame --agents "$TMP_ROOT/big8-helpers.json" --size 132x44 --view team) || fail "team text failed"
grep -q '├─ 10 more: 1 intern and 9 helpers' <<<"$TM" || fail "a mixed count names interns and helpers"
grep -Eq '(^|[^0-9])0 (interns?|helpers?)' <<<"$TH$TM" && fail "no zero count shows"
pass "a list with no room counts every row it hides, helpers as helpers"

readings "$TMP_ROOT/big-ok.json" '.mates = ([range(1; 8) | {key: "m\(.)-mate", value: 180}] | from_entries)'
BS=$(mc "$BIG" frame --readings "$TMP_ROOT/big-ok.json" --agents "$TMP_ROOT/big.json" --view system --size 96x37) \
  || fail "seven-mate system frame failed"
NOTE=$(grep 'more below' <<<"$BS") || fail "cards past the pane's height are announced"
grep -q '[└─]' <<<"$NOTE" && fail "the more-below note gets its own row, not a card's border: $NOTE"
pass "the System view announces the cards below on a row of its own"

AE=$(mc "$BIG" frame --agents "$TMP_ROOT/big.json" --view approvals) || fail "empty approvals frame failed"
grep -q 'Nothing waits on you.' <<<"$AE" || fail "with nothing waiting the view is a calm empty state"
grep -q 'THE DECISION' <<<"$AE" && fail "an empty approvals view has no detail panel"
pass "the Approvals view is calm when nothing waits on the captain"

# --- the live screen in a pseudo-terminal ----------------------------------

cat > "$FAKEBIN/herdr-list" <<SH
#!/usr/bin/env bash
[ -e "$TMP_ROOT/herdr-down" ] && exit 1
[ "\$1 \$2" = "agent list" ] && exec cat "\$DRIVE_AGENTS"
[ "\$1 \$2" = "agent focus" ] && printf '%s\n' "\$3" >> "$TMP_ROOT/live-focus.log"
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
screen "$TMP_ROOT/ap" 3 | grep -q 'asked 2 Sep, 18 days ago, sits with Denver, project Alpha' \
  || fail "the panel follows the highlight"
screen "$TMP_ROOT/ap" 4 | grep -q 'sits with Alpha, project Alpha' || fail "down crosses into the next agent and stops at the end"
screen "$TMP_ROOT/ap" 5 | grep -Eq '^ ▸ .*Approve the module outline' || fail "up moves back"
screen "$TMP_ROOT/ap" 6 | grep -Eq '^ ▸ .*Approve the module outline' || fail "enter leaves the view and the pick alone"
screen "$TMP_ROOT/ap" 6 | grep -q "opening .*'s chat" && fail "enter on Approvals moves no pane"
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

# Memory and Docs: kinds with left/right, the reader with Page Down and the
# wheel, a tapped row, and up/down on the memory list.
RIGHT=$'\e[C'
PGDN=$'\e[6~'
WHEEL_READER=$'\e[<65;80;20M'
TAP_ROW=$'\e[<0;5;8M'
code=$(DRIVE_NOW=2026-09-20T10:00:00 drive "$TMP_ROOT/shelf" \
  "4=8,5=$RIGHT,6=$PGDN,7=$WHEEL_READER,8=$TAP_ROW,9=7,10=$DOWN,11=q") || fail "the pty driver failed"
[ "$code" = 0 ] || fail "the memory and docs run quits cleanly, got exit $code"
screen "$TMP_ROOT/shelf" 2 | grep -Eq 'Report +Scout report: the quiz format' || fail "key 8 opens Docs on the newest document"
screen "$TMP_ROOT/shelf" 2 | grep -q 'A decision: fix' || fail "Docs starts on every kind"
screen "$TMP_ROOT/shelf" 3 | grep -q 'A decision: fix' && fail "right picks the Report kind, so decisions leave the list"
screen "$TMP_ROOT/shelf" 3 | grep -Eq 'lines 1 to 32 of [0-9]+' || fail "the reader starts at the top"
screen "$TMP_ROOT/shelf" 4 | grep -Eq 'lines 31 to [0-9]+ of [0-9]+' || fail "page down scrolls the reader by a page"
screen "$TMP_ROOT/shelf" 5 | grep -Eq 'lines 34 to [0-9]+ of [0-9]+' || fail "the wheel over the reader scrolls it"
screen "$TMP_ROOT/shelf" 6 | grep -Eq 'Report +A study with no task' || fail "tapping a row opens it in the reader"
screen "$TMP_ROOT/shelf" 6 | grep -q 'lines ' && fail "a newly opened page starts at its top"
screen "$TMP_ROOT/shelf" 7 | grep -q 'Sunday 20 September 2026, 22 words' || fail "key 7 opens Memory on the captain's page"
screen "$TMP_ROOT/shelf" 8 | grep -Eq '^▸ Lessons learned' || fail "down picks the next memory page"
pass "the live Memory and Docs views pick, filter, tap and scroll"

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

# A pane no record claims comes and goes as a helper in the activity feed, never as an intern.
LIVE_AGENTS="$TMP_ROOT/live-agents.json"
cp "$AGENTS" "$LIVE_AGENTS"
code=$(DRIVE_AGENTS="$LIVE_AGENTS" drive "$TMP_ROOT/helpers" \
  "2=SH:cp $AGENTS2 $LIVE_AGENTS,7=SH:cp $AGENTS $LIVE_AGENTS,12=q") || fail "the pty driver failed"
[ "$code" = 0 ] || fail "the helper run quits cleanly, got exit $code"
screen "$TMP_ROOT/helpers" 2 | grep -q 'Denver calls in a helper' || fail "a new helper arrives as a helper"
screen "$TMP_ROOT/helpers" 3 | grep -q "Denver's helper finished," || fail "a closed helper leaves as a helper"
screen "$TMP_ROOT/helpers" 3 | grep -Eq 'Denver calls in an intern|Denver.s intern finished' \
  && fail "the feed never calls a helper an intern"
pass "helpers come and go by name in the activity feed"

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
  drive "$TMP_ROOT/up" "5=SH:sed -i.bak /m6-mate/d $BIG/data/secondmates.md,14=6,16=q") || fail "the pty driver failed"
cp "$TMP_ROOT/big-mates.saved" "$BIG/data/secondmates.md"
screen "$TMP_ROOT/up" 1 | grep -q '1 upstairs, 0 working' || fail "the sixth mate starts upstairs"
screen "$TMP_ROOT/up" 2 | grep -Eq '□ p6 +second mate +retired' || fail "the upstairs mate has a retired row"
screen "$TMP_ROOT/up" 2 | grep -q 'p6 retires' || fail "the activity column shows the retirement"
screen "$TMP_ROOT/up" 2 | grep -q 'upstairs,' && fail "nobody is left upstairs"
screen "$TMP_ROOT/up" 3 | grep -A2 ' ALUMNI ' | grep -Eq 'p6 *$' || fail "the Team view's alumni row shows the retired mate"
screen "$TMP_ROOT/up" 3 | grep -A2 ' ALUMNI ' | grep -q 'retired' || fail "the alumni row says retired"
pass "a mate that leaves the registry from upstairs goes on the alumni wall"

# Up and down pick a second mate's card on the Team view and stay there.
DOWN=$'\e[B'
UP=$'\e[A'
code=$(DRIVE_HOME="$BIG" DRIVE_AGENTS="$TMP_ROOT/big.json" DRIVE_ROWS=44 \
  drive "$TMP_ROOT/pick" "3=6,4=$DOWN,5=$DOWN,6=$UP,7=q") || fail "the pty driver failed"
[ "$code" = 0 ] || fail "the team run quits cleanly, got exit $code"
for want in 2:P1 3:P2 4:P3 5:P2; do
  n=${want%%:*}
  who=${want#*:}
  screen "$TMP_ROOT/pick" "$n" | grep -q "ABOUT $who" || fail "screen $n shows the picked card $who"
  screen "$TMP_ROOT/pick" "$n" | grep -q "Mate number ${who#P}" || fail "screen $n shows $who's charter"
done
screen "$TMP_ROOT/pick" 2 | grep -q '4 more ▸' || fail "cards beyond the pane's width are counted"
# Tapping the first mate's card opens its chat and leaves the picked mate picked.
TB=$(mc "$BIG" frame --agents "$TMP_ROOT/big.json" --size 132x44 --view team) || fail "big team frame failed"
TB=$(mct "$BIG" frame --agents "$TMP_ROOT/big.json" --size 132x44 --view team \
  --keys "$DOWN$DOWN$(tap_on "$TB" "Chief of staff")") || fail "big team tap failed"
grep -q 'ABOUT P3' <<<"$TB" || fail "a tap on the first mate's card keeps P3 picked"
pass "up and down pick a second mate on the Team view"

# On the live screen a tap on the first mate's desk stands it up to talk, and
# its Open chat answer moves the captain's view to its pane.
: > "$TMP_ROOT/live-focus.log"
OPEN=$(tap_on "$(mc "$HOME_DIR" frame --agents "$AGENTS" --keys "$(tap_at 44 8)")" ' Open chat ')
code=$(drive "$TMP_ROOT/livetap" "3=$(tap_at 44 8),5=$OPEN,7=q") || fail "the pty driver failed"
[ "$code" = 0 ] || fail "the tap run quits cleanly, got exit $code"
screen "$TMP_ROOT/livetap" 2 | grep -qF ' What else? ' || fail "a live tap opens the talk box"
screen "$TMP_ROOT/livetap" 2 | grep -q 'talking' || fail "the live first mate stands up to talk"
[ "$(cat "$TMP_ROOT/live-focus.log")" = w1:p1 ] || fail "Open chat focuses the first mate's pane, got: $(cat "$TMP_ROOT/live-focus.log")"
screen "$TMP_ROOT/livetap" 3 | grep -q "opening Denver's chat" || fail "the live footer says the chat is opening"
screen "$TMP_ROOT/livetap" 3 | grep -qF ' What else? ' && fail "Open chat ends the live talk"
pass "a tap on the live office starts a talk whose Open chat opens that agent's chat"

# Paused, the scene never ticks, yet a talk still stands up and its Bye still
# sits the agent back down at once.
BYE=$(tap_on "$(mc "$HOME_DIR" frame --agents "$AGENTS" --keys "$(tap_at 44 8)")" ' Bye ')
code=$(drive "$TMP_ROOT/pausetap" "3=p,4=$(tap_at 44 8),6=$BYE,8=q") || fail "the pty driver failed"
[ "$code" = 0 ] || fail "the paused tap run quits cleanly, got exit $code"
screen "$TMP_ROOT/pausetap" 3 | grep -q 'PAUSED' || fail "p pauses the live office"
screen "$TMP_ROOT/pausetap" 3 | grep -qF ' What else? ' || fail "a paused tap opens the talk box"
screen "$TMP_ROOT/pausetap" 4 | grep -qF ' What else? ' && fail "a paused Bye ends the talk"
screen "$TMP_ROOT/pausetap" 4 | grep -q 'talking' && fail "after a paused Bye the desk no longer reads talking"
screen "$TMP_ROOT/pausetap" 4 | grep -q 'working' || fail "after a paused Bye the first mate is back at work"
pass "a paused office still ends a talk on Bye"

# On the live screen a tap on the corkboard opens its box and Open Tasks the
# board; key 0 then opens Controls, where Enter turns the switch over.
rm -f "$CSET"
OPENT=$(tap_on "$(mc "$CH" frame --agents "$AGENTS" --keys "$(tap_at 28 3)")" ' Open Tasks ')
code=$(DRIVE_HOME="$CH" drive "$TMP_ROOT/livething" "3=$(tap_at 28 3),5=$OPENT,7=0,9=$ENTER,11=q") \
  || fail "the pty driver failed"
[ "$code" = 0 ] || fail "the thing and Controls run quits cleanly, got exit $code"
screen "$TMP_ROOT/livething" 2 | grep -q 'The task board: ' || fail "a live tap on the corkboard opens its box"
screen "$TMP_ROOT/livething" 3 | grep -q 'WAITING ON YOU' || fail "the live Open Tasks opens the task board"
screen "$TMP_ROOT/livething" 4 | grep -q 'merge green pull requests on the workspace: OFF' || fail "key 0 opens Controls live"
screen "$TMP_ROOT/livething" 5 | grep -q 'Turned ON: Denver' || fail "Enter turns the switch over live and says so"
screen "$TMP_ROOT/livething" 5 | grep -q 'workspace: ON' || fail "the live Controls tab reads the switch back ON"
[ "$(jq -r '.permissions.allow | length' "$CSET")" = 2 ] || fail "the live turn writes the switch through its owner"
pass "live, a thing's box opens its view and Controls turns the switch over on Enter"

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
assert not any("asleep" in f["text"] or "wakes" in f["text"] for f in scene.feed), scene.feed
PY
pass "an idle pane falls asleep after SLEEP_AFTER seconds, on the desk and the team list alike, not in the activity column"

bash -n "$MC" || fail "fm-mission-control.sh has a syntax error"
pass "fm-mission-control.sh parses"
