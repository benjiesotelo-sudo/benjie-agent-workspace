#!/usr/bin/env bash
# Real-Herdr E2E for Mission Control's naming step in a guarded lab session:
# docs/herdr-config.toml passes `herdr config check` and is the lab server's
# settings; the running screen (started with `fm-mission-control.sh start`)
# gives the spaces their display names and the agent windows their names and
# jobs on its own, never renames a space or a tab or a window firstmate named;
# after a lab Herdr restart the display values are gone and the window names
# are not, and the screen started again puts the display values back.
# Every Herdr call goes through bin/fm-herdr-lab.sh; the live default session
# is never touched.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
FIX="$ROOT/tests/assets/bridge"
MC="$ROOT/bin/fm-mission-control.sh"

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }
herdr workspace report-metadata --help >/dev/null 2>&1 \
  || { echo "skip: this Herdr ($(herdr --version 2>/dev/null)) has no workspace display values"; exit 0; }

# A run from inside a Herdr pane must not carry that pane's identity into the lab.
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-mc-names.XXXXXX")
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name mc-names)
cleanup() {
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null || echo "not ok - lab teardown failed for $HERDR_LAB_SESSION" >&2
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
H() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

# Herdr writes files beside its settings file, so the lab reads a copy.
CONFIG="$TMP_ROOT/herdr/config.toml"
mkdir -p "$TMP_ROOT/herdr"
cp "$ROOT/docs/herdr-config.toml" "$CONFIG"
HERDR_CONFIG_PATH="$CONFIG" herdr config check >/dev/null \
  || fail "docs/herdr-config.toml does not pass herdr config check"
pass "docs/herdr-config.toml passes herdr config check"

HOME_DIR="$TMP_ROOT/benjie-agent-workspace"
MATE="$TMP_ROOT/alpha-mate-home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects/alpha" \
  "$MATE/data" "$MATE/state" "$TMP_ROOT/wt-alpha" "$TMP_ROOT/wt-beta"
for record in projects backlog done-archive captain learnings; do
  cp "$FIX/$record.fixture" "$HOME_DIR/data/$record.md"
done
sed "s|@MATE_HOME@|$MATE|" "$FIX/secondmates.fixture" > "$HOME_DIR/data/secondmates.md"
cp "$FIX/mate-backlog.fixture" "$MATE/data/backlog.md"
printf '{"first_mate_name": "Denver", "names": {"alpha": "Alpha"}}\n' > "$HOME_DIR/config/mission-control.json"
for task in "a1|$TMP_ROOT/wt-alpha|$HOME_DIR/projects/alpha" "q1|$TMP_ROOT/wt-beta|$HOME_DIR/projects/beta"; do
  IFS='|' read -r id wt project <<<"$task"
  printf 'window=fx:%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=claude\nkind=ship\n' \
    "$id" "$id" "$wt" "$project" > "$HOME_DIR/state/$id.meta"
done

HERDR_CONFIG_PATH="$CONFIG" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >/dev/null \
  || fail "the lab session did not start"

new_space() {  # <cwd> <label> - prints the root window
  H workspace create --cwd "$1" --label "$2" --no-focus | jq -r '.result.root_pane.pane_id'
}
FM_P=$(new_space "$HOME_DIR" benjie-agent-workspace)
MATE_P=$(new_space "$MATE" 2ndmate-alpha-mate)
MATE_W=${MATE_P%%:*}
INTERN_P=$(H tab create --workspace "$MATE_W" --cwd "$TMP_ROOT/wt-alpha" --label fm-a1 --no-focus \
  | jq -r '.result.root_pane.pane_id')
HELPER_P=$(new_space "$TMP_ROOT/wt-beta" "└ q1 · p:urXKPBo5LgWV2rrMCPavcQ")
OLD_P=$(H tab create --workspace "${FM_P%%:*}" --cwd /tmp --label fm-old-job --no-focus | jq -r '.result.root_pane.pane_id')
H pane rename "$OLD_P" fm-old-job >/dev/null || fail "could not name the left-over window"
for p in "$FM_P" "$MATE_P" "$INTERN_P" "$HELPER_P" "$OLD_P"; do
  [ -n "$p" ] && [ "$p" != null ] || fail "the lab layout was not created"
done

agents_up() {
  local p
  for p in "$FM_P" "$MATE_P" "$INTERN_P" "$HELPER_P" "$OLD_P"; do
    H pane report-agent "$p" --source fm-lab --agent claude --state idle >/dev/null || fail "could not report an agent on $p"
  done
}
start_screen() {
  FM_HOME="$HOME_DIR" FM_MC_HERDR="$HERDR_LAB_HELPER run $HERDR_LAB_SESSION" "$MC" start >/dev/null \
    || fail "Mission Control did not start in the lab"
}
space_name() {  # <label>
  H workspace list | jq -r --arg l "$1" '.result.workspaces[] | select(.label == $l) | .tokens.name // ""'
}
window() {  # <pane> <field: label|job>
  H pane get "$1" | jq -r --arg f "$2" 'if $f == "job" then .result.pane.tokens.job // "" else .result.pane.label // "" end'
}
named() {
  [ "$(space_name benjie-agent-workspace)" = Denver ] \
    && [ "$(space_name 2ndmate-alpha-mate)" = Alpha ] \
    && [ "$(space_name mission-control)" = "Mission Control" ] \
    && [ "$(space_name "└ q1 · p:urXKPBo5LgWV2rrMCPavcQ")" = "└ Denver's intern · Print the handouts" ] \
    && [ "$(window "$INTERN_P" job)" = "Build chapter four" ]
}
wait_named() {
  local i=0
  while [ $i -lt 60 ]; do
    named && return 0
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}
labels() {
  { H workspace list | jq -r '.result.workspaces[] | .workspace_id + " " + .label'
    H tab list | jq -r '.result.tabs[] | .tab_id + " " + .label'; } | sort
}

agents_up
BEFORE=$(labels)
start_screen
wait_named || fail "the running screen did not name the spaces: $(H workspace list | jq -c '[.result.workspaces[] | {label, tokens}]')"
for triple in "$FM_P|Denver|first mate" "$MATE_P|Alpha|second mate" "$INTERN_P|Alpha's intern|Build chapter four" \
  "$HELPER_P|Denver's intern|Print the handouts"; do
  IFS='|' read -r p who job <<<"$triple"
  [ "$(window "$p" label)" = "$who" ] || fail "window $p should be named '$who', is '$(window "$p" label)'"
  [ "$(window "$p" job)" = "$job" ] || fail "window $p should show job '$job', shows '$(window "$p" job)'"
done
[ "$(window "$OLD_P" label)" = fm-old-job ] || fail "a window firstmate named was renamed"
AFTER=$(labels)
while IFS= read -r line; do
  grep -F -x -q "$line" <<<"$AFTER" || fail "a space or tab changed its name or closed: $line"
done <<<"$BEFORE"
pass "the running screen names spaces and agent windows in the lab and renames no space, tab or firstmate window"

"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null || fail "the guarded lab stop failed"
HERDR_CONFIG_PATH="$CONFIG" "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >/dev/null \
  || fail "the lab session did not restart"
[ -z "$(space_name benjie-agent-workspace)" ] || fail "expected the restart to drop the space display values"
[ "$(window "$FM_P" label)" = Denver ] || fail "window names should survive a Herdr restart"
pass "a lab Herdr restart drops the display values and keeps the window names"

agents_up
start_screen
wait_named || fail "the screen started again did not put the display values back"
pass "Mission Control started again after the restart puts every display value back"
