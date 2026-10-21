# Checks behind scripts/m3-fixtures/selftest.sh (run as `python3 -I _selftest.py <command> …`).
# Every check prints `CHECK ok <name>` or `CHECK FAIL <name> -- <detail>`; the last line of a command
# is `CHECKS-DONE <command>` (selftest.sh counts a missing one as a failure). Python 3.9 compatible.
# Everything happens under the temp folder selftest.sh passes in; nothing is sent anywhere but
# 127.0.0.1 (the hook sink) and port 9 (refused at once).
import base64
import datetime
import json
import os
import pty
import re
import select
import shutil
import signal
import stat
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
ESCAPES = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-9;?<=>]*[ -/]*[@-~]")
EMAILS = {1: "personal@example.com", 2: "north@example.com", 3: "work@example.com", 4: "new@example.com"}
ALIASES = {1: "個人", 2: "藍鵲", 3: "工作"}
ORG_UUIDS = {1: "", 2: "org-2", 3: "", 4: "org-4"}
ORG_NAMES = {1: "personal@example.com's Organization", 2: "Synthetic North Org", 3: "", 4: "Synthetic Org 4"}
TIERS = {1: "default_claude_max_20x", 2: "default_claude_max_20x", 3: "default_claude_max_20x", 4: "default_claude_max_5x"}
DAY, HOUR, MINUTE = 86400, 3600, 60


def check(name, ok, detail=""):
    if ok:
        print("CHECK ok %s" % name, flush=True)
    else:
        print("CHECK FAIL %s -- %s" % (name, str(detail)[:600]), flush=True)
    return bool(ok)


def mode(path):
    return stat.S_IMODE(os.lstat(path).st_mode)


def load_json(path):
    with open(path, "rb") as f:
        return json.loads(f.read().decode("utf-8"))


def read_text(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def wait_until(fn, timeout, step=0.05):
    deadline = time.monotonic() + timeout
    while True:
        if fn():
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(step)


def ps_field(pid, field):
    out = subprocess.run(["/bin/ps", "-o", field + "=", "-p", str(pid)], stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, env={"LC_ALL": "C", "PATH": "/usr/bin:/bin"}).stdout
    return out.decode("utf-8", "replace").strip()


def pgrep(pattern, command_prefix=None):
    out = subprocess.run(["/usr/bin/pgrep", "-f", pattern], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout
    pids = [int(p) for p in out.split()]
    if command_prefix:
        pids = [p for p in pids if ps_field(p, "command").startswith(command_prefix)]
    return pids


def shq(s):
    return "'" + s.replace("'", "'\\''") + "'"


def parse_iso(text):
    return datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))


def folder_name(path):
    out = []
    for ch in path:
        if ("0" <= ch <= "9") or ("A" <= ch <= "Z") or ("a" <= ch <= "z"):
            out.append(ch)
        else:
            out.append("-" * (2 if ord(ch) > 0xFFFF else 1))
    return "".join(out)


def base_env(tmp):
    home = os.path.join(tmp, "home")
    os.makedirs(home, exist_ok=True)
    return {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home, "TMPDIR": tmp + "/", "LANG": "en_US.UTF-8",
            "LC_CTYPE": "en_US.UTF-8", "TERM": "xterm-256color", "USER": os.environ.get("USER", "test")}


def run(argv, env, stdin=b"", cwd=None, timeout=30):
    started = time.monotonic()
    p = subprocess.run(argv, input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, cwd=cwd,
                       timeout=timeout)
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace"), time.monotonic() - started


# ------------------------------------------------------------------------------------------------
# make-cswap-state.sh

def cmd_state(root, claude_dir, now_iso, count):
    count = int(count)
    now = parse_iso(now_iso)
    seq_path = os.path.join(root, "sequence.json")
    raw = read_text(seq_path)
    seq = json.loads(raw)
    check("sequence.json in cswap's writer form (indent 2, ASCII escapes, no trailing newline)",
          raw == json.dumps(seq, indent=2) and "\\u" in raw, raw[:120])
    check("sequence.json key order activeAccountNumber, lastUpdated, sequence, accounts",
          list(seq) == ["activeAccountNumber", "lastUpdated", "sequence", "accounts"], list(seq))
    check("sequence.json active #3, sequence 1..%d" % count,
          seq["activeAccountNumber"] == 3 and seq["sequence"] == list(range(1, count + 1)), (seq["activeAccountNumber"], seq["sequence"]))
    check("sequence.json lastUpdated is cswap's timestamp form",
          re.match(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$", seq["lastUpdated"]) is not None, seq["lastUpdated"])
    accounts = seq["accounts"]
    check("sequence.json has exactly the %d accounts" % count, sorted(accounts) == [str(n) for n in range(1, count + 1)], sorted(accounts))
    for n in range(1, count + 1):
        a = accounts.get(str(n), {})
        want_keys = ["email", "uuid", "organizationUuid", "organizationName", "added"] + (["alias"] if n in ALIASES else [])
        check("account #%d fields (email, org, alias %s)" % (n, ALIASES.get(n, "none")),
              list(a) == want_keys and a["email"] == EMAILS[n] and a["organizationUuid"] == ORG_UUIDS[n]
              and a["organizationName"] == ORG_NAMES[n] and a.get("alias") == ALIASES.get(n)
              and UUID_RE.match(a["uuid"]) is not None, a)
    check("#1's organizationName carries its e-mail (a D31 carrier)", "personal@example.com" in accounts["1"]["organizationName"],
          accounts["1"]["organizationName"])

    usage_path = os.path.join(root, "cache", "usage.json")
    raw = read_text(usage_path)
    usage = json.loads(raw)
    check("usage.json schemaVersion 2 in cswap's writer form", usage.get("schemaVersion") == 2 and raw == json.dumps(usage, indent=2)
          and list(usage) == ["schemaVersion", "accounts"], raw[:80])
    rows = usage.get("accounts", {})
    check("usage.json has one row per account", sorted(rows) == [str(n) for n in range(1, count + 1)], sorted(rows))
    for n in range(1, count + 1):
        r = rows.get(str(n), {})
        check("usage row #%d guarded by its e-mail + organizationUuid" % n,
              r.get("email") == accounts[str(n)]["email"] and r.get("organizationUuid") == accounts[str(n)]["organizationUuid"], r)
        check("usage row #%d is a clean success row" % n,
              r.get("consecutiveFailures") == 0 and r.get("lastError") is None and r.get("authDeadStrikes") == 0
              and r.get("claimId") is None and r.get("backoffUntil") is None and isinstance(r.get("lastGood"), dict), r)

    def reset_of(n, w):
        return parse_iso(rows[str(n)]["lastGood"][w]["resets_at"])

    def fetched_of(n):
        return rows[str(n)]["fetchedAt"]

    def countdown(n, w, text):
        return rows[str(n)]["lastGood"][w].get("countdown") == text

    lg1 = rows["1"]["lastGood"]
    check("#1 five_hour not started: pct 0 without resets_at", lg1["five_hour"] == {"pct": 0.0}, lg1["five_hour"])
    check("#1 seven_day 0 %% used, reset now+4d09h (with microseconds, like the API)",
          lg1["seven_day"]["pct"] == 0.0 and reset_of(1, "seven_day").replace(microsecond=0) == now + datetime.timedelta(days=4, hours=9)
          and reset_of(1, "seven_day").microsecond > 0 and countdown(1, "seven_day", "4d 9h"), lg1["seven_day"])
    lg2 = rows["2"]["lastGood"]
    check("#2 five_hour 2 %%, reset now+2h37m (countdown at fetch time)",
          lg2["five_hour"]["pct"] == 2.0 and reset_of(2, "five_hour") == now + datetime.timedelta(hours=2, minutes=37)
          and countdown(2, "five_hour", "2h 40m"), lg2["five_hour"])
    check("#2 seven_day 54 %%, reset now+1d12h", lg2["seven_day"]["pct"] == 54.0
          and reset_of(2, "seven_day") == now + datetime.timedelta(days=1, hours=12), lg2["seven_day"])
    check("#2 scoped Fable 0 %%", lg2.get("scoped") == [{"name": "Fable", "pct": 0.0}], lg2.get("scoped"))
    lg3 = rows["3"]["lastGood"]
    check("#3 five_hour 9 %% reset now+2h57m, seven_day 85 %% reset now+3d01h",
          lg3["five_hour"]["pct"] == 9.0 and reset_of(3, "five_hour") == now + datetime.timedelta(hours=2, minutes=57)
          and lg3["seven_day"]["pct"] == 85.0 and reset_of(3, "seven_day") == now + datetime.timedelta(days=3, hours=1), lg3)
    check("fetchedAt epoch seconds: #1 / #2 3 min ago, #3 10 min ago",
          fetched_of(1) == now.timestamp() - 180 and fetched_of(2) == now.timestamp() - 180
          and fetched_of(3) == now.timestamp() - 600 and all(isinstance(fetched_of(n), float) for n in (1, 2, 3)),
          [fetched_of(n) for n in (1, 2, 3)])
    check("resets_at are ISO 8601 with +00:00 (the API's form)",
          all(rows[str(n)]["lastGood"][w]["resets_at"].endswith("+00:00") for n in range(1, count + 1)
              for w in ("five_hour", "seven_day") if "resets_at" in rows[str(n)]["lastGood"][w]), "")
    if count == 4:
        lg4 = rows["4"]["lastGood"]
        check("#4 five_hour 30 %%, seven_day 20 %%", lg4["five_hour"]["pct"] == 30.0 and lg4["seven_day"]["pct"] == 20.0, lg4)

    configs = os.path.join(root, "configs")
    names = sorted(os.listdir(configs))
    want = sorted(".claude-config-%d-%s.json" % (n, EMAILS[n]) for n in range(1, count + 1))
    check("configs/.claude-config-<n>-<email>.json for each account", names == want, names)
    good = True
    for n in range(1, count + 1):
        p = os.path.join(configs, ".claude-config-%d-%s.json" % (n, EMAILS[n]))
        try:
            oa = load_json(p).get("oauthAccount", {})
        except (OSError, ValueError) as e:
            oa = {"error": str(e)}
        good = check("config backup #%d: oauthAccount identity and plan tier" % n,
                     oa.get("emailAddress") == EMAILS[n] and oa.get("organizationUuid") == ORG_UUIDS[n]
                     and oa.get("organizationRateLimitTier") == TIERS[n] and oa.get("organizationType") == "claude_max"
                     and mode(p) == 0o600, oa) and good

    sessions = os.path.join(root, "sessions")
    entries = sorted(os.listdir(sessions))
    check("sessions/ holds only the #2 profile 2-north_example.com (cswap's slugify_email)", entries == ["2-north_example.com"], entries)
    prof = os.path.join(sessions, "2-north_example.com")
    link = os.path.join(prof, "settings.json")
    check("profile has sessions/ and projects/ directories",
          os.path.isdir(os.path.join(prof, "sessions")) and os.path.isdir(os.path.join(prof, "projects"))
          and not os.path.islink(prof), sorted(os.listdir(prof)) if os.path.isdir(prof) else prof)
    check("profile settings.json is an absolute symlink to <claudeDir>/settings.json",
          os.path.islink(link) and os.readlink(link) == os.path.join(claude_dir, "settings.json"),
          os.readlink(link) if os.path.islink(link) else link)
    try:
        manifest = load_json(os.path.join(prof, ".cswap-shared.json"))
    except (OSError, ValueError) as e:
        manifest = {"error": str(e)}
    check("profile carries cswap's share manifest", manifest == {"items": ["settings.json"], "mode": "symlink"}, manifest)
    check("no stale marker by default", not any(e.endswith(".cswap-stale-credentials") for e in os.listdir(sessions))
          and not os.path.exists(os.path.join(prof, ".cswap-stale-credentials")), entries)
    check("the profile path is what the CLI maps to cswap-2",
          re.search(r"/\.claude-swap-backup/sessions/2-[^/]+$", prof) is not None, prof)

    cj = os.path.join(os.path.dirname(claude_dir), ".claude.json")
    try:
        cjd = load_json(cj)
    except (OSError, ValueError) as e:
        cjd = {"error": str(e)}
    check("<claudeDir>/../.claude.json: oauthAccount #3 and an empty projects object",
          (cjd.get("oauthAccount") or {}).get("emailAddress") == EMAILS[3] and cjd.get("projects") == {}
          and (cjd.get("oauthAccount") or {}).get("organizationRateLimitTier") == "default_claude_max_20x", cjd)
    dirs = [root] + [os.path.join(root, d) for d in ("cache", "configs", "credentials", "sessions")] + [prof]
    files = [seq_path, usage_path, cj]
    check("directories 0700, state files 0600 (cswap's modes)",
          all(mode(d) == 0o700 for d in dirs) and all(mode(f) == 0o600 for f in files),
          [(p, oct(mode(p))) for p in dirs + files])
    check("credentials/ exists and stays empty (never read by CODD)",
          os.path.isdir(os.path.join(root, "credentials")) and os.listdir(os.path.join(root, "credentials")) == [], "")
    check("the Claude directory exists", os.path.isdir(claude_dir), claude_dir)


def cmd_stale(root, number, dirname):
    sessions = os.path.join(root, "sessions")
    marker = os.path.join(sessions, ".%s.cswap-stale-credentials" % dirname)
    check("stale marker %s is cswap's sibling marker" % os.path.basename(marker),
          os.path.isfile(marker) and os.path.getsize(marker) == 0 and mode(marker) == 0o600, sorted(os.listdir(sessions)))
    prof = os.path.join(sessions, dirname)
    check("stale profile %s exists with sessions/ and projects/" % dirname,
          os.path.isdir(os.path.join(prof, "sessions")) and os.path.isdir(os.path.join(prof, "projects"))
          and os.path.islink(os.path.join(prof, "settings.json")), prof)
    check("legacy child marker not written", not os.path.exists(os.path.join(prof, ".cswap-stale-credentials")), prof)


# ------------------------------------------------------------------------------------------------
# fake-cswap.py

def cmd_cswap(fixtures, tmp):
    base = os.path.join(tmp, "cs")
    home = os.path.join(base, "home")
    root = os.path.join(home, ".claude-swap-backup")
    claude_dir = os.path.join(home, ".claude")
    env = base_env(base)
    env["HOME"] = os.path.join(base, "user")
    env["TMPDIR"] = tmp + "/"
    os.makedirs(env["HOME"], exist_ok=True)
    code, out, err, _ = run([os.path.join(fixtures, "make-cswap-state.sh"), root, claude_dir], env)
    check("fake cswap: state root for the CLI tests", code == 0 and out.strip() == root, (code, out, err))
    bindir = os.path.join(base, "bin")
    os.makedirs(bindir, exist_ok=True)
    cswap = os.path.join(bindir, "cswap")
    shutil.copy(os.path.join(fixtures, "fake-cswap.py"), cswap)
    os.chmod(cswap, 0o755)
    log = os.path.join(base, "cswap-log.jsonl")
    with open(cswap + ".env", "w", encoding="utf-8") as f:
        f.write("# sidecar of the copied fake cswap\nFAKE_CSWAP_ROOT=%s\nFAKE_CSWAP_LOG=%s\n" % (root, log))
    seq_path = os.path.join(root, "sequence.json")
    cj_path = os.path.join(home, ".claude.json")
    calls = []

    def cs(*args, **extra):
        e = dict(env)
        e.update(extra)
        calls.append(list(args))
        return run([cswap] + list(args), e)

    def seq():
        return load_json(seq_path)

    code, out, err, _ = cs("--version")
    check("--version prints `cswap 0.26.0`", code == 0 and out == "cswap 0.26.0\n", (code, out, err))

    code, out, err, _ = cs("list", "--json")
    try:
        lst = json.loads(out)
    except ValueError:
        lst = {}
    check("list --json: exit 0, schema 1, active #3 (from .claude.json)",
          code == 0 and lst.get("schemaVersion") == 1 and lst.get("activeAccountNumber") == 3, (code, out[:200], err))
    rows = {a.get("number"): a for a in lst.get("accounts", [])}
    check("list --json: accounts 1, 2, 3 in sequence order with e-mails and organizationName (like cswap)",
          [a.get("number") for a in lst.get("accounts", [])] == [1, 2, 3]
          and all(rows[n]["email"] == EMAILS[n] and rows[n]["organizationName"] == ORG_NAMES[n]
                  and rows[n]["isOrganization"] == bool(ORG_UUIDS[n]) for n in (1, 2, 3)), lst)
    check("list --json: CJK aliases read back (ASCII-escaped on stdout)",
          all(rows[n].get("alias") == ALIASES[n] for n in (1, 2, 3)) and "\\u5de5\\u4f5c" in out, [rows[n].get("alias") for n in rows])
    check("list --json: only #3 active", [n for n in rows if rows[n]["active"]] == [3], [rows[n]["active"] for n in rows])
    r1, r2, r3 = rows.get(1, {}), rows.get(2, {}), rows.get(3, {})
    check("list --json: #1 / #2 fetched 3 min ago are usageStatus ok with usageFetchedAt / usageAgeSeconds",
          r1.get("usageStatus") == "ok" and r2.get("usageStatus") == "ok" and 170 <= (r2.get("usageAgeSeconds") or 0) <= 300
          and str(r2.get("usageFetchedAt", "")).endswith("Z"), (r1.get("usageStatus"), r2.get("usageStatus"), r2.get("usageAgeSeconds")))
    u2 = r2.get("usage") or {}
    check("list --json: #2 fiveHour 2 / sevenDay 54 with resetsAt, countdown, clock and pace fields",
          (u2.get("fiveHour") or {}).get("pct") == 2.0 and (u2.get("sevenDay") or {}).get("pct") == 54.0
          and "resetsAt" in u2.get("sevenDay", {}) and "countdown" in u2.get("sevenDay", {})
          and u2.get("sevenDay", {}).get("aheadOfPace") is False and 77 <= u2.get("sevenDay", {}).get("expectedPct", 0) <= 80
          and u2.get("sevenDay", {}).get("willLastToReset") is True, u2)
    check("list --json: #2 scoped Fable 0 %%", u2.get("scoped") == [{"pct": 0.0, "name": "Fable"}], u2.get("scoped"))
    check("list --json: #1 fiveHour without resetsAt", (r1.get("usage") or {}).get("fiveHour") == {"pct": 0.0}, r1.get("usage"))
    lg3 = r3.get("lastGoodUsage") or {}
    check("list --json: #3 fetched 10 min ago is unavailable with lastGoodUsage (cswap's 300 s rule), ahead of pace",
          r3.get("usageStatus") == "unavailable" and r3.get("usage") is None and (lg3.get("sevenDay") or {}).get("pct") == 85.0
          and (lg3.get("sevenDay") or {}).get("aheadOfPace") is True and "projectedExhaustionAt" in lg3.get("sevenDay", {})
          and 590 <= (r3.get("lastGoodAgeSeconds") or 0) <= 900, r3)
    check("list --json: no warnings keys when clean", "duplicateAccountWarnings" not in lst and "lockstepUsageWarnings" not in lst,
          sorted(lst))

    code, out, err, _ = cs("status", "--json")
    try:
        st = json.loads(out)
    except ValueError:
        st = {}
    active = st.get("active") or {}
    check("status --json: managed #3 工作, 3 accounts",
          code == 0 and active.get("number") == 3 and active.get("email") == EMAILS[3] and active.get("managed") is True
          and active.get("alias") == "工作" and st.get("totalManagedAccounts") == 3, (code, out[:300]))

    before_cj = read_text(cj_path)
    code, out, err, _ = cs("switch", "2", "--json")
    try:
        sw = json.loads(out)
    except ValueError:
        sw = {}
    check("switch 2 --json: switched from #3 to #2 with cswap's message",
          code == 0 and sw.get("schemaVersion") == 1 and sw.get("switched") is True
          and sw.get("from") == {"number": 3, "email": EMAILS[3]} and sw.get("to") == {"number": 2, "email": EMAILS[2]}
          and sw.get("reason") == "switched" and sw.get("message") == "Switched to Account-2 (north@example.com)"
          and sw.get("strategy") == "direct" and sw.get("warnings") == [], (code, out, err))
    cj = load_json(cj_path)
    check("switch: sequence.json activeAccountNumber 2", seq()["activeAccountNumber"] == 2, seq()["activeAccountNumber"])
    check("switch: .claude.json identity is #2's (other keys kept)",
          cj.get("oauthAccount", {}).get("emailAddress") == EMAILS[2] and cj.get("oauthAccount", {}).get("organizationUuid") == "org-2"
          and cj.get("projects") == {} and mode(cj_path) == 0o600, cj)
    backup3 = os.path.join(root, "configs", ".claude-config-3-work@example.com.json")
    check("switch: the outgoing login was backed up into its slot", read_text(backup3) == before_cj, read_text(backup3)[:120])
    code, out, err, _ = cs("switch", "2", "--json")
    try:
        sw = json.loads(out)
    except ValueError:
        sw = {}
    check("switch to the active account: switched false, already-active",
          code == 0 and sw.get("switched") is False and sw.get("reason") == "already-active"
          and sw.get("message") == "Already on Account-2 (north@example.com)", out)
    code, out, err, _ = cs("switch", "9", "--json")
    check("switch to an unknown slot: AccountNotFoundError envelope, exit 1",
          code == 1 and json.loads(out or "{}").get("error", {}).get("type") == "AccountNotFoundError", (code, out))

    snapshot = (read_text(seq_path), read_text(cj_path))
    for fail, kind in (("lock", "ClaudeCodeLockTimeout"), ("error", "SwitchError")):
        code, out, err, _ = cs("switch", "3", "--json", FAKE_CSWAP_FAIL=fail)
        try:
            envl = json.loads(out)
        except ValueError:
            envl = {}
        message = (envl.get("error") or {}).get("message", "")
        check("FAKE_CSWAP_FAIL=%s: %s envelope on stdout, exit 1, nothing changed" % (fail, kind),
              code == 1 and envl.get("schemaVersion") == 1 and (envl.get("error") or {}).get("type") == kind
              and list(envl) == ["schemaVersion", "error"] and (read_text(seq_path), read_text(cj_path)) == snapshot, (code, out))
        check("FAKE_CSWAP_FAIL=%s: the message carries account e-mails (redaction input)" % fail,
              EMAILS[2] in message and EMAILS[3] in message, message)
    code, out, err, _ = cs("switch", "3", FAKE_CSWAP_FAIL="lock")
    check("a failure without --json: `Error: …` on stderr, exit 1", code == 1 and out == "" and err.startswith("Error: Could not acquire"),
          (code, out, err))

    results = []
    for _ in range(3):
        code, out, err, _ = cs("switch", "3", "--json", FAKE_CSWAP_LOCK_FAILS="2")
        try:
            results.append((code, (json.loads(out).get("error") or {}).get("type"), json.loads(out).get("switched")))
        except ValueError:
            results.append((code, "?", None))
    check("FAKE_CSWAP_LOCK_FAILS=2: two ClaudeCodeLockTimeout, then the switch succeeds",
          results == [(1, "ClaudeCodeLockTimeout", None), (1, "ClaudeCodeLockTimeout", None), (0, None, True)]
          and seq()["activeAccountNumber"] == 3, results)
    code, out, err, elapsed = cs("switch", "1", "--json", FAKE_CSWAP_SWITCH_DELAY_MS="400")
    check("FAKE_CSWAP_SWITCH_DELAY_MS=400 delays the switch", code == 0 and elapsed >= 0.4 and seq()["activeAccountNumber"] == 1,
          (code, elapsed))
    code, out, err, _ = cs("switch", "工作", "--json", FAKE_CSWAP_WARN="1")
    try:
        sw = json.loads(out)
    except ValueError:
        sw = {}
    check("switch by alias, FAKE_CSWAP_WARN=1 adds cswap's live-session warning (with the e-mail)",
          code == 0 and sw.get("to") == {"number": 3, "email": EMAILS[3]} and len(sw.get("warnings") or []) == 1
          and EMAILS[3] in sw["warnings"][0], out)
    check("back on #3 after the switches", seq()["activeAccountNumber"] == 3
          and load_json(cj_path)["oauthAccount"]["emailAddress"] == EMAILS[3], seq()["activeAccountNumber"])

    before = read_text(seq_path)
    code, out, err, _ = cs("add", "--slot", "4", "--alias", "工作室")
    check("add --alias 工作室: cswap's exact error on stderr, exit 1, nothing added",
          code == 1 and err.strip() == "Error: alias '工作室' may only contain letters, digits, '-', '_', and '.'"
          and read_text(seq_path) == before and not os.path.exists(os.path.join(root, "configs", ".claude-config-4-new@example.com.json")),
          (code, out, err))
    data = load_json(cj_path)
    data["oauthAccount"] = {"accountUuid": "a4000000-0000-4000-8000-000000000004", "emailAddress": EMAILS[4],
                            "organizationUuid": "org-4", "organizationName": "Synthetic Org 4",
                            "organizationRateLimitTier": "default_claude_max_5x", "organizationType": "claude_max"}
    with open(cj_path, "w", encoding="utf-8") as f:
        f.write(json.dumps(data, indent=2))
    code, out, err, _ = cs("add", "--slot", "4", "--alias", "Studio")
    s = seq()
    a4 = s["accounts"].get("4", {})
    check("add --slot 4 --alias Studio: added from the .claude.json identity, alias stored as `studio`",
          code == 0 and "Added Account 4: new@example.com" in out and a4.get("email") == EMAILS[4] and a4.get("alias") == "studio"
          and a4.get("organizationUuid") == "org-4" and s["sequence"] == [1, 2, 3, 4] and s["activeAccountNumber"] == 4, (code, out, err, a4))
    check("add: config backup and an identity-guarded usage row for #4",
          os.path.isfile(os.path.join(root, "configs", ".claude-config-4-new@example.com.json"))
          and load_json(os.path.join(root, "cache", "usage.json"))["accounts"].get("4", {}).get("email") == EMAILS[4], "")
    code, out, err, _ = cs("add", "--slot", "4", "--alias", "lab")
    check("add again for the same login and slot: alias replaced", code == 0 and seq()["accounts"]["4"].get("alias") == "lab", (code, out, err))

    code, out, err, _ = cs("alias", "4", "Studio")
    check("alias 4 Studio: stored as `studio`", code == 0 and out.strip() == "Set alias 'studio' for Account 4"
          and seq()["accounts"]["4"]["alias"] == "studio", (code, out, err))
    for value, text in (("123", "cannot be purely numeric"), (" -x", "cannot start with '-'"), ("a b", "may only contain"),
                        ("a@b", "may only contain"), ("工作", "may only contain"), ("  ", "alias cannot be empty")):
        code, out, err, _ = cs("alias", "4", value)
        check("alias 4 %r refused like cswap (exit 1)" % value, code == 1 and text in err and seq()["accounts"]["4"]["alias"] == "studio",
              (code, err))
    code, out, err, _ = cs("alias", "4", "-x")
    check("alias 4 -x: an option to argparse (exit 2)", code == 2 and "unrecognized arguments" in err, (code, err))
    code, out, err, _ = cs("alias", "2", "studio")
    check("alias already used by another account: ConfigError, exit 1", code == 1 and "already used by account 4" in err, (code, err))
    code, out, err, _ = cs("alias", "4", "--unset")
    check("alias 4 --unset removes it", code == 0 and "alias" not in seq()["accounts"]["4"], (code, out, err))
    code, out, err, _ = cs("alias", "9", "x")
    check("alias of an unknown slot: exit 1", code == 1 and "Account-9 does not exist" in err, (code, err))
    code, out, err, _ = cs("alias", "4")
    check("alias without NAME: usage error, exit 2", code == 2, (code, err))

    for args in (("frobnicate",), ("run", "2"), ("add", "--json"), ("list", "--bogus"), ()):
        code, out, err, _ = cs(*args)
        check("unknown / unsupported %r: exit 2" % (" ".join(args),), code == 2 and out == "", (code, out, err))

    try:
        lines = [json.loads(line) for line in read_text(log).splitlines()]
    except (OSError, ValueError) as e:
        lines = [{"error": str(e)}]
    check("FAKE_CSWAP_LOG: one {argv, at} line per call, argv exact", [l.get("argv") for l in lines] == calls
          and all(sorted(l) == ["argv", "at"] and isinstance(l["at"], int) and l["at"] > 1.7e12 for l in lines)
          and mode(log) == 0o600, (len(lines), len(calls)))

    no_tmpdir = {k: v for k, v in env.items() if k != "TMPDIR"}
    code, out, err, _ = run([cswap, "status", "--json"], no_tmpdir)
    try:
        user_tmp = os.path.realpath(os.confstr(65537))
    except (ValueError, OSError):
        user_tmp = "/nonexistent"
    if os.path.realpath(tmp).startswith(user_tmp.rstrip("/") + "/"):
        check("without TMPDIR the per-user temp folder (confstr) is the allowed area", code == 0
              and json.loads(out or "{}").get("schemaVersion") == 1, (code, err))
    else:
        check("without TMPDIR outside the per-user temp folder: refused", code == 1 and "outside $TMPDIR" in err, (code, err))
    zone = os.path.join(tmp, "zone")
    os.makedirs(zone, exist_ok=True)
    snapshot = (read_text(seq_path), read_text(log))
    code, out, err, _ = run([cswap, "list", "--json"], dict(env, TMPDIR=zone))
    check("refuses FAKE_CSWAP_ROOT / FAKE_CSWAP_LOG outside $TMPDIR (exit 1, nothing read or written)",
          code == 1 and "outside $TMPDIR" in err and out == "" and (read_text(seq_path), read_text(log)) == snapshot, (code, err))
    code, out, err, _ = run([cswap, "list", "--json"], dict(env, HOME=home))
    check("refuses a root inside ~/.claude-swap-backup (exit 1)", code == 1 and ".claude-swap-backup" in err and out == "", (code, err))
    code, out, err, _ = run([cswap, "list", "--json"], dict(env, FAKE_CLAUDE_JSON=os.path.join(env["HOME"], ".claude.json")))
    check("refuses FAKE_CLAUDE_JSON at ~/.claude.json (exit 1)", code == 1 and "FAKE_CLAUDE_JSON" in err, (code, err))
    code, out, err, _ = run([cswap, "switch", "2", "--json"], dict(env, CLAUDE_CONFIG_DIR=os.path.join(root, "sessions", "2-north_example.com")))
    check("switch inside a cswap run profile shell: SwitchError like cswap", code == 1
          and json.loads(out or "{}").get("error", {}).get("type") == "SwitchError", (code, out))


# ------------------------------------------------------------------------------------------------
# make-claude-settings.sh / rate-limits.sh

def commands_of(settings):
    out = []
    for groups in (settings.get("hooks") or {}).values():
        for g in groups:
            if isinstance(g.get("command"), str):
                out.append(g["command"])
            for h in g.get("hooks") or []:
                out.append(h.get("command", ""))
    return out


def cmd_settings(path, kind, claude_dir, user_cmd, data_root=""):
    raw = read_text(path)
    s = json.loads(raw)
    base = os.path.join(os.path.dirname(claude_dir), "fixture-tools")
    check("[%s] 2-space JSON like Claude writes (non-ASCII kept, trailing newline)" % kind,
          raw == json.dumps(s, indent=2, ensure_ascii=False) + "\n" and "測試" in raw, raw[:100])
    keys = ["env", "permissions", "hooks"] + (["statusLine"] if kind != "none" else []) + ["enabledPlugins", "alwaysThinkingEnabled"]
    check("[%s] top-level keys %s" % (kind, ",".join(keys)), list(s) == keys, list(s))
    check("[%s] unrelated keys with non-ASCII strings, no secrets" % kind,
          "範例外掛@本機市集" in s["enabledPlugins"] and any("文件" in a for a in s["permissions"]["allow"])
          and not any(re.search(r"(?i)(token|secret|key)\b", k) for k in s["env"]), s["env"])
    hooks = s["hooks"]
    tap = {e: [h for g in hooks[e] for h in g.get("hooks", []) if "hook-tap" in h.get("command", "")] for e in hooks}
    tap_events = sorted(e for e in tap if tap[e])
    check("[%s] hook-tap handlers on 12 events" % kind, len(tap_events) == 12 and all(len(tap[e]) == 1 for e in tap_events), tap_events)
    check("[%s] hook-tap PermissionRequest timeout 600 (others 10)" % kind,
          tap["PermissionRequest"][0].get("timeout") == 600 and all(tap[e][0].get("timeout") == 10 for e in tap_events if e != "PermissionRequest"),
          tap.get("PermissionRequest"))
    osa = [(e, h["command"]) for e in hooks for g in hooks[e] for h in g.get("hooks", []) if "osascript" in h.get("command", "")]
    check("[%s] two osascript display notification handlers (Notification, Stop)" % kind,
          sorted(e for e, _ in osa) == ["Notification", "Stop"] and all("display notification" in c for _, c in osa), osa)
    web = [(e, g) for e in hooks for g in hooks[e] if "status-writer.js" in json.dumps(g)]
    if kind in ("legacy", "legacy-nochain", "desktop"):
        official = [(e, g) for e, g in web if "hooks" in g]
        old = [(e, g) for e, g in web if "command" in g]
        check("[legacy] status-writer.js in the official shape on the 10 CODD web events",
              sorted(e for e, _ in official) == sorted(["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                                                       "PostToolUseFailure", "PermissionRequest", "Notification", "Stop",
                                                       "StopFailure", "SessionEnd"])
              and all(g["hooks"][0].get("timeout") == 5 and g["hooks"][0].get("type") == "command" and len(g["hooks"]) == 1
                      for _, g in official), [e for e, _ in official])
        check("[legacy] matcher \"*\" exactly on the tool / permission / notification events",
              sorted(e for e, g in official if g.get("matcher") == "*")
              == sorted(["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "Notification"])
              and all(list(g)[0] == "matcher" for _, g in official if "matcher" in g), "")
        check("[legacy] one old {matcher, command} entry", len(old) == 1 and sorted(old[0][1]) == ["command", "matcher"], old)
        check("[legacy] hook command is CODD web's guard form",
              official[0][1]["hooks"][0]["command"].startswith('[ -z "$CODD_TERMINAL_ID" ] || [ ! -x \''), official[0][1])
    else:
        check("[%s] no CODD web leftovers" % kind, web == [] and "codd-statusline.js" not in raw, web)
    if kind == "desktop":
        check("[desktop] the global wrapper replaced CODD web's status line", "codd-statusline.js" not in raw, "")
    paths = [m for c in commands_of(s) + [s.get("statusLine", {}).get("command", "")] for m in re.findall(r"(/[^\s'\"]+)", c)
             if not m.startswith("/bin/")]
    allowed = [base + "/"] + ([data_root.rstrip("/") + "/"] if data_root else [])
    # A path with a space or a quote is cut into fragments by the regex; a fragment must be a prefix of an
    # allowed folder then.
    check("[%s] every path in a command is fake, under the temp folder" % kind,
          paths and all(any(p.startswith(a) or a.startswith(p) for a in allowed) for p in paths), paths)
    sl = s.get("statusLine")
    if kind == "none":
        return
    check("[%s] statusLine type command, padding 0" % kind, sl.get("type") == "command" and sl.get("padding") == 0
          and list(sl) == ["type", "command", "padding"], sl)
    cmd = sl["command"]
    m = re.search(r"--chain-b64 ([A-Za-z0-9+/=]+)", cmd)
    if kind == "plain":
        check("[plain] statusLine is the user's own command", cmd == user_cmd, cmd)
    elif kind in ("legacy", "legacy-nochain"):
        if user_cmd:
            check("[%s] statusLine is CODD web's wrapper chaining the user's command (base64 round trip)" % kind,
                  "codd-statusline.js" in cmd and m is not None and base64.b64decode(m.group(1)).decode("utf-8") == user_cmd
                  and base64.b64encode(user_cmd.encode()).decode() == m.group(1) and cmd.startswith("if [ -x '"), cmd)
        else:
            check("[%s] standalone CODD web wrapper (no chain)" % kind, "codd-statusline.js" in cmd and m is None
                  and cmd.endswith("; else :; fi"), cmd)
    elif kind == "desktop":
        binary = os.path.join(data_root, "bin", "codd-statusline")
        check("[desktop] statusLine is the D11 global wrapper (single-quote escaped)",
              cmd == "if [ -x %s ]; then %s --data-root %s --chain-b64 %s; else /bin/sh -c %s; fi"
              % (shq(binary), shq(binary), shq(data_root), base64.b64encode(user_cmd.encode()).decode(), shq(user_cmd)), cmd)
    env = {"PATH": "/usr/bin:/bin", "HOME": os.path.dirname(claude_dir)}
    if user_cmd:
        direct = subprocess.run(["/bin/sh", "-c", user_cmd], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, env=env, timeout=10)
        out = subprocess.run(["/bin/sh", "-c", cmd], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             env=env, timeout=10)
        check("[%s] statusLine under /bin/sh (tool missing): falls back to the user's command (same output)" % kind,
              out.returncode == direct.returncode == 0 and out.stdout == direct.stdout and out.stdout
              and (user_cmd != "printf 'USER-SL-%s' ok" or out.stdout == b"USER-SL-ok"),
              (out.returncode, out.stdout, direct.stdout, out.stderr))
    if kind == "desktop":
        binary = os.path.join(data_root, "bin", "codd-statusline")
        os.makedirs(os.path.dirname(binary), exist_ok=True)
        with open(binary, "w") as f:
            f.write("#!/bin/sh\nprintf 'STUB'; for a in \"$@\"; do printf ' [%s]' \"$a\"; done\n")
        os.chmod(binary, 0o755)
        out = subprocess.run(["/bin/sh", "-c", cmd], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             env=env, timeout=10).stdout.decode()
        want = "STUB [--data-root] [%s] [--chain-b64] [%s]" % (data_root, base64.b64encode(user_cmd.encode()).decode())
        check("[desktop] with the binary present it runs `codd-statusline --data-root <root> --chain-b64 <b64>`", out == want, out)
        os.unlink(binary)


def cmd_project(path, user_cmd):
    raw = read_text(path)
    s = json.loads(raw)
    check("--project: <cwd>/.claude/settings.json holds only a statusLine",
          s == {"statusLine": {"type": "command", "command": user_cmd}} and raw.endswith("\n"), raw)


def cmd_rate_limits(fixtures, tmp):
    script = os.path.join(fixtures, "rate-limits.sh")
    env = base_env(tmp)
    f = os.path.join(tmp, "rl", "limits.json")
    cases = [
        (["91", "1792040340", "15", "1792296000"],
         {"five_hour": {"used_percentage": 91, "resets_at": 1792040340}, "seven_day": {"used_percentage": 15, "resets_at": 1792296000}}),
        (["-", "-", "99.5", "1792296000"], {"seven_day": {"used_percentage": 99.5, "resets_at": 1792296000}}),
        (["12", "-", "15", "1792296000"], {"seven_day": {"used_percentage": 15, "resets_at": 1792296000}}),
        (["9", "1792040340000", "85", "2026-10-18T04:00:00Z"],
         {"five_hour": {"used_percentage": 9, "resets_at": 1792040340000}, "seven_day": {"used_percentage": 85, "resets_at": "2026-10-18T04:00:00Z"}}),
        (["-", "-", "-", "-"], {}),
    ]
    for args, want in cases:
        code, out, err, _ = run([script, f] + args, env)
        try:
            got = load_json(f)
            raw = read_text(f)
        except (OSError, ValueError) as e:
            got, raw = {"error": str(e)}, ""
        check("rate-limits.sh %s" % " ".join(args), code == 0 and got == want and out.strip() == f and mode(f) == 0o600
              and raw.endswith("}\n") and ": " not in raw, (code, raw, err))
    for args in (["abc", "1", "2", "3"], ["1", "soon", "2", "3"], ["1", "2", "3"], ["nan", "1", "2", "3"]):
        code, out, err, _ = run([script, f] + args, env)
        check("rate-limits.sh refuses %s (exit 2)" % " ".join(args), code == 2, (code, err))


# ------------------------------------------------------------------------------------------------
# pty helper (as in scripts/m2-fixtures/_selftest.py)

class Pty:
    def __init__(self, argv, env, cwd, answer_da1=True):
        pid, fd = pty.fork()
        if pid == 0:
            try:
                os.chdir(cwd)
                os.execve(argv[0], argv, env)
            finally:
                os._exit(127)
        self.pid, self.fd = pid, fd
        self.buf = b""
        self.answer_da1 = answer_da1
        self.answered = False
        self.status = None

    def pump(self, timeout):
        try:
            r, _, _ = select.select([self.fd], [], [], timeout)
        except (OSError, ValueError):
            return False
        if not r:
            return False
        try:
            data = os.read(self.fd, 65536)
        except OSError:
            data = b""
        if not data:
            return False
        self.buf += data
        if self.answer_da1 and not self.answered and b"\x1b[c" in self.buf:
            self.answered = True
            self.write(b"\x1b[?62;22c")
        return True

    def text(self):
        return self.buf.decode("utf-8", "replace")

    def lines(self):
        return ESCAPES.sub("", self.text()).replace("\r\n", "\n").split("\n")

    def count(self, prefix):
        return sum(1 for l in self.lines() if l.startswith(prefix))

    def wait_for(self, predicate, timeout):
        deadline = time.monotonic() + timeout
        while not predicate(self):
            left = deadline - time.monotonic()
            if left <= 0:
                return False
            if not self.pump(min(left, 0.1)) and self.exited():
                return predicate(self)
        return True

    def wait_text(self, needle, timeout=10, count=1):
        return self.wait_for(lambda p: p.text().count(needle) >= count, timeout)

    def settle(self, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            self.pump(0.05)

    def write(self, data):
        os.write(self.fd, data)

    def exited(self):
        if self.status is None:
            try:
                pid, status = os.waitpid(self.pid, os.WNOHANG)
            except ChildProcessError:
                return True
            if pid == self.pid:
                self.status = status
        return self.status is not None

    def wait_exit(self, timeout):
        deadline = time.monotonic() + timeout
        while not self.exited():
            if time.monotonic() >= deadline:
                return None
            self.pump(0.05)
        while self.pump(0.05):
            pass
        return self.status

    def close(self):
        if self.fd >= 0:
            try:
                os.close(self.fd)
            except OSError:
                pass
            self.fd = -1

    def kill(self):
        if not self.exited():
            try:
                os.kill(self.pid, signal.SIGKILL)
            except OSError:
                pass
            self.wait_exit(3)


def exit_code(status):
    if status is None:
        return None
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return -os.WTERMSIG(status)
    return None


def submits(p):
    return sum(1 for l in p.lines() if l == "FAKE-SUBMIT")


def copy_fake(script, directory, sidecar):
    os.makedirs(directory, exist_ok=True)
    copy = os.path.join(directory, "fake-claude")
    shutil.copy(script, copy)
    os.chmod(copy, 0o755)
    with open(copy + ".env", "w", encoding="utf-8") as f:
        f.write("# sidecar of the copied fake claude\n" + "".join("%s=%s\n" % kv for kv in sidecar.items()))
    return copy


# ------------------------------------------------------------------------------------------------
# fake-claude-m3.sh: the M2 contract (ported from scripts/m2-fixtures/_selftest.py)

def cmd_fake_claude(script, tmp):
    reg = os.path.join(tmp, "fcreg")
    cwd = os.path.join(tmp, "work", "fc")
    os.makedirs(cwd, exist_ok=True)
    sid = "6f1d1c2e-7a3b-4c5d-8e9f-0a1b2c3d4e5f"
    marker = os.path.join(tmp, "fc1")
    settings = '{"permissions":{"defaultMode":"default"}}'
    env = base_env(tmp)
    env.update({"FAKE_REGISTRY_DIR": reg, "FAKE_PRINT_ENV": "FAKE_REGISTRY_DIR,LANG,FAKE_NOT_SET_X",
                "CODD_SESSION_ID": "0b7e6a52-3c41-4d2e-9f80-1a2b3c4d5e6f"})
    argv = [script, "--session-id", sid, "--settings", settings, "--model", "opus", "-n", "名稱 測試", "--fake-marker", marker]
    started = time.monotonic()
    p = Pty(argv, env, cwd)
    try:
        ready = p.wait_text("FAKE-READY", 10)
        check("m2 contract: FAKE-READY", ready, repr(p.text()[-400:]))
        if not ready:
            return
        check("m2 contract: FAKE-READY within 3 s", time.monotonic() - started < 3, time.monotonic() - started)
        lines = p.lines()
        want_argv = "FAKE-ARGV --session-id %s --settings <settings:%dB> --model opus -n 名稱 測試 --fake-marker %s" % (
            sid, len(settings.encode()), marker)
        check("m2 contract: FAKE-ARGV line", want_argv in lines, [l for l in lines if l.startswith("FAKE-ARGV")])
        check("m2 contract: FAKE-ENV value / unset lines",
              "FAKE-ENV FAKE_REGISTRY_DIR=%s" % reg in lines and "FAKE-ENV LANG=en_US.UTF-8" in lines
              and "FAKE-ENV-UNSET FAKE_NOT_SET_X" in lines, [l for l in lines if l.startswith("FAKE-ENV")])
        check("m2 contract: DA1 probe answered", "FAKE-DA1-OK" in lines, lines)
        check("m2 contract: no SessionStart hook, no statusLine",
              "FAKE-SESSIONSTART-MISSING hook=" in lines and "FAKE-STATUSLINE-MISSING" in lines, lines)
        check("m2 contract: FAKE-CLAUDE line", "FAKE-CLAUDE session=%s resume=none url=" % sid in lines, lines)
        head = p.buf[:p.buf.find(b"FAKE-READY")]
        check("OSC 0 title `fake claude m3` and bracketed paste before FAKE-READY",
              b"\x1b]0;fake claude m3\x07" in head and b"\x1b[?2004h" in head, repr(head[-80:]))
        path = os.path.join(reg, "%d.json" % p.pid)
        check("m2 contract: FAKE-REGISTRY <dir>/<pid>.json", "FAKE-REGISTRY " + path in lines and os.path.isfile(path), lines)
        entry = load_json(path) if os.path.isfile(path) else {}
        check("m2 contract: registry entry (pid, session, cwd, idle, name)",
              entry.get("pid") == p.pid and entry.get("sessionId") == sid and entry.get("cwd") == os.path.realpath(cwd)
              and entry.get("status") == "idle" and entry.get("name") == "名稱 測試" and entry.get("version") == "2.1.300", entry)
        p.write(b"hello \xe4\xb8")
        time.sleep(0.05)
        p.write(b"\x96\xe7\x95\x8c\r")
        got = p.wait_for(lambda q: submits(q) >= 1, 5)
        busy = load_json(path).get("status") if os.path.exists(path) else None
        check("m2 contract: FAKE-LINE hello 世界 + FAKE-SUBMIT, registry busy", got and "FAKE-LINE hello 世界" in p.lines()
              and busy == "busy", (p.lines()[-4:], busy))
        check("m2 contract: registry idle after Stop", wait_until(lambda: load_json(path).get("status") == "idle", 3), "")
        p.write("\x1b[200~第一行\r第二行\x1b[201~\r".encode())
        got = p.wait_for(lambda q: submits(q) >= 2, 5)
        check("m2 contract: FAKE-PASTE 第一行⏎第二行", got and "FAKE-PASTE 第一行⏎第二行" in p.lines(), p.lines()[-4:])
        p.write(b"\x1b")
        p.wait_text("FAKE-KEY 1b", 3)
        p.write("ab\x7fc測\x7f\r".encode())
        got = p.wait_for(lambda q: submits(q) >= 3, 5)
        check("m2 contract: lone ESC and backspace", got and "FAKE-KEY 1b" in p.lines() and "FAKE-LINE ac" in p.lines(), p.lines()[-4:])
        p.write(b"FAKE-EXIT\r")
        status = p.wait_exit(5)
        check("m2 contract: FAKE-EXIT exits 3, registry removed, paste mode off",
              exit_code(status) == 3 and "FAKE-CLAUDE-EXITING" in p.lines() and not os.path.exists(path) and b"\x1b[?2004l" in p.buf,
              exit_code(status))
    finally:
        p.close()
        p.kill()


class Sink(BaseHTTPRequestHandler):
    records = []
    lock = threading.Lock()

    def do_POST(self):  # noqa: N802 - http.server API
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)
        with Sink.lock:
            Sink.records.append({"t": time.monotonic(), "path": self.path, "headers": dict(self.headers.items()),
                                 "body": json.loads(body.decode("utf-8"))})
        self.send_response(204)
        self.send_header("Connection", "close")
        self.end_headers()

    def log_message(self, *args):
        pass


def events(name=None):
    with Sink.lock:
        return [r for r in Sink.records if name is None or r["body"].get("hook_event_name") == name]


def cmd_fake_claude_hooks(script, tmp):
    fc = os.path.join(tmp, "fch")
    reg = os.path.join(tmp, "fcreg2")
    logs = os.path.join(tmp, "fclog")
    copy = copy_fake(script, fc, {"FAKE_REGISTRY_DIR": reg, "FAKE_PRINT_ENV": "CODD_SESSION_ID", "FAKE_LOG_DIR": logs})
    hook_out = os.path.join(tmp, "hook-out.txt")
    hook = os.path.join(fc, "hook.sh")
    with open(hook, "w") as f:
        f.write('#!/bin/sh\n{ printf \'%%s\\n\' "$*"; cat; } > "%s"\n' % hook_out)
    os.chmod(hook, 0o755)
    server = HTTPServer(("127.0.0.1", 0), Sink)
    url = "http://127.0.0.1:%d/hooks" % server.server_address[1]
    http = {"type": "http", "url": url, "timeout": 2}
    settings = json.dumps({"hooks": {
        "SessionStart": [{"hooks": [{"type": "command", "command": hook, "args": ["session-start", "--url", url], "timeout": 5}]}],
        "UserPromptSubmit": [{"hooks": [http]}], "Stop": [{"hooks": [http]}], "SessionEnd": [{"hooks": [http]}]}},
        separators=(",", ":"), sort_keys=True)
    rid = "3f2a91c0-1b2c-4d3e-8f40-5a6b7c8d9e0f"
    codd = "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"
    token = "ab" * 32
    env = base_env(tmp)
    env.update({"CODD_HOOK_URL": url, "CODD_HOOK_TOKEN": token, "CODD_SESSION_ID": codd})
    cwd = os.path.join(tmp, "work", "fc2")
    os.makedirs(cwd, exist_ok=True)
    argv = [copy, "--resume", rid, "--settings", settings, "--remote-control"]
    p = Pty(argv, env, cwd)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        ready = p.wait_text("FAKE-READY", 10)
        check("m2 hooks: FAKE-READY with a sidecar", ready, repr(p.text()[-400:]))
        if not ready:
            return
        lines = p.lines()
        path = os.path.join(reg, "%d.json" % p.pid)
        check("m2 hooks: sidecar read (FAKE_PRINT_ENV, FAKE_REGISTRY_DIR)",
              "FAKE-ENV CODD_SESSION_ID=%s" % codd in lines and "FAKE-REGISTRY " + path in lines, lines)
        check("m2 hooks: SessionStart ran the command hook", "FAKE-SESSIONSTART hook=%s status=0" % hook in lines, lines)
        p.write("fix 登入\r".encode())
        got = wait_until(lambda: len(events("Stop")) >= 1, 5)
        ups = events("UserPromptSubmit")
        check("m2 hooks: UserPromptSubmit then Stop posted with token and session headers",
              got and len(ups) == 1 and ups[0]["body"].get("prompt") == "fix 登入"
              and {k.lower(): v for k, v in ups[0]["headers"].items()}.get("x-codd-token") == token
              and {k.lower(): v for k, v in ups[0]["headers"].items()}.get("x-codd-session") == codd, [r["body"] for r in events()])
        check("m2 hooks: FAKE-HOOK lines show 204", p.wait_text("FAKE-HOOK Stop 204", 3), p.lines()[-4:])
        p.write(b"FAKE-CLEAR\r")
        got = p.wait_for(lambda q: any(l.startswith("FAKE-CLEARED session=") for l in q.lines()), 5)
        check("m2 hooks: FAKE-CLEAR posts SessionEnd and changes the session id",
              got and wait_until(lambda: len(events("SessionEnd")) == 1, 3), p.lines()[-4:])
        try:
            logged = load_json(os.path.join(logs, "fake-%d.json" % p.pid))
        except (OSError, ValueError) as e:
            logged = {"error": str(e)}
        check("m2 hooks: FAKE_LOG_DIR exact argv", logged.get("argv") == argv[1:], logged)
        os.kill(p.pid, signal.SIGTERM)
        status = p.wait_exit(5)
        check("m2 hooks: SIGTERM exit 143, registry removed", exit_code(status) == 143 and not os.path.exists(path), exit_code(status))
    finally:
        p.close()
        p.kill()
        server.shutdown()
        server.server_close()


# ------------------------------------------------------------------------------------------------
# fake-claude-m3.sh: status line runner, FAKE_REGISTRY_DIR=auto, masked env

STUB = r'''import json, os, sys
raw = sys.stdin.buffer.read()
d = json.loads(raw.decode("utf-8"))
rec = {"raw": raw.decode("utf-8"), "env": {k: os.environ.get(k) for k in ("CODD_SESSION_ID", "CODD_HOOK_URL", "CODD_HOOK_TOKEN",
       "CODD_STATUSLINE_CHAIN", "CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY")}, "cwd": os.getcwd(), "pgid": os.getpgid(0), "pid": os.getpid()}
with open(sys.argv[1], "a", encoding="utf-8") as f:
    f.write(json.dumps(rec, ensure_ascii=False) + "\n")
five = ((d.get("rate_limits") or {}).get("five_hour") or {}).get("used_percentage", "none")
sys.stdout.write("STUB session=%s five=%s \x1b[1mbold\x1b[0m\nSECOND LINE\n" % (d["session_id"], five))
sys.exit(3)
'''


def records(path):
    try:
        return [json.loads(l) for l in read_text(path).splitlines() if l.strip()]
    except (OSError, ValueError):
        return []


def cmd_fake_claude_statusline(fixtures, tmp):
    script = os.path.join(fixtures, "fake-claude-m3.sh")
    rate_limits = os.path.join(fixtures, "rate-limits.sh")
    d = os.path.join(tmp, "fsl")
    default_dir = os.path.join(d, "claude")
    logs = os.path.join(d, "log")
    rl = os.path.join(d, "rl.json")
    inputs = os.path.join(d, "sl-inputs.jsonl")
    copy = copy_fake(script, d, {"FAKE_REGISTRY_DIR": "auto", "FAKE_DEFAULT_CLAUDE_DIR": default_dir, "FAKE_LOG_DIR": logs,
                                 "FAKE_RATE_LIMITS_FILE": rl, "FAKE_STATUSLINE_INTERVAL_MS": "0",
                                 "FAKE_PRINT_ENV": "CLAUDE_CONFIG_DIR,ANTHROPIC_API_KEY,CODD_HOOK_TOKEN,CODD_STATUSLINE_CHAIN"})
    stub = os.path.join(d, "sl-stub.py")
    with open(stub, "w", encoding="utf-8") as f:
        f.write(STUB)
    sl_command = "/usr/bin/python3 -I '%s' '%s'" % (stub, inputs)
    settings = json.dumps({"hooks": {}, "statusLine": {"type": "command", "command": sl_command, "padding": 0}}, separators=(",", ":"))
    sid = "5e1f0c2a-9b8d-4c7e-a6f5-0d1c2b3a4f5e"
    chain = base64.b64encode(b"printf 'USER-SL-%s' ok").decode()
    secret_key = "sk-fake-not-a-real-key-0000"
    secret_token = "cd" * 32
    env = base_env(d)
    env.update({"CODD_SESSION_ID": "1c2d3e4f-5a6b-4c7d-8e9f-0a1b2c3d4e5f", "CODD_HOOK_URL": "http://127.0.0.1:9/hooks",
                "CODD_HOOK_TOKEN": secret_token, "CODD_STATUSLINE_CHAIN": chain, "ANTHROPIC_API_KEY": secret_key})
    cwd = os.path.join(d, "work", "整合 proj")
    os.makedirs(cwd, exist_ok=True)
    argv = [copy, "--session-id", sid, "--settings", settings, "--model", "opus", "-n", "狀態列"]
    p = Pty(argv, env, cwd)
    try:
        ready = p.wait_text("FAKE-READY", 10)
        check("status line: FAKE-READY", ready, repr(p.text()[-400:]))
        if not ready:
            return
        lines = p.lines()
        check("status line: FAKE-STATUSLINE-CONFIG names the --settings statusLine.command",
              "FAKE-STATUSLINE-CONFIG interval=0 command=%s" % sl_command in lines, [l for l in lines if "STATUSLINE" in l])
        check("FAKE-ENV CLAUDE_CONFIG_DIR=unset / ANTHROPIC_API_KEY=set / CODD_HOOK_TOKEN=set, chain value printed",
              "FAKE-ENV CLAUDE_CONFIG_DIR=unset" in lines and "FAKE-ENV ANTHROPIC_API_KEY=set" in lines
              and "FAKE-ENV CODD_HOOK_TOKEN=set" in lines and "FAKE-ENV CODD_STATUSLINE_CHAIN=%s" % chain in lines,
              [l for l in lines if l.startswith("FAKE-ENV")])
        reg = os.path.join(default_dir, "sessions", "%d.json" % p.pid)
        check("FAKE_REGISTRY_DIR=auto without CLAUDE_CONFIG_DIR: $FAKE_DEFAULT_CLAUDE_DIR/sessions/<pid>.json",
              "FAKE-REGISTRY " + reg in lines and os.path.isfile(reg), [l for l in lines if l.startswith("FAKE-REGISTRY")])
        p.settle(0.6)
        check("interval 0: no run until asked", p.count("FAKE-STATUSLINE-OUT") == 0, p.lines()[-3:])

        p.write(b"FAKE-STATUSLINE\r")
        got = p.wait_for(lambda q: q.count("FAKE-STATUSLINE-EXIT") >= 1, 10)
        lines = p.lines()
        check("typed FAKE-STATUSLINE: first stdout line (escapes shown) and the exit code",
              got and "FAKE-LINE FAKE-STATUSLINE" in lines
              and "FAKE-STATUSLINE-OUT STUB session=%s five=none ^[[1mbold^[[0m" % sid in lines
              and "FAKE-STATUSLINE-EXIT 3" in lines and submits(p) == 0, lines[-4:])
        recs = records(inputs)
        rec = recs[0] if recs else {}
        try:
            body = json.loads(rec.get("raw", "{}"))
        except ValueError:
            body = {}
        check("status line stdin: compact JSON (JSON.stringify form)",
              rec.get("raw") == json.dumps(body, ensure_ascii=False, separators=(",", ":")), rec.get("raw", "")[:200])
        real_cwd = os.path.realpath(cwd)
        check("status line stdin: session_id, transcript_path, cwd, session_name",
              body.get("session_id") == sid and body.get("cwd") == real_cwd and body.get("session_name") == "狀態列"
              and body.get("transcript_path") == os.path.join(default_dir, "projects", folder_name(real_cwd), sid + ".jsonl"), body)
        check("status line stdin: model, workspace, version, cost, context_window.used_percentage",
              body.get("model") == {"id": "opus", "display_name": "opus"}
              and body.get("workspace", {}).get("current_dir") == real_cwd and body.get("workspace", {}).get("project_dir") == real_cwd
              and body.get("version") == "2.1.300" and set(body.get("cost", {})) >= {"total_cost_usd", "total_duration_ms"}
              and body.get("context_window", {}).get("used_percentage") == 12, body)
        check("status line stdin: no rate_limits while FAKE_RATE_LIMITS_FILE is missing", "rate_limits" not in body, sorted(body))
        check("status line env: CODD_SESSION_ID, CODD_HOOK_URL, CODD_HOOK_TOKEN, CODD_STATUSLINE_CHAIN as given, no CLAUDE_CONFIG_DIR",
              rec.get("env") == {"CODD_SESSION_ID": env["CODD_SESSION_ID"], "CODD_HOOK_URL": env["CODD_HOOK_URL"],
                                 "CODD_HOOK_TOKEN": secret_token, "CODD_STATUSLINE_CHAIN": chain, "CLAUDE_CONFIG_DIR": None,
                                 "ANTHROPIC_API_KEY": secret_key} and rec.get("cwd") == real_cwd, rec.get("env"))
        check("status line runs in its own process group", rec.get("pgid") not in (None, p.pid), rec)

        steps = [(["91", "1792040340", "15", "1792296000"], {"five_hour": {"used_percentage": 91, "resets_at": 1792040340},
                                                          "seven_day": {"used_percentage": 15, "resets_at": 1792296000}}),
                 (["-", "-", "99", "1792296000"], {"seven_day": {"used_percentage": 99, "resets_at": 1792296000}}),
                 (["-", "-", "-", "-"], None)]
        for n, (args, want) in enumerate(steps, 2):
            subprocess.run([rate_limits, rl] + args, env=env, stdout=subprocess.DEVNULL, check=True)
            p.write(b"FAKE-STATUSLINE\r")
            got = p.wait_for(lambda q: q.count("FAKE-STATUSLINE-EXIT") >= n, 10)
            recs = records(inputs)
            try:
                body = json.loads(recs[-1]["raw"]) if len(recs) >= n else {}
            except ValueError:
                body = {}
            check("FAKE_RATE_LIMITS_FILE re-read per run: %s" % (" ".join(args)),
                  got and len(recs) == n and body.get("rate_limits") == want if want else got and "rate_limits" not in body,
                  body.get("rate_limits"))
            if want and "five_hour" in want:
                check("rate_limits passed byte for byte", '"rate_limits":{"five_hour":{"used_percentage":91,"resets_at":1792040340}'
                      in recs[-1]["raw"], recs[-1]["raw"][-160:])
        lines = p.lines()
        check("FAKE-STATUSLINE-OUT shows the five_hour value", "FAKE-STATUSLINE-OUT STUB session=%s five=91 ^[[1mbold^[[0m" % sid in lines,
              [l for l in lines if l.startswith("FAKE-STATUSLINE-OUT")])
        p.write(b"/login\r")
        got = p.wait_for(lambda q: "FAKE-LOGIN" in q.lines(), 5)
        p.settle(0.3)
        check("/login without FAKE_LOGIN_AS: FAKE-LOGIN only", got and not any(l.startswith("FAKE-LOGIN-") for l in p.lines())
              and submits(p) == 0, p.lines()[-3:])
        text = p.text()
        check("secrets never printed (API key, hook token)", secret_key not in text and secret_token not in text, "")
        logfile = os.path.join(logs, "fake-%d.log" % p.pid)
        log_lines = read_text(logfile).split("\n") if os.path.exists(logfile) else []
        check("FAKE_LOG_DIR log has the status line lines", log_lines.count("FAKE-STATUSLINE-EXIT 3") == 4
              and any(l.startswith("FAKE-STATUSLINE-OUT STUB") for l in log_lines), log_lines[-6:])
        p.write(b"FAKE-EXIT\r")
        status = p.wait_exit(5)
        check("status line instance: FAKE-EXIT exit 3, auto registry removed", exit_code(status) == 3 and not os.path.exists(reg),
              exit_code(status))
    finally:
        p.close()
        p.kill()

    # Pinned-like: CLAUDE_CONFIG_DIR set, periodic runs.
    prof = os.path.join(d, "prof", ".claude-swap-backup", "sessions", "2-north_example.com")
    os.makedirs(prof, exist_ok=True)
    env2 = dict(env, CLAUDE_CONFIG_DIR=prof, FAKE_STATUSLINE_INTERVAL_MS="200")
    open(inputs, "w").close()
    p = Pty([copy, "--session-id", sid, "--settings", settings], env2, cwd)
    try:
        ready = p.wait_text("FAKE-READY", 10)
        check("pinned: FAKE-READY", ready, repr(p.text()[-300:]))
        if not ready:
            return
        lines = p.lines()
        reg = os.path.join(prof, "sessions", "%d.json" % p.pid)
        check("FAKE_REGISTRY_DIR=auto with CLAUDE_CONFIG_DIR: the registry lands in the profile, shown masked",
              "FAKE-REGISTRY <CLAUDE_CONFIG_DIR>/sessions/%d.json" % p.pid in lines and os.path.isfile(reg)
              and not os.path.exists(os.path.join(default_dir, "sessions", "%d.json" % p.pid)), [l for l in lines if "REGISTRY" in l])
        check("pinned: FAKE-ENV CLAUDE_CONFIG_DIR=set, the profile path (e-mail slug) never printed",
              "FAKE-ENV CLAUDE_CONFIG_DIR=set" in lines and "north_example.com" not in p.text(), [l for l in lines if l.startswith("FAKE-ENV")])
        t0 = time.monotonic()
        got = p.wait_for(lambda q: q.count("FAKE-STATUSLINE-EXIT") >= 4, 5)
        check("FAKE_STATUSLINE_INTERVAL_MS=200: a run at FAKE-READY, then periodic", got and time.monotonic() - t0 < 3,
              p.count("FAKE-STATUSLINE-EXIT"))
        recs = records(inputs)
        try:
            body = json.loads(recs[0]["raw"])
        except (IndexError, ValueError):
            body = {}
        check("pinned: transcript_path under the profile, CLAUDE_CONFIG_DIR passed to the command",
              str(body.get("transcript_path", "")).startswith(prof + "/projects/") and recs and recs[0]["env"]["CLAUDE_CONFIG_DIR"] == prof,
              body.get("transcript_path"))
        os.kill(p.pid, signal.SIGTERM)
        status = p.wait_exit(5)
        check("pinned: SIGTERM exit 143, profile registry removed", exit_code(status) == 143 and not os.path.exists(reg), exit_code(status))
    finally:
        p.close()
        p.kill()

    # A status line that hangs: killed at FAKE_STATUSLINE_TIMEOUT_MS, and with its process group on exit.
    hang = "exec /usr/bin/perl -e 'sleep 30' '%s/sl-hang-marker'" % d
    settings3 = json.dumps({"statusLine": {"type": "command", "command": hang}})
    env3 = dict(env, FAKE_STATUSLINE_TIMEOUT_MS="500")
    p = Pty([copy, "--settings", settings3], env3, cwd)
    try:
        ready = p.wait_text("FAKE-READY", 10)
        check("hang: FAKE-READY", ready, repr(p.text()[-300:]))
        if not ready:
            return
        p.write(b"FAKE-STATUSLINE\r")
        t0 = time.monotonic()
        got = p.wait_for(lambda q: "FAKE-STATUSLINE-EXIT timeout" in q.lines(), 5)
        check("hung status line: FAKE-STATUSLINE-EXIT timeout after ~0.5 s, process killed",
              got and time.monotonic() - t0 < 3 and "FAKE-STATUSLINE-OUT" in p.lines()
              and wait_until(lambda: not pgrep(d + "/sl-hang-marker", "/usr/bin/perl"), 3),
              (p.lines()[-3:], pgrep(d + "/sl-hang-marker", "/usr/bin/perl")))
        os.kill(p.pid, signal.SIGTERM)
        p.wait_exit(5)
    finally:
        p.close()
        p.kill()
    env4 = dict(env, FAKE_STATUSLINE_TIMEOUT_MS="60000")
    p = Pty([copy, "--settings", settings3], env4, cwd)
    try:
        if p.wait_text("FAKE-READY", 10):
            p.write(b"FAKE-STATUSLINE\r")
            running = wait_until(lambda: bool(pgrep(d + "/sl-hang-marker", "/usr/bin/perl")), 5)
            os.kill(p.pid, signal.SIGTERM)
            status = p.wait_exit(5)
            check("exit during a status line run kills its process group", running and exit_code(status) == 143
                  and wait_until(lambda: not pgrep(d + "/sl-hang-marker", "/usr/bin/perl"), 3),
                  (running, exit_code(status), pgrep(d + "/sl-hang-marker", "/usr/bin/perl")))
        else:
            check("hang 2: FAKE-READY", False, repr(p.text()[-300:]))
    finally:
        p.close()
        p.kill()


# ------------------------------------------------------------------------------------------------
# fake-claude-m3.sh /login + fake cswap add / switch (dialog C at the fixture level)

def cmd_fake_claude_login(fixtures, tmp):
    script = os.path.join(fixtures, "fake-claude-m3.sh")
    d = os.path.join(tmp, "lg")
    home = os.path.join(d, "home")
    root = os.path.join(home, ".claude-swap-backup")
    env = base_env(d)
    env["HOME"] = os.path.join(d, "user")
    env["TMPDIR"] = tmp + "/"
    os.makedirs(env["HOME"], exist_ok=True)
    code, out, err, _ = run([os.path.join(fixtures, "make-cswap-state.sh"), root, os.path.join(home, ".claude")], env)
    check("login: cswap state", code == 0, (code, err))
    cj = os.path.join(home, ".claude.json")
    copy = copy_fake(script, os.path.join(d, "bin"), {"FAKE_CSWAP_ROOT": root, "FAKE_LOGIN_AS": "4", "FAKE_LOGIN_DELAY_MS": "0"})
    cwd = home

    def login_run(argv_tail, extra, typed):
        e = dict(env)
        e.update(extra)
        p = Pty([copy] + argv_tail, e, cwd)
        try:
            if not p.wait_text("FAKE-READY", 10):
                return p, False
            if typed:
                p.write(b"/login\r")
            ok = p.wait_for(lambda q: any(l.startswith(("FAKE-LOGIN-OK", "FAKE-LOGIN-REFUSED")) for l in q.lines()), 5)
            p.write(b"FAKE-EXIT\r")
            p.wait_exit(5)
            return p, ok
        finally:
            p.close()
            p.kill()

    p, ok = login_run(["/login"], {}, False)
    ident = load_json(cj).get("oauthAccount", {})
    check("argv /login with FAKE_LOGIN_AS=4: FAKE-LOGIN, FAKE-LOGIN-OK account=4",
          ok and "FAKE-LOGIN" in p.lines() and "FAKE-LOGIN-OK account=4" in p.lines(), p.lines()[-5:])
    check("login rewrote .claude.json to the built-in #4 (other keys kept, 0600)",
          ident.get("emailAddress") == EMAILS[4] and ident.get("organizationUuid") == "org-4"
          and ident.get("organizationRateLimitTier") == "default_claude_max_5x" and load_json(cj).get("projects") == {}
          and mode(cj) == 0o600, ident)
    check("login never prints an e-mail", "@example.com" not in p.text(), "")

    bindir = os.path.join(d, "bin")
    cswap = os.path.join(bindir, "cswap")
    shutil.copy(os.path.join(fixtures, "fake-cswap.py"), cswap)
    os.chmod(cswap, 0o755)
    with open(cswap + ".env", "w", encoding="utf-8") as f:
        f.write("FAKE_CSWAP_ROOT=%s\n" % root)
    code, out, err, _ = run([cswap, "add", "--slot", "4", "--alias", "studio"], env)
    seq = load_json(os.path.join(root, "sequence.json"))
    check("dialog C flow: cswap add --slot 4 --alias studio captures the new login",
          code == 0 and seq["accounts"].get("4", {}).get("email") == EMAILS[4] and seq["accounts"]["4"].get("alias") == "studio", (code, err))
    code, out, err, _ = run([cswap, "switch", "3", "--json"], env)
    check("dialog C flow: cswap switch 3 brings the global login back",
          code == 0 and json.loads(out or "{}").get("from") == {"number": 4, "email": EMAILS[4]}
          and load_json(cj)["oauthAccount"]["emailAddress"] == EMAILS[3], (code, out))

    p, ok = login_run([], {"FAKE_LOGIN_AS": "2"}, True)
    ident = load_json(cj).get("oauthAccount", {})
    check("typed /login with FAKE_LOGIN_AS=2: identity from the cswap state (#2, plan from its config backup)",
          ok and "FAKE-LINE /login" in p.lines() and "FAKE-LOGIN-OK account=2" in p.lines() and ident.get("emailAddress") == EMAILS[2]
          and ident.get("organizationUuid") == "org-2" and ident.get("organizationRateLimitTier") == "default_claude_max_20x"
          and submits(p) == 0, (p.lines()[-5:], ident))
    before = read_text(cj)
    p, ok = login_run(["/login"], {"FAKE_LOGIN_AS": "9"}, False)
    check("FAKE_LOGIN_AS=9 (no such account): FAKE-LOGIN-REFUSED unknown-account, file unchanged",
          ok and "FAKE-LOGIN-REFUSED unknown-account" in p.lines() and read_text(cj) == before, p.lines()[-4:])
    zone = os.path.join(tmp, "lgzone")
    os.makedirs(zone, exist_ok=True)
    p, ok = login_run(["/login"], {"TMPDIR": zone}, False)
    check("FAKE_CLAUDE_JSON outside $TMPDIR: FAKE-LOGIN-REFUSED claude-json-outside-tmpdir, file unchanged",
          ok and "FAKE-LOGIN-REFUSED claude-json-outside-tmpdir" in p.lines() and read_text(cj) == before, p.lines()[-4:])
    p, ok = login_run(["/login"], {"HOME": home}, False)
    check("FAKE_CLAUDE_JSON at ~/.claude.json: refused", ok and "FAKE-LOGIN-REFUSED claude-json-inside-home-claude.json" in p.lines()
          and read_text(cj) == before, p.lines()[-4:])


def cmd_compile(*paths):
    for path in paths:
        try:
            compile(read_text(path), path, "exec")
            ok, detail = True, ""
        except SyntaxError as e:
            ok, detail = False, e
        check("python compiles (%s, %s)" % (os.path.basename(path), sys.version.split()[0]), ok, detail)


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: _selftest.py <command> …")
    command, args = sys.argv[1], sys.argv[2:]
    table = {"state": cmd_state, "stale": cmd_stale, "cswap": cmd_cswap, "settings": cmd_settings, "project": cmd_project,
             "rate-limits": cmd_rate_limits, "fake-claude": cmd_fake_claude, "fake-claude-hooks": cmd_fake_claude_hooks,
             "fake-claude-statusline": cmd_fake_claude_statusline, "fake-claude-login": cmd_fake_claude_login,
             "compile": cmd_compile}
    try:
        table[command](*args)
    except Exception as e:  # noqa: BLE001 - every crash is one failed check
        import traceback
        traceback.print_exc(file=sys.stdout)
        check("%s ran to the end" % command, False, "%s: %s" % (type(e).__name__, e))
    print("CHECKS-DONE %s" % command, flush=True)


if __name__ == "__main__":
    main()
