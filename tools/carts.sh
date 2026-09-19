#!/bin/sh
# Regenerates everything that has to agree with carts.txt: the shelf's list and
# the table of licences in THIRD-PARTY.md. Run by `make assets`, so the three
# cannot drift apart.
#
# With an argument of `ids`, prints one cart id per line instead, which is how
# fetch-assets.sh knows what to download.
set -eu
cd "$(dirname "$0")/.."

CONFIG=carts.txt
LIST=Sources/W4/CartList.swift
NOTICE=THIRD-PARTY.md

# Fields, trimmed, from the lines that are not comments or blank.
fields() {
    awk -F'|' '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        {
            if (NF != 4) {
                printf "carts.txt:%d: expected four fields separated by |, found %d\n", NR, NF > "/dev/stderr"
                exit 1
            }
            for (i = 1; i <= NF; i++) {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
            }
            print $1 "\t" $2 "\t" $3 "\t" $4
        }
    ' "$CONFIG"
}

# Checked before anything is written, so a malformed line leaves the generated
# files as they were rather than half rewritten.
if ! fields >/dev/null; then
    echo "carts.txt is malformed; nothing was regenerated" >&2
    exit 1
fi

if [ "${1:-}" = "ids" ]; then
    fields | cut -f1
    exit 0
fi

# ---- the shelf's list ----
{
    echo "// Generated from carts.txt by tools/carts.sh. Do not edit."
    echo
    echo "let carts: [CartEntry] = ["
    fields | while IFS="$(printf '\t')" read -r id title licence upstream; do
        printf '    CartEntry(title: "%s", path: "carts/%s.wasm", cover: "covers/%s"),\n' \
            "$title" "$id" "$id"
    done
    echo "]"
} > "$LIST.tmp"
mv "$LIST.tmp" "$LIST"

# ---- the table of licences ----
{
    sed -n '1,/^<!-- carts:begin -->$/p' "$NOTICE"
    echo "| Cart | Upstream | Licence |"
    echo "| --- | --- | --- |"
    fields | while IFS="$(printf '\t')" read -r id title licence upstream; do
        printf '| `%s` | %s | %s |\n' "$id" "$upstream" "$licence"
    done
    sed -n '/^<!-- carts:end -->$/,$p' "$NOTICE"
} > "$NOTICE.tmp"
mv "$NOTICE.tmp" "$NOTICE"

echo "cart list: $(fields | wc -l | tr -d ' ') games"
