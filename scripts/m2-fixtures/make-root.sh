#!/bin/bash
# Creates a CODD data root for a test or manual run with its OWN hook endpoint (docs/M2-PLAN.md D24,
# §8): <root> (0700, parents as needed) and <root>/config.json in the exact format HookConfigStore
# reads ({"port":<n>,"token":"<64 hex>","v":1}, 0600, like scripts/m1-e2e.sh writes it). The port is
# a random one in 43000-43999 that is free right now, so a test instance never takes the port the
# user's own CODD (47821-47899) and its claude sessions post to.
#
#   scripts/m2-fixtures/make-root.sh "$(mktemp -d "${TMPDIR:-/tmp}/codd-x.XXXXXX")/root"
#   -> prints "<port> <token>"
#
# Refuses (exit 1) when <root>/config.json already exists or <root> is inside ~/Library or ~/.claude.
# Exit 2: bad arguments or no free port. Starts no process.
set -u

usage() {
    cat >&2 <<'EOF'
usage: make-root.sh <root>
  Creates <root> (0700) and <root>/config.json (0600) with a free port in 43000-43999 and a
  fresh 32-byte hex token. Prints "<port> <token>". Refuses an existing config.json.
EOF
    exit 2
}
[[ $# -eq 1 && -n "$1" && "$1" != -* ]] || usage

exec "${PYTHON3:-python3}" -I - "$1" <<'PY'
import os, pwd, random, secrets, socket, sys

root = sys.argv[1]

def protected(path):
    """Inside ~/Library or ~/.claude (or ~ itself): never written by fixtures."""
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

if protected(root):
    sys.exit("make-root: refusing %s (inside ~, ~/Library or ~/.claude)" % root)

def free_port():
    for _ in range(500):
        port = random.randint(43000, 43999)
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            s.bind(("127.0.0.1", port))  # no SO_REUSEADDR, like HookConfigStore's PortProbe
        except OSError:
            continue
        finally:
            s.close()
        return port
    return None

os.makedirs(root, mode=0o700, exist_ok=True)
os.chmod(root, 0o700)
config = os.path.join(root, "config.json")
if os.path.lexists(config):
    sys.exit("make-root: %s already exists; refusing to replace it" % config)
port = free_port()
if port is None:
    print("make-root: no free port in 43000-43999", file=sys.stderr)
    sys.exit(2)
token = secrets.token_hex(32)
try:
    fd = os.open(config, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
except FileExistsError:
    sys.exit("make-root: %s already exists; refusing to replace it" % config)
with os.fdopen(fd, "w") as f:
    f.write('{"port":%d,"token":"%s","v":1}\n' % (port, token))
    os.fchmod(f.fileno(), 0o600)
print(port, token)
PY
