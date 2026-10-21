#!/usr/bin/python3 -I
# A tiny stand-in for CODD's hook server, used ONLY by scripts/m4-fixtures/selftest.sh to exercise
# the fake claude and mcp-client.py (docs/M4-PLAN.md C11). It is not CODD and does not implement the
# notes rules; it answers the wire shapes of §3.9 / §3.10 / D16 / D19 with canned data.
#
#   mock-codd.py --config <codd config.json> --port-file <file> [--log <jsonl>] [--port <n>]
#
# Binds 127.0.0.1 (port 0 = any free one), writes the port to --port-file (atomically) and serves
# until SIGTERM / SIGINT. Auth like D16: hooks and /mcp with a session need X-CODD-Token = the hook
# token / HMAC-SHA256(hookToken, "codd-mcp-v1:<uuid>"); external /mcp callers send the config's
# mcpToken (X-CODD-Token or Bearer); 401 otherwise, a foreign Origin 403.
# Routes: POST /hooks -> 204; POST /hooks/prompt -> 200 JSON (systemMessage + additionalContext) for a
# codd://note/<id> or [[note:<id>]] ref, else 204; POST /mcp (initialize, server/discover -32601,
# notifications 202, tools/list, tools/call notes_search / notes_read / notes_list / notes_append,
# resources/list, resources/templates/list, resources/read, prompts/list; batches); GET|DELETE /mcp
# 405; GET /n/<id>.md?t=<24 hex> -> 200 / 404 / 410; GET /health 200.
# --log gets one JSON line per request: path, method, status, auth kind, rpc methods, the hook body,
# header names and the non-secret header values (X-CODD-Token / Authorization are logged as "<set>").
import base64
import hashlib
import hmac
import importlib.util
import json
import os
import re
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qsl, urlsplit

HERE = os.path.dirname(os.path.realpath(__file__))
SUPPORTED = ("2025-11-25", "2025-06-18", "2025-03-26")
REF = re.compile(r"codd://note/([a-z0-9]+(?:-[a-z0-9]+)*)|\[\[note:([a-z0-9]+(?:-[a-z0-9]+)*)\]\]")
NOTES = {
    "rwd-punch-k7x2": {"title": "打卡頁 RWD 跑版紀錄", "ai": "read", "images": 1},
    "ai-append-note": {"title": "AI 附加測試", "ai": "append", "images": 0},
    "global-note": {"title": "全域：常用指令", "ai": "read", "images": 0},
    "ai-off-note": {"title": "不給 AI 的私人紀錄", "ai": "off", "images": 0},
}
TOOLS = [
    {"name": "notes_search", "description": "Search CODD notes", "inputSchema": {"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]},
     "annotations": {"readOnlyHint": True}, "_meta": {"anthropic/alwaysLoad": True}},
    {"name": "notes_read", "description": "Read one CODD note", "inputSchema": {"type": "object", "properties": {"ref": {"type": "string"}}, "required": ["ref"]},
     "annotations": {"readOnlyHint": True}, "_meta": {"anthropic/alwaysLoad": True}},
    {"name": "notes_list", "description": "List CODD notes", "inputSchema": {"type": "object", "properties": {}}, "annotations": {"readOnlyHint": True}},
    {"name": "notes_append", "description": "Append to an APPEND note", "inputSchema": {"type": "object", "properties": {"ref": {"type": "string"}, "markdown": {"type": "string"}}, "required": ["ref", "markdown"]}},
]


def load_png():
    sys.dont_write_bytecode = True  # never leave __pycache__ next to the fixtures
    spec = importlib.util.spec_from_file_location("m4_make_png", os.path.join(HERE, "make-png.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class State:
    def __init__(self, config, log_path):
        self.hook_token = config.get("token") or ""
        self.mcp_token = config.get("mcpToken") or ""
        self.log_path = log_path
        self.lock = threading.Lock()
        self.port = 0
        self.phone_png = base64.b64encode(load_png().png_bytes(750, 1334, phone=True)).decode("ascii")

    def log(self, record):
        if not self.log_path:
            return
        record["at"] = round(time.time(), 3)
        with self.lock:
            with open(self.log_path, "a", encoding="utf-8") as f:
                f.write(json.dumps(record, ensure_ascii=False) + "\n")


def eq(a, b):
    return hmac.compare_digest(a.encode("utf-8"), b.encode("utf-8"))


def session_token(hook_token, uuid):
    return hmac.new(hook_token.encode("utf-8"), ("codd-mcp-v1:" + uuid.lower()).encode("utf-8"), hashlib.sha256).hexdigest()


def note_url_token(mcp_token, nid):
    return hmac.new(mcp_token.encode("utf-8"), ("codd-note-url-v1:" + nid).encode("utf-8"), hashlib.sha256).hexdigest()[:24]


def ai_text(nid):
    if nid == "rwd-punch-k7x2":
        return ("# 打卡頁 RWD 跑版紀錄\ncodd://note/rwd-punch-k7x2 · NOTE · #rwd #punch · updated 2026-10-15 10:05 · AI READ\n\n"
                "## 問題\niPhone SE（375×667）下打卡按鈕被底部導覽列蓋住；橫向時表格溢出。\n\n"
                "[image] /mock/notes/assets/rwd-punch-k7x2/9f3a1c.annotated.png (750×1334)\n"
                "annotations（原圖像素，左上為原點）:\n"
                "  1 rect  x=20 y=1150 w=710 h=120  上班打卡按鈕被底部導覽列蓋住 → 改 position: sticky，底部留 env(safe-area-inset-bottom)\n")
    note = NOTES[nid]
    return "# %s\ncodd://note/%s · NOTE · AI %s\n\n(mock body)\n" % (note["title"], nid, note["ai"].upper())


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    state = None

    def log_message(self, *args):
        pass

    # -- helpers ---------------------------------------------------------------------------------

    def answer(self, status, body=b"", ctype=None, extra=None):
        self.send_response(status)
        if ctype:
            self.send_header("Content-Type", ctype)
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)
        self.close_connection = True

    def json_answer(self, status, obj):
        self.answer(status, json.dumps(obj, ensure_ascii=False).encode("utf-8"), "application/json")

    def header_record(self):
        out = {}
        for k, v in self.headers.items():
            out[k] = "<set>" if k.lower() in ("x-codd-token", "authorization") else v
        return out

    def read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length > 1024 * 1024:
            return None
        return self.rfile.read(length) if length else b""

    def origin_ok(self):
        origin = self.headers.get("Origin")
        port = self.state.port
        return origin is None or origin in ("http://127.0.0.1:%d" % port, "http://localhost:%d" % port)

    def auth(self, external_allowed):
        token = self.headers.get("X-CODD-Token")
        bearer = self.headers.get("Authorization") or ""
        if not token and bearer.lower().startswith("bearer "):
            token = bearer[7:]
        session = self.headers.get("X-CODD-Session")
        st = self.state
        if not token:
            return "none"
        if session:
            if external_allowed:
                return "session" if eq(token, session_token(st.hook_token, session)) else "bad"
            return "session" if eq(token, st.hook_token) else "bad"
        if external_allowed and st.mcp_token and eq(token, st.mcp_token):
            return "external"
        if not external_allowed and eq(token, st.hook_token):
            return "session"
        return "bad"

    # -- routes ----------------------------------------------------------------------------------

    def do_GET(self):  # noqa: N802 - http.server API
        u = urlsplit(self.path)
        record = {"method": "GET", "path": u.path, "headers": self.header_record()}
        if u.path == "/health":
            status = 200
            self.answer(200, b"ok", "text/plain")
        elif u.path == "/mcp":
            status = 405
            self.answer(405, b"", None, {"Allow": "POST"})
        elif u.path.startswith("/n/") and u.path.endswith(".md"):
            nid = u.path[3:-3]
            t = dict(parse_qsl(u.query)).get("t", "")
            if nid == "gone-note-g0n3" and eq(t, note_url_token(self.state.mcp_token, nid)):
                status = 410
                self.answer(410, "這則筆記已永久刪除\n".encode("utf-8"), "text/markdown; charset=utf-8")
            elif nid in NOTES and NOTES[nid]["ai"] != "off" and eq(t, note_url_token(self.state.mcp_token, nid)):
                status = 200
                self.answer(200, ai_text(nid).encode("utf-8"), "text/markdown; charset=utf-8")
            else:
                status = 404
                self.answer(404, b"", None)
        else:
            status = 404
            self.answer(404, b"", None)
        record["status"] = status
        self.state.log(record)

    def do_DELETE(self):  # noqa: N802 - http.server API
        status = 405 if urlsplit(self.path).path == "/mcp" else 404
        self.answer(status, b"", None, {"Allow": "POST"} if status == 405 else None)
        self.state.log({"method": "DELETE", "path": self.path, "status": status})

    def do_POST(self):  # noqa: N802 - http.server API
        path = urlsplit(self.path).path
        record = {"method": "POST", "path": path, "headers": self.header_record()}
        body = self.read_body()
        if body is None:
            self.answer(413)
            record["status"] = 413
            self.state.log(record)
            return
        if path in ("/hooks", "/hooks/prompt"):
            status = self.hooks(path, body, record)
        elif path == "/mcp":
            status = self.mcp(body, record)
        else:
            status = 404
            self.answer(404)
        record["status"] = status
        self.state.log(record)

    def hooks(self, path, body, record):
        if self.headers.get("Origin") is not None:
            self.answer(403)
            return 403
        kind = self.auth(False)
        record["auth"] = kind
        try:
            payload = json.loads(body.decode("utf-8"))
        except ValueError:
            payload = None
        record["body"] = payload
        if kind != "session":
            self.answer(401)
            return 401
        if path == "/hooks" or not isinstance(payload, dict):
            self.answer(204)
            return 204
        prompt = payload.get("prompt") or ""
        refs = []
        for m in REF.finditer(prompt):
            nid = m.group(1) or m.group(2)
            if nid not in refs:
                refs.append(nid)
        if not refs:
            self.answer(204)
            return 204
        parts, lines = [], []
        for nid in refs[:5]:
            note = NOTES.get(nid)
            if note is None:
                lines.append("codd：codd://note/%s 無法展開（找不到）" % nid)
            elif note["ai"] == "off":
                lines.append("codd：codd://note/%s 無法展開（AI 存取為 OFF）" % nid)
            else:
                parts.append('<codd-note ref="codd://note/%s" title="%s">\n%s</codd-note>' % (nid, note["title"], ai_text(nid)))
                lines.append("codd：已展開 codd://note/%s（%s · %d 張圖片）" % (nid, note["title"], note["images"]))
        answer = {"systemMessage": "\n".join(lines),
                  "hookSpecificOutput": {"hookEventName": "UserPromptSubmit",
                                         "additionalContext": ("CODD 已展開使用者提到的筆記（不需要再呼叫 notes_read）：\n" + "\n".join(parts)) if parts else ""}}
        self.json_answer(200, answer)
        return 200

    def mcp(self, body, record):
        if not self.origin_ok():
            self.answer(403)
            return 403
        kind = self.auth(True)
        record["auth"] = kind
        if kind not in ("session", "external"):
            self.answer(401)
            return 401
        try:
            message = json.loads(body.decode("utf-8"))
        except ValueError:
            record["rpc"] = ["<parse error>"]
            self.json_answer(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}})
            return 400
        batch = isinstance(message, list)
        items = message if batch else [message]
        record["rpc"] = [m.get("method") if isinstance(m, dict) else None for m in items]
        version = self.headers.get("MCP-Protocol-Version")
        methods = {m.get("method") for m in items if isinstance(m, dict)}
        if version and version not in SUPPORTED and not methods <= {"initialize", "server/discover"}:
            self.json_answer(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "Unsupported protocol version"}})
            return 400
        answers = [a for a in (self.rpc(m) for m in items) if a is not None]
        if not answers:
            self.answer(202)
            return 202
        self.json_answer(200, answers if batch else answers[0])
        return 200

    def rpc(self, m):
        if not isinstance(m, dict) or m.get("jsonrpc") != "2.0":
            return {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "Invalid Request"}}
        if "method" not in m:
            return None  # a response from the client
        rid = m.get("id")
        if rid is None:
            return None  # a notification
        method = m["method"]
        params = m.get("params") or {}

        def ok(result):
            return {"jsonrpc": "2.0", "id": rid, "result": result}

        def err(code, message, data=None):
            e = {"code": code, "message": message}
            if data is not None:
                e["data"] = data
            return {"jsonrpc": "2.0", "id": rid, "error": e}

        if method == "initialize":
            asked = params.get("protocolVersion")
            return ok({"protocolVersion": asked if asked in SUPPORTED else SUPPORTED[0],
                       "capabilities": {"tools": {"listChanged": False}, "resources": {"listChanged": False}, "prompts": {"listChanged": False}},
                       "serverInfo": {"name": "codd", "title": "CODD notes", "version": "mock"},
                       "instructions": "Mock CODD notes server for the M4 fixture self test."})
        if method == "ping":
            return ok({})
        if method == "tools/list":
            return ok({"tools": TOOLS})
        if method == "tools/call":
            return ok(self.tool(params.get("name"), params.get("arguments") or {}))
        if method == "resources/templates/list":
            return ok({"resourceTemplates": [{"uriTemplate": "codd://note/{id}", "name": "note", "mimeType": "text/markdown"}]})
        if method == "resources/list":
            return ok({"resources": [{"uri": "codd://note/%s" % k, "name": v["title"], "mimeType": "text/markdown"}
                                     for k, v in NOTES.items() if v["ai"] != "off"]})
        if method == "resources/read":
            uri = params.get("uri") or ""
            nid = uri.rsplit("/", 1)[-1]
            if nid not in NOTES or NOTES[nid]["ai"] == "off":
                return err(-32602, "unknown note", {"state": "unknown"})
            return ok({"contents": [{"uri": uri, "mimeType": "text/markdown", "text": ai_text(nid)}]})
        if method == "prompts/list":
            return ok({"prompts": [{"name": "note", "arguments": [{"name": "id", "required": True}]}]})
        return err(-32601, "Method not found")

    def tool(self, name, args):
        def text(t, is_error=False, structured=None):
            out = {"content": [{"type": "text", "text": t}], "isError": is_error}
            if structured is not None:
                out["structuredContent"] = structured
            return out

        ref = str(args.get("ref") or "")
        nid = ref.rsplit("/", 1)[-1] if ref.startswith("codd://note/") else ref
        if name == "notes_search":
            q = str(args.get("query") or "")
            hits = [k for k, v in NOTES.items() if v["ai"] != "off" and (q in v["title"] or q in ai_text(k))]
            lines = ["%d. %s · codd://note/%s · NOTE" % (n + 1, NOTES[k]["title"], k) for n, k in enumerate(hits)]
            return text("\n".join(lines) or "沒有符合的筆記", structured={"results": [{"id": k, "uri": "codd://note/" + k, "title": NOTES[k]["title"]} for k in hits]})
        if name == "notes_list":
            return text("\n".join("codd://note/%s · %s" % (k, v["title"]) for k, v in NOTES.items() if v["ai"] != "off"))
        if name == "notes_read":
            if nid not in NOTES or NOTES[nid]["ai"] == "off":
                return text("找不到這則筆記：%s" % nid, True)
            content = [{"type": "text", "text": ai_text(nid)}]
            if NOTES[nid]["images"]:
                content.append({"type": "image", "data": self.state.phone_png, "mimeType": "image/png"})
            return {"content": content, "isError": False, "_meta": {"anthropic/maxResultSizeChars": 200000}}
        if name == "debug_echo_token":
            # Selftest only: echoes the caller's token so mcp-client.py's leak marker can be checked.
            return text("token=%s" % (self.headers.get("X-CODD-Token") or ""))
        if name == "notes_append":
            if nid not in NOTES or NOTES[nid]["ai"] == "off":
                return text("找不到這則筆記：%s" % nid, True)
            if NOTES[nid]["ai"] != "append":
                return text("這則筆記的 AI 存取是 READ，不能附加", True)
            return text("已附加到 codd://note/%s" % nid)
        return text("unknown tool %s" % name, True)


def main(argv):
    config_path = port_file = log_path = None
    port = 0
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--config", "--port-file", "--log", "--port") and i + 1 < len(argv):
            v = argv[i + 1]
            if a == "--config":
                config_path = v
            elif a == "--port-file":
                port_file = v
            elif a == "--log":
                log_path = v
            else:
                port = int(v)
            i += 2
        else:
            print("usage: mock-codd.py --config <config.json> --port-file <file> [--log <jsonl>] [--port <n>]", file=sys.stderr)
            return 2
    if not config_path or not port_file:
        print("usage: mock-codd.py --config <config.json> --port-file <file> [--log <jsonl>] [--port <n>]", file=sys.stderr)
        return 2
    with open(config_path, "r", encoding="utf-8") as f:
        config = json.load(f)
    Handler.state = State(config, log_path)
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    Handler.state.port = server.server_address[1]
    tmp = port_file + ".tmp"
    with open(tmp, "w") as f:
        f.write("%d\n" % Handler.state.port)
    os.replace(tmp, port_file)

    def stop(signum, frame):
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        server.serve_forever(poll_interval=0.1)
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
