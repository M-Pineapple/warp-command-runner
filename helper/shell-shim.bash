#!/usr/bin/env bash
# warp-command-runner — Tier E shell shim for bash
#
# Bash equivalent of helper/shell-shim.zsh. Uses DEBUG trap (preexec
# equivalent) and PROMPT_COMMAND (precmd equivalent). See the zsh shim
# for protocol notes.

_wcr_shim_sock="/tmp/wcr-shell-shim-${UID}.sock"
_wcr_shim_last_cmd=""
_wcr_shim_preexec_ts=""
_wcr_shim_in_command=0

_wcr_shim_send() {
    [[ -z "$WARP_SESSION_ID" ]] && return 0
    [[ ! -S "$_wcr_shim_sock" ]] && return 0
    python3 - "$_wcr_shim_sock" "$1" 2>/dev/null <<'PYEOF' &
import socket, sys
sock_path, line = sys.argv[1], sys.argv[2]
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(0.5)
    s.connect(sock_path)
    s.sendall((line + "\n").encode("utf-8"))
    s.close()
except Exception:
    pass
PYEOF
    disown $! 2>/dev/null || true
}

_wcr_shim_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

_wcr_shim_preexec() {
    # The DEBUG trap fires for many things including PROMPT_COMMAND
    # internals. Gate so we only emit for the user's interactive command.
    [[ -n "$COMP_LINE" ]] && return 0
    [[ "$BASH_COMMAND" == "$PROMPT_COMMAND"* ]] && return 0
    [[ "$_wcr_shim_in_command" -eq 1 ]] && return 0

    _wcr_shim_in_command=1
    _wcr_shim_last_cmd="$BASH_COMMAND"
    _wcr_shim_preexec_ts="$(date +%s.%N 2>/dev/null || date +%s)"
    local cmd_escaped
    cmd_escaped="$(_wcr_shim_json_escape "$BASH_COMMAND")"
    local sid_escaped
    sid_escaped="$(_wcr_shim_json_escape "${WARP_SESSION_ID:-}")"
    _wcr_shim_send "{\"type\":\"preexec\",\"command\":\"$cmd_escaped\",\"warp_session_id\":\"$sid_escaped\",\"ts\":\"$_wcr_shim_preexec_ts\"}"
}

_wcr_shim_precmd() {
    local exit_code=$?
    if [[ -n "$_wcr_shim_last_cmd" && "$_wcr_shim_in_command" -eq 1 ]]; then
        local now
        now="$(date +%s.%N 2>/dev/null || date +%s)"
        local cmd_escaped
        cmd_escaped="$(_wcr_shim_json_escape "$_wcr_shim_last_cmd")"
        local sid_escaped
        sid_escaped="$(_wcr_shim_json_escape "${WARP_SESSION_ID:-}")"
        _wcr_shim_send "{\"type\":\"command_finished\",\"command\":\"$cmd_escaped\",\"exit_code\":$exit_code,\"warp_session_id\":\"$sid_escaped\",\"started_at\":\"$_wcr_shim_preexec_ts\",\"ts\":\"$now\"}"
        _wcr_shim_last_cmd=""
        _wcr_shim_preexec_ts=""
        _wcr_shim_in_command=0
    fi
}

trap '_wcr_shim_preexec' DEBUG
PROMPT_COMMAND="_wcr_shim_precmd; ${PROMPT_COMMAND:-}"
