"""Drive `fm-mission-control.sh run` in a real pty with a set window size,
send timed keys, and save each emulated screen (text + coloured HTML)."""
import os, pty, re, sys, struct, fcntl, termios, time, select, signal, html, json
mc, prefix, actions, cols, rows = sys.argv[1:6]
COLS, ROWS = int(cols), int(rows)
plan = sorted((float(t), a) for t, a in (x.split("=", 1) for x in actions.split(",")))
KEYS = {"DOWN": "\x1b[B", "UP": "\x1b[A", "ENTER": "\r"}
blank = lambda: [[(" ", None, None)] * COLS for _ in range(ROWS)]
grid, pos, sgr = blank(), [0, 0], [None, None]
tok = re.compile(r"\x1b\[([0-9;?<]*)([A-Za-z])|\x1b.|[\s\S]")

def set_sgr(p):
    a = [int(x) if x else 0 for x in (p or "0").split(";")]
    i = 0
    while i < len(a):
        v = a[i]
        if v == 0: sgr[:] = [None, None]
        elif v in (38, 48) and i + 4 < len(a) and a[i+1] == 2:
            sgr[0 if v == 38 else 1] = "#%02x%02x%02x" % tuple(a[i+2:i+5]); i += 4
        elif v == 39: sgr[0] = None
        elif v == 49: sgr[1] = None
        i += 1

def feed(text):
    for m in tok.finditer(text):
        t = m.group(0)
        if m.group(2) == "H":
            a = m.group(1).split(";") + ["1", "1"]
            pos[:] = [int(a[0] or 1) - 1, int(a[1] or 1) - 1]
        elif m.group(2) == "J":
            grid[:] = blank()
        elif m.group(2) == "m" and not m.group(1).startswith("?"):
            set_sgr(m.group(1))
        elif m.group(2) == "K":
            for c in range(pos[1], COLS):
                if 0 <= pos[0] < ROWS: grid[pos[0]][c] = (" ", None, sgr[1])
        elif not t.startswith("\x1b") and t not in "\r\n":
            if 0 <= pos[0] < ROWS and 0 <= pos[1] < COLS:
                grid[pos[0]][pos[1]] = (t, sgr[0], sgr[1])
            pos[1] += 1

def to_html(title):
    out = ['<html><head><meta charset="utf-8"><title>%s</title><style>body{background:#0d1117;margin:0;padding:12px}'
           'pre{font:13px/1.15 Menlo,monospace;color:#c9d1d9;margin:0}h1{font:13px sans-serif;color:#8b949e}</style></head><body><h1>%s</h1><pre>' % (html.escape(title), html.escape(title))]
    for row in grid:
        for ch, fg, bg in row:
            st = (("color:%s;" % fg) if fg else "") + (("background:%s;" % bg) if bg else "")
            c = html.escape(ch)
            out.append('<span style="%s">%s</span>' % (st, c) if st else c)
        out.append("\n")
    out.append("</pre></body></html>")
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
        os.write(fd, "".join(KEYS.get(k, k) for k in act.split("+")).encode())
    got, status = os.waitpid(pid, os.WNOHANG)
    if got: done = status; break
if done is None:
    os.kill(pid, signal.SIGKILL); _, done = os.waitpid(pid, 0)
screens = []
for n, (mark, act) in enumerate(marks, 1):
    grid[:] = blank(); pos[:] = [0, 0]; sgr[:] = [None, None]
    feed(bytes(raw[:mark]).decode("utf-8", "replace"))
    txt = "\n".join("".join(c[0] for c in row) for row in grid)
    screens.append(txt)
    open("%s.%d.html" % (prefix, n), "w").write(to_html("%s  screen %d (before key %r) %dx%d" % (os.path.basename(prefix), n, act, COLS, ROWS)))
open(prefix + ".screens.txt", "w").write("\n=====\n".join(screens) + "\n")
print(os.WEXITSTATUS(done) if os.WIFEXITED(done) else 128 + os.WTERMSIG(done))
