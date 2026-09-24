#!/usr/bin/env bash
# Behavior tests for Mission Control (bin/fm-mission-control.sh over
# bin/fm_mission_control.py): one-frame snapshots from fixture records and a
# saved `herdr agent list`, asserting desks, working and asleep states, interns
# beside the right person in charge, the second-floor sign at seven mates, the
# inbox count and the task columns; then the live screen in a pseudo-terminal,
# which must redraw only what changed and restore the terminal on q and on
# SIGTERM. The record parsers themselves are covered by fm-bridge.test.sh.
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
  PATH="$FAKEBIN:$PATH" FM_HOME="$home" FM_BRIDGE_NOW=2026-09-20T10:00:00 "$MC" "$@"
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

L=$(mc "$HOME_DIR" frame --agents "$AGENTS" --view calendar)
grep -q 'Calendar is coming next' <<<"$L" || fail "a later view shows its coming-next note"
grep -q ' 9 System ' <<<"$L" || fail "the tab bar shows all nine views"
S=$(mc "$HOME_DIR" frame --agents "$AGENTS" --size 80x24)
[ "$(printf '%s\n' "$S" | grep -c .)" = 1 ] || fail "a too-small pane gets exactly one line"
grep -q 'Make this pane bigger' <<<"$S" || fail "a too-small pane asks for more room"
pass "later views and a too-small pane each get one line"

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
  # DRIVE_HOME, DRIVE_AGENTS and DRIVE_ROWS replace the home, the agent list and the height.
  PATH="$FAKEBIN:$PATH" FM_HOME="${DRIVE_HOME:-$HOME_DIR}" DRIVE_AGENTS="${DRIVE_AGENTS:-$AGENTS}" \
    FM_MC_HERDR="$FAKEBIN/herdr-list" FM_MC_COLORS=truecolor python3 - "$MC" "$1" "$2" "${DRIVE_ROWS:-44}" <<'PY'
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

# Herdr stops answering after one good read: the notice says what is shown.
code=$(drive "$TMP_ROOT/down" "1=SH:touch $TMP_ROOT/herdr-down,6=q") || fail "the pty driver failed"
rm -f "$TMP_ROOT/herdr-down"
screen "$TMP_ROOT/down" 2 | grep -q 'showing what it' || fail "the Herdr notice says the last states are shown"
screen "$TMP_ROOT/down" 2 | grep -q 'everyone looks asleep' && fail "the Herdr notice must not claim everyone is asleep"
screen "$TMP_ROOT/down" 2 | grep -q 'working' || fail "the last known working state stays on screen"
pass "a Herdr outage keeps the last states and says so"

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
