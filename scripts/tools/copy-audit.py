#!/usr/bin/env python3
"""Copy audit for CODD Desktop (docs/M5-PLAN.md §2.7, D22). Standard library only.

    scripts/tools/copy-audit.py [--allow <file>] [--rules EFMSGL] [<path prefix>...]

Rules
  E  emoji anywhere in the repo's *.md *.swift *.sh *.py *.yml: scalars U+1F000-1FAFF, U+FE0F and the
     Emoji_Presentation code points below U+2B56. Text-presentation symbols (Claude's own ✻ ❯ ★ ☐) and
     SPEC's glyph allow-list are never flagged. In UI strings also SPEC §1's FORBIDDEN symbols
     (⚠ ⚙ ⏺ ▶ ⌨ ✏ ✔ ✖ ☀ ♻: text by default, but AppKit draws them from the emoji font). Unicode test data
     is written as Swift `\\u{…}` escapes (the same scalars at run time), so it never reaches this rule.
  F  the old brand: the upper-case word and the old bundle prefix (D1), in every text file; only the
     allow-listed places (history, Spikes/, design/research/, the M5 plan, the legacy constant) may have it.
  M  e-mail addresses in UI strings (made-up fixture addresses belong in tests); the last domain label
     must start with a letter, so an npm `name@1.2.3` is no address.
  S  simplified-only characters in UI strings (each one checked to have a different traditional form and
     to be absent from Big5, the Taiwan character set: 后 并 几 制 面 里 只 台 are valid traditional ones).
  G  glossary variants in UI strings (帳户 / 账户 / 賬號 -> 帳號, 設置 -> 設定, …).
  L  English sentences in UI strings: no CJK and at least 4 lower-case words of two or more letters
     (or `a`); SQL statements are skipped (report only, never failing).

UI strings are the string literals of App/**/*.swift and Packages/*/Sources/**/*.swift outside comments,
except: Tests/ folders, App/Debug/, Sources/codd-* demo targets; arguments of log / print / Logger /
os_log / fatalError / precondition / assert / #expect / #require calls, DispatchQueue(label:),
Notification.Name(…), NSPasteboard…(…), UserDefaults calls and forKey: labels; regex patterns;
format-only literals (no letters besides format specifiers); identifiers / paths / commands (no white
space and no CJK; rule M still reads those, an address has no white space).

Output: one `<rule> <path>:<line> <text>` per finding, then `COPY findings=<n> failing=<n> review=<n>
allowed=<n>`. Exit 1 when failing > 0 (E F M S G findings not allow-listed), 2 on a usage or allow-list
error, else 0.

Allow list (default scripts/tools/copy-audit-allow.txt), one entry per line, `#` comment lines:
    <rule> <path>:<text> # reason
<path> is repo-relative: a trailing `/` matches the folder, otherwise an fnmatch pattern (`*` also
crosses `/`). <text> must occur in the finding's text; empty = any finding of that rule in <path>.
Every entry needs a reason. Entries that match nothing are listed on stderr (not failing).
"""
import fnmatch
import os
import re
import subprocess
import sys
import unicodedata

REPO = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
DEFAULT_ALLOW = os.path.join(REPO, "scripts", "tools", "copy-audit-allow.txt")
RULES = "EFMSGL"
FAILING = set("EFMSG")
E_SUFFIXES = (".md", ".swift", ".sh", ".py", ".yml")
TEXT_MAX = 140  # the printed text of a finding (the allow list matches the full text)

# --- rule E --------------------------------------------------------------------------------------
# Emoji_Presentation=Yes code points below U+2B56 (Unicode emoji-data.txt); everything in
# U+1F000-1FAFF and the emoji presentation selector U+FE0F count as well.
_EMOJI_BMP_RANGES = [
    (0x231A, 0x231B), (0x23E9, 0x23EC), (0x23F0, 0x23F0), (0x23F3, 0x23F3), (0x25FD, 0x25FE),
    (0x2614, 0x2615), (0x2648, 0x2653), (0x267F, 0x267F), (0x2693, 0x2693), (0x26A1, 0x26A1),
    (0x26AA, 0x26AB), (0x26BD, 0x26BE), (0x26C4, 0x26C5), (0x26CE, 0x26CE), (0x26D4, 0x26D4),
    (0x26EA, 0x26EA), (0x26F2, 0x26F3), (0x26F5, 0x26F5), (0x26FA, 0x26FA), (0x26FD, 0x26FD),
    (0x2705, 0x2705), (0x270A, 0x270B), (0x2728, 0x2728), (0x274C, 0x274C), (0x274E, 0x274E),
    (0x2753, 0x2755), (0x2757, 0x2757), (0x2795, 0x2797), (0x27B0, 0x27B0), (0x27BF, 0x27BF),
    (0x2B1B, 0x2B1C), (0x2B50, 0x2B50), (0x2B55, 0x2B55),
]
EMOJI_BMP = {cp for lo, hi in _EMOJI_BMP_RANGES for cp in range(lo, hi + 1)}
# SPEC §2.7 glyph allow-list (state glyphs, keys, arrows, ① to ⑳) and Claude's own text symbols.
SPEC_GLYPHS = "◆▲◇●◌○$✕⟲✓✎↻→←↑↓⏎⌘⌥⇧⌃⎋▸▾·…■□↗✳◐◑" + "".join(chr(c) for c in range(0x2460, 0x2474))
CLAUDE_GLYPHS = "✻❯★☐"
# SPEC §1 FORBIDDEN (render as emoji) besides the Emoji_Presentation ones: checked in UI strings only.
SPEC_FORBIDDEN = set("⚠⚙⏺▶⌨✏✔✖☀♻")


def is_emoji(ch):
    cp = ord(ch)
    return 0x1F000 <= cp <= 0x1FAFF or cp == 0xFE0F or cp in EMOJI_BMP


# --- rule F --------------------------------------------------------------------------------------
# Built from pieces so this file and the allow list never match themselves.
F_PATTERNS = [re.compile(r"\b" + "FAN" + "CY" + r"\b"), re.compile("fancy" + "codd", re.IGNORECASE)]

# --- rule S --------------------------------------------------------------------------------------
# simplified + traditional pairs. Each simplified character is absent from Big5 (checked at start)
# and was cross-checked with ICU's Hans-Hant transform. Left out although common: 复 与 确 么 万 网 扰
# (they are Big5 characters too, i.e. valid traditional ones in Taiwan).
S_PAIRS = """
设設 话話 认認 证證 讯訊 说說 让讓 请請 访訪 订訂 计計 记記 议議 讨討 论論 译譯 试試 详詳 语語 误誤
读讀 调調 谢謝 询詢 该該 识識 诉訴 评評 课課 谁誰 词詞 许許 训訓 讲講
络絡 统統 线線 纪紀 级級 约約 红紅 纸紙 组組 细細 终終 经經 结結 给給 绝絕 继繼 续續 维維 编編 缓緩
练練 绑綁 绿綠 缩縮 纯純 织織 绘繪 绩績 综綜
钟鐘 错錯 钮鈕 银銀 链鏈 锁鎖 键鍵 镜鏡 针針 钱錢 铁鐵
门門 问問 间間 闭閉 闪閃 阅閱 闻聞 闲閒
页頁 项項 题題 顺順 须須 顾顧 预預 领領 频頻 颜顏 额額 显顯 顶頂
账賬 资資 贴貼 负負 责責 败敗 货貨 质質 费費 购購 贵貴 买買 卖賣
车車 转轉 软軟 载載 输輸 较較 轮輪 辑輯 连連 库庫 阵陣 军軍
码碼 马馬 验驗 驱驅
见見 规規 视視 览覽 觉覺 观觀 现現
会會 开開 关關 启啟 动動 时時 档檔 录錄 实實 务務 应應 发發 帮幫 这這 们們 为為 个個 来來 对對 还還
进進 过過 从從 无無 条條 变變 处處 头頭 将將 东東 选選 择擇 删刪 号號
书書 长長 爱愛 当當 国國 图圖 团團 块塊 场場 报報 换換 扩擴 扫掃 损損 数數 断斷 暂暫 杂雜 权權 标標
样樣 检檢 楼樓 测測 满滿 滚滾 点點 热熱 状狀 环環 电電 画畫 盘盤 积積 称稱 稳穩 笔筆 简簡 签簽 类類
职職 联聯 脑腦 节節 虑慮 补補 装裝 边邊 运運 远遠 递遞 释釋 队隊 际際 随隨 隐隱 难難 风風 飞飛 区區
华華 单單 压壓 厅廳 参參 双雙 吗嗎 员員 响響 围圍 备備 宝寶 审審 宽寬 寻尋 导導 层層 岁歲 币幣 师師
帐帳 带帶 废廢 张張 弹彈 归歸 态態 总總 恶惡 战戰 执執 拟擬 拥擁 旧舊 杀殺 栏欄 树樹 欢歡 毕畢 汇匯
湿濕 灵靈 户戶 别別 没沒 术術 药藥 达達 灯燈
""".split()
S_MAP = {p[0]: p[1] for p in S_PAIRS}

# --- rule G --------------------------------------------------------------------------------------
GLOSSARY = [
    ("帳户", "帳號"), ("账户", "帳號"), ("賬號", "帳號"), ("設置", "設定"), ("文件夾", "資料夾"),
    ("登錄", "登入"), ("屏幕", "螢幕"), ("默認", "預設"), ("信息", "訊息"), ("程序", "程式"),
    ("鏈接", "連結"), ("菜單", "選單"), ("窗口", "視窗"), ("用戶", "使用者"), ("視頻", "影片"),
    ("質量", "品質"),
]

# --- rule M / L / helpers ------------------------------------------------------------------------
EMAIL = re.compile(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)*\.[A-Za-z][\w-]*")
SQL = re.compile(r"^\s*(?:SELECT|INSERT|UPDATE|DELETE|CREATE|DROP|ALTER|PRAGMA|WITH|EXISTS|REPLACE|BEGIN|COMMIT)\b")
CJK = re.compile("[\u3000-\u303f\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\uff00-\uffef\U00020000-\U0002fa1f]")
FORMAT_SPEC = re.compile(r"%(?:\d+\$)?[-+ 0#']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfFeEgGaAcCsSp%]")
WORD = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)?")
# Regex patterns: `\d` `\s` `\w` `\b` `\.` are no Swift escapes, so a literal holding one is a pattern.
REGEXY = re.compile(r"\\[dswbDSWB.]|\(\?[:=!<i]|\[\^|\.\*|\.\+")

LOG_CALLS = {"log", "printLog", "print", "debugPrint", "NSLog", "os_log", "debugLog", "logSafe",
             "fatalError", "precondition", "preconditionFailure", "assert", "assertionFailure"}
MACRO_CALLS = {"#expect", "#require", "#Preview"}
IDENT_CALLS = {"DispatchQueue", "OSSignposter", "Logger", "OSLog", "NSRegularExpression", "Regex"}
IDENT_LABELS = {"forKey", "forKeyPath", "pattern"}


def fail_usage(message):
    print(f"copy-audit: {message}", file=sys.stderr)
    sys.exit(2)


def self_check():
    """The lists are part of the contract: refuse to run with a broken one."""
    if len(S_MAP) < 150 or len(S_MAP) != len(S_PAIRS):
        fail_usage(f"S list has {len(S_MAP)} distinct characters (needs >= 150, no duplicates)")
    for pair in S_PAIRS:
        simplified, traditional = pair[0], pair[1]
        if len(pair) != 2 or simplified == traditional:
            fail_usage(f"S pair {pair!r} is not a simplified/traditional pair")
        try:
            simplified.encode("big5")
            fail_usage(f"S character {simplified} is also a Big5 (traditional) character")
        except UnicodeEncodeError:
            pass
        try:
            traditional.encode("big5")
        except UnicodeEncodeError:
            fail_usage(f"S pair {pair}: traditional form {traditional} is not in Big5")
    for glyph in SPEC_GLYPHS + CLAUDE_GLYPHS:
        if is_emoji(glyph) or glyph in SPEC_FORBIDDEN:
            fail_usage(f"glyph U+{ord(glyph):04X} of the allow-lists would be flagged as emoji")


# --- files ---------------------------------------------------------------------------------------
def repo_files():
    """Tracked files plus untracked ones not ignored (the parallel M5 work is not committed yet)."""
    try:
        out = subprocess.run(["git", "-C", REPO, "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                             check=True, capture_output=True).stdout
    except (OSError, subprocess.CalledProcessError) as error:
        fail_usage(f"git ls-files failed: {error}")
    names = sorted({n.decode("utf-8", "surrogateescape") for n in out.split(b"\0") if n})
    return [n for n in names if os.path.isfile(os.path.join(REPO, n)) and not os.path.islink(os.path.join(REPO, n))]


def read_text(rel):
    try:
        with open(os.path.join(REPO, rel), "rb") as f:
            data = f.read()
    except OSError:
        return None
    if b"\0" in data:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


def ui_scope(rel):
    parts = rel.split("/")
    if not rel.endswith(".swift") or "Tests" in parts:
        return False
    if parts[0] == "App":
        return len(parts) < 2 or parts[1] != "Debug"
    if parts[0] == "Packages" and len(parts) > 3 and parts[2] == "Sources":
        return not parts[3].startswith("codd-")
    return False


def one_line(text):
    return text.replace("\n", "\\n").replace("\t", " ").strip()


def clip(text, limit=TEXT_MAX):
    return text if len(text) <= limit else text[: limit - 1] + "…"


# --- Swift string literals -----------------------------------------------------------------------
IDENT_CHARS = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")


class Literal:
    __slots__ = ("line", "text", "raw", "calls", "label")

    def __init__(self, line, text, raw, calls, label):
        self.line, self.text, self.raw, self.calls, self.label = line, text, raw, calls, label


class SwiftLexer:
    """Finds the string literals of a Swift file outside comments, with the chain of calls they are
    arguments of (`HolderSessionStore.printLog`, `#expect`, …) and the argument label right before them.
    Interpolations become `{}` in the text; literals inside them are reported on their own."""

    def __init__(self, src):
        self.s, self.n, self.i, self.line = src, len(src), 0, 1
        self.stack = []  # open brackets: (char, callee chain or None)
        self.literals = []

    def run(self):
        self.code(stop_at_close=False)
        return self.literals

    def advance(self, count=1):
        for _ in range(count):
            if self.i < self.n and self.s[self.i] == "\n":
                self.line += 1
            self.i += 1

    def callee_before(self, pos):
        j = pos - 1
        while j >= 0 and self.s[j] in " \t":
            j -= 1
        end = j + 1
        while j >= 0 and (self.s[j] in IDENT_CHARS or self.s[j] in ".?!#"):
            j -= 1
        chain = self.s[j + 1:end].replace("?", "").replace("!", "").strip(".")
        return chain or None

    def label_before(self, pos):
        j = pos - 1
        while j >= 0 and self.s[j] in " \t\n":
            j -= 1
        if j < 0 or self.s[j] != ":":
            return None
        j -= 1
        while j >= 0 and self.s[j] in " \t":
            j -= 1
        end = j + 1
        while j >= 0 and self.s[j] in IDENT_CHARS:
            j -= 1
        return self.s[j + 1:end] or None

    def code(self, stop_at_close):
        """Code until the end, or (in an interpolation) until the `)` that closes it."""
        depth = len(self.stack)
        s = self.s
        while self.i < self.n:
            c = s[self.i]
            if c == "/" and s.startswith("//", self.i):
                while self.i < self.n and s[self.i] != "\n":
                    self.i += 1
                continue
            if c == "/" and s.startswith("/*", self.i):
                self.block_comment()
                continue
            if c == '"' or (c == "#" and self.raw_start()):
                self.string()
                continue
            if c in "([{":
                self.stack.append((c, self.callee_before(self.i) if c == "(" else None))
            elif c in ")]}":
                if stop_at_close and c == ")" and len(self.stack) == depth:
                    self.advance()
                    return
                if self.stack:
                    self.stack.pop()
            self.advance()

    def block_comment(self):
        nesting = 0
        while self.i < self.n:
            if self.s.startswith("/*", self.i):
                nesting += 1
                self.advance(2)
            elif self.s.startswith("*/", self.i):
                nesting -= 1
                self.advance(2)
                if nesting == 0:
                    return
            else:
                self.advance()

    def raw_start(self):
        j = self.i
        while j < self.n and self.s[j] == "#":
            j += 1
        return j < self.n and self.s[j] == '"'

    def string(self):
        start, line = self.i, self.line
        hashes = 0
        while self.s[self.i] == "#":
            hashes += 1
            self.i += 1
        multi = self.s.startswith('"""', self.i)
        self.advance(3 if multi else 1)
        close = ('"""' if multi else '"') + "#" * hashes
        escape = "\\" + "#" * hashes
        calls = [chain for kind, chain in self.stack if kind == "(" and chain]
        label = self.label_before(start)
        text = []
        while self.i < self.n:
            if self.s.startswith(close, self.i):
                self.advance(len(close))
                break
            if not multi and self.s[self.i] == "\n":
                break  # unterminated: give up on this literal
            if self.s.startswith(escape, self.i):
                after = self.i + len(escape)
                if after < self.n and self.s[after] == "(":
                    self.advance(len(escape) + 1)
                    self.stack.append(("(", None))
                    self.code(stop_at_close=True)
                    if self.stack and self.stack[-1] == ("(", None):
                        self.stack.pop()
                    text.append("{}")
                    continue
                text.append(self.s[self.i:after + 1])
                self.advance(len(escape) + 1)
                continue
            text.append(self.s[self.i])
            self.advance()
        self.literals.append(Literal(line, "".join(text), self.s[start:self.i], calls, label))


def excluded_context(lit):
    for chain in lit.calls:
        parts = chain.split(".")
        last = parts[-1]
        if last in LOG_CALLS or chain in MACRO_CALLS or last in IDENT_CALLS:
            return True
        if any("logger" in p.lower() for p in parts):
            return True
        if "Pasteboard" in chain or "pasteboard" in chain or "UserDefaults" in chain or "defaults" in parts:
            return True
        if last == "Name" and "Notification" in chain:
            return True
    return lit.label in IDENT_LABELS


def letters_left(text):
    stripped = FORMAT_SPEC.sub("", text.replace("{}", ""))
    stripped = re.sub(r"\\[nrt0\\\"']|\\u\{[0-9A-Fa-f]+\}", "", stripped)
    return any(ch.isalpha() for ch in stripped)


# --- the audit -----------------------------------------------------------------------------------
class Audit:
    def __init__(self, rules, prefixes):
        self.rules, self.prefixes = rules, prefixes
        self.findings = []  # (rule, path, line, text)

    def wanted(self, rel):
        return not self.prefixes or any(rel == p.rstrip("/") or rel.startswith(p.rstrip("/") + "/") for p in self.prefixes)

    def add(self, rule, rel, line, content, hint=""):
        """A finding: the printed text is the clipped content plus the hint in brackets; the allow
        list matches the full text."""
        if rule not in self.rules:
            return
        content = one_line(content)
        full = f"{content} [{hint}]" if hint else content
        shown = f"{clip(content)} [{clip(hint, 80)}]" if hint else clip(content)
        self.findings.append((rule, rel, line, shown, full))

    def scan(self):
        for rel in repo_files():
            if not self.wanted(rel):
                continue
            text = read_text(rel)
            if text is None:
                continue
            self.line_rules(rel, text)
            if ui_scope(rel):
                self.ui_rules(rel, text)

    def line_rules(self, rel, text):
        check_e = rel.endswith(E_SUFFIXES)
        for number, line in enumerate(text.split("\n"), 1):
            if check_e:
                found = [ch for ch in line if is_emoji(ch)]
                if found:
                    marked = "".join(f"<U+{ord(ch):04X}>" if is_emoji(ch) else ch for ch in line)
                    names = ", ".join(f"U+{ord(ch):04X} {unicodedata.name(ch, '?')}" for ch in dict.fromkeys(found))
                    self.add("E", rel, number, marked, names)
            if any(p.search(line) for p in F_PATTERNS):
                self.add("F", rel, number, line)

    def ui_rules(self, rel, text):
        for lit in SwiftLexer(text).run():
            if excluded_context(lit) or REGEXY.search(lit.raw[1:-1] if len(lit.raw) > 1 else ""):
                continue
            content = lit.text
            forbidden = [ch for ch in dict.fromkeys(content) if ch in SPEC_FORBIDDEN]
            if forbidden:
                names = ", ".join(f"U+{ord(ch):04X} {unicodedata.name(ch, '?')}" for ch in forbidden)
                self.add("E", rel, lit.line, content, f"SPEC FORBIDDEN {names}")
            if not letters_left(content):
                continue
            has_cjk = bool(CJK.search(content))
            plain = has_cjk or bool(re.search(r"\s", content))
            emails = EMAIL.findall(content)
            if emails:
                self.add("M", rel, lit.line, content, ", ".join(emails))
            if not plain:
                continue
            simplified = sorted({ch for ch in content if ch in S_MAP}, key=content.index)
            if simplified:
                hint = " ".join(f"{ch}->{S_MAP[ch]}" for ch in simplified)
                self.add("S", rel, lit.line, content, hint)
            variants = [(v, t) for v, t in GLOSSARY if v in content]
            if variants:
                hint = " ".join(f"{v}->{t}" for v, t in variants)
                self.add("G", rel, lit.line, content, hint)
            if not has_cjk and not SQL.match(content):
                words = [w for w in WORD.findall(content.replace("{}", " ")) if w.islower() and (len(w) > 1 or w == "a")]
                if len(words) >= 4:
                    self.add("L", rel, lit.line, content)


# --- allow list ----------------------------------------------------------------------------------
class AllowEntry:
    def __init__(self, number, rule, path, text, reason, source):
        self.number, self.rule, self.path, self.text, self.reason, self.source = number, rule, path, text, reason, source
        self.used = 0

    def matches(self, rule, rel, text):
        if rule != self.rule:
            return False
        if self.path.endswith("/"):
            if not rel.startswith(self.path):
                return False
        elif not fnmatch.fnmatchcase(rel, self.path):
            return False
        return self.text in text


def load_allow(path):
    entries = []
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().split("\n")
    except OSError as error:
        fail_usage(f"cannot read the allow list {path}: {error}")
    for number, raw in enumerate(lines, 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if " # " not in line:
            fail_usage(f"{path}:{number}: entry without ` # reason`")
        entry, reason = line.split(" # ", 1)
        m = re.match(r"^([A-Z]) ([^:]+):(.*)$", entry.strip())
        if not m or m.group(1) not in RULES or not reason.strip():
            fail_usage(f"{path}:{number}: expected `<rule> <path>:<text> # reason`")
        entries.append(AllowEntry(number, m.group(1), m.group(2).strip(), m.group(3).strip(), reason.strip(), line))
    return entries


def main(argv):
    allow_path, rules, prefixes = DEFAULT_ALLOW, RULES, []
    args = list(argv)
    while args:
        arg = args.pop(0)
        if arg == "--allow" and args:
            allow_path = args.pop(0)
        elif arg == "--rules" and args:
            rules = args.pop(0).upper().replace(",", "")
            if not rules or any(r not in RULES for r in rules):
                fail_usage(f"--rules takes letters of {RULES}")
        elif arg in ("-h", "--help"):
            print(__doc__)
            return 0
        elif arg.startswith("-"):
            fail_usage(f"unknown option {arg} (see --help)")
        else:
            prefixes.append(os.path.relpath(os.path.realpath(arg), REPO))
    self_check()
    entries = load_allow(allow_path)
    audit = Audit(set(rules), prefixes)
    audit.scan()
    failing = review = allowed = 0
    for rule, rel, line, text, full in sorted(audit.findings, key=lambda f: (f[1], f[2], f[0])):
        match = next((e for e in entries if e.matches(rule, rel, full)), None)
        if match:
            match.used += 1
            allowed += 1
            continue
        print(f"{rule} {rel}:{line} {text}")
        if rule in FAILING:
            failing += 1
        else:
            review += 1
    if not prefixes and rules == RULES:
        for e in entries:
            if not e.used:
                print(f"copy-audit: unused allow-list entry (line {e.number}): {e.source}", file=sys.stderr)
    print(f"COPY findings={failing + review} failing={failing} review={review} allowed={allowed}")
    return 1 if failing else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
