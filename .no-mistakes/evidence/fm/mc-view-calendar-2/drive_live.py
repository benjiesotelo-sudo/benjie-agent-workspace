# Live pty driver for Mission Control: runs `fm-mission-control.sh run` in a
# pseudo-terminal of a given size, sends timed keys, emulates the colour screen
# and writes an HTML snapshot (and plain text) just before each action.
import os, pty, re, sys, struct, fcntl, termios, time, select, signal, html, json
mc, prefix, cols, rows, actions = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
plan = sorted((float(t), a) for t, a in (x.split("=", 1) for x in actions.split(",")))
KEYS = {"RIGHT": "\x1b[C", "LEFT": "\x1b[D"}
tok = re.compile(r"\x1b\[([0-9;?]*)([A-Za-z])|\x1b.|[\s\S]")
def render(text):
    grid = [[(" ", None, None, False)] * cols for _ in range(rows)]
    pos = [0, 0]; fg = bg = None; bold = False
    for m in tok.finditer(text):
        t = m.group(0)
        if m.group(2) == "H":
            a = m.group(1).split(";") + ["1", "1"]; pos[:] = [int(a[0] or 1) - 1, int(a[1] or 1) - 1]
        elif m.group(2) == "J":
            grid = [[(" ", None, None, False)] * cols for _ in range(rows)]
        elif m.group(2) == "m":
            p = [int(x) if x else 0 for x in m.group(1).split(";")]; i = 0
            while i < len(p):
                if p[i] == 0: fg = bg = None; bold = False
                elif p[i] == 1: bold = True
                elif p[i] == 22: bold = False
                elif p[i] in (38, 48) and i + 4 < len(p) and p[i+1] == 2:
                    c = "#%02x%02x%02x" % tuple(p[i+2:i+5])
                    if p[i] == 38: fg = c
                    else: bg = c
                    i += 4
                i += 1
        elif not t.startswith("\x1b") and t not in "\r\n":
            if 0 <= pos[0] < rows and 0 <= pos[1] < cols:
                grid[pos[0]][pos[1]] = (t, fg, bg, bold)
            pos[1] += 1
    return grid
def to_html(grid, title):
    out = ['<html><head><meta charset="utf-8"><title>%s</title><style>body{background:#111;margin:8px}pre{font:13px/1.15 Menlo,monospace;margin:0;color:#ddd}</style></head><body><pre>' % html.escape(title)]
    for row in grid:
        for ch, fg, bg, bold in row:
            st = (("color:%s;" % fg) if fg else "") + (("background:%s;" % bg) if bg else "") + ("font-weight:bold;" if bold else "")
            out.append('<span style="%s">%s</span>' % (st, html.escape(ch)) if st else html.escape(ch))
        out.append("\n")
    out.append("</pre></body></html>")
    return "".join(out)
pid, fd = pty.fork()
if pid == 0:
    os.execvp(mc, [mc, "run"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
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
        _, act = plan.pop(0); marks.append((len(raw), act))
        os.write(fd, "".join(KEYS.get(k, k) for k in act.split("+")).encode())
    got, status = os.waitpid(pid, os.WNOHANG)
    if got: done = status; break
if done is None:
    os.kill(pid, signal.SIGKILL); _, done = os.waitpid(pid, 0)
open(prefix + ".raw", "wb").write(bytes(raw))
for n, (mark, act) in enumerate(marks, 1):
    g = render(bytes(raw[:mark]).decode("utf-8", "replace"))
    open("%s-%d.txt" % (prefix, n), "w").write("\n".join("".join(c[0] for c in row).rstrip() for row in g) + "\n")
    open("%s-%d.html" % (prefix, n), "w").write(to_html(g, "screen before action %d (%s)" % (n, act)))
print("exit", os.WEXITSTATUS(done) if os.WIFEXITED(done) else 128 + os.WTERMSIG(done))
print("terminal restored last:", bytes(raw).endswith(b"\x1b[0m\x1b[?1000l\x1b[?1006l\x1b[?7h\x1b[?25h\x1b[?1049l"))
