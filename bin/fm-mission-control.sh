#!/usr/bin/env bash
# fm-mission-control.sh - Mission Control, the crew as a live read-only office.
#
# Mission Control draws the whole crew as an animated pixel-art office, plus a
# task board, a card per project, the decisions waiting on the captain, a
# week, month and year calendar, the crew as an org chart and the health of
# the machine and the crew's plumbing, in one terminal pane;
# bin/fm_mission_control.py owns what it reads, how the crew maps onto the
# office, and how frames are drawn. It is read-only: it never writes a record,
# never sends keys or prompts to an agent, and never starts or stops one.
#
# Commands:
#   run                     draw the screen in this terminal until q
#   start                   ensure the current Herdr session has one workspace
#                           labelled mission-control whose pane runs `run`;
#                           idempotent, never a second copy
#   stop                    close that workspace
#   status                  report whether the workspace exists and whether the
#                           screen is running in it
#   frame [--view <v>] [--size <cols>x<rows>] [--agents <file>] [--readings <file>]
#         [--format text|json|ansi] [--keys <keys>]
#                           print one frame from the records and a saved
#                           `herdr agent list` file (tests, a quick look),
#                           or without --agents from asking Herdr once;
#                           <v> is office, tasks, approvals, projects,
#                           calendar, team, system, or a later view's
#                           name.
#                           --readings is a saved set of System readings;
#                           without it the system view reads this machine and
#                           Herdr once, and the other views leave the system
#                           unchecked. <keys> are keys and mouse taps applied
#                           first, as the terminal sends them (Enter and q
#                           are ignored)
#
# Keys while running: 1-9 switch view, p pauses the animation, q quits,
# up/down pick an agent in the team list and Enter moves your Herdr view to
# its pane (`herdr agent focus`, navigation only); on the Projects view
# up/down pick a project card instead. On the Approvals view up/down move
# the highlight through the decisions instead, and Enter does nothing: no key
# answers or changes a decision. On the calendar, left and right move one
# week, month or year, t returns to today and v cycles Week, Month and Year;
# its control bar does the same when tapped, and tapping a month in Year opens
# it. On the Team view up/down pick a second mate's card instead and Enter
# moves to that mate's pane. Tapping a tab switches view when the terminal
# reports mouse clicks.
#
# start creates the workspace with `herdr workspace create --label
# mission-control --no-focus` in this home and types the run command into its
# root pane with `herdr pane run`. When the workspace already exists it looks
# at each pane's foreground processes (`herdr pane process-info`): a pane
# already running the screen means there is nothing to do, and a pane idle at
# its shell prompt is reused. A workspace whose panes are all busy with
# something else is left alone and reported.
#
# Settings: config/mission-control.json in the home is optional; its one key,
# first_mate_name, names the first mate on screen (default "First mate").
# The screen rereads it, so an edit shows without a restart.
#
# Environment: FM_HOME selects the home whose crew and records are shown.
# FM_MC_HERDR replaces the herdr command and is split on spaces, so a lab can
# route every call through `bin/fm-herdr-lab.sh run <session>`; start passes it
# into the pane so the screen's own reads use it too. FM_MC_COLORS forces
# truecolor or 256 colours; by default what the terminal advertises decides.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_HOME="$(cd "$FM_HOME" && pwd)"
CONFIG="$FM_HOME/config"
PY="$SCRIPT_DIR/fm_mission_control.py"
LABEL=mission-control
HERDR_CMD="${FM_MC_HERDR:-herdr}"

usage() {
  sed -n '2,/^set -eu$/p' "${BASH_SOURCE[0]}" | sed -e '/^set -eu$/d' -e 's/^# \{0,1\}//'
}

die() { printf 'fm-mission-control: %s\n' "$1" >&2; exit 1; }

hd() {  # herdr, through FM_MC_HERDR when set
  local -a cmd
  read -r -a cmd <<<"$HERDR_CMD"
  "${cmd[@]}" "$@"
}

need_herdr() {
  command -v jq >/dev/null 2>&1 || die "jq is required"
  hd workspace list >/dev/null 2>&1 || die "Herdr did not answer; run this inside a Herdr session"
}

quote() {  # <text> - single-quoted for the pane's shell
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

workspace_id() {  # prints the mission-control workspace id, if any
  hd workspace list | jq -r --arg l "$LABEL" '[.result.workspaces[]? | select(.label == $l)][0].workspace_id // empty'
}

panes() {  # <workspace>
  hd pane list --workspace "$1" | jq -r '.result.panes[]?.pane_id'
}

pane_runs_screen() {  # <pane>
  hd pane process-info --pane "$1" 2>/dev/null \
    | jq -e '[.result.process_info.foreground_processes[]?.cmdline // ""] | any(test("fm_mission_control[.]py run"))' \
      >/dev/null 2>&1
}

pane_at_prompt() {  # <pane> - the shell itself holds the foreground
  hd pane process-info --pane "$1" 2>/dev/null \
    | jq -e '.result.process_info | .foreground_process_group_id == .shell_pid' >/dev/null 2>&1
}

running_pane() {  # <workspace> - prints the pane running the screen
  local p
  for p in $(panes "$1"); do
    if pane_runs_screen "$p"; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 0
}

run_command() {
  local cmd
  cmd="FM_HOME=$(quote "$FM_HOME")"
  [ -n "${FM_MC_HERDR:-}" ] && cmd="$cmd FM_MC_HERDR=$(quote "$FM_MC_HERDR")"
  [ -n "${FM_MC_COLORS:-}" ] && cmd="$cmd FM_MC_COLORS=$(quote "$FM_MC_COLORS")"
  printf '%s %s run' "$cmd" "$(quote "$SCRIPT_DIR/fm-mission-control.sh")"
}

cmd_run() {
  exec python3 "$PY" run --home "$FM_HOME" --config-dir "$CONFIG" --herdr "$HERDR_CMD"
}

cmd_frame() {
  exec python3 "$PY" frame --home "$FM_HOME" --config-dir "$CONFIG" --herdr "$HERDR_CMD" "$@"
}

cmd_start() {
  local ws pane p i
  need_herdr
  ws=$(workspace_id)
  if [ -n "$ws" ]; then
    pane=$(running_pane "$ws")
    if [ -n "$pane" ]; then
      echo "fm-mission-control: already running in workspace $ws (pane $pane)"
      return 0
    fi
    pane=""
    for p in $(panes "$ws"); do
      if pane_at_prompt "$p"; then
        pane=$p
        break
      fi
    done
    [ -n "$pane" ] || die "workspace $ws is labelled $LABEL but every pane is busy with something else; left alone"
  else
    pane=$(hd workspace create --cwd "$FM_HOME" --label "$LABEL" --no-focus | jq -r '.result.root_pane.pane_id // empty')
    [ -n "$pane" ] || die "Herdr did not create the $LABEL workspace"
    ws=$(workspace_id)
    i=0
    while [ $i -lt 20 ] && ! pane_at_prompt "$pane"; do
      sleep 0.25
      i=$((i + 1))
    done
  fi
  hd pane run "$pane" "$(run_command)" >/dev/null || die "Herdr refused to run the screen in pane $pane"
  i=0
  while [ $i -lt 40 ]; do
    if pane_runs_screen "$pane"; then
      echo "fm-mission-control: running in workspace $ws (pane $pane)"
      return 0
    fi
    sleep 0.25
    i=$((i + 1))
  done
  die "the screen did not start in pane $pane; read it with: herdr pane read $pane"
}

cmd_stop() {
  local ws
  need_herdr
  ws=$(workspace_id)
  if [ -z "$ws" ]; then
    echo "fm-mission-control: not running (no $LABEL workspace)"
    return 0
  fi
  hd workspace close "$ws" >/dev/null || die "Herdr refused to close workspace $ws"
  echo "fm-mission-control: closed workspace $ws"
}

cmd_status() {
  local ws pane
  need_herdr
  ws=$(workspace_id)
  if [ -z "$ws" ]; then
    echo "running: no ($LABEL workspace not found)"
    return 0
  fi
  pane=$(running_pane "$ws")
  if [ -n "$pane" ]; then
    echo "running: yes, workspace $ws, pane $pane"
  else
    echo "running: no, workspace $ws exists but no pane runs the screen; fix with: fm-mission-control.sh start"
  fi
}

case "${1:-}" in
  run) shift; cmd_run ;;
  frame) shift; cmd_frame "$@" ;;
  start) shift; cmd_start ;;
  stop) shift; cmd_stop ;;
  status) shift; cmd_status ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
