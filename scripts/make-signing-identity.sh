#!/bin/bash
#
# Creates the local code-signing identity that scripts/build-app.sh signs Islet
# with: a self-signed certificate named "Islet Local Signing" and its private
# key, in your login keychain. Run it once; ./install.sh does the rest.
#
# Why: macOS ties a permission such as Accessibility to the signature of the
# app it was given to. An ad-hoc signature only names one exact build, so every
# update loses the permission. Signed with a certificate that stays the same,
# every build is the same app to macOS, and the permission is kept.
#
# Usage: scripts/make-signing-identity.sh        (from any directory)
#
# Safe to run again: it does nothing when the identity already exists. Never
# asks for administrator rights and leaves the trust settings alone: the
# certificate stays untrusted, which codesign does not mind.

set -euo pipefail

readonly IDENTITY="Islet Local Signing"
readonly VALIDITY_DAYS=3650

# Tests only: ISLET_SIGNING_KEYCHAIN names a keychain file to use instead of
# the login keychain (scripts/build-app.sh honours the same variable).
readonly TEST_KEYCHAIN="${ISLET_SIGNING_KEYCHAIN:-}"
readonly KEYCHAIN="${TEST_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    BOLD=""; RESET=""
fi

step() { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$1"; }
die() { printf 'Erreur : %s\n' "$1" >&2; exit 1; }

# The private key exists as a file only between its creation and its import.
WORK=""
cleanup() {
    if [ -n "$WORK" ]; then
        rm -rf "$WORK" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 141' PIPE
trap 'exit 143' TERM

# Runs a command quietly: its output is only worth showing when it fails.
quietly() {
    local output
    if ! output="$("$@" 2>&1)"; then
        printf '%s\n' "$output" >&2
        return 1
    fi
}

# Prints what `security` lists under the identity's name (certificate and
# private key together) where build-app.sh looks for it: the user's keychains,
# or the test keychain alone. Reads only; nothing is printed when there is none.
# No -v: a self-signed certificate is listed as untrusted, never as "valid".
identity_lines() {
    local identities
    if [ -n "$TEST_KEYCHAIN" ]; then
        identities="$(/usr/bin/security find-identity -p codesigning "$TEST_KEYCHAIN" 2>/dev/null || true)"
    else
        identities="$(/usr/bin/security find-identity -p codesigning 2>/dev/null || true)"
    fi
    printf '%s\n' "$identities" | grep -F "\"$IDENTITY\"" || true
}

# True when an identity codesign accepts is there. An expired certificate is
# listed too, but codesign refuses to sign with it ("no identity found").
identity_exists() {
    identity_lines | grep -v -e CSSMERR_TP_CERT_EXPIRED -e CSSMERR_TP_CERT_NOT_VALID_YET >/dev/null
}

identity_expired() {
    identity_lines | grep -e CSSMERR_TP_CERT_EXPIRED >/dev/null
}

# Signs $1 the way build-app.sh does.
sign_with_identity() {
    if [ -n "$TEST_KEYCHAIN" ]; then
        codesign --force --timestamp=none --sign "$IDENTITY" --keychain "$TEST_KEYCHAIN" "$1"
    else
        codesign --force --timestamp=none --sign "$IDENTITY" "$1"
    fi
}

# --- Checks ------------------------------------------------------------------

[ "$(uname -s)" = "Darwin" ] || die "ce script ne fonctionne que sur macOS."

if [ "$(id -u)" -eq 0 ]; then
    die "ne lancez pas ce script avec sudo : l'identité doit aller dans votre propre trousseau."
fi

# By absolute path: these ship with macOS, and a Homebrew openssl earlier in
# PATH does not write the key in a form `security import` is sure to read.
for tool in /usr/bin/openssl /usr/bin/security; do
    [ -x "$tool" ] || die "« $tool » est introuvable."
done
command -v codesign >/dev/null 2>&1 \
    || die "« codesign » est introuvable. Installez les outils de développement d'Apple : xcode-select --install"

if identity_exists; then
    printf "L'identité « %s » existe déjà : rien à faire.\n" "$IDENTITY"
    exit 0
fi

if identity_expired; then
    printf "L'identité « %s » de votre trousseau a expiré : une nouvelle va la remplacer (vous pourrez supprimer l'ancienne dans Trousseaux d'accès).\n" "$IDENTITY"
fi

[ -f "$KEYCHAIN" ] || die "trousseau introuvable : $KEYCHAIN"

# --- Certificate -------------------------------------------------------------

step "Création du certificat « $IDENTITY » (auto-signé, valable $((VALIDITY_DAYS / 365)) ans)…"

umask 077
WORK="$(mktemp -d "${TMPDIR:-/tmp}/islet-signing.XXXXXX")"

# macOS shows the base name of the imported file as the key's name when it asks
# whether a tool may use it, so the file is named after the identity.
readonly KEY_FILE="$WORK/$IDENTITY.pem"
readonly CERT_FILE="$WORK/certificate.pem"

cat > "$WORK/certificate.cnf" <<EOF
[ req ]
distinguished_name = subject
x509_extensions = extensions
prompt = no

[ subject ]
CN = $IDENTITY

[ extensions ]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

quietly /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -sha256 \
    -days "$VALIDITY_DAYS" -config "$WORK/certificate.cnf" \
    -keyout "$KEY_FILE" -out "$CERT_FILE" \
    || die "la création du certificat a échoué."

# --- Keychain ----------------------------------------------------------------

step "Ajout au trousseau…"

# -T: codesign may use the key. -x: the key cannot be exported again.
quietly /usr/bin/security import "$KEY_FILE" -k "$KEYCHAIN" -x -T /usr/bin/codesign \
    || die "l'ajout de la clé privée au trousseau a échoué. Si votre trousseau « session » est verrouillé, déverrouillez-le (app Trousseaux d'accès), puis relancez ce script."
quietly /usr/bin/security import "$CERT_FILE" -k "$KEYCHAIN" \
    || die "l'ajout du certificat au trousseau a échoué (la clé privée « Imported Private Key », elle, y est déjà : supprimez-la dans Trousseaux d'accès avant de réessayer)."

# The key now lives in the keychain only.
rm -f "$KEY_FILE"

identity_exists \
    || die "l'identité vient d'être ajoutée mais reste introuvable dans le trousseau : $KEYCHAIN"

# --- Trial signature ---------------------------------------------------------

# Better here, where it is expected, than in the middle of ./install.sh: if
# macOS wants a confirmation before codesign uses the new key, it asks now.
step "Signature d'essai…"
cat <<EOF
    Il se peut que macOS affiche une fenêtre « codesign souhaite signer avec la
    clé "$IDENTITY" de votre trousseau ». Saisissez alors le mot de passe de
    votre trousseau (en général celui de votre session) et cliquez sur
    « Toujours autoriser » (avec « Autoriser », la question reviendrait à
    chaque construction). Ce mot de passe va à macOS, jamais à ce script.
EOF

cp /usr/bin/true "$WORK/essai"
if ! quietly sign_with_identity "$WORK/essai" \
    || ! quietly codesign --verify --strict "$WORK/essai"; then
    die "l'identité est créée, mais codesign n'a pas pu signer avec elle. Si vous avez refusé l'accès à la clé, répondez « Toujours autoriser » quand macOS reposera la question, au prochain ./install.sh."
fi

cat <<EOF

${BOLD}L'identité « $IDENTITY » est prête.${RESET}

  • Relancez ./install.sh : Islet sera désormais signée avec elle.
  • Si vous utilisez « Éviter les icônes de la barre des menus » : après cette
    installation, autorisez Islet une dernière fois (Réglages Système →
    Confidentialité et sécurité → Accessibilité : retirez Islet de la liste avec
    le bouton –, puis autorisez-la de nouveau quand elle le demande). Les mises
    à jour suivantes conserveront l'autorisation.
  • Rien n'a été modifié dans les réglages de confiance du Mac : le certificat
    ne sert qu'à signer Islet sur cette machine. Pour le retirer : app
    Trousseaux d'accès, trousseau « session », éléments « $IDENTITY »
    (certificat) et « Imported Private Key » (sa clé).
EOF
