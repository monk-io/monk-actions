# Helpers for reading the CLI's --json output. Monk 4 wraps every result in an envelope
# ({"command":..,"data":{..},"ok":true,"type":"result","v":1}) and lists under data.items; Monk 3
# printed the bare array or object. Each helper reads both, so the image works whichever CLI it
# bundles. Source this file; it only defines functions.

# stdin: the output of `monk --json cluster peers`; stdout: the peers as one JSON array.
monk_peers_array() {
    jq -c '
        if type == "array" then .
        elif (.data.items | type) == "array" then .data.items
        elif (.data.peers | type) == "array" then .data.peers
        elif (.peers | type) == "array" then .peers
        else [] end
    '
}

# The peers of the connected cluster as a JSON array. Fails when the CLI does.
monk_peers_json() {
    monk_out=$(monk --json cluster peers) || return 1
    printf '%s' "$monk_out" | monk_peers_array
}

# stdin: the output of `monk --json cluster users list`; stdout: the users as one JSON array.
monk_users_array() {
    jq -c '
        if type == "array" then .
        elif type == "object" and (.data.items | type) == "array" then .data.items
        elif type == "object" and (.users | type) == "array" then .users
        elif type == "object" and (.Users | type) == "array" then .Users
        elif type == "object" and (.data | type) == "array" then .data
        elif type == "object" and (.result | type) == "array" then .result
        else [] end
    '
}

# stdin: the output of `monk --json plugins list`; exit status 0 when the plugin named $1 is
# enabled. Empty or unreadable input is "not enabled".
monk_plugin_enabled() {
    jq -e --arg name "$1" \
        '[(.data.items // .data.plugins // .plugins // [])[] | select(.name == $name and .enabled == true)] | length > 0' \
        >/dev/null 2>&1
}

# stdin: the output of `monk --json secrets get`; stdout: the secret's value. Monk 4 has it in
# data.value, Monk 3 in message.
monk_secret_value() {
    jq -r '.data.value // .message // empty'
}
