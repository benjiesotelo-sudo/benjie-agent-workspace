#!/usr/bin/env python3
"""fm_mission_control.py - Mission Control: the crew as a live pixel-art office.

bin/fm-mission-control.sh is the operator entry point and owns the command
surface and the Herdr workspace; this module owns what the screen reads, how
the crew maps onto the office, and how frames are drawn and written.

READ ONLY. Nothing here writes a record, sends a key or a prompt to an agent,
or starts or stops anything. The one outward call besides the reads is
`herdr agent focus` when the captain presses Enter on a team row, which only
moves the captain's own view to that agent's pane.

WHAT IT READS.
  Records   bin/fm_bridge.py collect(), the Bridge's single reader: backlog
            buckets (the same counting as the Bridge), the project and second
            mate registries, and each local home's fleet snapshot, whose
            tasks[] rows are the live workers of that home. Refreshed in the
            background when any home's state/*.meta set or backlog, registry or
            done-archive file changes, and at least every two minutes.
  Agents    `herdr agent list` (JSON), polled every two seconds, never faster
            than once a second. Each entry carries pane_id, agent_status, cwd
            and foreground_cwd.
  Settings  config/mission-control.json (optional, gitignored with config/):
            first_mate_name is the first mate's name on its desk, in the team
            list and in the activity column; "First mate" when absent.
            Reread on every crew update, so an edit shows without a restart.
  Services  for the Calendar's always-running strip, every SERVICES_EVERY
            seconds: `launchctl print gui/<uid>/com.firstmate.bridge` (the
            Bridge's LaunchAgent; "state = running" is running, any other
            answer stopped, no job off) and, from `frame` only, `ps` for a
            `fm_mission_control.py run` on this home; a running screen counts
            itself. Second mates take their state from the crew below.

MATCHING a Herdr agent to a crew member, first rule that applies:
  a worker    the pane in its task's recorded Herdr endpoint (fleet snapshot
              endpoint.target "<session>:<pane>", honoured only when that
              session is the one this screen runs in), else an agent whose cwd
              or foreground_cwd is the task's worktree;
  a second mate  the pane recorded for its kind=secondmate task in this home,
              else an agent whose cwd is the mate's registered home;
  the first mate  an agent whose cwd is this home.
This screen's own pane (HERDR_PANE_ID) and panes already claimed by a worker
or mate never match the first mate. agent_status "working" is working; every
other status is asleep, and a working agent falls asleep only after it has been
idle for SLEEP_AFTER seconds, so the gaps between turns do not flicker.

THE CREW. The first mate has the top desk. Every registered second mate gets
a desk, three to a row; a floor holds six when the pane is tall enough for two
rows, else three. Beyond that the busiest mates (working, then most interns,
then most open items) stay downstairs and a sign counts the rest upstairs.
Every worker is an intern standing beside its person in charge: the mate whose
home launched it, else the mate whose registered projects include its project,
else the first mate. The alumni wall shows mates this screen watched leave the
registry; retirement leaves no durable record (fm-teardown.sh removes the
route and the home), so the wall starts empty on every run.

PROJECTS. One card per registered project except this home's own repository,
in registry order, then "The setup itself" for items with no project, as on
the Bridge. A card is Active when a working intern's project is it, its person
in charge (the second mate whose registered projects include it, else the
first mate) is working and has no other registered project, or it has work in
flight; else Parked when its registry note says the captain parked it; else
Quiet. The first mate, and a mate with several projects, never count as
working on any one of them by themselves. Its counts are the Bridge's buckets
and its bar is done this month against done plus everything still open. The
picked card lists its first three items waiting on the captain under the grid.

APPROVALS. The decisions waiting on the captain are exactly the office
inbox's items, the Bridge's waiting bucket, grouped by the agent whose home
holds them (the first mate, then the second mates in registry order) and
oldest first. The panel shows the highlighted one's title and note: its
record's body lines without bookkeeping lines, else its hold reason, with
paths replaced by the Bridge's plain_note().

THE CALENDAR. Three modes under one control bar whose every part can be
tapped: Week | Month | Year, the period between two arrows, and a way back to
today. Month (the first shown) is the whole month in five or six Sunday to
Saturday weeks, neighbouring months' days dimmed, each day's items as short
lines and "+N more"; Year is twelve small months, a day with items in the
colour of the project with most of them, and a tapped month opens in Month;
Week is Sunday to Saturday, or from today when fewer than seven day columns
of DAY_MIN_WIDTH fit. Left and right move one period, t comes back to today
and v cycles the modes; nothing is ever dropped from the month grid, item
lines shorten instead. A day shows the Done records completed on it (this month's items plus the
Bridge's history of other months) and, from today on, open items due on it: a
hold-until date first, else the one date a title clearly names (a day and a
full month name in either order, with an optional full weekday name and year,
or YYYY-MM-DD).
Abbreviations such as Sep or Sat and ordinals such as 27th are not read. A
title with two different dates, a weekday that does not match, a short weekday
such as Fri right before the date, numbers only, or a yearless date with no
reading within half a year of today is skipped rather than guessed.

DRAWING. Each character cell is two pixels: an upper half block with the top
pixel as foreground and the bottom pixel as background, 24-bit colour when the
terminal advertises it (COLORTERM truecolor or 24bit, a TERM containing
"direct", or FM_MC_COLORS), the 256-colour cube otherwise. Frames are diffed
and only changed cells are written. Ticks run at 10 per second while someone
walks, 5 while a screen is lit, and 2.5 otherwise; paused or unchanged frames
write nothing.
"""

import datetime as _dt
import json
import math
import os
import re
import select
import signal
import subprocess
import sys
import threading
import time
import unicodedata

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fm_bridge as bridge  # noqa: E402  - the one owner of the record readers

AGENT_POLL_SECONDS = 2.0
SERVICES_EVERY = 10.0
RECORDS_MAX_AGE = 120.0
RECORDS_MIN_GAP = 3.0
SLEEP_AFTER = 30.0


def H(s):
    return int(s[1:], 16)


def mix(a, b, t):
    r = int(((a >> 16) & 255) * (1 - t) + ((b >> 16) & 255) * t + 0.5)
    g = int(((a >> 8) & 255) * (1 - t) + ((b >> 8) & 255) * t + 0.5)
    bl = int((a & 255) * (1 - t) + (b & 255) * t + 0.5)
    return (r << 16) | (g << 8) | bl


# ---------------------------------------------------------------------------
# Palette and geometry (the approved mock-up's values)
# ---------------------------------------------------------------------------

BG = H("#0c0e12")
INK = H("#d9e0e8")
DIM = H("#7f8995")
DIMMER = H("#5d6773")
LINE = H("#1e242d")
SOFT = H("#aab3be")
QUIET = H("#8a93a0")
GREEN = H("#35d07f")
AMBER = H("#ffb454")
ZZZ = H("#8fa3c7")
LABEL = H("#6b7582")

P = {k: H(v) for k, v in {
    "floorA": "#14171d", "floorB": "#171b22", "wall": "#1a2030", "wallEdge": "#2a3348",
    "desk": "#3b4250", "deskTop": "#4a5364", "deskD": "#262b34", "frame": "#07090c",
    "chair": "#232830", "skin": "#e2b48f", "wood": "#5a3e2b", "woodD": "#3e2a1d",
    "plant": "#3f9d5a", "plantD": "#2c7443", "pot": "#7a4a33", "paper": "#e9e4d8",
    "paperD": "#bdb6a6", "rack": "#1d2129", "table": "#4a3a2e", "tableTop": "#5c493a",
}.items()}

FIRST_MATE_COLOR = "#2fbf71"
FIRST_MATE_HAIR = "#3b2a20"
MATE_COLORS = ["#3fb6c9", "#7b93ff", "#e6b422", "#c678dd", "#e86a9a", "#ff8c42", "#a3be8c", "#d0493f"]
MATE_HAIRS = ["#1f1f24", "#5a3b22", "#2b2b2b", "#4a3222", "#6b3b2a", "#3b2a20"]
INTERN_HAIR = "#6b3b2a"

OW = 96            # office width in pixels (= columns)
OY = 2             # first screen row of the office
ROW_BAND = 24      # extra pixels for a second row of mate desks
MIN_COLS = OW
FEED_COL = OW + 2
FEED_MIN_WIDTH = 24

TABS = ["Office", "Tasks", "Approvals", "Projects", "Calendar", "Team", "Memory", "Docs", "System"]
VIEWS = ["office", "tasks"] + [t.lower() for t in TABS[2:]]
READY = ("office", "tasks", "approvals", "projects", "calendar")
COLUMNS = (("waiting", "WAITING ON YOU", AMBER), ("queued", "QUEUED", INK),
           ("in_flight", "IN FLIGHT", GREEN), ("done", "DONE THIS MONTH", DIM))
SHIP_TAG = "setup"


def room_height(rows_of_mates):
    return 60 + ROW_BAND * (rows_of_mates - 1)


def min_rows(room_h):
    return OY + room_h // 2 + 4


def clean(text):
    """One-cell-per-character text: plain dashes, no controls, no wide glyphs."""
    out = []
    for ch in str(text or ""):
        if ch in "—–":
            ch = "-"
        cat = unicodedata.category(ch)
        if cat in ("Cc", "Cf", "Mn", "Me", "Cs", "Co"):
            continue
        if unicodedata.east_asian_width(ch) in ("W", "F"):
            ch = "?"
        out.append(ch)
    return "".join(out)


def wrap(text, width):
    out, line = [], ""
    for word in text.split(" "):
        if not word:
            continue
        cand = (line + " " + word).strip()
        if len(cand) > width:
            if line:
                out.append(line)
            while len(word) > width:
                out.append(word[:width])
                word = word[width:]
            line = word
        else:
            line = cand
    if line:
        out.append(line)
    return out


def clip(text, width):
    if width <= 0:
        return ""
    if len(text) <= width:
        return text
    return text[:max(0, width - 3)].rstrip() + "..."


# ---------------------------------------------------------------------------
# Crew: records plus the Herdr agent list, in plain words
# ---------------------------------------------------------------------------

def _real(path):
    try:
        return os.path.realpath(path) if path else None
    except (OSError, ValueError):
        return None


def mate_name(model, mid):
    entry = model["names"].get(mid)
    if isinstance(entry, dict) and entry.get("title"):
        return clean(entry["title"])
    base = re.sub(r"[-_]?(second-?)?mate$", "", mid) or mid
    if len(base) <= 4 or any(ch.isdigit() for ch in base):
        return base.upper()
    return base[:1].upper() + base[1:]


def parse_agents(text):
    """`herdr agent list` JSON -> [{pane, status, cwds}]."""
    try:
        data = json.loads(text)
    except ValueError:
        return []
    agents = ((data or {}).get("result") or {}).get("agents") or []
    out = []
    for a in agents:
        if not isinstance(a, dict) or not a.get("pane_id"):
            continue
        cwds = {c for c in (_real(a.get("cwd")), _real(a.get("foreground_cwd"))) if c}
        out.append({"pane": str(a["pane_id"]), "status": str(a.get("agent_status") or ""), "cwds": cwds})
    return out


class SleepTimer:
    """A pane that stops working still reads as working for SLEEP_AFTER seconds."""

    def __init__(self):
        self.awake = {}     # pane -> None while working, else when it went idle

    def apply(self, agents, now):
        awake, out = {}, []
        for a in agents:
            pane = a["pane"]
            if a["status"] == "working":
                awake[pane] = None
            elif pane in self.awake:
                since = self.awake[pane] if self.awake[pane] is not None else now
                if now - since < SLEEP_AFTER:
                    awake[pane] = since
                    a = dict(a, status="working")
            out.append(a)
        self.awake = awake
        return out

    def due(self):
        """When the next idle pane falls asleep, or None."""
        stamps = [s for s in self.awake.values() if s is not None]
        return min(stamps) + SLEEP_AFTER if stamps else None


def _endpoint_pane(task, session):
    if task.get("backend") != "herdr":
        return None
    target = (task.get("endpoint") or {}).get("target") or ""
    if ":" not in target:
        return None
    sess, pane = target.split(":", 1)
    return pane if sess == session else None


class _Matcher:
    def __init__(self, agents, own_pane):
        self.agents = [a for a in agents if a["pane"] != own_pane]
        self.by_pane = {a["pane"]: a for a in self.agents}
        self.claimed = set()

    def find(self, pane=None, cwds=()):
        cwds = {c for c in (_real(c) for c in cwds) if c}
        hit = self.by_pane.get(pane) if pane else None
        if hit is None and cwds:
            cands = [a for a in self.agents if a["pane"] not in self.claimed and a["cwds"] & cwds]
            cands.sort(key=lambda a: a["status"] != "working")
            hit = cands[0] if cands else None
        if hit is not None:
            self.claimed.add(hit["pane"])
        return hit


def first_mate_name(config_dir):
    """config/mission-control.json first_mate_name, else "First mate"."""
    try:
        with open(os.path.join(config_dir, "mission-control.json"), encoding="utf-8") as fh:
            cfg = json.load(fh)
    except (OSError, ValueError):
        return "First mate"
    name = cfg.get("first_mate_name") if isinstance(cfg, dict) else None
    if not isinstance(name, str) or not clean(name).strip():
        return "First mate"
    return clean(name).strip()


def build_crew(model, agents, home, session="default", own_pane=None, fm_name="First mate"):
    """The crew in office order: first mate, mates, then interns."""
    snaps = model.get("snapshots") or {}
    mates = model.get("mates") or []
    items = model["items"]
    match = _Matcher(agents, own_pane)
    main_tasks = (snaps.get("main") or {}).get("tasks") or []

    colors = {}
    for i, m in enumerate(mates):
        colors[m["id"]] = (MATE_COLORS[i % len(MATE_COLORS)], MATE_HAIRS[i % len(MATE_HAIRS)])

    def waiting(owner):
        return sum(1 for it in items if it["owner"] == owner and it["bucket"] == "waiting")

    def opened(owner):
        return sum(1 for it in items if it["owner"] == owner and it["bucket"] != "done")

    # Workers first, so their panes are claimed before cwd matching.
    interns = []
    for hid, snap in [("main", snaps.get("main"))] + [(m["id"], snaps.get(m["id"])) for m in mates]:
        for t in (snap or {}).get("tasks") or []:
            if t.get("kind") == "secondmate" or not t.get("id"):
                continue
            proj = os.path.basename(os.path.normpath(t.get("project") or "")) or None
            if hid != "main":
                lead = "mate:" + hid
            else:
                owner = next((m for m in mates if proj and proj.lower() in
                              [p.lower() for p in m["projects"]]), None)
                lead = "mate:" + owner["id"] if owner else "fm"
            wt = ((t.get("paths") or {}).get("worktree") or {}).get("path")
            agent = match.find(_endpoint_pane(t, session), [wt] if wt else [])
            state = ((t.get("current_state") or {}).get("state")) or "unknown"
            if agent is not None:
                working = agent["status"] == "working"
            else:
                working = state == "working"
            title = bridge._clean_title(((t.get("backlog") or {}).get("title")) or "")
            if working:
                doing = title or "working on a one-off job"
            else:
                word = bridge.STATE_WORDS.get(state, "waiting")
                if word == "working":
                    word = "between steps"
                doing = "%s: %s" % (word, title) if title else word
            interns.append({
                "key": "intern:%s:%s" % (hid, t["id"]), "kind": "intern", "lead": lead, "home": hid,
                "status": "work" if working else "idle", "doing": clean(doing),
                "path": "projects/%s" % proj if proj else "no project", "project": proj,
                "pane": agent["pane"] if agent else None, "title": clean(title),
            })

    crew = []
    mate_rows = []
    for m in mates:
        task = next((t for t in main_tasks if t.get("id") == m["id"] and t.get("kind") == "secondmate"), None)
        agent = None if m["remote"] else match.find(_endpoint_pane(task or {}, session), [m["home"]])
        color, hair = colors[m["id"]]
        team = next((e for e in model["team"] if e["id"] == m["id"]), {})
        n_open, n_wait = opened(m["id"]), waiting(m["id"])
        working = bool(agent and agent["status"] == "working")
        if m["remote"]:
            doing = "works on another machine"
        elif not team.get("readable", True):
            doing = "its records could not be read"
        elif working:
            doing = "working, %s in its list" % bridge._plural(n_open, "job")
        elif agent is None:
            doing = "asleep, its window is closed"
        else:
            doing = "asleep, %s listed" % bridge._plural(n_open, "job")
        if n_wait and not m["remote"]:
            doing += ", %d waiting on you" % n_wait
        mate_rows.append({
            "key": "mate:" + m["id"], "kind": "mate", "id": m["id"], "name": mate_name(model, m["id"]),
            "role": "second mate", "color": color, "hair": hair,
            "status": "work" if working else "sleep", "doing": doing,
            "path": "projects/%s" % m["projects"][0] if m["projects"] else "no project",
            "pane": agent["pane"] if agent else None, "waiting": n_wait, "open": n_open,
        })

    home_real = _real(home)
    fm_agent = match.find(None, [home_real])
    fm_interns = [i for i in interns if i["lead"] == "fm"]
    fm_working = bool(fm_agent and fm_agent["status"] == "working")
    n_wait = waiting("main")
    if fm_working:
        doing = "working"
        if fm_interns:
            doing += ", %s on jobs" % bridge._plural(len(fm_interns), "intern")
    else:
        doing = "standing by"
    if n_wait:
        doing += ", %d waiting on you" % n_wait
    crew.append({
        "key": "fm", "kind": "first", "id": "main", "name": fm_name,
        "role": "first mate", "color": FIRST_MATE_COLOR, "hair": FIRST_MATE_HAIR,
        "status": "work" if fm_working else "sleep", "doing": doing, "path": "every project",
        "pane": fm_agent["pane"] if fm_agent else None, "waiting": n_wait, "open": opened("main"),
    })
    crew.extend(mate_rows)

    by_key = {c["key"]: c for c in crew}
    for i in interns:
        lead = by_key.get(i["lead"]) or by_key["fm"]
        i["lead"] = lead["key"]
        i["name"] = "intern"
        i["role"] = "%s's intern" % lead["name"]
        i["color"] = "#" + format(mix(H(lead["color"]), 0xFFFFFF, 0.35), "06x")
        i["hair"] = INTERN_HAIR
    crew.extend(interns)
    return crew


def project_colors(model):
    """Board tag colours: a mate's projects wear its colour, the rest take spares."""
    colors = {None: FIRST_MATE_COLOR}
    mates = model.get("mates") or []
    for i, m in enumerate(mates):
        for p in m["projects"]:
            colors.setdefault(p.lower(), MATE_COLORS[i % len(MATE_COLORS)])
    spare = [c for c in MATE_COLORS if c not in colors.values()] or MATE_COLORS
    n = 0
    for p in model["projects"]:
        key = p["name"].lower()
        if p["name"] == model["ship"] or key in colors:
            continue
        colors[key] = spare[n % len(spare)]
        n += 1
    return colors


# ---------------------------------------------------------------------------
# Layout: desks from the crew
# ---------------------------------------------------------------------------

class Layout:
    def __init__(self, mates, retired, pane_rows, crew_interns):
        """mates: live mate members; retired: kept members whose desks are boxed."""
        tall = pane_rows >= min_rows(room_height(2))
        cap = 6 if tall else 3
        seats = list(mates) + list(retired)
        if len(seats) > cap:
            def busy(m):
                n_int = sum(1 for i in crew_interns if i["lead"] == m["key"])
                return (m.get("retired", False), m["status"] != "work", -n_int, -m.get("open", 0))
            order = {m["key"]: i for i, m in enumerate(seats)}
            chosen = sorted(seats, key=lambda m: busy(m) + (order[m["key"]],))[:cap]
            keep = {m["key"] for m in chosen}
            down = [m for m in seats if m["key"] in keep]
            self.upstairs = [m for m in seats if m["key"] not in keep and not m.get("retired")]
        else:
            down, self.upstairs = seats, []
        rows = 2 if len(down) > 3 else 1
        self.band = ROW_BAND * (rows - 1)
        self.height = room_height(rows)
        self.walk_y = 50 + self.band
        self.inbox_y = 59 + self.band
        self.desks = {"fm": {"x": 34, "y": 13, "w": 21, "two": True, "cap": 4}}
        for i, m in enumerate(down):
            row, col = divmod(i, 3)
            self.desks[m["key"]] = {"x": 1 + 29 * col, "y": 33 + ROW_BAND * row, "w": 13, "two": False,
                                    "cap": 3 if col == 2 else 2}
        self.down = down
        self.signature = (self.height, tuple((k, d["x"], d["y"]) for k, d in sorted(self.desks.items())))

    def seat(self, key):
        d = self.desks[key]
        return (d["x"] + d["w"] // 2 - 3, d["y"] + 3)

    def home(self, key):
        sx, sy = self.seat(key)
        return (sx, sy + 9)

    def spot(self, lead, slot):
        d = self.desks[lead]
        return (d["x"] + d["w"] + 1 + 7 * slot, d["y"] + 11)


# ---------------------------------------------------------------------------
# Scene: what is on the floor and how it moves
# ---------------------------------------------------------------------------

class Actor:
    def __init__(self, member):
        self.member = member
        self.key = member["key"]
        self.x, self.feet = 97, 50
        self.state = "gone"     # work|sleep|idle|walk|stand|retired|gone
        self.rest = "sleep"     # the state it settles into at home
        self.route = None
        self.arrive = None
        self.trail = []
        self.bang = 0
        self.bubble = ""
        self.slot = None
        self.errand = False     # on an inbox trip or packing up; keeps its place meanwhile


class Scene:
    def __init__(self):
        self.actors = {}
        self.tick = 0
        self.timers = []
        self.feed = []
        self.alumni = []
        self.retired = {}
        self.layout = None
        self.crew = []
        self.model = None
        self.first = True
        self.prev_waiting = {}
        self.prev_done = None
        self.prev_asks = None
        self.in_transit = 0
        self.inbox_real = 0
        self.counts = {"waiting": 0, "queued": 0, "in_flight": 0, "done": 0}
        self.overflow = {}
        self.known = set()
        self.read = set()

    # -- events --------------------------------------------------------------
    def log(self, who, text, color, when=None):
        self.feed.insert(0, {"t": when or time.strftime("%H:%M"), "who": clean(who),
                             "text": clean(text), "col": H(color) if isinstance(color, str) else color})
        del self.feed[14:]

    def at(self, dt, fn):
        self.timers.append((self.tick + dt, fn))

    # -- movement ------------------------------------------------------------
    def walk(self, a, route, arrive=None):
        a.state = "walk"
        a.route = [tuple(p) for p in route]
        a.arrive = arrive

    def place(self, a):
        L = self.layout
        m = a.member
        if m["kind"] == "intern":
            a.x, a.feet = L.spot(m["lead"], a.slot)
            a.state = a.rest
        else:
            a.x, a.feet = L.home(a.key)
            a.state = a.rest
        a.route, a.arrive = None, None

    def door(self):
        return (97, self.layout.walk_y)

    def intern_route_in(self, a):
        L = self.layout
        sx, sf = L.spot(a.member["lead"], a.slot)
        if a.member["lead"] == "fm":
            return [(81, L.walk_y), (81, sf), (sx, sf)]
        return [(sx, L.walk_y), (sx, sf)]

    def intern_route_out(self, a):
        L = self.layout
        if a.member["lead"] == "fm":
            return [(81, a.feet), (81, L.walk_y), self.door()]
        return [(a.x, L.walk_y), self.door()]

    def inbox_route(self, a):
        L = self.layout
        hx, hy = L.home(a.key)
        lane = [(23, hy), (23, L.walk_y)] if a.key == "fm" else [(hx, L.walk_y)]
        return lane + [(17, L.walk_y), (17, L.inbox_y)], list(reversed(lane)) + [(hx, hy)]

    # -- observation ---------------------------------------------------------
    def observe(self, model, crew, pane_rows):
        self.model = model
        prev_mates = {c["key"]: c for c in self.crew if c["kind"] == "mate"}
        self.crew = crew
        first = self.first
        items = model["items"]
        fresh = set(model["snapshots"]) - self.read
        self.counts = bridge._counts(items)
        self.inbox_real = self.counts["waiting"]

        desk_members = [c for c in crew if c["kind"] in ("first", "mate")]
        interns = [c for c in crew if c["kind"] == "intern"]
        live_keys = {c["key"] for c in desk_members}

        # Mates this screen watched leave the registry pack up and walk out.
        if not first:
            for key, m in prev_mates.items():
                if key in live_keys or key in self.retired:
                    continue
                a = self.actors.get(key)
                if a is not None:
                    self.retire(a)
                    continue
                a = Actor(m)
                a.state = a.rest = "retired"
                self.retired[key] = a
                self.alumni.append(m)
                self.log(m["name"], "retires; photo goes up on the alumni wall", m["color"])
        mates = [c for c in desk_members if c["kind"] == "mate"]
        retired = [dict(a.member, retired=True, status="sleep") for a in self.retired.values()]
        layout = Layout(mates, retired, pane_rows, interns)
        relayout = self.layout is None or layout.signature != self.layout.signature
        self.layout = layout
        down = {"fm"} | {m["key"] for m in layout.down}

        for m in desk_members:
            a = self.actors.get(m["key"])
            if m["key"] not in down:
                if a is not None and not a.errand:
                    del self.actors[m["key"]]
                continue
            want = "work" if m["status"] == "work" else "sleep"
            if a is None:
                a = Actor(m)
                a.rest = want
                self.actors[m["key"]] = a
                if first or m["key"] in self.known:
                    self.place(a)
                else:
                    hx, hy = layout.home(m["key"])
                    a.x, a.feet = self.door()
                    self.walk(a, [(hx, layout.walk_y), (hx, hy)], lambda a=a: self.settle(a))
                    self.log(m["name"], "joins the crew", m["color"])
                continue
            a.member = m
            self._apply_status(a, want, first)
            if relayout and a.state != "walk":
                self.place(a)

        # Interns: arrive through the right-hand door, leave the same way.
        present = {i["key"] for i in interns}
        for key, a in list(self.actors.items()):
            if a.member["kind"] == "intern" and key not in present and not a.member.get("leaving"):
                if first or a.member["lead"] not in layout.desks:
                    del self.actors[key]
                    continue
                lead = self._member(a.member["lead"])
                self.log("%s's intern" % (lead["name"] if lead else "the"), "finished, goes home",
                         a.member["color"])
                a.member = dict(a.member, leaving=True)
                self.walk(a, self.intern_route_out(a), lambda k=key: self.actors.pop(k, None))
        self.overflow = {}
        for i in interns:
            a = self.actors.get(i["key"])
            if i["lead"] not in layout.desks:
                if a is not None and not a.member.get("leaving"):
                    del self.actors[i["key"]]
                continue
            want = "work" if i["status"] == "work" else "idle"
            if a is not None and a.member["lead"] != i["lead"] and not a.member.get("leaving"):
                # A new person in charge: walk over to stand beside them.
                slot = self._free_slot(i["lead"])
                if slot is None:
                    del self.actors[i["key"]]
                    self.overflow[i["lead"]] = self.overflow.get(i["lead"], 0) + 1
                    continue
                a.member, a.slot, a.rest = i, slot, want
                self.walk(a, [(a.x, layout.walk_y)] + self.intern_route_in(a), lambda a=a: self.settle(a))
                continue
            if a is None:
                slot = self._free_slot(i["lead"])
                if slot is None:
                    self.overflow[i["lead"]] = self.overflow.get(i["lead"], 0) + 1
                    continue
                a = Actor(i)
                a.slot, a.rest = slot, want
                self.actors[i["key"]] = a
                if first or i["key"] in self.known or i["home"] in fresh:
                    self.place(a)
                else:
                    a.x, a.feet = self.door()
                    self.walk(a, self.intern_route_in(a), lambda a=a: self.settle(a))
                    lead = self._member(i["lead"])
                    self.log(lead["name"], "calls in an intern", lead["color"])
                continue
            a.member = i
            a.rest = want
            if a.state in ("work", "idle"):
                a.state = want
            if relayout and a.state != "walk":
                self.place(a)

        # Someone newly needs the captain: a walk to the inbox with a sheet.
        waiting_now = {m["key"]: m.get("waiting", 0) for m in desk_members}
        if not first:
            for m in desk_members:
                if m["id"] in fresh:
                    continue
                key, n = m["key"], waiting_now[m["key"]]
                a = self.actors.get(key)
                if n >self.prev_waiting.get(key, n) and a is not None and a.state in ("work", "sleep"):
                    self.send_to_inbox(a, n - self.prev_waiting.get(key, 0))
        self.prev_waiting = waiting_now
        self.known |= {c["key"] for c in crew}

        # Backlog completions: history at start, news afterwards.
        done = [it for it in items if it["bucket"] == "done"]
        ids = {(it["owner"], it["id"]) for it in done}
        if self.prev_done is None:
            recent = sorted(done, key=lambda it: it["date"] or "", reverse=True)[:8]
            for it in reversed(recent):
                who = self._owner(it["owner"])
                self.log(who["name"], "finished " + it["title"], who["color"],
                         when=bridge._day(it["date"], model["today"]) or "")
        else:
            for it in done:
                if it["owner"] not in fresh and (it["owner"], it["id"]) not in self.prev_done:
                    who = self._owner(it["owner"])
                    self.log(who["name"], "finished " + it["title"], who["color"])
        self.prev_done = ids

        # A captain item newly filed: its owner asks the captain, in words.
        asks = {(it["owner"], it["id"]) for it in items if it["bucket"] == "waiting"}
        if self.prev_asks is not None:
            for it in items:
                if it["bucket"] == "waiting" and it["owner"] not in fresh \
                        and (it["owner"], it["id"]) not in self.prev_asks:
                    who = self._owner(it["owner"])
                    self.log(who["name"], "asks you " + it["title"], who["color"])
        self.prev_asks = asks
        self.read |= fresh
        self.first = False

    def _member(self, key):
        return next((c for c in self.crew if c["key"] == key), None)

    def _owner(self, owner):
        key = "fm" if owner == "main" else "mate:" + owner
        return self._member(key) or {"name": owner, "color": DIM}

    def _free_slot(self, lead):
        used = {a.slot for a in self.actors.values()
                if a.member["kind"] == "intern" and a.member["lead"] == lead}
        for s in range(self.layout.desks[lead]["cap"]):
            if s not in used:
                return s
        return None

    def _apply_status(self, a, want, first):
        if want == "work":
            if a.rest != "work":
                a.rest = "work"
                if not first:
                    self.log(a.member["name"], "wakes up", a.member["color"])
                if a.state == "sleep":
                    a.bang = 0 if first else 12
                    if first:
                        a.state = "work"
            return
        if a.rest == "sleep":
            return
        a.rest = "sleep"
        if a.state == "work":
            a.state = "sleep"
        if not first:
            self.log(a.member["name"], "falls asleep", a.member["color"])

    def settle(self, a):
        a.route = None
        a.state = a.rest
        a.errand = False

    def send_to_inbox(self, a, sheets):
        out, back = self.inbox_route(a)
        a.errand = True
        self.in_transit += sheets

        def dropped():
            self.in_transit = max(0, self.in_transit - sheets)
            a.bubble = "for you"
            a.state = "stand"
            self.log(a.member["name"], "left a question in your inbox", AMBER)

            def home():
                a.bubble = ""
                self.walk(a, back, lambda: self.settle(a))
            self.at(16, home)
        self.walk(a, out, dropped)

    def retire(self, a):
        L = self.layout
        self.retired[a.key] = a
        a.bubble = "bye"
        a.errand = True
        hx = L.home(a.key)[0] if a.key in L.desks else a.x

        def go():
            a.bubble = ""

            def gone():
                a.state = "retired"
                a.rest = "retired"
                self.alumni.append(a.member)
                self.log(a.member["name"], "retires; photo goes up on the alumni wall", a.member["color"])
            self.walk(a, [(hx, L.walk_y), self.door()], gone)
        self.at(12, go)

    # -- time ----------------------------------------------------------------
    def speed(self):
        acts = self.actors.values()
        if any(a.state == "walk" or a.bang > 0 or a.trail or a.bubble for a in acts) or self.timers:
            return 1
        if any(a.state == "work" for a in acts):
            return 2
        return 4

    def step(self, n=1):
        for _ in range(n):
            self.tick += 1
            due = [t for t in self.timers if t[0] <= self.tick]
            self.timers = [t for t in self.timers if t[0] > self.tick]
            for _t, fn in due:
                fn()
            for a in list(self.actors.values()):
                if a.bang > 0:
                    a.bang -= 1
                    if a.bang == 0 and a.state == "sleep" and a.rest == "work":
                        a.state = "work"
                if a.state == "walk" and a.route is not None:
                    self._step_walker(a)
                elif a.trail and self.tick % 2 == 0:
                    a.trail.pop(0)

    def _step_walker(self, a):
        if not a.route:
            a.route = None
            fn, a.arrive = a.arrive, None
            a.state = "stand"
            if fn:
                fn()
            return
        tx, ty = a.route[0]
        if a.x != tx:
            a.x += 1 if tx > a.x else -1
        elif a.feet != ty:
            a.feet += 1 if ty > a.feet else -1
        a.trail.append((a.x + 3, a.feet))
        del a.trail[:-90]
        if a.x == tx and a.feet == ty:
            a.route.pop(0)


# ---------------------------------------------------------------------------
# Canvas and drawing
# ---------------------------------------------------------------------------

class Canvas:
    def __init__(self, cols, rows):
        n = cols * rows
        self.C, self.R = cols, rows
        self.top = [BG] * n
        self.bot = [BG] * n
        self.ch = [""] * n
        self.fg = [INK] * n
        self.bold = [False] * n

    def put(self, c, r, s, fg=INK, bg=None, b=False):
        if r < 0 or r >= self.R:
            return
        C = self.C
        for i, ch in enumerate(clean(s)):
            cc = c + i
            if cc < 0 or cc >= C:
                continue
            k = r * C + cc
            self.ch[k] = ch
            self.fg[k] = fg
            self.bold[k] = b
            if bg is not None:
                self.top[k] = bg
                self.bot[k] = bg

    def cells(self):
        out = []
        for k in range(self.C * self.R):
            ch, top, bot = self.ch[k], self.top[k], self.bot[k]
            if ch and ch != " ":
                out.append((ch, self.fg[k], top, self.bold[k]))
            elif top == bot:
                out.append((" ", top, top, False))
            else:
                out.append(("▀", top, bot, False))
        return out

    def text(self):
        lines = []
        for r in range(self.R):
            row = "".join(self.ch[r * self.C + c] or " " for c in range(self.C))
            lines.append(row.rstrip())
        while lines and not lines[-1]:
            lines.pop()
        return "\n".join(lines)


class Office:
    """The pixel room: OW x height pixels, plus an overlaid text layer."""

    def __init__(self, height):
        self.h = height
        self.px = [0] * (OW * height)
        self.mask = bytearray(OW * height)
        self.texts = []

    def copy_from(self, base):
        self.px = base.px[:]
        self.mask = bytearray(OW * self.h)
        self.texts = list(base.texts)

    def p(self, x, y, col, m=False):
        x, y = int(round(x)), int(round(y))
        if 0 <= x < OW and 0 <= y < self.h:
            self.px[y * OW + x] = col
            if m:
                self.mask[y * OW + x] = 1

    def rect(self, x, y, w, h, col, m=False):
        for j in range(h):
            for i in range(w):
                self.p(x + i, y + j, col, m)

    def text(self, x, y, s, fg, force=False, b=False):
        self.texts.append((x, y, clean(s), fg, force, b))


def _static_room(L, counts, inbox, alumni, desks_info):
    o = Office(L.height)
    b = L.band
    fa, fb = P["floorA"], P["floorB"]
    for y in range(o.h):
        for x in range(OW):
            o.px[y * OW + x] = fa if ((x >> 2) + (y >> 2)) % 2 else fb
    o.rect(0, 0, OW, 7, P["wall"])
    o.rect(0, 7, OW, 1, P["wallEdge"])
    # Alumni wall: one framed photo per mate seen retiring.
    o.rect(3, 1, 16, 5, H("#151a26"))
    for i in range(3):
        fx = 4 + i * 5
        o.rect(fx, 1, 4, 5, H("#8a6d2b"))
        o.rect(fx + 1, 2, 2, 3, H("#0f131b"))
        if i < len(alumni):
            who = alumni[-1 - i]
            hair, color = H(who["hair"]), H(who["color"])
            o.p(fx + 1, 2, hair)
            o.p(fx + 2, 2, hair)
            o.p(fx + 1, 3, P["skin"])
            o.p(fx + 2, 3, P["skin"])
            o.p(fx + 1, 4, color)
            o.p(fx + 2, 4, color)
    o.text(4, 8, "alumni", LABEL)
    o.rect(40, 1, 16, 5, H("#10141d"))
    # Corkboard: one sticky-note column per task column, sized by its count.
    o.rect(22, 1, 14, 5, H("#6e5334"))
    o.rect(22, 1, 14, 1, H("#8a6a43"))
    for i, (key, _h, c) in enumerate(COLUMNS):
        n = counts.get(key, 0)
        n = 0 if n == 0 else min(6, 1 + n // 12)
        for j in range(n):
            o.p(23 + i * 3, 2 + (j % 3), c)
            o.p(24 + i * 3, 2 + (j % 3), mix(c, H("#6e5334"), 0.4) if j > 2 else c)
    o.text(23, 8, "tasks", LABEL)
    o.rect(60, 1, 9, 6, P["paper"])
    o.rect(60, 1, 9, 1, H("#d0493f"))
    for j in range(2):
        for i in range(4):
            o.p(61 + i * 2, 3 + j * 2, H("#d0493f") if (i == 2 and j == 1) else H("#9aa0aa"))
    o.text(60, 8, "plan", LABEL)
    o.rect(72, 1, 13, 6, P["woodD"])
    o.rect(72, 3, 13, 1, H("#2a1c13"))
    books = [H(c) for c in ("#3fb6c9", "#7b93ff", "#e6b422", "#c678dd", "#2fbf71", "#d0493f", "#e9e4d8")]
    for i in range(11):
        o.p(73 + i, 1, books[i % 7])
        o.p(73 + i, 2, books[(i + 3) % 7])
        o.p(73 + i, 4, books[(i + 5) % 7])
        o.p(73 + i, 5, books[(i + 1) % 7])
    o.text(73, 8, "memory", LABEL)
    o.rect(57, 2, 2, 2, P["paper"])
    o.p(57, 2, H("#1b1b1b"))
    o.rect(28, 50 + b, 38, 10, H("#191620"))
    o.rect(28, 50 + b, 38, 1, H("#241f2e"))
    for x, y in ((2, 9), (84, 50 + b)):
        o.rect(x + 1, y, 3, 3, P["plant"])
        o.p(x, y + 1, P["plantD"])
        o.p(x + 4, y + 1, P["plantD"])
        o.rect(x + 1, y + 3, 3, 3, P["pot"])
    o.rect(88, 9, 7, 16, P["rack"])
    o.rect(88, 9, 7, 1, H("#2a303b"))
    o.text(87, 26, "system", LABEL)
    o.rect(28, 10, 3, 3, H("#5aa6d6"))
    o.rect(27, 13, 5, 5, H("#c8ccd4"))
    o.p(29, 15, H("#3b82c4"))
    # The captain's door and the inbox paper stack.
    o.rect(1, 49 + b, 8, 11, P["wood"])
    o.rect(1, 49 + b, 8, 1, P["woodD"])
    o.p(7, 55 + b, H("#e6b422"))
    o.text(1, 50 + b, "CAPTAIN", AMBER, False, True)
    o.rect(10, 59 + b, 7, 1, H("#6b7280"))
    for j in range(min(8, int(math.ceil(inbox / 8.0)))):
        o.rect(11, 58 + b - j, 5, 1, P["paperD"] if j % 2 else P["paper"])
    o.text(18, 56 + b, "inbox %d" % inbox, AMBER, False, True)
    # The visitor door on the right wall, where interns come and go.
    o.rect(95, 48 + b, 1, 10, H("#0a0c10"))
    o.rect(94, 47 + b, 2, 1, P["wallEdge"])
    o.rect(94, 58 + b, 2, 1, P["wallEdge"])
    for y in range(-2, 3):
        for x in range(-10, 11):
            if (x * x) / 100.0 + (y * y) / 5.2 <= 1:
                o.p(46 + x, 55 + b + y, P["tableTop"] if y < 0 else P["table"])
    for x, y in ((38, 51), (46, 51), (54, 51), (40, 59), (52, 59)):
        o.rect(x, y + b, 3, 1, P["chair"])
    for key, d in L.desks.items():
        sx, sy = L.seat(key)
        for mx in _monitors(d):
            o.rect(mx, d["y"] - 6, 9, 5, P["frame"])
            o.rect(mx + 4, d["y"] - 1, 1, 1, P["frame"])
        o.rect(d["x"], d["y"], d["w"], 1, P["deskTop"])
        o.rect(d["x"], d["y"] + 1, d["w"], 1, P["desk"])
        o.rect(d["x"], d["y"] + 2, d["w"], 1, P["deskD"])
        o.rect(d["x"], d["y"] + 3, 1, 2, P["deskD"])
        o.rect(d["x"] + d["w"] - 1, d["y"] + 3, 1, 2, P["deskD"])
        if desks_info.get(key) == "retired":
            o.rect(d["x"] + 4, d["y"] - 3, 5, 3, H("#a47a4d"))
            o.rect(d["x"] + 4, d["y"] - 3, 5, 1, H("#c79a66"))
            o.p(d["x"] + 6, d["y"] - 2, H("#6e5334"))
        o.rect(sx - 1, sy + 4, 9, 4, P["chair"])
        o.rect(sx, sy + 8, 1, 2, P["chair"])
        o.rect(sx + 6, sy + 8, 1, 2, P["chair"])
    return o


def _monitors(d):
    if d["two"]:
        return [d["x"] + 1, d["x"] + d["w"] - 11]
    return [d["x"] + d["w"] // 2 - 4]


class Renderer:
    def __init__(self):
        self._static_key = None
        self._static = None

    def office(self, scene, now, records_ok):
        L = scene.layout
        tick = scene.tick
        info = {k: "retired" for k in scene.retired if scene.retired[k].state == "retired"}
        inbox = max(0, scene.inbox_real - scene.in_transit)
        key = (L.signature, tuple(a["key"] for a in scene.alumni), tuple(sorted(scene.counts.items())),
               inbox, tuple(sorted(info)))
        if key != self._static_key:
            self._static = _static_room(L, scene.counts, inbox, scene.alumni, info)
            self._static_key = key
        o = Office(L.height)
        o.copy_from(self._static)
        day = 6 <= now.hour < 18
        for j in range(3):
            for i in range(14):
                c = mix(H("#4f7fb8"), H("#7fa9d9"), j / 3.0) if day else H("#0d1628")
                if not day and (i * 7 + j * 13 + 40) % 23 == 0 and ((tick >> 3) + i) % 5:
                    c = H("#c9d6ff")
                o.p(41 + i, 2 + j, c)
        o.rect(48, 1, 1, 5, H("#10141d"))
        for j in range(6):
            on = ((tick >> 2) + j * 3) % 7 != 0
            o.p(90, 11 + j * 2, GREEN if on else H("#1f5a3a"))
            o.p(92, 11 + j * 2, AMBER if (j == 2 and (tick >> 3) % 2) else H("#1f5a3a"))
        o.text(88, 28, " ok " if records_ok else "late", GREEN if records_ok else AMBER)
        # Monitors: lit and scrolling for a seated worker, a standby light otherwise.
        for key, d in L.desks.items():
            a = scene.actors.get(key)
            working = a is not None and a.state == "work"
            color = H(a.member["color"]) if a else DIM
            for mx in _monitors(d):
                for j in range(3):
                    for i in range(7):
                        c = H("#101319")
                        if working:
                            n = 3 + ((j * 5 + (tick >> 1) + mx) % 5)
                            if i < n:
                                c = mix(color, H("#0c1f18"), 0.35 + 0.2 * ((i + j + (tick >> 1)) % 2))
                            else:
                                c = H("#0c1a14")
                        o.p(mx + 1 + i, d["y"] - 5 + j, c)
                if not working and info.get(key) != "retired" and a is not None:
                    o.p(mx + 7, d["y"] - 3, H("#6b4b1f") if (tick >> 4) % 2 else H("#2a2012"))
        for a in scene.actors.values():
            n = len(a.trail)
            base = H(a.member["color"])
            for i, (x, y) in enumerate(a.trail):
                if i % 3 == 0:
                    t = 1 - i / float(max(1, n))
                    o.p(x, y, mix(base, P["floorA"], 0.35 + 0.45 * t))
        for a in scene.actors.values():
            self._agent(o, scene, a)
        self._labels(o, scene, info)
        if L.upstairs:
            working = sum(1 for m in L.upstairs if m["status"] == "work")
            sign = "%d upstairs, %d working" % (len(L.upstairs), working)
            o.rect(73, 30, 23, 2, P["woodD"])
            o.text(95 - len(sign), 30, sign, P["paper"], True)
        for lead, extra in scene.overflow.items():
            if lead in L.desks:
                x, feet = L.spot(lead, L.desks[lead]["cap"])
                o.text(min(x, OW - 3), feet - 5, "+%d" % extra, SOFT, True)
        return o

    def _agent(self, o, scene, a):
        if a.state in ("gone", "retired"):
            return
        m = a.member
        tick = scene.tick
        body = H(m["color"])
        hair = H(m["hair"])
        sh = mix(body, 0, 0.3)
        skin = P["skin"]
        leg = H("#2a2f3a")
        L = scene.layout
        if a.state in ("work", "sleep") and m["kind"] != "intern" and a.key in L.desks:
            d = L.desks[a.key]
            x, y = L.seat(a.key)
            if a.state == "work":
                o.rect(x + 2, y, 3, 1, hair, True)
                o.rect(x + 1, y + 1, 5, 2, hair, True)
                o.rect(x + 2, y + 3, 3, 1, skin, True)
                o.rect(x + 1, y + 4, 5, 3, body, True)
                o.rect(x, y + 5, 1, 2, sh, True)
                o.rect(x + 6, y + 5, 1, 2, sh, True)
                f = (tick >> 1) % 2
                o.p(x + 1 + f, d["y"] + 2, skin, True)
                o.p(x + 5 - f, d["y"] + 2, skin, True)
            else:
                o.rect(x, d["y"] + 2, 7, 1, sh, True)
                o.rect(x + 1, y + 1, 5, 3, hair, True)
                o.rect(x + 1, y + 4, 5, 3, body, True)
                o.rect(x, y + 4, 1, 2, sh, True)
                o.rect(x + 6, y + 4, 1, 2, sh, True)
                if a.bang > 0:
                    o.text(x + 3, y - 4, "!", AMBER, True, True)
                else:
                    for k in range(3):
                        ph = ((tick >> 2) + k * 4) % 12
                        if ph < 9:
                            o.text(x + 6 + k, y - 1 - (ph // 3) * 2 - k, "Z" if k == 2 else "z", ZZZ, True)
            return
        x, y = a.x, a.feet - 9
        f = (tick >> 1) % 2 if a.state == "walk" else 0
        o.rect(x + 2, y, 3, 1, hair, True)
        o.rect(x + 1, y + 1, 5, 1, hair, True)
        o.p(x + 1, y + 2, hair, True)
        o.p(x + 5, y + 2, hair, True)
        o.rect(x + 2, y + 2, 3, 2, skin, True)
        o.p(x + 2, y + 2, H("#1b1b1b"), True)
        o.p(x + 4, y + 2, H("#1b1b1b"), True)
        o.rect(x + 1, y + 4, 5, 3, body, True)
        o.rect(x, y + 4, 1, 3, sh, True)
        o.rect(x + 6, y + 4, 1, 3, sh, True)
        o.p(x, y + 7, skin, True)
        o.p(x + 6, y + 7, skin, True)
        o.rect(x + 2, y + 7, 3, 1, sh, True)
        if f:
            for px_, py_ in ((1, 8), (5, 8), (2, 9), (4, 9)):
                o.p(x + px_, y + py_, leg, True)
        else:
            for px_, py_ in ((2, 8), (4, 8), (2, 9), (4, 9)):
                o.p(x + px_, y + py_, leg, True)
        if a.bubble:
            o.text(x - 1, y - 3, a.bubble, AMBER, True, True)
        if a.bang > 0:
            o.text(x + 3, y - 3, "!", AMBER, True, True)
        if m["kind"] == "intern" and a.state in ("work", "idle"):
            lead = scene.actors.get(m["lead"])
            lead_color = H(lead.member["color"]) if lead else body
            o.rect(x + 1, y + 6, 5, 1, H("#9aa3af"), True)
            lit = mix(lead_color, H("#0c1f18"), 0.3 + 0.3 * ((tick >> 2) % 2)) if a.state == "work" \
                else H("#1b1f27")
            o.rect(x + 2, y + 5, 3, 1, lit, True)

    def _labels(self, o, scene, info):
        L = scene.layout
        for key, d in L.desks.items():
            a = scene.actors.get(key) or scene.retired.get(key)
            if a is None:
                continue
            cx = d["x"] + d["w"] // 2
            name = a.member["name"]
            if info.get(key) == "retired" or a.state == "retired":
                st, stc = "retired", AMBER
            elif a.state == "work":
                st, stc = "working", GREEN
            elif a.state == "sleep":
                st, stc = "asleep", ZZZ
            else:
                st, stc = "walking", AMBER
            o.text(cx - len(name) // 2, d["y"] + 12, name, H(a.member["color"]), False, True)
            o.text(cx - len(st) // 2, d["y"] + 14, st, stc)


def compose_office(cv, o):
    for r in range(o.h // 2):
        row = (OY + r) * cv.C
        for c in range(min(OW, cv.C)):
            cv.top[row + c] = o.px[(2 * r) * OW + c]
            cv.bot[row + c] = o.px[(2 * r + 1) * OW + c]
    for x, y, s, fg, force, b in o.texts:
        r = OY + y // 2
        py = (y // 2) * 2
        if r >= cv.R:
            continue
        for i, ch in enumerate(s):
            c = x + i
            if c < 0 or c >= OW or c >= cv.C or ch == " ":
                continue
            if not force and (o.mask[py * OW + c] or (py + 1 < o.h and o.mask[(py + 1) * OW + c])):
                continue
            k = r * cv.C + c
            cv.ch[k] = ch
            cv.fg[k] = fg
            cv.bold[k] = b
            bg = mix(cv.top[k], cv.bot[k], 0.5)
            cv.top[k] = cv.bot[k] = bg


# ---------------------------------------------------------------------------
# Screens
# ---------------------------------------------------------------------------

class UI:
    def __init__(self):
        self.view = "office"
        self.paused = False
        self.selected = None
        self.project = None     # the picked card on the Projects view, by its key
        self.decision = None    # the highlighted row on the Approvals view
        self.toast = ""
        self.toast_until = 0.0
        self.tab_hits = []
        self.cal_mode = "month"  # Calendar: week, month or year
        self.cal_at = None      # Calendar: a day in the period shown, None for today's
        self.cal_hits = []      # Calendar: (row0, row1, col0, col1, action) tap targets
        self.services = []      # Calendar: read_services()


def _chrome(cv, ui, now):
    C, R = cv.C, cv.R
    cv.put(0, 0, " MISSION CONTROL ", BG, H("#2fbf71"), True)
    clk = now.strftime("%a %H:%M ")
    c = 18
    ui.tab_hits = []
    limit = C - len(clk) - 1
    for i, t in enumerate(TABS):
        s = " %d %s " % (i + 1, t)
        if c + len(s) > limit:
            break
        on = VIEWS[i] == ui.view
        cv.put(c, 0, s, BG if on else (INK if VIEWS[i] in READY else LABEL), INK if on else None, on)
        ui.tab_hits.append((c, c + len(s), i))
        c += len(s) + 1
    cv.put(C - len(clk), 0, clk, DIM)
    cv.put(0, 1, "─" * C, LINE)
    cv.put(0, R - 2, "─" * C, LINE)
    tag = " PAUSED " if ui.paused else " updates by itself "
    if ui.toast and time.monotonic() < ui.toast_until:
        keys = " " + ui.toast
    elif ui.view == "approvals":
        keys = " 1-9 switch view   up/down read each decision   answers happen in chat, not here   q quit "
    else:
        keys = " 1-9 switch view   up/down pick an agent   enter talk to it   p pause   q quit "
        if ui.view == "projects":
            keys = " 1-9 switch view   up/down pick a project   p pause   q quit "
        elif ui.view == "calendar":
            keys = " left/right earlier or later   t today   v week, month or year   1-9 switch view   p pause   q quit "
    cv.put(0, R - 1, clip(keys, C - len(tag) - 1), DIM)
    cv.put(C - len(tag), R - 1, tag, BG if ui.paused else GREEN, AMBER if ui.paused else None, True)


def _office_screen(cv, ui, scene, renderer, now, records_ok, notice):
    L = scene.layout
    o = renderer.office(scene, now, records_ok)
    compose_office(cv, o)
    C, R = cv.C, cv.R
    rows = L.height // 2
    feed_w = C - FEED_COL
    if feed_w >= FEED_MIN_WIDTH:
        for r in range(OY, OY + rows):
            cv.put(OW, r, "│", LINE)
        cv.put(FEED_COL, OY, "LIVE ACTIVITY", INK, None, True)
        cv.put(FEED_COL + 14, OY, "real", BG, GREEN, True)
        r = OY + 2
        last = OY + rows - 1
        if notice:
            for ln in wrap(notice, feed_w - 1)[:3]:
                cv.put(FEED_COL, r, ln, AMBER)
                r += 1
            r += 1
        text_w = feed_w - 8
        for f in scene.feed:
            if r > last:
                break
            cv.put(FEED_COL, r, f["t"][:6].ljust(7), DIMMER)
            who = clip(f["who"], max(4, text_w - 8))
            cv.put(FEED_COL + 7, r, who, f["col"], None, True)
            # The first line follows the name; the rest use the full width.
            first_w = max(6, text_w - len(who) - 1)
            text = " ".join(f["text"].split())
            head = wrap(text, first_w)[:1]
            rest = wrap(text[len(head[0]):].strip(), max(6, text_w)) if head else []
            if len(rest) > 2:
                rest = [rest[0], clip(rest[1] + " " + rest[2], max(6, text_w))]
            lines = head + rest
            if lines:
                cv.put(FEED_COL + 7 + len(who) + 1, r, lines[0], SOFT)
            r += 1
            for ln in lines[1:]:
                if r > last:
                    break
                cv.put(FEED_COL + 7, r, clip(ln, text_w), SOFT)
                r += 1
            r += 1
    # The team list under the office.
    tr = OY + rows
    cv.put(0, tr, "─ TEAM " + "─" * (C - 7), LINE)
    cv.put(2, tr, "TEAM", INK, None, True)
    path_c = max(60, C - 48)
    cv.put(3, tr + 1, "NAME", DIMMER)
    cv.put(14, tr + 1, "ROLE", DIMMER)
    cv.put(34, tr + 1, "DOING NOW", DIMMER)
    cv.put(path_c, tr + 1, "PATH (the project it works in)", DIMMER)
    note_r = R - 4
    last = note_r - 1 if note_r > tr + 3 else R - 3
    r = tr + 2
    people = [m for m in scene.crew if m["kind"] != "intern"]
    interns = [m for m in scene.crew if m["kind"] == "intern"]
    upstairs = {m["key"] for m in L.upstairs}
    gone = [dict(a.member, doing="retired", status="retired") for a in scene.retired.values()
            if a.state == "retired"]
    rows_out = people + gone + interns
    for m in rows_out:
        if r > last:
            break
        a = scene.actors.get(m["key"])
        g, gc = _glyph(m, a)
        if ui.selected == m["key"]:
            for c in range(C):
                k = r * C + c
                cv.top[k] = cv.bot[k] = H("#18202b")
        name = m["name"]
        role = m["role"] + (", upstairs" if m["key"] in upstairs else "")
        cv.put(1, r, g, gc, None, True)
        cv.put(3, r, clip(name, 10), H(m["color"]), None, True)
        cv.put(14, r, clip(role, 19), SOFT)
        doing = "waking up" if a is not None and a.bang > 0 else m["doing"]
        cv.put(34, r, clip(doing, path_c - 36), INK if m["status"] == "work" else QUIET)
        cv.put(path_c, r, clip(m["path"], C - path_c - 1), DIM)
        r += 1
    if not interns and r <= last:
        cv.put(1, r, "·", DIMMER)
        cv.put(3, r, "interns", QUIET, None, True)
        cv.put(14, r, "one job each", SOFT)
        cv.put(34, r, "none right now", QUIET)
    if note_r > tr + 3:
        cv.put(3, note_r, clip("Interns stand beside their person in charge for one job, then go home. "
                               "Sleeping agents cost nothing.", C - 4), DIMMER)


def _glyph(m, a):
    if m["status"] == "retired":
        return "□", H("#8a6d2b")
    if a is not None and a.state in ("walk", "stand"):
        return "◐", AMBER
    if m["status"] == "work":
        return "●", GREEN
    if m["kind"] == "intern":
        return "○", ZZZ
    return "z", ZZZ


def _box(cv, c0, r0, w, h, col):
    cv.put(c0, r0, "┌" + "─" * (w - 2) + "┐", col)
    for r in range(r0 + 1, r0 + h - 1):
        cv.put(c0, r, "│", col)
        cv.put(c0 + w - 1, r, "│", col)
    cv.put(c0, r0 + h - 1, "└" + "─" * (w - 2) + "┘", col)


def board(model):
    """The four task columns, ordered like the Bridge's board."""
    items = model["items"]
    return {
        "waiting": bridge._round_robin([it for it in items if it["bucket"] == "waiting"]),
        "queued": bridge._round_robin([it for it in items if it["bucket"] == "queued"]),
        "in_flight": [it for it in items if it["bucket"] == "in_flight"],
        "done": sorted([it for it in items if it["bucket"] == "done"],
                       key=lambda it: it["date"] or "", reverse=True),
    }


def _tasks_screen(cv, model):
    C, R = cv.C, cv.R
    cols = board(model)
    today = model["today"]
    colors = project_colors(model)
    c = 1
    for key, label, color in COLUMNS:
        n = str(len(cols[key]))
        cv.put(c, 3, n, color if key != "done" else INK, None, True)
        cv.put(c + len(n) + 1, 3, label.lower(), SOFT)
        c += len(n) + 1 + len(label) + 4
    oldest = min((it["since"] for it in cols["waiting"] if bridge._parse_day(it["since"])), default=None)
    if oldest:
        s = "oldest decision waiting: %s" % bridge._day(oldest, today)
        cv.put(c, 3, s, DIMMER)
        c += len(s) + 3
    for pill in ("real list, same one the Bridge reads", "real list"):
        if C - len(pill) - 1 > c:
            cv.put(C - len(pill) - 1, 3, pill, BG, GREEN, True)
            break
    w = max(12, (C - 3) // 4)
    h = R - 8
    for i, (key, label, color) in enumerate(COLUMNS):
        c0, r0 = i * (w + 1), 5
        items = cols[key]
        _box(cv, c0, r0, w, h, H("#262d38"))
        cv.put(c0 + 2, r0, " %s " % label, color, None, True)
        cv.put(c0 + 2 + len(label) + 3, r0, str(len(items)), color, None, True)
        r = r0 + 2
        if not items:
            if key == "in_flight":
                cv.put(c0 + 3, r, clip("nothing moving right now", w - 4), DIMMER)
                cv.put(c0 + 3, r + 1, clip("everyone is asleep", w - 4), DIMMER)
            else:
                cv.put(c0 + 3, r, "nothing here", DIMMER)
        shown = 0
        for it in items:
            if r > r0 + h - 5:
                break
            pname = it["project"]
            tag = SHIP_TAG if pname is None else clean(bridge._short(model, pname))
            tc = H(colors.get(pname.lower() if pname else None, FIRST_MATE_COLOR))
            day = bridge._day(it["date"] if key == "done" else it.get("since"), today) \
                if key in ("done", "waiting") else ""
            cv.put(c0 + 2, r, clip("■ " + tag, w - 4 - len(day)), tc, None, True)
            if day:
                cv.put(c0 + w - 2 - len(day), r, day, DIMMER)
            lines = wrap(clean(it["title"]), w - 5)
            if len(lines) > 2:
                lines = [lines[0], clip(lines[1] + " " + lines[2], w - 5)]
            for j, ln in enumerate(lines):
                cv.put(c0 + 4, r + 1 + j, ln, H("#c3cbd5"))
            r += 4
            shown += 1
        more = len(items) - shown
        if more > 0:
            cv.put(c0 + 2, r0 + h - 2, "+%d more" % more, DIM)


PROJECT_PILLS = {"active": ("Active", GREEN), "parked": ("Parked", AMBER), "quiet": ("Quiet", H("#3a4250"))}
CARD_MIN_W = 42
CARD_H = 9          # a card's rows, borders included; one blank row between grid rows
DECISIONS_H = 6     # the picked card's decisions under the grid, heading included


def project_cards(model, crew):
    """One card per registered project, then the setup itself, in registry order."""
    items = model["items"]
    ship = model["ship"]
    registered = {p["name"].lower(): p["name"] for p in model["projects"] if p["name"] != ship}
    colors = project_colors(model)
    by_key = {c["key"]: c for c in crew}
    fm = by_key.get("fm") or {"name": "First mate", "color": FIRST_MATE_COLOR, "status": "sleep"}
    working = set()
    for c in crew:
        if c["kind"] == "intern" and c["status"] == "work":
            working.add(registered.get((c.get("project") or "").lower()))
    cards = []
    for p in [p for p in model["projects"] if p["name"] != ship] + [None]:
        pname = p["name"] if p else None
        pitems = [it for it in items if it["project"] == pname]
        counts = bridge._counts(pitems)
        if p:
            mate = next((m for m in model.get("mates") or []
                         if pname.lower() in [x.lower() for x in m["projects"]]), None)
            lead = by_key.get("mate:" + mate["id"]) if mate else None
            if mate and lead is None:
                lead = {"name": mate_name(model, mate["id"]), "color": DIM, "status": "sleep"}
            lead = lead or fm
            entry = model["names"].get(pname)
            desc = entry.get("description") if isinstance(entry, dict) and entry.get("description") \
                else bridge._summary(p["description"])
            name = bridge._title(model, pname)
        else:
            lead = fm
            desc = "Housekeeping that belongs to no project, and work on the first mate itself."
            name = "The setup itself"
        agent_on = pname in working or (lead is not fm and len(mate["projects"]) == 1 and lead["status"] == "work")
        if agent_on or counts["in_flight"]:
            status = "active"
        elif p and p.get("parked"):
            status = "parked"
        else:
            status = "quiet"
        cards.append({
            "key": pname or "", "name": clean(name), "desc": clean(desc), "status": status,
            "color": colors.get(pname.lower() if pname else None, FIRST_MATE_COLOR),
            "lead": {"name": lead["name"], "color": lead["color"]}, "counts": counts,
            "decisions": [it for it in pitems if it["bucket"] == "waiting"],
        })
    return cards


def _picked(ui, cards):
    keys = [c["key"] for c in cards]
    return keys.index(ui.project) if ui.project in keys else 0


def _pick_project(ui, scene, down):
    if scene.model is None:
        return False
    cards = project_cards(scene.model, scene.crew)
    if not cards:
        return False
    i = (_picked(ui, cards) + (1 if down else -1)) % len(cards)
    ui.project = cards[i]["key"]
    return True


def _project_card(cv, c0, r0, w, card, picked):
    inner = w - 4
    _box(cv, c0, r0, w, CARD_H, INK if picked else H("#262d38"))
    label, pill_bg = PROJECT_PILLS[card["status"]]
    pill = " %s " % label
    cv.put(c0 + w - 2 - len(pill), r0 + 1, pill, BG if card["status"] != "quiet" else SOFT, pill_bg, True)
    cv.put(c0 + 2, r0 + 1, clip(card["name"], inner - len(pill) - 1), H(card["color"]), None, True)
    lines = wrap(" ".join(card["desc"].split()), inner)
    if len(lines) > 2:
        lines = [lines[0], clip(lines[1] + " " + lines[2], inner)]
    for j, ln in enumerate(lines):
        cv.put(c0 + 2, r0 + 2 + j, ln, H("#c3cbd5"))
    half = c0 + 2 + max(20, inner // 2)
    n = card["counts"]
    for (key, label_, color), (cc, rr) in zip(COLUMNS, ((c0 + 2, 4), (half, 4), (c0 + 2, 5), (half, 5))):
        s = str(n[key])
        cv.put(cc, r0 + rr, s, color if key != "done" else INK, None, True)
        cv.put(cc + len(s) + 1, r0 + rr, label_.lower(), SOFT)
    done = n["done"]
    total = done + n["waiting"] + n["queued"] + n["in_flight"]
    tail = " %d%%  %d/%d" % (round(100.0 * done / total) if total else 0, done, total)
    bar_w = max(4, inner - len(tail))
    fill = int(round(bar_w * done / total)) if total else 0
    cv.put(c0 + 2, r0 + 6, "━" * fill, GREEN)
    cv.put(c0 + 2 + fill, r0 + 6, "━" * (bar_w - fill), H("#262d38"))
    cv.put(c0 + 2 + bar_w, r0 + 6, tail, DIM)
    lead = card["lead"]
    cv.put(c0 + 2, r0 + 7, "■", H(lead["color"]), None, True)
    cv.put(c0 + 4, r0 + 7, clip(lead["name"], inner - 16), H(lead["color"]), None, True)
    cv.put(c0 + 5 + len(clip(lead["name"], inner - 16)), r0 + 7, "in charge", DIM)


def _projects_screen(cv, ui, scene):
    C, R = cv.C, cv.R
    model = scene.model
    cards = project_cards(model, scene.crew)
    real = cards[:-1]
    c = 1
    for n, label, color in ((len(real), "projects" if len(real) != 1 else "project", INK),
                            (sum(1 for p in real if p["status"] == "active"), "active", GREEN),
                            (sum(1 for p in real if p["status"] == "parked"), "parked", AMBER),
                            (sum(1 for p in real if p["status"] == "quiet"), "quiet", QUIET)):
        cv.put(c, 3, str(n), color, None, True)
        cv.put(c + len(str(n)) + 1, 3, label, SOFT)
        c += len(str(n)) + len(label) + 5
    for pill in ("real list, same one the Bridge reads", "real list"):
        if C - len(pill) - 1 > c:
            cv.put(C - len(pill) - 1, 3, pill, BG, GREEN, True)
            break
    per_row = max(1, (C - 1) // (CARD_MIN_W + 1))
    w = (C - 1 - (per_row - 1)) // per_row
    rows = (len(cards) + per_row - 1) // per_row
    fits = max(1, (R - 2 - 5 - DECISIONS_H + 1) // (CARD_H + 1))
    pick = _picked(ui, cards)
    first = max(0, min(pick // per_row - fits + 1, rows - fits))
    shown = min(fits, rows - first)
    for i, card in enumerate(cards[first * per_row:(first + shown) * per_row]):
        row, col = divmod(i, per_row)
        _project_card(cv, col * (w + 1), 5 + row * (CARD_H + 1), w, card, first * per_row + i == pick)
    if first:
        cv.put(C - 16, 4, "more above", DIM)
    if first + shown < rows:
        cv.put(C - 16, 5 + shown * (CARD_H + 1) - 1, "more below", DIM)
    # The picked card's first three decisions, underneath the grid.
    card = cards[pick]
    r = 5 + shown * (CARD_H + 1)
    head = "WAITING ON YOU FOR %s" % card["name"].upper()
    cv.put(0, r, "─" * C, LINE)
    cv.put(1, r, " %s " % clip(head, C - 4), H(card["color"]), None, True)
    if not card["decisions"]:
        cv.put(3, r + 1, "Nothing waits on you here.", DIMMER)
    for j, it in enumerate(card["decisions"][:3]):
        day = bridge._day(it.get("since"), model["today"])
        kind = "decide" if it["hold"] else "do"
        cv.put(3, r + 1 + j, kind, AMBER, None, True)
        cv.put(11, r + 1 + j, clip(clean(it["title"]), C - 14 - len(day)), H("#c3cbd5"))
        if day:
            cv.put(C - 1 - len(day), r + 1 + j, day, DIMMER)
    more = len(card["decisions"]) - 3
    if more > 0:
        cv.put(3, r + 4, "+%d more on the task board" % more, DIM)


def _age(since, today):
    d, t = bridge._parse_day(since), bridge._parse_day(today)
    if d is None or t is None:
        return "", 0
    n = max(0, (t - d).days)
    return ("today" if n == 0 else bridge._plural(n, "day")), n


def _plain(text):
    return clean(bridge.plain_note(text))


# Bookkeeping body lines (bin/fm-captain-hold.sh's Origin, Task and Decision key,
# the hold stamp, the old decision records' State) name ids, not the question.
_BOOKKEEPING = re.compile(r"^\s*(Origin|Task|Decision key|State|Captain hold set):")


def _decision_note(model, it):
    """The record's own note, without paths: its body lines, else its hold reason."""
    recs = ((model["snapshots"].get(it["owner"]) or {}).get("backlog") or {}).get("records") or []
    rec = next((x for x in recs if x.get("id") == it["id"]), {})
    parts = [x for x in rec.get("body_lines") or [] if isinstance(x, str) and not _BOOKKEEPING.match(x)]
    parts = parts or [rec.get("hold_reason") or ""]
    return _plain(" ".join(x for x in parts if x.strip()))


def approvals(model, crew):
    """What waits on the captain, one group per agent holding it, oldest first.

    The same items as the office inbox: the Bridge's waiting bucket."""
    people = {c["id"]: c for c in crew if c["kind"] in ("first", "mate")}
    order = ["main"] + [m["id"] for m in model.get("mates") or []]
    groups = []
    for owner in order:
        items = [it for it in model["items"] if it["bucket"] == "waiting" and it["owner"] == owner]
        if not items:
            continue
        items.sort(key=lambda it: (bridge._parse_day(it["since"]) is None, it["since"] or ""))
        who = people.get(owner) or {"name": mate_name(model, owner), "color": FIRST_MATE_COLOR}
        groups.append({"owner": owner, "name": who["name"], "color": who["color"],
                       "items": [dict(it, key="%s:%s" % (owner, it["id"])) for it in items]})
    return groups


def _approvals_screen(cv, ui, scene):
    C, R = cv.C, cv.R
    model = scene.model
    today = model["today"]
    groups = approvals(model, scene.crew)
    rows = [it for g in groups for it in g["items"]]
    if not rows:
        cv.put(3, 4, "Nothing waits on you.", GREEN, None, True)
        cv.put(3, 6, "Every decision has been made; the crew carries on by itself.", SOFT)
        cv.put(3, 7, "When an agent needs your word, it shows up here and in the office inbox.", DIMMER)
        return
    keys = [it["key"] for it in rows]
    pick = ui.decision if ui.decision in keys else keys[0]
    oldest = min((it["since"] for it in rows if bridge._parse_day(it["since"])), default=None)
    n = str(len(rows))
    cv.put(1, 3, n, AMBER, None, True)
    head = "%s on you, with %s" % ("decision waits" if len(rows) == 1 else "decisions wait",
                                   bridge._plural(len(groups), "agent"))
    cv.put(len(n) + 2, 3, head, SOFT)
    c = len(n) + 2 + len(head) + 3
    if oldest:
        age = _age(oldest, today)[0]
        s = "oldest asked today" if age == "today" else "oldest since %s, %s ago" % (bridge._day(oldest, today), age)
        cv.put(c, 3, s, DIMMER)
        c += len(s) + 3
    for pill in ("read only, answer in chat", "read only"):
        if C - len(pill) - 1 > c:
            cv.put(C - len(pill) - 1, 3, pill, BG, GREEN, True)
            break

    # The list: a rule per agent, then its decisions, scrolled to keep the pick in view.
    colors = project_colors(model)
    qc = 38
    qw = max(12, C - qc - 2)
    lines = []     # (kind, payload, row offset within a decision)
    for g in groups:
        if lines:
            lines.append(("gap", None, 0))
        lines.append(("group", g, 0))
        for it in g["items"]:
            q = wrap(_plain(it["title"]), qw)
            if len(q) > 2:
                q = [q[0], clip(q[1] + " " + q[2], qw)]
            for j, ln in enumerate(q or [""]):
                lines.append(("item", (it, ln), j))
    panel_h = 9
    top, bottom = 5, R - 3 - panel_h
    room = bottom - top + 1
    at = [i for i, (k, p, _) in enumerate(lines) if k == "item" and p[0]["key"] == pick]
    off = 0
    if at and at[-1] >= room:
        off = at[-1] - room + 1
    for i, (kind, p, j) in enumerate(lines[off:off + room]):
        r = top + i
        if kind == "group":
            cv.put(0, r, "─" * C, LINE)
            cv.put(2, r, " %s %d " % (p["name"], len(p["items"])), H(p["color"]), None, True)
            continue
        if kind != "item":
            continue
        it, ln = p
        on = it["key"] == pick
        if on:
            for cc in range(C):
                k = r * C + cc
                cv.top[k] = cv.bot[k] = H("#18202b")
        if j == 0:
            if on:
                cv.put(1, r, "▸", AMBER, None, True)
            age, days = _age(it["since"], today)
            cv.put(12 - len(age), r, age, AMBER if days >= 7 else QUIET)
            pname = it["project"]
            tag = SHIP_TAG if pname is None else clean(bridge._short(model, pname))
            tc = H(colors.get(pname.lower() if pname else None, FIRST_MATE_COLOR))
            cv.put(14, r, clip("■ " + tag, qc - 16), tc, None, True)
        cv.put(qc, r, ln, INK if on else H("#c3cbd5"), None, on and j == 0)
    above = sum(1 for k, _, j in lines[:off] if k == "item" and j == 0)
    below = sum(1 for k, _, j in lines[off + room:] if k == "item" and j == 0)

    # The picked decision in full: title, who holds it, and its note.
    it = next(x for x in rows if x["key"] == pick)
    g = next(x for x in groups if x["owner"] == it["owner"])
    r0 = R - 2 - panel_h
    _box(cv, 0, r0, C, panel_h, H("#262d38"))
    cv.put(2, r0, " THE DECISION ", AMBER, None, True)
    c = C - 2
    for n, where in ((below, "below"), (above, "above")):
        if n:
            s = " %d more %s " % (n, where)
            c -= len(s)
            cv.put(c, r0, s, DIM)
            c -= 1
    w = C - 6
    title = wrap(_plain(it["title"]), w)
    if len(title) > 2:
        title = [title[0], clip(title[1] + " " + " ".join(title[2:]), w)]
    r = r0 + 1
    for ln in title:
        cv.put(3, r, ln, INK, None, True)
        r += 1
    since = bridge._day(it["since"], today)
    age = _age(it["since"], today)[0]
    asked = ("asked %s" % ("today" if age == "today" else "%s, %s ago" % (since, age))) if since else ""
    project = "project %s" % bridge._title(model, it["project"]) if it["project"] else "the ship's own setup"
    facts = ", ".join(x for x in (asked, "sits with %s" % g["name"], project) if x)
    cv.put(3, r, clip(facts, w), H(g["color"]))
    r += 1
    last = r0 + panel_h - 2
    note = wrap(_decision_note(model, it), w)
    if not note:
        cv.put(3, r, "No further notes on this one.", DIMMER)
    room = last - r + 1
    if len(note) > room:
        note = note[:room - 1] + [clip(note[room - 1] + " " + " ".join(note[room:]), w)]
    for ln in note:
        cv.put(3, r, ln, SOFT)
        r += 1


def _later_screen(cv, name):
    cv.put(2, 4, "%s is coming next. Press 1 for the office or 2 for the task board." % name, SOFT)


# ---------------------------------------------------------------------------
# Calendar: a week of what got done and what is due, under what always runs
# ---------------------------------------------------------------------------

BRIDGE_AGENT = "com.firstmate.bridge"     # bin/fm-bridge.sh's LaunchAgent label
DAY_MIN_WIDTH = 18
_WEEKDAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
_MONTHS = ["january", "february", "march", "april", "may", "june", "july", "august",
           "september", "october", "november", "december"]
_MONTH_WORD = "(%s)" % "|".join(m.capitalize() for m in _MONTHS)
_WEEKDAY_WORD = r"(?:(%s),?\s+)?" % "|".join(d.capitalize() for d in _WEEKDAYS)
_TITLE_DATES = [
    ("dmy", re.compile(r"\b%s(\d{1,2})\s+%s\b(?:,?\s+(\d{4})\b)?" % (_WEEKDAY_WORD, _MONTH_WORD))),
    ("mdy", re.compile(r"\b%s%s\s+(\d{1,2})\b(?:,?\s+(\d{4})\b)?" % (_WEEKDAY_WORD, _MONTH_WORD))),
    ("iso", re.compile(r"\b(\d{4})-(\d{2})-(\d{2})\b")),
]
_SHORT_WEEKDAY_BEFORE = re.compile(r"\b(?:Mon|Tues?|Wed|Thu(?:rs?)?|Fri|Sat|Sun),?\s+$")


def _resolve_day(day, month, year, weekday, today):
    """One calendar day, or None when it would take a guess."""
    if year is not None:
        years = [year]
    else:
        years = [today.year - 1, today.year, today.year + 1]
    found = []
    for y in years:
        try:
            d = _dt.date(y, month, day)
        except ValueError:
            continue
        if weekday is not None and d.weekday() != weekday:
            continue
        found.append(d)
    if year is None:
        # No year: only a reading within half a year of today counts.
        found = [d for d in found if abs((d - today).days) <= 182]
    return found[0] if len(found) == 1 else None


def title_date(title, today):
    """The one date a title clearly names ("Sunday 27 September", "2026-09-27"), else None."""
    days = set()
    spans = []
    for kind, rx in _TITLE_DATES:
        for m in rx.finditer(title):
            if any(m.start() < e and s < m.end() for s, e in spans):
                continue
            spans.append((m.start(), m.end()))
            if kind == "iso":
                d = _resolve_day(int(m.group(3)), int(m.group(2)), int(m.group(1)), None, today)
            else:
                wd, a, b, y = m.groups()
                if not wd and _SHORT_WEEKDAY_BEFORE.search(title, 0, m.start()):
                    return None
                day, mon = (a, b) if kind == "dmy" else (b, a)
                month = _MONTHS.index(mon.lower()) + 1
                weekday = _WEEKDAYS.index(wd.lower()) if wd else None
                d = _resolve_day(int(day), month, int(y) if y else None, weekday, today)
            if d is None:
                return None
            days.add(d)
    return days.pop() if len(days) == 1 else None


def _month_start(d, months=0):
    """The first day of d's month, moved by whole months."""
    n = d.year * 12 + d.month - 1 + months
    return _dt.date(n // 12, n % 12 + 1, 1)


def _sunday(d):
    return d - _dt.timedelta(days=(d.weekday() + 1) % 7)


def week_days(anchor, count):
    """The Week's days: Sunday to Saturday around anchor, or from anchor when fewer fit."""
    start = _sunday(anchor) if count >= 7 else anchor
    return [start + _dt.timedelta(days=i) for i in range(min(7, count))]


def month_days(anchor):
    """The Month's grid: whole weeks from Sunday covering anchor's month, never fewer than five."""
    start = _sunday(_month_start(anchor))
    last = _month_start(anchor, 1) - _dt.timedelta(days=1)
    weeks = max(5, (last - start).days // 7 + 1)
    return [start + _dt.timedelta(days=i) for i in range(7 * weeks)]


def year_days(anchor):
    first = _dt.date(anchor.year, 1, 1)
    return [first + _dt.timedelta(days=i) for i in range((_dt.date(anchor.year + 1, 1, 1) - first).days)]


def calendar(model, days):
    """{day: [entry]} for the given days: what was done, then what is due."""
    today = bridge._parse_day(model["today"])
    want = set(days)
    out = {d: [] for d in days}
    for it in list(model["items"]) + list(model.get("history") or []):
        if it["bucket"] == "done":
            d = bridge._parse_day(it["date"])
            mark = "done"
        else:
            d = bridge._parse_day(it.get("until")) or title_date(it["title"], today)
            if d is not None and d < today:
                continue
            mark = "due"
        if d in want:
            out[d].append(dict(it, mark=mark))
    for d in days:
        out[d].sort(key=lambda it: (it["mark"] != "due", it["project"] or "", it["title"]))
    return out


def read_services(home, self_running=False):
    """What always runs on this Mac: [(name, one-word state)], mates excluded."""
    bridge_state = "off"
    try:
        proc = subprocess.run(["launchctl", "print", "gui/%d/%s" % (os.getuid(), BRIDGE_AGENT)],
                              capture_output=True, text=True, timeout=3, check=False)
        if proc.returncode == 0:
            m = re.search(r"^\s*state = (.+)$", proc.stdout, re.M)
            bridge_state = "running" if m and m.group(1).strip() == "running" else "stopped"
    except (OSError, subprocess.SubprocessError):
        pass
    mc_state = "running" if self_running else "off"
    if not self_running:
        try:
            proc = subprocess.run(["ps", "-A", "-o", "command="], capture_output=True, text=True,
                                  timeout=3, check=False)
            homes = {" run --home %s --config-dir " % h for h in (home, _real(home)) if h}
            for line in proc.stdout.splitlines():
                if "fm_mission_control.py" in line and any(h in line for h in homes):
                    mc_state = "running"
                    break
        except (OSError, subprocess.SubprocessError):
            pass
    return [("Bridge", bridge_state), ("Mission Control", mc_state)]


STATE_COLORS = {"running": GREEN, "working": GREEN, "asleep": ZZZ, "stopped": AMBER,
                "closed": QUIET, "remote": QUIET, "off": DIMMER}


def _mate_word(m):
    if m["doing"] == "works on another machine":
        return "remote"
    if m["status"] == "work":
        return "working"
    return "asleep" if m.get("pane") else "closed"


CAL_MODES = ("week", "month", "year")
CHIP = H("#262d38")
TODAY_TINT = H("#11171f")


def _cal_now(ui, model):
    today = bridge._parse_day(model["today"]) if model else _dt.date.today()
    return today, ui.cal_at or today


def _same_period(mode, a, b):
    if mode == "week":
        return _sunday(a) == _sunday(b)
    if mode == "month":
        return (a.year, a.month) == (b.year, b.month)
    return a.year == b.year


def cal_action(ui, model, act):
    """One Calendar control, from a key or a tap: ("mode", m), ("cycle",), ("move", +1 or -1),
    ("today",) or ("month", its first day)."""
    today, anchor = _cal_now(ui, model)
    kind = act[0]
    if kind == "mode":
        ui.cal_mode = act[1]
    elif kind == "cycle":
        ui.cal_mode = CAL_MODES[(CAL_MODES.index(ui.cal_mode) + 1) % len(CAL_MODES)]
    elif kind == "today":
        ui.cal_at = None
    elif kind in ("move", "month"):
        if kind == "move":
            if ui.cal_mode == "week":
                anchor += _dt.timedelta(days=7 * act[1])
            else:
                anchor = _month_start(anchor, act[1] * (1 if ui.cal_mode == "month" else 12))
        else:
            ui.cal_mode, anchor = "month", act[1]
        # Back on today's own period, the Calendar follows today again.
        ui.cal_at = None if _same_period(ui.cal_mode, anchor, today) else anchor
    return True


def _rel_words(offset, unit):
    if offset == 0:
        return "this " + unit
    if abs(offset) == 1:
        return ("next " if offset > 0 else "last ") + unit
    return ("in %d %ss" if offset > 0 else "%d %ss ago") % (abs(offset), unit)


def _month_name(d):
    return _MONTHS[d.month - 1].capitalize()


def _week_span(days, today):
    first, last = days[0], days[-1]
    if first.month == last.month:
        span = "%d to %d %s" % (first.day, last.day, _month_name(last))
    else:
        span = "%d %s to %d %s" % (first.day, _month_name(first), last.day, _month_name(last))
    if last.year != today.year:
        span += " %d" % last.year
    return span


def _item_color(model, colors, it):
    pname = it["project"]
    tag = SHIP_TAG if pname is None else clean(bridge._short(model, pname))
    return tag, H(colors.get(pname.lower() if pname else None, FIRST_MATE_COLOR))


def _control_bar(cv, ui, model, colors, title, rel, current, entries):
    """Week | Month | Year, the period with its arrows, and a way back to today, all tappable."""
    C, r = cv.C, 3
    c = 1
    for i, m in enumerate(CAL_MODES):
        s = " %s " % m.capitalize()
        on = m == ui.cal_mode
        cv.put(c, r, s, BG if on else INK, GREEN if on else CHIP, on)
        ui.cal_hits.append((r, r + 1, c, c + len(s), ("mode", m)))
        c += len(s)
        if i < len(CAL_MODES) - 1:
            cv.put(c, r, "│", DIMMER, CHIP)
            c += 1
    c += 3
    for arrow, step in ((" ◂ ", -1), (None, 0), (" ▸ ", 1)):
        if arrow is None:
            s = "  %s  " % title
            cv.put(c, r, s, INK, None, True)
        else:
            s = arrow
            cv.put(c, r, s, INK, CHIP, True)
            ui.cal_hits.append((r, r + 1, c, c + len(s), ("move", step)))
        c += len(s)
    c += 2
    s = " %s " % rel
    cv.put(c, r, s, BG if current else INK, GREEN if current else CHIP, True)
    ui.cal_hits.append((r, r + 1, c, c + len(s), ("today",)))
    c += len(s) + 1
    if not current:
        s = " back to today "
        cv.put(c, r, s, GREEN, CHIP, True)
        ui.cal_hits.append((r, r + 1, c, c + len(s), ("today",)))
        c += len(s) + 1
    n_done = sum(1 for it in entries if it["mark"] == "done")
    counts = "%d done, %d due" % (n_done, len(entries) - n_done)
    cv.put(c + 1, r, counts, DIM)
    c += len(counts) + 4
    # Which colour is which project, busiest first, as many as fit.
    seen = {}
    for it in entries:
        tag, pc = _item_color(model, colors, it)
        n, _ = seen.get(tag, (0, pc))
        seen[tag] = (n + 1, pc)
    chips = sorted(seen.items(), key=lambda kv: (-kv[1][0], kv[0]))
    while chips and sum(len(t) + 4 for t, _ in chips) > C - 1 - c:
        chips.pop()
    x = C - 1 - sum(len(t) + 4 for t, _ in chips) + 2
    for tag, (_, pc) in chips:
        cv.put(x, r, "■", pc)
        cv.put(x + 2, r, tag, SOFT)
        x += len(tag) + 4


def _always_running(cv, ui, crew):
    """The Bridge, this screen, and every second mate."""
    C = cv.C
    _box(cv, 0, 5, C, 3, CHIP)
    cv.put(2, 5, " ALWAYS RUNNING ", INK, None, True)
    chips = list(ui.services) + [(m["name"], _mate_word(m)) for m in crew if m["kind"] == "mate"]
    c = 2
    for i, (name, word) in enumerate(chips):
        chip = "● %s %s" % (name, word)
        rest = len(chips) - i
        if c + len(chip) > C - 2 - (len("+%d more" % rest) + 3 if rest > 1 else 0):
            cv.put(c, 6, "+%d more" % rest, DIM)
            break
        col = STATE_COLORS.get(word, DIM)
        cv.put(c, 6, "●", col)
        cv.put(c + 2, 6, clean(name), INK, None, True)
        cv.put(c + 3 + len(name), 6, word, col)
        c += len(chip) + 4


def _calendar_screen(cv, ui, model, crew):
    C, R = cv.C, cv.R
    today, anchor = _cal_now(ui, model)
    colors = project_colors(model)
    mode = ui.cal_mode
    if mode == "week":
        n = max(1, min(7, (C + 1) // (DAY_MIN_WIDTH + 1)))
        days = week_days(anchor, n)
        shown = days
        title = _week_span(days, today)
        offset = ((_sunday(anchor) - _sunday(today)).days if n >= 7 else (anchor - today).days) // 7
    elif mode == "month":
        days = month_days(anchor)
        shown = [d for d in days if d.month == anchor.month]
        title = "%s %d" % (_month_name(anchor), anchor.year)
        offset = (anchor.year - today.year) * 12 + anchor.month - today.month
    else:
        days = shown = year_days(anchor)
        title = str(anchor.year)
        offset = anchor.year - today.year
    cal = calendar(model, days)
    ui.cal_hits = []
    _control_bar(cv, ui, model, colors, title, _rel_words(offset, mode), offset == 0,
                 [it for d in shown for it in cal[d]])
    _always_running(cv, ui, crew)
    top, bottom = 9, R - 3
    if mode == "week":
        _week_grid(cv, model, colors, days, cal, today, top, bottom)
    elif mode == "month":
        _month_grid(cv, model, colors, days, cal, anchor, today, top, bottom)
    else:
        _year_grid(cv, ui, model, colors, anchor.year, cal, today, top, bottom)


def _week_grid(cv, model, colors, days, cal, today, top, bottom):
    C, n = cv.C, len(days)
    w = (C - (n - 1)) // n
    for j, d in enumerate(days):
        c0 = j * (w + 1)
        is_today = d == today
        if is_today:
            for r in range(top, bottom + 1):
                for cc in range(c0, c0 + w):
                    k = r * C + cc
                    cv.top[k] = cv.bot[k] = TODAY_TINT
        head = "%s %d" % (d.strftime("%a"), d.day)
        if d.day == 1 or j == 0:
            head += " %s" % d.strftime("%b")
        cv.put(c0 + 1, top, head, GREEN if is_today else (DIM if d < today else INK), None, True)
        if is_today:
            cv.put(c0 + w - 7, top, " today ", BG, GREEN, True)
        cv.put(c0, top + 1, "─" * w, GREEN if is_today else LINE)
        entries = cal[d]
        r = top + 2
        if not entries:
            cv.put(c0 + 1, r, clip("nothing finished" if d < today else "nothing due", w - 2), DIMMER)
            continue
        # Two title lines per block while the day has room, else one.
        tall = len(entries) * 4 <= bottom - r + 1
        bh = 4 if tall else 3
        room = (bottom - r + 1) // bh
        shown = entries if len(entries) <= room else entries[:max(0, room - 1)]
        for it in shown:
            tag, pc = _item_color(model, colors, it)
            due = it["mark"] == "due"
            edge = pc if due else mix(pc, BG, 0.45)
            _box(cv, c0 + 1, r, w - 2, bh, edge)
            mark = " %s " % it["mark"]
            cv.put(c0 + 2, r, " %s " % clip(tag, w - 7 - len(mark)), pc, None, True)
            cv.put(c0 + w - 2 - len(mark), r, mark, AMBER if due else DIM, None, due)
            lines = wrap(clean(it["title"]), w - 6)
            if len(lines) > bh - 2:
                lines = lines[:bh - 3] + [clip(" ".join(lines[bh - 3:]), w - 6)]
            for i, ln in enumerate(lines):
                cv.put(c0 + 3, r + 1 + i, ln, INK if due else SOFT)
            r += bh
        more = len(entries) - len(shown)
        if more > 0:
            cv.put(c0 + 2, r, "+%d more" % more, DIM)
    for j in range(1, n):
        cc = j * (w + 1) - 1
        for r in range(top, bottom + 1):
            cv.put(cc, r, "┼" if r == top + 1 else "│", LINE)


def _month_grid(cv, model, colors, days, cal, anchor, today, top, bottom):
    """Every day of the month in whole weeks; each week's top border carries its day numbers."""
    C = cv.C
    weeks = len(days) // 7
    base, extra = divmod(C - 8, 7)
    widths = [base + (1 if j < extra else 0) for j in range(7)]
    xs = [sum(widths[:j]) + j for j in range(8)]      # each cell's left border, then the right edge
    for j in range(7):
        name = _WEEKDAYS[(j + 6) % 7]
        cv.put(xs[j] + 2, top, name.capitalize() if widths[j] >= 10 else name[:3].capitalize(), SOFT, None, True)
    k = max(1, (bottom - top - 1) // weeks - 1)          # item lines in a day
    for i in range(weeks + 1):
        r = top + 1 + i * (k + 1)
        ends = "┌┬┐" if i == 0 else ("└┴┘" if i == weeks else "├┼┤")
        cv.put(0, r, ends[0] + ends[1].join("─" * w for w in widths) + ends[2], CHIP)
        if i == weeks:
            break
        for rr in range(r + 1, r + k + 1):
            for x in xs:
                cv.put(x, rr, "│", CHIP)
        for j in range(7):
            d = days[i * 7 + j]
            x, w = xs[j], widths[j]
            inside = d.month == anchor.month
            if d == today:
                for rr in range(r + 1, r + k + 1):
                    for cc in range(x + 1, x + w + 1):
                        cv.top[rr * C + cc] = cv.bot[rr * C + cc] = TODAY_TINT
                cv.put(x + 1, r, "─" * w, GREEN)
                num = " %d " % d.day
                cv.put(x + 1, r, num, BG, GREEN, True)
                if w >= len(num) + 6:
                    cv.put(x + 1 + len(num), r, "today ", GREEN, None, True)
            else:
                num = " %d " % d.day if inside or d.day != 1 else " 1 %s " % d.strftime("%b")
                cv.put(x + 1, r, num, INK if inside else DIMMER, None, inside)
            entries = cal[d]
            shown = entries if len(entries) <= k else entries[:k - 1]
            for n, it in enumerate(shown):
                _, pc = _item_color(model, colors, it)
                due = it["mark"] == "due"
                col = pc if due else mix(pc, BG, 0.3)
                if not inside:
                    col = mix(col, BG, 0.5)
                cv.put(x + 2, r + 1 + n, "●" if due else "✓", AMBER if due and inside else col, None, due)
                cv.put(x + 4, r + 1 + n, clip(clean(it["title"]), w - 4), col, None, due)
            if len(shown) < len(entries):
                cv.put(x + 4, r + 1 + len(shown), "+%d more" % (len(entries) - len(shown)),
                       DIM if inside else DIMMER)


def _year_grid(cv, ui, model, colors, year, cal, today, top, bottom):
    """Twelve small months; a day with items takes the colour of the project with most of them."""
    C = cv.C
    firsts = [_dt.date(year, m, 1) for m in range(1, 13)]
    lead = [(f.weekday() + 1) % 7 for f in firsts]
    weeks = [(lead[i] + (_month_start(f, 1) - f).days + 6) // 7 for i, f in enumerate(firsts)]
    plan = None
    for header in (True, False):
        for gap in (1, 0):
            for ncol in (4, 6, 3, 2):
                dw = min(5, (C - 2 - 3 * (ncol - 1)) // (7 * ncol))
                rows = [weeks[i:i + ncol] for i in range(0, 12, ncol)]
                heights = [1 + header + max(r) for r in rows]
                if dw >= 3 and sum(heights) + gap * (len(rows) - 1) <= bottom - top + 1:
                    plan = (ncol, dw, heights, gap, header)
                    break
            if plan:
                break
        if plan:
            break
    if plan is None:
        plan = (4, 3, [8, 8, 8], 0, False)
    ncol, dw, heights, gap, header = plan
    if gap and len(heights) > 1:
        gap = min(3, (bottom - top + 1 - sum(heights)) // (len(heights) - 1))
    mw = 7 * dw
    hgap = min(8, (C - 2 - mw * ncol) // max(1, ncol - 1)) if ncol > 1 else 0
    x0 = max(0, (C - (mw * ncol + hgap * (ncol - 1))) // 2)
    y = top
    for row, h in enumerate(heights):
        for col in range(ncol):
            i = row * ncol + col
            f = firsts[i]
            x = x0 + col * (mw + hgap)
            ui.cal_hits.append((y, y + h, x, x + mw, ("month", f)))
            this = (f.year, f.month) == (today.year, today.month)
            cv.put(x + dw - 2, y, _month_name(f), GREEN if this else INK, None, True)
            items = [it for d in cal if d.month == f.month for it in cal[d]]
            n_done = sum(1 for it in items if it["mark"] == "done")
            tally = ", ".join(s for s in ("%d done" % n_done if n_done else "",
                                          "%d due" % (len(items) - n_done) if len(items) > n_done else "") if s)
            if tally and len(_month_name(f)) + 2 + len(tally) <= mw - dw + 2:
                cv.put(x + mw - len(tally), y, tally, DIMMER)
            r0 = y + 1
            if header:
                for j in range(7):
                    cv.put(x + j * dw + dw - 2, r0, _WEEKDAYS[(j + 6) % 7][:2].capitalize(), DIMMER)
                r0 += 1
            d = f
            while d.month == f.month:
                slot = lead[i] + d.day - 1
                cx, cy = x + (slot % 7) * dw + dw - 2, r0 + slot // 7
                entries = cal[d]
                if d == today:
                    cv.put(cx, cy, "%2d" % d.day, BG, GREEN, True)
                elif entries:
                    tally = {}
                    for it in entries:
                        _, pc = _item_color(model, colors, it)
                        tally[pc] = tally.get(pc, 0) + 1
                    pc = max(sorted(tally), key=lambda c: tally[c])
                    cv.put(cx, cy, "%2d" % d.day, pc, mix(pc, BG, 0.8), True)
                else:
                    cv.put(cx, cy, "%2d" % d.day, DIM)
                d += _dt.timedelta(days=1)
        y += h + gap


def compose(scene, renderer, ui, cols, rows, now, records_ok=True, notice=None):
    """One frame, or the one-line too-small message."""
    cv = Canvas(cols, rows)
    need_r = min_rows(60)
    if cols < MIN_COLS or rows < need_r:
        msg = "Make this pane bigger: Mission Control needs %d x %d, this pane is %d x %d." % (
            MIN_COLS, need_r, cols, rows)
        cv.put(0, 0, clip(msg, cols), AMBER)
        return cv, True
    _chrome(cv, ui, now)
    if scene.model is None:
        cv.put(2, 4, notice or "Reading the ship's records...", SOFT)
        return cv, False
    if ui.view == "office":
        _office_screen(cv, ui, scene, renderer, now, records_ok, notice)
    elif ui.view == "tasks":
        _tasks_screen(cv, scene.model)
    elif ui.view == "projects":
        _projects_screen(cv, ui, scene)
    elif ui.view == "approvals":
        _approvals_screen(cv, ui, scene)
    elif ui.view == "calendar":
        _calendar_screen(cv, ui, scene.model, scene.crew)
    else:
        _later_screen(cv, TABS[VIEWS.index(ui.view)])
    return cv, False


# ---------------------------------------------------------------------------
# Terminal output
# ---------------------------------------------------------------------------

def _xterm256(rgb):
    r, g, b = (rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255
    levels = (0, 95, 135, 175, 215, 255)

    def near(v):
        return min(range(6), key=lambda i: abs(levels[i] - v))
    ri, gi, bi = near(r), near(g), near(b)
    cube = (levels[ri], levels[gi], levels[bi])
    gray_i = max(0, min(23, int(round(((r + g + b) / 3.0 - 8) / 10.0))))
    gray = 8 + 10 * gray_i

    def dist(c):
        return (c[0] - r) ** 2 + (c[1] - g) ** 2 + (c[2] - b) ** 2
    if dist((gray, gray, gray)) < dist(cube):
        return 232 + gray_i
    return 16 + 36 * ri + 6 * gi + bi


def color_mode():
    forced = os.environ.get("FM_MC_COLORS", "").lower()
    if forced in ("truecolor", "256"):
        return forced
    if os.environ.get("COLORTERM", "").lower() in ("truecolor", "24bit"):
        return "truecolor"
    if "direct" in os.environ.get("TERM", ""):
        return "truecolor"
    return "256"


class Encoder:
    def __init__(self, mode):
        self.mode = mode
        self.cache = {}

    def sgr(self, fg, bg, bold):
        key = (fg, bg, bold)
        s = self.cache.get(key)
        if s is None:
            if self.mode == "truecolor":
                s = "\x1b[%d;38;2;%d;%d;%d;48;2;%d;%d;%dm" % (
                    1 if bold else 22, (fg >> 16) & 255, (fg >> 8) & 255, fg & 255,
                    (bg >> 16) & 255, (bg >> 8) & 255, bg & 255)
            else:
                s = "\x1b[%d;38;5;%d;48;5;%dm" % (1 if bold else 22, _xterm256(fg), _xterm256(bg))
            if len(self.cache) > 20000:
                self.cache.clear()
            self.cache[key] = s
        return s

    def diff(self, prev, cur, cols):
        out = []
        pos = None
        style = None
        for k, cell in enumerate(cur):
            if prev is not None and prev[k] == cell:
                continue
            r, c = divmod(k, cols)
            if pos != k:
                out.append("\x1b[%d;%dH" % (r + 1, c + 1))
            ch, fg, bg, bold = cell
            st = (fg, bg, bold)
            # A blank only needs the right background, whatever the pen.
            if st != style and not (ch == " " and style is not None and style[1] == bg):
                out.append(self.sgr(fg, bg, bold))
                style = st
            out.append(ch)
            pos = k + 1 if c + 1 < cols else None
        return "".join(out)


def to_ansi(cv, mode="truecolor"):
    enc = Encoder(mode)
    cells = cv.cells()
    lines = []
    for r in range(cv.R):
        row = cells[r * cv.C:(r + 1) * cv.C]
        style = None
        parts = []
        for ch, fg, bg, bold in row:
            st = (fg, bg, bold)
            if st != style and not (ch == " " and style is not None and style[1] == bg):
                parts.append(enc.sgr(fg, bg, bold))
                style = st
            parts.append(ch)
        lines.append("".join(parts) + "\x1b[0m")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Live data: records and agents, gathered off the drawing thread
# ---------------------------------------------------------------------------

def keep_last_good(model, last):
    """A second mate home that could not be read this time keeps its last good read."""
    lost = {hid for hid in model["errors"] if last and hid in last["snapshots"]}
    if not lost:
        return model
    snaps = dict(model["snapshots"])
    for hid in lost:
        snaps[hid] = last["snapshots"][hid]
    kept = {}
    for key in ("items", "history"):
        kept[key] = [it for it in model.get(key) or [] if it["owner"] not in lost] + \
            [it for it in last.get(key) or [] if it["owner"] in lost]
    return dict(model, snapshots=snaps, **kept)


class Feed:
    def __init__(self, home, config_dir, herdr):
        self.home, self.config_dir, self.herdr = home, config_dir, herdr
        self.lock = threading.Lock()
        self.model = None
        self.model_at = 0.0
        self.model_error = None
        self.agents = []
        self.agents_read = False
        self.agents_error = None
        self.services = []
        self._services_at = None
        self.gen = 0
        self.poke = threading.Event()
        self.stop = threading.Event()
        self._fingerprint = None

    def start(self):
        for fn in (self._records_loop, self._agents_loop):
            threading.Thread(target=fn, daemon=True).start()

    def snapshot(self):
        with self.lock:
            return self.gen, self.model, self.agents, self.model_error, self.agents_error, self.model_at

    def _records_loop(self):
        while not self.stop.is_set():
            started = time.monotonic()
            self.poke.clear()
            try:
                model = keep_last_good(bridge.collect(self.home, self.config_dir, bridge._now()), self.model)
                with self.lock:
                    self.model, self.model_error, self.model_at = model, None, time.monotonic()
                    self.gen += 1
            except Exception as exc:  # noqa: BLE001 - shown as a notice, never a traceback
                with self.lock:
                    self.model_error = str(exc) if isinstance(exc, RuntimeError) else "the records could not be read"
                    self.gen += 1
            self.poke.wait(RECORDS_MAX_AGE)
            gap = RECORDS_MIN_GAP - (time.monotonic() - started)
            if gap > 0:
                self.stop.wait(gap)

    def _homes(self):
        with self.lock:
            model = self.model
        homes = [self.home]
        if model:
            homes += [m["home"] for m in model.get("mates") or [] if not m["remote"]]
        return homes

    def _watch(self):
        """Cheap change detection: which records exist and when they changed."""
        parts = []
        for h in self._homes():
            state = os.path.join(h, "state")
            try:
                parts.append(tuple(sorted(n for n in os.listdir(state) if n.endswith(".meta"))))
            except OSError:
                parts.append(None)
            for rel in ("data/backlog.md", "data/secondmates.md", "data/projects.md", "data/done-archive.md"):
                try:
                    parts.append(os.stat(os.path.join(h, rel)).st_mtime)
                except OSError:
                    parts.append(None)
        fp = tuple(parts)
        if self._fingerprint is not None and fp != self._fingerprint:
            self.poke.set()
        self._fingerprint = fp

    def _agents_loop(self):
        while not self.stop.is_set():
            try:
                proc = subprocess.run(self.herdr + ["agent", "list"], capture_output=True, text=True,
                                      timeout=5, check=False)
                agents = parse_agents(proc.stdout) if proc.returncode == 0 else None
            except (OSError, subprocess.SubprocessError):
                agents = None
            with self.lock:
                if agents is not None:
                    changed = [(a["pane"], a["status"], tuple(sorted(a["cwds"]))) for a in agents] != \
                        [(a["pane"], a["status"], tuple(sorted(a["cwds"]))) for a in self.agents]
                    self.agents, self.agents_read, err = agents, True, None
                else:
                    err = "Herdr's agent list could not be read just now; showing what it last said." \
                        if self.agents_read else "Herdr's agent list could not be read, so everyone looks asleep."
                    changed = self.agents_error != err
                if changed or self.agents_error != err:
                    self.gen += 1
                self.agents_error = err
            self._watch()
            if self._services_at is None or time.monotonic() - self._services_at >= SERVICES_EVERY:
                self.services = read_services(self.home, self_running=True)
                self._services_at = time.monotonic()
            self.stop.wait(max(1.0, AGENT_POLL_SECONDS))

    def focus(self, pane):
        def go():
            try:
                subprocess.run(self.herdr + ["agent", "focus", pane], capture_output=True,
                               timeout=5, check=False)
            except (OSError, subprocess.SubprocessError):
                pass
        threading.Thread(target=go, daemon=True).start()


# ---------------------------------------------------------------------------
# The live loop
# ---------------------------------------------------------------------------

_KEYS = re.compile(rb"\x1b\[<(\d+);(\d+);(\d+)([Mm])|\x1b\[[0-9;]*[A-Za-z~]|\x1bO[A-Za-z]|\x1b|[\s\S]")


class Terminal:
    def __init__(self):
        self.fd_in = sys.stdin.fileno()
        self.fd_out = sys.stdout.fileno()
        self.saved = None

    def enter(self):
        import termios
        import tty
        self.saved = termios.tcgetattr(self.fd_in)
        tty.setcbreak(self.fd_in)
        self.write("\x1b[?1049h\x1b[?25l\x1b[?7l\x1b[?1000h\x1b[?1006h\x1b[0m\x1b[2J")

    def leave(self):
        import termios
        self.write("\x1b[0m\x1b[?1000l\x1b[?1006l\x1b[?7h\x1b[?25h\x1b[?1049l")
        if self.saved is not None:
            termios.tcsetattr(self.fd_in, termios.TCSADRAIN, self.saved)
            self.saved = None

    def size(self):
        try:
            s = os.get_terminal_size(self.fd_out)
            return s.columns, s.lines
        except OSError:
            return 80, 24

    def write(self, data):
        buf = data.encode("utf-8")
        while buf:
            try:
                n = os.write(self.fd_out, buf)
            except InterruptedError:
                continue
            except BlockingIOError:
                select.select([], [self.fd_out], [], 1.0)
                continue
            buf = buf[n:]


def run(home, config_dir, herdr):
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        print("fm_mission_control.py: run needs a terminal", file=sys.stderr)
        return 2
    session = os.environ.get("HERDR_SESSION") or "default"
    own_pane = os.environ.get("HERDR_PANE_ID")
    term = Terminal()
    feed = Feed(home, config_dir, herdr)
    scene, renderer, ui = Scene(), Renderer(), UI()
    sleeper = SleepTimer()
    enc = Encoder(color_mode())
    wake_r, wake_w = os.pipe()
    os.set_blocking(wake_w, False)
    flags = {"resize": True, "quit": False}

    def on_winch(_s, _f):
        flags["resize"] = True
        try:
            os.write(wake_w, b"w")
        except OSError:
            pass

    def on_quit(_s, _f):
        flags["quit"] = True
        try:
            os.write(wake_w, b"q")
        except OSError:
            pass

    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, on_quit)
    signal.signal(signal.SIGWINCH, on_winch)
    prev = None
    last_gen = None
    size = term.size()
    next_frame = time.monotonic()
    feed.start()
    term.enter()
    try:
        while not flags["quit"]:
            wait = max(0.0, next_frame - time.monotonic())
            try:
                ready, _, _ = select.select([term.fd_in, wake_r], [], [], wait)
            except InterruptedError:
                ready = []
            dirty = False
            if wake_r in ready:
                os.read(wake_r, 64)
            if term.fd_in in ready:
                data = os.read(term.fd_in, 1024)
                if not data:
                    break
                dirty = _handle_input(data, ui, scene, feed) or dirty
                if ui.view == "quit":
                    break
            if flags["resize"]:
                flags["resize"] = False
                size = term.size()
                prev = None
                last_gen = None
                term.write("\x1b[0m\x1b[2J")
                dirty = True
            gen, model, agents, model_err, agents_err, _at = feed.snapshot()
            now_m = time.monotonic()
            due = sleeper.due()
            if model is not None and (gen != last_gen or (due is not None and now_m >= due)):
                crew = build_crew(model, sleeper.apply(agents, now_m), home, session, own_pane,
                                  first_mate_name(config_dir))
                scene.observe(model, crew, size[1])
                last_gen = gen
                dirty = True
            if now_m >= next_frame:
                if ui.paused or scene.model is None:
                    next_frame = now_m + 1.0
                else:
                    n = scene.speed()
                    scene.step(n)
                    next_frame = now_m + 0.1 * n
                dirty = True
            if not dirty:
                continue
            ui.services = feed.services
            notice = None
            if model_err:
                notice = "The records could not be read just now (%s); showing the last good read." % model_err \
                    if scene.model is not None else "The records could not be read just now; trying again."
            elif agents_err:
                notice = agents_err
            cv, _small = compose(scene, renderer, ui, size[0], size[1], bridge._now(),
                                 records_ok=model_err is None, notice=notice)
            cells = cv.cells()
            if prev is None or len(prev) != len(cells):
                out = enc.diff(None, cells, cv.C)
            else:
                out = enc.diff(prev, cells, cv.C)
            if out:
                term.write(out)
            prev = cells
    finally:
        feed.stop.set()
        feed.poke.set()
        term.leave()
    return 0


def _pick_decision(ui, scene, down):
    """Move the Approvals highlight; it only changes what the panel shows."""
    if scene.model is None:
        return False
    keys = [it["key"] for g in approvals(scene.model, scene.crew) for it in g["items"]]
    if not keys:
        return False
    # With no pick yet the screen highlights the first row, so moving starts there.
    i = keys.index(ui.decision) if ui.decision in keys else 0
    ui.decision = keys[max(0, min(len(keys) - 1, i + (1 if down else -1)))]
    return True


def _handle_input(data, ui, scene, feed):
    changed = False
    for m in _KEYS.finditer(data):
        tok = m.group(0)
        if m.group(1) is not None:
            btn, x, y, kind = int(m.group(1)), int(m.group(2)), int(m.group(3)), m.group(4)
            if kind != b"M" or btn & (3 | 32 | 64 | 128):
                continue
            if y == 1:
                for c0, c1, i in ui.tab_hits:
                    if c0 <= x - 1 < c1:
                        ui.view = VIEWS[i]
                        changed = True
            elif ui.view == "calendar":
                act = next((a for r0, r1, c0, c1, a in ui.cal_hits if r0 <= y - 1 < r1 and c0 <= x - 1 < c1), None)
                if act is not None:
                    changed = cal_action(ui, scene.model, act) or changed
            continue
        if tok in (b"q", b"Q"):
            ui.view = "quit"
            return True
        if len(tok) == 1 and b"1" <= tok <= b"9":
            ui.view = VIEWS[int(tok) - 1]
            changed = True
        elif ui.view == "calendar" and tok in (b"\x1b[C", b"\x1bOC", b"\x1b[D", b"\x1bOD", b"t", b"T", b"v", b"V"):
            act = ("today",) if tok in (b"t", b"T") else ("cycle",) if tok in (b"v", b"V") \
                else ("move", 1 if tok in (b"\x1b[C", b"\x1bOC") else -1)
            changed = cal_action(ui, scene.model, act) or changed
        elif tok in (b"p", b"P"):
            ui.paused = not ui.paused
            changed = True
        elif tok in (b"\x1b[A", b"\x1bOA", b"\x1b[B", b"\x1bOB") and ui.view == "projects":
            changed = _pick_project(ui, scene, tok in (b"\x1b[B", b"\x1bOB")) or changed
        elif ui.view == "approvals" and tok in (b"\x1b[A", b"\x1bOA", b"\x1b[B", b"\x1bOB"):
            changed = _pick_decision(ui, scene, tok in (b"\x1b[B", b"\x1bOB")) or changed
        elif tok in (b"\x1b[A", b"\x1bOA", b"\x1b[B", b"\x1bOB"):
            keys = [m_["key"] for m_ in scene.crew]
            if keys:
                down = tok in (b"\x1b[B", b"\x1bOB")
                if ui.selected in keys:
                    i = (keys.index(ui.selected) + (1 if down else -1)) % len(keys)
                else:
                    i = 0 if down else len(keys) - 1
                ui.selected = keys[i]
                ui.view = "office"
                changed = True
        elif tok in (b"\r", b"\n") and ui.view != "approvals":
            m_ = next((c for c in scene.crew if c["key"] == ui.selected), None)
            if m_ is None:
                continue
            if m_.get("pane"):
                feed.focus(m_["pane"])
                ui.toast = "moving your view to %s's pane" % m_["name"]
            else:
                ui.toast = "%s has no open pane to show" % m_["name"]
            ui.toast_until = time.monotonic() + 3
            changed = True
    return changed


# ---------------------------------------------------------------------------
# One frame, for tests and a quick look
# ---------------------------------------------------------------------------

def frame(home, config_dir, agents_text, view, cols, rows, fmt, session="default", keys=""):
    model = bridge.collect(home, config_dir, bridge._now())
    agents = parse_agents(agents_text) if agents_text else []
    crew = build_crew(model, agents, home, session, None, first_mate_name(config_dir))
    scene = Scene()
    scene.observe(model, crew, rows)
    ui = UI()
    ui.view = view
    ui.services = read_services(home) if view == "calendar" else []
    # Keys and taps as the terminal sends them, each on the frame before it;
    # Enter and q do nothing here.
    for m in _KEYS.finditer(keys.encode("utf-8", "surrogateescape")):
        if m.group(0) not in (b"\r", b"\n", b"q", b"Q"):
            compose(scene, Renderer(), ui, cols, rows, bridge._now())
            _handle_input(m.group(0), ui, scene, None)
    cv, small = compose(scene, Renderer(), ui, cols, rows, bridge._now())
    if fmt == "ansi":
        return to_ansi(cv)
    if fmt == "text":
        return cv.text()
    L = scene.layout
    desks = []
    for key, d in L.desks.items():
        m = next((c for c in crew if c["key"] == key), None)
        desks.append({"key": key, "name": m["name"] if m else key, "x": d["x"], "y": d["y"], "w": d["w"]})
    actors = []
    for a in scene.actors.values():
        m = a.member
        actors.append({"key": a.key, "name": m["name"], "kind": m["kind"], "state": a.state,
                       "x": a.x, "feet": a.feet, "lead": m.get("lead"), "slot": a.slot})
    cols_ = board(model)
    return json.dumps({
        "size": [cols, rows], "too_small": small, "room_height": L.height,
        "desks": desks, "actors": actors,
        "upstairs": {"count": len(L.upstairs), "working": sum(1 for m in L.upstairs if m["status"] == "work"),
                     "names": [m["name"] for m in L.upstairs]},
        "inbox": scene.inbox_real,
        "columns": {k: len(v) for k, v in cols_.items()},
        "projects": [{"name": p["name"], "status": p["status"], "lead": p["lead"]["name"],
                      "counts": p["counts"], "decisions": [it["title"] for it in p["decisions"]]}
                     for p in project_cards(model, crew)],
        "approvals": [{"name": g["name"], "count": len(g["items"])} for g in approvals(model, crew)],
        "team": [{"name": m["name"], "role": m["role"], "doing": m["doing"], "path": m["path"],
                  "status": m["status"]} for m in crew],
    }, indent=1)


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(prog="fm_mission_control.py")
    ap.add_argument("command", choices=["run", "frame"])
    ap.add_argument("--home", required=True)
    ap.add_argument("--config-dir", required=True)
    ap.add_argument("--herdr", default="herdr", help="the herdr command, split on spaces")
    ap.add_argument("--agents", help="frame: a saved `herdr agent list` JSON file")
    ap.add_argument("--view", default="office", choices=VIEWS)
    ap.add_argument("--size", default="132x44")
    ap.add_argument("--format", default="text", choices=["text", "json", "ansi"])
    ap.add_argument("--keys", default="", help="frame: keys and taps to apply first, as the terminal sends them")
    args = ap.parse_args(argv)
    home = os.path.abspath(args.home)
    if args.command == "run":
        return run(home, args.config_dir, args.herdr.split())
    m = re.match(r"^(\d+)x(\d+)$", args.size)
    if not m:
        print("fm_mission_control.py: --size is <cols>x<rows>", file=sys.stderr)
        return 2
    text = None
    if args.agents:
        with open(args.agents, encoding="utf-8") as fh:
            text = fh.read()
    try:
        out = frame(home, args.config_dir, text, args.view, int(m.group(1)), int(m.group(2)), args.format,
                    os.environ.get("HERDR_SESSION") or "default", args.keys)
    except RuntimeError as exc:
        print("fm_mission_control.py: %s" % exc, file=sys.stderr)
        return 1
    sys.stdout.write(out + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
