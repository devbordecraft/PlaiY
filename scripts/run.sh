#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"

echo "Building C++ core..."
cmake -B "$PROJECT_DIR/build/apple-debug" -DCMAKE_BUILD_TYPE=Debug -DCMAKE_PREFIX_PATH="$PREFIX" -S "$PROJECT_DIR"
cmake --build "$PROJECT_DIR/build/apple-debug" --parallel

echo "Building app..."
cd "$PROJECT_DIR/app"
xcodegen generate
xcodebuild -project PlaiY.xcodeproj -scheme PlaiY -configuration Debug build 2>&1 | grep -E '(BUILD|error:)' || true

# Find the built app
APP_PATH=$(xcodebuild -project PlaiY.xcodeproj -scheme PlaiY -configuration Debug -showBuildSettings 2>/dev/null | grep ' BUILT_PRODUCTS_DIR' | awk '{print $3}')
APP="$APP_PATH/PlaiY.app"

if [ -d "$APP" ]; then
    echo "Launching PlaiY..."
    open "$APP"
else
    echo "Build failed — app not found."
    exit 1
fi
