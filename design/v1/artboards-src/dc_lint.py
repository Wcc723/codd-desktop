#!/usr/bin/env python3
"""Static lint for Design-canvas .dc.html artboards (CODD Desktop mockups).

Usage: python3 -I dc_lint.py <file.dc.html> [...]
Exit code 0 = no errors (warnings may still print), 1 = errors found.
"""
import html
import json
import re
import sys
from html.parser import HTMLParser

VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
        "param", "source", "track", "wbr"}
# SVG elements that are commonly self-closed; we allow "/>" for these.
SVG_SELF = {"path", "rect", "circle", "line", "polyline", "polygon", "ellipse", "stop", "use"}

EMOJI_CPS = set()
for a, b in [(0x1F000, 0x1FAFF), (0x2600, 0x2604), (0x2606, 0x26FF), (0x23E9, 0x23FA), (0x2B50, 0x2B55),
             (0x231A, 0x231B), (0x2753, 0x2757), (0x2795, 0x2797)]:
    EMOJI_CPS.update(range(a, b + 1))
EMOJI_CPS.update([0xFE0F, 0x25B6, 0x25C0, 0x2328, 0x270F, 0x2714, 0x2716, 0x2705, 0x274C,
                  0x274E, 0x27A1, 0x27B0, 0x27BF, 0x2934, 0x2935, 0x3030, 0x303D, 0x3297,
                  0x3299, 0x2702, 0x2708, 0x2709, 0x270A, 0x270B, 0x270C, 0x270D, 0x2712,
                  0x2728, 0x2733, 0x2734, 0x2744, 0x2747, 0x2763, 0x2764, 0x23CF, 0x24C2,
                  0x2B05, 0x2B06, 0x2B07, 0x2B1B, 0x2B1C, 0x00A9, 0x00AE, 0x203C, 0x2049,
                  0x2122, 0x2139, 0x21A9, 0x21AA, 0x23FA])

HOLE_OK = re.compile(r"^\s*(?:[A-Za-z_$][\w$]*(?:\.[\w$]+)*|true|false|null|-?\d+(?:\.\d+)?|'[^']*'|\"[^\"]*\")\s*$")


class Checker(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack = []
        self.errors = []
        self.in_xdc = False
        self.sc_for = 0

    def handle_starttag(self, tag, attrs):
        line = self.getpos()[0]
        a = dict(attrs)
        if tag == "x-dc":
            self.in_xdc = True
        if tag in ("iframe", "object", "embed"):
            self.errors.append(f"L{line}: forbidden <{tag}>")
        if tag == "sc-for":
            if "list" not in a or "as" not in a:
                self.errors.append(f"L{line}: <sc-for> needs list= and as=")
            if "hint-placeholder-count" not in a:
                self.errors.append(f"L{line}: <sc-for> missing hint-placeholder-count")
        if tag == "sc-if":
            if "value" not in a:
                self.errors.append(f"L{line}: <sc-if> needs value=")
            if "hint-placeholder-val" not in a:
                self.errors.append(f"L{line}: <sc-if> missing hint-placeholder-val")
        for k, v in attrs:
            if k.startswith("on") and k != k.lower() and v is not None:
                if not re.fullmatch(r"\s*\{\{[^{}]+\}\}\s*", v):
                    self.errors.append(f"L{line}: event attr {k} must be a single {{{{ handler }}}} hole")
            if k in ("src", "href") and v and re.match(r"https?://", v):
                if not v.startswith("https://fonts.googleapis.com/css2"):
                    if not (k == "href" and tag == "a"):
                        self.errors.append(f"L{line}: external {k}={v[:60]} (only Google Fonts css2 allowed)")
        if tag not in VOID:
            self.stack.append((tag, line))

    def handle_startendtag(self, tag, attrs):
        line = self.getpos()[0]
        if tag not in VOID and tag not in SVG_SELF:
            self.errors.append(f"L{line}: self-closed non-void <{tag}/> (close it explicitly)")
        # treat as opened+closed: do nothing for the stack
        # still run attribute checks
        self.handle_starttag_attrs_only(tag, attrs, line)

    def handle_starttag_attrs_only(self, tag, attrs, line):
        for k, v in attrs:
            if k in ("src", "href") and v and re.match(r"https?://", v):
                if not v.startswith("https://fonts.googleapis.com/css2"):
                    self.errors.append(f"L{line}: external {k}={v[:60]}")

    def handle_endtag(self, tag):
        line = self.getpos()[0]
        if tag in VOID:
            return
        if tag in ("html", "head") and tag not in [t for t, _ in self.stack]:
            return
        if not self.stack:
            self.errors.append(f"L{line}: stray </{tag}>")
            return
        if self.stack[-1][0] == tag:
            self.stack.pop()
            return
        # find matching open
        names = [t for t, _ in self.stack]
        if tag in names:
            while self.stack and self.stack[-1][0] != tag:
                t, l = self.stack.pop()
                self.errors.append(f"L{l}: <{t}> not closed before </{tag}> at L{line}")
            self.stack.pop()
        else:
            self.errors.append(f"L{line}: stray </{tag}> (open stack top: <{self.stack[-1][0]}> from L{self.stack[-1][1]})")


def lint(path):
    errs, warns = [], []
    src = open(path, encoding="utf-8").read()
    if '<script src="./support.js"></script>' not in src:
        errs.append('missing exact head line <script src="./support.js"></script>')
    if not re.search(r"<html[^>]*\blang=\"[^\"]+\"", src):
        errs.append("<html> missing lang=")
    if "<title>" not in src:
        errs.append("missing <title>")
    if src.count("<x-dc>") != 1 or "</x-dc>" not in src:
        errs.append("need exactly one <x-dc> ... </x-dc>")
    xdc = src[src.find("<x-dc>"):src.rfind("</x-dc>")] if "<x-dc>" in src else ""
    if "<helmet>" not in xdc:
        warns.append("no <helmet> inside <x-dc>")
    m = re.search(r"<script type=\"text/x-dc\" data-dc-script data-props='([^']*)'>(.*?)</script>", src, re.S)
    if not m:
        errs.append("missing <script type=\"text/x-dc\" data-dc-script data-props='...'> block (single-quoted data-props)")
        script = ""
    else:
        raw, script = m.group(1), m.group(2)
        try:
            props = json.loads(html.unescape(raw))
            pv = props.get("$preview")
            if not (isinstance(pv, dict) and "width" in pv and "height" in pv):
                errs.append("data-props lacks $preview {width,height}")
        except Exception as e:  # noqa
            errs.append(f"data-props is not valid JSON after entity decode: {e}")
        if "class Component extends DCLogic" not in script:
            errs.append("script lacks 'class Component extends DCLogic'")
        if re.search(r"\b(import|export)\b\s", script):
            errs.append("script uses import/export")
        for bad in ("innerHTML", "appendChild", "createElement", "insertAdjacentHTML", "document.write"):
            if bad in script:
                errs.append(f"script uses {bad} (UI must be <x-dc> markup)")
        if re.search(r"addEventListener\(\s*['\"]key", script):
            errs.append("global key listener in script")
        if re.search(r"\bwindow\.[A-Za-z_]+\s*=", script):
            errs.append("script assigns window.X")
        if "render()" in script and "renderVals" not in script:
            errs.append("uses render() instead of renderVals()")
    for lm in re.finditer(r"\son(click|change|input|mouse\w*|key\w*)=", xdc):
        ln = xdc[:lm.start()].count("\n") + 1
        errs.append(f"x-dc L~{ln}: lowercase inline handler on{lm.group(1)}= (use onClick=\"{{{{ fn }}}}\")")
    # holes
    for hm in re.finditer(r"\{\{(.*?)\}\}", xdc, re.S):
        inner = hm.group(1)
        if not HOLE_OK.match(inner):
            ln = xdc[:hm.start()].count("\n") + 1
            errs.append(f"x-dc L~{ln}: hole is not a dotted lookup/literal: {{{{{inner.strip()[:50]}}}}}")
    # unquoted attributes inside tags (rough)
    for tm in re.finditer(r"<([a-zA-Z][\w-]*)(\s[^<>]*?)>", xdc):
        attrs = tm.group(2)
        # strip quoted values
        stripped = re.sub(r"\"[^\"]*\"|'[^']*'", "", attrs)
        if re.search(r"[\w:-]+=[^\s\"'>/]", stripped):
            ln = xdc[:tm.start()].count("\n") + 1
            errs.append(f"x-dc L~{ln}: unquoted attribute in <{tm.group(1)} ...>")
    # emoji
    for i, ch in enumerate(src):
        if ord(ch) in EMOJI_CPS:
            ln = src[:i].count("\n") + 1
            errs.append(f"L{ln}: emoji-capable char U+{ord(ch):04X} '{ch}'")
            if len(errs) > 80:
                break
    # tag balance inside body
    body = src[src.find("<body"):] if "<body" in src else src
    c = Checker()
    try:
        c.feed(body)
        c.close()
    except Exception as e:  # noqa
        errs.append(f"parser error: {e}")
    errs.extend(c.errors)
    for t, l in c.stack:
        if t not in ("body", "html"):
            errs.append(f"L{l}: <{t}> never closed")
    # heuristics
    if "role=\"button\"" in xdc or "role='button'" in xdc:
        warns.append("role=button found: use a real <button> or <a href>")
    if re.search(r"<(div|span)[^>]*\bonClick=", xdc):
        warns.append("onClick on div/span: use <button>/<a> for accessibility")
    if "font-family: Inter" in src or "'Inter'" in src or "Roboto" in src:
        warns.append("Inter/Roboto font used")
    size = len(src.encode("utf-8"))
    if size > 400_000:
        warns.append(f"file is large: {size/1024:.0f} KB")
    return errs, warns


def main():
    bad = 0
    for p in sys.argv[1:]:
        errs, warns = lint(p)
        print(f"== {p}: {len(errs)} error(s), {len(warns)} warning(s)")
        for e in errs:
            print("  ERROR", e)
        for w in warns:
            print("  warn ", w)
        bad += bool(errs)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
