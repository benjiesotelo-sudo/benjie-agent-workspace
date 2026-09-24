#!/usr/bin/env python3
"""Live driver for Mission Control: runs `fm-mission-control.sh run` in a real pty
(TIOCSWINSZ set before the TUI reads its grid), feeds keys on a plan, emulates the
screen with colours, and writes text + HTML snapshots of each moment.
usage: drive_live.py <mc> <prefix> <cols> <rows> <plan: t=keys;t=keys...>"""
import os, pty, re, sys, struct, fcntl, termios, time, select, signal, html
mc, prefix, cols, rows, planarg = sys.argv[1:]
COLS, ROWS = int(cols), int(rows)
KEYS = {"UP": "\x1b[A", "DOWN": "\x1b[B", "ENTER": "\r"}
plan = []
for part in planarg.split(";"):
    t, a = part.split("=", 1)
    plan.append((float(t), "".join(KEYS.get(x, x) for x in a.split("+"))))
plan.sort()
tok = re.compile(r"\x1b\[([0-9;?]*)([A-Za-z])|\x1b.|[\s\S]")

def blank():
    return [[(" ", (200, 200, 200), (0, 0, 0), False) for _ in range(COLS)] for _ in range(ROWS)]

def render(data):
    grid, pos, pen = blank(), [0, 0], [(200, 200, 200), (0, 0, 0), False]
    for m in tok.finditer(data):
        t, fin = m.group(0), m.group(2)
        if fin == "H":
            a = m.group(1).split(";") + ["1", "1"]
            pos[:] = [int(a[0] or 1) - 1, int(a[1] or 1) - 1]
        elif fin == "J":
            grid = blank()
        elif fin == "m":
            p = [int(x) if x else 0 for x in m.group(1).split(";")]
            i = 0
            while i < len(p):
                v = p[i]
                if v == 0: pen[:] = [(200, 200, 200), (0, 0, 0), False]
                elif v == 1: pen[2] = True
                elif v == 22: pen[2] = False
                elif v in (38, 48) and i + 4 < len(p) and p[i + 1] == 2:
                    pen[0 if v == 38 else 1] = tuple(p[i + 2:i + 5]); i += 4
                elif v in (38, 48) and i + 2 < len(p) and p[i + 1] == 5:
                    i += 2
                i += 1
        elif not t.startswith("\x1b") and t not in "\r\n":
            if 0 <= pos[0] < ROWS and 0 <= pos[1] < COLS:
                grid[pos[0]][pos[1]] = (t, pen[0], pen[1], pen[2])
            pos[1] += 1
    return grid

def to_html(grid, title):
    out = ['<html><head><meta charset="utf-8"><title>%s</title><style>body{background:#111;margin:0;padding:12px}'
           'pre{font:13px/1.15 Menlo,monospace;margin:0}</style></head><body><pre>' % html.escape(title)]
    for row in grid:
        for ch, fg, bg, b in row:
            out.append('<span style="color:rgb%s;background:rgb%s%s">%s</span>' % (
                fg, bg, ";font-weight:bold" if b else "", html.escape(ch)))
        out.append("\n")
    out.append("</pre></body></html>")
    return "".join(out)

pid, fd = pty.fork()
if pid == 0:
    os.execvp(mc, [mc, "run"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
os.kill(pid, signal.SIGWINCH)
raw, marks, t0, done = bytearray(), [], time.time(), None
while time.time() - t0 < 40:
    r, _, _ = select.select([fd], [], [], 0.05)
    if r:
        try: chunk = os.read(fd, 1 << 16)
        except OSError: chunk = b""
        if not chunk: break
        raw += chunk
    while plan and plan[0][0] <= time.time() - t0:
        _, act = plan.pop(0)
        marks.append(len(raw))
        os.write(fd, act.encode())
    got, status = os.waitpid(pid, os.WNOHANG)
    if got:
        done = status; break
if done is None:
    os.kill(pid, signal.SIGKILL); _, done = os.waitpid(pid, 0)
open(prefix + ".raw", "wb").write(bytes(raw))
texts = []
for n, mark in enumerate(marks, 1):
    g = render(bytes(raw[:mark]).decode("utf-8", "replace"))
    txt = "\n".join("".join(c[0] for c in row).rstrip() for row in g)
    texts.append(txt)
    open("%s.%02d.html" % (prefix, n), "w").write(to_html(g, "%s screen %d" % (os.path.basename(prefix), n)))
open(prefix + ".screens.txt", "w").write("\n===== next =====\n".join(texts) + "\n")
print(os.WEXITSTATUS(done) if os.WIFEXITED(done) else 128 + os.WTERMSIG(done))
