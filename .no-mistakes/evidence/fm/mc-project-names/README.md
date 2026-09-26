# Mission Control project names: live evidence

Fixture home named benjie-agent-workspace with the captain's six repositories, the names map from the intent (tools/fixture-mission-control.json), three second mates by project plus one with no project (ops-mate), and a Herdr agent list saved from fixtures.
The clock is pinned to Wed 23 Sep 2026 10:00.

- screenshots/live-*.png: `fm-mission-control.sh run` driven in a 170x50 pty (tools/drive.py), keys 1, 5, v, v, v, 6, 3, 4, q; the raw bytes are rendered by tools/ansi2html.py.
- screenshots/frame-*.png: `fm-mission-control.sh frame --format ansi` at 132x44, 170x50 and 96x36.
- frames/*.txt: the same frames as plain text.
- frames/always-running-base-vs-branch.txt: the always-running strip on base a032acf0a and on this branch, using the fixture, empty, and real `herdr agent list`.
