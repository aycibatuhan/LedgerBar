# Contributing to LedgerBar

Thanks for your interest. LedgerBar is a small personal project with a
deliberately narrow v1, so the most useful first step for any change is an
issue describing the problem. This page is the contributor's map; the
user-facing overview is the [README](README.md).

## Documents

| Document | What it is |
| --- | --- |
| [SPEC.md](SPEC.md) | The governing specification: domain model, invariants, exact replay semantics, SimpleFIN integration, UI, build system, definition of done. Behavior follows the spec; if they disagree, the spec is fixed first. |
| [docs/DESIGN.md](docs/DESIGN.md) | Architecture and decisions behind split transactions, rules, file import, reports, schedules, and multiple budgets, including schema changes, invariants, migration and testing strategy. |
| [docs/LOCAL-AI.md](docs/LOCAL-AI.md) | The local assistant: the hard privacy boundary, runtime abstraction, tool layer, permission model, prompt-injection defenses, and implementation status. |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | Repository layout, database paths, schema upgrades, local and signed builds, the test gates, and the publication workflow. |
| [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) | Dependency versions and license texts. |

## Building and testing

Command Line Tools with a Swift 6 toolchain are enough for the core:

```bash
swift test               # headless correctness gate; must be green
swift build              # builds LedgerCore and the LedgerBar executable
swift run LedgerBar      # runs the SwiftUI app (menu bar + window)
```

`./Tools/build-local-app.sh` packages the SwiftPM executable as an ad-hoc
signed `.app`. The signed, sandboxed bundle (needed for the Keychain-backed
SimpleFIN credential) requires full Xcode and XcodeGen 2.46.0; run
`xcodegen generate` after adding files, because the Xcode project is
generated and not committed. See
[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for the signed build, the native
gates, and disposable smoke tests against a scratch database.

## How the code is organized

- `Sources/LedgerCore` is the engine: domain types, the value-type
  `BudgetWorkspace`, the replay engine, persistence (GRDB), and the
  feature modules `Automation`, `Import`, `Reports`, `Schedules`, and
  `Assistant`. It has no UI dependency.
- `LedgerBar/` is the SwiftUI app. All writes go through the single
  `BudgetMutationService` actor.
- `Tests/LedgerCoreTests` holds the Swift Testing suite, including the
  independent reference model and conservation oracle that gate the engine.

## Ground rules for changes

- **Keep the invariants.** Deterministic replay, conservation of money,
  provider-owned imported amounts, no silent history changes, and the
  local-only boundary of the assistant are not negotiable. New features
  extend the replay model rather than bypass it.
- **Migrations are additive** and every schema change comes with a
  migration test. Bump the schema in `DatabaseSchema.swift` and mirror the
  new tables in `WorkspaceStore`.
- **Tests first for engine work.** A behavior change to the engine needs a
  test that fails before and passes after. Run `swift test` before opening
  a pull request.
- **Docs move with code.** Update `SPEC.md` for behavior, `docs/DESIGN.md`
  or `docs/LOCAL-AI.md` for architecture, and the README for anything a
  user would notice.
- **Register new files.** Every published file must be listed in
  `PUBLIC_FILES.txt`; `./Tools/check-public-files.sh` verifies the list,
  fail-closed, against the tree and reachable history so nothing generated,
  private, or credential-bearing is published.

## App icon

The icon is an "LB" monogram built from ledger-like strokes.
`Design/AppIcon.svg` is the reference drawing. Regenerate the asset catalog
with:

```bash
swift Tools/render-app-icon.swift LedgerBar/Resources/Assets.xcassets
```

The menu-bar glyph is drawn at runtime by `LedgerBar/UI/BrandGlyph.swift`
from the same geometry, and `Tools/build-local-app.sh` assembles
`AppIcon.icns` for the SwiftPM bundle from the same PNGs. Change the
geometry in all three places together.

## Reporting problems

Open an issue with the steps to reproduce and, when relevant, the output of
`swift test`. Never attach your real database or a backup; use the
disposable smoke test in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) to
reproduce with synthetic data.

## License

By contributing you agree that your contributions are licensed under the
Apache License, Version 2.0, like the rest of the project.
