#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
NPROCS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

BUILD_TYPE="${1:-Debug}"

case "$BUILD_TYPE" in
    debug|Debug)     BUILD_TYPE=Debug   ; BUILD_DIR=build/apple-debug   ;;
    release|Release) BUILD_TYPE=Release ; BUILD_DIR=build/apple-release ;;
    *)
        echo "Usage: $0 [debug|release]"
        exit 1
        ;;
esac

PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"

cd "$PROJECT_DIR"
cmake -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE="$BUILD_TYPE" -DCMAKE_PREFIX_PATH="$PREFIX" -S .
cmake --build "$BUILD_DIR" --parallel "$NPROCS"

echo "Build complete."
