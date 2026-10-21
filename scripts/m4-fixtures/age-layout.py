#!/usr/bin/python3 -I
# Ages a seeded CODD layout for the M4 retention tests (docs/M4-PLAN.md C11, D30): sets sessions
# stopped / archived at given times in layout.json (CoddCore's exact format: version 1, pretty-printed
# with sorted keys and "key" : value, JSDate.isoString dates), writes a dummy `ring` (and `holder.log`)
# of a given size into <dataRoot>/sessions/<id>/, and writes cleanup.json retention.firstRunAt so the
# D30 first-run grace is over.
#
#   age-layout.py <layout.json> [--stopped <session id> <ISO>]... [--archived <session id> <ISO>]...
#                 [--ring <dataRoot> <session id> <MiB>]... [--first-run <dataRoot> <ISO>]
#   -> one line per change: `stopped <id> <iso>`, `archived <id> <iso>`, `ring <path> <bytes>`,
#      `first-run <cleanup.json> <iso>`
#
# Session ids match case-insensitively (the app writes them upper case); session folders are lower
# case like HolderLauncher's. --stopped sets lastState {"kind": "stopped"} and lastStateAt; --archived
# sets archivedAt (lastState untouched unless --stopped is given too). Run it while CODD is not
# running (the app rewrites layout.json). cleanup.json (§3.4) keeps every other key; dates there are
# UTC seconds with Z. Refuses (exit 1) a path inside ~/Library, ~/.claude*, ~/.codex or ~ outside
# $TMPDIR, an unknown session, or an unreadable layout; exit 2 on bad arguments. Starts no process.
import datetime
import json
import os
import sys
import uuid

USAGE = """usage: age-layout.py <layout.json> [--stopped <session id> <ISO>]... [--archived <session id> <ISO>]...
                     [--ring <dataRoot> <session id> <MiB>]... [--first-run <dataRoot> <ISO>]"""


def die(message, code):
    print("age-layout: " + message, file=sys.stderr)
    if code == 2:
        print(USAGE, file=sys.stderr)
    sys.exit(code)


def protected(path):
    target = os.path.realpath(os.path.abspath(path))
    homes = set()
    if os.environ.get("HOME"):
        homes.add(os.path.realpath(os.environ["HOME"]))
    try:
        import pwd
        homes.add(os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir))
    except (ImportError, KeyError):
        pass
    tmp = os.path.realpath(os.environ.get("TMPDIR") or "/tmp")

    def inside(p, base):
        return p == base or p.startswith(base.rstrip("/") + "/")

    for home in homes:
        for name in ("Library", ".claude", ".claude.json", ".claude-swap-backup", ".codex"):
            if inside(target, os.path.join(home, name)):
                return "inside ~/" + name
        if inside(target, home) and not inside(target, tmp):
            return "inside ~ (outside $TMPDIR)"
    return None


def parse_iso(text):
    t = text.strip()
    if t[-1:] in ("Z", "z"):
        t = t[:-1] + "+00:00"
    if "." in t:
        head, rest = t.split(".", 1)
        digits = ""
        while rest and rest[0].isdigit():
            digits, rest = digits + rest[0], rest[1:]
        t = head + ("." + (digits + "000000")[:6] if digits else "") + rest
    value = datetime.datetime.fromisoformat(t)
    if value.tzinfo is None:
        value = value.astimezone()
    return value


def js_date(dt):
    """CoddCore JSDate.isoString (`new Date(ms).toISOString()`)."""
    u = dt.astimezone(datetime.timezone.utc)
    return u.strftime("%Y-%m-%dT%H:%M:%S") + ".%03dZ" % (u.microsecond // 1000)


def utc_seconds(dt):
    return dt.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def encode_layout(obj):
    # JSONEncoder [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] like scripts/m2-fixtures/seed-layout.sh.
    return (json.dumps(obj, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : ")) + "\n").encode("utf-8")


def write_atomic(path, data, mode):
    folder = os.path.dirname(os.path.abspath(path))
    tmp = os.path.join(folder, ".%s.%d.tmp" % (os.path.basename(path), os.getpid()))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def session_id(text):
    try:
        return str(uuid.UUID(text)).lower()
    except ValueError:
        die("%s is not a session UUID" % text, 2)


def main(argv):
    if not argv or argv[0].startswith("-"):
        die("missing <layout.json>", 2)
    layout_path = argv[0]
    stopped, archived, rings, first_run = [], [], [], None
    i = 1
    while i < len(argv):
        a = argv[i]
        try:
            if a in ("--stopped", "--archived"):
                if i + 2 >= len(argv):
                    die("%s needs <session id> <ISO>" % a, 2)
                (stopped if a == "--stopped" else archived).append((session_id(argv[i + 1]), parse_iso(argv[i + 2])))
                i += 3
            elif a == "--ring":
                if i + 3 >= len(argv):
                    die("--ring needs <dataRoot> <session id> <MiB>", 2)
                mib = float(argv[i + 3])
                if not 0 <= mib <= 1024:
                    die("--ring size must be 0...1024 MiB", 2)
                rings.append((argv[i + 1], session_id(argv[i + 2]), mib))
                i += 4
            elif a == "--first-run":
                if i + 2 >= len(argv):
                    die("--first-run needs <dataRoot> <ISO>", 2)
                first_run = (argv[i + 1], parse_iso(argv[i + 2]))
                i += 3
            else:
                die("unknown argument %s" % a, 2)
        except ValueError:
            die("bad value after %s" % a, 2)
    targets = [layout_path] + [r[0] for r in rings] + ([first_run[0]] if first_run else [])
    for t in targets:
        why = protected(t)
        if why:
            die("refusing %s (%s)" % (t, why), 1)

    lines = []
    if stopped or archived:
        try:
            with open(layout_path, "rb") as f:
                layout = json.loads(f.read().decode("utf-8"))
            mode = os.stat(layout_path).st_mode & 0o777
        except (OSError, ValueError) as e:
            die("cannot read %s (%s)" % (layout_path, type(e).__name__), 1)
        sessions = {str(s.get("id", "")).lower(): s for s in layout.get("sessions") or [] if isinstance(s, dict)}
        for sid, _ in stopped + archived:
            if sid not in sessions:
                die("no session %s in %s" % (sid, layout_path), 1)
        for sid, when in stopped:
            sessions[sid]["lastState"] = {"kind": "stopped"}
            sessions[sid]["lastStateAt"] = js_date(when)
            lines.append("stopped %s %s" % (sid, js_date(when)))
        for sid, when in archived:
            sessions[sid]["archivedAt"] = js_date(when)
            lines.append("archived %s %s" % (sid, js_date(when)))
        write_atomic(layout_path, encode_layout(layout), mode or 0o600)
    for root, sid, mib in rings:
        folder = os.path.join(root, "sessions", sid)
        os.makedirs(folder, mode=0o700, exist_ok=True)
        size = int(mib * 1024 * 1024)
        ring = os.path.join(folder, "ring")
        chunk = (b"fixture ring bytes \x1b[32mok\x1b[0m\r\n" * 32768)[:1024 * 1024]
        fd = os.open(ring, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as f:
            left = size
            while left > 0:
                f.write(chunk[:min(left, len(chunk))])
                left -= len(chunk)
        log = os.path.join(folder, "holder.log")
        if not os.path.exists(log):
            write_atomic(log, b"fixture holder log (age-layout.py)\n", 0o600)
        lines.append("ring %s %d" % (ring, size))
    if first_run:
        root, when = first_run
        path = os.path.join(root, "cleanup.json")
        doc = {"v": 1, "sessions": {}, "files": {}}
        if os.path.exists(path):
            try:
                with open(path, "rb") as f:
                    doc = json.loads(f.read().decode("utf-8"))
            except (OSError, ValueError):
                die("%s is not readable JSON; refusing to replace it" % path, 1)
            if not isinstance(doc, dict):
                die("%s is not a JSON object; refusing to replace it" % path, 1)
        retention = doc.get("retention") if isinstance(doc.get("retention"), dict) else {}
        retention["firstRunAt"] = utc_seconds(when)
        doc["retention"] = retention
        doc.setdefault("v", 1)
        os.makedirs(root, mode=0o700, exist_ok=True)
        write_atomic(path, (json.dumps(doc, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8"), 0o600)
        lines.append("first-run %s %s" % (path, utc_seconds(when)))
    sys.stdout.write("".join(l + "\n" for l in lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
