#!/usr/bin/env bash
# Behavior tests for Controls (bin/fm-controls.sh over bin/fm_controls.py) and
# the merge switch it sets (bin/fm_merge_switch.py), against a temporary home:
# ON adds exactly the two allow rules and keeps every other key and entry, OFF
# removes exactly them, repeated turns change nothing, a missing settings file
# is created and kept out of git, a malformed one is left byte for byte with a
# plain error on screen, and the frame shows the real state, including an edit
# made elsewhere. Then the live screen in a pseudo-terminal: Enter and a tap on
# the switch turn it over at once, a tap elsewhere does nothing, an outside
# edit shows by itself, and q and SIGTERM restore the terminal. Then start,
# status and stop against a fake Herdr, and Mission Control's one read-only
# System line for the switch.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CT="$ROOT/bin/fm-controls.sh"
MC="$ROOT/bin/fm-mission-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-controls)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$HOME_DIR/data"
HOME_DIR=$(cd "$HOME_DIR" && pwd)
git -C "$HOME_DIR" init -q
printf '{"first_mate_name": "Denver"}\n' > "$HOME_DIR/config/mission-control.json"
SETTINGS="$HOME_DIR/.claude/settings.local.json"
R1="Bash(bin/fm-pr-merge.sh *)"
R2="Bash($HOME_DIR/bin/fm-pr-merge.sh *)"

ct() {  # <args...> - Controls on the test home
  FM_HOME="$HOME_DIR" "$CT" "$@"
}
turn() {  # on|off - the switch's own write, as a tap makes it
  PYTHONPATH="$ROOT/bin" python3 -c 'import sys, fm_merge_switch as m; m.switch(sys.argv[1], sys.argv[2] == "on")' \
    "$HOME_DIR" "$1"
}
allow() {  # the allow list, one entry a line
  jq -r '.permissions.allow[]' "$SETTINGS"
}
frame_state() {
  ct frame --format json | jq -r '.state // "none"'
}

# --- the switch's file ------------------------------------------------------

[ ! -e "$SETTINGS" ] || fail "the test home starts without settings"
F=$(ct frame --size 80x30) || fail "frame with no settings file failed: $F"
grep -q 'Let Denver merge green pull requests on the workspace: OFF' <<<"$F" || fail "a missing file reads OFF under the label"
grep -q 'Never changed yet; it starts OFF.' <<<"$F" || fail "a switch never changed says so"
grep -q 'other projects still wait for you' <<<"$F" || fail "the screen says what ON allows"
[ ! -e "$SETTINGS" ] || fail "frame writes nothing"
turn off
[ ! -e "$SETTINGS" ] || fail "OFF on a missing file creates nothing"
pass "a missing settings file reads OFF and frame and OFF write nothing"

turn on
jq -e . "$SETTINGS" >/dev/null || fail "ON leaves valid JSON"
[ "$(allow)" = "$R1"$'\n'"$R2" ] || fail "ON on a missing file creates it with exactly the two rules: $(allow)"
[ "$(jq -c 'del(.permissions.allow)' "$SETTINGS")" = '{"permissions":{}}' ] || fail "a created file holds nothing else"
git -C "$HOME_DIR" check-ignore -q .claude/settings.local.json || fail "the settings file is ignored by git"
grep -qx '/.claude/settings.local.json' "$HOME_DIR/.git/info/exclude" || fail "the ignore line is in info/exclude"
git -C "$HOME_DIR" status --porcelain --untracked-files=all | grep -q '\.claude' && fail "git status shows the settings file"
[ "$(frame_state)" = on ] || fail "the frame reads ON after ON"
pass "ON on a missing file creates it with the two rules, kept out of git"

cat > "$SETTINGS" <<'JSON'
{
  "model": "opus",
  "permissions": {
    "deny": ["Task", "Agent"],
    "allow": ["Bash(ls *)", "Read(./docs/**)"],
    "defaultMode": "default"
  },
  "hooks": {"Stop": []}
}
JSON
BEFORE=$(jq -c . "$SETTINGS")
turn on
[ "$(allow)" = $'Bash(ls *)\nRead(./docs/**)\n'"$R1"$'\n'"$R2" ] || fail "ON keeps the other allow entries in order and adds the two: $(allow)"
[ "$(jq -c 'del(.permissions.allow)' "$SETTINGS")" = "$(jq -c 'del(.permissions.allow)' <<<"$BEFORE")" ] \
  || fail "ON keeps every other key"
[ "$(jq -r 'keys_unsorted | join(",")' "$SETTINGS")" = "model,permissions,hooks" ] || fail "ON keeps the key order"
ON_BYTES=$(cat "$SETTINGS")
ON_MTIME=$(stat -f %m "$SETTINGS" 2>/dev/null || stat -c %Y "$SETTINGS")
sleep 1
turn on
[ "$(cat "$SETTINGS")" = "$ON_BYTES" ] || fail "a second ON changes nothing"
[ "$(stat -f %m "$SETTINGS" 2>/dev/null || stat -c %Y "$SETTINGS")" = "$ON_MTIME" ] || fail "a second ON does not even rewrite"
turn off
[ "$(jq -c . "$SETTINGS")" = "$BEFORE" ] || fail "OFF removes exactly the two rules: $(jq -c . "$SETTINGS")"
OFF_BYTES=$(cat "$SETTINGS")
turn off
[ "$(cat "$SETTINGS")" = "$OFF_BYTES" ] || fail "a second OFF changes nothing"
for _ in 1 2 3; do turn on; turn off; done
[ "$(jq -c . "$SETTINGS")" = "$BEFORE" ] || fail "repeated turns settle back to the original"
[ -z "$(find "$HOME_DIR/.claude" -name '.settings.*')" ] || fail "no temporary file is left behind"
pass "ON adds exactly the two rules, OFF removes exactly them, and repeats change nothing"

jq --arg r "$R1" '.permissions.allow += [$r, $r]' "$SETTINGS" > "$TMP_ROOT/s" && mv "$TMP_ROOT/s" "$SETTINGS"
[ "$(frame_state)" = partial ] || fail "one rule of two reads partly on"
ct frame --size 80x30 | grep -q 'workspace: PARTLY ON' || fail "partly on shows under the label"
turn off
[ "$(jq -c . "$SETTINGS")" = "$BEFORE" ] || fail "OFF removes every copy of the rules"
pass "one rule of two reads partly on, and OFF clears every copy"

jq --arg r1 "$R1" --arg r2 "$R2" '.permissions.allow += [$r1, $r2]' "$SETTINGS" > "$TMP_ROOT/s" && mv "$TMP_ROOT/s" "$SETTINGS"
F=$(ct frame --size 80x30)
grep -q 'workspace: ON' <<<"$F" || fail "an edit made elsewhere shows as ON"
grep -q 'Changed outside this screen; the settings file was last written' <<<"$F" \
  || fail "an edit made elsewhere is not claimed as a change made here"
turn off
ct frame --size 80x30 | grep -q 'Turned OFF here' || fail "a change made here is dated as made here"
pass "the frame reads the real state, including an edit made elsewhere"

for bad in '{"permissions": {"allow": ["Bash(ls *)",]}}' '[1, 2]' '{"permissions": {"allow": "Bash(ls *)"}}' ''; do
  printf '%s' "$bad" > "$SETTINGS"
  cp "$SETTINGS" "$TMP_ROOT/bad.saved"
  if turn on 2>/dev/null; then fail "ON on a malformed file must refuse: $bad"; fi
  if turn off 2>/dev/null; then fail "OFF on a malformed file must refuse: $bad"; fi
  cmp -s "$SETTINGS" "$TMP_ROOT/bad.saved" || fail "a malformed file is left byte for byte: $bad"
  [ "$(frame_state)" = none ] || fail "a malformed file has no state: $bad"
done
printf '{"permissions": {"allow": [\n' > "$SETTINGS"
F=$(ct frame --size 80x30)
grep -q 'workspace: CANNOT BE READ' <<<"$F" || fail "a malformed file shows under the label"
grep -q 'The settings file is not valid JSON (line 2' <<<"$F" || fail "the error is in plain words, with where"
grep -q 'Nothing was changed' <<<"$F" || fail "the screen says nothing was changed"
pass "a malformed settings file is left untouched with a plain error on screen"

# --- the live screen --------------------------------------------------------

drive() {  # <out-prefix> <actions> - runs the screen at 100x30; actions: "<seconds>=<keys|TERM|SH:cmd>,..."
  # Writes <out-prefix>.raw and <out-prefix>.screens (the screen just before
  # each action) and prints the exit code.
  FM_HOME="$HOME_DIR" FM_MC_COLORS=truecolor python3 - "$CT" "$1" "$2" <<'PY'
import os, pty, re, sys, struct, fcntl, termios, time, select, signal
ct, prefix, actions = sys.argv[1:]
plan = sorted((float(t), a) for t, a in (x.split("=", 1) for x in actions.split(",")))
COLS, ROWS = 100, 30
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
    os.execvp(ct, [ct, "run"])
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
ENTER=$'\r'
# The label is one line at 100 columns, so the switch card is rows 6 to 10.
TAP=$'\e[<0;10;8M\e[<0;10;8m'
WHEEL=$'\e[<64;10;8M'
MISS=$'\e[<0;10;20M\e[<0;10;20m'

printf '%s\n' "$BEFORE" > "$SETTINGS"
# An edit made elsewhere, as another tool would make it.
cat > "$TMP_ROOT/edit.sh" <<SH
#!/usr/bin/env bash
jq --arg a '$R1' --arg b '$R2' '.permissions.allow += [\$a, \$b]' '$SETTINGS' > '$TMP_ROOT/e' && mv '$TMP_ROOT/e' '$SETTINGS'
SH
code=$(drive "$TMP_ROOT/live" "1.5=$ENTER,3=$TAP,4.5=$MISS,6=$WHEEL,7.5=SH:bash $TMP_ROOT/edit.sh,9.5=q") \
  || fail "the pty driver failed"
[ "$code" = 0 ] || fail "q quits cleanly, got exit $code"
grep -q $'\e\\[?1049h' "$TMP_ROOT/live.raw" || fail "the screen enters the alternate screen"
grep -q $'\e\\[?1006h' "$TMP_ROOT/live.raw" || fail "the screen asks for SGR mouse reporting"
[ "$(tail -c ${#RESTORE} "$TMP_ROOT/live.raw")" = "$RESTORE" ] || fail "q restores the terminal last"
screen "$TMP_ROOT/live" 1 | grep -q 'workspace: OFF' || fail "the live screen starts on the real state, OFF"
screen "$TMP_ROOT/live" 2 | grep -q 'workspace: ON' || fail "Enter turns the switch ON at once"
screen "$TMP_ROOT/live" 2 | grep -q 'Turned ON: Denver may now merge' || fail "the change is confirmed in plain words"
screen "$TMP_ROOT/live" 3 | grep -q 'workspace: OFF' || fail "a tap on the switch turns it OFF"
screen "$TMP_ROOT/live" 4 | grep -q 'workspace: OFF' || fail "a tap off the switch changes nothing"
screen "$TMP_ROOT/live" 5 | grep -q 'workspace: OFF' || fail "a wheel scroll is not a tap"
screen "$TMP_ROOT/live" 6 | grep -q 'workspace: ON' || fail "an edit made elsewhere shows by itself"
screen "$TMP_ROOT/live" 6 | grep -q 'Changed outside this screen' || fail "the outside edit is dated as made elsewhere"
[ "$(frame_state)" = on ] || fail "the file holds what the screen shows"
pass "Enter and a tap turn the switch over at once, and an outside edit shows by itself"

printf '{"permissions": ' > "$SETTINGS"
cp "$SETTINGS" "$TMP_ROOT/bad.saved"
code=$(drive "$TMP_ROOT/bad" "1.5=$ENTER,2.5=TERM") || fail "the pty driver failed"
[ "$(tail -c ${#RESTORE} "$TMP_ROOT/bad.raw")" = "$RESTORE" ] || fail "SIGTERM restores the terminal"
screen "$TMP_ROOT/bad" 1 | grep -q 'workspace: CANNOT BE READ' || fail "the live screen shows a malformed file"
screen "$TMP_ROOT/bad" 2 | grep -q 'Nothing changed: the settings file is not valid JSON' \
  || fail "Enter on a malformed file says nothing changed"
cmp -s "$SETTINGS" "$TMP_ROOT/bad.saved" || fail "Enter leaves a malformed file byte for byte"
pass "a malformed file stays untouched on the live screen, and SIGTERM restores the terminal"

# --- start, status and stop -------------------------------------------------

# A fake Herdr holding one workspace in a file: its pane is at the prompt
# until `pane run` types the screen's command into it.
FAKE="$TMP_ROOT/herdr"
WS="$TMP_ROOT/ws"
cat > "$FAKE" <<SH
#!/usr/bin/env bash
echo "\$*" >> "$TMP_ROOT/herdr.log"
case "\$1 \$2" in
  "workspace list")
    if [ -e "$WS" ]; then echo '{"result":{"workspaces":[{"workspace_id":"w9","label":"controls"}]}}'
    else echo '{"result":{"workspaces":[]}}'; fi ;;
  "workspace create") touch "$WS"; echo '{"result":{"root_pane":{"pane_id":"w9:p1"}}}' ;;
  "workspace close") rm -f "$WS" "$WS.run" ;;
  "pane list") echo '{"result":{"panes":[{"pane_id":"w9:p1"}]}}' ;;
  "pane run") printf '%s' "\$4" > "$WS.run" ;;
  "pane process-info")
    if [ -e "$WS.run" ]; then
      jq -n --arg c "python3 $ROOT/bin/fm_controls.py run --home x" \
        '{result:{process_info:{shell_pid:1,foreground_process_group_id:2,foreground_processes:[{cmdline:\$c}]}}}'
    else echo '{"result":{"process_info":{"shell_pid":1,"foreground_process_group_id":1,"foreground_processes":[]}}}'; fi ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKE"
hd_ct() { FM_HOME="$HOME_DIR" FM_CONTROLS_HERDR="$FAKE" "$CT" "$@"; }
[ "$(hd_ct status)" = "running: no (controls workspace not found)" ] || fail "status with no workspace"
[ "$(hd_ct start)" = "fm-controls: running in workspace w9 (pane w9:p1)" ] || fail "start creates and runs the screen"
grep -q "fm-controls.sh' run" "$WS.run" || fail "start types the run command: $(cat "$WS.run")"
grep -q "FM_HOME='$HOME_DIR'" "$WS.run" || fail "start passes the home into the pane"
[ "$(hd_ct start)" = "fm-controls: already running in workspace w9 (pane w9:p1)" ] || fail "start twice is a no-op"
[ "$(grep -c 'workspace create' "$TMP_ROOT/herdr.log")" = 1 ] || fail "start never makes a second workspace"
[ "$(hd_ct status)" = "running: yes, workspace w9, pane w9:p1" ] || fail "status sees the running screen"
[ "$(hd_ct stop)" = "fm-controls: closed workspace w9" ] || fail "stop closes the workspace"
[ "$(hd_ct stop)" = "fm-controls: not running (no controls workspace)" ] || fail "stop twice says not running"
pass "start keeps exactly one controls workspace running the screen; status and stop agree"

# --- Mission Control's read-only line ----------------------------------------

AGENTS="$TMP_ROOT/agents.json"
echo '{"result":{"agents":[]}}' > "$AGENTS"
line() {  # <readings-json> - the Crew card's merge switch line on the System view
  printf '%s' "$1" > "$TMP_ROOT/readings.json"
  FM_HOME="$HOME_DIR" FM_MC_HERDR=false "$MC" frame --view system --size 132x44 --agents "$AGENTS" \
    --readings "$TMP_ROOT/readings.json" --format json \
    | jq -r '.system.cards[] | select(.title == "Crew") | .lines[] | select(.text | startswith("Merge switch")) | "\(.dot) \(.text)"'
}
[ "$(line '{"merge_switch": {"state": "on", "error": null}}')" \
  = "green Merge switch ON: Denver may merge green pull requests on the workspace" ] || fail "the System view shows ON"
[ "$(line '{"merge_switch": {"state": "off", "error": null}}')" = "green Merge switch OFF: every merge waits for you" ] \
  || fail "the System view shows OFF"
line '{"merge_switch": {"state": "partial", "error": null}}' | grep -q '^amber Merge switch partly on' \
  || fail "the System view flags partly on"
line '{"merge_switch": {"state": null, "error": "the settings file is not valid JSON"}}' \
  | grep -q '^amber Merge switch could not be read: the settings file is not valid JSON' || fail "the System view flags an unreadable file"
[ -z "$(line '{}')" ] || fail "saved readings without the switch show no line"
cmp -s "$SETTINGS" "$TMP_ROOT/bad.saved" || fail "Mission Control never writes the settings file"
printf '%s\n' "$BEFORE" > "$SETTINGS"
turn on
PYTHONPATH="$ROOT/bin" python3 -c '
import sys, fm_mission_control as mc
got = mc.read_fast(sys.argv[1], [])["merge_switch"]
assert got == {"state": "on", "error": None}, got
' "$HOME_DIR" || fail "Mission Control's file reads include the switch"
pass "Mission Control's System view shows the switch's state, read only"

bash -n "$CT" || fail "fm-controls.sh has a syntax error"
pass "fm-controls.sh parses"
