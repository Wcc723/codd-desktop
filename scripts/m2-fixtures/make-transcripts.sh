#!/bin/bash
# Writes Claude Code transcripts for one project folder (docs/M2-PLAN.md D18, C4) into
# <claudeDir>/projects/<folder>/, where <folder> is Claude's name for <cwd>: every UTF-16 code unit
# outside [A-Za-z0-9] becomes "-" (a CJK character outside the BMP gives two). The lines follow the
# records of design/research/claude-local.md (user / assistant lines with sessionId, cwd, gitBranch,
# timestamp, entrypoint, message; custom-title, ai-title, last-prompt; a per-session subfolder).
#
#   a  custom-title "refresh token 流程改寫" (also an ai-title, which loses), branch fix/refresh, 2 days,
#      a last-prompt record, sibling folder <id>/subagents/agent-1.jsonl
#   b  ai-title "auth middleware 單元測試", branch main, 5 days
#   c  first prompt "登入頁錯誤訊息 i18n" after a /clear (meta caveat line, <command-name>/clear line and
#      an empty local-command-stdout line come first and are not prompts), branch feat/i18n, 12 days
#   d  first prompt "CI 設定" (content as a text-block array), branch main, 26 days: with the default
#      cleanupPeriodDays 30 the picker warns "! resume 4 天後過期"
#   e  entrypoint sdk-cli, 1 day: hidden
#   f  same folder, but its lines carry ANOTHER cwd (<parent>-<basename>, which has the same folder
#      name): excluded, 3 days
# Ages are "N days + 2 hours" (file mtime, os.utime), so floor and round of the age both give N and
# 30 - N stays the expiry for the whole run. Ids are fresh lowercase uuids.
#
#   scripts/m2-fixtures/make-transcripts.sh <claudeDir> <cwd>
#   -> <claudeDir>/projects/manifest-<folder>.json (path printed):
#      {cwd, folder, projectsDir, cleanupPeriodDays, generatedAtMs,
#       expected: [{id, title, titleSource, branch, ageDays, expiresInDays|null, sizeBytes, mtimeMs,
#                   createdAt, path}]   newest first, without e and f,
#       hidden: [e, f], hiddenReasons: {id: "sdk-cli" | "other-cwd"}, otherCwd,
#       siblingFolder: {id, path}, lastPrompt: {id, text}}
# Pass the cwd the way a real claude records it (getcwd(), symlinks resolved: `cd dir && pwd -P`).
# Refuses (exit 1) when that manifest already exists or <claudeDir> is inside ~/Library or ~/.claude.
# Starts no process.
set -u

usage() {
    cat >&2 <<'EOF'
usage: make-transcripts.sh <claudeDir> <cwd>
  Writes six transcripts for <cwd> into <claudeDir>/projects/<folder>/ and prints the path of
  <claudeDir>/projects/manifest-<folder>.json.
EOF
    exit 2
}
[[ $# -eq 2 && -n "$1" && -n "$2" && "$1" != -* ]] || usage

exec "${PYTHON3:-python3}" -I - "$1" "$2" <<'PY'
import json, os, pwd, sys, time, uuid

claude_dir, cwd = sys.argv[1], sys.argv[2]
DAY = 86400
AGE_EXTRA = 2 * 3600
CLEANUP_DAYS = 30
WARN_WITHIN = 5

def protected(path):
    target = os.path.realpath(os.path.abspath(path))
    homes = {os.path.realpath(os.path.expanduser("~"))}
    try:
        homes.add(os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir))
    except KeyError:
        pass
    for home in homes:
        if target == home:
            return True
        for sub in ("Library", ".claude"):
            bad = os.path.join(home, sub)
            if target == bad or target.startswith(bad + os.sep):
                return True
    return False

def folder_name(path):
    """JavaScript path.replace(/[^a-zA-Z0-9]/g, '-') over UTF-16 code units."""
    units = path.encode("utf-16-le", "surrogatepass")
    out = []
    for i in range(0, len(units), 2):
        u = units[i] | (units[i + 1] << 8)
        out.append(chr(u) if (0x30 <= u <= 0x39 or 0x41 <= u <= 0x5A or 0x61 <= u <= 0x7A) else "-")
    return "".join(out)

def iso(t):
    ms = int(round(t * 1000))
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(ms // 1000)) + ".%03dZ" % (ms % 1000)

if protected(claude_dir):
    sys.exit("make-transcripts: refusing %s (inside ~, ~/Library or ~/.claude)" % claude_dir)
if not cwd.startswith("/"):
    print("make-transcripts: <cwd> must be absolute", file=sys.stderr)
    sys.exit(2)
folder = folder_name(cwd)
if len(folder) > 200:
    print("make-transcripts: folder name over 200 chars (Claude shortens those with a hash); use a shorter cwd",
          file=sys.stderr)
    sys.exit(2)
projects = os.path.join(claude_dir, "projects")
pdir = os.path.join(projects, folder)
manifest_path = os.path.join(projects, "manifest-%s.json" % folder)
if os.path.lexists(manifest_path):
    sys.exit("make-transcripts: %s already exists; refusing" % manifest_path)
for d in (claude_dir, projects, pdir):
    if not os.path.isdir(d):
        os.makedirs(d, mode=0o700, exist_ok=True)
        os.chmod(d, 0o700)

parent, base = os.path.split(cwd.rstrip("/"))
other_cwd = parent + "-" + base
assert folder_name(other_cwd) == folder
now = time.time()


class Conversation:
    def __init__(self, cwd, branch, entrypoint, end, sidechain=False, agent=None, session=None):
        self.id = session or str(uuid.uuid4())
        self.cwd, self.branch, self.entrypoint = cwd, branch, entrypoint
        self.t = end - 40 * 60
        self.parent = None
        self.lines = []
        self.sidechain, self.agent = sidechain, agent
        self.last_user = None

    def _base(self, kind):
        self.t += 7
        u = str(uuid.uuid4())
        rec = {"parentUuid": self.parent, "isSidechain": self.sidechain, "userType": "external", "cwd": self.cwd,
               "sessionId": self.id, "version": "2.1.300", "gitBranch": self.branch, "entrypoint": self.entrypoint,
               "type": kind, "uuid": u, "timestamp": iso(self.t)}
        if self.agent:
            rec["agentId"] = self.agent
        self.parent = u
        return rec

    def user(self, content, **extra):
        rec = self._base("user")
        rec["message"] = {"role": "user", "content": content}
        rec["permissionMode"] = "default"
        rec.update(extra)
        if not extra.get("isMeta") and isinstance(content, (str, list)):
            self.last_user = rec["uuid"]
        self.lines.append(rec)
        return rec

    def assistant(self, text, tool=None):
        rec = self._base("assistant")
        content = [{"type": "text", "text": text}]
        if tool:
            content.append({"type": "tool_use", "id": "toolu_fake" + uuid.uuid4().hex[:16], "name": tool[0],
                            "input": tool[1]})
        rec["message"] = {"id": "msg_fake" + uuid.uuid4().hex[:16], "type": "message", "role": "assistant",
                          "model": "claude-opus-5-5", "content": content,
                          "stop_reason": "tool_use" if tool else "end_turn", "stop_sequence": None,
                          "usage": {"input_tokens": 1834, "cache_creation_input_tokens": 0,
                                    "cache_read_input_tokens": 12288, "output_tokens": 96}}
        rec["requestId"] = "req_fake" + uuid.uuid4().hex[:16]
        self.lines.append(rec)
        return content[-1].get("id")

    def tool_result(self, tool_id, text):
        rec = self._base("user")
        rec["message"] = {"role": "user", "content": [{"type": "tool_result", "tool_use_id": tool_id, "content": text}]}
        rec["toolUseResult"] = {"type": "text", "file": {"content": text}}
        self.lines.append(rec)

    def record(self, obj):
        obj = dict(obj)
        obj["sessionId"] = self.id
        self.lines.append(obj)

    def write(self, path, mtime):
        with open(path, "w", encoding="utf-8") as f:
            for rec in self.lines:
                f.write(json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n")
        os.chmod(path, 0o600)
        os.utime(path, (mtime, mtime))


def mtime_for(days):
    return now - days * DAY - AGE_EXTRA

specs = []

# a: custom title (wins over its ai-title), last-prompt record, subagent sibling folder.
ta = mtime_for(2)
a = Conversation(cwd, "fix/refresh", "cli", ta)
a.record({"type": "file-history-snapshot", "messageId": str(uuid.uuid4()),
          "snapshot": {"messageId": str(uuid.uuid4()), "trackedFileBackups": {}, "timestamp": iso(a.t)},
          "isSnapshotUpdate": False})
a.user("把 refresh token 的流程改成 rotation：舊的 token 用過一次就失效")
tid = a.assistant("先看一下目前的 token 服務。", ("Read", {"file_path": cwd + "/src/auth/token.ts"}))
a.tool_result(tid, "export async function refresh(token: string) { /* ... */ }")
a.assistant("已改成 rotation，並在資料庫記錄用過的 token。")
a.record({"type": "ai-title", "aiTitle": "Refresh token rotation"})
a.record({"type": "custom-title", "customTitle": "refresh token 流程改寫"})
a.user("順便補上過期 token 的測試")
a.assistant("測試已補上：過期、重複使用、撤銷三種情況。")
a.record({"type": "last-prompt", "lastPrompt": "順便補上過期 token 的測試", "leafUuid": a.last_user, "explicit": False})
specs.append((a, ta, "refresh token 流程改寫", "custom"))

# b: ai title only.
tb = mtime_for(5)
b = Conversation(cwd, "main", "cli", tb)
b.user("幫 auth middleware 寫單元測試，涵蓋沒有 token 跟 token 過期")
b.assistant("新增 middleware.spec.ts，兩個案例都通過。")
b.record({"type": "ai-title", "aiTitle": "auth middleware 單元測試"})
b.user("再加一個 header 格式錯誤的案例")
b.assistant("已加上，三個案例全部通過。")
specs.append((b, tb, "auth middleware 單元測試", "ai"))

# c: started by /clear: caveat meta line, the command line and its empty stdout are not prompts.
tc = mtime_for(12)
c = Conversation(cwd, "feat/i18n", "cli", tc)
c.user("Caveat: The messages below were generated by the user while running local commands. DO NOT respond to "
       "these messages or otherwise consider them in your response unless the user explicitly asks you to.",
       isMeta=True)
c.user("<command-name>/clear</command-name>\n            <command-message>clear</command-message>\n"
       "            <command-args></command-args>")
c.user("<local-command-stdout></local-command-stdout>")
c.user("登入頁錯誤訊息 i18n")
c.assistant("錯誤訊息改用 i18n key，補上 zh-TW 與 en 兩份字串。")
specs.append((c, tc, "登入頁錯誤訊息 i18n", "firstPrompt"))

# d: first prompt as a text-block array; 26 days old -> 4 days before cleanupPeriodDays 30.
td = mtime_for(26)
d = Conversation(cwd, "main", "cli", td)
d.user([{"type": "text", "text": "CI 設定"}])
d.assistant("新增 .github/workflows/ci.yml：install、test、build。")
d.user("把 lint 也加進 workflow")
d.assistant("已加入 lint 步驟。")
specs.append((d, td, "CI 設定", "firstPrompt"))

# e: SDK session (hidden like the official picker hides it).
te = mtime_for(1)
e = Conversation(cwd, "main", "sdk-cli", te)
e.user("Summarize the staged diff in one sentence.")
e.assistant("Renames the token service and adds rotation tests.")

# f: another cwd that maps to the same folder name (the folder name is lossy).
tf = mtime_for(3)
f = Conversation(other_cwd, "main", "cli", tf)
f.user("另一個資料夾的對話")
f.assistant("這個對話屬於另一個資料夾。")

expected = []
for conv, mtime, title, source in specs:
    path = os.path.join(pdir, conv.id + ".jsonl")
    conv.write(path, mtime)
for conv, mtime in ((e, te), (f, tf)):
    conv.write(os.path.join(pdir, conv.id + ".jsonl"), mtime)

# a's per-session folder: <id>/subagents/agent-1.jsonl.
sibling = os.path.join(pdir, a.id)
os.makedirs(os.path.join(sibling, "subagents"), mode=0o700, exist_ok=True)
agent = Conversation(cwd, "fix/refresh", "cli", ta - 600, sidechain=True, agent="a1b2c3d4", session=a.id)
agent.user("找出所有呼叫 refresh() 的地方")
agent.assistant("共 3 處：middleware.ts、session.ts、cli.ts。")
agent.write(os.path.join(sibling, "subagents", "agent-1.jsonl"), ta - 300)
for p in (os.path.join(sibling, "subagents"), sibling):
    os.chmod(p, 0o700)
    os.utime(p, (ta - 300, ta - 300))
newest = max(m for _, m, _, _ in specs + [(None, te, None, None), (None, tf, None, None)])
os.utime(pdir, (newest, newest))

for conv, mtime, title, source in specs:
    path = os.path.join(pdir, conv.id + ".jsonl")
    age = int((now - mtime) // DAY)
    left = CLEANUP_DAYS - age
    expected.append({"id": conv.id, "title": title, "titleSource": source, "branch": conv.branch, "ageDays": age,
                     "expiresInDays": left if left <= WARN_WITHIN else None, "sizeBytes": os.path.getsize(path),
                     "mtimeMs": int(mtime * 1000), "createdAt": conv.lines[0].get("timestamp") or conv.lines[1]["timestamp"],
                     "path": path})
expected.sort(key=lambda x: -x["mtimeMs"])
manifest = {"cwd": cwd, "folder": folder, "projectsDir": pdir, "cleanupPeriodDays": CLEANUP_DAYS,
            "warnWithinDays": WARN_WITHIN, "generatedAtMs": int(now * 1000), "expected": expected,
            "hidden": [e.id, f.id], "hiddenReasons": {e.id: "sdk-cli", f.id: "other-cwd"}, "otherCwd": other_cwd,
            "siblingFolder": {"id": a.id, "path": sibling},
            "lastPrompt": {"id": a.id, "text": "順便補上過期 token 的測試"}}
tmp = manifest_path + ".tmp-%d" % os.getpid()
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(manifest, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
os.chmod(tmp, 0o600)
os.replace(tmp, manifest_path)
print(manifest_path)
PY
