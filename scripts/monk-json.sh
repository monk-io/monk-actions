# Helpers for reading the CLI's --json output. Monk 4 wraps every result in an envelope
# ({"command":..,"data":{..},"ok":true,"type":"result","v":1}) and lists under data.items; Monk 3
# printed the bare array or object. Each helper reads both, so the image works whichever CLI it
# bundles. Source this file; it only defines functions.
#
# A helper fails (non-zero, nothing on stdout) on input it can't read: not JSON, or a Monk 4 error
# envelope ({"ok":false,...}). Callers must check the status; an empty list is only ever a real one.

# stdin: the output of `monk --json cluster peers`; stdout: the peers as one JSON array.
monk_peers_array() {
    jq -c '
        if type == "array" then .
        elif type != "object" then error("not an object")
        elif .ok == false then error("the CLI reported an error")
        elif (.data.items | type) == "array" then .data.items
        elif (.data.peers | type) == "array" then .data.peers
        elif (.peers | type) == "array" then .peers
        elif (.data | type) == "object" or (.data | type) == "null" then []
        else error("unrecognized peers output") end
    '
}

# The peers of the connected cluster as a JSON array. Fails when the CLI or the output does.
monk_peers_json() {
    local out
    out=$(monk --json cluster peers) || return 1
    printf '%s' "$out" | monk_peers_array
}

# stdin: the output of `monk --json cluster users list`; stdout: the users as one JSON array.
monk_users_array() {
    jq -c '
        if type == "array" then .
        elif type != "object" then error("not an object")
        elif .ok == false then error("the CLI reported an error")
        elif (.data.items | type) == "array" then .data.items
        elif (.users | type) == "array" then .users
        elif (.Users | type) == "array" then .Users
        elif (.data | type) == "array" then .data
        elif (.result | type) == "array" then .result
        else [] end
    '
}

# stdin: the output of `monk --json plugins list`; exit status 0 when the plugin named $1 is
# enabled. Empty, unreadable or error output is "not enabled".
monk_plugin_enabled() {
    jq -e --arg name "$1" '
        (if type == "array" then .
         elif .ok == false then []
         else (.data.items // .data.plugins // .plugins // []) end)
        | [.[] | select(.name == $name and .enabled == true)] | length > 0
    ' >/dev/null 2>&1
}

# stdin: the output of `monk --json secrets get`; stdout: the secret's value (a string; anything
# else is printed as JSON). Monk 4 has it in data.value, Monk 3 in message. Fails on an error
# envelope or output that isn't JSON; a secret without a value prints nothing.
monk_secret_value() {
    jq -r '
        if type != "object" then error("not an object")
        elif .ok == false then error("the CLI reported an error")
        else (.data.value // .message // empty) | if type == "string" then . else tojson end end
    '
}
