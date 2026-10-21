# Generators behind the M4 fixture scripts (docs/M4-PLAN.md C11), run as
# `/usr/bin/python3 -I _m4fix.py <command> …` by make-notes.sh, make-claude-json.sh and
# make-git-project.sh. Python 3.9, standard library only. Every target path is an argument and is
# checked against the protected places first; nothing here touches $HOME, ~/.claude*, ~/.codex or the
# real data root, starts a process or opens a socket. All content is made up (the SPEC §5 sample is
# design data).
#
# Formats written are docs/M4-PLAN.md §3.1-§3.4 exactly (shared with C1, built in parallel):
# notes are Markdown with the §3.2 frontmatter subset; `.codd/state.json`, `.codd/activity.jsonl`,
# `.codd/tombstones.json` and `.codd/notebook.json` are v1. Dates: frontmatter in the anchor's own
# UTC offset (`2026-10-15T10:05:44+08:00`, like §3.2), JSON state files in UTC without fractions
# (`2026-10-15T02:05:44Z`); both are what ISO8601DateFormatter / JSONDecoder.iso8601 read.
import datetime
import hashlib
import importlib.util
import json
import os
import random
import sys
import unicodedata
import uuid

HERE = os.path.dirname(os.path.realpath(__file__))
DAY = datetime.timedelta(days=1)
HOUR = datetime.timedelta(hours=1)
MINUTE = datetime.timedelta(minutes=1)


# ------------------------------------------------------------------------------------------------
# shared helpers

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
    value = os.environ.get("TMPDIR")
    if not value:
        try:
            value = os.confstr(65537)  # _CS_DARWIN_USER_TEMP_DIR
        except (ValueError, OSError):
            value = None
    return os.path.realpath(value or "/tmp")


def _inside(path, base):
    return path == base or path.startswith(base.rstrip("/") + "/")


def protected(path):
    """Why `path` must not be written, or None: inside ~/Library, ~/.claude, ~/.claude.json,
    ~/.claude-swap-backup or ~/.codex (realpath, so links count), or inside ~ outside $TMPDIR."""
    target = os.path.realpath(os.path.abspath(path))
    tmp = _tmpdir()
    for home in _homes():
        for name in ("Library", ".claude", ".claude.json", ".claude-swap-backup", ".codex"):
            if _inside(target, os.path.join(home, name)):
                return "inside ~/" + name
        if _inside(target, home) and not _inside(target, tmp):
            return "inside ~ (outside $TMPDIR)"
    return None


def refuse(tool, path):
    why = protected(path)
    if why:
        print("%s: refusing %s (%s)" % (tool, path, why), file=sys.stderr)
        sys.exit(1)


def usage(tool, text, message=None):
    if message:
        print("%s: %s" % (tool, message), file=sys.stderr)
    print(text.rstrip("\n"), file=sys.stderr)
    sys.exit(2)


def parse_iso(text):
    """ISO 8601 with an offset or Z (fractions allowed); a naive value is local time."""
    t = text.strip()
    if t.endswith("Z") or t.endswith("z"):
        t = t[:-1] + "+00:00"
    if "." in t:
        head, rest = t.split(".", 1)
        digits = ""
        while rest and rest[0].isdigit():
            digits, rest = digits + rest[0], rest[1:]
        t = head + ("." + (digits + "000000")[:6] if digits else "") + rest
    value = datetime.datetime.fromisoformat(t)
    if value.tzinfo is None:
        value = value.astimezone()
    return value


def local_now():
    return datetime.datetime.now().astimezone().replace(microsecond=0)


def fm_date(dt, tz):
    """Frontmatter form: seconds, the anchor's offset (`2026-10-15T10:05:44+08:00`)."""
    s = dt.astimezone(tz).replace(microsecond=0).isoformat()
    return s


def utc_date(dt):
    """JSON state form: UTC seconds with Z (`2026-10-15T02:05:44Z`)."""
    return dt.astimezone(datetime.timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ")


def js_date(dt):
    """CoddCore JSDate.isoString: UTC with milliseconds (`2026-10-15T02:05:44.000Z`)."""
    u = dt.astimezone(datetime.timezone.utc)
    return u.strftime("%Y-%m-%dT%H:%M:%S") + ".%03dZ" % (u.microsecond // 1000)


def makedirs(path):
    """Creates missing folders 0700 (existing ones keep their mode)."""
    missing = []
    p = os.path.abspath(path)
    while not os.path.isdir(p):
        missing.append(p)
        parent = os.path.dirname(p)
        if parent == p:
            break
        p = parent
    for d in reversed(missing):
        os.mkdir(d, 0o700)
        os.chmod(d, 0o700)


def write_atomic(path, data, mode=0o600, mtime=None):
    makedirs(os.path.dirname(os.path.abspath(path)))
    folder = os.path.dirname(os.path.abspath(path))
    tmp = os.path.join(folder, ".%s.%d.tmp" % (os.path.basename(path), os.getpid()))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    os.chmod(tmp, mode)
    os.replace(tmp, path)
    if mtime is not None:
        ts = mtime.timestamp()
        os.utime(path, (ts, ts))


def load_png_module():
    sys.dont_write_bytecode = True  # never leave __pycache__ next to the fixtures
    spec = importlib.util.spec_from_file_location("m4_make_png", os.path.join(HERE, "make-png.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# ------------------------------------------------------------------------------------------------
# notes (make-notes.sh)

NOTES_USAGE = """usage: make-notes.sh <notesDir> [--count N] [--old <ISO now>] [--now <ISO>] [--spec|--no-spec]
                     [--session <uuid>] [--project <path>] [--two-images] [--text-annotation]
                     [--manifest <file>]
  Writes the SPEC §5 notes n1-n7 plus the M4 test notes as docs/M4-PLAN.md §3.2 files into
  <notesDir> (0700), with .codd/{notebook.json,state.json,activity.jsonl,tombstones.json},
  a trashed note and history snapshots. Prints the created ids, one per line.
  --old <now> back-dates the retention cases relative to <now>; --now only anchors the dates.
  Refuses (exit 1) a protected target or a <notesDir> that already holds .md files; exit 2 on
  bad arguments."""

SPEC_PROJECT = "~/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-frontend"
DEFAULT_SESSION = "7c1e9a04-5b3d-4f0e-9a52-3d6c1b2e8f10"   # s9 打卡頁 RWD 調整 (§3.2)
S1_SESSION = "3f6d2a10-8c4e-4b7a-9e21-5d0c7b9a1e01"        # s1 修正登入 API 401
S6_SESSION = "b2e4c6d8-0a1c-4e3f-8a5b-7c9d1e2f3a46"        # s6 產生程式碼審查清單
S11_SESSION = "5e7f9a1b-3c5d-4e6f-8a7b-9c0d1e2f3a11"       # s11 keynote 第 3 章
OFF_SECRET = "OFF-NOTE-SECRET-42"
OFF_TITLE = "不給 AI 的私人紀錄"

ANNOTATIONS = [
    {"n": 1, "type": "rect", "x": 20, "y": 1150, "w": 710, "h": 120,
     "note": "上班打卡按鈕被底部導覽列蓋住 → 改 position: sticky，底部留 env(safe-area-inset-bottom)"},
    {"n": 2, "type": "point", "x": 375, "y": 330, "note": "時鐘數字在 SE 上太大，會擠到下方卡片 → 改 48px"},
    {"n": 3, "type": "arrow", "x": 600, "y": 760, "x2": 700, "y2": 1080, "note": "打卡紀錄卡片離按鈕太近，間距加到 16px"},
]
TEXT_ANNOTATION = {"n": 4, "type": "text", "x": 40, "y": 80, "note": "這段文字直接畫在圖上", "color": "cyan"}

# Generated notes never contain the search words of the fixed table (打卡, 筆記, 注音, RWD, keynote).
GEN_CJK = ["部署", "效能", "快取", "測試", "資料庫", "介面", "元件", "路由", "設定", "版本", "伺服器", "前端",
           "後端", "排程", "備份", "搜尋", "索引", "權限", "帳號", "通知", "報表", "匯出", "上傳", "下載",
           "同步", "監控", "錯誤", "修正", "重構", "文件", "流程", "會議", "需求", "規格", "延遲", "記憶體"]
GEN_ASCII = ["api", "cache", "build", "deploy", "query", "index", "vue", "swift", "sqlite", "trigram",
             "latency", "p95", "docker", "queue", "worker", "router", "schema", "migration", "lint", "release"]
GEN_PUNCT = ["，", "。", "；", "、", "：", "（", "）"]


def yaml_scalar(value):
    """A scalar the §3.2 subset reads back unchanged: plain unless it needs double quotes."""
    s = str(value)
    if s == "" or s != s.strip() or any(c in s for c in ",[]{}\"'#") or ": " in s or s.endswith(":") \
            or s[0] in "-?!&*|>%@`" or s.lower() in ("true", "false", "null", "yes", "no", "~"):
        return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return s


def yaml_list(values):
    return "[" + ", ".join(yaml_scalar(v) for v in values) + "]"


class Note:
    """One note file plus its app state (§3.4 state.json entry) and assets."""

    def __init__(self, nid, title, kind, path, body, ai="read", scope="global", tags=(), sessions=(), projects=(),
                 pinned=False, activity=None, created=None, open_count=1, eol="\n", style="default"):
        self.id = nid
        self.title = title
        self.kind = kind
        self.path = path            # relative to the notes folder (or to .codd/trash for a trashed note)
        self.body = body            # LF text starting with the H1
        self.ai = ai
        self.scope = scope
        self.tags = list(tags)
        self.sessions = list(sessions)
        self.projects = list(projects)
        self.pinned = pinned
        self.status = "active"
        self.archived = None
        self.archived_by = None
        self.sent = None
        self.sent_to = None
        self.trashed = None
        self.activity = activity    # last user activity (= updated, the file mtime, state.json)
        self.created = created
        self.open_count = open_count
        self.eol = eol
        self.style = style          # default | yaml-subset | none
        self.assets = []            # (relative path from the notes folder, w, h, phone, seed, mtime or None)
        self.history = []           # (datetime, text)

    @property
    def updated(self):
        return self.activity if self.sent is None else min(self.activity, self.sent - 10 * MINUTE)

    def frontmatter(self, tz):
        if self.style == "none":
            return ""
        lines = ["---"]
        if self.style == "yaml-subset":
            lines.append("# 這行是註解：CODD 必須原樣保留")
        lines.append("id: " + self.id)
        lines.append("title: " + (('"%s"' % self.title) if self.style == "yaml-subset" else yaml_scalar(self.title)))
        lines.append("kind: " + self.kind)
        if self.tags:
            if self.style == "yaml-subset":
                lines.append("tags:")
                lines.extend("  - " + yaml_scalar(t) for t in self.tags)
            else:
                lines.append("tags: " + yaml_list(self.tags))
        if self.sessions:
            lines.append("sessions: " + yaml_list(self.sessions))
        if self.projects:
            lines.append("projects: " + yaml_list(self.projects))
        lines.append("ai: " + self.ai)
        lines.append("scope: " + self.scope)
        lines.append("pinned: " + ("true" if self.pinned else "false"))
        lines.append("status: " + self.status)
        if self.archived is not None:
            lines.append("archived: " + fm_date(self.archived, tz))
            lines.append("archivedBy: " + self.archived_by)
        if self.sent is not None:
            lines.append("sent: " + fm_date(self.sent, tz))
            lines.append("sentTo: " + self.sent_to)
        if self.style == "yaml-subset":
            lines.append("customKey: 保留我")
            lines.append("quoted: '單引號字串'")
        lines.append("created: " + fm_date(self.created, tz))
        lines.append("updated: " + fm_date(self.updated, tz))
        if self.trashed is not None:
            lines.append("trashed: " + fm_date(self.trashed, tz))
        lines.append("---")
        return "\n".join(lines) + "\n"

    def text(self, tz):
        content = self.frontmatter(tz) + self.body
        if self.eol != "\n":
            content = content.replace("\n", self.eol)
        return content


def annotation_block(image, items):
    data = {"v": 1, "image": image, "size": [750, 1334], "items": items,
            "send": {"original": False, "annotated": True, "list": True}}
    return "```codd-annotations\n" + json.dumps(data, ensure_ascii=False, separators=(",", ":")) + "\n```\n"


def n1_body(two_images, text_annotation):
    items = ANNOTATIONS + ([TEXT_ANNOTATION] if text_annotation else [])
    body = ("# 打卡頁 RWD 跑版紀錄\n\n"
            "## 問題\n"
            "iPhone SE（375×667）下打卡按鈕被底部導覽列蓋住；橫向時表格溢出。\n\n"
            "- 影響頁面：`/punch`（打卡）與 `/punch/history`（打卡紀錄表格）\n"
            "- **Safari 底部工具列展開時**才會完全蓋住，收起後還露出上半截\n\n"
            "![截圖 2026-10-15 09:32 · iPhone SE](assets/rwd-punch-k7x2/9f3a1c.png)\n"
            + annotation_block("assets/rwd-punch-k7x2/9f3a1c.png", items))
    if two_images:
        body += "\n![截圖 2026-10-15 09:35 · 橫向](assets/rwd-punch-k7x2/2b7e04.png)\n"
    body += ("\n## 想請 AI 做的\n"
             "- [x] 先重現（Chrome DevTools 375 寬）\n"
             "- [ ] 按鈕改 `position: sticky; bottom: env(safe-area-inset-bottom)`\n"
             "- [ ] 表格改卡片式（<640px）\n\n"
             "```css\n"
             "@media (max-width: 640px) {\n"
             "  .punch-table { display: block; }\n"
             "}\n"
             "```\n")
    return body


def daily_log_body(now, tz):
    """12 dated H2 sections: 9 older than 30 days (7 as YYYY-MM-DD, one M/DD, one MM/DD) and 3 newer."""
    old = [31, 33, 36, 39, 42, 45, 48, 52, 58]
    new = [1, 4, 9]
    sections = []
    for i, days in enumerate(sorted(old + new)):
        d = (now - days * DAY).astimezone(tz)
        if days == 45:
            head = "%d/%02d" % (d.month, d.day)
        elif days == 52:
            head = "%02d/%02d" % (d.month, d.day)
        else:
            head = d.strftime("%Y-%m-%d")
        sections.append((days, head))
    out = ["# 每日工作日誌", "", "每天下班前寫三行：做了什麼、卡在哪、明天先做什麼。", ""]
    tasks = ["整理 PR 評論", "修 CI 快取", "補單元測試", "更新部署文件", "和設計師對齊間距", "排查記憶體用量",
             "重寫匯出流程", "清理舊分支", "準備週會報告", "調整排程時間", "審查權限設定", "整理需求清單"]
    for i, (days, head) in enumerate(sorted(sections, key=lambda s: -s[0])):
        out += ["## %s" % head, "- 做了：%s" % tasks[i % len(tasks)], "- 卡在：等待回覆",
                "- 明天：%s" % tasks[(i + 1) % len(tasks)], ""]
    return "\n".join(out)


def gen_note(i, now, tz, rnd):
    word = GEN_CJK[i % len(GEN_CJK)]
    nid = "gen-%05d" % i
    title = "生成資料 %05d · %s" % (i, word)
    parts = ["# " + title, "", "效能 部署 資料庫：第 %d 則產生的效能測試資料。" % i, ""]
    size = len("\n".join(parts).encode("utf-8"))
    section = 0
    while size < 3900:
        section += 1
        sentence = []
        for _ in range(rnd.randint(14, 26)):
            if rnd.random() < 0.3:
                sentence.append(" %s " % rnd.choice(GEN_ASCII))
            else:
                sentence.append(rnd.choice(GEN_CJK))
            if rnd.random() < 0.15:
                sentence.append(rnd.choice(GEN_PUNCT))
        line = "".join(sentence).strip() + "。"
        if section % 4 == 1:
            parts += ["## 段落 %d" % (section // 4 + 1)]
        parts.append(line)
        parts.append("")
        size += len(line.encode("utf-8")) + 2
    activity = now - datetime.timedelta(hours=(i % 240) + 1)
    note = Note(nid, title, "note", "generated/生成資料-%05d.md" % i, "\n".join(parts) + "\n",
                ai="read", scope="global", tags=["gen", "perf"], activity=activity, created=activity - 2 * HOUR)
    return note


def build_notes(now, tz, old, session, project, two_images, text_annotation, spec):
    """(notes, trashed note, tombstones, activity events, extra assets) relative to `now`."""
    notes = []

    def add(note):
        notes.append(note)
        return note

    if not spec:
        return notes, None, [], [], []
    linked = session or DEFAULT_SESSION
    n4_session = session or S6_SESSION
    proj = project or SPEC_PROJECT

    def age(recent, aged):
        return now - (aged if old else recent)

    n1 = add(Note("rwd-punch-k7x2", "打卡頁 RWD 跑版紀錄", "note", "2026-10-15-打卡頁-rwd-跑版紀錄.md",
                  n1_body(two_images, text_annotation), ai="read", scope="project", tags=["rwd", "punch"],
                  sessions=[linked], projects=[proj], activity=now - 2 * HOUR, open_count=12))
    n1.created = n1.activity - (15 * HOUR + 45 * MINUTE + datetime.timedelta(seconds=33))
    n1.assets.append(("assets/rwd-punch-k7x2/9f3a1c.png", 750, 1334, True, 0, None))
    if two_images:
        n1.assets.append(("assets/rwd-punch-k7x2/2b7e04.png", 1334, 750, False, 7, None))
    n1.history = [(n1.activity - 24 * MINUTE, n1_body(False, False).replace("- [x] 先重現", "- [ ] 先重現")),
                  (n1.activity - 15 * HOUR - 45 * MINUTE, "# 打卡頁 RWD 跑版紀錄\n\n## 問題\niPhone SE 下打卡按鈕被蓋住。\n")]

    n2 = add(Note("prompt-401-b3m9", "給後端的 prompt：401 修正條件", "prompt",
                  "2026-10-15-給後端的-prompt-401-修正條件.md",
                  "# 給後端的 prompt：401 修正條件\n\n"
                  "請檢查 `auth.spec.ts` 裡 refresh token 過期時的 401 判斷：\n"
                  "- access token 過期但 refresh token 有效 → 自動換發，不回 401\n"
                  "- refresh token 也過期 → 回 401，前端導回登入頁\n",
                  ai="read", scope="project", sessions=[S1_SESSION],
                  projects=["~/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-backend"]))
    n2.sent = age(3 * HOUR, 8 * DAY + HOUR)
    n2.sent_to = S1_SESSION
    n2.activity = n2.sent
    n2.created = n2.sent - 40 * MINUTE

    add(Note("mcp-demo-r8q1", "MCP 示範腳本重點", "note", "2026-10-10-mcp-示範腳本重點.md",
             "# MCP 示範腳本重點\n\n## 重點\n1. 先示範 `claude mcp list`\n2. 再連線整合範例的 server\n"
             "3. 最後展示 notes_search 的搜尋結果\n",
             ai="read", scope="project", tags=["mcp", "demo"],
             projects=["~/Project/Northstar/lab/agent-lab-2026/整合範例/MCP"], pinned=True,
             activity=age(DAY, 40 * DAY + HOUR)))

    add(Note("v2-review-h4n6", "程式碼審查標準 v2", "note", "2026-10-12-程式碼審查標準-v2.md",
             "# 程式碼審查標準 v2\n\n## 審查項目\n| 項目 | 檢查重點 |\n|---|---|\n| 需求理解 | 每條需求都有對應的改動 |\n"
             "| 錯誤處理 | 失敗時有明確的回應 |\n| 驗證方式 | 附測試或重現步驟 |\n| 文件 | 改動寫進說明 |\n",
             ai="read", scope="project", tags=["review"], sessions=[n4_session],
             projects=["~/Project/Northstar/lab/agent-lab-2026/原型試做"],
             activity=age(DAY + 2 * HOUR, 35 * DAY + HOUR)))

    add(Note("quick-scratch-s5c2", "隨手記 10/15", "scratch", "2026-10-15-隨手記-10-15.md",
             "# 隨手記 10/15\n\n- 問一下設計師底部導覽列高度\n- 午餐前把 PR 開出去\n",
             ai="read", scope="global", activity=age(2 * HOUR + 30 * MINUTE, 8 * DAY + HOUR)))

    keynote = ("請依照下面的大綱產生投影片草稿，每頁一個重點，語氣口語：\n"
               "- 開場：為什麼要用 Pencil 做簡報\n"
               "- 第一段：版面網格與字級系統\n"
               "- 第二段：元件庫與主題色\n"
               "- 第三段：匯出 PDF 與講者備忘稿\n"
               "- 結尾：常見問題與下一步\n"
               "每一頁都附上一句講者備忘，控制在三十字以內。\n")
    add(Note("keynote-p6d1", "keynote 第 3 章大綱", "prompt", "2026-10-13-keynote-第-3-章大綱.md",
             "# keynote 第 3 章大綱\n\n" + keynote, ai="read", scope="project", sessions=[S11_SESSION],
             projects=["~/Github/keynote-deck"], activity=now - 2 * DAY))

    n7 = add(Note("gear3d-n7q0", "Gear3D 載入效能想法", "note", "2026-09-24-gear3d-載入效能想法.md",
                  "# Gear3D 載入效能想法\n\n## 想法\n- 場景切塊延遲載入\n- 貼圖改 KTX2\n- 先量測再優化\n",
                  ai="read", scope="project", projects=["~/Github/Gear3D"],
                  activity=age(DAY + 5 * HOUR, 21 * DAY + 3 * HOUR)))
    n7.assets.append(("assets/gear3d-n7q0/7e8f90.png", 320, 200, False, 5, age(DAY, 12 * DAY)))

    add(Note("ai-append-note", "AI 附加測試", "note", "2026-10-16-ai-附加測試.md",
             "# AI 附加測試\n\n## 紀錄\n- 初始內容（AI 可以在最後附加）\n", ai="append", scope="global",
             tags=["mcp"], activity=now - DAY))
    add(Note("ai-off-note", OFF_TITLE, "note", "2026-10-16-不給-ai-的私人紀錄.md",
             "# %s\n\n這則紀錄的 AI 存取是 OFF，MCP、引用展開與網址都不提供。\n\n%s\n" % (OFF_TITLE, OFF_SECRET),
             ai="off", scope="global", activity=now - DAY - HOUR))
    add(Note("global-note", "全域：常用指令", "note", "2026-10-16-全域-常用指令.md",
             "# 全域：常用指令\n\n## 常用指令\n- `npm run dev`\n- `git status --short`\n",
             ai="read", scope="global", tags=["shell"], activity=now - DAY - 2 * HOUR))
    add(Note("cjk-search-note", "注音輸入法筆記", "note", "2026-10-16-注音輸入法筆記.md",
             "# 注音輸入法筆記\n\n注音輸入法在 macOS 上選字時按 Enter 才確定；組字中不能自動儲存。\n"
             "這裡也提到打卡兩個字，給短詞搜尋用。\n",
             ai="read", scope="global", tags=["ime"], activity=now - 3 * HOUR))
    add(Note("subfolder-note", "子資料夾裡的待辦", "note", "work/2026-10-12-子資料夾裡的待辦.md",
             "# 子資料夾裡的待辦\n\n- [ ] 這一則放在 work/ 子資料夾\n- [ ] 一樣要被索引\n",
             ai="read", scope="global", activity=now - 2 * DAY))
    add(Note("crlf-note", "Windows 換行測試", "note", "2026-10-16-windows-換行測試.md",
             "# Windows 換行測試\n\n這個檔案整份都是 CRLF 換行，儲存後要保持 CRLF。\n- 第一項\n- 第二項\n",
             ai="read", scope="global", activity=now - 2 * DAY - HOUR, eol="\r\n"))
    add(Note("daily-log-d9w1", "每日工作日誌", "note", "2026-08-01-每日工作日誌.md", daily_log_body(now, tz),
             ai="read", scope="global", tags=["log"], activity=now - DAY))
    add(Note("keynote-ch2-k2d8", "keynote 第 2 章大綱", "note", "2026-10-12-keynote-第-2-章大綱.md",
             "# keynote 第 2 章大綱\n\n" + keynote.replace("- 第三段：匯出 PDF 與講者備忘稿", "- 第三段：匯出 PNG 與講者備忘稿"),
             ai="read", scope="project", projects=["~/Github/keynote-deck"], activity=now - 3 * DAY))
    add(Note("old-review-r30d", "舊審查清單草稿", "note", "2026-09-15-舊審查清單草稿.md",
             "# 舊審查清單草稿\n\n- 舊版項目：程式碼風格、可讀性\n", ai="read", scope="global",
             activity=age(2 * DAY, 30 * DAY + 2 * HOUR)))
    add(Note("yaml-subset-note", "YAML 子集測試", "note", "2026-10-11-yaml-子集測試.md",
             "# YAML 子集測試\n\n這一則的 frontmatter 有註解、引號字串、區塊清單與未知鍵，CODD 只改它懂的那一行。\n",
             ai="read", scope="global", tags=["yaml", "測試"], activity=now - 3 * DAY, style="yaml-subset"))
    archived = add(Note("archived-login-a1z9", "已封存：舊版登入流程", "note", "2026-09-01-已封存-舊版登入流程.md",
                        "# 已封存：舊版登入流程\n\n## 流程\n1. 輸入帳號密碼\n2. 取得 session cookie\n",
                        ai="read", scope="global", activity=now - 20 * DAY))
    archived.status = "archived"
    archived.archived = now - 5 * DAY
    archived.archived_by = "user"
    add(Note("nofm", "從別處拖進來的 Markdown", "note", "從別處拖進來.md",
             "# 從別處拖進來的 Markdown\n\n這個檔案沒有 frontmatter，是使用者自己丟進資料夾的。\n",
             activity=now - 4 * DAY, style="none"))

    for n in notes:
        if n.created is None:
            n.created = n.updated - 6 * HOUR

    trashed = Note("trashed-idea-t3x1", "已丟掉的舊想法", "note", "2026-09-10-已丟掉的舊想法.md",
                   "# 已丟掉的舊想法\n\n這個想法不做了。\n\n![草圖](assets/trashed-idea-t3x1/1a2b3c.png)\n",
                   ai="read", scope="global")
    trashed.trashed = age(2 * DAY, 31 * DAY + HOUR)
    trashed.activity = trashed.trashed - 3 * DAY
    trashed.created = trashed.activity - DAY
    trashed.assets.append((".codd/trash/assets/trashed-idea-t3x1/1a2b3c.png", 64, 64, False, 3, None))
    trashed.history = [(trashed.activity, trashed.body)]

    tombstones = [{"id": "gone-note-g0n3", "title": "很久以前刪掉的筆記", "trashedAt": utc_date(now - 40 * DAY),
                   "purgedAt": utc_date(now - 10 * DAY)}]
    events = [
        {"v": 1, "at": utc_date(n1.activity + 7 * MINUTE), "note": "rwd-punch-k7x2", "action": "read",
         "client": "Claude Code", "session": linked, "sessionTitle": "打卡頁 RWD 調整", "via": "mcp"},
        {"v": 1, "at": utc_date(now - 2 * DAY - HOUR), "note": "gear3d-n7q0", "action": "read",
         "client": "Claude Code", "session": None, "sessionTitle": None, "via": "mcp"},
    ]
    return notes, trashed, tombstones, events, []


def expectations(notes, old):
    """What CODD should show for these notes (README tables; the self test re-derives them)."""
    active = [n for n in notes if n.status == "active"]
    ids = lambda xs: [n.id for n in xs if n.style != "none"]  # noqa: E731 - small local helper
    exp = {
        "counts": {"inbox": len(active), "pinned": len([n for n in active if n.pinned]),
                   "prompts": len([n for n in active if n.kind == "prompt"]),
                   "archive": len([n for n in notes if n.status == "archived"]), "trash": 1},
        "search": {
            "打卡頁": ["rwd-punch-k7x2"],
            "打卡": ["rwd-punch-k7x2", "cjk-search-note"],
            "筆記": ["cjk-search-note"],
            "注音輸入法": ["cjk-search-note"],
            "#rwd": ["rwd-punch-k7x2"],
            "RWD 打卡": ["rwd-punch-k7x2"],
            OFF_SECRET: ["ai-off-note"],
        },
        "mcpInvisible": ["ai-off-note"],
        "appendable": ["ai-append-note"],
        "longNote": {"id": "daily-log-d9w1", "datedSections": 12, "olderThan30d": 9},
        "nearDuplicate": {"older": "keynote-ch2-k2d8", "of": "keynote-p6d1"},
        "trashed": "trashed-idea-t3x1",
        "tombstone": "gone-note-g0n3",
        "noFrontmatter": [n.path for n in notes if n.style == "none"],
    }
    if old:
        # Default policy (stale 14 d, archive 30 d, SCRATCH / sent PROMPT 7 d, purge 30 d, exemptions ON).
        exp["retention"] = {
            "staleBeforeRun": ["gear3d-n7q0", "old-review-r30d"],
            "staleBeforeRunUnlessLinkedSessionLive": ["v2-review-h4n6"],
            "staleAfterRun": ["gear3d-n7q0"],
            "archivedByRun": ["old-review-r30d", "quick-scratch-s5c2", "prompt-401-b3m9"],
            "archivedByRunUnlessLinkedSessionLive": ["v2-review-h4n6"],
            "keptByRun": ["mcp-demo-r8q1", "gear3d-n7q0"],
            "purgedByRun": ["trashed-idea-t3x1"],
            "unusedAsset": "assets/gear3d-n7q0/7e8f90.png",
        }
    exp["ids"] = ids(notes)
    return exp


def cmd_notes(argv):
    tool = "make-notes"
    pos, count, old, anchor, spec = [], 0, False, None, True
    session = project = manifest = None
    two_images = text_annotation = False
    i = 0
    while i < len(argv):
        a = argv[i]

        def value():
            if i + 1 >= len(argv):
                usage(tool, NOTES_USAGE, "%s needs a value" % a)
            return argv[i + 1]

        if a == "--count":
            try:
                count = int(value())
            except ValueError:
                usage(tool, NOTES_USAGE, "--count must be an integer")
            if not 0 <= count <= 100000:
                usage(tool, NOTES_USAGE, "--count must be 0...100000")
            i += 1
        elif a in ("--old", "--now"):
            try:
                anchor = parse_iso(value())
            except ValueError:
                usage(tool, NOTES_USAGE, "%s needs an ISO 8601 date" % a)
            old = old or a == "--old"
            i += 1
        elif a == "--spec":
            spec = True
        elif a == "--no-spec":
            spec = False
        elif a == "--session":
            session = value().lower()
            try:
                uuid.UUID(session)
            except ValueError:
                usage(tool, NOTES_USAGE, "--session must be a UUID")
            i += 1
        elif a == "--project":
            project = value()
            if not project:
                usage(tool, NOTES_USAGE, "--project must not be empty")
            i += 1
        elif a == "--manifest":
            manifest = value()
            i += 1
        elif a == "--two-images":
            two_images = True
        elif a == "--text-annotation":
            text_annotation = True
        elif a.startswith("-") and a != "-":
            usage(tool, NOTES_USAGE, "unknown option " + a)
        else:
            pos.append(a)
        i += 1
    if len(pos) != 1 or not pos[0]:
        usage(tool, NOTES_USAGE)
    root = os.path.abspath(pos[0])
    refuse(tool, root)
    if manifest:
        refuse(tool, manifest)
    if os.path.isdir(root):
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if not d.startswith(".")]
            if any(f.endswith(".md") for f in filenames):
                print("%s: %s already holds notes; refusing" % (tool, root), file=sys.stderr)
                sys.exit(1)
    now = (anchor or local_now()).replace(microsecond=0)
    tz = now.tzinfo
    notes, trashed, tombstones, events, _ = build_notes(now, tz, old, session, project, two_images,
                                                        text_annotation, spec)
    rnd = random.Random(20261017)
    generated = [gen_note(k + 1, now, tz, rnd) for k in range(count)]
    png = load_png_module()

    makedirs(root)
    os.chmod(root, 0o700)
    codd = os.path.join(root, ".codd")
    makedirs(codd)
    write_atomic(os.path.join(codd, "notebook.json"),
                 json.dumps({"v": 1, "createdAt": utc_date(now - 60 * DAY)}, separators=(",", ":")).encode())
    state = {}
    for n in notes + generated:
        write_atomic(os.path.join(root, n.path), unicodedata.normalize("NFC", n.text(tz)).encode("utf-8"),
                     mtime=n.updated)
        if n.style != "none":
            state[n.id] = {"lastOpenedAt": utc_date(n.activity), "openCount": n.open_count,
                           "lastUserActivityAt": utc_date(n.activity), "keepUntil": None}
        for rel, w, h, phone, seed, mtime in n.assets:
            path = os.path.join(root, rel)
            png.write_png(path, w, h, phone=phone, seed=seed)
            stamp = (mtime or n.updated).timestamp()
            os.utime(path, (stamp, stamp))
        for at, text in n.history:
            write_snapshot(codd, n.id, at, text)
    if trashed is not None:
        write_atomic(os.path.join(codd, "trash", trashed.path), trashed.text(tz).encode("utf-8"), mtime=trashed.trashed)
        state[trashed.id] = {"lastOpenedAt": utc_date(trashed.activity), "openCount": 2,
                             "lastUserActivityAt": utc_date(trashed.activity), "keepUntil": None}
        for rel, w, h, phone, seed, mtime in trashed.assets:
            path = os.path.join(root, rel)
            png.write_png(path, w, h, phone=phone, seed=seed)
            os.utime(path, (trashed.activity.timestamp(), trashed.activity.timestamp()))
        for at, text in trashed.history:
            write_snapshot(codd, trashed.id, at, text)
    write_atomic(os.path.join(codd, "state.json"),
                 json.dumps({"v": 1, "notes": state}, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
    write_atomic(os.path.join(codd, "activity.jsonl"),
                 "".join(json.dumps(e, ensure_ascii=False, separators=(",", ":")) + "\n" for e in events).encode("utf-8"))
    write_atomic(os.path.join(codd, "tombstones.json"),
                 json.dumps({"v": 1, "items": tombstones}, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))

    printed = [n.id for n in notes if n.style != "none"] + ([trashed.id] if trashed else []) + [n.id for n in generated]
    if manifest:
        exp = expectations(notes, old) if spec else {}
        doc = {"notesDir": root, "now": fm_date(now, tz), "old": old, "session": session or DEFAULT_SESSION,
               "project": project or SPEC_PROJECT, "count": count, "expect": exp, "notes": []}
        for n in notes + ([trashed] if trashed else []) + generated:
            doc["notes"].append({
                "id": None if n.style == "none" else n.id, "title": n.title, "kind": n.kind, "ai": n.ai,
                "scope": n.scope, "pinned": n.pinned, "status": n.status,
                "path": (".codd/trash/" + n.path) if n is trashed else n.path,
                "tags": n.tags, "sessions": n.sessions, "projects": n.projects,
                "updated": fm_date(n.updated, tz), "activity": fm_date(n.activity, tz),
                "sent": fm_date(n.sent, tz) if n.sent else None,
                "archived": fm_date(n.archived, tz) if n.archived else None,
                "trashed": fm_date(n.trashed, tz) if n.trashed else None,
                "assets": [a[0] for a in n.assets], "eol": "crlf" if n.eol != "\n" else "lf",
                "frontmatter": n.style})
        write_atomic(os.path.abspath(manifest), (json.dumps(doc, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))
    sys.stdout.write("".join(p + "\n" for p in printed))


def write_snapshot(codd, nid, at, text):
    stamp = at.astimezone(datetime.timezone.utc)
    name = stamp.strftime("%Y%m%d-%H%M%S-") + "%03d" % (stamp.microsecond // 1000)
    data = text.encode("utf-8")
    name += "-" + hashlib.sha256(data).hexdigest()[:8] + ".md"
    write_atomic(os.path.join(codd, "history", nid, name), data, mtime=at)


# ------------------------------------------------------------------------------------------------
# fake ~/.claude.json (make-claude-json.sh)

CLAUDE_JSON_USAGE = """usage: make-claude-json.sh <file> [--codd-foreign | --codd-ours <url> <token|@config.json>]
                          [--no-mcp-servers] [--project <cwd>]... [--project-codd <cwd>]...
                          [--extra-projects N] [--force]
  Writes a made-up ~/.claude.json-shaped file laid out like JSON.stringify(x, null, 2) (no final
  newline, mode 0600). Prints <file>. Refuses a protected target or an existing file (--force
  replaces it); exit 2 on bad arguments."""


class RawNumber(str):
    """A JSON number token written exactly as given (`1e21`, `-0`, `1.0`)."""


def stringify(value, indent=""):
    """JSON.stringify(value, null, 2)."""
    inner = indent + "  "
    if isinstance(value, RawNumber):
        return str(value)
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        raise TypeError("use RawNumber for non-integer numbers")
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list):
        if not value:
            return "[]"
        return "[\n" + ",\n".join(inner + stringify(v, inner) for v in value) + "\n" + indent + "]"
    if isinstance(value, dict):
        if not value:
            return "{}"
        return "{\n" + ",\n".join(inner + json.dumps(k, ensure_ascii=False) + ": " + stringify(v, inner)
                                    for k, v in value.items()) + "\n" + indent + "}"
    raise TypeError(type(value))


def claude_project(name, servers, cost):
    return {
        "allowedTools": [],
        "mcpContextUris": [],
        "mcpServers": servers,
        "enabledMcpjsonServers": [],
        "disabledMcpjsonServers": [],
        "hasTrustDialogAccepted": True,
        "projectOnboardingSeenCount": 3,
        "hasClaudeMdExternalIncludesApproved": False,
        "hasClaudeMdExternalIncludesWarningShown": False,
        "lastCost": RawNumber(cost),
        "lastAPIDuration": 182345,
        "lastDuration": 905112,
        "lastLinesAdded": 42,
        "lastLinesRemoved": 7,
        "lastTotalInputTokens": 120394,
        "lastTotalOutputTokens": 8812,
        "lastSessionName": name,
        "exampleFiles": ["src/pages/punch.vue", "src/components/PunchButton.vue"],
    }


def build_claude_json(foreign, ours, no_servers, projects, project_codd, extra):
    top_servers = {
        "pencil-like": {"type": "stdio", "command": "/opt/fixture/bin/pencil-like-mcp", "args": ["--stdio"], "env": {}},
        "stitch-like": {"type": "http", "url": "https://stitch-like.invalid/mcp",
                        "headers": {"X-Fixture-Api-Key": "${STITCH_LIKE_KEY}"}},
    }
    if foreign:
        top_servers["codd"] = {"type": "stdio", "command": "/opt/fixture/bin/codd-like-mcp", "args": ["serve"], "env": {}}
    if ours:
        top_servers["codd"] = {"type": "http", "url": ours[0], "headers": {"X-CODD-Token": ours[1]}}
    proj = {
        "/Users/fixture/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-frontend":
            claude_project("打卡頁 RWD 調整", {"playwright-like": {"type": "stdio", "command": "npx",
                                                               "args": ["-y", "@fixture/playwright-like-mcp"], "env": {}}},
                           "1.0"),
        "/Users/fixture/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-backend":
            claude_project("修正登入 API 401", {}, "2.14"),
        "/Users/fixture/Project/Northstar/lab/agent-lab-2026/原型試做":
            claude_project("第二版原型 · 審查流程", {"原型-db": {"type": "stdio", "command": "/opt/fixture/bin/db-mcp",
                                                         "args": ["--readonly"], "env": {"DB_NAME": "原型"}}}, "0.41"),
        "/Users/fixture/Github/Gear3D": claude_project("場景載入優化", {}, "4.8"),
    }
    for k in range(extra):
        proj["/Users/fixture/Generated/project-%04d" % k] = claude_project("產生的專案 %d" % k, {}, "0.%02d" % (k % 100))
    for cwd in projects:
        proj[cwd] = claude_project("fixture project", {"local-db": {"type": "stdio", "command": "/opt/fixture/bin/local-db",
                                                                   "args": [], "env": {}}}, "0.5")
    for cwd in project_codd:
        entry = proj.get(cwd) or claude_project("fixture project", {}, "0.5")
        servers = dict(entry["mcpServers"])
        servers["codd"] = {"type": "stdio", "command": "/opt/fixture/bin/project-codd-mcp", "args": [], "env": {}}
        entry["mcpServers"] = servers
        proj[cwd] = entry
    doc = {
        "numStartups": 412,
        "installMethod": "native",
        "autoUpdates": False,
        "theme": "dark",
        "tipsHistory": {"new-user-warmup": 7, "memory-command": 31, "shift-enter": 12},
        "promptQueueUseCount": 9,
        "userID": "fixture-user-0000",
        "firstStartTime": "2026-03-02T01:23:45.678Z",
        "projects": proj,
    }
    if not no_servers:
        doc["mcpServers"] = top_servers
    doc.update({
        "oauthAccount": {"accountUuid": "a3000000-0000-4000-8000-000000000003", "emailAddress": "work@example.com",
                         "organizationUuid": "", "organizationName": "", "organizationRateLimitTier": "default_claude_max_20x",
                         "organizationType": "claude_max"},
        "hasCompletedOnboarding": True,
        "lastOnboardingVersion": "2.1.302",
        "cachedGrowthBookFeatures": {
            "fixture_big_int": RawNumber("12345678901234567890"),
            "fixture_exp": RawNumber("1e21"),
            "fixture_neg_zero": RawNumber("-0"),
            "fixture_float_one": RawNumber("1.0"),
            "fixture_small": RawNumber("1.5e-7"),
            "fixture_nested": [[1, [2, []]], {}, {"深層": ["值", None, True]}],
        },
        "fixtureStrings": {"cjk": "打卡頁 RWD 調整", "escapes": "quote \" backslash \\ tab \t newline \n",
                           "slash": "a/b", "ls": "line separator"},
        "subscriptionNoticeCount": 0,
    })
    return doc


def cmd_claude_json(argv):
    tool = "make-claude-json"
    pos, foreign, ours, no_servers, force, extra = [], False, None, False, False, 0
    projects, project_codd = [], []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--codd-foreign":
            foreign = True
        elif a == "--codd-ours":
            if i + 2 >= len(argv):
                usage(tool, CLAUDE_JSON_USAGE, "--codd-ours needs <url> <token>")
            ours = [argv[i + 1], argv[i + 2]]
            i += 2
        elif a == "--no-mcp-servers":
            no_servers = True
        elif a == "--force":
            force = True
        elif a in ("--project", "--project-codd"):
            if i + 1 >= len(argv) or not argv[i + 1]:
                usage(tool, CLAUDE_JSON_USAGE, "%s needs a path" % a)
            (projects if a == "--project" else project_codd).append(argv[i + 1])
            i += 1
        elif a == "--extra-projects":
            try:
                extra = int(argv[i + 1]) if i + 1 < len(argv) else -1
            except ValueError:
                extra = -1
            if not 0 <= extra <= 100000:
                usage(tool, CLAUDE_JSON_USAGE, "--extra-projects must be 0...100000")
            i += 1
        elif a.startswith("-") and a != "-":
            usage(tool, CLAUDE_JSON_USAGE, "unknown option " + a)
        else:
            pos.append(a)
        i += 1
    if len(pos) != 1 or not pos[0]:
        usage(tool, CLAUDE_JSON_USAGE)
    if foreign and ours:
        usage(tool, CLAUDE_JSON_USAGE, "--codd-foreign and --codd-ours exclude each other")
    if no_servers and (foreign or ours):
        usage(tool, CLAUDE_JSON_USAGE, "--no-mcp-servers cannot carry a codd entry")
    path = os.path.abspath(pos[0])
    refuse(tool, path)
    if ours:
        url, token = ours
        if token.startswith("@"):
            src = token[1:]
            refuse(tool, src)
            try:
                with open(src, "r", encoding="utf-8") as f:
                    token = json.load(f).get("mcpToken")
            except (OSError, ValueError, AttributeError):
                token = None
            if not isinstance(token, str) or not token:
                print("%s: %s has no mcpToken" % (tool, src), file=sys.stderr)
                sys.exit(1)
        if not url.startswith("http://127.0.0.1:") and not url.startswith("http://localhost:"):
            usage(tool, CLAUDE_JSON_USAGE, "--codd-ours url must be http://127.0.0.1:<port>/mcp")
        ours = [url, token]
    if os.path.lexists(path) and not force:
        print("%s: %s already exists; refusing (use --force)" % (tool, path), file=sys.stderr)
        sys.exit(1)
    doc = build_claude_json(foreign, ours, no_servers, projects, project_codd, extra)
    write_atomic(path, stringify(doc).encode("utf-8"))
    print(path)


# ------------------------------------------------------------------------------------------------
# git project trees (make-git-project.sh)

PUNCH_HEAD_STYLE = ["  position: fixed;", "  bottom: 0;"]
PUNCH_AI_STYLE = ["  position: sticky;", "  bottom: env(safe-area-inset-bottom);",
                  "  margin-bottom: 64px; /* 底部導覽列高度 */", "  z-index: 10;"]


def punch_vue(style_lines):
    lines = [
        "<script setup>",
        "import { computed, onMounted } from 'vue'",
        "import { useBreakpoints } from '@vueuse/core'",
        "import PunchButton from '@/components/PunchButton.vue'",
        "import PunchRecordCard from '@/components/PunchRecordCard.vue'",
        "import { usePunchStore } from '@/stores/punch'",
        "",
        "const store = usePunchStore()",
        "const breakpoints = useBreakpoints({ sm: 640 })",
        "const isNarrow = breakpoints.smaller('sm')",
        "const records = computed(() => store.todayRecords)",
        "",
        "onMounted(() => store.fetchToday())",                                       # 13
        "</script>",
        "",
        "<template>",
        '  <main class="punch-page">',
        '    <header class="punch-head">',
        '      <h1 class="text-lg font-bold">今日打卡</h1>',
        '      <span class="text-sm text-stone-500">{{ store.todayLabel }}</span>',
        "    </header>",
        '    <template v-if="isNarrow">',
        '      <PunchRecordCard v-for="r in records" :key="r.id" :record="r" />',
        "    </template>",
        '    <table v-else class="punch-table">',
        '      <tr v-for="r in records" :key="r.id">',
        "        <td>{{ r.typeLabel }}</td>",
        '        <td class="tabular-nums">{{ r.time }}</td>',
        '        <td class="truncate">{{ r.location }}</td>',
        "      </tr>",
        "    </table>",
        '    <div class="punch-sticky">',
        '      <PunchButton :loading="store.pending" sticky @punch="store.punch" />',   # 33
        "    </div>",
        "  </main>",
        "</template>",
        "",
        "<style scoped>",
        ".punch-sticky {",                                                           # 39
    ] + style_lines + [
        "}",
        ".punch-page {",
        "  min-height: 100dvh;",
        "  padding-bottom: calc(64px + env(safe-area-inset-bottom));",
        "}",
        "@media (max-width: 640px) {",
        "  .punch-table { display: none; }",
        "  .punch-sticky { padding: 0 16px; }",
        "  .punch-head h1 { font-size: 1.125rem; }",
        "  /* sticky 在 iOS Safari 需要父層不是 overflow: hidden */",
        "  .punch-page:has(.punch-sticky) { overflow: visible; }",
        "}",
        "</style>",
    ]
    return ("\n".join(lines) + "\n").encode("utf-8")


PUNCH_BUTTON_V0 = """<script setup>
defineProps({ loading: Boolean })
defineEmits(['punch'])
</script>

<template>
  <button class="punch-btn" type="button" @click="$emit('punch')">
    上班打卡
  </button>
</template>

<style scoped>
.punch-btn {
  width: 100%;
  height: 60px;
  background: #2f6fe0;
  color: #fff;
  font-weight: 700;
}
</style>
"""
PUNCH_BUTTON_V1 = PUNCH_BUTTON_V0.replace(
    "  <button class=\"punch-btn\" type=\"button\" @click=\"$emit('punch')\">\n    上班打卡\n",
    "  <button class=\"punch-btn\" type=\"button\" :disabled=\"loading\" @click=\"$emit('punch')\">\n"
    "    {{ loading ? '打卡中…' : '上班打卡' }}\n")
PUNCH_BUTTON_WORK = PUNCH_BUTTON_V1.replace(
    "defineProps({ loading: Boolean })", "defineProps({ loading: Boolean, sticky: Boolean })").replace(
    "<button class=\"punch-btn\" type=\"button\"", "<button class=\"punch-btn\" :class=\"{ 'is-sticky': sticky }\" type=\"button\"").replace(
    "  font-weight: 700;\n}\n", "  font-weight: 700;\n}\n.punch-btn.is-sticky {\n  box-shadow: 0 -2px 8px rgba(0, 0, 0, 0.12);\n}\n")

TAILWIND_V0 = """/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{vue,js}'],
  theme: {
    extend: {},
  },
  plugins: [],
}
"""
TAILWIND_WORK = TAILWIND_V0.replace("    extend: {},\n", "    extend: {\n      spacing: {\n        'safe-b': 'env(safe-area-inset-bottom)',\n      },\n    },\n")

PUNCH_RECORD_CARD = """<script setup>
defineProps({ record: { type: Object, required: true } })
</script>

<template>
  <article class="punch-card">
    <span class="punch-card__type">{{ record.typeLabel }}</span>
    <time class="punch-card__time tabular-nums">{{ record.time }}</time>
    <p class="punch-card__loc truncate">{{ record.location }}</p>
  </article>
</template>

<style scoped>
.punch-card {
  margin: 0 16px 16px;
  padding: 12px 14px;
  border: 1px solid #dcd8cf;
}
</style>
"""


def large_text(size):
    """`size` bytes of 64-byte ASCII lines."""
    line_count = size // 64
    out = bytearray()
    for k in range(line_count):
        out += ("%07d punch log line, fixed width for the read-only plain mode test.." % k)[:63].encode("ascii") + b"\n"
    out += b"x" * (size - len(out))
    return bytes(out)


def git_stage(stage):
    """relative path -> bytes written at each stage (A initial commit, B, C, work = working tree)."""
    if stage == "A":
        return {
            "package.json": (json.dumps({
                "name": "orb-toolkit-frontend", "private": True, "version": "0.3.0", "type": "module",
                "scripts": {"dev": "vite", "build": "vite build", "test": "vitest"},
                "dependencies": {"vue": "^3.5.0", "pinia": "^2.2.0", "@vueuse/core": "^11.0.0"},
                "devDependencies": {"vite": "^5.4.0", "tailwindcss": "^3.4.0", "vitest": "^2.1.0"},
            }, indent=2) + "\n").encode("utf-8"),
            ".gitignore": b"node_modules/\n.env.local\ndist/\n",
            "README.md": "# orb-toolkit-frontend（fixture）\n\n打卡頁與打卡紀錄的前端。這個 repo 是 CODD M4 測試用的假專案。\n".encode("utf-8"),
            "index.html": b'<!doctype html>\n<html lang="zh-Hant">\n  <body>\n    <div id="app"></div>\n'
                          b'    <script type="module" src="/src/main.js"></script>\n  </body>\n</html>\n',
            "vite.config.js": b"import { defineConfig } from 'vite'\nimport vue from '@vitejs/plugin-vue'\n\n"
                              b"export default defineConfig({ plugins: [vue()] })\n",
            "tailwind.config.js": TAILWIND_V0.encode("utf-8"),
            "public/favicon.svg": b'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><rect width="16" height="16" fill="#2f6fe0"/></svg>\n',
            "src/main.js": b"import { createApp } from 'vue'\nimport { createPinia } from 'pinia'\nimport App from './App.vue'\n\n"
                           b"createApp(App).use(createPinia()).mount('#app')\n",
            "src/App.vue": b"<template>\n  <RouterView />\n</template>\n",
            "src/stores/punch.js": "import { defineStore } from 'pinia'\n\nexport const usePunchStore = defineStore('punch', {\n"
                                   "  state: () => ({ todayRecords: [], todayLabel: '', pending: false }),\n"
                                   "  actions: {\n    async fetchToday() {},\n    async punch() {},\n  },\n})\n".encode("utf-8"),
            "src/pages/punch.vue": punch_vue(PUNCH_HEAD_STYLE),
            "src/components/PunchButton.vue": PUNCH_BUTTON_V0.encode("utf-8"),
            "src/legacy-crlf.js": "// 舊版打卡 API（Windows 換行）\r\nexport function legacyPunch(type) {\r\n"
                                  "  return fetch('/api/punch', { method: 'POST', body: JSON.stringify({ type }) })\r\n}\r\n".encode("utf-8"),
            "src/mixed-eol.js": b"// mixed line endings: CRLF majority\r\nexport const a = 1\r\nexport const b = 2\n"
                                b"export const c = 3\r\nexport const d = 4\r\n",
            "src/bom.css": b"\xef\xbb\xbf" + "/* 打卡頁共用樣式（UTF-8 BOM） */\n.punch-page { color: #1d1d1d; }\n".encode("utf-8"),
            "docs/big5.csv": "發票匯出,金額\n2026-10-01,1200\n2026-10-02,860\n".encode("big5"),
            "docs/utf16le.txt": b"\xff\xfe" + "打卡紀錄 UTF-16 LE\r\n第二行\r\n".encode("utf-16-le"),
            "docs/latin1.txt": b"caf\xe9 cr\xe8me br\xfbl\xe9e \xb7 fixture\n",
            "assets/blob.bin": b"\x89BLOB\x00\x01\x02\x00" + bytes(range(256)) * 16,
            "big/large.txt": large_text(6 * 1024 * 1024),
            "node_modules/x/index.js": b"module.exports = 'ignored dependency'\n",
            ".env.local": b"# fixture only, ignored by git; no secrets\nVITE_API_BASE=http://127.0.0.1:9/api\n",
        }
    if stage == "B":
        return {"src/components/PunchRecordCard.vue": PUNCH_RECORD_CARD.encode("utf-8")}
    if stage == "C":
        return {"src/components/PunchButton.vue": PUNCH_BUTTON_V1.encode("utf-8")}
    if stage == "work":
        return {
            "src/pages/punch.vue": punch_vue(PUNCH_AI_STYLE),
            "src/components/PunchButton.vue": PUNCH_BUTTON_WORK.encode("utf-8"),
            "tailwind.config.js": TAILWIND_WORK.encode("utf-8"),
        }
    raise ValueError(stage)


def cmd_git_stage(argv):
    """`git-stage <repo> <A|B|C|work>`: writes that stage's files (0644, folders 0755 like a checkout)."""
    if len(argv) != 2 or argv[1] not in ("A", "B", "C", "work"):
        usage("make-git-project", "usage: _m4fix.py git-stage <repo> <A|B|C|work>")
    repo = os.path.abspath(argv[0])
    refuse("make-git-project", repo)
    for rel, data in git_stage(argv[1]).items():
        path = os.path.join(repo, rel)
        os.makedirs(os.path.dirname(path), mode=0o755, exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)
        os.chmod(path, 0o644)


def cmd_check_target(argv):
    """`check-target <tool> <path>`: exit 1 with a message when the path is protected."""
    if len(argv) != 2:
        usage("_m4fix", "usage: _m4fix.py check-target <tool> <path>")
    refuse(argv[0], argv[1])


def main():
    if len(sys.argv) < 2:
        usage("_m4fix", "usage: _m4fix.py <notes|claude-json|git-stage|check-target> …")
    command, args = sys.argv[1], sys.argv[2:]
    table = {"notes": cmd_notes, "claude-json": cmd_claude_json, "git-stage": cmd_git_stage,
             "check-target": cmd_check_target}
    if command not in table:
        usage("_m4fix", "usage: _m4fix.py <notes|claude-json|git-stage|check-target> …", "unknown command " + command)
    table[command](args)


if __name__ == "__main__":
    main()
