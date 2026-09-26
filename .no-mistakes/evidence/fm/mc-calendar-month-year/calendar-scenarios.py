# Drives bin/fm-mission-control.sh frame --view calendar against an isolated fixture home.
import re, sys
sys.path.insert(0, "/tmp/fmcal.IuwZ")
from cal import frame, tap_at, save, bar
ok = []
def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else "  :: " + detail))
    ok.append(cond)
RIGHT, LEFT = "\x1b[C", "\x1b[D"

# S1 Month default
t = save("month-170x50", "Month (default), today Sat 26 Sep 2026, 170x50")
b = bar(t)
check("month: bar shows Week|Month|Year, arrows, title, this month", re.search(r"Week │ Month │ Year +◂ +September 2026 +▸ +this month", b) is not None, b)
check("month: no back to today on current period", "back to today" not in b, b)
body = "\n".join(t.split("\n")[9:])
nums = [int(n) for n in re.findall(r"[┌├][ ─]*?(?:(?<=[┌├┬┼] )|(?<=[┬┼] ))(\d+)", body)]
cells = re.findall(r"[┌├┬┼] (\d+)(?: Oct| today)? ", body)
check("month: every day 1..30 of September appears, plus neighbours 30,31 Aug and 1..3 Oct", cells == ["30","31"]+[str(i) for i in range(1,31)]+["1","2","3"], str(cells))
check("month: five week rows for September 2026", body.count("├") == 4 * 1 + 0 or len(re.findall(r"^├", body, re.M)) == 4, "")
check("month: today cell labelled", "26 today" in body)
check("month: +N more on a crowded day", "+3 more" in body)
check("month: done item marked with ✓, due item with ●", "✓ Chapter five slides" in body and "● Book the lecture" in body)
check("month: title date 27 September (a Sunday, mismatched weekday) is not guessed onto grid", "Review the syllabus" not in body)
foot = [l for l in t.split("\n") if l.strip()][-1]
check("month: footer lists left/right, t, v", all(k in foot for k in ("left/right", "t today", "v week, month or year")), foot)
check("no em dash anywhere", "—" not in t)
check("no raw task ids / paths", not re.search(r"\b(h1|t[1-5]|w[124]|b[1-8]|e1|f[1-3]|j1)\b", t) and "/tmp" not in t)
a = frame(fmt="ansi")
rows = a.split("\n")
wk1 = rows[10]
check("month: neighbour-day numbers 30, 31 (Aug) drawn DIMMER not bold; Sep 1 bold INK", re.search(r"22;38;2;93;103;115;48;2;\d+;\d+;\d+m30 ", wk1) is not None and re.search(r"22;38;2;93;103;115;48;2;\d+;\d+;\d+m31 ", wk1) is not None and re.search(r"1;38;2;217;224;232;48;2;\d+;\d+;\d+m1 ", wk1) is not None, repr(wk1[:300]))
check("month: today's number 26 drawn on green background", re.search(r"1;38;2;12;14;18;48;2;53;208;127m26 ", a) is not None)

# S2 132x44 and narrow 96 month
t = save("month-132x44", "Month, 132x44")
cells = re.findall(r"[┌├┬┼] (\d+)(?: Oct| today)? ", t)
check("month 132x44: all 35 cells present", len(cells) == 35, str(cells))
t = save("month-96x40", "Month, narrow 96x40", size="96x40")
cells = re.findall(r"[┌├┬┼] (\d+)(?: Oct| today)? ", t)
check("month 96x40: never drops days (35 cells)", len(cells) == 35, str(cells))
check("month 96x40: item lines shortened with ...", "..." in t)

# S3 Year
t = save("year-170x50", "Year (v), 170x50", keys="v")
b = bar(t)
check("year: bar 2026 this year", re.search(r"◂ +2026 +▸ +this year", b) is not None, b)
months = ["January","February","March","April","May","June","July","August","September","October","November","December"]
check("year: all twelve month names", all(m in t for m in months))
a = frame(fmt="ansi", keys="v")
check("year: today (26) drawn on green", "48;2;53;208;127m26" in a, "")
t2 = save("year-132x44", "Year (v), 132x44", size="132x44", keys="v")
check("year 132x44: all twelve months", all(m in t2 for m in months))
check("year: counts per month e.g. February 3 done", "3 done" in t, "")

# S4 Week
t = save("week-170x50", "Week (v v), 170x50", keys="vv")
check("week: 20 to 26 September this week, 7 days", re.search(r"◂ +20 to 26 September +▸ +this week", bar(t)) is not None and all(d in t for d in ("Sun 20","Sat 26")), bar(t))

# S5 active mode highlighted in the ANSI bar
for keys, m in (("", "Month"), ("v", "Year"), ("vv", "Week")):
    a = frame(fmt="ansi", keys=keys).split("\n")[3]
    greens = re.findall(r"1;38;2;12;14;18;48;2;53;208;127m(\w+) ", a)
    check("bar: only the active segment %s drawn bold on green" % m, [g for g in greens if g in ("Week","Month","Year")] == [m], str(greens))

# S6 keys
t = frame(keys=RIGHT); b = bar(t)
check("key right: October 2026 next month + back to today", "October 2026" in b and "next month" in b and "back to today" in b, b)
t = frame(keys=LEFT+LEFT); b = bar(t)
check("key left left: July 2026 2 months ago", "July 2026" in b and "2 months ago" in b, b)
check("six-row month: August via left", len(re.findall(r"[┌├┬┼] (\d+)(?: \w+)? ", frame(keys=LEFT))) == 42)
t = frame(keys=RIGHT*3+"t"); check("key t returns to this month", "September 2026" in bar(t) and "this month" in bar(t), bar(t))
t = frame(keys="v"+RIGHT); check("year + right: 2027 next year", re.search(r"2027 +▸ +next year", bar(t)) is not None, bar(t))
t = frame(keys="vv"+LEFT); check("week + left: last week", "last week" in bar(t), bar(t))
t = frame(keys="vvv"); check("v cycles back to Month after Week", "September 2026" in bar(t) and "this month" in bar(t), bar(t))
t = frame(keys="\r\nq"+RIGHT); check("Enter and q ignored in --keys", "October 2026" in bar(t), bar(t))

# S7 February 2026 and six-row month snapshots
t = save("month-feb-2026", "February 2026 (left x7): four-week month padded to five rows", keys=LEFT*7)
cells = re.findall(r"[┌├┬┼] (\d+)(?: \w+)? ", t)
check("February 2026: 5 rows, 1..28 then 1..7 March", cells == [str(i) for i in range(1,29)]+[str(i) for i in range(1,8)], str(cells))
check("February: items in Feb 10", "February kickoff" in t or "February deck" in t)
t = save("month-aug-2026", "August 2026 (left): six-row month", keys=LEFT)
cells = re.findall(r"[┌├┬┼] (\d+)(?: \w+)? ", t)
check("August 2026: six rows (42 cells) incl. 1..31", len(cells) == 42 and cells[6:37] == [str(i) for i in range(1,32)], str(cells))

# S8 taps
base = frame()
t = frame(keys=tap_at(base, " Year ", 3)); check("tap Year segment -> Year", "this year" in bar(t), bar(t))
t = frame(keys=tap_at(base, " Week ", 3)); check("tap Week segment -> Week", "this week" in bar(t), bar(t))
t = frame(keys=tap_at(base, " ▸ ", 3)); check("tap ▸ -> next month", "October 2026" in bar(t), bar(t))
t = frame(keys=tap_at(base, " ◂ ", 3)); check("tap ◂ -> last month", "August 2026" in bar(t), bar(t))
nm = frame(keys=RIGHT)
t = save("month-tap-back-to-today", "October 2026 then tap back to today", keys=RIGHT+tap_at(nm, "back to today", 3))
check("tap back to today -> this month", "September 2026" in bar(t) and "this month" in bar(t), bar(t))
t = frame(keys=RIGHT+tap_at(nm, "next month", 3)); check("adversarial: tapping the relative label does nothing (display-only)", "October 2026" in bar(t) and "next month" in bar(t), bar(t))
yr = frame(keys="v")
t = save("year-tap-february", "Year, tap February -> Month February 2026", keys="v"+tap_at(yr, "February"))
check("tap February in Year -> Month February 2026", "February 2026" in bar(t) and "7 months ago" in bar(t), bar(t))
t = frame(keys=tap_at(base, "Sunday", 9)); check("adversarial: tapping inside the grid changes nothing", "September 2026" in bar(t) and "this month" in bar(t), bar(t))

# S9 narrow week labels, today 2026-09-29, 96 columns
N = "2026-09-29T10:00:00"
t = save("week-narrow-today", "Narrow Week 96x36, today Tue 29 Sep", size="96x36", keys="vv", now=N)
check("narrow week at today: this week, today shown", "this week" in bar(t) and "Tue 29" in t, bar(t))
seq = [(RIGHT+"vv", "next week"), (RIGHT+"vv"+RIGHT, "in 2 weeks"), (RIGHT+"vv"+RIGHT+RIGHT, "in 3 weeks"),
       ("vv"+LEFT, "last week"), ("vv"+LEFT+LEFT, "2 weeks ago"), (RIGHT+"vv"+LEFT, "last week")]
for k, want in seq:
    t = frame(size="96x36", keys=k, now=N); b = bar(t)
    shown_today = "Tue 29" in t
    check("narrow week %r -> %s, back to today shown, today not in grid" % (k, want), want in b and "back to today" in b and not shown_today, b)
t = save("week-narrow-oct1", "Narrow Week 96x36, today Tue 29 Sep, keys right v v", size="96x36", keys=RIGHT+"vv", now=N)
t = frame(size="96x36", keys=RIGHT+"vv"+"t", now=N)
check("narrow week: t from Oct 1 week returns to this week with today shown", "this week" in bar(t) and "Tue 29" in t, bar(t))

# S10 frame without --agents asks Herdr
print("frame without --agents:")
t = frame(agents=False, herdr="/tmp/fmcal.IuwZ/fakebin/herdr-ok")
check("frame asks Herdr: live mate window -> Alpha asleep", "● Alpha asleep" in t, t.split("\n")[6])
t = save("frame-herdr-silent", "frame without --agents, Herdr silent", agents=False, herdr="/tmp/fmcal.IuwZ/fakebin/herdr")
check("Herdr silent -> Alpha unknown, never closed", "● Alpha unknown" in t and "Alpha closed" not in t, t.split("\n")[6])
t = frame(agents=False, herdr="/tmp/fmcal.IuwZ/fakebin/herdr-empty")
check("Herdr answers with no mate pane -> Alpha closed", "● Alpha closed" in t, t.split("\n")[6])
print("ALL PASS" if all(ok) else "SOME FAILED: %d" % ok.count(False))
