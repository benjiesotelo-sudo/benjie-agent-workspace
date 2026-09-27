#!/usr/bin/env python3
"""Drive the live Mission Control screen (fm-mission-control.sh run) in a 170x50 pty and save rendered frames.

Usage: drive_mc_pty.py <repo root> <fixture tmp root> <out dir> [<suffix>: System view only]
Each frame is written as <name>.txt (the screen text) and <name>.html (the screen with its colours).
"""
import fcntl, html, os, pty, select, struct, sys, termios, time
import pyte

root, tmp, out = sys.argv[1:4]
COLS, ROWS = 170, 50
env = dict(os.environ, FM_HOME=tmp + "/demoship", FM_BRIDGE_STATE_DIR=tmp + "/bridge-run",
           FM_BRIDGE_TAILSCALE=tmp + "/fakebin/tailscale-down", FM_BRIDGE_AGENT_DIR=tmp + "/launch-agents",
           PATH=tmp + "/fakebin:" + os.environ["PATH"], TERM="xterm-256color", COLUMNS=str(COLS), LINES=str(ROWS))
screen = pyte.Screen(COLS, ROWS)
stream = pyte.ByteStream(screen)

pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
    os.execvpe("bash", ["bash", root + "/bin/fm-mission-control.sh", "run"], env)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))


def drain(seconds):
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                data = os.read(fd, 65536)
            except OSError:
                return
            if not data:
                return
            stream.feed(data)


def text():
    return "\n".join(line.rstrip() for line in screen.display)


def save(name):
    with open(os.path.join(out, name + ".txt"), "w") as fh:
        fh.write(text() + "\n")
    rows = []
    for y in range(ROWS):
        line = screen.buffer[y]
        cells = []
        for x in range(COLS):
            ch = line[x]
            fg = ch.fg if ch.fg != "default" else "d8d4c8"
            bg = ch.bg if ch.bg != "default" else "1b1a17"
            fg = fg if all(c in "0123456789abcdefABCDEF" for c in fg) and len(fg) == 6 else {"white": "eeeeee", "black": "111111", "red": "e06c5a", "green": "7fc59a", "yellow": "e0c060", "blue": "7aa2d8", "magenta": "c08ad8", "cyan": "6cc0c8", "brightblack": "777777"}.get(fg, "d8d4c8")
            bg = bg if all(c in "0123456789abcdefABCDEF" for c in bg) and len(bg) == 6 else {"black": "111111", "white": "eeeeee"}.get(bg, "1b1a17")
            if ch.reverse:
                fg, bg = bg, fg
            style = "color:#%s;background:#%s%s" % (fg, bg, ";font-weight:700" if ch.bold else "")
            cells.append('<span style="%s">%s</span>' % (style, html.escape(ch.data or " ")))
        rows.append("".join(cells))
    with open(os.path.join(out, name + ".html"), "w") as fh:
        fh.write("<!doctype html><meta charset=utf-8><body style='margin:0;background:#1b1a17'>"
                 "<pre style='font:13px/1.15 Menlo,monospace;margin:8px'>%s</pre>" % "\n".join(rows))


def wait_for(needle, seconds):
    end = time.time() + seconds
    while time.time() < end:
        drain(0.5)
        if needle in text():
            return True
    return False


drain(4)
system_only = len(sys.argv) > 4
if not system_only:
    os.write(fd, b"8")
    wait_for("IMPORTANT LINKS", 20)
    drain(1.5)
    save("mc-docs-initial")
    os.write(fd, b"\x1b[B")
    drain(1.5)
    save("mc-docs-after-down")
    os.write(fd, b"\x1b[A")
    drain(1.5)
    os.write(fd, b"\x1b[A")
    drain(1.5)
    save("mc-docs-after-up-to-pins")
    for _ in range(8):
        os.write(fd, b"\x1b[A")
        drain(0.4)
    drain(1)
    save("mc-docs-system-map-link")
os.write(fd, b"9")
ok = wait_for("Open in Safari" if not system_only else "System Map: opens once", 90)
drain(2)
save("mc-system-view" + ("-" + sys.argv[4] if system_only else ""))
print("system card showed its address:", ok)
os.write(fd, b"q")
drain(1)
try:
    os.kill(pid, 15)
except OSError:
    pass
