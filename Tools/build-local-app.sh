#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${LEDGERBAR_APP_OUTPUT_DIR:-$ROOT_DIR/.build/Local}"
CONFIGURATION="${LEDGERBAR_BUILD_CONFIGURATION:-release}"
APP_PATH="$OUTPUT_DIR/LedgerBar.app"

case "$OUTPUT_DIR" in
    ""|"/"|"$ROOT_DIR"|"$HOME")
        printf 'Refusing unsafe app output directory: %s\n' "$OUTPUT_DIR" >&2
        exit 2
        ;;
esac

cd "$ROOT_DIR"

mkdir -p "$OUTPUT_DIR"
STAGING_DIR="$(mktemp -d "$OUTPUT_DIR/.LedgerBar-build.XXXXXXXX")"
STAGED_APP="$STAGING_DIR/LedgerBar.app"
BACKUP_APP="$OUTPUT_DIR/.LedgerBar-previous.$$.app"
cleanup() {
    rm -rf "$STAGING_DIR" "$BACKUP_APP"
}
trap cleanup EXIT

swift build --configuration "$CONFIGURATION" --product LedgerBar
BIN_DIR="$(swift build --configuration "$CONFIGURATION" --show-bin-path)"
BINARY_PATH="$BIN_DIR/LedgerBar"

if [[ ! -x "$BINARY_PATH" ]]; then
    printf 'LedgerBar executable was not produced: %s\n' "$BINARY_PATH" >&2
    exit 1
fi

mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BINARY_PATH" "$STAGED_APP/Contents/MacOS/LedgerBar"
cp "$ROOT_DIR/LedgerBar/App/Info.plist" "$STAGED_APP/Contents/Info.plist"

# SwiftPM copies the source plist without Xcode's build-setting expansion.
# Materialize the values required by the standalone local bundle explicitly;
# the generated Xcode project continues to use PRODUCT_* settings normally.
/usr/libexec/PlistBuddy -c 'Set :CFBundleDevelopmentRegion en' "$STAGED_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable LedgerBar' "$STAGED_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.ledgerbar.app' "$STAGED_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName LedgerBar' "$STAGED_APP/Contents/Info.plist"

# App icon: assemble AppIcon.icns from the same PNGs the Xcode asset catalog
# uses (Tools/render-app-icon.swift regenerates them from Design/AppIcon.svg).
ICONSET_DIR="$STAGING_DIR/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"
cp "$ROOT_DIR"/LedgerBar/Resources/Assets.xcassets/AppIcon.appiconset/icon_*.png "$ICONSET_DIR/"
iconutil --convert icns --output "$STAGED_APP/Contents/Resources/AppIcon.icns" "$ICONSET_DIR"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$STAGED_APP/Contents/Info.plist"

if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$STAGED_APP/Contents/Info.plist")" != "com.ledgerbar.app" ]]; then
    printf 'Local bundle has an invalid CFBundleIdentifier\n' >&2
    exit 1
fi

# This is intentionally ad-hoc signing for local manual use. It does not claim
# the development-signed Keychain/access-group gate from SPEC.md.
codesign --force --sign - --timestamp=none "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"

if [[ -e "$APP_PATH" ]]; then
    mv "$APP_PATH" "$BACKUP_APP"
fi
if ! mv "$STAGED_APP" "$APP_PATH"; then
    if [[ -e "$BACKUP_APP" ]]; then mv "$BACKUP_APP" "$APP_PATH"; fi
    exit 1
fi
if ! codesign --verify --deep --strict "$APP_PATH"; then
    rm -rf "$APP_PATH"
    if [[ -e "$BACKUP_APP" ]]; then mv "$BACKUP_APP" "$APP_PATH"; fi
    exit 1
fi

printf 'LOCAL_APP=%s\n' "$APP_PATH"
printf 'SIGNING=ad-hoc (development-signed Keychain gate remains separate)\n'
printf 'DATABASE=Application Support/LedgerBar/ledgerbar.sqlite (override with LEDGERBAR_DB_PATH when launching)\n'
