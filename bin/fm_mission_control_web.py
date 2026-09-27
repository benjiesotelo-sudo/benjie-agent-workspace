#!/usr/bin/env python3
"""fm_mission_control_web.py - Mission Control's public page: one static snapshot folder.

bin/fm-mission-control-web.sh is the operator entry point and owns the command
surface, publishing (a GitHub Pages checkout or Cloudflare) and the schedule; this module owns what
the public snapshot may contain and writes the folder.

ONE-SHOT. Each build reads the home once, writes the folder, and exits; nothing
here keeps running. The movement on the page is drawn by the visitor's browser
from the snapshot (bin/mission-control-web/app.js), so the Mac does no work
between builds.

WHAT IT READS. The same records Mission Control reads, through its own readers:
bin/fm_bridge.py collect() for the records, bin/fm_mission_control.py
read_settings(), build_crew() and project_cards() for the crew, the project
display names (config/mission-control.json `names`) and each project's colour
and status, and `herdr agent list` once for who is working (--agents replaces
it with a saved list; with neither, a worker's state comes from its records
and the first mate and second mates read asleep).

THE FOLDER. index.html, style.css and app.js are copied byte for byte from
bin/mission-control-web/, so they carry no home data and every improvement to
them reaches the page on the next build. snapshot.json is the only file built
from the home. A file is rewritten only when its bytes change. When nothing in
the snapshot changed except the time, the previous generated_at is kept, so an
unchanged crew leaves the whole folder unchanged, until heartbeat_minutes pass
and the time moves once so the page still shows it is alive.

WHAT THE SNAPSHOT MAY CONTAIN. It is built by allow-list: public_snapshot()
constructs every field from the list below and copies nothing else from the
records, so a field added to a record later never reaches the page.
  timing    the schema number, generated_at, today's date, every_minutes and
            heartbeat_minutes, so the page can say how long ago it was
            updated and mark the time late only after the heartbeat has passed.
  agents   the first mate (config first_mate_name), each second mate named by
            its first project's public name ("Second mate N" with none), and
            each live worker as "helper for <project>", or "helper for a
            one-off job" when its project is not registered; state working or
            asleep; one activity line built only from a fixed phrase and
            project names ("working on <project>"); the shirt and hair colours;
            the person in charge of a helper; a role built only from those
            names ("first mate", "second mate for <projects>", "helper for
            <project>"), never from a registered scope or charter.
  projects  public name, colour, status (active, parked or quiet), person in
            charge, and four counts: waiting on the captain, in flight, done
            this week (Sunday to Saturday) and done this month.
  calendar  per day, per project, how many items were done and how many are
            due, from the first day of the month two months back to the end of
            next month.
  office    how many items wait on the captain, in total.
  events    the live activity column: the last EVENTS_KEPT plain state changes,
            each a time, an agent's public name and a fixed phrase ("joins the
            crew", "calls in a helper for <project>", "helper for <project>
            goes home", "<project> finishes a job"), found by comparing this
            build's snapshot with the previous one in the folder, so an
            unchanged crew adds none. Falling asleep and waking up are never
            events; the office shows who is asleep.
A project's public name is its entry in the names map, else the Bridge's
display name when that differs from the repository name, else "Project N" in
registry order; this home's own repository is "setup" unless the names map
names it. Every agent, project and calendar key is a position ("a1", "p2"),
never a record id. Nothing is read from task titles, notes, paths, links,
emails, scopes, charters, data/captain.md, data/learnings.md, reports
or decision pages into the snapshot.

SETTINGS. config/mission-control.json `public_page` (optional object):
  host               where publish sends the page: "github" (the default), a
                     GitHub Pages checkout, or "cloudflare", a Cloudflare Pages
                     project with the snapshot in Workers KV.
  repository         host github: "owner/name" of the Pages repository that
                     publish pushes to; publish pushes only from a checkout
                     whose origin is it.
  project            host cloudflare: the Cloudflare Pages project name
                     (default "mission-control"); its Workers KV namespace is
                     "<project>-snapshot".
  every_minutes      the build cadence the schedule uses and the page states
                     (default 5, at least 1).
  heartbeat_minutes  how long an unchanged snapshot keeps its time (default 60,
                     at least every_minutes).
"""

import datetime as _dt
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fm_bridge as bridge  # noqa: E402  - the one owner of the record readers
import fm_mission_control as mc  # noqa: E402  - the one owner of the crew and the project names

SCHEMA = "fm-mission-control-public.v1"
ASSETS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mission-control-web")
STATIC = ("index.html", "style.css", "app.js")
SNAPSHOT = "snapshot.json"
FILES = STATIC + (SNAPSHOT, ".nojekyll")
DEFAULTS = {"host": "github", "repository": "", "project": "mission-control",
            "every_minutes": 5, "heartbeat_minutes": 60}
MAX_MATES_SHOWN = 12
EVENTS_KEPT = 20


def read_public_settings(config_dir):
    """config/mission-control.json `public_page`, with defaults and bounds applied."""
    try:
        with open(os.path.join(config_dir, "mission-control.json"), encoding="utf-8") as fh:
            cfg = json.load(fh)
    except (OSError, ValueError):
        cfg = {}
    raw = cfg.get("public_page") if isinstance(cfg, dict) else None
    raw = raw if isinstance(raw, dict) else {}
    out = dict(DEFAULTS)
    host = raw.get("host")
    if isinstance(host, str) and host.strip():
        # An unknown host is passed through so publish refuses it by name.
        host = host.strip().lower()
        out["host"] = host if re.match(r"^[a-z0-9_-]{1,32}$", host) else "invalid"
    project = raw.get("project")
    if isinstance(project, str) and re.match(r"^[a-z0-9][a-z0-9-]{0,57}$", project.strip()):
        out["project"] = project.strip()
    repo = raw.get("repository")
    if isinstance(repo, str) and re.match(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", repo.strip()):
        out["repository"] = repo.strip()
    for key in ("every_minutes", "heartbeat_minutes"):
        val = raw.get(key)
        if isinstance(val, (int, float)) and not isinstance(val, bool) and val >= 1:
            out[key] = int(val)
    out["heartbeat_minutes"] = max(out["heartbeat_minutes"], out["every_minutes"])
    return out


# ---------------------------------------------------------------------------
# The allow-list
# ---------------------------------------------------------------------------

def _public_names(model):
    """{registered project name or None: public name} and the order projects are shown in."""
    ship = model["ship"]
    display = model.get("display") or {}
    names, order, n = {}, [], 0
    for p in model["projects"]:
        pname = p["name"]
        if pname == ship:
            continue
        n += 1
        explicit = display.get(pname)
        if explicit is None:
            explicit = next((v for k, v in display.items() if k.lower() == pname.lower()), None)
        name = explicit or mc.project_name(model, pname, card=True)
        if not explicit and name.strip().lower() == pname.lower():
            name = "Project %d" % n
        names[pname] = mc.clean(name).strip() or "Project %d" % n
        order.append(pname)
    names[None] = mc.project_name(model, None)
    return names, order


def _join(names):
    names = [n for n in names if n]
    if len(names) <= 2:
        return " and ".join(names)
    return ", ".join(names[:-1]) + " and " + names[-1]


def _week_start(day):
    return day - _dt.timedelta(days=(day.weekday() + 1) % 7)


def public_snapshot(model, crew, settings, pub, now):
    """The whole public snapshot, built field by field from the allow-list above."""
    today = bridge._parse_day(model["today"])
    names, order = _public_names(model)
    pkey = {pname: "p%d" % (i + 1) for i, pname in enumerate(order)}
    pkey[None] = "p0"
    registered = {p.lower(): p for p in order}

    def base(raw):
        return os.path.basename(os.path.normpath(str(raw))).lower() if raw is not None else None

    def proj(raw):
        """A raw project reference (a name, a path's last part, or None) -> registered name or None."""
        return registered.get(base(raw))

    mates = model.get("mates") or []
    akey = {}
    agents = []

    def add(member, **fields):
        key = "a%d" % (len(agents) + 1)
        akey[member["key"]] = key
        entry = {"key": key, "kind": fields.pop("kind"), "name": fields.pop("name"),
                 "state": "working" if member["status"] == "work" else "asleep",
                 "color": member["color"], "hair": member["hair"]}
        entry.update(fields)
        agents.append(entry)

    by_key = {c["key"]: c for c in crew}
    fm = by_key["fm"]
    add(fm, kind="first", name=settings["first_mate_name"], role="first mate",
        activity="working" if fm["status"] == "work" else "standing by",
        projects=[pkey[p] for p in order], lead=None)
    shown = 0
    for i, m in enumerate(mates):
        c = by_key.get("mate:" + m["id"])
        if c is None or shown >= MAX_MATES_SHOWN:
            continue
        shown += 1
        owned = [p for p in (proj(x) for x in m["projects"]) if p]
        pub_owned = [names[p] for p in owned]
        name = pub_owned[0] if pub_owned else "Second mate %d" % (i + 1)
        if m["remote"]:
            activity = "works on another machine"
        elif c["status"] == "work":
            activity = "working on %s" % (_join(pub_owned) if pub_owned else "its own list")
        else:
            activity = "asleep"
        role = "second mate for %s" % _join(pub_owned) if pub_owned else "second mate"
        add(c, kind="mate", name=name, role=role, activity=activity,
            projects=[pkey[p] for p in owned], lead=akey["fm"])
    for c in crew:
        if c["kind"] != "intern":
            continue
        lead = akey.get(c["lead"])
        if lead is None:
            continue
        p = proj(c.get("project"))
        if p or (model["ship"] and base(c.get("project")) == model["ship"].lower()):
            where, keys = names[p], [pkey[p]]
        else:
            where, keys = "a one-off job", []
        add(c, kind="helper", name="helper for %s" % where, role="helper for %s" % where,
            activity=("working on %s" if c["status"] == "work" else "between steps on %s") % where,
            projects=keys, lead=lead)

    week0 = _week_start(today)
    month = model["today"][:7]
    cards = {card["key"] or None: card for card in mc.project_cards(model, crew)}
    projects = []
    for pname in order + [None]:
        card = cards.get(pname)
        items = [it for it in model["items"] if it["project"] == pname]
        done_days = [bridge._parse_day(it["date"]) for it in items + list(model.get("history") or [])
                     if it["bucket"] == "done" and it["project"] == pname]
        lead_key = "fm"
        if pname is not None:
            mate = next((m for m in mates if pname.lower() in [x.lower() for x in m["projects"]]), None)
            if mate and "mate:" + mate["id"] in akey:
                lead_key = "mate:" + mate["id"]
        projects.append({
            "key": pkey[pname], "name": names[pname] if pname else mc.project_name(model, None, card=True),
            "short": names[pname],
            "color": card["color"] if card else mc.FIRST_MATE_COLOR,
            "status": card["status"] if card else "quiet",
            "lead": akey[lead_key],
            "counts": {
                "waiting": sum(1 for it in items if it["bucket"] == "waiting"),
                "in_flight": sum(1 for it in items if it["bucket"] == "in_flight"),
                "done_week": sum(1 for d in done_days if d and week0 <= d <= today),
                "done_month": sum(1 for d in done_days if d and d.strftime("%Y-%m") == month),
            },
        })

    first = mc._month_start(today, -2)
    last = mc._month_start(today, 2) - _dt.timedelta(days=1)
    span = [first + _dt.timedelta(days=i) for i in range((last - first).days + 1)]
    days = []
    for day, entries in sorted(mc.calendar(model, span).items()):
        done, due = {}, {}
        for it in entries:
            bucket = done if it["mark"] == "done" else due
            k = pkey.get(it["project"], "p0")
            bucket[k] = bucket.get(k, 0) + 1
        if done or due:
            days.append({"date": day.isoformat(), "done": done, "due": due})

    return {
        "schema": SCHEMA,
        "generated_at": now.astimezone(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "every_minutes": pub["every_minutes"],
        "heartbeat_minutes": pub["heartbeat_minutes"],
        "today": today.isoformat(),
        "office": {"inbox": sum(1 for it in model["items"] if it["bucket"] == "waiting")},
        "agents": agents,
        "projects": projects,
        "calendar": {"from": first.isoformat(), "to": last.isoformat(), "days": days},
    }


def events(old, new, now):
    """The previous snapshot's events plus the plain state changes from old to new, newest first."""
    kept = [e for e in (old or {}).get("events") or [] if isinstance(e, dict)
            and set(e) == {"at", "who", "what"} and all(isinstance(v, str) for v in e.values())]
    if not old or not isinstance(old.get("agents"), list):
        return kept[:EVENTS_KEPT]
    at = now.astimezone(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    fresh = []

    def people(snap):
        """{(kind, name): agent} for the first mate and the second mates, by public name."""
        return {(a.get("kind"), a.get("name")): a for a in snap.get("agents") or []
                if isinstance(a, dict) and a.get("kind") in ("first", "mate")}

    def helpers(snap):
        names = {a.get("key"): a.get("name") for a in snap.get("agents") or [] if isinstance(a, dict)}
        out = {}
        for a in snap.get("agents") or []:
            if isinstance(a, dict) and a.get("kind") == "helper":
                k = (names.get(a.get("lead")), a.get("name"))
                out[k] = out.get(k, 0) + 1
        return out

    was, now_ = people(old), people(new)
    for k, a in now_.items():
        if k not in was:
            fresh.append((a["name"], "joins the crew"))
    h_was, h_now = helpers(old), helpers(new)
    for (lead, name), n in h_now.items():
        for _ in range(n - h_was.get((lead, name), 0)):
            if lead:
                fresh.append((lead, "calls in a %s" % name))
    for (lead, name), n in h_was.items():
        for _ in range(n - h_now.get((lead, name), 0)):
            fresh.append((name[:1].upper() + name[1:], "goes home"))
    if old.get("today") == new.get("today"):
        def done_today(snap):
            day = next((d for d in (snap.get("calendar") or {}).get("days") or []
                        if isinstance(d, dict) and d.get("date") == snap.get("today")), {})
            return day.get("done") or {}
        names = {p["key"]: p["short"] for p in new["projects"]}
        d_was, d_now = done_today(old), done_today(new)
        for k, n in d_now.items():
            for _ in range(n - (d_was.get(k) or 0)):
                if k in names:
                    fresh.append((names[k], "finishes a job"))
    return ([{"at": at, "who": who, "what": what} for who, what in fresh] + kept)[:EVENTS_KEPT]


# ---------------------------------------------------------------------------
# Writing the folder
# ---------------------------------------------------------------------------

def _read_bytes(path):
    try:
        with open(path, "rb") as fh:
            return fh.read()
    except OSError:
        return None


def _write_if_changed(path, data):
    if _read_bytes(path) == data:
        return False
    tmp = path + ".tmp"
    with open(tmp, "wb") as fh:
        fh.write(data)
    os.replace(tmp, path)
    return True


def _encode(snap):
    return (json.dumps(snap, indent=1, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")


def _keep_time(snap, old_bytes, heartbeat_minutes, now):
    """The previous generated_at when only the time changed and the heartbeat has not passed."""
    try:
        old = json.loads(old_bytes.decode("utf-8")) if old_bytes else None
    except ValueError:
        return snap
    if not isinstance(old, dict) or not isinstance(old.get("generated_at"), str):
        return snap
    if dict(old, generated_at="") != dict(snap, generated_at=""):
        return snap
    try:
        then = _dt.datetime.strptime(old["generated_at"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=_dt.timezone.utc)
    except ValueError:
        return snap
    if (now - then).total_seconds() >= heartbeat_minutes * 60:
        return snap
    return dict(snap, generated_at=old["generated_at"])


def build(home, config_dir, out_dir, agents_text=None, herdr=("herdr",)):
    """Write the folder; returns the names of the files whose bytes changed."""
    now = bridge._now()
    model = bridge.collect(home, config_dir, now)
    settings = mc.read_settings(config_dir)
    pub = read_public_settings(config_dir)
    model = mc.with_settings(model, settings)
    agents = mc.parse_agents(agents_text) if agents_text is not None else mc.read_agents(list(herdr))
    crew = mc.build_crew(model, agents or [], home, os.environ.get("HERDR_SESSION") or "default",
                         None, settings["first_mate_name"])
    snap = public_snapshot(model, crew, settings, pub, now)
    os.makedirs(out_dir, exist_ok=True)
    changed = []
    for name in STATIC:
        with open(os.path.join(ASSETS, name), "rb") as fh:
            if _write_if_changed(os.path.join(out_dir, name), fh.read()):
                changed.append(name)
    if _write_if_changed(os.path.join(out_dir, ".nojekyll"), b""):
        changed.append(".nojekyll")
    path = os.path.join(out_dir, SNAPSHOT)
    previous = _read_bytes(path)
    try:
        old = json.loads(previous.decode("utf-8")) if previous else None
    except ValueError:
        old = None
    snap["events"] = events(old if isinstance(old, dict) and old.get("schema") == SCHEMA else None, snap, now)
    snap = _keep_time(snap, previous, pub["heartbeat_minutes"], now)
    if _write_if_changed(path, _encode(snap)):
        changed.append(SNAPSHOT)
    return changed


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(prog="fm_mission_control_web.py")
    ap.add_argument("command", choices=["build", "setting", "files"])
    ap.add_argument("key", nargs="?", help="setting: host, repository, project, every_minutes or heartbeat_minutes")
    ap.add_argument("--home")
    ap.add_argument("--config-dir")
    ap.add_argument("--out", help="build: the folder to write")
    ap.add_argument("--agents", help="build: a saved `herdr agent list` JSON file")
    ap.add_argument("--herdr", default="herdr", help="the herdr command, split on spaces")
    args = ap.parse_args(argv)
    if args.command == "files":
        print("\n".join(FILES))
        return 0
    if not args.config_dir:
        ap.error("--config-dir is required")
    if args.command == "setting":
        pub = read_public_settings(args.config_dir)
        if args.key not in pub:
            ap.error("unknown setting: %s" % args.key)
        print(pub[args.key])
        return 0
    if not args.home or not args.out:
        ap.error("build needs --home and --out")
    text = None
    if args.agents:
        with open(args.agents, encoding="utf-8") as fh:
            text = fh.read()
    try:
        changed = build(os.path.abspath(args.home), args.config_dir, os.path.abspath(args.out),
                        text, args.herdr.split())
    except RuntimeError as exc:
        print("fm_mission_control_web.py: %s" % exc, file=sys.stderr)
        return 1
    print("changed: %s" % (" ".join(changed) if changed else "nothing"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
