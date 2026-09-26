Live Mission Control runs (bin/fm-mission-control.sh run in a 170x50 pty, isolated fixture home built by setup-lab.sh, fake herdr).
drive.py sends keys on a schedule and snapshots the emulated screen before each step: <run>.stepNN.txt/.html/.png, <run>.raw = every byte written.
memory.*: 7 -> down x5 -> Enter -> q (captain page, lessons, Today/Yesterday journal days, Enter inert)
docs.*:   8 -> right x3 (Report, Decision, Link) -> down -> left x3 -> PgDn -> wheel -> sideways wheel -> tap row -> Enter -> down x2 (escape-laden report) -> q
scroll.*: 8 -> PgDn (1-38 -> 37-74) -> wheel down (40-77) -> sideways wheel (unchanged) -> wheel up (37-74) -> PgUp (1-38) -> q
