#!/usr/bin/env bash
# helper/uninstall-shim.sh
#
# Removes the warp-command-runner shell shim block (and the v6
# claude-command-runner marker, if still present) from the user's shell
# rc file(s). Idempotent — safe to run multiple times.

set -euo pipefail

remove_block() {
    local rc_file="$1" begin="$2" end="$3"
    [[ -f "$rc_file" ]] || return 0
    if ! grep -qF "$begin" "$rc_file"; then
        return 0
    fi
    local tmp
    tmp="$(mktemp)"
    awk -v begin="$begin" -v end="$end" '
        $0 == begin { in_block = 1; next }
        $0 == end   { in_block = 0; next }
        !in_block   { print }
    ' "$rc_file" > "$tmp"
    mv "$tmp" "$rc_file"
    echo "uninstall-shim: removed marker block from $rc_file"
}

for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
    remove_block "$rc" "# >>> warp-command-runner shell shim >>>" "# <<< warp-command-runner shell shim <<<"
    remove_block "$rc" "# >>> claude-command-runner shell shim >>>" "# <<< claude-command-runner shell shim <<<"
done

echo "uninstall-shim: done. Open a new shell to fully clear."
