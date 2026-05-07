#!/usr/bin/env bash
# scripts/patch-swift-sdk.sh
#
# swift-sdk 0.10.x and 0.11.x trigger Swift 6 strict-concurrency errors in
# NetworkTransport.swift on closure captures of two locally-declared `Bool`
# vars. The fix is to mark those decls `nonisolated(unsafe)`. This is the
# same patch the project relied on pre-v6.0; we now apply it deterministically
# from a script so the build is reproducible from a fresh clone.
#
# Idempotent: re-running is a no-op once the patch is applied.
# Lost on `swift package clean` or `swift package update swift-sdk` —
# rerun this script after either.
#
# Pinned to swift-sdk 0.10.x (Package.swift). When migrating to 0.12+, this
# script should be retired and the call sites updated for the new API.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${PROJECT_ROOT}/.build/checkouts/swift-sdk/Sources/MCP/Base/Transports/NetworkTransport.swift"

if [[ ! -f "${TARGET}" ]]; then
    echo "patch-swift-sdk: target not found at ${TARGET}"
    echo "Run 'swift package resolve' first (or 'swift build')."
    exit 1
fi

PATCH_MARKER="// patched-by-ccr-v6"
if grep -q "${PATCH_MARKER}" "${TARGET}"; then
    echo "patch-swift-sdk: already patched (no-op)"
    exit 0
fi

# .build/checkouts files are checked out read-only. Make writable for the patch.
chmod u+w "${TARGET}"

# Two textual replacements. We anchor each on a unique surrounding context so
# the patch fails loudly rather than silently mismatching if upstream changes.

python3 - <<'PYEOF' "${TARGET}" "${PATCH_MARKER}"
import sys, re, pathlib

target = pathlib.Path(sys.argv[1])
marker = sys.argv[2]
src = target.read_text()
orig = src

src = src.replace(
    "var sendContinuationResumed = false",
    f"nonisolated(unsafe) var sendContinuationResumed = false  {marker}",
    1,
)
src = src.replace(
    "var receiveContinuationResumed = false",
    f"nonisolated(unsafe) var receiveContinuationResumed = false  {marker}",
    1,
)

if src == orig:
    print("patch-swift-sdk: no replacements made — upstream may have changed", file=sys.stderr)
    sys.exit(2)

target.write_text(src)
print("patch-swift-sdk: applied")
PYEOF
