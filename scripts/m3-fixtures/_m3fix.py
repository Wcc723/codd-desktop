# Writers behind make-cswap-state.sh, make-claude-settings.sh and rate-limits.sh (docs/M3-PLAN.md C9,
# §1, §3). Run as `python3 -I _m3fix.py <command> …` by those wrappers; Python 3.9 compatible, no
# network, never reads or writes ~, ~/Library, ~/.claude, ~/.claude.json or ~/.claude-swap-backup.
# Usage errors exit 2, refusals exit 1. E-mails are `*@example.com` only.
import base64
import datetime
import json
import math
import os
import re
import sys
import unicodedata

FORBIDDEN_IN_HOME = ("Library", ".claude", ".claude.json", ".claude-swap-backup")


class Refused(Exception):
    """Exit 1: a target the fixtures must never write."""


class Usage(Exception):
    """Exit 2: bad arguments."""


def _homes():
    homes = set()
    if os.environ.get("HOME"):
        homes.add(os.path.realpath(os.environ["HOME"]))
    try:
        import pwd
        homes.add(os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir))
    except (ImportError, KeyError):
        pass
    return homes


def _inside(path, base):
    return path == base or path.startswith(base.rstrip("/") + "/")


def guard(path, what):
    """Refuses inside ~ (unless under $TMPDIR), ~/Library, ~/.claude, ~/.claude.json, ~/.claude-swap-backup."""
    target = os.path.realpath(os.path.abspath(path))
    tmp = os.path.realpath(os.environ["TMPDIR"]) if os.environ.get("TMPDIR") else None
    for home in _homes():
        for name in FORBIDDEN_IN_HOME:
            if _inside(target, os.path.join(home, name)):
                raise Refused("refusing %s %s (inside ~/%s)" % (what, path, name))
        if _inside(target, home) and not (tmp and _inside(target, tmp)):
            raise Refused("refusing %s %s (inside ~)" % (what, path))


def write_file(path, text, mode, replace=True):
    """Temp file + rename in the target's folder (never through a symlink at the target)."""
    directory = os.path.dirname(path)
    tmp = os.path.join(directory, ".%s.%d.tmp" % (os.path.basename(path), os.getpid()))
    if not replace and os.path.lexists(path):
        raise Refused("%s already exists" % path)
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, mode)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def mkdirs(path, mode=0o700):
    os.makedirs(path, mode=mode, exist_ok=True)
    os.chmod(path, mode)


def shq(s):
    """Single-quote for /bin/sh exactly like CODD web's claude-setup.js shq()."""
    return "'" + str(s).replace("'", "'\\''") + "'"


def b64(text):
    return base64.b64encode(text.encode("utf-8")).decode("ascii")


# ------------------------------------------------------------------------------------------------
# make-cswap-state.sh

# SPEC §5 accounts. The CJK aliases are what an older cswap or a hand edit left in sequence.json
# (cswap 0.26 itself only accepts ^[a-z0-9_.-]+$, D34). #4 is only written with --accounts 4 and is
# the identity fake-claude-m3.sh's FAKE_LOGIN_AS=4 logs in as.
ACCOUNTS = [
    {"number": 1, "email": "personal@example.com", "uuid": "a1000000-0000-4000-8000-000000000001",
     "orgUuid": "", "orgName": "personal@example.com's Organization", "alias": "個人",
     "tier": "default_claude_max_20x", "type": "claude_max", "addedDays": 40},
    {"number": 2, "email": "north@example.com", "uuid": "a2000000-0000-4000-8000-000000000002",
     "orgUuid": "org-2", "orgName": "Synthetic North Org", "alias": "藍鵲",
     "tier": "default_claude_max_20x", "type": "claude_max", "addedDays": 30},
    {"number": 3, "email": "work@example.com", "uuid": "a3000000-0000-4000-8000-000000000003",
     "orgUuid": "", "orgName": "", "alias": "工作",
     "tier": "default_claude_max_20x", "type": "claude_max", "addedDays": 20},
    {"number": 4, "email": "new@example.com", "uuid": "a4000000-0000-4000-8000-000000000004",
     "orgUuid": "org-4", "orgName": "Synthetic Org 4", "alias": None,
     "tier": "default_claude_max_5x", "type": "claude_max", "addedDays": 1},
]
ACTIVE = 3
PROFILE_ACCOUNT = 2
DAY, HOUR, MINUTE = 86400, 3600, 60
# Usage rows (cache/usage.json lastGood) as offsets from --now: (pct, reset offset in s or None).
USAGE = {
    1: {"fetchedAgo": 3 * MINUTE, "five_hour": (0.0, None), "seven_day": (0.0, 4 * DAY + 9 * HOUR), "resetMicros": 441208},
    2: {"fetchedAgo": 3 * MINUTE, "five_hour": (2.0, 2 * HOUR + 37 * MINUTE), "seven_day": (54.0, DAY + 12 * HOUR),
        "scoped": [("Fable", 0.0)]},
    3: {"fetchedAgo": 10 * MINUTE, "five_hour": (9.0, 2 * HOUR + 57 * MINUTE), "seven_day": (85.0, 3 * DAY + HOUR)},
    4: {"fetchedAgo": 3 * MINUTE, "five_hour": (30.0, HOUR + 10 * MINUTE), "seven_day": (20.0, 5 * DAY + 2 * HOUR)},
}
STALE_MARKER = ".cswap-stale-credentials"


def slugify_email(email):
    """claude_swap.session.slugify_email: `north@example.com` -> `north_example.com`."""
    normalized = unicodedata.normalize("NFC", email)
    return "".join(ch if (ch.isascii() and (ch.isalnum() or ch in "._-")) else "_" for ch in normalized)


def iso_utc(dt):
    return dt.astimezone(datetime.timezone.utc).isoformat()


def stamp(dt):
    return dt.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def format_reset(reset, now):
    """claude_swap.oauth.format_reset evaluated at `now` (the fetch time), local clock."""
    total = max(0, int((reset - now).total_seconds()))
    days, rest = divmod(total, DAY)
    hours, rest = divmod(rest, HOUR)
    minutes = rest // MINUTE
    if days > 0:
        countdown = "%dd %dh" % (days, hours)
    elif hours > 0:
        countdown = "%dh %dm" % (hours, minutes)
    else:
        countdown = "%dm" % minutes
    local, now_local = reset.astimezone(), now.astimezone()
    if local.date() == now_local.date():
        clock = local.strftime("%H:%M")
    else:
        clock = local.strftime("%b " + str(local.day) + " %H:%M")
    return countdown, clock


def window(pct, reset_offset, now, fetched, micros=0):
    out = {"pct": pct}
    if reset_offset is not None:
        reset = (now + datetime.timedelta(seconds=reset_offset)).replace(microsecond=micros)
        out["resets_at"] = iso_utc(reset)
        out["countdown"], out["clock"] = format_reset(reset, fetched)
    return out


def oauth_account(a):
    return {"accountUuid": a["uuid"], "emailAddress": a["email"], "organizationUuid": a["orgUuid"],
            "organizationName": a["orgName"], "organizationRateLimitTier": a["tier"], "organizationType": a["type"]}


def dumps_cswap(obj):
    """cswap's own writer: json.dumps(data, indent=2), ASCII escapes, no trailing newline."""
    return json.dumps(obj, indent=2)


def dumps_claude(obj):
    """Claude Code's .claude.json: 2-space JSON.stringify (non-ASCII kept)."""
    return json.dumps(obj, indent=2, ensure_ascii=False)


def profile_dir(root, a):
    return os.path.join(root, "sessions", "%d-%s" % (a["number"], slugify_email(a["email"])))


def make_profile(root, claude_dir, a):
    """A `cswap run <n>` profile: sessions/ and projects/ (per account), settings.json shared as an
    absolute symlink into the Claude directory, cswap's share manifest. No credentials."""
    d = profile_dir(root, a)
    mkdirs(os.path.join(root, "sessions"))
    mkdirs(d)
    mkdirs(os.path.join(d, "sessions"))
    mkdirs(os.path.join(d, "projects"))
    link = os.path.join(d, "settings.json")
    if not os.path.lexists(link):
        os.symlink(os.path.join(claude_dir, "settings.json"), link)
    manifest = os.path.join(d, ".cswap-shared.json")
    if not os.path.exists(manifest):
        write_file(manifest, json.dumps({"items": ["settings.json"], "mode": "symlink"}, indent=2), 0o600)
    return d


def mark_stale(root, claude_dir, a):
    d = profile_dir(root, a)
    if not os.path.isdir(d):
        make_profile(root, claude_dir, a)
    marker = os.path.join(root, "sessions", ".%s%s" % (os.path.basename(d), STALE_MARKER))
    fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    os.close(fd)
    return marker


def parse_now(text):
    try:
        dt = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        raise Usage("--now must be ISO 8601 (e.g. 2026-10-17T02:00:00Z): %s" % text)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return dt


def cmd_cswap_state(args):
    if len(args) < 2 or args[0].startswith("-") or args[1].startswith("-"):
        raise Usage("make-cswap-state.sh <cswapRoot> <claudeDir> [--now <iso>] [--accounts 3|4] [--stale <n>]")
    root, claude_dir = os.path.abspath(args[0]), os.path.abspath(args[1])
    now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    count, stale = 3, None
    rest = args[2:]
    while rest:
        flag = rest.pop(0)
        if flag not in ("--now", "--accounts", "--stale") or not rest:
            raise Usage("unknown or incomplete option %s" % flag)
        value = rest.pop(0)
        if flag == "--now":
            now = parse_now(value)
        elif flag == "--accounts":
            if value not in ("3", "4"):
                raise Usage("--accounts takes 3 or 4")
            count = int(value)
        else:
            if not value.isdigit():
                raise Usage("--stale takes an account number")
            stale = int(value)
    if os.path.basename(root) != ".claude-swap-backup":
        raise Refused("refusing %s: the cswap root's last component must be .claude-swap-backup "
                      "(the CLI derives cswap-<n> from …/.claude-swap-backup/sessions/<n>-…)" % args[0])
    parent = os.path.realpath(os.path.dirname(claude_dir))
    shared = {os.path.realpath(p) for p in ("/tmp", "/private/tmp") if os.path.exists(p)}
    if os.environ.get("TMPDIR"):
        shared.add(os.path.realpath(os.environ["TMPDIR"]))
    try:
        shared.add(os.path.realpath(os.confstr(65537)))  # the per-user temp folder (_CS_DARWIN_USER_TEMP_DIR)
    except (ValueError, OSError):
        pass
    if parent in shared or parent == "/":
        raise Refused("refusing %s: its parent %s is a shared folder; <claudeDir>/../.claude.json must land in a "
                      "dedicated temp folder" % (args[1], os.path.dirname(claude_dir)))
    claude_json = os.path.join(os.path.dirname(claude_dir), ".claude.json")
    guard(root, "cswap root")
    guard(claude_dir, "Claude directory")
    guard(claude_json, ".claude.json")
    accounts = ACCOUNTS[:count]
    by_number = {a["number"]: a for a in ACCOUNTS}
    sequence_file = os.path.join(root, "sequence.json")
    if os.path.lexists(sequence_file):
        # An existing state is only ever marked stale (mid-run, --now / --accounts ignored); anything
        # else is refused so a running test's state is never rewritten.
        if stale is None:
            raise Refused("%s already exists; refusing to replace it (only --stale applies to an existing root)"
                          % sequence_file)
        try:
            with open(sequence_file, "r", encoding="utf-8") as f:
                record = (json.load(f).get("accounts") or {}).get(str(stale))
        except (OSError, ValueError, AttributeError):
            record = None
        if not isinstance(record, dict) or not record.get("email"):
            raise Usage("--stale %d: no such account in %s" % (stale, sequence_file))
        mark_stale(root, claude_dir, {"number": stale, "email": record["email"]})
        print(root)
        return 0
    if stale is not None and stale not in [a["number"] for a in accounts]:
        raise Usage("--stale %d: no such account (accounts 1-%d)" % (stale, count))

    mkdirs(root)
    for sub in ("cache", "configs", "credentials", "sessions"):
        mkdirs(os.path.join(root, sub))
    mkdirs(claude_dir)

    seq = {"activeAccountNumber": ACTIVE, "lastUpdated": stamp(now - datetime.timedelta(minutes=30)),
           "sequence": [a["number"] for a in accounts], "accounts": {}}
    for a in accounts:
        record = {"email": a["email"], "uuid": a["uuid"], "organizationUuid": a["orgUuid"],
                  "organizationName": a["orgName"], "added": stamp(now - datetime.timedelta(days=a["addedDays"]))}
        if a["alias"]:
            record["alias"] = a["alias"]
        seq["accounts"][str(a["number"])] = record
    write_file(sequence_file, dumps_cswap(seq), 0o600, replace=False)

    rows = {}
    for a in accounts:
        u = USAGE[a["number"]]
        fetched = now - datetime.timedelta(seconds=u["fetchedAgo"])
        fetched_s = fetched.timestamp()
        last_good = {"five_hour": window(u["five_hour"][0], u["five_hour"][1], now, fetched),
                     "seven_day": window(u["seven_day"][0], u["seven_day"][1], now, fetched, u.get("resetMicros", 0))}
        if u.get("scoped"):
            last_good["scoped"] = [{"name": name, "pct": pct} for name, pct in u["scoped"]]
        # Key order of a row after cswap's claim + successful record (usage_store.py).
        rows[str(a["number"])] = {
            "email": a["email"], "organizationUuid": a["orgUuid"], "lastAttemptAt": fetched_s, "claimId": None,
            "claimUntil": 0.0, "lastGood": last_good, "fetchedAt": fetched_s, "nextPollAt": fetched_s + 180.0,
            "pollIntervalS": 180.0, "consecutiveFailures": 0, "lastError": None, "backoffUntil": None,
            "authDeadStrikes": 0}
    write_file(os.path.join(root, "cache", "usage.json"), dumps_cswap({"schemaVersion": 2, "accounts": rows}), 0o600)

    for a in accounts:
        write_file(os.path.join(root, "configs", ".claude-config-%d-%s.json" % (a["number"], a["email"])),
                   dumps_claude({"oauthAccount": oauth_account(a), "projects": {}}), 0o600)
    make_profile(root, claude_dir, by_number[PROFILE_ACCOUNT])
    if stale is not None:
        mark_stale(root, claude_dir, by_number[stale])
    write_file(claude_json, dumps_claude({"oauthAccount": oauth_account(by_number[ACTIVE]), "projects": {}}), 0o600)
    print(root)
    return 0


# ------------------------------------------------------------------------------------------------
# make-claude-settings.sh

HOOK_EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
               "PermissionRequest", "Notification", "Stop", "StopFailure", "SessionEnd"]
MATCHER_EVENTS = {"PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "Notification"}
HOOK_TAP_EVENTS = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
              "PermissionRequest", "Notification", "Stop", "StopFailure", "SubagentStart", "SubagentStop"]
HOOK_TAP_MATCHER_EVENTS = {"PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest"}
DEFAULT_USER_STATUSLINE = "printf 'USER-SL-%s' ok"
OSASCRIPT = {
    "Notification": "osascript -e 'display notification \"Claude Code 需要你的注意\" with title \"Claude Code\"'",
    "Stop": "osascript -e 'display notification \"任務完成\" with title \"Claude Code\" sound name \"Glass\"'",
}


def sh_word(path):
    return path if re.fullmatch(r"[A-Za-z0-9/._+-]+", path) else shq(path)


class WebInstall:
    """The CODD web (Node) leftovers exactly as its claude-setup.js wrote them, at fake paths."""

    def __init__(self, base):
        self.node = os.path.join(base, "codd-web", "node", "bin", "node")
        repo = os.path.join(base, "codd-web", "repo")
        self.hook_script = os.path.join(repo, "configs", "hooks", "status-writer.js")
        self.sl_script = os.path.join(repo, "configs", "statusline", "codd-statusline.js")
        self.status_dir = os.path.join(base, "codd-web", "status")

    def hook_command(self):
        return ('[ -z "$CODD_TERMINAL_ID" ] || [ ! -x %s ] || [ ! -f %s ] || STATUS_DIR_PATH=%s %s %s'
                % (shq(self.node), shq(self.hook_script), shq(self.status_dir), shq(self.node), shq(self.hook_script)))

    def old_hook_command(self):
        """The pre-installer manual entry ({matcher, command} shape)."""
        return "STATUS_DIR_PATH=%s %s %s" % (shq(self.status_dir), shq(self.node), shq(self.hook_script))

    def statusline_command(self, chained):
        guard_ = "[ -x %s ] && [ -f %s ]" % (shq(self.node), shq(self.sl_script))
        base = "STATUS_DIR_PATH=%s %s %s" % (shq(self.status_dir), shq(self.node), shq(self.sl_script))
        if not chained:
            return "if %s; then %s; else :; fi" % (guard_, base)
        return "if %s; then %s --chain-b64 %s; else /bin/sh -c %s; fi" % (guard_, base, b64(chained), shq(chained))


def desktop_statusline(data_root, chained):
    """CODD Desktop's global wrapper (docs/M3-PLAN.md D11)."""
    binary = os.path.join(data_root, "bin", "codd-statusline")
    head = "if [ -x %s ]; then %s --data-root %s" % (shq(binary), shq(binary), shq(data_root))
    if not chained:
        return head + "; fi"
    return "%s --chain-b64 %s; else /bin/sh -c %s; fi" % (head, b64(chained), shq(chained))


def settings_object(claude_dir, legacy, user_cmd, desktop_root):
    base = os.path.join(os.path.dirname(claude_dir), "fixture-tools")
    web = WebInstall(base)
    hook_tap = os.path.join(base, "hook-tap", "bin", "hook-tap")
    hooks = {}

    def add(event, group):
        hooks.setdefault(event, []).append(group)

    for event in HOOK_EVENTS + [e for e in HOOK_TAP_EVENTS if e not in HOOK_EVENTS]:
        web_group = None
        if legacy and event in HOOK_EVENTS:
            web_group = {}
            if event in MATCHER_EVENTS:
                web_group["matcher"] = "*"
            web_group["hooks"] = [{"type": "command", "command": web.hook_command(), "timeout": 5}]
        tap_group = None
        if event in HOOK_TAP_EVENTS:
            tap_group = {}
            if event in HOOK_TAP_MATCHER_EVENTS:
                tap_group["matcher"] = "*"
            tap_group["hooks"] = [{"type": "command", "command": "%s --event %s" % (sh_word(hook_tap), event),
                                   "timeout": 600 if event == "PermissionRequest" else 10}]
        # Installed at different times: CODD web first on some events, hook-tap first on others.
        order = [web_group, tap_group] if event in ("SessionStart", "UserPromptSubmit", "Stop", "SessionEnd") \
            else [tap_group, web_group]
        for g in order:
            if g:
                add(event, g)
        if event in OSASCRIPT:
            group = {"matcher": ""} if event == "Notification" else {}
            group["hooks"] = [{"type": "command", "command": OSASCRIPT[event]}]
            add(event, group)
        if legacy and event == "PostToolUse":
            add(event, {"matcher": "*", "command": web.old_hook_command()})

    if desktop_root:
        status_line = {"type": "command", "command": desktop_statusline(desktop_root, user_cmd), "padding": 0}
    elif legacy:
        status_line = {"type": "command", "command": web.statusline_command(user_cmd), "padding": 0}
    elif user_cmd:
        status_line = {"type": "command", "command": user_cmd, "padding": 0}
    else:
        status_line = None

    obj = {
        "env": {"CODD_FIXTURE_NOTE": "測試用的假設定（不是秘密）", "FIXTURE_DOCS_LANG": "zh-TW"},
        "permissions": {"allow": ["Bash(git status:*)", "Read(%s/文件/**)" % base],
                        "deny": ["Read(%s/機密/**)" % base], "defaultMode": "default"},
        "hooks": hooks,
    }
    if status_line:
        obj["statusLine"] = status_line
    obj["enabledPlugins"] = {"範例外掛@本機市集": True, "fixture-tools@local-fixture-market": False}
    obj["alwaysThinkingEnabled"] = True
    return obj


def dumps_settings(obj):
    """Claude Code's settings files: 2-space JSON.stringify, non-ASCII kept, trailing newline."""
    return json.dumps(obj, indent=2, ensure_ascii=False) + "\n"


def cmd_claude_settings(args):
    usage = ("make-claude-settings.sh <claudeDir> [--legacy] [--user-statusline '<cmd>'] [--desktop-global <dataRoot>] "
             "[--project <cwd> '<cmd>'] [--force]")
    if not args or args[0].startswith("-"):
        raise Usage(usage)
    claude_dir = os.path.abspath(args[0])
    legacy = force = False
    user_cmd, desktop_root, project = DEFAULT_USER_STATUSLINE, None, None
    rest = args[1:]
    while rest:
        flag = rest.pop(0)
        if flag == "--legacy":
            legacy = True
        elif flag == "--force":
            force = True
        elif flag == "--user-statusline" and rest:
            user_cmd = rest.pop(0)
        elif flag == "--desktop-global" and rest:
            desktop_root = os.path.abspath(rest.pop(0))
        elif flag == "--project" and len(rest) >= 2:
            project = (os.path.abspath(rest.pop(0)), rest.pop(0))
        else:
            raise Usage(usage)
    guard(claude_dir, "Claude directory")
    target = os.path.join(claude_dir, "settings.json")
    guard(target, "settings file")
    if desktop_root:
        guard(desktop_root, "data root")
    project_file = None
    if project:
        project_file = os.path.join(project[0], ".claude", "settings.json")
        guard(project_file, "project settings file")
        if not project[1]:
            raise Usage("--project needs a non-empty command")
    for path in (target, project_file):
        if path and os.path.lexists(path) and not force:
            raise Refused("%s already exists (pass --force to replace it)" % path)
    mkdirs(claude_dir)
    write_file(target, dumps_settings(settings_object(claude_dir, legacy, user_cmd, desktop_root)), 0o644)
    print(target)
    if project_file:
        os.makedirs(os.path.dirname(project_file), mode=0o755, exist_ok=True)
        write_file(project_file, dumps_settings({"statusLine": {"type": "command", "command": project[1]}}), 0o644)
        print(project_file)
    return 0


# ------------------------------------------------------------------------------------------------
# rate-limits.sh

NUMBER = re.compile(r"-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?")


def json_number(text, what):
    if not NUMBER.fullmatch(text) or not math.isfinite(float(text)):
        raise Usage("%s must be a JSON number: %s" % (what, text))
    return text


def reset_token(text, what):
    if re.fullmatch(r"[0-9]+", text):
        return str(int(text))
    if re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+(Z|[+-][0-9]{2}:?[0-9]{2})?", text):
        return json.dumps(text)  # an ISO string, for CODD's tolerant decoding
    raise Usage("%s must be epoch seconds (or ms, or ISO 8601) or -: %s" % (what, text))


def cmd_rate_limits(args):
    if len(args) != 5:
        raise Usage("rate-limits.sh <file> <5h used> <5h reset epoch s|-> <7d used> <7d reset epoch s|->")
    path = os.path.abspath(args[0])
    guard(path, "rate limits file")
    parts = []
    for name, used, reset in (("five_hour", args[1], args[2]), ("seven_day", args[3], args[4])):
        if used == "-" or reset == "-":
            continue
        parts.append('"%s":{"used_percentage":%s,"resets_at":%s}'
                     % (name, json_number(used, name + " used"), reset_token(reset, name + " reset")))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    write_file(path, "{" + ",".join(parts) + "}\n", 0o600)
    print(path)
    return 0


def main():
    commands = {"cswap-state": cmd_cswap_state, "claude-settings": cmd_claude_settings, "rate-limits": cmd_rate_limits}
    if len(sys.argv) < 2 or sys.argv[1] not in commands:
        sys.stderr.write("usage: _m3fix.py cswap-state|claude-settings|rate-limits …\n")
        return 2
    try:
        return commands[sys.argv[1]](sys.argv[2:])
    except Usage as e:
        sys.stderr.write("usage: %s\n" % e)
        return 2
    except Refused as e:
        sys.stderr.write("%s\n" % e)
        return 1


if __name__ == "__main__":
    sys.exit(main())
