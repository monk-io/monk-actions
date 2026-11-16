#!/bin/sh
# Shared helpers sourced by per-action entrypoints.

_kv_export() {
    while :; do
        case "$_kv_val" in
            *"
") _kv_val="${_kv_val%?}" ;;
            *) break ;;
        esac
    done
    export "$_kv_key=$_kv_val"
}

# Parse a multiline KEY=value bag and export each entry as an env var in the
# current shell. A line starting NAME= (NAME a valid identifier) begins an
# entry and splits on the first '=' only, so values containing '=' are kept
# verbatim. Any other line continues the previous entry's value after a
# newline, so multiline values (a pretty-printed service-account JSON, an
# Azure SDK auth file) survive. Lines before the first entry are ignored.
#
# Trailing blank lines are not part of a value. Runs in the current shell (no
# pipeline), so the exports reach the caller.
# Usage: load_kv_bag "$CLOUD_CREDENTIALS"
load_kv_bag() {
    bag="$1"
    [ -z "$bag" ] && return 0
    tmp="$(mktemp)"
    printf '%s\n' "$bag" > "$tmp"
    _kv_key=""
    _kv_val=""
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            [A-Za-z_]*=*)
                key="${line%%=*}"
                case "$key" in
                    *[!A-Za-z0-9_]*) key="" ;;
                esac
                ;;
            *) key="" ;;
        esac
        if [ -n "$key" ]; then
            [ -n "$_kv_key" ] && _kv_export
            _kv_key="$key"
            _kv_val="${line#*=}"
        elif [ -n "$_kv_key" ]; then
            _kv_val="$_kv_val
$line"
        fi
    done < "$tmp"
    [ -n "$_kv_key" ] && _kv_export
    rm -f "$tmp"
    unset _kv_key _kv_val
}
