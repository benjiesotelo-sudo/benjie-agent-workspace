#!/usr/bin/env bash
# Behavior tests for the Bridge (bin/fm-bridge.sh over bin/fm_bridge.py): the
# registry and archive parsers against fixture files, the rendered page's
# counts on every tab from a fixture home plus a fixture second mate home, the
# read-only server's routes, and the address rules. Fixtures live in
# tests/assets/bridge/.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIDGE="$ROOT/bin/fm-bridge.sh"
FIX="$ROOT/tests/assets/bridge"
TMP_ROOT=$(fm_test_tmproot fm-bridge)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

# The fixture home's directory name matches the registered project "homeship",
# so that project's items join the ship's own card.
HOME_DIR="$TMP_ROOT/homeship"
MATE="$TMP_ROOT/alpha-mate-home"
CFG="$TMP_ROOT/bridge-config"
RUN="$TMP_ROOT/bridge-run"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
mkdir -p "$HOME_DIR/data/x" "$HOME_DIR/state" "$HOME_DIR/projects/alpha" "$HOME_DIR/config" \
  "$MATE/data/y" "$MATE/state" "$CFG" "$RUN"
HOME_DIR=$(cd "$HOME_DIR" && pwd)
cp "$FIX/projects.md" "$FIX/backlog.md" "$FIX/done-archive.md" "$FIX/captain.md" "$FIX/learnings.md" \
  "$HOME_DIR/data/"
sed "s|@MATE_HOME@|$MATE|" "$FIX/secondmates.md" > "$HOME_DIR/data/secondmates.md"
cp "$FIX/AGENTS.md" "$HOME_DIR/projects/alpha/AGENTS.md"
cp "$FIX/decision.md" "$HOME_DIR/data/x/decision-quiz-private.md"
cp "$FIX/mate-backlog.md" "$MATE/data/backlog.md"
cat > "$HOME_DIR/state/w1.meta" <<EOF
window=fx:1
endpoint_task_id=w1
worktree=$TMP_ROOT/w1-worktree
project=$HOME_DIR/projects/alpha
harness=claude
kind=ship
mode=direct-PR
yolo=off
backend=tmux
EOF
printf 'blocked: sign in to GitHub; token file at /Users/someone/secret/token.txt\n' > "$HOME_DIR/state/w1.status"
# No tmux session answers, so the worker's pane reads as gone.
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/tmux"
chmod +x "$FAKEBIN/tmux"
cat > "$CFG/bridge.json" <<'EOF'
{"port": 7373, "bind": "tailscale", "first_mate": "Denver",
 "names": {"alpha": {"title": "Alpha Course", "short": "ALPHA", "kind": "Course"}, "beta": {"short": "B<&>"}},
 "links": [{"project": "alpha", "label": "class folder", "url": "https://drive.google.com/drive/folders/abc"},
           {"project": "beta", "label": "not a web link", "url": "file:///etc/passwd"}]}
EOF

bridge() {
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_BRIDGE_CONFIG_DIR="$CFG" FM_BRIDGE_STATE_DIR="$RUN" \
    FM_BRIDGE_NOW=2026-09-20T10:00:00 "$BRIDGE" "$@"
}

# --- parsers -------------------------------------------------------------

parsed=$(PYTHONPATH="$ROOT/bin" python3 - "$HOME_DIR" <<'PY'
import json, os, sys
import fm_bridge as b
home = sys.argv[1]
read = lambda p: open(os.path.join(home, "data", p)).read()
print(json.dumps({
    "projects": b.parse_projects(read("projects.md")),
    "mates": b.parse_secondmates(read("secondmates.md")),
    "archive": b.parse_done_archive(read("done-archive.md")),
    "headings": b.headings(open(os.path.join(home, "projects/alpha/AGENTS.md")).read()),
}))
PY
) || fail "the parsers could not be driven"

[ "$(jq -r '.projects | map(.name) | join(",")' <<<"$parsed")" = "alpha,beta,homeship" ] \
  || fail "projects registry: every line should parse, in order"
[ "$(jq -r '.projects[0] | [.posture, .added, .parked, .github] | join("|")' <<<"$parsed")" \
  = "direct-PR +yolo|2026-08-01|2026-09-10|octo/alpha-repo" ] \
  || fail "projects registry: posture, added date, parked date and repository are metadata"
[ "$(jq -r '.projects[0].description' <<<"$parsed")" \
  = "Alpha course materials for a class; public repo octo/alpha-repo; decks and notes" ] \
  || fail "projects registry: the description excludes the bracket and the parenthetical"
pass "projects registry parses posture, dates and description apart"

[ "$(jq -r '.mates[0] | [.id, .home, (.projects | join(",")), .remote] | join("|")' <<<"$parsed")" \
  = "alpha-mate|$MATE|alpha|false" ] || fail "secondmates registry: id, home, projects and placement"
[ "$(jq -r '.mates[0].scope' <<<"$parsed")" = "the alpha course, its decks and its quizzes" ] \
  || fail "secondmates registry: scope may hold commas"
[ "$(jq -r '.mates | map(.id) | join(",")' <<<"$parsed")" = "alpha-mate" ] \
  || fail "secondmates registry: a record with an empty home is skipped like the owner does"
pass "secondmates registry parses the local record form"

[ "$(jq -r '.archive | map("\(.id):\(.repo):\(.completion.date)") | join(",")' <<<"$parsed")" \
  = "d3:beta:2026-09-02,d4:alpha:2026-07-20" ] || fail "done archive: ids, repos and completion dates"
[ "$(jq -r '[.headings[] | select(.[0] == 2) | .[1]] | join(",")' <<<"$parsed")" = "Build,Maintaining this file" ] \
  || fail "headings skip fenced code"
pass "done archive and memory headings parse"

# --- render --------------------------------------------------------------

PAGE="$TMP_ROOT/page.html"
bridge render > "$PAGE" || fail "render failed: $(head -c 400 "$PAGE")"

counts() {  # <scope> - prints "waiting queued in_flight done" for one card's stats
  python3 - "$PAGE" "$1" <<'PY'
import re, sys
page, scope = open(sys.argv[1]).read(), sys.argv[2]
m = re.search(r'<div class="stats four" data-scope="%s">((?:<div class="stat">.*?</div>){4})' % re.escape(scope), page)
if not m:
    print("missing"); sys.exit(0)
vals = dict(re.findall(r'data-count="([a-z_]+)">(\d+)', m.group(1)))
print(" ".join(vals.get(k, "?") for k in ("waiting", "queued", "in_flight", "done")))
PY
}
column() {  # <key>
  grep -o "<h4>[^<]*<b data-count=\"$1\">[0-9]*" "$PAGE" | sed 's/.*>//'
}
single() {  # <key>
  grep -o "data-count=\"$1\">[0-9]*" "$PAGE" | head -n 1 | sed 's/.*>//'
}

[ "$(counts alpha)" = "2 2 1 2" ] || fail "Bridge tab, alpha: got $(counts alpha); a mate's items count under their project"
[ "$(counts beta)" = "1 2 0 1" ] || fail "Bridge tab, beta: got $(counts beta); a future hold-until is queued, the archive counts"
[ "$(counts ship)" = "1 1 0 0" ] || fail "Bridge tab, ship: got $(counts ship); no-project and the home's own repo belong to the ship"
grep -q 'Alpha Course <span class="pill parked">parked</span>' "$PAGE" || fail "Bridge tab: a parked project shows its pill"
grep -q 'Course &middot; parked since 10 Sep' "$PAGE" || fail "Bridge tab: the kicker carries the parked date"
grep -q 'href="https://github.com/octo/alpha-repo"' "$PAGE" || fail "Bridge tab: the registry repository becomes a link"
grep -q 'href="https://drive.google.com/drive/folders/abc"' "$PAGE" || fail "Bridge tab: configured links appear"
grep -q 'file:///etc/passwd' "$PAGE" && fail "a non-web link must never be rendered"
pass "Bridge tab counts every project, the mate's items and the ship"

[ "$(column waiting)" = 4 ] || fail "Board tab: waiting on you, got $(column waiting)"
[ "$(column queued)" = 5 ] || fail "Board tab: queued, got $(column queued)"
[ "$(column in_flight)" = 1 ] || fail "Board tab: in flight, got $(column in_flight)"
[ "$(column "done")" = 3 ] || fail "Board tab: done this month, got $(column "done")"
grep -q '<div class="tcard blocked"><div class="p">ALPHA</div>Build the quiz once the format is chosen</div>' "$PAGE" \
  || fail "Board tab: a blocked item is marked and its blocked-by token is not shown"
grep -q 'ALPHA &middot; 5 Sep</div>Chapter three decks</div>' "$PAGE" \
  || fail "Board tab: done cards carry project and date, without the pull request address"
grep -q 'B&lt;&amp;&gt; &middot; 2 Sep</div>Module one handout</div>' "$PAGE" \
  || fail "Board tab: a done card escapes its configured project short name"
grep -q 'A note whose date carries words' "$PAGE" \
  && fail "Board tab: a Done record whose date does not parse is not done this month"
pass "Board tab columns hold every open item and this month's Done"

[ "$(single team-waiting)" = 4 ] || fail "Team tab: the captain's row counts what waits on him"
grep -q '<tr data-mate="alpha-mate"><td><span class="dot idle"></span><b>alpha-mate</b></td>' "$PAGE" \
  || fail "Team tab: a mate with no runtime records is idle"
grep -q 'Idle, 2 items in its list, 1 waiting on you' "$PAGE" || fail "Team tab: the mate's own list is counted"
grep -q '<li data-worker="w1">' "$PAGE" || fail "Office: the live worker is listed"
grep -q '<b>w1</b> &middot; alpha' "$PAGE" || fail "Office: the worker's project is named"
grep -q 'last said it was needs the first mate: sign in to GitHub; token file at a local file' "$PAGE" \
  || fail "Office: the last status reads in plain words with paths removed"
grep -q '/Users/someone' "$PAGE" && fail "Office: a raw path leaked onto the page"
[ "$(single login)" = 1 ] || fail "Office: a worker blocked on a sign in is counted"
[ "$(single prs)" = 0 ] || fail "Office: no pull request is recorded"
pass "Team and Office tab shows mates, the worker and the counters"

grep -q '3 sections, 10 lines' "$PAGE" || fail "Memory tab: captain preferences are counted"
grep -q '<li>Standing instructions</li>' "$PAGE" || fail "Memory tab: section headings are listed"
grep -q 'private sentence' "$PAGE" && fail "Memory tab: body text must never be printed"
grep -q '<h3>alpha</h3><p class="desc">2 sections' "$PAGE" || fail "Memory tab: each project's AGENTS.md has a card"
[ "$(single decision-files)" = 1 ] || fail "Memory tab: decision files are counted"
grep -q '<li>The quiz stays private (' "$PAGE" || fail "Memory tab: a decision file shows its heading"
grep -q 'in words the Bridge does not print' "$PAGE" && fail "Memory tab: decision text must never be printed"
pass "Memory tab shows headings and counts only"

grep -q '<div class="card" data-docs="alpha"><div class="kicker">Drive</div><h3>Alpha Course</h3>' "$PAGE" \
  || fail "Documents tab: configured links are grouped by project"
pass "Documents tab renders the configured links"

grep -q $'\xe2\x80\x94' "$PAGE" && fail "the page must not contain an em dash"
grep -q 'A body line that the Bridge never shows' "$PAGE" && fail "backlog bodies must never be printed"
pass "the page carries no em dash and no backlog body text"

# --- first run config ------------------------------------------------------

FRESH="$TMP_ROOT/fresh-config"
PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" python3 "$ROOT/bin/fm_bridge.py" init-config \
  --home "$HOME_DIR" --config-dir "$FRESH" 2>/dev/null || fail "init-config failed"
[ "$(jq -r '[.port, .bind] | join(" ")' "$FRESH/bridge.json")" = "7373 tailscale" ] \
  || fail "first run config: port 7373 and the Tailscale bind by default"
[ "$(jq -r '.links | map("\(.project) \(.url)") | join(",")' "$FRESH/bridge.json")" \
  = "alpha https://github.com/octo/alpha-repo" ] || fail "first run config: seeded with each project's GitHub page"
pass "first run writes an example config seeded from the registry"

# --- addresses -------------------------------------------------------------

cat > "$FAKEBIN/tailscale-up" <<'SH'
#!/usr/bin/env bash
printf '{"BackendState":"Running","Self":{"DNSName":"mac.tail.ts.net.","TailscaleIPs":["100.64.0.9","fd7a::1"]}}\n'
SH
cat > "$FAKEBIN/tailscale-down" <<'SH'
#!/usr/bin/env bash
printf '{"BackendState":"Stopped","Self":{"TailscaleIPs":[]}}\n'
SH
chmod +x "$FAKEBIN/tailscale-up" "$FAKEBIN/tailscale-down"

out=$(FM_BRIDGE_TAILSCALE="$FAKEBIN/tailscale-up" bridge start --foreground --bind 0.0.0.0 2>&1) \
  && fail "a wildcard bind must be refused"
case "$out" in *"refusing to bind a wildcard address"*) ;; *) fail "wildcard refusal should explain itself: $out" ;; esac
pass "a wildcard address is refused"

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
# Started directly, not through the bridge() function, so $! is the server itself
# (the script execs python) and killing it frees the port.
PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_BRIDGE_CONFIG_DIR="$CFG" FM_BRIDGE_STATE_DIR="$RUN" \
  FM_BRIDGE_TAILSCALE="$FAKEBIN/tailscale-down" "$BRIDGE" start --foreground --port "$PORT" > "$RUN/fg.log" 2>&1 &
SERVER=$!
trap 'kill "$SERVER" 2>/dev/null; fm_test_cleanup' EXIT
i=0
until curl -fsS --max-time 2 "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; do
  i=$((i + 1)); [ $i -lt 40 ] || fail "the server never answered: $(cat "$RUN/fg.log")"
  sleep 0.25
done
grep -q 'Tailscale is not running; binding 127.0.0.1 only' "$RUN/fg.log" \
  || fail "start should say it fell back to 127.0.0.1"
status=$(FM_BRIDGE_TAILSCALE="$FAKEBIN/tailscale-down" bridge status)
case "$status" in *"bound to 127.0.0.1 only, so the iPad cannot reach it"*) ;; *) fail "status should report the fallback: $status" ;; esac
pass "without Tailscale the server binds 127.0.0.1 and status says so"

[ "$(curl -fsS "http://127.0.0.1:$PORT/healthz")" = ok ] || fail "/healthz answers ok"
code=$(curl -s -o "$TMP_ROOT/served.html" -w '%{http_code}' "http://127.0.0.1:$PORT/")
[ "$code" = 200 ] || fail "GET / should answer 200, got $code"
grep -q '<title>The Bridge</title>' "$TMP_ROOT/served.html" || fail "GET / serves the page"
for path in /data/backlog.md /state/w1.meta /../../etc/passwd /index.html /static/; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --path-as-is "http://127.0.0.1:$PORT$path")
  [ "$code" = 404 ] || fail "GET $path must be 404, got $code"
done
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/")
[ "$code" = 501 ] || fail "POST must be refused, got $code"
pass "the server serves only the page and the health check"

# --- LaunchAgent -----------------------------------------------------------
# A stand-in launchctl runs the plist's program with only the plist's own
# environment, the way launchd does, so the proof that the job wrote its
# listening line also proves the plist's absolute paths and variables suffice.

kill "$SERVER" 2>/dev/null
wait "$SERVER" 2>/dev/null
if ! command -v plutil >/dev/null 2>&1; then
  echo "skip: plutil not found; LaunchAgent install not exercised"
  exit 0
fi
AGENTS="$TMP_ROOT/LaunchAgents"
cat > "$FAKEBIN/launchctl" <<'SH'
#!/usr/bin/env bash
set -u
jobs="${FAKE_LAUNCHD_DIR:?}"
mkdir -p "$jobs"
case "$1" in
  bootstrap)
    json=$(plutil -convert json -o - "$3") || exit 5
    label=$(printf '%s' "$json" | jq -r .Label)
    log=$(printf '%s' "$json" | jq -r .StandardOutPath)
    envs=()
    while IFS= read -r kv; do envs+=("$kv"); done < <(printf '%s' "$json" | jq -r '.EnvironmentVariables | to_entries[] | "\(.key)=\(.value)"')
    args=()
    while IFS= read -r a; do args+=("$a"); done < <(printf '%s' "$json" | jq -r '.ProgramArguments[]')
    wd=$(printf '%s' "$json" | jq -r .WorkingDirectory)
    { cd "$wd" && exec env -i "${envs[@]}" FM_BRIDGE_CONFIG_DIR="$FAKE_BRIDGE_CONFIG" \
        FM_BRIDGE_STATE_DIR="$FAKE_BRIDGE_STATE" FM_BRIDGE_TAILSCALE="$FAKE_BRIDGE_TAILSCALE" \
        "${args[@]}"; } >> "$log" 2>&1 < /dev/null &
    echo $! > "$jobs/$label.pid"
    ;;
  print) [ -f "$jobs/${2##*/}.pid" ] ;;
  bootout)
    pidf="$jobs/${2##*/}.pid"
    [ -f "$pidf" ] || exit 3
    pkill -P "$(cat "$pidf")" 2>/dev/null; kill "$(cat "$pidf")" 2>/dev/null
    rm -f "$pidf"
    ;;
esac
SH
chmod +x "$FAKEBIN/launchctl"
agent() {
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_BRIDGE_CONFIG_DIR="$CFG" FM_BRIDGE_STATE_DIR="$RUN" \
    FM_BRIDGE_AGENT_DIR="$AGENTS" FAKE_LAUNCHD_DIR="$TMP_ROOT/launchd" FAKE_BRIDGE_CONFIG="$CFG" \
    FAKE_BRIDGE_STATE="$RUN" FAKE_BRIDGE_TAILSCALE="$FAKEBIN/tailscale-down" "$BRIDGE" "$@"
}
jq --argjson p "$PORT" '.port = $p' "$CFG/bridge.json" > "$CFG/bridge.json.new" && mv "$CFG/bridge.json.new" "$CFG/bridge.json"
trap 'agent uninstall >/dev/null 2>&1; fm_test_cleanup' EXIT
out=$(agent install 2>&1) || fail "install did not prove the job runs: $out"
case "$out" in *"the job is running"*"listening on http://127.0.0.1:$PORT/"*) ;; *) fail "install should report the job's listening line: $out" ;; esac
plist="$AGENTS/com.firstmate.bridge.plist"
[ "$(plutil -extract ProgramArguments.1 raw -o - "$plist")" = "$ROOT/bin/fm-bridge.sh" ] \
  || fail "the plist names the script by absolute path"
[ "$(plutil -extract EnvironmentVariables.FM_HOME raw -o - "$plist")" = "$HOME_DIR" ] \
  || fail "the plist carries FM_HOME"
[ "$(plutil -extract StandardOutPath raw -o - "$plist")" = "$RUN/bridge.log" ] \
  || fail "the job logs under the state directory"
[ "$(curl -fsS "http://127.0.0.1:$PORT/healthz")" = ok ] || fail "the installed job answers"
out=$(agent stop 2>&1) && fail "stop must defer to uninstall while the LaunchAgent runs the Bridge"
agent uninstall >/dev/null || fail "uninstall failed"
[ -f "$plist" ] && fail "uninstall removes the plist"
pass "install writes an absolute plist, bootstraps it, and proves the job from its log"
