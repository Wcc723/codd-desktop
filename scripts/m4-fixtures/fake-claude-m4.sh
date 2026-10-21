#!/usr/bin/python3 -I
""":" ; exec /usr/bin/python3 -I "$0" "$@" ; : <<'_M4_SHELL_END=0'
"""
# Fake `claude` for the M4 end-to-end run (docs/M4-PLAN.md C11): scripts/m3-fixtures/fake-claude-m3.sh
# with everything kept (argv, sidecar, registry, DA1, SessionStart command hook, http hooks, status
# line runner, masked env, /login, the FAKE-* contract), plus: the variadic `--mcp-config` (logged,
# validated like Claude: a missing or invalid file aborts startup), an MCP script run through
# mcp-client.py against the session's mcp.json, UserPromptSubmit payloads from a file posted to the
# `--settings` handler (headers interpolated like Claude: only `allowedEnvVars`), PostToolUse edits,
# a stdin log, and Claude's print mode (`-p`) for CODD's condense run (D32). Never talks to
# Anthropic or any host but 127.0.0.1, never uses quota. CODD starts it like the real one
# (`-codd-claude-path`): through a holder, with `--session-id` / `--resume`, `--mcp-config
# <sessionDir>/mcp.json` right before `--settings`, and CODD_SESSION_ID / CODD_HOOK_TOKEN /
# CODD_HOOK_URL / CODD_STATUSLINE_CHAIN (and CLAUDE_CONFIG_DIR when pinned) in the environment.
# Python 3.9 (the system /usr/bin/python3); the kernel runs this file directly, so the pid is the
# one the holder spawned.
#
# Output contract, interactive (the e2e greps these; README.md lists them):
#   FAKE-ARGV <args joined by spaces; --settings shown as <settings:NB>, an empty arg as "",
#             runs of >= 32 hex digits and the CODD_HOOK_TOKEN value masked>
#   FAKE-ENV <NAME>=<value> | FAKE-ENV-UNSET <NAME>     for each name in FAKE_PRINT_ENV (comma separated)
#   FAKE-ENV <NAME>=set|unset                           instead, for CLAUDE_CONFIG_DIR and secrets
#   FAKE-MCP-CONFIG <path>                              one per --mcp-config value, in argv order
#   FAKE-MCP-SERVER name=<n> type=<t> url=<u|-> headers=<names|-> config=<index>
#   (a missing / invalid config: `Error: Invalid MCP configuration: <path>`, exit 1, like Claude)
#   FAKE-REGISTRY <path> | FAKE-REGISTRY-MISSING auto | FAKE-REGISTRY-REFUSED <reason>
#   FAKE-DA1-OK | FAKE-DA1-MISSING                      stdin is a tty: DA1 probe, 3 s
#   FAKE-CLAUDE session=<id> resume=<id|none> url=<url>
#   FAKE-SETTINGS prompt-url=<UserPromptSubmit url|-> allow=<permissions.allow, comma separated|->
#   FAKE-SESSIONSTART hook=<cmd> status=<rc> | FAKE-SESSIONSTART-MISSING hook=<cmd>
#   FAKE-STATUSLINE-CONFIG interval=<ms> command=<cmd> | FAKE-STATUSLINE-MISSING
#   (OSC 0 title "fake claude m4", ESC[?2004h)
#   FAKE-READY
#   per input: FAKE-PASTE <text, CR as U+23CE, LF as U+21B5, TAB as U+21E5>, FAKE-LINE <typed text>,
#   FAKE-SUBMIT, FAKE-HOOK <event> <http status|000> (only when a hook URL is known), FAKE-KEY <hex>,
#   FAKE-SYSTEM-MESSAGE <text> (a hook answer's systemMessage, as Claude shows it)
#   typed lines: FAKE-EXIT -> FAKE-CLAUDE-EXITING, exit 3; FAKE-CLEAR -> FAKE-CLEARED session=<new id>;
#   FAKE-STATUSLINE -> one status line run; /login (also as the argv prompt) -> FAKE-LOGIN, then
#   FAKE-LOGIN-OK account=<n> | FAKE-LOGIN-REFUSED <reason> when FAKE_LOGIN_AS is set
#   every status line run: FAKE-STATUSLINE-OUT [<first stdout line>], FAKE-STATUSLINE-EXIT <code|timeout>
#   FAKE_MCP_SCRIPT: FAKE-MCP <method> <http status | JSON-RPC error code | 000> [details], FAKE-MCP-DONE …
#   FAKE_PROMPTS: FAKE-PROMPT-HOOK <http status|000> <response bytes> per line, FAKE-PROMPTS-DONE <n>
#   FAKE_TOOL_EDITS: FAKE-TOOL-EDIT <path> <http status|000> <applied|posted-only|refused-…|no-match>,
#                    FAKE-HOOK <event> <status> for `Hook` lines, FAKE-TOOL-EDITS-DONE <n edits>
#   `--version` alone: prints `2.1.302 (Claude Code)` and exits 0 (Settings › 關於, D28)
# Print mode (`-p` / `--print`): stdout carries only the result (FAKE_P_OUTPUT or the default
# summary); the FAKE-P-* / FAKE-MCP lines go to stderr and FAKE_LOG_DIR (README.md "Print mode").
#
# Settings come from the environment, else from a sidecar file `<this script's path>.env` (KEY=VALUE
# lines; FAKE_CONFIG=<file> names another one). CODD passes only an allow-list of its own environment
# to sessions (and none of FAKE_* with -codd-login-env NO), so e2e runs copy this script (and
# mcp-client.py next to it) into their temp root and put the sidecar next to the copy:
#   FAKE_REGISTRY_DIR  keep <dir>/<pid>.json like a real claude (idle / busy, removed on exit);
#                      `auto` = $CLAUDE_CONFIG_DIR/sessions when set, else $FAKE_DEFAULT_CLAUDE_DIR/sessions
#   FAKE_DEFAULT_CLAUDE_DIR  the unpinned Claude directory (registry `auto`, status line transcript_path)
#   FAKE_PRINT_ENV     names to print as FAKE-ENV lines
#   FAKE_LOG_DIR       <dir>/fake-<pid>.json (argv, cwd, ids) and <dir>/fake-<pid>.log (every FAKE- line)
#   FAKE_STOP_DELAY_MS delay between UserPromptSubmit and Stop (default 300)
#   FAKE_STATUSLINE_INTERVAL_MS  status line period (default 1000, first run at FAKE-READY; 0 = only on demand)
#   FAKE_STATUSLINE_TIMEOUT_MS   a status line run is killed (process group) after this (default 15000)
#   FAKE_RATE_LIMITS_FILE        JSON object for the status line `rate_limits` (re-read every run)
#   FAKE_LOGIN_AS / FAKE_CLAUDE_JSON / FAKE_CSWAP_ROOT / FAKE_LOGIN_DELAY_MS   the fake `/login`
#   FAKE_MCP_SCRIPT / FAKE_MCP_LOG / FAKE_MCP_SERVER / FAKE_MCP_CLIENT / FAKE_MCP_TIMEOUT_S
#   FAKE_PROMPTS / FAKE_PROMPT_LOG / FAKE_PROMPT_DELAY_MS / FAKE_HEADER_BLANK
#   FAKE_TOOL_EDITS / FAKE_TOOL_EDIT_DELAY_MS / FAKE_EDIT_ROOT / FAKE_TOOL_EDIT_ATOMIC
#   FAKE_STDIN_LOG
#   FAKE_P_INPUT / FAKE_P_OUTPUT / FAKE_P_EXIT / FAKE_P_DELAY / FAKE_P_MCP / FAKE_P_DATE   (print mode)
import datetime
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
FAKE_VERSION = "2.1.302"
# Claude's commander options as the fake parses them (2.1.302 `--help`): variadic ones take every
# following argument that does not look like an option (`--tools ""` is one empty value).
VALUE_FLAGS = {"--settings": "settings", "--session-id": "session", "--resume": "resume", "-r": "resume",
               "-n": "name", "--name": "name", "--model": "model", "--permission-mode": "permission",
               "--output-format": "output_format", "--input-format": "input_format",
               "--permission-prompts": "permission_prompts", "--append-system-prompt": "append_system_prompt",
               "--system-prompt": "system_prompt", "--fallback-model": "fallback_model", "--max-turns": "max_turns"}
VARIADIC_FLAGS = {"--mcp-config": "mcp_configs", "--allowedTools": "allowed_tools", "--allowed-tools": "allowed_tools",
                  "--disallowedTools": "disallowed_tools", "--disallowed-tools": "disallowed_tools",
                  "--tools": "tools", "--add-dir": "add_dirs", "--betas": "betas"}
BOOL_FLAGS = {"-p": "print", "--print": "print", "--strict-mcp-config": "strict_mcp_config",
              "--no-session-persistence": "no_session_persistence", "--remote-control": "remote",
              "--verbose": "verbose", "--dangerously-skip-permissions": "skip_permissions",
              "-c": "continue", "--continue": "continue", "--debug": "debug"}
HEX_RUN = re.compile(r"[0-9a-fA-F]{32,}")
NOTE_REF = re.compile(r"codd://note/([a-z0-9]+(?:-[a-z0-9]+)*)")
ENV_REF = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)")
TOOL_LINE = re.compile(r"^\s*(Edit|Write|MultiEdit|NotebookEdit)\s+(.*)$")
SLEEP_LINE = re.compile(r"^\s*sleep\s+(\d+)\s*$")
HOOK_LINE = re.compile(r"^\s*Hook\s+([A-Za-z]+)\s*(.*)$")
# Subprocesses (mcp-client.py runs) killed at exit, so none outlives the fake.
CHILDREN = []
CHILDREN_LOCK = threading.Lock()


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
    """Lines to the terminal (and FAKE_LOG_DIR); one lock for the main and the helper threads.
    Print mode writes them to stderr (fd 2): stdout is the result CODD reads."""

    def __init__(self, log_path, fd=1):
        self.lock = threading.Lock()
        self.log_path = log_path
        self.fd = fd

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

    def _write(self, data):
        view = memoryview(data)
        while view:
            try:
                n = os.write(self.fd, view)
            except InterruptedError:
                continue
            except OSError:
                return  # the terminal is gone (hangup)
            view = view[n:]


class JsonLog:
    """Appends one JSON object per line to a FAKE_*_LOG file (shared by the helper threads)."""

    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()

    def write(self, record):
        if not self.path:
            return
        line = json.dumps(record, ensure_ascii=False) + "\n"
        with self.lock:
            try:
                with open(self.path, "a", encoding="utf-8") as f:
                    f.write(line)
            except OSError:
                pass

    def write_raw(self, text):
        if not self.path:
            return
        with self.lock:
            try:
                with open(self.path, "a", encoding="utf-8") as f:
                    f.write(text if text.endswith("\n") else text + "\n")
            except OSError:
                pass


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


def looks_like_option(a):
    """commander's test: more than one character and a leading `-` (so `""` and `-` are values)."""
    return len(a) > 1 and a[0] == "-"


def parse_args(args):
    opts = {key: None for key in VALUE_FLAGS.values()}
    opts.update({key: [] for key in VARIADIC_FLAGS.values()})
    opts.update({key: False for key in BOOL_FLAGS.values()})
    opts.update({"prompt": None, "seen": []})
    i = 0
    rest_positional = False
    while i < len(args):
        a = args[i]
        if rest_positional or not looks_like_option(a):
            if opts["prompt"] is None:
                # The positional prompt (`claude /login`). Values of unknown flags land here too.
                opts["prompt"] = a
            i += 1
            continue
        if a == "--":
            rest_positional = True
            i += 1
            continue
        name, eq, inline = a.partition("=")
        if a in VALUE_FLAGS:
            opts[VALUE_FLAGS[a]] = args[i + 1] if i + 1 < len(args) else ""
            opts["seen"].append(a)
            i += 2
            continue
        if eq and name in VALUE_FLAGS:
            opts[VALUE_FLAGS[name]] = inline
            opts["seen"].append(name)
        elif a in VARIADIC_FLAGS:
            key = VARIADIC_FLAGS[a]
            opts["seen"].append(a)
            i += 1
            while i < len(args) and not looks_like_option(args[i]):
                opts[key].append(args[i])
                i += 1
            continue
        elif eq and name in VARIADIC_FLAGS:
            opts[VARIADIC_FLAGS[name]].append(inline)
            opts["seen"].append(name)
        elif a in BOOL_FLAGS:
            opts[BOOL_FLAGS[a]] = True
            opts["seen"].append(a)
        i += 1
    return opts


def secret_values():
    """Values that must never be printed (the hook token), for argv masking."""
    token = os.environ.get("CODD_HOOK_TOKEN") or ""
    return [token] if len(token) >= 8 else []


def mask_arg(a, secrets):
    for s in secrets:
        if s in a:
            a = a.replace(s, "<token>")
    return HEX_RUN.sub(lambda m: "<hex:%d>" % len(m.group(0)), a)


def masked_argv(args):
    """argv for logs: inline JSON configs / settings summarized, tokens and long hex runs masked."""
    secrets = secret_values()
    out = []
    i = 0
    while i < len(args):
        a = args[i]
        out.append(mask_arg(a, secrets))
        i += 1
    return out


def argv_line(args, prefix="FAKE-ARGV"):
    secrets = secret_values()
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
        elif a.lstrip().startswith("{"):
            a = "<json:%dB>" % len(a.encode("utf-8", "surrogateescape"))
        shown.append('""' if a == "" else mask_arg(a, secrets))
        i += 1
    return prefix + " " + " ".join(shown)


def load_mcp_configs(paths):
    """[(path, config dict)] like Claude: a JSON string or a file; None + the reason on failure."""
    loaded = []
    for value in paths:
        text = value
        if not value.lstrip().startswith("{"):
            try:
                with open(value, "r", encoding="utf-8") as f:
                    text = f.read()
            except OSError:
                return None, value
        try:
            obj = json.loads(text)
        except ValueError:
            return None, value
        if not isinstance(obj, dict) or not isinstance(obj.get("mcpServers"), dict):
            return None, value
        loaded.append((value, obj))
    return loaded, None


def mcp_server_lines(loaded):
    lines = []
    for index, (_, obj) in enumerate(loaded):
        for name, entry in obj["mcpServers"].items():
            entry = entry if isinstance(entry, dict) else {}
            headers = entry.get("headers") if isinstance(entry.get("headers"), dict) else {}
            lines.append("FAKE-MCP-SERVER name=%s type=%s url=%s headers=%s config=%d" % (
                name, entry.get("type") or ("stdio" if entry.get("command") else "-"), entry.get("url") or "-",
                ",".join(headers.keys()) or "-", index))
    return lines


def pick_mcp_config(loaded, wanted):
    """(config path, server name) for the MCP script: FAKE_MCP_SERVER by name, else the first http
    server on a loopback url (CODD's codd / codd-desktop)."""
    for path, obj in loaded:
        for name, entry in obj["mcpServers"].items():
            if not isinstance(entry, dict):
                continue
            if wanted:
                if name == wanted:
                    return path, name
                continue
            if entry.get("type") in ("http", "streamable-http") and isinstance(entry.get("url"), str):
                if urlsplit(entry["url"]).hostname in ("127.0.0.1", "localhost"):
                    return path, name
    return None, None


def mcp_client_path(config):
    explicit = config.get("FAKE_MCP_CLIENT")
    if explicit:
        return explicit if os.path.isfile(explicit) else None
    for base in (os.path.dirname(os.path.abspath(sys.argv[0])), os.path.dirname(os.path.realpath(sys.argv[0]))):
        candidate = os.path.join(base, "mcp-client.py")
        if os.path.isfile(candidate):
            return candidate
    return None


def mcp_line(rec):
    """FAKE-MCP <method> <code> [details] for one mcp-client.py result line."""
    method = rec.get("method")
    status = rec.get("status")
    body = rec.get("body")
    code = str(status) if status else "000"
    extras = []
    if rec.get("label"):
        extras.append("label=%s" % rec["label"])
    if isinstance(body, dict) and isinstance(body.get("error"), dict):
        code = str(body["error"].get("code"))
        extras.append("http=%s" % status)
    elif isinstance(body, list):
        extras.append("batch=%d" % len(body))
    else:
        result = body.get("result") if isinstance(body, dict) else None
        if isinstance(result, dict):
            if method == "initialize":
                extras.append("protocolVersion=%s" % result.get("protocolVersion"))
            elif method == "tools/list":
                extras.append("tools=" + ",".join(str(t.get("name")) for t in result.get("tools") or [] if isinstance(t, dict)))
            elif method == "tools/call":
                content = result.get("content") if isinstance(result.get("content"), list) else []
                chars = sum(len(c.get("text") or "") for c in content if isinstance(c, dict) and c.get("type") == "text")
                images = sum(1 for c in content if isinstance(c, dict) and c.get("type") == "image")
                extras += ["tool=%s" % rec.get("tool"), "isError=%s" % ("true" if result.get("isError") else "false"),
                           "images=%d" % images, "chars=%d" % chars]
            elif method == "resources/list":
                extras.append("resources=%d" % len(result.get("resources") or []))
    if rec.get("error"):
        extras.append("error=%s" % str(rec["error"]).replace(" ", "_")[:80])
    if rec.get("secretInBody"):
        extras.append("SECRET-IN-BODY")
    return "FAKE-MCP %s %s%s" % (method, code, "".join(" " + e for e in extras))


def run_mcp_client(out, config, config_path, server, script_path=None, script_text=None):
    """Runs mcp-client.py once; every result line goes to FAKE_MCP_LOG and becomes a FAKE-MCP line."""
    client = mcp_client_path(config)
    if not client:
        out.say("FAKE-MCP-CLIENT-MISSING")
        return
    argv = ["/usr/bin/python3", "-I", client, "--config", config_path]
    if server:
        argv += ["--server", server]
    argv += ["script", script_path or "-"]
    log = JsonLog(config.get("FAKE_MCP_LOG"))
    try:
        timeout = max(1, int(config.get("FAKE_MCP_TIMEOUT_S", "60")))
    except ValueError:
        timeout = 60
    lines = 0
    try:
        child = subprocess.Popen(argv, stdin=subprocess.PIPE if script_text is not None else subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError:
        out.say("FAKE-MCP-DONE exit=127 lines=0")
        return
    with CHILDREN_LOCK:
        CHILDREN.append(child)
    try:
        stdout, stderr = child.communicate((script_text or "").encode("utf-8") if script_text is not None else None,
                                           timeout=timeout)
        rc = child.returncode
    except subprocess.TimeoutExpired:
        child.kill()
        stdout, stderr = child.communicate()
        rc = "timeout"
    finally:
        with CHILDREN_LOCK:
            if child in CHILDREN:
                CHILDREN.remove(child)
    for raw in stdout.decode("utf-8", "replace").splitlines():
        if not raw.strip():
            continue
        log.write_raw(raw)
        lines += 1
        try:
            out.say(mcp_line(json.loads(raw)))
        except ValueError:
            out.say("FAKE-MCP-BAD-LINE")
    err = stderr.decode("utf-8", "replace").strip().splitlines()
    if err and rc not in (0, "timeout"):
        out.say("FAKE-MCP-CLIENT-ERROR " + show(err[-1])[:200])
    out.say("FAKE-MCP-DONE exit=%s lines=%d" % (rc, lines))


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
                     "procStart": proc_start(self.pid), "version": FAKE_VERSION, "kind": "interactive",
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
    """http hooks over loopback only. Each event goes to its own `--settings` http handler (url,
    headers interpolated like Claude: `$VAR` / `${VAR}` only for names in `allowedEnvVars`, every
    other reference empty, FAKE_HEADER_BLANK names blanked like Claude's credential rule; timeout =
    the handler's seconds); an event without a handler falls back to CODD_HOOK_URL (or the
    UserPromptSubmit url) with X-CODD-Token / X-CODD-Session from the environment, as the M3 fake
    did. A missing URL posts nothing and prints nothing."""

    def __init__(self, out, settings, cwd, permission, config):
        self.out = out
        self.cwd = cwd
        self.permission = permission or "default"
        self.handlers = {}
        hooks = settings.get("hooks") if isinstance(settings.get("hooks"), dict) else {}
        for event in hooks:
            for h in hook_handlers(settings, event):
                if h.get("type") == "http" and isinstance(h.get("url"), str):
                    self.handlers[event] = h
                    break
        self.url = os.environ.get("CODD_HOOK_URL") or ""
        if not self.url and "UserPromptSubmit" in self.handlers:
            self.url = self.handlers["UserPromptSubmit"]["url"]
        self.token = os.environ.get("CODD_HOOK_TOKEN", "")
        self.codd_session = os.environ.get("CODD_SESSION_ID", "")
        self.blank = {n.strip() for n in (config.get("FAKE_HEADER_BLANK") or "").split(",") if n.strip()}

    def prompt_url(self):
        h = self.handlers.get("UserPromptSubmit")
        return h["url"] if h else None

    def event(self, name, session, **extra):
        body = {"hook_event_name": name, "session_id": session, "cwd": self.cwd}
        body.update(extra)
        return body

    def interpolate(self, headers, allowed):
        allowed = {a for a in (allowed or []) if isinstance(a, str)}

        def value(m):
            name = m.group(1) or m.group(2)
            if name in allowed and name not in self.blank:
                return os.environ.get(name, "")
            return ""

        return {str(k): ENV_REF.sub(value, str(v)) for k, v in (headers or {}).items()}

    def target(self, event):
        h = self.handlers.get(event)
        if h:
            try:
                timeout = max(0.2, float(h.get("timeout") or 2))
            except (TypeError, ValueError):
                timeout = 2.0
            return h["url"], self.interpolate(h.get("headers"), h.get("allowedEnvVars")), timeout
        if self.url:
            return self.url, {"X-CODD-Token": self.token, "X-CODD-Session": self.codd_session}, 1.0
        return None

    def send(self, body):
        """(status text, response bytes, ms) or None when no URL is known; never raises."""
        target = self.target(body.get("hook_event_name"))
        if target is None:
            return None
        url, headers, timeout = target
        code, data = "000", b""
        started = time.monotonic()
        try:
            u = urlsplit(url)
            if u.scheme == "http" and u.hostname in ("127.0.0.1", "localhost") and u.port:
                conn = HTTPConnection("127.0.0.1", u.port, timeout=timeout)
                try:
                    h = {"Content-Type": "application/json"}
                    h.update(headers)
                    conn.request("POST", (u.path or "/") + ("?" + u.query if u.query else ""),
                                 body=json.dumps(body, ensure_ascii=False).encode("utf-8"), headers=h)
                    resp = conn.getresponse()
                    data = resp.read(16 * 1024 * 1024)
                    code = str(resp.status)
                finally:
                    conn.close()
        except Exception:
            code = "000"
        return code, data, round((time.monotonic() - started) * 1000, 1)

    def post(self, body):
        sent = self.send(body)
        if sent is None:
            return None
        self.out.say("FAKE-HOOK %s %s" % (body.get("hook_event_name"), sent[0]))
        return sent[0]


def hook_answer(data):
    """Claude's reading of an http hook body: empty -> {}; else it must be a JSON object."""
    text = data.decode("utf-8", "replace")
    if not text.strip():
        return {}, True
    if not text.lstrip().startswith("{"):
        return None, False
    try:
        obj = json.loads(text)
    except ValueError:
        return None, False
    return (obj, True) if isinstance(obj, dict) else (None, False)


class Turns(threading.Thread):
    """UserPromptSubmit, then Stop after FAKE_STOP_DELAY_MS; the registry is busy in between.
    Prompts come from typed / pasted input (source `typed`) or FAKE_PROMPTS (source `file`); the
    UserPromptSubmit answer is logged to FAKE_PROMPT_LOG and its systemMessage printed."""

    def __init__(self, out, hooks, registry, state, delay, prompt_log):
        super().__init__(daemon=True)
        self.out = out
        self.hooks = hooks
        self.registry = registry
        self.state = state
        self.delay = delay
        self.prompt_log = prompt_log
        self.cond = threading.Condition()
        self.queue = []
        self.pending = 0

    def begin(self):
        """Busy before FAKE-SUBMIT is printed, so whoever sees the line also sees the registry busy."""
        with self.cond:
            self.pending += 1
            if self.registry:
                self.registry.write(status="busy")

    def end(self):
        """The counterpart of begin() for work outside the queue (the tool edit batch)."""
        with self.cond:
            self.pending -= 1
            if self.pending == 0 and self.registry:
                self.registry.write(status="idle")

    def submit(self, prompt, source="typed"):
        with self.cond:
            self.queue.append(("prompt", prompt, source))
            self.cond.notify()

    def marker(self, line):
        """Prints `line` once every turn queued before it has finished."""
        with self.cond:
            self.queue.append(("marker", line, None))
            self.cond.notify()

    def run(self):
        while True:
            with self.cond:
                while not self.queue:
                    self.cond.wait()
                kind, prompt, source = self.queue.pop(0)
            if kind == "marker":
                self.out.say(prompt)
                continue
            session = self.state["session"]
            body = self.hooks.event("UserPromptSubmit", session, prompt=prompt, permission_mode=self.hooks.permission)
            sent = self.hooks.send(body)
            if sent is not None:
                code, data, ms = sent
                if source == "file":
                    self.out.say("FAKE-PROMPT-HOOK %s %d" % (code, len(data)))
                else:
                    self.out.say("FAKE-HOOK UserPromptSubmit %s" % code)
                answer, valid = hook_answer(data)
                record = {"v": 1, "source": source, "prompt": prompt, "status": int(code), "bytes": len(data),
                          "ms": ms, "valid": valid, "body": answer if answer != {} or data.strip() else None}
                if not valid:
                    record["raw"] = data.decode("utf-8", "replace")[:4000]
                self.prompt_log.write(record)
                message = answer.get("systemMessage") if isinstance(answer, dict) else None
                if isinstance(message, str) and message:
                    for line in message.split("\n"):
                        self.out.say("FAKE-SYSTEM-MESSAGE " + show(line))
            time.sleep(self.delay)
            self.hooks.post(self.hooks.event("Stop", session, stop_hook_active=False))
            with self.cond:
                self.pending -= 1
                if self.pending == 0 and self.registry:
                    self.registry.write(status="idle")


def unescape(s):
    """`\\n`, `\\t`, `\\r`, `\\\\` and `\\uXXXX` in FAKE_TOOL_EDITS replacements; other text verbatim."""
    out = []
    i = 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            if n in "ntr\\":
                out.append({"n": "\n", "t": "\t", "r": "\r", "\\": "\\"}[n])
                i += 2
                continue
            if n == "u" and re.match(r"[0-9a-fA-F]{4}$", s[i + 2:i + 6] or ""):
                out.append(chr(int(s[i + 2:i + 6], 16)))
                i += 6
                continue
        out.append(c)
        i += 1
    return "".join(out)


def parse_tool_line(line):
    """('sleep', ms) | ('hook', event, extra fields) | ('edit', tool, path, old or None, new or None)
    | None for a bad line."""
    m = SLEEP_LINE.match(line)
    if m:
        return ("sleep", int(m.group(1)))
    m = HOOK_LINE.match(line)
    if m:
        extra = {}
        if m.group(2).strip():
            try:
                extra = json.loads(m.group(2))
            except ValueError:
                return None
            if not isinstance(extra, dict):
                return None
        return ("hook", m.group(1), extra)
    m = TOOL_LINE.match(line)
    if not m:
        return None
    tool, rest = m.group(1), m.group(2)
    if rest.startswith('"'):
        try:
            path, end = json.JSONDecoder().raw_decode(rest)
        except ValueError:
            return None
        remainder = rest[end:].lstrip()
    else:
        path, _, remainder = rest.partition(" ")
        remainder = remainder.lstrip()
    if not isinstance(path, str) or not path:
        return None
    if not remainder:
        return ("edit", tool, path, None, None)
    if "→" not in remainder:
        return None
    old, new = remainder.split("→", 1)
    old, new = unescape(old), unescape(new)
    if (tool == "Write") != (old == ""):
        return None  # Write takes `→<whole content>`; the others need the old text
    return ("edit", tool, path, old, new)


class ToolEdits(threading.Thread):
    """FAKE_TOOL_EDITS: after FAKE_TOOL_EDIT_DELAY_MS (counted from FAKE-READY) each line applies an
    edit (only under FAKE_EDIT_ROOT, never in a protected place) and posts PostToolUse with the
    tool_input path (PostToolUseFailure when the old text is not found); `sleep <ms>` waits;
    `Hook <Event> [<json object>]` posts that event (extra payload fields from the JSON). The batch
    counts as a turn (registry busy, shared with prompts); Stop follows a batch that edited."""

    def __init__(self, out, hooks, turns, state, config, ready_at):
        super().__init__(daemon=True)
        self.out = out
        self.hooks = hooks
        self.turns = turns
        self.state = state
        self.config = config
        self.ready_at = ready_at

    def run(self):
        path = self.config.get("FAKE_TOOL_EDITS")
        try:
            with open(path, "r", encoding="utf-8") as f:
                lines = f.read().splitlines()
        except OSError:
            self.out.say("FAKE-TOOL-EDITS-UNREADABLE")
            return
        delay = int_setting(self.config, "FAKE_TOOL_EDIT_DELAY_MS", 0) / 1000.0
        wait = self.ready_at + delay - time.monotonic()
        if wait > 0:
            time.sleep(wait)
        root = self.config.get("FAKE_EDIT_ROOT")
        root = os.path.realpath(root) if root else None
        atomic = self.config.get("FAKE_TOOL_EDIT_ATOMIC") == "1"
        self.turns.begin()
        count = 0
        for number, raw in enumerate(lines, 1):
            if not raw.strip() or raw.lstrip().startswith("#"):
                continue
            parsed = parse_tool_line(raw)
            if parsed is None:
                self.out.say("FAKE-TOOL-EDIT-BAD line=%d" % number)
                continue
            if parsed[0] == "sleep":
                time.sleep(parsed[1] / 1000.0)
                continue
            if parsed[0] == "hook":
                extra = dict(parsed[2])
                extra.setdefault("permission_mode", self.hooks.permission)
                self.hooks.post(self.hooks.event(parsed[1], self.state["session"], **extra))
                continue
            _, tool, target, old, new = parsed
            count += 1
            result = self.apply(target, old, new, root, atomic)
            self.post(tool, target, old, new, result, count)
        if count:
            # Claude ends a turn that edited files with Stop; a batch of only Hook lines leaves the
            # state to those hooks (a PermissionRequest keeps the session WAITING).
            self.hooks.post(self.hooks.event("Stop", self.state["session"], stop_hook_active=False))
        self.turns.end()
        self.out.say("FAKE-TOOL-EDITS-DONE %d" % count)

    def apply(self, target, old, new, root, atomic):
        if old is None:
            return "posted-only"
        full = os.path.abspath(os.path.join(self.hooks.cwd, target))
        real = os.path.realpath(full)
        if not root or not (real == root or real.startswith(root.rstrip("/") + "/")):
            return "refused-outside-root"
        if protected(real, False):
            return "refused-protected"
        try:
            with open(full, "rb") as f:
                text = f.read().decode("utf-8", "surrogateescape")
            exists = True
        except FileNotFoundError:
            text, exists = "", False
        except OSError:
            return "no-match"
        if old == "":
            updated = new
        elif not exists or old not in text:
            return "no-match"
        else:
            updated = text.replace(old, new, 1)
        data = updated.encode("utf-8", "surrogateescape")
        try:
            if atomic:
                tmp = os.path.join(os.path.dirname(full), ".%s.fake-edit.tmp" % os.path.basename(full))
                with open(tmp, "wb") as f:
                    f.write(data)
                if exists:
                    os.chmod(tmp, os.stat(full).st_mode & 0o7777)
                os.replace(tmp, full)
            else:
                with open(full, "wb") as f:
                    f.write(data)
        except OSError:
            return "no-match"
        return "applied"

    def post(self, tool, target, old, new, result, count):
        key = "notebook_path" if tool == "NotebookEdit" else "file_path"
        tool_input = {key: target}
        if old is not None:
            if tool == "Write":
                tool_input["content"] = new
            elif tool == "MultiEdit":
                tool_input["edits"] = [{"old_string": old, "new_string": new}]
            elif tool == "NotebookEdit":
                tool_input["new_source"] = new
            else:
                tool_input.update({"old_string": old, "new_string": new, "replace_all": False})
        session = self.state["session"]
        if result == "no-match":
            body = self.hooks.event("PostToolUseFailure", session, permission_mode=self.hooks.permission,
                                    tool_name=tool, tool_input=tool_input, tool_use_id="toolu_fake_%04d" % count,
                                    error="String to replace not found in file.")
        else:
            body = self.hooks.event("PostToolUse", session, permission_mode=self.hooks.permission, tool_name=tool,
                                    tool_input=tool_input, tool_use_id="toolu_fake_%04d" % count,
                                    tool_response={"filePath": target, "success": True})
        sent = self.hooks.send(body)
        code = sent[0] if sent is not None else "000"
        self.out.say("FAKE-TOOL-EDIT %s %s %s" % (show(target), code, result))


class Startup(threading.Thread):
    """After FAKE-READY: the MCP script (FAKE_MCP_SCRIPT through mcp-client.py), then FAKE_PROMPTS
    (after FAKE_PROMPT_DELAY_MS) through the turn queue."""

    def __init__(self, out, config, loaded_mcp, turns):
        super().__init__(daemon=True)
        self.out = out
        self.config = config
        self.loaded_mcp = loaded_mcp
        self.turns = turns

    def run(self):
        script = self.config.get("FAKE_MCP_SCRIPT")
        if script:
            path, server = pick_mcp_config(self.loaded_mcp, self.config.get("FAKE_MCP_SERVER"))
            if path is None:
                self.out.say("FAKE-MCP-NO-CONFIG")
            elif path.lstrip().startswith("{"):
                self.out.say("FAKE-MCP-SKIPPED inline-config")
            else:
                run_mcp_client(self.out, self.config, path, server, script_path=script)
        prompts = self.config.get("FAKE_PROMPTS")
        if prompts:
            try:
                with open(prompts, "r", encoding="utf-8") as f:
                    lines = [l.rstrip("\r\n") for l in f.read().split("\n")]
            except OSError:
                self.out.say("FAKE-PROMPTS-UNREADABLE")
                return
            time.sleep(int_setting(self.config, "FAKE_PROMPT_DELAY_MS", 0) / 1000.0)
            n = 0
            for line in lines:
                if not line.strip():
                    continue
                n += 1
                self.turns.begin()
                self.turns.submit(line, source="file")
            self.turns.marker("FAKE-PROMPTS-DONE %d" % n)


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
    """Bracketed paste, typed text, CR submits; UTF-8 survives chunk boundaries. Every paste, typed
    line, submit and key also goes to FAKE_STDIN_LOG as JSON (exact text)."""

    def __init__(self, out, turns, on_command, stdin_log):
        self.out = out
        self.turns = turns
        self.on_command = on_command
        self.stdin_log = stdin_log
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
                self.stdin_log.write({"at": now_ms(), "kind": "paste", "text": text})
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
        self.stdin_log.write({"at": now_ms(), "kind": "key", "hex": bytes(data).hex()})

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
            self.stdin_log.write({"at": now_ms(), "kind": "command", "text": typed.strip()})
            self.on_command(typed.strip())
            return
        if typed:
            self.out.say("FAKE-LINE " + show(typed))
            self.stdin_log.write({"at": now_ms(), "kind": "line", "text": typed})
        if prompt:
            self.turns.begin()
        self.out.say("FAKE-SUBMIT")
        self.stdin_log.write({"at": now_ms(), "kind": "submit", "prompt": prompt, "pasted": pasted})
        if prompt:
            self.turns.submit(prompt)


def kill_children():
    with CHILDREN_LOCK:
        children = list(CHILDREN)
    for child in children:
        try:
            child.kill()
        except OSError:
            pass


def env_state(name):
    return "set" if os.environ.get(name) is not None else "unset"


def summary_for(text, date_label):
    """The default condense result: `# 摘要 · M/D 清理（n 則）` and one `##` per distinct
    codd://note/<id> in the input (its title = the nearest `# ` line above the first mention)."""
    lines = text.split("\n")
    refs = []
    for m in NOTE_REF.finditer(text):
        if m.group(1) not in refs:
            refs.append(m.group(1))
    out = ["# 摘要 · %s 清理（%d 則）" % (date_label, len(refs)), ""]
    for nid in refs:
        marker = "codd://note/" + nid
        index = next((k for k, l in enumerate(lines) if marker in l), 0)
        title = None
        for k in range(index, -1, -1):
            if lines[k].startswith("# "):
                title = lines[k][2:].strip()
                break
        point = None
        for l in lines[index + 1:]:
            s = l.strip()
            if not s or s.startswith(("file:", "links:", "[image]", "annotations", "```", "<", "codd://", "#")):
                if s.startswith("# "):
                    break
                continue
            point = s.lstrip("-*0123456789. ").strip()[:60]
            break
        out += ["## %s" % (title or marker), "- 來源：%s" % marker, "- 重點：%s" % (point or "（無內容）"), ""]
    return "\n".join(out)


def print_mode(args, opts, config):
    """`claude -p …` as CODD's condense run uses it (D32): stdin is the prompt, stdout the result."""
    pid = os.getpid()
    log_dir = config.get("FAKE_LOG_DIR")
    log_path = None
    started = now_ms()
    if log_dir:
        try:
            os.makedirs(log_dir, mode=0o700, exist_ok=True)
            log_path = os.path.join(log_dir, "fake-%d.log" % pid)
        except OSError:
            log_path = None
    out = Output(log_path, fd=2)

    def on_term(signum, frame):
        # CODD's 取消 / timeout kills the run (process group): leave at once, children included.
        raise SystemExit(128 + signum)

    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, on_term)
    try:
        out.say(argv_line(args, "FAKE-P-ARGV"))
        out.say("FAKE-P-ENV CODD_HOOK_TOKEN=%s CODD_SESSION_ID=%s" % (env_state("CODD_HOOK_TOKEN"), env_state("CODD_SESSION_ID")))
        out.say("FAKE-P-ENV CLAUDE_CONFIG_DIR=%s" % env_state("CLAUDE_CONFIG_DIR"))
        out.say("FAKE-P-FLAGS model=%s output-format=%s tools=%s permission-prompts=%s strict-mcp-config=%s mcp-config=%d "
                "allowedTools=%s no-session-persistence=%s prompt=%s" % (
                    opts["model"] or "-", opts["output_format"] or "-", json.dumps(opts["tools"], ensure_ascii=False),
                    opts["permission_prompts"] or "-", "yes" if opts["strict_mcp_config"] else "no", len(opts["mcp_configs"]),
                    ",".join(opts["allowed_tools"]) or "-", "yes" if opts["no_session_persistence"] else "no",
                    "argv" if opts["prompt"] is not None else "stdin"))
        loaded, bad = load_mcp_configs(opts["mcp_configs"])
        if loaded is None:
            sys.stderr.write("Error: Invalid MCP configuration: %s\n" % bad)
            return 1
        for path, _ in loaded:
            out.say("FAKE-MCP-CONFIG " + ("<json>" if path.lstrip().startswith("{") else path))
        for line in mcp_server_lines(loaded):
            out.say(line)
        data = b"" if os.isatty(0) else sys.stdin.buffer.read()
        text = data.decode("utf-8", "replace")
        if config.get("FAKE_P_INPUT"):
            try:
                fd = os.open(config["FAKE_P_INPUT"], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                with os.fdopen(fd, "wb") as f:
                    f.write(data)
            except OSError:
                out.say("FAKE-P-INPUT-UNWRITABLE")
        refs = list(dict.fromkeys(m.group(1) for m in NOTE_REF.finditer(text)))
        out.say("FAKE-P-STDIN bytes=%d refs=%d" % (len(data), len(refs)))
        if log_dir and log_path:
            try:
                with open(os.path.join(log_dir, "fake-%d.json" % pid), "w", encoding="utf-8") as f:
                    json.dump({"pid": pid, "mode": "print", "argv": masked_argv(args), "cwd": os.getcwd(),
                               "flags": {k: opts[k] for k in ("model", "output_format", "tools", "permission_prompts",
                                                               "strict_mcp_config", "mcp_configs", "allowed_tools",
                                                               "no_session_persistence", "prompt")},
                               "env": {n: env_state(n) for n in ("CODD_HOOK_TOKEN", "CODD_SESSION_ID", "CODD_HOOK_URL",
                                                                  "CLAUDE_CONFIG_DIR")},
                               "stdinBytes": len(data), "refs": refs, "config": None, "startedAt": started},
                              f, ensure_ascii=False)
            except OSError:
                pass
        if not data.strip() and not opts["prompt"]:
            sys.stderr.write("Error: Input must be provided either through stdin or as a prompt argument when using --print\n")
            return 1
        if config.get("FAKE_P_MCP") == "1":
            path, server = pick_mcp_config(loaded, config.get("FAKE_MCP_SERVER"))
            if path is None or path.lstrip().startswith("{"):
                out.say("FAKE-MCP-NO-CONFIG")
            elif not refs:
                out.say("FAKE-P-MCP-SKIPPED no-ref")
            else:
                script = "\n".join(json.dumps(l, ensure_ascii=False) for l in [
                    {"method": "server/discover"},
                    {"method": "initialize", "params": {"protocolVersion": "2025-11-25", "capabilities": {},
                                                        "clientInfo": {"name": "claude-code", "version": FAKE_VERSION}}},
                    {"method": "notifications/initialized"},
                    {"tool": "notes_read", "arguments": {"ref": "codd://note/" + refs[0]}}]) + "\n"
                run_mcp_client(out, config, path, server, script_text=script)
        try:
            pause = max(0.0, float(config.get("FAKE_P_DELAY", "0")))
        except ValueError:
            pause = 0.0
        time.sleep(pause)
        if config.get("FAKE_P_OUTPUT"):
            try:
                with open(config["FAKE_P_OUTPUT"], "r", encoding="utf-8") as f:
                    result = f.read()
            except OSError:
                result = ""
                out.say("FAKE-P-OUTPUT-UNREADABLE")
        else:
            label = config.get("FAKE_P_DATE")
            if not label:
                today = datetime.date.today()
                label = "%d/%d" % (today.month, today.day)
            result = summary_for(text, label)
        if opts["output_format"] == "json":
            result = json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": result,
                                 "session_id": str(uuid.uuid4()), "num_turns": 1}, ensure_ascii=False) + "\n"
        sys.stdout.write(result)
        sys.stdout.flush()
        try:
            code = int(config.get("FAKE_P_EXIT", "0"))
        except ValueError:
            code = 0
        out.say("FAKE-P-OUTPUT bytes=%d" % len(result.encode("utf-8")))
        out.say("FAKE-P-EXIT %d" % code)
        return code
    finally:
        kill_children()


def main():
    args = sys.argv[1:]
    if args[:1] == ["--version"]:
        # Settings › 關於 runs `<claude> --version` (D28): answer like Claude Code and leave.
        sys.stdout.write("%s (Claude Code)\n" % FAKE_VERSION)
        sys.stdout.flush()
        return 0
    config, config_path = load_config()
    opts = parse_args(args)
    if opts["print"]:
        return print_mode(args, opts, config)
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
                json.dump({"pid": pid, "mode": "interactive", "argv": masked_argv(args), "cwd": cwd, "session": session,
                           "resume": opts["resume"], "mcpConfigs": opts["mcp_configs"], "config": config_path,
                           "startedAt": now_ms()}, f, ensure_ascii=False)
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
        kill_children()
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

        # MCP configs before anything else, like Claude: a missing or invalid one aborts startup.
        for path in opts["mcp_configs"]:
            out.say("FAKE-MCP-CONFIG " + ("<json:%dB>" % len(path.encode("utf-8")) if path.lstrip().startswith("{") else path))
        loaded_mcp, bad = load_mcp_configs(opts["mcp_configs"])
        if loaded_mcp is None:
            out.say("Error: Invalid MCP configuration: %s" % ("<json>" if bad.lstrip().startswith("{") else bad))
            return 1
        for line in mcp_server_lines(loaded_mcp):
            out.say(line)

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
        hooks = Hooks(out, settings, cwd, opts["permission"], config)
        out.say("FAKE-CLAUDE session=%s resume=%s url=%s" % (session, opts["resume"] or "none", hooks.url))
        perms = settings.get("permissions") if isinstance(settings.get("permissions"), dict) else {}
        allow = [a for a in (perms.get("allow") or []) if isinstance(a, str)]
        out.say("FAKE-SETTINGS prompt-url=%s allow=%s" % (hooks.prompt_url() or "-", ",".join(allow) or "-"))
        run_session_start(out, settings, hooks, session, "resume" if opts["resume"] else "startup")
        sl_command = status_line_command(settings)
        if sl_command:
            runner = StatusLine(out, sl_command, config, state, opts, cwd)
            out.say("FAKE-STATUSLINE-CONFIG interval=%d command=%s" % (int(runner.interval * 1000), show(sl_command)))
        else:
            out.say("FAKE-STATUSLINE-MISSING")

        out.raw(b"\x1b]0;fake claude m4\x07")
        out.raw(b"\x1b[?2004h")
        term.raw()
        try:
            delay = max(0, int(config.get("FAKE_STOP_DELAY_MS", "300"))) / 1000.0
        except ValueError:
            delay = 0.3
        turns = Turns(out, hooks, registry, state, delay, JsonLog(config.get("FAKE_PROMPT_LOG")))
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

        parser = Input(out, turns, on_command, JsonLog(config.get("FAKE_STDIN_LOG")))
        out.say("FAKE-READY")
        ready_at = time.monotonic()
        if runner:
            runner.start()
        if config.get("FAKE_MCP_SCRIPT") or config.get("FAKE_PROMPTS"):
            Startup(out, config, loaded_mcp, turns).start()
        if config.get("FAKE_TOOL_EDITS"):
            ToolEdits(out, hooks, turns, state, config, ready_at).start()
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
_M4_SHELL_END=0
