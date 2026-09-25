#!/usr/bin/env python3
"""Drive `fm-mission-control.sh run` in a real pty (TIOCSWINSZ set), emulate the
screen with colours, and write per-action text + HTML snapshots.
usage: drive.py <mc> <out-prefix> <cols>x<rows> "<sec>=<keys|SH:cmd>,..."
"""
import os, pty, re, sys, struct, fcntl, termios, time, select, signal, html
mc, prefix, size, actions = sys.argv[1:5]
COLS, ROWS = map(int, size.split("x"))
plan = []
for x in actions.split(","):
    t, a = x.split("=", 1)
    a = a.replace("<DOWN>", "\x1b[B").replace("<UP>", "\x1b[A").replace("<ENTER>", "\r")
    plan.append((float(t), a))
plan.sort(key=lambda p: p[0])
tok = re.compile(r"\x1b\[([0-9;?<]*)([A-Za-z])|\x1b.|[\s\S]")

def render(text):
    grid = [[(" ", None, None, False)] * COLS for _ in range(ROWS)]
    pos = [0, 0]; fg = bg = None; bold = False
    for m in tok.finditer(text):
        t = m.group(0)
        if m.group(2) == "H":
            a = m.group(1).split(";") + ["1", "1"]
            pos[:] = [int(a[0] or 1) - 1, int(a[1] or 1) - 1]
        elif m.group(2) == "J":
            grid = [[(" ", None, None, False)] * COLS for _ in range(ROWS)]
        elif m.group(2) == "m":
            p = [int(x) if x else 0 for x in m.group(1).split(";")] if m.group(1) else [0]
            i = 0
            while i < len(p):
                c = p[i]
                if c == 0: fg = bg = None; bold = False
                elif c == 1: bold = True
                elif c == 22: bold = False
                elif c in (38, 48) and i + 4 < len(p) + 0 and p[i+1] == 2:
                    col = "#%02x%02x%02x" % tuple(p[i+2:i+5])
                    if c == 38: fg = col
                    else: bg = col
                    i += 4
                elif c == 39: fg = None
                elif c == 49: bg = None
                i += 1
        elif m.group(2) == "K":
            for cc in range(pos[1], COLS):
                if 0 <= pos[0] < ROWS: grid[pos[0]][cc] = (" ", None, bg, False)
        elif not t.startswith("\x1b") and t not in "\r\n":
            if 0 <= pos[0] < ROWS and 0 <= pos[1] < COLS:
                grid[pos[0]][pos[1]] = (t, fg, bg, bold)
            pos[1] += 1
    return grid

def to_text(grid):
    return "\n".join("".join(c[0] for c in row).rstrip() for row in grid)

def to_html(grid, title):
    out = ['<div class="scr"><div class="cap">%s</div><pre>' % html.escape(title)]
    for row in grid:
        for ch, fg, bg, b in row:
            st = ""
            if fg: st += "color:%s;" % fg
            if bg: st += "background:%s;" % bg
            if b: st += "font-weight:bold;"
            out.append('<span style="%s">%s</span>' % (st, html.escape(ch)) if st else html.escape(ch))
        out.append("\n")
    out.append("</pre></div>")
    return "".join(out)

pid, fd = pty.fork()
if pid == 0:
    os.execvp(mc, [mc, "run"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
os.kill(pid, signal.SIGWINCH)
raw, marks, t0, done = bytearray(), [], time.time(), None
while time.time() - t0 < 30:
    r, _, _ = select.select([fd], [], [], 0.05)
    if r:
        try: chunk = os.read(fd, 1 << 16)
        except OSError: chunk = b""
        if not chunk: break
        raw += chunk
    while plan and plan[0][0] <= time.time() - t0:
        _, act = plan.pop(0)
        marks.append((len(raw), act))
        if act.startswith("SH:"): os.system(act[3:])
        else: os.write(fd, act.encode())
    got, status = os.waitpid(pid, os.WNOHANG)
    if got:
        done = status; break
if done is None:
    os.kill(pid, signal.SIGKILL); _, done = os.waitpid(pid, 0)
open(prefix + ".raw", "wb").write(bytes(raw))
texts, htmls = [], []
for n, (mark, act) in enumerate(marks, 1):
    g = render(bytes(raw[:mark]).decode("utf-8", "replace"))
    label = "screen %d, just before sending %r" % (n, act)
    texts.append("===== " + label + "\n" + to_text(g))
    htmls.append(to_html(g, label))
open(prefix + ".screens.txt", "w").write("\n".join(texts) + "\n")
open(prefix + ".html", "w").write(
    "<!doctype html><meta charset=utf-8><title>%s</title><style>body{background:#111;color:#ddd;font-family:Menlo,monospace}"
    ".scr{margin:12px 0}.cap{color:#9cf;font-size:13px;margin:4px 0}pre{font-family:Menlo,monospace;font-size:12px;line-height:1.15;"
    "background:#0d1117;color:#c9d1d9;display:inline-block;padding:6px;margin:0}</style>%s" % (html.escape(os.path.basename(prefix)), "".join(htmls)))
print(os.WEXITSTATUS(done) if os.WIFEXITED(done) else 128 + os.WTERMSIG(done))
