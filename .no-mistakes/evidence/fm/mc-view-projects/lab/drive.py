"""Live pty driver: runs `fm-mission-control.sh run` at COLSxROWS, sends keys on a schedule,
emulates the screen (text + truecolor SGR) and writes <prefix>-<n>.txt / .html before each action."""
import os, pty, re, sys, struct, fcntl, termios, time, select, signal, html
mc, prefix, actions, cols, rows = sys.argv[1:6]
COLS, ROWS = int(cols), int(rows)
plan = sorted((float(t), a.encode().decode("unicode_escape")) for t, a in (x.split("=", 1) for x in actions.split(",")))
grid = [[(" ", None, None, False)] * COLS for _ in range(ROWS)]
pos = [0, 0]; fg = [None]; bg = [None]; bold = [False]
tok = re.compile(r"\x1b\[([0-9;?<]*)([A-Za-z])|\x1b.|[\s\S]")
def sgr(params):
    p = [int(x) if x else 0 for x in (params.split(";") if params else ["0"])]
    i = 0
    while i < len(p):
        v = p[i]
        if v == 0: fg[0] = bg[0] = None; bold[0] = False
        elif v == 1: bold[0] = True
        elif v == 22: bold[0] = False
        elif v in (38, 48) and i + 1 < len(p) and p[i+1] == 2:
            c = "#%02x%02x%02x" % tuple(p[i+2:i+5]); (fg if v == 38 else bg)[0] = c; i += 4
        elif v in (38, 48) and i + 1 < len(p) and p[i+1] == 5:
            n = p[i+2]; (fg if v == 38 else bg)[0] = "x256-%d" % n; i += 2
        elif v == 39: fg[0] = None
        elif v == 49: bg[0] = None
        i += 1
def feed(text):
    for m in tok.finditer(text):
        t = m.group(0); cmd = m.group(2)
        if cmd == "H":
            a = m.group(1).split(";") + ["1", "1"]; pos[:] = [int(a[0] or 1) - 1, int(a[1] or 1) - 1]
        elif cmd == "J":
            for r in range(ROWS): grid[r] = [(" ", None, None, False)] * COLS
        elif cmd == "K":
            r = pos[0]
            if 0 <= r < ROWS:
                for c in range(pos[1], COLS): grid[r][c] = (" ", None, bg[0], False)
        elif cmd == "m": sgr(m.group(1))
        elif not t.startswith("\x1b") and t not in "\r\n":
            if 0 <= pos[0] < ROWS and 0 <= pos[1] < COLS:
                grid[pos[0]][pos[1]] = (t, fg[0], bg[0], bold[0])
            pos[1] += 1
def text():
    return "\n".join("".join(c[0] for c in row).rstrip() for row in grid)
def to_html(title):
    out = []
    for row in grid:
        line = []
        for ch, f, b, bo in row:
            st = []
            if f and f.startswith("#"): st.append("color:" + f)
            if b and b.startswith("#"): st.append("background:" + b)
            if bo: st.append("font-weight:bold")
            line.append('<span style="%s">%s</span>' % (";".join(st), html.escape(ch)) if st else html.escape(ch))
        out.append("".join(line))
    return ('<!doctype html><meta charset="utf-8"><title>%s</title><body style="margin:0;background:#101014">'
            '<div style="padding:4px 8px;color:#ccc;font:13px monospace">%s</div>'
            '<pre style="margin:0;padding:8px;font:14px/1.2 Menlo,monospace;color:#d0d0d0;background:#16161c">%s</pre>'
            % (html.escape(title), html.escape(title), "\n".join(out)))
pid, fd = pty.fork()
if pid == 0:
    os.execvp(mc, [mc, "run"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
os.kill(pid, signal.SIGWINCH)
t0, n, done = time.time(), 0, None
buf = b""
while time.time() - t0 < 25:
    r, _, _ = select.select([fd], [], [], 0.05)
    if r:
        try: chunk = os.read(fd, 1 << 16)
        except OSError: chunk = b""
        if not chunk: break
        buf += chunk
        s = buf.decode("utf-8", "ignore") if False else None
        # feed only up to the last complete escape sequence / utf-8 char
        cut = len(buf)
        k = buf.rfind(b"\x1b")
        if k != -1 and not re.match(rb"\x1b(\[[0-9;?<]*[A-Za-z@-~]|[^\[])", buf[k:]):
            cut = k
        while cut > 0:
            try: s = buf[:cut].decode(); break
            except UnicodeDecodeError: cut -= 1
        if s is not None:
            feed(s); buf = buf[cut:]
    if plan and time.time() - t0 >= plan[0][0]:
        at, act = plan.pop(0); n += 1
        label = "before action %d (t=%.1fs, next keys %r)" % (n, at, act)
        open("%s-%d.txt" % (prefix, n), "w").write(text() + "\n")
        open("%s-%d.html" % (prefix, n), "w").write(to_html(label))
        os.write(fd, act.encode())
    wp, st = os.waitpid(pid, os.WNOHANG)
    if wp: done = st; break
if done is None:
    for _ in range(40):
        wp, st = os.waitpid(pid, os.WNOHANG)
        if wp: done = st; break
        time.sleep(0.05)
if done is None:
    os.kill(pid, signal.SIGKILL); os.waitpid(pid, 0); print("timeout"); sys.exit(1)
print(os.waitstatus_to_exitcode(done))
