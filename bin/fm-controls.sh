#!/usr/bin/env bash
# fm-controls.sh - Controls, the captain's switches, as a screen of their own.
#
# Controls shows one switch, "Let <first mate> merge green pull requests on
# the workspace", ON or OFF, always read back from the home's settings, and
# turns it over on a tap or Enter with no confirmation.
# bin/fm_controls.py owns what it shows and what a tap changes, and
# bin/fm_merge_switch.py owns the settings the switch writes. The switch lives
# on Mission Control's Controls tab (bin/fm-mission-control.sh), the one
# place there that changes anything; this command draws the same switch on a
# screen of its own, for any terminal, and no longer keeps a Herdr workspace.
#
# Commands:
#   run                     draw the screen in this terminal until q
#   stop                    close a workspace labelled controls left from
#                           before Controls became a Mission Control tab
#   status                  report whether that workspace exists and whether
#                           the screen is running in it
#   frame [--size <cols>x<rows>] [--format text|json|ansi]
#                           print one frame of the switch as it reads now,
#                           changing nothing (tests, a quick look)
#
# Keys while running: a tap on the switch, Enter or space turns it over;
# q quits.
#
# stop and status find the controls workspace through
# bin/fm-herdr-screen-lib.sh, whose header owns how a workspace is found and
# closed.
#
# Environment: FM_HOME selects the home whose switch is shown and changed.
# FM_CONTROLS_HERDR replaces the herdr command for stop and status and is
# split on spaces, so a lab can route every call through
# `bin/fm-herdr-lab.sh run <session>`. FM_MC_COLORS forces truecolor or 256
# colours, as for Mission Control.
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

case "${1:-}" in
  run) exec python3 "$PY" run --home "$FM_HOME" --config-dir "$CONFIG" ;;
  frame) shift; exec python3 "$PY" frame --home "$FM_HOME" --config-dir "$CONFIG" "$@" ;;
  stop) screen_stop ;;
  status) screen_status ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
