#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

BUILD_TYPE="${1:-debug}"

cd "$PROJECT_DIR"

case "$BUILD_TYPE" in
    debug)
        cmake --preset apple-debug
        cmake --build --preset apple-debug
        ;;
    release)
        cmake --preset apple-release
        cmake --build --preset apple-release
        ;;
    *)
        echo "Usage: $0 [debug|release]"
        exit 1
        ;;
esac

echo "Build complete."
