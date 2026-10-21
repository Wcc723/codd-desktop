#!/usr/bin/env python3
"""Expand include markers in src/<Name>.src.html -> canvas/project/<Name>.dc.html, then lint.

Markers (each on its own, exactly as written):
  <!--@HELMET-->                       shared fonts + CSS (spec/helmet.html), put inside <helmet>
  <!--@SHELL on=sessions current=s1-->  traffic lights + rail + SESSIONS sidebar
  <!--@RAIL on=notes-->                 traffic lights + rail only (on = sessions|notes|status|settings|none)
  <!--@SIDEBAR current=s9-->            SESSIONS sidebar only (current = s1..s14 | none)
  <!--@STATUSBAR-->                     app status bar (MCP · hooks · counts · ⌘K)

Usage: python3 -I build_dc.py Main            (reads src/Main.src.html)
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
SPEC = os.path.join(ROOT, "spec")

STATUSBAR = ('<div class="statusbar"><span><span class="lamp st-busy" style="width:auto">●</span> MCP 127.0.0.1:47821 · 3 clients</span>'
             '<span>hooks <span class="ok">●</span> ok</span><span style="flex:1"></span>'
             '<span class="num">13 live · <span class="amber">◆ 3</span> · <span class="ok">● 4</span></span><span class="kbd">⌘K</span></div>')


def read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def split_shell():
    s = read(os.path.join(SPEC, "shell-sessions.html"))
    i = s.find('<div class="tl"')
    j = s.find("</nav>") + len("</nav>")
    k = s.find('<aside class="side"')
    m = s.find("</aside>") + len("</aside>")
    return s[i:j], s[k:m]


def set_rail(rail, on):
    rail = rail.replace('class="ri on" href="#sessions" aria-current="page"', 'class="ri" href="#sessions"')
    if on and on != "none":
        rail = rail.replace(f'class="ri" href="#{on}"', f'class="ri on" href="#{on}" aria-current="page"', 1)
    return rail


def set_current(side, cur):
    side = re.sub(r'(class="srow[^"]*?) current"', r'\1"', side)
    if cur and cur != "none":
        side = re.sub(r'(class="srow[^"]*?)"( href="#%s")' % re.escape(cur), r'\1 current"\2', side)
    return side


def opts(s):
    return dict(re.findall(r"(\w+)=([\w-]+)", s or ""))


def expand(src):
    helmet = read(os.path.join(SPEC, "helmet.html"))
    rail, side = split_shell()

    def rep(m):
        kind, arg = m.group(1), opts(m.group(2))
        if kind == "HELMET":
            return helmet
        if kind == "STATUSBAR":
            return STATUSBAR
        if kind == "RAIL":
            return set_rail(rail, arg.get("on", "sessions"))
        if kind == "SIDEBAR":
            return set_current(side, arg.get("current", "s1"))
        if kind == "SHELL":
            return set_rail(rail, arg.get("on", "sessions")) + "\n" + set_current(side, arg.get("current", "s1"))
        return m.group(0)

    return re.sub(r"<!--@(HELMET|SHELL|RAIL|SIDEBAR|STATUSBAR)((?:\s+\w+=[\w-]+)*)\s*-->", rep, src)


def main():
    for name in sys.argv[1:]:
        name = name.replace(".src.html", "").replace(".dc.html", "")
        src = read(os.path.join(ROOT, "src", name + ".src.html"))
        out = expand(src)
        dst = os.path.join(ROOT, "canvas", "project", name + ".dc.html")
        with open(dst, "w", encoding="utf-8") as f:
            f.write(out)
        print(f"built {dst} ({len(out.encode('utf-8'))/1024:.0f} KB)")
        subprocess.run([sys.executable, "-I", os.path.join(ROOT, "dc_lint.py"), dst])


if __name__ == "__main__":
    main()
