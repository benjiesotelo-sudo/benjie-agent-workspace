import html, re, sys
title = sys.argv[1]
text = sys.stdin.read()
tok = re.compile(r"\x1b\[([0-9;]*)m|([^\x1b]+)")
out = []
fg, bg, bold = "d9e0e8", "0c0e12", False
for line in text.split("\n"):
    row = []
    for m in tok.finditer(line):
        if m.group(1) is not None:
            p = [int(x) for x in m.group(1).split(";") if x] or [0]
            i = 0
            while i < len(p):
                v = p[i]
                if v == 0: fg, bg, bold = "d9e0e8", "0c0e12", False
                elif v == 1: bold = True
                elif v == 22: bold = False
                elif v in (38, 48) and p[i+1] == 2:
                    c = "%02x%02x%02x" % tuple(p[i+2:i+5])
                    if v == 38: fg = c
                    else: bg = c
                    i += 4
                i += 1
        else:
            row.append('<span style="color:#%s;background:#%s;%s">%s</span>' % (fg, bg, "font-weight:bold" if bold else "", html.escape(m.group(2))))
    out.append("".join(row))
print("""<!doctype html><html><head><meta charset="utf-8"><title>%s</title><style>
body{background:#0c0e12;margin:0;padding:12px}h1{color:#9aa;font:13px monospace;margin:0 0 8px}
pre{font:13px/1.15 Menlo,Monaco,monospace;margin:0;white-space:pre}</style></head><body><h1>%s</h1><pre>%s</pre></body></html>""" % (html.escape(title), html.escape(title), "\n".join(out)))
