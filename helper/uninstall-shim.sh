#!/usr/bin/env bash
# helper/uninstall-shim.sh
#
# Removes the claude-command-runner shell shim block from the user's shell
# rc file(s). Idempotent — safe to run multiple times. Does not modify
# unrelated lines.

set -euo pipefail

readonly MARKER_BEGIN="# >>> claude-command-runner shell shim >>>"
readonly MARKER_END="# <<< claude-command-runner shell shim <<<"

remove_block() {
    local rc_file="$1"
    [[ -f "$rc_file" ]] || return 0
    if ! grep -qF "$MARKER_BEGIN" "$rc_file"; then
        return 0
    fi
    # Use a portable sed approach: print everything except lines between
    # the markers (inclusive). awk is more reliable than sed across BSD/GNU.
    local tmp
    tmp="$(mktemp)"
    awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" '
        $0 == begin { in_block = 1; next }
        $0 == end   { in_block = 0; next }
        !in_block   { print }
    ' "$rc_file" > "$tmp"
    mv "$tmp" "$rc_file"
    echo "uninstall-shim: removed marker block from $rc_file"
}

remove_block "$HOME/.zshrc"
remove_block "$HOME/.bashrc"

echo "uninstall-shim: done. Open a new shell to fully clear."
