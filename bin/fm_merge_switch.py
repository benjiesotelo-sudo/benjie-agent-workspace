"""fm_merge_switch.py - the merge switch: may the first mate merge green pull requests itself.

The switch is two Claude Code allow rules in the home's untracked
.claude/settings.local.json, under permissions.allow:

    Bash(bin/fm-pr-merge.sh *)
    Bash(<home>/bin/fm-pr-merge.sh *)

ON is both rules present, OFF is neither, and "partly on" is exactly one, which
still lets one spelling of the merge command through. bin/fm_controls.py is the
one place that changes it, when the captain taps the switch; Mission Control's
System view only reads it.

READ. read() parses the file each time it is called. A missing file is OFF. A
file that is not valid JSON, or whose top level, permissions or
permissions.allow has the wrong shape, reads as an error with no state, and
switch() then refuses to write, so the file is left exactly as it was. A null
permissions or permissions.allow counts as empty, in read() and switch() alike.

WRITE. switch() rereads the file, adds the missing rules (ON) or removes every
copy of exactly those two (OFF), and keeps every other key and entry in their
order. It writes only when something changes: to a temporary file in the same
directory, flushed, then renamed over the real file (through a symlink to its
target), keeping the old file's mode, so a failure leaves the old file whole.
A missing file is created on ON, with its .claude directory; OFF on a missing
file writes nothing. Before writing it makes sure git ignores the file: when
the home is a git work tree and `git check-ignore` does not already ignore
.claude/settings.local.json, it appends /.claude/settings.local.json to the
repository's info/exclude.

WHEN IT LAST CHANGED. Each change switch() makes is recorded in
state/merge-switch.json of the home as {"state": "on"|"off", "at": <epoch
seconds>}. read() reports that record as changed_here when it matches the
file's current state. When it does not (the file was edited or removed
elsewhere), or there is no record but the file exists, it reports
changed_outside, with the file's own modification time as changed_elsewhere
while the file is there.
"""

import json
import os
import subprocess
import tempfile
import time

SETTINGS = os.path.join(".claude", "settings.local.json")
RECORD = os.path.join("state", "merge-switch.json")
IGNORE_LINE = "/.claude/settings.local.json"


class SettingsError(Exception):
    """The settings file cannot be read as settings, so the switch cannot be read or set."""


def rules(home):
    return ["Bash(bin/fm-pr-merge.sh *)", "Bash(%s/bin/fm-pr-merge.sh *)" % home.rstrip("/")]


def settings_path(home):
    return os.path.join(home, SETTINGS)


def _load(path):
    """The parsed settings, None when the file does not exist."""
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except FileNotFoundError:
        return None
    except (OSError, UnicodeDecodeError) as exc:
        raise SettingsError("the settings file could not be read (%s)" % (getattr(exc, "strerror", None) or exc))
    if not text.strip():
        raise SettingsError("the settings file is empty, so it is not valid JSON")
    try:
        data = json.loads(text)
    except ValueError as exc:
        where = " (line %d, column %d)" % (exc.lineno, exc.colno) if hasattr(exc, "lineno") else ""
        raise SettingsError("the settings file is not valid JSON%s" % where)
    if not isinstance(data, dict):
        raise SettingsError("the settings file is JSON but not a settings object")
    perms = data.get("permissions")
    if perms is not None and not isinstance(perms, dict):
        raise SettingsError('the settings file\'s "permissions" is not an object')
    allow = (perms or {}).get("allow")
    if allow is not None and not isinstance(allow, list):
        raise SettingsError('the settings file\'s "permissions.allow" is not a list')
    return data


def _state(data, home):
    allow = ((data or {}).get("permissions") or {}).get("allow") or []
    have = sum(1 for r in rules(home) if r in allow)
    return "on" if have == 2 else "off" if have == 0 else "partial"


def _mtime(path):
    try:
        return os.stat(path).st_mtime
    except OSError:
        return None


def _record(home):
    try:
        with open(os.path.join(home, RECORD), encoding="utf-8") as fh:
            rec = json.load(fh)
        if rec.get("state") in ("on", "off") and isinstance(rec.get("at"), (int, float)):
            return rec
    except (OSError, ValueError, AttributeError):
        pass
    return None


def read(home):
    """{"state": "on"|"off"|"partial"|None, "error": text|None, "exists": bool,
    "changed_here": epoch|None, "changed_outside": bool, "changed_elsewhere": epoch|None}."""
    path = settings_path(home)
    out = {"state": None, "error": None, "exists": os.path.lexists(path),
           "changed_here": None, "changed_outside": False, "changed_elsewhere": None}
    try:
        out["state"] = _state(_load(path), home)
    except SettingsError as exc:
        out["error"] = str(exc)
        return out
    rec = _record(home)
    if rec is not None and rec["state"] == out["state"]:
        out["changed_here"] = rec["at"]
    elif out["exists"] or rec is not None:
        out["changed_outside"] = True
        out["changed_elsewhere"] = _mtime(path)
    return out


def ensure_ignored(home):
    """Keep the settings file out of git: True when it is ignored (or the home is not a git work tree)."""
    def git(*args):
        return subprocess.run(["git", "-C", home] + list(args), stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=10)
    try:
        if git("rev-parse", "--is-inside-work-tree").stdout.strip() != "true":
            return True
        if git("check-ignore", "-q", SETTINGS).returncode == 0:
            return True
        exclude = git("rev-parse", "--git-path", "info/exclude").stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return False
    if not exclude:
        return False
    exclude = os.path.join(home, exclude)
    try:
        os.makedirs(os.path.dirname(exclude), exist_ok=True)
        with open(exclude, "a+", encoding="utf-8") as fh:
            fh.seek(0)
            text = fh.read()
            if IGNORE_LINE not in text.splitlines():
                fh.write(("" if not text or text.endswith("\n") else "\n") + IGNORE_LINE + "\n")
    except OSError:
        return False
    return True


def _write_atomic(path, text, mode=None):
    target = os.path.realpath(path)
    d = os.path.dirname(target)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".settings.", suffix=".tmp", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        if mode is not None:
            os.chmod(tmp, mode)
        os.replace(tmp, target)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def switch(home, on, now=None):
    """Turn the switch ON (True) or OFF (False); returns read(home) afterwards.
    Raises SettingsError, leaving the file untouched, when it cannot be read
    as settings or cannot be written."""
    path = settings_path(home)
    data = _load(path)
    if data is None and not on:
        return read(home)
    data = {} if data is None else data
    perms = data["permissions"] = data.get("permissions") or {}
    allow = perms.get("allow") or []
    want = rules(home)
    if on:
        new = allow + [r for r in want if r not in allow]
    else:
        new = [a for a in allow if a not in want]
    if new == allow:
        return read(home)
    perms["allow"] = new
    ensure_ignored(home)
    try:
        mode = os.stat(path).st_mode & 0o7777
    except OSError:
        mode = None
    try:
        _write_atomic(path, json.dumps(data, indent=2, ensure_ascii=False) + "\n", mode)
    except OSError as exc:
        raise SettingsError("the settings file could not be written (%s)" % (exc.strerror or exc))
    try:
        _write_atomic(os.path.join(home, RECORD),
                      json.dumps({"state": "on" if on else "off", "at": time.time() if now is None else now}) + "\n")
    except OSError:
        pass  # the switch itself changed; only its "last changed" line falls back to the file's time
    return read(home)
