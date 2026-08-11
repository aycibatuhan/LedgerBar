#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="${LEDGERBAR_INSTALL_DIR:-/Applications}"
DEST_APP="$INSTALL_DIR/LedgerBar.app"
SOURCE_APP="$ROOT_DIR/.build/Local/LedgerBar.app"
BUNDLE_ID="com.ledgerbar.app"

case "$INSTALL_DIR" in
    /Applications|"$HOME/Applications")
        ;;
    *)
        printf 'Refusing install outside /Applications or %s/Applications: %s\n' "$HOME" "$INSTALL_DIR" >&2
        exit 2
        ;;
esac

mkdir -p "$INSTALL_DIR"
if [[ ! -w "$INSTALL_DIR" ]]; then
    printf 'Install directory is not writable: %s\n' "$INSTALL_DIR" >&2
    printf 'Use LEDGERBAR_INSTALL_DIR="$HOME/Applications" for a user-local install.\n' >&2
    exit 1
fi

# Always rebuild the canonical, menu-bar-only bundle first.
LEDGERBAR_APP_OUTPUT_DIR="$ROOT_DIR/.build/Local" \
    "$ROOT_DIR/Tools/build-local-app.sh"

if [[ ! -d "$SOURCE_APP" ]]; then
    printf 'Built app bundle is missing: %s\n' "$SOURCE_APP" >&2
    exit 1
fi

STAGING_DIR="$(mktemp -d "$INSTALL_DIR/.LedgerBar-install.XXXXXXXX")"
STAGED_APP="$STAGING_DIR/LedgerBar.app"
BACKUP_APP="$INSTALL_DIR/.LedgerBar-previous.$$.app"
replacement_started=0
install_succeeded=0
cleanup() {
    local status=$?
    trap - EXIT
    if [[ "$install_succeeded" == "1" ]]; then
        rm -rf "$BACKUP_APP"
    elif [[ -e "$BACKUP_APP" ]]; then
        rm -rf "$DEST_APP"
        if ! mv "$BACKUP_APP" "$DEST_APP"; then
            printf 'Failed to restore the previous app after an interrupted install: %s\n' "$DEST_APP" >&2
            status=1
        fi
    elif [[ "$replacement_started" == "1" ]]; then
        rm -rf "$DEST_APP"
    fi
    rm -rf "$STAGING_DIR"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

ditto --rsrc --extattr --acl "$SOURCE_APP" "$STAGED_APP"
plutil -replace LSUIElement -bool false "$STAGED_APP/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"

if [[ -e "$DEST_APP" ]]; then
    existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST_APP/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$existing_id" != "$BUNDLE_ID" ]]; then
        printf 'Refusing to replace an app with a different bundle identifier: %s\n' "$DEST_APP" >&2
        exit 2
    fi
fi

# The canonical build remains LSUIElement=true per SPEC.md. This
# installed personal-use copy is deliberately Dock-visible while retaining the
# same native SwiftUI app and menu-bar extra.
if [[ -e "$DEST_APP" ]]; then
    mv "$DEST_APP" "$BACKUP_APP"
fi
replacement_started=1
if ! mv "$STAGED_APP" "$DEST_APP"; then
    exit 1
fi
if ! codesign --verify --deep --strict "$DEST_APP"; then
    exit 1
fi
install_succeeded=1

printf 'INSTALLED_APP=%s\n' "$DEST_APP"
printf 'DOCK_VISIBLE=true (installed copy only)\n'
printf 'CANONICAL_BUILD=%s\n' "$SOURCE_APP"
printf 'SIGNING=ad-hoc (development-signed Keychain gate remains separate)\n'
printf 'NEXT=open %q\n' "$DEST_APP"
