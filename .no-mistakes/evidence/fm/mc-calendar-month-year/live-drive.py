# Runs "bin/fm-mission-control.sh run" in a pty sized COLSxROWS (TIOCSWINSZ set before the
# screen reads its grid), sends timed keys/taps, emulates the screen (CUP, ED, SGR truecolor)
# and saves each screen before an action as text and HTML.
import fcntl, html, os, pty, re, select, signal, struct, sys, termios, time
W = "/Users/benjie/.no-mistakes/worktrees/40995176e50b/01M3E0D9Z6Y7Z1E9XFYM6YFSN0"
SB, EV = "/tmp/fmcal.IuwZ", "/Users/benjie/.no-mistakes/evidence/01M3E0D9Z6Y7Z1E9XFYM6YFSN0"
name, COLS, ROWS, herdr = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
plan = [(float(t), a.encode().decode("unicode_escape")) for t, a in (x.split("=", 1) for x in sys.argv[5].split("|"))]
DEF = ((0xd9,0xe0,0xe8),(0x0c,0x0e,0x12),False)
grid = [[(" ",)+DEF for _ in range(COLS)] for _ in range(ROWS)]
pos, sty = [0, 0], list(DEF)
tok = re.compile(r"\x1b\[([0-9;?<]*)([A-Za-z])|\x1b.|[\s\S]")
def feed(text):
    for m in tok.finditer(text):
        t, fin = m.group(0), m.group(2)
        if fin == "H":
            a = m.group(1).split(";") + ["1", "1"]; pos[:] = [int(a[0] or 1) - 1, int(a[1] or 1) - 1]
        elif fin == "J":
            for row in grid: row[:] = [(" ",)+DEF for _ in range(COLS)]
        elif fin == "m":
            p = [int(x) for x in m.group(1).split(";") if x.isdigit()] or [0]; i = 0
            while i < len(p):
                v = p[i]
                if v == 0: sty[:] = list(DEF)
                elif v == 1: sty[2] = True
                elif v == 22: sty[2] = False
                elif v in (38, 48) and i + 4 < len(p) and p[i+1] == 2:
                    sty[0 if v == 38 else 1] = tuple(p[i+2:i+5]); i += 4
                i += 1
        elif t == "\r": pos[1] = 0
        elif t == "\n": pos[0] += 1
        elif not t.startswith("\x1b"):
            if 0 <= pos[0] < ROWS and 0 <= pos[1] < COLS: grid[pos[0]][pos[1]] = (t, sty[0], sty[1], sty[2])
            pos[1] += 1
env = dict(os.environ, PATH=SB + "/fakebin:" + os.environ["PATH"], FM_HOME=SB + "/ship", FM_MC_HERDR=herdr,
           FM_BRIDGE_NOW="2026-09-26T10:00:00", FM_MC_COLORS="truecolor", TERM="xterm-256color")
pid, fd = pty.fork()
if pid == 0:
    os.execve(W + "/bin/fm-mission-control.sh", ["fm-mission-control.sh", "run"], env)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
os.kill(pid, signal.SIGWINCH)
raw, marks, t0, status = bytearray(), [], time.time(), None
while time.time() - t0 < 40:
    r, _, _ = select.select([fd], [], [], 0.05)
    if r:
        try: chunk = os.read(fd, 1 << 16)
        except OSError: chunk = b""
        if not chunk: break
        raw += chunk
    while plan and plan[0][0] <= time.time() - t0:
        _, act = plan.pop(0); marks.append((len(raw), act)); os.write(fd, act.encode())
    got, st = os.waitpid(pid, os.WNOHANG)
    if got: status = st; break
for _ in range(40):
    if status is not None: break
    got, st = os.waitpid(pid, os.WNOHANG)
    if got: status = st
    else: time.sleep(0.05)
if status is None:
    os.kill(pid, signal.SIGKILL); os.waitpid(pid, 0); print("KILLED (did not quit)")
else:
    print("exit", os.waitstatus_to_exitcode(status))
out = []
for i, (mark, act) in enumerate(marks):
    for row in grid: row[:] = [(" ",)+DEF for _ in range(COLS)]
    pos[:] = [0, 0]; sty[:] = list(DEF)
    feed(bytes(raw[:mark]).decode("utf-8", "replace"))
    txt = "\n".join("".join(c[0] for c in row) for row in grid)
    out.append("===== screen %d, before sending %r\n%s" % (i, act, txt))
    h = []
    for row in grid:
        h.append("".join('<span style="color:#%02x%02x%02x;background:#%02x%02x%02x;%s">%s</span>' % (c[1]+c[2]+("font-weight:bold" if c[3] else "",html.escape(c[0]))) for c in row))
    open("%s/live-%s-%d.html" % (EV, name, i), "w").write('<!doctype html><meta charset="utf-8"><body style="background:#0c0e12;margin:0;padding:12px"><h1 style="color:#9aa;font:13px monospace">live run %dx%d, screen %d before %s</h1><pre style="font:13px/1.15 Menlo,monospace;margin:0">%s</pre>' % (COLS, ROWS, i, html.escape(repr(act)), "\n".join(h)))
open("%s/live-%s.screens.txt" % (EV, name), "w").write("\n".join(out) + "\n")
