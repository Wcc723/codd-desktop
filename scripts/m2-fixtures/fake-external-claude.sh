#!/bin/bash
# A claude "started outside CODD" for the M2 end-to-end run (docs/M2-PLAN.md D6, D27, C4): a
# long-lived dummy process whose argv carries <marker>, plus the registry file a real claude keeps,
# <claudeDir>/sessions/<pid>.json (pid, sessionId, cwd, startedAt ms, procStart = `TZ=UTC ps -o
# lstart=` in the C locale, version, kind, entrypoint, name, status, waitingFor, statusUpdatedAt,
# updatedAt), always written atomically (temp file + rename in the same folder).
#
#   start <claudeDir> <cwd> <marker> [status] [name] [waitingFor]
#       Detached dummy (own session, like a claude in another terminal). Prints "<pid> <sessionId>".
#   host <claudeDir> <cwd> <marker> [status] [name]
#       Same, but the dummy is a child of this script's process; "<pid> <sessionId>" also goes to
#       <claudeDir>/host-<basename of marker>.txt; then `exec cat` keeps the pid (argv[0] becomes
#       "fake-external-host <marker>"), so the dummy's parent stays alive. Use it as a CODD shell's
#       argv (-codd-shell-argv, split on spaces: no spaces in the paths): the dummy's ancestor chain
#       then contains that shell's holder.
#   set-status <claudeDir> <pid> <status> [waitingFor]
#       Rewrites the file with a new status / statusUpdatedAt (waitingFor dropped unless given).
#       `waiting` + `permission prompt` is a permission wait, `input needed` a question.
#   stop <claudeDir> <pid>
#       Removes the file and kills the dummy (only a process whose argv names <claudeDir>/sessions).
#
# Optional environment for `start` / `host`: FAKE_EXT_SESSION_ID (instead of a fresh uuid),
# FAKE_EXT_ENTRYPOINT (default cli, e.g. sdk-cli), FAKE_EXT_KIND (default interactive).
# The dummy removes its own file on SIGTERM / SIGHUP / SIGINT (like claude on a clean exit), so a
# SIGKILL is the way to leave a stale file behind. It ends by itself after an hour.
set -u

usage() {
    cat >&2 <<'EOF'
usage: fake-external-claude.sh start <claudeDir> <cwd> <marker> [status] [name] [waitingFor]
       fake-external-claude.sh host <claudeDir> <cwd> <marker> [status] [name]
       fake-external-claude.sh set-status <claudeDir> <pid> <status> [waitingFor]
       fake-external-claude.sh stop <claudeDir> <pid>
  start/host print "<pid> <sessionId>"; status defaults to busy, name to "external test".
EOF
    exit 2
}

[[ $# -ge 1 ]] || usage
cmd="$1"; shift
PY="${PYTHON3:-python3}"

# The registry writer and the other file operations (python3 -I, stdin = this program).
registry() {
    "$PY" -I - "$@" <<'PY'
import json, os, pwd, subprocess, sys, time, uuid

def now_ms():
    return int(time.time() * 1000)

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

def proc_start(pid):
    out = subprocess.run(["/bin/ps", "-o", "lstart=", "-p", str(pid)], stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, env={"LC_ALL": "C", "TZ": "UTC", "PATH": "/usr/bin:/bin"}).stdout
    return " ".join(out.decode("ascii", "replace").split()) or None

def write_atomic(path, data):
    directory = os.path.dirname(path)
    tmp = os.path.join(directory, ".%s.tmp-%d" % (os.path.basename(path), os.getpid()))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    os.replace(tmp, path)

def encode(obj):
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8")

op, claude_dir = sys.argv[1], sys.argv[2]
if protected(claude_dir):
    sys.exit("fake-external-claude: refusing %s (inside ~, ~/Library or ~/.claude)" % claude_dir)
sessions = os.path.join(claude_dir, "sessions")

if op == "prepare":
    os.makedirs(sessions, mode=0o700, exist_ok=True)
elif op == "register":
    pid, cwd, status, name, waiting, host_file = int(sys.argv[3]), sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7], sys.argv[8]
    session = os.environ.get("FAKE_EXT_SESSION_ID") or str(uuid.uuid4())
    start = proc_start(pid)
    if start is None:
        sys.exit("fake-external-claude: dummy %d is not running" % pid)
    stamp = now_ms()
    entry = {"pid": pid, "sessionId": session, "cwd": cwd, "startedAt": stamp, "procStart": start,
             "version": "2.1.300", "kind": os.environ.get("FAKE_EXT_KIND") or "interactive",
             "entrypoint": os.environ.get("FAKE_EXT_ENTRYPOINT") or "cli", "name": name, "status": status}
    if waiting:
        entry["waitingFor"] = waiting
    entry["statusUpdatedAt"] = stamp
    entry["updatedAt"] = stamp
    write_atomic(os.path.join(sessions, "%d.json" % pid), encode(entry))
    line = "%d %s" % (pid, session)
    if host_file:
        write_atomic(host_file, (line + "\n").encode("utf-8"))
    print(line)
elif op == "set-status":
    pid, status = int(sys.argv[3]), sys.argv[4]
    waiting = sys.argv[5] if len(sys.argv) > 5 else ""
    path = os.path.join(sessions, "%d.json" % pid)
    try:
        with open(path, "rb") as f:
            entry = json.loads(f.read().decode("utf-8"))
    except (OSError, ValueError) as e:
        sys.exit("fake-external-claude: cannot read %s: %s" % (path, e))
    entry["status"] = status
    entry.pop("waitingFor", None)
    if waiting:
        entry["waitingFor"] = waiting
    stamp = now_ms()
    if stamp <= entry.get("statusUpdatedAt", 0):
        stamp = entry["statusUpdatedAt"] + 1  # strictly newer, even within one millisecond
    entry["statusUpdatedAt"] = stamp
    entry["updatedAt"] = stamp
    write_atomic(path, encode(entry))
elif op == "remove":
    pid = int(sys.argv[3])
    try:
        os.unlink(os.path.join(sessions, "%d.json" % pid))
    except FileNotFoundError:
        pass
PY
}

# The dummy: argv = perl -e <code> <claudeDir>/sessions <marker>; removes <pid>.json when signalled.
DUMMY_CODE='my ($d) = @ARGV; my $f = "$d/$$.json"; my $bye = sub { unlink $f; exit 0 }; $SIG{TERM} = $bye; $SIG{HUP} = $bye; $SIG{INT} = $bye; sleep 3600; unlink $f; exit 0;'
DETACHED_CODE="use POSIX (); POSIX::setsid(); $DUMMY_CODE"

strip() { local p="$1"; while [[ ${#p} -gt 1 && "$p" == */ ]]; do p="${p%/}"; done; printf '%s' "$p"; }

case "$cmd" in
    start|host)
        [[ $# -ge 3 && $# -le 6 && -n "$1" && -n "$2" && -n "$3" ]] || usage
        [[ "$cmd" == start || $# -le 5 ]] || usage
        dir="$(strip "$1")"; cwd="$2"; marker="$3"
        status="${4:-busy}"; name="${5:-external test}"; waiting="${6:-}"
        registry prepare "$dir" || exit 1
        host_file=""
        if [[ "$cmd" == start ]]; then
            perl -e "$DETACHED_CODE" "$dir/sessions" "$marker" </dev/null >/dev/null 2>&1 &
        else
            perl -e "$DUMMY_CODE" "$dir/sessions" "$marker" </dev/null >/dev/null 2>&1 &
            host_file="$dir/host-$(basename "$marker").txt"
        fi
        pid=$!
        if ! line="$(registry register "$dir" "$pid" "$cwd" "$status" "$name" "$waiting" "$host_file")"; then
            kill -TERM "$pid" 2>/dev/null
            exit 1
        fi
        printf '%s\n' "$line"
        if [[ "$cmd" == host ]]; then
            exec -a "fake-external-host $marker" /bin/cat
        fi
        ;;
    set-status)
        [[ $# -ge 3 && $# -le 4 && "$2" =~ ^[0-9]+$ && -n "$3" ]] || usage
        registry set-status "$(strip "$1")" "$2" "$3" "${4:-}"
        ;;
    stop)
        [[ $# -eq 2 && "$2" =~ ^[0-9]+$ ]] || usage
        dir="$(strip "$1")"; pid="$2"
        registry remove "$dir" "$pid" || exit 1
        command="$(ps -o command= -p "$pid" 2>/dev/null)"
        if [[ -z "$command" ]]; then
            exit 0
        fi
        if [[ "$command" != *"$dir/sessions"* ]]; then
            echo "fake-external-claude: pid $pid is not a dummy of $dir (not killed)" >&2
            exit 1
        fi
        # Gone or a zombie (a `host` dummy's parent is cat, which never reaps it) counts as stopped.
        ended() { local s; s="$(ps -o stat= -p "$pid" 2>/dev/null)"; [[ -z "$s" || "$s" == Z* ]]; }
        kill -TERM "$pid" 2>/dev/null
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
            ended && exit 0
            sleep 0.1
        done
        kill -KILL "$pid" 2>/dev/null
        sleep 0.2
        ended
        ;;
    *)
        usage
        ;;
esac
