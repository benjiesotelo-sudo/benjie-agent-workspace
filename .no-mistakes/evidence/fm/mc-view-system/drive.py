"""Drive `fm-mission-control.sh run` in a real pty with a non-zero window size.

usage: drive.py <mc> <out-prefix> <cols> <rows> <actions>
actions: "<secs>=<keys>|SH:<cmd>|SNAP:<name>|CPU:<name>:<secs>,..."
Each SNAP writes <prefix>-<name>.txt and .html (colours kept) of the emulated screen.
"""
import os, pty, re, sys, struct, fcntl, termios, time, select, signal, subprocess, html
mc, prefix, cols, rows, actions = sys.argv[1:]
COLS, ROWS = int(cols), int(rows)
plan = sorted((float(t), a) for t, a in (x.split("=", 1) for x in actions.split(",")))
blank = (" ", None, None, False)
grid = [[blank] * COLS for _ in range(ROWS)]
st = {"pos": [0, 0], "fg": None, "bg": None, "b": False}
tok = re.compile(r"\x1b\[([0-9;?]*)([A-Za-z])|\x1b.|[\s\S]")
import codecs
dec = codecs.getincrementaldecoder("utf-8")("replace")
pend = [""]
partial = re.compile(r"\x1b(\[[0-9;?]*)?$")


def feed(text):
    text = pend[0] + dec.decode(text)
    m = partial.search(text)
    pend[0] = text[m.start():] if m else ""
    text = text[:m.start()] if m else text
    for m in tok.finditer(text):
        t = m.group(0)
        g = m.group(2)
        if g == "H":
            a = m.group(1).split(";") + ["1", "1"]
            st["pos"] = [int(a[0] or 1) - 1, int(a[1] or 1) - 1]
        elif g == "J":
            for row in grid:
                row[:] = [blank] * COLS
        elif g == "m":
            p = [int(x) if x else 0 for x in m.group(1).split(";")] if m.group(1) else [0]
            i = 0
            while i < len(p):
                v = p[i]
                if v == 0: st.update(fg=None, bg=None, b=False)
                elif v == 1: st["b"] = True
                elif v == 22: st["b"] = False
                elif v in (38, 48) and i + 1 < len(p) and p[i + 1] == 2:
                    st["fg" if v == 38 else "bg"] = "#%02x%02x%02x" % tuple(p[i + 2:i + 5]); i += 4
                elif v in (38, 48) and i + 1 < len(p) and p[i + 1] == 5:
                    i += 2
                i += 1
        elif not t.startswith("\x1b") and t not in "\r\n":
            r, c = st["pos"]
            if 0 <= r < ROWS and 0 <= c < COLS:
                grid[r][c] = (t, st["fg"], st["bg"], st["b"])
            st["pos"][1] += 1


def snap(name):
    open("%s-%s.txt" % (prefix, name), "w").write("\n".join("".join(c[0] for c in row).rstrip() for row in grid) + "\n")
    out = ['<html><head><meta charset="utf-8"><style>body{background:#0b0f14;margin:0;padding:12px}'
           'pre{font:13px/1.0 Menlo,monospace;margin:0;color:#ccc} span{display:inline-block;height:13px}</style></head><body><pre>']
    for row in grid:
        for ch, fg, bg, b in row:
            s = "color:%s;" % (fg or "#cccccc") + ("background:%s;" % bg if bg else "") + ("font-weight:bold;" if b else "")
            out.append('<span style="%s">%s</span>' % (s, html.escape(ch)))
        out.append("\n")
    out.append("</pre></body></html>")
    open("%s-%s.html" % (prefix, name), "w").write("".join(out))


def cputime(pid):
    try:
        ps = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        mm, ss = ps.split(":")
        return int(mm) * 60 + float(ss)
    except Exception:
        return None


pid, fd = pty.fork()
if pid == 0:
    os.execvp(mc, [mc, "run"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
os.kill(pid, signal.SIGWINCH)
raw, t0, done, cpu = bytearray(), time.time(), None, {}
log = open(prefix + ".log", "w")
end = max(t for t, _ in plan) + 5
while time.time() - t0 < end:
    r, _, _ = select.select([fd], [], [], 0.05)
    if r:
        try:
            chunk = os.read(fd, 1 << 16)
        except OSError:
            chunk = b""
        if not chunk:
            break
        raw += chunk
        feed(chunk)
    while plan and plan[0][0] <= time.time() - t0:
        _, act = plan.pop(0)
        log.write("%.1fs %s\n" % (time.time() - t0, act if not act.startswith("\x1b") else repr(act)))
        if act.startswith("SNAP:"):
            snap(act[5:])
        elif act.startswith("SH:"):
            os.system(act[3:])
        elif act.startswith("CPU:"):
            _, name, secs = act.split(":")
            # the screen's python process: the child itself (the wrapper execs python) or its child
            kids = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True).stdout.split()
            target = pid
            a = cputime(target); w0 = time.time()
            # keep draining while measuring
            while time.time() - w0 < float(secs):
                rr, _, _ = select.select([fd], [], [], 0.05)
                if rr:
                    try:
                        chunk = os.read(fd, 1 << 16); raw += chunk; feed(chunk)
                    except OSError:
                        pass
            b = cputime(target)
            pct = 100.0 * (b - a) / (time.time() - w0) if a is not None and b is not None else None
            log.write("CPU %s: %.2f%% over %ss (pid %d, cpu %.2fs -> %.2fs)\n" % (name, pct, secs, target, a, b))
        else:
            os.write(fd, act.encode())
    got, status = os.waitpid(pid, os.WNOHANG)
    if got:
        done = status
        break
if done is None:
    os.kill(pid, signal.SIGKILL)
    _, done = os.waitpid(pid, 0)
open(prefix + ".raw", "wb").write(bytes(raw))
code = os.WEXITSTATUS(done) if os.WIFEXITED(done) else 128 + os.WTERMSIG(done)
log.write("exit %d\n" % code)
print(code)
