#!/usr/bin/python3 -I
# Fake `claude` for the M2 end-to-end run (docs/M2-PLAN.md C4). Never talks to Anthropic, never uses
# quota. CODD starts it like the real one (`-codd-claude-path`): through a holder, with
# `--session-id` / `--resume`, the per-session `--settings` hooks JSON and CODD_SESSION_ID /
# CODD_HOOK_TOKEN / CODD_HOOK_URL in the environment. Python 3.9 (the system /usr/bin/python3, which
# is what the holder's default PATH finds); the kernel runs this file directly, so the pid is the one
# the holder spawned.
#
# Output contract (scripts/m2-e2e.sh greps these; README.md lists them):
#   FAKE-ARGV <args joined by spaces; the --settings value shown as <settings:NB>>
#   FAKE-ENV <NAME>=<value> | FAKE-ENV-UNSET <NAME>     for each name in FAKE_PRINT_ENV (comma separated)
#   FAKE-REGISTRY <path>                                registry mode (FAKE_REGISTRY_DIR)
#   FAKE-DA1-OK | FAKE-DA1-MISSING                      stdin is a tty: DA1 probe, 3 s
#   FAKE-CLAUDE session=<id> resume=<id|none> url=<url>
#   FAKE-SESSIONSTART hook=<cmd> status=<rc> | FAKE-SESSIONSTART-MISSING hook=<cmd>
#   (OSC 0 title "fake claude m2", ESC[?2004h)
#   FAKE-READY
#   per input: FAKE-PASTE <text, CR as U+23CE, LF as U+21B5, TAB as U+21E5>, FAKE-LINE <typed text>,
#   FAKE-SUBMIT, FAKE-HOOK <event> <http status|000> (only when a hook URL is known), FAKE-KEY <hex>
#   typed lines: FAKE-EXIT -> FAKE-CLAUDE-EXITING, exit 3; FAKE-CLEAR -> FAKE-CLEARED session=<new id>
#
# Settings come from the environment, else from a sidecar file `<this script's path>.env` (KEY=VALUE
# lines; FAKE_CONFIG=<file> names another one). CODD passes only an allow-list of its own environment
# to sessions (and none of FAKE_* with -codd-login-env NO), so e2e runs copy this script into their
# temp root and put the sidecar next to the copy:
#   FAKE_REGISTRY_DIR  keep <dir>/<pid>.json like a real claude (idle / busy, removed on exit)
#   FAKE_PRINT_ENV     names to print as FAKE-ENV lines
#   FAKE_LOG_DIR       <dir>/fake-<pid>.json (exact argv, cwd, ids) and <dir>/fake-<pid>.log (every FAKE- line)
#   FAKE_STOP_DELAY_MS delay between UserPromptSubmit and Stop (default 300)
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


def now_ms():
    return int(time.time() * 1000)


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
            "permission": None, "remote": False}
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
        if not pasted and typed.strip() in ("FAKE-EXIT", "FAKE-CLEAR"):
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
    cleaned = []

    def cleanup():
        if cleaned:
            return
        cleaned.append(True)
        for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            signal.signal(sig, signal.SIG_IGN)
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
            if name in os.environ:
                out.say("FAKE-ENV %s=%s" % (name, os.environ[name]))
            else:
                out.say("FAKE-ENV-UNSET %s" % name)

        # Registry first, like claude at startup (CODD may see it before the holder's WELCOME).
        if config.get("FAKE_REGISTRY_DIR"):
            registry = Registry(config["FAKE_REGISTRY_DIR"], session, cwd, opts["name"], opts["remote"])
            registry.write(status="idle")
            out.say("FAKE-REGISTRY " + registry.path)

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

        out.raw(b"\x1b]0;fake claude m2\x07")
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
            fresh = str(uuid.uuid4())
            hooks.post(hooks.event("SessionEnd", state["session"], reason="clear"))
            state["session"] = fresh
            if registry:
                registry.write(session=fresh)
            out.say("FAKE-CLEARED session=%s" % fresh)
            run_session_start(out, settings, hooks, fresh, "clear")

        parser = Input(out, turns, on_command)
        out.say("FAKE-READY")
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
