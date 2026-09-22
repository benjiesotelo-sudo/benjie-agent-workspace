#!/usr/bin/env bash
# fm-bridge.sh - serve the Bridge, a read-only page over this home's records.
#
# The Bridge is one page with five tabs (Bridge, Board, Team & Office, Memory,
# Documents), rendered fresh from this home's records by bin/fm_bridge.py, which
# owns what is read, how it is counted, and the HTTP server. Nothing on the page
# can change anything: the server answers GET / with the page and GET /healthz
# with "ok", and every other path with 404; no request input selects a file.
#
# Commands:
#   render                  write the page to stdout (tests, a quick look)
#   start [--foreground] [--bind <addr>] [--port <n>] [--retry-fallback]
#                           serve the page; without --foreground it detaches,
#                           records its pid in state/bridge.pid, and logs to
#                           state/bridge.log
#   stop                    stop a detached server started by `start`
#   status                  report whether it answers, on which address, and
#                           whether the LaunchAgent is loaded
#   install                 write ~/Library/LaunchAgents/com.firstmate.bridge.plist
#                           with absolute paths, load it with
#                           `launchctl bootstrap gui/<uid>`, and prove it runs by
#                           waiting for its "listening" line in state/bridge.log
#   uninstall               `launchctl bootout` the job and remove the plist
#
# Address: config/bridge.json `bind` is "tailscale" (the default) or an explicit
# address. "tailscale" binds this Mac's Tailscale IPv4 address, read from
# `tailscale status --self --json` using `tailscale` on PATH or else the app
# bundle's /Applications/Tailscale.app/Contents/MacOS/Tailscale. When Tailscale
# is not running the server binds 127.0.0.1 instead, and `status` says so.
# A wildcard address (0.0.0.0, ::, *) is refused. `--bind` overrides the
# setting for one foreground run. The installed job passes --retry-fallback, so
# a server that came up before Tailscale exits after a few minutes on 127.0.0.1
# and launchd restarts it to detect Tailscale again.
#
# Settings live in config/bridge.json (gitignored; bin/fm_bridge.py owns the
# schema and writes a commented example on first use): port (default 7373),
# bind, first_mate, render_reuse_seconds, names, and links.
#
# Why bootstrap and absolute paths: `launchctl load` silently does nothing from
# an SSH session while `bootstrap` works, and launchd does not guarantee HOME,
# so the plist carries FM_HOME, HOME and PATH explicitly.
#
# Environment: FM_HOME selects the home whose records are shown.
# FM_BRIDGE_CONFIG_DIR and FM_BRIDGE_STATE_DIR relocate only the Bridge's own
# settings file and its log, pid and address files, never the records it reads.
# FM_BRIDGE_TAILSCALE names the Tailscale binary, and FM_BRIDGE_AGENT_DIR
# relocates the LaunchAgents directory.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_HOME="$(cd "$FM_HOME" && pwd)"
STATE="${FM_BRIDGE_STATE_DIR:-$FM_HOME/state}"
CONFIG="${FM_BRIDGE_CONFIG_DIR:-$FM_HOME/config}"
PY="$SCRIPT_DIR/fm_bridge.py"
LABEL=com.firstmate.bridge
AGENT_DIR="${FM_BRIDGE_AGENT_DIR:-$HOME/Library/LaunchAgents}"
PLIST="$AGENT_DIR/$LABEL.plist"
LOG="$STATE/bridge.log"
PIDFILE="$STATE/bridge.pid"
ADDRFILE="$STATE/bridge.addr"

usage() {
  sed -n '2,/^set -eu$/p' "${BASH_SOURCE[0]}" | sed -e '/^set -eu$/d' -e 's/^# \{0,1\}//'
}

die() { printf 'fm-bridge: %s\n' "$1" >&2; exit 1; }

py() { python3 "$PY" "$@"; }

setting() {  # <key> - prints one config/bridge.json value
  py setting "$1" --home "$FM_HOME" --config-dir "$CONFIG"
}

tailscale_bin() {
  if [ -n "${FM_BRIDGE_TAILSCALE:-}" ]; then
    printf '%s\n' "$FM_BRIDGE_TAILSCALE"
  elif command -v tailscale >/dev/null 2>&1; then
    command -v tailscale
  elif [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
    printf '%s\n' /Applications/Tailscale.app/Contents/MacOS/Tailscale
  fi
}

tailscale_self() {  # prints "<ipv4> <dns-name>" when Tailscale is running
  local bin
  bin=$(tailscale_bin)
  [ -n "$bin" ] || return 0
  "$bin" status --self --json 2>/dev/null | jq -r '
    select(.BackendState == "Running")
    | ([.Self.TailscaleIPs[]? | select(test("^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$"))][0]) as $ip
    | select($ip != null)
    | "\($ip) \((.Self.DNSName // "") | rtrimstr("."))"' 2>/dev/null | head -n 1
}

resolve_bind() {  # [<override>] - prints "<host> <mode>"; mode tailscale|fallback|explicit
  local want=${1:-} ts
  [ -n "$want" ] || want=$(setting bind)
  case "$want" in
    0.0.0.0|::|'*'|'[::]') die "refusing to bind a wildcard address ($want); use tailscale or one address" ;;
    ''|tailscale)
      ts=$(tailscale_self)
      if [ -n "$ts" ]; then
        printf '%s tailscale\n' "${ts%% *}"
      else
        printf '127.0.0.1 fallback\n'
      fi
      ;;
    *) printf '%s explicit\n' "$want" ;;
  esac
}

server_pid() {  # prints the detached server's pid when it is alive
  local pid
  [ -f "$PIDFILE" ] || return 0
  pid=$(cat "$PIDFILE" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  if ps -p "$pid" -o command= 2>/dev/null | grep -q 'fm_bridge.py serve'; then
    printf '%s\n' "$pid"
  fi
}

agent_loaded() {
  launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1
}

healthy() {  # <host> <port>
  curl -fsS --max-time 3 "http://$1:$2/healthz" 2>/dev/null | grep -qx ok
}

cmd_render() {
  py render --home "$FM_HOME" --config-dir "$CONFIG"
}

cmd_start() {
  local foreground=0 bind="" port="" retry=0 host mode give_up=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --foreground) foreground=1 ;;
      --bind) bind=${2:?--bind needs an address}; shift ;;
      --port) port=${2:?--port needs a number}; shift ;;
      --retry-fallback) retry=1 ;;
      *) die "unknown start option: $1" ;;
    esac
    shift
  done
  py init-config --home "$FM_HOME" --config-dir "$CONFIG"
  [ -n "$port" ] || port=$(setting port)
  case "$port" in ''|*[!0-9]*) die "port must be a number, got: $port" ;; esac
  read -r host mode <<EOF
$(resolve_bind "$bind")
EOF
  [ -n "$host" ] || exit 1
  [ "$mode" = fallback ] && [ "$retry" -eq 1 ] && give_up=300
  mkdir -p "$STATE"
  printf '%s %s %s\n' "$host" "$port" "$mode" > "$ADDRFILE"
  if [ "$mode" = fallback ]; then
    echo "fm-bridge: Tailscale is not running; binding 127.0.0.1 only, so the iPad cannot reach it" >&2
  fi
  if [ "$foreground" -eq 1 ]; then
    exec python3 "$PY" serve --home "$FM_HOME" --config-dir "$CONFIG" \
      --host "$host" --port "$port" --give-up-after "$give_up"
  fi
  if agent_loaded; then
    die "the LaunchAgent already runs the Bridge; see: fm-bridge.sh status"
  fi
  if [ -n "$(server_pid)" ]; then
    echo "fm-bridge: already running (pid $(server_pid)) on http://$host:$port/"
    return 0
  fi
  nohup python3 "$PY" serve --home "$FM_HOME" --config-dir "$CONFIG" \
    --host "$host" --port "$port" >> "$LOG" 2>&1 < /dev/null &
  printf '%s\n' "$!" > "$PIDFILE"
  local i=0
  while [ $i -lt 20 ]; do
    if healthy "$host" "$port"; then
      echo "fm-bridge: serving http://$host:$port/ (pid $(cat "$PIDFILE"))"
      return 0
    fi
    sleep 0.25
    i=$((i + 1))
  done
  die "the server did not answer on http://$host:$port/healthz; see state/bridge.log"
}

cmd_stop() {
  local pid
  pid=$(server_pid)
  if [ -z "$pid" ]; then
    if agent_loaded; then
      die "the Bridge runs under its LaunchAgent; stop it with: fm-bridge.sh uninstall"
    fi
    echo "fm-bridge: not running"
    rm -f "$PIDFILE"
    return 0
  fi
  kill "$pid"
  rm -f "$PIDFILE"
  echo "fm-bridge: stopped pid $pid"
}

cmd_status() {
  local host="" port="" mode="" ts manager="none"
  if [ -f "$ADDRFILE" ]; then
    read -r host port mode < "$ADDRFILE" || true
  fi
  if agent_loaded; then
    manager="LaunchAgent $LABEL"
  elif [ -n "$(server_pid)" ]; then
    manager="detached pid $(server_pid)"
  fi
  ts=$(tailscale_self)
  if [ -n "$host" ] && [ -n "$port" ] && healthy "$host" "$port"; then
    echo "running: yes, answering on http://$host:$port/ ($manager)"
  else
    echo "running: no answer${host:+ on http://$host:$port/} ($manager)"
  fi
  case "$mode" in
    fallback) echo "address: Tailscale was not running at start; bound to 127.0.0.1 only, so the iPad cannot reach it" ;;
    tailscale) echo "address: bound to the Tailscale address only" ;;
    explicit) echo "address: bound to the configured address $host" ;;
  esac
  if [ -n "$ts" ]; then
    echo "tailscale: running, http://${ts#* }:${port:-$(setting port)}/ (${ts%% *})"
  else
    echo "tailscale: not running"
  fi
  if [ -f "$LOG" ]; then
    echo "last log line: $(tail -n 1 "$LOG")"
  fi
}

plist_escape() {  # <text>
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

cmd_install() {
  local uid before i
  uid=$(id -u)
  py init-config --home "$FM_HOME" --config-dir "$CONFIG"
  mkdir -p "$AGENT_DIR" "$STATE"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$(plist_escape "$SCRIPT_DIR/fm-bridge.sh")</string>
    <string>start</string>
    <string>--foreground</string>
    <string>--retry-fallback</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>FM_HOME</key><string>$(plist_escape "$FM_HOME")</string>
    <key>HOME</key><string>$(plist_escape "$HOME")</string>
    <key>PATH</key><string>$(plist_escape "$PATH")</string>
    <key>LANG</key><string>en_US.UTF-8</string>
  </dict>
  <key>WorkingDirectory</key><string>$(plist_escape "$FM_HOME")</string>
  <key>StandardOutPath</key><string>$(plist_escape "$LOG")</string>
  <key>StandardErrorPath</key><string>$(plist_escape "$LOG")</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
</dict>
</plist>
EOF
  plutil -lint "$PLIST" >/dev/null || die "the written plist does not validate: $PLIST"
  if [ -n "$(server_pid)" ]; then
    cmd_stop
  fi
  launchctl bootout "gui/$uid/$LABEL" >/dev/null 2>&1 || true
  before=0
  [ -f "$LOG" ] && before=$(wc -c < "$LOG" | tr -d ' ')
  launchctl bootstrap "gui/$uid" "$PLIST" || die "launchctl bootstrap refused $PLIST"
  i=0
  while [ $i -lt 40 ]; do
    if [ -f "$LOG" ] && tail -c +"$((before + 1))" "$LOG" | grep -q 'bridge: listening on'; then
      echo "fm-bridge: installed; the job is running: $(tail -c +"$((before + 1))" "$LOG" | grep 'bridge: listening on' | tail -n 1)"
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  die "the job was registered but wrote no listening line to state/bridge.log within 20 seconds"
}

cmd_uninstall() {
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  rm -f "$PLIST"
  if agent_loaded; then
    die "launchctl still lists $LABEL after bootout"
  fi
  echo "fm-bridge: uninstalled"
}

case "${1:-}" in
  render) shift; cmd_render "$@" ;;
  start) shift; cmd_start "$@" ;;
  stop) shift; cmd_stop ;;
  status) shift; cmd_status ;;
  install) shift; cmd_install ;;
  uninstall) shift; cmd_uninstall ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
