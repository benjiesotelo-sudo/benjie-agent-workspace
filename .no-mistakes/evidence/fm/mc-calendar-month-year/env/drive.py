"""Drive `fm-mission-control.sh run` in a sized pty and snapshot the screen.

usage: drive.py <mc> <cols> <rows> <outdir> <plan>
plan is "name|keys;name|keys;..." applied 1.5 s apart after the first frame;
the screen is snapshotted (text + coloured HTML) just before each step, then q.
"""
import fcntl, html, os, pty, re, select, signal, struct, sys, termios, time

mc, cols, rows, out, plan = sys.argv[1:]
COLS, ROWS = int(cols), int(rows)
steps = [(s + "|").split("|")[:2] for s in plan.split(";") if s]
os.makedirs(out, exist_ok=True)
INK, BG = (0xd9, 0xe0, 0xe8), (0x0c, 0x0e, 0x12)
grid = [[(" ", INK, BG, False)] * COLS for _ in range(ROWS)]
st = {"pos": [0, 0], "fg": INK, "bg": BG, "bold": False}
tok = re.compile(r"\x1b\[([0-9;?<]*)([A-Za-z])|\x1b.|[\s\S]")


def feed(text):
    for m in tok.finditer(text):
        t, cmd = m.group(0), m.group(2)
        pos = st["pos"]
        if cmd:
            args = m.group(1)
            if args.startswith("?"):
                continue
            a = [int(x) if x else 0 for x in args.split(";")] if args else []
            if cmd == "H":
                a += [1, 1]
                pos[:] = [(a[0] or 1) - 1, (a[1] or 1) - 1]
            elif cmd == "J":
                for r in range(ROWS):
                    grid[r] = [(" ", INK, st["bg"], False)] * COLS
            elif cmd == "K":
                for c in range(pos[1], COLS):
                    if 0 <= pos[0] < ROWS:
                        grid[pos[0]][c] = (" ", INK, st["bg"], False)
            elif cmd == "C":
                pos[1] += a[0] if a else 1
            elif cmd == "m":
                a = a or [0]
                i = 0
                while i < len(a):
                    v = a[i]
                    if v == 0:
                        st.update(fg=INK, bg=BG, bold=False)
                    elif v == 1:
                        st["bold"] = True
                    elif v == 22:
                        st["bold"] = False
                    elif v in (38, 48) and i + 4 < len(a) and a[i + 1] == 2:
                        st["fg" if v == 38 else "bg"] = tuple(a[i + 2:i + 5])
                        i += 4
                    elif v == 39:
                        st["fg"] = INK
                    elif v == 49:
                        st["bg"] = BG
                    i += 1
        elif t.startswith("\x1b"):
            continue
        elif t == "\r":
            pos[1] = 0
        elif t == "\n":
            pos[0] += 1
        else:
            if 0 <= pos[0] < ROWS and 0 <= pos[1] < COLS:
                grid[pos[0]][pos[1]] = (t, st["fg"], st["bg"], st["bold"])
            pos[1] += 1


RAW = bytearray()


def snap(name):
    for r in range(ROWS):
        grid[r] = [(" ", INK, BG, False)] * COLS
    st.update(pos=[0, 0], fg=INK, bg=BG, bold=False)
    feed(bytes(RAW).decode("utf-8", "replace"))
    text = "\n".join("".join(c[0] for c in row).rstrip() for row in grid)
    open(os.path.join(out, name + ".txt"), "w").write(text + "\n")
    parts = []
    for row in grid:
        line, cur, buf = [], None, ""
        for ch, fg, bg, b in row:
            key = (fg, bg, b)
            if key != cur and buf:
                line.append('<span style="color:rgb%s;background:rgb%s;%s">%s</span>'
                            % (cur[0], cur[1], "font-weight:bold" if cur[2] else "", html.escape(buf)))
                buf = ""
            cur = key
            buf += ch
        if buf:
            line.append('<span style="color:rgb%s;background:rgb%s;%s">%s</span>'
                        % (cur[0], cur[1], "font-weight:bold" if cur[2] else "", html.escape(buf)))
        parts.append("".join(line))
    page = ("<!doctype html><meta charset=utf-8><title>%s</title><body style='margin:0;background:rgb%s'>"
            "<div style='padding:4px 8px;color:#aaa;font:12px sans-serif'>%s - %dx%d live pty</div>"
            "<pre style='margin:0;padding:8px;font:13px/1.2 Menlo,monospace'>%s</pre>"
            % (name, BG, html.escape(name), COLS, ROWS, "\n".join(parts)))
    open(os.path.join(out, name + ".html"), "w").write(page)
    return text


pid, fd = pty.fork()
if pid == 0:
    os.execvp(mc, [mc, "run"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
os.kill(pid, signal.SIGWINCH)


def pump(secs):
    end = time.time() + secs
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                chunk = os.read(fd, 1 << 16)
            except OSError:
                return False
            if not chunk:
                return False
            RAW.extend(chunk)
    return True


pump(3)
os.write(fd, b"5")      # the Calendar view
pump(1.5)
for name, keys in steps:
    text = snap(name)
    if keys.startswith("TAP:"):   # TAP:<needle>[@dx] - a left click on the needle's first letter + dx
        needle, _, dx = keys[4:].partition("@")
        lines = text.split("\n")
        i, j = next((i, ln.index(needle)) for i, ln in enumerate(lines) if needle in ln and i > 1)
        keys = "\x1b[<0;%d;%dM" % (j + 1 + int(dx or 1), i + 1)
        print(name, "tap", needle, "at row", i + 1, "col", j + 1 + int(dx or 1))
    keys = keys.encode().decode("unicode_escape")
    os.write(fd, keys.encode())
    pump(1.5)
snap("final")
os.write(fd, b"q")
pump(1)
_, status = os.waitpid(pid, 0)
print("exit", os.WEXITSTATUS(status) if os.WIFEXITED(status) else status)
