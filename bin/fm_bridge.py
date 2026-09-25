#!/usr/bin/env python3
"""fm_bridge.py - the Bridge: a read-only page over this home's records.

bin/fm-bridge.sh is the operator entry point and owns the command surface,
address selection, and the LaunchAgent; this module owns what the page reads,
how it is counted, how it is drawn, and the tiny HTTP server that draws it.
Mission Control (bin/fm_mission_control.py) imports collect() and the helpers
below rather than reading the same records a second way.

WHERE THE NUMBERS COME FROM. Backlog items, live workers and their current
state come from bin/fm-fleet-snapshot.sh --json, the canonical read-only fleet
reader ("human views must render this output instead of parsing state files
again"). It is run once for this home and once inside every registered local
second mate's home, so items handed to a mate still count under their project.
Each run keeps the snapshot's own walk of registered mate homes at its smallest
bound (FM_SNAPSHOT_SECONDMATES=1; 0 would lift the bound, not disable it),
since the Bridge snapshots every mate home itself and never reads that walk.
tasks-axi was checked first: its list output is TOON and truncates long titles,
and its --json flag applies to mutations only, so it is not a reader here.
Two small inputs the snapshot does not cover are parsed directly, each against
its documented owner:
  data/projects.md       the line grammar in bin/fm-project-mode.sh's header;
  data/secondmates.md    the regexes in bin/fm-secondmate-registry-lib.sh;
  data/done-archive.md   only its `- [x]` lines and their completion token
                         `(done|merged|reported YYYY-MM-DD)`, the tasks-axi
                         form, so "done this month" survives Done pruning.
Memory cards read headings and line counts only, never body text.

COUNTING. An open item is waiting on the captain when it is queued, is a
captain item (kind: captain or hold-kind: captain), has no unresolved blocker,
and carries no hold-until date still in the future. Other queued items are
queued. In-flight items are in flight. Done this month means a Done record
whose completion date falls in the current calendar month.
An item belongs to the registered project named by its repo field (an
owner/ prefix is ignored); a second mate's item with no repo belongs to the
mate's single project when it has exactly one. Everything else, and the
project named like this home's own directory (the firstmate repository
itself), belongs to "The ship itself".

SERVING. GET / renders the page, GET /healthz answers ok, every other path is
404 and no request input selects a file. A render younger than
render_reuse_seconds (config, default 15) is reused, so a reload does not pay
for a second snapshot; concurrent requests share one render.
"""

import datetime as _dt
import html
import json
import os
import re
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

CODE_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SNAPSHOT = os.path.join(CODE_ROOT, "bin", "fm-fleet-snapshot.sh")
DEFAULT_PORT = 7373
BOARD_CARDS = 6

# ---------------------------------------------------------------------------
# Registry parsers
# ---------------------------------------------------------------------------

_PROJECT_RE = re.compile(r"^- (\S+)(?: \[([^\]]*)\])? - (.*)$")
_PROJECT_META_RE = re.compile(r"^(.*?)\s*\((added [^()]*)\)\s*$")
_DATE_RE = re.compile(r"(\d{4}-\d{2}-\d{2})")
_REPO_RE = re.compile(r"\brepo(?:sitory)?(?: at)? ([A-Za-z0-9-]+/[A-Za-z0-9._-]+)")


def parse_projects(text):
    """Parse data/projects.md lines per bin/fm-project-mode.sh's header."""
    out = []
    for line in text.splitlines():
        m = _PROJECT_RE.match(line.rstrip())
        if not m:
            continue
        name, posture, rest = m.group(1), m.group(2) or "", m.group(3)
        meta = ""
        mm = _PROJECT_META_RE.match(rest)
        if mm:
            rest, meta = mm.group(1), mm.group(2)
        added = _DATE_RE.search(meta)
        parked = None
        pm = re.search(r"parked\b[^;]*?(\d{4}-\d{2}-\d{2})", meta)
        if pm:
            parked = pm.group(1)
        repo = _REPO_RE.search(rest)
        out.append({
            "name": name,
            "posture": posture.strip(),
            "description": rest.strip(),
            "meta": meta,
            "added": added.group(1) if added else None,
            "parked": parked,
            "github": repo.group(1).rstrip(".,;") if repo else None,
        })
    return out


# Mirrors secondmate_registry_parse_line in bin/fm-secondmate-registry-lib.sh.
_MATE_LOCAL_RE = re.compile(
    r"^- ([A-Za-z0-9._-]+) - (.+) \(home:\s*([^;)]*);\s*scope:\s*(.*);"
    r"\s*projects:\s*([^;)]*);\s*added\s+(\d{4}-\d{2}-\d{2})\)\s*$")
_MATE_REMOTE_RE = re.compile(
    r"^- ([A-Za-z0-9._-]+) - (.+) \(host:\s*([^;)]*);\s*root:\s*([^;)]*);"
    r"\s*home:\s*([^;)]*);\s*scope:\s*(.*);\s*projects:\s*([^;)]*);"
    r"\s*added\s+(\d{4}-\d{2}-\d{2})\)\s*$")


def _split_projects(value):
    return [p for p in re.split(r"[,\s]+", value.strip()) if p]


def parse_secondmates(text):
    """Parse data/secondmates.md records, local form first like the owner."""
    out = []
    for line in text.splitlines():
        line = line.rstrip()
        m = _MATE_LOCAL_RE.match(line)
        if m:
            out.append({"id": m.group(1), "summary": m.group(2).strip(),
                        "home": m.group(3).strip(), "scope": m.group(4).strip(),
                        "projects": _split_projects(m.group(5)),
                        "added": m.group(6), "remote": False})
            continue
        m = _MATE_REMOTE_RE.match(line)
        if m:
            out.append({"id": m.group(1), "summary": m.group(2).strip(),
                        "home": m.group(5).strip(), "scope": m.group(6).strip(),
                        "projects": _split_projects(m.group(7)),
                        "added": m.group(8), "remote": True})
    return [m for m in out if m["home"] and m["scope"]]


_ARCHIVE_DONE_RE = re.compile(r"^- \[x\] ([A-Za-z0-9._-]+) - (.*)$")
_COMPLETION_RE = re.compile(r"\((done|merged|reported) (\d{4}-\d{2}-\d{2})\)")
_REPO_FIELD_RE = re.compile(r"\(repo: ([^)]*)\)")


def parse_done_archive(text):
    """Read only the Done lines of a tasks-axi archive file."""
    out = []
    for line in text.splitlines():
        m = _ARCHIVE_DONE_RE.match(line)
        if not m:
            continue
        rest = m.group(2)
        comp = _COMPLETION_RE.findall(rest)
        repo = _REPO_FIELD_RE.search(rest)
        title = re.sub(r"\s*\([a-z-]+: [^)]*\)", "", rest)
        title = _COMPLETION_RE.sub("", title)
        out.append({"id": m.group(1), "state": "done", "structured": True,
                    "title": title.strip(), "repo": repo.group(1) if repo else None,
                    "completion": {"verb": comp[-1][0] if comp else None,
                                   "date": comp[-1][1] if comp else None}})
    return out


def headings(text):
    """Return (level, heading) pairs, skipping fenced code."""
    out, fenced = [], False
    for line in text.splitlines():
        if line.startswith("```"):
            fenced = not fenced
            continue
        if fenced:
            continue
        m = re.match(r"^(#{1,3}) (.+?)\s*#*\s*$", line)
        if m:
            out.append((len(m.group(1)), m.group(2).strip()))
    return out


# ---------------------------------------------------------------------------
# Collection
# ---------------------------------------------------------------------------

def _read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return None


def _snapshot(home, now):
    """Run the canonical snapshot for one home and return its JSON."""
    env = {k: v for k, v in os.environ.items()
           if not (k.startswith("FM_") and k.endswith("_OVERRIDE"))}
    env["FM_HOME"] = home
    env["FM_SNAPSHOT_SECONDMATES"] = "1"
    env["FM_SNAPSHOT_NOW"] = now.astimezone(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    proc = subprocess.run([SNAPSHOT, "--json"], env=env, capture_output=True,
                          text=True, timeout=120, check=False)
    if proc.returncode != 0:
        raise RuntimeError("the fleet snapshot could not be read")
    return json.loads(proc.stdout)


def _norm_repo(repo):
    if not repo:
        return None
    return repo.strip().split("/")[-1].lower() or None


def _summary(desc):
    """A registry description without the parts the card already links."""
    parts = [x.strip() for x in desc.split(";")]
    keep = [x for x in parts if x and not re.search(r"\brepo\b|\b[A-Za-z0-9_-]{25,}\b", x)]
    text = "; ".join(keep) or desc
    return text[:1].upper() + text[1:]


def _clip(text, limit=150):
    if len(text) <= limit:
        return text
    return text[:limit].rsplit(" ", 1)[0].rstrip(",;:") + "..."


def _clean_title(title):
    title = re.sub(r"https?://\S+", "", title or "")
    title = re.sub(r"\bblocked-by: \S+", "", title)
    title = re.sub(r"\S*data/[\w.-]+/report\.md", "", title)
    return re.sub(r"\s{2,}", " ", title).strip(" -")


def project_of(rec, mate, by_key, ship_name):
    """The registered project a backlog record belongs to, or None for the ship.

    by_key maps each lowercased registered project name to its entry; mate is
    the second mate whose home holds the record, or None for this home."""
    key = _norm_repo(rec.get("repo"))
    if key is None and mate and len(mate["projects"]) == 1:
        key = mate["projects"][0].lower()
    project = by_key.get(key) if key else None
    return project["name"] if project and project["name"] != ship_name else None


def _is_captain(rec):
    return rec.get("kind") == "captain" or rec.get("hold_kind") == "captain"


def classify(rec, today):
    """Return waiting|queued|in_flight|done|None for one backlog record."""
    state = rec.get("state")
    if not rec.get("structured"):
        return None
    if state == "in_flight":
        return "in_flight"
    if state == "done":
        return "done"
    if state != "queued":
        return None
    if _is_captain(rec):
        until = rec.get("hold_until")
        blocked = rec.get("unresolved_blocker_ids") or []
        if not blocked and not (until and until > today):
            return "waiting"
    return "queued"


def _birth(path):
    try:
        st = os.stat(path)
    except OSError:
        return None
    return getattr(st, "st_birthtime", None) or st.st_mtime


_PATH_RE = re.compile(r"(?<![\w:/.])(?:~|\.{0,2})/[^\s,;)]+|\b(?:state|data|config|projects)/[^\s,;)]+")
_URL_RE = re.compile(r"https?://\S+")


def plain_note(note):
    """Drop raw paths from a status note, keeping any web links intact."""
    urls = []

    def keep(m):
        urls.append(m.group(0))
        return "\x00%d\x00" % (len(urls) - 1)

    text = _URL_RE.sub(keep, note or "")
    text = _PATH_RE.sub("a local file", text)
    return re.sub(r"\x00(\d+)\x00", lambda m: urls[int(m.group(1))], text).strip()


EVENT_WORDS = {
    "working": "working", "paused": "waiting", "blocked": "needs the first mate",
    "done": "finished", "failed": "failed", "needs-decision": "needs a decision",
    "resolved": "back at work",
}
STATE_WORDS = {
    "working": "working", "parked": "waiting at a review", "done": "finished",
    "blocked": "needs the first mate", "paused": "waiting", "failed": "failed",
    "unknown": "state not readable",
}
LOGIN_RE = re.compile(r"\b(log ?in|sign ?in|credential|auth\w*|token|password)\b", re.I)


DEFAULTS = {"port": DEFAULT_PORT, "bind": "tailscale", "first_mate": "First mate",
            "render_reuse_seconds": 15}


def example_config(home):
    """The first-run settings file: defaults plus each project's GitHub page."""
    data = os.path.join(home, "data")
    links = [{"project": p["name"], "label": "repository", "url": "https://github.com/%s" % p["github"]}
             for p in parse_projects(_read(os.path.join(data, "projects.md")) or "") if p["github"]]
    cfg = {"_comment": [
        "Settings for the Bridge page (bin/fm-bridge.sh). Edit freely; the page rereads this on every render.",
        "port and bind take effect on the next start. bind is tailscale or one explicit address, never 0.0.0.0.",
        "first_mate is the name the page uses for the first mate.",
        "names maps a registered project to {title, short, kind, description} for its card, board tag and kicker,",
        "and a second mate id to {title} for its row on Team and Office.",
        "links is a list of {project, label, url}; project is a registered project name, or null for the ship.",
        "Example link: {\"project\": \"my-project\", \"label\": \"class Drive folder\", "
        "\"url\": \"https://drive.google.com/drive/folders/...\"}",
    ]}
    cfg.update(DEFAULTS)
    cfg["names"] = {}
    cfg["links"] = links
    return cfg


def init_config(home, config_dir):
    path = os.path.join(config_dir, "bridge.json")
    if os.path.exists(path):
        return False
    os.makedirs(config_dir, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(example_config(home), fh, indent=2)
        fh.write("\n")
    os.replace(tmp, path)
    return True


def load_config(config_dir):
    cfg = {}
    raw = _read(os.path.join(config_dir, "bridge.json"))
    if raw:
        try:
            cfg = json.loads(raw)
        except ValueError:
            cfg = {"_error": "config/bridge.json is not valid JSON"}
    if not isinstance(cfg, dict):
        cfg = {"_error": "config/bridge.json must hold one JSON object"}
    return cfg


def collect(home, config_dir, now):
    today = now.strftime("%Y-%m-%d")
    month = now.strftime("%Y-%m")
    data = os.path.join(home, "data")
    cfg = load_config(config_dir)
    names = cfg.get("names") if isinstance(cfg.get("names"), dict) else {}

    projects = parse_projects(_read(os.path.join(data, "projects.md")) or "")
    mates = parse_secondmates(_read(os.path.join(data, "secondmates.md")) or "")
    ship_name = os.path.basename(os.path.normpath(home))
    by_key = {p["name"].lower(): p for p in projects}

    homes = [("main", home)] + [(m["id"], m["home"]) for m in mates if not m["remote"]]
    snaps, errors = {}, []
    with ThreadPoolExecutor(max_workers=max(1, len(homes))) as pool:
        futures = {hid: pool.submit(_snapshot, h, now) for hid, h in homes}
        for hid, fut in futures.items():
            try:
                snaps[hid] = fut.result()
            except Exception:  # noqa: BLE001 - a failed home is disclosed, not fatal
                errors.append(hid)
    if "main" not in snaps:
        raise RuntimeError("this home's records could not be read")

    items = []

    def add(rec, owner, mate):
        bucket = classify(rec, today)
        if bucket is None:
            return
        if bucket == "done":
            date = (rec.get("completion") or {}).get("date")
            if _parse_day(date) is None or not date.startswith(month):
                return
        else:
            date = None
        pname = project_of(rec, mate, by_key, ship_name)
        items.append({
            "id": rec.get("id"), "title": _clean_title(rec.get("title")),
            "bucket": bucket, "project": pname, "owner": owner, "date": date,
            "hold": rec.get("hold_kind") == "captain",
            "blocked": bool(rec.get("unresolved_blocker_ids")),
            "since": rec.get("since"),
        })

    seen = set()
    for hid, hhome in homes:
        snap = snaps.get(hid)
        mate = next((m for m in mates if m["id"] == hid), None)
        if not snap:
            continue
        for rec in snap.get("backlog", {}).get("records", []):
            seen.add((hid, rec.get("id")))
            add(rec, hid, mate)
        hdata = data if hid == "main" else os.path.join(hhome, "data")
        for rec in parse_done_archive(_read(os.path.join(hdata, "done-archive.md")) or ""):
            if (hid, rec["id"]) not in seen:
                add(rec, hid, mate)

    # Live workers: this home's runtime records, minus the persistent mates.
    main = snaps["main"]
    state_dir = os.path.join(home, "state")
    workers = []
    for task in main.get("tasks", []):
        if task.get("kind") == "secondmate":
            continue
        tid = task.get("id")
        cur = task.get("current_state") or {}
        ev = ((task.get("paths") or {}).get("status_log") or {}).get("last_event") or {}
        started = _birth(os.path.join(state_dir, "%s.meta" % tid))
        ev_at = None
        try:
            ev_at = os.stat(os.path.join(state_dir, "%s.status" % tid)).st_mtime
        except OSError:
            pass
        proj = os.path.basename(task.get("project") or "") or None
        workers.append({
            "id": tid, "project": proj, "started": started, "event_at": ev_at,
            "state": cur.get("state") or "unknown",
            "event": ev.get("state") or "", "note": plain_note(ev.get("note")),
            "pr": (task.get("pr") or {}).get("url"),
        })

    team = []
    for m in mates:
        snap = snaps.get(m["id"])
        entry = {"id": m["id"], "summary": m["summary"], "projects": m["projects"],
                 "remote": m["remote"], "readable": snap is not None,
                 "busy": 0, "open": 0, "waiting": 0}
        if snap:
            entry["busy"] = len(snap.get("tasks", []))
            for it in items:
                if it["owner"] == m["id"] and it["bucket"] != "done":
                    entry["open"] += 1
                    entry["waiting"] += it["bucket"] == "waiting"
        team.append(entry)

    memory = []
    for label, kicker, rel in (("Captain preferences", "About you", "captain.md"),
                               ("Fleet learnings", "About the ship", "learnings.md")):
        text = _read(os.path.join(data, rel))
        if text is not None:
            memory.append(_memory_card(kicker, label, text))
    projects_dir = os.path.join(home, "projects")
    for p in projects:
        text = _read(os.path.join(projects_dir, p["name"], "AGENTS.md"))
        if text is not None:
            card = _memory_card("Project memory", p["name"], text)
            memory.append(card)
    decisions = _decision_files([data] + [os.path.join(m["home"], "data")
                                          for m in mates if not m["remote"]])

    reports = []
    for r in main.get("scout_reports", []) or []:
        rid = r.get("id") if isinstance(r, dict) else None
        if rid:
            rec = next((x for x in main["backlog"]["records"] if x.get("id") == rid), None)
            reports.append(_clean_title(rec.get("title")) if rec else rid)

    links = cfg.get("links") if isinstance(cfg.get("links"), list) else []
    links = [link for link in links if isinstance(link, dict)
             and str(link.get("url", "")).startswith(("https://", "http://"))]
    # A link filed under the home's own repository belongs to the ship's card.
    links = [dict(link, project=None) if link.get("project") == ship_name else link for link in links]

    return {
        "now": now, "today": today, "projects": projects, "ship": ship_name,
        "names": names, "items": items, "workers": workers, "team": team,
        "memory": memory, "decisions": decisions, "reports": reports,
        "links": links, "errors": errors, "config_error": cfg.get("_error"),
        "first_mate": str(cfg.get("first_mate") or "First mate"),
        # Raw per-home inputs for other read-only views (bin/fm_mission_control.py).
        "mates": mates, "snapshots": snaps,
    }


def _memory_card(kicker, title, text):
    hs = headings(text)
    sections = [h for lvl, h in hs if lvl == 2]
    return {"kicker": kicker, "title": title, "sections": sections,
            "lines": len(text.splitlines()), "tokens": len(text) // 4}


def _decision_files(dirs):
    found = []
    for d in dirs:
        try:
            subdirs = sorted(os.listdir(d))
        except OSError:
            continue
        for sub in subdirs:
            full = os.path.join(d, sub)
            if not os.path.isdir(full):
                continue
            for fn in os.listdir(full):
                if not (fn.startswith("decision-") or fn == "captain-decision.md"):
                    continue
                if not fn.endswith(".md"):
                    continue
                path = os.path.join(full, fn)
                text = _read(path) or ""
                hs = headings(text)
                title = hs[0][1] if hs else fn[:-3].replace("-", " ")
                title = re.sub(r"^Decision:\s*", "", title)
                title = title[:1].upper() + title[1:]
                found.append({"title": title, "mtime": os.stat(path).st_mtime, "path": path})
    found.sort(key=lambda x: -x["mtime"])
    return found


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

def e(value):
    """Escape for HTML; long dashes in the records render as a plain dash."""
    text = str(value).replace("\u2014", "-").replace("\u2013", "-")
    return html.escape(text, quote=True)


def _parse_day(date):
    try:
        return _dt.date.fromisoformat(date) if isinstance(date, str) else None
    except ValueError:
        return None


def _day(date, today):
    d = _parse_day(date)
    if d is None:
        return ""
    if date == today:
        return "today"
    return "%d %s" % (d.day, d.strftime("%b"))


def _plural(n, one, many=None):
    return "%d %s" % (n, one if n == 1 else (many or one + "s"))


def _duration(seconds):
    minutes = int(max(0, seconds) // 60)
    if minutes < 60:
        return "%d min" % minutes
    hours, minutes = divmod(minutes, 60)
    if hours < 48:
        return "%d h %d min" % (hours, minutes)
    return "%d days" % (hours // 24)


def _title(model, pname):
    entry = model["names"].get(pname) if pname else None
    if isinstance(entry, dict) and entry.get("title"):
        return entry["title"]
    return pname or "The ship itself"


def _short(model, pname):
    entry = model["names"].get(pname) if pname else None
    if isinstance(entry, dict) and entry.get("short"):
        return entry["short"]
    return pname or "Ship"


def _kind(model, pname):
    entry = model["names"].get(pname) if pname else None
    if isinstance(entry, dict) and entry.get("kind"):
        return entry["kind"]
    return "Project"


def _stat(n, label, key):
    return '<div class="stat"><b data-count="%s">%d</b><span>%s</span></div>' % (e(key), n, e(label))


def _stats(counts, scope):
    return '<div class="stats four" data-scope="%s">%s%s%s%s</div>' % (
        e(scope),
        _stat(counts["waiting"], "waiting on you", "waiting"),
        _stat(counts["queued"], "queued", "queued"),
        _stat(counts["in_flight"], "in flight", "in_flight"),
        _stat(counts["done"], "done this month", "done"))


def _counts(items):
    c = {"waiting": 0, "queued": 0, "in_flight": 0, "done": 0}
    for it in items:
        c[it["bucket"]] += 1
    return c


def _links_html(model, pname, extra=()):
    out = []
    for link in model["links"]:
        if (link.get("project") or None) == pname:
            out.append('<a href="%s" rel="noopener">%s</a>' % (e(link["url"]), e(link.get("label") or "link")))
    out.extend(extra)
    return '<div class="links">%s</div>' % "".join(out) if out else ""


def _project_card(model, project, pitems):
    pname = project["name"] if project else None
    counts = _counts(pitems)
    waiting = [it for it in pitems if it["bucket"] == "waiting"]
    if project and project.get("parked"):
        pill = '<span class="pill parked">parked</span>'
    elif counts["in_flight"]:
        pill = '<span class="pill live">under way</span>'
    elif counts["waiting"]:
        pill = '<span class="pill captain">%s</span>' % e(_plural(counts["waiting"], "decision"))
    else:
        pill = '<span class="pill idle">quiet</span>'
    if project:
        bits = [_kind(model, pname)]
        if project.get("parked"):
            bits.append("parked since %s" % _day(project["parked"], model["today"]))
        elif project.get("added"):
            bits.append("added %s" % _day(project["added"], model["today"]))
        kicker = " &middot; ".join(e(b) for b in bits)
        entry = model["names"].get(pname)
        desc = entry.get("description") if isinstance(entry, dict) and entry.get("description") else _summary(project["description"])
    else:
        kicker = "Fleet &middot; this machine"
        desc = "Housekeeping that belongs to no project, and work on the first mate itself."
    calls = "".join('<li><span class="who">%s</span>%s</li>' % (
        "decide" if it["hold"] else "do", e(_clip(it["title"]))) for it in waiting[:3])
    extra = []
    if project and project.get("github"):
        extra.append('<a href="https://github.com/%s" rel="noopener">repository</a>' % e(project["github"]))
    if len(waiting) > 3:
        extra.append('<a href="#board" data-goto="board">%s</a>' % e(_plural(len(waiting) - 3, "more decision")))
    has_repo_link = any((lnk.get("project") or None) == pname and "github.com" in lnk["url"]
                        for lnk in model["links"])
    if has_repo_link:
        extra = [x for x in extra if ">repository<" not in x]
    return ('<div class="card" data-project="%s"><div class="kicker">%s</div>'
            '<h3>%s %s</h3><p class="desc">%s</p>%s%s%s</div>') % (
        e(pname or "ship"), kicker, e(_title(model, pname)), pill, e(desc),
        _stats(counts, pname or "ship"),
        '<ul class="calls">%s</ul>' % calls if calls else "",
        _links_html(model, pname, extra))


def _round_robin(items):
    groups, order = {}, []
    for it in items:
        key = it["project"]
        if key not in groups:
            groups[key] = []
            order.append(key)
        groups[key].append(it)
    out = []
    while any(groups.values()):
        for key in order:
            if groups[key]:
                out.append(groups[key].pop(0))
    return out


def _column(model, title, key, items, more_text):
    cards = []
    for it in items[:BOARD_CARDS]:
        tag = e(_short(model, it["project"]))
        day = _day(it["date"], model["today"]) if it["bucket"] == "done" else ""
        if day:
            tag += " &middot; " + e(day)
        cls = "tcard blocked" if it["blocked"] else "tcard"
        cards.append('<div class="%s"><div class="p">%s</div>%s</div>' % (cls, tag, e(_clip(it["title"], 110))))
    rest = len(items) - BOARD_CARDS
    if rest > 0:
        cards.append('<div class="more">%s</div>' % e(more_text % rest))
    if not items:
        cards.append('<div class="more">nothing here</div>')
    return '<div class="col" data-column="%s"><h4>%s <b data-count="%s">%d</b></h4>%s</div>' % (
        e(key), e(title), e(key), len(items), "".join(cards))


def _worker_words(w):
    word = STATE_WORDS.get(w["state"], w["state"])
    if w["note"]:
        lead = EVENT_WORDS.get(w["event"], w["event"])
        return "%s; last said it was %s: %s" % (word, lead, w["note"]) if lead else word
    return word


def render(model):
    now, today = model["now"], model["today"]
    items = model["items"]
    projects = [p for p in model["projects"] if p["name"] != model["ship"]]
    total = _counts(items)
    fm = model["first_mate"]

    cards = []
    for p in projects:
        cards.append(_project_card(model, p, [it for it in items if it["project"] == p["name"]]))
    cards.append(_project_card(model, None, [it for it in items if it["project"] is None]))

    waiting = _round_robin([it for it in items if it["bucket"] == "waiting"])
    queued = _round_robin([it for it in items if it["bucket"] == "queued"])
    flying = [it for it in items if it["bucket"] == "in_flight"]
    done = sorted([it for it in items if it["bucket"] == "done"],
                  key=lambda it: it["date"] or "", reverse=True)

    notices = []
    if model["errors"]:
        notices.append("Some second mate records could not be read just now: %s." % ", ".join(model["errors"]))
    if model["config_error"]:
        notices.append("The Bridge settings file could not be read, so no links are shown.")
    if total["waiting"]:
        oldest = min((it["since"] for it in items
                      if it["bucket"] == "waiting" and _parse_day(it["since"]) is not None), default=None)
        n = total["waiting"]
        banner = "%s waiting on you across all projects" % ("1 thing is" if n == 1 else "%d things are" % n)
        if oldest:
            banner += ", the oldest since %s" % _day(oldest, today)
        banner += "."
    else:
        banner = "Nothing is waiting on you right now."
    live = len(model["workers"])
    banner += " %s under way." % _plural(live, "worker is", "workers are") if live else " No workers are under way."

    # Team and office.
    rows = ['<tr><td><span class="dot you"></span><b>You</b></td><td>Captain. Vision, decisions, merges.</td>'
            '<td data-count="team-waiting">%s</td></tr>' % e(_plural(total["waiting"], "decision") + " waiting")]
    rows.append('<tr><td><span class="dot live"></span><b>%s</b></td><td>First mate. Every project, routing, '
                'supervision.</td><td>%s</td></tr>' % (
                    e(fm), e("Supervising " + _plural(live, "worker") if live else "Standing by")))
    for m in model["team"]:
        dot = "live" if m["busy"] else "idle"
        if not m["readable"]:
            now_text = "Its records are on another machine" if m["remote"] else "Its records could not be read"
        else:
            now_text = "%s, %s in its list" % ("Busy" if m["busy"] else "Idle", _plural(m["open"], "item"))
            if m["waiting"]:
                now_text += ", %d waiting on you" % m["waiting"]
        rows.append('<tr data-mate="%s"><td><span class="dot %s"></span><b>%s</b></td><td>Second mate. %s</td>'
                    '<td>%s</td></tr>' % (e(m["id"]), dot, e(_title(model, m["id"])), e(m["summary"]), e(now_text)))

    office = []
    stale = login = prs = 0
    for w in model["workers"]:
        ran = _duration(now.timestamp() - w["started"]) if w["started"] else "time unknown"
        quiet_for = now.timestamp() - w["event_at"] if w["event_at"] else None
        if w["state"] != "working" and quiet_for is not None and quiet_for > 3600:
            stale += 1
        if (w["state"] == "blocked" or w["event"] == "blocked") and LOGIN_RE.search(w["note"] or ""):
            login += 1
        if w["pr"]:
            prs += 1
        dot = "live" if w["state"] == "working" else "idle"
        office.append('<li data-worker="%s"><span><span class="dot %s"></span><b>%s</b> &middot; %s<br>'
                      '<small style="white-space:normal">%s</small></span><small>running %s</small></li>' % (
                          e(w["id"]), dot, e(w["id"]), e(w["project"] or "no project"),
                          e(_worker_words(w)), e(ran)))
    if not office:
        office.append('<li><span>No workers are running.</span></li>')
    today_done = [it for it in done if it["date"] == today]
    earlier = ""
    if today_done:
        earlier = '<p class="desc" style="margin-top:12px">Finished today: %s.</p>' % e(
            "; ".join("%s (%s)" % (it["title"], _short(model, it["project"])) for it in today_done[:4]))

    # Memory.
    mem_cards = []
    for card in model["memory"]:
        secs = card["sections"]
        li = "".join("<li>%s</li>" % e(s) for s in secs[:6])
        if len(secs) > 6:
            li += '<li><span class="who">and</span>%s</li>' % e(_plural(len(secs) - 6, "more section"))
        mem_cards.append('<div class="card"><div class="kicker">%s</div><h3>%s</h3><p class="desc">%s, %s, '
                         'about %s tokens.</p><ul class="calls">%s</ul></div>' % (
                             e(card["kicker"]), e(card["title"]), e(_plural(len(secs), "section")),
                             e(_plural(card["lines"], "line")), e("{:,}".format(card["tokens"])), li))
    dec = model["decisions"]
    dec_li = "".join("<li>%s (%s)</li>" % (e(_clip(d["title"], 110)), e(_day(
        _dt.datetime.fromtimestamp(d["mtime"]).strftime("%Y-%m-%d"), today))) for d in dec[:5])
    mem_cards.append('<div class="card"><div class="kicker">Decisions on record</div><h3>Decision files</h3>'
                     '<p class="desc">Every decision you made, in your words, one file each. '
                     '<b data-count="decision-files">%d</b> on record, newest first.</p>'
                     '<ul class="calls">%s</ul></div>' % (len(dec), dec_li))

    # Documents.
    groups, order = {}, []
    for link in model["links"]:
        key = link.get("project") or None
        if key not in groups:
            groups[key] = []
            order.append(key)
        groups[key].append(link)
    doc_cards = []
    for key in order:
        kinds = sorted({"Drive" if "drive.google.com" in lnk["url"] else
                        "Repository" if "github.com" in lnk["url"] else "Web" for lnk in groups[key]})
        li = "".join('<li><a href="%s" rel="noopener">%s</a></li>' % (e(lnk["url"]), e(lnk.get("label") or lnk["url"]))
                     for lnk in groups[key])
        doc_cards.append('<div class="card" data-docs="%s"><div class="kicker">%s</div><h3>%s</h3>'
                         '<ul class="calls">%s</ul></div>' % (
                             e(key or "ship"), " &middot; ".join(e(k) for k in kinds),
                             e(_title(model, key)), li))
    if model["reports"]:
        li = "".join("<li>%s</li>" % e(r) for r in model["reports"][:8])
        more = len(model["reports"]) - 8
        if more > 0:
            li += "<li>%s</li>" % e(_plural(more, "more report"))
        doc_cards.append('<div class="card"><div class="kicker">Reports &middot; on this Mac</div>'
                         '<h3>Investigations</h3><ul class="calls">%s</ul></div>' % li)
    if not doc_cards:
        doc_cards.append('<div class="card"><h3>No links yet</h3><p class="desc">Add links to the Bridge '
                         'settings file on this Mac and they appear here.</p></div>')

    stamp = now.strftime("%A %d %B %Y, %H:%M").replace(" 0", " ", 1)
    notice_html = "".join('<div class="banner">%s</div>' % e(n) for n in notices)
    return PAGE % {
        "stamp": e(stamp),
        "banner": e(banner),
        "notices": notice_html,
        "cards": "".join(cards),
        "waiting": _column(model, "Waiting on you", "waiting", waiting, "%d more, grouped by project on the Bridge tab"),
        "queued": _column(model, "Queued", "queued", queued, "%d more"),
        "flying": _column(model, "In flight", "in_flight", flying, "%d more"),
        "done": _column(model, "Done this month", "done", done, "%d more"),
        "rows": "".join(rows),
        "office": "".join(office),
        "earlier": earlier,
        "counters": ('<div class="stats">%s%s%s</div>' % (
            _stat(stale, "waiting too long", "stale"), _stat(login, "blocked on a login", "login"),
            _stat(prs, "pull requests open" if prs != 1 else "pull request open", "prs"))),
        "memory": "".join(mem_cards),
        "docs": "".join(doc_cards),
        "fm": e(fm),
    }


def render_error(now, message):
    return PAGE_ERROR % {"stamp": e(now.strftime("%H:%M")), "message": e(message)}


# The sketch the captain approved (data/bridge/sketch.html), with its tokens,
# media queries and tab script kept; only the content is generated.
STYLE = """
:root{
  --bg:#faf9f5; --surface:#ffffff; --surface-2:#f3f1ea; --line:#e6e2d6; --line-2:#d9d3c3;
  --ink:#1f1d19; --ink-2:#5b574d; --ink-3:#8a8477;
  --accent:#d97757; --accent-ink:#9c4a2f; --accent-soft:#f6e3da;
  --good:#3f7d5a; --good-soft:#e2efe6; --warn:#a56b12; --warn-soft:#f7ead2; --idle:#7b7a9a; --idle-soft:#e9e8f3;
  --radius:12px; --pill:999px;
  --display:"Archivo",system-ui,-apple-system,"Segoe UI",sans-serif;
  --prose:"Crimson Pro",Georgia,"Times New Roman",serif;
}
@media (prefers-color-scheme: dark){
  :root:not([data-theme="light"]){
    --bg:#1b1a17; --surface:#24221e; --surface-2:#2c2a25; --line:#37342d; --line-2:#46423a;
    --ink:#f1ede4; --ink-2:#c3bdb0; --ink-3:#8f897b;
    --accent:#e6906f; --accent-ink:#f0b39a; --accent-soft:#3b2a22;
    --good:#7fbf9a; --good-soft:#233329; --warn:#e0b060; --warn-soft:#3a2f1a; --idle:#a9a7c9; --idle-soft:#2a2934;
  }
}
:root[data-theme="dark"]{
  --bg:#1b1a17; --surface:#24221e; --surface-2:#2c2a25; --line:#37342d; --line-2:#46423a;
  --ink:#f1ede4; --ink-2:#c3bdb0; --ink-3:#8f897b;
  --accent:#e6906f; --accent-ink:#f0b39a; --accent-soft:#3b2a22;
  --good:#7fbf9a; --good-soft:#233329; --warn:#e0b060; --warn-soft:#3a2f1a; --idle:#a9a7c9; --idle-soft:#2a2934;
}
*{box-sizing:border-box}
html,body{margin:0}
body{background:var(--bg);color:var(--ink);font-family:var(--display);font-size:15px;line-height:1.45;-webkit-font-smoothing:antialiased}
a{color:var(--accent-ink);text-decoration:none;border-bottom:1px solid var(--line-2)}
a:hover{border-bottom-color:var(--accent)}
.wrap{max-width:1180px;margin:0 auto;padding:0 16px 48px}
header.top{display:flex;align-items:center;justify-content:space-between;gap:16px;padding:18px 0 10px;border-bottom:1px solid var(--line)}
.brand{display:flex;align-items:baseline;gap:12px}
.brand h1{font-size:22px;font-weight:700;letter-spacing:-.01em;margin:0}
.brand .sub{font-family:var(--prose);font-size:16px;color:var(--ink-2);font-style:italic}
.meta{font-size:12.5px;color:var(--ink-3);text-align:right}
.meta b{color:var(--ink-2);font-weight:600}
nav.tabs{display:flex;gap:6px;flex-wrap:wrap;padding:12px 0 6px;position:sticky;top:0;background:var(--bg);z-index:5}
nav.tabs button{font:inherit;font-weight:600;font-size:13.5px;padding:8px 14px;border-radius:var(--pill);border:1px solid var(--line-2);background:var(--surface);color:var(--ink-2);cursor:pointer}
nav.tabs button[aria-selected="true"]{background:var(--ink);color:var(--bg);border-color:var(--ink)}
nav.tabs button:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
section.tab{display:none;padding-top:14px}
section.tab.active{display:block}
.note{font-family:var(--prose);font-size:16.5px;color:var(--ink-2);margin:6px 0 16px;max-width:70ch}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:14px}
.card{background:var(--surface);border:1px solid var(--line);border-radius:var(--radius);padding:16px 16px 14px;min-width:0}
.card h3{margin:0 0 2px;font-size:16px;font-weight:700;letter-spacing:-.005em}
.card .kicker{font-size:11.5px;text-transform:uppercase;letter-spacing:.08em;color:var(--ink-3);margin-bottom:8px}
.card .desc{font-family:var(--prose);font-size:15.5px;color:var(--ink-2);margin:0 0 10px;overflow-wrap:anywhere}
.stats{display:flex;gap:14px;flex-wrap:wrap;margin:8px 0 10px}
.stats.four{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:10px}
.stat{min-width:0}
.stat b{display:block;font-size:22px;font-weight:700;letter-spacing:-.02em;font-variant-numeric:tabular-nums}
.stat span{font-size:11.5px;color:var(--ink-3);text-transform:uppercase;letter-spacing:.06em}
.pill{display:inline-block;font-size:11.5px;font-weight:600;padding:3px 9px;border-radius:var(--pill);border:1px solid transparent}
.pill.captain{background:var(--accent-soft);color:var(--accent-ink)}
.pill.live{background:var(--good-soft);color:var(--good)}
.pill.idle{background:var(--idle-soft);color:var(--idle)}
.pill.parked{background:var(--surface-2);color:var(--ink-2);border-color:var(--line-2)}
.pill.warn{background:var(--warn-soft);color:var(--warn)}
ul.calls{list-style:none;margin:6px 0 0;padding:0}
ul.calls li{font-family:var(--prose);font-size:15.5px;padding:7px 0;border-top:1px dashed var(--line);overflow-wrap:anywhere}
ul.calls li:first-child{border-top:none}
ul.calls li .who{font-family:var(--display);font-size:11px;text-transform:uppercase;letter-spacing:.07em;color:var(--ink-3);margin-right:8px}
.links{display:flex;gap:8px 14px;flex-wrap:wrap;font-size:13px;margin-top:8px}
.board{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px}
@media (max-width:820px){.board{grid-template-columns:repeat(2,minmax(0,1fr))}}
@media (max-width:480px){.board{grid-template-columns:1fr}}
.col{background:var(--surface-2);border:1px solid var(--line);border-radius:var(--radius);padding:10px;min-width:0}
.col h4{margin:2px 4px 10px;font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:var(--ink-2);display:flex;justify-content:space-between}
.col h4 b{font-variant-numeric:tabular-nums;color:var(--ink)}
.tcard{background:var(--surface);border:1px solid var(--line);border-radius:10px;padding:9px 10px;margin-bottom:8px;font-size:13.5px;min-width:0;overflow-wrap:anywhere}
.tcard .p{font-size:11px;text-transform:uppercase;letter-spacing:.07em;color:var(--ink-3);margin-bottom:3px}
.tcard.blocked{border-left:3px solid var(--warn)}
.more{font-size:12.5px;color:var(--ink-3);padding:4px 6px}
table{width:100%;border-collapse:collapse;font-size:14px}
th,td{text-align:left;padding:9px 8px;border-bottom:1px solid var(--line);vertical-align:top}
th{font-size:11.5px;text-transform:uppercase;letter-spacing:.07em;color:var(--ink-3);font-weight:600}
td.num{font-variant-numeric:tabular-nums;text-align:right}
.scroll{overflow-x:auto}
.dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:7px;vertical-align:middle}
.dot.live{background:var(--good);box-shadow:0 0 0 3px var(--good-soft)}
.dot.idle{background:var(--idle);box-shadow:0 0 0 3px var(--idle-soft)}
.dot.you{background:var(--accent);box-shadow:0 0 0 3px var(--accent-soft)}
.two{display:grid;grid-template-columns:1.1fr .9fr;gap:14px}
@media (max-width:820px){.two{grid-template-columns:1fr}}
.list{margin:0;padding:0;list-style:none}
.list li{padding:9px 0;border-top:1px solid var(--line);display:flex;justify-content:space-between;gap:12px;align-items:baseline}
.list li:first-child{border-top:none}
.list li small{color:var(--ink-3);font-size:12px;white-space:nowrap}
.banner{background:var(--accent-soft);border:1px solid var(--line);border-radius:var(--radius);padding:10px 14px;font-family:var(--prose);font-size:15.5px;color:var(--accent-ink);margin:0 0 14px}
footer{margin-top:28px;padding-top:12px;border-top:1px solid var(--line);font-size:12.5px;color:var(--ink-3);display:flex;justify-content:space-between;flex-wrap:wrap;gap:8px}
@media (prefers-reduced-motion:no-preference){.dot.live{animation:pulse 2.4s ease-in-out infinite}@keyframes pulse{0%,100%{box-shadow:0 0 0 3px var(--good-soft)}50%{box-shadow:0 0 0 6px var(--good-soft)}}}
"""

SCRIPT = """
(function(){
  var tabs=document.querySelectorAll('nav.tabs [role=tab]');
  var panels=document.querySelectorAll('section.tab');
  function show(id){
    tabs.forEach(function(t){t.setAttribute('aria-selected', t.dataset.tab===id ? 'true':'false');});
    panels.forEach(function(p){p.classList.toggle('active', p.id==='tab-'+id);});
    try{localStorage.setItem('bridge.tab',id);}catch(e){}
  }
  tabs.forEach(function(t){t.addEventListener('click',function(){show(t.dataset.tab);});});
  document.querySelectorAll('[data-goto]').forEach(function(a){a.addEventListener('click',function(ev){ev.preventDefault();show(a.dataset.goto);window.scrollTo(0,0);});});
  var saved=null; try{saved=localStorage.getItem('bridge.tab');}catch(e){}
  var hash=(location.hash||'').slice(1);
  if(hash && document.getElementById('tab-'+hash)) show(hash);
  else if(saved && document.getElementById('tab-'+saved)) show(saved);
})();
"""

HEAD = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>The Bridge</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Archivo:wght@400;500;600;700&family=Crimson+Pro:ital,wght@0,400;0,600;1,400&display=swap">
<style>""" + STYLE.replace("%", "%%") + """</style>
</head>
"""

PAGE = HEAD + """<body>
<div class="wrap">
  <header class="top">
    <div class="brand">
      <h1>The Bridge</h1>
      <span class="sub">where every project stands, on one page</span>
    </div>
    <div class="meta"><b>%(stamp)s</b><br>rendered from the live records, refreshes on open</div>
  </header>

  <nav class="tabs" role="tablist" aria-label="Bridge views">
    <button role="tab" aria-selected="true" data-tab="bridge">Bridge</button>
    <button role="tab" aria-selected="false" data-tab="board">Board</button>
    <button role="tab" aria-selected="false" data-tab="team">Team &amp; Office</button>
    <button role="tab" aria-selected="false" data-tab="memory">Memory</button>
    <button role="tab" aria-selected="false" data-tab="docs">Documents</button>
  </nav>

  <section class="tab active" id="tab-bridge" role="tabpanel">
    <p class="note">One card per project. The number that matters is <b>waiting on you</b>: decisions only you can make. Everything else is either moving or done.</p>
    %(notices)s<div class="banner">%(banner)s</div>
    <div class="grid">%(cards)s</div>
  </section>

  <section class="tab" id="tab-board" role="tabpanel">
    <p class="note">Every open item, by state. <b>Waiting on you</b> is its own column on purpose: it is the only column nobody else can empty.</p>
    <div class="board">%(waiting)s%(queued)s%(flying)s%(done)s</div>
  </section>

  <section class="tab" id="tab-team" role="tabpanel">
    <p class="note">Who is on the ship and what each one is doing right now. Second mates are permanent and sleep between jobs; workers are hired for one job and let go.</p>
    <div class="two">
      <div class="card">
        <div class="kicker">Team</div>
        <div class="scroll"><table>
          <tr><th>Who</th><th>Charge</th><th>Now</th></tr>
          %(rows)s
        </table></div>
      </div>
      <div class="card">
        <div class="kicker">Office &middot; live workers</div>
        <ul class="list">%(office)s</ul>
        %(earlier)s
        %(counters)s
      </div>
    </div>
  </section>

  <section class="tab" id="tab-memory" role="tabpanel">
    <p class="note">What the ship remembers about you and about itself, and where. Read only; changes still happen by talking to %(fm)s.</p>
    <div class="grid">%(memory)s</div>
  </section>

  <section class="tab" id="tab-docs" role="tabpanel">
    <p class="note">Everything produced for you, by where it lives. Drive links open in Drive; repository links open on GitHub.</p>
    <div class="grid">%(docs)s</div>
  </section>

  <footer>
    <span>Read only. The board shows; you decide; %(fm)s dispatches.</span>
    <span>Served on this Mac, reachable from the iPad over Tailscale.</span>
  </footer>
</div>
<script>""" + SCRIPT.replace("%", "%%") + """</script>
</body>
</html>
"""

PAGE_ERROR = HEAD + """<body>
<div class="wrap">
  <header class="top"><div class="brand"><h1>The Bridge</h1></div><div class="meta"><b>%(stamp)s</b></div></header>
  <div class="banner" style="margin-top:16px">%(message)s Try again in a minute.</div>
</div>
</body>
</html>
"""


# ---------------------------------------------------------------------------
# Entry points
# ---------------------------------------------------------------------------

def _now():
    fixed = os.environ.get("FM_BRIDGE_NOW")
    if fixed:
        return _dt.datetime.fromisoformat(fixed).astimezone()
    return _dt.datetime.now().astimezone()


def build_page(home, config_dir):
    now = _now()
    try:
        return render(collect(home, config_dir, now)), True
    except Exception as exc:  # noqa: BLE001 - the page says what failed, never a traceback
        msg = str(exc) if isinstance(exc, RuntimeError) else "The records could not be read."
        return render_error(now, msg[:1].upper() + msg[1:] + "." if not msg.endswith(".") else msg), False


class _Cache:
    def __init__(self, home, config_dir, reuse):
        self.home, self.config_dir, self.reuse = home, config_dir, reuse
        self.lock = threading.Lock()
        self.page, self.at = None, 0.0

    def get(self):
        with self.lock:
            if self.page is None or time.monotonic() - self.at > self.reuse:
                page, ok = build_page(self.home, self.config_dir)
                if not ok:
                    return page
                self.page, self.at = page, time.monotonic()
            return self.page


def serve(home, config_dir, host, port, give_up_after=0):
    cfg = load_config(config_dir)
    try:
        reuse = max(0, int(cfg.get("render_reuse_seconds", 15)))
    except (TypeError, ValueError):
        reuse = 15
    cache = _Cache(home, config_dir, reuse)

    class Handler(BaseHTTPRequestHandler):
        server_version = "Bridge"
        sys_version = ""

        def _send(self, code, body, ctype):
            data = body.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Content-Security-Policy",
                             "default-src 'none'; style-src 'unsafe-inline' https://fonts.googleapis.com; "
                             "font-src https://fonts.gstatic.com; script-src 'unsafe-inline'; "
                             "base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)

        def do_GET(self):
            path = urlsplit(self.path).path
            if path == "/":
                self._send(200, cache.get(), "text/html; charset=utf-8")
            elif path == "/healthz":
                self._send(200, "ok\n", "text/plain; charset=utf-8")
            else:
                self._send(404, "not found\n", "text/plain; charset=utf-8")

        do_HEAD = do_GET

        def log_message(self, fmt, *args):
            sys.stderr.write("%s bridge: %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), fmt % args))

    httpd = ThreadingHTTPServer((host, port), Handler)
    httpd.daemon_threads = True
    print("%s bridge: listening on http://%s:%d/" % (time.strftime("%Y-%m-%dT%H:%M:%S"), host, port), flush=True)
    if give_up_after > 0:
        def later():
            time.sleep(give_up_after)
            print("%s bridge: bound to the fallback address; exiting so Tailscale is detected again"
                  % time.strftime("%Y-%m-%dT%H:%M:%S"), flush=True)
            os._exit(75)
        threading.Thread(target=later, daemon=True).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(prog="fm_bridge.py")
    ap.add_argument("command", choices=["render", "serve", "init-config", "setting"])
    ap.add_argument("key", nargs="?")
    ap.add_argument("--home", required=True)
    ap.add_argument("--config-dir", required=True)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--give-up-after", type=int, default=0)
    args = ap.parse_args(argv)
    if args.command == "init-config":
        if init_config(args.home, args.config_dir):
            print("fm-bridge: wrote an example config/bridge.json; edit it to add links", file=sys.stderr)
        return 0
    if args.command == "setting":
        if args.key not in DEFAULTS:
            print("fm_bridge.py: unknown setting %r" % args.key, file=sys.stderr)
            return 2
        cfg = load_config(args.config_dir)
        print(cfg.get(args.key, DEFAULTS[args.key]))
        return 0
    if args.command == "render":
        page, ok = build_page(args.home, args.config_dir)
        sys.stdout.write(page)
        return 0 if ok else 1
    serve(args.home, args.config_dir, args.host, args.port, args.give_up_after)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
