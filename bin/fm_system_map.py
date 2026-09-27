#!/usr/bin/env python3
"""fm_system_map.py - the System Map: the whole crew and how work flows, drawn live.

The Bridge (bin/fm_bridge.py) serves it at /system-map (the page) and
/system-map.json (the map), and bin/fm-bridge.sh owns the command surface and
the address. This module owns what the map reads, which nodes and lines it
draws, the guided tour, and the page that draws them in the browser.

GENERATED, NEVER HAND-DRAWN. Every node comes from a record or a tool read at
build time, so a new second mate, project, worker, tool, pipeline step or
playbook shows up with nobody editing the map, and each caption comes from the
node's own source. When a source cannot be read its node says "could not read"
instead of guessing.
  The captain       always there; how requests arrive: chat with the first
                    mate, Termius on the iPad (this Mac answering secure shell
                    on port 22), quick notes (bin/fm-inbox.sh, once
                    state/inbox exists) and public mentions (only when the
                    Relay's generated poll state/x-watch.check.sh exists).
  The first mate    named by config/mission-control.json first_mate_name; its
                    caption is the first sentence of the home's AGENTS.md
                    section 1.
  Second mates      data/secondmates.md through bin/fm_bridge.py collect(),
                    named the way Mission Control names them.
  Workers           every live task in this home and each local second mate
                    home (the fleet snapshot collect() runs), except the mates
                    themselves; working or not, and who leads each, come from
                    Mission Control's build_crew() over `herdr agent list`, so
                    the map and the office always agree.
  Projects          data/projects.md, with Mission Control's display names and
                    colours; the bracketed posture says how its work ships.
  Toolbox           the worker runtime (config/crew-harness) and runtime
                    backend (config/backend), the tools in TOOLS found on PATH
                    plus every tool in config/watched-tools.json, Controls and
                    its merge switch (bin/fm_merge_switch.py read()), the first
                    mate's memory pages, and the playbooks in the home's
                    .agents/skills, each with its own description line.
  Delivery lane     "build", then the step names `no-mistakes axi logs --help`
                    prints, then "merge", whose words follow the merge switch
                    and the projects marked +yolo; side paths appear only for
                    postures some project uses (direct-PR, local-only).
  Where results show  OUTPUTS, each present when its script is in bin/.
Tool versions, help lines, the step names and the other command reads are
cached for PROBE_TTL seconds; the records are read on every build.

LIVE. A node whose agent is working glows, the lines on a working path are
lit, and each worker sits on its delivery step, derived from the snapshot's
current state (a parked gate names its step; "ci running" is ci; green checks
wait at merge; a run still validating lights the checks as a group). The page
fetches the map every REFRESH seconds.

READ ONLY AND PRIVATE. Nothing here writes a file or changes anything. Every
string in the map passes scrub(), which removes file paths, web links, email
addresses and long token-like strings, and the map never reads .env or any
credential. Node captions name their source in plain words, never a path.

Commands: `json` prints the map, `page` prints the page; both take --home and
the Bridge's --config-dir like bin/fm_bridge.py.
"""

import json
import os
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fm_bridge as bridge  # noqa: E402  - the one reader of the records
import fm_mission_control as mc  # noqa: E402  - names, colours and who is working
import fm_merge_switch as merge_switch  # noqa: E402  - the one owner of the switch

CODE_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REFRESH = 60
PROBE_TTL = 600
CMD_TIMEOUT = 8
COULD_NOT_READ = "could not read"

HARNESS_NAMES = {"claude": "Claude Code", "codex": "Codex", "opencode": "OpenCode", "pi": "Pi",
                 "pi-signed": "Pi", "grok": "Grok", "kimi": "Kimi", "cursor": "Cursor", "muse": "Muse"}
BACKEND_NAMES = {"tmux": "tmux", "herdr": "Herdr", "zellij": "Zellij", "orca": "Orca", "cmux": "cmux"}

# Tools the first mate leans on: (id, label, command, what it does in our workflow, who uses it, icon).
TOOLS = (
    ("github", "GitHub CLI", "gh", "Opens pull requests, reads their checks and merges them on GitHub.",
     "The first mate and the interns", "\U0001F419"),
    ("no-mistakes", "no-mistakes", "no-mistakes",
     "Runs the automatic checks on every change before it reaches GitHub: the delivery lane below.",
     "Every intern shipping a change", "\u2705"),
    ("herdr", "Herdr", "herdr", "Holds every agent's window, so the first mate can start, watch and talk to them.",
     "The first mate, and you when you open an agent's window", "\U0001FA9F"),
    ("tasks", "Backlog tool", "tasks-axi",
     "Keeps each to-do list: what is queued, in flight, waiting on you and done.",
     "The first mate and every second mate", "\U0001F4CB"),
    ("quota", "Quota checker", "quota-axi",
     "Checks how much AI usage is left before the first mate picks who does a job.",
     "The first mate", "\u26FD"),
    ("rclone", "Google Drive (rclone)", "rclone", "Copies finished files to and from your Google Drive.",
     "The first mate and the interns", "\u2601\uFE0F"),
    ("tailscale", "Tailscale", "tailscale",
     "The private network that lets your iPad reach this Mac, and keeps everyone else out.",
     "You, from the iPad", "\U0001F512"),
    ("browser", "Browser helper", "chrome-devtools-axi", "Lets an agent open and check web pages.",
     "The interns", "\U0001F310"),
    ("lavish", "Review pages", "lavish-axi", "Builds visual pages for you to review and comment on.",
     "The first mate and scouts", "\U0001F5BC\uFE0F"),
)

# Where results show: (id, label, script in bin/, what it does, who uses it, icon).
OUTPUTS = (
    ("mission-control", "Mission Control", "fm-mission-control.sh",
     "The animated office on this Mac: who is working, the board, the calendar and the health checks.",
     "You, on this Mac or through Termius", "\U0001F5A5\uFE0F"),
    ("public-page", "Public page", "fm-mission-control-web.sh",
     "A public snapshot of the office for anyone to see, with private details left out.",
     "Anyone you share the link with", "\U0001F30D"),
    ("bridge", "The Bridge", "fm-bridge.sh",
     "The private web page this map lives on: every project on one page, on your iPad.",
     "You, from the iPad", "\U0001F4CA"),
    ("drive", "Google Drive", None, "Where finished documents land for you.", "You", "\U0001F4C2"),
    ("github", "GitHub", None, "Where each project's files and pull requests live.",
     "You, to read and approve pull requests", "\U0001F419"),
)

STEP_WORDS = {
    "build": "The intern makes the change in its own private copy, so nothing else is disturbed.",
    "intent": "Reads what you asked for, so every later check judges the change against your words.",
    "rebase": "Brings the change up to date with the latest version of the project.",
    "review": "An automatic reviewer reads the change looking for mistakes.",
    "test": "Runs the project's own tests.",
    "document": "Updates the written guides so they match the change.",
    "lint": "Checks the code against the project's tidiness rules.",
    "push": "Sends the checked change up to GitHub.",
    "pr": "Opens a pull request: a page on GitHub showing exactly what would change.",
    "ci": "GitHub runs the checks again on its own machines.",
}
STEP_LABELS = {"build": "Build", "intent": "Your words", "rebase": "Catch up", "review": "Review",
               "test": "Test", "document": "Docs", "lint": "Tidy", "push": "Push", "pr": "Pull request",
               "ci": "GitHub checks", "merge": "Merge"}
CHECK_STEPS = ("intent", "rebase", "review", "test", "document", "lint")

POSTURE_WORDS = {
    "no-mistakes": "every change goes through the full automatic checks, then a pull request",
    "no-mistakes-prod-only": "changes you will see go through the full checks; behind-the-scenes "
                             "tooling takes the quick pull request",
    "direct-PR": "changes go straight to a quick pull request, without the full checks",
    "local-only": "work stays on this Mac and is landed here after your OK",
}


# ---------------------------------------------------------------------------
# Plain words and scrubbing
# ---------------------------------------------------------------------------

_URL = re.compile(r"\b(?:https?|file|ssh)://[^\s,;)]+")
_EMAIL = re.compile(r"\b[\w.+-]+@[\w-]+\.[\w.-]+\b")
_TOKEN = re.compile(r"\b(?:gh[opsu]_|github_pat_|sk-|xox[abp]-)[A-Za-z0-9_-]+"
                    r"|\b(?=[A-Za-z0-9_-]*\d)(?=[A-Za-z0-9_-]*[A-Za-z])[A-Za-z0-9_-]{20,}\b")
_PATHISH = re.compile(r"(?<![\w:/.])(?:~/|\.{1,2}/|/[^\s/,;)]+/)[^\s,;)]*"
                      r"|\b(?:state|data|config|projects|bin|tests)/[^\s,;)]+"
                      r"|\b[\w.-]+\.(?:md|meta|status|sh|py|json|toml|log|env)\b")


def scrub(text, secrets=()):
    """Plain words only: no paths, links, email addresses or token-like strings."""
    if not isinstance(text, str):
        return text
    for s in secrets:
        if s and len(s) > 1:
            text = re.sub(re.escape(s) + r"[^\s,;)]*", "a local file", text)
    text = _URL.sub("a web link", text)
    text = _EMAIL.sub("an email address", text)
    text = _TOKEN.sub("(hidden)", text)
    text = _PATHISH.sub("a local file", text)
    return re.sub(r"\s{2,}", " ", text).strip()


def _scrub_all(value, secrets):
    if isinstance(value, dict):
        return {k: _scrub_all(v, secrets) for k, v in value.items()}
    if isinstance(value, list):
        return [_scrub_all(v, secrets) for v in value]
    return scrub(value, secrets)


def _sentence(text, limit=190):
    text = re.sub(r"\s+", " ", (text or "").strip())
    m = re.match(r"(.+?[.!?])(?:\s|$)", text)
    text = m.group(1) if m else text
    return bridge._clip(text, limit)


def _cap(text):
    return text[:1].upper() + text[1:] if text else text


def _read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return None


def script_caption(path):
    """A script's own one-line description: header line 2, "# <name> - <text>"."""
    text = _read(path)
    if text is None:
        return None
    for line in text.splitlines()[1:4]:
        m = re.match(r"^(?:#|\"\"\")\s*[\w.-]+\s+-\s+(.+)$", line.strip())
        if m:
            return _cap(m.group(1).strip().rstrip(".") + ".")
    return None


def leader_sentence(home, name):
    """The first sentence of AGENTS.md section 1, told about the first mate by name."""
    text = _read(os.path.join(home, "AGENTS.md"))
    if not text:
        return None
    m = re.search(r"^## 1\.[^\n]*\n+(.*?)(?:\n\n|\Z)", text, re.S | re.M)
    if not m:
        return None
    first = _sentence(m.group(1).replace("\n", " "), 240)
    first = re.sub(r"^You are\b", "%s is" % name, first)
    first = first.replace("the captain's", "your").replace("the captain", "you")
    return re.sub(r"\btheir\b", "your", first) if "your" in first else first


def skill_entries(home):
    """Playbooks: [{name, text, yours}] from each .agents/skills/<name>/SKILL.md front matter."""
    root = os.path.join(home, ".agents", "skills")
    if not os.path.isdir(root):
        root = os.path.join(CODE_ROOT, ".agents", "skills")
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return None
    out = []
    for name in names:
        text = _read(os.path.join(root, name, "SKILL.md"))
        if text is None or not text.startswith("---"):
            continue
        front = text.split("\n---", 1)[0]
        desc, grab = [], False
        for line in front.splitlines()[1:]:
            if re.match(r"^description:", line):
                rest = line.split(":", 1)[1].strip()
                grab = True
                if rest and rest not in (">-", ">", "|", "|-"):
                    desc.append(rest.strip("'\""))
                continue
            if grab:
                if line.startswith((" ", "\t")):
                    desc.append(line.strip())
                    continue
                grab = False
        yours = bool(re.search(r"^user-invocable:\s*true\b", front, re.M))
        words = _sentence(" ".join(desc)) or COULD_NOT_READ
        words = re.sub(r"^Agent-only\s+", "", words)
        out.append({"name": name, "text": _cap(words), "yours": yours})
    return out


# ---------------------------------------------------------------------------
# Command reads, cached
# ---------------------------------------------------------------------------

def _run(argv, timeout=CMD_TIMEOUT):
    try:
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False,
                              stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    return proc.returncode, (proc.stdout or "") + ("\n" + proc.stderr if not proc.stdout else "")


def _which(command):
    if command == "tailscale":
        return mc._tailscale()
    return shutil.which(command) if command else None


def _help_line(text):
    """A tool's description of itself: a `description:` field, else its first plain paragraph."""
    text = (text or "").replace("\u2014", "-")
    m = re.search(r"^description:\s*\"?(.+?)\"?\s*$", text, re.M)
    if m:
        return _sentence(m.group(1), 140)
    for para in re.split(r"\n\s*\n", text):
        lines = [ln.strip() for ln in para.strip().splitlines()]
        if not lines or not lines[0]:
            continue
        first = lines[0]
        if (re.match(r"^(usage|commands|flags|options|examples)\b", first, re.I) or first.endswith(":")
                or re.match(r"^[\w-]+(\[\d+\])?(\{[^}]*\})?:\s", first) or first.startswith(("(", "-"))):
            continue
        return _sentence(" ".join(lines), 140)
    return None


def probe_tool(command, version_args=("--version",)):
    path = _which(command)
    if not path:
        return {"found": False}
    ver = _run([path] + list(version_args))
    helped = _run([path, "--help"])
    return {"found": True, "version": mc._version(ver[1]) if ver and ver[0] == 0 else None,
            "help": _help_line(helped[1]) if helped and helped[0] == 0 else None}


def pipeline_steps():
    """The step names no-mistakes lists for its own logs, or None."""
    path = shutil.which("no-mistakes")
    got = _run([path, "axi", "logs", "--help"]) if path else None
    if not got or got[0] != 0:
        return None
    m = re.search(r"step name:\s*([^\n(]+)", got[1])
    if not m:
        return None
    names = []
    for part in re.split(r",\s*|\s+or\s+", m.group(1)):
        part = part.strip().strip(".")
        if re.fullmatch(r"[a-z][a-z0-9-]*", part):
            names.append(part)
    return names or None


def ssh_answers():
    try:
        with socket.create_connection(("127.0.0.1", 22), timeout=0.5):
            return True
    except OSError:
        return False


def drive_remotes():
    path = shutil.which("rclone")
    got = _run([path, "listremotes", "--long"]) if path else None
    if not got or got[0] != 0:
        return None
    return sum(1 for ln in got[1].splitlines() if re.search(r":\s+drive\b", ln))


def tailnet_up():
    path = mc._tailscale()
    got = _run([path, "status", "--json"]) if path else None
    if not got or not got[1].strip():
        return None
    try:
        return json.loads(got[1]).get("BackendState") == "Running"
    except (ValueError, AttributeError):
        return None


def running_screens():
    got = _run(["ps", "-ax", "-o", "command="])
    if not got or got[0] != 0:
        return None
    return {"mission-control": "fm_mission_control.py run" in got[1],
            "controls": "fm_controls.py run" in got[1]}


def watched_tools(config_dir):
    """config/watched-tools.json's tools as (label, command, version args), per docs/configuration.md."""
    text = _read(os.path.join(config_dir, "watched-tools.json"))
    if text is None:
        return []
    try:
        tools = json.loads(text).get("tools") or []
    except (ValueError, AttributeError):
        return []
    out = []
    for t in tools:
        if not isinstance(t, dict) or not isinstance(t.get("name"), str):
            continue
        cmd = t.get("command") if isinstance(t.get("command"), str) else None
        if cmd and not re.fullmatch(r"[A-Za-z0-9._+-]+", cmd):
            cmd = None
        args = t.get("version_args")
        args = tuple(a for a in args if isinstance(a, str)) if isinstance(args, list) else ("--version",)
        out.append((t["name"], cmd, args or ("--version",)))
    return out


class _Probes:
    """Command reads shared across builds, refreshed after PROBE_TTL seconds."""

    def __init__(self):
        self.lock = threading.Lock()
        self.at, self.key, self.value = 0.0, None, None

    def get(self, commands):
        key = tuple(commands)
        with self.lock:
            if self.value is not None and self.key == key and time.monotonic() - self.at < PROBE_TTL:
                return self.value
        with ThreadPoolExecutor(max_workers=8) as pool:
            tools = {c: pool.submit(probe_tool, c, a) for c, a in commands}
            jobs = {"steps": pool.submit(pipeline_steps), "ssh": pool.submit(ssh_answers),
                    "drive": pool.submit(drive_remotes), "tailnet": pool.submit(tailnet_up)}
            value = {"tools": {c: f.result() for c, f in tools.items()}}
            value.update({k: f.result() for k, f in jobs.items()})
        with self.lock:
            self.at, self.key, self.value = time.monotonic(), key, value
        return value


PROBES = _Probes()


# ---------------------------------------------------------------------------
# Building the map
# ---------------------------------------------------------------------------

def _node(nid, kind, col, label, icon, what, role, users, now, source, status="idle", color=None, **extra):
    node = {"id": nid, "kind": kind, "col": col, "label": label, "icon": icon, "status": status,
            "color": color or "#8a93a0",
            "card": {"what": what or COULD_NOT_READ, "role": role, "users": users, "now": now,
                     "source": source}}
    node.update(extra)
    return node


def worker_step(task):
    """(step, zone) on the delivery lane for one worker from its current state, or (None, None)."""
    if task.get("kind") == "scout":
        return None, None
    cur = task.get("current_state") or {}
    state, source, detail = cur.get("state"), cur.get("source"), (cur.get("detail") or "").lower()
    if source == "run-step":
        m = re.match(r"parked at ([a-z][a-z0-9-]*)", detail)
        if m:
            return m.group(1), None
        if detail.startswith("ci running"):
            return "ci", None
        if detail.startswith(("checks green", "run passed")):
            return "merge", None
        return None, "checks"
    if state == "done":
        if (task.get("pr") or {}).get("url") or task.get("mode") == "local-only":
            return "merge", None
        return None, None
    return ("build", None) if state in ("working", "paused", "blocked", "parked") else (None, None)


def _step_phrase(step, zone):
    if zone == "checks":
        return "going through the automatic checks"
    if step == "merge":
        return "ready, waiting to be merged"
    if step == "build":
        return "making the change"
    return "at the %s step" % STEP_LABELS.get(step, step)


def build(home, config_dir, now=None, agents=None, probes=None):
    """The map as a dict: nodes, edges, lane, tour and the list the "What changed" strip tracks.

    config_dir is the Bridge's settings folder, as bin/fm_bridge.py collect() takes it; the
    home's own settings (Mission Control's names, the worker runtime and backend, the
    watched tools) are always read from the home's config folder, as Mission Control does."""
    now = now or bridge._now()
    home = os.path.realpath(home)
    bridge_config, config_dir = config_dir, os.path.join(home, "config")
    settings = mc.read_settings(config_dir)
    fm = settings["first_mate_name"]
    model = mc.with_settings(bridge.collect(home, bridge_config, now), settings)
    herdr = (os.environ.get("FM_MC_HERDR") or "herdr").split()
    if agents is None:
        agents = mc.read_agents(herdr) if shutil.which(herdr[0]) else None
    herdr_ok = agents is not None
    crew = mc.build_crew(model, agents or [], home, os.environ.get("HERDR_SESSION") or "default", None, fm)
    colors = mc.project_colors(model)
    extra_tools = watched_tools(config_dir)
    commands = [(t[2], ("--version",)) for t in TOOLS] + [(c, a) for _, c, a in extra_tools if c]
    probes = probes or PROBES.get(commands)
    screens = running_screens() or {}
    switch = merge_switch.read(home)
    nodes, edges, tracked = [], [], []

    def add(node, track=True):
        nodes.append(node)
        if track:
            tracked.append({"key": node["id"], "label": node["label"], "kind": node["kind"]})
        return node

    def edge(a, b, kind="flow", live=False):
        edges.append({"from": a, "to": b, "kind": kind, "live": bool(live)})

    by_key = {c["key"]: c for c in crew}
    lead = by_key["fm"]
    fm_working = lead["status"] == "work"

    # --- the captain and how requests arrive -----------------------------------
    add(_node("captain", "captain", 0, "You", "\U0001F9D1\u200D\u2708\uFE0F",
              "The captain: the one person every agent works for.",
              "Every job starts with something you ask for, and only you make the big calls.",
              "Everyone on the map works for you.",
              "%s waiting on you." % _cap(bridge._plural(sum(1 for it in model["items"]
                                                            if it["bucket"] == "waiting"), "decision")),
              "the to-do lists", status="you", color="#d97757"), track=False)
    channels = [("chat", "Chat with %s" % fm, "\U0001F4AC",
                 "The chat window where you type to %s." % fm,
                 "Your main way in: ask for anything in plain words and %s takes it from there." % fm,
                 "You", "Working now." if fm_working else "Ready for your next message.",
                 "who is working, from the agent windows", "working" if fm_working else "idle")]
    ssh = probes.get("ssh")
    channels.append(("termius", "Termius on the iPad", "\U0001F4F1",
                     "A terminal app on your iPad that opens a secure connection to this Mac.",
                     "Lets you reach %s's window, and Mission Control, from anywhere on your private network." % fm,
                     "You, away from the Mac",
                     "This Mac is accepting secure connections." if ssh else
                     "This Mac is not accepting secure connections right now.",
                     "this Mac's secure shell service", "idle" if ssh else "off"))
    if os.path.isdir(os.path.join(home, "state", "inbox")):
        cap = script_caption(os.path.join(CODE_ROOT, "bin", "fm-inbox.sh"))
        pending = [n for n in os.listdir(os.path.join(home, "state", "inbox")) if not n.startswith(".")
                   and n != "handled"]
        channels.append(("inbox", "Quick notes", "\U0001F4DD", cap or COULD_NOT_READ,
                         "Leave %s a note, typed or spoken, while it is busy; it reads them in order." % fm,
                         "You", "%s waiting to be read." % _cap(bridge._plural(len(pending), "note")),
                         "the inbox script's own description", "idle"))
    if os.path.exists(os.path.join(home, "state", "x-watch.check.sh")):
        channels.append(("relay", "Public mentions", "\U0001F4E3",
                         "Mentions of %s on the public web, collected by the Relay." % fm,
                         "Lets people ask for small things in public; %s answers or turns them into jobs." % fm,
                         "People who mention %s" % fm, "Switched on for this Mac.", "the Relay setting", "idle"))
    for cid, label, icon, what, role, users, nw, src, status in channels:
        add(_node("channel:" + cid, "channel", 1, label, icon, what, role, users, nw, src, status=status,
                  color="#d97757"))
        edge("captain", "channel:" + cid, live=status == "working")
        edge("channel:" + cid, "fm", live=status == "working")

    # --- the first mate ----------------------------------------------------------
    lead_words = leader_sentence(home, fm)
    add(_node("fm", "first", 2, fm, "\U0001F9ED", lead_words or COULD_NOT_READ,
              "Takes every request, decides who handles it, watches the work, and brings you only "
              "the decisions that need you.",
              "You talk to %s; %s directs the second mates and the interns." % (fm, fm),
              _cap(lead["doing"]) + "." if herdr_ok else "Could not ask the agent windows who is working.",
              "the rule book's first section", status="working" if fm_working else
              ("idle" if herdr_ok else "unknown"), color=mc.FIRST_MATE_COLOR))

    # --- second mates, workers and projects -----------------------------------------
    mates = model.get("mates") or []
    snaps = model.get("snapshots") or {}
    main_tasks = (snaps.get("main") or {}).get("tasks") or []
    owner_of = {}
    for m in mates:
        for p in m["projects"]:
            owner_of.setdefault(p.lower(), m["id"])
    tasks_by = {}
    for hid, snap in [("main", snaps.get("main"))] + [(m["id"], snaps.get(m["id"])) for m in mates]:
        for t in (snap or {}).get("tasks") or []:
            if t.get("kind") != "secondmate" and t.get("id"):
                tasks_by["intern:%s:%s" % (hid, t["id"])] = t

    for i, m in enumerate(mates):
        row = by_key.get("mate:" + m["id"]) or {}
        task = next((t for t in main_tasks if t.get("id") == m["id"] and t.get("kind") == "secondmate"), None)
        harness = HARNESS_NAMES.get((task or {}).get("harness") or "", (task or {}).get("harness"))
        team = next((e for e in model["team"] if e["id"] == m["id"]), {})
        if m["remote"]:
            status, now_words = "off", "Works on another machine."
        elif not team.get("readable", True):
            status, now_words = "unreadable", "Could not read its records."
        elif not herdr_ok:
            status, now_words = "unknown", "Could not ask the agent windows who is working."
        else:
            status = "working" if row.get("status") == "work" else "idle"
            now_words = _cap(row.get("doing") or "") + "."
        role = m["scope"].split(":", 1)[0]
        extra = []
        if harness:
            extra.append("Runs on %s." % harness)
        extra.append("Keeps its own to-do list (%s open) and its charter." % team.get("open", 0))
        add(_node("mate:" + m["id"], "mate", 3, mc.mate_name(model, m["id"]), "\U0001F9D1\u200D\U0001F4BC",
                  _cap(_sentence(m["summary"])),
                  "Owns %s. %s" % (role, " ".join(extra)),
                  "%s sends it work for %s; it hires interns for that work." %
                  (fm, ", ".join(mc.project_name(model, p) for p in m["projects"]) or "its area"),
                  now_words, "the second mate list", status=status, color=mc.MATE_COLORS[i % len(mc.MATE_COLORS)],
                  group=m["id"]))
        edge("fm", "mate:" + m["id"], live=status == "working")

    def group_of(pname):
        return owner_of.get((pname or "").lower(), "main")

    for p in model["projects"]:
        pname = None if p["name"] == model["ship"] else p["name"]
        posture = p["posture"].split()
        mode = posture[0] if posture else ""
        yolo = "+yolo" in posture
        words = POSTURE_WORDS.get(mode)
        how = (_cap(words) + "." if words else "How its work ships could not be read.")
        how += (" %s may merge its green pull requests." % fm if yolo else " You approve every merge.")
        grp = group_of(p["name"])
        owner = "mate:" + grp if grp != "main" else "fm"
        parked = " Parked since %s." % p["parked"] if p.get("parked") else ""
        counts = bridge._counts([it for it in model["items"] if it["project"] == pname])
        add(_node("project:" + p["name"].lower(), "project", 5, mc.project_name(model, pname, card=pname is None),
                  "\U0001F4C1", _cap(_sentence(bridge._summary(p["description"]))), how,
                  "Worked on by %s." % (by_key.get(owner, lead)["name"] if owner != "fm" else fm),
                  "%d in flight, %d queued, %d waiting on you.%s" %
                  (counts.get("in_flight", 0), counts.get("queued", 0), counts.get("waiting", 0), parked),
                  "the project list", status="idle" if not p.get("parked") else "off",
                  color=colors.get(p["name"].lower(), mc.FIRST_MATE_COLOR), group=grp, mode=mode, yolo=yolo))
        edge(owner, "project:" + p["name"].lower(), kind="owns")

    steps_read = probes.get("steps")
    lane_steps = ["build"] + (steps_read or []) + ["merge"]
    at_step = {}
    for c in crew:
        if c["kind"] != "intern":
            continue
        task = tasks_by.get(c["key"]) or {}
        step, zone = worker_step(task)
        if (step, zone) == (None, None) and c["status"] == "work" and task and task.get("kind") != "scout":
            step = "build"  # its window is working though its record is not readable yet
        if step and step not in lane_steps:
            step, zone = None, "checks"
        lead_row = by_key.get(c["lead"]) or lead
        grp = c["lead"].split(":", 1)[1] if c["lead"].startswith("mate:") else "main"
        working = c["status"] == "work"
        state = (task.get("current_state") or {}).get("state") or ""
        word = "working" if working else ("idle" if state == "unknown" else "between steps" if state == "working"
                                          else bridge.STATE_WORDS.get(state, "idle"))
        nid = c["key"]
        if c.get("helper"):
            what = "An agent window working without a job record, such as one opened by hand."
            role = "Does whatever was asked in its window; it is not on any to-do list."
            users = "Started outside the usual hiring, next to %s." % lead_row["name"]
            now_words = "%s." % _cap(word if working else "idle")
            step = zone = None
        else:
            scout = task.get("kind") == "scout"
            what = "An intern hired for one job: it %s." % (
                "investigates a question and writes you a report" if scout else "makes one change and ships it")
            role = ("Works in its own private copy of the project, then hands its work to the delivery lane."
                    if not scout else "Works in its own private copy and writes its findings up for you.")
            users = "Hired by %s, let go when the job lands." % lead_row["name"]
            if (step or zone) and not working:
                where = "at the %s" % ("checks" if zone else "%s step" % STEP_LABELS.get(step, step))
            elif step or zone:
                where = _step_phrase(step, zone)
            elif scout:
                where = "report written" if state == "done" else "investigating"
            elif state == "done":
                where = "its work is finished"
            else:
                where = "its record could not be read"
            now_words = "%s, %s." % (_cap(word), where)
        add(_node(nid, "intern", 4, c["title"] or "A one-off job", "\U0001F6E0\uFE0F", what, role, users,
                  now_words, "the live worker records",
                  status="working" if working else "idle", color=c["color"], group=grp,
                  step=step, zone=zone, ships=not c.get("helper") and task.get("kind") != "scout"), track=False)
        edge(lead_row["key"] if lead_row["key"] != "fm" else "fm", nid, live=working)
        if c.get("project"):
            pkey = "project:" + c["project"].lower()
            if any(n["id"] == pkey for n in nodes):
                edge(nid, pkey, live=working)
        if step or zone:
            at_step.setdefault(step or zone, []).append({"id": nid, "label": c["title"] or "A one-off job",
                                                         "working": working})

    # --- toolbox ------------------------------------------------------------------
    tools = probes.get("tools") or {}

    def tool_node(tid, label, command, role, users, icon):
        got = tools.get(command) or {"found": False}
        if not got.get("found"):
            return add(_node("tool:" + tid, "tool", None, label, icon, COULD_NOT_READ, role, users,
                             "Could not find it on this Mac.", "the tool itself", status="unreadable"))
        ver = got.get("version")
        return add(_node("tool:" + tid, "tool", None, label, icon,
                         ("In its own words: \"%s\"" % got["help"]) if got.get("help") else "A tool on this Mac.",
                         role, users, "Installed%s." % (", version %s" % ver if ver else ""),
                         "the tool itself", status="idle"))

    crew_harness = (_read(os.path.join(config_dir, "crew-harness")) or "").strip().split()
    ch = crew_harness[0] if crew_harness else "default"
    add(_node("tool:runtime", "tool", None, "Worker runtime", "\U0001F916",
              "The AI assistant each intern runs on: %s." %
              (HARNESS_NAMES.get(ch, ch) if ch != "default" else "the same one %s runs on" % fm),
              "Every intern is a fresh copy of this assistant, given one job's instructions.",
              "Every intern", "Set for every new job.", "the worker runtime setting"))
    backend = (_read(os.path.join(config_dir, "backend")) or "").strip() or None
    add(_node("tool:backend", "tool", None, "Agent windows", "\U0001FA9F",
              "Where each agent's window lives: %s." %
              (BACKEND_NAMES.get(backend, backend) if backend else "picked automatically"),
              "Each agent gets its own window here, so %s can watch it and you can open it." % fm,
              fm, "Answering." if herdr_ok else "Could not be asked who is working.", "the backend setting",
              status="idle" if herdr_ok else "unknown"))
    for tid, label, command, role, users, icon in TOOLS:
        tool_node(tid, label, command, role, users, icon)
    for name, command, _args in extra_tools:
        tid = "watched:" + re.sub(r"[^a-z0-9-]+", "-", name.lower()).strip("-")
        if command:
            tool_node(tid, name, command, "A tool this home depends on, from the watched tools list.",
                      "The crew", "\U0001F527")
        else:
            add(_node("tool:" + tid, "tool", None, name, "\U0001F527", COULD_NOT_READ,
                      "A tool this home depends on, from the watched tools list.", "The crew",
                      "Could not tell which command it is.", "the watched tools list", status="unreadable"))
    word = {"on": "ON", "off": "OFF", "partial": "partly on"}.get(switch.get("state"))
    add(_node("tool:controls", "tool", None, "Controls", "\U0001F39B\uFE0F",
              script_caption(os.path.join(CODE_ROOT, "bin", "fm-controls.sh")) or COULD_NOT_READ,
              "Holds your merge switch: whether %s may merge green pull requests itself." % fm, "You",
              ("The merge switch is %s%s." % (word, "; the screen is open" if screens.get("controls") else ""))
              if word else "Could not read the merge switch.",
              "the Controls screen and its switch", status="idle" if word else "unreadable"))
    memory = model.get("memory") or []
    mem = [c for c in memory if c["kicker"] in ("About you", "About the ship")]
    add(_node("tool:memory", "tool", None, "Memory", "\U0001F9E0",
              "What %s remembers between conversations: your preferences and the lessons it has learned." % fm,
              "Read at the start of every session, so %s picks up where it left off." % fm, fm,
              ("%s, %s." % (bridge._plural(len(mem), "page"),
                            bridge._plural(sum(len(c["sections"]) for c in mem), "section")))
              if mem else "Nothing written down yet.", "the memory pages' headings"))
    skills = skill_entries(home)
    if skills is None:
        add(_node("tool:playbooks", "tool", None, "Playbooks", "\U0001F4D8", COULD_NOT_READ,
                  "Step-by-step procedures %s follows in particular situations." % fm, fm,
                  "Could not read the playbooks.", "the playbook folder", status="unreadable"))
    else:
        add(_node("tool:playbooks", "tool", None, "Playbooks", "\U0001F4D8",
                  "Step-by-step procedures %s follows in particular situations." % fm,
                  "%s opens the right one when a situation comes up; the ones marked yours you can start "
                  "by typing a slash and its name." % fm, "%s, and you for the ones marked yours" % fm,
                  "%s, %d you can start." % (_cap(bridge._plural(len(skills), "playbook")),
                                             sum(1 for s in skills if s["yours"])),
                  "each playbook's own description", items=skills))
        for s in skills:
            tracked.append({"key": "playbook:" + s["name"], "label": "Playbook: " + s["name"], "kind": "playbook"})

    # --- the delivery lane --------------------------------------------------------
    yolo_names = [mc.project_name(model, None if p["name"] == model["ship"] else p["name"])
                  for p in model["projects"] if "+yolo" in p["posture"].split()]
    sw = switch.get("state")
    if sw == "on":
        merge_role = ("%s merges green pull requests itself for %s, because your Controls switch is on; "
                      "everything else waits for your word." % (fm, ", ".join(yolo_names) or "no project yet"))
    elif sw == "off":
        merge_role = "You approve every merge, because your Controls switch is off; %s then merges it." % fm
    elif sw == "partial":
        merge_role = ("Your Controls switch is only partly on, so %s asks you before merging; "
                      "tap it once on Controls to set it cleanly." % fm)
    else:
        merge_role = "Could not read the merge switch, so %s asks you before merging." % fm
    lane = []
    for s in lane_steps:
        here = at_step.get(s, [])
        role = merge_role if s == "merge" else STEP_WORDS.get(s, "A check no-mistakes runs, named %s." % s)
        src = ("the merge switch" if s == "merge" else "how interns start work" if s == "build"
               else "no-mistakes itself")
        status = "working" if any(h["working"] for h in here) else "idle"
        if here:
            now_words = "Here now: %s." % "; ".join(h["label"] for h in here)
        else:
            now_words = "Nobody at this step right now."
        add(_node("step:" + s, "step", None, STEP_LABELS.get(s, _cap(s.replace("-", " "))),
                  "\U0001F500" if s == "merge" else "\U0001F528" if s == "build" else "\u2714\uFE0F",
                  role if s != "merge" else "The last step: the change joins the project.", role,
                  "Every change that ships through the full checks.", now_words, src, status=status,
                  here=here, check=s in CHECK_STEPS))
        lane.append("step:" + s)
    for a, b in zip(lane, lane[1:]):
        edge(a, b, kind="lane", live=nodes[[n["id"] for n in nodes].index(b)]["status"] == "working")
    if steps_read is None:
        add(_node("step:unread", "step", None, "The checks", "\u2754", COULD_NOT_READ,
                  "The automatic checks between the change and GitHub.", "Every change",
                  "Could not ask no-mistakes for its steps.", "no-mistakes itself", status="unreadable",
                  here=at_step.get("checks", [])))
        lane.insert(1, "step:unread")
    elif at_step.get("checks"):
        for n in nodes:
            if n["kind"] == "step" and n.get("check"):
                n["zone_here"] = at_step["checks"]
    side = []
    modes = {}
    for p in model["projects"]:
        mode = (p["posture"].split() or [""])[0]
        modes.setdefault(mode, []).append(mc.project_name(model, None if p["name"] == model["ship"] else p["name"]))
    for mode, sid, label, icon, role in (
            ("direct-PR", "quick", "Quick pull request", "\u26A1",
             "Skips the full checks: the intern opens the pull request straight away, and GitHub's own checks "
             "still run."),
            ("local-only", "local", "Stays on this Mac", "\U0001F3E0",
             "Never goes to GitHub for review: once you say yes, %s lands it on this Mac." % fm)):
        if mode in modes:
            add(_node("path:" + sid, "path", None, label, icon, role, role, "Used by " + ", ".join(modes[mode]) + ".",
                      "Some projects ship this way.", "the project list"))
            side.append("path:" + sid)

    # --- where results show ---------------------------------------------------------
    for oid, label, script, role, users, icon in OUTPUTS:
        nid = "output:" + oid
        if script:
            cap = script_caption(os.path.join(CODE_ROOT, "bin", script))
            if cap is None:
                add(_node(nid, "output", 6, label, icon, COULD_NOT_READ, role, users,
                          "Not set up on this Mac yet.", "its script", status="unreadable"))
                continue
            if oid == "mission-control":
                st = "working" if screens.get("mission-control") else "idle"
                nw = "Running on this Mac." if st == "working" else "Not open right now."
            elif oid == "bridge":
                st, nw = "working", "Serving this page right now."
            else:
                st, nw = "idle", "Updates on its own schedule."
            add(_node(nid, "output", 6, label, icon, cap, role, users, nw, "its script's own description",
                      status=st))
        elif oid == "drive":
            n = probes.get("drive")
            if n is None:
                add(_node(nid, "output", 6, label, icon, COULD_NOT_READ, role, users,
                          "Could not ask rclone which drives are connected.", "rclone", status="unreadable"))
            else:
                add(_node(nid, "output", 6, label, icon, "Your Google Drive, reached through rclone.", role, users,
                          "%s connected." % _cap(bridge._plural(n, "Drive account")), "rclone",
                          status="idle" if n else "off"))
        else:
            gh = tools.get("gh") or {}
            repos = sum(1 for p in model["projects"] if p.get("github"))
            add(_node(nid, "output", 6, label, icon, "The website where the code lives.", role, users,
                      "%s with a GitHub home." % _cap(bridge._plural(repos, "project")) if gh.get("found")
                      else "The GitHub tool is not on this Mac.", "the project list",
                      status="idle" if gh.get("found") else "unreadable"))
    edge("step:merge", "output:github", kind="shows")

    tour = build_tour(nodes, edges, fm)
    out = {
        "generated": now.isoformat(timespec="seconds"),
        "stamp": now.strftime("%A %-d %B, %-I:%M %p").replace("AM", "am").replace("PM", "pm"),
        "first_mate": fm, "refresh": REFRESH, "nodes": nodes, "edges": edges, "lane": lane, "side": side,
        "tour": tour, "tracked": tracked, "notices": [],
    }
    if not herdr_ok:
        out["notices"].append("Could not ask the agent windows who is working, so nobody glows.")
    if model.get("errors"):
        out["notices"].append("Could not read the records of %s." %
                              ", ".join(mc.mate_name(model, e) for e in model["errors"]))
    secrets = [home, os.path.expanduser("~"), CODE_ROOT, config_dir, bridge_config] + [m["home"] for m in mates]
    return _scrub_all(out, sorted({s for s in secrets if s}, key=len, reverse=True))


def build_tour(nodes, edges, fm):
    """One request's journey, one plain sentence per hop, along nodes that exist."""
    ids = {n["id"]: n for n in nodes}
    hops = []

    def hop(nid, text):
        if nid in ids:
            hops.append({"node": nid, "text": text})

    hop("captain", "You ask for something, in plain words.")
    hop("channel:chat", "Your message arrives in %s's chat, or through Termius when you are on the iPad." % fm)
    hop("fm", "%s reads it, works out which project it belongs to, and decides who should handle it." % fm)
    mates = [n for n in nodes if n["kind"] == "mate"]
    interns = [n for n in nodes if n["kind"] == "intern"]
    busy = [m for m in mates if any(i.get("group") == m.get("group") and i.get("ships") for i in interns)]
    mate = (busy or mates or [None])[0]
    if mate:
        hop(mate["id"], "Work for %s goes to its second mate, who keeps that project's list and rules." %
            mate["label"])
    grp = mate["group"] if mate else "main"
    boss = "The second mate" if mate else fm
    intern = next((i for i in interns if i.get("group") == grp and i.get("ships")), None)
    proj = None
    if intern:
        hop(intern["id"], "%s hires an intern for this one job; it works in its own private copy." % boss)
        proj = next((e["to"] for e in edges if e["from"] == intern["id"] and e["to"].startswith("project:")), None)
    if proj is None:
        proj = next((n["id"] for n in nodes if n["kind"] == "project" and n.get("group") == grp), None)
    if proj:
        hop(proj, "The job is about %s: that project's files are what change." % ids[proj]["label"])
    for sid in _lane_ids(nodes):
        n = ids[sid]
        if sid == "step:build" and not intern:
            hop(sid, "%s hires an intern for this one job; it makes the change in its own private copy." % boss)
            continue
        hop(sid, "%s step. %s" % (n["label"], n["card"]["role"]))
    hop("output:github", "The change now lives on GitHub with the rest of the project.")
    hop("output:mission-control", "Mission Control and the Bridge show it done, and %s tells you in chat." % fm)
    return hops


def _lane_ids(nodes):
    return [n["id"] for n in nodes if n["kind"] == "step"]


# ---------------------------------------------------------------------------
# The page
# ---------------------------------------------------------------------------

STYLE = bridge.STYLE + """
.wrap{max-width:none}
header.top{flex-wrap:wrap}
.tools{display:flex;gap:8px;flex-wrap:wrap;align-items:center;padding:10px 0}
.tools button,.tools a.btn{font:inherit;font-weight:600;font-size:13.5px;padding:8px 14px;border-radius:var(--pill);
  border:1px solid var(--line-2);background:var(--surface);color:var(--ink-2);cursor:pointer;min-height:40px}
.tools button.primary{background:var(--ink);color:var(--bg);border-color:var(--ink)}
.tools .zoom{display:flex;gap:4px;margin-left:auto}
.changed{background:var(--surface);border:1px solid var(--line);border-radius:var(--radius);padding:9px 14px;
  font-size:13.5px;color:var(--ink-2);margin:0 0 10px;display:flex;gap:6px 12px;flex-wrap:wrap;align-items:baseline}
.changed b{color:var(--ink);font-weight:700}
.chip{display:inline-block;padding:2px 9px;border-radius:var(--pill);font-size:12.5px;font-weight:600}
.chip.add{background:var(--good-soft);color:var(--good)}
.chip.gone{background:var(--warn-soft);color:var(--warn)}
.stage{background:var(--surface-2);border:1px solid var(--line);border-radius:var(--radius);overflow:auto;
  -webkit-overflow-scrolling:touch;touch-action:pan-x pan-y pinch-zoom;position:relative}
svg.map{display:block}
svg .band{fill:var(--surface);stroke:var(--line)}
svg .band-label{font:700 12px var(--display);letter-spacing:.08em;text-transform:uppercase;fill:var(--ink-3)}
svg .col-label{font:600 11.5px var(--display);letter-spacing:.07em;text-transform:uppercase;fill:var(--ink-3)}
svg .edge{fill:none;stroke:var(--line-2);stroke-width:1.6}
svg .edge.owns{stroke-dasharray:3 4}
svg .edge.shows{stroke-dasharray:6 5}
svg .edge.live{stroke:var(--good);stroke-width:2.4;stroke-dasharray:8 6}
svg .node{cursor:pointer}
svg .node rect.box{fill:var(--surface);stroke:var(--line-2);stroke-width:1.2}
svg .node.working rect.box{stroke:var(--good);stroke-width:2.2}
svg .node.unreadable rect.box{stroke-dasharray:4 3;fill:var(--surface-2)}
svg .node.off{opacity:.62}
svg .node .label{font:700 13.5px var(--display);fill:var(--ink)}
svg .node .sub{font:500 11.5px var(--display);fill:var(--ink-3)}
svg .node .icon{font-size:17px}
svg .node.selected rect.box{stroke:var(--accent);stroke-width:2.6}
svg .node.tour rect.box{stroke:var(--accent);stroke-width:3}
svg .badge{font:700 11px var(--display);fill:#fff}
svg .zone{fill:var(--good-soft);stroke:var(--good);stroke-dasharray:5 4}
svg .traveller{fill:var(--accent)}
.sheet{position:fixed;left:0;right:0;bottom:0;max-height:62vh;overflow:auto;background:var(--surface);
  border-top:1px solid var(--line-2);box-shadow:0 -10px 30px rgba(0,0,0,.12);padding:16px 16px 24px;
  transform:translateY(105%);transition:transform .22s ease;z-index:20}
.sheet.open{transform:none}
.sheet .inner{max-width:760px;margin:0 auto}
.sheet h2{margin:0 0 2px;font-size:20px}
.sheet .kind{font-size:11.5px;text-transform:uppercase;letter-spacing:.08em;color:var(--ink-3)}
.sheet dl{margin:12px 0 0}
.sheet dt{font-size:11.5px;text-transform:uppercase;letter-spacing:.07em;color:var(--ink-3);margin-top:12px}
.sheet dd{margin:3px 0 0;font-family:var(--prose);font-size:17px;color:var(--ink);overflow-wrap:anywhere}
.sheet .close{float:right;font:inherit;font-weight:600;border:1px solid var(--line-2);background:var(--surface-2);
  border-radius:var(--pill);padding:8px 14px;cursor:pointer;min-height:40px}
.sheet ul{margin:6px 0 0;padding-left:18px;font-family:var(--prose);font-size:16px}
.sheet li{margin:4px 0}
.tourbar{position:fixed;left:50%;bottom:16px;transform:translateX(-50%);width:min(760px,calc(100% - 32px));
  background:var(--ink);color:var(--bg);border-radius:14px;padding:12px 14px;display:none;gap:10px;align-items:center;
  z-index:25;box-shadow:0 8px 30px rgba(0,0,0,.25)}
.tourbar.open{display:flex}
.tourbar p{margin:0;flex:1;font-family:var(--prose);font-size:17px;line-height:1.35}
.tourbar small{display:block;font-family:var(--display);font-size:11px;letter-spacing:.07em;text-transform:uppercase;opacity:.7}
.tourbar button{font:inherit;font-weight:600;border:none;border-radius:var(--pill);padding:8px 12px;cursor:pointer;
  min-height:40px;background:rgba(255,255,255,.16);color:inherit}
body.touring{padding-bottom:140px}
.legend{display:flex;gap:6px 16px;flex-wrap:wrap;font-size:12.5px;color:var(--ink-3);padding:8px 2px 0}
.notice{background:var(--warn-soft);color:var(--warn);border-radius:var(--radius);padding:8px 14px;margin:0 0 10px;font-size:14px}
@media (prefers-reduced-motion:no-preference){
  svg .edge.live{animation:flow 1.2s linear infinite}
  @keyframes flow{to{stroke-dashoffset:-14}}
  svg .node.working rect.box{animation:glow 2.2s ease-in-out infinite}
  @keyframes glow{0%,100%{filter:drop-shadow(0 0 2px rgba(63,125,90,.35))}50%{filter:drop-shadow(0 0 9px rgba(63,125,90,.75))}}
}
"""

SCRIPT = r"""
(function(){
'use strict';
var NS='http://www.w3.org/2000/svg';
var W=184,H=70,GAP=44,ROW=84,PAD=24,TW=164,TH=62;
var COLS=['You','How requests arrive','Router','Second mates','Interns at work','Projects','Where results show'];
var KIND={captain:'You',channel:'How a request arrives',first:'The first mate',mate:'Second mate',intern:'Intern',
  project:'Project',tool:'Toolbox',step:'Delivery lane',path:'Delivery lane: another way',output:'Where results show'};
var data=null,pos={},scale=null,selected=null,tourAt=-1,tourTimer=null;
var stage=document.getElementById('stage'),svg=document.getElementById('map');
function el(tag,attrs,parent){var e=document.createElementNS(NS,tag);for(var k in attrs)e.setAttribute(k,attrs[k]);if(parent)parent.appendChild(e);return e;}
function txt(tag,attrs,text,parent){var e=el(tag,attrs,parent);e.textContent=text;return e;}
function fit(s,n){return s.length>n?s.slice(0,n-1).trim()+'\u2026':s;}
function wrap(s,n,max){var words=String(s).split(/\s+/),lines=[],cur='';
  words.forEach(function(w){if(!cur)cur=w;else if((cur+' '+w).length<=n)cur+=' '+w;else{lines.push(cur);cur=w;}});
  if(cur)lines.push(cur);if(lines.length>max){lines=lines.slice(0,max);lines[max-1]=fit(lines[max-1]+' \u2026',n);}
  return lines.map(function(l){return fit(l,n);});}
function sub(n){
  if(n.status==='unreadable')return 'could not read';
  if(n.kind==='intern'||n.kind==='mate'||n.kind==='first')return n.card.now;
  if(n.kind==='step'){var h=(n.here||[]).length;return h?(h+' here now'):'';}
  if(n.kind==='tool'||n.kind==='output'||n.kind==='channel')return n.card.now;
  return n.card.now;
}
function layout(d){
  pos={};var by={};d.nodes.forEach(function(n){by[n.id]=n;});
  var x=function(c){return PAD+c*(W+GAP);};
  var groups=[];d.nodes.forEach(function(n){if(n.kind==='mate')groups.push(n.group);});groups.push('main');
  var y=PAD+30,rows={};
  groups.forEach(function(g){
    var m=d.nodes.filter(function(n){return n.kind==='mate'&&n.group===g;});
    var i=d.nodes.filter(function(n){return n.kind==='intern'&&n.group===g;});
    var p=d.nodes.filter(function(n){return n.kind==='project'&&n.group===g;});
    var r=Math.max(1,m.length,i.length,p.length);rows[g]={y:y,r:r};
    m.forEach(function(n,k){pos[n.id]={x:x(3),y:y+k*ROW,w:W,h:H};});
    i.forEach(function(n,k){pos[n.id]={x:x(4),y:y+k*ROW,w:W,h:H};});
    p.forEach(function(n,k){pos[n.id]={x:x(5),y:y+k*ROW,w:W,h:H};});
    y+=r*ROW+14;
  });
  var mainTop=PAD+30,mainBottom=Math.max(y,mainTop+4*ROW);
  function stack(list,col){var total=list.length*ROW-(ROW-H);var y0=mainTop+Math.max(0,(mainBottom-mainTop-total)/2);
    list.forEach(function(n,k){pos[n.id]={x:x(col),y:y0+k*ROW,w:W,h:H};});}
  stack(d.nodes.filter(function(n){return n.kind==='captain';}),0);
  stack(d.nodes.filter(function(n){return n.kind==='channel';}),1);
  stack(d.nodes.filter(function(n){return n.kind==='first';}),2);
  stack(d.nodes.filter(function(n){return n.kind==='output';}),6);
  var width=x(7)-GAP+PAD;
  var tools=d.nodes.filter(function(n){return n.kind==='tool';});
  var per=Math.max(1,Math.floor((width-2*PAD+12)/(TW+12)));
  var ty=mainBottom+48;
  tools.forEach(function(n,k){pos[n.id]={x:PAD+(k%per)*(TW+12),y:ty+Math.floor(k/per)*(TH+12),w:TW,h:TH};});
  var toolsBottom=ty+Math.ceil(tools.length/per)*(TH+12);
  var lane=d.lane.map(function(id){return by[id];}).filter(Boolean);
  var lw=Math.min(W,Math.floor((width-2*PAD-(lane.length-1)*18)/Math.max(1,lane.length)));
  var ly=toolsBottom+56;
  lane.forEach(function(n,k){pos[n.id]={x:PAD+k*(lw+18),y:ly,w:lw,h:H};});
  var sy=ly+H+22;
  d.side.forEach(function(id,k){pos[id]={x:PAD+k*(W+18),y:sy,w:W,h:H};});
  var height=sy+(d.side.length?H:0)+PAD+6;
  return {width:width,height:height,mainTop:mainTop,mainBottom:mainBottom,ty:ty,toolsBottom:toolsBottom,ly:ly,rows:rows,x:x};
}
function curve(a,b){
  var x1=a.x+a.w,y1=a.y+a.h/2,x2=b.x,y2=b.y+b.h/2;
  if(b.x<=a.x){x1=a.x+a.w/2;y1=a.y+a.h;x2=b.x+b.w/2;y2=b.y;var my=(y1+y2)/2;return 'M'+x1+','+y1+' C'+x1+','+my+' '+x2+','+my+' '+x2+','+y2;}
  var mx=(x1+x2)/2;return 'M'+x1+','+y1+' C'+mx+','+y1+' '+mx+','+y2+' '+x2+','+y2;
}
function draw(){
  var d=data,L=layout(d);svg.innerHTML='';
  svg.setAttribute('viewBox','0 0 '+L.width+' '+L.height);
  var bands=el('g',{},svg);
  el('rect',{class:'band',x:8,y:8,width:L.width-16,height:L.mainBottom-2,rx:14},bands);
  txt('text',{class:'band-label',x:PAD,y:PAD+2},'The crew',bands);
  COLS.forEach(function(c,i){txt('text',{class:'col-label',x:L.x(i),y:PAD+20},c,bands);});
  el('rect',{class:'band',x:8,y:L.ty-30,width:L.width-16,height:L.toolsBottom-L.ty+34,rx:14},bands);
  txt('text',{class:'band-label',x:PAD,y:L.ty-12},d.first_mate+'\u2019s toolbox',bands);
  el('rect',{class:'band',x:8,y:L.ly-34,width:L.width-16,height:L.height-L.ly+26,rx:14},bands);
  txt('text',{class:'band-label',x:PAD,y:L.ly-14},'Delivery lane: how a change reaches the project',bands);
  var fmPos=pos['fm'];
  if(fmPos){el('path',{class:'edge owns',d:'M'+(fmPos.x+fmPos.w/2)+','+(fmPos.y+fmPos.h)+' L'+(fmPos.x+fmPos.w/2)+','+(L.ty-30)},bands);}
  var zone=d.nodes.filter(function(n){return n.zone_here&&pos[n.id];});
  if(zone.length){var a=pos[zone[0].id],b=pos[zone[zone.length-1].id];
    el('rect',{class:'zone',x:a.x-6,y:a.y-6,width:b.x+b.w-a.x+12,height:a.h+12,rx:12},bands);}
  var eg=el('g',{},svg);
  d.edges.forEach(function(e){var a=pos[e.from],b=pos[e.to];if(!a||!b)return;
    el('path',{class:'edge '+e.kind+(e.live?' live':''),d:curve(a,b)},eg);});
  var ng=el('g',{},svg);
  d.nodes.forEach(function(n){
    var p=pos[n.id];if(!p)return;
    var g=el('g',{class:'node '+n.status+(selected===n.id?' selected':''),transform:'translate('+p.x+','+p.y+')',tabindex:0,role:'button','data-id':n.id},ng);
    g.setAttribute('aria-label',n.label+'. '+(n.card.now||''));
    el('rect',{class:'box',width:p.w,height:p.h,rx:10},g);
    el('rect',{width:5,height:p.h-14,x:0,y:7,rx:2.5,fill:n.color},g);
    txt('text',{class:'icon',x:13,y:p.h/2+6},n.icon||'',g);
    var lines=wrap(n.label,Math.floor((p.w-46)/7.3),2),top=lines.length>1?p.h/2-12:p.h/2-4;
    lines.forEach(function(l,k){txt('text',{class:'label',x:38,y:top+k*15},l,g);});
    txt('text',{class:'sub',x:38,y:top+lines.length*15+2},fit(sub(n)||'',Math.floor((p.w-44)/6.1)),g);
    var here=(n.here||[]).length;
    if(here){el('circle',{cx:p.w-10,cy:10,r:9,fill:'#3f7d5a'},g);txt('text',{class:'badge',x:p.w-10,y:14,'text-anchor':'middle'},String(here),g);}
    g.addEventListener('click',function(){open(n.id);});
    g.addEventListener('keydown',function(ev){if(ev.key==='Enter'||ev.key===' '){ev.preventDefault();open(n.id);}});
  });
  el('circle',{class:'traveller',r:8,cx:-50,cy:-50,id:'traveller'},svg);
  applyZoom(L);
}
var zoomLevel=null;
function applyZoom(L){
  L=L||{width:+svg.getAttribute('viewBox').split(' ')[2],height:+svg.getAttribute('viewBox').split(' ')[3]};
  var fitScale=Math.min(1.25,(stage.clientWidth-4)/L.width);
  var s=zoomLevel===null?Math.max(fitScale,0.62):zoomLevel;
  svg.setAttribute('width',Math.round(L.width*s));svg.setAttribute('height',Math.round(L.height*s));
}
function zoom(f){var vb=svg.getAttribute('viewBox').split(' ');var cur=(+svg.getAttribute('width'))/(+vb[2]);
  zoomLevel=f===0?null:Math.max(0.35,Math.min(2.2,cur*f));applyZoom();}
function row(dl,k,v){if(!v)return;var dt=document.createElement('dt');dt.textContent=k;var dd=document.createElement('dd');dd.textContent=v;dl.appendChild(dt);dl.appendChild(dd);}
function open(id){
  var n=data.nodes.filter(function(x){return x.id===id;})[0];if(!n)return;
  selected=id;draw();
  var s=document.getElementById('sheet');var b=document.getElementById('sheet-body');b.innerHTML='';
  var k=document.createElement('div');k.className='kind';k.textContent=KIND[n.kind]||'';b.appendChild(k);
  var h=document.createElement('h2');h.textContent=n.label;b.appendChild(h);
  var dl=document.createElement('dl');b.appendChild(dl);
  row(dl,'What it is',n.card.what);row(dl,'What it does in our workflow',n.card.role);
  row(dl,'Who uses it',n.card.users);row(dl,'What it is doing now',n.card.now);
  var list=(n.here||[]).concat(n.zone_here||[]);
  if(list.length){var dt=document.createElement('dt');dt.textContent='Interns at this step';dl.appendChild(dt);
    var ul=document.createElement('ul');list.forEach(function(x){var li=document.createElement('li');li.textContent=x.label+(x.working?' (working)':'');ul.appendChild(li);});dl.appendChild(ul);}
  if(n.items){[['Ones you can start yourself',true],[data.first_mate+' opens these on its own',false]].forEach(function(p){
    var items=n.items.filter(function(i){return i.yours===p[1];});if(!items.length)return;
    var dt=document.createElement('dt');dt.textContent=p[0];dl.appendChild(dt);var ul=document.createElement('ul');
    items.forEach(function(i){var li=document.createElement('li');var bb=document.createElement('b');bb.textContent=(p[1]?'/':'')+i.name;li.appendChild(bb);li.appendChild(document.createTextNode(': '+i.text));ul.appendChild(li);});dl.appendChild(ul);});}
  row(dl,'Read from',n.card.source);
  s.classList.add('open');
}
function closeSheet(){document.getElementById('sheet').classList.remove('open');selected=null;draw();}
function centre(id){var p=pos[id];return p?{x:p.x+p.w-12,y:p.y}:null;}
function scrollTo(id){var g=svg.querySelector('[data-id="'+CSS.escape(id)+'"]');
  if(g&&g.scrollIntoView)g.scrollIntoView({block:'center',inline:'center',behavior:'smooth'});}
function showHop(i){
  var t=data.tour;if(!t.length)return;tourAt=Math.max(0,Math.min(t.length-1,i));
  document.querySelectorAll('.node.tour').forEach(function(g){g.classList.remove('tour');});
  var hop=t[tourAt],g=svg.querySelector('[data-id="'+CSS.escape(hop.node)+'"]');if(g)g.classList.add('tour');
  document.getElementById('tour-text').textContent=hop.text;
  document.getElementById('tour-count').textContent='Step '+(tourAt+1)+' of '+t.length;
  var dot=document.getElementById('traveller'),to=centre(hop.node),from=tourAt>0?centre(t[tourAt-1].node):to;
  if(dot&&to&&from){var start=null;var reduce=window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    function stepAnim(ts){if(start===null)start=ts;var k=reduce?1:Math.min(1,(ts-start)/700);
      dot.setAttribute('cx',from.x+(to.x-from.x)*k);dot.setAttribute('cy',from.y+(to.y-from.y)*k);if(k<1)requestAnimationFrame(stepAnim);}
    requestAnimationFrame(stepAnim);}
  scrollTo(hop.node);
}
function tour(on){var bar=document.getElementById('tourbar');clearInterval(tourTimer);tourTimer=null;
  document.body.classList.toggle('touring',!!on);
  if(!on){bar.classList.remove('open');tourAt=-1;document.getElementById('play').textContent='Play';draw();return;}
  bar.classList.add('open');showHop(0);}
function play(){var b=document.getElementById('play');if(tourTimer){clearInterval(tourTimer);tourTimer=null;b.textContent='Play';return;}
  b.textContent='Pause';tourTimer=setInterval(function(){if(tourAt>=data.tour.length-1){clearInterval(tourTimer);tourTimer=null;b.textContent='Play';return;}showHop(tourAt+1);},4200);}
var baseline;
function changes(){
  var key='systemMap.seen',now={};data.tracked.forEach(function(t){now[t.key]=t.label;});
  if(baseline===undefined){baseline=null;try{baseline=JSON.parse(localStorage.getItem(key)||'null');}catch(e){baseline=null;}}
  var box=document.getElementById('changed');box.innerHTML='';
  var lead=document.createElement('b');lead.textContent='What changed';box.appendChild(lead);
  if(!baseline){box.appendChild(document.createTextNode('This is your first look from this device: '+Object.keys(now).length+' parts on the map. New and removed parts will show here next time.'));}
  else{var added=Object.keys(now).filter(function(k){return !(k in baseline.nodes);});
    var gone=Object.keys(baseline.nodes).filter(function(k){return !(k in now);});
    var when=document.createElement('span');when.textContent='since you last looked ('+new Date(baseline.at).toLocaleString([], {weekday:'short',hour:'numeric',minute:'2-digit'})+'):';box.appendChild(when);
    if(!added.length&&!gone.length){box.appendChild(document.createTextNode('nothing added or removed.'));}
    added.forEach(function(k){var c=document.createElement('span');c.className='chip add';c.textContent='+ '+now[k];box.appendChild(c);});
    gone.forEach(function(k){var c=document.createElement('span');c.className='chip gone';c.textContent='\u2212 '+baseline.nodes[k];box.appendChild(c);});}
  try{localStorage.setItem(key,JSON.stringify({at:Date.now(),nodes:now}));}catch(e){}
}
function notices(){var n=document.getElementById('notices');n.innerHTML='';(data.notices||[]).forEach(function(t){var d=document.createElement('div');d.className='notice';d.textContent=t;n.appendChild(d);});}
function load(){
  fetch('system-map.json',{cache:'no-store'}).then(function(r){if(!r.ok)throw new Error(r.status);return r.json();}).then(function(d){
    data=d;document.getElementById('stamp').textContent=d.stamp;draw();changes();notices();
    if(tourAt>=0)showHop(tourAt);
    if(selected){var still=d.nodes.some(function(n){return n.id===selected;});if(still)open(selected);else closeSheet();}
  }).catch(function(){document.getElementById('stamp').textContent='could not reach the map; trying again in a minute';});
}
document.getElementById('tour-btn').addEventListener('click',function(){tour(true);});
document.getElementById('tour-close').addEventListener('click',function(){tour(false);});
document.getElementById('prev').addEventListener('click',function(){showHop(tourAt-1);});
document.getElementById('next').addEventListener('click',function(){showHop(tourAt+1);});
document.getElementById('play').addEventListener('click',play);
document.getElementById('sheet-close').addEventListener('click',closeSheet);
document.getElementById('zoom-in').addEventListener('click',function(){zoom(1.2);});
document.getElementById('zoom-out').addEventListener('click',function(){zoom(1/1.2);});
document.getElementById('zoom-fit').addEventListener('click',function(){zoom(0);});
window.addEventListener('resize',function(){if(data)applyZoom();});
load();setInterval(load,REFRESH_MS);
})();
"""

PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>System Map</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Archivo:wght@400;500;600;700&family=Crimson+Pro:ital,wght@0,400;0,600;1,400&display=swap">
<style>%(style)s</style>
</head>
<body>
<div class="wrap">
  <header class="top">
    <div class="brand">
      <h1>System Map</h1>
      <span class="sub">how the whole crew works, drawn fresh from the records</span>
    </div>
    <div class="meta"><b id="stamp">loading</b><br>updates every minute; tap anything to learn what it does</div>
  </header>
  <div class="tools">
    <button class="primary" id="tour-btn" type="button">How a request travels</button>
    <a class="btn" href="./">Back to the Bridge</a>
    <div class="zoom">
      <button id="zoom-out" type="button" aria-label="Zoom out">&minus;</button>
      <button id="zoom-fit" type="button">Fit</button>
      <button id="zoom-in" type="button" aria-label="Zoom in">+</button>
    </div>
  </div>
  <div id="notices"></div>
  <div class="changed" id="changed" aria-live="polite"><b>What changed</b></div>
  <div class="stage" id="stage"><svg class="map" id="map" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="The system map"></svg></div>
  <div class="legend">
    <span><span class="dot live"></span>working right now</span>
    <span><span class="dot idle"></span>standing by</span>
    <span>dashed box: could not read its source</span>
    <span>green moving line: work flowing now</span>
  </div>
  <footer>
    <span>Read only. Nothing here changes anything.</span>
    <span>Private: served on this Mac, reachable only over your Tailscale network.</span>
  </footer>
</div>
<div class="sheet" id="sheet" role="dialog" aria-modal="false"><div class="inner">
  <button class="close" id="sheet-close" type="button">Close</button>
  <div id="sheet-body"></div>
</div></div>
<div class="tourbar" id="tourbar" role="region" aria-label="How a request travels">
  <button id="prev" type="button" aria-label="Back">&lsaquo;</button>
  <p><small id="tour-count"></small><span id="tour-text"></span></p>
  <button id="play" type="button">Play</button>
  <button id="next" type="button" aria-label="Next">&rsaquo;</button>
  <button id="tour-close" type="button" aria-label="Close the tour">&times;</button>
</div>
<script>%(script)s</script>
</body>
</html>
"""


def page():
    """The page: static, it fetches system-map.json and draws it."""
    return PAGE % {"style": STYLE, "script": SCRIPT.replace("REFRESH_MS", str(REFRESH * 1000))}


class Cache:
    """One map build shared by concurrent requests, reused for `reuse` seconds."""

    def __init__(self, home, config_dir, reuse):
        self.home, self.config_dir, self.reuse = home, config_dir, reuse
        self.lock = threading.Lock()
        self.body, self.at = None, 0.0

    def get(self):
        with self.lock:
            if self.body is None or time.monotonic() - self.at > self.reuse:
                try:
                    body = json.dumps(build(self.home, self.config_dir))
                except Exception:  # noqa: BLE001 - the page says it could not read, never a traceback
                    return None
                self.body, self.at = body, time.monotonic()
            return self.body


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(prog="fm_system_map.py")
    ap.add_argument("command", choices=["json", "page"])
    ap.add_argument("--home", required=True)
    ap.add_argument("--config-dir", required=True)
    args = ap.parse_args(argv)
    if args.command == "page":
        sys.stdout.write(page())
        return 0
    print(json.dumps(build(args.home, args.config_dir), indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
