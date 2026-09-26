"""Drive `fm-mission-control.sh run` in a sized pty, snapshot the emulated screen (text + coloured HTML).
usage: drive.py <mc> <outprefix> <cols> <rows> <secs> <actions>
actions: "<t>=<keys>|SNAP:<name>|SH:<cmd>,..."  (keys may use \\e for ESC)"""
import os, pty, re, sys, struct, fcntl, termios, time, select, signal, html
mc, prefix, cols, rows, secs, actions = sys.argv[1:]
COLS, ROWS, SECS = int(cols), int(rows), float(secs)
plan = sorted((float(t), a) for t, a in (x.split("=", 1) for x in actions.split(",")))
blank = lambda: [[" ", None, None, False] for _ in range(COLS)]
grid = [blank() for _ in range(ROWS)]
st = {"r": 0, "c": 0, "fg": None, "bg": None, "b": False}
tok = re.compile(r"\x1b\[([0-9;?]*)([A-Za-z])|\x1b[()][0-9A-Za-z]|\x1b.|[\s\S]")
X256 = None
def x256(n):
    n = int(n)
    if n < 16:
        base = [(0,0,0),(205,0,0),(0,205,0),(205,205,0),(0,0,238),(205,0,205),(0,205,205),(229,229,229),
                (127,127,127),(255,0,0),(0,255,0),(255,255,0),(92,92,255),(255,0,255),(0,255,255),(255,255,255)]
        return base[n]
    if n < 232:
        n -= 16; v = [0, 95, 135, 175, 215, 255]
        return (v[n // 36], v[(n // 6) % 6], v[n % 6])
    g = 8 + (n - 232) * 10
    return (g, g, g)
def sgr(params):
    p = [x for x in params.split(";")] if params else ["0"]
    i = 0
    while i < len(p):
        v = int(p[i] or 0)
        if v == 0: st.update(fg=None, bg=None, b=False)
        elif v == 1: st["b"] = True
        elif v == 22: st["b"] = False
        elif v in (38, 48):
            key = "fg" if v == 38 else "bg"
            if p[i+1] == "2": st[key] = tuple(int(x) for x in p[i+2:i+5]); i += 4
            elif p[i+1] == "5": st[key] = x256(p[i+2]); i += 2
        elif v == 39: st["fg"] = None
        elif v == 49: st["bg"] = None
        i += 1
def feed(text):
    for m in tok.finditer(text):
        t = m.group(0)
        if m.group(2):
            k, a = m.group(2), m.group(1)
            if k == "H":
                q = a.split(";") + ["1", "1"]
                st["r"], st["c"] = int(q[0] or 1) - 1, int(q[1] or 1) - 1
            elif k == "J":
                for i in range(ROWS): grid[i] = blank()
            elif k == "K":
                if 0 <= st["r"] < ROWS:
                    for c in range(st["c"], COLS): grid[st["r"]][c] = [" ", st["fg"], st["bg"], st["b"]]
            elif k == "m" and "?" not in a:
                sgr(a)
        elif t.startswith("\x1b"):
            pass
        elif t == "\r": st["c"] = 0
        elif t == "\n": st["r"] += 1
        else:
            if 0 <= st["r"] < ROWS and 0 <= st["c"] < COLS:
                grid[st["r"]][st["c"]] = [t, st["fg"], st["bg"], st["b"]]
            st["c"] += 1
def snap(name):
    for i in range(ROWS): grid[i] = blank()
    st.update(r=0, c=0, fg=None, bg=None, b=False)
    feed("".join(rawtxt))
    txt = "\n".join("".join(c[0] for c in row).rstrip() for row in grid)
    open(prefix + "-" + name + ".txt", "w").write(txt + "\n")
    out = ['<html><head><meta charset="utf-8"><style>body{background:#111;margin:8px}pre{font:10.5px/13px Menlo,monospace;color:#ddd;background:#000;margin:0;display:inline-block}</style></head><body><pre>']
    for row in grid:
        for ch, fg, bg, b in row:
            s = []
            if fg: s.append("color:rgb(%d,%d,%d)" % fg)
            if bg: s.append("background:rgb(%d,%d,%d)" % bg)
            if b: s.append("font-weight:bold")
            out.append('<span style="%s">%s</span>' % (";".join(s), html.escape(ch)) if s else html.escape(ch))
        out.append("\n")
    out.append("</pre></body></html>")
    open(prefix + "-" + name + ".html", "w").write("".join(out))
pid, fd = pty.fork()
if pid == 0:
    os.execvp(mc, [mc, "run"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
os.kill(pid, signal.SIGWINCH)
import codecs
dec = codecs.getincrementaldecoder("utf-8")("replace")
rawtxt = []
t0, done = time.time(), None
while time.time() - t0 < SECS:
    r, _, _ = select.select([fd], [], [], 0.05)
    if r:
        try: chunk = os.read(fd, 1 << 16)
        except OSError: chunk = b""
        if not chunk: break
        rawtxt.append(dec.decode(chunk))
    while plan and plan[0][0] <= time.time() - t0:
        _, act = plan.pop(0)
        if act.startswith("SNAP:"): snap(act[5:])
        elif act.startswith("SH:"): os.system(act[3:])
        elif act == "TERM": os.kill(pid, signal.SIGTERM)
        else: os.write(fd, act.encode().decode("unicode_escape").encode())
    got, status = os.waitpid(pid, os.WNOHANG)
    if got: done = status; break
if done is None:
    os.kill(pid, signal.SIGKILL); _, done = os.waitpid(pid, 0)
print("exit", os.WEXITSTATUS(done) if os.WIFEXITED(done) else 128 + os.WTERMSIG(done))
