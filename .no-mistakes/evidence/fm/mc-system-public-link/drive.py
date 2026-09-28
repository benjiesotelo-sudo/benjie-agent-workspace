# Drives `fm-mission-control.sh run` in a pseudo-terminal of COLSxROWS, presses the given keys at given times,
# writes <prefix>.raw and <prefix>.screen (the emulated screen at the end, before q).
import os, pty, re, sys, struct, fcntl, termios, time, select, signal
mc, prefix, cols, rows, actions = sys.argv[1:]
COLS, ROWS = int(cols), int(rows)
plan = sorted((float(t), a) for t, a in (x.split("=", 1) for x in actions.split(",")))
grid = [[" "] * COLS for _ in range(ROWS)]; pos = [0, 0]
tok = re.compile(r"\x1b\[([0-9;?]*)([A-Za-z])|\x1b.|[\s\S]")
def feed(text):
    for m in tok.finditer(text):
        t = m.group(0)
        if m.group(2) == "H":
            a = m.group(1).split(";") + ["1", "1"]; pos[:] = [int(a[0] or 1) - 1, int(a[1] or 1) - 1]
        elif m.group(2) == "J":
            for row in grid: row[:] = [" "] * COLS
        elif not t.startswith("\x1b") and t not in "\r\n":
            if 0 <= pos[0] < ROWS and 0 <= pos[1] < COLS: grid[pos[0]][pos[1]] = t
            pos[1] += 1
pid, fd = pty.fork()
if pid == 0:
    os.execvp(mc, [mc, "run"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0)); os.kill(pid, signal.SIGWINCH)
raw, t0, done, snap = bytearray(), time.time(), None, None
while time.time() - t0 < 40:
    r, _, _ = select.select([fd], [], [], 0.05)
    if r:
        try: chunk = os.read(fd, 1 << 16)
        except OSError: chunk = b""
        if not chunk: break
        raw += chunk
    while plan and plan[0][0] <= time.time() - t0:
        _, act = plan.pop(0)
        if act == "q": snap = len(raw)
        os.write(fd, act.encode())
    got, status = os.waitpid(pid, os.WNOHANG)
    if got: done = status; break
if done is None:
    os.kill(pid, signal.SIGKILL); _, done = os.waitpid(pid, 0)
open(prefix + ".raw", "wb").write(bytes(raw))
feed(bytes(raw[:snap or len(raw)]).decode("utf-8", "replace"))
open(prefix + ".screen", "w").write("\n".join("".join(r).rstrip() for r in grid) + "\n")
print("exit", os.WEXITSTATUS(done) if os.WIFEXITED(done) else 128 + os.WTERMSIG(done))
