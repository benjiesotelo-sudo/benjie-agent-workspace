#!/usr/bin/env bash
# fm-mission-control.sh - Mission Control, the crew as a live read-only office.
#
# Mission Control draws the whole crew as an animated pixel-art office, plus a
# task board, a card per project, the decisions waiting on the captain, a
# week, month and year calendar, the crew as an org chart, a reader for the
# crew's memory and documents, and the health of the machine and the crew's
# plumbing, in one terminal pane; bin/fm_mission_control.py owns what it
# reads, how the crew maps onto the office, and how frames are drawn. It is
# read-only: it never writes a record, never sends keys or prompts to an
# agent, and never starts or stops one.
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
#                           calendar, team, memory, docs, or system.
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
# moves to that mate's pane. On Memory and Docs up/down pick a page and the
# reader shows it, Page Up/Page Down scroll the reader, on Docs left/right
# pick a kind of document, and Enter does nothing. Tapping a tab switches view
# when the terminal reports mouse clicks; on Memory and Docs tapping a row
# picks it and the wheel over the reader scrolls it.
#
# start, stop and status keep the mission-control workspace through
# bin/fm-herdr-screen-lib.sh, whose header owns how a workspace is created,
# reused or left alone.
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
SCREEN_NAME=fm-mission-control
SCREEN_LABEL=mission-control
SCREEN_MATCH='fm_mission_control[.]py run'
SCREEN_HERDR="${FM_MC_HERDR:-herdr}"
# shellcheck source=bin/fm-herdr-screen-lib.sh
. "$SCRIPT_DIR/fm-herdr-screen-lib.sh"

usage() {
  sed -n '2,/^set -eu$/p' "${BASH_SOURCE[0]}" | sed -e '/^set -eu$/d' -e 's/^# \{0,1\}//'
}

screen_run_command() {
  local cmd
  cmd="FM_HOME=$(screen_quote "$FM_HOME")"
  [ -n "${FM_MC_HERDR:-}" ] && cmd="$cmd FM_MC_HERDR=$(screen_quote "$FM_MC_HERDR")"
  [ -n "${FM_MC_COLORS:-}" ] && cmd="$cmd FM_MC_COLORS=$(screen_quote "$FM_MC_COLORS")"
  printf '%s %s run' "$cmd" "$(screen_quote "$SCRIPT_DIR/fm-mission-control.sh")"
}

cmd_run() {
  exec python3 "$PY" run --home "$FM_HOME" --config-dir "$CONFIG" --herdr "$SCREEN_HERDR"
}

cmd_frame() {
  exec python3 "$PY" frame --home "$FM_HOME" --config-dir "$CONFIG" --herdr "$SCREEN_HERDR" "$@"
}

case "${1:-}" in
  run) shift; cmd_run ;;
  frame) shift; cmd_frame "$@" ;;
  start) shift; screen_start ;;
  stop) shift; screen_stop ;;
  status) shift; screen_status ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
