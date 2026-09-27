#!/usr/bin/env python3
"""drive.py <mc> <outdir> <name> <cols>x<rows> <plan.json>
Runs `fm-mission-control.sh run` in a real pseudo-terminal of the given size, emulates the
screen with colours, and before each planned action saves <name>-NN-<label>.txt/.html.
plan: [[seconds, label, action], ...]; action is one of
  "keys:<text>" (\\e \\r escapes), "tap:<col>,<row>" (zero-based), "tapon:<needle>",
  "sh:<command>", "snap" (snapshot only), "quit" (sends q).
"""
import fcntl, html, json, os, pty, re, select, signal, struct, sys, termios, time
mc, out, name, size, planf = sys.argv[1:]
COLS, ROWS = map(int, size.split("x"))
plan = sorted(json.load(open(planf)), key=lambda p: p[0])
BLANK = (" ", 0xcccccc, 0x000000, False)
grid = [[BLANK] * COLS for _ in range(ROWS)]
st = {"pos": [0, 0], "fg": 0xcccccc, "bg": 0, "bold": False}
tok = re.compile(r"\x1b\[([0-9;?]*)([A-Za-z])|\x1b.|[\s\S]")

def sgr(params):
    p = [int(x or 0) for x in params.split(";")] if params else [0]
    i = 0
    while i < len(p):
        v = p[i]
        if v == 0: st.update(fg=0xcccccc, bg=0, bold=False)
        elif v == 1: st["bold"] = True
        elif v == 22: st["bold"] = False
        elif v in (38, 48) and i + 4 < len(p) and p[i+1] == 2:
            st["fg" if v == 38 else "bg"] = (p[i+2] << 16) | (p[i+3] << 8) | p[i+4]; i += 4
        i += 1

def feed(text):
    for m in tok.finditer(text):
        t = m.group(0)
        if m.group(2) == "H":
            a = (m.group(1) or "1;1").split(";") + ["1"]
            st["pos"] = [int(a[0] or 1) - 1, int(a[1] or 1) - 1]
        elif m.group(2) == "J":
            for r in range(ROWS): grid[r] = [BLANK] * COLS
        elif m.group(2) == "m":
            sgr(m.group(1))
        elif not t.startswith("\x1b") and t not in "\r\n":
            r, c = st["pos"]
            if 0 <= r < ROWS and 0 <= c < COLS:
                grid[r][c] = (t, st["fg"], st["bg"], st["bold"])
            st["pos"][1] += 1

def text():
    return "\n".join("".join(c[0] for c in row).rstrip() for row in grid)

def to_html(title):
    rows = []
    for row in grid:
        spans, cur, buf = [], None, []
        for ch, fg, bg, b in row:
            k = (fg, bg, b)
            if k != cur and buf:
                spans.append('<span style="color:#%06x;background:#%06x%s">%s</span>' % (cur[0], cur[1], ";font-weight:bold" if cur[2] else "", html.escape("".join(buf))))
                buf = []
            cur = k; buf.append(ch)
        if buf:
            spans.append('<span style="color:#%06x;background:#%06x%s">%s</span>' % (cur[0], cur[1], ";font-weight:bold" if cur[2] else "", html.escape("".join(buf))))
        rows.append("".join(spans))
    return ('<!doctype html><meta charset="utf-8"><title>%s</title><style>body{margin:0;background:#000}'
            'pre{margin:0;font:14px/1.15 Menlo,monospace;letter-spacing:0}</style><pre>%s</pre>' % (html.escape(title), "\n".join(rows)))

raw = bytearray()
def replay():
    for r in range(ROWS): grid[r] = [BLANK] * COLS
    st.update(pos=[0, 0], fg=0xcccccc, bg=0, bold=False)
    feed(bytes(raw).decode("utf-8", "replace"))

snaps = []
def snap(label):
    replay()
    n = len(snaps) + 1
    base = os.path.join(out, "%s-%02d-%s" % (name, n, label))
    open(base + ".txt", "w").write(text() + "\n")
    open(base + ".html", "w").write(to_html("%s %s" % (name, label)))
    snaps.append(base)

def find(needle):
    replay()
    for i, row in enumerate(grid):
        j = "".join(c[0] for c in row).find(needle)
        if j >= 0:
            return j, i
    raise SystemExit("no %r on the screen" % needle)

pid, fd = pty.fork()
if pid == 0:
    os.execvp(mc, [mc, "run"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
os.kill(pid, signal.SIGWINCH)
t0, done, log = time.time(), None, []
while time.time() - t0 < 120:
    r, _, _ = select.select([fd], [], [], 0.05)
    if r:
        try: chunk = os.read(fd, 1 << 16)
        except OSError: chunk = b""
        if not chunk: break
        raw.extend(chunk)
    while plan and plan[0][0] <= time.time() - t0:
        _, label, act = plan.pop(0)
        snap(label)
        kind, _, arg = act.partition(":")
        if kind == "keys":
            os.write(fd, arg.encode().decode("unicode_escape").encode())
        elif kind == "tap":
            c, rr = map(int, arg.split(","))
            os.write(fd, b"\x1b[<0;%d;%dM" % (c + 1, rr + 1))
        elif kind == "tapon":
            c, rr = find(arg)
            os.write(fd, b"\x1b[<0;%d;%dM" % (c + 1, rr + 1))
        elif kind == "sh":
            os.system(arg)
        elif kind == "quit":
            os.write(fd, b"q")
        log.append("%.1fs %s -> %s" % (time.time() - t0, label, act))
    got, status = os.waitpid(pid, os.WNOHANG)
    if got:
        done = status; break
if done is None:
    os.kill(pid, signal.SIGKILL); _, done = os.waitpid(pid, 0)
code = os.WEXITSTATUS(done) if os.WIFEXITED(done) else 128 + os.WTERMSIG(done)
log.append("exit %d" % code)
open(os.path.join(out, name + "-actions.log"), "w").write("\n".join(log) + "\n")
print("\n".join(log))
