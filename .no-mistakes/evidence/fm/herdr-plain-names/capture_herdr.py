"""Attach a real Herdr client in a sized pty, let it draw, and render the grid to HTML."""
import fcntl, html, os, pty, select, signal, struct, subprocess, sys, termios, time
import pyte

session, config, out_html, title = sys.argv[1:5]
keys = sys.argv[5].encode().decode("unicode_escape").encode("latin1") if len(sys.argv) > 5 else b""
COLS, ROWS = 150, 42
master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
env = dict(os.environ, HERDR_CONFIG_PATH=config, TERM="xterm-256color", HERDR_SESSION=session)
for k in ("HERDR_ENV", "HERDR_PANE_ID", "HERDR_TAB_ID", "HERDR_WORKSPACE_ID", "HERDR_SOCKET_PATH"):
    env.pop(k, None)
p = subprocess.Popen(["herdr", "--session", session], stdin=slave, stdout=slave, stderr=slave,
                     env=env, start_new_session=True, close_fds=True)
os.close(slave)
screen = pyte.Screen(COLS, ROWS)
stream = pyte.ByteStream(screen)
end = time.time() + 6
sent = not keys
while time.time() < end:
    r, _, _ = select.select([master], [], [], 0.2)
    if r:
        try:
            data = os.read(master, 65536)
        except OSError:
            break
        if not data:
            break
        stream.feed(data)
    if not sent and time.time() > end - 4:
        for chunk in keys.split(b"|"):
            os.write(master, chunk); time.sleep(0.7)
        sent = True; end += 4
# Detach politely (prefix + d is Herdr's detach), then make sure the client is gone.
try:
    os.write(master, b"\x02d")
    time.sleep(0.5)
except OSError:
    pass
if p.poll() is None:
    os.killpg(p.pid, signal.SIGTERM)
    try:
        p.wait(3)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)

NAMED = {"black": "#1e1e1e", "red": "#e06c75", "green": "#98c379", "brown": "#e5c07b", "yellow": "#e5c07b",
         "blue": "#61afef", "magenta": "#c678dd", "cyan": "#56b6c2", "white": "#dcdfe4",
         "brightblack": "#7f848e", "brightred": "#e06c75", "brightgreen": "#98c379", "brightyellow": "#e5c07b",
         "brightblue": "#61afef", "brightmagenta": "#c678dd", "brightcyan": "#56b6c2", "brightwhite": "#ffffff"}
def col(c, default):
    if c == "default":
        return default
    if c in NAMED:
        return NAMED[c]
    if len(c) == 6:
        return "#" + c
    return default
rows = []
for y in range(ROWS):
    line = screen.buffer[y]
    parts = []
    for x in range(COLS):
        ch = line[x]
        fg, bg = col(ch.fg, "#dcdfe4"), col(ch.bg, "#1e1e1e")
        if ch.reverse:
            fg, bg = bg, fg
        style = "color:%s;background:%s;" % (fg, bg)
        if ch.bold:
            style += "font-weight:bold;"
        if getattr(ch, "italics", False):
            style += "font-style:italic;"
        parts.append('<span style="%s">%s</span>' % (style, html.escape(ch.data or " ")))
    rows.append("".join(parts))
doc = """<!doctype html><meta charset="utf-8"><title>%s</title>
<style>body{background:#111;color:#ddd;font-family:-apple-system,sans-serif;margin:16px}
pre{font-family:Menlo,monospace;font-size:13px;line-height:1.25;background:#1e1e1e;padding:8px;display:inline-block;margin:0}
h1{font-size:15px;font-weight:600}</style><h1>%s</h1><pre>%s</pre>""" % (html.escape(title), html.escape(title), "\n".join(rows))
open(out_html, "w").write(doc)
open(out_html.replace(".html", ".txt"), "w").write("\n".join("".join(screen.buffer[y][x].data for x in range(COLS)).rstrip() for y in range(ROWS)))
print("captured", out_html)
