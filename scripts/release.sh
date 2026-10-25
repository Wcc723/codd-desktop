#!/bin/bash
# Release packaging for CODD Desktop (docs/M5-PLAN.md D18, §2.10): builds the Release
# configuration with the package graph pinned by App/Package.resolved, copies the app out of derived
# data, strips the debug map (strip -S: no build-machine paths), re-signs it inside-out with the
# hardened runtime (the three helpers in Contents/MacOS with their own identifiers, then any nested
# code, then the app; never --deep, which would give the helpers the app's identifier; the app and
# codd-holder with scripts/release.entitlements), ad-hoc unless an identity is asked for, verifies
# it (signatures, entitlements, the Info.plist purpose strings they need, no build-machine paths),
# zips it without AppleDouble entries, prints the zip's SHA-256 and the app's CDHash per
# architecture and, only when the user asks for it, installs it into /Applications.
#
# Usage: scripts/release.sh [--dry-run] [--output <dir>] [--identity <name>] [--install]
#   --dry-run          print the resolved values and every command it would run; nothing is
#                      generated, built, signed, zipped or installed
#   --output <dir>     derived data in <dir>/dd, the app and the zip in <dir> (default build/release);
#                      a folder inside the repository but outside build/, build/user-* (the user's own
#                      builds), build/wt-*, /Applications, ~/Applications (and folders inside them) and
#                      a folder holding a CODD.app this script did not make (no .codd-release-output
#                      marker next to it) are refused
#   --identity <name>  sign with this Apple Development or Developer ID Application identity (its
#                      name, a unique part of it, or its SHA-1, as `security find-identity -v -p
#                      codesigning` lists it; `-` is ad-hoc, the default); the certificate's name and
#                      Team ID end up in the signature of the app and of the zip's copy
#   --install          after the build, replace /Applications/CODD.app (the old app goes to the Trash
#                      through /usr/bin/trash); default output only; refused inside a Claude Code shell
#                      (CLAUDECODE set) and while a CODD runs from /Applications/CODD.app
# Environment: RELEASE_IDENTITY, the same as --identity (the option wins); RELEASE_EXPECT_BUNDLE
#   (default app.codd.CODD), the CFBundleIdentifier the built app must carry (a mismatch fails).
# Exit status: 0 done, 1 failed, 2 usage, 3 refused.
#
# Pinned packages: App/Package.resolved is copied into the generated workspace and xcodebuild runs
# with -onlyUsePackageVersionsFromResolvedFile, so a moved upstream tag cannot swap a dependency
# (libghostty's prebuilt XCFramework included). After changing a dependency on purpose, build once
# without the flag (Xcode or `xcodebuild … -resolvePackageDependencies`) and copy
# CODD.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved to App/Package.resolved.
#
# It never launches CODD and never reads or writes a CODD data root. ~/.Trash is never listed or
# written directly (a Claude Code shell is refused it by TCC); /usr/bin/trash does the move.
set -euo pipefail

say() { printf 'RELEASE %s\n' "$*"; }
step() { printf 'RELEASE step %s\n' "$*"; }
warn() { printf 'RELEASE warning: %s\n' "$*" >&2; }
die() { printf 'RELEASE error: %s\n' "$*" >&2; exit 1; }
refuse() { printf 'RELEASE refused: %s\n' "$*" >&2; exit 3; }
# The header's "Usage:" through "Exit status:" lines (a pattern range, so the header may grow).
usage() { sed -n '/^# Usage: /,/^# Exit status: /s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; }
usage_error() { printf 'RELEASE error: %s\n' "$1" >&2; usage >&2; exit 2; }

# Shell-quotes each argument for the dry-run listing (bash 3.2's printf %q mangles UTF-8, and the
# repository path has CJK characters).
quote() {
    local out="" arg
    for arg in "$@"; do
        case $arg in
            "" | *[!A-Za-z0-9_./=:,+@%-]*) arg="'${arg//\'/\'\\\'\'}'" ;;
        esac
        out+="${out:+ }$arg"
    done
    printf '%s' "$out"
}

# Runs a command, or only prints it in a dry run.
run() {
    if (( DRY_RUN )); then say "would run: $(quote "$@")"; else "$@"; fi
}

# Pids of the processes whose command line starts with <executable>.
pids_running() {
    ps -axww -o pid=,command= | awk -v exe="$1" '{
        pid = $1
        sub(/^[ \t]*[0-9]+[ \t]+/, "")
        if ($0 == exe || index($0, exe " ") == 1) printf "%s ", pid
    }'
}

DRY_RUN=0
INSTALL=0
OUTPUT_ARG=""
IDENTITY_ARG=${RELEASE_IDENTITY:-}
while (( $# )); do
    case $1 in
        --dry-run) DRY_RUN=1 ;;
        --install) INSTALL=1 ;;
        --output)
            [[ $# -ge 2 && -n $2 ]] || usage_error "--output needs a folder"
            OUTPUT_ARG=$2
            shift ;;
        --output=*)
            OUTPUT_ARG=${1#--output=}
            [[ -n $OUTPUT_ARG ]] || usage_error "--output needs a folder" ;;
        --identity)
            [[ $# -ge 2 && -n $2 ]] || usage_error "--identity needs an identity name, its SHA-1 or -"
            IDENTITY_ARG=$2
            shift ;;
        --identity=*)
            IDENTITY_ARG=${1#--identity=}
            [[ -n $IDENTITY_ARG ]] || usage_error "--identity needs an identity name, its SHA-1 or -" ;;
        -h | --help) usage; exit 0 ;;
        *) usage_error "unknown argument: $1" ;;
    esac
    shift
done

INVOKE_DIR=$PWD
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
APP_INSTALLED=/Applications/CODD.app
APP_STAGING=/Applications/.CODD.app.installing
INSTALLED_EXE=$APP_INSTALLED/Contents/MacOS/CODD

# Absolute, symlink-free form of a folder that may not exist yet: the deepest existing ancestor
# goes through `pwd -P`, the missing rest is appended (`.` or `..` in that rest is refused).
resolve_dir() {
    local path=$1 rest="" name
    [[ $path == /* ]] || path=$INVOKE_DIR/$path
    while [[ $path == */ && $path != / ]]; do path=${path%/}; done
    while [[ ! -d $path ]]; do
        name=${path##*/}
        case $name in . | ..) return 1 ;; esac
        [[ -n $name ]] && rest=/$name$rest
        path=${path%/*}
        [[ -n $path ]] || path=/
    done
    path=$(cd "$path" && pwd -P) || return 1
    printf '%s%s' "${path%/}" "$rest"
}

if [[ -n $OUTPUT_ARG ]]; then
    OUT=$(resolve_dir "$OUTPUT_ARG") || usage_error "--output: cannot resolve '$OUTPUT_ARG' (no . or .. below a missing folder)"
else
    OUT=$ROOT/build/release
fi

# --install checks come before anything else runs or changes (D18).
if (( INSTALL )); then
    step "install preflight"
    reason=""
    if [[ -n ${CLAUDECODE:-} ]]; then
        reason="--install does not run inside a Claude Code shell (CLAUDECODE is set); run it in your own Terminal"
    elif [[ $OUT != "$ROOT/build/release" ]]; then
        reason="--install only installs a build to build/release, not $OUT"
    else
        pids=$(pids_running "$INSTALLED_EXE")
        [[ -z $pids ]] || reason="CODD is running from $APP_INSTALLED (pid ${pids% }); quit it first"
    fi
    if [[ -n $reason ]]; then
        if (( DRY_RUN )); then warn "--install would be refused: $reason"; else refuse "$reason"; fi
    fi
fi

step "output $OUT"
shopt -s nocasematch
case $OUT/ in
    "$ROOT"/build/user-*) refuse "$OUT is one of the user's own builds (build/user-*)" ;;
    "$ROOT"/build/wt-*) refuse "$OUT is under build/wt-* (git worktrees)" ;;
esac
if [[ -z $OUT || $OUT == "$ROOT" || $OUT == "$ROOT/build" ]]; then
    refuse "--output must be a folder of its own (got '${OUT:-/}')"
fi
# The zip, xcodebuild.log and dd/ must not land where `git add -A` would pick them up: inside the
# repository only build/ (ignored) takes release output.
case $OUT/ in
    "$ROOT"/build/*) ;;
    "$ROOT"/*) refuse "$OUT is inside the repository; use a folder under $ROOT/build or outside the repository" ;;
esac
# Review (correctness-4 / security-data-1): the copy step replaces $OUT/CODD.app with rm -rf, so an
# output holding the user's installed app would delete it without the Trash backup, the running
# check and the Claude Code refusal that guard --install. /Applications is --install's alone.
APPS_HOME=$(resolve_dir "$HOME/Applications" 2>/dev/null || printf '%s' "$HOME/Applications")
case $OUT/ in
    /Applications/* | /System/Applications/* | "$APPS_HOME"/* | "$HOME"/Applications/*)
        refuse "$OUT is an Applications folder: only --install changes /Applications (the old app goes to the Trash)" ;;
esac
shopt -u nocasematch
MARKER=$OUT/.codd-release-output
if [[ $OUT != "$ROOT/build/release" && -e $OUT/CODD.app && ! -e $MARKER ]]; then
    refuse "$OUT/CODD.app was not made by this script (no $(basename "$MARKER") next to it); pick an empty or new folder"
fi

DD=$OUT/dd
PRODUCT=$DD/Build/Products/Release/CODD.app
APP=$OUT/CODD.app
LOG=$OUT/xcodebuild.log
PLIST=$APP/Contents/Info.plist
PLISTBUDDY=/usr/libexec/PlistBuddy
EXPECT_BUNDLE=${RELEASE_EXPECT_BUNDLE:-app.codd.CODD}
HELPERS=(codd-holder codd-hook codd-statusline)
# Hardened runtime (the owner's decision for the public download): every signature below gets
# --options runtime. Under it a TCC request is refused without a prompt when the responsible app
# has not declared the matching resource-access entitlement, and macOS attributes the requests of
# the programs run in a session (osascript, a CLI that wants the camera or the microphone, ...) to
# CODD, so scripts/release.entitlements declares the seven that Ghostty, also a terminal host, ships.
# - CODD.app needs them: HolderSpawner posix_spawns holders with POSIX_SPAWN_SETSID but without
#   responsibility_spawnattrs_setdisclaim, so while CODD runs a holder and everything it starts
#   report CODD as their responsible process.
# - codd-holder carries the same set as a precaution; nothing attributes a request to it today. A
#   probe (2026-10-25, macOS 27: an app spawned with responsibility disclaimed, a SETSID child, its
#   children started before and after the app exits) showed that once the app is gone each process
#   reports itself, not the holder, as responsible. A holder becomes the responsible process only if
#   it is ever spawned with responsibility disclaimed, and then it has to prompt, not refuse (it has
#   no Info.plist, so that change would also have to embed the purpose strings below, a
#   __TEXT,__info_plist section). The holder does not ask for these resources itself.
# - codd-hook and codd-statusline: no entitlements. codd-statusline does start the user's chained
#   status-line command, but TCC looks at the responsible process (CODD while it runs), not at
#   intermediate processes; the same is why codd-holder's copy does not matter today.
# - The entitlement alone is not enough: tccd also wants the matching purpose string in the
#   responsible app's Info.plist (NSCameraUsageDescription, ...) and refuses without a prompt when
#   it is missing (only Apple Events prompts without one). usage_keys below names the strings each
#   entitlement needs; project.yml (targets.CODD.info.properties) carries them, and the verify step
#   fails when the built Info.plist lacks one.
# - Ad-hoc signing takes them: they are unrestricted (no provisioning profile needed, unlike
#   com.apple.developer.*); `codesign -s - --options runtime --entitlements` signs with them and the
#   kernel runs the result (checked on arm64 and, under Rosetta, x86_64). Xcode's own entitlements
#   (get-task-allow) are never kept: no --preserve-metadata.
ENTITLEMENTS=$ROOT/scripts/release.entitlements
ENTITLED_HELPERS=(codd-holder)
# The Info.plist purpose strings tccd wants next to each resource-access entitlement (EventKit asks
# for the full-access keys on macOS 14 and later, Core Location for the when-in-use key on 11 and
# later). An entitlement not listed here fails the entitlements step.
usage_keys() {
    case $1 in
        com.apple.security.automation.apple-events) echo NSAppleEventsUsageDescription ;;
        com.apple.security.device.audio-input) echo NSMicrophoneUsageDescription ;;
        com.apple.security.device.camera) echo NSCameraUsageDescription ;;
        com.apple.security.personal-information.addressbook) echo NSContactsUsageDescription ;;
        com.apple.security.personal-information.calendars)
            echo NSCalendarsUsageDescription NSCalendarsFullAccessUsageDescription \
                NSRemindersUsageDescription NSRemindersFullAccessUsageDescription ;;
        com.apple.security.personal-information.location) echo NSLocationUsageDescription NSLocationWhenInUseUsageDescription ;;
        com.apple.security.personal-information.photos-library) echo NSPhotoLibraryUsageDescription ;;
        *) return 1 ;;
    esac
}
# The architectures whose CDHash is printed for users to compare (Apple silicon, Intel).
CDHASH_ARCHS=(arm64 x86_64)
PINNED_RESOLVED=$ROOT/App/Package.resolved
WORKSPACE_RESOLVED=$ROOT/CODD.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
START=$SECONDS

step "tools"
for tool in xcodebuild codesign ditto git security strip file lipo plutil shasum zipinfo "$PLISTBUDDY"; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found"
done
(( INSTALL == 0 )) || [[ -x /usr/bin/trash ]] || die "/usr/bin/trash not found (macOS 15 or later)"
XCODEGEN=$(command -v xcodegen 2>/dev/null || true)
say "value xcodegen=${XCODEGEN:-missing} xcodebuild=$(command -v xcodebuild)"

step "versions"
[[ -f $ROOT/VERSION ]] || die "$ROOT/VERSION is missing"
VERSION=$(tr -d ' \t\r\n' <"$ROOT/VERSION")
[[ $VERSION =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "VERSION must look like 1.0.0 (got '$VERSION')"
BUILD=$(git -C "$ROOT" rev-list --count HEAD) || die "git rev-list --count HEAD failed"
[[ $BUILD =~ ^[0-9]+$ ]] || die "unexpected build number '$BUILD'"
ZIP=$OUT/CODD-$VERSION-$BUILD.zip
dirty=$(git -C "$ROOT" status --porcelain | wc -l | tr -d ' ')
(( dirty == 0 )) || warn "the working tree has $dirty uncommitted or untracked paths; build $BUILD counts commits only"
say "value version=$VERSION build=$BUILD (MARKETING_VERSION / CURRENT_PROJECT_VERSION)"

step "packages"
[[ -f $PINNED_RESOLVED ]] || die "$PINNED_RESOLVED is missing (the app's pinned package graph)"
pins=$(awk -F'"' '/"identity"/ { id = $4 } /"revision"/ { rev = substr($4, 1, 7) }
    /"version"/ && id != "" { printf "%s%s %s (%s)", sep, id, $4, rev; sep = ", "; id = "" }' "$PINNED_RESOLVED")
say "value packages=${pins:-none} (App/Package.resolved, -onlyUsePackageVersionsFromResolvedFile)"

step "entitlements"
[[ -f $ENTITLEMENTS ]] || die "$ENTITLEMENTS is missing (the hardened runtime's resource-access entitlements)"
plutil -lint -s "$ENTITLEMENTS" || die "$ENTITLEMENTS is not a valid property list"
WANT_ENTITLEMENTS=$(plutil -convert xml1 -o - -- "$ENTITLEMENTS") || die "plutil cannot read $ENTITLEMENTS"
[[ $WANT_ENTITLEMENTS != *get-task-allow* ]] || die "$ENTITLEMENTS must not carry get-task-allow (it would let any process debug the app)"
ent_keys=$(printf '%s\n' "$WANT_ENTITLEMENTS" | sed -n 's/^[[:space:]]*<key>\(.*\)<\/key>$/\1/p' | tr '\n' ' ')
say "value entitlements=$ENTITLEMENTS keys=${ent_keys% } (CODD.app and ${ENTITLED_HELPERS[*]}; hardened runtime on every signature)"
USAGE_KEYS=()
for key in $ent_keys; do
    keys=$(usage_keys "$key") || die "$ENTITLEMENTS declares $key, but no Info.plist purpose string is known for it (add it to usage_keys in this script and to project.yml targets.CODD.info.properties)"
    for usage in $keys; do USAGE_KEYS+=("$usage"); done
done
(( ${#USAGE_KEYS[@]} > 0 )) || die "$ENTITLEMENTS declares no resource-access entitlement"
say "value usage-descriptions=${USAGE_KEYS[*]} (the built Info.plist must carry each; project.yml targets.CODD.info.properties)"

step "identity"
# Ad-hoc unless asked (MISS-1): a certificate's signature carries its holder's name and Team ID into
# every published copy, so a keychain identity is never picked up on its own.
SIGN_ID=-
IDENTITY=adhoc
if [[ -n $IDENTITY_ARG && $IDENTITY_ARG != - ]]; then
    # `security` lists `  1) <SHA-1> "<name>"` per valid identity; the argument is a whole name, a
    # SHA-1, or a part of exactly one name (codesign's own rule, made strict).
    identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
    matches=()
    while IFS= read -r line; do
        [[ $line =~ ^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-Fa-f]{40})[[:space:]]+\"(.*)\"$ ]] || continue
        sha=${BASH_REMATCH[1]} name=${BASH_REMATCH[2]}
        shopt -s nocasematch
        if [[ $sha == "$IDENTITY_ARG" || $name == "$IDENTITY_ARG" ]]; then
            matches=("$sha $name")
            shopt -u nocasematch
            break
        fi
        shopt -u nocasematch
        if [[ $name == *"$IDENTITY_ARG"* ]]; then matches+=("$sha $name"); fi
    done <<<"$identities"
    (( ${#matches[@]} > 0 )) || die "no valid code-signing identity matches '$IDENTITY_ARG' (security find-identity -v -p codesigning)"
    (( ${#matches[@]} == 1 )) || die "'$IDENTITY_ARG' matches ${#matches[@]} identities; pass the whole name or its SHA-1"
    SIGN_ID=${matches[0]:0:40}
    IDENTITY=${matches[0]:41}
    case $IDENTITY in
        "Apple Development: "* | "Developer ID Application: "*) ;;
        *) die "'$IDENTITY' is not an Apple Development or Developer ID Application identity" ;;
    esac
    warn "signing with '$IDENTITY': the certificate's name and Team ID end up in the signature, and anyone with the app or the zip can read them (codesign -dvv); without notarization other Macs still block the app"
fi
say "value identity=$IDENTITY sign=$SIGN_ID"
project_bundle=$(sed -n '/^ *PRODUCT_BUNDLE_IDENTIFIER: */{s///p;q;}' "$ROOT/project.yml")
say "value expect-bundle=$EXPECT_BUNDLE project-bundle=${project_bundle:-unknown} (project.yml, first target)"
[[ $project_bundle == "$EXPECT_BUNDLE" ]] || warn "project.yml builds $project_bundle, not $EXPECT_BUNDLE: the bundle check after the build will fail unless RELEASE_EXPECT_BUNDLE matches"
say "value derived-data=$DD app=$APP zip=$ZIP log=$LOG"

if (( ! DRY_RUN )); then
    pids=$(pids_running "$APP/Contents/MacOS/CODD")
    [[ -z $pids ]] || refuse "CODD is running from $APP (pid ${pids% }); quit it first (this build replaces that copy)"
fi

# Other agents build from the shared generated project: regenerate only when it is stale.
PROJECT=$ROOT/CODD.xcodeproj/project.pbxproj
if [[ ! -f $PROJECT || $PROJECT -ot $ROOT/project.yml ]]; then
    step "xcodegen generate (project missing or older than project.yml)"
    [[ -n $XCODEGEN ]] || die "xcodegen not found (brew install xcodegen)"
    run "$XCODEGEN" generate --spec "$ROOT/project.yml" --project "$ROOT"
else
    step "xcodegen skipped (project current)"
fi

# ATK-M1: the generated workspace's Package.resolved is untracked (CODD.xcodeproj is ignored), so
# the tracked copy is put in place and xcodebuild may not resolve anything else.
step "package pins $PINNED_RESOLVED"
if cmp -s "$PINNED_RESOLVED" "$WORKSPACE_RESOLVED"; then
    say "package pins current in the workspace"
else
    [[ ! -f $WORKSPACE_RESOLVED ]] || warn "the workspace's Package.resolved differs from App/Package.resolved and is replaced by it (if you changed a dependency on purpose, copy the workspace's file to App/Package.resolved first)"
    run mkdir -p "$(dirname "$WORKSPACE_RESOLVED")"
    run cp "$PINNED_RESOLVED" "$WORKSPACE_RESOLVED"
fi

step "xcodebuild Release"
XB=(xcodebuild -project "$ROOT/CODD.xcodeproj" -scheme CODD -configuration Release -derivedDataPath "$DD"
    -onlyUsePackageVersionsFromResolvedFile "MARKETING_VERSION=$VERSION" "CURRENT_PROJECT_VERSION=$BUILD" build)
run mkdir -p "$OUT"
# Marks the folder as this script's output, so a later run may replace the CODD.app it made.
run touch "$MARKER"
if (( DRY_RUN )); then
    say "would run: $(quote "${XB[@]}") >$(quote "$LOG") 2>&1"
else
    t0=$SECONDS
    if ! "${XB[@]}" >"$LOG" 2>&1; then
        grep -E 'error:|BUILD' "$LOG" | tail -n 30 >&2 || true
        if grep -q 'Package.resolved' "$LOG"; then
            warn "the package graph no longer matches App/Package.resolved: resolve once without -onlyUsePackageVersionsFromResolvedFile, review the new pins and copy $WORKSPACE_RESOLVED to App/Package.resolved"
        fi
        die "xcodebuild failed after $((SECONDS - t0)) s (log $LOG)"
    fi
    grep -E 'warning:' "$LOG" | sort -u | head -n 20 | sed 's/^/RELEASE xcodebuild /' || true
    say "xcodebuild ok in $((SECONDS - t0)) s ($(grep -c 'warning:' "$LOG" || true) warning lines, log $LOG)"
    [[ -d $PRODUCT ]] || die "no product at $PRODUCT"
fi

step "copy $PRODUCT -> $APP"
run rm -rf "$APP"
run ditto "$PRODUCT" "$APP"

plist_get() { "$PLISTBUDDY" -c "Print :$1" "$PLIST" 2>/dev/null; }
plist_set() {
    "$PLISTBUDDY" -c "Set :$1 $2" "$PLIST" 2>/dev/null || "$PLISTBUDDY" -c "Add :$1 string $2" "$PLIST"
}

step "bundle id (expect $EXPECT_BUNDLE)"
if (( ! DRY_RUN )); then
    bundle=$(plist_get CFBundleIdentifier || true)
    [[ $bundle == "$EXPECT_BUNDLE" ]] || die "the built CFBundleIdentifier is '$bundle', expected $EXPECT_BUNDLE (RELEASE_EXPECT_BUNDLE)"
fi

step "info plist versions"
if (( DRY_RUN )); then
    say "would run (when the built Info.plist lacks them): $(quote "$PLISTBUDDY" -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$PLIST")"
else
    have_version=$(plist_get CFBundleShortVersionString || true)
    have_build=$(plist_get CFBundleVersion || true)
    if [[ $have_version != "$VERSION" || $have_build != "$BUILD" ]]; then
        warn "the built Info.plist carries ${have_version:-none} (${have_build:-none}), not $VERSION ($BUILD): project.yml does not map CFBundleShortVersionString / CFBundleVersion to \$(MARKETING_VERSION) / \$(CURRENT_PROJECT_VERSION); set with PlistBuddy"
        plist_set CFBundleShortVersionString "$VERSION"
        plist_set CFBundleVersion "$BUILD"
    else
        say "info plist carries $VERSION ($BUILD) from the build settings"
    fi
fi

# Every Mach-O file (regular files only) below the given folders, one path per line.
macho_files() {
    local dir file
    for dir in "$@"; do
        [[ -d $dir ]] || continue
        while IFS= read -r -d '' file; do
            case $(file -b "$file") in Mach-O*) printf '%s\n' "$file" ;; esac
        done < <(find "$dir" -type f -print0)
    done
}

# strip -S, keeping its other output but not its warning that the old signature is now invalid
# (the signing steps below replace it).
strip_debug() {
    local out status=0
    out=$(strip -S "$1" 2>&1) || status=$?
    out=$(printf '%s\n' "$out" | grep -v -e 'invalidate the code signature' -e '^$' || true)
    [[ -z $out ]] || printf '%s\n' "$out" | sed 's/^/RELEASE strip: /' >&2
    (( status == 0 )) || die "strip -S $1 failed (status $status)"
}

# The linker's debug map (N_SO / N_OSO entries) names the sources and the object files in derived
# data, that is build-machine paths such as /Users/<name>/<project folder>. strip -S drops it before
# signing; the symbol table stays. The verify step fails if such a path is still in a binary.
step "strip debug map (Contents/MacOS, Contents/Frameworks, Contents/PlugIns)"
if (( DRY_RUN )); then
    for name in CODD "${HELPERS[@]}"; do run strip -S "$APP/Contents/MacOS/$name"; done
    say "would also strip -S each Mach-O in Contents/Frameworks and Contents/PlugIns (none today)"
else
    stripped=0
    while IFS= read -r file; do
        strip_debug "$file"
        stripped=$((stripped + 1))
    done < <(macho_files "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/PlugIns")
    (( stripped > 0 )) || die "no Mach-O file in $APP/Contents/MacOS"
    say "stripped $stripped Mach-O files"
fi

# Inside-out: every nested code item is signed before what contains it; the app last. All of them
# with the hardened runtime; the entitlements only where the comment at ENTITLEMENTS says.
step "sign helpers"
for name in "${HELPERS[@]}"; do
    helper=$APP/Contents/MacOS/$name
    (( DRY_RUN )) || [[ -f $helper ]] || die "missing helper $helper"
    entitlements=()
    case " ${ENTITLED_HELPERS[*]} " in *" $name "*) entitlements=(--entitlements "$ENTITLEMENTS") ;; esac
    # ${a[@]+...}: bash 3.2 treats an empty array as unset under set -u.
    run codesign --force --sign "$SIGN_ID" --timestamp=none --options runtime \
        ${entitlements[@]+"${entitlements[@]}"} --identifier "app.codd.$name" "$helper"
done

step "sign nested code (Contents/Frameworks, Contents/PlugIns)"
if (( DRY_RUN )); then
    say "would sign each *.framework, *.dylib, *.bundle, *.appex, *.xpc, *.app there, deepest first, with $(quote codesign --force --sign "$SIGN_ID" --timestamp=none --options runtime) (none today)"
else
    nested=()
    while IFS= read -r item; do
        if [[ -n $item ]]; then nested+=("$item"); fi
    done < <(
        for dir in "$APP/Contents/Frameworks" "$APP/Contents/PlugIns"; do
            [[ -d $dir ]] || continue
            find "$dir" ! -type l \( -name '*.framework' -o -name '*.dylib' -o -name '*.bundle' \
                -o -name '*.appex' -o -name '*.xpc' -o -name '*.app' \) -print
        done | awk -F/ '{ print NF "\t" $0 }' | sort -t $'\t' -k1,1nr | cut -f2-
    )
    if (( ${#nested[@]} == 0 )); then
        say "nested code none"
    else
        for item in "${nested[@]}"; do
            codesign --force --sign "$SIGN_ID" --timestamp=none --options runtime "$item"
            say "signed nested $item"
        done
    fi
fi

step "sign app"
run codesign --force --sign "$SIGN_ID" --timestamp=none --options runtime --entitlements "$ENTITLEMENTS" "$APP"

# The CodeDirectory flags of <code> (for <arch>, when given), e.g. adhoc,runtime (codesign -dvv).
code_flags() {
    local out
    out=$(codesign -dvv ${2:+--arch "$2"} "$1" 2>&1) || true
    printf '%s\n' "$out" | sed -n 's/^CodeDirectory .* flags=0x[0-9a-fA-F]*(\([^)]*\)).*/\1/p'
}
# The entitlements of <code> for <arch> as plutil's XML, or nothing when it has none.
code_entitlements() {
    local xml
    xml=$(codesign -d --arch "$2" --entitlements - --xml "$1" 2>/dev/null) || true
    [[ $xml == *"<key>"* ]] || return 0
    printf '%s' "$xml" | plutil -convert xml1 -o - - || die "plutil cannot read the entitlements of $1 ($2)"
}
# The CDHash of <code> for <arch> (the CDHash= line of codesign -dvvv).
code_cdhash() {
    local out
    out=$(codesign -dvvv --arch "$2" "$1" 2>&1) || true
    printf '%s\n' "$out" | sed -n 's/^CDHash=//p'
}

# Build-machine paths no Mach-O may name: the repository, derived data (when outside it), $HOME/.
leaks=("$ROOT")
[[ $DD == "$ROOT"/* ]] || leaks+=("$DD")
if [[ -n ${HOME:-} && -n ${HOME%/} ]]; then leaks+=("${HOME%/}/"); fi

step "verify"
run codesign --verify --strict --deep --verbose=2 "$APP"
if (( DRY_RUN )); then
    say "would check CFBundleIdentifier=$EXPECT_BUNDLE, CFBundleShortVersionString=$VERSION, CFBundleVersion=$BUILD, helper identifiers app.codd.{${HELPERS[*]}} (codesign --verify --strict each)"
    say "would check the hardened runtime on CODD.app and each helper, every architecture (codesign -dvv --arch <arch>: flags=0x10002(adhoc,runtime) ad-hoc, the runtime flag with an identity)"
    say "would check the entitlements (codesign -d --arch <arch> --entitlements - --xml): CODD.app and ${ENTITLED_HELPERS[*]} equal to $ENTITLEMENTS, none on the other helpers"
    say "would check that $(quote "$PLIST") carries a non-empty ${USAGE_KEYS[*]} ($(quote "$PLISTBUDDY") -c 'Print :<key>')"
    say "would check that no Mach-O in the app names any of ${leaks[*]} (LC_ALL=C grep -a -F -c)"
else
    bundle=$(plist_get CFBundleIdentifier || true)
    [[ $bundle == "$EXPECT_BUNDLE" ]] || die "verify: CFBundleIdentifier '$bundle', expected $EXPECT_BUNDLE"
    [[ $(plist_get CFBundleShortVersionString || true) == "$VERSION" ]] || die "verify: CFBundleShortVersionString is not $VERSION"
    [[ $(plist_get CFBundleVersion || true) == "$BUILD" ]] || die "verify: CFBundleVersion is not $BUILD"
    say "verify bundle=$bundle version=$VERSION build=$BUILD"
    for name in "${HELPERS[@]}"; do
        helper=$APP/Contents/MacOS/$name
        codesign --verify --strict "$helper" || die "verify: $helper"
        ident=$(codesign -d --verbose=1 "$helper" 2>&1 | sed -n 's/^Identifier=//p' || true)
        [[ $ident == "app.codd.$name" ]] || die "verify: $name has identifier '$ident', expected app.codd.$name"
        say "verify helper $name identifier=$ident"
    done
    say "verify signature $(codesign -d --verbose=2 "$APP" 2>&1 | grep -E '^(Identifier|Signature|Authority|TeamIdentifier)=' | tr '\n' ' ')"

    # Hardened runtime on every signature and every architecture; the entitlements exactly where
    # the comment at ENTITLEMENTS puts them (and so never Xcode's get-task-allow).
    for name in CODD "${HELPERS[@]}"; do
        code=$APP/Contents/MacOS/$name
        [[ $name != CODD ]] || code=$APP
        archs=$(lipo -archs "$APP/Contents/MacOS/$name") || die "verify: lipo -archs $APP/Contents/MacOS/$name failed"
        expect=none
        case " CODD ${ENTITLED_HELPERS[*]} " in *" $name "*) expect=release.entitlements ;; esac
        for arch in $archs; do
            flags=$(code_flags "$code" "$arch")
            [[ ,$flags, == *,runtime,* ]] || die "verify: $name ($arch) is signed without the hardened runtime (flags (${flags:-none}); codesign -dvv --arch $arch $code)"
            [[ $IDENTITY != adhoc || ,$flags, == *,adhoc,* ]] || die "verify: $name ($arch) is not signed ad-hoc (flags ($flags))"
            got=$(code_entitlements "$code" "$arch")
            if [[ $expect == none ]]; then
                [[ -z $got ]] || die "verify: $name ($arch) carries entitlements, expected none (codesign -d --arch $arch --entitlements - --xml $code)"
            else
                [[ $got == "$WANT_ENTITLEMENTS" ]] || die "verify: the entitlements of $name ($arch) differ from $ENTITLEMENTS (codesign -d --arch $arch --entitlements - --xml $code)"
            fi
        done
        say "verify runtime $name archs=$(printf '%s' "$archs" | tr ' ' ',') flags=($flags) entitlements=$expect"
    done
    for item in ${nested[@]+"${nested[@]}"}; do
        flags=$(code_flags "$item" "")
        [[ ,$flags, == *,runtime,* ]] || die "verify: $item is signed without the hardened runtime (flags (${flags:-none}))"
        say "verify runtime nested $item flags=($flags)"
    done

    # The purpose strings the entitlements need (usage_keys): without one, tccd refuses that
    # service without a prompt although the entitlement is there.
    missing=()
    for key in "${USAGE_KEYS[@]}"; do
        [[ -n $(plist_get "$key" || true) ]] || missing+=("$key")
    done
    (( ${#missing[@]} == 0 )) || die "verify: the built Info.plist has no ${missing[*]} (the purpose strings $ENTITLEMENTS needs; project.yml targets.CODD.info.properties)"
    say "verify usage descriptions: all ${#USAGE_KEYS[@]} in Info.plist (${USAGE_KEYS[*]})"

    # No build-machine path left in any Mach-O of the bundle (strip -S above removed the debug map).
    scanned=0
    while IFS= read -r file; do
        for leak in "${leaks[@]}"; do
            hits=$(LC_ALL=C grep -a -F -c -- "$leak" "$file") || (( $? == 1 )) || die "verify: grep cannot read $file"
            [[ $hits == 0 ]] || die "verify: ${file#"$APP"/} still names $leak ($hits lines; strings -a $(quote "$file") | grep -F $(quote "$leak"))"
        done
        scanned=$((scanned + 1))
    done < <(macho_files "$APP")
    (( scanned > 0 )) || die "verify: no Mach-O file in $APP"
    say "verify paths: none of ${leaks[*]} in the $scanned Mach-O files"
fi

step "zip"
run rm -f "$ZIP"
# Without resource forks, extended attributes, quarantine and ACLs ditto writes no ._ AppleDouble
# entries next to the files (the app needs none of them; its signature does not cover them).
run ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl "$APP" "$ZIP"
if (( DRY_RUN )); then
    say "would check that $(quote zipinfo -1 "$ZIP") lists no ._ (AppleDouble) or __MACOSX/ entries, then unpack a copy (ditto -x -k) and check its signature (codesign --verify --strict --deep) and CDHash against $APP"
else
    entries=$(zipinfo -1 "$ZIP") || die "zipinfo -1 $ZIP failed"
    doubles=$(printf '%s\n' "$entries" | grep -E '(^|/)\._|^__MACOSX/' || true)
    [[ -z $doubles ]] || die "verify: $ZIP has AppleDouble entries ($(printf '%s\n' "$doubles" | wc -l | tr -d ' '), the first ${doubles%%$'\n'*})"
    say "zip $(du -h "$ZIP" | cut -f1 | tr -d ' ') $ZIP ($(printf '%s\n' "$entries" | wc -l | tr -d ' ') entries, no ._ AppleDouble entries)"
    # What a user unpacks: it must verify and carry the CDHash printed below.
    unpacked=$(mktemp -d "$OUT/.zip-check.XXXXXX") || die "mktemp in $OUT failed"
    zip_fail() { rm -rf "$unpacked"; die "$@"; }
    ditto -x -k "$ZIP" "$unpacked" || zip_fail "ditto -x -k $ZIP failed"
    codesign --verify --strict --deep "$unpacked/CODD.app" || zip_fail "verify: the zip's copy of CODD.app does not verify (codesign --verify --strict --deep)"
    for arch in $(lipo -archs "$APP/Contents/MacOS/CODD"); do
        [[ $(code_cdhash "$unpacked/CODD.app" "$arch") == "$(code_cdhash "$APP" "$arch")" ]] ||
            zip_fail "verify: the zip's copy of CODD.app has another $arch CDHash than $APP"
    done
    rm -rf "$unpacked"
    say "verify zip copy: signature valid, CDHash equal to $APP"
fi

# For the release notes: the zip's SHA-256 (shasum -a 256 <zip>) and, for a copy Safari already
# unpacked, the app's CDHash per architecture (codesign -dvvv /Applications/CODD.app shows the host's).
step "checksums"
if (( DRY_RUN )); then
    run shasum -a 256 "$ZIP"
    for arch in "${CDHASH_ARCHS[@]}"; do say "would run: $(quote codesign -dvvv --arch "$arch" "$APP") (its CDHash= line)"; done
    say "would print RELEASE sha256 <hex> ${ZIP##*/} and RELEASE cdhash ${CDHASH_ARCHS[0]}=<hex> ${CDHASH_ARCHS[1]}=<hex>"
else
    sha=$(shasum -a 256 "$ZIP") || die "shasum -a 256 $ZIP failed"
    sha=${sha%% *}
    [[ $sha =~ ^[0-9a-f]{64}$ ]] || die "unexpected shasum output for $ZIP: $sha"
    say "sha256 $sha ${ZIP##*/}"
    app_archs=" $(lipo -archs "$APP/Contents/MacOS/CODD") "
    hashes=()
    for arch in "${CDHASH_ARCHS[@]}"; do
        if [[ $app_archs != *" $arch "* ]]; then
            warn "CODD.app has no $arch slice (archs:${app_archs% }): no CDHash for it, and Macs of that architecture cannot run this build"
            continue
        fi
        cdhash=$(code_cdhash "$APP" "$arch")
        [[ $cdhash =~ ^[0-9a-f]{40}$ ]] || die "no CDHash for $arch (codesign -dvvv --arch $arch $APP)"
        hashes+=("$arch=$cdhash")
    done
    (( ${#hashes[@]} > 0 )) || die "no CDHash for ${CDHASH_ARCHS[*]} in $APP"
    say "cdhash ${hashes[*]}"
fi
# LGPL-2.1 §6(d) / MPL-2.0 §3.2: the libintl and z2d sources go wherever the zip goes
# (THIRD-PARTY-NOTICES.md › Source of the MPL-2.0 and LGPL-2.1 parts).
say "publish attach to the same release as the zip: gettext-0.24.tar.gz (sha256 c918503d593d70daf4844d175a13d816afacb667c06fba1ec9dcd5002c1518b7, https://deps.files.ghostty.org/gettext-0.24.tar.gz) and z2d-7dbae85c81784dba9988320bf9543ed9a81350c8.tar.gz (sha256 e55c9d0b156edaddfea32fb1c0e3597e1b6306b9a4ec1888e2f8008c598bced8, https://deps.files.ghostty.org/z2d-7dbae85c81784dba9988320bf9543ed9a81350c8.tar.gz)"

if (( INSTALL )); then
    step "install $APP -> $APP_INSTALLED"
    if (( ! DRY_RUN )); then
        # The build took minutes: check again right before anything in /Applications changes.
        pids=$(pids_running "$INSTALLED_EXE")
        [[ -z $pids ]] || refuse "CODD is running from $APP_INSTALLED (pid ${pids% }); quit it, then rerun --install"
    fi
    # A staging copy left by an interrupted install is this script's own; replace it.
    if [[ -e $APP_STAGING ]]; then run rm -rf "$APP_STAGING"; fi
    run ditto "$APP" "$APP_STAGING"
    run codesign --verify --strict --deep "$APP_STAGING"
    if (( DRY_RUN )) || [[ -e $APP_INSTALLED ]]; then
        step "old $APP_INSTALLED -> Trash"
        if (( DRY_RUN )); then
            say "would run (when $APP_INSTALLED exists): $(quote /usr/bin/trash -s "$APP_INSTALLED")"
        elif ! /usr/bin/trash -s "$APP_INSTALLED" || [[ -e $APP_INSTALLED ]]; then
            die "could not move $APP_INSTALLED to the Trash; nothing else changed: the old app stays at $APP_INSTALLED, the new one at $APP_STAGING (move the old app to the Trash yourself, then rerun --install)"
        fi
    fi
    (( DRY_RUN )) || [[ ! -e $APP_INSTALLED ]] || die "$APP_INSTALLED appeared again; the new app stays at $APP_STAGING"
    run mv "$APP_STAGING" "$APP_INSTALLED"
    if (( ! DRY_RUN )); then
        say "installed $APP_INSTALLED ($VERSION, build $BUILD)"
        cat <<EOF
接下來：
  1. 如果還有從別的位置（例如 build/user-m4）啟動的舊 CODD 在執行，先在那個 CODD 按 ⌘Q 結束它；
     舊的還開著時，新的 CODD 只會把舊的視窗叫到前面。
  2. 從「應用程式」資料夾打開 CODD。
  3. session 不會中斷：holder 會繼續在背景執行，新的 CODD 啟動後會重新接上。
  4. macOS 會再問一次通知權限（新的 bundle id 對系統來說是另一個 app）。
EOF
    fi
fi

if (( DRY_RUN )); then
    say "dry-run app=$APP zip=$ZIP version=$VERSION build=$BUILD identity=$IDENTITY bundle=$EXPECT_BUNDLE (nothing was built)"
else
    say "done in $((SECONDS - START)) s"
    say "app=$APP zip=$ZIP version=$VERSION build=$BUILD identity=$IDENTITY bundle=$bundle"
fi
