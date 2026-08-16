#!/usr/bin/env bash
#
# build_golden_image.sh (Shim)
#
# Thin wrapper that invokes the Python/uv dynamic golden image builder.
# Preserved for backward-compatibility with scripts or muscle memory.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec uv run "${REPO_ROOT}/provisioning/image/build_golden_image.py" "$@"
