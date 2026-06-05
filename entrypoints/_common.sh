#!/bin/sh
# Shared helpers sourced by per-action entrypoints.

# Parse a multiline KEY=value bag (one assignment per line) and export each as
# an env var in the current shell. Lines must split on the first '=' only, so
# values containing '=' are preserved verbatim.
#
# Usage: export_kv_bag "$CLOUD_CREDENTIALS"
export_kv_bag() {
    bag="$1"
    [ -z "$bag" ] && return 0
    printf '%s\n' "$bag" | while IFS= read -r line; do
        [ -z "$line" ] && continue
        key="${line%%=*}"
        val="${line#*=}"
        [ -z "$key" ] && continue
        # shellcheck disable=SC2163
        export "$key=$val"
    done
}

# When sourced, export_kv_bag runs in a subshell pipeline — exports won't
# escape. Use this variant that reads from a file or here-doc instead.
load_kv_bag() {
    bag="$1"
    [ -z "$bag" ] && return 0
    tmp="$(mktemp)"
    printf '%s\n' "$bag" > "$tmp"
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        key="${line%%=*}"
        val="${line#*=}"
        [ -z "$key" ] && continue
        # shellcheck disable=SC2163
        export "$key=$val"
    done < "$tmp"
    rm -f "$tmp"
}
