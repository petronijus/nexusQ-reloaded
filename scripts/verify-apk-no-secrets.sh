#!/usr/bin/env bash
# Refuse to publish an apk that carries personal access.
#
# The sibling gate `release-preflight-no-secrets.sh` guards the ROOTFS IMAGE,
# because a release uploads that image to public GitHub. It was written on
# 2026-07-02 and it works. But the same personal files are also baked into the
# `device-google-steelhead` PACKAGE — the APKBUILD installs the staged
# `wifi.nmconnection` and `ssh-authorized-keys` when they are non-empty — and the
# OTA repo publishes that package to a **public GitHub Pages branch**. Nothing
# checked that side.
#
# Found 2026-08-30: every published `device-google-steelhead-*.apk` from **r62
# (2026-08-02) onward** contained `etc/NetworkManager/system-connections/
# wifi.nmconnection` with the WPA PSK in plain text, plus the ssh public keys.
# Four weeks, public repo. The image gate would have caught the identical bytes
# one directory away; it simply was not pointed at the packages.
#
# So: this gate looks INSIDE each apk about to be published.
#
# Usage:
#   scripts/verify-apk-no-secrets.sh <file.apk> [file.apk ...]
#
# Exit 0 = clean, exit 1 = personal data found (abort the publish), exit 2 = the
# gate could not look, which is also a failure. A gate that cannot read what it
# judges must say so in the exit code — two release gates fixed earlier the same
# day had been reporting success for months for exactly that reason.
set -uo pipefail

[ $# -gt 0 ] || { echo "usage: $0 <file.apk> [file.apk ...]" >&2; exit 2; }

FAIL=0
CHECKED=0

# What counts as personal, by PATH inside the package. Deliberately broader than
# "the two files we bake today": anything that looks like a credential or a
# key belongs nowhere near a public repo, whether or not we put it there on
# purpose.
is_personal_path() {
    case "$1" in
        *NetworkManager/system-connections/*) return 0 ;;
        *authorized_keys)                     return 0 ;;
        *.nmconnection)                       return 0 ;;
        */wpa_supplicant.conf)                return 0 ;;
        *id_rsa|*id_ed25519|*id_ecdsa)        return 0 ;;
        */shadow|*/gshadow)                   return 0 ;;
        *mqtt.json|*/secrets.json)            return 0 ;;
    esac
    return 1
}

for apk in "$@"; do
    [ -r "$apk" ] || { echo "FAIL: cannot read $apk — the gate cannot look" >&2; exit 2; }
    listing="$(tar tzf "$apk" 2>/dev/null)" || {
        echo "FAIL: cannot list $apk — the gate cannot look" >&2; exit 2; }
    [ -n "$listing" ] || { echo "FAIL: $apk lists no members — refusing to bless it" >&2; exit 2; }
    CHECKED=$((CHECKED + 1))
    name="$(basename "$apk")"

    hits=""
    while IFS= read -r member; do
        case "$member" in */) continue ;; esac
        is_personal_path "$member" || continue
        # Present is not automatically damning: PUBLIC_RELEASE=1 stages EMPTY
        # placeholders and the APKBUILD then installs nothing, but a future
        # change could ship an empty file. Judge the CONTENT — a profile with no
        # psk= and an empty authorized_keys carry no secret.
        body="$(tar xzOf "$apk" "$member" 2>/dev/null)"
        case "$member" in
            *authorized_keys)
                # Any non-comment, non-blank line is somebody's key.
                if printf '%s\n' "$body" | grep -qE '^[^#[:space:]]'; then
                    hits="$hits\n      $member — contains ssh key(s)"
                fi ;;
            *)
                # A psk=/password=/private key with an actual value.
                if printf '%s\n' "$body" | grep -qE '^[[:space:]]*(psk|password|passwd|pre-shared-key)[[:space:]]*=[[:space:]]*[^[:space:]]'; then
                    hits="$hits\n      $member — contains a plaintext key/password"
                elif printf '%s\n' "$body" | grep -q 'BEGIN [A-Z ]*PRIVATE KEY'; then
                    hits="$hits\n      $member — contains a private key"
                fi ;;
        esac
    done <<< "$listing"

    if [ -n "$hits" ]; then
        FAIL=$((FAIL + 1))
        printf '  \033[31mFAIL\033[0m  %s%b\n' "$name" "$hits"
    else
        printf '  \033[32mPASS\033[0m  %s\n' "$name"
    fi
done

echo
if [ "$FAIL" -ne 0 ]; then
    cat >&2 <<'MSG'
ABORTING PUBLISH: one or more packages carry personal access.

The OTA repo is a PUBLIC GitHub Pages branch — publishing these hands out the
WiFi PSK and ssh keys to anyone who fetches the URL.

Rebuild the packages clean:
    PUBLIC_RELEASE=1 ./docker-build.sh
which stages EMPTY placeholders so the APKBUILD installs no access files at all.

⚠️ Do NOT simply publish a clean build of the SAME package over a personal one
   in the field: apk removes files that leave a package's file list, so a device
   upgrading from a personal build to a clean one loses its WiFi profile and its
   root authorized_keys — offline and locked out. Baked access has to move OUT
   of an OTA-shipped package before that package can be published at all.
MSG
    exit 1
fi
echo "$CHECKED package(s) clean — no personal access inside."
