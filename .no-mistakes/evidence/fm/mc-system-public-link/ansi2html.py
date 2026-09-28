# Replays a captured Mission Control pty stream (cursor moves + truecolor SGR) into an HTML page.
import re, sys, html
raw, cols, rows, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
data = open(raw, "rb").read().decode("utf-8", "replace")
q = data.rfind("\x1b[?1049l")          # stop before the screen is restored on q
data = data[:q] if q > 0 else data
cell = lambda: [" ", "#ddd", "#111", False]
grid = [[cell() for _ in range(cols)] for _ in range(rows)]
pos = [0, 0]; fg, bg, bold = "#ddd", "#111", False
tok = re.compile(r"\x1b\[([0-9;?<]*)([A-Za-z])|\x1b.|[\s\S]")
for m in tok.finditer(data):
    t, cmd = m.group(0), m.group(2)
    if cmd == "H":
        a = m.group(1).split(";") + ["1", "1"]; pos[:] = [int(a[0] or 1) - 1, int(a[1] or 1) - 1]
    elif cmd == "J":
        grid = [[cell() for _ in range(cols)] for _ in range(rows)]
    elif cmd == "m":
        p = [int(x) if x else 0 for x in m.group(1).split(";")] if m.group(1) else [0]
        i = 0
        while i < len(p):
            v = p[i]
            if v == 0: fg, bg, bold = "#ddd", "#111", False
            elif v == 1: bold = True
            elif v == 22: bold = False
            elif v in (38, 48) and i + 4 < len(p) and p[i + 1] == 2:
                c = "#%02x%02x%02x" % tuple(p[i + 2:i + 5])
                if v == 38: fg = c
                else: bg = c
                i += 4
            elif v == 39: fg = "#ddd"
            elif v == 49: bg = "#111"
            i += 1
    elif t.startswith("\x1b"):
        pass
    elif t in "\r\n":
        pass
    else:
        if 0 <= pos[0] < rows and 0 <= pos[1] < cols:
            grid[pos[0]][pos[1]] = [t, fg, bg, bold]
        pos[1] += 1
lines = []
for row in grid:
    s = ""
    for ch, f, b, bd in row:
        s += '<span style="color:%s;background:%s%s">%s</span>' % (f, b, ";font-weight:bold" if bd else "", html.escape(ch))
    lines.append(s)
open(out, "w").write('<html><body style="margin:0;background:#111"><pre style="font:13px/1.2 Menlo,monospace;margin:8px">%s</pre></body></html>' % "\n".join(lines))
