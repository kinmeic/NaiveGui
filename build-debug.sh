#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_PATH="$ROOT_DIR/NaiveGui.xcodeproj"
SCHEME="NaiveGui"
CONFIGURATION="${1:-Debug}"
DESTINATION="platform=macOS,arch=arm64,name=My Mac"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  build
