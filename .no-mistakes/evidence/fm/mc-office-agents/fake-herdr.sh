#!/usr/bin/env bash
# Fake herdr for live evidence: serves a saved agent list, logs every focus,
# and answers "not found" for panes listed in $GONE_PANES.
if [ "$1 $2" = "agent list" ]; then exec cat "$DRIVE_AGENTS"; fi
if [ "$1 $2" = "agent focus" ]; then
  printf '%s\n' "$3" >> "$FOCUS_LOG"
  case " ${GONE_PANES:-} " in *" $3 "*) echo "pane not found" >&2; exit 1;; esac
fi
exit 0
