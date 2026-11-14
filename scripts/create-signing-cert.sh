#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Creates the project's code signing identity and exports Sparkle's update key, once, on the owner's Mac: a
# self-signed certificate "Toma Project Signing" for code signing, valid 10 years, with its private key, in
# the login keychain (the key not extractable from it) and trusted for code signing. Every release is
# signed with it, so macOS sees the same app across updates and its permissions survive them. The script:
# - creates an AES-256 encrypted disk image first and makes every secret inside it, the only place they are
#   ever written outside the keychains: the .p12, its password, the .p12 in base64, and Sparkle's private
#   key, which generate_keys exports there itself (creating it in the login keychain first if there is none);
# - prints nothing secret: the certificate's SHA-1, Sparkle's public key (for Config/Identity.xcconfig) and
#   the `gh secret set` commands that read each secret from the mounted image;
# - waits, with the image mounted, until those are run, then detaches it.
# Nothing it writes goes into the repository. It asks for a password for the image, and macOS asks for the
# user's password once, to trust the certificate. Run `make build` first: it fetches Sparkle's tools.
#   bash scripts/create-signing-cert.sh
# Environment: BACKUP_IMAGE, where to write the encrypted image (default ~/Toma-signing-backup.dmg), outside
# the repository.
set -euo pipefail

repository=$(cd "$(dirname "$0")/.." && pwd -P)

name="Toma Project Signing"
# LibreSSL: Homebrew's OpenSSL 3 writes .p12 files that `security import` rejects.
openssl=/usr/bin/openssl
login_keychain="$HOME/Library/Keychains/login.keychain-db"
backup_image=${BACKUP_IMAGE:-$HOME/Toma-signing-backup.dmg}
generate_keys=$repository/build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys

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

[[ $# == 0 ]] || fail "takes no arguments: Sparkle's key is exported into the encrypted image, never to a file elsewhere"
[[ -x $generate_keys ]] || fail "$generate_keys not found: run make project && make build first (it fetches Sparkle)"
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
mount_point=$(mktemp -d)
mounted=false
cleanup() {
  if $mounted; then hdiutil detach -force "$mount_point" >/dev/null || true; fi
  rmdir "$mount_point" 2>/dev/null || true
}
trap cleanup EXIT

echo "Creating the encrypted backup image $backup_image"
printf '%s\0' "$image_password" |
  hdiutil create -encryption AES-256 -stdinpass -size 10m -fs APFS -volname "Toma signing backup" "$backup_image" >/dev/null
printf '%s\0' "$image_password" | hdiutil attach -stdinpass -nobrowse -mountpoint "$mount_point" "$backup_image" >/dev/null
mounted=true
unset image_password repeated

echo "Creating the certificate and its key, in the image"
p12_password=$("$openssl" rand -base64 24)
export P12_PASSWORD="$p12_password"  # openssl reads it from the environment, not from its command line
"$openssl" req -x509 -newkey rsa:2048 -days 3650 -nodes -keyout "$mount_point/key.pem" -out "$mount_point/toma-signing-cert.pem" \
  -subj "/CN=$name" -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning"
"$openssl" pkcs12 -export -inkey "$mount_point/key.pem" -in "$mount_point/toma-signing-cert.pem" -name "$name" \
  -out "$mount_point/toma-signing.p12" -passout env:P12_PASSWORD
unset P12_PASSWORD
rm "$mount_point/key.pem"  # the .p12 holds it
# No line break: each file is a GitHub secret exactly as it is.
printf '%s' "$p12_password" >"$mount_point/toma-signing.p12.password"
base64 <"$mount_point/toma-signing.p12" | tr -d '\n' >"$mount_point/toma-signing.p12.b64"
sha1=$("$openssl" x509 -in "$mount_point/toma-signing-cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')
expires=$("$openssl" x509 -in "$mount_point/toma-signing-cert.pem" -noout -enddate | sed 's/.*=//')

echo "Sparkle's EdDSA key (created in the login keychain if it is not there yet; the public key is not secret):"
"$generate_keys"
"$generate_keys" -x "$mount_point/sparkle_ed.key"
[[ -s $mount_point/sparkle_ed.key ]] || fail "generate_keys -x wrote no key into the image"

cat >"$mount_point/README.txt" <<EOF
$name, SHA-1 $sha1, valid until $expires.
toma-signing.p12           certificate and private key (security import ... -T /usr/bin/codesign -x)
toma-signing.p12.b64       the same in base64: the SIGNING_CERT_P12 secret
toma-signing.p12.password  its password: the SIGNING_CERT_PASSWORD secret
toma-signing-cert.pem      the certificate alone
sparkle_ed.key             Sparkle's private EdDSA key: the SPARKLE_ED_PRIVATE_KEY secret
                           (generate_keys -f sparkle_ed.key puts it back in a keychain)
Set a secret straight from this image: gh secret set <NAME> --env release < <file>
EOF

echo "Importing the certificate into the login keychain, its private key not extractable"
# -T: codesign may use the key. -x: it can never be exported from the keychain; the image keeps the .p12.
# `security import` takes the .p12 password only as an argument (-P) or in a dialog, so for the moment it
# runs it is visible to this user's other processes (ps); it only unlocks this .p12, kept in the image.
security import "$mount_point/toma-signing.p12" -k "$login_keychain" -P "$p12_password" -T /usr/bin/codesign -x ||
  fail "security import failed. $backup_image holds a certificate that is not in the keychain: delete it before trying again"
unset p12_password
echo "Trusting it for code signing (macOS asks for your password)"
security add-trusted-cert -r trustRoot -p codeSign -k "$login_keychain" "$mount_point/toma-signing-cert.pem" ||
  fail "trusting the certificate failed: it is in the keychain but codesign won't use it. Trust it for code signing in Keychain Access, or delete it and $backup_image before trying again"
security find-identity -p codesigning -v | grep -F "\"$name\"" ||
  fail "\"$name\" is not a valid code signing identity after importing and trusting it"

cat <<EOF

Certificate "$name"
  SHA-1:       $sha1
  valid until: $expires
  backup:      $backup_image (encrypted; keep two copies offline)

The image is mounted at $mount_point. With the GitHub repository and its "release" environment created,
set the secrets now from another Terminal window; each reads its file, nothing is shown:
  gh secret set SIGNING_CERT_P12 --env release < "$mount_point/toma-signing.p12.b64"
  gh secret set SIGNING_CERT_PASSWORD --env release < "$mount_point/toma-signing.p12.password"
  gh secret set SPARKLE_ED_PRIVATE_KEY --env release < "$mount_point/sparkle_ed.key"
Later, open the image and run the same commands with its mount point.
EOF
read -r -p "Press Return to detach the image: " _
