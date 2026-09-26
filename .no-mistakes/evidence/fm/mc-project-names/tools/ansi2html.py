#!/usr/bin/env python3
"""Emulate a truecolor terminal grid from Mission Control output and write HTML.

usage: ansi2html.py <cols> <rows> <in> <out.html> [title]
Handles CUP (H), ED (J), EL (K), SGR 0/1/22/38;2/48;2/38;5/48;5 and newlines.
"""
import html, re, sys

cols, rows, src, out = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4]
title = sys.argv[5] if len(sys.argv) > 5 else src
data = open(src, "rb").read().decode("utf-8", "replace")
DEF_FG, DEF_BG = (217, 224, 232), (12, 14, 18)
grid = [[(" ", DEF_FG, DEF_BG, False) for _ in range(cols)] for _ in range(rows)]
fg, bg, bold = DEF_FG, DEF_BG, False
r = c = 0


def c256(n):
    if n < 16:
        base = [(0,0,0),(128,0,0),(0,128,0),(128,128,0),(0,0,128),(128,0,128),(0,128,128),(192,192,192),
                (128,128,128),(255,0,0),(0,255,0),(255,255,0),(0,0,255),(255,0,255),(0,255,255),(255,255,255)]
        return base[n]
    if n >= 232:
        v = 8 + 10 * (n - 232)
        return (v, v, v)
    n -= 16
    lv = [0, 95, 135, 175, 215, 255]
    return (lv[n // 36], lv[(n // 6) % 6], lv[n % 6])


tok = re.compile(r"\x1b\[([0-9;?<]*)([A-Za-z])|\x1b[^\[]|([\s\S])")
for m in tok.finditer(data):
    code, ch = m.group(2), m.group(3)
    if code:
        args = m.group(1)
        if args.startswith("?") or args.startswith("<"):
            continue
        a = [int(x) if x else 0 for x in args.split(";")] if args else []
        if code == "H":
            r = (a[0] if a and a[0] else 1) - 1
            c = (a[1] if len(a) > 1 and a[1] else 1) - 1
        elif code == "J":
            for row in grid:
                row[:] = [(" ", DEF_FG, DEF_BG, False)] * cols
        elif code == "K":
            if 0 <= r < rows:
                for x in range(c, cols):
                    grid[r][x] = (" ", fg, bg, False)
        elif code == "m":
            a = a or [0]
            i = 0
            while i < len(a):
                v = a[i]
                if v == 0:
                    fg, bg, bold = DEF_FG, DEF_BG, False
                elif v == 1:
                    bold = True
                elif v == 22:
                    bold = False
                elif v in (38, 48) and i + 1 < len(a):
                    if a[i + 1] == 2:
                        col = tuple(a[i + 2:i + 5]); i += 4
                    else:
                        col = c256(a[i + 2]); i += 2
                    if v == 38:
                        fg = col
                    else:
                        bg = col
                elif v == 39:
                    fg = DEF_FG
                elif v == 49:
                    bg = DEF_BG
                i += 1
    elif ch is not None:
        if ch == "\n":
            r += 1; c = 0
        elif ch == "\r":
            c = 0
        else:
            if 0 <= r < rows and 0 <= c < cols:
                grid[r][c] = (ch, fg, bg, bold)
            c += 1

parts = []
for row in grid:
    line, last, buf = [], None, ""
    for ch, f, b, bo in row:
        key = (f, b, bo)
        if key != last and buf:
            lf, lb, lbo = last
            line.append('<span style="color:rgb%s;background:rgb%s%s">%s</span>' % (lf, lb, ";font-weight:bold" if lbo else "", html.escape(buf)))
            buf = ""
        last = key
        buf += ch
    if buf:
        lf, lb, lbo = last
        line.append('<span style="color:rgb%s;background:rgb%s%s">%s</span>' % (lf, lb, ";font-weight:bold" if lbo else "", html.escape(buf)))
    parts.append("".join(line))
open(out, "w").write(
    "<!doctype html><meta charset=utf-8><title>%s</title><style>body{margin:0;background:#0c0e12}"
    "pre{margin:0;padding:8px;font:13px/15px Menlo,monospace;letter-spacing:0}"
    "h1{font:12px sans-serif;color:#aab3be;margin:6px 8px}</style><h1>%s</h1><pre>%s</pre>"
    % (html.escape(title), html.escape(title), "\n".join(parts)))
