#!/usr/bin/env bash
# Behavior tests for Mission Control's public page (bin/fm-mission-control-web.sh
# over bin/fm_mission_control_web.py): a fixture home whose records are full of
# private strings builds a folder that contains none of them; the snapshot holds
# exactly the allow-listed fields with the right counts, public names and
# positional keys; the locked views are never written into the page; publish
# commits and pushes only when the folder changed, keeps an unchanged snapshot's
# time until the heartbeat, retries a commit it could not push, leaves a plain
# folder alone and refuses a checkout of another repository; install writes a
# schedule at the configured cadence; the Cloudflare host writes a changed
# snapshot to Workers KV, deploys the page code only when it changed, retries
# what failed and never exposes the token. The record readers are covered by
# fm-bridge.test.sh and the crew by fm-mission-control.test.sh.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MCW="$ROOT/bin/fm-mission-control-web.sh"
TMP_ROOT=$(fm_test_tmproot fm-mission-control-web)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }
fm_git_identity

# --- a home full of private strings ----------------------------------------
# Every private string below contains "secret" (or is an email, a link or a
# path), so one search proves none of them reached the page.
HOME_DIR="$TMP_ROOT/secretship"
MATE="$TMP_ROOT/secret-mate-home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
mkdir -p "$HOME_DIR/data/zz-secret-report-1" "$HOME_DIR/data/secret-decision" "$HOME_DIR/state" \
  "$HOME_DIR/config" "$MATE/data" "$MATE/state" "$TMP_ROOT/wt-secret-one" "$TMP_ROOT/wt-secret-two"
HOME_DIR=$(cd "$HOME_DIR" && pwd)
MATE=$(cd "$MATE" && pwd)
cat > "$HOME_DIR/data/projects.md" <<'EOF'
# Projects

- secretrepo-orchard [direct-PR] - Private client work at https://secret.example.com for jane.secret@example.com; repo octo/secretrepo-orchard (added 2026-08-01)
- secretrepo-bakery [local-only] - Work kept under /Users/secretuser/private (added 2026-08-02; parked by the captain 2026-09-10 for the secret reason)
- secretship [no-mistakes-prod-only] - This home's own secret repository (added 2026-07-01)
EOF
cat > "$HOME_DIR/data/secondmates.md" <<EOF
# Second mates

- secret-mate-id - Charter with secretcharter words and https://secret.example.org/charter (home: $MATE; scope: Orchard clients for Secretford University: the secretscope details; projects: secretrepo-orchard; added 2026-09-01)
EOF
cat > "$HOME_DIR/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] zz-secret-a - Secret title about the orchard contract https://secret.example.com/pr/1 (repo: secretrepo-orchard) (kind: ship) (since 2026-09-18)
## Queued
- [ ] zz-secret-c1 - Choose the secret pricing on 24 September 2026 (repo: secretrepo-orchard) (kind: captain) (since 2026-09-02)
  A secret body line with jane.secret@example.com in it.
- [ ] zz-secret-c2 - Approve the secret outline (repo: secretrepo-bakery) (kind: task) (since 2026-09-03) (hold: the secret hold reason) (hold-kind: captain)
- [ ] zz-secret-q1 - Print the secret handouts due 30 September 2026 (repo: secretrepo-bakery) (kind: task) (since 2026-09-05)
- [ ] zz-secret-s1 - Tidy the secret setup (repo: secretship) (kind: task) (since 2026-09-07)
## Done
- [x] zz-secret-d1 - Secret decks shipped (repo: secretrepo-orchard) (kind: ship) (merged 2026-09-15)
- [x] zz-secret-d2 - Secret module (repo: secretrepo-bakery) (kind: ship) (done 2026-09-16)
- [x] zz-secret-d3 - Last month's secret (repo: secretrepo-bakery) (kind: ship) (done 2026-08-30)
EOF
cat > "$HOME_DIR/data/done-archive.md" <<'EOF'
## Archived 2026-09-15
- [x] zz-secret-d4 - Archived secret handout (repo: secretrepo-bakery) (kind: ship) (done 2026-09-14)
EOF
printf '# Captain\n\n## Who\nThe captain secretcaptain sentence.\n' > "$HOME_DIR/data/captain.md"
printf '# Learnings\n\n## Git\nA secretlearning fact.\n' > "$HOME_DIR/data/learnings.md"
printf '# Scout report: secretreport findings\n\nSecret body.\n' > "$HOME_DIR/data/zz-secret-report-1/report.md"
printf '# Decision: the secret decision\n\nSecret words.\n' > "$HOME_DIR/data/secret-decision/decision-secret.md"
cat > "$MATE/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] zz-secret-m1 - Decide the secret review point (kind: task) (since 2026-09-08) (hold: the secret call) (hold-kind: captain)
## Done
- [x] zz-secret-m2 - Secret notes (repo: secretrepo-orchard) (kind: ship) (done 2026-09-17)
EOF
printf '{"first_mate_name": "Denver", "names": {"secretrepo-orchard": "Orchard"}, "public_page": {"repository": "octo/pages", "every_minutes": 7, "heartbeat_minutes": 60}}\n' \
  > "$HOME_DIR/config/mission-control.json"
cat > "$HOME_DIR/config/bridge.json" <<'EOF'
{"links": [{"title": "Secret link", "url": "https://secret.example.net/doc", "project": "secretrepo-orchard"}]}
EOF
meta() {  # <home> <id> <worktree> <project>
  printf 'window=fx:%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=claude\nkind=ship\nmode=direct-PR\nyolo=off\n' \
    "$2" "$2" "$3" "$4" > "$1/state/$2.meta"
}
meta "$HOME_DIR" zz-secret-a "$TMP_ROOT/wt-secret-one" "$HOME_DIR/projects/secretrepo-orchard"
meta "$HOME_DIR" zz-secret-q1 "$TMP_ROOT/wt-secret-two" "$HOME_DIR/projects/secretrepo-bakery"
meta "$HOME_DIR" zz-secret-s1 "$TMP_ROOT/wt-secret-three" "$HOME_DIR"
for tool in tmux herdr; do
  printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/$tool"
  chmod +x "$FAKEBIN/$tool"
done
AGENTS="$TMP_ROOT/agents.json"
jq -n --arg home "$HOME_DIR" --arg mate "$MATE" --arg w1 "$TMP_ROOT/wt-secret-one" '
  {result: {type: "agent_list", agents: [
    {pane_id: "secretpane:1", agent_status: "working", cwd: $home},
    {pane_id: "secretpane:2", agent_status: "working", cwd: $mate},
    {pane_id: "secretpane:3", agent_status: "working", cwd: "/secret/elsewhere", foreground_cwd: $w1},
    {pane_id: "secretpane:4", agent_status: "working", cwd: "/secret/unlisted/secretrepo-unlisted"}]}}' > "$AGENTS"

mcw() {  # <now> <args...>
  local now=$1
  shift
  TZ=UTC-8 PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_BRIDGE_NOW="$now" FM_MC_HERDR="$FAKEBIN/herdr" "$MCW" "$@"
}

OUT="$TMP_ROOT/page"
mcw 2026-09-18T10:00:00 build "$OUT" --agents "$AGENTS" > "$TMP_ROOT/build.out" || fail "build failed: $(cat "$TMP_ROOT/build.out")"
for f in index.html style.css app.js snapshot.json .nojekyll; do
  [ -f "$OUT/$f" ] || fail "the folder holds $f"
done
pass "build writes one self-contained folder: the page, its style and script, and one data file"

# --- redaction --------------------------------------------------------------
HITS=$(grep -ril 'secret' "$OUT" || true)
[ -z "$HITS" ] || fail "no private string may reach the page; found in: $HITS: $(grep -i secret "$OUT"/* | head -3)"
for needle in '@' 'http' 'example.' '/Users' "$TMP_ROOT" 'zz-' 'octo/' 'repo'; do
  grep -qF -- "$needle" "$OUT/snapshot.json" && fail "the snapshot carries no emails, links, paths, ids or repository names: $needle"
done
pass "a home full of private titles, notes, paths, emails, links, ids, repository names and charters leaves none of them on the page"

SNAP=$(cat "$OUT/snapshot.json")
q() { jq -r "$1" <<<"$SNAP"; }
[ "$(q '[keys[]] | join(",")')" = "agents,calendar,events,every_minutes,generated_at,heartbeat_minutes,office,projects,schema,today" ] \
  || fail "the snapshot's top level is exactly the allow-list, got $(q '[keys[]] | join(",")')"
[ "$(q '[.agents[] | keys[]] | unique | join(",")')" = "activity,color,hair,key,kind,lead,name,projects,role,state" ] \
  || fail "an agent carries only the allow-listed fields, got $(q '[.agents[] | keys[]] | unique | join(",")')"
[ "$(q '[.projects[] | keys[]] | unique | join(",")')" = "color,counts,key,lead,name,short,status" ] \
  || fail "a project carries only the allow-listed fields"
[ "$(q '[.projects[].counts | keys[]] | unique | join(",")')" = "done_month,done_week,in_flight,waiting" ] \
  || fail "a project's counts are waiting, in flight, done this week and done this month"
[ "$(q '[.calendar.days[] | keys[]] | unique | join(",")')" = "date,done,due" ] || fail "a calendar day is only its date and counts"
[ "$(q '[.agents[].key, .projects[].key] | map(test("^[ap][0-9]+$")) | all')" = true ] || fail "every key is a position, never a record id"
[ "$(q '[.agents[].state] | map(. == "working" or . == "asleep") | all')" = true ] || fail "a state is working or asleep"
pass "the snapshot's shape is exactly the allow-list, with positional keys"

# --- what the snapshot says -------------------------------------------------
[ "$(q .schema)" = fm-mission-control-public.v1 ] || fail "the snapshot names its schema"
[ "$(q .every_minutes)" = 7 ] || fail "the page states the configured cadence"
[ "$(q .heartbeat_minutes)" = 60 ] || fail "the page states how long an unchanged snapshot keeps its time"
[ "$(q .today)" = 2026-09-18 ] || fail "today is the home's local date"
[ "$(q '.events | length')" = 0 ] || fail "a first build has no activity to report"
[ "$(q '.agents | map(.name) | join("|")')" = "Denver|Orchard|helper for Orchard|helper for Project 2|helper for setup|helper for a one-off job" ] \
  || fail "the first mate by name, the second mate by its project's public name, helpers by project, got $(q '.agents | map(.name) | join("|")')"
[ "$(q '.agents | map(.role) | join("|")')" = "first mate|second mate for Orchard|helper for Orchard|helper for Project 2|helper for setup|helper for a one-off job" ] \
  || fail "every role is built only from public names, never a scope, got $(q '.agents | map(.role) | join("|")')"
grep -q 'University\|clients' "$OUT/snapshot.json" && fail "a scope naming an institution never reaches the page"
[ "$(q '.agents[1].activity')" = "working on Orchard" ] || fail "a working mate's activity is built from its project's name"
[ "$(q '.agents[2].lead')" = "$(q '.agents[1].key')" ] || fail "the orchard helper stands with the orchard mate"
[ "$(q '.agents[3].lead')" = "$(q '.agents[0].key')" ] || fail "a helper on an unowned project stands with the first mate"
[ "$(q '.agents[3].activity')" = "between steps on Project 2" ] || fail "a helper with no working pane is between steps"
[ "$(q '.agents[4] | "\(.projects | join(",")) \(.activity)"')" = "p0 between steps on setup" ] \
  || fail "a helper on this home's own repository works on the setup, got $(q '.agents[4]')"
[ "$(q '.agents[5] | "\(.projects | length) \(.activity) \(.lead)"')" = "0 working on a one-off job $(q '.agents[0].key')" ] \
  || fail "a helper with no registered project works on a one-off job, never the setup, got $(q '.agents[5]')"
[ "$(q '.projects | map(.name) | join("|")')" = "Orchard|Project 2|The setup itself" ] \
  || fail "a project without a public name is numbered, never named by its repository, got $(q '.projects | map(.name) | join("|")')"
[ "$(q '.projects[0] | "\(.status) \(.counts.waiting) \(.counts.in_flight) \(.counts.done_week) \(.counts.done_month)"')" = "active 2 1 2 2" ] \
  || fail "Orchard is active with 2 waiting (its mate's hold included), 1 in flight, 2 done this week and 2 this month, got $(q '.projects[0]')"
[ "$(q '.projects[1] | "\(.status) \(.counts.waiting) \(.counts.done_week) \(.counts.done_month)"')" = "parked 1 2 2" ] \
  || fail "Project 2 is parked, with the archived handout counted in its month, got $(q '.projects[1]')"
[ "$(q .office.inbox)" = 3 ] || fail "the inbox counts every item waiting on the captain, got $(q .office.inbox)"
[ "$(q '.calendar.days[] | select(.date == "2026-09-15") | .done.p1')" = 1 ] || fail "the calendar counts a finished item on its day"
[ "$(q '.calendar.days[] | select(.date == "2026-09-30") | .due.p2')" = 1 ] || fail "the calendar counts a due date named in a title"
[ "$(q '.calendar.days[] | select(.date == "2026-08-30") | .done.p2')" = 1 ] || fail "the calendar reaches back into earlier months"
[ "$(q '.calendar | "\(.from) \(.to)"')" = "2026-07-01 2026-10-31" ] || fail "the calendar spans two months back to the end of next month"
pass "the snapshot names the crew publicly and counts the right items per project and per day"

# --- locked views are never rendered ----------------------------------------
# The built index.html is the page a visitor loads; parse it into its tabs,
# views, controls and the Open chat button rather than matching its text.
PAGE=$(python3 - "$OUT/index.html" <<'PY'
import json, sys
from html.parser import HTMLParser
class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.stack, self.tabs, self.views, self.controls, self.chat = [], [], [], [], None
    def handle_startendtag(self, tag, attrs):
        self.record(tag, dict(attrs))
    def handle_starttag(self, tag, attrs):
        a = self.record(tag, dict(attrs))
        if tag not in ("area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "wbr"):
            self.stack.append((tag, a))
    def record(self, tag, a):
        if tag == "svg" and self.stack and self.stack[-1][0] == "button" and "lock" in (a.get("class") or "").split():
            self.stack[-1][1]["lock"] = True
        if tag in ("form", "input", "textarea", "select", "a"):
            self.controls.append(tag)
        if tag == "section" and "view" in (a.get("class") or "").split():
            self.views.append(a.get("id"))
        if tag != "button":
            return a
        b = {"view": a.get("data-view"), "locked": a.get("data-locked") == "true", "lock": False,
             "id": a.get("id"), "class": (a.get("class") or "").split(), "disabled": a.get("aria-disabled")}
        if any(t == "nav" and x.get("id") == "tabs" for t, x in self.stack):
            self.tabs.append(b)
        if b["id"] == "talk-chat":
            self.chat = b
        return b
    def handle_endtag(self, tag):
        if any(t == tag for t, _ in self.stack):
            while self.stack.pop()[0] != tag:
                pass
p = Page()
with open(sys.argv[1], encoding="utf-8") as fh:
    p.feed(fh.read())
print(json.dumps({"tabs": p.tabs, "views": p.views, "controls": p.controls, "chat": p.chat}))
PY
) || fail "the built page parses"
pg() { jq -r "$1" <<<"$PAGE"; }
[ "$(pg '.tabs | map(.view) | join(",")')" = "office,tasks,approvals,projects,calendar,team,memory,docs,system" ] \
  || fail "the tab bar holds all nine tabs in order, got $(pg '.tabs | map(.view) | join(",")')"
[ "$(pg '[.tabs[] | select(.locked and .lock) | .view] | join(",")')" = "tasks,approvals,memory,docs,system" ] \
  || fail "exactly Tasks, Approvals, Memory, Docs and System are locked and show a lock, got $(pg '[.tabs[] | select(.locked) | .view] | join(",")')"
[ "$(pg '[.tabs[] | select(.locked != .lock)] | length')" = 0 ] || fail "a tab shows a lock exactly when it is locked"
[ "$(pg '.views | join(",")')" = "view-office,view-projects,view-calendar,view-team,view-locked" ] \
  || fail "only Office, Projects, Calendar and Team render, and a locked tab opens the lock view, got $(pg '.views | join(",")')"
for v in tasks approvals memory docs system; do
  [ "$(q "has(\"$v\")")" = false ] || fail "the snapshot holds nothing for $v"
done
[ "$(pg '.controls | length')" = 0 ] || fail "the public page has no form, link or control of any kind, got $(pg '.controls')"
[ "$(pg '.chat | "\(.class | index("locked") != null) \(.disabled) \(.lock)"')" = "true true true" ] \
  || fail "a tapped agent's Open chat button is locked and disabled, got $(pg .chat)"
pass "Tasks, Approvals, Memory, Docs and System are locked tabs with nothing behind them, Open chat is locked, and Office, Projects, Calendar and Team render"

# --- an unchanged crew leaves the folder unchanged ---------------------------
BEFORE=$(cat "$OUT/snapshot.json")
R=$(mcw 2026-09-18T10:20:00 build "$OUT" --agents "$AGENTS") || fail "second build failed"
[ "$R" = "changed: nothing" ] || fail "a rebuild with nothing new changes no file, got: $R"
[ "$(cat "$OUT/snapshot.json")" = "$BEFORE" ] || fail "an unchanged snapshot keeps its time"
R=$(mcw 2026-09-18T11:05:00 build "$OUT" --agents "$AGENTS") || fail "heartbeat build failed"
[ "$R" = "changed: snapshot.json" ] || fail "past the heartbeat the time moves once, got: $R"
[ "$(jq -r .generated_at "$OUT/snapshot.json")" != "$(jq -r .generated_at <<<"$BEFORE")" ] || fail "the heartbeat moves the time"
pass "an unchanged crew keeps the whole folder byte for byte until the heartbeat"

# --- live activity: plain state changes only --------------------------------
EVT="$TMP_ROOT/events-page"
cp -R "$OUT" "$EVT"
jq '(.result.agents[] | select(.pane_id == "secretpane:2") | .agent_status) = "idle"
  | .result.agents |= map(select(.pane_id != "secretpane:4"))' "$AGENTS" > "$TMP_ROOT/agents2.json"
printf -- '- [x] zz-secret-e1 - Secret event title (repo: secretrepo-orchard) (kind: ship) (done 2026-09-18)\n' >> "$HOME_DIR/data/backlog.md"
mcw 2026-09-18T10:30:00 build "$EVT" --agents "$TMP_ROOT/agents2.json" >/dev/null || fail "event build failed"
E=$(jq -c '[.events[] | "\(.who) \(.what)"]' "$EVT/snapshot.json")
[ "$(jq -r '.agents[1].state' "$EVT/snapshot.json")" = asleep ] || fail "the orchard mate fell asleep"
[ "$E" = '["Helper for a one-off job goes home","Orchard finishes a job"]' ] \
  || fail "a helper leaving and a finished job read as plain events, and falling asleep is no event, got $E"
[ "$(jq -r '[.events[] | keys | join(",")] | unique | join("|")' "$EVT/snapshot.json")" = "at,what,who" ] || fail "an event is only a time, a name and a phrase"
[ "$(jq -r '.events[0].at' "$EVT/snapshot.json")" = "2026-09-18T02:30:00Z" ] || fail "an event carries the build's time"
grep -qi secret "$EVT/snapshot.json" && fail "an event never carries a task title"
mcw 2026-09-18T10:35:00 build "$EVT" --agents "$AGENTS" >/dev/null || fail "second event build failed"
[ "$(jq -r '.agents[1].state' "$EVT/snapshot.json")" = working ] || fail "the orchard mate woke up"
E=$(jq -c '[.events[] | "\(.who) \(.what)"]' "$EVT/snapshot.json")
[ "$E" = '["Denver calls in a helper for a one-off job","Helper for a one-off job goes home","Orchard finishes a job"]' ] \
  || fail "a new helper is the newest event, waking up is no event, and earlier events are kept, got $E"
sed -i.bak '/zz-secret-e1/d' "$HOME_DIR/data/backlog.md"
pass "the live activity lists plain state changes with public names, newest first, never a title"

# --- publish ------------------------------------------------------------------
REMOTE="$TMP_ROOT/remote/octo/pages.git"
PAGES="$TMP_ROOT/pages"
mkdir -p "$(dirname "$REMOTE")"
git init -q --bare "$REMOTE"
git clone -q "$REMOTE" "$PAGES" 2>/dev/null
printf 'A page repository.\n' > "$PAGES/README.md"
git -C "$PAGES" add README.md
git -C "$PAGES" commit -qm initial
git -C "$PAGES" push -q origin HEAD 2>/dev/null
commits() { git --git-dir="$REMOTE" rev-list --count --all; }
[ "$(commits)" = 1 ] || fail "the fixture remote starts with one commit"

R=$(mcw 2026-09-18T10:00:00 publish "$PAGES" --agents "$AGENTS") || fail "first publish failed: $R"
grep -q 'pushed' <<<"$R" || fail "the first publish pushes, got: $R"
[ "$(commits)" = 2 ] || fail "the first publish adds one commit"
[ "$(git --git-dir="$REMOTE" show --name-only --format= HEAD | sort | tr '\n' ' ')" = ".nojekyll app.js index.html snapshot.json style.css " ] \
  || fail "the commit holds only the page's files"
printf 'local edit\n' >> "$PAGES/README.md"
R=$(mcw 2026-09-18T10:05:00 publish "$PAGES" --agents "$AGENTS") || fail "second publish failed: $R"
[ "$(tail -n 1 <<<"$R")" = "fm-mission-control-web: unchanged; nothing to push" ] || fail "publish is a no-op when nothing changed, got: $R"
[ "$(commits)" = 2 ] || fail "an unchanged folder commits and pushes nothing"
git -C "$PAGES" diff --quiet -- README.md && fail "publish leaves other files in the checkout alone"

printf -- '- [x] zz-secret-d5 - Another secret (repo: secretrepo-orchard) (kind: ship) (done 2026-09-18)\n' >> "$HOME_DIR/data/backlog.md"
R=$(mcw 2026-09-18T10:10:00 publish "$PAGES" --agents "$AGENTS") || fail "third publish failed: $R"
[ "$(commits)" = 3 ] || fail "a change in the records is pushed as one more commit"
[ "$(git --git-dir="$REMOTE" show --name-only --format= HEAD)" = snapshot.json ] || fail "only the snapshot changed"
git --git-dir="$REMOTE" show HEAD:snapshot.json | grep -qi secret && fail "the published snapshot is the redacted one"

git -C "$PAGES" remote set-url origin "$TMP_ROOT/nowhere.git"
printf -- '- [x] zz-secret-d6 - Yet another secret (repo: secretrepo-orchard) (kind: ship) (done 2026-09-18)\n' >> "$HOME_DIR/data/backlog.md"
mcw 2026-09-18T10:15:00 publish "$PAGES" --agents "$AGENTS" >/dev/null 2>&1 && fail "a push that cannot reach the remote fails the run"
git -C "$PAGES" remote set-url origin "$REMOTE"
git -C "$PAGES" commit -qm "held back" -- snapshot.json 2>/dev/null || true
R=$(mcw 2026-09-18T10:16:00 publish "$PAGES" --agents "$AGENTS") || fail "retry publish failed: $R"
grep -q 'pushed' <<<"$R" || fail "a commit an earlier run could not push is pushed next time, got: $R"
[ "$(git -C "$PAGES" rev-parse HEAD)" = "$(git --git-dir="$REMOTE" rev-parse HEAD)" ] || fail "the remote catches up"
pass "publish commits and pushes only the page's files, only when they changed, and retries an unpushed commit"

git -C "$PAGES" remote set-url origin "$TMP_ROOT/remote/octo/other.git"
printf -- '- [x] zz-secret-d7 - One more secret (repo: secretrepo-orchard) (kind: ship) (done 2026-09-18)\n' >> "$HOME_DIR/data/backlog.md"
R=$(mcw 2026-09-18T10:20:00 publish "$PAGES" --agents "$AGENTS" 2>&1) && fail "a checkout of another repository is refused"
grep -q 'not octo/pages' <<<"$R" || fail "the refusal names the configured repository, got: $R"
git -C "$PAGES" remote set-url origin "$REMOTE"
PLAIN="$TMP_ROOT/plain"
R=$(mcw 2026-09-18T10:20:00 publish "$PLAIN" --agents "$AGENTS") || fail "publish into a plain folder failed: $R"
grep -q 'not the top of a git checkout' <<<"$R" || fail "a plain folder is built and left alone, got: $R"
[ -f "$PLAIN/snapshot.json" ] || fail "the plain folder was built"
pass "publish refuses another repository's checkout and only builds a plain folder"

# --- the schedule -------------------------------------------------------------
cat > "$FAKEBIN/launchctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP_ROOT/launchctl.log"
case "\$1" in print) exit 1 ;; esac
exit 0
EOF
chmod +x "$FAKEBIN/launchctl"
if ! command -v plutil >/dev/null 2>&1; then
  cat > "$FAKEBIN/plutil" <<'PY'
#!/usr/bin/env python3
import plistlib, sys
args = sys.argv[1:]
with open(args[-1], "rb") as fh:
    value = plistlib.load(fh)
if args[0] == "-extract":
    for part in args[1].split("."):
        value = value[int(part)] if isinstance(value, list) else value[part]
    print(value)
PY
  chmod +x "$FAKEBIN/plutil"
fi
AGENT_DIR="$TMP_ROOT/agents-dir"
R=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_MCW_AGENT_DIR="$AGENT_DIR" "$MCW" install "$PAGES") || fail "install failed: $R"
PL="$AGENT_DIR/com.firstmate.mission-control-web.plist"
plx() { PATH="$FAKEBIN:$PATH" plutil -extract "$1" raw -o - "$PL"; }
[ "$(plx StartInterval)" = 420 ] || fail "the schedule runs every every_minutes minutes, got $(plx StartInterval)"
[ "$(plx ProgramArguments.1)" = "$ROOT/bin/fm-mission-control-web.sh" ] || fail "the schedule runs this script by absolute path"
[ "$(plx ProgramArguments.2)" = publish ] || fail "the schedule runs publish"
[ "$(plx ProgramArguments.3)" = "$(cd "$PAGES" && pwd -P)" ] || fail "the schedule publishes the given folder"
grep -q "bootstrap gui/" "$TMP_ROOT/launchctl.log" || fail "install loads the job"
R=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_MCW_AGENT_DIR="$AGENT_DIR" "$MCW" uninstall) || fail "uninstall failed: $R"
[ -e "$PL" ] && fail "uninstall removes the plist"
pass "install schedules publish at the configured cadence and uninstall removes it"

# --- Cloudflare ---------------------------------------------------------------
# A fake Cloudflare API (curl) and a fake wrangler stand in for the real ones.
# The token below is a made-up fixture value; it proves the token reaches curl
# only on standard input and wrangler only in its environment.
CF_TOKEN_FIXTURE=fixtureTOKENnotreal_0123456789
CF_ACCOUNT_FIXTURE=0123456789abcdef0123456789abcdef
CF_STATE="$TMP_ROOT/cf-state.json"
printf '{"namespaces": [{"id": "ns-other", "title": "someone-else"}], "projects": {}, "kv": {}}\n' > "$CF_STATE"
cat > "$FAKEBIN/curl" <<EOF
#!/usr/bin/env python3
import json, re, sys
token, account, state_path = "$CF_TOKEN_FIXTURE", "$CF_ACCOUNT_FIXTURE", "$CF_STATE"
log = open("$TMP_ROOT/curl.log", "a")
args = sys.argv[1:]
if any(token in a for a in args):
    log.write("TOKEN IN ARGUMENTS\n")
config = sys.stdin.read() if "--config" in args else ""
method, out, url, body = "GET", None, None, None
i = 0
while i < len(args):
    a = args[i]
    if a in ("-X", "-o", "-w", "-H", "--data", "--data-binary", "--config"):
        v = args[i + 1]
        if a == "-X": method = v
        if a == "-o": out = v
        if a in ("--data", "--data-binary"):
            body = open(v[1:], "rb").read() if v.startswith("@") else v.encode()
        i += 2
        continue
    if a.startswith("https://"):
        url = a
    i += 1
state = json.load(open(state_path))
prefix = "https://api.cloudflare.com/client/v4/accounts/%s" % account
path = url[len(prefix):] if url and url.startswith(prefix) else None
log.write("%s %s\n" % (method, path))
code, res = 200, None
def ok(result): return {"success": True, "errors": [], "result": result}
def err(msg): return {"success": False, "errors": [{"code": 1, "message": msg}], "result": None}
if 'header = "Authorization: Bearer %s"' % token not in config or path is None:
    code, res = 401, err("Authentication error")
elif method == "GET" and path.startswith("/storage/kv/namespaces?"):
    res = ok(state["namespaces"])
elif method == "POST" and path == "/storage/kv/namespaces":
    title = json.loads(body)["title"]
    ns = {"id": "ns%d" % len(state["namespaces"]), "title": title}
    state["namespaces"].append(ns)
    res = ok(ns)
elif method == "PUT" and re.match(r"^/storage/kv/namespaces/[^/]+/values/snapshot\.json$", path):
    nid = path.split("/")[4]
    if state.get("fail_put") or nid not in [n["id"] for n in state["namespaces"]]:
        code, res = 404, err("namespace not found")
    else:
        state["kv"].setdefault(nid, {})["snapshot.json"] = body.decode()
        res = ok(None)
elif method == "GET" and path.startswith("/pages/projects/"):
    name = path.split("/")[3]
    if name in state["projects"]:
        res = ok(state["projects"][name])
    else:
        code, res = 404, err("Project not found")
elif method == "POST" and path == "/pages/projects":
    req = json.loads(body)
    proj = {"name": req["name"], "subdomain": req["name"] + "-abc.pages.dev",
            "production_branch": req["production_branch"]}
    state["projects"][req["name"]] = proj
    res = ok(proj)
else:
    code, res = 400, err("unexpected request")
json.dump(state, open(state_path, "w"))
open(out, "w").write(json.dumps(res))
sys.stdout.write(str(code))
EOF
chmod +x "$FAKEBIN/curl"
cat > "$FAKEBIN/wrangler" <<EOF
#!/usr/bin/env bash
{ printf 'wrangler %s\n' "\$*"
  [ "\$CLOUDFLARE_API_TOKEN" = "$CF_TOKEN_FIXTURE" ] && echo "token in the environment"
  [ "\$CLOUDFLARE_ACCOUNT_ID" = "$CF_ACCOUNT_FIXTURE" ] && echo "account in the environment"
  case "\$*" in *"$CF_TOKEN_FIXTURE"*) echo "TOKEN IN ARGUMENTS" ;; esac
} >> "$TMP_ROOT/wrangler.log"
rm -rf "$TMP_ROOT/staged"
cp -R "\$PWD" "$TMP_ROOT/staged"
[ ! -e "$TMP_ROOT/wrangler.fail" ] || { echo "deploy refused"; exit 1; }
echo "Deployment complete"
EOF
chmod +x "$FAKEBIN/wrangler"
calls() { [ ! -f "$TMP_ROOT/curl.log" ] || tr '\n' ',' < "$TMP_ROOT/curl.log"; }
deploys() { grep -c '^wrangler ' "$TMP_ROOT/wrangler.log" 2>/dev/null || echo 0; }
kv() { jq -r --arg id "$1" '.kv[$id]["snapshot.json"] // empty' "$CF_STATE"; }
cf_config() {  # <project>
  printf '{"first_mate_name": "Denver", "names": {"secretrepo-orchard": "Orchard"}, "public_page": {"host": "cloudflare", "project": "%s", "every_minutes": 7}}\n' "$1" \
    > "$HOME_DIR/config/mission-control.json"
}
cf_config mission-control
CF="$TMP_ROOT/cf-page"

R=$(mcw 2026-09-18T12:00:00 publish "$CF" --agents "$AGENTS" 2>&1) && fail "publish without Cloudflare credentials fails"
grep -q "CLOUDFLARE_API_TOKEN is not set in $HOME_DIR/.env" <<<"$R" || fail "the refusal names the missing key and where it is read from, got: $R"
[ -f "$TMP_ROOT/curl.log" ] && fail "nothing is sent without credentials"
printf 'OTHER=1\nexport CLOUDFLARE_API_TOKEN="%s"\nCLOUDFLARE_ACCOUNT_ID=%s\n' "$CF_TOKEN_FIXTURE" "$CF_ACCOUNT_FIXTURE" > "$HOME_DIR/.env"
pass "publish to Cloudflare refuses to run until the home's .env holds the credentials"

R=$(mcw 2026-09-18T12:00:00 publish "$CF" --agents "$AGENTS" 2>&1) || fail "first Cloudflare publish failed: $R"
[ "$(calls)" = "GET /storage/kv/namespaces?per_page=100&page=1,POST /storage/kv/namespaces,PUT /storage/kv/namespaces/ns1/values/snapshot.json,GET /pages/projects/mission-control,POST /pages/projects," ] \
  || fail "the first publish creates the namespace, writes the snapshot, then creates the project, got $(calls)"
[ "$(jq -r '.namespaces[1].title' "$CF_STATE")" = mission-control-snapshot ] || fail "the namespace is named after the project"
[ "$(deploys)" = 1 ] || fail "the first publish deploys the page once"
grep -q '^wrangler pages deploy public --project-name mission-control --branch main' "$TMP_ROOT/wrangler.log" \
  || fail "wrangler deploys the staged page to the project's production branch, got $(cat "$TMP_ROOT/wrangler.log")"
grep -q 'token in the environment' "$TMP_ROOT/wrangler.log" || fail "wrangler gets the token in its environment"
grep -q 'account in the environment' "$TMP_ROOT/wrangler.log" || fail "wrangler gets the account id in its environment"
[ "$(cd "$TMP_ROOT/staged" && find . -type f | sort | tr '\n' ' ')" = "./functions/snapshot.json.js ./public/app.js ./public/index.html ./public/style.css ./wrangler.toml " ] \
  || fail "only the page code and its function are deployed, never the snapshot, got $(cd "$TMP_ROOT/staged" && find . -type f | sort | tr '\n' ' ')"
grep -q '^binding = "SNAPSHOT"$' "$TMP_ROOT/staged/wrangler.toml" || fail "the deploy binds a namespace to the function"
grep -q '^id = "ns1"$' "$TMP_ROOT/staged/wrangler.toml" || fail "the bound namespace is the snapshot's"
cmp -s "$TMP_ROOT/staged/public/app.js" "$ROOT/bin/mission-control-web/app.js" || fail "the deployed page is the tracked page"
[ "$(kv ns1)" = "$(cat "$CF/snapshot.json")" ] || fail "Workers KV holds the built snapshot"
kv ns1 | grep -qi secret && fail "the snapshot in Workers KV is the redacted one"
[ "$(tail -n 1 <<<"$R")" = "fm-mission-control-web: wrote the snapshot to Workers KV and deployed the page for https://mission-control-abc.pages.dev" ] \
  || fail "publish names the page's real address, got: $R"
pass "the first Cloudflare publish creates the namespace and project, writes the snapshot to KV and deploys only the page code"

: > "$TMP_ROOT/curl.log"
R=$(mcw 2026-09-18T12:05:00 publish "$CF" --agents "$AGENTS" 2>&1) || fail "unchanged Cloudflare publish failed: $R"
[ "$(tail -n 1 <<<"$R")" = "fm-mission-control-web: unchanged; nothing to upload" ] || fail "an unchanged folder uploads nothing, got: $R"
[ -s "$TMP_ROOT/curl.log" ] && fail "an unchanged run makes no request, got $(calls)"
[ "$(deploys)" = 1 ] || fail "an unchanged run never redeploys the page"
printf -- '- [x] zz-secret-c8 - A cloud secret (repo: secretrepo-orchard) (kind: ship) (done 2026-09-18)\n' >> "$HOME_DIR/data/backlog.md"
R=$(mcw 2026-09-18T12:10:00 publish "$CF" --agents "$AGENTS" 2>&1) || fail "changed Cloudflare publish failed: $R"
[ "$(calls)" = "PUT /storage/kv/namespaces/ns1/values/snapshot.json," ] || fail "a changed snapshot is one KV write, got $(calls)"
[ "$(deploys)" = 1 ] || fail "a changed snapshot never redeploys the page"
[ "$(kv ns1)" = "$(cat "$CF/snapshot.json")" ] || fail "Workers KV holds the new snapshot"
pass "a scheduled run writes the snapshot to KV only when it changed and never redeploys unchanged page code"

jq '.fail_put = true' "$CF_STATE" > "$CF_STATE.new" && mv "$CF_STATE.new" "$CF_STATE"
printf -- '- [x] zz-secret-c9 - Another cloud secret (repo: secretrepo-orchard) (kind: ship) (done 2026-09-18)\n' >> "$HOME_DIR/data/backlog.md"
mcw 2026-09-18T12:15:00 publish "$CF" --agents "$AGENTS" >/dev/null 2>&1 && fail "a KV write that fails fails the run"
jq '.fail_put = false' "$CF_STATE" > "$CF_STATE.new" && mv "$CF_STATE.new" "$CF_STATE"
: > "$TMP_ROOT/curl.log"
R=$(mcw 2026-09-18T12:16:00 publish "$CF" --agents "$AGENTS" 2>&1) || fail "retry after a failed KV write failed: $R"
[ "$(calls)" = "GET /storage/kv/namespaces?per_page=100&page=1,PUT /storage/kv/namespaces/ns1/values/snapshot.json," ] \
  || fail "the next run finds the namespace again and writes the snapshot it could not write, got $(calls)"
[ "$(kv ns1)" = "$(cat "$CF/snapshot.json")" ] || fail "Workers KV catches up"
touch "$TMP_ROOT/wrangler.fail"
cf_config mission-control-two
mcw 2026-09-18T12:20:00 publish "$CF" --agents "$AGENTS" >/dev/null 2>&1 && fail "a deploy that fails fails the run"
rm -f "$TMP_ROOT/wrangler.fail"
: > "$TMP_ROOT/curl.log"
R=$(mcw 2026-09-18T12:21:00 publish "$CF" --agents "$AGENTS" 2>&1) || fail "retry after a failed deploy failed: $R"
[ "$(calls)" = "GET /pages/projects/mission-control-two," ] || fail "the next run retries only the deploy, got $(calls)"
[ "$(deploys)" = 3 ] || fail "the failed deploy is retried once"
grep -q 'mission-control-two-abc.pages.dev' <<<"$R" || fail "the new project's address is reported, got: $R"
pass "a failed KV write or deploy is retried on the next run, and only what failed is sent again"

grep -q 'TOKEN IN ARGUMENTS' "$TMP_ROOT/curl.log" "$TMP_ROOT/wrangler.log" && fail "the token never appears on a command line"
HITS=$(grep -rlF -- "$CF_TOKEN_FIXTURE" "$TMP_ROOT" | grep -v "/secretship/.env$" | grep -v "/$(basename "$FAKEBIN")/" || true)
[ -z "$HITS" ] || fail "the token is never written anywhere but the home's .env, found in: $HITS"
R=$(mcw 2026-09-18T12:25:00 publish "$CF" --agents "$AGENTS" 2>&1)
grep -qF -- "$CF_TOKEN_FIXTURE" <<<"$R" && fail "the token is never printed"
pass "the token reaches curl on standard input and wrangler in its environment, and is never printed, written or put on a command line"

R=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_MCW_AGENT_DIR="$AGENT_DIR" "$MCW" install "$CF") || fail "Cloudflare install failed: $R"
[ "$(plx ProgramArguments.2) $(plx ProgramArguments.3) $(plx StartInterval)" = "publish $(cd "$CF" && pwd -P) 420" ] \
  || fail "the Cloudflare schedule runs publish on the folder at the configured cadence"
grep -qF -- "$CF_TOKEN_FIXTURE" "$PL" && fail "the schedule never carries the token"
R=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_MCW_AGENT_DIR="$AGENT_DIR" "$MCW" status) || fail "status failed: $R"
grep -q '^address: https://mission-control-two-abc.pages.dev$' <<<"$R" || fail "status shows the page's address, got: $R"
PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_MCW_AGENT_DIR="$AGENT_DIR" "$MCW" uninstall >/dev/null || fail "uninstall failed"
mv "$HOME_DIR/.env" "$HOME_DIR/.env.off"
R=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_MCW_AGENT_DIR="$AGENT_DIR" "$MCW" install "$CF" 2>&1) && fail "install without credentials is refused"
[ -e "$PL" ] && fail "a refused install writes no schedule"
mv "$HOME_DIR/.env.off" "$HOME_DIR/.env"
printf '{"public_page": {"host": "netlify"}}\n' > "$HOME_DIR/config/mission-control.json"
R=$(mcw 2026-09-18T12:30:00 publish "$CF" --agents "$AGENTS" 2>&1) && fail "an unknown host is refused"
grep -q 'public_page.host in config/mission-control.json is "netlify"' <<<"$R" || fail "the refusal names the host, got: $R"
pass "install schedules the Cloudflare publish once the credentials are set, and an unknown host is refused"

bash -n "$MCW" || fail "fm-mission-control-web.sh has a syntax error"
pass "fm-mission-control-web.sh parses"
