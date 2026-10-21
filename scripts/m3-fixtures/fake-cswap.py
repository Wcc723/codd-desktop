#!/usr/bin/python3 -I
# Fake `cswap` (claude-swap 0.26.0) for CODD's M3 tests (docs/M3-PLAN.md C9). It works on a fake
# state root written by make-cswap-state.sh and never touches the network, the Keychain, ~/.claude,
# ~/.claude.json or ~/.claude-swap-backup. The JSON shapes, messages, alias rule and exit codes follow
# claude_swap 0.26.0 (cli.py, switcher.py, json_output.py, models.py, usage_store.py, pace.py); the
# credential steps are left out (CODD never reads credentials).
#
#   --version                         cswap 0.26.0
#   list --json | status --json       schema-1 JSON from the state files (e-mails included, like cswap)
#   switch <n|alias|email> [--json]   activeAccountNumber + the fake .claude.json identity
#   add [--slot N] [--alias A]        captures the identity in the fake .claude.json
#   alias <n> <name> | alias <n> --unset | alias
# Anything else: exit 2. Handled failures: error envelope on stdout with --json, else
# `Error: <message>` on stderr; exit 1.
#
# Configuration: the sidecar `<this script's path>.env` (KEY=VALUE lines, `#` comments;
# FAKE_CONFIG=<file> names another file), the environment wins:
#   FAKE_CSWAP_ROOT            the state root (required except for --version)
#   FAKE_CLAUDE_JSON           the fake ~/.claude.json (default <root>/../.claude.json)
#   FAKE_CSWAP_LOG             one JSON line {"argv": [...], "at": <ms>} per call
#   FAKE_CSWAP_SWITCH_DELAY_MS a switch waits this long first (default 0)
#   FAKE_CSWAP_FAIL            lock | error: every switch fails with ClaudeCodeLockTimeout | SwitchError
#   FAKE_CSWAP_LOCK_FAILS      the first n switch calls fail with ClaudeCodeLockTimeout (counted in
#                              <root>/.fake-cswap-lock-fails)
#   FAKE_CSWAP_WARN            1: a successful switch carries cswap's live-session warning (with e-mail)
#   FAKE_CSWAP_ADD_USAGE       1: `add` also stores a fresh 0 % usage measurement (as if a list had run)
# Every path must be inside $TMPDIR and outside ~, ~/Library, ~/.claude, ~/.claude.json and
# ~/.claude-swap-backup; otherwise the call refuses (exit 1) before it reads or writes anything.
# Error messages deliberately carry account e-mails, as cswap's own often do, so CODD's redaction is
# exercised.
import datetime
import json
import os
import re
import sys
import time

VERSION_LINE = "cswap 0.26.0"
SCHEMA_VERSION = 1
USAGE_SCHEMA_VERSION = 2
STALE_OK_S = 300.0
TRUST_MAX_AGE_S = 3600.0
WEEKLY_PERIOD_S = 7 * 86400.0
SUPPRESS_AFTER_RESET_S = 24 * 3600.0
AHEAD_THRESHOLD_PCT = 15.0
PROG = "cswap"

# claude_swap/models.py
_ALIAS_RE = re.compile(r"^[a-z0-9_.-]+$")


def normalize_alias(name):
    """Exactly claude_swap.models.normalize_alias (0.26.0)."""
    normalized = name.strip().lower()
    if not normalized:
        raise ValueError("alias cannot be empty")
    if normalized.isdigit():
        raise ValueError("alias '%s' cannot be purely numeric (reserved for slot numbers)" % name)
    if normalized.startswith("-"):
        raise ValueError("alias '%s' cannot start with '-' (would be read as a command flag)" % name)
    if not _ALIAS_RE.match(normalized):
        raise ValueError("alias '%s' may only contain letters, digits, '-', '_', and '.'" % name)
    return normalized


# claude_swap/exceptions.py: the envelope's `type` is the class name.
class ClaudeSwitchError(Exception):
    pass


class ConfigError(ClaudeSwitchError):
    pass


class SwitchError(ClaudeSwitchError):
    pass


class ValidationError(ClaudeSwitchError):
    pass


class AccountNotFoundError(ClaudeSwitchError):
    pass


class LockError(ClaudeSwitchError):
    pass


class ClaudeCodeLockTimeout(LockError):
    pass


class UsageError(Exception):
    """argparse-style usage error: exit 2."""


# ------------------------------------------------------------------------------------------------
# configuration and the path guard

def load_config():
    path = os.environ.get("FAKE_CONFIG") or (sys.argv[0] + ".env")
    values = {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                if key.strip().startswith("FAKE_"):
                    values[key.strip()] = value.strip()
    except OSError:
        pass
    for key, value in os.environ.items():
        if key.startswith("FAKE_"):
            values[key] = value
    return values


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


def _tmpdir():
    """$TMPDIR, else the per-user temp folder launchd normally exports as TMPDIR
    (confstr _CS_DARWIN_USER_TEMP_DIR = 65537), else /tmp."""
    value = os.environ.get("TMPDIR")
    if not value:
        try:
            value = os.confstr(65537)
        except (ValueError, OSError):
            value = None
    return os.path.realpath(value or "/tmp")


def _inside(path, base):
    return path == base or path.startswith(base.rstrip("/") + "/")


def refusal(path):
    """Why the fake must not touch `path`, or None."""
    target = os.path.realpath(os.path.abspath(path))
    tmp = _tmpdir()
    for home in _homes():
        for name in ("Library", ".claude", ".claude.json", ".claude-swap-backup"):
            if _inside(target, os.path.join(home, name)):
                return "inside ~/" + name
        if _inside(target, home) and not _inside(target, tmp):
            return "inside ~"
    if not _inside(target, tmp):
        return "outside $TMPDIR"
    return None


# ------------------------------------------------------------------------------------------------
# files

def timestamp():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def atomic_write(path, text):
    """Temp file next to the target + rename, 0600 (cswap's _write_json / atomic_write_json)."""
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    tmp = os.path.join(directory, ".%s.%d.tmp" % (os.path.basename(path), os.getpid()))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def write_json(path, data):
    atomic_write(path, json.dumps(data, indent=2))


def read_json(path, what):
    """None when the file is absent; a torn or unreadable file is a ConfigError, like cswap's strict read."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    except FileNotFoundError:
        return None
    except OSError as e:
        raise ConfigError("Could not read %s: %s" % (what, e.strerror))
    try:
        return json.loads(text)
    except ValueError:
        raise ConfigError("%s is not valid JSON" % what)


class State:
    def __init__(self, config):
        self.root = os.path.abspath(config["FAKE_CSWAP_ROOT"])
        self.claude_json = os.path.abspath(config.get("FAKE_CLAUDE_JSON")
                                           or os.path.join(os.path.dirname(self.root), ".claude.json"))
        self.sequence_file = os.path.join(self.root, "sequence.json")
        self.configs_dir = os.path.join(self.root, "configs")
        self.usage_file = os.path.join(self.root, "cache", "usage.json")
        self.config = config

    def sequence(self):
        data = read_json(self.sequence_file, "sequence.json")
        if data is not None and not isinstance(data, dict):
            raise ConfigError("sequence.json is not a JSON object")
        if data is not None:
            data.setdefault("sequence", [])
            data.setdefault("accounts", {})
        return data

    def init_sequence(self):
        for d in (self.root, self.configs_dir, os.path.join(self.root, "credentials")):
            os.makedirs(d, mode=0o700, exist_ok=True)
            os.chmod(d, 0o700)
        if not os.path.exists(self.sequence_file):
            write_json(self.sequence_file, {"activeAccountNumber": None, "lastUpdated": timestamp(),
                                            "sequence": [], "accounts": {}})

    def write_sequence(self, data):
        write_json(self.sequence_file, data)

    def config_path(self, number, email):
        return os.path.join(self.configs_dir, ".claude-config-%s-%s.json" % (number, email))

    def identity(self):
        """(email, organizationUuid, accountUuid) of the live login (.claude.json oauthAccount); a missing
        or torn file means no login, like cswap's lenient read of it."""
        try:
            data = read_json(self.claude_json, ".claude.json")
        except ConfigError:
            data = None
        if not isinstance(data, dict):
            return None
        oauth = data.get("oauthAccount") or {}
        if not isinstance(oauth, dict) or not oauth.get("emailAddress"):
            return None
        return oauth["emailAddress"], oauth.get("organizationUuid", "") or "", oauth.get("accountUuid", "") or ""

    def usage_rows(self):
        try:
            with open(self.usage_file, "r", encoding="utf-8") as f:
                raw = json.load(f)
        except (OSError, ValueError):
            return {}
        if not isinstance(raw, dict) or raw.get("schemaVersion") != USAGE_SCHEMA_VERSION:
            return {}
        rows = raw.get("accounts")
        return rows if isinstance(rows, dict) else {}

    def write_usage_rows(self, rows):
        os.makedirs(os.path.dirname(self.usage_file), mode=0o700, exist_ok=True)
        write_json(self.usage_file, {"schemaVersion": USAGE_SCHEMA_VERSION, "accounts": rows})

    def refuse_session_shell(self):
        cfg_dir = os.environ.get("CLAUDE_CONFIG_DIR")
        if not cfg_dir:
            return
        if _inside(os.path.realpath(cfg_dir), os.path.realpath(os.path.join(self.root, "sessions"))):
            raise SwitchError("This shell is inside a cswap run session profile (CLAUDE_CONFIG_DIR points at it). "
                              "Mutating accounts here would operate on the wrong live store — unset "
                              "CLAUDE_CONFIG_DIR or run from a normal shell.")


def find_slot(data, email, org_uuid):
    for num, account in (data or {}).get("accounts", {}).items():
        if account.get("email") == email and account.get("organizationUuid", "") == org_uuid:
            return num
    return None


def find_by_alias(data, alias):
    if not alias:
        return None
    key = alias.lower()
    for num, account in (data or {}).get("accounts", {}).items():
        if (account.get("alias") or "").lower() == key:
            return num
    return None


def alias_in_use(data, alias, exclude=None):
    num = find_by_alias(data, alias)
    return None if num is not None and num == exclude else num


def resolve_identifier(data, identifier):
    """number -> alias -> email (claude_swap _resolve_account_identifier)."""
    if identifier.isdigit():
        return identifier
    if not data:
        return None
    num = find_by_alias(data, identifier)
    if num is not None:
        return num
    matches = [n for n, a in data.get("accounts", {}).items() if a.get("email") == identifier]
    if not matches:
        return None
    if len(matches) == 1:
        return matches[0]
    details = ", ".join("%s [%s]" % (n, data["accounts"][n].get("organizationName") or "personal") for n in matches)
    raise ConfigError("Email '%s' is ambiguous — matches accounts: %s. Use account number instead "
                      "(e.g., cswap --switch-to 1)." % (identifier, details))


def valid_email(value):
    return bool(re.match(r"^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$", value))


def display_tag(org_name):
    return org_name if org_name else "personal"


# ------------------------------------------------------------------------------------------------
# usage projection (json_output.py, oauth.py, pace.py, usage_store.py)

def parse_iso(value):
    if not isinstance(value, str):
        return None
    try:
        dt = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return dt


def format_reset(resets_at):
    reset_utc = parse_iso(resets_at)
    if reset_utc is None:
        raise ValueError(resets_at)
    now = datetime.datetime.now(datetime.timezone.utc)
    total = max(0, int((reset_utc - now).total_seconds()))
    days, rest = divmod(total, 86400)
    hours, rest = divmod(rest, 3600)
    minutes = rest // 60
    if days > 0:
        countdown = "%dd %dh" % (days, hours)
    elif hours > 0:
        countdown = "%dh %dm" % (hours, minutes)
    else:
        countdown = "%dm" % minutes
    reset_local, now_local = reset_utc.astimezone(), now.astimezone()
    if reset_local.date() == now_local.date():
        clock = reset_local.strftime("%H:%M")
    else:
        clock = reset_local.strftime("%b " + str(reset_local.day) + " %H:%M")
    return countdown, clock


def fresh_reset_strings(window):
    if window.get("resets_at"):
        try:
            return format_reset(window["resets_at"])
        except (ValueError, TypeError):
            pass
    if "clock" in window:
        return window.get("countdown", "?"), window["clock"]
    return None


def iso_z(ts):
    return datetime.datetime.fromtimestamp(ts, tz=datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def compute_pace(window, fetched_at):
    if not isinstance(window, dict) or fetched_at is None:
        return None
    pct = window.get("pct")
    if isinstance(pct, bool) or not isinstance(pct, (int, float)):
        return None
    reset = parse_iso(window.get("resets_at"))
    if reset is None:
        return None
    remaining = (reset.timestamp() - fetched_at) % WEEKLY_PERIOD_S
    elapsed = 0.0 if remaining == 0 else WEEKLY_PERIOD_S - remaining
    if elapsed < SUPPRESS_AFTER_RESET_S:
        return None
    expected = min(100.0, elapsed / WEEKLY_PERIOD_S * 100.0)
    return {"expected": expected, "actual": float(pct), "elapsed": elapsed,
            "ahead": (float(pct) - expected) >= AHEAD_THRESHOLD_PCT}


def pace_fields(window, fetched_at):
    p = compute_pace(window, fetched_at)
    if p is None:
        return {}
    out = {"expectedPct": round(p["expected"], 1), "aheadOfPace": p["ahead"]}
    if p["elapsed"] > 0 and p["actual"] > 0:
        rate = p["actual"] / p["elapsed"]
        remaining_pct = 100.0 - p["actual"]
        eta = fetched_at if remaining_pct <= 0 else fetched_at + remaining_pct / rate
        out["projectedExhaustionAt"] = iso_z(eta)
    if p["actual"] <= 0:
        out["willLastToReset"] = True
    elif p["elapsed"] > 0:
        rate = p["actual"] / p["elapsed"]
        out["willLastToReset"] = p["actual"] + rate * (WEEKLY_PERIOD_S - p["elapsed"]) <= 100.0
    return out


def window_to_json(entry):
    out = {"pct": entry["pct"]}
    if "resets_at" in entry:
        out["resetsAt"] = entry["resets_at"]
    cell = fresh_reset_strings(entry)
    if cell:
        out["countdown"], out["clock"] = cell
    return out


def usage_to_json(usage, fetched_at):
    out = {}
    if "five_hour" in usage:
        out["fiveHour"] = window_to_json(usage["five_hour"])
    if "seven_day" in usage:
        out["sevenDay"] = window_to_json(usage["seven_day"])
        out["sevenDay"].update(pace_fields(usage["seven_day"], fetched_at))
    if "spend" in usage:
        spend = usage["spend"]
        s = {"used": spend["used"], "limit": spend["limit"], "pct": spend["pct"], "currency": spend["currency"]}
        if "resets_at" in spend:
            s["resetsAt"] = spend["resets_at"]
        cell = fresh_reset_strings(spend)
        if cell:
            s["countdown"], s["clock"] = cell
        out["spend"] = s
    if "scoped" in usage:
        scoped = []
        for w in usage["scoped"]:
            j = window_to_json(w)
            j.update(pace_fields(w, fetched_at))
            j["name"] = w["name"]
            scoped.append(j)
        out["scoped"] = scoped
    return out


def _num(value):
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def usage_entry(row, email, org_uuid, now):
    """The identity-guarded read model of one row (UsageStore.entries, without the 429 rules)."""
    if not (isinstance(row, dict) and row.get("email") == email and row.get("organizationUuid", "") == org_uuid):
        return {"last_good": None, "fetched_at": None, "age_s": None, "trust": False}
    fetched = _num(row.get("fetchedAt"))
    last_good = row.get("lastGood") if isinstance(row.get("lastGood"), dict) else None
    age = (now - fetched) if fetched is not None else None
    failures = int(row.get("consecutiveFailures") or 0)
    next_poll = _num(row.get("nextPollAt"))
    within = age is not None and age <= TRUST_MAX_AGE_S
    trust = within and (failures > 0 or (next_poll is not None and now < next_poll))
    return {"last_good": last_good, "fetched_at": fetched, "age_s": age, "trust": trust}


def decision_value(entry):
    if entry["last_good"] is not None and entry["age_s"] is not None and (entry["age_s"] <= STALE_OK_S or entry["trust"]):
        return entry["last_good"]
    return None


def freshness(fetched_at, age_s, prefix):
    if fetched_at is None:
        return {}
    out = {prefix + "FetchedAt": iso_z(fetched_at)}
    if age_s is not None:
        out[prefix + "AgeSeconds"] = round(age_s, 1)
    return out


def usage_status_fields(entry):
    """(usageStatus, usage, extra freshness fields) like account_row / the status payload."""
    value = decision_value(entry)
    if isinstance(value, dict):
        return "ok", usage_to_json(value, entry["fetched_at"]), freshness(entry["fetched_at"], entry["age_s"], "usage")
    extra = {}
    if entry["last_good"] is not None and entry["fetched_at"] is not None:
        extra["lastGoodUsage"] = usage_to_json(entry["last_good"], entry["fetched_at"])
        extra.update(freshness(entry["fetched_at"], entry["age_s"], "lastGood"))
    return "unavailable", None, extra


# ------------------------------------------------------------------------------------------------
# commands

def emit(payload):
    print(json.dumps(payload, indent=2))


def accounts_info(state, seq):
    ident = state.identity()
    active = find_slot(seq, ident[0], ident[1]) if ident else None
    out = []
    for num in seq.get("sequence", []):
        acc = seq["accounts"].get(str(num), {})
        out.append((num, acc.get("email", "unknown"), acc.get("organizationName", "") or "",
                    acc.get("organizationUuid", "") or "", str(num) == active, acc.get("alias", "") or "",
                    bool(acc.get("disabled"))))
    return out


def cmd_list(state, json_mode):
    seq = state.sequence()
    if seq is None:
        if json_mode:
            emit({"schemaVersion": SCHEMA_VERSION, "activeAccountNumber": None, "accounts": []})
        else:
            print("No accounts are managed yet.")
        return 0
    rows = state.usage_rows()
    now = time.time()
    info = accounts_info(state, seq)
    entries = {}
    accounts = []
    active_num = None
    for num, email, org_name, org_uuid, active, alias, disabled in info:
        if active:
            active_num = num
        entry = usage_entry(rows.get(str(num)), email, org_uuid, now)
        entries[str(num)] = entry
        status, usage, extra = usage_status_fields(entry)
        row = {"number": num, "email": email, "organizationName": org_name, "organizationUuid": org_uuid,
               "isOrganization": bool(org_uuid), "active": active, "usageStatus": status, "usage": usage}
        if alias:
            row["alias"] = alias
        if disabled:
            row["disabled"] = True
        row.update(extra)
        accounts.append(row)
    if not json_mode:
        print("Accounts:")
        for num, email, org_name, org_uuid, active, alias, disabled in info:
            label = "%s (%s)" % (alias, email) if alias else email
            marks = (" (active)" if active else "") + (" (disabled)" if disabled else "")
            print("  %s: %s [%s]%s" % (num, label, display_tag(org_name), marks))
        return 0
    payload = {"schemaVersion": SCHEMA_VERSION, "activeAccountNumber": active_num, "accounts": accounts}
    dup, seen = [], {}
    for num, email, org_name, org_uuid, active, alias, disabled in info:
        uuid = (seq["accounts"].get(str(num), {}).get("uuid") or "").strip()
        if uuid:
            other = seen.get((uuid, org_uuid))
            if other and other != str(num):
                dup.append("Account-%s and Account-%s both authenticate as %s — remove or re-login one of them."
                           % (other, num, email))
            elif not other:
                seen[(uuid, org_uuid)] = str(num)
    if dup:
        payload["duplicateAccountWarnings"] = dup
    lock, keys = [], {}
    for num, *_ in info:
        usage = decision_value(entries[str(num)])
        h5 = usage.get("five_hour") if isinstance(usage, dict) else None
        d7 = usage.get("seven_day") if isinstance(usage, dict) else None
        if not isinstance(h5, dict) or not isinstance(d7, dict):
            continue
        key = (h5.get("pct"), h5.get("resets_at"), d7.get("pct"), d7.get("resets_at"))
        if None in key:
            continue
        if key in keys:
            lock.append("Account-%s and Account-%s report identical usage and reset times — they may be the same "
                        "account (issue #117). If it persists, log in with the missing account and re-add it: "
                        "cswap add --slot N" % (keys[key], num))
        else:
            keys[key] = str(num)
    if lock:
        payload["lockstepUsageWarnings"] = lock
    emit(payload)
    return 0


def cmd_status(state, json_mode):
    ident = state.identity()
    seq = state.sequence()
    if ident is None:
        payload = {"schemaVersion": SCHEMA_VERSION, "active": None}
    elif not seq or not find_slot(seq, ident[0], ident[1]):
        payload = {"schemaVersion": SCHEMA_VERSION, "active": {"email": ident[0], "managed": False}}
    else:
        num = find_slot(seq, ident[0], ident[1])
        acct = seq["accounts"][num]
        org_uuid = acct.get("organizationUuid", "") or ""
        entry = usage_entry(state.usage_rows().get(num), ident[0], org_uuid, time.time())
        status, usage, extra = usage_status_fields(entry)
        active = {"number": int(num), "email": ident[0], "organizationName": acct.get("organizationName", "") or "",
                  "organizationUuid": org_uuid, "isOrganization": bool(org_uuid), "managed": True,
                  "usageStatus": status, "usage": usage}
        if acct.get("alias"):
            active["alias"] = acct["alias"]
        active.update(extra)
        payload = {"schemaVersion": SCHEMA_VERSION, "active": active, "totalManagedAccounts": len(seq["accounts"])}
    if json_mode:
        emit(payload)
    elif payload["active"] is None:
        print("Status: No active Claude account")
    elif not payload["active"].get("managed"):
        print("Status: %s (not managed)" % payload["active"]["email"])
    else:
        a = payload["active"]
        print("Status: Account-%d (%s) [%s]" % (a["number"], a["email"], display_tag(a["organizationName"])))
    return 0


def lock_fail_due(state):
    """FAKE_CSWAP_LOCK_FAILS=<n>: true for the first n switch calls (counter kept in the root)."""
    try:
        limit = int(state.config.get("FAKE_CSWAP_LOCK_FAILS") or "0")
    except ValueError:
        limit = 0
    if limit <= 0:
        return False
    path = os.path.join(state.root, ".fake-cswap-lock-fails")
    try:
        with open(path, "r", encoding="utf-8") as f:
            done = int(f.read().strip() or "0")
    except (OSError, ValueError):
        done = 0
    if done >= limit:
        return False
    atomic_write(path, "%d\n" % (done + 1))
    return True


def cmd_switch(state, identifier, json_mode, force):
    if not os.path.exists(state.sequence_file):
        raise ConfigError("No accounts are managed yet")
    seq = state.sequence()
    strategy = "direct"
    ident = state.identity()
    current = find_slot(seq, ident[0], ident[1]) if ident else None
    if identifier is None:
        # Bare `switch`: rotate to the next enabled account after the current one.
        strategy = None
        order = [str(n) for n in seq.get("sequence", []) if not seq["accounts"].get(str(n), {}).get("disabled")]
        if not order:
            raise ConfigError("No accounts are managed yet")
        anchor = current or (str(seq.get("activeAccountNumber")) if seq.get("activeAccountNumber") is not None else None)
        identifier = order[(order.index(anchor) + 1) % len(order)] if anchor in order else order[0]
    if not identifier.isdigit() and find_by_alias(seq, identifier) is None and not valid_email(identifier):
        raise ValidationError("Invalid account identifier: %s" % identifier)
    target = resolve_identifier(seq, identifier)
    if not target:
        raise AccountNotFoundError("No account found with identifier: %s" % identifier)
    if target not in seq["accounts"]:
        raise AccountNotFoundError("Account-%s does not exist" % target)
    to_email = seq["accounts"][target].get("email", "")
    to_ref = {"number": int(target), "email": to_email}
    if not force and current == target:
        message = "Already on Account-%s (%s)" % (target, to_email)
        if not json_mode:
            print(message)
            return 0
        emit({"schemaVersion": SCHEMA_VERSION, "switched": False, "from": to_ref, "to": to_ref, "strategy": strategy,
              "reason": "already-active", "message": message, "warnings": []})
        return 0
    state.refuse_session_shell()
    try:
        delay = max(0, int(state.config.get("FAKE_CSWAP_SWITCH_DELAY_MS") or "0"))
    except ValueError:
        delay = 0
    if delay:
        time.sleep(delay / 1000.0)
    from_num = current if ident else (str(seq["activeAccountNumber"]) if seq.get("activeAccountNumber") is not None else None)
    from_email = seq["accounts"].get(from_num, {}).get("email", "") if from_num else ""
    who = from_email or (ident[0] if ident else "the current login")
    fail = (state.config.get("FAKE_CSWAP_FAIL") or "").strip().lower()
    if fail == "lock" or lock_fail_due(state):
        raise ClaudeCodeLockTimeout("Could not acquire .claude.lock while switching %s to Account-%s (%s) — Claude "
                                    "Code appears to be refreshing credentials. Retry in a few seconds."
                                    % (who, target, to_email))
    if fail == "error":
        raise SwitchError("Switch failed and was rolled back: could not write the stored credentials of Account-%s "
                          "(%s); %s stays active" % (target, to_email, who))
    target_text = None
    try:
        with open(state.config_path(target, to_email), "r", encoding="utf-8") as f:
            target_text = f.read()
    except OSError:
        pass
    if target_text is None:
        raise SwitchError("Account-%s (%s) has no stored config backup; log in with it and run: cswap add --slot %s"
                          % (target, to_email, target))
    try:
        target_config = json.loads(target_text)
    except ValueError:
        raise SwitchError("Invalid oauthAccount in backup")
    oauth = target_config.get("oauthAccount") if isinstance(target_config, dict) else None
    if not isinstance(oauth, dict) or not oauth:
        raise SwitchError("Invalid oauthAccount in backup")
    # Back up the outgoing login's config into its own slot, then splice the target's identity.
    current_text = None
    try:
        with open(state.claude_json, "r", encoding="utf-8") as f:
            current_text = f.read()
    except OSError:
        pass
    if current and current_text is not None:
        atomic_write(state.config_path(current, seq["accounts"][current].get("email", "")), current_text)
    try:
        current_config = json.loads(current_text) if current_text is not None else None
    except ValueError:
        current_config = None
    if isinstance(current_config, dict):
        current_config["oauthAccount"] = oauth
        write_json(state.claude_json, current_config)
    else:
        write_json(state.claude_json, target_config)
    seq["activeAccountNumber"] = int(target)
    seq["lastUpdated"] = timestamp()
    state.write_sequence(seq)
    from_ref = {"number": int(from_num), "email": from_email} if from_num else None
    switched = from_ref != to_ref
    warnings = []
    if (state.config.get("FAKE_CSWAP_WARN") or "") == "1":
        warnings.append("Account-%s (%s) has a live session-mode Claude instance (PID 4242). Running the same "
                        "account as both the default login and a session can make one copy's token go stale if "
                        "the server rotates it. If the session later fails to authenticate, exit it and re-run "
                        "'cswap run %s'." % (target, to_email, target))
    message = ("Switched to Account-%s (%s)" if switched else "Already on Account-%s (%s)") % (target, to_email)
    if not json_mode:
        print(message)
        return 0
    emit({"schemaVersion": SCHEMA_VERSION, "switched": switched, "from": from_ref, "to": to_ref, "strategy": strategy,
          "reason": "switched" if switched else "already-active", "message": message, "warnings": warnings})
    return 0


def clear_dead_token(state, num, email, org_uuid, fresh_usage):
    rows = state.usage_rows()
    row = rows.get(num)
    if not (isinstance(row, dict) and row.get("email") == email and row.get("organizationUuid", "") == org_uuid):
        row = {"email": email, "organizationUuid": org_uuid}
        rows[num] = row
    row.update({"claimId": None, "claimUntil": 0.0, "authDeadStrikes": 0, "struckFingerprint": None,
                "consecutiveFailures": 0, "lastError": None, "backoffUntil": None})
    if fresh_usage:
        now = time.time()
        row.update({"lastAttemptAt": now, "lastGood": {"five_hour": {"pct": 0.0}, "seven_day": {"pct": 0.0}},
                    "fetchedAt": now})
    state.write_usage_rows(rows)


def cmd_add(state, slot, alias):
    state.refuse_session_shell()
    state.init_sequence()
    if alias is not None:
        try:
            alias = normalize_alias(alias)
        except ValueError as e:
            raise ValidationError(str(e))
    ident = state.identity()
    if ident is None:
        raise ConfigError("No active Claude account found. Please log in first.")
    email, org_uuid, account_uuid = ident
    seq = state.sequence()
    existing = find_slot(seq, email, org_uuid)
    fresh_usage = (state.config.get("FAKE_CSWAP_ADD_USAGE") or "") == "1"
    with open(state.claude_json, "r", encoding="utf-8") as f:
        config_text = f.read()
    if slot is None and existing:
        if alias is not None:
            conflict = alias_in_use(seq, alias, existing)
            if conflict is not None:
                raise ValidationError("Alias '%s' is already used by account %s" % (alias, conflict))
        atomic_write(state.config_path(existing, email), config_text)
        clear_dead_token(state, existing, email, org_uuid, fresh_usage)
        if alias is not None:
            seq["accounts"][existing]["alias"] = alias
        seq["activeAccountNumber"] = int(existing)
        seq["lastUpdated"] = timestamp()
        state.write_sequence(seq)
        tag = display_tag(seq["accounts"][existing].get("organizationName", ""))
        print("Updated credentials for Account %s (%s [%s])." % (existing, email, tag))
        return 0
    displace = migrate_from = None
    if slot is not None:
        if slot < 1:
            raise ConfigError("Slot number must be >= 1")
        num = str(slot)
        if existing and existing != num:
            migrate_from = existing
        other = seq["accounts"].get(num)
        if other and not (other.get("email") == email and other.get("organizationUuid", "") == org_uuid):
            print("Slot %d already occupied" % slot)
            print("%s [%s]" % (other.get("email", "unknown"), display_tag(other.get("organizationName", ""))))
            try:
                answer = input("Overwrite slot %d? [y/N] " % slot).strip().lower()
            except (EOFError, KeyboardInterrupt):
                print("\nCancelled")
                return 0
            if answer not in ("y", "yes"):
                print("Cancelled")
                return 0
            displace = num
    else:
        num = str(max([int(k) for k in seq["accounts"]] or [0]) + 1)
    existing_alias = None
    if slot is not None:
        prior = seq["accounts"].get(num) or {}
        if prior.get("email") == email and prior.get("organizationUuid", "") == org_uuid:
            existing_alias = prior.get("alias")
        if migrate_from:
            existing_alias = seq["accounts"][migrate_from].get("alias") or existing_alias
    if alias is not None:
        conflict = alias_in_use(seq, alias, num)
        if conflict is not None:
            raise ValidationError("Alias '%s' is already used by account %s" % (alias, conflict))
    try:
        oauth = (json.loads(config_text) or {}).get("oauthAccount") or {}
    except (ValueError, AttributeError):
        oauth = {}
    for gone in (displace, migrate_from):
        if gone:
            old_email = seq["accounts"][gone].get("email", "")
            try:
                os.unlink(state.config_path(gone, old_email))
            except OSError:
                pass
            if int(gone) in seq["sequence"]:
                seq["sequence"].remove(int(gone))
            del seq["accounts"][gone]
    atomic_write(state.config_path(num, email), config_text)
    clear_dead_token(state, num, email, oauth.get("organizationUuid", "") or "", fresh_usage)
    record = {"email": email, "uuid": account_uuid, "organizationUuid": oauth.get("organizationUuid", "") or "",
              "organizationName": oauth.get("organizationName", "") or "", "added": timestamp()}
    carried = alias if alias is not None else existing_alias
    if carried:
        record["alias"] = carried
    seq["accounts"][num] = record
    if int(num) not in seq["sequence"]:
        seq["sequence"].append(int(num))
        seq["sequence"].sort()
    seq["activeAccountNumber"] = int(num)
    seq["lastUpdated"] = timestamp()
    state.write_sequence(seq)
    if migrate_from:
        print("Moved from slot %s → %s" % (migrate_from, slot))
    print("Added Account %s: %s [%s]" % (num, email, display_tag(record["organizationName"])))
    return 0


def cmd_alias(state, args):
    positional, unset = [], False
    for a in args:
        if a == "--unset":
            unset = True
        elif a == "--debug":
            pass
        elif a.startswith("-"):
            raise UsageError("unrecognized arguments: %s" % a, "alias")
        else:
            positional.append(a)
    if len(positional) > 2:
        raise UsageError("unrecognized arguments: %s" % " ".join(positional[2:]), "alias")
    account = positional[0] if positional else None
    name = positional[1] if len(positional) > 1 else None
    if unset and name:
        raise UsageError("--unset does not take a NAME argument", "alias")
    if unset and account is None:
        raise UsageError("NUM|EMAIL is required with --unset", "alias")
    if account is not None and not unset and not name:
        raise UsageError("NAME is required (or pass --unset to remove the alias)", "alias")
    if account is None:
        seq = state.sequence() or {"accounts": {}}
        rows = sorted(((n, a.get("alias"), a.get("email", "")) for n, a in seq["accounts"].items() if a.get("alias")),
                      key=lambda r: int(r[0]))
        if not rows:
            print("No aliases set")
            return 0
        print("Aliases:")
        for n, a, e in rows:
            print("  %s: %s (%s)" % (n, a, e))
        return 0
    state.refuse_session_shell()
    normalized = None
    if not unset:
        try:
            normalized = normalize_alias(name)
        except ValueError as e:
            raise ValidationError(str(e))
    seq = state.sequence()
    num = resolve_identifier(seq, account)
    if not num:
        raise AccountNotFoundError("No account found with identifier: %s" % account)
    record = (seq or {}).get("accounts", {}).get(num)
    if not record:
        raise AccountNotFoundError("Account-%s does not exist" % num)
    if unset:
        if "alias" in record:
            del record["alias"]
            seq["lastUpdated"] = timestamp()
            state.write_sequence(seq)
        print("Removed alias for Account %s" % num)
        return 0
    conflict = alias_in_use(seq, normalized, num)
    if conflict is not None:
        raise ConfigError("Alias '%s' is already used by account %s" % (normalized, conflict))
    record["alias"] = normalized
    seq["lastUpdated"] = timestamp()
    state.write_sequence(seq)
    print("Set alias '%s' for Account %s" % (normalized, num))
    return 0


# ------------------------------------------------------------------------------------------------
# argv

SUBCOMMANDS = {"list": "--list", "ls": "--list", "status": "--status", "add": "--add-account"}
UNSUPPORTED = {"run", "auto", "map", "unmap", "unclaimed", "swap", "move", "config", "help", "add-token", "remove",
               "rm", "disable", "enable", "export", "import", "purge", "upgrade", "update", "tui", "watch", "menubar"}


def parse_main(argv):
    """The subset of cswap's main parser CODD uses."""
    if argv and argv[0] == "switch":
        rest = argv[1:]
        argv = ["--switch-to"] + rest if rest and not rest[0].startswith("-") else ["--switch"] + rest
    elif argv and argv[0] in SUBCOMMANDS:
        argv = [SUBCOMMANDS[argv[0]]] + argv[1:]
    opts = {"command": None, "target": None, "json": False, "slot": None, "alias": None, "force": False}
    commands = {"--list": "list", "--status": "status", "--add-account": "add", "--switch": "switch"}
    i = 0
    while i < len(argv):
        a = argv[i]
        key, eq, inline = a.partition("=")
        if a in commands:
            if opts["command"]:
                raise UsageError("argument %s: not allowed with argument %s" % (a, opts["command"]))
            opts["command"] = a
        elif key in ("--switch-to", "--slot", "--alias"):
            if eq:
                value = inline
            elif i + 1 < len(argv) and not argv[i + 1].startswith("-"):
                value = argv[i + 1]
                i += 1
            else:
                raise UsageError("argument %s: expected one argument" % key)
            if key == "--switch-to":
                if opts["command"]:
                    raise UsageError("argument --switch-to: not allowed with argument %s" % opts["command"])
                opts["command"], opts["target"] = "--switch-to", value
            elif key == "--slot":
                try:
                    opts["slot"] = int(value)
                except ValueError:
                    raise UsageError("argument --slot: invalid int value: '%s'" % value)
            else:
                opts["alias"] = value
        elif a == "--json":
            opts["json"] = True
        elif a == "--force":
            opts["force"] = True
        elif a == "--debug":
            pass
        elif not a.startswith("-") and opts["command"] is None and i == 0:
            raise UsageError("argument: invalid choice: '%s'" % a)
        else:
            raise UsageError("unrecognized arguments: %s" % a)
        i += 1
    if opts["command"] is None:
        raise UsageError("no command given — try '%s help'" % PROG)
    if opts["json"] and opts["command"] not in ("--list", "--status", "--switch", "--switch-to"):
        raise UsageError("--json can only be used with 'list', 'status', or 'switch'")
    if opts["slot"] is not None and opts["command"] != "--add-account":
        raise UsageError("--slot can only be used with 'add' or 'add-token'")
    if opts["alias"] is not None and opts["command"] != "--add-account":
        raise UsageError("--alias can only be used with 'add'")
    if opts["force"] and opts["command"] != "--switch-to":
        raise UsageError("--force can only be used with 'import' or 'switch <num|email>'")
    return opts


def usage_exit(message, sub=None):
    prog = PROG + (" " + sub if sub else "")
    sys.stderr.write("usage: %s <command> [args] [options]\n%s: error: %s\n" % (prog, prog, message))
    return 2


def log_call(config, argv):
    path = config.get("FAKE_CSWAP_LOG")
    if not path:
        return
    line = json.dumps({"argv": argv, "at": int(time.time() * 1000)}, ensure_ascii=False) + "\n"
    os.makedirs(os.path.dirname(os.path.abspath(path)), mode=0o700, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(fd, line.encode("utf-8"))
    finally:
        os.close(fd)


def main():
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8")
        except (AttributeError, ValueError):
            pass
    argv = sys.argv[1:]
    config = load_config()
    for name in ("FAKE_CSWAP_LOG", "FAKE_CSWAP_ROOT", "FAKE_CLAUDE_JSON"):
        if config.get(name):
            why = refusal(config[name])
            if why:
                sys.stderr.write("fake-cswap: refusing %s=%s (%s)\n" % (name, config[name], why))
                return 1
    try:
        log_call(config, argv)
    except OSError as e:
        sys.stderr.write("fake-cswap: cannot write FAKE_CSWAP_LOG (%s)\n" % e.strerror)
        return 1
    if argv and argv[0] == "--version":
        print(VERSION_LINE)
        return 0
    if argv and argv[0] in UNSUPPORTED:
        return usage_exit("'%s' is not supported by the fake cswap" % argv[0])
    json_mode = "--json" in argv and (not argv or argv[0] != "alias")
    try:
        if argv and argv[0] == "alias":
            if not config.get("FAKE_CSWAP_ROOT"):
                sys.stderr.write("fake-cswap: FAKE_CSWAP_ROOT is not set\n")
                return 1
            return cmd_alias(State(config), argv[1:])
        opts = parse_main(argv)
    except UsageError as e:
        return usage_exit(e.args[0], e.args[1] if len(e.args) > 1 else None)
    except ClaudeSwitchError as e:
        sys.stderr.write("Error: %s\n" % e)
        return 1
    if not config.get("FAKE_CSWAP_ROOT"):
        sys.stderr.write("fake-cswap: FAKE_CSWAP_ROOT is not set\n")
        return 1
    state = State(config)
    try:
        command = opts["command"]
        if command == "--list":
            return cmd_list(state, json_mode)
        if command == "--status":
            return cmd_status(state, json_mode)
        if command == "--add-account":
            return cmd_add(state, opts["slot"], opts["alias"])
        return cmd_switch(state, opts["target"] if command == "--switch-to" else None, json_mode, opts["force"])
    except ClaudeSwitchError as e:
        if json_mode:
            emit({"schemaVersion": SCHEMA_VERSION, "error": {"type": type(e).__name__, "message": str(e)}})
        else:
            sys.stderr.write("Error: %s\n" % e)
        return 1


if __name__ == "__main__":
    sys.exit(main())
