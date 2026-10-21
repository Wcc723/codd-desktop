#!/usr/bin/python3 -I
""":" ; exec /usr/bin/python3 -I "$0" "$@" ; : <<'_M3_SHELL_END=0'
"""
# Fake `claude` for the M3 end-to-end run (docs/M3-PLAN.md C9): scripts/m2-fixtures/fake-claude-m2.sh
# with everything kept, plus Claude Code's status line runner, FAKE_REGISTRY_DIR=auto for pinned
# sessions, set/unset-only FAKE-ENV lines for secrets and CLAUDE_CONFIG_DIR, and a fake `/login`.
# Never talks to Anthropic, never uses quota. CODD starts it like the real one
# (`-codd-claude-path`): through a holder, with `--session-id` / `--resume`, the per-session
# `--settings` JSON (hooks and statusLine) and CODD_SESSION_ID / CODD_HOOK_TOKEN / CODD_HOOK_URL /
# CODD_STATUSLINE_CHAIN (and CLAUDE_CONFIG_DIR when pinned) in the environment. Python 3.9 (the
# system /usr/bin/python3, which is what the holder's default PATH finds); the kernel runs this file
# directly, so the pid is the one the holder spawned.
#
# Output contract (the e2e greps these; README.md lists them):
#   FAKE-ARGV <args joined by spaces; the --settings value shown as <settings:NB>>
#   FAKE-ENV <NAME>=<value> | FAKE-ENV-UNSET <NAME>     for each name in FAKE_PRINT_ENV (comma separated)
#   FAKE-ENV <NAME>=set|unset                           instead, for CLAUDE_CONFIG_DIR and secrets
#   FAKE-REGISTRY <path> | FAKE-REGISTRY-MISSING auto | FAKE-REGISTRY-REFUSED <reason>
#   FAKE-DA1-OK | FAKE-DA1-MISSING                      stdin is a tty: DA1 probe, 3 s
#   FAKE-CLAUDE session=<id> resume=<id|none> url=<url>
#   FAKE-SESSIONSTART hook=<cmd> status=<rc> | FAKE-SESSIONSTART-MISSING hook=<cmd>
#   FAKE-STATUSLINE-CONFIG interval=<ms> command=<cmd> | FAKE-STATUSLINE-MISSING
#   (OSC 0 title "fake claude m3", ESC[?2004h)
#   FAKE-READY
#   per input: FAKE-PASTE <text, CR as U+23CE, LF as U+21B5, TAB as U+21E5>, FAKE-LINE <typed text>,
#   FAKE-SUBMIT, FAKE-HOOK <event> <http status|000> (only when a hook URL is known), FAKE-KEY <hex>
#   typed lines: FAKE-EXIT -> FAKE-CLAUDE-EXITING, exit 3; FAKE-CLEAR -> FAKE-CLEARED session=<new id>;
#   FAKE-STATUSLINE -> one status line run; /login (also as the argv prompt) -> FAKE-LOGIN, then
#   FAKE-LOGIN-OK account=<n> | FAKE-LOGIN-REFUSED <reason> when FAKE_LOGIN_AS is set
#   every status line run: FAKE-STATUSLINE-OUT [<first stdout line>], FAKE-STATUSLINE-EXIT <code|timeout>
#   `--version` alone: prints `2.1.300 (Claude Code)` and exits 0 (Settings › 關於, D28)
#
# Settings come from the environment, else from a sidecar file `<this script's path>.env` (KEY=VALUE
# lines; FAKE_CONFIG=<file> names another one). CODD passes only an allow-list of its own environment
# to sessions (and none of FAKE_* with -codd-login-env NO), so e2e runs copy this script into their
# temp root and put the sidecar next to the copy:
#   FAKE_REGISTRY_DIR  keep <dir>/<pid>.json like a real claude (idle / busy, removed on exit);
#                      `auto` = $CLAUDE_CONFIG_DIR/sessions when set, else $FAKE_DEFAULT_CLAUDE_DIR/sessions
#   FAKE_DEFAULT_CLAUDE_DIR  the unpinned Claude directory (registry `auto`, status line transcript_path)
#   FAKE_PRINT_ENV     names to print as FAKE-ENV lines
#   FAKE_LOG_DIR       <dir>/fake-<pid>.json (exact argv, cwd, ids) and <dir>/fake-<pid>.log (every FAKE- line)
#   FAKE_STOP_DELAY_MS delay between UserPromptSubmit and Stop (default 300)
#   FAKE_STATUSLINE_INTERVAL_MS  status line period (default 1000, first run at FAKE-READY; 0 = only on demand)
#   FAKE_STATUSLINE_TIMEOUT_MS   a status line run is killed (process group) after this (default 15000)
#   FAKE_RATE_LIMITS_FILE        JSON object for the status line `rate_limits` (re-read every run)
#   FAKE_LOGIN_AS / FAKE_CLAUDE_JSON / FAKE_CSWAP_ROOT / FAKE_LOGIN_DELAY_MS   the fake `/login`
import json
import os
import re
import select
import signal
import subprocess
import sys
import termios
import threading
import time
import uuid
from http.client import HTTPConnection
from urllib.parse import urlsplit

PASTE_START = b"\x1b[200~"
PASTE_END = b"\x1b[201~"
DA1_REPLY = re.compile(rb"\x1b\[\?[0-9;]*c")
# An escape sequence not finished within this time is a key of its own (a lone ESC).
ESC_TIMEOUT = 0.1
# Printed as `set` / `unset` only: values are secrets, or (CLAUDE_CONFIG_DIR of a pinned session) a
# cswap profile path whose name carries the account's e-mail slug.
MASKED_ENV = {"CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN",
              "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR", "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR", "CODD_HOOK_TOKEN"}
# The account `FAKE_LOGIN_AS=4` logs in as when the cswap state has no #4 (make-cswap-state.sh's #4).
BUILTIN_LOGIN = {"4": {"accountUuid": "a4000000-0000-4000-8000-000000000004", "emailAddress": "new@example.com",
                       "organizationUuid": "org-4", "organizationName": "Synthetic Org 4",
                       "organizationRateLimitTier": "default_claude_max_5x", "organizationType": "claude_max"}}
FAKE_VERSION = "2.1.300"


def now_ms():
    return int(time.time() * 1000)


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


def protected(path, need_tmpdir):
    """Why `path` must not be touched, or None: inside ~ (outside $TMPDIR), ~/Library, ~/.claude,
    ~/.claude.json, ~/.claude-swap-backup; with need_tmpdir also anything outside $TMPDIR."""
    target = os.path.realpath(os.path.abspath(path))
    tmp = _tmpdir()
    for home in _homes():
        for name in ("Library", ".claude", ".claude.json", ".claude-swap-backup"):
            if _inside(target, os.path.join(home, name)):
                return "inside-home-" + name.lstrip(".")
        if _inside(target, home) and not _inside(target, tmp):
            return "inside-home"
    if need_tmpdir and not _inside(target, tmp):
        return "outside-tmpdir"
    return None


def folder_name(path):
    """Claude's projects folder name: every UTF-16 unit outside [A-Za-z0-9] becomes '-'."""
    out = []
    for ch in path:
        if ch.isascii() and ch.isalnum():
            out.append(ch)
        else:
            out.append("-" * (2 if ord(ch) > 0xFFFF else 1))
    return "".join(out)


def load_config():
    """FAKE_* settings: the sidecar file first, the environment wins."""
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
        path = None
    for key, value in os.environ.items():
        if key.startswith("FAKE_"):
            values[key] = value
    return values, path


class Output:
    """Lines to the terminal (and FAKE_LOG_DIR); one lock for the main and the hook thread."""

    def __init__(self, log_path):
        self.lock = threading.Lock()
        self.log_path = log_path

    def raw(self, data):
        with self.lock:
            self._write(data)

    def say(self, line):
        with self.lock:
            self._write((line + "\n").encode("utf-8", "replace"))
            if self.log_path:
                try:
                    with open(self.log_path, "a", encoding="utf-8") as f:
                        f.write(line + "\n")
                except OSError:
                    pass

    @staticmethod
    def _write(data):
        view = memoryview(data)
        while view:
            try:
                n = os.write(1, view)
            except InterruptedError:
                continue
            except OSError:
                return  # the terminal is gone (hangup)
            view = view[n:]


def show(text):
    """Visible form of control characters inside a line."""
    out = []
    for ch in text:
        if ch == "\r":
            out.append("⏎")
        elif ch == "\n":
            out.append("↵")
        elif ch == "\t":
            out.append("⇥")
        elif ord(ch) < 0x20 or ord(ch) == 0x7F:
            out.append("^" + chr((ord(ch) + 0x40) & 0x7F))
        else:
            out.append(ch)
    return "".join(out)


def parse_args(args):
    opts = {"settings": None, "session": None, "resume": None, "name": None, "model": None,
            "permission": None, "remote": False, "prompt": None}
    keys = {"--settings": "settings", "--session-id": "session", "--resume": "resume", "-r": "resume",
            "-n": "name", "--name": "name", "--model": "model", "--permission-mode": "permission"}
    i = 0
    while i < len(args):
        a = args[i]
        if a in keys:
            opts[keys[a]] = args[i + 1] if i + 1 < len(args) else ""
            i += 2
            continue
        if "=" in a and a.split("=", 1)[0] in keys:
            k, v = a.split("=", 1)
            opts[keys[k]] = v
        elif a == "--remote-control":
            opts["remote"] = True
        elif opts["prompt"] is None and not a.startswith("-"):
            # The positional prompt (`claude /login`). Values of unknown flags land here too; only
            # `/login` means anything to this fake.
            opts["prompt"] = a
        i += 1
    return opts


def argv_line(args):
    shown = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--settings" and i + 1 < len(args):
            shown += [a, "<settings:%dB>" % len(args[i + 1].encode("utf-8", "surrogateescape"))]
            i += 2
            continue
        if a.startswith("--settings="):
            a = "--settings=<settings:%dB>" % len(a.encode("utf-8", "surrogateescape"))
        shown.append(a)
        i += 1
    return "FAKE-ARGV " + " ".join(shown)


def load_settings(value):
    if not value:
        return {}
    text = value
    if not value.lstrip().startswith("{"):
        try:
            with open(value, "r", encoding="utf-8") as f:
                text = f.read()
        except OSError:
            return {}
    try:
        obj = json.loads(text)
    except ValueError:
        return {}
    return obj if isinstance(obj, dict) else {}


def hook_handlers(settings, event):
    groups = (settings.get("hooks") or {}).get(event) if isinstance(settings.get("hooks"), dict) else None
    out = []
    for group in groups if isinstance(groups, list) else []:
        for h in (group.get("hooks") if isinstance(group, dict) else None) or []:
            if isinstance(h, dict):
                out.append(h)
    return out


def proc_start(pid):
    """`ps -o lstart` in UTC and the C locale (what Claude Code writes), whitespace-normalized."""
    try:
        out = subprocess.run(["/bin/ps", "-o", "lstart=", "-p", str(pid)], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, env={"LC_ALL": "C", "TZ": "UTC", "PATH": "/usr/bin:/bin"},
                             timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    text = " ".join(out.decode("ascii", "replace").split())
    return text or None


class Registry:
    """<dir>/<pid>.json like a real claude: written atomically, removed on exit."""

    def __init__(self, directory, session, cwd, name, remote):
        self.lock = threading.Lock()
        self.pid = os.getpid()
        self.path = os.path.join(directory, "%d.json" % self.pid)
        self.tmp = os.path.join(directory, ".%d.json.tmp" % self.pid)
        os.makedirs(directory, mode=0o700, exist_ok=True)
        self.data = {"pid": self.pid, "sessionId": session, "cwd": cwd, "startedAt": now_ms(),
                     "procStart": proc_start(self.pid), "version": "2.1.300", "kind": "interactive",
                     "entrypoint": "cli"}
        if name:
            self.data["name"] = name
            self.data["nameSource"] = "user"
        if remote:
            self.data["bridgeSessionId"] = "cse_fake" + uuid.uuid4().hex[:20]
        self.removed = False

    def write(self, status=None, session=None):
        with self.lock:
            if self.removed:
                return
            if status is not None:
                self.data["status"] = status
                self.data["statusUpdatedAt"] = now_ms()
            if session is not None:
                self.data["sessionId"] = session
            self.data["updatedAt"] = now_ms()
            data = json.dumps(self.data, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            try:
                fd = os.open(self.tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                with os.fdopen(fd, "wb") as f:
                    f.write(data)
                os.replace(self.tmp, self.path)
            except OSError:
                pass

    def remove(self):
        with self.lock:
            self.removed = True
            for p in (self.path, self.tmp):
                try:
                    os.unlink(p)
                except OSError:
                    pass


class Hooks:
    """http hooks over loopback only, 1 s timeouts; a missing URL posts nothing and prints nothing."""

    def __init__(self, out, settings, cwd, permission):
        self.out = out
        self.cwd = cwd
        self.permission = permission or "default"
        self.url = os.environ.get("CODD_HOOK_URL") or ""
        if not self.url:
            for h in hook_handlers(settings, "UserPromptSubmit"):
                if h.get("type") == "http" and isinstance(h.get("url"), str):
                    self.url = h["url"]
                    break
        self.token = os.environ.get("CODD_HOOK_TOKEN", "")
        self.codd_session = os.environ.get("CODD_SESSION_ID", "")

    def event(self, name, session, **extra):
        body = {"hook_event_name": name, "session_id": session, "cwd": self.cwd}
        body.update(extra)
        return body

    def post(self, body):
        if not self.url:
            return None
        code = "000"
        try:
            u = urlsplit(self.url)
            if u.scheme == "http" and u.hostname in ("127.0.0.1", "localhost") and u.port:
                conn = HTTPConnection("127.0.0.1", u.port, timeout=1)
                try:
                    conn.request("POST", u.path or "/", body=json.dumps(body, ensure_ascii=False).encode("utf-8"),
                                 headers={"Content-Type": "application/json", "X-CODD-Token": self.token,
                                          "X-CODD-Session": self.codd_session})
                    code = str(conn.getresponse().status)
                finally:
                    conn.close()
        except Exception:
            code = "000"
        self.out.say("FAKE-HOOK %s %s" % (body.get("hook_event_name"), code))
        return code


class Turns(threading.Thread):
    """UserPromptSubmit, then Stop after FAKE_STOP_DELAY_MS; the registry is busy in between."""

    def __init__(self, hooks, registry, state, delay):
        super().__init__(daemon=True)
        self.hooks = hooks
        self.registry = registry
        self.state = state
        self.delay = delay
        self.cond = threading.Condition()
        self.queue = []
        self.pending = 0

    def begin(self):
        """Busy before FAKE-SUBMIT is printed, so whoever sees the line also sees the registry busy."""
        with self.cond:
            self.pending += 1
            if self.registry:
                self.registry.write(status="busy")

    def submit(self, prompt):
        with self.cond:
            self.queue.append(prompt)
            self.cond.notify()

    def run(self):
        while True:
            with self.cond:
                while not self.queue:
                    self.cond.wait()
                prompt = self.queue.pop(0)
            session = self.state["session"]
            self.hooks.post(self.hooks.event("UserPromptSubmit", session, prompt=prompt,
                                             permission_mode=self.hooks.permission))
            time.sleep(self.delay)
            self.hooks.post(self.hooks.event("Stop", session, stop_hook_active=False))
            with self.cond:
                self.pending -= 1
                if self.pending == 0 and self.registry:
                    self.registry.write(status="idle")


def run_session_start(out, settings, hooks, session, source):
    handlers = [h for h in hook_handlers(settings, "SessionStart") if h.get("type") == "command"]
    command = handlers[0].get("command") if handlers else None
    if not isinstance(command, str) or not command:
        out.say("FAKE-SESSIONSTART-MISSING hook=")
        return
    args = handlers[0].get("args")
    if isinstance(args, list):
        argv = [command] + [str(a) for a in args]
    elif os.access(command, os.X_OK):
        argv = [command, "session-start", "--url", hooks.url]
    else:
        argv = ["/bin/sh", "-c", command]
    if not os.access(argv[0], os.X_OK):
        out.say("FAKE-SESSIONSTART-MISSING hook=%s" % command)
        return
    body = json.dumps(hooks.event("SessionStart", session, source=source), ensure_ascii=False).encode("utf-8")
    try:
        rc = subprocess.run(argv, input=body, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                            timeout=5).returncode
    except (OSError, subprocess.SubprocessError):
        rc = -1
    out.say("FAKE-SESSIONSTART hook=%s status=%d" % (command, rc))


def status_line_command(settings):
    sl = settings.get("statusLine")
    if isinstance(sl, dict) and isinstance(sl.get("command"), str) and sl["command"].strip():
        return sl["command"]
    return None


def int_setting(config, name, default):
    try:
        return max(0, int(config.get(name, str(default))))
    except ValueError:
        return default


class StatusLine(threading.Thread):
    """Claude Code's status line: `/bin/sh -c <statusLine.command>` with this process's environment
    and the status line JSON on stdin, every FAKE_STATUSLINE_INTERVAL_MS and on demand. One run at a
    time (a trigger during a run starts the next one right after it), each in its own process group so
    a timeout or the exit kills the whole chain."""

    def __init__(self, out, command, config, state, opts, cwd):
        super().__init__(daemon=True)
        self.out = out
        self.command = command
        self.config = config
        self.state = state
        self.opts = opts
        self.cwd = cwd
        self.interval = int_setting(config, "FAKE_STATUSLINE_INTERVAL_MS", 1000) / 1000.0
        self.timeout = max(1, int_setting(config, "FAKE_STATUSLINE_TIMEOUT_MS", 15000)) / 1000.0
        self.started = time.monotonic()
        self.trigger = threading.Event()
        self.lock = threading.Lock()
        self.child = None
        self.stopped = False

    def request(self):
        self.trigger.set()

    def stop(self):
        with self.lock:
            self.stopped = True
            child = self.child
        self.trigger.set()
        if child is not None:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except OSError:
                pass

    def run(self):
        if self.interval > 0:
            self.run_once()
        while True:
            self.trigger.wait(self.interval if self.interval > 0 else None)
            self.trigger.clear()
            with self.lock:
                if self.stopped:
                    return
            self.run_once()

    def rate_limits(self):
        """FAKE_RATE_LIMITS_FILE, re-read every run. Like Claude Code, the key is present only when
        at least one window is known; a missing or unreadable file means none."""
        path = self.config.get("FAKE_RATE_LIMITS_FILE")
        if not path:
            return None
        try:
            with open(path, "r", encoding="utf-8") as f:
                value = json.load(f)
        except (OSError, ValueError):
            return None
        if isinstance(value, dict) and any(k in value for k in ("five_hour", "seven_day", "spend_limit")):
            return value
        return None

    def payload(self):
        session = self.state["session"]
        config_dir = (os.environ.get("CLAUDE_CONFIG_DIR") or self.config.get("FAKE_DEFAULT_CLAUDE_DIR")
                      or os.path.join(os.environ.get("HOME", "/nonexistent"), ".claude"))
        model = self.opts["model"]
        body = {"session_id": session,
                "transcript_path": os.path.join(config_dir, "projects", folder_name(self.cwd), session + ".jsonl"),
                "cwd": self.cwd}
        if self.opts["name"]:
            body["session_name"] = self.opts["name"]
        body.update({
            "model": {"id": model or "claude-fake-model", "display_name": model or "Fake Model"},
            "workspace": {"current_dir": self.cwd, "project_dir": self.cwd, "added_dirs": []},
            "version": FAKE_VERSION,
            "output_style": {"name": "default"},
            "cost": {"total_cost_usd": 0, "total_duration_ms": int((time.monotonic() - self.started) * 1000),
                     "total_api_duration_ms": 0, "total_lines_added": 0, "total_lines_removed": 0},
            "context_window": {"total_input_tokens": 24000, "total_output_tokens": 1200,
                               "context_window_size": 200000, "current_usage": None,
                               "used_percentage": 12, "remaining_percentage": 88},
            "exceeds_200k_tokens": False,
        })
        limits = self.rate_limits()
        if limits is not None:
            body["rate_limits"] = limits
        # Compact like JSON.stringify: CODD forwards `rate_limits` byte for byte.
        return json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")

    def run_once(self):
        data = self.payload()
        try:
            child = subprocess.Popen(["/bin/sh", "-c", self.command], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, cwd=self.cwd, start_new_session=True)
        except OSError:
            self.out.say("FAKE-STATUSLINE-OUT")
            self.out.say("FAKE-STATUSLINE-EXIT 127")
            return
        with self.lock:
            self.child = child
            stopped = self.stopped
        if stopped:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except OSError:
                pass
        try:
            stdout, _ = child.communicate(data, timeout=self.timeout)
            code = child.returncode
            code = str(128 - code if code < 0 else code)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except OSError:
                pass
            stdout, _ = child.communicate()
            code = "timeout"
        finally:
            with self.lock:
                self.child = None
        first = (stdout or b"").decode("utf-8", "replace").split("\n", 1)[0].rstrip("\r")
        self.out.say(("FAKE-STATUSLINE-OUT " + show(first)) if first else "FAKE-STATUSLINE-OUT")
        self.out.say("FAKE-STATUSLINE-EXIT " + code)


def login_identity(number, config):
    """oauthAccount for account `number`: from the fake cswap state when it has that slot (plan fields
    from its configs/ backup), else the built-in #4."""
    root = config.get("FAKE_CSWAP_ROOT")
    if root and protected(root, True) is None:
        try:
            with open(os.path.join(root, "sequence.json"), "r", encoding="utf-8") as f:
                seq = json.load(f)
            record = (seq.get("accounts") or {}).get(number)
        except (OSError, ValueError, AttributeError):
            record = None
        if isinstance(record, dict) and record.get("email"):
            ident = {"accountUuid": record.get("uuid") or "", "emailAddress": record["email"],
                     "organizationUuid": record.get("organizationUuid") or "",
                     "organizationName": record.get("organizationName") or "",
                     "organizationRateLimitTier": "default_claude_max_20x", "organizationType": "claude_max"}
            backup = os.path.join(root, "configs", ".claude-config-%s-%s.json" % (number, record["email"]))
            try:
                with open(backup, "r", encoding="utf-8") as f:
                    saved = (json.load(f) or {}).get("oauthAccount") or {}
                for key in ("organizationRateLimitTier", "organizationType", "accountUuid"):
                    if saved.get(key):
                        ident[key] = saved[key]
            except (OSError, ValueError, AttributeError):
                pass
            return ident
    return dict(BUILTIN_LOGIN[number]) if number in BUILTIN_LOGIN else None


def fake_login(out, config):
    """`/login`: FAKE-LOGIN; with FAKE_LOGIN_AS=<n> the fake .claude.json identity becomes account n's
    (what a browser login would do). The e-mail is never printed."""
    out.say("FAKE-LOGIN")
    number = (config.get("FAKE_LOGIN_AS") or "").strip()
    if not number:
        return
    if not number.isdigit():
        out.say("FAKE-LOGIN-REFUSED bad-account")
        return
    path = config.get("FAKE_CLAUDE_JSON")
    if not path and config.get("FAKE_CSWAP_ROOT"):
        path = os.path.join(os.path.dirname(os.path.abspath(config["FAKE_CSWAP_ROOT"])), ".claude.json")
    if not path:
        out.say("FAKE-LOGIN-REFUSED no-claude-json")
        return
    why = protected(path, True)
    if why:
        out.say("FAKE-LOGIN-REFUSED claude-json-" + why)
        return
    ident = login_identity(number, config)
    if ident is None:
        out.say("FAKE-LOGIN-REFUSED unknown-account")
        return
    time.sleep(int_setting(config, "FAKE_LOGIN_DELAY_MS", 200) / 1000.0)
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, dict):
            data = {}
    except (OSError, ValueError):
        data = {}
    data["oauthAccount"] = ident
    tmp = os.path.join(os.path.dirname(os.path.abspath(path)), ".%s.%d.tmp" % (os.path.basename(path), os.getpid()))
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(json.dumps(data, ensure_ascii=False, indent=2))
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        out.say("FAKE-LOGIN-REFUSED write-failed")
        return
    out.say("FAKE-LOGIN-OK account=%s" % number)


class Terminal:
    """Raw input (no echo, no signals, no CR/NL translation); output processing stays on."""

    def __init__(self, fd):
        self.fd = fd
        self.saved = None
        if os.isatty(fd):
            try:
                self.saved = termios.tcgetattr(fd)
            except termios.error:
                self.saved = None

    def raw(self):
        if self.saved is None:
            return
        attrs = termios.tcgetattr(self.fd)
        attrs[0] &= ~(termios.BRKINT | termios.ICRNL | termios.INLCR | termios.IGNCR | termios.INPCK
                      | termios.ISTRIP | termios.IXON)
        attrs[3] &= ~(termios.ECHO | termios.ECHONL | termios.ICANON | termios.ISIG | termios.IEXTEN)
        attrs[6][termios.VMIN] = 1
        attrs[6][termios.VTIME] = 0
        termios.tcsetattr(self.fd, termios.TCSANOW, attrs)

    def restore(self):
        if self.saved is not None:
            try:
                termios.tcsetattr(self.fd, termios.TCSANOW, self.saved)
            except termios.error:
                pass


def read_some(fd, timeout):
    ready, _, _ = select.select([fd], [], [], timeout)
    if not ready:
        return None
    try:
        return os.read(fd, 4096)
    except OSError:
        return b""


class Input:
    """Bracketed paste, typed text, CR submits; UTF-8 survives chunk boundaries."""

    def __init__(self, out, turns, on_command):
        self.out = out
        self.turns = turns
        self.on_command = on_command
        self.pending = b""
        self.in_paste = False
        self.paste = bytearray()
        self.typed = bytearray()   # typed since the last paste or submit
        self.line = bytearray()    # all typed text since the last submit (FAKE-LINE)
        self.parts = []            # prompt pieces in order
        self.had_paste = False

    def feed(self, data):
        buf = self.pending + data
        i = 0
        n = len(buf)
        while i < n:
            if self.in_paste:
                j = buf.find(PASTE_END, i)
                if j < 0:
                    keep = 0
                    for k in range(min(len(PASTE_END) - 1, n - i), 0, -1):
                        if PASTE_END.startswith(buf[n - k:]):
                            keep = k
                            break
                    self.paste += buf[i:n - keep]
                    i = n - keep
                    break
                self.paste += buf[i:j]
                i = j + len(PASTE_END)
                self.in_paste = False
                text = bytes(self.paste).decode("utf-8", "replace")
                self.paste = bytearray()
                self.out.say("FAKE-PASTE " + show(text))
                self.parts.append(text)
                self.had_paste = True
                continue
            b = buf[i]
            if b == 0x1B:
                rest = buf[i:]
                if rest.startswith(PASTE_START):
                    self._flush_typed()
                    self.in_paste = True
                    i += len(PASTE_START)
                    continue
                if len(rest) < len(PASTE_START) and PASTE_START.startswith(rest):
                    break  # maybe the start of a paste: wait for more (or the lone-ESC timeout)
                if len(rest) >= 2 and rest[1] in (0x5B, 0x4F):  # CSI / SS3 key
                    k = 2
                    if rest[1] == 0x5B:
                        while k < len(rest) and 0x30 <= rest[k] <= 0x3F:
                            k += 1
                        while k < len(rest) and 0x20 <= rest[k] <= 0x2F:
                            k += 1
                    if k >= len(rest):
                        break
                    self._key(rest[:k + 1])
                    i += k + 1
                    continue
                if len(rest) == 1:
                    break
                self._key(rest[:2])
                i += 2
                continue
            if b == 0x0D:
                self._submit()
            elif b == 0x0A:
                self.typed += b"\n"
                self.line += b"\n"
            elif b in (0x7F, 0x08):
                self._backspace()
            elif b == 0x09:
                self.typed += b"\t"
                self.line += b"\t"
            elif b == 0x03:
                self._key(b"\x03")
                self.typed = bytearray()
                self.line = bytearray()
                self.parts = []
                self.had_paste = False
            elif b < 0x20:
                self._key(bytes([b]))
            else:
                self.typed.append(b)
                self.line.append(b)
            i += 1
        self.pending = buf[i:]

    def idle(self):
        """No byte for a while: an unfinished escape is a key of its own (lone ESC)."""
        if self.pending and not self.in_paste:
            self._key(self.pending)
            self.pending = b""

    def _key(self, data):
        self.out.say("FAKE-KEY " + bytes(data).hex())

    def _backspace(self):
        for buf in (self.typed, self.line):
            while buf and (buf[-1] & 0xC0) == 0x80:
                buf.pop()
            if buf:
                buf.pop()

    def _flush_typed(self):
        if self.typed:
            self.parts.append(bytes(self.typed).decode("utf-8", "replace"))
            self.typed = bytearray()

    def _submit(self):
        self._flush_typed()
        typed = bytes(self.line).decode("utf-8", "replace")
        pasted = self.had_paste
        prompt = "".join(self.parts).replace("\r\n", "\n").replace("\r", "\n")
        self.typed = bytearray()
        self.line = bytearray()
        self.parts = []
        self.had_paste = False
        if not pasted and typed.strip() in ("FAKE-EXIT", "FAKE-CLEAR", "FAKE-STATUSLINE", "/login"):
            self.out.say("FAKE-LINE " + show(typed))
            self.on_command(typed.strip())
            return
        if typed:
            self.out.say("FAKE-LINE " + show(typed))
        if prompt:
            self.turns.begin()
        self.out.say("FAKE-SUBMIT")
        if prompt:
            self.turns.submit(prompt)


def main():
    args = sys.argv[1:]
    if args[:1] == ["--version"]:
        # Settings › 關於 runs `<claude> --version` (D28): answer like Claude Code and leave.
        sys.stdout.write("%s (Claude Code)\n" % FAKE_VERSION)
        sys.stdout.flush()
        return 0
    config, config_path = load_config()
    opts = parse_args(args)
    session = opts["resume"] or opts["session"] or str(uuid.uuid4())
    state = {"session": session}
    cwd = os.getcwd()
    pid = os.getpid()

    log_dir = config.get("FAKE_LOG_DIR")
    log_path = None
    if log_dir:
        try:
            os.makedirs(log_dir, mode=0o700, exist_ok=True)
            log_path = os.path.join(log_dir, "fake-%d.log" % pid)
            with open(os.path.join(log_dir, "fake-%d.json" % pid), "w", encoding="utf-8") as f:
                json.dump({"pid": pid, "argv": args, "cwd": cwd, "session": session, "resume": opts["resume"],
                           "config": config_path, "startedAt": now_ms()}, f, ensure_ascii=False)
        except OSError:
            log_path = None
    out = Output(log_path)
    term = Terminal(0)
    registry = None
    runner = None
    cleaned = []

    def cleanup():
        if cleaned:
            return
        cleaned.append(True)
        for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            signal.signal(sig, signal.SIG_IGN)
        if runner:
            runner.stop()
        if registry:
            registry.remove()
        if term.saved is not None:
            out.raw(b"\x1b[?2004l")
        term.restore()

    def on_signal(signum, frame):
        # The holder's hangup sends SIGHUP and SIGCONT, often next to a SIGTERM: a second signal must
        # not abort the cleanup the first one started (the registry file would stay behind).
        for other in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            signal.signal(other, signal.SIG_IGN)
        raise SystemExit(128 + signum)

    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, on_signal)

    try:
        out.say(argv_line(args))
        for name in [n.strip() for n in config.get("FAKE_PRINT_ENV", "").split(",") if n.strip()]:
            if name in MASKED_ENV:
                out.say("FAKE-ENV %s=%s" % (name, "set" if name in os.environ else "unset"))
            elif name in os.environ:
                out.say("FAKE-ENV %s=%s" % (name, os.environ[name]))
            else:
                out.say("FAKE-ENV-UNSET %s" % name)

        # Registry first, like claude at startup (CODD may see it before the holder's WELCOME).
        # `auto` follows CLAUDE_CONFIG_DIR like a real claude, so a pinned session's file lands in its
        # cswap profile; that path is printed with the variable name (its name carries an e-mail slug).
        reg_dir, reg_shown = config.get("FAKE_REGISTRY_DIR"), None
        if reg_dir == "auto":
            if os.environ.get("CLAUDE_CONFIG_DIR"):
                reg_dir, reg_shown = os.path.join(os.environ["CLAUDE_CONFIG_DIR"], "sessions"), "<CLAUDE_CONFIG_DIR>/sessions"
            elif config.get("FAKE_DEFAULT_CLAUDE_DIR"):
                reg_dir = os.path.join(config["FAKE_DEFAULT_CLAUDE_DIR"], "sessions")
            else:
                reg_dir = None
                out.say("FAKE-REGISTRY-MISSING auto")
        if reg_dir:
            why = protected(reg_dir, False)
            if why:
                out.say("FAKE-REGISTRY-REFUSED " + why)
            else:
                registry = Registry(reg_dir, session, cwd, opts["name"], opts["remote"])
                registry.write(status="idle")
                out.say("FAKE-REGISTRY " + (reg_shown + "/" + os.path.basename(registry.path) if reg_shown else registry.path))

        # Startup probe: DA1, up to 3 s; bytes that arrive with or after the reply are kept.
        leftover = b""
        if term.saved is not None:
            term.raw()
            out.raw(b"\x1b[c")
            deadline = time.monotonic() + 3.0
            buf = b""
            found = None
            while time.monotonic() < deadline:
                chunk = read_some(0, max(0.0, deadline - time.monotonic()))
                if not chunk:
                    break  # timeout, end of input or hangup
                buf += chunk
                found = DA1_REPLY.search(buf)
                if found:
                    break
            if found:
                out.say("FAKE-DA1-OK")
                leftover = buf[:found.start()] + buf[found.end():]
            else:
                out.say("FAKE-DA1-MISSING")
                leftover = buf

        settings = load_settings(opts["settings"])
        hooks = Hooks(out, settings, cwd, opts["permission"])
        out.say("FAKE-CLAUDE session=%s resume=%s url=%s" % (session, opts["resume"] or "none", hooks.url))
        run_session_start(out, settings, hooks, session, "resume" if opts["resume"] else "startup")
        sl_command = status_line_command(settings)
        if sl_command:
            runner = StatusLine(out, sl_command, config, state, opts, cwd)
            out.say("FAKE-STATUSLINE-CONFIG interval=%d command=%s" % (int(runner.interval * 1000), show(sl_command)))
        else:
            out.say("FAKE-STATUSLINE-MISSING")

        out.raw(b"\x1b]0;fake claude m3\x07")
        out.raw(b"\x1b[?2004h")
        term.raw()
        try:
            delay = max(0, int(config.get("FAKE_STOP_DELAY_MS", "300"))) / 1000.0
        except ValueError:
            delay = 0.3
        turns = Turns(hooks, registry, state, delay)
        turns.start()

        def on_command(command):
            if command == "FAKE-EXIT":
                out.say("FAKE-CLAUDE-EXITING")
                raise SystemExit(3)
            if command == "FAKE-STATUSLINE":
                if runner:
                    runner.request()
                else:
                    out.say("FAKE-STATUSLINE-MISSING")
                return
            if command == "/login":
                fake_login(out, config)
                return
            fresh = str(uuid.uuid4())
            hooks.post(hooks.event("SessionEnd", state["session"], reason="clear"))
            state["session"] = fresh
            if registry:
                registry.write(session=fresh)
            out.say("FAKE-CLEARED session=%s" % fresh)
            run_session_start(out, settings, hooks, fresh, "clear")

        parser = Input(out, turns, on_command)
        out.say("FAKE-READY")
        if runner:
            runner.start()
        if (opts["prompt"] or "").strip() == "/login":
            fake_login(out, config)
        if leftover:
            parser.feed(leftover)
        while True:
            chunk = read_some(0, ESC_TIMEOUT if parser.pending else None)
            if chunk is None:
                parser.idle()
                continue
            if chunk == b"":
                break  # end of input or the terminal hung up
            parser.feed(chunk)
        return 0
    finally:
        cleanup()


if __name__ == "__main__":
    sys.exit(main())
# The kernel runs this file with python (shebang); `bash file` re-execs python (line 2), and
# `bash -n` reads everything up to the next line as a quoted heredoc. Keep it the last line.
_M3_SHELL_END=0
