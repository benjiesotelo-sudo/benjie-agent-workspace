#!/usr/bin/env bash
# fm-herdr-screen-lib.sh - keep one full-screen program running in its own
# labelled Herdr workspace; sourced by fm-mission-control.sh and fm-controls.sh.
#
# The caller sets, before calling any function:
#   SCREEN_NAME    its script name without .sh, the prefix of every message
#   SCREEN_LABEL   the workspace label
#   SCREEN_MATCH   a jq regex a foreground process's command line matches
#                  while the screen runs in a pane
#   SCREEN_HERDR   the herdr command, split on spaces
#   FM_HOME        the new workspace's working directory
# and defines screen_run_command, which prints the shell command typed into
# the pane.
#
# screen_start ensures one workspace labelled SCREEN_LABEL whose pane runs the
# screen; idempotent, never a second copy. It creates the workspace with
# `herdr workspace create --label <label> --no-focus` and types the run command
# into its root pane with `herdr pane run`. When the workspace already exists
# it looks at each pane's foreground processes (`herdr pane process-info`): a
# pane already running the screen means there is nothing to do, and a pane idle
# at its shell prompt is reused. A workspace whose panes are all busy with
# something else is left alone and reported.
# screen_stop closes that workspace; screen_status reports whether it exists
# and whether the screen runs in it, as "running: yes, ..." or "running: no ...".

screen_die() { printf '%s: %s\n' "$SCREEN_NAME" "$1" >&2; exit 1; }

screen_hd() {  # herdr, through SCREEN_HERDR
  local -a cmd
  read -r -a cmd <<<"$SCREEN_HERDR"
  "${cmd[@]}" "$@"
}

screen_need_herdr() {
  command -v jq >/dev/null 2>&1 || screen_die "jq is required"
  screen_hd workspace list >/dev/null 2>&1 || screen_die "Herdr did not answer; run this inside a Herdr session"
}

screen_quote() {  # <text> - single-quoted for the pane's shell
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

screen_workspace_id() {  # prints the workspace id, if any
  screen_hd workspace list \
    | jq -r --arg l "$SCREEN_LABEL" '[.result.workspaces[]? | select(.label == $l)][0].workspace_id // empty'
}

screen_panes() {  # <workspace>
  screen_hd pane list --workspace "$1" | jq -r '.result.panes[]?.pane_id'
}

screen_pane_runs() {  # <pane>
  screen_hd pane process-info --pane "$1" 2>/dev/null \
    | jq -e --arg re "$SCREEN_MATCH" \
      '[.result.process_info.foreground_processes[]?.cmdline // ""] | any(test($re))' >/dev/null 2>&1
}

screen_pane_at_prompt() {  # <pane> - the shell itself holds the foreground
  screen_hd pane process-info --pane "$1" 2>/dev/null \
    | jq -e '.result.process_info | .foreground_process_group_id == .shell_pid' >/dev/null 2>&1
}

screen_running_pane() {  # <workspace> - prints the pane running the screen
  local p
  for p in $(screen_panes "$1"); do
    if screen_pane_runs "$p"; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 0
}

screen_start() {
  local ws pane p i
  screen_need_herdr
  ws=$(screen_workspace_id)
  if [ -n "$ws" ]; then
    pane=$(screen_running_pane "$ws")
    if [ -n "$pane" ]; then
      echo "$SCREEN_NAME: already running in workspace $ws (pane $pane)"
      return 0
    fi
    pane=""
    for p in $(screen_panes "$ws"); do
      if screen_pane_at_prompt "$p"; then
        pane=$p
        break
      fi
    done
    [ -n "$pane" ] || screen_die "workspace $ws is labelled $SCREEN_LABEL but every pane is busy with something else; left alone"
  else
    pane=$(screen_hd workspace create --cwd "$FM_HOME" --label "$SCREEN_LABEL" --no-focus \
      | jq -r '.result.root_pane.pane_id // empty')
    [ -n "$pane" ] || screen_die "Herdr did not create the $SCREEN_LABEL workspace"
    ws=$(screen_workspace_id)
    i=0
    while [ $i -lt 20 ] && ! screen_pane_at_prompt "$pane"; do
      sleep 0.25
      i=$((i + 1))
    done
  fi
  screen_hd pane run "$pane" "$(screen_run_command)" >/dev/null || screen_die "Herdr refused to run the screen in pane $pane"
  i=0
  while [ $i -lt 40 ]; do
    if screen_pane_runs "$pane"; then
      echo "$SCREEN_NAME: running in workspace $ws (pane $pane)"
      return 0
    fi
    sleep 0.25
    i=$((i + 1))
  done
  screen_die "the screen did not start in pane $pane; read it with: herdr pane read $pane"
}

screen_stop() {
  local ws
  screen_need_herdr
  ws=$(screen_workspace_id)
  if [ -z "$ws" ]; then
    echo "$SCREEN_NAME: not running (no $SCREEN_LABEL workspace)"
    return 0
  fi
  screen_hd workspace close "$ws" >/dev/null || screen_die "Herdr refused to close workspace $ws"
  echo "$SCREEN_NAME: closed workspace $ws"
}

screen_status() {
  local ws pane
  screen_need_herdr
  ws=$(screen_workspace_id)
  if [ -z "$ws" ]; then
    echo "running: no ($SCREEN_LABEL workspace not found)"
    return 0
  fi
  pane=$(screen_running_pane "$ws")
  if [ -n "$pane" ]; then
    echo "running: yes, workspace $ws, pane $pane"
  else
    echo "running: no, workspace $ws exists but no pane runs the screen; fix with: $SCREEN_NAME.sh start"
  fi
}
