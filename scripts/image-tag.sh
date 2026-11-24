#!/bin/sh
# Where build-images.sh pushes each MANIFEST image, and pointing the templates dynenv-deploy.sh loads
# at it. Both source this and must agree: one pushes <registry>/<tag>[-<suffix>] (a per-branch tag
# on a shared registry), the other points the loaded templates at that. monkd 4.0.2 and later pull
# a short image name from Docker Hub, never from the registries the cluster is logged in to, so a
# template must name the registry too.

# The template files a MANIFEST loads: its LOAD files, and those of the sub-MANIFESTs named by
# DIR/DIRS, each relative to the MANIFEST that names it. A missing sub-MANIFEST adds nothing.
# $2 is the nesting depth, which stops a DIRS loop.
manifest_templates() {
    [ -f "$1/MANIFEST" ] || return 0
    sed 's/#.*//' "$1/MANIFEST" | awk 'toupper($1) == "LOAD" { for (i = 2; i <= NF; i++) print $i }' |
        while read -r file; do printf '%s/%s\n' "$1" "$file"; done
    [ "${2:-0}" -lt 8 ] || return 0
    sed 's/#.*//' "$1/MANIFEST" |
        awk 'toupper($1) == "DIR" || toupper($1) == "DIRS" { for (i = 2; i <= NF; i++) print $i }' |
        while read -r sub; do manifest_templates "$1/$sub" $((${2:-0} + 1)); done
}

# $1 is a MANIFEST image as written. Prints its name, without the tag.
image_name() {
    case "$1" in
        *:*) case "${1##*:}" in */*) printf '%s' "$1" ;; *) printf '%s' "${1%:*}" ;; esac ;;
        *) printf '%s' "$1" ;;
    esac
}

# $1 is a MANIFEST image as written. Prints its tag, `latest` when it has none.
image_tag_of() {
    case "$1" in
        *:*) case "${1##*:}" in */*) printf 'latest' ;; *) printf '%s' "${1##*:}" ;; esac ;;
        *) printf 'latest' ;;
    esac
}

# Prints <name>:<tag>-<suffix> for MANIFEST image $1 and suffix $2. Fails for a digest, a suffix
# a tag can't hold, or a result over 128 characters.
branch_image_tag() {
    local name tag
    case "$2" in
        ""|*[!A-Za-z0-9_.-]*) return 1 ;;
    esac
    case "$1" in
        *@*) return 1 ;;
    esac
    name=$(image_name "$1")
    tag="$(image_tag_of "$1")-$2"
    [ "${#tag}" -le 128 ] || return 1
    printf '%s:%s' "$name" "$tag"
}

# Prints the ref MANIFEST image $1 is pushed as: [$3/]<name>:<tag>[-$2], for registry $3 and
# suffix $2, either of which may be empty. Fails for a digest, a suffix a tag can't hold, or a tag
# over 128 characters.
pushed_image_ref() {
    local name tag
    case "$1" in
        *@*) return 1 ;;
    esac
    name=$(image_name "$1")
    tag=$(image_tag_of "$1")
    if [ -n "$2" ]; then
        case "$2" in
            *[!A-Za-z0-9_.-]*) return 1 ;;
        esac
        tag="$tag-$2"
    fi
    [ "${#tag}" -le 128 ] || return 1
    printf '%s%s:%s' "${3:+$3/}" "$name" "$tag"
}

# Points template file $3 at where MANIFEST image $1 is pushed: suffix $2 on its tag, and registry
# $4 before its name (either may be empty). Prints 1 when the file names it there, else 0.
rewrite_image_in_file() {
    local new newname newtag name tag esc_name esc_tag esc_new before tmp
    new=$(pushed_image_ref "$1" "$2" "${4:-}") || return 1
    name=$(image_name "$1")
    tag=$(image_tag_of "$1")
    newname="${4:+$4/}$name"
    newtag="$tag${2:+-$2}"
    # Escape what is special in an extended regular expression, and the delimiter.
    esc_name=$(printf '%s' "$name" | sed 's/[][\.*^$|/+?(){}]/\\&/g')
    esc_tag=$(printf '%s' "$tag" | sed 's/[][\.*^$|/+?(){}]/\\&/g')
    esc_new=$(printf '%s' "$new" | sed 's/[&/\]/\\&/g')
    before=$(cksum < "$3")
    # name:tag as a whole word: not part of a longer name or tag, nor already after a registry.
    # Twice, because two matches separated by one character share it.
    tmp=$(mktemp)
    if [ "$new" != "$name:$tag" ]; then
        for _ in 1 2; do
            sed -E "s/(^|[^A-Za-z0-9_.\/:-])${esc_name}:${esc_tag}(\$|[^A-Za-z0-9_.-])/\1${esc_new}\2/g" "$3" > "$tmp"
            cat "$tmp" > "$3"
        done
    fi
    # `image: name` on its own line, with or without a sibling `image-tag:` (see the awk).
    awk -v name="$name" -v tag="$tag" -v newtag="$newtag" -v newname="$newname" -v new="$new" '
        function unq(v) { sub(/[ \t]+#.*$/, "", v); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v); gsub(/^["'"'"']|["'"'"']$/, "", v); return v }
        function indent(s) { match(s, /^ */); return RLENGTH }
        # the `image-tag:` line next to line i: same key column, in the same block. 0 when none.
        function sibling(i, col,    j, s, ind) {
            # the first key of a list item has its siblings after it, never before: above it is the previous item
            for (j = i - 1; j >= 1 && line[i] !~ /^ *- /; j--) {
                s = line[j]; if (s ~ /^[ \t]*(#|$)/) continue
                # `- image-tag: x` opening the item: its key sits at the column of the keys after the dash
                if (s ~ /^ *- +image-tag:/ && index(s, "image-tag:") - 1 == col) return j
                ind = indent(s); if (ind < col) break
                if (ind == col && s ~ /^ *image-tag:/) return j
            }
            for (j = i + 1; j <= n; j++) {
                s = line[j]; if (s ~ /^[ \t]*(#|$)/) continue
                ind = indent(s); if (ind < col) break
                if (ind == col && s ~ /^ *image-tag:/) return j
            }
            return 0
        }
        function setval(s, key, old, repl,    p, head, rest, q) {
            p = index(s, key) + length(key); head = substr(s, 1, p - 1); rest = substr(s, p)
            q = index(rest, old); return head substr(rest, 1, q - 1) repl substr(rest, q + length(old))
        }
        { line[NR] = $0; n = NR }
        END {
            for (i = 1; i <= n; i++) {
                s = line[i]
                if (s !~ /^ *(- +)?image:/) continue
                col = index(s, "image:") - 1
                v = s; sub(/^ *(- +)?image:[ \t]*/, "", v)
                if (unq(v) != name) continue
                k = sibling(i, col)
                if (k > 0) {
                    # an image and its tag apart: each changes, if the tag is the one built
                    tv = line[k]; sub(/^ *(- +)?image-tag:[ \t]*/, "", tv)
                    if (unq(tv) == tag) {
                        if (newtag != tag) line[k] = setval(line[k], "image-tag:", tag, newtag)
                        if (newname != name) line[i] = setval(s, "image:", name, newname)
                    }
                } else if (tag == "latest") {
                    # no tag at all is latest; the name alone also appears as a namespace or a path,
                    # so only an `image:` line counts
                    line[i] = setval(s, "image:", name, new)
                }
            }
            for (i = 1; i <= n; i++) print line[i]
        }' "$3" > "$tmp"
    cat "$tmp" > "$3"
    rm -f "$tmp"
    # A file that already names the pushed image (a rerun in the same checkout) counts as found.
    if [ "$before" != "$(cksum < "$3")" ] || grep -qF "$new" "$3" ||
        { [ -n "${4:-}" ] && grep -qF "$newname" "$3"; }; then echo 1; else echo 0; fi
}

# Points the templates the MANIFEST loads at where every image it builds is pushed: registry $1 and
# branch tag suffix $2, either of which may be empty. Warns for an image that isn't written out as
# `image: ...` in any loaded template (it may come from a variable).
rewrite_templates_for_registry() {
    local registry suffix images templates image changed file n
    registry="$1"
    suffix="$2"
    [ -n "$registry$suffix" ] || return 0
    [ -f MANIFEST ] || return 0
    images=$(sh "${PARSE_MANIFEST:-/opt/monk-actions/scripts/parse-manifest.sh}" get-images)
    [ -n "$images" ] || return 0
    templates=$(manifest_templates . | while read -r file; do if [ -f "$file" ]; then echo "$file"; fi; done)
    for image in $images; do
        if ! pushed_image_ref "$image" "$suffix" "$registry" > /dev/null; then
            if [ -n "$suffix" ]; then
                echo "Warning: image '$image' can't get a branch tag (digest, or a tag longer than 128 characters); it is shared by every branch." >&2
            else
                echo "Warning: image '$image' is a digest; the templates name it as written." >&2
            fi
            continue
        fi
        changed=0
        for file in $templates; do
            n=$(rewrite_image_in_file "$image" "$suffix" "$file" "$registry")
            changed=$((changed + n))
        done
        if [ "$changed" -eq 0 ]; then
            if [ -n "$suffix" ]; then
                echo "Warning: image '$image' (a MANIFEST IMAGE line) isn't written out as 'image: ...' in any template the MANIFEST loads (it may come from a variable), so it can't get a branch tag and stays shared between branches: a node that already has it runs the image another branch pushed." >&2
            else
                echo "Warning: image '$image' (a MANIFEST IMAGE line) isn't written out as 'image: ...' in any template the MANIFEST loads (it may come from a variable), so it isn't pointed at $registry: on monkd 4.0.2 and later a short image name is pulled from Docker Hub." >&2
            fi
        else
            echo "Image '$image' -> '$(pushed_image_ref "$image" "$suffix" "$registry")' in $changed template file(s)"
        fi
    done
}

# Points the templates the MANIFEST loads at the branch tag ($1) of every image it builds, on no
# registry. See rewrite_templates_for_registry.
rewrite_templates_for_branch() {
    rewrite_templates_for_registry "" "$1"
}
