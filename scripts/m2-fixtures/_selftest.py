# Checks behind scripts/m2-fixtures/selftest.sh (run as `python3 -I _selftest.py <command> …`).
# Every check prints `CHECK ok <name>` or `CHECK FAIL <name> -- <detail>`; the last line of a command
# is `CHECKS-DONE <command>` (selftest.sh counts a missing one as a failure). Python 3.9 compatible.
import calendar
import ctypes
import json
import os
import pty
import re
import select
import shutil
import signal
import stat
import struct
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
ISO_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")
ESCAPES = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-9;?<=>]*[ -/]*[@-~]")
COLOR_TAGS = {"none", "red", "blue", "green", "yellow", "purple", "orange", "pink", "cyan"}


def check(name, ok, detail=""):
    if ok:
        print("CHECK ok %s" % name, flush=True)
    else:
        print("CHECK FAIL %s -- %s" % (name, detail), flush=True)
    return bool(ok)


def mode(path):
    return stat.S_IMODE(os.lstat(path).st_mode)


def load_json(path):
    with open(path, "rb") as f:
        return json.loads(f.read().decode("utf-8"))


_libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)


def kernel_start(pid):
    """kinfo_proc.kp_proc.p_starttime via sysctl(KERN_PROC_PID), what CODD's liveness check uses."""
    mib = (ctypes.c_int * 4)(1, 14, 1, pid)  # CTL_KERN, KERN_PROC, KERN_PROC_PID
    size = ctypes.c_size_t(0)
    if _libc.sysctl(mib, 4, None, ctypes.byref(size), None, ctypes.c_size_t(0)) != 0 or size.value == 0:
        return None
    buf = ctypes.create_string_buffer(size.value)
    if _libc.sysctl(mib, 4, buf, ctypes.byref(size), None, ctypes.c_size_t(0)) != 0 or size.value < 48:
        return None
    sec, usec = struct.unpack_from("qi", buf.raw, 0)
    (p_pid,) = struct.unpack_from("i", buf.raw, 40)
    if p_pid != pid:
        return None
    return sec + usec / 1e6


def parse_proc_start(text):
    """`Thu Oct 15 01:02:22 2026` as UTC (C-locale month and weekday names)."""
    try:
        return calendar.timegm(time.strptime(" ".join(text.split()), "%a %b %d %H:%M:%S %Y"))
    except (ValueError, AttributeError):
        return None


def ps_field(pid, field):
    out = subprocess.run(["/bin/ps", "-o", field + "=", "-p", str(pid)], stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, env={"LC_ALL": "C", "PATH": "/usr/bin:/bin"}).stdout
    return out.decode("utf-8", "replace").strip()


def alive(pid):
    s = ps_field(pid, "stat")
    return bool(s) and not s.startswith("Z")


def wait_until(fn, timeout, step=0.05):
    deadline = time.monotonic() + timeout
    while True:
        if fn():
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(step)


def folder_name(path):
    """Independent of the fixture's implementation: per code point, two dashes outside the BMP."""
    out = []
    for ch in path:
        if ("0" <= ch <= "9") or ("A" <= ch <= "Z") or ("a" <= ch <= "z"):
            out.append(ch)
        else:
            out.append("-" * (2 if ord(ch) > 0xFFFF else 1))
    return "".join(out)


def check_registry_entry(prefix, path, pid, session=None, cwd=None, status=None, name=None):
    try:
        entry = load_json(path)
    except Exception as e:  # noqa: BLE001 - reported as a failure
        check(prefix + " registry file is JSON", False, "%s: %s" % (path, e))
        return None
    check(prefix + " registry file is JSON", isinstance(entry, dict), path)
    check(prefix + " registry pid", entry.get("pid") == pid and type(entry.get("pid")) is int, entry.get("pid"))
    sid = entry.get("sessionId")
    check(prefix + " registry sessionId", isinstance(sid, str) and (sid == session if session else bool(UUID_RE.match(sid))), sid)
    if cwd is not None:
        check(prefix + " registry cwd", entry.get("cwd") == cwd, "%r != %r" % (entry.get("cwd"), cwd))
    for key in ("startedAt", "statusUpdatedAt", "updatedAt"):
        v = entry.get(key)
        check(prefix + " registry %s is epoch ms" % key, type(v) is int and v > 1.7e12, v)
    check(prefix + " registry version/kind/entrypoint",
          (entry.get("version"), entry.get("kind"), entry.get("entrypoint")) == ("2.1.300", "interactive", "cli"),
          (entry.get("version"), entry.get("kind"), entry.get("entrypoint")))
    if status is not None:
        check(prefix + " registry status %s" % status, entry.get("status") == status, entry.get("status"))
    if name is not None:
        check(prefix + " registry name", entry.get("name") == name, entry.get("name"))
    ps = entry.get("procStart")
    parsed = parse_proc_start(ps) if isinstance(ps, str) else None
    started = kernel_start(pid)
    check(prefix + " procStart parses (ps lstart layout)", parsed is not None and "  " not in ps, repr(ps))
    check(prefix + " procStart equals the process start in UTC (1.5 s)",
          parsed is not None and started is not None and abs(parsed - started) <= 1.5,
          "procStart=%r kernel=%r" % (ps, started))
    return entry


# ------------------------------------------------------------------------------------------------
# make-root.sh

def cmd_config(root, printed):
    path = os.path.join(root, "config.json")
    with open(path, "rb") as f:
        raw = f.read().decode("utf-8")
    m = re.match(r'^\{"port":(\d+),"token":"([0-9a-f]{64})","v":1\}\n$', raw)
    check("config.json has the exact m1-e2e format", m is not None, repr(raw))
    if m:
        port, token = int(m.group(1)), m.group(2)
        check("port in 43000-43999", 43000 <= port <= 43999, port)
        check("printed '<port> <token>' matches the file", printed.split() == [str(port), token], printed)
        obj = json.loads(raw)
        check("config.json parses as JSON with port/token/v", set(obj) == {"port", "token", "v"}, obj)
    check("config.json is 0600", mode(path) == 0o600, oct(mode(path)))
    check("root is 0700", mode(root) == 0o700, oct(mode(root)))


# ------------------------------------------------------------------------------------------------
# fake-external-claude.sh

def cmd_external(claude_dir, pid, sid, cwd, marker, status, name):
    pid = int(pid)
    path = os.path.join(claude_dir, "sessions", "%d.json" % pid)
    check("external registry file <pid>.json exists", os.path.isfile(path), path)
    check_registry_entry("external", path, pid, session=sid, cwd=cwd, status=status, name=name)
    entry = load_json(path)
    check("external has no waitingFor unless waiting", "waitingFor" not in entry, entry.get("waitingFor"))
    check("external sessionId is a fresh lowercase uuid", bool(UUID_RE.match(sid)), sid)
    check("external dummy runs with the marker in its argv", alive(pid) and marker in ps_field(pid, "command"),
          ps_field(pid, "command"))
    leftovers = [n for n in os.listdir(os.path.dirname(path)) if n != "%d.json" % pid]
    check("no temp files left in sessions/", not leftovers, leftovers)


def cmd_external_status(claude_dir, pid, status, waiting, before):
    pid = int(pid)
    path = os.path.join(claude_dir, "sessions", "%d.json" % pid)
    entry = load_json(path)
    check("set-status %s" % status, entry.get("status") == status, entry.get("status"))
    if waiting == "-":
        check("set-status %s drops waitingFor" % status, "waitingFor" not in entry, entry.get("waitingFor"))
    else:
        check("set-status waitingFor %r" % waiting, entry.get("waitingFor") == waiting, entry.get("waitingFor"))
    check("set-status advances statusUpdatedAt", entry.get("statusUpdatedAt", 0) > int(before),
          (entry.get("statusUpdatedAt"), before))
    check("set-status keeps updatedAt = statusUpdatedAt", entry.get("updatedAt") == entry.get("statusUpdatedAt"), entry)


# ------------------------------------------------------------------------------------------------
# pty helper

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
        """Output lines as a terminal shows them: CSI and OSC sequences removed."""
        return ESCAPES.sub("", self.text()).replace("\r\n", "\n").split("\n")

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


def base_env(tmp):
    home = os.path.join(tmp, "home")
    os.makedirs(home, exist_ok=True)
    return {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home, "TMPDIR": tmp + "/", "LANG": "en_US.UTF-8",
            "LC_CTYPE": "en_US.UTF-8", "TERM": "xterm-256color", "USER": os.environ.get("USER", "test")}


# ------------------------------------------------------------------------------------------------
# fake-external-claude.sh host (under a pty, like a CODD shell's argv)

def cmd_host(script, claude_dir, cwd, marker):
    os.makedirs(cwd, exist_ok=True)
    env = base_env(os.path.dirname(claude_dir))
    p = Pty([script, "host", claude_dir, cwd, marker], env, cwd, answer_da1=False)
    try:
        pattern = re.compile(r"(\d+) ([0-9a-f-]{36})\r?\n")
        got = p.wait_for(lambda q: pattern.search(q.text()) is not None, 10)
        check("host prints '<pid> <sessionId>'", got, repr(p.text()[-300:]))
        if not got:
            return
        m = pattern.search(p.text())
        dummy, sid = int(m.group(1)), m.group(2)
        check("host dummy runs", alive(dummy), dummy)
        check("host dummy's parent is the host process", ps_field(dummy, "ppid") == str(p.pid),
              "ppid=%s host=%d" % (ps_field(dummy, "ppid"), p.pid))
        wait_until(lambda: ps_field(p.pid, "ucomm") == "cat", 3)
        check("host process exec'd cat (same pid)", ps_field(p.pid, "ucomm") == "cat", ps_field(p.pid, "ucomm"))
        check("host process argv carries the marker", marker in ps_field(p.pid, "command"), ps_field(p.pid, "command"))
        host_file = os.path.join(claude_dir, "host-%s.txt" % os.path.basename(marker))
        try:
            with open(host_file, encoding="utf-8") as f:
                content = f.read()
        except OSError as e:
            content = str(e)
        check("host file holds the same line", content == "%d %s\n" % (dummy, sid), repr(content))
        reg = os.path.join(claude_dir, "sessions", "%d.json" % dummy)
        check_registry_entry("host", reg, dummy, session=sid, cwd=cwd, status="busy", name="external test")
        p.write(b"ping-host\n")
        check("host cat echoes input", p.wait_text("ping-host", 5, count=2), repr(p.text()[-200:]))
        p.close()  # hang up: cat and the dummy get SIGHUP
        status = p.wait_exit(5)
        check("host process ends on hangup", status is not None, status)
        check("host dummy ends with its shell", wait_until(lambda: not alive(dummy), 5), ps_field(dummy, "stat"))
        check("host dummy removed its registry file", wait_until(lambda: not os.path.exists(reg), 3), reg)
    finally:
        p.close()
        p.kill()


# ------------------------------------------------------------------------------------------------
# make-transcripts.sh

def derive_title(lines):
    custom = ai = first = None
    for rec in lines:
        t = rec.get("type")
        if t == "custom-title" and rec.get("customTitle"):
            custom = rec["customTitle"]
        elif t == "ai-title" and rec.get("aiTitle"):
            ai = rec["aiTitle"]
        elif t == "user" and first is None and not rec.get("isMeta") and not rec.get("isSidechain"):
            content = (rec.get("message") or {}).get("content")
            text = None
            if isinstance(content, str):
                text = content
            elif isinstance(content, list):
                texts = [b.get("text") for b in content if isinstance(b, dict) and b.get("type") == "text"]
                text = texts[0] if texts else None
            if text and not text.lstrip().startswith(("<command-name>", "<local-command-stdout>", "<command-message>")):
                first = text
    return custom or ai or first


def read_lines(path, name):
    out = []
    ok = True
    with open(path, "rb") as f:
        for n, raw in enumerate(f, 1):
            try:
                obj = json.loads(raw.decode("utf-8"))
                ok = ok and isinstance(obj, dict)
                out.append(obj)
            except ValueError as e:
                ok = False
                check("%s line %d is JSON" % (name, n), False, e)
    return out, ok


def cmd_transcripts(manifest_path, cwd, expected_folder, claude_dir):
    m = load_json(manifest_path)
    check("manifest cwd", m.get("cwd") == cwd, m.get("cwd"))
    check("folder name (UTF-16 units, independent check)", m.get("folder") == expected_folder == folder_name(cwd),
          "%r / %r / %r" % (m.get("folder"), expected_folder, folder_name(cwd)))
    pdir = os.path.join(claude_dir, "projects", expected_folder)
    check("transcript folder exists", os.path.isdir(pdir) and m.get("projectsDir") == pdir, pdir)
    exp = m.get("expected") or []
    titles = [e.get("title") for e in exp]
    check("expected titles newest first",
          titles == ["refresh token 流程改寫", "auth middleware 單元測試", "登入頁錯誤訊息 i18n", "CI 設定"], titles)
    check("expected branches", [e.get("branch") for e in exp] == ["fix/refresh", "main", "feat/i18n", "main"],
          [e.get("branch") for e in exp])
    check("expected ages 2/5/12/26 days", [e.get("ageDays") for e in exp] == [2, 5, 12, 26], [e.get("ageDays") for e in exp])
    check("expiry warning only for the 26-day one (4 days)", [e.get("expiresInDays") for e in exp] == [None, None, None, 4],
          [e.get("expiresInDays") for e in exp])
    check("expected sorted by mtime, newest first",
          [e["mtimeMs"] for e in exp] == sorted([e["mtimeMs"] for e in exp], reverse=True), [e.get("mtimeMs") for e in exp])
    ids = [e.get("id") for e in exp] + list(m.get("hidden") or [])
    check("ids are unique lowercase uuids", len(set(ids)) == 6 and all(UUID_RE.match(i or "") for i in ids), ids)
    now = time.time()
    all_ok = True
    for e in exp:
        path = os.path.join(pdir, e["id"] + ".jsonl")
        st = os.stat(path) if os.path.exists(path) else None
        good = (st is not None and e.get("path") == path and st.st_size == e.get("sizeBytes")
                and abs(st.st_mtime * 1000 - e.get("mtimeMs")) < 2 and int((now - st.st_mtime) // 86400) == e.get("ageDays"))
        all_ok = check("transcript %s file, size, mtime" % e.get("title"), good,
                       "%s %r" % (path, st and (st.st_size, st.st_mtime))) and all_ok
        lines, ok = read_lines(path, e.get("title"))
        check("transcript %s lines are JSON objects" % e.get("title"), ok and lines, path)
        cwds = {l.get("cwd") for l in lines if "cwd" in l}
        check("transcript %s lines carry the cwd" % e.get("title"), cwds == {cwd}, cwds)
        check("transcript %s title derived from its lines" % e.get("title"), derive_title(lines) == e.get("title"),
              derive_title(lines))
        check("transcript %s branch in its lines" % e.get("title"),
              {l.get("gitBranch") for l in lines if "gitBranch" in l} == {e.get("branch")}, e.get("branch"))
    hidden = m.get("hidden") or []
    reasons = m.get("hiddenReasons") or {}
    check("two hidden transcripts (sdk-cli, other cwd)", len(hidden) == 2 and sorted(reasons.values()) == ["other-cwd", "sdk-cli"],
          reasons)
    for hid in hidden:
        path = os.path.join(pdir, hid + ".jsonl")
        lines, ok = read_lines(path, "hidden " + hid)
        check("hidden %s lines are JSON objects" % reasons.get(hid), ok and lines and os.path.isfile(path), path)
        if reasons.get(hid) == "sdk-cli":
            check("sdk transcript has entrypoint sdk-cli",
                  {l.get("entrypoint") for l in lines if "entrypoint" in l} == {"sdk-cli"}, path)
            check("sdk transcript carries the cwd", {l.get("cwd") for l in lines if "cwd" in l} == {cwd}, path)
        else:
            other = m.get("otherCwd")
            cwds = {l.get("cwd") for l in lines if "cwd" in l}
            check("other-cwd transcript carries another cwd with the same folder name",
                  cwds == {other} and other != cwd and folder_name(other) == expected_folder, (cwds, other))
    files = sorted(n for n in os.listdir(pdir) if n.endswith(".jsonl"))
    check("folder holds exactly the six transcripts", files == sorted(i + ".jsonl" for i in ids), files)
    sib = m.get("siblingFolder") or {}
    agent = os.path.join(pdir, str(sib.get("id")), "subagents", "agent-1.jsonl")
    check("sibling folder <id>/subagents/agent-1.jsonl of the newest transcript",
          sib.get("path") == os.path.join(pdir, str(sib.get("id"))) and sib.get("id") == exp[0]["id"] and os.path.isfile(agent),
          sib)
    if os.path.isfile(agent):
        lines, ok = read_lines(agent, "subagent")
        check("subagent lines are sidechain JSON of that session",
              ok and lines and all(l.get("isSidechain") is True and l.get("sessionId") == sib.get("id") for l in lines), agent)
    first_lines, _ = read_lines(os.path.join(pdir, exp[0]["id"] + ".jsonl"), "first")
    lp = [l.get("lastPrompt") for l in first_lines if l.get("type") == "last-prompt"]
    check("last-prompt record in the custom-title transcript",
          lp == [(m.get("lastPrompt") or {}).get("text")] and (m.get("lastPrompt") or {}).get("id") == exp[0]["id"], lp)
    third, _ = read_lines(os.path.join(pdir, exp[2]["id"] + ".jsonl"), "third")
    kinds = [("meta" if l.get("isMeta") else str((l.get("message") or {}).get("content"))[:15]) for l in third[:3]]
    check("the /clear transcript starts with meta and command lines", kinds[0] == "meta" and kinds[1].startswith("<command-name>"),
          kinds)
    check("manifest is 0600 JSON", mode(manifest_path) == 0o600, oct(mode(manifest_path)))


# ------------------------------------------------------------------------------------------------
# seed-layout.sh

def cmd_layout(data_root, work_dir, manifest_path):
    path = os.path.join(data_root, "layout.json")
    raw = open(path, "rb").read().decode("utf-8")
    layout = json.loads(raw)
    check("layout.json is 0600, data root 0700", mode(path) == 0o600 and mode(data_root) == 0o700,
          (oct(mode(path)), oct(mode(data_root))))
    redump = json.dumps(layout, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : ")) + "\n"
    check("layout.json in JSONEncoder pretty + sorted keys form", raw == redump and '"version" : 1' in raw, raw[:80])
    check("layout.json version 1 with groups/projects/sessions",
          set(layout) == {"version", "groups", "projects", "sessions"} and layout["version"] == 1, sorted(layout))
    groups, projects, sessions = layout["groups"], layout["projects"], layout["sessions"]
    check("two groups with names, colors and order",
          [(g["name"], g["color"], g["order"], g["collapsed"]) for g in groups]
          == [("藍鵲 · 網站", "blue", 0, False), ("個人 · Github", "green", 1, False)], groups)
    gids = {g["id"] for g in groups}
    pids = {p["id"] for p in projects}
    all_ids = list(gids) + list(pids) + [s["id"] for s in sessions] + [s["claudeSessionId"] for s in sessions if "claudeSessionId" in s]
    check("ids are lowercase uuids", all(UUID_RE.match(i) for i in all_ids), all_ids)
    check("four projects, one ungrouped (no groupId), one collapsed",
          len(projects) == 4 and sum(1 for p in projects if "groupId" not in p) == 1
          and sum(1 for p in projects if p["collapsed"]) == 1
          and all(p.get("groupId") in gids for p in projects if "groupId" in p), projects)
    check("project folders exist (0700) under the work dir, one CJK name",
          all(os.path.isdir(p["path"]) and mode(p["path"]) == 0o700 and os.path.dirname(p["path"]) == work_dir for p in projects)
          and any(p["name"] == "整合範例" for p in projects), [p["path"] for p in projects])
    kinds = sorted(s["kind"] for s in sessions)
    check("sessions: 3 claude (1 archived), 1 shell", kinds == ["claude", "claude", "claude", "shell"], kinds)
    check("sessions reference known projects", all(s["projectId"] in pids for s in sessions), sessions)
    check("claude sessions carry a claudeSessionId, shells none",
          all(("claudeSessionId" in s) == (s["kind"] == "claude") for s in sessions), sessions)
    pinned = [s for s in sessions if s["pinned"]]
    archived = [s for s in sessions if "archivedAt" in s]
    check("exactly one pinned claude session", len(pinned) == 1 and pinned[0]["kind"] == "claude", pinned)
    check("exactly one archived claude session", len(archived) == 1 and archived[0]["kind"] == "claude", archived)
    dates = [s[k] for s in sessions for k in ("createdAt", "lastStateAt", "archivedAt", "lastViewedAt") if k in s]
    check("dates in JSDate.isoString form", all(ISO_RE.match(d) for d in dates), dates)
    check("colors are ColorTag raw values", all(s["color"] in COLOR_TAGS for s in sessions)
          and all(g["color"] in COLOR_TAGS for g in groups), [s["color"] for s in sessions])
    check("every session has order, createdAt and a title",
          all(isinstance(s["order"], int) and "createdAt" in s and (s.get("titleOverride") or s.get("title")) for s in sessions),
          sessions)
    m = load_json(manifest_path)
    check("manifest pinned / archived / collapsed ids",
          m["pinned"] == pinned[0]["id"] and m["archived"] == archived[0]["id"]
          and m["collapsedProject"] == next(p["id"] for p in projects if p["collapsed"]), m)
    check("manifest group order (未分類 last)", m["groupOrder"] == ["藍鵲 · 網站", "個人 · Github", "未分類"], m["groupOrder"])
    check("manifest visible sessions = non-archived",
          sorted(m["visibleSessions"]) == sorted(s["id"] for s in sessions if "archivedAt" not in s), m["visibleSessions"])
    check("manifest is 0600", mode(manifest_path) == 0o600, oct(mode(manifest_path)))


# ------------------------------------------------------------------------------------------------
# fake-claude-m2.sh

def submits(p):
    return sum(1 for l in p.lines() if l == "FAKE-SUBMIT")


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
        check("fake claude reaches FAKE-READY", ready, repr(p.text()[-400:]))
        if not ready:
            return
        check("FAKE-READY within 3 s (no hook URL: no waits)", time.monotonic() - started < 3, time.monotonic() - started)
        lines = p.lines()
        want_argv = "FAKE-ARGV --session-id %s --settings <settings:%dB> --model opus -n 名稱 測試 --fake-marker %s" % (
            sid, len(settings.encode()), marker)
        check("FAKE-ARGV line", want_argv in lines, [l for l in lines if l.startswith("FAKE-ARGV")])
        check("FAKE-ENV FAKE_REGISTRY_DIR / LANG / unset name",
              "FAKE-ENV FAKE_REGISTRY_DIR=%s" % reg in lines and "FAKE-ENV LANG=en_US.UTF-8" in lines
              and "FAKE-ENV-UNSET FAKE_NOT_SET_X" in lines, [l for l in lines if l.startswith("FAKE-ENV")])
        check("DA1 probe answered", "FAKE-DA1-OK" in lines, lines)
        check("no SessionStart hook in --settings", "FAKE-SESSIONSTART-MISSING hook=" in lines, lines)
        check("FAKE-CLAUDE line", "FAKE-CLAUDE session=%s resume=none url=" % sid in lines, lines)
        head = p.buf[:p.buf.find(b"FAKE-READY")]
        check("OSC 0 title and bracketed paste on before FAKE-READY",
              b"\x1b]0;fake claude m2\x07" in head and b"\x1b[?2004h" in head, repr(head[-80:]))
        path = os.path.join(reg, "%d.json" % p.pid)
        check("FAKE-REGISTRY names <dir>/<pid>.json", "FAKE-REGISTRY " + path in lines, lines)
        check_registry_entry("fake claude", path, p.pid, session=sid, cwd=os.path.realpath(cwd), status="idle",
                             name="名稱 測試")

        # Typed text, a UTF-8 character split across two writes.
        p.write(b"hello \xe4\xb8")
        time.sleep(0.05)
        p.write(b"\x96\xe7\x95\x8c\r")
        got = p.wait_for(lambda q: submits(q) >= 1, 5)
        busy = load_json(path).get("status") if os.path.exists(path) else None
        check("FAKE-LINE hello 世界 + FAKE-SUBMIT", got and "FAKE-LINE hello 世界" in p.lines(), p.lines()[-4:])
        check("registry busy right after the submit", busy == "busy", busy)
        check("registry idle again after Stop (300 ms)",
              wait_until(lambda: load_json(path).get("status") == "idle", 3), load_json(path).get("status"))

        # Bracketed paste with CR inside (the composer's line endings), then Enter.
        p.write("\x1b[200~第一行\r第二行\x1b[201~\r".encode())
        got = p.wait_for(lambda q: submits(q) >= 2, 5)
        check("FAKE-PASTE 第一行⏎第二行 + FAKE-SUBMIT", got and "FAKE-PASTE 第一行⏎第二行" in p.lines(), p.lines()[-4:])
        check("a paste alone prints no FAKE-LINE", sum(1 for l in p.lines() if l.startswith("FAKE-LINE")) == 1, p.lines()[-4:])

        # LF inside a paste, typed text after it.
        p.write("\x1b[200~甲\n乙\x1b[201~ 丙\r".encode())
        got = p.wait_for(lambda q: submits(q) >= 3, 5)
        check("FAKE-PASTE 甲↵乙 then FAKE-LINE  丙", got and "FAKE-PASTE 甲↵乙" in p.lines() and "FAKE-LINE  丙" in p.lines(),
              p.lines()[-5:])

        # Paste markers split across writes.
        p.write(b"\x1b[20")
        time.sleep(0.01)
        p.write(b"0~split\x1b[2")
        time.sleep(0.01)
        p.write(b"01~\r")
        got = p.wait_for(lambda q: submits(q) >= 4, 5)
        check("paste markers split across reads", got and "FAKE-PASTE split" in p.lines(), p.lines()[-4:])

        # A lone ESC is a key; backspace edits the typed text.
        p.write(b"\x1b")
        p.wait_text("FAKE-KEY 1b", 3)
        p.write("ab\x7fc測\x7f\r".encode())
        got = p.wait_for(lambda q: submits(q) >= 5, 5)
        check("lone ESC -> FAKE-KEY 1b, backspace edits (FAKE-LINE ac)",
              got and "FAKE-KEY 1b" in p.lines() and "FAKE-LINE ac" in p.lines(), p.lines()[-4:])

        p.write(b"FAKE-EXIT\r")
        status = p.wait_exit(5)
        lines = p.lines()
        check("FAKE-EXIT exits with status 3", exit_code(status) == 3, exit_code(status))
        check("FAKE-EXIT is echoed, not submitted", "FAKE-LINE FAKE-EXIT" in lines and "FAKE-CLAUDE-EXITING" in lines
              and submits(p) == 5, lines[-4:])
        check("bracketed paste off on exit", b"\x1b[?2004l" in p.buf, repr(p.buf[-40:]))
        check("registry file removed on exit", not os.path.exists(path), path)
        check("no stray registry files", os.listdir(reg) == [], os.listdir(reg))
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
    fc = os.path.join(tmp, "fc")
    os.makedirs(fc, exist_ok=True)
    copy = os.path.join(fc, "fake-claude")
    shutil.copy(script, copy)
    os.chmod(copy, 0o755)
    reg = os.path.join(tmp, "fcreg2")
    logs = os.path.join(tmp, "fclog")
    with open(copy + ".env", "w", encoding="utf-8") as f:
        f.write("# sidecar of the copied fake claude\nFAKE_REGISTRY_DIR=%s\nFAKE_PRINT_ENV=CODD_SESSION_ID\nFAKE_LOG_DIR=%s\n"
                % (reg, logs))
    hook_out = os.path.join(tmp, "hook-out.txt")
    hook = os.path.join(fc, "hook.sh")
    with open(hook, "w") as f:
        f.write('#!/bin/sh\n{ printf \'%%s\\n\' "$*"; cat; } > "%s"\n' % hook_out)
    os.chmod(hook, 0o755)

    server = HTTPServer(("127.0.0.1", 0), Sink)  # bound before the fork, served after it
    url = "http://127.0.0.1:%d/hooks" % server.server_address[1]
    http = {"type": "http", "url": url, "headers": {"X-CODD-Token": "$CODD_HOOK_TOKEN", "X-CODD-Session": "$CODD_SESSION_ID"},
            "allowedEnvVars": ["CODD_HOOK_TOKEN", "CODD_SESSION_ID"], "timeout": 2}
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
        check("hooks run: FAKE-READY", ready, repr(p.text()[-400:]))
        if not ready:
            return
        lines = p.lines()
        check("sidecar .env read (FAKE_PRINT_ENV)", "FAKE-ENV CODD_SESSION_ID=%s" % codd in lines, lines)
        path = os.path.join(reg, "%d.json" % p.pid)
        check("sidecar .env read (FAKE_REGISTRY_DIR)", "FAKE-REGISTRY " + path in lines and os.path.isfile(path), lines)
        check("FAKE-CLAUDE line with --resume", "FAKE-CLAUDE session=%s resume=%s url=%s" % (rid, rid, url) in lines, lines)
        check("SessionStart ran the command hook", "FAKE-SESSIONSTART hook=%s status=0" % hook in lines, lines)
        try:
            with open(hook_out, encoding="utf-8") as f:
                out = f.read().split("\n", 1)
            start_event = json.loads(out[1])
        except (OSError, ValueError, IndexError) as e:
            out, start_event = ["", ""], {"error": str(e)}
        check("SessionStart hook argv and stdin (source resume)",
              out[0] == "session-start --url %s" % url and start_event.get("hook_event_name") == "SessionStart"
              and start_event.get("source") == "resume" and start_event.get("session_id") == rid, (out[0], start_event))
        entry = load_json(path)
        check("registry: --resume id, Remote Control bridge id", entry.get("sessionId") == rid
              and str(entry.get("bridgeSessionId", "")).startswith("cse_"), entry)

        p.write("fix 登入\r".encode())
        got = wait_until(lambda: len(events("Stop")) >= 1, 5)
        ups, stops = events("UserPromptSubmit"), events("Stop")
        check("UserPromptSubmit then Stop posted", got and len(ups) == 1, [r["body"] for r in events()])
        if got and ups:
            body, headers = ups[0]["body"], {k.lower(): v for k, v in ups[0]["headers"].items()}
            check("UserPromptSubmit body (prompt, session_id, cwd)",
                  body.get("prompt") == "fix 登入" and body.get("session_id") == rid and body.get("cwd") == os.path.realpath(cwd),
                  body)
            check("hook headers: token, CODD session, JSON, Host, no Origin",
                  headers.get("x-codd-token") == token and headers.get("x-codd-session") == codd
                  and headers.get("content-type") == "application/json"
                  and headers.get("host") == "127.0.0.1:%d" % server.server_address[1] and "origin" not in headers
                  and ups[0]["path"] == "/hooks", headers)
            check("Stop about 300 ms after UserPromptSubmit", 0.25 <= stops[0]["t"] - ups[0]["t"] <= 2.0,
                  stops[0]["t"] - ups[0]["t"])
        check("FAKE-HOOK lines show 204", p.wait_text("FAKE-HOOK Stop 204", 3) and "FAKE-HOOK UserPromptSubmit 204" in p.lines(),
              p.lines()[-4:])

        p.write(b"\x1b[200~a\rb\r\nc\x1b[201~\r")
        got = wait_until(lambda: len(events("UserPromptSubmit")) >= 2, 5)
        check("pasted prompt posted with CR as LF", got and events("UserPromptSubmit")[1]["body"].get("prompt") == "a\nb\nc",
              [r["body"].get("prompt") for r in events("UserPromptSubmit")])

        p.write(b"FAKE-CLEAR\r")
        got = p.wait_for(lambda q: any(l.startswith("FAKE-CLEARED session=") for l in q.lines())
                         and q.text().count("FAKE-SESSIONSTART hook=") >= 2, 5)
        fresh = next((l.split("=", 1)[1] for l in p.lines() if l.startswith("FAKE-CLEARED session=")), "")
        wait_until(lambda: load_json(path).get("sessionId") == fresh, 2)
        check("FAKE-CLEAR: new session id in the registry, SessionEnd posted",
              got and UUID_RE.match(fresh) and load_json(path).get("sessionId") == fresh
              and wait_until(lambda: len(events("SessionEnd")) == 1, 3), (fresh, load_json(path).get("sessionId")))
        try:
            with open(hook_out, encoding="utf-8") as f:
                clear_event = json.loads(f.read().split("\n", 1)[1])
        except (OSError, ValueError, IndexError) as e:
            clear_event = {"error": str(e)}
        check("FAKE-CLEAR ran SessionStart with source clear", clear_event.get("source") == "clear"
              and clear_event.get("session_id") == fresh, clear_event)

        log_json = os.path.join(logs, "fake-%d.json" % p.pid)
        try:
            logged = load_json(log_json)
        except (OSError, ValueError) as e:
            logged = {"error": str(e)}
        check("FAKE_LOG_DIR: exact argv (full --settings) and the FAKE- lines",
              logged.get("argv") == argv[1:] and "FAKE-READY" in open(os.path.join(logs, "fake-%d.log" % p.pid),
                                                                      encoding="utf-8").read().split("\n"), logged)

        os.kill(p.pid, signal.SIGTERM)
        status = p.wait_exit(5)
        check("SIGTERM: exit 143 and the registry file removed", exit_code(status) == 143 and not os.path.exists(path),
              (exit_code(status), os.path.exists(path)))
    finally:
        p.close()
        p.kill()
        server.shutdown()
        server.server_close()


# ------------------------------------------------------------------------------------------------
# --with-app

def cmd_dump(dump_path, manifest_path, config_path, log_path):
    dump = load_json(dump_path)
    m = load_json(manifest_path)
    config = load_json(config_path)
    check("app dump: layout loaded", dump.get("loaded") is True, dump.get("loaded"))
    check("app dump: seeded groups in order", dump.get("groups") == m["groupOrder"], dump.get("groups"))
    rows = {s["id"]: s for s in dump.get("sessions") or []}
    check("app dump: exactly the non-archived sessions", sorted(rows) == sorted(m["visibleSessions"]),
          (sorted(rows), m["visibleSessions"]))
    check("app dump: archived session not listed", m["archived"] not in rows, m["archived"])
    projects = {p["id"]: p for p in m["projects"]}
    good = True
    for s in m["sessions"]:
        if s["archived"]:
            continue
        row = rows.get(s["id"]) or {}
        want_state = "stopped" if s["kind"] == "claude" else "exited"
        same = (row.get("kind") == s["kind"] and row.get("title") == s["title"] and row.get("state") == want_state
                and row.get("project") == projects[s["projectId"]]["name"] and row.get("cwd") == projects[s["projectId"]]["path"]
                and row.get("claudeSessionId") == s["claudeSessionId"])
        good = check("app dump: session %s (%s, %s)" % (s["title"], s["kind"], want_state), same, row) and good
    hooks = dump.get("hooks") or {}
    check("app dump: hook endpoint listens on the root's own port",
          hooks.get("status") == "listening" and hooks.get("port") == config["port"], (hooks, config["port"]))
    log = open(log_path, encoding="utf-8", errors="replace").read()
    check("app log: hooks listening port=%d" % config["port"], "hooks listening port=%d" % config["port"] in log, log[-400:])


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: _selftest.py <command> …")
    command, args = sys.argv[1], sys.argv[2:]
    table = {"config": cmd_config, "external": cmd_external, "external-status": cmd_external_status,
             "host": cmd_host, "transcripts": cmd_transcripts, "layout": cmd_layout, "fake-claude": cmd_fake_claude,
             "fake-claude-hooks": cmd_fake_claude_hooks, "dump": cmd_dump}
    try:
        table[command](*args)
    except Exception as e:  # noqa: BLE001 - every crash is one failed check
        import traceback
        traceback.print_exc(file=sys.stdout)
        check("%s ran to the end" % command, False, "%s: %s" % (type(e).__name__, e))
    print("CHECKS-DONE %s" % command, flush=True)


if __name__ == "__main__":
    main()
