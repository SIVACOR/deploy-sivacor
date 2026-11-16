#!/bin/sh
# Builds the Web Key Directory tree that the `openpgpkey` service publishes, so
# `gpg --locate-external-keys editors@sivacor.org` finds the TRS signing key from
# the domain itself (SIVACOR/documentation#36, request 4).
#
#   gpg --export ... | ./build-wkd.sh <domain> <outdir>
#
# Reads the exported public key on stdin, never the keyring: the Makefile exports
# it as the keyring's owner, and this script works in a throwaway GNUPGHOME, so
# nothing here can leave a root-owned file in the keyring local_worker signs with.
#
# Writes the WKD "advanced" layout, the only one gpg will use here: *.sivacor.org
# is a wildcard record, so openpgpkey.<domain> always resolves, and gpg then asks
# https://openpgpkey.<domain>/.well-known/openpgpkey/<domain>/hu/<hash> and never
# falls back to the apex (verified with gpg 2.4.4). The apex is GitHub Pages
# anyway, not this stack.
#
#   <outdir>/<domain>/policy          empty; its presence announces the directory
#   <outdir>/<domain>/hu/<zbase32>    the key, cut down to that one user ID
#
# Only user IDs at <domain> are published. On the test mirror (domain
# test.sivacor.org) a key whose addresses are @sivacor.org therefore yields an
# empty directory and a 404 for every lookup, which is correct: that host is not
# the authority for those addresses.
set -eu

domain=$1
out=$2

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GNUPGHOME="$tmp"

cat > "$tmp/key"
if [ ! -s "$tmp/key" ]; then
    echo "build-wkd: no key on stdin (is the fingerprint in the keyring?)" >&2
    exit 1
fi
gpg --batch --quiet --import "$tmp/key" 2>/dev/null
fprs=$(gpg --batch --with-colons --list-keys | awk -F: '$1 == "pub" { p = 1; next } p && $1 == "fpr" { print $10; p = 0 }')
if [ "$(printf '%s\n' "$fprs" | grep -c .)" -ne 1 ]; then
    echo "build-wkd: expected exactly one key on stdin, got: ${fprs:-none}" >&2
    exit 1
fi

# WKD hash: z-base-32 of SHA-1 over the lower-cased local part. 160 bits is
# exactly 32 five-bit characters, so there is no padding to get wrong.
wkd_hash() {
    python3 -c '
import hashlib, sys
alphabet = "ybndrfg8ejkmcpqxot1uwisza345h769"
n = int.from_bytes(hashlib.sha1(sys.argv[1].lower().encode()).digest(), "big")
print("".join(alphabet[(n >> (155 - 5 * i)) & 31] for i in range(32)))
' "$1"
}

# Rebuilt from scratch every time, so a user ID removed from the key also stops
# being published.
rm -rf "${out:?}/$domain"
mkdir -p "$out/$domain/hu"
: > "$out/$domain/policy"

published=0
for mbox in $(gpg --batch --with-colons --list-keys "$fprs" |
              awk -F: '$1 == "uid" && $2 != "r" { print $10 }' |
              sed -n 's/.*<\([^>]*\)>.*/\1/p' | tr 'A-Z' 'a-z' | sort -u); do
    [ "${mbox#*@}" = "$domain" ] || continue
    gpg --batch --export-options export-minimal \
        --export-filter keep-uid="mbox = $mbox" \
        --export "$fprs" > "$out/$domain/hu/$(wkd_hash "${mbox%@*}")"
    echo "build-wkd: published $mbox ($fprs)"
    published=$((published + 1))
done

# World-readable: nginx in the openpgpkey service reads these as its own user.
chmod -R a+rX "$out"

if [ "$published" -eq 0 ]; then
    echo "build-wkd: no user ID of $fprs is at $domain; WKD will answer 404" >&2
fi
