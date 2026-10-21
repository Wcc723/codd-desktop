#!/usr/bin/python3 -I
# Writes a made-up PNG with zlib only (no PIL), for the M4 notes fixtures (docs/M4-PLAN.md C11).
#
#   make-png.py <out.png> <w> <h> [--phone] [--seed <n>] [--alpha]
#   -> prints <out.png>
#
# Default picture: a vertical gradient with a 64 px checker (compresses well; a 4000 x 3000 file is
# ~0.1 MB and takes well under a second). --seed shifts the colours, so two seeds give different bytes
# (D9 dedupe / collision tests). --alpha writes RGBA (colour type 6) with a transparent 64 x 64 corner.
# --phone draws the made-up iPhone SE punch page of the Notebook / ImageAnnotate artboards in
# 750 x 1334 coordinates (scaled to <w> x <h>): white status bar 0-40, white header 40-128, a big dark
# clock block 266-394, a date line, two light cards, a blue button band x 20-730 y 1150-1270 (so the
# SPEC R6 rect 1 lies on it), and a bottom nav band 1222-1334 drawn over the button like the bug.
# Refuses (exit 1) a target inside ~/Library, ~/.claude*, ~/.codex or ~ outside $TMPDIR; exit 2 on
# bad arguments. Python 3.9, standard library only; starts no process.
import os
import struct
import sys
import zlib

PHONE_W, PHONE_H = 750, 1334

# (x0, y0, x1, y1, rgb) in 750 x 1334 space, painted in order (later wins).
PHONE_RECTS = [
    (0, 0, 750, 40, (255, 255, 255)),          # status bar
    (24, 12, 84, 28, (17, 17, 17)),            # "9:32"
    (690, 13, 726, 27, (17, 17, 17)),          # battery
    (0, 40, 750, 127, (255, 255, 255)),        # header band
    (0, 127, 750, 129, (217, 214, 206)),       # header rule
    (330, 70, 420, 98, (29, 29, 29)),          # header title "打卡"
    (175, 266, 575, 394, (29, 29, 29)),        # big dark clock block
    (230, 408, 520, 432, (107, 103, 96)),      # date line
    (32, 472, 718, 600, (220, 216, 207)),      # card 1 border
    (34, 474, 716, 598, (255, 255, 255)),      # card 1 (shift)
    (60, 500, 300, 520, (138, 133, 124)),
    (60, 540, 360, 572, (29, 29, 29)),
    (560, 516, 690, 556, (159, 208, 180)),     # GPS chip
    (32, 632, 718, 1124, (220, 216, 207)),     # card 2 border
    (34, 634, 716, 1122, (255, 255, 255)),     # card 2 (records)
    (60, 660, 250, 690, (29, 29, 29)),
    (34, 718, 716, 720, (235, 232, 225)),
    (34, 818, 716, 820, (235, 232, 225)),
    (34, 918, 716, 920, (235, 232, 225)),
    (34, 1018, 716, 1020, (235, 232, 225)),
    (20, 1150, 730, 1270, (47, 111, 224)),     # the blue "上班打卡" button band
    (290, 1170, 460, 1206, (255, 255, 255)),   # button label
    (0, 1222, 750, 1334, (250, 250, 249)),     # bottom nav band (covers the button: the bug)
    (0, 1222, 750, 1224, (214, 210, 200)),
    (78, 1248, 118, 1288, (119, 115, 107)),    # nav icons
    (264, 1248, 304, 1288, (47, 111, 224)),
    (450, 1248, 490, 1288, (119, 115, 107)),
    (636, 1248, 676, 1288, (119, 115, 107)),
]
PHONE_BACKGROUND = (236, 235, 230)


def _protected(path):
    """Why `path` must not be written, or None (the M3 fixtures' rule)."""
    target = os.path.realpath(os.path.abspath(path))
    homes = set()
    if os.environ.get("HOME"):
        homes.add(os.path.realpath(os.environ["HOME"]))
    try:
        import pwd
        homes.add(os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir))
    except (ImportError, KeyError):
        pass
    tmp = os.path.realpath(os.environ.get("TMPDIR") or "/tmp")

    def inside(p, base):
        return p == base or p.startswith(base.rstrip("/") + "/")

    for home in homes:
        for name in ("Library", ".claude", ".claude.json", ".claude-swap-backup", ".codex"):
            if inside(target, os.path.join(home, name)):
                return "inside ~/" + name
        if inside(target, home) and not inside(target, tmp):
            return "inside ~ (outside $TMPDIR)"
    return None


def _chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)


def _rows_default(w, h, seed, alpha):
    channels = 4 if alpha else 3
    shift = (seed * 47) % 256
    for y in range(h):
        t = y / max(1, h - 1)
        a = ((40 + int(160 * t) + shift) % 256, (90 + shift // 2) % 256, (200 - int(150 * t) + shift) % 256)
        b = tuple(min(255, c + 36) for c in a)
        if alpha:
            a, b = a + (255,), b + (255,)
        block_a, block_b = bytes(a) * 64, bytes(b) * 64
        pair = (block_a + block_b) if (y // 64) % 2 == 0 else (block_b + block_a)
        row = (pair * (w // 128 + 1))[: w * channels]
        if alpha and y < 64:
            clear = bytes((0, 0, 0, 0)) * min(64, w)
            row = clear + row[len(clear):]
        yield row


def _rows_phone(w, h, alpha):
    channels = 4 if alpha else 3
    sx, sy = w / PHONE_W, h / PHONE_H
    rects = [(round(x0 * sx), round(y0 * sy), round(x1 * sx), round(y1 * sy), rgb) for x0, y0, x1, y1, rgb in PHONE_RECTS]
    bg = bytes(PHONE_BACKGROUND + ((255,) if alpha else ()))
    for y in range(h):
        row = bytearray(bg * w)
        for x0, y0, x1, y1, rgb in rects:
            if y0 <= y < y1 and x1 > x0:
                px = bytes(rgb + ((255,) if alpha else ()))
                x0c, x1c = max(0, x0), min(w, x1)
                if x1c > x0c:
                    row[x0c * channels:x1c * channels] = px * (x1c - x0c)
        yield bytes(row)


def png_bytes(w, h, phone=False, seed=0, alpha=False):
    """The PNG file bytes (8-bit RGB or RGBA, filter 0 on every row, one IDAT)."""
    if w < 1 or h < 1:
        raise ValueError("size must be positive")
    rows = _rows_phone(w, h, alpha) if phone else _rows_default(w, h, seed, alpha)
    comp = zlib.compressobj(6)
    parts = []
    for row in rows:
        parts.append(comp.compress(b"\x00" + row))
    parts.append(comp.flush())
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6 if alpha else 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + _chunk(b"IHDR", ihdr) + _chunk(b"IDAT", b"".join(parts)) + _chunk(b"IEND", b"")


def write_png(path, w, h, phone=False, seed=0, alpha=False):
    """Writes atomically (temp + rename in the same folder), mode 0600; missing parents 0700."""
    data = png_bytes(w, h, phone=phone, seed=seed, alpha=alpha)
    folder = os.path.dirname(os.path.abspath(path))
    missing = []
    p = folder
    while not os.path.isdir(p) and os.path.dirname(p) != p:
        missing.append(p)
        p = os.path.dirname(p)
    for d in reversed(missing):
        os.mkdir(d, 0o700)
        os.chmod(d, 0o700)
    tmp = os.path.join(folder, ".%s.%d.tmp" % (os.path.basename(path), os.getpid()))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    os.replace(tmp, path)
    return len(data)


def _usage(message=None):
    if message:
        print("make-png: " + message, file=sys.stderr)
    print("usage: make-png.py <out.png> <w> <h> [--phone] [--seed <n>] [--alpha]", file=sys.stderr)
    sys.exit(2)


def main(argv):
    pos, phone, seed, alpha = [], False, 0, False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--phone":
            phone = True
        elif a == "--alpha":
            alpha = True
        elif a == "--seed":
            if i + 1 >= len(argv):
                _usage("--seed needs a value")
            try:
                seed = int(argv[i + 1])
            except ValueError:
                _usage("--seed must be an integer")
            i += 1
        elif a.startswith("-") and a != "-":
            _usage("unknown option " + a)
        else:
            pos.append(a)
        i += 1
    if len(pos) != 3:
        _usage()
    out = pos[0]
    try:
        w, h = int(pos[1]), int(pos[2])
    except ValueError:
        _usage("width and height must be integers")
    if not (1 <= w <= 20000 and 1 <= h <= 20000):
        _usage("width and height must be 1...20000")
    why = _protected(out)
    if why:
        print("make-png: refusing %s (%s)" % (out, why), file=sys.stderr)
        sys.exit(1)
    write_png(out, w, h, phone=phone, seed=seed, alpha=alpha)
    print(out)


if __name__ == "__main__":
    main(sys.argv[1:])
