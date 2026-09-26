# Live pty driver: runs `fm-mission-control.sh run` at COLSxROWS, sends timed
# actions, emulates the screen with colours, writes text + HTML per capture.
import os, pty, re, sys, struct, fcntl, termios, time, select, signal, html, json
mc, out, cols, rows, plan_json = sys.argv[1:6]
COLS, ROWS = int(cols), int(rows)
plan = json.loads(plan_json)   # [[seconds, keys_or_null, capture_name_or_null], ...]
grid = [[(" ", 0xc3cbd5, 0x0b0f14, False)] * COLS for _ in range(ROWS)]
st = {"pos": [0, 0], "fg": 0xc3cbd5, "bg": 0x0b0f14, "bold": False}
tok = re.compile(r"\x1b\[([0-9;?]*)([A-Za-z])|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b.|[\s\S]")
seen_osc = []
def feed(text):
    for m in tok.finditer(text):
        t = m.group(0)
        if t.startswith("\x1b]"):
            seen_osc.append(t); continue
        c = m.group(2)
        if c == "H":
            a = m.group(1).split(";") + ["1", "1"]
            st["pos"] = [int(a[0] or 1) - 1, int(a[1] or 1) - 1]
        elif c == "J":
            for r in grid: r[:] = [(" ", st["fg"], st["bg"], False)] * COLS
        elif c == "m":
            p = [int(x) if x else 0 for x in (m.group(1) or "0").split(";")]
            i = 0
            while i < len(p):
                v = p[i]
                if v == 0: st.update(fg=0xc3cbd5, bg=0x0b0f14, bold=False)
                elif v == 1: st["bold"] = True
                elif v == 22: st["bold"] = False
                elif v in (38, 48) and i + 4 < len(p) and p[i+1] == 2:
                    st["fg" if v == 38 else "bg"] = (p[i+2] << 16) | (p[i+3] << 8) | p[i+4]; i += 4
                i += 1
        elif not t.startswith("\x1b") and t not in "\r\n":
            r, cc = st["pos"]
            if 0 <= r < ROWS and 0 <= cc < COLS:
                grid[r][cc] = (t, st["fg"], st["bg"], st["bold"])
            st["pos"][1] += 1
def dump(name):
    for r in grid: r[:] = [(" ", 0xc3cbd5, 0x0b0f14, False)] * COLS
    st.update(pos=[0, 0], fg=0xc3cbd5, bg=0x0b0f14, bold=False); seen_osc.clear()
    feed(bytes(raw).decode("utf-8", "replace"))
    text = "\n".join("".join(c[0] for c in row).rstrip() for row in grid)
    open(os.path.join(out, name + ".txt"), "w").write(text + "\n")
    h = ['<!doctype html><meta charset="utf-8"><title>%s</title><style>body{background:#0b0f14;margin:0;padding:8px}pre{font:13px/1.15 Menlo,monospace;margin:0}</style><pre>' % html.escape(name)]
    for row in grid:
        run, key = [], None
        for ch, fg, bg, b in row:
            k = (fg, bg, b)
            if k != key:
                if key is not None: h.append("</span>")
                h.append('<span style="color:#%06x;background:#%06x%s">' % (fg, bg, ";font-weight:bold" if b else ""))
                key = k
            h.append(html.escape(ch))
        h.append("</span>\n")
    h.append("</pre>")
    open(os.path.join(out, name + ".html"), "w").write("".join(h))
pid, fd = pty.fork()
if pid == 0:
    os.execvp(mc, [mc, "run"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
os.kill(pid, signal.SIGWINCH)
raw, t0, done = bytearray(), time.time(), None
plan.sort(key=lambda x: x[0])
while time.time() - t0 < 60:
    r, _, _ = select.select([fd], [], [], 0.05)
    if r:
        try: chunk = os.read(fd, 1 << 16)
        except OSError: chunk = b""
        if not chunk: break
        raw += chunk
    while plan and plan[0][0] <= time.time() - t0:
        _, keys, cap = plan.pop(0)
        if cap: dump(cap)
        if keys: os.write(fd, keys.encode())
    got, status = os.waitpid(pid, os.WNOHANG)
    if got: done = status; break
if done is None:
    os.kill(pid, signal.SIGKILL); _, done = os.waitpid(pid, 0)
open(os.path.join(out, "session.raw"), "wb").write(bytes(raw))
dump("_final")
print("exit", os.WEXITSTATUS(done) if os.WIFEXITED(done) else -1, "osc8", sum("]8;" in s for s in seen_osc))
