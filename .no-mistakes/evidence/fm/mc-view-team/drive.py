"""Live pty driver for Mission Control with a colour-aware screen emulator.

usage: drive.py <mc> <out-prefix> <cols> <rows> "<t>=<keys|SH:cmd|TERM>,..."
Writes <prefix>.raw, <prefix>-N.txt and <prefix>-N.html (screen just before action N).
"""
import os, pty, re, sys, struct, fcntl, termios, time, select, signal, subprocess, html
mc, prefix, cols, rows, actions = sys.argv[1:]
COLS, ROWS = int(cols), int(rows)
plan = sorted((float(t), a) for t, a in (x.split("=", 1) for x in actions.split(",")))
DEF_FG, DEF_BG = (200, 200, 200), (0, 0, 0)
grid = [[(" ", DEF_FG, DEF_BG, False)] * COLS for _ in range(ROWS)]
pos = [0, 0]
st = {"fg": DEF_FG, "bg": DEF_BG, "b": False}
tok = re.compile(r"\x1b\[([0-9;?]*)([A-Za-z])|\x1b.|[\s\S]")


def sgr(params):
    p = [int(x or 0) for x in params.split(";")] if params else [0]
    i = 0
    while i < len(p):
        v = p[i]
        if v == 0:
            st.update(fg=DEF_FG, bg=DEF_BG, b=False)
        elif v == 1:
            st["b"] = True
        elif v == 22:
            st["b"] = False
        elif v in (38, 48) and i + 4 < len(p) + 0 and p[i + 1] == 2:
            st["fg" if v == 38 else "bg"] = tuple(p[i + 2:i + 5]); i += 4
        elif v in (38, 48) and p[i + 1] == 5:
            i += 2
        i += 1


def feed(text):
    for m in tok.finditer(text):
        t = m.group(0)
        if m.group(2) == "H":
            a = m.group(1).split(";") + ["1", "1"]
            pos[:] = [int(a[0] or 1) - 1, int(a[1] or 1) - 1]
        elif m.group(2) == "J":
            for r in range(ROWS):
                grid[r] = [(" ", DEF_FG, DEF_BG, False)] * COLS
        elif m.group(2) == "m":
            sgr(m.group(1))
        elif not t.startswith("\x1b") and t not in "\r\n":
            if 0 <= pos[0] < ROWS and 0 <= pos[1] < COLS:
                grid[pos[0]][pos[1]] = (t, st["fg"], st["bg"], st["b"])
            pos[1] += 1


def dump(n):
    txt = "\n".join("".join(c[0] for c in row).rstrip() for row in grid)
    open("%s-%d.txt" % (prefix, n), "w").write(txt + "\n")
    out = ['<html><body style="background:#000;margin:8px"><pre style="font:11px/1.0 Menlo,monospace;margin:0">']
    for row in grid:
        for ch, fg, bg, b in row:
            out.append('<span style="color:rgb%s;background:rgb%s%s">%s</span>' % (
                fg, bg, ";font-weight:bold" if b else "", html.escape(ch)))
        out.append("\n")
    out.append("</pre></body></html>")
    open("%s-%d.html" % (prefix, n), "w").write("".join(out))


pid, fd = pty.fork()
if pid == 0:
    os.execvp(mc, [mc, "run"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
os.kill(pid, signal.SIGWINCH)
raw, t0, done, n = bytearray(), time.time(), None, 0
import codecs
dec = codecs.getincrementaldecoder("utf-8")()
pend = ""
while time.time() - t0 < 30:
    r, _, _ = select.select([fd], [], [], 0.05)
    if r:
        try:
            chunk = os.read(fd, 1 << 16)
        except OSError:
            chunk = b""
        if not chunk:
            break
        raw += chunk
        pend += dec.decode(chunk)
        k = pend.rfind("\x1b")
        if k >= 0 and not re.match(r"\x1b(\[[0-9;?]*[A-Za-z]|[^\[])", pend[k:]):
            feed(pend[:k]); pend = pend[k:]
        else:
            feed(pend); pend = ""
    while plan and time.time() - t0 >= plan[0][0]:
        _, a = plan.pop(0)
        n += 1
        dump(n)
        if a == "TERM":
            os.kill(pid, signal.SIGTERM)
        elif a.startswith("SH:"):
            subprocess.run(a[3:], shell=True)
        else:
            os.write(fd, a.encode())
    w, status = os.waitpid(pid, os.WNOHANG)
    if w:
        done = os.waitstatus_to_exitcode(status)
        break
if done is None:
    try:
        w, status = os.waitpid(pid, 0); done = os.waitstatus_to_exitcode(status)
    except ChildProcessError:
        pass
open(prefix + ".raw", "wb").write(raw)
print(done)
