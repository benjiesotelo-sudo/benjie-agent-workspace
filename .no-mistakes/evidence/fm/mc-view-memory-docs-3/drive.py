"""Drive `fm-mission-control.sh run` in a real pty (170x50), emulate the colour grid, dump text+HTML per step.
usage: drive.py <mc.sh> <outprefix> <cols> <rows> "<t>=<keys>,..."   (keys: python-escaped)"""
import os, pty, re, sys, struct, fcntl, termios, time, select, signal, html, json
mc, prefix, cols, rows, actions = sys.argv[1:]
COLS, ROWS = int(cols), int(rows)
plan = sorted((float(t), a.encode().decode("unicode_escape")) for t, a in (x.split("=", 1) for x in actions.split(",")))
blank = lambda: (" ", None, None, False)
grid = [[blank() for _ in range(COLS)] for _ in range(ROWS)]
st = {"pos": [0, 0], "fg": None, "bg": None, "b": False}
tok = re.compile(r"\x1b\[([0-9;?<>]*)([A-Za-z@~])|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b.|[\s\S]")
def sgr(params):
    p = [int(x or 0) for x in params.split(";")] if params else [0]
    i = 0
    while i < len(p):
        c = p[i]
        if c == 0: st.update(fg=None, bg=None, b=False)
        elif c == 1: st["b"] = True
        elif c == 22: st["b"] = False
        elif c in (38, 48) and i + 1 < len(p) and p[i+1] == 2:
            st["fg" if c == 38 else "bg"] = "#%02x%02x%02x" % tuple(p[i+2:i+5]); i += 4
        elif c in (38, 48) and i + 1 < len(p) and p[i+1] == 5:
            i += 2
        elif c == 39: st["fg"] = None
        elif c == 49: st["bg"] = None
        i += 1
def feed(text):
    for m in tok.finditer(text):
        t = m.group(0); cmd = m.group(2)
        if cmd == "H":
            a = m.group(1).split(";") + ["1", "1"]
            st["pos"] = [int(a[0] or 1) - 1, int(a[1] or 1) - 1]
        elif cmd == "J":
            for r in grid: r[:] = [blank() for _ in range(COLS)]
        elif cmd == "m": sgr(m.group(1))
        elif cmd == "K":
            y, x = st["pos"]
            if 0 <= y < ROWS:
                for xx in range(x, COLS): grid[y][xx] = (" ", None, st["bg"], False)
        elif t.startswith("\x1b"): pass
        elif t == "\r": st["pos"][1] = 0
        elif t == "\n": st["pos"][0] += 1
        else:
            y, x = st["pos"]
            if 0 <= y < ROWS and 0 <= x < COLS: grid[y][x] = (t, st["fg"], st["bg"], st["b"])
            st["pos"][1] += 1
def text():
    return "\n".join("".join(c[0] for c in r).rstrip() for r in grid)
def to_html(title):
    out = ['<html><head><meta charset="utf-8"><title>%s</title><style>body{background:#0b0e13;margin:12px;font-family:Menlo,monospace}'
           'pre{font-size:13px;line-height:1.18;color:#c9d1d9;background:#0b0e13;margin:0}h3{color:#8b949e;font:13px sans-serif}</style></head><body><h3>%s</h3><pre>' % (html.escape(title), html.escape(title))]
    for r in grid:
        for ch, fg, bg, b in r:
            s = ""
            if fg: s += "color:%s;" % fg
            if bg: s += "background:%s;" % bg
            if b: s += "font-weight:bold;"
            e = html.escape(ch)
            out.append('<span style="%s">%s</span>' % (s, e) if s else e)
        out.append("\n")
    out.append("</pre></body></html>")
    return "".join(out)
def emulate():
    for r in grid: r[:] = [blank() for _ in range(COLS)]
    st.update(pos=[0, 0], fg=None, bg=None, b=False)
    feed(bytes(raw).decode("utf-8", "replace"))
pid, fd = pty.fork()
if pid == 0:
    os.execvp(mc, [mc, "run"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
os.kill(pid, signal.SIGWINCH)
raw, t0, step, code = bytearray(), time.time(), 0, None
while time.time() - t0 < 30:
    r, _, _ = select.select([fd], [], [], 0.05)
    if r:
        try: chunk = os.read(fd, 65536)
        except OSError: chunk = b""
        if chunk:
            raw += chunk
    while plan and time.time() - t0 >= plan[0][0]:
        _, keys = plan.pop(0); step += 1
        emulate()
        open("%s.step%02d.txt" % (prefix, step), "w").write(text() + "\n")
        open("%s.step%02d.html" % (prefix, step), "w").write(to_html("before step %d, then sending %r" % (step, keys)))
        os.write(fd, keys.encode())
    w, s = os.waitpid(pid, os.WNOHANG)
    if w:
        code = os.waitstatus_to_exitcode(s); break
open(prefix + ".raw", "wb").write(bytes(raw))
print("exit", code)
