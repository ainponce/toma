#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Creates the project's code signing identity, once, on the owner's Mac: a self-signed certificate
# "Toma Project Signing" for code signing, valid 10 years, with its private key, in the login keychain and
# trusted for code signing. Every release is signed with it, so macOS sees the same app across updates and
# its permissions survive them. The script:
# - keeps the .p12, its password and Sparkle's private key (sparkle_ed.key, if given) in an AES-256
#   encrypted disk image, for a copy kept offline;
# - prints the certificate's SHA-1, and the .p12 in base64 with its password: the GitHub secrets
#   SIGNING_CERT_P12 and SIGNING_CERT_PASSWORD of the `release` environment.
# Nothing it writes goes into the repository. It asks for a password for the image, and macOS asks for the
# user's password once, to trust the certificate.
#   bash scripts/create-signing-cert.sh [~/sparkle_ed.key]
# Environment: BACKUP_IMAGE, where to write the encrypted image (default ~/Toma-signing-backup.dmg).
# The Sparkle key and the image must be outside the repository.
set -euo pipefail

repository=$(cd "$(dirname "$0")/.." && pwd -P)

name="Toma Project Signing"
# LibreSSL: Homebrew's OpenSSL 3 writes .p12 files that `security import` rejects.
openssl=/usr/bin/openssl
login_keychain="$HOME/Library/Keychains/login.keychain-db"
sparkle_key=${1:-}
backup_image=${BACKUP_IMAGE:-$HOME/Toma-signing-backup.dmg}

fail() {
  echo "create-signing-cert: $*" >&2
  exit 1
}

# Whether a path (existing or not) is inside the repository, where `git add -A` would pick it up.
in_repository() {
  local dir
  dir=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P) || return 1
  [[ $dir/ == "$repository"/* ]]
}

if [[ -n $sparkle_key ]]; then
  [[ -f $sparkle_key ]] || fail "$sparkle_key not found"
  in_repository "$sparkle_key" &&
    fail "$sparkle_key is inside the repository: export the key outside it (generate_keys -x ~/sparkle_ed.key) and delete this copy (rm -P)"
fi
[[ ! -e $backup_image ]] || fail "$backup_image already exists: move it away first"
in_repository "$backup_image" && fail "$backup_image is inside the repository: set BACKUP_IMAGE to a path outside it"
if security find-certificate -c "$name" "$login_keychain" >/dev/null 2>&1; then
  fail "\"$name\" is already in the login keychain. Keep using it; a new certificate makes macOS ask every user for the permissions again"
fi

# Asked first, so the rest runs without stopping.
read -r -s -p "Password for the encrypted backup image: " image_password
echo
read -r -s -p "The same password again: " repeated
echo
[[ -n $image_password && $image_password == "$repeated" ]] || fail "the passwords are empty or differ"

umask 077
work=$(mktemp -d)
mount_point=$(mktemp -d)
mounted=false
cleanup() {
  # Detach before removing anything: the image is mounted outside the work folder, never inside it.
  if $mounted; then hdiutil detach -force "$mount_point" >/dev/null || true; fi
  rmdir "$mount_point" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

echo "Creating the certificate and its key"
p12_password=$("$openssl" rand -base64 24)
export P12_PASSWORD="$p12_password"  # openssl reads it from the environment, not from its command line
"$openssl" req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout "$work/key.pem" -out "$work/cert.pem" \
  -subj "/CN=$name" -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning"
"$openssl" pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" \
  -out "$work/signing.p12" -passout env:P12_PASSWORD
unset P12_PASSWORD
sha1=$("$openssl" x509 -in "$work/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')
expires=$("$openssl" x509 -in "$work/cert.pem" -noout -enddate | sed 's/.*=//')

echo "Writing the encrypted backup image $backup_image"
printf '%s\0' "$image_password" |
  hdiutil create -encryption AES-256 -stdinpass -size 10m -fs APFS -volname "Toma signing backup" "$backup_image" >/dev/null
printf '%s\0' "$image_password" | hdiutil attach -stdinpass -nobrowse -mountpoint "$mount_point" "$backup_image" >/dev/null
mounted=true
cp "$work/signing.p12" "$mount_point/toma-signing.p12"
cp "$work/cert.pem" "$mount_point/toma-signing-cert.pem"
printf '%s\n' "$p12_password" >"$mount_point/toma-signing.p12.password"
[[ -z $sparkle_key ]] || cp "$sparkle_key" "$mount_point/sparkle_ed.key"
cat >"$mount_point/README.txt" <<EOF
$name, SHA-1 $sha1, valid until $expires.
toma-signing.p12           certificate and private key (security import, or the SIGNING_CERT_P12 secret in base64)
toma-signing.p12.password  its password (the SIGNING_CERT_PASSWORD secret)
toma-signing-cert.pem      the certificate alone
sparkle_ed.key             Sparkle's private EdDSA key, if it was given (the SPARKLE_ED_PRIVATE_KEY secret;
                           generate_keys -f sparkle_ed.key puts it back in a keychain)
EOF
hdiutil detach "$mount_point" >/dev/null
mounted=false

echo "Importing it into the login keychain"
# -T: codesign may use the key. `security import` takes the .p12 password only as an argument (-P) or in
# a dialog, so for the moment it runs it is visible to this user's other processes (ps); it only unlocks
# this .p12, which is in the encrypted image and is deleted when the script ends.
security import "$work/signing.p12" -k "$login_keychain" -P "$p12_password" -T /usr/bin/codesign ||
  fail "security import failed. $backup_image holds a certificate that is not in the keychain: delete it before trying again"
echo "Trusting it for code signing (macOS asks for your password)"
security add-trusted-cert -r trustRoot -p codeSign -k "$login_keychain" "$work/cert.pem" ||
  fail "trusting the certificate failed: it is in the keychain but codesign won't use it. Trust it for code signing in Keychain Access, or delete it and $backup_image before trying again"
security find-identity -p codesigning -v | grep -F "\"$name\"" ||
  fail "\"$name\" is not a valid code signing identity after importing and trusting it"

echo
echo "Certificate \"$name\""
echo "  SHA-1:       $sha1"
echo "  valid until: $expires"
echo "  backup:      $backup_image (encrypted; keep a copy offline)"
[[ -z $sparkle_key ]] || echo "  $sparkle_key is in the backup: delete it here once it is the SPARKLE_ED_PRIVATE_KEY secret (rm -P \"$sparkle_key\")"
echo
echo "GitHub secret SIGNING_CERT_PASSWORD (environment \"release\"):"
echo "$p12_password"
echo
echo "GitHub secret SIGNING_CERT_P12 (environment \"release\"):"
base64 -i "$work/signing.p12"
