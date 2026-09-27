#!/usr/bin/env bash
# Behavior tests for Mission Control's public page (bin/fm-mission-control-web.sh
# over bin/fm_mission_control_web.py): a fixture home whose records are full of
# private strings builds a folder that contains none of them; the snapshot holds
# exactly the allow-listed fields with the right counts, public names and
# positional keys; the locked views are never written into the page; publish
# commits and pushes only when the folder changed, keeps an unchanged snapshot's
# time until the heartbeat, retries a commit it could not push, leaves a plain
# folder alone and refuses a checkout of another repository; install writes a
# schedule at the configured cadence. The record readers are covered by
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

- secret-mate-id - Charter with secretcharter words and https://secret.example.org/charter (home: $MATE; scope: Secretrepo-orchard clients: the secretscope details; projects: secretrepo-orchard; added 2026-09-01)
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
for tool in tmux herdr; do
  printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/$tool"
  chmod +x "$FAKEBIN/$tool"
done
AGENTS="$TMP_ROOT/agents.json"
jq -n --arg home "$HOME_DIR" --arg mate "$MATE" --arg w1 "$TMP_ROOT/wt-secret-one" '
  {result: {type: "agent_list", agents: [
    {pane_id: "secretpane:1", agent_status: "working", cwd: $home},
    {pane_id: "secretpane:2", agent_status: "working", cwd: $mate},
    {pane_id: "secretpane:3", agent_status: "working", cwd: "/secret/elsewhere", foreground_cwd: $w1}]}}' > "$AGENTS"

mcw() {  # <now> <args...>
  local now=$1
  shift
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_BRIDGE_NOW="$now" FM_MC_HERDR="$FAKEBIN/herdr" "$MCW" "$@"
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
[ "$(q '[keys[]] | join(",")')" = "agents,calendar,events,every_minutes,generated_at,office,projects,schema,today" ] \
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
[ "$(q .today)" = 2026-09-18 ] || fail "today is the home's local date"
[ "$(q '.events | length')" = 0 ] || fail "a first build has no activity to report"
[ "$(q '.agents | map(.name) | join("|")')" = "Denver|Orchard|helper for Orchard|helper for Project 2" ] \
  || fail "the first mate by name, the second mate by its project's public name, helpers by project, got $(q '.agents | map(.name) | join("|")')"
[ "$(q '.agents[1].role')" = "Looks after Orchard" ] || fail "a role naming a repository falls back to what the mate looks after"
[ "$(q '.agents[1].activity')" = "working on Orchard" ] || fail "a working mate's activity is built from its project's name"
[ "$(q '.agents[2].lead')" = "$(q '.agents[1].key')" ] || fail "the orchard helper stands with the orchard mate"
[ "$(q '.agents[3].lead')" = "$(q '.agents[0].key')" ] || fail "a helper on an unowned project stands with the first mate"
[ "$(q '.agents[3].activity')" = "between steps on Project 2" ] || fail "a helper with no working pane is between steps"
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
for v in tasks approvals memory docs system; do
  grep -q "data-view=\"$v\" data-locked=\"true\"" "$OUT/index.html" || fail "the $v tab shows in the tab bar with a lock"
  grep -q "id=\"view-$v\"" "$OUT/index.html" && fail "the $v view is not rendered at all"
  [ "$(q "has(\"$v\")")" = false ] || fail "the snapshot holds nothing for $v"
done
for v in office projects calendar team; do
  grep -q "id=\"view-$v\"" "$OUT/index.html" || fail "the $v view is rendered"
done
grep -q 'id="view-locked"' "$OUT/index.html" || fail "a locked tab opens the shaded lock view"
grep -qi '<form\|<input\|<textarea\|<a ' "$OUT/index.html" && fail "the public page has no form, link or control of any kind"
grep -q 'id="talk-chat" class="locked" aria-disabled="true"' "$OUT/index.html" \
  || fail "a tapped agent's Open chat button shows locked"
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
jq '(.result.agents[] | select(.pane_id == "secretpane:2") | .agent_status) = "idle"' "$AGENTS" > "$TMP_ROOT/agents2.json"
printf -- '- [x] zz-secret-e1 - Secret event title (repo: secretrepo-orchard) (kind: ship) (done 2026-09-18)\n' >> "$HOME_DIR/data/backlog.md"
mcw 2026-09-18T10:30:00 build "$EVT" --agents "$TMP_ROOT/agents2.json" >/dev/null || fail "event build failed"
E=$(jq -c '[.events[] | "\(.who) \(.what)"]' "$EVT/snapshot.json")
[ "$E" = '["Orchard falls asleep","Orchard finishes a job"]' ] || fail "a state change and a finished job read as plain events, got $E"
[ "$(jq -r '[.events[] | keys | join(",")] | unique | join("|")' "$EVT/snapshot.json")" = "at,what,who" ] || fail "an event is only a time, a name and a phrase"
[ "$(jq -r '.events[0].at' "$EVT/snapshot.json")" = "2026-09-18T02:30:00Z" ] || fail "an event carries the build's time"
grep -qi secret "$EVT/snapshot.json" && fail "an event never carries a task title"
mcw 2026-09-18T10:35:00 build "$EVT" --agents "$AGENTS" >/dev/null || fail "second event build failed"
[ "$(jq -r '.events[0] | "\(.who) \(.what)"' "$EVT/snapshot.json")" = "Orchard wakes up" ] || fail "waking up is the newest event"
[ "$(jq -r '.events | length' "$EVT/snapshot.json")" = 3 ] || fail "earlier events are kept"
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
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/plutil"
chmod +x "$FAKEBIN/launchctl" "$FAKEBIN/plutil"
AGENT_DIR="$TMP_ROOT/agents-dir"
R=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_MCW_AGENT_DIR="$AGENT_DIR" "$MCW" install "$PAGES") || fail "install failed: $R"
PL="$AGENT_DIR/com.firstmate.mission-control-web.plist"
grep -q '<key>StartInterval</key><integer>420</integer>' "$PL" || fail "the schedule runs every every_minutes minutes"
grep -q '<string>publish</string>' "$PL" || fail "the schedule runs publish"
grep -qF "<string>$(cd "$PAGES" && pwd -P)</string>" "$PL" || fail "the schedule publishes the given folder"
grep -q "bootstrap gui/" "$TMP_ROOT/launchctl.log" || fail "install loads the job"
R=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_MCW_AGENT_DIR="$AGENT_DIR" "$MCW" uninstall) || fail "uninstall failed: $R"
[ -e "$PL" ] && fail "uninstall removes the plist"
pass "install schedules publish at the configured cadence and uninstall removes it"

bash -n "$MCW" || fail "fm-mission-control-web.sh has a syntax error"
pass "fm-mission-control-web.sh parses"
