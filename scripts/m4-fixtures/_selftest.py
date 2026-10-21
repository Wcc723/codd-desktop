# Checks behind scripts/m4-fixtures/selftest.sh (run as `python3 -I _selftest.py <command> …`).
# Every check prints `CHECK ok <name>` or `CHECK FAIL <name> -- <detail>`; numbers print as
# `NUMBER <name> <value>`; the last line of a command is `CHECKS-DONE <command>` (selftest.sh counts
# a missing one as a failure). Python 3.9. Everything happens under the temp folder selftest.sh
# passes in; nothing is sent anywhere but 127.0.0.1 (mock-codd.py) and port 9 (refused at once).
# Secret inputs (CODD config.json files, mcp.json files, a .claude.json with our token) live under
# <tmp>/secret-inputs; `secrets` then proves that no token appears in any other file of the run.
import datetime
import hashlib
import hmac
import json
import os
import pty
import re
import secrets
import select
import shutil
import signal
import stat
import struct
import subprocess
import sys
import time
import unicodedata
import zlib

ESCAPES = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-9;?<=>]*[ -/]*[@-~]")
DAY, HOUR = datetime.timedelta(days=1), datetime.timedelta(hours=1)
NOW = "2026-10-17T10:00:00+08:00"
SESSION = "7c1e9a04-5b3d-4f0e-9a52-3d6c1b2e8f10"
SPEC_IDS = ["rwd-punch-k7x2", "prompt-401-b3m9", "mcp-demo-r8q1", "v2-review-h4n6", "quick-scratch-s5c2",
            "keynote-p6d1", "gear3d-n7q0", "ai-append-note", "ai-off-note", "global-note", "cjk-search-note",
            "subfolder-note", "crlf-note", "daily-log-d9w1", "keynote-ch2-k2d8", "old-review-r30d", "yaml-subset-note",
            "archived-login-a1z9", "trashed-idea-t3x1"]
OFF_SECRET = "OFF-NOTE-SECRET-42"
OFF_TITLE = "不給 AI 的私人紀錄"


def check(name, ok, detail=""):
    if ok:
        print("CHECK ok %s" % name, flush=True)
    else:
        print("CHECK FAIL %s -- %s" % (name, str(detail)[:700]), flush=True)
    return bool(ok)


def number(name, value):
    print("NUMBER %s %s" % (name, value), flush=True)


def mode(path):
    return stat.S_IMODE(os.lstat(path).st_mode)


def load_json(path):
    with open(path, "rb") as f:
        return json.loads(f.read().decode("utf-8"))


def read_text(path):
    with open(path, "r", encoding="utf-8", newline="") as f:
        return f.read()


def read_bytes(path):
    with open(path, "rb") as f:
        return f.read()


def jsonl(path):
    try:
        return [json.loads(l) for l in read_text(path).splitlines() if l.strip()]
    except (OSError, ValueError):
        return []


def wait_until(fn, timeout, step=0.05):
    deadline = time.monotonic() + timeout
    while True:
        if fn():
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(step)


def parse_iso(text):
    t = text.replace("Z", "+00:00")
    return datetime.datetime.fromisoformat(t)


def base_env(tmp, home=None):
    home = home or os.path.join(tmp, "home")
    os.makedirs(home, exist_ok=True)
    return {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home, "TMPDIR": tmp + "/", "LANG": "en_US.UTF-8",
            "LC_CTYPE": "en_US.UTF-8", "TERM": "xterm-256color", "USER": os.environ.get("USER", "test")}


def run(argv, env, stdin=b"", cwd=None, timeout=60):
    started = time.monotonic()
    p = subprocess.run(argv, input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, cwd=cwd,
                       timeout=timeout)
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace"), time.monotonic() - started


def out_dir(tmp, *parts):
    path = os.path.join(tmp, "out", *parts)
    os.makedirs(path, exist_ok=True)
    return path


def secret_dir(tmp, *parts):
    path = os.path.join(tmp, "secret-inputs", *parts)
    os.makedirs(path, exist_ok=True)
    return path


def make_codd_config(tmp, name):
    """A CODD data root config.json (§3.11) with fresh tokens, under secret-inputs."""
    path = os.path.join(secret_dir(tmp, name), "config.json")
    cfg = {"port": 0, "token": secrets.token_hex(32), "mcpToken": secrets.token_hex(32), "v": 1}
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(cfg, f)
    return path, cfg


def session_token(hook_token, uuid):
    return hmac.new(hook_token.encode(), ("codd-mcp-v1:" + uuid.lower()).encode(), hashlib.sha256).hexdigest()


def write_session_mcp(tmp, name, port, hook_token, uuid, server="codd"):
    path = os.path.join(secret_dir(tmp, name), "mcp.json")
    doc = {"mcpServers": {server: {"type": "http", "url": "http://127.0.0.1:%d/mcp" % port,
                                   "headers": {"X-CODD-Token": session_token(hook_token, uuid), "X-CODD-Session": uuid}}}}
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(doc, f)
    return path


class Mock:
    """mock-codd.py as a child process (its argv carries the temp folder, so pkill -f finds it)."""

    def __init__(self, fixtures, tmp, name, config):
        d = out_dir(tmp, "mock-" + name)
        self.port_file = os.path.join(d, "port")
        self.log = os.path.join(d, "mock.jsonl")
        self.proc = subprocess.Popen(["/usr/bin/python3", "-I", os.path.join(fixtures, "mock-codd.py"), "--config", config,
                                      "--port-file", self.port_file, "--log", self.log],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=base_env(tmp))
        if not wait_until(lambda: os.path.exists(self.port_file), 10):
            raise RuntimeError("mock-codd did not start: %s" % self.proc.stderr.read(2000))
        self.port = int(read_text(self.port_file).strip())

    def records(self, path=None):
        return [r for r in jsonl(self.log) if path is None or r.get("path") == path]

    def stop(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(5)


# ------------------------------------------------------------------------------------------------
# PNG reading

def png_info(data):
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    pos, chunks = 8, []
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        tag = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        crc = struct.unpack(">I", data[pos + 8 + length:pos + 12 + length])[0]
        if zlib.crc32(tag + body) & 0xFFFFFFFF != crc:
            return None
        chunks.append((tag, body))
        pos += 12 + length
    w, h, depth, ctype = struct.unpack(">IIBB", chunks[0][1][:10])
    raw = zlib.decompress(b"".join(b for t, b in chunks if t == b"IDAT"))
    channels = 4 if ctype == 6 else 3
    return {"w": w, "h": h, "depth": depth, "ctype": ctype, "raw": raw, "channels": channels,
            "tags": [t for t, _ in chunks]}


def pixel(info, x, y):
    stride = 1 + info["w"] * info["channels"]
    start = y * stride + 1 + x * info["channels"]
    return tuple(info["raw"][start:start + info["channels"]])


def cmd_png(fixtures, tmp):
    d = out_dir(tmp, "png")
    env = base_env(tmp)
    tool = os.path.join(fixtures, "make-png.py")
    big = os.path.join(d, "big.png")
    rc, out, err, secs = run([tool, big, "4000", "3000"], env)
    number("make-png 4000x3000 seconds", "%.2f" % secs)
    info = png_info(read_bytes(big)) if rc == 0 else None
    check("make-png prints the path and writes a valid 4000x3000 RGB PNG", rc == 0 and out.strip() == big and info
          and (info["w"], info["h"], info["depth"], info["ctype"]) == (4000, 3000, 8, 2)
          and len(info["raw"]) == 3000 * (1 + 4000 * 3) and mode(big) == 0o600, (rc, err, info and info["w"]))
    check("every row uses filter 0 and the file is small", info and all(info["raw"][y * 12001] == 0 for y in range(0, 3000, 97))
          and os.path.getsize(big) < 2 * 1024 * 1024, os.path.getsize(big) if os.path.exists(big) else None)
    phone = os.path.join(d, "phone.png")
    rc, out, err, _ = run([tool, phone, "750", "1334", "--phone"], env)
    info = png_info(read_bytes(phone)) if rc == 0 else None
    ok = info and (info["w"], info["h"]) == (750, 1334)
    check("--phone writes 750x1334", ok, (rc, err))
    if ok:
        blue = (47, 111, 224)
        check("--phone: the R6 rect 1 (x 20 y 1150 710x120) lies on the blue button band",
              pixel(info, 21, 1151) == blue and pixel(info, 728, 1151) == blue and pixel(info, 100, 1180) == blue
              and pixel(info, 19, 1180) != blue and pixel(info, 375, 1149) != blue,
              [pixel(info, 21, 1151), pixel(info, 375, 1149)])
        check("--phone: nav band drawn over the button (the bug), status bar white, dark clock under point 2",
              pixel(info, 375, 1300) == (250, 250, 249) and pixel(info, 375, 1240) != blue and pixel(info, 375, 20) == (255, 255, 255)
              and pixel(info, 375, 330) == (29, 29, 29) and pixel(info, 5, 200) == (236, 235, 230),
              [pixel(info, 375, 1300), pixel(info, 375, 20), pixel(info, 375, 330)])
    alpha = os.path.join(d, "alpha.png")
    rc, _, err, _ = run([tool, alpha, "200", "100", "--alpha"], env)
    info = png_info(read_bytes(alpha)) if rc == 0 else None
    check("--alpha writes RGBA with a transparent corner", info and info["ctype"] == 6 and pixel(info, 3, 3)[3] == 0
          and pixel(info, 150, 80)[3] == 255, (rc, err))
    a, b = os.path.join(d, "s1.png"), os.path.join(d, "s2.png")
    run([tool, a, "64", "64", "--seed", "1"], env)
    run([tool, b, "64", "64", "--seed", "2"], env)
    run([tool, os.path.join(d, "s1b.png"), "64", "64", "--seed", "1"], env)
    check("--seed changes the bytes; the same seed repeats them", read_bytes(a) != read_bytes(b)
          and read_bytes(a) == read_bytes(os.path.join(d, "s1b.png")), "")
    if os.path.exists("/usr/bin/sips"):
        rc, out, _, _ = run(["/usr/bin/sips", "-g", "pixelWidth", "-g", "pixelHeight", phone, big], env)
        check("ImageIO (sips) decodes the PNGs with the right sizes", rc == 0 and "pixelWidth: 750" in out
              and "pixelHeight: 1334" in out and "pixelWidth: 4000" in out, out[-300:])
    fake = os.path.join(tmp, "fakehome-png")
    os.makedirs(os.path.join(fake, "Library"), exist_ok=True)
    env2 = base_env(tmp, fake)
    env2["TMPDIR"] = os.path.join(tmp, "othertmp") + "/"
    rc1, _, _, _ = run([tool, os.path.join(fake, "Library", "x.png"), "8", "8"], env2)
    rc2, _, _, _ = run([tool, os.path.join(fake, "proj", "x.png"), "8", "8"], env2)
    check("make-png refuses ~/Library and ~ outside $TMPDIR (exit 1, nothing written)", rc1 == 1 and rc2 == 1
          and not os.path.exists(os.path.join(fake, "Library", "x.png")) and not os.path.exists(os.path.join(fake, "proj")), (rc1, rc2))
    codes = [run([tool] + args, env)[0] for args in ([], [os.path.join(d, "x.png"), "a", "2"], [os.path.join(d, "x.png"), "2", "2", "--bogus"])]
    check("make-png usage errors exit 2", codes == [2, 2, 2], codes)


# ------------------------------------------------------------------------------------------------
# notes

def unquote(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] == '"':
        return v[1:-1].replace('\\"', '"').replace("\\\\", "\\")
    if len(v) >= 2 and v[0] == v[-1] == "'":
        return v[1:-1].replace("''", "'")
    return v


def split_flow(v):
    inner = v.strip()[1:-1]
    items, cur, quote = [], "", None
    for ch in inner:
        if quote:
            cur += ch
            if ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
            cur += ch
        elif ch == ",":
            items.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        items.append(cur)
    return [unquote(i) for i in items]


def parse_note(text):
    """(meta, keys in order, body) with the §3.2 subset rules, or (None, [], text) without frontmatter.
    Raises ValueError for a frontmatter the subset cannot read."""
    lines = text.split("\n")
    if lines[0].rstrip("\r") != "---":
        return None, [], text
    end = next((k for k in range(1, len(lines)) if lines[k].rstrip("\r") == "---"), None)
    if end is None:
        raise ValueError("no closing ---")
    meta, keys, k = {}, [], 1
    while k < end:
        line = lines[k].rstrip("\r")
        k += 1
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m = re.match(r"^([A-Za-z][A-Za-z0-9_]*):(.*)$", line)
        if not m:
            raise ValueError("bad line %r" % line)
        key, value = m.group(1), m.group(2).strip()
        keys.append(key)
        if value == "":
            items = []
            while k < end and re.match(r"^\s*- ", lines[k]):
                items.append(unquote(lines[k].split("- ", 1)[1].rstrip("\r")))
                k += 1
            meta[key] = items
        elif value.startswith("["):
            meta[key] = split_flow(value)
        else:
            meta[key] = unquote(value)
    body = "\n".join(lines[end + 1:])
    return meta, keys, body


def note_files(root):
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if not d.startswith(".") and d != "assets"]
        for f in filenames:
            if f.endswith(".md"):
                out.append(os.path.join(dirpath, f))
    return sorted(out)


def first_h1(body):
    for line in body.replace("\r\n", "\n").split("\n"):
        if line.startswith("# "):
            return line[2:].strip()
    return None


def trigrams(s):
    s = unicodedata.normalize("NFKC", s).lower()
    return {s[i:i + 3] for i in range(len(s) - 2)}


def jaccard(a, b):
    ta, tb = trigrams(a), trigrams(b)
    return len(ta & tb) / max(1, len(ta | tb))


def load_notes(root):
    notes = {}
    for path in note_files(root):
        text = read_text(path)
        meta, keys, body = parse_note(text)
        rel = os.path.relpath(path, root)
        notes[(meta or {}).get("id") or rel] = {"path": path, "rel": rel, "text": text, "meta": meta, "keys": keys, "body": body}
    return notes


def naive_search(notes, query):
    """The D6 behaviour the fixture's expectation table assumes: AND of terms; `#tag` filters tags;
    other terms match NFKC-lowercased title + body + tags; active notes only."""
    hits = []
    for nid, n in notes.items():
        meta = n["meta"] or {}
        if meta.get("status", "active") != "active":
            continue
        tags = [t.lower() for t in meta.get("tags", [])]
        hay = unicodedata.normalize("NFKC", (meta.get("title", "") + "\n" + n["body"] + "\n" + " ".join(tags))).lower()
        ok = True
        for term in query.split():
            if term.startswith("#"):
                ok = ok and term[1:].lower() in tags
            else:
                ok = ok and unicodedata.normalize("NFKC", term).lower() in hay
        if ok and n["meta"] is not None:
            hits.append(nid)
    return sorted(hits)


def check_note_tree(root, label, now, expect_ids, session, project):
    notes = load_notes(root)
    bad = []
    for nid, n in notes.items():
        meta = n["meta"]
        if meta is None:
            continue
        try:
            order = [k for k in n["keys"] if k in ("id", "title", "kind", "ai", "scope", "pinned", "status", "created", "updated")]
            if order[:3] != ["id", "title", "kind"] or meta["kind"] not in ("note", "prompt", "scratch") \
                    or meta["ai"] not in ("off", "read", "append") or meta["scope"] not in ("global", "project") \
                    or meta["pinned"] not in ("true", "false") or meta["status"] not in ("active", "archived"):
                bad.append((nid, "keys/values"))
            if first_h1(n["body"]) != meta["title"]:
                bad.append((nid, "title mirror"))
            created, updated = parse_iso(meta["created"]), parse_iso(meta["updated"])
            if not created <= updated <= now:
                bad.append((nid, "dates"))
            if abs(os.stat(n["path"]).st_mtime - updated.timestamp()) > 1.0:
                bad.append((nid, "mtime != updated"))
            if mode(n["path"]) != 0o600:
                bad.append((nid, "mode"))
        except (KeyError, ValueError) as e:
            bad.append((nid, repr(e)))
    check("%s: every note's frontmatter reads with the §3.2 subset (keys, values, H1 mirror, dates, mtime = updated, 0600)" % label,
          not bad, bad[:6])
    dirs = []
    for dirpath, dirnames, _ in os.walk(root):
        for d in dirnames:
            if mode(os.path.join(dirpath, d)) != 0o700:
                dirs.append(os.path.join(dirpath, d))
    check("%s: every folder is 0700" % label, not dirs and mode(root) == 0o700, dirs[:4])
    return notes


def cmd_notes(fixtures, tmp):
    env = base_env(tmp)
    script = os.path.join(fixtures, "make-notes.sh")
    now = parse_iso(NOW)
    project = os.path.join(tmp, "work", "orb-toolkit-frontend")
    root = os.path.join(out_dir(tmp, "notes"), "spec", "notes")
    manifest_path = os.path.join(out_dir(tmp, "notes"), "spec-manifest.json")
    rc, out, err, _ = run(["/bin/bash", script, root, "--now", NOW, "--session", SESSION.upper(), "--project", project,
                           "--manifest", manifest_path], env)
    ids = out.split()
    check("make-notes prints the 19 ids in order (the no-frontmatter note has none)", rc == 0 and ids == SPEC_IDS, (rc, err, ids))
    if rc != 0:
        return
    notes = check_note_tree(root, "spec", now, SPEC_IDS, SESSION, project)
    manifest = load_json(manifest_path)
    exp = manifest["expect"]
    n1 = notes.get("rwd-punch-k7x2")
    check("n1 is the SPEC file name and links the session (lowercased) and --project",
          n1 and n1["rel"] == "2026-10-15-打卡頁-rwd-跑版紀錄.md" and n1["meta"]["sessions"] == [SESSION]
          and n1["meta"]["projects"] == [project] and n1["meta"]["tags"] == ["rwd", "punch"] and n1["meta"]["scope"] == "project"
          and n1["meta"]["ai"] == "read", n1 and n1["meta"])
    body = n1["body"] if n1 else ""
    m = re.search(r"!\[截圖 2026-10-15 09:32 · iPhone SE\]\(assets/rwd-punch-k7x2/9f3a1c\.png\)\n```codd-annotations\n(.*)\n```\n", body)
    block = None
    try:
        block = json.loads(m.group(1)) if m else None
    except ValueError:
        block = None
    want_items = [
        {"n": 1, "type": "rect", "x": 20, "y": 1150, "w": 710, "h": 120,
         "note": "上班打卡按鈕被底部導覽列蓋住 → 改 position: sticky，底部留 env(safe-area-inset-bottom)"},
        {"n": 2, "type": "point", "x": 375, "y": 330, "note": "時鐘數字在 SE 上太大，會擠到下方卡片 → 改 48px"},
        {"n": 3, "type": "arrow", "x": 600, "y": 760, "x2": 700, "y2": 1080, "note": "打卡紀錄卡片離按鈕太近，間距加到 16px"}]
    check("n1: image line followed by the §3.3 codd-annotations block (items 1-3, size, send)",
          block and block.get("v") == 1 and block.get("image") == "assets/rwd-punch-k7x2/9f3a1c.png"
          and block.get("size") == [750, 1334] and block.get("items") == want_items
          and block.get("send") == {"original": False, "annotated": True, "list": True}, block)
    check("n1: H2s, the **bold** bullet, the task list and the css code block",
          "## 問題\n" in body and "## 想請 AI 做的\n" in body and "**Safari 底部工具列展開時**" in body
          and "- [x] 先重現（Chrome DevTools 375 寬）" in body and "- [ ] 表格改卡片式（<640px）" in body
          and "```css\n@media (max-width: 640px) {\n  .punch-table { display: block; }\n}\n```\n" in body, body[-300:])
    asset = os.path.join(root, "assets", "rwd-punch-k7x2", "9f3a1c.png")
    info = png_info(read_bytes(asset)) if os.path.exists(asset) else None
    check("n1's image is a 750x1334 PNG (0600) under assets/rwd-punch-k7x2/", info and (info["w"], info["h"]) == (750, 1334)
          and mode(asset) == 0o600, asset)
    off = notes.get("ai-off-note")
    check("ai-off-note: AI off, scope global, carries %s and its title" % OFF_SECRET,
          off and off["meta"]["ai"] == "off" and off["meta"]["scope"] == "global" and OFF_SECRET in off["body"]
          and off["meta"]["title"] == OFF_TITLE, off and off["meta"])
    check("ai-append-note is AI append + global; global-note is global",
          notes["ai-append-note"]["meta"]["ai"] == "append" and notes["ai-append-note"]["meta"]["scope"] == "global"
          and notes["global-note"]["meta"]["scope"] == "global", "")
    nofm = notes.get("從別處拖進來.md")
    check("a note without frontmatter (從別處拖進來.md)", nofm and nofm["meta"] is None and nofm["text"].startswith("# ")
          and exp["noFrontmatter"] == ["從別處拖進來.md"], nofm and nofm["text"][:40])
    check("subfolder-note lives in work/", notes["subfolder-note"]["rel"].startswith("work/"), notes["subfolder-note"]["rel"])
    crlf = notes["crlf-note"]["text"]
    check("crlf-note is CRLF throughout (frontmatter included)", "\r\n" in crlf and "\n" not in crlf.replace("\r\n", ""), repr(crlf[:40]))
    ys = notes["yaml-subset-note"]
    check("yaml-subset-note: comment line, quoted title, block list, unknown keys kept",
          "\n# 這行是註解：CODD 必須原樣保留\n" in ys["text"] and 'title: "YAML 子集測試"' in ys["text"]
          and "tags:\n  - yaml\n  - 測試\n" in ys["text"] and ys["meta"]["tags"] == ["yaml", "測試"]
          and ys["meta"]["customKey"] == "保留我" and ys["meta"]["quoted"] == "單引號字串", ys["meta"])
    log = notes["daily-log-d9w1"]["body"]
    heads = re.findall(r"^## (\d{4}-\d{2}-\d{2}|\d{1,2}/\d{2})$", log, re.M)

    def head_date(h):
        if "-" in h:
            return datetime.datetime.strptime(h, "%Y-%m-%d").date()
        mm, dd = h.split("/")
        d = datetime.date(now.year, int(mm), int(dd))
        return d if d <= now.date() else d.replace(year=now.year - 1)

    old_heads = [h for h in heads if (now.date() - head_date(h)).days > 30]
    check("daily-log: 12 dated H2 sections, 9 older than 30 days, with YYYY-MM-DD, M/DD and MM/DD forms",
          len(heads) == 12 and len(old_heads) == 9 and any("/" in h and len(h.split("/")[0]) == 1 for h in heads)
          and any("/" in h and len(h.split("/")[0]) == 2 for h in heads), heads)
    j = jaccard(notes["keynote-ch2-k2d8"]["body"], notes["keynote-p6d1"]["body"])
    check("keynote-ch2 is a near-duplicate of n6 (trigram Jaccard >= 0.80, same project)", 0.8 <= j < 1.0
          and notes["keynote-ch2-k2d8"]["meta"]["projects"] == notes["keynote-p6d1"]["meta"]["projects"], j)
    number("near-duplicate trigram Jaccard", "%.3f" % j)
    codd = os.path.join(root, ".codd")
    state = load_json(os.path.join(codd, "state.json"))
    entries = state.get("notes", {})
    check(".codd/state.json is §3.4 v1 with an entry per note id (trashed included)",
          state.get("v") == 1 and sorted(entries) == sorted(SPEC_IDS)
          and all(set(e) == {"lastOpenedAt", "openCount", "lastUserActivityAt", "keepUntil"} and e["keepUntil"] is None
                  and parse_iso(e["lastUserActivityAt"]) <= now for e in entries.values())
          and mode(os.path.join(codd, "state.json")) == 0o600, sorted(entries)[:3])
    acts = jsonl(os.path.join(codd, "activity.jsonl"))
    check(".codd/activity.jsonl lines are §3.4 (n1 read by the session, n7 read 2 days ago)",
          len(acts) == 2 and all(set(a) == {"v", "at", "note", "action", "client", "session", "sessionTitle", "via"} for a in acts)
          and acts[0]["note"] == "rwd-punch-k7x2" and acts[0]["session"] == SESSION and acts[0]["sessionTitle"] == "打卡頁 RWD 調整"
          and acts[1]["note"] == "gear3d-n7q0" and (now - parse_iso(acts[1]["at"])) >= 2 * DAY, acts)
    tomb = load_json(os.path.join(codd, "tombstones.json"))
    mark = load_json(os.path.join(codd, "notebook.json"))
    check(".codd/tombstones.json and notebook.json are v1", tomb.get("v") == 1 and tomb["items"][0]["id"] == "gone-note-g0n3"
          and set(tomb["items"][0]) == {"id", "title", "trashedAt", "purgedAt"} and mark.get("v") == 1 and "createdAt" in mark, (tomb, mark))
    trashed = os.path.join(codd, "trash", "2026-09-10-已丟掉的舊想法.md")
    tmeta = parse_note(read_text(trashed))[0] if os.path.exists(trashed) else {}
    check("the trashed note is under .codd/trash/ with trashed:, its asset under .codd/trash/assets/<id>/",
          tmeta.get("id") == "trashed-idea-t3x1" and "trashed" in tmeta and tmeta.get("status") == "active"
          and os.path.exists(os.path.join(codd, "trash", "assets", "trashed-idea-t3x1", "1a2b3c.png"))
          and not os.path.exists(os.path.join(root, "2026-09-10-已丟掉的舊想法.md")), tmeta)
    hist = sorted(os.listdir(os.path.join(codd, "history", "rwd-punch-k7x2")))
    names_ok = all(re.match(r"^\d{8}-\d{6}-\d{3}-[0-9a-f]{8}\.md$", h) and
                   hashlib.sha256(read_bytes(os.path.join(codd, "history", "rwd-punch-k7x2", h))).hexdigest()[:8] == h[-11:-3]
                   for h in hist)
    check("history snapshots: 2 for n1 named <yyyyMMdd-HHmmss-SSS>-<hash8>.md (hash8 of the content), 1 for the trashed note",
          len(hist) == 2 and names_ok and len(os.listdir(os.path.join(codd, "history", "trashed-idea-t3x1"))) == 1, hist)
    active = {k: v for k, v in notes.items() if v["meta"] is None or v["meta"].get("status") == "active"}
    counts = {"inbox": len(active), "pinned": len([v for v in active.values() if v["meta"] and v["meta"]["pinned"] == "true"]),
              "prompts": len([v for v in active.values() if v["meta"] and v["meta"]["kind"] == "prompt"]),
              "archive": len([v for v in notes.values() if v["meta"] and v["meta"].get("status") == "archived"]), "trash": 1}
    check("manifest counts match the files (INBOX 18, PINNED 1, PROMPTS 2, ARCHIVE 1, TRASH 1)",
          counts == exp["counts"] == {"inbox": 18, "pinned": 1, "prompts": 2, "archive": 1, "trash": 1}, (counts, exp["counts"]))
    wrong = {q: (naive_search(notes, q), sorted(want)) for q, want in exp["search"].items() if naive_search(notes, q) != sorted(want)}
    check("manifest search table holds for a substring search over the files (打卡頁, 打卡, 筆記, 注音輸入法, #rwd, RWD 打卡, the OFF secret)",
          not wrong, wrong)
    check("the OFF note's secret and title appear only in ai-off-note", [k for k, v in notes.items() if OFF_SECRET in v["text"]] == ["ai-off-note"]
          and [k for k, v in notes.items() if OFF_TITLE in v["text"]] == ["ai-off-note"], "")
    check("manifest lists every note with its relative path", len(manifest["notes"]) == 20
          and all(os.path.exists(os.path.join(root, n["path"])) for n in manifest["notes"]), "")
    two = os.path.join(out_dir(tmp, "notes"), "two", "notes")
    rc, out, err, _ = run(["/bin/bash", script, two, "--two-images", "--text-annotation"], env)
    t1 = read_text(os.path.join(two, "2026-10-15-打卡頁-rwd-跑版紀錄.md")) if rc == 0 else ""
    info = png_info(read_bytes(os.path.join(two, "assets", "rwd-punch-k7x2", "2b7e04.png"))) if rc == 0 else None
    check("--two-images adds 2b7e04.png (1334x750); --text-annotation adds the §3.3 text item 4",
          rc == 0 and "](assets/rwd-punch-k7x2/2b7e04.png)" in t1 and info and (info["w"], info["h"]) == (1334, 750)
          and '"n":4,"type":"text","x":40,"y":80,"note":"這段文字直接畫在圖上","color":"cyan"' in t1
          and "sessions: [%s]" % SESSION in t1, (rc, err))

    # --old: back-dated retention cases
    old = os.path.join(out_dir(tmp, "notes"), "old", "notes")
    old_manifest = os.path.join(out_dir(tmp, "notes"), "old-manifest.json")
    rc, out, err, _ = run(["/bin/bash", script, old, "--old", NOW, "--session", SESSION, "--manifest", old_manifest], env)
    check("--old prints the same ids", rc == 0 and out.split() == SPEC_IDS, (rc, err))
    if rc != 0:
        return
    onotes = check_note_tree(old, "old", now, SPEC_IDS, SESSION, None)
    ostate = load_json(os.path.join(old, ".codd", "state.json"))["notes"]

    def age(nid):
        return now - parse_iso(ostate[nid]["lastUserActivityAt"])

    want = {"gear3d-n7q0": 21 * DAY + 3 * HOUR, "old-review-r30d": 30 * DAY + 2 * HOUR, "quick-scratch-s5c2": 8 * DAY + HOUR,
            "prompt-401-b3m9": 8 * DAY + HOUR, "mcp-demo-r8q1": 40 * DAY + HOUR, "v2-review-h4n6": 35 * DAY + HOUR}
    ages = {k: age(k) for k in want}
    check("--old: last activity ages relative to <now> (stale 21 d, 30 d, SCRATCH 8 d, sent PROMPT 8 d, pinned 40 d, linked 35 d)",
          ages == want, {k: str(v) for k, v in ages.items()})
    n2 = onotes["prompt-401-b3m9"]["meta"]
    check("--old: the sent PROMPT has sent 8 d ago + sentTo, updated before the send",
          now - parse_iso(n2["sent"]) == 8 * DAY + HOUR and n2["sentTo"] and parse_iso(n2["updated"]) < parse_iso(n2["sent"]), n2)
    check("--old: the pinned note is pinned, the linked note links --session",
          onotes["mcp-demo-r8q1"]["meta"]["pinned"] == "true" and onotes["v2-review-h4n6"]["meta"]["sessions"] == [SESSION], "")
    tm = parse_note(read_text(os.path.join(old, ".codd", "trash", "2026-09-10-已丟掉的舊想法.md")))[0]
    check("--old: the trashed note was trashed 31 d ago", now - parse_iso(tm["trashed"]) == 31 * DAY + HOUR, tm.get("trashed"))
    unused = os.path.join(old, "assets", "gear3d-n7q0", "7e8f90.png")
    check("--old: an unreferenced image 12 d old (unused-asset candidate)", os.path.exists(unused)
          and abs(now.timestamp() - 12 * 86400 - os.stat(unused).st_mtime) < 2
          and "7e8f90" not in onotes["gear3d-n7q0"]["text"], unused)
    # Re-derive the expected retention run from the files with the default policy.
    stale, archived = [], []
    for nid, n in onotes.items():
        meta = n["meta"]
        if not meta or meta["status"] != "active" or meta["pinned"] == "true" or nid == "v2-review-h4n6":
            continue
        days = age(nid).days if nid in ostate else 0
        limit = 7 if meta["kind"] == "scratch" or (meta["kind"] == "prompt" and meta.get("sent")) else 30
        if days >= limit:
            archived.append(nid)
        elif days >= 14:
            stale.append(nid)
    ret = load_json(old_manifest)["expect"]["retention"]
    check("--old: the manifest retention expectations follow from the files (default policy)",
          sorted(archived) == sorted(ret["archivedByRun"]) and sorted(stale) == sorted(ret["staleAfterRun"])
          and ret["purgedByRun"] == ["trashed-idea-t3x1"] and ret["archivedByRunUnlessLinkedSessionLive"] == ["v2-review-h4n6"],
          (archived, stale, ret))

    # --count 1000: performance notes
    perf = os.path.join(out_dir(tmp, "notes"), "perf", "notes")
    rc, out, err, secs = run(["/bin/bash", script, perf, "--count", "1000"], env, timeout=120)
    number("make-notes --count 1000 (+ the spec notes) seconds", "%.2f" % secs)
    gen = [i for i in out.split() if i.startswith("gen-")]
    check("--count 1000 adds gen-00001 … gen-01000 after the spec ids", rc == 0 and out.split()[:19] == SPEC_IDS
          and gen == ["gen-%05d" % k for k in range(1, 1001)], (rc, err, gen[:2]))
    files = sorted(os.listdir(os.path.join(perf, "generated"))) if rc == 0 else []
    sizes = [os.path.getsize(os.path.join(perf, "generated", f)) for f in files]
    check("generated notes are ~4 KB each (3.5-4.6 KB), mixed CJK / ASCII", len(files) == 1000 and min(sizes) >= 3500
          and max(sizes) <= 4700, (len(files), sizes and (min(sizes), max(sizes))))
    texts = [read_text(os.path.join(perf, "generated", f)) for f in files]
    forbidden = [w for w in ("打卡", "筆記", "注音", "rwd", "RWD", "keynote", OFF_SECRET) if any(w in t for t in texts)]
    check("generated notes never contain the fixed search words, always 效能 / 部署 / 資料庫 and ASCII",
          not forbidden and all("效能" in t and "部署" in t and "資料庫" in t and re.search(r"[a-z]{3}", t) for t in texts), forbidden)
    gnotes = load_notes(perf)
    check("generated notes parse (frontmatter subset, tags gen + perf, global, not stale)",
          all(gnotes["gen-%05d" % k]["meta"]["tags"] == ["gen", "perf"]
              and datetime.datetime.now().astimezone() - parse_iso(gnotes["gen-%05d" % k]["meta"]["updated"]) < 14 * DAY
              for k in (1, 500, 1000)) if len(gnotes) > 1000 else False, len(gnotes))

    # refusals and usage errors
    rc, out, err, _ = run(["/bin/bash", script, root], env)
    check("make-notes refuses a folder that already holds notes (exit 1)", rc == 1 and "refusing" in err, (rc, err))
    fake = os.path.join(tmp, "fakehome-notes")
    os.makedirs(os.path.join(fake, "Library"), exist_ok=True)
    env2 = base_env(tmp, fake)
    env2["TMPDIR"] = os.path.join(tmp, "othertmp") + "/"
    targets = [os.path.join(fake, "Library", "Application Support", "CODD", "notes"), os.path.join(fake, ".claude", "notes"),
               os.path.join(fake, "proj", "notes"), os.path.join(fake, ".codex", "notes")]
    codes = [run(["/bin/bash", script, t], env2)[0] for t in targets]
    check("make-notes refuses ~/Library, ~/.claude, ~ outside $TMPDIR and ~/.codex (exit 1, nothing written)",
          codes == [1, 1, 1, 1] and not os.path.exists(targets[0]) and not os.path.exists(os.path.join(fake, ".claude"))
          and not os.path.exists(os.path.join(fake, "proj")), codes)
    bad = os.path.join(out_dir(tmp, "notes"), "bad")
    codes = [run(["/bin/bash", script] + a, env)[0] for a in ([], [bad, "--count", "x"], [bad, "--old", "yesterday"],
                                                               [bad, "--session", "nope"], [bad, "--bogus"], [bad, bad])]
    check("make-notes usage errors exit 2 (nothing written)", codes == [2] * 6 and not os.path.exists(bad), codes)


# ------------------------------------------------------------------------------------------------
# git project

def git_env(tmp):
    cfg = os.path.join(tmp, "git-check-empty-config")
    open(cfg, "a").close()
    env = base_env(tmp, os.path.join(tmp, "git-check-home"))
    env.update({"GIT_CONFIG_GLOBAL": cfg, "GIT_CONFIG_NOSYSTEM": "1", "GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C"})
    return env


def git(repo, env, *args):
    p = subprocess.run(["git", "-C", repo, "--no-optional-locks", "-c", "core.fsmonitor=false"] + list(args),
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=30)
    return p.returncode, p.stdout


def processes_with_cwd_under(tmp, patterns):
    """pids matching (pgrep flag, pattern) pairs whose cwd is inside tmp (lsof)."""
    found = []
    for flag, name in patterns:
        out = subprocess.run(["/usr/bin/pgrep", flag, name], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout
        for pid in out.split():
            lo = subprocess.run(["/usr/sbin/lsof", "-a", "-p", pid.decode(), "-d", "cwd", "-Fn"], stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL).stdout.decode("utf-8", "replace")
            for line in lo.splitlines():
                if line.startswith("n") and os.path.realpath(line[1:]).startswith(os.path.realpath(tmp)):
                    found.append((name, pid.decode()))
    return found


def cmd_git(fixtures, tmp):
    script = os.path.join(fixtures, "make-git-project.sh")
    # A hostile user config that must never apply: wrong identity, fsmonitor on, CRLF, gpg, a template
    # hook writing a marker, global attributes and excludes.
    fake = os.path.join(tmp, "fakehome-git")
    marker = os.path.join(tmp, "out", "git-hook-ran")
    tpl = os.path.join(fake, "tpl", "hooks")
    os.makedirs(tpl, exist_ok=True)
    os.makedirs(os.path.join(fake, ".config", "git"), exist_ok=True)
    with open(os.path.join(tpl, "pre-commit"), "w") as f:
        f.write("#!/bin/sh\ntouch '%s'\n" % marker)
    os.chmod(os.path.join(tpl, "pre-commit"), 0o755)
    with open(os.path.join(fake, ".gitconfig"), "w") as f:
        f.write("[user]\n\tname = SHOULD-NOT-APPEAR\n\temail = wrong@example.invalid\n[core]\n\tfsmonitor = true\n\tautocrlf = true\n"
                "[commit]\n\tgpgsign = true\n[init]\n\tdefaultBranch = trunk\n\ttemplateDir = %s\n" % os.path.dirname(tpl))
    with open(os.path.join(fake, ".config", "git", "attributes"), "w") as f:
        f.write("* text=auto eol=crlf\n")
    with open(os.path.join(fake, ".config", "git", "ignore"), "w") as f:
        f.write("*.vue\n")
    env = base_env(tmp, fake)
    env["GIT_DIR"] = os.path.join(tmp, "nonexistent-git-dir")
    env["GIT_CONFIG_PARAMETERS"] = "'core.fsmonitor'='true'"
    repo = os.path.join(out_dir(tmp, "git"), "frontend")
    rc, out, err, secs = run(["/bin/bash", script, repo], env)
    number("make-git-project seconds", "%.2f" % secs)
    check("make-git-project prints the repo path", rc == 0 and out.strip() == os.path.realpath(repo), (rc, err[-400:]))
    if rc != 0:
        return
    left = subprocess.run(["/usr/bin/pgrep", "-f", repo], stdout=subprocess.PIPE).stdout.split()
    daemons = processes_with_cwd_under(tmp, [("-f", "fsmonitor--daemon"), ("-x", "git")])
    check("make-git-project leaves no git / fsmonitor process", not left and not daemons, (left, daemons))
    genv = git_env(tmp)
    _, status = git(repo, genv, "status", "--porcelain=v2", "--branch", "--untracked-files=all")
    lines = status.decode("utf-8", "replace").splitlines()
    changed = sorted(l.split(" ")[-1] for l in lines if l.startswith("1 "))
    check("git status: feat/punch-rwd, upstream origin/feat/punch-rwd, ahead 2 / behind 0",
          "# branch.head feat/punch-rwd" in lines and "# branch.upstream origin/feat/punch-rwd" in lines
          and "# branch.ab +2 -0" in lines, lines[:5])
    check("git status: exactly punch.vue, PunchButton.vue and tailwind.config.js modified (.M), nothing untracked",
          changed == ["src/components/PunchButton.vue", "src/pages/punch.vue", "tailwind.config.js"]
          and all(" .M " in l for l in lines if l.startswith("1 ")) and not [l for l in lines if l[:1] in ("?", "2", "u")], lines)
    _, log = git(repo, genv, "log", "--format=%an <%ae>|%s|%aI")
    log = log.decode("utf-8").splitlines()
    check("3 commits by fixture <fixture@localhost> with fixed dates (the user's config never applied)",
          len(log) == 3 and all(l.startswith("fixture <fixture@localhost>|") for l in log)
          and log[-1].endswith("2026-10-13T09:00:00+08:00") and "SHOULD-NOT-APPEAR" not in read_text(os.path.join(repo, ".git", "config"))
          and not os.path.exists(marker) and not os.path.exists(os.path.join(repo, ".git", "hooks")), log)
    _, diff = git(repo, genv, "diff", "-U0", "--", "src/pages/punch.vue")
    hunks = re.findall(r"^@@ [^@]+ @@", diff.decode("utf-8"), re.M)
    check("punch.vue vs HEAD is one hunk @@ -40,2 +40,4 @@", hunks == ["@@ -40,2 +40,4 @@"], hunks)
    work = read_text(os.path.join(repo, "src", "pages", "punch.vue")).split("\n")
    _, head = git(repo, genv, "cat-file", "blob", "HEAD:src/pages/punch.vue")
    head = head.decode("utf-8").split("\n")
    check("punch.vue: the artboard's lines (13, 33, 39, 40-43, 49), 56 lines, `sticky` 7 times; HEAD has fixed / bottom 0",
          len(work) == 57 and work[56] == "" and work[12] == "onMounted(() => store.fetchToday())"
          and work[32] == '      <PunchButton :loading="store.pending" sticky @punch="store.punch" />'
          and work[38] == ".punch-sticky {" and work[39:43] == ["  position: sticky;", "  bottom: env(safe-area-inset-bottom);",
                                                                 "  margin-bottom: 64px; /* 底部導覽列高度 */", "  z-index: 10;"]
          and work[48] == "@media (max-width: 640px) {" and "\n".join(work).count("sticky") == 7
          and head[39:41] == ["  position: fixed;", "  bottom: 0;"], work[38:44])
    _, tracked = git(repo, genv, "ls-files", "src/components/PunchRecordCard.vue")
    _, head_crlf = git(repo, genv, "cat-file", "blob", "HEAD:src/legacy-crlf.js")
    check("the user's global attributes / excludes never applied (CRLF blob kept, .vue files tracked)",
          tracked.strip() == b"src/components/PunchRecordCard.vue" and head_crlf.count(b"\r\n") == head_crlf.count(b"\n") > 0, (tracked, head_crlf[:40]))
    rc_ign = max(subprocess.run(["git", "-C", repo, "-c", "core.fsmonitor=false", "check-ignore", "-q", rel], env=genv).returncode
                 for rel in ("node_modules/x/index.js", ".env.local"))
    check(".gitignore ignores node_modules/ and .env.local (both present)", rc_ign == 0
          and os.path.exists(os.path.join(repo, "node_modules", "x", "index.js")) and os.path.exists(os.path.join(repo, ".env.local")), rc_ign)

    def b(rel):
        return read_bytes(os.path.join(repo, rel))

    crlf, mixed, bom, big5, u16, latin = b("src/legacy-crlf.js"), b("src/mixed-eol.js"), b("src/bom.css"), b("docs/big5.csv"), \
        b("docs/utf16le.txt"), b("docs/latin1.txt")

    def not_utf8(data):
        try:
            data.decode("utf-8")
            return False
        except UnicodeDecodeError:
            return True

    def not_big5(data):
        try:
            data.decode("big5")
            return False
        except UnicodeDecodeError:
            return True

    check("encodings: CRLF, mixed EOL (CRLF majority), UTF-8 BOM, Big5 發票匯出,金額, UTF-16 LE BOM, Latin-1",
          crlf.count(b"\r\n") == crlf.count(b"\n") > 0 and 0 < mixed.count(b"\r\n") < mixed.count(b"\n")
          and mixed.count(b"\r\n") * 2 > mixed.count(b"\n") and bom.startswith(b"\xef\xbb\xbf")
          and not_utf8(big5) and big5.decode("big5").startswith("發票匯出,金額\n") and u16.startswith(b"\xff\xfe")
          and u16[2:].decode("utf-16-le").startswith("打卡紀錄") and not_utf8(latin) and not_big5(latin), "")
    check("assets/blob.bin has NUL bytes in its first 8 KB; big/large.txt is 6 MiB",
          b"\x00" in b("assets/blob.bin")[:8192] and os.path.getsize(os.path.join(repo, "big", "large.txt")) == 6 * 1024 * 1024, "")
    _, up = git(os.path.join(repo, ".git", "fixture-upstream.git"), genv, "rev-parse", "refs/heads/feat/punch-rwd")
    _, first = git(repo, genv, "rev-list", "--max-parents=0", "HEAD")
    check("the bare upstream .git/fixture-upstream.git holds feat/punch-rwd at the first commit", up.strip() == first.strip() and up.strip(), (up, first))
    index = os.path.join(repo, ".git", "index")
    before = os.stat(index).st_mtime_ns
    for _ in range(2):
        git(repo, genv, "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all")
        git(repo, genv, "ls-files", "-co", "--exclude-standard", "-z")
    check(".git/index is not rewritten by read-only git (--no-optional-locks) on the fixture", os.stat(index).st_mtime_ns == before, "")
    repo2 = os.path.join(out_dir(tmp, "git"), "frontend-2")
    rc, _, _, _ = run(["/bin/bash", script, repo2], base_env(tmp))
    _, h1 = git(repo, genv, "rev-parse", "HEAD")
    _, h2 = git(repo2, genv, "rev-parse", "HEAD")
    check("commit hashes are reproducible (fixed identity and dates)", rc == 0 and h1 == h2 and h1.strip(), (h1, h2))
    punch2 = os.path.join(repo2, "src", "pages", "punch.vue")
    text = read_text(punch2)
    with open(punch2, "w", encoding="utf-8") as f:
        f.write(text.replace("  z-index: 10;\n", "  z-index: 20;\n", 1))
    _, diff2 = git(repo2, genv, "diff", "-U0", "--", "src/pages/punch.vue")
    check("the README's suggested FAKE_TOOL_EDITS line (z-index 10 -> 20) keeps punch.vue at one hunk @@ -40,2 +40,4 @@",
          re.findall(r"^@@ [^@]+ @@", diff2.decode("utf-8"), re.M) == ["@@ -40,2 +40,4 @@"], diff2[:200])
    rc, _, err, _ = run(["/bin/bash", script, repo], base_env(tmp))
    check("make-git-project refuses a non-empty folder (exit 1)", rc == 1 and "not empty" in err, (rc, err))
    fake2 = os.path.join(tmp, "fakehome-git2")
    os.makedirs(fake2, exist_ok=True)
    env2 = base_env(tmp, fake2)
    env2["TMPDIR"] = os.path.join(tmp, "othertmp") + "/"
    codes = [run(["/bin/bash", script, t], env2)[0] for t in (os.path.join(fake2, "proj"), os.path.join(fake2, "Library", "x"))]
    check("make-git-project refuses ~ outside $TMPDIR and ~/Library (exit 1, nothing created)", codes == [1, 1]
          and not os.path.exists(os.path.join(fake2, "proj")) and not os.path.exists(os.path.join(fake2, "Library")), codes)
    codes = [run(["/bin/bash", script] + a, base_env(tmp))[0] for a in ([], ["-x"], [repo2, repo2])]
    check("make-git-project usage errors exit 2", codes == [2, 2, 2], codes)


# ------------------------------------------------------------------------------------------------
# fake .claude.json

class Raw(str):
    pass


def stringify(value, indent=""):
    inner = indent + "  "
    if isinstance(value, Raw):
        return str(value)
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list):
        return "[]" if not value else "[\n" + ",\n".join(inner + stringify(v, inner) for v in value) + "\n" + indent + "]"
    if not value:
        return "{}"
    return "{\n" + ",\n".join(inner + json.dumps(k, ensure_ascii=False) + ": " + stringify(v, inner) for k, v in value.items()) + "\n" + indent + "}"


def parse_raw(text):
    return json.loads(text, parse_int=Raw, parse_float=Raw)


def cmd_claude_json(fixtures, tmp):
    script = os.path.join(fixtures, "make-claude-json.sh")
    env = base_env(tmp)
    d = out_dir(tmp, "claude-json")
    plain = os.path.join(d, "plain", ".claude.json")
    rc, out, err, _ = run(["/bin/bash", script, plain], env)
    text = read_text(plain) if rc == 0 else ""
    check("make-claude-json prints the path; mode 0600; no final newline", rc == 0 and out.strip() == plain and mode(plain) == 0o600
          and text.startswith("{\n  \"numStartups\": 412,") and text.endswith("\n}"), (rc, err))
    if rc != 0:
        return
    doc = parse_raw(text)
    check("the layout is JSON.stringify(x, null, 2) byte for byte (number tokens kept: 1e21, -0, 1.0, 12345678901234567890)",
          stringify(doc) == text and all(t in text for t in ('": 1e21,', '": -0,', '": 1.0,', '": 12345678901234567890,', '": 1.5e-7,')), "")
    keys = list(doc)
    check("top-level key order: numStartups … projects, mcpServers, oauthAccount …",
          keys[0] == "numStartups" and keys.index("projects") < keys.index("mcpServers") < keys.index("oauthAccount")
          and list(doc["mcpServers"]) == ["pencil-like", "stitch-like"] and doc["mcpServers"]["pencil-like"]["type"] == "stdio"
          and doc["mcpServers"]["stitch-like"]["type"] == "http", keys)
    check("projects carry mcpServers keys, CJK keys and values", len(doc["projects"]) == 4 and all("mcpServers" in p for p in doc["projects"].values())
          and any("原型試做" in k for k in doc["projects"]) and "打卡頁 RWD 調整" in text and "\\t" in text and " " in text, list(doc["projects"])[:2])
    check("no real-looking host, token or e-mail other than the M3 fixtures' work@example.com",
          "anthropic" not in text and re.findall(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}", text) == ["work@example.com"] and not re.search(r"[0-9a-f]{32}", text), "")
    foreign = os.path.join(d, "foreign", ".claude.json")
    rc, _, err, _ = run(["/bin/bash", script, foreign, "--codd-foreign"], env)
    fdoc = parse_raw(read_text(foreign)) if rc == 0 else {}
    entry = fdoc.get("mcpServers", {}).get("codd", {})
    del_ok = False
    if entry:
        del fdoc["mcpServers"]["codd"]
        del_ok = stringify(fdoc) == text
    check("--codd-foreign adds mcpServers.codd as a stdio server; everything else is the plain file", rc == 0 and entry.get("type") == "stdio"
          and entry.get("command") and del_ok, (rc, err, entry))
    cfg_path, cfg = make_codd_config(tmp, "claude-json")
    ours = os.path.join(secret_dir(tmp, "claude-json-ours"), ".claude.json")
    rc, out, err, _ = run(["/bin/bash", script, ours, "--codd-ours", "http://127.0.0.1:47821/mcp", "@" + cfg_path], env)
    odoc = parse_raw(read_text(ours)) if rc == 0 else {}
    entry = odoc.get("mcpServers", {}).get("codd", {})
    del_ok = False
    if entry:
        del odoc["mcpServers"]["codd"]
        del_ok = stringify(odoc) == text
    check("--codd-ours <url> @config.json writes §3.12's entry with the config's mcpToken; nothing printed but the path",
          rc == 0 and entry == {"type": "http", "url": "http://127.0.0.1:47821/mcp", "headers": {"X-CODD-Token": cfg["mcpToken"]}}
          and del_ok and out.strip() == ours and cfg["mcpToken"] not in out + err, (rc, err))
    ours2 = os.path.join(secret_dir(tmp, "claude-json-ours"), "literal.json")
    rc, _, _, _ = run(["/bin/bash", script, ours2, "--codd-ours", "http://localhost:47821/mcp", "abc123"], env)
    check("--codd-ours also takes a literal token", rc == 0 and parse_raw(read_text(ours2))["mcpServers"]["codd"]["headers"]["X-CODD-Token"] == "abc123", rc)
    none = os.path.join(d, "none.json")
    rc, _, _, _ = run(["/bin/bash", script, none, "--no-mcp-servers"], env)
    check("--no-mcp-servers omits the top-level mcpServers", rc == 0 and "mcpServers" not in parse_raw(read_text(none)), rc)
    cwd = os.path.join(tmp, "work", "frontend")
    proj = os.path.join(d, "proj.json")
    rc, _, _, _ = run(["/bin/bash", script, proj, "--project", cwd, "--project-codd", cwd, "--project-codd", "/Users/fixture/Github/Gear3D"], env)
    pdoc = parse_raw(read_text(proj)) if rc == 0 else {}
    check("--project / --project-codd add projects[cwd].mcpServers keys (a project-scope foreign codd)",
          rc == 0 and list(pdoc["projects"][cwd]["mcpServers"]) == ["local-db", "codd"]
          and "codd" in pdoc["projects"]["/Users/fixture/Github/Gear3D"]["mcpServers"] and "codd" not in pdoc.get("mcpServers", {}), rc)
    big = os.path.join(d, "big.json")
    rc, _, _, secs = run(["/bin/bash", script, big, "--extra-projects", "4000"], env)
    size = os.path.getsize(big) if rc == 0 else 0
    check("--extra-projects 4000 gives a > 2 MB file that still parses", rc == 0 and size > 2 * 1024 * 1024
          and stringify(parse_raw(read_text(big))) == read_text(big), size)
    number("make-claude-json --extra-projects 4000 bytes / seconds", "%d / %.2f" % (size, secs))
    before = read_bytes(plain)
    rc, _, err, _ = run(["/bin/bash", script, plain, "--codd-foreign"], env)
    check("an existing file is refused (exit 1, bytes unchanged); --force replaces it", rc == 1 and read_bytes(plain) == before
          and run(["/bin/bash", script, plain, "--force", "--codd-foreign"], env)[0] == 0 and read_bytes(plain) != before, (rc, err))
    fake = os.path.join(tmp, "fakehome-json")
    os.makedirs(fake, exist_ok=True)
    env2 = base_env(tmp, fake)
    env2["TMPDIR"] = os.path.join(tmp, "othertmp") + "/"
    link = os.path.join(d, "link-to-home-claude.json")
    os.symlink(os.path.join(fake, ".claude.json"), link)
    codes = [run(["/bin/bash", script, t], env2)[0] for t in (os.path.join(fake, ".claude.json"), link, os.path.join(fake, ".claude", "x.json"))]
    check("refuses ~/.claude.json, a dangling link to it and ~/.claude (exit 1, nothing created)", codes == [1, 1, 1]
          and not os.path.lexists(os.path.join(fake, ".claude.json")) and not os.path.exists(os.path.join(fake, ".claude")), codes)
    codes = [run(["/bin/bash", script] + a, env)[0] for a in ([], [os.path.join(d, "u.json"), "--codd-foreign", "--codd-ours", "http://127.0.0.1:1/mcp", "x"],
                                                             [os.path.join(d, "u.json"), "--codd-ours", "https://example.com/mcp", "x"],
                                                             [os.path.join(d, "u.json"), "--bogus"])]
    check("make-claude-json usage errors exit 2 (nothing written)", codes == [2, 2, 2, 2] and not os.path.exists(os.path.join(d, "u.json")), codes)


# ------------------------------------------------------------------------------------------------
# age-layout.py

def js_iso(dt):
    u = dt.astimezone(datetime.timezone.utc)
    return u.strftime("%Y-%m-%dT%H:%M:%S") + ".%03dZ" % (u.microsecond // 1000)


def cmd_age_layout(fixtures, tmp, seed_layout):
    env = base_env(tmp)
    env["PYTHON3"] = "/usr/bin/python3"
    d = out_dir(tmp, "age")
    data, work = os.path.join(d, "data"), os.path.join(d, "work")
    rc, out, err, _ = run(["/bin/bash", seed_layout, data, work], env)
    check("seed-layout.sh (M2 fixture, unchanged) seeds a layout", rc == 0, err)
    if rc != 0:
        return
    manifest = load_json(out.strip())
    layout = os.path.join(data, "layout.json")
    original = load_json(layout)
    by_title = {s["title"]: s for s in manifest["sessions"]}
    stop_id = by_title["refresh token 流程改寫"]["id"]
    arch_id = manifest["archived"]
    now = parse_iso(NOW)
    tool = os.path.join(fixtures, "age-layout.py")
    rc, out, err, _ = run([tool, layout, "--stopped", stop_id.upper(), (now - 8 * DAY).isoformat(),
                           "--archived", arch_id, (now - 31 * DAY).isoformat(), "--ring", data, arch_id.upper(), "1",
                           "--first-run", data, (now - 30 * DAY).isoformat()], env)
    lines = out.splitlines()
    check("age-layout prints one line per change", rc == 0 and lines == [
        "stopped %s %s" % (stop_id, js_iso(now - 8 * DAY)), "archived %s %s" % (arch_id, js_iso(now - 31 * DAY)),
        "ring %s %d" % (os.path.join(data, "sessions", arch_id, "ring"), 1024 * 1024),
        "first-run %s %s" % (os.path.join(data, "cleanup.json"), (now - 30 * DAY).astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))],
        (rc, err, lines))
    if rc != 0:
        return
    text = read_text(layout)
    aged = json.loads(text)
    check("layout.json keeps CoddCore's format (sorted keys, \"key\" : value, final newline) and mode 0600",
          text == json.dumps(aged, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : ")) + "\n" and mode(layout) == 0o600, "")
    sess = {s["id"]: s for s in aged["sessions"]}
    orig = {s["id"]: s for s in original["sessions"]}
    st, ar = sess[stop_id], sess[arch_id]
    check("--stopped sets lastState stopped + lastStateAt; --archived sets archivedAt (JSDate form); other sessions untouched",
          st["lastState"] == {"kind": "stopped"} and st["lastStateAt"] == js_iso(now - 8 * DAY) and ar["archivedAt"] == js_iso(now - 31 * DAY)
          and all(sess[k] == orig[k] for k in sess if k not in (stop_id, arch_id))
          and {k: v for k, v in st.items() if k not in ("lastState", "lastStateAt")} == {k: v for k, v in orig[stop_id].items() if k not in ("lastState", "lastStateAt")},
          (st.get("lastState"), st.get("lastStateAt"), ar.get("archivedAt")))
    ring = os.path.join(data, "sessions", arch_id, "ring")
    check("--ring writes <dataRoot>/sessions/<lowercase id>/ring of 1 MiB (0600) and a holder.log", os.path.getsize(ring) == 1024 * 1024
          and mode(ring) == 0o600 and os.path.exists(os.path.join(os.path.dirname(ring), "holder.log")), ring)
    cleanup = load_json(os.path.join(data, "cleanup.json"))
    check("--first-run writes cleanup.json retention.firstRunAt (§3.4, UTC seconds)", cleanup.get("v") == 1
          and cleanup["retention"]["firstRunAt"] == (now - 30 * DAY).astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
          and cleanup.get("sessions") == {} and cleanup.get("files") == {} and mode(os.path.join(data, "cleanup.json")) == 0o600, cleanup)
    cleanup["digest"] = {"lastShownAt": "2026-10-12T01:05:00Z", "lastCount": 15}
    cleanup["retention"]["lastRunAt"] = "2026-10-16T01:00:00Z"
    with open(os.path.join(data, "cleanup.json"), "w") as f:
        json.dump(cleanup, f)
    rc, _, _, _ = run([tool, layout, "--first-run", data, NOW], env)
    again = load_json(os.path.join(data, "cleanup.json"))
    check("a second --first-run keeps the other cleanup.json keys", rc == 0 and again["digest"] == cleanup["digest"]
          and again["retention"]["lastRunAt"] == "2026-10-16T01:00:00Z" and again["retention"]["firstRunAt"] == "2026-10-17T02:00:00Z", again)
    before = read_bytes(layout)
    rc, _, err, _ = run([tool, layout, "--stopped", "00000000-0000-4000-8000-000000000000", NOW], env)
    check("an unknown session is refused (exit 1, layout unchanged)", rc == 1 and read_bytes(layout) == before, (rc, err))
    fake = os.path.join(tmp, "fakehome-age")
    os.makedirs(os.path.join(fake, "Library", "Application Support", "CODD"), exist_ok=True)
    env2 = base_env(tmp, fake)
    env2["TMPDIR"] = os.path.join(tmp, "othertmp") + "/"
    target = os.path.join(fake, "Library", "Application Support", "CODD", "layout.json")
    codes = [run([tool, target, "--first-run", os.path.join(fake, "Library", "Application Support", "CODD"), NOW], env2)[0],
             run([tool, layout, "--ring", os.path.join(fake, ".claude"), stop_id, "1"], env2)[0]]
    check("refuses ~/Library and ~/.claude targets (exit 1, nothing written)", codes == [1, 1]
          and not os.path.exists(os.path.join(fake, "Library", "Application Support", "CODD", "cleanup.json"))
          and not os.path.exists(os.path.join(fake, ".claude")), codes)
    codes = [run([tool] + a, env)[0] for a in ([], [layout, "--stopped", stop_id, "yesterday"], [layout, "--stopped", "nope", NOW],
                                               [layout, "--ring", data, stop_id, "lots"], [layout, "--bogus"])]
    check("age-layout usage errors exit 2", codes == [2] * 5, codes)


# ------------------------------------------------------------------------------------------------
# mcp-client.py

def client(fixtures, args, env, stdin=b""):
    rc, out, err, _ = run(["/usr/bin/python3", "-I", os.path.join(fixtures, "mcp-client.py")] + args, env, stdin=stdin)
    recs = []
    for line in out.splitlines():
        try:
            recs.append(json.loads(line))
        except ValueError:
            recs.append({"unparsed": line})
    return rc, recs, out, err


def cmd_mcp_client(fixtures, tmp):
    env = base_env(tmp)
    cfg_path, cfg = make_codd_config(tmp, "client")
    mock = Mock(fixtures, tmp, "client", cfg_path)
    d = out_dir(tmp, "client")
    outputs = []

    def keep(rc_recs):
        outputs.append(rc_recs[2])
        with open(os.path.join(d, "outputs.jsonl"), "a", encoding="utf-8") as f:
            f.write(rc_recs[2])
        return rc_recs

    try:
        sid = "0b7e6a52-3c41-4d2e-9f80-1a2b3c4d5e6f"
        mcp = write_session_mcp(tmp, "client-session", mock.port, cfg["token"], sid)
        rc, recs, out, err = keep(client(fixtures, ["--config", mcp, "--init", "call", "tools/list"], env))
        check("call --init: initialize 200 (2025-11-25), notifications/initialized 202, tools/list 200 with the 4 tools",
              rc == 0 and [r.get("status") for r in recs] == [200, 202, 200]
              and recs[0]["body"]["result"]["protocolVersion"] == "2025-11-25" and recs[1]["id"] is None
              and [t["name"] for t in recs[2]["body"]["result"]["tools"]] == ["notes_search", "notes_read", "notes_list", "notes_append"],
              (rc, err, [r.get("status") for r in recs]))
        posts = mock.records("/mcp")[-3:]
        check("requests carry Content-Type / Accept, the session headers, MCP-Protocol-Version only after initialize",
              all(p["headers"].get("Content-Type") == "application/json" and p["headers"].get("Accept") == "application/json, text/event-stream"
                  and p["headers"].get("X-CODD-Session") == sid and p["headers"].get("X-CODD-Token") == "<set>" and p["auth"] == "session" for p in posts)
              and "MCP-Protocol-Version" not in posts[0]["headers"] and posts[2]["headers"].get("MCP-Protocol-Version") == "2025-11-25"
              and "Origin" not in posts[0]["headers"], posts)
        script = os.path.join(d, "script.jsonl")
        with open(script, "w", encoding="utf-8") as f:
            for line in [{"method": "server/discover", "label": "probe"},
                         {"method": "initialize", "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}}},
                         {"method": "notifications/initialized"}, {"sleep": 50},
                         {"tool": "notes_search", "arguments": {"query": "打卡"}},
                         {"tool": "notes_read", "arguments": {"ref": "codd://note/rwd-punch-k7x2"}},
                         {"raw": "{bad json"}, {"method": "tools/list", "token": "wrong-token-value"},
                         {"method": "tools/list", "noSession": True},
                         {"method": "tools/list", "origin": "http://evil.example"},
                         {"method": "tools/list", "origin": "http://127.0.0.1:%d" % mock.port},
                         {"tool": "debug_echo_token", "arguments": {}}]:
                f.write("# comment lines are skipped\n" if line.get("label") else "")
                f.write(json.dumps(line, ensure_ascii=False) + "\n")
        rc, recs, out, err = keep(client(fixtures, ["--config", mcp, "script", script], env))
        st = [(r.get("method"), r.get("status")) for r in recs]
        check("script: 11 results (sleep and comments print nothing), labels echoed",
              rc == 0 and len(recs) == 11 and recs[0].get("label") == "probe", (rc, err, st))
        if len(recs) == 11:
            check("server/discover answers JSON-RPC -32601 over HTTP 200", recs[0]["status"] == 200 and recs[0]["body"]["error"]["code"] == -32601, recs[0])
            check("notes_search 打卡 finds rwd-punch-k7x2 (tool name in the line)", recs[3]["tool"] == "notes_search"
                  and "codd://note/rwd-punch-k7x2" in json.dumps(recs[3]["body"], ensure_ascii=False), recs[3])
            img = [c for c in recs[4]["body"]["result"]["content"] if c.get("type") == "image"]
            check("notes_read: image blocks summarised as {mimeType, bytes, size} (no base64)", len(img) == 1 and "data" not in img[0]
                  and img[0]["image"]["mimeType"] == "image/png" and img[0]["image"]["bytes"] > 1000 and img[0]["image"]["size"] == [750, 1334]
                  and len(out) < 20000, img)
            check("a raw parse error is HTTP 400 with -32700", recs[5]["status"] == 400 and recs[5]["body"]["error"]["code"] == -32700, recs[5])
            check("per-line token / noSession overrides give 401, a foreign Origin 403, the own Origin 200",
                  [recs[k]["status"] for k in (6, 7, 8, 9)] == [401, 401, 403, 200], [recs[k]["status"] for k in (6, 7, 8, 9)])
            echo = json.dumps(recs[10], ensure_ascii=False)
            check("a token echoed in a response is shown as <SECRET-LEAK> with secretInBody: true (never the token)",
                  recs[10].get("secretInBody") is True and "<SECRET-LEAK>" in echo and session_token(cfg["token"], sid) not in echo, recs[10])
        url = "http://127.0.0.1:%d/mcp" % mock.port
        rc, recs, out, err = keep(client(fixtures, ["--url", url, "--token-from-config", cfg_path, "--init", "call", "tools/call",
                                                    json.dumps({"name": "notes_read", "arguments": {"ref": "ai-off-note"}})], env))
        check("--url + --token-from-config (external mcpToken): initialize 200, the OFF note read is isError",
              rc == 0 and recs[0]["status"] == 200 and recs[2]["body"]["result"]["isError"] is True and mock.records("/mcp")[-1]["auth"] == "external", recs[-1:])
        rc, recs, _, _ = keep(client(fixtures, ["--url", url, "--token-from-config", cfg_path, "--bearer", "call", "tools/list"], env))
        check("--bearer sends the token as Authorization: Bearer (200)", rc == 0 and recs[0]["status"] == 200
              and "Authorization" in mock.records("/mcp")[-1]["headers"] and "X-CODD-Token" not in mock.records("/mcp")[-1]["headers"], recs)
        rc, recs, _, _ = keep(client(fixtures, ["--config", mcp, "--no-session", "call", "tools/list"], env))
        rc2, recs2, _, _ = keep(client(fixtures, ["--url", url, "--header", "X-CODD-Token:nope", "call", "tools/list"], env))
        rc3, recs3, _, _ = keep(client(fixtures, ["--config", mcp, "--origin", "http://evil.example", "call", "tools/list"], env))
        check("--no-session 401, a wrong --header token 401, --origin http://evil.example 403",
              [recs[0]["status"], recs2[0]["status"], recs3[0]["status"]] == [401, 401, 403], (recs, recs2, recs3))
        rc, recs, _, _ = keep(client(fixtures, ["--config", "-", "call", "tools/list"], env, stdin=read_bytes(mcp)))
        check("--config - reads the MCP config from stdin", rc == 0 and recs[0]["status"] == 200 and mock.records("/mcp")[-1]["auth"] == "session", recs)
        rc, recs, _, _ = keep(client(fixtures, ["--config", mcp, "--protocol", "1999-01-01", "call", "tools/list"], env))
        check("--protocol sends MCP-Protocol-Version before initialize (the mock refuses an unknown one with 400)",
              recs[0]["status"] == 400 and mock.records("/mcp")[-1]["headers"].get("MCP-Protocol-Version") == "1999-01-01", recs)
        base = "http://127.0.0.1:%d/n/" % mock.port
        rc, recs, out, _ = keep(client(fixtures, ["--note-token-from-config", cfg_path, "rwd-punch-k7x2", "get", base + "rwd-punch-k7x2.md"], env))
        check("get --note-token-from-config: 200 text/markdown, the url shown with t=••••", rc == 0 and recs[0]["status"] == 200
              and recs[0]["contentType"] == "text/markdown; charset=utf-8" and recs[0]["url"].endswith("?t=••••")
              and recs[0]["body"].startswith("# 打卡頁 RWD 跑版紀錄"), recs)
        r_wrong = keep(client(fixtures, ["get", base + "rwd-punch-k7x2.md?t=" + "0" * 24], env))[1]
        r_off = keep(client(fixtures, ["--note-token-from-config", cfg_path, "ai-off-note", "get", base + "ai-off-note.md"], env))[1]
        r_gone = keep(client(fixtures, ["--note-token-from-config", cfg_path, "gone-note-g0n3", "get", base + "gone-note-g0n3.md"], env))[1]
        check("get: a wrong t 404, the OFF note 404, a purged note 410", [r_wrong[0]["status"], r_off[0]["status"], r_gone[0]["status"]] == [404, 404, 410]
              and "0" * 24 not in json.dumps(r_wrong), (r_wrong, r_off, r_gone))
        rc, recs, _, _ = keep(client(fixtures, ["--url", "http://127.0.0.1:9/mcp", "call", "tools/list"], env))
        check("a refused connection prints status 0 + error and exits 1", rc == 1 and recs[0]["status"] == 0 and "error" in recs[0], (rc, recs))
        codes = [client(fixtures, a, env)[0] for a in (["--url", "http://example.com/mcp", "call", "x"], ["get", "https://127.0.0.1:1/x"],
                                                       [], ["--config", mcp], ["--config", mcp, "call"], ["--bogus", "call", "x"])]
        check("non-loopback urls and usage errors exit 2", codes == [2] * 6, codes)
        check("no output line ever contains a request header value", all("<set>" not in o and cfg["mcpToken"] not in o for o in outputs), "")
    finally:
        mock.stop()


# ------------------------------------------------------------------------------------------------
# fake-claude-m4.sh (interactive, under a pty)

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
        self.seen = {}

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
        now = time.time()
        for line in self.lines():
            self.seen.setdefault(line, now)
        if self.answer_da1 and not self.answered and b"\x1b[c" in self.buf:
            self.answered = True
            self.write(b"\x1b[?62;22c")
        return True

    def text(self):
        return self.buf.decode("utf-8", "replace")

    def lines(self):
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


def copy_fake(fixtures, directory, sidecar):
    os.makedirs(directory, exist_ok=True)
    copy = os.path.join(directory, "fake-claude")
    shutil.copy(os.path.join(fixtures, "fake-claude-m4.sh"), copy)
    os.chmod(copy, 0o755)
    shutil.copy(os.path.join(fixtures, "mcp-client.py"), os.path.join(directory, "mcp-client.py"))
    with open(copy + ".env", "w", encoding="utf-8") as f:
        f.write("# sidecar of the copied fake claude\n" + "".join("%s=%s\n" % kv for kv in sidecar.items()))
    return copy


def hook_settings(port, extra_ups_headers=None):
    """ClaudeHookSettings with the M4 prompt route (§3.8) and permissions.allow."""
    def handler(path, timeout=2, extra=None):
        headers = {"X-CODD-Token": "$CODD_HOOK_TOKEN", "X-CODD-Session": "$CODD_SESSION_ID"}
        headers.update(extra or {})
        return {"type": "http", "url": "http://127.0.0.1:%d%s" % (port, path), "headers": headers,
                "allowedEnvVars": ["CODD_HOOK_TOKEN", "CODD_SESSION_ID"], "timeout": timeout}
    hooks = {}
    for event in ("PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "Notification", "Stop", "StopFailure",
                  "SessionEnd", "PreCompact", "PostCompact", "SubagentStart", "SubagentStop"):
        hooks[event] = [{"hooks": [handler("/hooks", 1 if event == "SessionEnd" else 2)]}]
    hooks["UserPromptSubmit"] = [{"hooks": [handler("/hooks/prompt", 3, extra_ups_headers)]}]
    return {"hooks": hooks, "permissions": {"allow": ["mcp__codd__notes_search", "mcp__codd__notes_read", "mcp__codd__notes_list"]}}


def cmd_fake_claude(fixtures, tmp):
    cfg_path, cfg = make_codd_config(tmp, "fake")
    mock = Mock(fixtures, tmp, "fake", cfg_path)
    base = out_dir(tmp, "fake")
    edit_root = os.path.join(base, "edit-root")
    outside = os.path.join(base, "outside")
    os.makedirs(os.path.join(edit_root, "with space"), exist_ok=True)
    os.makedirs(outside, exist_ok=True)
    with open(os.path.join(edit_root, "a.vue"), "w") as f:
        f.write(".punch-sticky {\n  position: fixed;\n  bottom: 0;\n}\n")
    with open(os.path.join(edit_root, "with space", "b.css"), "w") as f:
        f.write("a { color: red; }\n")
    with open(os.path.join(outside, "c.txt"), "w") as f:
        f.write("x stays\n")
    sid = "6f1d1c2e-7a3b-4c5d-8e9f-0a1b2c3d4e5f"
    codd = "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"
    session_mcp = write_session_mcp(tmp, "fake-session", mock.port, cfg["token"], codd)
    user_mcp = os.path.join(base, "user-mcp.json")
    with open(user_mcp, "w") as f:
        json.dump({"mcpServers": {"user-stdio": {"command": "/opt/fixture/bin/user-mcp", "args": []}}}, f)
    # The shipped session script (mcp-script-session.jsonl) plus a wrong-token line.
    script = os.path.join(base, "mcp-script.jsonl")
    with open(script, "w", encoding="utf-8") as f:
        f.write(read_text(os.path.join(fixtures, "mcp-script-session.jsonl")))
        f.write(json.dumps({"method": "tools/list", "token": "wrong", "label": "wrong-token"}) + "\n")
    prompts = os.path.join(base, "prompts.txt")
    with open(prompts, "w", encoding="utf-8") as f:
        f.write("看一下 codd://note/rwd-punch-k7x2\n\n沒有引用的一般 prompt\n[[note:ai-off-note]] 也看一下\n")
    edits = os.path.join(base, "edits.txt")
    bpath = os.path.join(edit_root, "with space", "b.css")
    with open(edits, "w", encoding="utf-8") as f:
        f.write("\n".join([
            "# comments and blank lines are skipped", "",
            "Edit %s/a.vue position: fixed;\\n  bottom: 0;→position: sticky;\\n  bottom: env(safe-area-inset-bottom);" % edit_root,
            "sleep 400",
            "Write %s/new.txt →新的檔案\\n第二行\\n" % edit_root,
            "Edit %s/c.txt x→y" % outside,
            "Edit %s/a.vue NOT-THERE→x" % edit_root,
            "Edit %s red→blue" % json.dumps(bpath, ensure_ascii=False),
            "Bogus line",
            "NotebookEdit relative/n.ipynb"]) + "\n")
    logs = os.path.join(base, "fakelog")
    sidecar = {"FAKE_LOG_DIR": logs, "FAKE_REGISTRY_DIR": os.path.join(base, "registry"), "FAKE_MCP_SCRIPT": script,
               "FAKE_MCP_LOG": os.path.join(base, "mcp.jsonl"), "FAKE_PROMPTS": prompts, "FAKE_PROMPT_LOG": os.path.join(base, "prompts.jsonl"),
               "FAKE_TOOL_EDITS": edits, "FAKE_TOOL_EDIT_DELAY_MS": "700", "FAKE_EDIT_ROOT": edit_root,
               "FAKE_STDIN_LOG": os.path.join(base, "stdin.jsonl"), "FAKE_STOP_DELAY_MS": "100",
               "FAKE_PRINT_ENV": "CODD_HOOK_TOKEN,CODD_SESSION_ID", "FAKE_STATUSLINE_INTERVAL_MS": "0"}
    copy = copy_fake(fixtures, os.path.join(base, "bin"), sidecar)
    hook_out = os.path.join(base, "sessionstart.txt")
    hook = os.path.join(base, "bin", "codd-hook")
    with open(hook, "w") as f:
        f.write('#!/bin/sh\n{ printf \'%%s\\n\' "$*"; cat; } > "%s"\n' % hook_out)
    os.chmod(hook, 0o755)
    settings = hook_settings(mock.port, {"X-Extra": "pre-$NOT_ALLOWED-post", "X-Braced": "${CODD_SESSION_ID}"})
    settings["hooks"]["SessionStart"] = [{"hooks": [{"type": "command", "command": hook, "args": ["session-start", "--url",
                                                                                                  "http://127.0.0.1:%d/hooks" % mock.port], "timeout": 5}]}]
    settings_json = json.dumps(settings, separators=(",", ":"), sort_keys=True)
    env = base_env(tmp)
    env.update({"CODD_SESSION_ID": codd, "CODD_HOOK_TOKEN": cfg["token"], "CODD_HOOK_URL": "http://127.0.0.1:%d/hooks" % mock.port,
                "NOT_ALLOWED": "leak-value"})
    cwd = os.path.join(base, "work")
    os.makedirs(cwd, exist_ok=True)
    argv = [copy, "--session-id", sid, "--mcp-config", user_mcp, session_mcp, "--settings", settings_json, "--model", "opus"]
    p = Pty(argv, env, cwd)
    transcript = os.path.join(base, "pty-transcript.txt")
    try:
        ready = p.wait_text("FAKE-READY", 10)
        check("fake m4: FAKE-READY", ready, repr(p.text()[-500:]))
        if not ready:
            return
        ready_at = p.seen.get("FAKE-READY", time.time())
        lines = p.lines()
        argv_lines = [l for l in lines if l.startswith("FAKE-ARGV ")]
        check("FAKE-ARGV shows both --mcp-config values (variadic) right before --settings <settings:NB>",
              argv_lines == ["FAKE-ARGV --session-id %s --mcp-config %s %s --settings <settings:%dB> --model opus" % (
                  sid, user_mcp, session_mcp, len(settings_json.encode()))], argv_lines)
        check("FAKE-MCP-CONFIG per config and FAKE-MCP-SERVER per server (header names only)",
              "FAKE-MCP-CONFIG " + user_mcp in lines and "FAKE-MCP-CONFIG " + session_mcp in lines
              and "FAKE-MCP-SERVER name=user-stdio type=stdio url=- headers=- config=0" in lines
              and "FAKE-MCP-SERVER name=codd type=http url=http://127.0.0.1:%d/mcp headers=X-CODD-Token,X-CODD-Session config=1" % mock.port in lines,
              [l for l in lines if l.startswith("FAKE-MCP-")])
        check("FAKE-ENV masks CODD_HOOK_TOKEN; FAKE-SETTINGS shows the prompt url and the allow rules; title fake claude m4",
              "FAKE-ENV CODD_HOOK_TOKEN=set" in lines and "FAKE-ENV CODD_SESSION_ID=%s" % codd in lines
              and "FAKE-SETTINGS prompt-url=http://127.0.0.1:%d/hooks/prompt allow=mcp__codd__notes_search,mcp__codd__notes_read,mcp__codd__notes_list" % mock.port in lines
              and b"\x1b]0;fake claude m4\x07" in p.buf and "FAKE-DA1-OK" in lines, [l for l in lines if l.startswith(("FAKE-ENV", "FAKE-SETTINGS"))])
        check("SessionStart command hook ran (M3 contract kept)", "FAKE-SESSIONSTART hook=%s status=0" % hook in lines, lines[-6:])
        done = p.wait_text("FAKE-MCP-DONE", 15)
        mlines = [l for l in p.lines() if l.startswith("FAKE-MCP ")]
        check("FAKE_MCP_SCRIPT ran through mcp-client.py against the session config", done and "FAKE-MCP-DONE exit=0 lines=11" in p.lines(),
              [l for l in p.lines() if l.startswith("FAKE-MCP")][-12:])
        want = ["FAKE-MCP server/discover -32601 label=discover http=200", "FAKE-MCP initialize 200 label=initialize protocolVersion=2025-11-25",
                "FAKE-MCP notifications/initialized 202 label=initialized",
                "FAKE-MCP tools/list 200 label=tools tools=notes_search,notes_read,notes_list,notes_append"]
        check("FAKE-MCP lines: discover -32601, initialize 2025-11-25, initialized 202, tools/list", mlines[:4] == want, mlines[:4])
        calls = mlines[4:9]
        check("FAKE-MCP tools/call lines: search ok, read with 1 image, append ok, append on a READ note and the OFF read isError, wrong token 401",
              len(mlines) == 11 and calls[0].startswith("FAKE-MCP tools/call 200 label=search tool=notes_search isError=false")
              and calls[1].startswith("FAKE-MCP tools/call 200 label=read tool=notes_read isError=false images=1")
              and calls[2].startswith("FAKE-MCP tools/call 200 label=append tool=notes_append isError=false")
              and calls[3].startswith("FAKE-MCP tools/call 200 label=append-read-note tool=notes_append isError=true")
              and calls[4].startswith("FAKE-MCP tools/call 200 label=read-off tool=notes_read isError=true")
              and mlines[9] == "FAKE-MCP resources/list 200 label=resources resources=3"
              and mlines[10] == "FAKE-MCP tools/list 401 label=wrong-token", mlines[4:])
        mlog = jsonl(os.path.join(base, "mcp.jsonl"))
        check("FAKE_MCP_LOG has the client's JSON lines (image summarised, no base64)", len(mlog) == 11
              and mlog[5]["body"]["result"]["content"][1]["image"]["size"] == [750, 1334] and "data" not in mlog[5]["body"]["result"]["content"][1], len(mlog))
        mposts = [r for r in mock.records("/mcp")]
        check("the MCP requests used the per-session token and X-CODD-Session", all(r["auth"] == "session" for r in mposts[:10])
              and all(r["headers"].get("X-CODD-Session") == codd for r in mposts[:10]) and mposts[10]["auth"] == "bad", [r.get("auth") for r in mposts])
        pdone = p.wait_text("FAKE-PROMPTS-DONE 3", 15)
        plines = [l for l in p.lines() if l.startswith("FAKE-PROMPT-HOOK ")]
        check("FAKE_PROMPTS: three FAKE-PROMPT-HOOK lines (200 with a body, 204 0, 200), then FAKE-PROMPTS-DONE 3",
              pdone and len(plines) == 3 and plines[0].startswith("FAKE-PROMPT-HOOK 200 ") and int(plines[0].split()[2]) > 100
              and plines[1] == "FAKE-PROMPT-HOOK 204 0" and plines[2].startswith("FAKE-PROMPT-HOOK 200 "), plines)
        plog = jsonl(os.path.join(base, "prompts.jsonl"))
        first = plog[0] if plog else {}
        ctx = ((first.get("body") or {}).get("hookSpecificOutput") or {}).get("additionalContext", "")
        check("FAKE_PROMPT_LOG: the expansion's additionalContext (title) and systemMessage; 204 has no body; latency recorded",
              len(plog) == 3 and first.get("status") == 200 and first.get("valid") is True and "打卡頁 RWD 跑版紀錄" in ctx
              and first["body"]["systemMessage"] == "codd：已展開 codd://note/rwd-punch-k7x2（打卡頁 RWD 跑版紀錄 · 1 張圖片）"
              and plog[1]["status"] == 204 and plog[1]["body"] is None and isinstance(first.get("ms"), (int, float))
              and plog[0]["source"] == "file" and plog[0]["prompt"] == "看一下 codd://note/rwd-punch-k7x2", plog[:1])
        check("the OFF ref's refusal line never names the OFF note's title", OFF_TITLE not in json.dumps(plog, ensure_ascii=False)
              and "無法展開" in plog[2]["body"]["systemMessage"] if len(plog) == 3 else False, plog[2:])
        check("FAKE-SYSTEM-MESSAGE lines show the hook's systemMessage like Claude",
              "FAKE-SYSTEM-MESSAGE codd：已展開 codd://note/rwd-punch-k7x2（打卡頁 RWD 跑版紀錄 · 1 張圖片）" in p.lines(), "")
        ups = mock.records("/hooks/prompt")
        check("UserPromptSubmit went to the settings handler (/hooks/prompt) with headers interpolated per allowedEnvVars",
              len(ups) == 3 and all(r["auth"] == "session" and r["headers"].get("X-CODD-Session") == codd
                                    and r["headers"].get("X-Extra") == "pre--post" and r["headers"].get("X-Braced") == codd for r in ups)
              and ups[0]["body"] == {"hook_event_name": "UserPromptSubmit", "session_id": sid, "cwd": os.path.realpath(cwd),
                                     "prompt": "看一下 codd://note/rwd-punch-k7x2", "permission_mode": "default"}, ups[:1])
        edone = p.wait_text("FAKE-TOOL-EDITS-DONE", 15)
        elines = [l for l in p.lines() if l.startswith("FAKE-TOOL-EDIT")]
        check("FAKE_TOOL_EDITS: applied / written / refused outside the root / no-match / quoted path / posted-only / a bad line",
              edone and elines == ["FAKE-TOOL-EDIT %s/a.vue 204 applied" % edit_root, "FAKE-TOOL-EDIT %s/new.txt 204 applied" % edit_root,
                                   "FAKE-TOOL-EDIT %s/c.txt 204 refused-outside-root" % outside,
                                   "FAKE-TOOL-EDIT %s/a.vue 204 no-match" % edit_root, "FAKE-TOOL-EDIT %s 204 applied" % bpath,
                                   "FAKE-TOOL-EDIT-BAD line=9", "FAKE-TOOL-EDIT relative/n.ipynb 204 posted-only",
                                   "FAKE-TOOL-EDITS-DONE 6"], elines)
        check("the edits landed only under FAKE_EDIT_ROOT",
              read_text(os.path.join(edit_root, "a.vue")) == ".punch-sticky {\n  position: sticky;\n  bottom: env(safe-area-inset-bottom);\n}\n"
              and read_text(os.path.join(edit_root, "new.txt")) == "新的檔案\n第二行\n" and read_text(os.path.join(outside, "c.txt")) == "x stays\n"
              and read_text(bpath) == "a { color: blue; }\n", read_text(os.path.join(edit_root, "a.vue")))
        posts = [r for r in mock.records("/hooks") if (r.get("body") or {}).get("hook_event_name") in ("PostToolUse", "PostToolUseFailure")]
        names = [(r["body"]["hook_event_name"], r["body"]["tool_name"], r["body"]["tool_input"].get("file_path") or r["body"]["tool_input"].get("notebook_path")) for r in posts]
        check("PostToolUse payloads carry tool_name and tool_input.file_path (notebook_path for NotebookEdit; PostToolUseFailure on no-match)",
              names == [("PostToolUse", "Edit", edit_root + "/a.vue"), ("PostToolUse", "Write", edit_root + "/new.txt"),
                        ("PostToolUse", "Edit", outside + "/c.txt"), ("PostToolUseFailure", "Edit", edit_root + "/a.vue"),
                        ("PostToolUse", "Edit", bpath), ("PostToolUse", "NotebookEdit", "relative/n.ipynb")]
              and posts[0]["body"]["tool_input"]["old_string"] == "position: fixed;\n  bottom: 0;" and posts[0]["body"]["session_id"] == sid
              and posts[0]["auth"] == "session", names)
        if len(posts) >= 2:
            first_delay = posts[0]["at"] - ready_at
            gap = posts[1]["at"] - posts[0]["at"]
            number("tool edit: first PostToolUse after FAKE-READY (s, delay 0.7)", "%.2f" % first_delay)
            check("the first edit waits FAKE_TOOL_EDIT_DELAY_MS after FAKE-READY; `sleep 400` spaces the next one",
                  0.65 <= first_delay < 3.0 and 0.38 <= gap < 3.0, (first_delay, gap))
        p.write("hello 世界\r".encode())
        typed = p.wait_text("FAKE-HOOK UserPromptSubmit 204", 5)
        p.write("\x1b[200~第一行\r第二行 codd://note/rwd-punch-k7x2\x1b[201~\r".encode())
        pasted = p.wait_text("FAKE-HOOK UserPromptSubmit 200", 5)
        check("typed and pasted prompts post UserPromptSubmit (204 / 200 for the ref) with the M3 FAKE-HOOK line", typed and pasted, p.lines()[-8:])
        slog = jsonl(os.path.join(base, "stdin.jsonl"))
        kinds = [(r["kind"], r.get("text") or r.get("prompt")) for r in slog]
        check("FAKE_STDIN_LOG records the typed line, the paste (exact text) and each submit",
              ("line", "hello 世界") in kinds and ("paste", "第一行\r第二行 codd://note/rwd-punch-k7x2") in kinds
              and ("submit", "hello 世界") in kinds and ("submit", "第一行\n第二行 codd://note/rwd-punch-k7x2") in kinds, kinds)
        tplog = [r for r in jsonl(os.path.join(base, "prompts.jsonl")) if r["source"] == "typed"]
        check("typed prompts are in FAKE_PROMPT_LOG too (source typed)", len(tplog) == 2 and tplog[1]["status"] == 200, tplog)
        reg = os.path.join(base, "registry", "%d.json" % p.pid)
        regd = load_json(reg) if os.path.exists(reg) else {}
        check("the registry file is written (version 2.1.302, M3 contract)", regd.get("sessionId") == sid and regd.get("version") == "2.1.302", regd)
        logged = load_json(os.path.join(logs, "fake-%d.json" % p.pid))
        check("FAKE_LOG_DIR json: argv as given, mode interactive, mcpConfigs", logged.get("argv") == argv[1:] and logged.get("mode") == "interactive"
              and logged.get("mcpConfigs") == [user_mcp, session_mcp], logged.get("mcpConfigs"))
        p.write(b"FAKE-CLEAR\r")
        cleared = p.wait_for(lambda q: any(l.startswith("FAKE-CLEARED session=") for l in q.lines()), 5)
        fresh = next((l.split("=", 1)[1] for l in p.lines() if l.startswith("FAKE-CLEARED session=")), "")
        ends = [r for r in mock.records("/hooks") if (r.get("body") or {}).get("hook_event_name") == "SessionEnd"]
        check("FAKE-CLEAR posts SessionEnd (reason clear) to its handler and moves the registry to the new id (M3 contract)",
              cleared and wait_until(lambda: len([r for r in mock.records("/hooks") if (r.get("body") or {}).get("hook_event_name") == "SessionEnd"]) == 1, 3)
              and load_json(reg).get("sessionId") == fresh, (ends, fresh))
        p.write(b"FAKE-EXIT\r")
        status = p.wait_exit(5)
        check("FAKE-EXIT exits 3 and removes the registry file", exit_code(status) == 3 and not os.path.exists(reg), exit_code(status))
    finally:
        with open(transcript, "wb") as f:
            f.write(p.buf)
        p.close()
        p.kill()
    try:
        fake_claude_pipe(fixtures, tmp, base, mock, settings_json, session_mcp, edit_root, codd, cfg)
    finally:
        mock.stop()
    env = base_env(tmp)
    rc, out, err, _ = run([copy, "--mcp-config", os.path.join(base, "missing.json"), "--settings", "{}"], env, timeout=20)
    check("a missing --mcp-config aborts startup like Claude (Error: Invalid MCP configuration, exit 1)",
          rc == 1 and "Error: Invalid MCP configuration: %s" % os.path.join(base, "missing.json") in out, (rc, out[-300:]))
    bad = os.path.join(base, "bad-mcp.json")
    with open(bad, "w") as f:
        f.write("{not json")
    rc, out, _, _ = run([copy, "--mcp-config", bad], env, timeout=20)
    check("an invalid --mcp-config aborts too", rc == 1 and "Error: Invalid MCP configuration" in out, rc)
    rc, out, _, _ = run([copy, "--version"], env)
    rc2, out2, _, _ = run(["/bin/bash", os.path.join(fixtures, "fake-claude-m4.sh"), "--version"], env)
    check("--version prints 2.1.302 (Claude Code), also when run through bash (polyglot)", rc == 0 and out == "2.1.302 (Claude Code)\n"
          and rc2 == 0 and out2 == out, (out, out2))


def fake_claude_pipe(fixtures, tmp, base, mock, settings_json, session_mcp, edit_root, codd, cfg):
    """The same fake without a tty (no DA1), with FAKE_HEADER_BLANK (Claude's credential blanking),
    FAKE_TOOL_EDIT_ATOMIC and FAKE_MCP_SERVER; stdin stays open until every helper is done."""
    script = os.path.join(base, "mcp-script-2.jsonl")
    with open(script, "w") as f:
        f.write('{"method": "tools/list"}\n')
    prompts = os.path.join(base, "prompts-2.txt")
    with open(prompts, "w", encoding="utf-8") as f:
        f.write("codd://note/rwd-punch-k7x2\n")
    target = os.path.join(edit_root, "atomic.txt")
    with open(target, "w") as f:
        f.write("before\n")
    inode = os.stat(target).st_ino
    edits = os.path.join(base, "edits-2.txt")
    with open(edits, "w", encoding="utf-8") as f:
        f.write("Hook PermissionRequest {\"tool_name\": \"Bash\", \"tool_input\": {\"command\": \"npm test\"}}\n"
                "Hook Bogus {not json\n"
                "Edit %s before→after\n" % target)
    sidecar = {"FAKE_MCP_SCRIPT": script, "FAKE_MCP_SERVER": "codd", "FAKE_MCP_LOG": os.path.join(base, "mcp-2.jsonl"),
               "FAKE_PROMPTS": prompts, "FAKE_PROMPT_LOG": os.path.join(base, "prompts-2.jsonl"), "FAKE_HEADER_BLANK": "CODD_HOOK_TOKEN",
               "FAKE_TOOL_EDITS": edits, "FAKE_EDIT_ROOT": edit_root, "FAKE_TOOL_EDIT_ATOMIC": "1", "FAKE_STOP_DELAY_MS": "50"}
    copy = copy_fake(fixtures, os.path.join(base, "bin2"), sidecar)
    env = base_env(tmp)
    env.update({"CODD_SESSION_ID": codd, "CODD_HOOK_TOKEN": cfg["token"]})
    cwd = os.path.join(base, "work")
    proc = subprocess.Popen([copy, "--mcp-config", session_mcp, "--settings", settings_json], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, cwd=cwd)
    buf = b""
    deadline = time.monotonic() + 15
    want = (b"FAKE-MCP-DONE", b"FAKE-PROMPTS-DONE 1", b"FAKE-TOOL-EDITS-DONE 1")
    while time.monotonic() < deadline and not all(w in buf for w in want):
        r, _, _ = select.select([proc.stdout], [], [], 0.2)
        if r:
            chunk = os.read(proc.stdout.fileno(), 65536)
            if not chunk:
                break
            buf += chunk
    proc.stdin.close()
    try:
        code = proc.wait(5)
    except subprocess.TimeoutExpired:
        proc.kill()
        code = proc.wait(5)
    buf += proc.stdout.read()
    proc.stdout.close()
    with open(os.path.join(base, "pipe-transcript.txt"), "wb") as f:
        f.write(buf)
    lines = buf.decode("utf-8", "replace").splitlines()
    check("without a tty: no DA1 probe, the helpers still run, EOF on stdin exits 0",
          code == 0 and not any(l.startswith("FAKE-DA1") for l in lines) and all(w.decode() in "\n".join(lines) for w in want), (code, lines[-6:]))
    check("FAKE_MCP_SERVER picks the server by name", "FAKE-MCP tools/list 200 tools=notes_search,notes_read,notes_list,notes_append" in lines, lines)
    check("FAKE_HEADER_BLANK=CODD_HOOK_TOKEN blanks the token like Claude's credential rule (every hook answers 401)",
          "FAKE-PROMPT-HOOK 401 0" in lines and "FAKE-TOOL-EDIT %s 401 applied" % target in lines
          and mock.records("/hooks/prompt")[-1]["auth"] == "none", [l for l in lines if "HOOK" in l or "TOOL-EDIT" in l])
    check("FAKE_TOOL_EDIT_ATOMIC=1 replaces the file (new inode) with the edit", read_text(target) == "after\n"
          and os.stat(target).st_ino != inode, read_text(target))
    perm = [r["body"] for r in mock.records("/hooks") if (r.get("body") or {}).get("hook_event_name") == "PermissionRequest"]
    check("a `Hook PermissionRequest {…}` line posts that event with its fields (a bad JSON line is reported)",
          len(perm) == 1 and perm[0]["tool_name"] == "Bash" and perm[0]["tool_input"] == {"command": "npm test"}
          and perm[0]["session_id"] and "FAKE-HOOK PermissionRequest 401" in lines and "FAKE-TOOL-EDIT-BAD line=2" in lines, perm)


# ------------------------------------------------------------------------------------------------
# fake-claude-m4.sh print mode (-p, D32)

def cmd_fake_print(fixtures, tmp):
    cfg_path, cfg = make_codd_config(tmp, "print")
    mock = Mock(fixtures, tmp, "print", cfg_path)
    base = out_dir(tmp, "print")
    try:
        run_id = "3c2b1a09-8f7e-4d6c-9b5a-4e3d2c1b0a99"
        run_dir = os.path.join(base, "run", "condense-" + run_id)
        os.makedirs(run_dir, exist_ok=True)
        mcp = write_session_mcp(tmp, "print-run", mock.port, cfg["token"], run_id)
        logs = os.path.join(base, "fakelog")
        sidecar = {"FAKE_LOG_DIR": logs, "FAKE_P_INPUT": os.path.join(base, "p-input.txt"), "FAKE_P_MCP": "1",
                   "FAKE_MCP_LOG": os.path.join(base, "p-mcp.jsonl"), "FAKE_P_DATE": "10/15",
                   "FAKE_REGISTRY_DIR": os.path.join(base, "registry")}
        copy = copy_fake(fixtures, os.path.join(base, "bin"), sidecar)
        stdin = ("請把下面的筆記濃縮成一則 Markdown 摘要，每則來源一個 ## 段落，不要編造。\n\n"
                 "# 打卡頁 RWD 跑版紀錄\ncodd://note/rwd-punch-k7x2 · NOTE · #rwd #punch · AI READ\n"
                 "file: /x/notes/2026-10-15-打卡頁-rwd-跑版紀錄.md\n\n## 問題\niPhone SE 下打卡按鈕被底部導覽列蓋住。\n\n"
                 "# 每日工作日誌（舊段落 9 段）\ncodd://note/daily-log-d9w1 · NOTE · AI READ\n\n## 2026-09-01\n- 做了：整理 PR 評論\n").encode("utf-8")
        argv = [copy, "-p", "--model", "sonnet-5.5", "--output-format", "text", "--tools", "", "--permission-prompts", "none",
                "--strict-mcp-config", "--mcp-config", mcp, "--allowedTools", "mcp__codd__notes_read", "--no-session-persistence"]
        profile = os.path.join(base, "profile-SECRET-PATH-7q")
        env = base_env(tmp)
        env["CLAUDE_CONFIG_DIR"] = profile
        rc, out, err, secs = run(argv, env, stdin=stdin, cwd=run_dir, timeout=30)
        want = ("# 摘要 · 10/15 清理（2 則）\n\n## 打卡頁 RWD 跑版紀錄\n- 來源：codd://note/rwd-punch-k7x2\n"
                "- 重點：iPhone SE 下打卡按鈕被底部導覽列蓋住。\n\n"
                "## 每日工作日誌（舊段落 9 段）\n- 來源：codd://note/daily-log-d9w1\n- 重點：做了：整理 PR 評論\n")
        check("-p prints only the default summary on stdout (# 摘要 · 10/15 清理（2 則）, one ## per codd://note ref)",
              rc == 0 and out == want, (rc, out, err[-400:]))
        elines = err.splitlines()
        check("FAKE-P-ARGV is exactly D32's argv (the empty --tools value shown as \"\")",
              "FAKE-P-ARGV -p --model sonnet-5.5 --output-format text --tools \"\" --permission-prompts none --strict-mcp-config "
              "--mcp-config %s --allowedTools mcp__codd__notes_read --no-session-persistence" % mcp in elines, elines[:2])
        check("FAKE-P-ENV: CODD_HOOK_TOKEN=unset CODD_SESSION_ID=unset, CLAUDE_CONFIG_DIR=set (value never printed)",
              "FAKE-P-ENV CODD_HOOK_TOKEN=unset CODD_SESSION_ID=unset" in elines and "FAKE-P-ENV CLAUDE_CONFIG_DIR=set" in elines
              and profile not in err + out, [l for l in elines if l.startswith("FAKE-P-ENV")])
        check("FAKE-P-FLAGS: the variadic flags parsed like commander (--tools [\"\"], one --mcp-config, one allowed tool)",
              "FAKE-P-FLAGS model=sonnet-5.5 output-format=text tools=[\"\"] permission-prompts=none strict-mcp-config=yes mcp-config=1 "
              "allowedTools=mcp__codd__notes_read no-session-persistence=yes prompt=stdin" in elines, [l for l in elines if l.startswith("FAKE-P-FLAGS")])
        check("stdin went to FAKE_P_INPUT byte for byte; FAKE-P-STDIN counts the refs", read_bytes(os.path.join(base, "p-input.txt")) == stdin
              and "FAKE-P-STDIN bytes=%d refs=2" % len(stdin) in elines, "")
        mlines = [l for l in elines if l.startswith("FAKE-MCP ")]
        check("FAKE_P_MCP=1 calls notes_read once through --mcp-config (discover, initialize, initialized, tools/call)",
              len(mlines) == 4 and mlines[0].startswith("FAKE-MCP server/discover -32601") and mlines[3].startswith("FAKE-MCP tools/call 200 tool=notes_read isError=false images=1")
              and len(jsonl(os.path.join(base, "p-mcp.jsonl"))) == 4 and mock.records("/mcp")[-1]["headers"].get("X-CODD-Session") == run_id, mlines)
        logged = [load_json(os.path.join(logs, f)) for f in os.listdir(logs) if f.endswith(".json")]
        check("FAKE_LOG_DIR json: mode print, argv exactly as given, env set/unset only, no registry file",
              len(logged) == 1 and logged[0]["mode"] == "print" and logged[0]["argv"] == argv[1:]
              and logged[0]["env"] == {"CODD_HOOK_TOKEN": "unset", "CODD_SESSION_ID": "unset", "CODD_HOOK_URL": "unset", "CLAUDE_CONFIG_DIR": "set"}
              and logged[0]["flags"]["tools"] == [""] and not os.path.exists(os.path.join(base, "registry")), logged)
        check("-p log lines end with FAKE-P-OUTPUT and FAKE-P-EXIT 0", elines[-1] == "FAKE-P-EXIT 0" and elines[-2].startswith("FAKE-P-OUTPUT bytes="), elines[-2:])
        env2 = dict(env)
        env2.update({"CODD_HOOK_TOKEN": cfg["token"], "CODD_SESSION_ID": run_id})
        rc, out, err, _ = run(argv, env2, stdin=stdin, cwd=run_dir, timeout=30)
        check("with CODD_HOOK_TOKEN / CODD_SESSION_ID in the environment: FAKE-P-ENV ...=set, the token never printed",
              rc == 0 and "FAKE-P-ENV CODD_HOOK_TOKEN=set CODD_SESSION_ID=set" in err and cfg["token"] not in out + err, err.splitlines()[:3])
        output = os.path.join(base, "p-output.md")
        with open(output, "w", encoding="utf-8") as f:
            f.write("# 自訂摘要\n\n內容\n")
        with open(copy + ".env", "a") as f:
            f.write("FAKE_P_OUTPUT=%s\nFAKE_P_EXIT=3\nFAKE_P_DELAY=0.6\nFAKE_P_MCP=0\n" % output)
        rc, out, err, secs = run(argv, env, stdin=stdin, cwd=run_dir, timeout=30)
        check("FAKE_P_OUTPUT is printed as is, FAKE_P_EXIT=3 exits 3, FAKE_P_DELAY=0.6 waits",
              rc == 3 and out == "# 自訂摘要\n\n內容\n" and secs >= 0.6 and "FAKE-P-EXIT 3" in err, (rc, out, secs))
        rc, out, _, _ = run(argv[:5] + ["json"] + argv[6:], env, stdin=stdin, cwd=run_dir, timeout=30)
        try:
            obj = json.loads(out)
        except ValueError:
            obj = {}
        check("--output-format json wraps the result", rc == 3 and obj.get("type") == "result" and obj.get("result") == "# 自訂摘要\n\n內容\n", out[:200])
        rc, out, err, _ = run(argv, env, stdin=b"", cwd=run_dir, timeout=30)
        check("no stdin and no prompt: Claude's error, exit 1", rc == 1 and "Input must be provided either through stdin or as a prompt argument" in err, (rc, err[-200:]))
        rc, _, err, _ = run([copy, "-p", "--mcp-config", mcp, os.path.join(base, "x.json"), "--allowedTools", "a", "b",
                             "--no-session-persistence"], env, stdin=b"hi", cwd=run_dir, timeout=30)
        check("variadic parsing: two --mcp-config values; the missing second one aborts like Claude", rc == 1
              and "Error: Invalid MCP configuration: %s" % os.path.join(base, "x.json") in err, (rc, err[-300:]))
        with open(copy + ".env", "a") as f:
            f.write("FAKE_P_DELAY=20\n")
        proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, cwd=run_dir)
        proc.stdin.write(stdin)
        proc.stdin.close()
        time.sleep(0.8)
        started = time.monotonic()
        proc.terminate()
        try:
            code = proc.wait(5)
        except subprocess.TimeoutExpired:
            proc.kill()
            code = proc.wait(5)
        check("SIGTERM (CODD's 取消) ends a -p run at once with 143", code == 143 and time.monotonic() - started < 2, code)
        proc.stdout.close()
        proc.stderr.close()
    finally:
        mock.stop()


# ------------------------------------------------------------------------------------------------
# secrets and syntax

def cmd_secrets(tmp):
    """No token of the run (hook tokens, mcpTokens, derived session tokens, the fake profile path)
    appears in any file outside <tmp>/secret-inputs."""
    tokens = set()
    sdir = os.path.join(tmp, "secret-inputs")
    for dirpath, _, filenames in os.walk(sdir):
        for f in filenames:
            path = os.path.join(dirpath, f)
            try:
                obj = load_json(path)
            except (OSError, ValueError):
                continue
            if f == "config.json":
                tokens.update([obj["token"], obj["mcpToken"]])
            for server in (obj.get("mcpServers") or {}).values() if isinstance(obj, dict) else []:
                for k, v in (server.get("headers") or {}).items():
                    if k == "X-CODD-Token":
                        tokens.add(v)
    tokens = {t for t in tokens if isinstance(t, str) and len(t) >= 16}
    leaks, scanned = [], 0
    needles = [t.encode() for t in tokens] + [b"profile-SECRET-PATH-7q"]
    for dirpath, dirnames, filenames in os.walk(tmp):
        if os.path.realpath(dirpath).startswith(os.path.realpath(sdir)):
            continue
        dirnames[:] = [d for d in dirnames if d != ".git"]
        for f in filenames:
            path = os.path.join(dirpath, f)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            try:
                data = read_bytes(path)
            except OSError:
                continue
            scanned += 1
            for needle in needles:
                if needle in data and not (needle == b"profile-SECRET-PATH-7q" and f.endswith(".env")):
                    leaks.append(os.path.relpath(path, tmp))
    check("no token (%d known) and no profile path in any of the %d fixture outputs / logs" % (len(tokens), scanned),
          tokens and not leaks and scanned > 50, leaks[:8])


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
    table = {"png": cmd_png, "notes": cmd_notes, "git": cmd_git, "claude-json": cmd_claude_json, "age-layout": cmd_age_layout,
             "mcp-client": cmd_mcp_client, "fake-claude": cmd_fake_claude, "fake-print": cmd_fake_print, "secrets": cmd_secrets,
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
