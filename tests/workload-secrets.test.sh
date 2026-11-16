#!/bin/sh
# Tests for scripts/workload-secrets.sh. Run: sh tests/workload-secrets.test.sh (also under busybox:
# the actions image is Alpine, and needs jq).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../scripts/workload-secrets.sh"

FAILS=0
eq() { # name expected actual
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "  expected: $2"; echo "  actual:   $3"; FAILS=$((FAILS + 1)); fi
}
OUT=""
rec() { OUT="$OUT[$1=$2]"; }
run() { OUT=""; WORKLOAD_SECRETS="$1"; each_workload_secret rec; }

run 'a=1
b=x=y'
eq "legacy lines"        "[a=1][b=x=y]" "$OUT"

run '{"db": "postgres://u:p@h/d?x=1" }
legacy=2'
eq "json and legacy mixed" "[db=postgres://u:p@h/d?x=1][legacy=2]" "$OUT"

PEM='-----BEGIN KEY-----
abc
Zm9vYmFy==
-----END KEY-----'
run "{\"key\": $(printf '%s' "$PEM" | jq -Rs .) }"
eq "pem round trip"      "[key=$PEM]" "$OUT"

run "{\"k\": $(printf 'v\n\n' | jq -Rs .) }"
eq "trailing newlines kept" "[k=v

]" "$OUT"

run '{"unset": "" }'
eq "empty json value reaches the callback empty" "[unset=]" "$OUT"

run '{"n": null }'
eq "null (an unset secret) arrives empty, name kept" "[n=]" "$OUT"

run '{"two": "a", "x": "b" }
{"a-b": "ok" }'
eq "multi-key skipped" "[a-b=ok]" "$OUT"

run 'NOEQUALS
bad name=1
{"bad name": "1" }
{not json
ok=1'
eq "malformed skipped"   "[ok=1]" "$OUT"

run "$(printf 'crlf=value\r\n')"
eq "crlf stripped"       "[crlf=value]" "$OUT"

run 'a=1'; OUT=""; WORKLOAD_SECRETS=""; each_workload_secret rec
eq "empty bag"           "" "$OUT"

w=$(WORKLOAD_SECRETS='{"s": "topsecret"
not-a-secret-line-topsecret' ; each_workload_secret rec)
case "$w" in *topsecret*) eq "warnings never echo lines" "no echo" "echoed" ;; *) eq "warnings never echo lines" 1 1 ;; esac

[ "$FAILS" -eq 0 ] || exit 1
