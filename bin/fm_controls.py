#!/usr/bin/env python3
"""fm_controls.py - Controls: the captain's switches, one tap each.

bin/fm-controls.sh is the operator entry point and owns the command surface
and the Herdr workspace; this module owns what the screen shows and what a
tap changes.

ONE SWITCH. "Let <first mate> merge green pull requests on the workspace",
ON or OFF, is the merge switch bin/fm_merge_switch.py owns: that module's
header is the one statement of which rules the switch writes, where, and how.
This screen is the only thing that changes it, and only when the captain taps
the switch card or presses Enter (or space); it asks for no confirmation,
since either way can be undone with the next tap, and shows the new state at
once. A switch that reads partly on turns OFF with a tap. When the settings
file cannot be read the switch shows why and a tap changes nothing.

ALWAYS THE REAL STATE. The screen reads the settings file back after every
change it makes, whenever the file, the switch's "last changed" record or
config/mission-control.json changes (checked every POLL seconds), and at least
every REREAD seconds, so an edit made anywhere else shows within a second.
Under the switch it says in plain words what ON allows, when the switch last
changed (here, with the time, or elsewhere, with the settings file's own
modification time) and what the current state means, in that order so the
first two stay on a short pane.

The first mate's name comes from config/mission-control.json first_mate_name,
read the way Mission Control reads it ("the first mate" when absent).

DRAWING. Mission Control's canvas, colours, terminal handling and diffed
output (bin/fm_mission_control.py), with SGR mouse reports so a tap works
from a phone or tablet terminal; q quits and every exit restores the
terminal.
"""

import json
import os
import select
import signal
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fm_mission_control as mc  # noqa: E402  - the canvas, colours and terminal
import fm_merge_switch as ms  # noqa: E402  - the one owner of the switch's file

POLL = 0.5
REREAD = 5.0
MIN_COLS = 40
MIN_ROWS = 14
CARD_H = 5
TRACK_W = 16
KNOB_W = 6
OFF_TRACK = mc.H("#3a4250")
CARD_LINE = mc.H("#262d38")
KNOB = mc.H("#f4f7fa")

LOOKS = {  # state: (word, colour, track colour, knob at the right, what a tap does)
    "on": ("ON", mc.GREEN, mc.GREEN, True, "tap to turn it off"),
    "off": ("OFF", mc.SOFT, OFF_TRACK, False, "tap to turn it on"),
    "partial": ("PARTLY ON", mc.AMBER, mc.AMBER, None, "tap to turn it off"),
    None: ("CANNOT BE READ", mc.AMBER, mc.DIMMER, None, "a tap changes nothing"),
}


class UI:
    def __init__(self):
        self.toast = ""
        self.toast_until = 0.0
        self.hit = None     # (row0, row1, col0, col1) of the switch card


def who(config_dir):
    name = mc.first_mate_name(config_dir)
    return "the first mate" if name == "First mate" else name


def _cap(text):
    return text[:1].upper() + text[1:]


def label(name):
    return "Let %s merge green pull requests on the workspace" % name


def allows(name):
    return ("%s may merge pull requests on the workspace once every check passes and there are no conflicts; "
            "other projects still wait for you." % _cap(name))


def meaning(sw, name):
    if sw["error"]:
        return ("%s. Nothing was changed; fix or remove .claude/settings.local.json in the home and this "
                "screen reads it again by itself." % _cap(sw["error"]))
    return {
        "on": "%s may merge green pull requests on the workspace without asking you." % _cap(name),
        "off": "%s waits for your word before merging any pull request." % _cap(name),
        "partial": ("Only one of the switch's two permission rules is in the settings file, so %s may merge "
                    "through one spelling of the merge command. A tap turns it fully off." % name),
    }[sw["state"]]


def _when(stamp, now):
    t = time.localtime(stamp)
    return "%s (%s)" % (time.strftime("%a %-d %b at %H:%M", t), mc._ago(max(0.0, now - stamp)))


def changed(sw, now):
    if sw["error"]:
        return "Not known while the settings file cannot be read."
    if sw["changed_here"] is not None:
        return "Turned %s here %s." % (LOOKS[sw["state"]][0], _when(sw["changed_here"], now))
    if sw["changed_outside"]:
        if sw["changed_elsewhere"] is None:
            return "Changed outside this screen; the settings file is gone, so it reads OFF."
        return "Changed outside this screen; the settings file was last written %s." % _when(
            sw["changed_elsewhere"], now)
    return "Never changed yet; it starts OFF."


def compose(sw, name, ui, cols, rows, now):
    """One frame of the Controls screen; ui.hit is set to the switch card."""
    cv = mc.Canvas(cols, rows)
    ui.hit = None
    if cols < MIN_COLS or rows < MIN_ROWS:
        cv.put(0, 0, mc.clip("Make this pane bigger: Controls needs %d x %d, this pane is %d x %d." % (
            MIN_COLS, MIN_ROWS, cols, rows), cols), mc.AMBER)
        return cv
    C, R = cols, rows
    cv.put(0, 0, " CONTROLS ", mc.BG, mc.H("#2fbf71"), True)
    clk = time.strftime("%a %H:%M ", time.localtime(now))
    cv.put(C - len(clk), 0, clk, mc.DIM)
    cv.put(0, 1, "─" * C, mc.LINE)
    cv.put(0, R - 2, "─" * C, mc.LINE)
    last = R - 3
    word, colour, track, right, tap = LOOKS[sw["state"] if not sw["error"] else None]
    r = 3
    lines = mc.wrap(mc.clean("%s: %s" % (label(name), word)), C - 4)
    for ln in lines:
        cv.put(2, r, ln, mc.INK, None, True)
        r += 1
    if lines[-1].endswith(word):
        cv.put(2 + len(lines[-1]) - len(word), r - 1, word, colour, None, True)
    r += 1

    # The switch card: a track with its knob, and the state in a word beside it.
    w = min(C - 4, 64)
    c0, r0 = 2, r
    mc._box(cv, c0, r0, w, CARD_H, colour if sw["error"] or sw["state"] == "partial" else CARD_LINE)
    ui.hit = (r0, r0 + CARD_H, c0, c0 + w)
    tc = c0 + 3
    for k in range(3):
        cv.put(tc, r0 + 1 + k, " " * TRACK_W, colour, track)
    if right is None:
        kc = tc + (TRACK_W - KNOB_W) // 2
    else:
        kc = tc + TRACK_W - KNOB_W if right else tc
    if sw["error"]:
        cv.put(tc + TRACK_W // 2, r0 + 2, "?", mc.INK, None, True)
    else:
        for k in range(3):
            cv.put(kc, r0 + 1 + k, " " * KNOB_W, KNOB, KNOB)
    sc = tc + TRACK_W + 3
    room = c0 + w - 2 - sc
    if room >= len(word):
        cv.put(sc, r0 + 1, mc.clip("the switch is", room), mc.DIM)
        cv.put(sc, r0 + 2, word, colour, None, True)
        cv.put(sc, r0 + 3, mc.clip(tap, room), mc.DIM)
    r = r0 + CARD_H + 1

    def section(title, text, fg=mc.SOFT):
        nonlocal r
        if r > last:
            return
        cv.put(2, r, title, mc.LABEL, None, True)
        r += 1
        for ln in mc.wrap(mc.clean(text), C - 4):
            if r > last:
                return
            cv.put(2, r, ln, fg)
            r += 1
        r += 1

    section("WHAT ON ALLOWS", allows(name))
    section("LAST CHANGED", changed(sw, now))
    section("RIGHT NOW", meaning(sw, name), mc.AMBER if sw["error"] or sw["state"] == "partial" else mc.INK)
    if ui.toast and time.monotonic() < ui.toast_until:
        cv.put(0, R - 1, mc.clip(" " + ui.toast, C), mc.INK, None, True)
    else:
        keys = " tap the switch or Enter: %s   q quit " % (
            "change nothing" if sw["error"] else "turn it on" if sw["state"] == "off" else "turn it off")
        cv.put(0, R - 1, mc.clip(keys, C), mc.DIM)
    return cv


def flip(home, sw, name, ui):
    """The one write: turn the switch to the other state and say what happened."""
    ui.toast_until = time.monotonic() + 4
    if sw["error"]:
        ui.toast = "Nothing changed: %s." % sw["error"]
        return ms.read(home)
    on = sw["state"] == "off"
    try:
        got = ms.switch(home, on)
    except ms.SettingsError as exc:
        ui.toast = "Nothing changed: %s." % exc
        return ms.read(home)
    except Exception as exc:
        ui.toast = "The switch could not be changed (%s); it shows what the file holds now." % exc
        return ms.read(home)
    ui.toast = ("Turned ON: %s may now merge green pull requests on the workspace." % name if on
                else "Turned OFF: %s now waits for your word before any merge." % name)
    return got


def _stamp(home, config_dir):
    out = []
    for p in (ms.settings_path(home), os.path.join(home, ms.RECORD), os.path.join(config_dir, "mission-control.json")):
        try:
            st = os.stat(p)
            out.append((st.st_mtime_ns, st.st_size, st.st_ino))
        except OSError:
            out.append(None)
    return out


def _taps(data, ui):
    """How many toggles the input asks for, and whether q was pressed."""
    n, quit_ = 0, False
    for m in mc._KEYS.finditer(data):
        tok = m.group(0)
        if m.group(1) is not None:
            btn, x, y, kind = int(m.group(1)), int(m.group(2)), int(m.group(3)), m.group(4)
            if kind != b"M" or btn & (3 | 32 | 64 | 128) or ui.hit is None:
                continue
            r0, r1, c0, c1 = ui.hit
            if r0 <= y - 1 < r1 and c0 <= x - 1 < c1:
                n += 1
        elif tok in (b"q", b"Q"):
            quit_ = True
            break
        elif tok in (b"\r", b"\n", b" "):
            n += 1
    return n, quit_


def run(home, config_dir):
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        print("fm_controls.py: run needs a terminal", file=sys.stderr)
        return 2
    term = mc.Terminal()
    enc = mc.Encoder(mc.color_mode())
    ui = UI()
    wake_r, wake_w = os.pipe()
    os.set_blocking(wake_w, False)
    flags = {"resize": True, "quit": False}

    def poke(kind):
        def handler(_s, _f):
            flags[kind] = True
            try:
                os.write(wake_w, b"w")
            except OSError:
                pass
        return handler

    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, poke("quit"))
    signal.signal(signal.SIGWINCH, poke("resize"))
    if os.path.lexists(ms.settings_path(home)):
        ms.ensure_ignored(home)
    sw, name = ms.read(home), who(config_dir)
    stamp, read_at = _stamp(home, config_dir), time.monotonic()
    prev, shown, size = None, None, term.size()
    term.enter()
    try:
        while not flags["quit"]:
            try:
                ready, _, _ = select.select([term.fd_in, wake_r], [], [], POLL)
            except InterruptedError:
                ready = []
            if wake_r in ready:
                os.read(wake_r, 64)
            if term.fd_in in ready:
                data = os.read(term.fd_in, 1024)
                if not data:
                    break
                n, quit_ = _taps(data, ui)
                if quit_:
                    break
                for _ in range(n):
                    sw = flip(home, sw, name, ui)
                if n:
                    stamp, read_at = _stamp(home, config_dir), time.monotonic()
            if flags["resize"]:
                flags["resize"] = False
                size = term.size()
                prev = None
                term.write("\x1b[0m\x1b[2J")
            now_s = _stamp(home, config_dir)
            if now_s != stamp or time.monotonic() - read_at >= REREAD:
                sw, name = ms.read(home), who(config_dir)
                stamp, read_at = now_s, time.monotonic()
            cells = compose(sw, name, ui, size[0], size[1], time.time()).cells()
            if cells == shown:
                continue
            out = enc.diff(prev if prev is not None and len(prev) == len(cells) else None, cells, size[0])
            if out:
                term.write(out)
            prev = shown = cells
    finally:
        term.leave()
    return 0


def frame(home, config_dir, cols, rows, fmt):
    sw, name = ms.read(home), who(config_dir)
    cv = compose(sw, name, UI(), cols, rows, time.time())
    if fmt == "ansi":
        return mc.to_ansi(cv)
    if fmt == "text":
        return cv.text()
    return json.dumps({"label": label(name), "state": sw["state"], "error": sw["error"],
                       "changed_here": sw["changed_here"], "changed_outside": sw["changed_outside"],
                       "changed_elsewhere": sw["changed_elsewhere"],
                       "text": cv.text()}, indent=1)


def main(argv):
    import argparse
    import re
    ap = argparse.ArgumentParser(prog="fm_controls.py")
    ap.add_argument("command", choices=["run", "frame"])
    ap.add_argument("--home", required=True)
    ap.add_argument("--config-dir", required=True)
    ap.add_argument("--size", default="80x24")
    ap.add_argument("--format", default="text", choices=["text", "json", "ansi"])
    args = ap.parse_args(argv)
    home = os.path.abspath(args.home)
    if args.command == "run":
        return run(home, args.config_dir)
    m = re.match(r"^(\d+)x(\d+)$", args.size)
    if not m:
        print("fm_controls.py: --size is <cols>x<rows>", file=sys.stderr)
        return 2
    sys.stdout.write(frame(home, args.config_dir, int(m.group(1)), int(m.group(2)), args.format) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
