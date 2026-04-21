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
APP_ARCHIVE="$OUTPUT_DIR/${APP_NAME}-${VERSION}-macOS-unsigned.zip"
DSYM_ARCHIVE="$OUTPUT_DIR/${APP_NAME}-${VERSION}-macOS-dSYM.zip"
CHECKSUM_FILE="$OUTPUT_DIR/SHA256SUMS.txt"

rm -rf "$DERIVED_DATA_PATH" "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "Expected app bundle was not produced at $APP_PATH" >&2
  exit 1
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
