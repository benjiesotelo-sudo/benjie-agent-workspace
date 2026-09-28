#!/usr/bin/env python3
"""fm_herdr_names.py - Mission Control's naming step: plain names in Herdr's sidebar.

bin/fm-mission-control.sh owns the command surface (`names`), and
bin/fm_mission_control.py owns who everyone is: this module asks its
build_crew() for the crew, the same matching the Office uses, and turns it into
names Herdr shows. The running screen repeats the step every NAMES_EVERY
seconds through Keeper, because Herdr forgets display values when Herdr itself
restarts. With the settings in docs/herdr-config.toml, the sidebar shows only
the status icons after a Herdr restart, and for an agent that appears while
Mission Control is not running, until Mission Control starts again or Ctrl+B
then Alt+N is pressed.

WHAT IT CHANGES, and nothing else: display values, which Herdr shows but
never keeps across its own restart and never uses as a name.
  a space     the display value `name` (`herdr workspace report-metadata
              <space> --source mission-control --token name=<value>`), shown
              by the sidebar's `$name` space token;
  an agent's window
              the display values `who` and `job` (`herdr pane report-metadata
              <pane> --source mission-control --token who=<value>`, and the
              same with job=), shown by the sidebar's `$who` and `$job` agent
              tokens.
A value that already reads right is not sent again. docs/herdr-config.toml is
the sidebar settings that show these values.

WHAT IT NEVER DOES. It never renames anything: no space, tab or window name
changes, so the captain's own window names stick and firstmate's names (fm-,
2ndmate-, firstmate, └) stay exactly as firstmate set them. It never moves,
closes, creates or focuses anything, and never writes a record.

THE NAMES. Settings are Mission Control's own: config/mission-control.json's
first_mate_name and names map (fm_mission_control.py's header owns them).
  Agent windows: the first mate is first_mate_name with job "first mate"; a
    second mate is its Mission Control name (its first project's display
    name) with job "second mate"; an intern or helper is "<lead>'s intern" or
    "<lead>'s helper" with its job in plain words (its backlog title, else its
    window title).
  Spaces, first rule that applies:
    a firstmate helper space (its name starts with └, or is an older
      firstmate/<job> · p:<code> or 2ndmate-<id>/<job> · p:<code>) reads
      "<lead>'s intern · <job>" for the intern whose window it holds, else
      "<job>" from its own name without the prefix and the " · p:<code>"
      suffix;
    a space holding the first mate's window reads first_mate_name;
    a space holding a second mate's window, or named 2ndmate-<id> for a
      registered second mate, reads that mate's name;
    a space named firstmate that does not hold the first mate's window reads
      "<first_mate_name>'s interns", so no two spaces read first_mate_name;
    mission-control and controls read Mission Control and Controls;
    any other space reads its own name.

Environment: HERDR_SESSION is the session whose recorded endpoints count (as
on the Office), default "default". The running screen's Keeper leaves out its
own window (HERDR_PANE_ID there); the one-off `names` command has no screen and
leaves out nothing.
"""

import json
import os
import re
import subprocess
import sys
import threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fm_mission_control as mc  # noqa: E402  - the one owner of who everyone is

SOURCE = "mission-control"
SPACE_TOKEN = "name"
WHO_TOKEN = "who"
JOB_TOKEN = "job"
SCREENS = {"mission-control": "Mission Control", "controls": "Controls"}
HELPER_SUFFIX = " · p:"
OLD_HELPER = re.compile(r"^(?:firstmate|2ndmate-[^/]+)/(.+ · p:.*)$")
NAMES_EVERY = 5.0


def _one_line(text):
    return " ".join(mc.clean(text or "").split())


def _herdr_json(herdr, args):
    try:
        proc = subprocess.run(list(herdr) + list(args), capture_output=True, text=True, timeout=5, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    try:
        return json.loads(proc.stdout).get("result") or {}
    except (ValueError, AttributeError):
        return None


def read_layout(herdr):
    """(spaces, windows) from `herdr workspace list` and `herdr pane list`, or None."""
    spaces = _herdr_json(herdr, ["workspace", "list"])
    windows = _herdr_json(herdr, ["pane", "list"])
    if spaces is None or windows is None:
        return None
    return spaces.get("workspaces") or [], windows.get("panes") or []


def _who(member):
    if member["kind"] == "intern":
        return member["role"]
    return member["name"]


def _job(member):
    if member["kind"] == "first":
        return "first mate"
    if member["kind"] == "mate":
        return "second mate"
    return _one_line(member.get("title")) or "a one-off job"


def _helper_job(label):
    """The job part of a firstmate helper space's name, or None for any other space."""
    if label.startswith("└"):
        rest = label[len("└"):]
    else:
        old = OLD_HELPER.match(label)
        if not old:
            return None
        rest = old.group(1)
    return rest.split(HELPER_SUFFIX, 1)[0]


def plan(model, crew, spaces, windows, fm_name):
    """The display values that make Herdr show plain names.

    Each change is {"kind": "space"|"who"|"job", "id", "value", "was"}."""
    by_pane = {w.get("pane_id"): w for w in windows if w.get("pane_id")}
    in_space = {}
    changes = []

    for m in crew:
        pane = m.get("pane")
        win = by_pane.get(pane) if pane else None
        if win is None:
            continue
        in_space.setdefault(win.get("workspace_id"), []).append(m)
        tokens = win.get("tokens") or {}
        for kind, value in ((WHO_TOKEN, _one_line(_who(m))), (JOB_TOKEN, _job(m))):
            if value and tokens.get(kind) != value:
                changes.append({"kind": kind, "id": pane, "value": value, "was": tokens.get(kind)})

    mates = {m["id"]: m for m in model.get("mates") or []}
    for s in spaces:
        sid, label = s.get("workspace_id"), s.get("label") or ""
        if not sid:
            continue
        members = in_space.get(sid, [])
        kinds = {m["kind"]: m for m in reversed(members)}
        helper_job = _helper_job(label)
        if helper_job is not None:
            intern = kinds.get("intern")
            if intern:
                value = "%s · %s" % (_one_line(intern["role"]), _job(intern))
            else:
                value = helper_job
        elif "first" in kinds:
            value = fm_name
        elif "mate" in kinds:
            value = kinds["mate"]["name"]
        elif label.startswith("2ndmate-") and label[len("2ndmate-"):] in mates:
            value = mc.mate_name(model, label[len("2ndmate-"):])
        elif label == "firstmate":
            value = "%s's interns" % fm_name
        else:
            value = SCREENS.get(label, label)
        value = _one_line(value)
        was = (s.get("tokens") or {}).get(SPACE_TOKEN)
        if value and was != value:
            changes.append({"kind": "space", "id": sid, "value": value, "was": was, "label": label})
    return changes


def command(change):
    """The herdr arguments that make one change."""
    if change["kind"] == "space":
        return ["workspace", "report-metadata", change["id"], "--source", SOURCE,
                "--token", "%s=%s" % (SPACE_TOKEN, change["value"])]
    return ["pane", "report-metadata", change["id"], "--source", SOURCE,
            "--token", "%s=%s" % (change["kind"], change["value"])]


def describe(change):
    if change["kind"] == "space":
        return "space %s (%s) shows %s" % (change["id"], change["label"], change["value"])
    if change["kind"] == WHO_TOKEN:
        return "window %s shows who %s" % (change["id"], change["value"])
    return "window %s shows job %s" % (change["id"], change["value"])


def apply(herdr, changes):
    """Makes each change; returns the ones Herdr refused."""
    failed = []
    for c in changes:
        try:
            proc = subprocess.run(list(herdr) + command(c), capture_output=True, timeout=5, check=False)
            ok = proc.returncode == 0
        except (OSError, subprocess.SubprocessError):
            ok = False
        if not ok:
            failed.append(c)
    return failed


def crew_for(model, config_dir, agents, home, session, own_pane):
    settings = mc.read_settings(config_dir)
    model = mc.with_settings(model, settings)
    crew = mc.build_crew(model, agents, home, session, own_pane, settings["first_mate_name"])
    return model, crew, settings["first_mate_name"]


def names_once(model, agents, home, config_dir, herdr, session, own_pane):
    """One pass: read the layout, plan and apply. None when Herdr does not answer."""
    layout = read_layout(herdr)
    if layout is None:
        return None
    model, crew, fm_name = crew_for(model, config_dir, agents, home, session, own_pane)
    changes = plan(model, crew, layout[0], layout[1], fm_name)
    return changes, apply(herdr, changes)


class Keeper:
    """The running screen's naming step: every NAMES_EVERY seconds, off the render loop.

    source() returns (model, agents) once both have been read, else None.
    Nothing here prints or raises: the screen owns the terminal."""

    def __init__(self, source, home, config_dir, herdr, session, own_pane):
        self.source, self.home, self.config_dir = source, home, config_dir
        self.herdr, self.session, self.own_pane = list(herdr), session, own_pane
        self.stop = threading.Event()

    def start(self):
        threading.Thread(target=self._loop, daemon=True).start()

    def _loop(self):
        while not self.stop.is_set():
            try:
                got = self.source()
                if got is not None:
                    names_once(got[0], got[1], self.home, self.config_dir, self.herdr, self.session, self.own_pane)
            except Exception:  # noqa: BLE001 - naming is best effort and must never disturb the screen
                pass
            self.stop.wait(NAMES_EVERY)


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(prog="fm_herdr_names.py")
    ap.add_argument("--home", required=True)
    ap.add_argument("--config-dir", required=True)
    ap.add_argument("--herdr", default="herdr", help="the herdr command, split on spaces")
    args = ap.parse_args(argv)
    home = os.path.abspath(args.home)
    herdr = args.herdr.split()
    session = os.environ.get("HERDR_SESSION") or "default"
    try:
        model = mc.bridge.collect(home, args.config_dir, mc.bridge._now())
    except RuntimeError as exc:
        print("names: %s" % exc, file=sys.stderr)
        return 1
    agents = mc.read_agents(herdr)
    layout = read_layout(herdr)
    if agents is None or layout is None:
        print("names: Herdr did not answer; run this inside a Herdr session", file=sys.stderr)
        return 1
    model, crew, fm_name = crew_for(model, args.config_dir, agents, home, session, None)
    changes = plan(model, crew, layout[0], layout[1], fm_name)
    failed = apply(herdr, changes)
    for c in changes:
        print("%s: %s" % ("refused" if c in failed else "set", describe(c)))
    if not changes:
        print("names: every name already shows")
    else:
        print("names: %d set, %d refused" % (len(changes) - len(failed), len(failed)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
