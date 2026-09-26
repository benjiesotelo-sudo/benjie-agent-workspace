#!/usr/bin/env bash
# Fake herdr that logs EVERY call (to prove only `agent focus` is ever issued
# besides reads), serves a saved agent list, and fails focus on $GONE_PANES.
printf '%s\n' "$*" >> "$ALL_LOG"
if [ "$1 $2" = "agent list" ]; then exec cat "$DRIVE_AGENTS"; fi
if [ "$1 $2" = "agent focus" ]; then
  case " ${GONE_PANES:-} " in *" $3 "*) exit 1;; esac
fi
exit 0
