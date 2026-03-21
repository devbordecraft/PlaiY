#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Check for vcpkg
if [ -z "${VCPKG_ROOT:-}" ]; then
    echo "VCPKG_ROOT is not set."
    echo "Install vcpkg and set VCPKG_ROOT, or run:"
    echo "  git clone https://github.com/microsoft/vcpkg.git ~/vcpkg"
    echo "  ~/vcpkg/bootstrap-vcpkg.sh"
    echo "  export VCPKG_ROOT=~/vcpkg"
    exit 1
fi

echo "Using vcpkg at: $VCPKG_ROOT"

cd "$PROJECT_DIR"
"$VCPKG_ROOT/vcpkg" install --triplet "$(uname -m)-osx"

echo "Dependencies installed successfully."
