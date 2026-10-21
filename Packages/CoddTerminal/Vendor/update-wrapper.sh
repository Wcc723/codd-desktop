#!/bin/bash
# Re-vendors libghostty-spm's Swift wrapper (Sources/GhosttyTerminal) into Sources/GhosttyWrapper.
#
#   Vendor/update-wrapper.sh <libghostty-spm checkout> [--out <dir>]
#       Copies the macOS subset of the checkout's wrapper, applies Vendor/GhosttyWrapper-CODD.patch
#       and adds the attribution header. Sources/GhosttyWrapper/CODD/ (CODD's own code) is kept.
#       Update the commit in the header below, in NOTICE and in README.md when moving upstream.
#   Vendor/update-wrapper.sh --diff <libghostty-spm checkout>
#       Regenerates Vendor/GhosttyWrapper-CODD.patch from the current Sources/GhosttyWrapper.
#
# Run from Packages/CoddTerminal. A checkout of the pinned release lands in any SwiftPM scratch path,
# e.g. ../../.build-terminal/checkouts/libghostty-spm.
set -euo pipefail

cd "$(dirname "$0")/.."
PATCH="Vendor/GhosttyWrapper-CODD.patch"
VENDORED="Sources/GhosttyWrapper"
HEADER='// Vendored from libghostty-spm (https://github.com/Lakr233/libghostty-spm), commit d403978c6687
// (release 2.2.2026101301), Sources/GhosttyTerminal. MIT License, Copyright (c) 2026 @Lakr233;
// see Packages/CoddTerminal/NOTICE. CODD changes are marked `CODD:`.'
HEADER_LINES=3

# Every Swift file of the wrapper except the UIKit platform code (relative paths, sorted).
upstream_files() {
    (cd "$1" && find . -name '*.swift' ! -path './Platform/UIKit/*' ! -name '*@UIKit.swift' | sort)
}

# A vendored file without its attribution header (and the blank line a header-less file gets).
strip_header() {
    tail -n +$((HEADER_LINES + 1)) "$1" | sed '1{/^$/d;}'
}

if [[ "${1:-}" == "--diff" ]]; then
    UPSTREAM="${2:?usage: $0 --diff <libghostty-spm checkout>}/Sources/GhosttyTerminal"
    STAGE="$(mktemp -d)"
    trap 'rm -rf "$STAGE"' EXIT
    {
        echo "CODD changes to libghostty-spm Sources/GhosttyTerminal (commit d403978c6687, release 2.2.2026101301)."
        echo "Every vendored file also gains a 3-line attribution header (not shown). Not vendored: Platform/UIKit/,"
        echo "View/TerminalViewRepresentable@UIKit.swift and Resources/ (shell integration, terminfo, Localization)."
        echo "Added (CODD's own code): CODD/CoddExtensions.swift. Regenerate with Vendor/update-wrapper.sh."
        echo
    } > "$PATCH"
    for file in $(upstream_files "$UPSTREAM"); do
        mkdir -p "$STAGE/$(dirname "$file")"
        strip_header "$VENDORED/$file" > "$STAGE/$file"
        diff -u --label "a/Sources/GhosttyTerminal/${file#./}" --label "b/Sources/GhosttyWrapper/${file#./}" \
            "$UPSTREAM/$file" "$STAGE/$file" >> "$PATCH" || true
    done
    echo "wrote $PATCH"
    exit 0
fi

UPSTREAM="${1:?usage: $0 <libghostty-spm checkout> [--out <dir>]}/Sources/GhosttyTerminal"
OUT="$VENDORED"
if [[ "${2:-}" == "--out" ]]; then
    OUT="${3:?--out needs a directory}"
fi
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

for file in $(upstream_files "$UPSTREAM"); do
    mkdir -p "$STAGE/$(dirname "$file")"
    cp "$UPSTREAM/$file" "$STAGE/$file"
done
chmod -R u+w "$STAGE"
# Fails loudly when upstream moved under a CODD change; re-apply that change by hand, then --diff.
patch --quiet --forward -p3 -d "$STAGE" < "$PATCH"
find "$STAGE" -name '*.orig' -delete

mkdir -p "$OUT"
find "$OUT" -name '*.swift' ! -path "$OUT/CODD/*" -delete
for file in $(cd "$STAGE" && find . -name '*.swift' | sort); do
    mkdir -p "$OUT/$(dirname "$file")"
    if head -c 2 "$STAGE/$file" | grep -q '//'; then
        { echo "$HEADER"; cat "$STAGE/$file"; } > "$OUT/$file"
    else
        { echo "$HEADER"; echo; cat "$STAGE/$file"; } > "$OUT/$file"
    fi
done
find "$OUT" -type d -empty -delete
echo "vendored $(cd "$STAGE" && find . -name '*.swift' | wc -l | tr -d ' ') files into $OUT"
