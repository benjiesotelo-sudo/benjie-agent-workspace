# Live pty driver for fm-mission-control.sh run: sets a real window size, sends keys on a
# schedule, emulates the screen (cursor moves, clears, truecolor SGR), and writes each screen
# (just before each action and at the end) as text and as coloured HTML.
import os, pty, re, sys, struct, fcntl, termios, time, select, signal, html, json
mc, outdir, cols, rows, plan_json = sys.argv[1:]
COLS, ROWS = int(cols), int(rows)
plan = json.loads(plan_json)  # [[seconds, label, keys], ...]
DEF = ((217, 224, 232), (12, 14, 18), False)
grid = [[(" ", DEF)] * COLS for _ in range(ROWS)]
pos = [0, 0]; attr = [DEF]
tok = re.compile(r"\x1b\[([0-9;?]*)([A-Za-z])|\x1b.|[\s\S]")
def sgr(params):
    fg, bg, b = attr[0]
    p = [int(x) if x else 0 for x in params.split(";")] if params else [0]
    i = 0
    while i < len(p):
        v = p[i]
        if v == 0: fg, bg, b = DEF
        elif v == 1: b = True
        elif v == 22: b = False
        elif v == 38 and p[i+1] == 2: fg = tuple(p[i+2:i+5]); i += 4
        elif v == 48 and p[i+1] == 2: bg = tuple(p[i+2:i+5]); i += 4
        elif v == 39: fg = DEF[0]
        elif v == 49: bg = DEF[1]
        i += 1
    attr[0] = (fg, bg, b)
def feed(text):
    for m in tok.finditer(text):
        t = m.group(0); c = m.group(2)
        if c == "H":
            a = m.group(1).split(";") + ["1", "1"]; pos[:] = [int(a[0] or 1) - 1, int(a[1] or 1) - 1]
        elif c == "J":
            for r in range(ROWS): grid[r] = [(" ", DEF)] * COLS
        elif c == "m": sgr(m.group(1))
        elif c == "K":
            if 0 <= pos[0] < ROWS:
                for x in range(pos[1], COLS): grid[pos[0]][x] = (" ", attr[0])
        elif t == "\r": pos[1] = 0
        elif t == "\n": pos[0] += 1
        elif not t.startswith("\x1b"):
            if 0 <= pos[0] < ROWS and 0 <= pos[1] < COLS: grid[pos[0]][pos[1]] = (t, attr[0])
            pos[1] += 1
def dump(name):
    for r in range(ROWS): grid[r] = [(" ", DEF)] * COLS
    pos[:] = [0, 0]; attr[0] = DEF
    feed(bytes(raw).decode("utf-8", "replace"))
    txt = "\n".join("".join(ch for ch, _ in row).rstrip() for row in grid)
    open(os.path.join(outdir, name + ".txt"), "w").write(txt + "\n")
    out = ['<html><head><meta charset="utf-8"><style>body{margin:0;background:#0c0e12}pre{margin:0;padding:8px;font:13px/1.25 Menlo,monospace}</style></head><body><pre>']
    for row in grid:
        run, cur = [], None
        for ch, a in row:
            if a != cur and run:
                out.append(span(cur, "".join(run))); run = []
            cur = a; run.append(ch)
        if run: out.append(span(cur, "".join(run)))
        out.append("\n")
    out.append("</pre></body></html>")
    open(os.path.join(outdir, name + ".html"), "w").write("".join(out))
def span(a, s):
    fg, bg, b = a
    return '<span style="color:rgb%s;background:rgb%s%s">%s</span>' % (fg, bg, ";font-weight:bold" if b else "", html.escape(s))
pid, fd = pty.fork()
if pid == 0:
    os.execvp(mc, [mc, "run"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
os.kill(pid, signal.SIGWINCH)
t0, done, raw = time.time(), None, bytearray()
dec = __import__("codecs").getincrementaldecoder("utf-8")("replace")
while time.time() - t0 < 60:
    r, _, _ = select.select([fd], [], [], 0.05)
    if r:
        try: chunk = os.read(fd, 1 << 16)
        except OSError: chunk = b""
        if not chunk: break
        raw += chunk
    while plan and plan[0][0] <= time.time() - t0:
        _, label, keys = plan.pop(0)
        dump(label)  # screen as it stood after the previous action
        if keys: os.write(fd, keys.encode())
    got, status = os.waitpid(pid, os.WNOHANG)
    if got: done = status; break
if done is None:
    os.kill(pid, signal.SIGKILL); _, done = os.waitpid(pid, 0)
open(os.path.join(outdir, "session.raw"), "wb").write(bytes(raw))
print("exit", os.WEXITSTATUS(done) if os.WIFEXITED(done) else 128 + os.WTERMSIG(done))
