import os, subprocess, sys
W = "/Users/benjie/.no-mistakes/worktrees/40995176e50b/01M3E0D9Z6Y7Z1E9XFYM6YFSN0"
SB = os.path.dirname(os.path.abspath(__file__))
EV = "/Users/benjie/.no-mistakes/evidence/01M3E0D9Z6Y7Z1E9XFYM6YFSN0"
def frame(size="170x50", keys="", fmt="text", now="2026-09-26T10:00:00", agents=True, herdr=None):
    env = dict(os.environ, PATH=SB + "/fakebin:" + os.environ["PATH"], FM_HOME=SB + "/ship",
               FM_BRIDGE_NOW=now, FM_MC_HERDR=herdr or SB + "/fakebin/herdr", FM_MC_COLORS="truecolor")
    cmd = [W + "/bin/fm-mission-control.sh", "frame", "--view", "calendar", "--size", size, "--keys", keys, "--format", fmt]
    if agents:
        cmd[2:2] = ["--agents", SB + "/agents.json"]
    p = subprocess.run(cmd, env=env, capture_output=True, text=True)
    if p.returncode:
        raise SystemExit("frame failed: " + p.stderr)
    return p.stdout
def tap_at(text, needle, row=None, **kw):
    """SGR mouse tap on the first occurrence of needle in the frame text."""
    for r, ln in enumerate(text.split("\n")):
        if (row is None or r == row) and needle in ln:
            c = ln.index(needle) + len(needle) // 2
            return "\x1b[<0;%d;%dM" % (c + 1, r + 1)
    raise SystemExit("no %r on screen" % needle)
def save(name, title, **kw):
    t = frame(**kw)
    open(EV + "/" + name + ".txt", "w").write(t)
    a = frame(fmt="ansi", **kw)
    h = subprocess.run(["python3", SB + "/ansi2html.py", title], input=a, capture_output=True, text=True).stdout
    open(EV + "/" + name + ".html", "w").write(h)
    return t
def bar(t):
    return t.split("\n")[3]
