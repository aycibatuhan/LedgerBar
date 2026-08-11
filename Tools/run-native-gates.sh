#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  printf 'native-gates: BLOCKED: %s\n' "$1" >&2
  exit 2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is required; install the full Xcode/XcodeGen toolchain before running this gate"
}

printf '%s\n' 'native-gates: LedgerBar native verification'

require_command swift
require_command xcodebuild
require_command xcodegen
require_command security

if ! xcode_version="$(xcodebuild -version 2>&1)"; then
  printf '%s\n' "$xcode_version" >&2
  fail "full Xcode is required; the selected developer directory is Command Line Tools or otherwise cannot run xcodebuild"
fi
printf '%s\n' "$xcode_version"

expected_xcodegen="$(tr -d '[:space:]' < Tools/xcodegen-version.txt)"
actual_xcodegen="$(xcodegen --version | awk '/Version:/ { print $2; exit }')"
[[ "$actual_xcodegen" == "$expected_xcodegen" ]] || fail "xcodegen $expected_xcodegen is required; found $actual_xcodegen"

team_id="${LEDGERBAR_DEVELOPMENT_TEAM:-}"
[[ "$team_id" =~ ^[A-Z0-9]{10}$ ]] || fail "set LEDGERBAR_DEVELOPMENT_TEAM to the owner's 10-character Apple Development team identifier"

if ! security find-identity -v -p codesigning 2>/dev/null \
    | grep -F 'Apple Development' >/dev/null; then
  fail "no Apple Development signing identity is available in the selected keychain"
fi

printf '%s\n' 'native-gates: running Swift package correctness gate'
swift test --package-path .

printf '%s\n' 'native-gates: generating LedgerBar.xcodeproj with pinned XcodeGen'
xcodegen generate

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
DERIVED_ROOT="$ROOT_DIR/.build/NativeGates/$RUN_ID"
RESULT_ROOT="$DERIVED_ROOT/Results"
mkdir -p "$DERIVED_ROOT" "$RESULT_ROOT"

printf '%s\n' 'native-gates: unsigned compile gate'
xcodebuild \
  -project LedgerBar.xcodeproj \
  -scheme LedgerBar \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_ROOT/Unsigned" \
  CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath "$RESULT_ROOT/Unsigned.xcresult" \
  build

printf '%s\n' 'native-gates: ad-hoc signing/build diagnostic (not a Keychain gate)'
xcodebuild \
  -project LedgerBar.xcodeproj \
  -scheme LedgerBar \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_ROOT/AdHoc" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  PROVISIONING_PROFILE_SPECIFIER= \
  CODE_SIGN_ENTITLEMENTS= \
  ENABLE_APP_SANDBOX=NO \
  ENABLE_HARDENED_RUNTIME=NO \
  CODE_SIGNING_ALLOWED=YES \
  -resultBundlePath "$RESULT_ROOT/AdHoc.xcresult" \
  build

printf '%s\n' 'native-gates: development-signed host/UI/Keychain gate'
profile_specifier="${LEDGERBAR_PROVISIONING_PROFILE_SPECIFIER:-}"
[[ -n "$profile_specifier" ]] || \
  fail 'set LEDGERBAR_PROVISIONING_PROFILE_SPECIFIER to the owner selected Mac Development profile UUID/name; automatic signing must resolve the profile that supplies AppIdentifierPrefix'
LEDGERBAR_DEVELOPMENT_TEAM="$team_id" \
LEDGERBAR_PROVISIONING_PROFILE_SPECIFIER="$profile_specifier" \
xcodebuild \
  -project LedgerBar.xcodeproj \
  -scheme LedgerBar \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_ROOT/DevSigned" \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="$team_id" \
  PROVISIONING_PROFILE_SPECIFIER="$profile_specifier" \
  -allowProvisioningUpdates \
  -resultBundlePath "$RESULT_ROOT/DevSigned.xcresult" \
  test

SIGNED_APP="$DERIVED_ROOT/DevSigned/Build/Products/Debug/LedgerBar.app"
ENTITLEMENTS_REPORT="$RESULT_ROOT/development-signed-entitlements.txt"
if ! codesign -d --entitlements :- "$SIGNED_APP" > "$ENTITLEMENTS_REPORT" 2>/dev/null; then
  chmod 600 "$ENTITLEMENTS_REPORT" || true
  fail "codesign could not dump development-signed entitlements for $SIGNED_APP"
fi
chmod 600 "$ENTITLEMENTS_REPORT"
require_true_entitlement() {
  local key="$1"
  local value
  value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$ENTITLEMENTS_REPORT" 2>/dev/null || true)"
  [[ "$value" == "true" ]] || fail "development-signed app entitlement $key must be true; found '$value'"
}
require_true_entitlement 'com.apple.security.app-sandbox'
require_true_entitlement 'com.apple.security.network.client'
require_true_entitlement 'com.apple.security.files.user-selected.read-write'
keychain_group="$(/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:0' "$ENTITLEMENTS_REPORT" 2>/dev/null || true)"
[[ "$keychain_group" == "$team_id.com.ledgerbar.app" ]] || \
  fail "development-signed app must contain exactly the designated $team_id.com.ledgerbar.app keychain access group"
if /usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:1' "$ENTITLEMENTS_REPORT" >/dev/null 2>&1; then
  fail 'development-signed app must not contain additional keychain access groups'
fi

grep -Eq '<string>[A-Z0-9]{10}\.com\.ledgerbar\.app</string>' "$ENTITLEMENTS_REPORT" || \
  fail 'development-signed app did not resolve its designated TEAMID.com.ledgerbar.app access group'

EMBEDDED_PROFILE="$SIGNED_APP/Contents/embedded.provisionprofile"
PROFILE_PLIST="$RESULT_ROOT/embedded-provisioning-profile.plist"
[[ -f "$EMBEDDED_PROFILE" ]] || \
  fail 'development-signed app does not contain an embedded provisioning profile'
if ! security cms -D -i "$EMBEDDED_PROFILE" -o "$PROFILE_PLIST"; then
  chmod 600 "$PROFILE_PLIST" || true
  fail 'could not decode the development-signed embedded provisioning profile'
fi
chmod 600 "$PROFILE_PLIST"
embedded_profile_name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$PROFILE_PLIST" 2>/dev/null || true)"
embedded_profile_uuid="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$PROFILE_PLIST" 2>/dev/null || true)"
embedded_profile_team="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$PROFILE_PLIST" 2>/dev/null || true)"
[[ "$embedded_profile_team" == "$team_id" ]] || \
  fail 'development-signed embedded provisioning profile has the wrong Team ID'
[[ "$profile_specifier" == "$embedded_profile_name" || "$profile_specifier" == "$embedded_profile_uuid" ]] || \
  fail 'development-signed embedded provisioning profile does not match LEDGERBAR_PROVISIONING_PROFILE_SPECIFIER'

LIVE_FIXTURE="${LEDGERBAR_LIVE_FIXTURE_OUTPUT:-$ROOT_DIR/simplefin-shape-fixture.json}"
LIVE_DAYS="${LEDGERBAR_CAPTURE_DAYS:-7}"
MANIFEST="$RESULT_ROOT/manifest.txt"
write_manifest() {
  local live_fixture="$1"
  {
    printf 'xcodegen=%s\n' "$actual_xcodegen"
    printf 'team_id_configured=yes\n'
    printf 'provisioning_profile_configured=yes\n'
    printf 'derived_root=%s\n' "$DERIVED_ROOT"
    printf 'unsigned_result=%s\n' "$RESULT_ROOT/Unsigned.xcresult"
    printf 'adhoc_result=%s\n' "$RESULT_ROOT/AdHoc.xcresult"
    printf 'development_signed_result=%s\n' "$RESULT_ROOT/DevSigned.xcresult"
    printf 'development_signed_entitlements=%s\n' "$ENTITLEMENTS_REPORT"
    printf 'ui_accessibility_validation=xcodebuild-hosted-ui-test\n'
    printf 'simplefin_live_fixture=%s\n' "$live_fixture"
  } > "$MANIFEST"
  chmod 600 "$MANIFEST"
}
write_manifest 'SKIPPED'

if [[ "${LEDGERBAR_RUN_LIVE_SIMPLEFIN:-0}" != "1" ]]; then
  printf 'native-gates: PASS — native and development-signed gates completed; protected SimpleFIN capture SKIPPED (set LEDGERBAR_RUN_LIVE_SIMPLEFIN=1 to run it)\n'
  printf 'native-gates: evidence manifest %s\n' "$MANIFEST"
  exit 0
fi

printf '%s\n' 'native-gates: owner-authorized protected SimpleFIN capture gate'
if ! swift run ledgerbar-capture \
    --days "$LIVE_DAYS" \
    --output "$LIVE_FIXTURE"; then
  fail 'the protected SimpleFIN capture command failed; inspect only sanitized evidence and retry in the owner-controlled terminal'
fi
[[ -s "$LIVE_FIXTURE" ]] || fail "the protected capture did not produce a sanitized fixture: $LIVE_FIXTURE"
write_manifest "$LIVE_FIXTURE"

printf 'native-gates: PASS — unsigned, ad-hoc diagnostic, development-signed host/UI/Keychain, and protected live-capture gates completed\n'
printf 'native-gates: evidence manifest %s\n' "$MANIFEST"
