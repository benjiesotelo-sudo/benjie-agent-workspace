"""Render `frame --format ansi` output (line-based, truecolor SGR) to an HTML page."""
import re, sys, html
tok = re.compile(r"\x1b\[([0-9;]*)m|[\s\S]")
out = ['<html><head><meta charset="utf-8"><style>body{background:#0b0f14;margin:0;padding:12px}'
       'pre{font:13px/1.0 Menlo,monospace;margin:0;color:#ccc} span{display:inline-block;height:13px}</style></head><body><pre>']
fg = bg = None; b = False
for line in sys.stdin.read().split("\n"):
    for m in tok.finditer(line):
        if m.group(0).startswith("\x1b"):
            p = [int(x) if x else 0 for x in (m.group(1) or "0").split(";")]; i = 0
            while i < len(p):
                v = p[i]
                if v == 0: fg = bg = None; b = False
                elif v == 1: b = True
                elif v == 22: b = False
                elif v in (38, 48) and p[i + 1:i + 2] == [2]:
                    c = "#%02x%02x%02x" % tuple(p[i + 2:i + 5]); i += 4
                    if v == 38: fg = c
                    else: bg = c
                i += 1
        else:
            s = "color:%s;" % (fg or "#ccc") + ("background:%s;" % bg if bg else "") + ("font-weight:bold;" if b else "")
            out.append('<span style="%s">%s</span>' % (s, html.escape(m.group(0))))
    out.append("\n")
out.append("</pre></body></html>")
sys.stdout.write("".join(out))
