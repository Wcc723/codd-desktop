#!/bin/bash
# Seeds a CODD data root with a sidebar layout (docs/M2-PLAN.md C4, §6 "seeded layout reproduced"):
# project folders under <workDir> and <dataRoot>/layout.json in CoddCore's exact format (LayoutStore:
# version 1, pretty-printed with sorted keys and "key" : value, ISO-8601 dates as JSDate.isoString
# writes them, ColorTag raw values, lowercase UUIDs (the app writes them back upper case: compare
# ids case-insensitively), an ungrouped project has no groupId).
#
#   groups    藍鵲 · 網站 (blue), 個人 · Github (green)
#   projects  northstar-site (藍鵲 · 網站), 整合範例 (藍鵲 · 網站, collapsed), codd-desktop (個人 · Github, no
#             sessions), scratch (未分類)
#   sessions  claude "修正登入 API 401" (titleOverride, pinned, color orange) and an archived claude
#             "舊的部署腳本" in northstar-site; claude "refresh token 流程改寫" (title) in 整合範例; shell
#             "zsh" in scratch. Claude sessions carry a claudeSessionId (the pinned one equal to its own
#             id like a fresh session, the others different like after /clear); none has a holder, so
#             CODD shows the claude ones STOPPED and the shell EXITED.
#
#   scripts/m2-fixtures/seed-layout.sh <dataRoot> <workDir>
#   -> prints the path of <dataRoot>/manifest-layout.json:
#      {dataRoot, workDir, layout, groups [{id,name,color,order}], groupOrder (names, then 未分類 as the
#       app appends it), projects [{id,name,path,groupId,group,order,collapsed,sessions,archived}],
#       sessions [{id,kind,title,projectId,claudeSessionId,pinned,archived,order,color}],
#       pinned, archived, collapsedProject, ungroupedProject, cjkProject, visibleSessions}
# Directories 0700, files 0600; <dataRoot> is created when missing (a make-root.sh root works).
# Refuses (exit 1) when layout.json exists or a path is inside ~/Library or ~/.claude. Starts no process.
set -u

usage() {
    cat >&2 <<'EOF'
usage: seed-layout.sh <dataRoot> <workDir>
  Creates 4 project folders under <workDir>, writes <dataRoot>/layout.json (CoddCore format) and
  prints the path of <dataRoot>/manifest-layout.json. Refuses an existing layout.json.
EOF
    exit 2
}
[[ $# -eq 2 && -n "$1" && -n "$2" && "$1" != -* ]] || usage

exec "${PYTHON3:-python3}" -I - "$1" "$2" <<'PY'
import json, os, pwd, sys, time, uuid

data_root, work_dir = sys.argv[1], sys.argv[2]

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

for p in (data_root, work_dir):
    if protected(p):
        sys.exit("seed-layout: refusing %s (inside ~, ~/Library or ~/.claude)" % p)
for p in (data_root, work_dir):
    if not os.path.isabs(p):
        print("seed-layout: paths must be absolute", file=sys.stderr)
        sys.exit(2)

def iso(t):
    ms = int(round(t * 1000))
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(ms // 1000)) + ".%03dZ" % (ms % 1000)

def uid():
    return str(uuid.uuid4())

def create_exclusive(path, data):
    """Temp file + link: atomic, and never replaces an existing file."""
    tmp = path + ".tmp-%d" % os.getpid()
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    try:
        os.link(tmp, path)
    except FileExistsError:
        os.unlink(tmp)
        sys.exit("seed-layout: %s already exists; refusing" % path)
    os.unlink(tmp)

def encode(obj):
    # JSONEncoder [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]: 2 spaces, "key" : value, UTF-8.
    return (json.dumps(obj, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : ")) + "\n").encode("utf-8")

layout_path = os.path.join(data_root, "layout.json")
if os.path.lexists(layout_path):
    sys.exit("seed-layout: %s already exists; refusing" % layout_path)
for d in (data_root, work_dir):
    if not os.path.isdir(d):
        os.makedirs(d, mode=0o700, exist_ok=True)
        os.chmod(d, 0o700)

now = time.time()
DAY = 86400
g_site = {"id": uid(), "name": "藍鵲 · 網站", "color": "blue", "order": 0, "collapsed": False}
g_mine = {"id": uid(), "name": "個人 · Github", "color": "green", "order": 1, "collapsed": False}
groups = [g_site, g_mine]

def project(name, group, order, collapsed=False):
    path = os.path.join(work_dir, name)
    os.makedirs(path, mode=0o700, exist_ok=True)
    os.chmod(path, 0o700)
    p = {"id": uid(), "name": name, "path": path, "order": order, "pinned": False, "collapsed": collapsed}
    if group:
        p["groupId"] = group["id"]
    return p

p_site = project("northstar-site", g_site, 0)
p_cjk = project("整合範例", g_site, 1, collapsed=True)
p_codd = project("codd-desktop", g_mine, 0)
p_scratch = project("scratch", None, 0)
projects = [p_site, p_cjk, p_codd, p_scratch]

def session(project, kind, order, created_days, **fields):
    s = {"id": uid(), "projectId": project["id"], "kind": kind, "order": order, "pinned": False, "color": "none",
         "createdAt": iso(now - created_days * DAY)}
    s.update(fields)
    return s

s_pinned = session(p_site, "claude", 0, 3, titleOverride="修正登入 API 401", title="Fix login API 401",
                   color="orange", pinned=True, launchProfileId="claude-default",
                   lastState={"kind": "idle"}, lastStateAt=iso(now - 3600), lastViewedAt=iso(now - 3000))
s_pinned["claudeSessionId"] = s_pinned["id"]
s_archived = session(p_site, "claude", 1, 9, title="舊的部署腳本", claudeSessionId=uid(),
                     launchProfileId="claude-default", lastState={"kind": "stopped"},
                     lastStateAt=iso(now - 2 * DAY), archivedAt=iso(now - DAY))
s_cjk = session(p_cjk, "claude", 0, 2, title="refresh token 流程改寫", claudeSessionId=uid(),
                launchProfileId="claude-default", lastState={"kind": "idle"}, lastStateAt=iso(now - 7200))
s_shell = session(p_scratch, "shell", 0, 1, title="zsh", lastState={"kind": "exited", "code": 0},
                  lastStateAt=iso(now - 600))
sessions = [s_pinned, s_archived, s_cjk, s_shell]

layout = {"version": 1, "groups": groups, "projects": projects, "sessions": sessions}
create_exclusive(layout_path, encode(layout))

def title(s):
    return s.get("titleOverride") or s.get("title")

group_by_id = {g["id"]: g for g in groups}
manifest = {
    "dataRoot": data_root, "workDir": work_dir, "layout": layout_path,
    "groups": [{"id": g["id"], "name": g["name"], "color": g["color"], "order": g["order"]} for g in groups],
    "groupOrder": [g["name"] for g in groups] + ["未分類"],
    "projects": [{"id": p["id"], "name": p["name"], "path": p["path"], "groupId": p.get("groupId"),
                  "group": group_by_id[p["groupId"]]["name"] if p.get("groupId") else "未分類",
                  "order": p["order"], "collapsed": p["collapsed"],
                  "sessions": [s["id"] for s in sessions if s["projectId"] == p["id"] and "archivedAt" not in s],
                  "archived": [s["id"] for s in sessions if s["projectId"] == p["id"] and "archivedAt" in s]}
                 for p in projects],
    "sessions": [{"id": s["id"], "kind": s["kind"], "title": title(s), "projectId": s["projectId"],
                  "claudeSessionId": s.get("claudeSessionId"), "pinned": s["pinned"], "archived": "archivedAt" in s,
                  "order": s["order"], "color": s["color"]} for s in sessions],
    "pinned": s_pinned["id"], "archived": s_archived["id"], "collapsedProject": p_cjk["id"],
    "ungroupedProject": p_scratch["id"], "cjkProject": p_cjk["id"],
    "visibleSessions": [s["id"] for s in sessions if "archivedAt" not in s],
}
manifest_path = os.path.join(data_root, "manifest-layout.json")
tmp = manifest_path + ".tmp-%d" % os.getpid()
with open(tmp, "wb") as fh:
    fh.write((json.dumps(manifest, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))
os.chmod(tmp, 0o600)
os.replace(tmp, manifest_path)
print(manifest_path)
PY
