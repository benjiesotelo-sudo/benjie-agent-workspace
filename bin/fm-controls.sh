#!/usr/bin/env bash
# fm-controls.sh - Controls, the captain's switches on one tappable screen.
#
# Controls shows one switch, "Let <first mate> merge green pull requests on
# the workspace", ON or OFF, always read back from the home's settings, and
# turns it over on a tap or Enter with no confirmation.
# bin/fm_controls.py owns what the screen shows and what a tap changes, and
# bin/fm_merge_switch.py owns the settings the switch writes. It is the one
# screen that writes: Mission Control stays read-only and only reads the
# switch.
#
# Commands:
#   run                     draw the screen in this terminal until q
#   start                   ensure the current Herdr session has one workspace
#                           labelled controls whose pane runs `run`;
#                           idempotent, never a second copy
#   stop                    close that workspace
#   status                  report whether the workspace exists and whether the
#                           screen is running in it
#   frame [--size <cols>x<rows>] [--format text|json|ansi]
#                           print one frame of the switch as it reads now,
#                           changing nothing (tests, a quick look)
#
# Keys while running: a tap on the switch, Enter or space turns it over;
# q quits.
#
# start, stop and status keep the controls workspace through
# bin/fm-herdr-screen-lib.sh, whose header owns how a workspace is created,
# reused or left alone.
#
# Environment: FM_HOME selects the home whose switch is shown and changed.
# FM_CONTROLS_HERDR replaces the herdr command for start, stop and status and
# is split on spaces, so a lab can route every call through
# `bin/fm-herdr-lab.sh run <session>`. FM_MC_COLORS forces truecolor or 256
# colours, as for Mission Control, and start passes it into the pane.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_HOME="$(cd "$FM_HOME" && pwd)"
CONFIG="$FM_HOME/config"
PY="$SCRIPT_DIR/fm_controls.py"
SCREEN_NAME=fm-controls
SCREEN_LABEL=controls
SCREEN_MATCH='fm_controls[.]py run'
SCREEN_HERDR="${FM_CONTROLS_HERDR:-herdr}"
# shellcheck source=bin/fm-herdr-screen-lib.sh
. "$SCRIPT_DIR/fm-herdr-screen-lib.sh"

usage() {
  sed -n '2,/^set -eu$/p' "${BASH_SOURCE[0]}" | sed -e '/^set -eu$/d' -e 's/^# \{0,1\}//'
}

screen_run_command() {
  local cmd
  cmd="FM_HOME=$(screen_quote "$FM_HOME")"
  if [ -n "${FM_MC_COLORS:-}" ]; then
    cmd="$cmd FM_MC_COLORS=$(screen_quote "$FM_MC_COLORS")"
  fi
  printf '%s %s run' "$cmd" "$(screen_quote "$SCRIPT_DIR/fm-controls.sh")"
}

case "${1:-}" in
  run) exec python3 "$PY" run --home "$FM_HOME" --config-dir "$CONFIG" ;;
  frame) shift; exec python3 "$PY" frame --home "$FM_HOME" --config-dir "$CONFIG" "$@" ;;
  start) screen_start ;;
  stop) screen_stop ;;
  status) screen_status ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
