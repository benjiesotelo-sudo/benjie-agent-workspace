#!/usr/bin/env python3
"""fm_system_map.py - the System Map: the whole crew and how work flows, drawn live.

The Bridge (bin/fm_bridge.py) serves it at /system-map (the page) and
/system-map.json (the map), and bin/fm-bridge.sh owns the command surface and
the address. This module owns what the map reads, which nodes and lines it
draws, the guided tour, and the page that draws them in the browser.
Mission Control's Docs view reuses important_links().

THE SHAPE. Top to bottom, like an automation graph: the captain and every way
work arrives or wakes the crew; the first mate, with where results show beside
it; the second mates side by side, each with its own kit hanging beneath it
(its model, its memory, its projects, the tools only it uses) and its helpers
at work; the shared toolbox, each tool drawn once; the delivery lane.
A tool used by two or more agents is shared; its lines to the agents that use
it are drawn only while one of them, or the tool, is picked, so the map never
turns into a tangle. A tool only one agent uses hangs under that agent.

GENERATED, NEVER HAND-DRAWN. Every node comes from a record, a setting or a
tool read at build time, and each caption comes from the node's own source;
what cannot be read says "could not read", and nothing is invented.
  Ways in       chat with the first mate; Termius on the iPad (this Mac
                answering secure shell on port 22); quick notes (once
                state/inbox exists); public mentions (only while the Relay's
                generated poll state/x-watch.check.sh exists).
  Wake-ups      the Claude Code hooks in the home's .claude/settings.json and
                settings.local.json, one node per event, each naming the bin/
                scripts it runs by their own header line; the watcher (its
                heartbeat state/.last-watcher-beat and its registered checks
                state/*.check.sh); GitHub results (the watched pull requests,
                state/*.pr-poll); every LaunchAgent (FM_BRIDGE_AGENT_DIR, else
                ~/Library/LaunchAgents) whose label starts com.firstmate. or
                whose program is in this home, this code or a known tool,
                drawn as a schedule when it has a start interval; and every
                crontab line that runs this home's or this code's scripts.
  The first mate  named by config/mission-control.json first_mate_name,
                captioned by the first sentence of AGENTS.md section 1; its
                model is the agent Herdr reports in the home's window.
  Second mates  data/secondmates.md through bin/fm_bridge.py collect(), named
                the way Mission Control names them; model from the mate's
                recorded harness; memory from the pages in its home's data/.
  Helpers       every live task in this home and each local mate home, and
                every agent window with no record, from Mission Control's
                build_crew(), so the map and the office agree on who works.
  Projects      data/projects.md with Mission Control's display names and
                colours, hanging under the mate that owns them, else the first
                mate; the bracketed posture says how their work ships.
  Tools         the first mate uses every CLI in CLI_TOOLS found on PATH, every
                tool in config/watched-tools.json, Controls (its merge switch
                from bin/fm_merge_switch.py read()) and the playbooks in the
                home's .agents/skills. Every local second mate is a firstmate
                home too, so it uses the backlog tool, Herdr and the
                playbooks, plus GitHub when one of its projects lives there
                and no-mistakes when one ships through it. Each agent also
                uses its projects' stack, read from the project clones
                (package.json dependencies, Python imports, requirements,
                vercel.json, .github/workflows, a Dockerfile, headless Chrome
                in its scripts) and the services its charter names
                (data/<mate>/brief.md), each matched against STACK.
  Delivery lane "build", the step names `no-mistakes axi logs --help` prints,
                then "merge", worded by the merge switch and the +yolo
                projects; side paths only for postures some project uses.
  Results       OUTPUTS, each present when its script is in bin/.
Command reads (versions, help lines, steps, SSH, Drive remotes) are cached
for PROBE_TTL seconds; the records are read on every build.

LIVE. A working agent glows, lines carrying work move, each helper knows its
delivery step from the snapshot's current state (a parked gate names its
step; "ci running" is ci; green checks wait at merge; a run still validating
lights the checks as a group), and the page fetches the map every REFRESH
seconds. The Bridge answers from the last finished map and rebuilds it in the
background (Cache), so a slow build never holds a request; a map older than
the reuse window comes marked stale, and the page draws it as not yet live,
keeps it out of What changed, and fetches again in a few seconds; one kept
because the latest read failed comes marked failed, and the page says so and
tries again at the next minute. When a fetch fails
the page names the step that failed: reaching the Bridge, the Bridge's own
answer, reading the data, or drawing it.

ICONS. Real products carry their Simple Icons logo and concepts a Lucide line
icon, both fetched by the page from the pinned packages on cdn.jsdelivr.net
and drawn in one ink colour; only path and shape elements are copied in.

READ ONLY AND PRIVATE. Nothing here writes a file or changes anything. Every
shown string in the map passes scrub(), which removes file paths, web links,
email addresses and long token-like strings; the identifiers the page joins on
(_IDS) are left whole so two nodes never collapse into one; hook and LaunchAgent commands are never
shown, only the event and the scripts' own descriptions; .env and credentials
are never read.

Commands: `json` prints the map and `page` prints the page; each takes --home
and the Bridge's --config-dir like bin/fm_bridge.py.
"""

import json
import os
import plistlib
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
SIMPLE_ICONS = "https://cdn.jsdelivr.net/npm/simple-icons@16.33.0/icons/"
LUCIDE = "https://cdn.jsdelivr.net/npm/lucide-static@1.48.0/icons/"

HARNESS_NAMES = {"claude": "Claude Code", "codex": "Codex", "opencode": "OpenCode", "pi": "Pi",
                 "pi-signed": "Pi", "grok": "Grok", "kimi": "Kimi", "cursor": "Cursor", "muse": "Muse"}
HARNESS_ICONS = {"claude": "brand:claude"}
BACKEND_NAMES = {"tmux": "tmux", "herdr": "Herdr", "zellij": "Zellij", "orca": "Orca", "cmux": "cmux"}

# The first mate's command-line tools: (key, label, command, icon, what it does in our workflow).
CLI_TOOLS = (
    ("github", "GitHub CLI", "gh", "brand:github",
     "Opens pull requests, reads their checks and merges them on GitHub."),
    ("no-mistakes", "no-mistakes", "no-mistakes", "line:shield-check",
     "Runs the automatic checks on every change before it reaches GitHub: the delivery lane at the bottom."),
    ("herdr", "Herdr", "herdr", "line:app-window",
     "Holds every agent's window, so the first mate can start, watch and talk to them."),
    ("tasks", "Backlog tool", "tasks-axi", "line:list-checks",
     "Keeps each to-do list: what is queued, in flight, waiting on you and done."),
    ("quota", "Quota checker", "quota-axi", "line:gauge",
     "Checks how much AI usage is left before the first mate picks who does a job."),
    ("rclone", "rclone", "rclone", "brand:rclone", "Copies finished files to and from your Google Drive."),
    ("tailscale", "Tailscale", "tailscale", "brand:tailscale",
     "The private network that lets your iPad reach this Mac, and keeps everyone else out."),
    ("browser", "Chrome helper", "chrome-devtools-axi", "brand:googlechrome",
     "Lets an agent open and check web pages in Chrome."),
    ("lavish", "Review pages", "lavish-axi", "line:scan-eye", "Builds visual pages for you to review and comment on."),
)

# A project's stack: key -> (label, icon, what it does in that project).
STACK = {
    "node": ("Node.js", "brand:nodedotjs", "Runs the app's code and its build scripts."),
    "nextjs": ("Next.js", "brand:nextdotjs", "The framework the web app is built on."),
    "react": ("React", "brand:react", "Draws the app's screens."),
    "typescript": ("TypeScript", "brand:typescript", "The language the app is written in, with checks that catch slips."),
    "vitest": ("Vitest", "brand:vitest", "Runs the app's automatic tests."),
    "jest": ("Jest", "brand:jest", "Runs the app's automatic tests."),
    "neon": ("Neon", "brand:neon", "The online database where the app keeps its records."),
    "postgres": ("PostgreSQL", "brand:postgresql", "The kind of database the app keeps its records in."),
    "pglite": ("PGlite", "brand:postgresql", "A small built-in database for trying the app on this Mac and in tests."),
    "supabase": ("Supabase", "brand:supabase", "Online database and sign-in service for the app."),
    "prisma": ("Prisma", "brand:prisma", "Connects the app's code to its database."),
    "tailwind": ("Tailwind CSS", "brand:tailwindcss", "Styles the app's screens."),
    "vite": ("Vite", "brand:vite", "Builds and serves the app while it is being made."),
    "vercel": ("Vercel", "brand:vercel", "Hosts the web app on the internet."),
    "resend": ("Resend", "brand:resend", "Sends the app's emails."),
    "excel": ("Spreadsheets", "line:file-spreadsheet", "Reads and writes Excel spreadsheet files."),
    "python": ("Python", "brand:python", "Runs the scripts that build the project's files."),
    "matplotlib": ("Matplotlib", "line:chart-column", "Draws the charts."),
    "pptx": ("Slide decks", "line:presentation", "Builds the PowerPoint slide decks."),
    "docx": ("Word documents", "line:file-text", "Builds the Word documents."),
    "pillow": ("Pillow", "line:image", "Prepares the pictures."),
    "pandas": ("pandas", "brand:pandas", "Works through tables of data."),
    "numpy": ("NumPy", "brand:numpy", "Does the number crunching."),
    "chrome": ("Chrome", "brand:googlechrome", "Turns pages into PDFs and pictures without opening a window."),
    "actions": ("GitHub Actions", "brand:githubactions", "Runs the project's checks on GitHub's machines."),
    "docker": ("Docker", "brand:docker", "Packs the app into a container that runs anywhere."),
    "drive": ("Google Drive", "brand:googledrive", "Where its files are kept for you."),
    "slides": ("Google Slides", "brand:googleslides", "Where its decks are shared."),
    "sheets": ("Google Sheets", "brand:googlesheets", "Where its spreadsheets are shared."),
    "gmail": ("Gmail", "brand:gmail", "Sends or reads its email."),
    "pages": ("GitHub Pages", "brand:githubpages", "Publishes its web pages from GitHub."),
}
JS_DEPS = {"next": "nextjs", "react": "react", "typescript": "typescript", "vitest": "vitest", "jest": "jest",
           "@neondatabase/serverless": "neon", "pg": "postgres", "postgres": "postgres",
           "@electric-sql/pglite": "pglite", "@supabase/supabase-js": "supabase", "prisma": "prisma",
           "@prisma/client": "prisma", "tailwindcss": "tailwind", "vite": "vite", "vercel": "vercel",
           "exceljs": "excel", "xlsx": "excel", "resend": "resend"}
PY_MODULES = {"matplotlib": "matplotlib", "pptx": "pptx", "docx": "docx", "PIL": "pillow",
              "xlsxwriter": "excel", "openpyxl": "excel", "pandas": "pandas", "numpy": "numpy"}
PY_PACKAGES = {"matplotlib": "matplotlib", "python-pptx": "pptx", "python-docx": "docx", "pillow": "pillow",
               "xlsxwriter": "excel", "openpyxl": "excel", "pandas": "pandas", "numpy": "numpy"}
CHARTER_NAMES = ((r"\bVercel\b", "vercel"), (r"\bNeon\b", "neon"), (r"\bSupabase\b", "supabase"),
                 (r"\bGoogle Drive\b", "drive"), (r"\bGoogle Slides\b", "slides"),
                 (r"\bGoogle Sheets\b", "sheets"), (r"\bGmail\b", "gmail"), (r"\bPostgres(?:QL)?\b", "postgres"),
                 (r"\bGitHub Pages\b", "pages"), (r"\bResend\b", "resend"))

# Where results show: (key, label, script in bin/, icon, what it does, who uses it).
OUTPUTS = (
    ("mission-control", "Mission Control", "fm-mission-control.sh", "line:monitor",
     "The animated office on this Mac: who is working, the board, the calendar and the health checks.",
     "You, on this Mac or through Termius"),
    ("public-page", "Public page", "fm-mission-control-web.sh", "line:globe",
     "A public snapshot of the office for anyone to see, with private details left out.",
     "Anyone you share the link with"),
    ("bridge", "The Bridge", "fm-bridge.sh", "line:layout-dashboard",
     "The private web page this map lives on: every project on one page, on your iPad.", "You, from the iPad"),
    ("drive", "Google Drive", None, "brand:googledrive", "Where finished documents land for you.", "You"),
    ("github", "GitHub", None, "brand:github", "Where each project's files and pull requests live.",
     "You, to read and approve pull requests"),
)

HOOK_WORDS = {  # Claude Code hook event -> (label, when it runs)
    "SessionStart": ("Session start", "when an agent's session opens, so it reads its records before anything else"),
    "Stop": ("Turn end", "each time an agent finishes a turn, so no work is left unwatched"),
    "PreToolUse": ("Before each action", "before an agent uses a tool, to stop unsafe moves"),
    "PostToolUse": ("After each action", "after an agent uses a tool"),
    "UserPromptSubmit": ("Your message", "when a message arrives, before the agent reads it"),
    "SubagentStop": ("Helper finished", "when a sub-agent finishes"),
    "Notification": ("Notification", "when the agent raises a notification"),
    "PreCompact": ("Before tidying memory", "before the agent condenses its conversation"),
}

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


_IDS = frozenset({"id", "from", "to", "owner", "users_ids", "lane", "side", "agents", "node", "key", "step",
                  "project", "zone"})


def _scrub_all(value, secrets):
    if isinstance(value, dict):
        return {k: v if k in _IDS else _scrub_all(v, secrets) for k, v in value.items()}
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
    """A script's own description: header line 2 "# <name> - <text>", else the first sentence of its opening comment."""
    text = _read(path)
    if text is None:
        return None
    lines = text.splitlines()
    for line in lines[1:4]:
        m = re.match(r"^(?:#|\"\"\")\s*[\w.-]+\s+-\s+(.+)$", line.strip())
        if m:
            return _cap(m.group(1).strip().rstrip(".") + ".")
    para = []
    for line in lines[1:12]:
        if not line.startswith("#") or not line[1:].strip():
            if para:
                break
            continue
        para.append(line[1:].strip())
    return _cap(_sentence(" ".join(para), 200)) if para else None


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
# What each agent uses, found on disk
# ---------------------------------------------------------------------------

_SKIP_DIRS = {"node_modules", "venv", ".venv", "__pycache__", "dist", ".next", "site-packages"}


def _walk(root, want, depth=3, limit=400):
    """Files under root whose name passes want(name), at most depth folders down."""
    out = []
    top = root.rstrip(os.sep).count(os.sep)
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [] if dirpath.count(os.sep) - top >= depth else sorted(
            d for d in dirnames if not d.startswith(".") and d not in _SKIP_DIRS)
        for name in sorted(filenames):
            if want(name):
                out.append(os.path.join(dirpath, name))
                if len(out) >= limit:
                    return out
    return out


def detect_stack(pdir):
    """{STACK key: where it was found} for one project clone, or None when there is no clone."""
    if not os.path.isdir(pdir):
        return None
    found = {}

    def add(key, where):
        found.setdefault(key, where)

    for pj in _walk(pdir, lambda n: n == "package.json", depth=2, limit=20):
        try:
            data = json.loads(_read(pj) or "")
        except ValueError:
            continue
        if not isinstance(data, dict):
            continue
        add("node", "its package list")
        for section in ("dependencies", "devDependencies"):
            deps = data.get(section) if isinstance(data.get(section), dict) else {}
            for dep in deps:
                key = JS_DEPS.get(dep) or ("vercel" if dep.startswith("@vercel/") else None)
                if key:
                    add(key, "its package list")
    for py in _walk(pdir, lambda n: n.endswith(".py")):
        text = _read(py) or ""
        add("python", "its scripts")
        for mod in re.findall(r"^\s*(?:from|import)\s+([A-Za-z_]\w*)", text, re.M):
            if mod in PY_MODULES:
                add(PY_MODULES[mod], "its scripts")
        if "headless" in text and re.search(r"chrome", text, re.I):
            add("chrome", "its scripts")
    for req in ("requirements.txt", "pyproject.toml"):
        text = _read(os.path.join(pdir, req))
        if text is None:
            continue
        add("python", "its Python package list")
        for pkg, key in PY_PACKAGES.items():
            if re.search(r"(?im)^\s*\"?%s\b" % re.escape(pkg), text):
                add(key, "its Python package list")
    if os.path.exists(os.path.join(pdir, "vercel.json")) or os.path.isdir(os.path.join(pdir, ".vercel")):
        add("vercel", "its settings files")
    try:
        if any(n.endswith((".yml", ".yaml")) for n in os.listdir(os.path.join(pdir, ".github", "workflows"))):
            add("actions", "its settings files")
    except OSError:
        pass
    if os.path.exists(os.path.join(pdir, "Dockerfile")):
        add("docker", "its settings files")
    return found


def charter_services(text):
    return [key for pattern, key in CHARTER_NAMES if re.search(pattern, text or "")]


def claude_hooks(home):
    """({event: [bin script names]}, readable) from the home's Claude Code settings."""
    events, ok = {}, True
    for name in ("settings.json", "settings.local.json"):
        text = _read(os.path.join(home, ".claude", name))
        if text is None:
            continue
        try:
            hooks = (json.loads(text) or {}).get("hooks") or {}
        except (ValueError, AttributeError):
            ok = False
            continue
        if not isinstance(hooks, dict):
            ok = False
            continue
        for event, groups in hooks.items():
            for group in groups if isinstance(groups, list) else []:
                for hook in (group or {}).get("hooks") or [] if isinstance(group, dict) else []:
                    cmd = hook.get("command") if isinstance(hook, dict) else None
                    if isinstance(cmd, str):
                        scripts = events.setdefault(event, [])
                        for s in re.findall(r"bin/([\w.-]+\.(?:sh|py))", cmd) or [""]:
                            if s not in scripts:
                                scripts.append(s)
    return events, ok


def launch_agents(home):
    """This crew's LaunchAgents: label, the bin/ script or known tool it runs, and any schedule."""
    folder = os.environ.get("FM_BRIDGE_AGENT_DIR") or os.path.expanduser("~/Library/LaunchAgents")
    try:
        names = sorted(os.listdir(folder))
    except OSError:
        return []
    commands = {c for _k, _l, c, _i, _w in CLI_TOOLS}
    out = []
    for name in names:
        if not name.endswith(".plist"):
            continue
        try:
            with open(os.path.join(folder, name), "rb") as fh:
                plist = plistlib.load(fh)
        except Exception:  # noqa: BLE001 - an unreadable plist is not this crew's
            continue
        label = plist.get("Label") if isinstance(plist, dict) else None
        if not isinstance(label, str):
            continue
        args = plist.get("ProgramArguments") or ([plist["Program"]] if plist.get("Program") else [])
        args = [a for a in args if isinstance(a, str)] if isinstance(args, list) else []
        script = next((m.group(1) for a in args for m in [re.search(r"bin/([\w.-]+\.(?:sh|py))$", a)] if m), None)
        tool = next((os.path.basename(a) for a in args if os.path.basename(a) in commands), None)
        roots = [r.rstrip("/") + "/" for r in (home, CODE_ROOT)]
        if not (label.startswith("com.firstmate.") or tool or any(a.startswith(r) for a in args for r in roots)):
            continue
        interval = plist.get("StartInterval")
        out.append({"label": label, "script": script, "tool": tool,
                    "interval": interval if isinstance(interval, int) and interval > 0 else None,
                    "calendar": bool(plist.get("StartCalendarInterval"))})
    return out


def _launchd_loaded(label):
    if not shutil.which("launchctl"):
        return None
    got = _run(["launchctl", "print", "gui/%d/%s" % (os.getuid(), label)], timeout=3)
    return None if got is None else got[0] == 0


def cron_jobs(home):
    """Crontab lines that run this home's or this code's scripts: [(schedule, [scripts])]."""
    if not shutil.which("crontab"):
        return []
    got = _run(["crontab", "-l"], timeout=3)
    if not got or got[0] != 0:
        return []
    out = []
    for line in got[1].splitlines():
        line = line.strip()
        if not line or line.startswith("#") or re.match(r"^\w+=", line):
            continue
        if not (home in line or CODE_ROOT in line or re.search(r"bin/fm[-_]", line)):
            continue
        parts = line.split()
        sched = parts[0] if parts[0].startswith("@") else " ".join(parts[:5])
        out.append((sched, re.findall(r"bin/([\w.-]+\.(?:sh|py))", line)))
    return out


def cron_words(sched):
    m = re.fullmatch(r"\*/(\d+) \* \* \* \*", sched)
    if m:
        return "every %s" % bridge._plural(int(m.group(1)), "minute")
    if re.fullmatch(r"\d+ \* \* \* \*", sched):
        return "every hour"
    m = re.fullmatch(r"(\d+) (\d+) \* \* \*", sched)
    if m:
        return "every day at %d:%02d" % (int(m.group(2)), int(m.group(1)))
    if sched == "@reboot":
        return "when this Mac starts"
    return "on a schedule"


def _interval_words(seconds):
    if seconds % 3600 == 0:
        return "every %s" % bridge._plural(seconds // 3600, "hour")
    if seconds % 60 == 0:
        return "every %s" % bridge._plural(seconds // 60, "minute")
    return "every %s" % bridge._plural(seconds, "second")


def _scripts_words(scripts):
    words = [script_caption(os.path.join(CODE_ROOT, "bin", s)) for s in scripts if s]
    words = [w for w in words if w]
    return " ".join(words) if words else None


def _memory_pages(data_dir):
    """[(title, sections)] for the memory pages in one home's data folder, or None when unreadable."""
    if not os.path.isdir(data_dir):
        return None
    pages = []
    for name, title in (("captain.md", "about you"), ("captain-shared.md", "shared with every mate"),
                        ("learnings.md", "lessons learned")):
        text = _read(os.path.join(data_dir, name))
        if text is not None:
            pages.append((title, sum(1 for lvl, _h in bridge.headings(text) if lvl == 2)))
    return pages


def _herdr_agents():
    """(agents for Mission Control's matcher, {real cwd: agent kind}), or (None, {}) when Herdr does not answer."""
    herdr = (os.environ.get("FM_MC_HERDR") or "herdr").split()
    if not shutil.which(herdr[0]):
        return None, {}
    got = _run(herdr + ["agent", "list"], timeout=5)
    if not got or got[0] != 0:
        return None, {}
    kinds = {}
    try:
        for a in (json.loads(got[1]).get("result") or {}).get("agents") or []:
            if isinstance(a, dict) and isinstance(a.get("agent"), str):
                for c in (a.get("cwd"), a.get("foreground_cwd")):
                    if c:
                        kinds.setdefault(mc._real(c), a["agent"])
    except (ValueError, AttributeError):
        pass
    return mc.parse_agents(got[1]), kinds


# ---------------------------------------------------------------------------
# Building the map
# ---------------------------------------------------------------------------

def _node(nid, kind, label, icon, what, role, users, now, source, status="idle", **extra):
    node = {"id": nid, "kind": kind, "label": label, "icon": icon, "status": status,
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


def _cli(found, key):
    """use() arguments for one of CLI_TOOLS as this Mac has it."""
    _k, label, command, icon, role = next(t for t in CLI_TOOLS if t[0] == key)
    got = found.get(command) or {}
    if not got.get("found"):
        return label, icon, COULD_NOT_READ, role, "Could not find it on this Mac.", "the tool itself", "unreadable"
    ver = got.get("version")
    return (label, icon, ("In its own words: \"%s\"" % got["help"]) if got.get("help") else "A tool on this Mac.",
            role, "Installed%s." % (", version %s" % ver if ver else ""), "the tool itself")


POSTURE_SHORT = {"no-mistakes": "full checks", "no-mistakes-prod-only": "full checks for what you see",
                 "direct-PR": "quick pull request", "local-only": "stays on this Mac"}


def build(home, config_dir, now=None, probes=None):
    """The map as a dict: nodes, edges, the agents in column order, lane, tour, and what "What changed" tracks.

    config_dir is the Bridge's settings folder, as bin/fm_bridge.py collect() takes it; the
    home's own settings (Mission Control's names, the worker runtime, the watched tools)
    are always read from the home's config folder, as Mission Control does."""
    now = now or bridge._now()
    home = os.path.realpath(home)
    bridge_config, config_dir = config_dir, os.path.join(home, "config")
    settings = mc.read_settings(config_dir)
    fm = settings["first_mate_name"]
    model = mc.with_settings(bridge.collect(home, bridge_config, now), settings)
    agents, kinds = _herdr_agents()
    herdr_ok = agents is not None
    crew = mc.build_crew(model, agents or [], home, os.environ.get("HERDR_SESSION") or "default", None, fm)
    colors = mc.project_colors(model)
    extra_tools = watched_tools(config_dir)
    probes = probes or PROBES.get([(t[2], ("--version",)) for t in CLI_TOOLS] + [(c, a) for _, c, a in extra_tools if c])
    found = probes.get("tools") or {}
    screens = running_screens() or {}
    switch = merge_switch.read(home)
    mates = model.get("mates") or []
    snaps = model.get("snapshots") or {}
    main_tasks = (snaps.get("main") or {}).get("tasks") or []
    by_key = {c["key"]: c for c in crew}
    lead = by_key["fm"]
    fm_working = lead["status"] == "work"
    nodes, edges, tracked = [], [], []

    def add(node, track=True):
        nodes.append(node)
        if track:
            tracked.append({"key": node["id"], "label": node["label"], "kind": node["kind"]})
        return node

    def edge(a, b, kind="flow", live=False):
        edges.append({"from": a, "to": b, "kind": kind, "live": bool(live)})

    def pname_of(p):
        return None if p["name"] == model["ship"] else p["name"]

    # --- ways in ------------------------------------------------------------------
    waiting = sum(1 for it in model["items"] if it["bucket"] == "waiting")
    add(_node("captain", "captain", "You", "line:user", "The captain: the one person every agent works for.",
              "Every job starts with something you ask for, and only you make the big calls.",
              "Everyone on the map works for you.", "%s waiting on you." % _cap(bridge._plural(waiting, "decision")),
              "the to-do lists", status="you", cap=bridge._plural(waiting, "decision") + " for you"), track=False)
    ssh = probes.get("ssh")
    ins = [("chat", "Chat with %s" % fm, "line:message-square", "The chat window where you type to %s." % fm,
            "Your main way in: ask for anything in plain words and %s takes it from there." % fm, "You",
            "Working now." if fm_working else "Ready for your next message.",
            "who is working, from the agent windows", "working" if fm_working else "idle", None),
           ("termius", "Termius", "brand:termius",
            "A terminal app on your iPad that opens a secure connection to this Mac.",
            "Lets you reach %s's window, and Mission Control, from anywhere on your private network." % fm,
            "You, away from the Mac",
            "This Mac is accepting secure connections." if ssh else
            "This Mac is not accepting secure connections right now.",
            "this Mac's secure shell service", "idle" if ssh else "off", "on the iPad")]
    inbox = os.path.join(home, "state", "inbox")
    if os.path.isdir(inbox):
        pending = [n for n in os.listdir(inbox) if not n.startswith(".") and n != "handled"]
        ins.append(("inbox", "Quick notes", "line:sticky-note",
                    script_caption(os.path.join(CODE_ROOT, "bin", "fm-inbox.sh")) or COULD_NOT_READ,
                    "Leave %s a note, typed or spoken, while it is busy; it reads them in order." % fm, "You",
                    "%s waiting to be read." % _cap(bridge._plural(len(pending), "note")),
                    "the inbox script's own description", "idle", bridge._plural(len(pending), "note")))
    if os.path.exists(os.path.join(home, "state", "x-watch.check.sh")):
        ins.append(("relay", "Public mentions", "line:megaphone",
                    "Mentions of %s on the public web, collected by the Relay." % fm,
                    "Lets people ask for small things in public; %s answers or turns them into jobs." % fm,
                    "People who mention %s" % fm, "Switched on for this Mac.", "the Relay setting", "idle", None))
    for cid, label, icon, what, role, users, nw, src, status, cap in ins:
        add(_node("channel:" + cid, "channel", label, icon, what, role, users, nw, src, status=status, cap=cap))
        edge("captain", "channel:" + cid, live=status == "working")
        edge("channel:" + cid, "fm", live=status == "working")

    events, hooks_ok = claude_hooks(home)
    if not hooks_ok:
        add(_node("trigger:hooks", "trigger", "Hooks", "line:webhook", COULD_NOT_READ,
                  "Small scripts the assistant runs at set moments.", fm, "Could not read the hook settings.",
                  "the assistant's hook settings", status="unreadable"))
        edge("trigger:hooks", "fm", kind="wake")
    for event, scripts in events.items():
        label, when = HOOK_WORDS.get(event, (re.sub(r"(?<!^)(?=[A-Z])", " ", event), "on the %s event" % event))
        add(_node("trigger:hook:" + event, "trigger", label, "line:webhook",
                  "A hook: the assistant runs it %s." % when,
                  _scripts_words(scripts) or "Runs a command set in the assistant's settings.",
                  "%s and every agent started in this home" % fm,
                  "Set up with %s." % bridge._plural(len(scripts), "script"), "the assistant's hook settings",
                  cap=bridge._plural(len(scripts), "script")))
        edge("trigger:hook:" + event, "fm", kind="wake")
    state = os.path.join(home, "state")
    try:
        names = sorted(os.listdir(state))
    except OSError:
        names = []
    checks = [n[:-len(".check.sh")] for n in names if n.endswith(".check.sh")]
    beat = None
    try:
        beat = time.time() - os.stat(os.path.join(state, ".last-watcher-beat")).st_mtime
    except OSError:
        pass
    add(_node("trigger:watcher", "trigger", "Watcher", "line:radar",
              "The watcher: a small loop that keeps an eye on every agent and wakes %s when something needs it." % fm,
              "Notices finished turns, stuck agents, merged pull requests and its registered checks%s." %
              (" (%s)" % ", ".join(checks) if checks else ""), fm,
              ("Awake; last heartbeat %s ago." % mc._span(beat)) if beat is not None
              else "Could not find its heartbeat.", "the watcher's heartbeat and its checks",
              status="working" if beat is not None and beat < 300 else ("idle" if beat is not None else "unreadable"),
              cap=bridge._plural(len(checks), "check")))
    edge("trigger:watcher", "fm", kind="wake", live=beat is not None and beat < 300)
    polls = [n for n in names if n.endswith(".pr-poll")]
    add(_node("trigger:ci", "trigger", "GitHub results", "brand:githubactions",
              "News from GitHub about the pull requests %s is watching." % fm,
              "Wakes %s when a pull request's checks finish or it is merged." % fm, fm,
              "Watching %s." % bridge._plural(len(polls), "pull request"), "the watched pull requests",
              cap=bridge._plural(len(polls), "pull request")))
    edge("trigger:ci", "fm", kind="wake")
    for job in launch_agents(home):
        loaded = _launchd_loaded(job["label"])
        tool_label = next((t[1] for t in CLI_TOOLS if t[2] == job["tool"]), None)
        name = (tool_label + " service" if tool_label else
                re.sub(r"^com\.(firstmate|kunchenguid)\.", "", job["label"]).split(".")[0].replace("-", " "))
        what_runs = _scripts_words([job["script"]]) if job["script"] else None
        if job["tool"] and not what_runs:
            what_runs = "Keeps %s running in the background." % job["tool"]
        timed = job["interval"] or job["calendar"]
        when = _interval_words(job["interval"]) if job["interval"] else "on a schedule" if timed else "at login"
        add(_node("trigger:launch:" + job["label"], "trigger", _cap(name) + (" (scheduled)" if timed else " at login"),
                  "line:clock" if timed else "line:power",
                  "A background job macOS starts %s%s." % (when, "" if timed else " and restarts if it stops"),
                  what_runs or COULD_NOT_READ, fm,
                  "Loaded and running." if loaded else "Not loaded right now." if loaded is False
                  else "Could not ask macOS about it.", "this Mac's login items",
                  status="idle" if loaded else "off" if loaded is False else "unknown", cap=when))
        edge("trigger:launch:" + job["label"], "fm", kind="wake")
    for i, (sched, scripts) in enumerate(cron_jobs(home)):
        when = cron_words(sched)
        add(_node("trigger:cron:%d" % i, "trigger", "Scheduled job", "line:calendar-clock",
                  "A job this Mac runs %s." % when, _scripts_words(scripts) or COULD_NOT_READ, fm,
                  "Scheduled %s." % when, "this Mac's schedule", cap=when))
        edge("trigger:cron:%d" % i, "fm", kind="wake")

    # --- the first mate and where results show --------------------------------------
    fm_kind = kinds.get(home)
    add(_node("fm", "first", fm, "line:bot", leader_sentence(home, fm) or COULD_NOT_READ,
              "Takes every request, decides who handles it, watches the work, and brings you only "
              "the decisions that need you.", "You talk to %s; %s directs the second mates and the helpers." % (fm, fm),
              _cap(lead["doing"]) + "." if herdr_ok else "Could not ask the agent windows who is working.",
              "the rule book's first section", status="working" if fm_working else
              ("idle" if herdr_ok else "unknown"), color=mc.FIRST_MATE_COLOR, cap="the first mate"))
    tools_by_key = {}

    def use(agent, key, label, icon, what, role, now_words, source, status="idle"):
        t = tools_by_key.setdefault(key, {"label": label, "icon": icon, "what": what, "roles": [],
                                          "nows": [], "sources": [], "status": status, "users": []})
        for field, value in (("roles", role), ("nows", now_words), ("sources", source)):
            if value not in t[field]:
                t[field].append(value)
        if agent not in t["users"]:
            t["users"].append(agent)

    for key, _label, _command, _icon, _role in CLI_TOOLS:
        use("fm", "tool:" + key, *_cli(found, key))
    for name, command, _args in extra_tools:
        key = "tool:watched:" + re.sub(r"[^a-z0-9-]+", "-", name.lower()).strip("-")
        got = found.get(command) or {"found": False} if command else {"found": False}
        role = "A tool this home depends on, from the watched tools list."
        if got.get("found"):
            ver = got.get("version")
            use("fm", key, name, "line:wrench",
                ("In its own words: \"%s\"" % got["help"]) if got.get("help") else "A tool on this Mac.",
                role, "Installed%s." % (", version %s" % ver if ver else ""), "the watched tools list")
        else:
            use("fm", key, name, "line:wrench", COULD_NOT_READ, role,
                "Could not find it on this Mac." if command else "Could not tell which command it is.",
                "the watched tools list", status="unreadable")
    word = {"on": "ON", "off": "OFF", "partial": "partly on"}.get(switch.get("state"))
    use("fm", "tool:controls", "Controls", "line:sliders-horizontal",
        script_caption(os.path.join(CODE_ROOT, "bin", "fm-controls.sh")) or COULD_NOT_READ,
        "Holds your merge switch: whether %s may merge green pull requests itself." % fm,
        ("The merge switch is %s%s." % (word, "; the screen is open" if screens.get("controls") else ""))
        if word else "Could not read the merge switch.", "the Controls screen and its switch",
        status="idle" if word else "unreadable")
    skills = skill_entries(home)
    playbook_words = ("Step-by-step procedures an agent follows in particular situations.",
                      "Opened when a situation comes up; the ones marked yours you can start by typing a slash "
                      "and the name.")
    if skills is None:
        playbooks = (COULD_NOT_READ, playbook_words[1], "Could not read the playbooks.", "the playbook folder",
                     "unreadable")
    else:
        playbooks = (playbook_words[0], playbook_words[1],
                     "%s, %d you can start." % (_cap(bridge._plural(len(skills), "playbook")),
                                                sum(1 for s in skills if s["yours"])),
                     "each playbook's own description", "idle")
    use("fm", "tool:playbooks", "Playbooks", "line:book-open", *playbooks)
    for s in skills or []:
        tracked.append({"key": "playbook:" + s["name"], "label": "Playbook: " + s["name"], "kind": "playbook"})

    for oid, label, script, icon, role, users in OUTPUTS:
        nid = "output:" + oid
        if script:
            cap = script_caption(os.path.join(CODE_ROOT, "bin", script))
            if cap is None:
                add(_node(nid, "output", label, icon, COULD_NOT_READ, role, users, "Not set up on this Mac yet.",
                          "its script", status="unreadable", cap="not set up"))
                edge("fm", nid, kind="shows")
                continue
            if oid == "mission-control":
                st = "working" if screens.get("mission-control") else "idle"
                nw = "Running on this Mac." if st == "working" else "Not open right now."
            elif oid == "bridge":
                st, nw = "working", "Serving this page right now."
            else:
                st, nw = "idle", "Updates on its own schedule."
            add(_node(nid, "output", label, icon, cap, role, users, nw, "its script's own description", status=st))
        elif oid == "drive":
            n = probes.get("drive")
            if n is None:
                add(_node(nid, "output", label, icon, COULD_NOT_READ, role, users,
                          "Could not ask rclone which drives are connected.", "rclone", status="unreadable"))
            else:
                add(_node(nid, "output", label, icon, "Your Google Drive, reached through rclone.", role, users,
                          "%s connected." % _cap(bridge._plural(n, "Drive account")), "rclone",
                          status="idle" if n else "off", cap=bridge._plural(n, "account")))
        else:
            repos = sum(1 for p in model["projects"] if p.get("github"))
            ok = (found.get("gh") or {}).get("found")
            add(_node(nid, "output", label, icon, "The website where the code lives.", role, users,
                      "%s with a GitHub home." % _cap(bridge._plural(repos, "project")) if ok
                      else "The GitHub tool is not on this Mac.", "the project list",
                      status="idle" if ok else "unreadable", cap=bridge._plural(repos, "project")))
        edge("fm", nid, kind="shows")

    # --- each agent's own kit: its model and its memory ---------------------------------------
    def agent_kit(aid, ahome, harness, readable, name):
        if harness:
            hname = HARNESS_NAMES.get(harness, harness)
            add(_node("model:" + aid, "kit", hname, HARNESS_ICONS.get(harness, "line:cpu"),
                      "The AI model %s thinks with: %s." % (name, hname),
                      "Reads, reasons and writes for %s, in its own session." % name, name,
                      "Answers in %s's window." % name, "the agent window's record", owner=aid, slot="model",
                      cap="model"))
        else:
            add(_node("model:" + aid, "kit", "Model", "line:cpu", COULD_NOT_READ,
                      "The AI model %s thinks with." % name, name, "Could not tell which model it runs on.",
                      "the agent window's record", status="unreadable", owner=aid, slot="model", cap="model"))
        edge(aid, "model:" + aid, kind="own")
        pages = _memory_pages(os.path.join(ahome, "data")) if readable else None
        if pages is None:
            add(_node("memory:" + aid, "kit", "Memory", "line:brain", COULD_NOT_READ,
                      "What %s remembers between conversations." % name, name, "Could not read its memory pages.",
                      "its memory pages", status="unreadable", owner=aid, slot="memory", cap="memory"))
        else:
            add(_node("memory:" + aid, "kit", "Memory", "line:brain",
                      "What %s remembers between conversations: the pages it reads at every start." % name,
                      "Keeps what it learns about you and the work, so it picks up where it left off.", name,
                      ("%s: %s." % (_cap(bridge._plural(len(pages), "page")),
                                    ", ".join("%s (%s)" % (t, bridge._plural(n, "section")) for t, n in pages)))
                      if pages else "Nothing written down yet.", "its memory pages' headings",
                      owner=aid, slot="memory", cap=bridge._plural(len(pages), "page")))
        edge(aid, "memory:" + aid, kind="own")

    agent_kit("fm", home, fm_kind, True, fm)

    # --- second mates, their kit and helpers ----------------------------------------------
    owner_of = {}
    for m in mates:
        for p in m["projects"]:
            owner_of.setdefault(p.lower(), "mate:" + m["id"])
    agent_ids = ["fm"]
    for i, m in enumerate(mates):
        aid = "mate:" + m["id"]
        agent_ids.append(aid)
        row = by_key.get(aid) or {}
        task = next((t for t in main_tasks if t.get("id") == m["id"] and t.get("kind") == "secondmate"), None)
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
        add(_node(aid, "mate", mc.mate_name(model, m["id"]), "line:bot", _cap(_sentence(m["summary"])),
                  "Owns %s, keeping its own to-do list (%s open) and its charter." % (role, team.get("open", 0)),
                  "%s sends it work for %s; it hires helpers for that work." %
                  (fm, ", ".join(mc.project_name(model, p) for p in m["projects"]) or "its area"),
                  now_words, "the second mate list", status=status, color=mc.MATE_COLORS[i % len(mc.MATE_COLORS)],
                  cap="second mate"))
        edge("fm", aid, live=status == "working")
        harness = (task or {}).get("harness") or kinds.get(mc._real(m["home"]))
        agent_kit(aid, m["home"], harness, not m["remote"], mc.mate_name(model, m["id"]))
        if not m["remote"]:
            use(aid, "tool:tasks", *_cli(found, "tasks"))
            use(aid, "tool:herdr", *_cli(found, "herdr"))
            use(aid, "tool:playbooks", "Playbooks", "line:book-open", *playbooks)
            charter = _read(os.path.join(home, "data", m["id"], "brief.md"))
            for key in charter_services(charter):
                label, icon, what = STACK[key]
                use(aid, "tool:" + key, label, icon, what,
                    "Named in %s's charter as part of its work." % mc.mate_name(model, m["id"]),
                    "Named in %s's charter." % mc.mate_name(model, m["id"]), "its charter")

    def agent_home(aid):
        if aid == "fm":
            return home
        return next(m["home"] for m in mates if "mate:" + m["id"] == aid)

    for p in model["projects"]:
        pname = pname_of(p)
        posture = p["posture"].split()
        mode = posture[0] if posture else ""
        yolo = "+yolo" in posture
        words = POSTURE_WORDS.get(mode)
        how = (_cap(words) + "." if words else "How its work ships could not be read.")
        how += (" %s may merge its green pull requests." % fm if yolo else " You approve every merge.")
        owner = owner_of.get(p["name"].lower(), "fm")
        remote = owner != "fm" and next(m for m in mates if "mate:" + m["id"] == owner)["remote"]
        counts = bridge._counts([it for it in model["items"] if it["project"] == pname])
        nid = "project:" + p["name"].lower()
        add(_node(nid, "project", mc.project_name(model, pname, card=pname is None), "line:folder",
                  _cap(_sentence(bridge._summary(p["description"]))), how,
                  "Worked on by %s." % (fm if owner == "fm" else by_key.get(owner, lead)["name"]),
                  "%d in flight, %d queued, %d waiting on you.%s" %
                  (counts.get("in_flight", 0), counts.get("queued", 0), counts.get("waiting", 0),
                   " Parked since %s." % p["parked"] if p.get("parked") else ""),
                  "the project list", status="off" if p.get("parked") else "idle",
                  color=colors.get(p["name"].lower(), mc.FIRST_MATE_COLOR), owner=owner, slot="project",
                  cap=POSTURE_SHORT.get(mode, "")))
        edge(owner, nid, kind="own")
        if remote:
            continue
        if p.get("github"):
            use(owner, "tool:github", *_cli(found, "github"))
        if mode.startswith("no-mistakes"):
            use(owner, "tool:no-mistakes", *_cli(found, "no-mistakes"))
        stack = detect_stack(os.path.join(agent_home(owner), "projects", p["name"]))
        for key, where in (stack or {}).items():
            label, icon, what = STACK[key]
            shown = mc.project_name(model, pname, card=pname is None)
            use(owner, "tool:" + key, label, icon, what, "Part of %s, found in %s." % (shown, where),
                "In use by %s." % shown, where)

    for key, t in tools_by_key.items():
        shared = len(t["users"]) > 1
        names = [fm if u == "fm" else by_key.get(u, {}).get("name") or u for u in t["users"]]
        extra = {"shared": True} if shared else {"owner": t["users"][0], "slot": "tool"}
        add(_node(key, "tool", t["label"], t["icon"], t["what"], " ".join(t["roles"]),
                  "Used by %s." % ", ".join(names), " ".join(t["nows"]), ", ".join(t["sources"]), status=t["status"],
                  users_ids=t["users"], **extra))
        for u in t["users"]:
            edge(u, key, kind="uses" if shared else "own")

    # --- helpers --------------------------------------------------------------------
    tasks_by = {}
    for hid, snap in [("main", snaps.get("main"))] + [(m["id"], snaps.get(m["id"])) for m in mates]:
        for t in (snap or {}).get("tasks") or []:
            if t.get("kind") != "secondmate" and t.get("id"):
                tasks_by["intern:%s:%s" % (hid, t["id"])] = t
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
        owner = c["lead"] if c["lead"] in agent_ids else "fm"
        working = c["status"] == "work"
        state_word = (task.get("current_state") or {}).get("state") or ""
        word = "working" if working else ("idle" if state_word == "unknown" else "between steps"
                                          if state_word == "working" else bridge.STATE_WORDS.get(state_word, "idle"))
        scout = task.get("kind") == "scout"
        if c.get("helper"):
            what = "An agent window working without a job record, such as one opened by hand."
            role = "Does whatever was asked in its window; it is not on any to-do list."
            now_words = "%s." % _cap(word if working else "idle")
            step = zone = None
        else:
            what = "A helper hired for one job: it %s." % (
                "investigates a question and writes you a report" if scout else "makes one change and ships it")
            role = ("Works in its own private copy and writes its findings up for you." if scout else
                    "Works in its own private copy of the project, then sends its change down the delivery lane.")
            if (step or zone) and not working:
                where = "at the %s" % ("checks" if zone else "%s step" % STEP_LABELS.get(step, step))
            elif step or zone:
                where = _step_phrase(step, zone)
            elif scout:
                where = "report written" if state_word == "done" else "investigating"
            elif state_word == "done":
                where = "its work is finished"
            else:
                where = "its record could not be read"
            now_words = "%s, %s." % (_cap(word), where)
        lead_name = (by_key.get(owner) or lead)["name"]
        nid = c["key"]
        pkey = "project:" + c["project"].lower() if c.get("project") else None
        add(_node(nid, "helper", c["title"] or "A one-off job", "line:hard-hat", what, role,
                  "Hired by %s, let go when the job lands." % lead_name, now_words, "the live worker records",
                  status="working" if working else "idle", owner=owner, step=step, zone=zone,
                  project=pkey if pkey and any(n["id"] == pkey for n in nodes) else None,
                  ships=not c.get("helper") and not scout), track=False)
        edge(owner, nid, live=working)
        if step or zone:
            at_step.setdefault(step or zone, []).append({"id": nid, "label": c["title"] or "A one-off job",
                                                         "working": working, "step": step})

    # --- the delivery lane ---------------------------------------------------------------
    yolo_names = [mc.project_name(model, pname_of(p)) for p in model["projects"] if "+yolo" in p["posture"].split()]
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
    if steps_read is None:
        lane_steps = ["build", "unread", "merge"]
    for s in lane_steps:
        here = at_step.get(s, []) + (at_step.get("checks", []) if s == "unread" else [])
        if s == "unread":
            add(_node("step:unread", "step", "The checks", "line:circle-help", COULD_NOT_READ,
                      "The automatic checks between the change and GitHub.", "Every change",
                      "Could not ask no-mistakes for its steps.", "no-mistakes itself", status="unreadable",
                      here=here))
            lane.append("step:unread")
            continue
        role = merge_role if s == "merge" else STEP_WORDS.get(s, "A check no-mistakes runs, named %s." % s)
        src = ("the merge switch" if s == "merge" else "how helpers start work" if s == "build"
               else "no-mistakes itself")
        icon = "line:git-merge" if s == "merge" else "line:hammer" if s == "build" else "line:check"
        add(_node("step:" + s, "step", STEP_LABELS.get(s, _cap(s.replace("-", " "))), icon,
                  role if s != "merge" else "The last step: the change joins the project.", role,
                  "Every change that ships through the full checks.",
                  ("Here now: %s." % "; ".join(h["label"] for h in here)) if here else "Nobody at this step right now.",
                  src, status="working" if any(h["working"] for h in here) else "idle", here=here,
                  check=s in CHECK_STEPS))
        lane.append("step:" + s)
    if steps_read and at_step.get("checks"):
        for n in nodes:
            if n["kind"] == "step" and n.get("check"):
                n["zone_here"] = at_step["checks"]
    first_check = next((i for i in lane if i[5:] in CHECK_STEPS or i == "step:unread"), None)
    for key, hs in at_step.items():
        for h in hs:
            target = "step:" + h["step"] if h["step"] else first_check
            if target in lane:
                edge(h["id"], target, kind="at")
    live = {n["id"] for n in nodes if n["status"] == "working"}
    for a, b in zip(lane, lane[1:]):
        edge(a, b, kind="lane", live=b in live)
    side, modes = [], {}
    for p in model["projects"]:
        modes.setdefault((p["posture"].split() or [""])[0], []).append(mc.project_name(model, pname_of(p)))
    for mode, sid, label, icon, role in (
            ("direct-PR", "quick", "Quick pull request", "line:git-pull-request",
             "Skips the full checks: the helper opens the pull request straight away, and GitHub's own checks "
             "still run."),
            ("local-only", "local", "Stays on this Mac", "line:monitor",
             "Never goes to GitHub for review: once you say yes, %s lands it on this Mac." % fm)):
        if mode in modes:
            add(_node("path:" + sid, "path", label, icon, role, role, "Used by " + ", ".join(modes[mode]) + ".",
                      "Some projects ship this way.", "the project list"))
            side.append("path:" + sid)

    out = {
        "generated": now.isoformat(timespec="seconds"),
        "stamp": now.strftime("%A %-d %B, %-I:%M %p").replace("AM", "am").replace("PM", "pm"),
        "first_mate": fm, "refresh": REFRESH, "agents": agent_ids, "nodes": nodes, "edges": edges,
        "lane": lane, "side": side, "tracked": tracked, "notices": [],
        "playbooks": skills or [],
    }
    out["tour"] = build_tour(nodes, edges, fm)
    if not herdr_ok:
        out["notices"].append("Could not ask the agent windows who is working, so nobody glows.")
    if model.get("errors"):
        out["notices"].append("Could not read the records of %s." %
                              ", ".join(mc.mate_name(model, e) for e in model["errors"]))
    secrets = [home, os.path.expanduser("~"), CODE_ROOT, config_dir, bridge_config] + [m["home"] for m in mates]
    out = _scrub_all(out, sorted({s for s in secrets if s}, key=len, reverse=True))
    out["icons"] = {"brand": SIMPLE_ICONS, "line": LUCIDE}  # the pinned icon packages, added after the scrub
    return out


def build_tour(nodes, edges, fm):
    """One request's journey, one plain sentence per hop, along nodes that exist."""
    ids = {n["id"]: n for n in nodes}
    hops = []

    def hop(nid, text):
        if nid in ids:
            hops.append({"node": nid, "text": text})

    hop("captain", "You ask for something, in plain words.")
    hop("channel:chat", "Your message arrives in %s's chat, or through Termius when you are on the iPad." % fm)
    hop("trigger:watcher", "Behind the scenes the watcher and the hooks keep %s awake and on task, "
                           "even between your messages." % fm)
    hop("fm", "%s reads it, works out which project it belongs to, and decides who should handle it." % fm)
    mates = [n for n in nodes if n["kind"] == "mate"]
    helpers = [n for n in nodes if n["kind"] == "helper" and n.get("ships")]
    busy = [m for m in mates if any(h["owner"] == m["id"] for h in helpers)]
    mate = (busy or mates or [None])[0]
    owner = mate["id"] if mate else "fm"
    boss = "The second mate" if mate else fm
    if mate:
        hop(mate["id"], "Work for %s goes to its second mate, who keeps that project's list, rules and tools." %
            mate["label"])
    model = ids.get("model:" + owner)
    if model and model["status"] != "unreadable":
        hop(model["id"], "It thinks with %s, and its memory pages remind it what it has learned." % model["label"])
    helper = next((h for h in helpers if h["owner"] == owner), None)
    if helper:
        hop(helper["id"], "%s hires a helper for this one job; it works in its own private copy." % boss)
    proj = (helper or {}).get("project") or next(
        (n["id"] for n in nodes if n["kind"] == "project" and n.get("owner") == owner), None)
    if proj:
        hop(proj, "The job is about %s: that project's files are what change." % ids[proj]["label"])
    own_tool = next((n for n in nodes if n["kind"] == "tool" and n.get("owner") == owner), None)
    if own_tool:
        hop(own_tool["id"], "Along the way it uses the project's own tools, such as %s." % own_tool["label"])
    shared = next((n for n in nodes if n["kind"] == "tool" and n.get("shared") and owner in n.get("users_ids", [])),
                  None)
    if shared:
        hop(shared["id"], "It also shares tools with the rest of the crew, such as %s." % shared["label"])
    for sid in [n["id"] for n in nodes if n["kind"] == "step"]:
        n = ids[sid]
        if sid == "step:build" and not helper:
            hop(sid, "%s hires a helper for this one job; it makes the change in its own private copy." % boss)
            continue
        hop(sid, "%s step. %s" % (n["label"], n["card"]["role"]))
    hop("output:github", "The change now lives on GitHub with the rest of the project.")
    hop("output:mission-control", "Mission Control and the Bridge show it done, and %s tells you in chat." % fm)
    return hops


def public_url(home):
    """The public page's address from config/mission-control.json public_page.repository, or None."""
    try:
        with open(os.path.join(home, "config", "mission-control.json"), encoding="utf-8") as fh:
            repo = ((json.load(fh) or {}).get("public_page") or {}).get("repository")
    except (OSError, ValueError, AttributeError):
        return None
    m = re.fullmatch(r"([A-Za-z0-9-]+)/([A-Za-z0-9._-]+)", repo or "")
    if not m:
        return None
    owner = m.group(1).lower()
    return "https://%s.github.io/" % owner + ("" if m.group(2).lower() == owner + ".github.io"
                                                else m.group(2) + "/")


def bridge_address(home):
    """The Bridge's address as bin/fm-bridge.sh start recorded it in state/bridge.addr, or None."""
    state = os.environ.get("FM_BRIDGE_STATE_DIR") or os.path.join(home, "state")
    parts = (_read(os.path.join(state, "bridge.addr")) or "").split()
    if len(parts) < 2 or not parts[1].isdigit():
        return None
    host = "[%s]" % parts[0] if ":" in parts[0] else parts[0]
    return "http://%s:%s/" % (host, parts[1])


def important_links(home):
    """[(title, address)] Mission Control pins first on its Docs view: the System Map, the Bridge, the public page."""
    out = []
    address = bridge_address(home)
    if address:
        out += [("System Map", address + "system-map"), ("The Bridge page", address)]
    public = public_url(home)
    if public:
        out.append(("Public Mission Control page", public))
    return out


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
.stage{background-color:var(--surface-2);background-image:radial-gradient(var(--line-2) 1px,transparent 1.2px);
  background-size:22px 22px;border:1px solid var(--line);border-radius:var(--radius);overflow:auto;
  -webkit-overflow-scrolling:touch;touch-action:pan-x pan-y pinch-zoom;position:relative}
svg.map{display:block}
svg .section{font:700 11.5px var(--display);letter-spacing:.09em;text-transform:uppercase;fill:var(--ink-3)}
svg .hint{font:500 11.5px var(--display);fill:var(--ink-3)}
svg .rule{stroke:var(--line-2);stroke-dasharray:2 5}
svg .edge{fill:none;stroke:var(--ink-3);stroke-opacity:.45;stroke-width:1.4}
svg .edge.own,svg .edge.wake,svg .edge.shows{stroke-dasharray:4 4}
svg .edge.uses,svg .edge.at{display:none;stroke:var(--accent);stroke-opacity:.9;stroke-width:1.8;stroke-dasharray:5 4}
svg .edge.on{display:inline}
svg .edge.live{stroke:var(--good);stroke-opacity:1;stroke-width:2.2;stroke-dasharray:8 6}
svg .node{cursor:pointer;transition:opacity .15s}
svg .node .shape{fill:var(--surface);stroke:var(--line-2);stroke-width:1.4}
svg .node.working .shape{stroke:var(--good);stroke-width:2.4}
svg .node.unreadable .shape{stroke-dasharray:4 3}
svg .node.off{opacity:.55}
svg .node.dim{opacity:.22}
svg .node .ink{color:var(--ink)}
svg .node .label{font:700 12.5px var(--display);fill:var(--ink)}
svg .node .big{font:700 15px var(--display);fill:var(--ink)}
svg .node .cap{font:500 10.5px var(--display);fill:var(--ink-3)}
svg .node .fallback{font:700 13px var(--display);fill:var(--ink-2)}
svg .node.selected .shape,svg .node.tour .shape{stroke:var(--accent);stroke-width:2.8}
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
  svg .node.working .shape{animation:glow 2.2s ease-in-out infinite}
  @keyframes glow{0%,100%{filter:drop-shadow(0 0 2px rgba(63,125,90,.35))}50%{filter:drop-shadow(0 0 9px rgba(63,125,90,.8))}}
}
"""

SCRIPT = r"""
(function(){
'use strict';
var NS='http://www.w3.org/2000/svg';
var PAD=28,CW=104,R=25,CELL=112,PW=224,PH=58,HW=204,HH=48,GAPC=40,SW=132,SH=54;
var KIND={captain:'You',channel:'A way in',trigger:'Wakes the crew',first:'The first mate',mate:'Second mate',
  helper:'Helper at work',kit:'Part of an agent',project:'Project',tool:'Tool',step:'Delivery lane',
  path:'Delivery lane: another way',output:'Where results show'};
var SLOT={model:0,memory:1,project:2,tool:3};
var data=null,pos={},selected=null,hover=null,tourAt=-1,tourTimer=null,byId={};
var stage=document.getElementById('stage'),svg=document.getElementById('map');
var ICONS={},SAFE={path:1,circle:1,rect:1,line:1,polyline:1,polygon:1,ellipse:1,g:1};
var ATTRS=['d','cx','cy','r','rx','ry','x','y','x1','y1','x2','y2','width','height','points','transform','fill-rule','clip-rule'];
function el(tag,attrs,parent){var e=document.createElementNS(NS,tag);for(var k in attrs)e.setAttribute(k,attrs[k]);if(parent)parent.appendChild(e);return e;}
function txt(tag,attrs,text,parent){var e=el(tag,attrs,parent);e.textContent=text;return e;}
function fit(s,n){s=String(s||'');return s.length>n?s.slice(0,n-1).trim()+'…':s;}
function wrap(s,n,max){var words=String(s||'').split(/\s+/),lines=[],cur='';
  words.forEach(function(w){if(!cur)cur=w;else if((cur+' '+w).length<=n)cur+=' '+w;else{lines.push(cur);cur=w;}});
  if(cur)lines.push(cur);if(lines.length>max){lines=lines.slice(0,max);lines[max-1]=fit(lines[max-1]+' …',n);}
  return lines.map(function(l){return fit(l,n);});}
function loadIcon(spec){
  if(!ICONS[spec]){var p=String(spec).split(':'),base=(data.icons||{})[p[0]];
    ICONS[spec]=!base||!/^[a-z0-9-]+$/.test(p[1]||'')?Promise.resolve(null):fetch(base+p[1]+'.svg').then(function(r){return r.ok?r.text():null;})
      .then(function(t){return t?new DOMParser().parseFromString(t,'image/svg+xml').documentElement:null;}).catch(function(){return null;});}
  return ICONS[spec];}
function copySafe(src,dst){Array.prototype.forEach.call(src.children,function(c){var tag=c.tagName.toLowerCase();if(!SAFE[tag])return;
  var n=el(tag,{},dst);ATTRS.forEach(function(a){var v=c.getAttribute(a);if(v!==null)n.setAttribute(a,v);});if(tag==='g')copySafe(c,n);});}
function icon(g,spec,cx,cy,size,label){
  var s=size/24,h=el('g',{transform:'translate('+(cx-size/2)+','+(cy-size/2)+') scale('+s+')'},g);
  var brand=String(spec).indexOf('brand:')===0;
  if(brand)h.setAttribute('fill','currentColor');else{h.setAttribute('fill','none');h.setAttribute('stroke','currentColor');
    h.setAttribute('stroke-width','2');h.setAttribute('stroke-linecap','round');h.setAttribute('stroke-linejoin','round');}
  h.setAttribute('class','ink');
  loadIcon(spec).then(function(doc){if(doc){copySafe(doc,h);}else{h.remove();txt('text',{class:'fallback',x:cx,y:cy+5,'text-anchor':'middle'},(label||'?').charAt(0).toUpperCase(),g);}});
}
function layout(d){
  pos={};byId={};d.nodes.forEach(function(n){byId[n.id]=n;});
  var cols=d.agents.map(function(aid){
    var kit=d.nodes.filter(function(n){return n.owner===aid&&(n.kind==='kit'||n.kind==='project'||n.kind==='tool');});
    kit.sort(function(a,b){return (SLOT[a.slot]||0)-(SLOT[b.slot]||0);});
    var helpers=d.nodes.filter(function(n){return n.kind==='helper'&&n.owner===aid;});
    var per=Math.max(2,Math.min(4,kit.length));
    return {aid:aid,kit:kit,helpers:helpers,per:per,w:Math.max(PW,per*CW,helpers.length?HW:0)};});
  var rowC=cols.reduce(function(s,c){return s+c.w;},0)+GAPC*Math.max(0,cols.length-1);
  var ins=d.nodes.filter(function(n){return n.kind==='channel'||n.kind==='trigger';});
  var shared=d.nodes.filter(function(n){return n.kind==='tool'&&n.shared;});
  var outs=d.nodes.filter(function(n){return n.kind==='output';});
  var lane=d.lane.map(function(i){return byId[i];}).filter(Boolean);
  var rowB=PW+50+outs.length*CW;
  var W=Math.max(1080,rowC,rowB,lane.length*(SW+14),ins.length?Math.min(ins.length,11)*CW:0)+2*PAD,inner=W-2*PAD;
  var per=Math.max(1,Math.floor(inner/CW)),L={W:W,sections:[]};
  function grid(list,y0,n){list.forEach(function(node,k){var r=Math.floor(k/n),c=k%n,inRow=Math.min(n,list.length-r*n);
      var x0=PAD+(inner-inRow*CW)/2;pos[node.id]={x:x0+c*CW+CW/2-R,y:y0+r*CELL,w:2*R,h:2*R,shape:'circle'};});
    return y0+Math.ceil(list.length/n)*CELL;}
  var y=PAD+8;L.sections.push({y:y,text:'How work arrives',hint:'you, and everything that wakes the crew'});y+=22;
  if(byId.captain)pos.captain={x:PAD+inner/2-R,y:y,w:2*R,h:2*R,shape:'circle'};y+=CELL-6;
  y=grid(ins,y,Math.min(per,11));
  L.sections.push({y:y+6,text:'Who runs it',hint:'the first mate, and where results show'});y+=34;
  var bx=PAD+(inner-rowB)/2;if(byId.fm)pos.fm={x:bx,y:y,w:PW,h:PH,shape:'pill'};
  outs.forEach(function(n,k){pos[n.id]={x:bx+PW+50+k*CW+CW/2-R,y:y+PH/2-R,w:2*R,h:2*R,shape:'circle'};});
  y+=PH+64;
  L.sections.push({y:y,text:'The crew and their own kit',hint:'each agent’s model, memory, projects and the tools only it uses, with its helpers at work'});
  y+=34;var cx=PAD+(inner-rowC)/2,bottom=y;L.cols=[];L.geo={};
  cols.forEach(function(c){var yy=y;L.geo[c.aid]={x:cx,w:c.w,tx:cx+c.w/2,ty:y+PH+14};
    if(c.aid!=='fm'){pos[c.aid]={x:cx+(c.w-PW)/2,y:yy,w:PW,h:PH,shape:'pill'};yy+=PH+42;}
    else{L.cols.push({x:cx+c.w/2,y:yy-2,text:(byId.fm?byId.fm.label:'First mate')+'’s own kit'});yy+=PH+42;}
    c.kit.forEach(function(n,k){var r=Math.floor(k/c.per),q=k%c.per,inRow=Math.min(c.per,c.kit.length-r*c.per);
      var x0=cx+(c.w-inRow*CW)/2;pos[n.id]={x:x0+q*CW+CW/2-R,y:yy+r*CELL,w:2*R,h:2*R,shape:'circle'};});
    yy+=Math.ceil(c.kit.length/c.per)*CELL;
    c.helpers.forEach(function(n,k){pos[n.id]={x:cx+(c.w-HW)/2,y:yy+k*(HH+10),w:HW,h:HH,shape:'helper'};});
    yy+=c.helpers.length*(HH+10);bottom=Math.max(bottom,yy);cx+=c.w+GAPC;});
  y=bottom+18;
  L.sections.push({y:y,text:'Shared toolbox',hint:'drawn once; tap a tool or an agent to see who uses what'});y+=30;
  y=grid(shared,y,per)+4;
  L.sections.push({y:y,text:'Delivery lane',hint:'how a change reaches the project'});y+=30;
  var sw=Math.min(SW,Math.floor((inner-(lane.length-1)*14)/Math.max(1,lane.length))),lx=PAD+(inner-(lane.length*sw+(lane.length-1)*14))/2;
  lane.forEach(function(n,k){pos[n.id]={x:lx+k*(sw+14),y:y,w:sw,h:SH,shape:'step'};});
  y+=SH+18;
  d.side.forEach(function(id,k){pos[id]={x:lx+k*(200+14),y:y,w:200,h:SH-8,shape:'step'};});
  L.H=y+(d.side.length?SH:0)+PAD;return L;
}
var GEO={};
function path(e,a,b){
  var g=GEO[e.from];
  if(e.kind==='own'&&g&&b.shape==='circle'){var sx0=e.from==='fm'?g.tx:a.x+a.w/2,sy0=e.from==='fm'?g.ty:a.y+a.h,
      x2=b.x+b.w/2,bus=b.y-12;
    return 'M'+sx0+','+sy0+' L'+sx0+','+bus+' L'+x2+','+bus+' L'+x2+','+b.y;}
  if(e.kind==='flow'&&byId[e.to]&&byId[e.to].kind==='helper'&&g){var xr=g.x+g.w-6,hy=b.y+b.h/2;
    var sx=e.from==='fm'?g.tx:a.x+a.w,sy=e.from==='fm'?g.ty:a.y+a.h/2;
    return 'M'+sx+','+sy+' L'+xr+','+sy+' L'+xr+','+hy+' L'+(b.x+b.w)+','+hy;}
  if(e.kind==='shows'){var sx2=a.x+a.w,sy2=a.y+a.h/2,tx=b.x+b.w/2,ty=b.y;
    return 'M'+sx2+','+sy2+' C'+(sx2+30)+','+(sy2-46)+' '+tx+','+(ty-46)+' '+tx+','+ty;}
  if(e.kind==='lane'||(Math.abs((a.y+a.h/2)-(b.y+b.h/2))<8&&b.x>a.x)){var x1=a.x+a.w,y1=a.y+a.h/2,x2=b.x,y2=b.y+b.h/2;
    return 'M'+x1+','+y1+' L'+x2+','+y2;}
  var x1=a.x+a.w/2,y1=a.y+a.h,x2=b.x+b.w/2,y2=b.y;
  if(y2<y1){y1=a.y;y2=b.y+b.h+(b.shape==='circle'?34:0);}
  var my=(y1+y2)/2;return 'M'+x1+','+y1+' C'+x1+','+my+' '+x2+','+my+' '+x2+','+y2;
}
function draw(){
  var d=data,L=layout(d);GEO=L.geo;svg.innerHTML='';svg.setAttribute('viewBox','0 0 '+L.W+' '+L.H);
  var back=el('g',{},svg);
  if(pos.fm&&GEO.fm){var f=pos.fm,g0=GEO.fm,x1=f.x+f.w/2,y1=f.y+f.h,m=(y1+g0.ty)/2;
    el('path',{class:'edge own','data-from':'fm','data-to':'fm',d:'M'+x1+','+y1+' C'+x1+','+m+' '+g0.tx+','+m+' '+g0.tx+','+g0.ty},back);
    el('circle',{cx:g0.tx,cy:g0.ty,r:3.5,fill:'var(--ink-3)'},back);}
  L.sections.forEach(function(s,i){if(i)el('line',{class:'rule',x1:PAD,x2:L.W-PAD,y1:s.y-8,y2:s.y-8},back);
    var t=txt('text',{class:'section',x:PAD,y:s.y+8},s.text,back);var h=txt('text',{class:'hint',x:PAD,y:s.y+24},s.hint,back);});
  L.cols.forEach(function(c){txt('text',{class:'hint','text-anchor':'middle',x:c.x,y:c.y+24},c.text,back);});
  var zone=d.nodes.filter(function(n){return n.zone_here&&pos[n.id];});
  if(zone.length){var a=pos[zone[0].id],b=pos[zone[zone.length-1].id];
    el('rect',{class:'zone',x:a.x-6,y:a.y-6,width:b.x+b.w-a.x+12,height:a.h+12,rx:14},back);}
  var eg=el('g',{},svg);
  d.edges.forEach(function(e){var a=pos[e.from],b=pos[e.to];if(!a||!b)return;
    el('path',{class:'edge '+e.kind+(e.live?' live':''),d:path(e,a,b),'data-from':e.from,'data-to':e.to},eg);});
  var ng=el('g',{},svg);
  d.nodes.forEach(function(n){var p=pos[n.id];if(!p)return;
    var g=el('g',{class:'node '+n.status+(selected===n.id?' selected':''),transform:'translate('+p.x+','+p.y+')',tabindex:0,role:'button','data-id':n.id},ng);
    g.setAttribute('aria-label',n.label+'. '+(n.card.now||''));
    if(p.shape==='circle'){
      el('circle',{class:'shape',cx:R,cy:R,r:R,style:n.kind==='project'&&n.color?'stroke:'+n.color:''},g);
      icon(g,n.icon,R,R,22,n.label);
      wrap(n.label,15,2).forEach(function(l,k){txt('text',{class:'label',x:R,y:2*R+16+k*14,'text-anchor':'middle'},l,g);});
      var lines=wrap(n.label,15,2).length;
      txt('text',{class:'cap',x:R,y:2*R+18+lines*14,'text-anchor':'middle'},fit(n.cap||'',20),g);
    }else{
      var rx=p.shape==='pill'?p.h/2:12;
      el('rect',{class:'shape',width:p.w,height:p.h,rx:rx},g);
      var ic=p.shape==='pill'?22:16,ix=p.shape==='pill'?p.h/2:20;
      if(p.shape==='pill')el('circle',{cx:ix,cy:p.h/2,r:19,fill:n.color||'#888','fill-opacity':.18,stroke:n.color||'#888'},g);
      icon(g,n.icon,ix,p.h/2,ic,n.label);
      var tx=p.shape==='pill'?ix+28:36,chars=Math.floor((p.w-tx-10)/(p.shape==='pill'?8.2:7));
      var ls=wrap(n.label,chars,p.shape==='pill'?1:2),top=ls.length>1?p.h/2-7:p.h/2-(p.shape==='pill'?2:1);
      ls.forEach(function(l,k){txt('text',{class:p.shape==='pill'?'big':'label',x:tx,y:top+k*14},l,g);});
      var sub=p.shape==='pill'?(n.cap?n.cap+' · ':'')+(n.card.now||''):(n.kind==='step'?((n.here||[]).length?(n.here.length+' here now'):''):(n.card.now||''));
      txt('text',{class:'cap',x:tx,y:top+ls.length*14+(p.shape==='pill'?4:1)},fit(sub,Math.floor((p.w-tx-8)/5.6)),g);
      var here=(n.here||[]).length;
      if(here){el('circle',{cx:p.w-10,cy:10,r:9,fill:'#3f7d5a'},g);txt('text',{class:'badge',x:p.w-10,y:14,'text-anchor':'middle'},String(here),g);}
    }
    g.addEventListener('click',function(){open(n.id);});
    g.addEventListener('pointerenter',function(ev){if(ev.pointerType==='mouse'){hover=n.id;applyFocus();}});
    g.addEventListener('pointerleave',function(ev){if(ev.pointerType==='mouse'){hover=null;applyFocus();}});
    g.addEventListener('keydown',function(ev){if(ev.key==='Enter'||ev.key===' '){ev.preventDefault();open(n.id);}});
  });
  el('circle',{class:'traveller',r:7,cx:-50,cy:-50,id:'traveller'},svg);
  applyFocus();applyZoom(L);
}
function applyFocus(){
  var f=hover||selected||(tourAt>=0&&data.tour[tourAt]?data.tour[tourAt].node:null),near={};
  if(f){near[f]=1;data.edges.forEach(function(e){if(e.from===f)near[e.to]=1;if(e.to===f)near[e.from]=1;});}
  svg.querySelectorAll('path.edge').forEach(function(p){var on=f&&(p.dataset.from===f||p.dataset.to===f);p.classList.toggle('on',!!on);});
  svg.querySelectorAll('g.node').forEach(function(g){g.classList.toggle('dim',!!f&&!near[g.dataset.id]&&(selected||hover)!==null&&!!(selected||hover));});
}
var zoomLevel=null;
function applyZoom(L){var vb=svg.getAttribute('viewBox').split(' ');var w=+vb[2],h=+vb[3];
  var fitScale=Math.min(1.2,(stage.clientWidth-4)/w),s=zoomLevel===null?Math.max(fitScale,0.6):zoomLevel;
  svg.setAttribute('width',Math.round(w*s));svg.setAttribute('height',Math.round(h*s));}
function zoom(f){var vb=svg.getAttribute('viewBox').split(' ');var cur=(+svg.getAttribute('width'))/(+vb[2]);
  zoomLevel=f===0?null:Math.max(0.35,Math.min(2.2,cur*f));applyZoom();}
function row(dl,k,v){if(!v)return;var dt=document.createElement('dt');dt.textContent=k;var dd=document.createElement('dd');dd.textContent=v;dl.appendChild(dt);dl.appendChild(dd);}
function open(id){
  var n=byId[id];if(!n)return;selected=id;
  svg.querySelectorAll('g.node').forEach(function(g){g.classList.toggle('selected',g.dataset.id===id);});applyFocus();
  var b=document.getElementById('sheet-body');b.innerHTML='';
  var k=document.createElement('div');k.className='kind';k.textContent=KIND[n.kind]||'';b.appendChild(k);
  var h=document.createElement('h2');h.textContent=n.label;b.appendChild(h);
  var dl=document.createElement('dl');b.appendChild(dl);
  row(dl,'What it is',n.card.what);row(dl,'What it does in our workflow',n.card.role);
  row(dl,'Who uses it',n.card.users);row(dl,'What it is doing now',n.card.now);
  var list=(n.here||[]).concat(n.zone_here||[]);
  if(list.length){var dt=document.createElement('dt');dt.textContent='Helpers at this step';dl.appendChild(dt);
    var ul=document.createElement('ul');list.forEach(function(x){var li=document.createElement('li');li.textContent=x.label+(x.working?' (working)':'');ul.appendChild(li);});dl.appendChild(ul);}
  if(n.id==='tool:playbooks'&&data.playbooks){[['Ones you can start yourself',true],[data.first_mate+' opens these on its own',false]].forEach(function(p){
    var items=data.playbooks.filter(function(i){return i.yours===p[1];});if(!items.length)return;
    var dt=document.createElement('dt');dt.textContent=p[0];dl.appendChild(dt);var ul=document.createElement('ul');
    items.forEach(function(i){var li=document.createElement('li');var bb=document.createElement('b');bb.textContent=(p[1]?'/':'')+i.name;li.appendChild(bb);li.appendChild(document.createTextNode(': '+i.text));ul.appendChild(li);});dl.appendChild(ul);});}
  row(dl,'Read from',n.card.source);
  document.getElementById('sheet').classList.add('open');
}
function closeSheet(){document.getElementById('sheet').classList.remove('open');selected=null;
  svg.querySelectorAll('g.node.selected').forEach(function(g){g.classList.remove('selected');});applyFocus();}
function centre(id){var p=pos[id];return p?{x:p.x+p.w-6,y:p.y}:null;}
function scrollTo(id){var g=svg.querySelector('[data-id="'+CSS.escape(id)+'"]');
  if(g&&g.scrollIntoView)g.scrollIntoView({block:'center',inline:'center',behavior:'smooth'});}
function showHop(i){
  var t=data.tour;if(!t.length)return;tourAt=Math.max(0,Math.min(t.length-1,i));
  svg.querySelectorAll('.node.tour').forEach(function(g){g.classList.remove('tour');});
  var hop=t[tourAt],g=svg.querySelector('[data-id="'+CSS.escape(hop.node)+'"]');if(g)g.classList.add('tour');
  document.getElementById('tour-text').textContent=hop.text;
  document.getElementById('tour-count').textContent='Step '+(tourAt+1)+' of '+t.length;
  applyFocus();
  var dot=document.getElementById('traveller'),to=centre(hop.node),from=tourAt>0?centre(t[tourAt-1].node):to;
  if(dot&&to&&from){var start=null,reduce=window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    var stepAnim=function(ts){if(start===null)start=ts;var k=reduce?1:Math.min(1,(ts-start)/700);
      dot.setAttribute('cx',from.x+(to.x-from.x)*k);dot.setAttribute('cy',from.y+(to.y-from.y)*k);if(k<1)requestAnimationFrame(stepAnim);};
    requestAnimationFrame(stepAnim);}
  scrollTo(hop.node);
}
function tour(on){var bar=document.getElementById('tourbar');clearInterval(tourTimer);tourTimer=null;document.body.classList.toggle('touring',!!on);
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
  if(!baseline||!baseline.nodes){box.appendChild(document.createTextNode('This is your first look from this device: '+Object.keys(now).length+' parts on the map. New and removed parts will show here next time.'));}
  else{var added=Object.keys(now).filter(function(k){return !(k in baseline.nodes);});
    var gone=Object.keys(baseline.nodes).filter(function(k){return !(k in now);});
    var when=document.createElement('span');when.textContent='since you last looked ('+new Date(baseline.at).toLocaleString([], {weekday:'short',hour:'numeric',minute:'2-digit'})+'):';box.appendChild(when);
    if(!added.length&&!gone.length){box.appendChild(document.createTextNode('nothing added or removed.'));}
    added.forEach(function(k){var c=document.createElement('span');c.className='chip add';c.textContent='+ '+now[k];box.appendChild(c);});
    gone.forEach(function(k){var c=document.createElement('span');c.className='chip gone';c.textContent='− '+baseline.nodes[k];box.appendChild(c);});}
  try{localStorage.setItem(key,JSON.stringify({at:Date.now(),nodes:now}));}catch(e){}
}
function notices(){var n=document.getElementById('notices');n.innerHTML='';(data.notices||[]).forEach(function(t){var d=document.createElement('div');d.className='notice';d.textContent=t;n.appendChild(d);});}
var retry=null;
function say(t){document.getElementById('stamp').textContent=t;}
function why(e){return fit(e&&e.message?(e.name&&e.name!=='Error'?e.name+': ':'')+e.message:e,140);}
function load(){
  var step='reach',code=0,stale=null;clearTimeout(retry);
  fetch('system-map.json',{cache:'no-store'}).then(function(r){
    if(r.ok){step='read';stale=r.headers.get('X-Bridge-Stale');return r.json();}
    step='serve';code=r.status;return r.text().then(function(t){throw new Error(t.trim().split('\n')[0]||'no reason given');});
  }).then(function(d){
    step='draw';data=d;
    say(stale==='yes'?d.stamp+', not yet live: the Bridge is reading the latest records; trying again in a few seconds':
      stale?d.stamp+', not live: reading the latest records failed; trying again in a minute':d.stamp);
    draw();if(!stale)changes();notices();if(stale==='yes')retry=setTimeout(load,5000);
    if(tourAt>=0)showHop(tourAt);
    if(selected){if(byId[selected])open(selected);else closeSheet();}
  }).catch(function(e){
    if(step==='serve'&&code===503&&/still being drawn/.test(e.message)){
      say('the Bridge is still drawing the map; trying again in a few seconds');retry=setTimeout(load,5000);return;}
    say((step==='reach'?'could not reach the Bridge for the map data':
      step==='serve'?'the Bridge could not give the map (HTTP '+code+')':
      step==='read'?'the map data arrived damaged':'the map data arrived but could not be drawn')+
      ' ('+why(e)+'); trying again in a minute');
  });
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
    <span>dashed ring: could not read its source</span>
    <span>tap an agent or a shared tool to light up its lines</span>
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


class Cache(bridge.Cache):
    """The latest map, answered at once and rebuilt behind the request.

    A build reads every record and can take many seconds; waiting on it made
    iPad Safari give up on system-map.json. See bin/fm_bridge.py Cache for
    the states get() answers with.
    """

    def __init__(self, home, config_dir, reuse, wait=8.0):
        super().__init__(lambda: (json.dumps(build(home, config_dir)), None), reuse, wait)


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
