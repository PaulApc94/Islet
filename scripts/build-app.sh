#!/bin/bash
#
# Builds Islet in release mode and assembles build/Islet.app, an ad-hoc signed
# app bundle, with nothing but the Command Line Tools (no Xcode needed).
#
# Usage: scripts/build-app.sh        (from any directory)
#
# The last line printed on success is the path of the bundle.

set -euo pipefail

readonly APP_NAME="Islet"
readonly MIN_MACOS="14.0"

# Resolve everything from the script's own location so the cwd never matters.
# (cd is silenced because it echoes the directory when CDPATH is set.)
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"
readonly SCRIPT_DIR ROOT

readonly APP="$ROOT/build/$APP_NAME.app"
readonly BRIDGE_SOURCE="$ROOT/Bridge/IsletBridge.m"
readonly DYLIB="$APP/Contents/Resources/IsletBridge.dylib"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    BOLD=""; RESET=""
fi

step() { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$1"; }
warn() { printf 'Attention : %s\n' "$1" >&2; }
die() { printf 'Erreur : %s\n' "$1" >&2; exit 1; }

# A bundle only exists when the whole script succeeded: a half-assembled or
# unsigned app must never be mistaken for a good one by `make run` or install.sh.
bundle_complete=0
cleanup() {
    if [ "$bundle_complete" -ne 1 ]; then
        rm -rf "$APP"
    fi
}
trap cleanup EXIT

# --- Prerequisites -----------------------------------------------------------

for tool in swift clang codesign; do
    command -v "$tool" >/dev/null 2>&1 \
        || die "« $tool » est introuvable. Installez les outils de développement d'Apple : xcode-select --install"
done

for file in Package.swift Resources/Info.plist Resources/AppIcon.icns Bridge/IsletBridge.m; do
    [ -f "$ROOT/$file" ] || die "fichier manquant dans le dépôt : $file"
done

plutil -lint "$ROOT/Resources/Info.plist" >/dev/null \
    || die "Resources/Info.plist n'est pas un fichier plist valide."

# --- Swift build -------------------------------------------------------------

cd "$ROOT"
rm -rf "$APP"

step "Compilation d'$APP_NAME (release)…"
swift build -c release || die "la compilation Swift a échoué (voir les messages ci-dessus)."

BIN_DIR="$(swift build -c release --show-bin-path)"
EXECUTABLE="$BIN_DIR/$APP_NAME"
[ -f "$EXECUTABLE" ] && [ -x "$EXECUTABLE" ] \
    || die "exécutable introuvable après la compilation : $EXECUTABLE"

# --- Bundle ------------------------------------------------------------------

step "Assemblage d'$APP_NAME.app…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$EXECUTABLE" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# --- MediaRemote bridge ------------------------------------------------------

# "$@" holds the -arch flags of the attempt.
# Apple's clang by absolute path: a Homebrew or conda clang earlier in PATH
# would be picked up otherwise, and only Apple's compiler is certain to emit
# the arm64e slice the way the system's perl expects it.
compile_bridge() {
    rm -f "$DYLIB"
    # The library is loaded by path, so its install name is free: a fixed one
    # keeps the absolute path of this clone out of the binary.
    /usr/bin/clang -dynamiclib -fobjc-arc -O2 "$@" \
        -mmacosx-version-min="$MIN_MACOS" \
        -install_name "@rpath/IsletBridge.dylib" \
        -framework Foundation \
        -o "$DYLIB" "$BRIDGE_SOURCE"
}

step "Compilation du pont « À l'écoute » (IsletBridge.dylib)…"

# The library is loaded by /usr/bin/perl, which runs as arm64e on Apple
# silicon and as x86_64 on Intel, so the ideal build carries every slice.
if ! compile_bridge -arch arm64 -arch arm64e -arch x86_64; then
    # uname reports x86_64 under Rosetta, so ask the hardware instead.
    if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = "1" ]; then
        warn "compilation universelle impossible : nouvel essai pour ce Mac uniquement (arm64 + arm64e)."
        if ! compile_bridge -arch arm64 -arch arm64e; then
            warn "tranche arm64e indisponible : nouvel essai en arm64 seul. La lecture en cours (musique) risque de ne pas s'afficher dans l'îlot."
            compile_bridge -arch arm64 \
                || die "impossible de compiler Bridge/IsletBridge.m (voir les messages ci-dessus)."
        fi
    else
        host_arch="$(uname -m)"
        warn "compilation universelle impossible : nouvel essai pour ce Mac uniquement ($host_arch)."
        compile_bridge -arch "$host_arch" \
            || die "impossible de compiler Bridge/IsletBridge.m (voir les messages ci-dessus)."
    fi
fi

# --- Signature ---------------------------------------------------------------

# Runs codesign quietly: it chatters on stderr even when all is well (the
# linker already ad-hoc signs binaries, hence "replacing existing signature"),
# so its output is only worth showing when it fails.
quiet_codesign() {
    local output
    if ! output="$(codesign "$@" 2>&1)"; then
        printf '%s\n' "$output" >&2
        return 1
    fi
}

step "Signature ad hoc…"
# Extended attributes copied along with the sources (Finder info, quarantine,
# file-provider tags when the repo lives in a synced folder) make codesign
# reject the bundle, so start from bare files.
# By absolute path: the `xattr` that pip installs can shadow Apple's in PATH
# and has no -r option. Best effort: a few attributes are system-protected and
# cannot be removed; codesign right below is the judge of what still matters.
/usr/bin/xattr -cr "$APP" 2>/dev/null || true
# Inside out: the bundle's seal covers the signed library.
quiet_codesign --force --sign - "$DYLIB" \
    || die "la signature d'IsletBridge.dylib a échoué."
quiet_codesign --force --sign - "$APP" \
    || die "la signature d'$APP_NAME.app a échoué."
quiet_codesign --verify --deep --strict "$APP" \
    || die "la signature d'$APP_NAME.app est invalide."

bundle_complete=1
step "$APP_NAME.app est prête :"
printf '%s\n' "$APP"
