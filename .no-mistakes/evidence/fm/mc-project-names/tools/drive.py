#!/usr/bin/env python3
"""Drive `fm-mission-control.sh run` in a sized pty; snapshot raw bytes before each action.

usage: drive.py <mc> <cols> <rows> <out-prefix> <t=keys,...>
Writes <prefix>.<n>.raw: every byte written up to action n, and <prefix>.final.raw.
"""
import fcntl, os, pty, select, signal, struct, sys, termios, time

mc, cols, rows, prefix, actions = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5]
plan = sorted((float(t), a.encode().decode("unicode_escape")) for t, a in (x.split("=", 1) for x in actions.split(",")))
pid, fd = pty.fork()
if pid == 0:
    os.execvp(mc, [mc, "run"])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
os.kill(pid, signal.SIGWINCH)
raw, t0, n, done = bytearray(), time.time(), 0, None
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
    while plan and plan[0][0] <= time.time() - t0:
        _, act = plan.pop(0)
        n += 1
        open("%s.%d.raw" % (prefix, n), "wb").write(bytes(raw))
        os.write(fd, act.encode())
    got, status = os.waitpid(pid, os.WNOHANG)
    if got:
        done = status
        break
if done is None:
    os.kill(pid, signal.SIGKILL)
    _, done = os.waitpid(pid, 0)
open(prefix + ".final.raw", "wb").write(bytes(raw))
print("exit", os.WEXITSTATUS(done) if os.WIFEXITED(done) else 128 + os.WTERMSIG(done), "bytes", len(raw))
