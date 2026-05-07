#!/usr/bin/env bash
# helper/install-shim.sh
#
# Idempotent installer for the claude-command-runner shell shim. Adds a
# clearly-marked block to the user's shell rc that sources the appropriate
# shim for the active shell. Re-running is a no-op.
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

readonly MARKER_BEGIN="# >>> claude-command-runner shell shim >>>"
readonly MARKER_END="# <<< claude-command-runner shell shim <<<"

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

# Create rc file if absent.
[[ -f "$rc_file" ]] || touch "$rc_file"

# Idempotent: if marker already present, no-op.
if grep -qF "$MARKER_BEGIN" "$rc_file"; then
    echo "install-shim: marker already present in $rc_file (no-op)"
    exit 0
fi

# Append the marker block.
{
    echo ""
    echo "$MARKER_BEGIN"
    echo "# Auto-installed by claude-command-runner v6.0. To uninstall, run:"
    echo "#   ${HELPER_DIR}/uninstall-shim.sh"
    echo "# Auto-disables outside Warp panes (checks \$WARP_SESSION_ID)."
    echo "[[ -f \"$shim_path\" ]] && source \"$shim_path\""
    echo "$MARKER_END"
} >> "$rc_file"

echo "install-shim: appended marker block to $rc_file"
echo "Open a new ${shell} shell inside a Warp pane to activate."
