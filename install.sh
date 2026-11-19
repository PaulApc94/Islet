#!/bin/bash
#
# Builds Islet and installs it in /Applications, or in ~/Applications when
# /Applications is not writable. Never asks for administrator rights.
# Safe to run again: it replaces the installed copy with a fresh build.
#
# Usage: ./install.sh

set -euo pipefail

readonly APP_NAME="Islet"
readonly BUNDLE_ID="io.github.paulapc94.islet"
readonly MIN_MACOS_MAJOR=14

# (cd is silenced because it echoes the directory when CDPATH is set.)
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
readonly ROOT
readonly BUILT_APP="$ROOT/build/$APP_NAME.app"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    BOLD=""; RESET=""
fi

step() { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$1"; }
warn() { printf 'Attention : %s\n' "$1" >&2; }
die() { printf 'Erreur : %s\n' "$1" >&2; exit 1; }

# --- Running instance --------------------------------------------------------

is_running() { pgrep -U "$(id -u)" -x "$APP_NAME" >/dev/null 2>&1; }

# Waits up to $1 seconds for the app to exit.
wait_until_gone() {
    local tries=$(( $1 * 5 ))
    while is_running; do
        [ "$tries" -gt 0 ] || return 1
        tries=$((tries - 1))
        sleep 0.2
    done
}

quit_app() {
    is_running || return 0
    step "Fermeture d'$APP_NAME…"
    # Ask politely first so the app can tidy up. In the background, because an
    # Apple event can sit behind a consent prompt and must not stall the install.
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 &
    local asker=$!
    disown "$asker" 2>/dev/null || true
    if ! wait_until_gone 5; then
        pkill -U "$(id -u)" -x "$APP_NAME" >/dev/null 2>&1 || true
        if ! wait_until_gone 5; then
            pkill -9 -U "$(id -u)" -x "$APP_NAME" >/dev/null 2>&1 || true
            wait_until_gone 3 \
                || die "impossible de fermer $APP_NAME. Quittez-la depuis son icône dans la barre des menus, puis relancez ./install.sh"
        fi
    fi
    kill "$asker" >/dev/null 2>&1 || true
}

# --- Installation ------------------------------------------------------------

# Prints the bundle identifier of the app at $1 (nothing when unreadable).
bundle_id_of() {
    local plist="$1/Contents/Info.plist" identifier
    # PlistBuddy reports a missing file on stdout, so never hand it one, and
    # only trust its output when it succeeded.
    [ -f "$plist" ] || return 0
    if identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null)"; then
        printf '%s\n' "$identifier"
    fi
}

# True when $1 is some other product that merely shares our file name.
is_foreign_app() {
    local identifier
    identifier="$(bundle_id_of "$1")"
    [ -n "$identifier" ] && [ "$identifier" != "$BUNDLE_ID" ]
}

# Deletes the bundle at $1. Refuses up front when its parent folder is not
# writable: rm would then empty the bundle yet leave its shell behind.
remove_app() {
    [ -w "$(dirname -- "$1")" ] || return 1
    rm -rf "$1" 2>/dev/null
}

STAGING=""
cleanup() {
    if [ -n "$STAGING" ]; then
        rm -rf "$STAGING" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Installs the fresh bundle into the directory $1. Returns non-zero when that
# location cannot be used. An existing copy is then left as it was, unless it
# could only be deleted in part (an app locked in the Finder, say): the caller
# installs elsewhere and reports the leftover.
install_into() {
    local dir="$1"
    local target="$dir/$APP_NAME.app"

    [ -d "$dir" ] && [ -w "$dir" ] || return 1
    if [ -e "$target" ] && is_foreign_app "$target"; then
        warn "$target est une autre application portant le même nom : elle est laissée intacte."
        return 1
    fi

    # Copy next to the destination, then swap: a failed or interrupted copy
    # (disk full, Ctrl-C) never leaves a half-written app in place.
    STAGING="$dir/.$APP_NAME.app.installing"
    rm -rf "$STAGING" 2>/dev/null || return 1
    ditto "$BUILT_APP" "$STAGING" 2>/dev/null || return 1
    if [ -e "$target" ]; then
        remove_app "$target" || return 1
    fi
    mv "$STAGING" "$target" 2>/dev/null || return 1
    STAGING=""
}

# --- Checks ------------------------------------------------------------------

[ "$(uname -s)" = "Darwin" ] || die "$APP_NAME ne fonctionne que sur macOS."

if [ "$(id -u)" -eq 0 ]; then
    die "ne lancez pas ce script avec sudo : $APP_NAME s'installe sans droits d'administrateur."
fi

macos_version="$(sw_vers -productVersion 2>/dev/null || true)"
macos_major="${macos_version%%.*}"
case "$macos_major" in
    '' | *[!0-9]*) die "impossible de déterminer la version de macOS." ;;
esac
if [ "$macos_major" -lt "$MIN_MACOS_MAJOR" ]; then
    die "$APP_NAME nécessite macOS $MIN_MACOS_MAJOR (Sonoma) ou plus récent ; ce Mac utilise macOS $macos_version."
fi

# /usr/bin/swift exists on every Mac, as a stub that opens an installer dialog
# when no tools are present; `xcode-select -p` tells whether it is backed by a
# real toolchain.
if ! command -v swift >/dev/null 2>&1 || ! xcode-select -p >/dev/null 2>&1; then
    cat >&2 <<EOF
Erreur : le compilateur Swift est introuvable.

$APP_NAME se compile directement sur votre Mac. Il faut pour cela les outils de
développement en ligne de commande d'Apple (gratuits, Xcode n'est pas nécessaire) :

    xcode-select --install

Une fois leur installation terminée, relancez ./install.sh
EOF
    exit 1
fi

[ -f "$ROOT/scripts/build-app.sh" ] \
    || die "scripts/build-app.sh est introuvable : lancez install.sh depuis une copie complète du dépôt."

# --- Build, replace, launch --------------------------------------------------

step "Construction d'$APP_NAME (la première fois, cela peut prendre une minute)…"
# Through bash rather than by path: works even if the executable bit was lost.
bash "$ROOT/scripts/build-app.sh"
[ -d "$BUILT_APP" ] || die "la construction n'a pas produit $BUILT_APP"

quit_app

step "Installation…"
INSTALLED_APP=""
for dir in "/Applications" "$HOME/Applications"; do
    if [ "$dir" != "/Applications" ]; then
        mkdir -p "$dir" 2>/dev/null || true
    fi
    if install_into "$dir"; then
        INSTALLED_APP="$dir/$APP_NAME.app"
        break
    fi
    cleanup
    STAGING=""
done
[ -n "$INSTALLED_APP" ] \
    || die "impossible de copier $APP_NAME.app dans /Applications ni dans $HOME/Applications. L'application construite reste disponible ici : $BUILT_APP"

# Two copies with the same identifier confuse macOS (login item, permissions),
# so a previous install left in the other location goes away.
for other in "/Applications/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app"; do
    if [ "$other" = "$INSTALLED_APP" ] || [ ! -e "$other" ] || is_foreign_app "$other"; then
        continue
    fi
    remove_app "$other" \
        || warn "une autre copie d'$APP_NAME subsiste (droits insuffisants pour la supprimer) : $other. Pour éviter les doublons, mettez-la à la Corbeille depuis le Finder."
done

# Belt and braces: the build already strips extended attributes, but a
# quarantine flag on the installed copy (it follows files out of a downloaded
# zip) would make Gatekeeper refuse this locally built, ad-hoc signed app.
# (Absolute path: the `xattr` that pip installs has no -r option.)
/usr/bin/xattr -dr com.apple.quarantine "$INSTALLED_APP" 2>/dev/null || true

step "Lancement…"
open "$INSTALLED_APP" \
    || warn "le lancement automatique a échoué : ouvrez $INSTALLED_APP depuis le Finder."

cat <<EOF

${BOLD}$APP_NAME est installée :${RESET} $INSTALLED_APP

  • L'îlot vit dans l'encoche, tout en haut de l'écran.
  • Les réglages se trouvent dans l'icône $APP_NAME de la barre des menus.
  • Pour mettre à jour : relancez ./install.sh    Pour désinstaller : ./uninstall.sh
EOF
