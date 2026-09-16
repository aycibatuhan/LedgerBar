# LedgerBar development, gates, and publication workflow

Contributor and maintainer documentation. For what the app is and how to
install it, see the [README](../README.md). `SPEC.md` is the governing
specification; `§` references below point into it.

## Repository layout

- `Sources/LedgerCore` — headless core: deterministic replay engine
  (§3), conservation oracle (§3.7), GRDB persistence, the single
  `BudgetMutationService` actor (§6.4), SimpleFIN client/decoder/synchronizer
  (§4), Keychain credential store (§4.6).
- `Tests/LedgerCoreTests` — Swift Testing suite: §3.7 micro-goldens 1–17,
  the §3.10 three-month golden scenario, recurrence/overspending/refund
  rules, import classification, protocol/security boundaries, persistence,
  reconciliation.
- `Sources/LedgerCore/{Automation,Import,Reports,Schedules,Assistant}` —
  the financial-system extensions specified in `docs/DESIGN.md` and
  `docs/LOCAL-AI.md`: rules, file import, reports, schedules, and the
  local assistant. Each is a set of `BudgetWorkspace` extensions plus pure
  engines; none writes the database directly.
- `LedgerBar/` — app-only SwiftUI code (menu bar summary, onboarding,
  budget grid, register, Review Queue, staged-row resolution, reconciliation,
  SimpleFIN settings, backup). Consumed by both the SwiftPM executable target
  and the XcodeGen app bundle.
- `project.yml` — XcodeGen source for the sandboxed/signed `.app` bundle
  (§6.2). Requires `xcodegen` exactly `2.46.0` (see
  `Tools/xcodegen-version.txt`) and full Xcode.

## Schema upgrades

Migrations are additive and versioned (`v1`…`v16`). Opening a pre-v10
database first writes a verified copy next to it
(`ledgerbar.before-v10.sqlite`) before the `transactions` mirror is rebuilt;
delete that copy once you are satisfied with the upgrade. Restore remains
the manual procedure in the README.

## Development database paths

Relative `LEDGERBAR_DB_PATH` values are resolved inside the app's Application
Support directory. Absolute paths are restricted to explicit development
smoke tests and require `LEDGERBAR_ALLOW_ABSOLUTE_DB_PATH=1`; they are never
needed for normal use.

## Local `.app` builds

`./Tools/build-local-app.sh` packages the SwiftPM executable as an ad-hoc
signed bundle at `.build/Local/LedgerBar.app` — the canonical menu-bar-only
local build required by `SPEC.md` (`LSUIElement` = true, so no Dock icon).
`./Tools/install-local-app.sh` rebuilds it, copies it to
`/Applications/LedgerBar.app` (or `LEDGERBAR_INSTALL_DIR`), makes only the
installed copy Dock-visible, and re-signs it.

### App icon

The icon lives in `LedgerBar/Resources/Assets.xcassets/AppIcon.appiconset`
and is generated, not hand-edited: `Design/AppIcon.svg` is the reference
drawing and `swift Tools/render-app-icon.swift LedgerBar/Resources/Assets.xcassets`
re-renders every macOS size with CoreGraphics. The Xcode build compiles the
catalog (`ASSETCATALOG_COMPILER_APPICON_NAME`); the SwiftPM bundle script
assembles `AppIcon.icns` from the same PNGs with `iconutil`. The menu-bar
glyph is `BrandGlyph.menuBarImage`, an 18 pt template image drawn at runtime
from the same paths so the SwiftPM build needs no asset catalog. Change the
geometry in all three places together.

### Disposable smoke test

Use a scratch database so a first launch cannot touch the normal
Application Support store:

```bash
LEDGERBAR_ALLOW_ABSOLUTE_DB_PATH=1 \
LEDGERBAR_DB_PATH=/tmp/ledgerbar-smoke.sqlite \
  .build/Local/LedgerBar.app/Contents/MacOS/LedgerBar
```

This is also the correct way to produce README screenshots: seed the
scratch database with synthetic data and never capture a real budget.

### Ad-hoc signing boundary

Ad-hoc signing is sufficient for manual budgeting and launch testing, but
it does **not** pass the development-signed Keychain access-group gate. The
app preflights the actual Keychain store before sending a single-use
SimpleFIN Setup Token, so an unavailable Keychain fails closed before the
token is claimed; do not bypass that check or paste a production token into
another host. SimpleFIN credential storage must be validated with the
signed Xcode host described below; if full Xcode or a development team is
unavailable, that gate remains blocked rather than silently falling back to
a file credential store.

## Testing

`./Scripts/test.sh` is the canonical test invocation. With full Xcode it is
equivalent to `swift test --package-path .`; under a CommandLineTools-only
toolchain it supplies the Swift Testing framework search path and rpaths
explicitly. The headless suite must be green before any UI work (§6.2).

## SimpleFIN capture gate (§4.2)

Before the deployed-response decoder is frozen, run the one-command capture
against your own account (SimpleFIN must be connected in the app first):

```bash
swift run ledgerbar-capture            # → ./simplefin-shape-fixture.json
```

The standalone SwiftPM capture command is intentionally unsigned, so it
cannot query the signed app Keychain group. It therefore offers one
terminal-echo-disabled Access URL prompt and keeps the value in memory only
for the request. The signed app itself uses only its designated Keychain
group. The tool accepts no credential material in argv or ordinary
environment variables, and a non-interactive invocation remains blocked. The
raw body is written 0600 and deleted after the sanitized fixture is emitted
(best-effort deletion; not cryptographic erasure). The fixture preserves the
response shape (keys, string-vs-number types, decimal formatting,
`errors`/`errlist`) with all IDs pseudonymized and names/descriptions/amounts
redacted.

## Native host and signed Keychain gate (§6.2)

The repository includes a fail-closed runner for the complete native gate:

```bash
# Full Xcode must be selected; XcodeGen must be exactly 2.46.0.
# The team identifier is non-secret and is supplied only in the invoking shell.
# This command runs the native and signed Keychain gates, then reports PASS
# with the protected live capture explicitly marked SKIPPED unless opted in.
LEDGERBAR_DEVELOPMENT_TEAM=ABCDEFGHIJ \
LEDGERBAR_PROVISIONING_PROFILE_SPECIFIER='LedgerBar Mac Development' \
./Tools/run-native-gates.sh
```

The complete runner requires an explicit owner opt-in for the live capture
request. Run it from an interactive terminal after connecting the owner's
account in the app:

```bash
LEDGERBAR_DEVELOPMENT_TEAM=ABCDEFGHIJ \
LEDGERBAR_PROVISIONING_PROFILE_SPECIFIER='LedgerBar Mac Development' \
LEDGERBAR_RUN_LIVE_SIMPLEFIN=1 \
./Tools/run-native-gates.sh
```

`LEDGERBAR_RUN_LIVE_SIMPLEFIN` is only a gate switch; no credential is passed
through the environment. The signed app uses its Keychain boundary, while the
standalone capture tool opens its protected echo-disabled prompt and retains
only the sanitized fixture. When the live opt-in is absent, the runner exits
**PASS** after the native/signed gates and records
`simplefin_live_fixture=SKIPPED` in the evidence manifest. When the opt-in is
present, the protected capture must complete and its sanitized fixture path
is recorded instead.

The profile specifier belongs to the `LedgerBar` app target only. The hosted
unit/UI test bundles use automatic Apple Development signing with the supplied
team, so they are not incorrectly forced to use the app-only profile.
`Config/LocalSigning.xcconfig` maps both `LEDGERBAR_DEVELOPMENT_TEAM` and
`LEDGERBAR_PROVISIONING_PROFILE_SPECIFIER` into that app target; the runner
exports both values before invoking `xcodebuild`.
The runner intentionally does not pass `-xcconfig Config/LocalSigning.xcconfig`
globally to `xcodebuild test`: doing so would apply the app-only profile to the
distinct test bundle identifiers. The target-scoped `configFiles` binding is
the required equivalent for the development-signed host gate.

`Tools/run-native-gates.sh` runs `swift test`, verifies the pinned XcodeGen
version, an `Apple Development` identity, and the selected Mac Development
provisioning profile, generates `LedgerBar.xcodeproj`,
then runs the unsigned compile, ad-hoc signing spike, and development-signed
host/UI/Keychain test gates. The protected SimpleFIN capture runs only when
explicitly enabled; otherwise the native/signed result is **PASS** with the
live fixture marked **SKIPPED**. It exits as **BLOCKED** if full Xcode, XcodeGen,
the team identifier, the signing identity, or the provisioning profile is
unavailable; an unsigned or ad-hoc build is never reported as passing the
Keychain gate.
The generated native targets explicitly host `LedgerBarTests` inside the app
and associate `LedgerBarUITests` with the app target. The UI test still requires
a real macOS display and Accessibility permissions.

For manual inspection only, the underlying generation/build command is:

```bash
xcodegen --version       # must be exactly 2.46.0
xcodegen generate
xcodebuild -project LedgerBar.xcodeproj -scheme LedgerBar \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedDataUnsigned CODE_SIGNING_ALLOWED=NO build
```

`Config/LocalSigning.xcconfig` reads the non-secret team and app-profile
variables from the shell and is attached only to the app target. Never place
credentials or provider material in that file.

## Publication workflow (maintainer)

`PUBLIC_FILES.txt` is the explicit publication allowlist. Run
`./Tools/check-public-files.sh` before staging; it verifies — fail-closed —
that every listed file exists, that nothing generated, private, or
credential-bearing is included, and that no forbidden filename appears in
the current tree, in reachable history, or in any linked worktree. The
history audit inspects filenames only, never blob content; content review
of history is a separate manual gate. Never use `git add .` for
publication. Stage only the paths listed in `PUBLIC_FILES.txt` after the
check passes. New public files (for example README screenshots under
`docs/images/`) must be added to `PUBLIC_FILES.txt` first.
