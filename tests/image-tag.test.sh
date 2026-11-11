#!/bin/sh
# Tests for scripts/image-tag.sh. Run: sh tests/image-tag.test.sh (also under busybox: the actions
# image is Alpine).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
export PARSE_MANIFEST="$HERE/../scripts/parse-manifest.sh"
. "$HERE/../scripts/image-tag.sh"

FAILS=0
eq() { # name expected actual
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "  expected: $2"; echo "  actual:   $3"; FAILS=$((FAILS + 1)); fi
}
fails() { # name command...
    n="$1"; shift
    if "$@" > /dev/null 2>&1; then echo "FAIL $n (succeeded)"; FAILS=$((FAILS + 1)); else echo "ok   $n"; fi
}

# ── branch_image_tag
eq "tag as written"          "capsule-sample:latest-feat-a"   "$(branch_image_tag capsule-sample:latest feat-a)"
eq "no tag is latest"        "capsule-sample:latest-feat-a"   "$(branch_image_tag capsule-sample feat-a)"
eq "path in the name"        "acme/app:v1-feat-a"             "$(branch_image_tag acme/app:v1 feat-a)"
eq "registry with a port"    "reg:5000/app:latest-b"          "$(branch_image_tag reg:5000/app b)"
eq "registry port and tag"   "reg:5000/app:2-b"               "$(branch_image_tag reg:5000/app:2 b)"
fails "digest"               branch_image_tag app@sha256:abcd feat-a
fails "empty suffix"         branch_image_tag app ""
fails "suffix with a slash"  branch_image_tag app "a/b"
fails "tag too long"         branch_image_tag "app:$(printf 'x%.0s' $(seq 1 125))" abc

# ── rewriting
T=$(mktemp -d)
cd "$T" || exit 1
cat > MANIFEST <<'M'
REPO sample
LOAD tpl.yaml
DIRS sub
ENTRY sample/stack
IMAGE capsule-sample:latest sample/web . Dockerfile
IMAGE api:v2 sample/api ./api Dockerfile
IMAGE untouched:1 sample/none . Dockerfile
M
mkdir sub
printf 'LOAD sub.yaml\n' > sub/MANIFEST
cat > tpl.yaml <<'Y'
namespace: capsule-sample
web:
  defines: runnable
  containers:
    app:
      image: capsule-sample:latest
    other:
      image: "capsule-sample"
    keep:
      image: capsule-sample:latest-old
    keep2:
      image: my-capsule-sample:latest
stack:
  runnable-list:
    - capsule-sample/web
Y
cat > sub/sub.yaml <<'Y'
api:
  containers:
    c:
      image: api:v2
    d:
      image: api:v20
Y
rewrite_templates_for_branch feat-a > out.txt 2> err.txt
eq "tpl rewritten" "namespace: capsule-sample
web:
  defines: runnable
  containers:
    app:
      image: capsule-sample:latest-feat-a
    other:
      image: \"capsule-sample:latest-feat-a\"
    keep:
      image: capsule-sample:latest-old
    keep2:
      image: my-capsule-sample:latest
stack:
  runnable-list:
    - capsule-sample/web" "$(cat tpl.yaml)"
eq "sub-MANIFEST template rewritten" "api:
  containers:
    c:
      image: api:v2-feat-a
    d:
      image: api:v20" "$(cat sub/sub.yaml)"
eq "warns for an image no template names" "1" "$(grep -c "untouched:1" err.txt)"
eq "no other warning" "1" "$(wc -l < err.txt | tr -d ' ')"

# idempotent for the same suffix: the rewritten tag is not rewritten again
cp tpl.yaml before.yaml
rewrite_templates_for_branch feat-a > /dev/null 2> err2.txt
eq "second run changes nothing" "$(cat before.yaml)" "$(cat tpl.yaml)"
eq "second run is not told the image is shared" "1" "$(grep -c "untouched:1" err2.txt)"
eq "and has no other warning" "1" "$(wc -l < err2.txt | tr -d ' ')"

# a template outside the MANIFEST's loads is left alone
printf 'image: capsule-sample:latest\n' > other.yaml
rewrite_templates_for_branch feat-b > /dev/null 2>&1
eq "unloaded file untouched" "image: capsule-sample:latest" "$(cat other.yaml)"

# ── the tag as its own `image-tag:` key next to `image:`
cd / && rm -rf "$T"
T=$(mktemp -d)
cd "$T" || exit 1
printf 'LOAD tpl.yaml\nIMAGE app:v2 x . Dockerfile\nIMAGE web x . Dockerfile\n' > MANIFEST
cat > tpl.yaml <<'Y'
a:
  containers:
    one:
      image: app
      image-tag: v2
    two:
      image-tag: "v2"
      image: "app"
    three:
      image: app
      image-tag: v3
    four:
      image: app
      image-tag: <- $tag
    five:
      image: web
      image-tag: latest   # the pinned one
    six:
      image: web
    seven:
      image: other
      image-tag: v2
    eight:
      - image: web
        image-tag: latest
      - image: app
        image-tag: v2
Y
rewrite_templates_for_branch feat-a > out.txt 2> err.txt
eq "image + image-tag pairs" "a:
  containers:
    one:
      image: app
      image-tag: v2-feat-a
    two:
      image-tag: \"v2-feat-a\"
      image: \"app\"
    three:
      image: app
      image-tag: v3
    four:
      image: app
      image-tag: <- \$tag
    five:
      image: web
      image-tag: latest-feat-a   # the pinned one
    six:
      image: web:latest-feat-a
    seven:
      image: other
      image-tag: v2
    eight:
      - image: web
        image-tag: latest-feat-a
      - image: app
        image-tag: v2-feat-a" "$(cat tpl.yaml)"
eq "no warning when every image was found" "0" "$(wc -c < err.txt | tr -d ' ')"
cp tpl.yaml before.yaml
rewrite_templates_for_branch feat-a > /dev/null 2>&1
eq "pairs: second run changes nothing" "$(cat before.yaml)" "$(cat tpl.yaml)"

cd / && rm -rf "$T"
[ "$FAILS" -eq 0 ] && echo "all passed" || { echo "$FAILS failed"; exit 1; }
