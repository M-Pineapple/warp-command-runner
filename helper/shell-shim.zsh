#!/usr/bin/env zsh
# warp-command-runner — Tier E shell shim for zsh
#
# When sourced from ~/.zshrc, adds two hooks that emit JSON events to a
# Unix domain socket the MCP server listens on. This gives WCR clean
# block-boundary visibility (preexec / command_finished) without polling
# /tmp/wcr_output_<id>.json files.
#
# Auto-disables if not running inside a Warp pane (checks $WARP_SESSION_ID).
# Auto-disables if the socket isn't reachable — never blocks the prompt.
#
# Wire format: one JSON object per line, matching ShimSocket.swift's parser.

# Per-user socket so multiple users on the same machine don't collide.
typeset -g _wcr_shim_sock="/tmp/wcr-shell-shim-${UID}.sock"
typeset -g _wcr_shim_last_cmd=""
typeset -g _wcr_shim_preexec_ts=""

_wcr_shim_send() {
    # Skip silently if not inside Warp.
    [[ -z "$WARP_SESSION_ID" ]] && return 0
    # Skip silently if the socket is missing (MCP not listening).
    [[ ! -S "$_wcr_shim_sock" ]] && return 0

    # Use python3 for reliable line-delimited JSON write to the socket.
    # nc(1) varies wildly across BSDs; python is everywhere on macOS.
    python3 - "$_wcr_shim_sock" "$1" 2>/dev/null <<'PYEOF' &!
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
}

# Reasonable JSON-string escaping for the small set of characters that
# matter: backslash, double-quote, newline, tab.
_wcr_shim_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    print -r -- "$s"
}

_wcr_shim_preexec() {
    _wcr_shim_last_cmd="$1"
    _wcr_shim_preexec_ts="$(date +%s.%N 2>/dev/null || date +%s)"
    local cmd_escaped
    cmd_escaped="$(_wcr_shim_json_escape "$1")"
    local sid_escaped
    sid_escaped="$(_wcr_shim_json_escape "${WARP_SESSION_ID:-}")"
    _wcr_shim_send "{\"type\":\"preexec\",\"command\":\"$cmd_escaped\",\"warp_session_id\":\"$sid_escaped\",\"ts\":\"$_wcr_shim_preexec_ts\"}"
}

_wcr_shim_precmd() {
    local exit_code=$?
    [[ -z "$_wcr_shim_last_cmd" ]] && return 0
    local now
    now="$(date +%s.%N 2>/dev/null || date +%s)"
    local cmd_escaped
    cmd_escaped="$(_wcr_shim_json_escape "$_wcr_shim_last_cmd")"
    local sid_escaped
    sid_escaped="$(_wcr_shim_json_escape "${WARP_SESSION_ID:-}")"
    _wcr_shim_send "{\"type\":\"command_finished\",\"command\":\"$cmd_escaped\",\"exit_code\":$exit_code,\"warp_session_id\":\"$sid_escaped\",\"started_at\":\"$_wcr_shim_preexec_ts\",\"ts\":\"$now\"}"
    _wcr_shim_last_cmd=""
    _wcr_shim_preexec_ts=""
}

# Register hooks alongside whatever else (Warp, oh-my-zsh, etc.) already
# registered. zsh's add-zsh-hook is the safe way to do this.
autoload -Uz add-zsh-hook 2>/dev/null
if (( $+functions[add-zsh-hook] )); then
    add-zsh-hook preexec _wcr_shim_preexec
    add-zsh-hook precmd _wcr_shim_precmd
fi
