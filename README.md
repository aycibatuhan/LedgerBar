# LedgerBar

A local-first, zero-based envelope budgeting app for macOS (native SwiftUI,
menu bar + full window) that imports read-only bank data from SimpleFIN
Bridge and stores everything in one local SQLite file. No telemetry, no
LedgerBar server. `SPEC.md` is the governing specification.

## Layout

- `Sources/LedgerCore` — headless core: deterministic replay engine
  (§3), conservation oracle (§3.7), GRDB persistence, the single
  `BudgetMutationService` actor (§6.4), SimpleFIN client/decoder/synchronizer
  (§4), Keychain credential store (§4.6).
- `Tests/LedgerCoreTests` — Swift Testing suite: §3.7 micro-goldens 1–17,
  the §3.10 three-month golden scenario, recurrence/overspending/refund
  rules, import classification, protocol/security boundaries, persistence,
  reconciliation.
- `LedgerBar/` — app-only SwiftUI code (menu bar summary, onboarding,
  budget grid, register, Review Queue, staged-row resolution, reconciliation,
  SimpleFIN settings, backup). Consumed by both the SwiftPM executable target
  and the XcodeGen app bundle.
- `project.yml` — XcodeGen source for the sandboxed/signed `.app` bundle
  (§6.2). Requires `xcodegen` exactly `2.46.0` (see
  `Tools/xcodegen-version.txt`) and full Xcode.

## Build and run

With Command Line Tools only (development build, bare executable):

```bash
swift test               # headless correctness gate — must be green
swift build              # builds LedgerCore + the LedgerBar executable
swift run LedgerBar      # runs the real SwiftUI app (menu bar + window)
```

Relative `LEDGERBAR_DB_PATH` values are resolved inside the app's Application
Support directory. Absolute paths are restricted to explicit development
smoke tests and require `LEDGERBAR_ALLOW_ABSOLUTE_DB_PATH=1`; they are never
needed for normal use.

### Build a local `.app` with Command Line Tools only

When full Xcode is unavailable, package the same native SwiftUI executable as
an ad-hoc signed app bundle:

```bash
cd /path/to/LedgerBar
./Tools/build-local-app.sh
open .build/Local/LedgerBar.app
```

For a disposable first-run smoke test, use a scratch database so the launch
cannot touch the normal Application Support store:

```bash
LEDGERBAR_ALLOW_ABSOLUTE_DB_PATH=1 \
LEDGERBAR_DB_PATH=/tmp/ledgerbar-smoke.sqlite \
  .build/Local/LedgerBar.app/Contents/MacOS/LedgerBar
```

The bundle produced by this command is the canonical menu-bar-only local
build required by `SPEC.md`. It is a real native macOS app, not
Electron or a web wrapper. Because it uses `LSUIElement`, it appears as a
menu-bar app rather than a Dock icon.

### Install the Dock-visible app in Applications

To install a personal-use copy that appears in both the Dock and the menu bar:

```bash
cd /path/to/LedgerBar
./Tools/install-local-app.sh
open /Applications/LedgerBar.app
```

The installer rebuilds the canonical bundle, copies it to
`/Applications/LedgerBar.app`, changes only the installed copy to be
Dock-visible, and re-signs it. The installed copy retains the menu-bar
popover and its **Open LedgerBar**, Settings, and Quit controls. When the app
is running, right-click its Dock icon and choose **Options → Keep in Dock** if
you want it pinned after quitting.

If `/Applications` is not writable, install into your user Applications
folder instead:

```bash
LEDGERBAR_INSTALL_DIR="$HOME/Applications" ./Tools/install-local-app.sh
open "$HOME/Applications/LedgerBar.app"
```

Both the canonical and installed variants retain the menu-bar popover. Open
it, use **Open LedgerBar** for the full budgeting window, and use the gear
control for **Settings** (including SimpleFIN and Backup) or the power control
to quit. The main window's **Review Queue** is the user-facing surface for
persisted sync decisions.
When a Setup Token targets a non-official beta/test endpoint, LedgerBar first
rejects it locally and shows the exact host for confirmation. Choose
**Trust Host & Retry** only when the token came from that provider environment;
the exact lowercase host/port is then stored in this budget's trusted-host
list and the in-memory Setup Token is retried. The Setup Token is never written
to SQLite, UserDefaults, logs, or the repository. HTTPS, path, redirect, and
credential-forwarding checks remain enforced.
Ad-hoc signing is sufficient for manual budgeting and launch testing, but it
does **not** pass the development-signed Keychain access-group gate. The app
preflights the actual Keychain store before sending a single-use SimpleFIN
Setup Token, so an unavailable Keychain fails closed before the token is
claimed; do not bypass that check or paste a production token into another
host. SimpleFIN credential storage must be validated with the signed Xcode
host described below; if full Xcode or a development team is unavailable, that
gate remains blocked rather than silently falling back to a file credential
store.

### SimpleFIN capture gate (§4.2)

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

### Native host and signed Keychain gate (§6.2)

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
standalone capture tool opens its protected echo-disabled prompt and retains only the sanitized
fixture. When the live opt-in is absent, the runner exits **PASS** after the
native/signed gates and records `simplefin_live_fixture=SKIPPED` in the evidence
manifest. When the opt-in is present, the protected capture must complete and
its sanitized fixture path is recorded instead.

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

## Backup and manual restore (v1)

Settings → Backup creates a consistent snapshot via the GRDB backup API,
verifies it with `PRAGMA integrity_check`, and only then copies it to your
chosen destination. The backup is **unencrypted SQLite**; protect the
destination (FileVault, access controls).

Restore is manual in v1. A development-signed sandboxed app uses
`~/Library/Containers/com.ledgerbar.app/Data/Library/Application Support/LedgerBar/`;
the unsandboxed ad-hoc/manual bundle uses
`~/Library/Application Support/LedgerBar/`. Ad-hoc is not a SimpleFIN
credential-storage or live-capture configuration.

1. Quit LedgerBar.
2. In the appropriate LedgerBar Application Support directory above, remove
   `ledgerbar.sqlite`, `ledgerbar.sqlite-wal`, and `ledgerbar.sqlite-shm`.
3. Copy your backup file to `ledgerbar.sqlite` in that same directory.
4. Relaunch LedgerBar. The app rebuilds its observations from the replaced
   database on launch.

## Security posture

- SimpleFIN Setup Tokens are single-use, never persisted, and claimed only
  against `bridge.simplefin.org` or a host you explicitly trust.
- The Access URL credential lives in one Keychain item
  (`WhenUnlockedThisDeviceOnly`, non-synchronizable); SQLite stores only a
  reference. Redirects are refused; every request is validated against the
  approved host and exact path allowlist; errors and logs are redacted.
- The local database is unencrypted and relies on FileVault at rest.

## License

LedgerBar is licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).

LedgerBar's third-party dependencies remain under their respective upstream
licenses. Their exact versions, source revisions, and license texts are
recorded in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), with package
resolution recorded in `Package.swift` and `Package.resolved`.

## Public source allowlist

`PUBLIC_FILES.txt` is the explicit publication allowlist. Run
`./Tools/check-public-files.sh` before staging; it verifies that every listed
file exists and that no generated artifact, local database, credential, or
private path is included. Never use `git add .` for publication. Stage only
the paths listed in `PUBLIC_FILES.txt` after the check passes.