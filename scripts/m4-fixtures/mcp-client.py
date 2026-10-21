#!/usr/bin/python3 -I
# A tiny MCP Streamable HTTP client for the M4 fixtures (docs/M4-PLAN.md C11, §3.8-§3.10, D16).
# Loopback only (127.0.0.1 / localhost), standard library only, Python 3.9.
#
#   mcp-client.py <connection> [request options] call <method> [<params json>]
#   mcp-client.py <connection> [request options] script <jsonl file | ->
#   mcp-client.py [--note-token-from-config <config.json> <id>] get <url>
#
# connection (one of):
#   --config <mcp.json | -> [--server <name>]    the url and headers of one server of a Claude MCP
#                                                config (`-` reads the config from stdin); default
#                                                server: the first http server on a loopback url
#   --url <u> [--header K:V]...                  no config; --token-from-config <config.json> adds
#                                                CODD's external mcpToken as X-CODD-Token
# request options:
#   --token <t>       override the X-CODD-Token value     --bearer   send the token as Authorization: Bearer
#   --no-session      drop X-CODD-Session                 --origin <o>  send Origin: <o>
#   --protocol <v>    MCP-Protocol-Version before / without initialize ("" = none)
#   --init            call mode: initialize + notifications/initialized first
#   --timeout <s>     per request (default 15)
#
# Output: one JSON line per response, {"label"?, "method", "id", "tool"?, "status", "contentType", "ms",
# "body"} (status 0 + "error" when the connection fails). Image blocks become
# {"type": "image", "image": {"mimeType", "bytes", "size": [w, h]}}, resource blobs {"blob": {"bytes"}}.
# Request headers are never printed; a token value found in a response is replaced by <SECRET-LEAK>
# and the line gets "secretInBody": true (a leak stays visible without printing the secret).
# `get` prints {"method": "GET", "url" (t masked), "status", "contentType", "bytes", "body"}.
# Exit 0 (whatever the HTTP status), 1 when a connection fails, 2 on bad arguments.
#
# Script lines (JSONL; blank lines and lines starting with # are skipped):
#   {"method": "initialize", "params": {...}}            a request (id assigned 1, 2, …)
#   {"method": "notifications/initialized"}              a notification (no id) for notifications/*
#   {"tool": "notes_read", "arguments": {"ref": "x"}}    shorthand for tools/call
#   {"raw": "<body text>"}                               a raw body (parse error tests)
#   {"sleep": <ms>}                                      wait, no output
#   per line: "label", "id", "notify": true, "origin", "token", "bearer": true, "noSession": true,
#   "protocol", "headers": {...} (extra request headers)
# After an initialize answer, MCP-Protocol-Version is its protocolVersion (and an Mcp-Session-Id
# reply header is echoed), as a real client does.
import base64
import hashlib
import hmac
import json
import os
import struct
import sys
import time
from http.client import HTTPConnection
from urllib.parse import parse_qsl, urlsplit, urlunsplit

USAGE = """usage: mcp-client.py (--config <mcp.json|-> [--server <name>] | --url <u> [--header K:V]... [--token-from-config <config.json>])
                     [--token <t>] [--bearer] [--no-session] [--origin <o>] [--protocol <v>] [--init] [--timeout <s>]
                     (call <method> [<params json>] | script <jsonl|->)
       mcp-client.py [--note-token-from-config <config.json> <id>] [--timeout <s>] get <url>"""
LATEST = "2025-11-25"
TOKEN_HEADERS = ("x-codd-token", "authorization")


def die(message, code=2):
    print("mcp-client: " + message, file=sys.stderr)
    if code == 2:
        print(USAGE, file=sys.stderr)
    sys.exit(code)


def loopback(url):
    u = urlsplit(url)
    if u.scheme != "http" or u.hostname not in ("127.0.0.1", "localhost") or not u.port:
        die("only http://127.0.0.1:<port> or http://localhost:<port> urls are allowed (%s)" % mask_url(url))
    return u


def mask_url(url):
    """The url with its `t` (note URL token) shown as ••••, like CODD's COPY REF display."""
    try:
        u = urlsplit(url)
        q = "&".join("%s=%s" % (k, "••••" if k == "t" else v) for k, v in parse_qsl(u.query, keep_blank_values=True))
        return urlunsplit((u.scheme, u.netloc, u.path, q, u.fragment))
    except ValueError:
        return "<url>"


def read_json_file(path, what):
    try:
        if path == "-":
            return json.loads(sys.stdin.read())
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        die("cannot read %s %s (%s)" % (what, path, type(e).__name__), 1)


def mcp_token_from(path):
    obj = read_json_file(path, "CODD config")
    token = obj.get("mcpToken") if isinstance(obj, dict) else None
    if not isinstance(token, str) or not token:
        die("%s has no mcpToken" % path, 1)
    return token


def image_size(data):
    """(w, h) for PNG, GIF, JPEG and WebP (VP8 / VP8L / VP8X) bytes, else None."""
    try:
        if data[:8] == b"\x89PNG\r\n\x1a\n":
            return list(struct.unpack(">II", data[16:24]))
        if data[:6] in (b"GIF87a", b"GIF89a"):
            return list(struct.unpack("<HH", data[6:10]))
        if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
            kind = data[12:16]
            if kind == b"VP8X":
                return [1 + int.from_bytes(data[24:27], "little"), 1 + int.from_bytes(data[27:30], "little")]
            if kind == b"VP8L":
                b = int.from_bytes(data[21:25], "little")
                return [(b & 0x3FFF) + 1, ((b >> 14) & 0x3FFF) + 1]
            if kind == b"VP8 ":
                w, h = struct.unpack("<HH", data[26:30])
                return [w & 0x3FFF, h & 0x3FFF]
        if data[:2] == b"\xff\xd8":
            i = 2
            while i + 9 < len(data):
                if data[i] != 0xFF:
                    i += 1
                    continue
                marker = data[i + 1]
                if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                    h, w = struct.unpack(">HH", data[i + 5:i + 9])
                    return [w, h]
                if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
                    i += 2
                    continue
                i += 2 + struct.unpack(">H", data[i + 2:i + 4])[0]
    except (struct.error, IndexError):
        return None
    return None


class Summarizer:
    """Replaces image data by a summary and secrets by a marker, recording whether one was found."""

    def __init__(self, secrets):
        self.secrets = [s for s in secrets if isinstance(s, str) and len(s) >= 8]
        self.leak = False

    def text(self, s):
        for secret in self.secrets:
            if secret in s:
                s = s.replace(secret, "<SECRET-LEAK>")
                self.leak = True
        return s

    def walk(self, v):
        if isinstance(v, dict):
            if v.get("type") == "image" and isinstance(v.get("data"), str):
                try:
                    raw = base64.b64decode(v["data"], validate=False)
                except (ValueError, TypeError):
                    raw = b""
                out = {k: self.walk(x) for k, x in v.items() if k != "data"}
                out["image"] = {"mimeType": v.get("mimeType"), "bytes": len(raw), "size": image_size(raw)}
                return out
            if isinstance(v.get("blob"), str):
                out = {k: self.walk(x) for k, x in v.items() if k != "blob"}
                try:
                    out["blob"] = {"bytes": len(base64.b64decode(v["blob"]))}
                except (ValueError, TypeError):
                    out["blob"] = {"bytes": None}
                return out
            return {self.text(k): self.walk(x) for k, x in v.items()}
        if isinstance(v, list):
            return [self.walk(x) for x in v]
        if isinstance(v, str):
            return self.text(v)
        return v


def emit(record, summarizer):
    if summarizer.leak:
        record["secretInBody"] = True
    sys.stdout.write(json.dumps(record, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def http(method, url, headers, body, timeout):
    """(status, headers dict lowercased, bytes) or raises OSError. Connects to 127.0.0.1 only and
    sends the url's own host:port as Host (so `localhost` URLs keep their Host header)."""
    u = loopback(url)
    conn = HTTPConnection("127.0.0.1", u.port, timeout=timeout)
    try:
        path = u.path or "/"
        if u.query:
            path += "?" + u.query
        conn.putrequest(method, path, skip_host=True, skip_accept_encoding=True)
        conn.putheader("Host", u.netloc)
        for k, v in headers.items():
            conn.putheader(k, v)
        if body is not None:
            conn.putheader("Content-Length", str(len(body)))
        conn.endheaders(body)
        resp = conn.getresponse()
        data = resp.read()
        return resp.status, {k.lower(): v for k, v in resp.getheaders()}, data
    finally:
        conn.close()


def decode_body(content_type, data):
    if not data:
        return None
    text = data.decode("utf-8", "replace")
    if content_type and "text/event-stream" in content_type:
        last = None
        for line in text.splitlines():
            if line.startswith("data:"):
                try:
                    last = json.loads(line[5:].strip())
                except ValueError:
                    continue
        return last if last is not None else text
    try:
        return json.loads(text)
    except ValueError:
        return text


class Client:
    def __init__(self, url, headers, opts):
        self.url = url
        self.base = dict(headers)
        self.opts = opts
        self.protocol = opts["protocol"]
        self.session_header = None
        self.next_id = 1
        secrets = [v for k, v in headers.items() if k.lower() in TOKEN_HEADERS]
        secrets += [v[7:] for k, v in headers.items() if k.lower() == "authorization" and v.lower().startswith("bearer ")]
        if opts["token"]:
            secrets.append(opts["token"])
        self.secrets = secrets

    def headers_for(self, line):
        h = {}
        token = line.get("token", self.opts["token"])
        bearer = line.get("bearer", self.opts["bearer"])
        no_session = line.get("noSession", self.opts["no_session"])
        for k, v in self.base.items():
            low = k.lower()
            if low == "x-codd-session" and no_session:
                continue
            if low in TOKEN_HEADERS:
                if token is None:
                    token = v[7:] if low == "authorization" and v.lower().startswith("bearer ") else v
                continue
            h[k] = v
        if token is not None:
            if bearer:
                h["Authorization"] = "Bearer " + token
            else:
                h["X-CODD-Token"] = token
        h["Content-Type"] = "application/json"
        h["Accept"] = "application/json, text/event-stream"
        origin = line.get("origin", self.opts["origin"])
        if origin:
            h["Origin"] = origin
        protocol = line.get("protocol", self.protocol)
        if protocol:
            h["MCP-Protocol-Version"] = protocol
        if self.session_header:
            h["Mcp-Session-Id"] = self.session_header
        for k, v in (line.get("headers") or {}).items():
            h[str(k)] = str(v)
        if isinstance(line.get("token"), str):
            self.secrets.append(line["token"])
        return h

    def send(self, line):
        """Sends one script line; returns False when the connection failed."""
        if "sleep" in line:
            time.sleep(max(0, float(line["sleep"])) / 1000.0)
            return True
        record = {}
        if "label" in line:
            record["label"] = line["label"]
        if "raw" in line:
            method, payload, rid = "raw", str(line["raw"]).encode("utf-8"), None
        else:
            if "tool" in line:
                method = "tools/call"
                params = {"name": line["tool"], "arguments": line.get("arguments") or {}}
            else:
                method = line.get("method")
                params = line.get("params")
                if not isinstance(method, str):
                    die("a script line needs method, tool, raw or sleep: %s" % json.dumps(line, ensure_ascii=False)[:200])
            notify = line.get("notify", method.startswith("notifications/"))
            rid = None if notify else line.get("id", self.next_id)
            if not notify and "id" not in line:
                self.next_id += 1
            msg = {"jsonrpc": "2.0", "method": method}
            if rid is not None:
                msg["id"] = rid
            if params is not None:
                msg["params"] = params
            payload = json.dumps(msg, ensure_ascii=False).encode("utf-8")
        record.update({"method": method, "id": rid})
        if method == "tools/call" and "raw" not in line:
            record["tool"] = (params or {}).get("name")
        headers = self.headers_for(line)
        started = time.monotonic()
        summarizer = Summarizer(self.secrets)
        try:
            status, rheaders, data = http("POST", self.url, headers, payload, self.opts["timeout"])
        except OSError as e:
            record.update({"status": 0, "ms": round((time.monotonic() - started) * 1000, 1),
                           "error": "%s: %s" % (type(e).__name__, getattr(e, "strerror", None) or str(e))})
            emit(record, summarizer)
            return False
        ctype = rheaders.get("content-type")
        body = decode_body(ctype, data)
        if method == "initialize" and isinstance(body, dict):
            version = (body.get("result") or {}).get("protocolVersion") if isinstance(body.get("result"), dict) else None
            if isinstance(version, str) and "protocol" not in line:
                self.protocol = version
            if rheaders.get("mcp-session-id"):
                self.session_header = rheaders["mcp-session-id"]
        record.update({"status": status, "contentType": ctype, "ms": round((time.monotonic() - started) * 1000, 1),
                       "body": summarizer.walk(body)})
        emit(record, summarizer)
        return True


def init_lines():
    return [{"method": "initialize", "params": {"protocolVersion": LATEST, "capabilities": {},
                                                "clientInfo": {"name": "codd-m4-fixture", "version": "1"}}},
            {"method": "notifications/initialized"}]


def script_lines(path):
    try:
        text = sys.stdin.read() if path == "-" else open(path, "r", encoding="utf-8").read()
    except OSError as e:
        die("cannot read script %s (%s)" % (path, type(e).__name__), 1)
    out = []
    for n, raw in enumerate(text.splitlines(), 1):
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        try:
            obj = json.loads(s)
        except ValueError:
            die("script line %d is not JSON" % n)
        if not isinstance(obj, dict):
            die("script line %d is not an object" % n)
        out.append(obj)
    return out


def server_from_config(config, name):
    servers = config.get("mcpServers") if isinstance(config, dict) else None
    if not isinstance(servers, dict) or not servers:
        die("the config has no mcpServers", 1)
    if name is not None:
        entry = servers.get(name)
        if not isinstance(entry, dict):
            die("the config has no server %s" % name, 1)
        return entry
    for entry in servers.values():
        if isinstance(entry, dict) and entry.get("type") in ("http", "streamable-http") and isinstance(entry.get("url"), str):
            u = urlsplit(entry["url"])
            if u.hostname in ("127.0.0.1", "localhost"):
                return entry
    die("the config has no http server on a loopback url", 1)


def do_get(url, note_token, timeout):
    if note_token:
        config, nid = note_token
        token = mcp_token_from(config)
        t = hmac.new(token.encode("utf-8"), ("codd-note-url-v1:" + nid).encode("utf-8"), hashlib.sha256).hexdigest()[:24]
        url += ("&" if "?" in url else "?") + "t=" + t
        secrets = [token, t]
    else:
        secrets = [v for k, v in parse_qsl(urlsplit(url).query) if k == "t"]
    summarizer = Summarizer(secrets)
    record = {"method": "GET", "url": mask_url(url)}
    started = time.monotonic()
    try:
        status, rheaders, data = http("GET", url, {"Accept": "text/markdown, */*"}, None, timeout)
    except OSError as e:
        record.update({"status": 0, "error": "%s: %s" % (type(e).__name__, getattr(e, "strerror", None) or str(e))})
        emit(record, summarizer)
        return 1
    record.update({"status": status, "contentType": rheaders.get("content-type"), "bytes": len(data),
                   "ms": round((time.monotonic() - started) * 1000, 1),
                   "body": summarizer.text(data.decode("utf-8", "replace"))})
    emit(record, summarizer)
    return 0


def main(argv):
    opts = {"config": None, "server": None, "url": None, "headers": [], "token_config": None, "token": None,
            "bearer": False, "no_session": False, "origin": None, "protocol": None, "init": False, "timeout": 15.0,
            "note_token": None}
    i = 0
    rest = None
    while i < len(argv):
        a = argv[i]

        def need(n=1):
            if i + n >= len(argv):
                die("%s needs %d value(s)" % (a, n))
            return argv[i + 1:i + 1 + n]

        if a == "--config":
            opts["config"] = need()[0]
            i += 2
        elif a == "--server":
            opts["server"] = need()[0]
            i += 2
        elif a == "--url":
            opts["url"] = need()[0]
            i += 2
        elif a == "--header":
            value = need()[0]
            if ":" not in value:
                die("--header needs K:V")
            k, v = value.split(":", 1)
            opts["headers"].append((k.strip(), v.strip()))
            i += 2
        elif a == "--token-from-config":
            opts["token_config"] = need()[0]
            i += 2
        elif a == "--note-token-from-config":
            opts["note_token"] = need(2)
            i += 3
        elif a == "--token":
            opts["token"] = need()[0]
            i += 2
        elif a == "--origin":
            opts["origin"] = need()[0]
            i += 2
        elif a == "--protocol":
            opts["protocol"] = need()[0] or None
            i += 2
        elif a == "--timeout":
            try:
                opts["timeout"] = float(need()[0])
            except ValueError:
                die("--timeout needs seconds")
            i += 2
        elif a == "--bearer":
            opts["bearer"] = True
            i += 1
        elif a == "--no-session":
            opts["no_session"] = True
            i += 1
        elif a == "--init":
            opts["init"] = True
            i += 1
        elif a in ("call", "script", "get"):
            rest = argv[i:]
            break
        else:
            die("unknown argument %s" % a)
    if not rest:
        die("missing call, script or get")
    mode = rest[0]
    if mode == "get":
        if len(rest) != 2:
            die("get needs <url>")
        loopback(rest[1])
        return do_get(rest[1], opts["note_token"], opts["timeout"])
    if opts["config"] and opts["url"]:
        die("--config and --url exclude each other")
    if opts["config"]:
        if opts["config"] == "-" and mode == "script" and rest[1:2] == ["-"]:
            die("--config - and script - cannot both read stdin")
        entry = server_from_config(read_json_file(opts["config"], "MCP config"), opts["server"])
        url = entry.get("url")
        if not isinstance(url, str):
            die("the server has no url", 1)
        headers = {str(k): str(v) for k, v in (entry.get("headers") or {}).items()}
    elif opts["url"]:
        url = opts["url"]
        headers = dict(opts["headers"])
    else:
        die("give --config or --url")
    for k, v in opts["headers"]:
        headers[k] = v
    if opts["token_config"]:
        headers["X-CODD-Token"] = mcp_token_from(opts["token_config"])
    loopback(url)
    client = Client(url, headers, opts)
    if mode == "call":
        if len(rest) not in (2, 3):
            die("call needs <method> [<params json>]")
        line = {"method": rest[1]}
        if len(rest) == 3:
            try:
                line["params"] = json.loads(rest[2])
            except ValueError:
                die("params must be JSON")
        lines = (init_lines() if opts["init"] else []) + [line]
    elif mode == "script":
        if len(rest) != 2:
            die("script needs <jsonl file | ->")
        lines = (init_lines() if opts["init"] else []) + script_lines(rest[1])
    else:
        die("unknown mode %s" % mode)
    for line in lines:
        if not client.send(line):
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
