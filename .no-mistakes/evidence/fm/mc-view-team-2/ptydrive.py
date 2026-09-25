# Live pty driver for Mission Control: sizes the pty, drains it, emulates the
# screen with colours, and saves an HTML + text snapshot before each action.
import os, pty, re, sys, struct, fcntl, termios, time, select, signal, html, json
mc, prefix, actions, cols, rows = sys.argv[1:6]
COLS, ROWS = int(cols), int(rows)
plan = sorted((float(t), a) for t, a in (x.split("=", 1) for x in actions.split(",")))
DEF_FG, DEF_BG = (220, 220, 220), (12, 14, 18)
def blank(): return [[(" ", None, None, False) for _ in range(COLS)] for _ in range(ROWS)]
grid = blank(); pos = [0, 0]; st = [None, None, False]
tok = re.compile(r"\x1b\[([0-9;?<]*)([A-Za-z])|\x1b[()][0-9A-Za-z]|\x1b.|[\s\S]")
def sgr(params):
    p = [int(x) if x else 0 for x in params.split(";")] if params else [0]
    i = 0
    while i < len(p):
        v = p[i]
        if v == 0: st[:] = [None, None, False]
        elif v == 1: st[2] = True
        elif v == 22: st[2] = False
        elif v == 39: st[0] = None
        elif v == 49: st[1] = None
        elif v in (38, 48) and i + 1 < len(p) and p[i+1] == 2:
            st[0 if v == 38 else 1] = tuple(p[i+2:i+5]); i += 4
        elif v in (38, 48) and i + 1 < len(p) and p[i+1] == 5:
            i += 2
        i += 1
def feed(text):
    global grid
    for m in tok.finditer(text):
        t = m.group(0)
        if m.group(2):
            k, a = m.group(2), m.group(1)
            if k == "H":
                aa = a.split(";") + ["1", "1"]
                pos[:] = [int(aa[0] or 1) - 1, int(aa[1] or 1) - 1]
            elif k == "J": grid = blank()
            elif k == "K":
                r = pos[0]
                if 0 <= r < ROWS:
                    for c in range(pos[1], COLS): grid[r][c] = (" ", st[0], st[1], st[2])
            elif k == "m" and not a.startswith("?"): sgr(a)
        elif t.startswith("\x1b"): pass
        elif t == "\r": pos[1] = 0
        elif t == "\n": pos[0] += 1
        else:
            if 0 <= pos[0] < ROWS and 0 <= pos[1] < COLS:
                grid[pos[0]][pos[1]] = (t, st[0], st[1], st[2])
            pos[1] += 1
def snap(path, title):
    global grid
    grid = blank(); pos[:] = [0, 0]; st[:] = [None, None, False]
    feed(bytes(raw).decode("utf-8", "replace"))
    txt = "\n".join("".join(c[0] for c in row) for row in grid)
    open(path + ".txt", "w").write(txt + "\n")
    out = ['<html><head><meta charset="utf-8"><title>%s</title><style>body{background:#000;margin:8px;color:#ccc;font-family:Menlo,monospace}pre{font:10px/12px Menlo,monospace;margin:0}span{white-space:pre}</style></head><body><div style="font:12px sans-serif;margin-bottom:6px">%s</div><pre>' % (html.escape(title), html.escape(title))]
    for row in grid:
        for ch, fg, bg, b in row:
            f = fg or DEF_FG; g = bg or DEF_BG
            out.append('<span style="color:rgb%s;background:rgb%s%s">%s</span>' % (str(tuple(f)), str(tuple(g)), ";font-weight:bold" if b else "", html.escape(ch)))
        out.append("\n")
    out.append("</pre></body></html>")
    open(path + ".html", "w").write("".join(out))
pid, fd = pty.fork()
if pid == 0:
    os.execvp(mc, [mc, "run"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
os.kill(pid, signal.SIGWINCH)
raw = bytearray(); t0 = time.time(); done = None; n = 0
while time.time() - t0 < 30:
    r, _, _ = select.select([fd], [], [], 0.05)
    if r:
        try: chunk = os.read(fd, 1 << 16)
        except OSError: chunk = b""
        if not chunk: break
        raw += chunk
    while plan and plan[0][0] <= time.time() - t0:
        _, act = plan.pop(0); n += 1
        snap("%s.%02d" % (prefix, n), "before action %d: %r" % (n, act))
        if act == "TERM": os.kill(pid, signal.SIGTERM)
        elif act.startswith("SH:"): os.system(act[3:])
        else: os.write(fd, act.encode().decode("unicode_escape").encode("latin-1") if "\\" in act else act.encode())
    got, status = os.waitpid(pid, os.WNOHANG)
    if got: done = status; break
if done is None:
    os.kill(pid, signal.SIGKILL); _, done = os.waitpid(pid, 0)
open(prefix + ".raw", "wb").write(bytes(raw))
print(os.WEXITSTATUS(done) if os.WIFEXITED(done) else 128 + os.WTERMSIG(done))
