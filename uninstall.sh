#!/bin/bash
#
# Removes Islet: quits it, deletes the installed app bundle(s) and its
# preferences. Touches nothing else (the repo and its build/ folder stay).
#
# Usage: ./uninstall.sh

set -euo pipefail

readonly APP_NAME="Islet"
readonly BUNDLE_ID="io.github.paulapc94.islet"

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
    # Apple event can sit behind a consent prompt and must not stall the script.
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 &
    local asker=$!
    disown "$asker" 2>/dev/null || true
    if ! wait_until_gone 5; then
        pkill -U "$(id -u)" -x "$APP_NAME" >/dev/null 2>&1 || true
        if ! wait_until_gone 5; then
            pkill -9 -U "$(id -u)" -x "$APP_NAME" >/dev/null 2>&1 || true
            wait_until_gone 3 \
                || die "impossible de fermer $APP_NAME. Quittez-la depuis son icône dans la barre des menus, puis relancez ./uninstall.sh"
        fi
    fi
    kill "$asker" >/dev/null 2>&1 || true
}

# --- Bundles -----------------------------------------------------------------

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

# --- Uninstall ---------------------------------------------------------------

[ "$(uname -s)" = "Darwin" ] || die "$APP_NAME ne fonctionne que sur macOS."

if [ "$(id -u)" -eq 0 ]; then
    die "ne lancez pas ce script avec sudo : il supprimerait les réglages du mauvais compte."
fi

quit_app

removed=0
failed=0
for app in "/Applications/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app"; do
    [ -e "$app" ] || [ -L "$app" ] || continue
    if is_foreign_app "$app"; then
        warn "$app est une autre application portant le même nom : elle est laissée intacte."
        continue
    fi
    # Only the app can withdraw its own "launch at login" registration, so ask
    # it to before it disappears. Best effort: it fails when none was made.
    if [ -x "$app/Contents/MacOS/$APP_NAME" ]; then
        "$app/Contents/MacOS/$APP_NAME" --unregister-login-item >/dev/null 2>&1 || true
    fi
    if remove_app "$app"; then
        step "Supprimée : $app"
        removed=1
    else
        warn "impossible de supprimer $app (droits insuffisants). Mettez-la à la Corbeille depuis le Finder."
        failed=1
    fi
done

# Fails when there are no preferences yet, which is fine.
defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true

if [ "$failed" -ne 0 ]; then
    exit 1
fi
if [ "$removed" -eq 1 ]; then
    printf '\n%s%s est désinstallée.%s Ses réglages ont été effacés.\n' "$BOLD" "$APP_NAME" "$RESET"
else
    printf '\n%s n'\''était pas installée : aucune copie trouvée dans /Applications ni dans %s/Applications.\n' \
        "$APP_NAME" "$HOME"
fi
