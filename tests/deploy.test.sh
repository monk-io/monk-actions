#!/bin/sh
# Runs scripts/dynenv-deploy.sh against a stub `monk` that records what it is asked to do.
# Run: sh tests/deploy.test.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPTS="$HERE/../scripts"
FAILS=0
eq() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "  expected: $2"; echo "  actual:   $3"; FAILS=$((FAILS + 1)); fi; }

T=$(mktemp -d)
mkdir "$T/bin" "$T/work"
cat > "$T/bin/monk" <<'S'
#!/bin/sh
# record the call; `load` also records the template as it is at that moment
case "$*" in
    *"cluster peers"*) echo '[]'; exit 0 ;;
esac
echo "monk $*" >> "$STUB_LOG"
case "$1" in load) cat template.yaml >> "$STUB_LOG" ;; esac
exit 0
S
chmod +x "$T/bin/monk"
export PATH="$T/bin:$PATH" STUB_LOG="$T/log" PARSE_MANIFEST="$SCRIPTS/parse-manifest.sh"
export MONKCODE=x MONK_SERVICE_TOKEN=y MONK_WORKLOAD=sample/stack ENVIRONMENT_NAME=feat-a

cd "$T/work" || exit 1
printf 'REPO sample\nLOAD template.yaml\nENTRY sample/stack\nIMAGE app:latest sample/web . Dockerfile\n' > MANIFEST
printf 'web:\n  containers:\n    c:\n      image: app:latest\n' > template.yaml

run() { : > "$STUB_LOG"; sh "$SCRIPTS/dynenv-deploy.sh" > "$T/out" 2>&1; echo $?; }

# cluster mode: secrets (scoped) first, then load of the rewritten template, then update
export CAPSULE_MODE=cluster IMAGE_SUFFIX=feat-a
export WORKLOAD_SECRETS='greeting=hello=world
empty=
other=two'
eq "cluster deploy succeeds" 0 "$(run)"
eq "cluster: order, scope, values with =, empty skipped, template rewritten" "monk secrets add --scope feat-a greeting=hello=world
monk secrets add --scope feat-a other=two
monk load --repo feat-a MANIFEST
web:
  containers:
    c:
      image: app:latest-feat-a
monk update -t capsule-pool --repo feat-a --secret-scope feat-a -s environment=feat-a feat-a/sample/stack
monk ps" "$(cat "$STUB_LOG")"
eq "values are not printed" 0 "$(grep -c 'hello=world\|two' "$T/out")"

# cloud mode: global secrets, no suffix: template as written
printf 'web:\n  containers:\n    c:\n      image: app:latest\n' > template.yaml
export CAPSULE_MODE=cloud BRANCH_TAG=branch-feat-a; unset IMAGE_SUFFIX
export WORKLOAD_SECRETS='greeting=hi'
eq "cloud deploy succeeds" 0 "$(run)"
eq "cloud: global secret, template as written" "monk secrets add -g greeting=hi
monk load MANIFEST
web:
  containers:
    c:
      image: app:latest
monk update -t branch-feat-a -s environment=feat-a sample/stack
monk ps" "$(cat "$STUB_LOG")"

# static: the image suffix still applies (build-images doesn't know the mode), secrets are ignored
export CAPSULE_MODE=static IMAGE_SUFFIX=feat-a
eq "static deploy succeeds" 0 "$(run)"
eq "static: rewrite, no secrets" "monk load MANIFEST
web:
  containers:
    c:
      image: app:latest-feat-a
monk update -t branch-feat-a sample/stack
monk ps" "$(cat "$STUB_LOG")"
eq "static says the secrets are ignored" 1 "$(grep -c 'only used for capsules' "$T/out")"

# lines that aren't NAME=value, or whose name is odd, are skipped without being printed
printf 'web:\n  containers:\n    c:\n      image: app:latest\n' > template.yaml
export CAPSULE_MODE=cloud BRANCH_TAG=branch-feat-a; unset IMAGE_SUFFIX
export WORKLOAD_SECRETS='NOEQUALS
bad name=x
=novalue
good=ok'
eq "odd lines deploy" 0 "$(run)"
eq "only the valid line is set" "monk secrets add -g good=ok" "$(grep 'secrets add' "$STUB_LOG")"
eq "skipped lines are not echoed" 0 "$(grep -c 'NOEQUALS\|bad name\|novalue' "$T/out")"

# a MANIFEST whose last LOAD file is missing still deploys
printf 'REPO sample\nLOAD template.yaml\nLOAD missing.yaml\nENTRY sample/stack\nIMAGE app:latest sample/web . Dockerfile\n' > MANIFEST
export CAPSULE_MODE=cluster IMAGE_SUFFIX=feat-a; unset WORKLOAD_SECRETS
eq "missing last template doesn't stop the deploy" 0 "$(run)"
printf 'REPO sample\nLOAD template.yaml\nENTRY sample/stack\nIMAGE app:latest sample/web . Dockerfile\n' > MANIFEST

# a line ending from a file edited on Windows is not part of the value
cat > "$T/bin/monk" <<'S'
#!/bin/sh
echo "monk $*" >> "$STUB_LOG"
exit 0
S
export CAPSULE_MODE=cloud BRANCH_TAG=branch-feat-a; unset IMAGE_SUFFIX
export WORKLOAD_SECRETS="$(printf 'crlf=value\r\nonly-cr=\r\n')"
eq "CRLF deploy succeeds" 0 "$(run)"
eq "the carriage return is dropped, and a value that was only one is empty and skipped" "monk secrets add -g crlf=value" "$(grep 'secrets add' "$STUB_LOG")"

# a failing secret write fails the deploy before anything is loaded, without printing the value
cat > "$T/bin/monk" <<'S'
#!/bin/sh
echo "monk $*" >> "$STUB_LOG"
case "$1 $2" in "secrets add") echo "failed: $*" >&2; exit 1 ;; esac
exit 0
S
export CAPSULE_MODE=cluster WORKLOAD_SECRETS='a=topsecretvalue'
r=$(run)
eq "failed secret write fails the deploy" 1 "$r"
eq "and nothing is loaded" 0 "$(grep -c 'monk load' "$STUB_LOG")"
eq "and the value is not in the output" 0 "$(grep -c 'topsecretvalue' "$T/out")"

rm -rf "$T"
[ "$FAILS" -eq 0 ] && echo "all passed" || { echo "$FAILS failed"; exit 1; }
