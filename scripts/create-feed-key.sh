#!/bin/zsh
# Creates the update feed signing key once, in the login Keychain. It never leaves this Mac unless you back it up.
# The script refuses to replace an existing key: installed apps trust only the matching public key.
set -euo pipefail
cd "${0:A:h:h}"
if security find-generic-password -a artifloam -s artifloam-feed-signing >/dev/null 2>&1; then
    print -u2 "A feed signing key already exists in the Keychain."; exit 1
fi
read -r private public < <(swift scripts/feed-signing.swift generate)
# Through stdin, so the key never appears in a process list.
print -r -- "add-generic-password -a artifloam -s artifloam-feed-signing -T /usr/bin/security -w \"$private\"" | security -i >/dev/null
print -r -- "$public"
