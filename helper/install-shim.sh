#!/usr/bin/env bash
# helper/install-shim.sh
#
# Idempotent installer for the warp-command-runner shell shim. Adds a
# clearly-marked block to the user's shell rc that sources the appropriate
# shim for the active shell. Re-running is a no-op. If a v6
# claude-command-runner marker is present, it is replaced.
#
# Usage:
#   helper/install-shim.sh           # auto-detect shell
#   helper/install-shim.sh zsh       # force zsh
#   helper/install-shim.sh bash      # force bash
#
# To uninstall: helper/uninstall-shim.sh

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HELPER_DIR="${PROJECT_ROOT}/helper"

readonly MARKER_BEGIN="# >>> warp-command-runner shell shim >>>"
readonly MARKER_END="# <<< warp-command-runner shell shim <<<"
readonly LEGACY_BEGIN="# >>> claude-command-runner shell shim >>>"
readonly LEGACY_END="# <<< claude-command-runner shell shim <<<"

strip_block() {
    local rc="$1" begin="$2" end="$3"
    [[ -f "$rc" ]] || return 0
    grep -qF "$begin" "$rc" || return 0
    local tmp
    tmp="$(mktemp)"
    awk -v begin="$begin" -v end="$end" '
        $0 == begin { in_block = 1; next }
        $0 == end   { in_block = 0; next }
        !in_block   { print }
    ' "$rc" > "$tmp"
    mv "$tmp" "$rc"
}

detect_shell() {
    if [[ -n "${1:-}" ]]; then
        echo "$1"
        return
    fi
    case "${SHELL:-}" in
        */zsh) echo "zsh" ;;
        */bash) echo "bash" ;;
        *) echo "" ;;
    esac
}

target_rc() {
    case "$1" in
        zsh) echo "$HOME/.zshrc" ;;
        bash) echo "$HOME/.bashrc" ;;
        *) echo "" ;;
    esac
}

shell="$(detect_shell "${1:-}")"
if [[ -z "$shell" || ( "$shell" != "zsh" && "$shell" != "bash" ) ]]; then
    echo "install-shim: could not detect shell. Pass 'zsh' or 'bash' explicitly." >&2
    exit 1
fi

rc_file="$(target_rc "$shell")"
shim_path="${HELPER_DIR}/shell-shim.${shell}"

if [[ ! -f "$shim_path" ]]; then
    echo "install-shim: shim not found at $shim_path" >&2
    exit 1
fi

[[ -f "$rc_file" ]] || touch "$rc_file"

# Drop the v6 marker if present so we install the renamed block once.
strip_block "$rc_file" "$LEGACY_BEGIN" "$LEGACY_END"

if grep -qF "$MARKER_BEGIN" "$rc_file"; then
    echo "install-shim: marker already present in $rc_file (no-op)"
    exit 0
fi

{
    echo ""
    echo "$MARKER_BEGIN"
    echo "# Auto-installed by warp-command-runner. To uninstall, run:"
    echo "#   ${HELPER_DIR}/uninstall-shim.sh"
    echo "# Auto-disables outside Warp panes (checks \$WARP_SESSION_ID)."
    echo "[[ -f \"$shim_path\" ]] && source \"$shim_path\""
    echo "$MARKER_END"
} >> "$rc_file"

echo "install-shim: appended marker block to $rc_file"
echo "Open a new ${shell} shell inside a Warp pane to activate."
