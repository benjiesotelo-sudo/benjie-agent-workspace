#!/usr/bin/env bash
# Live drive of Mission Control's plain names against a real, guarded Herdr lab session.
set -u
ROOT=/Users/benjie/.no-mistakes/worktrees/40995176e50b/01M3HK9SNT7ERFD45Q1T5RDE34
E=/Users/benjie/.no-mistakes/evidence/01M3HK9SNT7ERFD45Q1T5RDE34
PY=/tmp/fm-pyte-venv/bin/python
LAB="$ROOT/bin/fm-herdr-lab.sh"; FIX="$ROOT/tests/assets/bridge"; MC="$ROOT/bin/fm-mission-control.sh"
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-mc-drive.XXXXXX")
S=$("$LAB" name mc-drive)
cleanup() { "$LAB" teardown "$S" >/dev/null || echo "TEARDOWN FAILED $S"; rm -rf "$TMP_ROOT"; }
trap cleanup EXIT
H() { "$LAB" run "$S" "$@"; }
step() { printf '\n== %s\n' "$*"; }
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fi; }

HOME_DIR="$TMP_ROOT/benjie-agent-workspace"; MATE="$TMP_ROOT/alpha-mate-home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects/alpha" "$MATE/data" "$MATE/state" "$TMP_ROOT/wt-alpha" "$TMP_ROOT/wt-beta" "$TMP_ROOT/herdr"
for r in projects backlog done-archive captain learnings; do cp "$FIX/$r.fixture" "$HOME_DIR/data/$r.md"; done
sed "s|@MATE_HOME@|$MATE|" "$FIX/secondmates.fixture" > "$HOME_DIR/data/secondmates.md"
cp "$FIX/mate-backlog.fixture" "$MATE/data/backlog.md"
printf '{"first_mate_name": "Denver", "names": {"alpha": "Alpha"}}\n' > "$HOME_DIR/config/mission-control.json"
for t in "a1|$TMP_ROOT/wt-alpha|$HOME_DIR/projects/alpha" "q1|$TMP_ROOT/wt-beta|$HOME_DIR/projects/beta"; do
  IFS='|' read -r id wt pr <<<"$t"
  printf 'window=fx:%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=claude\nkind=ship\n' "$id" "$id" "$wt" "$pr" > "$HOME_DIR/state/$id.meta"
done

# The docs settings verbatim, except the key's command points at this lab instead of the captain's real home.
CONFIG="$TMP_ROOT/herdr/config.toml"
sed "s|^command = .*|command = \"FM_HOME=$HOME_DIR FM_MC_HERDR='$LAB run $S' $MC names > $TMP_ROOT/key.log 2>\&1\"|" "$ROOT/docs/herdr-config.toml" > "$CONFIG"
step "lab settings (docs/herdr-config.toml, key command re-pointed at the lab)"; cat "$CONFIG"
HERDR_CONFIG_PATH="$CONFIG" herdr config check && echo "PASS: herdr config check"
HERDR_CONFIG_PATH="$CONFIG" "$LAB" provision "$S" >/dev/null || { echo "provision failed"; exit 1; }

new_space() { H workspace create --cwd "$1" --label "$2" --no-focus | jq -r '.result.root_pane.pane_id'; }
FM_P=$(new_space "$HOME_DIR" benjie-agent-workspace)
MATE_P=$(new_space "$MATE" 2ndmate-alpha-mate)
INTERN_P=$(H tab create --workspace "${MATE_P%%:*}" --cwd "$TMP_ROOT/wt-alpha" --label fm-a1 --no-focus | jq -r '.result.root_pane.pane_id')
HELPER_P=$(new_space "$TMP_ROOT/wt-beta" "└ q1 · p:urXKPBo5LgWV2rrMCPavcQ")
NOTES_P=$(H tab create --workspace "${FM_P%%:*}" --cwd /tmp --label scratch --no-focus | jq -r '.result.root_pane.pane_id')
H pane rename "$NOTES_P" "my notes" >/dev/null
# Remove the lab's initial empty workspace, if any, so the sidebar shows just the crew (only the lab session).
agents_up() { for p in "$FM_P" "$MATE_P" "$INTERN_P" "$HELPER_P"; do H pane report-agent "$p" --source fm-lab --agent claude --state idle >/dev/null; done; H pane report-agent "$INTERN_P" --source fm-lab --agent claude --state working >/dev/null; }
labels() { { H workspace list | jq -r '.result.workspaces[] | .workspace_id + " " + .label'; H tab list | jq -r '.result.tabs[] | .tab_id + " " + .label'; H pane list | jq -r '.result.panes[] | .pane_id + " " + (.label // "")'; } | sort; }
tokens() { H workspace list | jq -c '[.result.workspaces[] | {label, name: .tokens.name}]'; H pane list | jq -c '[.result.panes[] | select(.tokens.who != null or .tokens.job != null) | {pane_id, label, who: .tokens.who, job: .tokens.job}]'; }
H workspace focus "${FM_P%%:*}" >/dev/null 2>&1
agents_up
BEFORE=$(labels)
step "layout before (labels)"; echo "$BEFORE"
step "display values before"; tokens

$PY "$E/capture_herdr.py" "$S" "$CONFIG" "$E/sidebar-1-before.html" "Herdr lab sidebar BEFORE any naming (docs settings installed, no display values yet)"

step "SCENARIO one-off names --dry-run, run as if from the first mate's own pane (HERDR_PANE_ID=$FM_P)"
HERDR_PANE_ID="$FM_P" FM_HOME="$HOME_DIR" FM_MC_HERDR="$LAB run $S" "$MC" names --dry-run; echo "exit $?"
check "dry run changed nothing" '[ -z "$(H pane get "$FM_P" | jq -r ".result.pane.tokens.who // empty")" ]'

step "SCENARIO one-off names, from the first mate's own pane"
HERDR_PANE_ID="$FM_P" FM_HOME="$HOME_DIR" FM_MC_HERDR="$LAB run $S" "$MC" names; echo "exit $?"
step "display values after names"; tokens
check "first mate's own window shows who Denver / job first mate" '[ "$(H pane get "$FM_P" | jq -r ".result.pane.tokens.who")/$(H pane get "$FM_P" | jq -r ".result.pane.tokens.job")" = "Denver/first mate" ]'
helper_name() { H workspace list | jq -r '.result.workspaces[] | select(.label | startswith("└")) | .tokens.name'; }
WANT_HELPER="Denver's intern · Print the handouts"
check "helper space reads plain \"$WANT_HELPER\" with no └ glyph" '[ "$(helper_name)" = "$WANT_HELPER" ]'
check "no space, tab or window label changed (captain's \"my notes\", fm-a1, └ space, 2ndmate-)" '[ "$(labels)" = "$BEFORE" ]'
step "second names run"
HERDR_PANE_ID="$FM_P" FM_HOME="$HOME_DIR" FM_MC_HERDR="$LAB run $S" "$MC" names; echo "exit $?"

$PY "$E/capture_herdr.py" "$S" "$CONFIG" "$E/sidebar-2-after-names.html" "Herdr lab sidebar AFTER bin/fm-mission-control.sh names (plain names as display values)"

step "SCENARIO Herdr restart drops display values; Ctrl+B then Alt+N puts them back"
"$LAB" stop "$S" >/dev/null; HERDR_CONFIG_PATH="$CONFIG" "$LAB" provision "$S" >/dev/null
agents_up
step "display values right after restart"; tokens
check "labels survive restart unchanged" '[ "$(labels)" = "$BEFORE" ]'
check "display values gone after restart" '[ -z "$(H pane get "$FM_P" | jq -r ".result.pane.tokens.who // empty")" ]'
$PY "$E/capture_herdr.py" "$S" "$CONFIG" "$E/sidebar-3-after-restart-and-key.html" "Herdr lab sidebar after a Herdr restart, then Ctrl+B Alt+N pressed in the attached client" '\r|\x1b|\x02|\x1bn'
step "key command output"; cat "$TMP_ROOT/key.log" 2>/dev/null || echo "(key command wrote no log)"
step "display values after the key"; tokens
check "Ctrl+B Alt+N restored the first mate's who" '[ "$(H pane get "$FM_P" | jq -r ".result.pane.tokens.who // empty")" = Denver ]'

step "SCENARIO running Mission Control screen keeps names after another restart"
"$LAB" stop "$S" >/dev/null; HERDR_CONFIG_PATH="$CONFIG" "$LAB" provision "$S" >/dev/null
agents_up
FM_HOME="$HOME_DIR" FM_MC_HERDR="$LAB run $S" "$MC" start >/dev/null && echo "screen started"
for i in $(seq 1 60); do [ "$(H pane get "$FM_P" | jq -r '.result.pane.tokens.who // empty')" = Denver ] && [ -n "$(H workspace list | jq -r '.result.workspaces[] | select(.label=="mission-control") | .tokens.name // empty')" ] && break; sleep 0.5; done
step "display values set by the running screen"; tokens
check "running screen named the first mate's window" '[ "$(H pane get "$FM_P" | jq -r ".result.pane.tokens.who // empty")" = Denver ]'
check "running screen named its own space Mission Control" '[ "$(H workspace list | jq -r ".result.workspaces[] | select(.label==\"mission-control\") | .tokens.name")" = "Mission Control" ]'
AFTER=$(labels)
check "screen renamed nothing (every earlier label still present)" '[ -z "$(comm -23 <(echo "$BEFORE") <(echo "$AFTER"))" ]'
WANT_CAP_RENAME="captain's own name"
step "captain renames the helper tab to a name of their own while the screen runs; wait 12s (two naming passes)"
H pane rename "$NOTES_P" "$WANT_CAP_RENAME" >/dev/null; sleep 12
WANT_CAP="captain's own name"
check "captain's own window name sticks under the running screen" '[ "$(H pane get "$NOTES_P" | jq -r .result.pane.label)" = "$WANT_CAP" ]'
H workspace focus "${FM_P%%:*}" >/dev/null 2>&1
$PY "$E/capture_herdr.py" "$S" "$CONFIG" "$E/sidebar-4-running-screen.html" "Herdr lab sidebar while Mission Control runs (names kept by the screen's Keeper)" '\r|\x1b'
H workspace focus "${HELPER_P%%:*}" >/dev/null 2>&1
$PY "$E/capture_herdr.py" "$S" "$CONFIG" "$E/sidebar-5-single-tab-space.html" "Focused on the one-tab helper space: no tab strip (hide_tab_bar_when_single_tab)" '\r|\x1b'
FM_HOME="$HOME_DIR" FM_MC_HERDR="$LAB run $S" "$MC" stop >/dev/null
echo "done"
