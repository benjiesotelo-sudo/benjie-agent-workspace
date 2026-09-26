# Live pty driver: runs `fm-mission-control.sh run` at COLSxROWS, sends
# timed input, emulates the screen (text + truecolor), and dumps each screen
# before each action as text and as ANSI-free HTML with colors.
import os, pty, re, sys, struct, fcntl, termios, time, select, signal, json, html
mc, prefix, actions, cols, rows = sys.argv[1:]
COLS, ROWS = int(cols), int(rows)
plan = sorted((float(t), a) for t, a in (x.split("=", 1) for x in actions.split(",")))
grid = [[(" ", None, None)] * COLS for _ in range(ROWS)]
pos = [0, 0]; fg = [None]; bg = [None]
tok = re.compile(r"\x1b\[([0-9;?<]*)([A-Za-z])|\x1b.|[\s\S]")
def sgr(params):
    p = [int(x) if x else 0 for x in params.split(";")] if params else [0]
    i = 0
    while i < len(p):
        v = p[i]
        if v == 0: fg[0] = bg[0] = None
        elif v in (38, 48) and i + 1 < len(p) and p[i+1] == 2:
            c = "#%02x%02x%02x" % tuple(p[i+2:i+5]); (fg if v == 38 else bg)[0] = c; i += 4
        elif v in (38, 48) and i + 1 < len(p) and p[i+1] == 5: i += 2
        elif v == 39: fg[0] = None
        elif v == 49: bg[0] = None
        i += 1
def feed(text):
    for m in tok.finditer(text):
        t = m.group(0)
        if m.group(2) == "H":
            a = m.group(1).split(";") + ["1", "1"]
            pos[:] = [int(a[0] or 1) - 1, int(a[1] or 1) - 1]
        elif m.group(2) == "m": sgr(m.group(1))
        elif m.group(2) == "J":
            for row in grid: row[:] = [(" ", None, None)] * COLS
        elif m.group(2) == "K":
            r = pos[0]
            if 0 <= r < ROWS:
                for c in range(pos[1], COLS): grid[r][c] = (" ", None, bg[0])
        elif not t.startswith("\x1b") and t not in "\r\n":
            if 0 <= pos[0] < ROWS and 0 <= pos[1] < COLS: grid[pos[0]][pos[1]] = (t, fg[0], bg[0])
            pos[1] += 1
def text():
    return "\n".join("".join(c[0] for c in row).rstrip() for row in grid)
def as_html(title):
    out = []
    for row in grid:
        spans = []
        for ch, f, b in row:
            st = ("color:%s;" % f if f else "") + ("background:%s;" % b if b else "")
            spans.append('<span style="%s">%s</span>' % (st, html.escape(ch)) if st else html.escape(ch))
        out.append("".join(spans))
    return ('<!doctype html><meta charset="utf-8"><title>%s</title><body style="margin:0;background:#101014;color:#ddd">'
            '<div style="font:13px/15px Menlo,monospace;padding:8px;color:#bbb">%s</div>'
            '<pre style="font:13px/15px Menlo,monospace;margin:0;padding:8px;letter-spacing:0">%s</pre>' % (title, html.escape(title), "\n".join(out)))
pid, fd = pty.fork()
if pid == 0:
    os.execvp(mc, [mc, "run"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
os.kill(pid, signal.SIGWINCH)
import codecs
dec = codecs.getincrementaldecoder('utf-8')('replace'); pend = ['']
t0, k, done = time.time(), 0, None
screens = []
while time.time() - t0 < float(os.environ.get('DRIVE_SECS', '60')):
    r, _, _ = select.select([fd], [], [], 0.05)
    if r:
        try: chunk = os.read(fd, 1 << 16)
        except OSError: chunk = b""
        if not chunk: break
        pend[0] += dec.decode(chunk)
        cut = pend[0].rfind("")
        if cut >= 0 and not re.match(r"(\[[0-9;?<]*[A-Za-z]|[^\[])", pend[0][cut:]):
            feed(pend[0][:cut]); pend[0] = pend[0][cut:]
        else:
            feed(pend[0]); pend[0] = ""
    while k < len(plan) and time.time() - t0 >= plan[k][0]:
        k += 1
        label = "screen %d, before action %r" % (k, plan[k-1][1])
        screens.append(text())
        open("%s-%d.html" % (prefix, k), "w").write(as_html(label))
        os.write(fd, plan[k-1][1].encode())
    wpid, st = os.waitpid(pid, os.WNOHANG)
    if wpid: done = st; break
open(prefix + ".screens", "w").write("\n=====\n".join(screens))
done = done if done is not None else os.waitpid(pid, 0)[1]
print(os.waitstatus_to_exitcode(done) if done is not None else "timeout", "after %.1fs" % (time.time() - t0))
