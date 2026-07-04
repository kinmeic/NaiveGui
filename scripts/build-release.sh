#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/NaiveGui.xcodeproj"
SCHEME="NaiveGui"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/build/github-actions}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/build/releases}"
APP_NAME="NaiveGui"
INFO_PLIST="$ROOT_DIR/NaiveGui/Info.plist"

if [[ -n "${RELEASE_VERSION:-}" ]]; then
  VERSION="$RELEASE_VERSION"
else
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$INFO_PLIST")"
fi

APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
DSYM_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app.dSYM"
APP_ARCHIVE="$OUTPUT_DIR/${APP_NAME}-${VERSION}-macOS-universal-unsigned.zip"
DSYM_ARCHIVE="$OUTPUT_DIR/${APP_NAME}-${VERSION}-macOS-universal-dSYM.zip"
CHECKSUM_FILE="$OUTPUT_DIR/SHA256SUMS.txt"

rm -rf "$DERIVED_DATA_PATH" "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

# 构建 universal binary（同时包含 x86_64 和 arm64）。
# 只支持 arm64 的 ARCHS=arm64 会跳过 x86_64；用 ONLY_ACTIVE_ARCH=NO + ARCHS="arm64 x86_64"
# 产出可在 Intel 和 Apple Silicon 上运行的单个 .app。
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  ONLY_ACTIVE_ARCH=NO \
  ARCHS="arm64 x86_64" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "Expected app bundle was not produced at $APP_PATH" >&2
  exit 1
fi

# 验证双架构。
BINARY_PATH="$APP_PATH/Contents/MacOS/$APP_NAME"
echo "Built binary architectures:"
lipo -archs "$BINARY_PATH" || file "$BINARY_PATH"
if lipo -archs "$BINARY_PATH" 2>/dev/null | grep -q "x86_64" && lipo -archs "$BINARY_PATH" 2>/dev/null | grep -q "arm64"; then
  echo "✓ Universal binary (x86_64 + arm64) confirmed"
else
  echo "⚠ Warning: binary may not be universal; check architectures above"
fi

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$APP_ARCHIVE"

if [[ -d "$DSYM_PATH" ]]; then
  ditto -c -k --sequesterRsrc --keepParent "$DSYM_PATH" "$DSYM_ARCHIVE"
fi

(
  cd "$OUTPUT_DIR"
  shasum -a 256 ./*.zip > "$CHECKSUM_FILE"
)

echo "Created release artifacts:"
find "$OUTPUT_DIR" -maxdepth 1 -type f | sort
