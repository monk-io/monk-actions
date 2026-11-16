#!/bin/sh
# Reads $WORKLOAD_SECRETS, shared by the provision, deploy and cleanup scripts. One entry per line,
# in either form:
#   NAME=value                single-line value (workflows generated before multiline support)
#   {"NAME": "value" }        what the generated workflow emits, `{"NAME": ${{ toJSON(secrets.X) }} }`;
#                             the JSON string carries any newlines, so a PEM key or JSON blob survives.
# A line starting with `{` is JSON; nothing else is ever folded or guessed.

# each_workload_secret CALLBACK: calls `CALLBACK NAME VALUE` for each entry, in the current shell
# (a callback can `exit`) and with stdin closed. Malformed lines are skipped with a warning that
# never repeats the line. VALUE may be empty; a seeding callback skips those.
each_workload_secret() {
    _ws_cb="$1"
    [ -n "${WORKLOAD_SECRETS:-}" ] || return 0
    while IFS= read -r _ws_line; do
        _ws_line=${_ws_line%"$(printf '\r')"}   # a value edited on Windows must not carry its line ending
        [ -z "$_ws_line" ] && continue
        case "$_ws_line" in
            "{"*)
                _ws_key=$(printf '%s' "$_ws_line" |
                    jq -r 'if type == "object" and length == 1 and (to_entries[0].value | type) == "string" then keys[0] else empty end' 2>/dev/null) || _ws_key=""
                if [ -z "$_ws_key" ]; then
                    printf "${YELLOW:-}Warning: skipping a workload-secrets line that isn't {\"NAME\": \"value\"}${NC:-}\n"
                    continue
                fi
                # the sentinel keeps $(...) from trimming a value's trailing newlines
                _ws_val=$(printf '%s' "$_ws_line" | jq -j '.[]' 2>/dev/null; printf x)
                _ws_val=${_ws_val%x}
                ;;
            *=*)
                _ws_key=${_ws_line%%=*}
                _ws_val=${_ws_line#*=}
                ;;
            *)
                printf "${YELLOW:-}Warning: skipping a workload-secrets line that isn't NAME=value${NC:-}\n"
                continue
                ;;
        esac
        case "$_ws_key" in
            ""|*[!A-Za-z0-9_-]*)
                printf "${YELLOW:-}Warning: skipping a workload-secrets line with an invalid name${NC:-}\n"
                continue
                ;;
        esac
        "$_ws_cb" "$_ws_key" "$_ws_val" < /dev/null
    done <<EOF_WORKLOAD_SECRETS
$WORKLOAD_SECRETS
EOF_WORKLOAD_SECRETS
}
