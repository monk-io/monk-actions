#!/bin/sh
# Tests for load_kv_bag in entrypoints/_common.sh. Run: sh tests/kv-bag.test.sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../entrypoints/_common.sh"

FAILS=0
eq() { # name expected actual
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "  expected: $2"; echo "  actual:   $3"; FAILS=$((FAILS + 1)); fi
}

JSON='{
  "type": "service_account",
  "private_key": "-----BEGIN PRIVATE KEY-----\nabc==\n-----END PRIVATE KEY-----\n"
}'
load_kv_bag "GCP_SERVICE_ACCOUNT_KEY=$JSON
GCP_PROJECT_ID=proj"
eq "multiline json value"   "$JSON" "$GCP_SERVICE_ACCOUNT_KEY"
eq "entry after multiline"  "proj"  "$GCP_PROJECT_ID"

load_kv_bag "A=x=y
B=

C=3"
eq "value with ="  "x=y" "$A"
eq "empty value"   ""    "$B"
eq "after blank"   "3"   "$C"

load_kv_bag "junk line
D=1"
eq "leading junk ignored" "1" "$D"


load_kv_bag "TOKEN=-----BEGIN-----
abc==
Zm9vYmFy==
-----END-----"
eq "base64 lines ending in = stay in the value" "-----BEGIN-----
abc==
Zm9vYmFy==
-----END-----" "$TOKEN"
eq "no variable named after a base64 line" "" "${abc:-}${Zm9vYmFy:-}"

[ "$FAILS" -eq 0 ] || exit 1
