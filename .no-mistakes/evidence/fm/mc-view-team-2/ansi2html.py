import re, sys, html
title = sys.argv[1]; fg = bg = None; out = []
def sgr(p):
    global fg, bg
    a = [int(x) if x else 0 for x in (p or "0").split(";")]; i = 0
    while i < len(a):
        v = a[i]
        if v == 0: fg = bg = None
        elif v in (38, 48) and i + 4 < len(a) and a[i+1] == 2:
            c = "#%02x%02x%02x" % tuple(a[i+2:i+5]); i += 4
            if v == 38: fg = c
            else: bg = c
        elif v == 39: fg = None
        elif v == 49: bg = None
        i += 1
for m in re.finditer(r"\x1b\[([0-9;]*)m|\x1b\[[0-9;?]*[A-Za-z]|[\s\S]", sys.stdin.read()):
    t = m.group(0)
    if m.group(1) is not None: sgr(m.group(1)); continue
    if t.startswith("\x1b"): continue
    st = (("color:%s;" % fg) if fg else "") + (("background:%s;" % bg) if bg else "")
    out.append('<span style="%s">%s</span>' % (st, html.escape(t)) if st and t != "\n" else html.escape(t))
print('<html><head><meta charset="utf-8"><style>body{background:#0d1117;margin:0;padding:12px}pre{font:13px/1.15 Menlo,monospace;color:#c9d1d9;margin:0}h1{font:13px sans-serif;color:#8b949e}</style></head><body><h1>%s</h1><pre>%s</pre></body></html>' % (html.escape(title), "".join(out)))
