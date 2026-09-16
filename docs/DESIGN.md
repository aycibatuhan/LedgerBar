# LedgerBar v2 design: automation, splits, schedules, reports, file import, multiple budgets

Status: design accepted for implementation; sections are updated as phases land.
`SPEC.md` remains the governing accounting specification; this document
extends it and records the decisions behind each new capability. Section
references (`§`) point into `SPEC.md` unless prefixed with `D`.

## D1. Current architecture (as inspected)

- **Value-type ledger.** `BudgetWorkspace` is the complete mutable state of
  one budget. Every mutation is `validate → mutate a copy → replay →
  conservation oracle → bump revision → self = copy`. A thrown error leaves
  the workspace byte-for-byte unchanged.
- **Replay engine.** `ReplayEngine.replay` folds allocations and non-voided
  rows in §3.2 order into monthly snapshots (`MonthSnapshot`), register and
  projection balances, and posting decisions. Credit-card provenance
  (funded/credit lots, refund caps) is derived per `(month, category)`.
- **Persistence.** `LedgerWorkspaceStore` writes the workspace as one JSON
  snapshot in `workspace_states` and rebuilds normalized mirror tables in the
  same transaction. Every table carries `budget_id`; the snapshot loader
  validates that every row references the snapshot's own budget.
- **Sync.** `SimpleFINSyncEngine` materializes remote rows through
  `BudgetWorkspace.importPostedTransaction`, records `SimpleFINImportRecord`
  identities, and produces `SyncConflict` / `SnapshotDiscrepancy` rows that
  the Review Queue resolves through fixed commands.
- **App.** `BudgetMutationService` (actor) is the sole writer; `AppModel`
  bridges a revision `ValueObservation` into `@Observable` state; SwiftUI
  views call `model.perform { workspace in … }`.

Invariants that every new feature must preserve:

1. Register balance counts each non-voided physical row exactly once.
2. Projection excludes staged and voided rows; the §3.7 oracle holds after
   every event.
3. Imported identity (`source_kind`, order key, import record) is immutable
   and survives voiding.
4. Closed months are append-only; reconciled rows are immutable until
   un-reconciled.
5. Categories and accounts are archived, never physically deleted.

## D2. Proposed architecture

The six capabilities are layered on the existing value-type ledger rather
than beside it:

```
                 ┌──────────────── UI (SwiftUI, native) ────────────────┐
                 │ Register · Budget · Reports · Schedules · Rules ·    │
                 │ Import sheet · Budget switcher · Review Queue        │
                 └──────────────┬────────────────────────┬─────────────┘
                                │ perform / query        │ observe
                 ┌──────────────▼────────────────────────▼─────────────┐
                 │ BudgetMutationService (actor, one loaded budget)     │
                 └──────────────┬────────────────────────┬─────────────┘
       mutations (write)        │                        │ read-only queries
 ┌──────────────────────────────▼───┐   ┌────────────────▼────────────────┐
 │ BudgetWorkspace + extensions      │   │ LedgerQuery (pure, over a       │
 │  · splits (D3)                    │   │ snapshot + projection):         │
 │  · rules (D4)                     │   │  · category lines (D3.4)        │
 │  · import batches (D6)            │   │  · report evaluation (D7)       │
 │  · schedules & occurrences (D5)   │   │  · schedule forecast (D5.6)     │
 │  · report definitions (D7)        │   │  · assistant tools (LOCAL-AI.md)│
 └──────────────┬────────────────────┘   └─────────────────────────────────┘
                │ replay (unchanged ordering; effects iterate components)
 ┌──────────────▼────────────────────┐
 │ ReplayEngine                       │
 └──────────────┬────────────────────┘
                │ snapshot + mirrors, one transaction
 ┌──────────────▼────────────────────┐
 │ LedgerWorkspaceStore (SQLite)      │  budgets registry + active budget (D8)
 └────────────────────────────────────┘
```

Import sources (SimpleFIN, files) converge on one materialization primitive
(`materializeImportedRow`, D6.3) so every source gets the same
classification, rule pass, duplicate handling, and audit trail.

## D3. Split transactions

### D3.1 Representation

Options considered:

| Option | Pros | Cons |
|---|---|---|
| A. Child `TransactionRow`s linked to a parent | Reuses row type; SQL-visible | Register/projection must special-case parents vs children; replay ordering, fingerprints, refunds, pairing all need parent/child rules; easy to double-count |
| B. Embedded `splits: [SplitComponent]?` on the parent row | One physical row = one bank event (register unchanged); replay order unchanged; identity and reconciliation untouched; components are pure allocation | Needs a JSON column in the mirror table; per-component SQL needs a small `transaction_splits` mirror |

**Chosen: B.** A split is an allocation of one transaction's amount across
categories, not a set of transactions. `TransactionRow.splits` is `nil` for
an unsplit row. `SplitComponent { categoryID, amountMilliunits, memo? }`.

### D3.2 Invariants (service-enforced, tested)

- At least two components; every component amount is nonzero and carries the
  same sign as the parent; `Σ components == amountMilliunits` (checked
  arithmetic, rejected otherwise). Rounding is the user's/rule's
  responsibility to present exactly; the engine never adjusts a component.
  Rule-created percentage splits use the largest-remainder method so the
  sum is exact by construction.
- Only `kind == .normal`, non-positive rows on budget-eligible accounts may
  be split (cash or card outflows). Inflows point at RTA only; refunds,
  transfers, opening balances, and adjustments are never split.
- A component may target `Uncategorized`; the row is then `needsCategory`
  (partial categorization is a first-class state).
- Splitting/unsplitting is a category edit: blocked in closed months and on
  reconciled rows; the accounting fingerprint covers the components.
- Bank identity, account, date, amount, payee, and import metadata live on
  the parent and are untouched by split edits. An imported amount change
  that no longer matches the components re-stages nothing silently: the
  in-place remote update path is only eligible for untouched
  `needsCategory` rows, and a split row is user-edited, so a remote change
  becomes a `SyncConflict` as today.

### D3.3 Replay semantics

`applyStandaloneEffects` iterates components when present. For cash
spending each component debits its own category. For card spending each
component produces its own `PurchaseLot` keyed by `(transactionID,
componentIndex)`; the funded/credit split is computed per component in
component order, which is deterministic. `purchaseIndex` becomes keyed by
`PurchaseKey` (unsplit rows use component index 0).

Linked card refunds carry `refundOfComponentIndex` (nil for an unsplit
origin). A refund whose origin is split but which names no component, or a
component that no longer exists, is staged `missingRefundOrigin` — the same
rule §3.8 applies when an origin edit invalidates a refund. The materialized
refund category copies the named component's category.

### D3.4 Category lines (shared by reports and AI)

`LedgerQuery.categoryLines(snapshot)` expands every non-voided row into
zero or more lines `(date, account, payee, category, amount, kind, source,
postingState, isTransferLeg, transactionID, componentIndex)`. Unsplit rows
yield one line; split rows yield one per component. Reports, the assistant,
and the schedule matcher aggregate lines, never parents plus children.

## D4. Transaction automation (rules)

### D4.1 Model

```
AutomationRule { id, budgetID, name, enabled, sortOrder, matchMode (.all | .any),
                 conditions: [RuleCondition], actions: [RuleAction],
                 stopAfterMatch, createdAt, updatedAt }
RuleCondition  { field, operator, value }
  field: importedDescription | payee | memo | account | amount | direction |
         date (dayOfMonth range | weekday set | range) | source (imported|manual|file) | category
  text operators: contains | equals | startsWith | endsWith | wildcard (case/diacritic-insensitive on the normalized form)
  amount operators: equals | between | lessThan | greaterThan (on magnitude; direction is its own field)
RuleAction     { setPayee(name) | setCategory(id) | setMemo(mode: replace|append|prepend, text)
               | setFlag(color?) | setApproved(bool) | split([SplitSpec]) }
```

Rules are budget-scoped (D8) and persisted in the workspace snapshot plus an
`automation_rules` mirror table.

### D4.2 Raw versus user-facing values

Imported rows gain an immutable `importedDescription` (the provider payee
or description exactly as received). `payeeID` remains the user-facing,
editable payee. Rules read `importedDescription` for "imported payee"
conditions and write `payeeID`; renaming never destroys what the bank sent.
Existing rows are backfilled from the import record's stored payee display
name during migration where available; otherwise `importedDescription` is
nil and the payee display name is used for matching.

### D4.3 Evaluation semantics (deterministic)

- Order: `(sortOrder, id)`. One forward pass; each matching rule applies its
  actions in declared order; a later rule sees the modified row;
  `stopAfterMatch` ends the pass. No fixpoint iteration.
- Category actions are validated against the §2.2.1 sign/kind matrix at
  apply time; an incompatible action is skipped and reported in the preview
  and audit, never coerced.
- Rules never change amount, date, account, imported identity, reconciled
  rows, voided rows, staged rows, transfer legs, or rows in closed months.
- **Automatic application** happens once, at materialization of an imported
  row (SimpleFIN or file), before payee learning and the sign default.
- **Retroactive application** is an explicit mutation with a mandatory
  preview: `previewRules(scope)` returns per-row proposed changes;
  `applyRules(scope)` commits them. By default rows the user explicitly
  categorized (`userEditedAtEpoch != nil`) are skipped; the user can opt in
  to overwriting.
- Every applied rule records an `AuditEvent("transaction", "ruleApplied",
  {rule, actions})` so the register can answer "why was this changed?".

### D4.4 Suggestions

Rule creation is always explicit. The Categorize sheet offers a one-click
"Also create a rule for this imported payee" checkbox pre-filled from the
row; nothing is created silently.

## D5. Schedules

### D5.1 Model

```
Schedule { id, budgetID, name, accountID, payeeName, categoryID?, transferToAccountID?,
           amountMilliunits (signed expected), amountToleranceMilliunits,
           recurrence: RecurrenceRule, startDate, endDate?, status (.active|.paused|.ended),
           dateWindowDays, weekendPolicy (.exact|.previousBusinessDay|.nextBusinessDay),
           autoMatch: Bool, createdAt }
RecurrenceRule = once | daily(every n) | weekly(every n, weekday) | monthly(every n, day: 1…31 | lastDay)
               | yearly(month, day) | everyNDays(n)
ScheduleOccurrence { scheduleID, dueDate, status (.matched|.entered|.skipped), transactionID? }
```

Occurrences are sparse: only matched, entered, or skipped occurrences are
stored. Expected occurrences are derived from the rule, the start date, and
the stored occurrences, so an expected event never claims to be a
transaction (§ "actual vs expected").

### D5.2 Calendar rules

- Month lengths: a monthly day greater than the month's length clamps to the
  last day; `lastDay` is explicit.
- Leap years: a yearly Feb 29 falls on Feb 28 in non-leap years.
- Weekend policy shifts the *expected* date; the window is applied around
  the shifted date.
- Skipped occurrences advance the series without creating anything.
- Amount, payee, or category edits apply to future occurrences only; stored
  occurrences keep the transaction they point to.

### D5.3 Matching imported/manual rows to expected occurrences

Deterministic scoring over candidate rows on the schedule's account within
`dateWindowDays` of an unmatched expected date:

- amount: exact → 3; within tolerance → 2; otherwise not a candidate
- payee: normalized payee equal, or the schedule payee's normalized tokens all
  contained in the row's normalized payee/importedDescription → 2; partial
  token overlap → 1; none → 0
- date distance: 0 days → 1; else 0

Score ≥ 5 with a unique best candidate → automatic match (audited,
reversible via "Unmatch"). Score 3–4, or ties → a `ScheduleMatchReview`
item in the Review Queue with the candidates listed. Below 3 → no match. A
row matches at most one occurrence and an occurrence at most one row. The
matcher runs after each import commit and after manual entry, inside the
same write.

### D5.4 Never duplicating

Schedules never insert transactions on their own. "Enter now" creates a
manual transaction and an `entered` occurrence in one mutation. If the bank
later imports the same event, the existing manual/import duplicate conflict
path (§4.3) applies unchanged; a file import's dedup pass sees the manual
row too (D6.5).

### D5.5 Missed occurrences

An expected occurrence whose window has fully passed with no match is
"overdue"; it stays visible in the Schedules view until matched, entered,
or skipped. Nothing auto-skips.

### D5.6 Forecast

`ScheduleForecast.project(through:)` lists expected occurrences with
amounts. Projected balances are computed as `registerBalance + Σ expected
amounts` and are always labeled projected; they never enter the ledger,
replay, or oracle.

## D6. File import

### D6.1 Formats

- **CSV** ships first: universal, needs a mapping workflow (D6.2).
- **OFX/QFX** ships with it: common US export, carries `FITID` (a stable
  per-institution transaction id) — the strongest dedup key available.
- **QIF** is deferred: no identifiers, ambiguous date formats, declining use.

### D6.2 CSV mapping

`CSVImportMapping { hasHeader, delimiter, dateColumn, dateFormat, amount
layout (.signed(column) | .debitCredit(debit, credit) | .amountWithType(amount,
typeColumn, outflowValues)), invertSign, payeeColumn, memoColumn?,
externalIDColumn?, encoding }`. Mappings are saved per budget with a
fingerprint of the header row so a repeat import of the same bank's export
pre-selects the mapping.

### D6.3 Pipeline

```
file → parse (format-specific) → [ParsedRecord]
     → normalize (mapping, budget calendar, MoneyParser)  → [NormalizedImportRow]
     → validate (dates in range, amounts finite, target account eligible)
     → detect duplicates (D6.5) → ImportPreview (per-row decision)
     → user confirms → workspace.commitImportBatch → rules → schedule matcher
```

All sources share `materializeImportedRow(source:identity:…)`, which
SimpleFIN's `importPostedTransaction` becomes a thin wrapper around.

### D6.4 Identity and audit

`sourceKind` gains `.file`. Each file-imported row gets a `FileImportRecord
{ transactionID, batchID, format, externalID?, fingerprint, rawFields
(sanitized key/values, bounded) }` and a `SourceOrderKey.file(batch:, row:)`.
`ImportBatch { id, budgetID, accountID, format, fileName, importedAt,
rowCount, skippedCount }` records provenance; the raw file is never stored.

### D6.5 Deduplication (conservative)

Per candidate row, in order:

1. Same account + same `externalID` (FITID) on an existing file-import record
   → **duplicate**, skipped.
2. Same account + same fingerprint (date, amount, normalized description) →
   **duplicate**, skipped.
3. Same account + same amount + date within ±3 days against any non-voided
   row (manual, SimpleFIN, file) → **possible duplicate**: shown with the
   existing row; default decision is *skip*, the user can switch it to
   *import*.
4. Otherwise → **new**.

Re-importing the same file is therefore a no-op (1 or 2). A later SimpleFIN
sync on the same account raises the existing `manualPotentialDuplicate`
conflict for file rows too (the check is extended from `.manual` to
`.manual | .file`), so nothing is merged silently in either direction.

## D7. Reports

### D7.1 Separation

1. **Query/aggregation** — `LedgerQuery` (pure functions over a snapshot and
   projection): filters, category lines, monthly series, net worth series,
   payee/account/category totals, period comparison.
2. **Definition** — `ReportDefinition` (Codable): kind, date range (relative
   presets or absolute), granularity, filters, grouping, comparison,
   visualization, sort/limit. Saved reports live in a `reports` table and the
   snapshot; duplicate/rename/delete are plain mutations.
3. **Visualization** — Swift Charts (system framework, no new dependency):
   bar, stacked bar, line, area, donut (only for share-of-total kinds), and
   a table plus summary metrics for every report.

### D7.2 Semantics (explicit)

- Voided rows are never counted.
- Staged rows are excluded from budget/category reports (they are excluded
  from projection) and included in balance/net-worth reports (register).
- Transfers: on↔on legs are never spending or income; an on→off leg counts
  as spending in its category, an off→on leg counts as inflow; card
  payments are transfers, never spending.
- Refunds are positive category activity (they reduce net spending).
- Split rows contribute per component.
- Income = signed RTA inflows (normal positive rows to RTA, off→on legs);
  reconciliation adjustments and openings are shown separately, not as
  income, unless the report opts in.
- Net worth = Σ register balances of all accounts in the budget currency
  (on- and off-budget), as of each period end; mismatched-currency accounts
  are excluded and listed.

## D8. Multiple budgets

Options considered:

| Option | Isolation | Backup/restore per budget | Fit with current code |
|---|---|---|---|
| Separate SQLite file per budget | Physical | Trivial (copy file) | Store/service/observation/backup all assume one file; a registry of files and per-file migrations are new moving parts |
| One database, budget-scoped rows | Structural (FKs, snapshot validation) | Whole-file backup exists; per-budget export as a JSON snapshot | Schema already carries `budget_id` everywhere and `workspace_states` is keyed by budget; the loaded workspace is one budget by construction |

**Chosen: one database, budget-scoped**, because the isolation the spec
wants already exists at the type level: a `BudgetWorkspace` cannot contain
another budget's rows (the snapshot validator rejects it), all mutations are
workspace-local, SimpleFIN state is keyed by budget, and the projection
cache is keyed by budget. What changes:

- `budgets` gains `archived`, `sort_order`; a new `app_settings` table stores
  the active budget id.
- `LedgerWorkspaceStore` gains `listBudgets()`, `deleteBudget()` (FK cascades
  remove every scoped row; the SimpleFIN Keychain item for that budget is
  deleted first through the credential lifecycle), and a budget-scoped
  revision observation.
- `BudgetMutationService.switchBudget(id)` loads another workspace; the app
  tears down and rebuilds observation and sync state.
- Per-budget export writes the Codable workspace snapshot plus SimpleFIN
  state (minus credentials) as JSON; import of that file creates a new
  budget with fresh identities. Whole-database backup is unchanged.
- Rules, schedules, reports, import mappings, and import batches are all
  budget-scoped. No cross-budget references exist; a transfer is always
  within a budget. App preferences (window state, show-closed toggles, AI
  runtime settings) stay global.

Deleting a budget is the one physical deletion in the system. It is
guarded by a typed-name confirmation, offered only after an export, and
audited in a global `app_audit` table.

## D9. Schema changes (migrations `v10`–`v15`)

Implemented as one migration per phase rather than a single `v10` so each
phase shipped independently: `v10-splits-imported-description-file-source`,
`v11-automation-rules`, `v12-file-import`, `v13-reports`, `v14-schedules`,
`v15-app-settings`. All additive; no existing column changes meaning.
Existing rows keep their identities, reconciliation state, categories, and
history.

- `transactions`: `splits BLOB NULL` (JSON components), `imported_description
  TEXT NULL`, `refund_of_component_index INTEGER NULL`; `source_kind` CHECK
  extended with `'file'`.
- `transaction_splits` mirror `(transaction_id, component_index, budget_id,
  category_id, amount_milliunits, memo)` for SQL diagnostics.
- `automation_rules (id, budget_id, name, enabled, sort_order, match_mode,
  stop_after_match, payload BLOB, created_at, updated_at)`.
- `schedules (...)`, `schedule_occurrences (schedule_id, due_date, status,
  transaction_id)`.
- `import_batches (...)`, `file_imports (transaction_id, batch_id,
  external_id, fingerprint, raw_fields)`, `import_mappings (...)`.
- `reports (id, budget_id, name, definition BLOB, created_at, updated_at)`.
- `budgets`: `archived INTEGER NOT NULL DEFAULT 0`, `sort_order INTEGER NOT
  NULL DEFAULT 0`.
- `app_settings (key TEXT PRIMARY KEY, value TEXT)`; `app_audit`.
- Backfill: `imported_description` from the payee display name for rows that
  have a SimpleFIN import record (the display name was initialized from the
  raw provider string and is the best available original).

Because the snapshot blob is the source of truth, the snapshot decoder gives
every new field a default so pre-v10 payloads load unchanged; the first save
after upgrade writes the new shapes.

## D10. Cross-feature interactions

| Interaction | Decision |
|---|---|
| Rules + splits | A rule may create a split (`split` action with fixed amounts or percentages, largest-remainder rounding). Rules never modify an existing split's components (skipped, reported). |
| Rules + file import | Rules run on file rows exactly as on SimpleFIN rows, after normalization; `importedDescription` is the raw file description. |
| Schedules + imports | The matcher runs inside the import commit; ambiguous matches go to the Review Queue; nothing is created. |
| Reports + splits | Reports consume category lines (per component). |
| Reports + budgets | A report definition is evaluated only against the loaded workspace; definitions are budget rows. |
| Schedules + budgets, rules + budgets | Budget-scoped; no global rules (isolation by default; a "copy to budget" export can come later). |
| File import + budgets | The import sheet always shows the active budget name and requires an explicit target account. |
| Splits + refunds | Component-addressed refunds (D3.3). |
| Splits + transfers | Not supported; a transfer leg cannot be split and a split cannot contain a transfer (architecture leaves room for a component kind). |

## D11. Migration strategy

- One versioned GRDB migration (`v10`), additive, wrapped in the migrator's
  transaction; failure leaves the pre-v10 file intact.
- Snapshot decoding is backward compatible (defaults); forward compatibility
  is not promised (a v10 file must not be opened by a v9 app — the app
  refuses when the schema is newer than it knows).
- Tests: open a v9 fixture database (built by the v9 migrator in the test),
  run v10, assert row counts, identities, reconciliation membership,
  categories, and projection equality before/after.

## D12. Testing strategy

- Invariant tests: split sum/sign, per-component card lots and refunds with
  the conservation oracle after every event, rounding of percentage splits,
  rule ordering/conflicts/stop-after-match/skip-on-incompatible, file
  re-import idempotence, file-then-sync duplicates, schedule calendar edge
  cases (31st, leap year, year boundary, weekend policy), matcher
  determinism and ambiguity, report aggregation semantics (transfers,
  refunds, staged, splits), budget isolation (a mutation in A never changes
  B's snapshot or projection), migration round trip.
- Property-style: randomized split partitions always reconcile to the parent
  and keep the oracle; randomized rule orderings are deterministic under
  re-evaluation; recurrence enumeration is monotonic and never repeats.

## D12a. Status

Phases 1–6 are implemented and covered by the suite (`SplitTransactionTests`,
`AutomationRuleTests`, `FileImportTests`, `ReportTests`, `ScheduleTests`,
`MultipleBudgetTests`). Deviations from the plan above, all deliberate:

- Rule conditions on weekday sets and absolute date ranges exist in the
  engine but not yet in the editor UI (day-of-month is editable).
- Schedule matching runs inside `importPostedTransaction`,
  `commitImportBatch`, and `addManualTransaction`; a standalone pass is
  available from the Schedules toolbar.
- Budget export excludes SimpleFIN state entirely; import always remaps
  identities (so an export can also serve as "duplicate budget").
- The `simplefin_imports` mirror's `connection_id` is `"<budget>:primary"`
  so its composite unique constraint is per budget.

## D13. Implementation phases

1. Foundation: schema v10, snapshot fields, `importedDescription`, splits in
   engine/mutations/UI, category lines.
2. Rules: engine, import hook, retroactive preview/apply, Rules window,
   categorize-sheet suggestion.
3. File import: CSV + OFX parsers, mapping, dedup, batch commit, import
   sheet.
4. Reports: query layer, definitions, evaluation, Reports view with Swift
   Charts, saved reports.
5. Schedules: recurrence, occurrences, matcher, Review Queue integration,
   Schedules view, forecast.
6. Multiple budgets: registry, switcher, create/rename/archive/delete,
   export/import snapshot.
7. Local AI (see `docs/LOCAL-AI.md`).

The app stays functional after each phase; each phase ends with the full
suite green.

## D14. Unresolved questions (decided by default, revisit if needed)

- Whether rules should also run automatically on manual entry (default: no;
  explicit "Apply Rules" covers it).
- Whether a schedule may target an off-budget account with a category
  (default: off-budget schedules have no category, like their transactions).
- QIF support (deferred until requested).
- Per-budget encrypted export (deferred; whole-file backup remains
  unencrypted SQLite per §7.3).
