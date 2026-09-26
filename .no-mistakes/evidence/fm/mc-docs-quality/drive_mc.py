"""Drive `bin/fm-mission-control.sh run` in a 170x50 pty, emulate the screen,
and write each captured screen as text and as a coloured HTML page.
usage: drive_mc.py <mc> <out-prefix> "<sec>=<keys>,..."  (keys: DOWN UP ENTER PGDN or literal)"""
import os, pty, re, sys, struct, fcntl, termios, time, select, signal, html
mc, prefix, actions = sys.argv[1:4]
KEYS = {"DOWN": "\x1b[B", "UP": "\x1b[A", "ENTER": "\r", "PGDN": "\x1b[6~", "RIGHT": "\x1b[C"}
plan = sorted((float(t), a) for t, a in (x.split("=", 1) for x in actions.split(",")))
COLS, ROWS = 170, 50
blank = (" ", (220, 220, 220), (12, 13, 16), False)
grid = [[blank] * COLS for _ in range(ROWS)]
st = {"pos": [0, 0], "fg": (220, 220, 220), "bg": (12, 13, 16), "b": False}
tok = re.compile(r"\x1b\[([0-9;?<]*)([A-Za-z])|\x1b.|[\s\S]")
import codecs
dec = codecs.getincrementaldecoder("utf-8")("replace")
pend = [""]
def feed(text):
    text = pend[0] + text
    cut = text.rfind("\x1b")
    if cut >= 0 and not re.match(r"\x1b(\[[0-9;?<]*[A-Za-z]|[^\[])", text[cut:]):
        text, pend[0] = text[:cut], text[cut:]
    else:
        pend[0] = ""
    for m in tok.finditer(text):
        t, cmd = m.group(0), m.group(2)
        if cmd == "H":
            a = (m.group(1) or "").split(";") + ["1", "1"]
            st["pos"] = [int(a[0] or 1) - 1, int(a[1] or 1) - 1]
        elif cmd == "J":
            for r in range(ROWS): grid[r] = [blank] * COLS
        elif cmd == "m":
            p = [int(x) if x else 0 for x in (m.group(1) or "0").split(";")]
            i = 0
            while i < len(p):
                v = p[i]
                if v == 0: st.update(fg=blank[1], bg=blank[2], b=False)
                elif v == 1: st["b"] = True
                elif v == 22: st["b"] = False
                elif v in (38, 48) and p[i + 1] == 2:
                    st["fg" if v == 38 else "bg"] = tuple(p[i + 2:i + 5]); i += 4
                elif v in (38, 48) and p[i + 1] == 5: i += 2
                i += 1
        elif t.startswith("\x1b") or t in "\r\n":
            pass
        else:
            r, c = st["pos"]
            if 0 <= r < ROWS and 0 <= c < COLS:
                grid[r][c] = (t, st["fg"], st["bg"], st["b"])
            st["pos"][1] += 1
def snap(n):
    txt = "\n".join("".join(c[0] for c in row).rstrip() for row in grid)
    open("%s-%d.txt" % (prefix, n), "w").write(txt + "\n")
    rows = []
    for row in grid:
        out = []
        for ch, fg, bg, b in row:
            out.append('<span style="color:rgb%s;background:rgb%s%s">%s</span>' % (fg, bg, ";font-weight:bold" if b else "", html.escape(ch)))
        rows.append("".join(out))
    open("%s-%d.html" % (prefix, n), "w").write(
        '<!doctype html><meta charset="utf-8"><body style="margin:0;background:rgb(12,13,16)">'
        '<pre style="margin:0;font:14px/20px Menlo,monospace;letter-spacing:0">' + "\n".join(rows) + "</pre></body>")
pid, fd = pty.fork()
if pid == 0:
    os.execvp(mc, [mc, "run"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
os.kill(pid, signal.SIGWINCH)
t0, n, code = time.time(), 0, None
while time.time() - t0 < plan[-1][0] + 3:
    r, _, _ = select.select([fd], [], [], 0.05)
    if r:
        try: data = os.read(fd, 65536)
        except OSError: data = b""
        if data: feed(dec.decode(data))
    while plan and time.time() - t0 >= plan[0][0]:
        _t, a = plan.pop(0)
        if a == "SNAP":
            n += 1; snap(n); continue
        seq = "".join(KEYS.get(k, k) for k in a.split("+"))
        os.write(fd, seq.encode())
    if not plan:
        break
for _ in range(40):
    p, s = os.waitpid(pid, os.WNOHANG)
    if p: code = os.waitstatus_to_exitcode(s); break
    try: feed(dec.decode(os.read(fd, 65536)))
    except OSError: pass
    time.sleep(0.1)
print("exit", code, "snaps", n)
