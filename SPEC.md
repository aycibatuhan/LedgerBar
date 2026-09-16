# LedgerBar Specification: Local-First Menu Bar Envelope Budgeting App with SimpleFIN Integration

## Project name
**LedgerBar** (working title) — a native macOS menu-bar budgeting app with local-first envelope budgeting, pulling transactions from SimpleFIN Bridge.

## One-line summary
A local-first, zero-based envelope budgeting app for macOS that stores all data locally in SQLite, imports read-only bank data from SimpleFIN Bridge, and computes its deterministic envelope budget locally without a LedgerBar cloud service.

The accounting rules below are intentionally written as a replayable reference model rather than loose product prose. The reference model and its tests must be implemented before the UI.

---

## 1. Product vision and scope

LedgerBar is a **real native macOS application**, not an HTML page, Electron application, or web app. The application must:

1. Implement zero-based envelope budgeting.
2. Pull posted accounts and transactions from SimpleFIN Bridge.
3. Store all budget data locally in SQLite.
4. Live in the macOS menu bar with a full native SwiftUI window.
5. Never send telemetry or budget data to a LedgerBar server.

This is **not** a cloud synchronization bridge.

### 1.1 v1 scope boundary

v1 implements a small, deterministic core that can actually ship:

- One local budget.
- One SimpleFIN Access URL/connection, which may expose many institutions and accounts.
- Checking, savings, cash, and credit-card on-budget accounts. v1 credit cards use the negative-debt convention: a card `projectionBalance` is never allowed to become positive. A positive `registerBalance` may occur transiently due to staged rows.
- Tracking/off-budget accounts are represented but have no budget-envelope automation beyond same-currency paired transfers.
- Current-month budgeting and historical month viewing. **Future-month assignments and future-month reallocation behavior are deferred to v1.1.** Future months are read-only in v1.
- Manual transaction entry, SimpleFIN import, register-based Needs Category and Staged/Needs Resolution review flows, exact-payee auto-categorization, envelope budgeting, credit-card payment automation, manual transfers, reconciliation, and database backup.
- Posted transactions are deduplicated by the SimpleFIN composite identity.
- Automatic matching of imported transactions to pre-existing manual transactions is deferred to v1.1. v1 must not silently merge two transactions.
- Automatic transfer pairing suggestions are deferred to v1.1. v1 supports explicit user-created transfer pairs and manual pairing of two imported transactions.
- v1 rejects or stages any credit-card snapshot/transaction/payment that would make a credit-card `projectionBalance` positive. Positive `projectionBalance`, card-to-cash advances, card-to-card transfers, and overpayments are v1.1. This explicit limitation keeps the v1 oracle closed under the supported state space.
- Configurable payee rename rules are deferred to v1.1; v1 may use a deterministic built-in normalizer plus exact normalized-payee history.
- Restore is deferred to v1.1; v1 provides a verified local backup only.

### 1.2 Deferred to v1.1

- Future-month assignments, future-month reallocation, goals.
- Splits containing transfer legs (category splits are §3.11).
- Automatic manual/import matching and automatic transfer suggestions (schedule matching links rows to *expected* events, §3.12, but never merges two rows).
- Database restore UI, QIF import, CSV export, investment tracking, and loan amortization.
- iOS/iPadOS applications and cloud synchronization.

Shipped after v1 and specified in `docs/DESIGN.md`: split transactions (§3.11), automation rules (D4, hooked into §4.3 step 4½), file import for CSV/OFX/QFX (D6), reports (D7), schedules (§3.12/D5), and multiple budgets (D8). The single-budget accounting rules below are unchanged; each budget is an independent instance of them.

The v1 boundary is deliberate: correctness of the ledger and budget engine is more important than feature breadth.

---

## 2. Domain model and invariants

### 2.1 Entities

Every row below has a `budget_id` foreign key unless explicitly marked budget-global. v1 has one budget, but the key is retained so the schema does not bake in accidental global state.

- **Budget**: `id`, `name`, immutable `currency` (ISO 4217 such as `USD`), immutable IANA `time_zone_identifier` captured at budget creation, immutable `first_month` (`YYYY-MM`), `last_observed_budget_month` (`YYYY-MM`, monotonic and initialized to the creation month), `next_local_source_sequence` (the single source-order allocator shared by `manual:` and `system:` keys), `created_at`, monotonic `revision`.
- **Account**: `id`, `budget_id`, `name`, `type` (`checking`, `savings`, `cash`, `creditCard`, `other`), `on_budget`, `closed`, `currency`, `history_incomplete`, `created_at`. v1 permits `other` only as off-budget. No SimpleFIN identifiers are stored on this row. An on-budget credit-card `projectionBalance` is never allowed to become positive; a positive `registerBalance` may occur transiently due to staged rows and is explicitly permitted. A positive snapshot pauses its link.
- **CategoryGroup**: `id`, `budget_id`, `name`, `sort_order`, `hidden`.
- **Category**: `id`, `budget_id`, `group_id`, `name`, `sort_order`, `hidden`, immutable `kind` (`inflow`, `cc_payment`, `spending`), nullable `linked_account_id`, immutable `system_kind` nullable, `note`. In v1, `inflow` and `cc_payment` kinds are system-only: there is exactly one system `Inflow: Ready to Assign` category and exactly one payment category per credit-card account; user-created categories are `spending` only. A `cc_payment` category must point to exactly one credit-card account; each credit-card account has at most one such category. The system inflow and `Uncategorized` categories are immutable system categories.
- **MonthlyCategoryAllocation**: `id`, `budget_id`, `category_id`, `month`, `budgeted_milliunits`. Unique `(budget_id, category_id, month)`. Sparse: zero rows mean zero assignment. `setBudgeted` accepts only `>= 0`. A negative allocation row is permitted only when created or changed inside the atomic `moveMoney(category → category)` or `moveMoney(category → RTA)` mutation, with an `AuditEvent` recording the source/destination and amount; arbitrary negative assignments and direct SQL writes are rejected. `activity` and `available` are never stored.
- **Payee**: `id`, `budget_id`, immutable nullable `system_kind` (`openingBalance`, `transfer`, `reconciliationAdjustment`, `cardDebtAdjustment`, `unknown`), `namespace` (`system` or `user`), normalized `name` (NFKC + uppercase + whitespace-collapsed; this is the unique key within the namespace), `display_name` (user-visible, initialized from the raw `payee`/`description` and editable), `last_used_category_id` nullable, `hidden`. Unique `(budget_id, namespace, name)`. Imported descriptors that normalize to a system display string remain ordinary `namespace = user` payees; only `system_kind` marks a system payee. System payees are excluded from payee-learning updates and auto-categorization.
- **Transaction**: `id`, `budget_id`, `account_id`, nullable `payee_id`, `source_kind` (`manual`, `simplefin`, `system`), `date` (`YYYY-MM-DD` in the immutable budget calendar), `effective_at_epoch` nullable, non-null `source_order_key` text, nullable `memo`, signed `amount_milliunits`, `cleared` (`uncleared`, `cleared`, `reconciled`), `approved`, nullable `flag_color`, `posting_state` (`needsCategory`, `staged`, `posted`, `voided`), nullable `stage_reason` (`cardBalanceWouldBecomePositive`, `crossMonthRefund`, `missingRefundOrigin`, `overRefund`, `unlinkedCardInflow`, `cashInflowWithCreditDebt`, `transferPairCounterpartyStaged`, `closedMonthImport`, `transferPairUnpairNeedsCategorization`), nullable sanitized `stage_metadata_json`. Stage metadata must preserve the original/proposed category, refund origin, transfer-pair ID, and the triggering balance/reason fields needed for deterministic re-staging; for `cashInflowWithCreditDebt`, it must include `proposed_category_id`. nullable `user_edited_at`, nullable `category_id`, nullable `transfer_pair_id`, nullable `refund_of_transaction_id`, `kind` (`normal`, `refund`, `openingBalance`, `adjustment`). A linked refund's `category_id` is a materialized, non-user-editable copy of its origin's current spending category; origin recategorization atomically updates every dependent refund's copy before replay, or clears/stages it if the origin is invalid. `kind = refund` may target a spending category for a normal linked/same-month refund, the system `Inflow: Ready to Assign` category for an explicit cross-month refund-recovery resolution, or a spending category for a user-explicit cash reimbursement. A linked card refund requires `refund_of_transaction_id`; a user-explicit cash reimbursement may omit it. `category_id` is required for an on-budget `posted` normal or refund row. A positive normal row must point to the system inflow category; a non-positive normal row must point to `kind = spending` (and uses `Uncategorized` while `needsCategory`). It is null only for explicitly enumerated off-budget, transfer, opening-negative-credit-card, staged-card/staged-refund, and adjustment exceptions. `voided` rows retain import identity but affect neither register balances nor budget projection. `source_kind = simplefin` iff a `SimpleFINImport` row exists; manual and system rows never receive a remote import identity.
- **SimpleFINConnection**: `id`, `budget_id`, one row maximum in v1, `status` (`active`, `disconnected`), nullable `keychain_item_ref`, `base_host`, `base_port`, `credential_generation`, `created_at`, `last_successful_sync_at`. Disconnect/reconnect reuses this row and increments `credential_generation`; it never creates a second connection row for the budget.
- **SimpleFINLink**: `id`, `budget_id`, `connection_id`, `account_id`, `remote_connection_key`, `remote_account_id`, `amount_sign_normalization` (`normal`/`inverted`), `raw_currency`, `status` (`active`, `paused`), nullable `pause_reason` (`futurePostedEpoch`, `positiveCardSnapshot`, `unconfirmedSignDirection`, `duplicateRemoteIdentity`, `missingStableConnectionKey`, `currencyMismatch`, `authRevoked`, `closedMonthImportPending`, `snapshotDiscrepancy`, `protocolError`), `created_at`. Unique `(connection_id, remote_connection_key, remote_account_id)` and unique `(connection_id, account_id)`. `closedMonthImportPending` is informational after the append-only cursor commit, not a cursor-blocking error.
- **SimpleFINImport**: `id`, `budget_id`, `transaction_id` (non-null for all imported rows; remote-pending rows are never inserted; unique FK to exactly one import identity), `connection_id`, `remote_connection_key`, `remote_account_id`, `remote_transaction_id`, `remote_amount`, `remote_posted_epoch`, nullable `remote_transacted_epoch`, `remote_payload_hash` (SHA-256 of canonical UTF-8 JSON for the normalized remote row using lexicographically sorted keys and no secrets), `protocol_version`, `last_seen_at`. Unique `(transaction_id)` and unique `(connection_id, remote_connection_key, remote_account_id, remote_transaction_id)`. Remote-pending rows are not imported as transactions in v1; this table contains posted and staged imports only.
- **SimpleFINAccountCursor**: `budget_id`, `connection_id`, `remote_connection_key`, `remote_account_id`, `last_successful_posted_epoch`. Primary key `(connection_id, remote_connection_key, remote_account_id)`.
- **SyncState**: `id`, `budget_id`, `last_error_code`, `last_error_message_redacted`, `last_successful_sync_at`. Single-flight is a runtime actor/mutation-service invariant, not a persisted boolean. Request history is stored in `SyncRequestLog` rows, not an undefined JSON blob.
- **SyncRequestLog**: `id`, `budget_id`, `connection_id`, nullable `account_id`, requested start/end epochs, started/completed timestamps, status, HTTP status, nullable retry-after seconds.
- **SyncConflict**: `id`, `budget_id`, `transaction_id`, `simplefin_import_id`, `event_kind` (`remoteChanged`, `remoteDisappeared`, `manualPotentialDuplicate`), old/new sanitized metadata, created/resolved timestamps, status (`open`, `resolved`, `dismissed`). It records remote changes or explicit duplicate candidates that must not overwrite user-owned data.
- **SnapshotDiscrepancy**: `id`, `budget_id`, `account_id`, observed epoch, normalized remote balance, local non-voided register balance **as of the observed epoch** (same replay-order cutoff and posting-state inclusion rules as §4.4), status (`open`, `resolved`), nullable `resolution_reason` (`adjustment`, `accountClosedOffBudget`, `manualAttestation`), nullable `adjustment_transaction_id`, created/resolved timestamps.
- **TrustedHost**: `id`, `budget_id`, lowercase `host`, `port`, `created_at`. Unique `(budget_id, host, port)`; the official `bridge.simplefin.org:443` host is seeded, and a custom/test host is inserted only after explicit user confirmation.
- **TransferPair**: `id`, `budget_id`, status (`complete`, `unpaired`, `voided`), created_at. `transactions.transfer_pair_id` references this parent; a complete pair has exactly two legs and is validated atomically by the mutation service. A complete pair's canonical replay order is derived as the earlier of its two leg replay-order tuples, with `transfer_pair_id` as the final tie-breaker; it is not replayed as two independent budget events. Pairing captures one immutable `TransferPairLegSnapshot` per leg before replacing its standalone classification. If an existing pair is unpaired, its legs restore those snapshots exactly; if a newly-created leg has no valid standalone snapshot, unpairing leaves it staged with `stage_reason = transferPairUnpairNeedsCategorization` and never applies the positive-inflow/RTA default automatically.
- **TransferPairLegSnapshot**: `id`, `budget_id`, `transfer_pair_id`, `transaction_id`, standalone `payee_id`, `category_id`, `kind`, `posting_state`, `stage_reason`, `stage_metadata_json`, `approved`, `cleared`, `memo`, and `captured_at`. Unique `(transfer_pair_id, transaction_id)`. It is immutable audit state and is restored transactionally during unpairing; a new pair created from blank rows stores an explicit `requiresUnpairResolution` marker rather than inventing a standalone category.
- **Reconciliation**: `id`, `budget_id`, `account_id`, `statement_date`, `statement_balance_milliunits` (stored in the account's normalized sign convention), `cleared_balance_milliunits`, nullable `adjustment_transaction_id`, nullable `adjustment_fingerprint_at_creation`, `status` (`open`, `completed`, `undone`), `created_at`, nullable `completed_at`.
- **ReconciliationTransaction**: `id`, `budget_id`, `reconciliation_id`, `transaction_id`, `transaction_fingerprint_at_reconciliation`, `was_newly_marked_reconciled`. The fingerprint covers every accounting field (account, date/effective ordering, amount, category, kind, posting/void state, transfer/refund links, payee, memo, cleared, and approved), so undo is allowed only when the stored fingerprint still matches.
- **AuditEvent**: `id`, `budget_id`, `entity_type`, `entity_id`, `event_kind`, sanitized metadata, and `created_at`. It records staged-row resolutions, explicit pairing, reconciliation undo, and other user-visible accounting mutations without secrets.
- **ClosedMonth**: `budget_id`, `month` (`YYYY-MM`), `status` (`closed`, `reopened`), `closed_at`, nullable `reopened_at`. Unique `(budget_id, month)`. A `closed` month blocks user allocation changes and user edits/deletions/reclassification of existing transactions that affect that month's replay (amount/date/category/kind/posting-state/void/transfer/refund/reconciliation membership); an explicit audited reopen is required before those corrections. Append-only remote import materialization is the sole exception: a new remote row whose date falls in a closed month is inserted as `staged` with `stage_reason = closedMonthImport`, never re-staged or auto-resolved while closed, and its account cursor may advance after that append-only commit. Reopening is atomic, visible in history, and the month must be closed again deliberately.

The v1 migration does **not** create a subtransactions table. Category splits (§3.11) are stored on the transaction row as `splits` (JSON components) with a `transaction_splits` mirror; a split is an allocation of one physical row, never a set of rows.

Two further transaction fields exist since schema v10: immutable nullable `imported_description` (the provider/file payee text exactly as received; rules match on it and never overwrite it — `docs/DESIGN.md` D4.2) and nullable `refund_of_component_index` (a linked refund of a split purchase names its component, §3.11). `source_kind` also admits `file` for rows imported from a user-supplied file (`docs/DESIGN.md` D6); such rows carry a `FileImportRecord` identity exactly as `simplefin` rows carry a `SimpleFINImport`.

### 2.2 Required system entities and onboarding

On first launch, the app offers “Create your first budget,” asks for currency, the user's IANA time zone, and a **first budget month**. The first-month picker defaults to the current `YYYY-MM` in the selected budget time zone, permits the current month or an earlier month, rejects future months, and stores the chosen value immutably at budget creation. It is the lower bound used by replay and initial-link history truncation; changing it later is not supported in v1. The app then creates default category groups (`Fixed Expenses`, `Savings`, `Everyday Spending`, `Needs Attention`) with a small set of editable placeholder categories. The budget time zone is immutable in v1 so an epoch always maps to the same budget date. A month is **current** when its `YYYY-MM` equals the budget's persisted `last_observed_budget_month`; on every launch/activation the injected budget clock may advance that field but never decreases it when the system clock moves backward. A month is **past** when it precedes that monotonic observed month. A past month may be explicitly **closed** by the user (creating a `ClosedMonth` row), after which its allocations are read-only. An unclosed past month's allocations are also read-only — only the current month can be assigned or reallocated. The distinction is UI-visible: closed months show a lock icon; unclosed past months show "needs review" if spending exceeded assignments.

The app also creates:

- **Inflow: Ready to Assign**: an immutable system category with `kind = inflow`.
- **Uncategorized**: an immutable `kind = spending` system category in `Needs Attention`. A posted on-budget transaction imported without a chosen category and with a non-positive amount points here and remains `posting_state = needsCategory`; its activity is included in the projection until the user chooses a real category. An uncategorized positive on-budget inflow defaults to `Inflow: Ready to Assign` and remains visibly unapproved instead of using this spending category.
- **Credit Card Payments** group: created when the first credit card is added.
- One immutable `cc_payment` category per credit card account.
- System payees `Opening Balance`, `Transfer`, `Reconciliation Balance Adjustment`, `Card Debt Adjustment`, and `Unknown Payee`.
- “Needs Category” and “Staged/Needs Resolution” register filters. These are workflow states, not budget categories.

An opening balance for an on-budget non-card account is a signed inflow to `Inflow: Ready to Assign`: a positive opening funds RTA and a negative opening (an overdrawn account) reduces it, which may leave RTA negative (§3.3). A negative credit-card opening is allowed as pre-existing debt with no category and no budget-envelope effect. This is an explicit exception to the normal category-required rule. Off-budget accounts may have either opening sign and are register-only.

For v1, all past-month allocation cells are read-only, whether or not the month has explicitly closed; only the current month can be assigned or reallocated. Transactions may be corrected in an earlier **unclosed** month before reconciliation; a closed month requires the explicit reopen workflow in §2.1/§3.8, which triggers a full projection recomputation and a visible “historical change” notice.

### 2.2.1 Supported transaction constraint matrix

The mutation service enforces these rules before writing; SQLite checks/triggers enforce only row-local and parent/child facts, as stated in §6.3:

| Transaction state/kind | Payee | Category | Register/budget effect |
|---|---|---|---|
| posted normal on-budget positive | required | required; must be `kind = inflow` | register + signed RTA activity |
| posted cash reimbursement/refund | required | required; `kind = spending`, `Transaction.kind = refund` | register + positive spending-category activity; no RTA |
| posted linked credit-card refund | required | required; `kind = spending`, `Transaction.kind = refund`, earlier same-card origin | register + positive spending-category activity plus refund-lot/payment events; no RTA |
| posted cross-month refund-recovery resolution | system `Card Debt Adjustment` | required; system `Inflow: Ready to Assign`, `Transaction.kind = refund` | register + positive RTA activity + offsetting synthetic negative event to the refunding card's payment category (§3.5.3); no historical spending-lot mutation |
| posted normal on-budget non-positive | required | required; must be `kind = spending`; `Uncategorized` while `needsCategory`; never `cc_payment` | register + envelope projection |
| split normal on-budget non-positive (§3.11) | required | null on the row; every component `kind = spending`; any `Uncategorized` component keeps the row `needsCategory` | register once + one envelope event per component |
| posted normal off-budget | required | null | register only, no envelope effect |
| staged imported card row | required when known, otherwise `Unknown Payee` | null | register included; excluded from envelope projection until resolved |
| staged imported cash inflow with creditDebt | `Unknown Payee` or known | null; `stage_metadata_json.proposed_category_id` may name a `spending` category | register included; excluded from envelope projection until resolved |
| staged imported row landing in a closed month | required when known, otherwise `Unknown Payee` | null | append-only register row; excluded from envelope projection until the month is reopened and resolved |
| staged leg of a transfer pair | system `Transfer` | null or preserved original category metadata | register included; complete pair excluded from envelope/payment projection until atomically resolved |
| staged unpaired transfer leg without a standalone snapshot | system `Transfer` | null | register included; excluded from envelope projection until the user explicitly categorizes/resolves it |
| posted on↔on transfer leg | system `Transfer` | null | no direct effect; card-payment exception applies |
| posted on↔off transfer leg | system `Transfer` | required on the on-budget leg (`spending` or `inflow` kind only), null off-budget | included only on the on-budget leg |
| opening on-budget non-card, either sign | `Opening Balance` | RTA (`inflow` kind) | signed RTA activity |
| opening negative credit-card | `Opening Balance` | null | register only; pre-existing debt |
| opening off-budget | `Opening Balance` | null | register only |
| voided | may be retained | ignored | excluded |
| posted credit-card adjustment while `projectionBalance` remains `<= 0` | `Card Debt Adjustment` | null | register only; budget-neutral |
| posted cash-account reconciliation adjustment | `Reconciliation Balance Adjustment` | RTA (`inflow` kind), including a signed negative adjustment | signed RTA activity |

A `cc_payment` category is never user-assignable to a direct transaction. Its activity is always synthetic, derived from credit-card purchases, refunds, payment transfers, and cross-month refund-recovery resolutions (§3.5.3). Allocations to a `cc_payment` category are allowed only via `setBudgeted` or `moveMoney`. The sole `inflow` category (RTA) is assignable only to positive on-budget inflows, cross-month refund-recovery resolutions, and reconciliation adjustments. RTA is a sentinel endpoint, not an allocatable category: no `MonthlyCategoryAllocation` row ever carries the RTA category id. `setBudgeted` may not target RTA or `Uncategorized`; `moveMoney` interacts with RTA only through its explicit **RTA → category** / **category → RTA** forms (§3.3), which adjust only the non-RTA side's allocation row.

Initial `cleared` values for imported rows: imported posted transactions default to `cleared = uncleared`. Opening balance transactions default to `cleared = cleared`. Adjustment transactions default to `cleared = cleared`. Manually entered transactions default to `cleared = uncleared`. The user may toggle `uncleared` ↔ `cleared` at any time; `reconciled` is set only by the reconciliation flow.

A new manual credit-card transaction or new manual payment pair that would cross its `projectionBalance` above zero is rejected before any row is inserted. A SimpleFIN-imported row that would cross the guard is inserted as staged rather than dropped; an existing imported row whose later edit would cross the guard is left unchanged and the edit is rejected. The user can resolve an eligible staged card row as a budget-neutral `Card Debt Adjustment` only when `projectionBalanceAsIfResolved({row})` remains `<= 0`; a cross-month refund uses the explicit RTA-plus-payment-category recovery path in the matrix (§3.5.3). Because a staged row was already included in `registerBalance`, an eligible resolution changes projection classification but produces no register-balance delta.


### 2.3 Currency rule

v1 is single-currency:

- The budget has one immutable currency.
- SimpleFIN account currency is stored exactly as returned.
- A linked account with a different currency, a custom currency, or a missing currency is shown to the user but is excluded from on-budget calculations and cannot be used in a budget or transfer pair. Its `Account.on_budget` flag remains the user's immutable account classification, but `budgetEligible(account)` is derived as `on_budget && account.currency == budget.currency`; mismatched accounts are register-only/off-budget for projection and are tracked as `currencyMismatch` until v1.1 multi-currency support.
- `CashLikeAssets`, envelope projections, card guards, reconciliation adjustments, and conservation checks include an account only when `budgetEligible(account)` is true. Register views may display any one account in its own currency, but cross-account totals never mix currencies.
- Never sum milliunits from different currencies.

---

## 3. Accounting model — exact replay semantics

### 3.1 Money and signs

All stored money is a signed 64-bit integer in milliunits (1/1000 of a currency unit). `amount_milliunits > 0` is an inflow to an account; `< 0` is an outflow.

Define **signed category activity** as the sum of all direct and synthetic budget events for that category in a month. Therefore an outflow contributes a negative activity. The available formula uses `+ activity`, never `- activity`.

A decimal amount is parsed as `Decimal`, multiplied by 1000, then rounded to scale 0 using an explicit `NSDecimalNumberHandler` with `roundingMode = .bankers` and `scale = 0` (equivalently `NSDecimalRound` at scale 0 after multiplication). v1 accepts more than three fractional decimal places and deterministically banker-rounds them to the nearest milliunit; it rejects only NaN, infinity, values outside Int64, malformed values, and conversion overflow. Never use `Double` or `Int(amount * 1000)`.

All replay additions/subtractions use checked Int64 arithmetic. An overflow aborts the current mutation, rolls back its database transaction, records a redacted data-integrity error, and is surfaced to the user; it is never a wrapping operation and never crashes the process in production.


### 3.2 Ordering

Budget dates are stored as local-calendar `YYYY-MM-DD`, but credit-card behavior requires chronological ordering. Store:

- `effective_at_epoch`: SimpleFIN `posted` epoch for imported posted transactions.
- For a manually entered transaction with only a date, use local noon converted to epoch.
- `source_order_key`: stable canonical key. Components use one pinned length-prefixed UTF-8 encoding: `remote:<byteLength(connection)>:<connection><byteLength(account)>:<account><byteLength(transaction)>:<transaction>` for SimpleFIN rows, `manual:<20-digit-zero-padded-sequence>` for manual rows, and `system:<20-digit-zero-padded-sequence>:<system_kind>` for system rows. Both `manual:` and `system:` sequences draw from the budget's single `next_local_source_sequence` allocator, which is incremented in the same database transaction; values are never reused after a committed insert. The key must remain unchanged after insertion. The prefix is part of the deterministic lexicographic order; the fixed-width sequence is part of the wire/storage contract.
- **Budget date** (`transactions.date`): for imported transactions, derived from the SimpleFIN `posted` epoch converted to the budget's local calendar date using the immutable budget time zone. The optional `transacted_at` field is stored in the import record but is **not** used for the budget date in v1 — it may differ from `posted` by several days, and using it would place activity in a different budget month. For manually entered transactions, the user-provided date is used directly. Same-month refund linkage (§3.5.3) uses the budget date of both the refund and the original purchase.
- A user date edit is an explicit replay mutation: for a manually editable row, set `date` to the new budget date and recompute `effective_at_epoch` to that date's local noon; for an imported row, retain the remote posted epoch in `SimpleFINImport` but set the transaction's `effective_at_epoch` to the new date's local noon and retain its remote `source_order_key`. Paired legs recompute their logical event tuple together. Any edit that crosses a month/closed-month/dependency rule is rejected or re-staged by the rules below.

Replay order is `(effective_at_epoch or date-noon, source_order_key, transaction.id)` for standalone rows. Same-day manual ordering is deterministic, and a later sync cannot reorder an existing remote row merely because the server returned a different array order. Store the original `transacted_at`/`posted` values in the import record or a raw metadata column where available.

Before replay, group every `TransferPair` with status `complete` into one logical `TransferEvent`. Its order tuple is the earlier of the two leg order tuples, with `transfer_pair_id` as the final tie-breaker. Applying a `TransferEvent` updates both account balances and all associated synthetic budget events atomically; the two physical transaction rows are never replayed as separate budget events. For deterministic historical replay, both legs participate at the pair's logical effective tuple; their displayed dates and imported posted epochs remain preserved for audit. `registerBalanceAsOf`, `projectionBalanceAsOf`, snapshot comparisons, and card guards all use this same logical replay cutoff: an as-of prefix that includes either leg includes the complete pair, so no calculation can expose one half of a paired event. Reconciliation membership instead uses the separate row-local statement-date and cleared-state rule in §3.9; it does not use the logical pair-pulled cutoff. An on-budget↔on-budget pair therefore has zero net envelope effect at one oracle checkpoint, while a cash→card payment emits its payment-category event at that same checkpoint. An unpaired row is standalone only after its pre-pair snapshot is restored; a row without a valid standalone snapshot remains staged with `transferPairUnpairNeedsCategorization` and cannot receive a sign-based RTA/category default. Pair creation, unpairing, or edits invalidate the earliest affected month and rebuild the logical-event grouping before the next replay; no later leg can retroactively remove an earlier standalone event during a single pass.

### 3.3 Month state and current-month-only assignments

v1 does not allow assigning money in a future month. A future month can be viewed but its allocation cells are read-only. Past-month allocations are also read-only (whether or not the month has been explicitly closed). Only the current month can be assigned or reallocated. This removes undefined “future assignments draw from this month's pool” behavior from v1.

**Transaction-date boundary**: a manually entered transaction must use a budget date in `budget.first_month ... current_month`; a future-dated manual transaction is rejected before insertion. A SimpleFIN row whose `posted` epoch converts to a future budget date is a protocol/timezone anomaly: it is not inserted, not included in the cursor commit, and not silently clamped to the current month. The link is paused with `pause_reason = futurePostedEpoch` and a redacted sync error identifies the offending date; the user may retry after the budget clock reaches that date or fix the timezone/connection. Consequently v1 has no future-dated local transactions, and replay, snapshot, reconciliation, and RTA rollover never need an undefined future-month transaction state.

Two distinct allocation primitives exist:

1. **`setBudgeted(category, month, value)`** — sets a single category's `budgeted_milliunits` for the current month to an arbitrary non-negative integer. This is the primary user action in the budget grid. It may exceed `RTADisplayed(m)`, which makes `RTAEnd` negative (over-assignment, displayed in red). It may be reduced below the category's current-month activity, which creates or increases `cashDebt` or `creditDebt` mid-month — this is allowed and the replay handles it. The `value` parameter must be `>= 0`; negative budgets are rejected. `setBudgeted` rejects the system RTA and `Uncategorized` categories as targets. This primitive changes total assignment and therefore changes `RTAEnd`.

2. **`moveMoney(source, destination, amount, month)`** — atomically adjusts allocations. `amount` must be a strictly positive checked milliunit value; `source` and `destination` must be distinct; the operation is rejected on overflow, currency mismatch, `Uncategorized`, or any other immutable/system-ineligible category argument. RTA is a **sentinel endpoint**, not a category argument: no `MonthlyCategoryAllocation` row ever carries the RTA category id, RTA participates in `moveMoney` only through the two dedicated RTA-endpoint forms below (which adjust only the non-RTA side's allocation row), and passing the RTA category id as the `source` or `destination` of the category → category form is rejected. Three forms exist:
   - **category → category**: subtract `amount` from source allocation, add `amount` to destination. Total assignment unchanged. Both must be `spending` or `cc_payment` kind. If the source's current available includes carry-over, subtracting can make its stored `budgeted_milliunits` negative; that negative row is valid only as the audited result of this atomic operation.
   - **RTA → category**: add `amount` to destination allocation only. Total assignment increases, `RTAEnd` decreases by `amount`. `amount` cannot exceed `RTADisplayed(m)` and RTA may not go negative.
   - **category → RTA**: subtract `amount` from source allocation only. Total assignment decreases, `RTAEnd` increases by `amount`. `amount` cannot exceed the source's current non-negative available. A negative source allocation is valid only as the audited result of this operation or the category-to-category form.
   
   For a category source, `amount` cannot exceed its current non-negative available. Moving from a payment category is allowed only up to its current non-negative available balance and is shown as a reallocation, not a card payment. The engine never permits an arbitrary negative allocation row. `setBudgeted` and `moveMoney` are deliberately different primitives: direct assignment may leave `RTAEnd` negative as an over-assignment warning, while an explicit `RTA → category` move requires currently available RTA and may not cross below zero. The UI must label these distinct semantics rather than presenting them as interchangeable ways to reach the same allocation.

For each month `m`, replay months chronologically from `budget.first_month` through `m`. All allocations for month `m` become effective at the month-start boundary, before any transaction dated in month `m`; allocations do not participate in the epoch ordering of individual transactions. Therefore assigning money later in the UI recomputes the month as if the assignment was available before the month's transactions, and can turn formerly credit-overspent card purchases into funded purchases/payment-category movement without deducting RTA.

Use **signed RTA activity**, not an “inflows-only” shortcut:

```
RTAStart(first_month) = 0
RTAEnd(m) =
    RTAStart(m)
  + sum(signed RTAActivity in m)
  - sum(net category assignments in m)
RTAStart(next_month) = RTAEnd(m) - CashOverspendingAtEnd(m)
RTADisplayed(m) = RTAEnd(m)
```

Signed RTA activity includes positive cash-account transactions categorized to an inflow/RTA category, signed on-budget cash-like opening balances, positive cross-month refund-recovery resolutions (each paired with an offsetting synthetic negative event to the refunding card's payment category, §3.5.3), negative cash-account adjustments, and on-budget legs of off-budget → on-budget transfers (which bring money into the plan). It excludes refunds to a spending category, ordinary credit-card debt-reduction cashback, and on↔on transfers (which move money between accounts already in the plan). `RTAEnd` may be negative; v1 permits over-assignment and displays it in red. Current-month spending does not change RTA immediately. Cash-like underfunding is deducted only when the next month begins. Credit overspending is never deducted from RTA.


### 3.4 Derived category values

`activity` and `available` are not database columns. They are produced by a pure replay projection:

```
availableBefore(c, first_month) = 0
availableBefore(c, m) = max(0, availableEnd(c, previous_month))
availableEnd(c, m) =
    availableBefore(c, m)
  + budgeted(c, m)
  + sum(BudgetEvent.delta for category c during m)
```

All month-start allocations are applied before the month's ordered transaction replay. The sum is not a naïve SQL sum of raw transactions because credit-card purchases, refunds, and payments create synthetic budget events. The engine fetches allocations and posted transactions for the date range, sorts them by the ordering in §3.2, and replays them. It may batch-fetch with SQL and fold in Swift; it must not materialize `available` or attempt a cumulative `SUM` that ignores month-end clamping.

`activity(c,m)` is the sum of the same direct and synthetic events and is signed. A spending outflow is negative; a refund is positive; a funded credit-card purchase creates a positive synthetic event for that card's payment category; a credit-card payment transfer creates a negative synthetic event for that payment category; a cross-month refund-recovery resolution creates a negative synthetic event for the refunding card's payment category (§3.5.3).

The projection also retains event provenance: for each category it knows which negative lots came from cash overspending, credit overspending, or payment underfunding. Positive events consume those lots deterministically as specified in §3.5. This is an in-memory derived state, not a materialized database value.

Remote-pending SimpleFIN rows are not imported in v1 and therefore do not appear in the register or budget projection. A posted imported on-budget outflow without a user-selected category is stored with `posting_state = needsCategory` and the immutable `Uncategorized` category; it affects the register and budget projection until the user assigns a real category. A posted imported on-budget inflow without a user-selected category is assigned to `Inflow: Ready to Assign` with `approved = false` and remains visible for review. This prevents unknown activity from silently disappearing from the ledger while preserving conservation.


### 3.5 Cash and credit overspending — complete state machine

For each spending category during one month, the replay maintains:

- `available`: the displayed scalar;
- `creditDebt`: a non-negative bucket for the debt-like portion of credit-card outflows that exceeded available funds;
- `cashDebt`: **derived**, not independently tracked. After every event that changes `available` or `creditDebt`, recompute `cashDebt := max(0, -available - creditDebt)`. This ensures the bucket identity `negative available == -(cashDebt + creditDebt)` always holds, even when a card refund increases `available` in a category that also has cash overspending.

For each credit-card payment category it maintains `available` and `paymentCashDebt = max(0, -available)` when a payment, refund funded-lot consumption, or cross-month refund-recovery resolution makes the payment envelope negative. `paymentCashDebt` is treated as cash-like underfunding and is included in `CashOverspendingAtEnd`.

**Bucket identity invariants** (asserted after every replayed event alongside the §3.7 oracle):

- For every spending category: `negative available == -(cashDebt + creditDebt)` when available is negative; `cashDebt == 0 and creditDebt == 0` when available is non-negative.
- For every payment category: `paymentCashDebt == max(0, -available)`.

All these buckets reset at the next month boundary after their month-end amount has been used: positive available carries, all negative displayed availability resets to zero, `cashDebt` and `paymentCashDebt` reduce the next month's RTA, and `creditDebt` resets to zero because the credit-card debt itself remains in the account balance. A creditDebt value is never carried as a category balance into the next month.

#### 3.5.1 Cash-account spending

For an outflow `x` from a checking, savings, or cash account:

1. Decrease the category's `available` by `x`.
2. The portion `min(max(available_before, 0), x)` is consumed from previously assigned category funds for provenance; it creates no separate debt lot and does not mutate a stored cash-debt field.
3. For this cash-account source, recompute the derived `cashDebt := max(0, -available - creditDebt)` after the event.
4. Account balance decreases by `x`.

#### 3.5.2 Credit-card spending

For an outflow `x` from a credit card:

1. Read the normalized `projectionBalance` of the card immediately before the transaction, including all non-voided local `posted` and `needsCategory` rows; `staged` and remote-pending rows are excluded.
2. v1 requires the balance to be `<= 0`; a positive balance or a transaction that would cross above zero is rejected/staged.
3. Because v1 has no positive card balances, `cashLike = 0` and `debtLike = x`.
4. Decrease the spending category's `available` by `x`.
5. Consume remaining non-negative category available. The consumed amount is `fundedDebtLike` and creates a synthetic `+fundedDebtLike` event in this card's payment category. The remainder becomes category-scoped `creditDebt` and creates no payment-category funding; recompute the derived `cashDebt := max(0, -available - creditDebt)` after the event.
6. Decrease the card account balance by `x`.

The general positive-balance crossing algorithm is v1.1; v1 does not silently route it through a cash-like path.

#### 3.5.3 Positive events and refunds

A positive direct event from a cash account may be explicitly classified by the user as a cash reimbursement/refund (`Transaction.kind = refund`) and increase a spending category only when that category has no `creditDebt`. A positive imported/manual row is never auto-categorized to a spending category: absent explicit classification it uses the inflow/RTA path. A cash refund may carry an optional same-account origin for audit, but unlike a credit-card refund it does not consume credit-card funded lots. It increases `available`; the derived `cashDebt := max(0, -available - creditDebt)` therefore falls first if the category was cash-overspent, and any remaining amount becomes ordinary positive available. The implementation does not decrement a stored cash-debt field. If `creditDebt > 0`, the row is persisted with `posting_state = staged` and `stage_reason = cashInflowWithCreditDebt`; its sanitized stage metadata preserves the proposed spending category and `kind = refund`. The user may resolve it by (a) categorizing it to RTA, which creates RTA income without violating the category's `creditDebt` bucket, or (b) recategorizing the original credit-card purchase that created the `creditDebt` so the category no longer has `creditDebt`, which allows the cash refund to post normally on the next replay. A cash-account inflow is never allowed to reverse a credit-card purchase, because that would create cash without a corresponding envelope source.

A posted credit-card positive event is a `Transaction.kind = refund` and is normal only when all of these are true: `refund_of_transaction_id` identifies an earlier posted credit-card purchase in the **same budget month and earlier in replay order**, the refund amount is positive and no greater than that originating purchase's `remainingRefundableLot`, the refund is on the **same card account** as the original purchase, and applying it leaves the normalized card `projectionBalance <= 0`. The refund's materialized `category_id` must equal the original purchase's current spending category at replay time. If the origin is recategorized, the same atomic mutation updates every dependent refund's materialized category before replay; the refund is never allowed to retain a stale stored category. The projection stores per-purchase `remainingRefundableLot` (initialized to `abs(purchase.amount_milliunits)`) and per-purchase `remainingFundedLot` (initialized to that purchase's non-negative funded portion). Each refund decrements the originating purchase's `remainingRefundableLot` by the full refund amount; funded capacity is consumed from the category-wide lot set described below and may therefore decrement a different purchase's `remainingFundedLot`. Each funded-lot entry also retains its card account so the corresponding payment-category event can be emitted to the correct card. It stores category-scoped `creditDebt`; credit capacity is not tracked as a separate per-purchase field because credit debt and funded capacity are intentionally shared across all purchases in the same category and month. This is derived provenance, not a materialized transaction column.

For a linked refund amount `r`, consume the **category's** `creditDebt` bucket first, then the category's remaining funded lots across all purchases in replay order. The category scope is `(budget_id, budget_month, category_id)` and includes funded lots from every credit card; the refund itself must still be on the same card as its origin. This is an explicit deterministic cross-card category rule defined by the conservation model:

```
d = min(r, category.creditDebt)
f = r - d
require f <= sum(remainingFundedLot for all purchases in this category and month, in replay order)
category.creditDebt -= d
remainingRefundableLot(originPurchase) -= r
for each funded-lot segment (purchase, card, amount) consumed in replay order:
    purchase.remainingFundedLot -= amount
    payment-category(card).activity -= amount
available(category) += r
cashDebt(category) = max(0, -available(category) - category.creditDebt)
category activity += r
```

The `for` loop emits one negative synthetic event per consumed funded-lot segment to that segment's card payment category; it does not blindly subtract all `f` from the refund card's payment category. The origin purchase's refundable cap and the category-wide funded capacity are separate constraints. This category-scoped credit-first rule ensures `creditDebt` reaches zero before `available` becomes non-negative, preserving the §3.5 bucket identity invariant and the §3.7 oracle at the month boundary, even when multiple purchases in the same category have different funded/credit mixes, cash overspending, or different credit cards. A refund may reduce derived `cashDebt` simply because `available` rises; no cash-debt lot is consumed or stored. Thus `f + d = r` for every partial or full refund. Repeated refunds are capped by the originating purchase's `remainingRefundableLot` and the category's total remaining funded lots plus `creditDebt`, and are rejected/staged if they would over-refund. This category-scoped, cross-card credit-first algorithm is a deliberate deterministic choice; correctness is judged by the conservation oracle and bucket identity.

A refund whose original is in another budget month, whose original is missing, whose amount exceeds remaining lots, or whose application would make the card positive is persisted as `staged` with an explicit `stage_reason` (`crossMonthRefund`, `missingRefundOrigin`, `overRefund`, or `cardBalanceWouldBecomePositive`). Its amount already affects `registerBalance` but has no envelope projection effect until resolution. A `crossMonthRefund` may be explicitly resolved only through the current-month recovery workflow: retain the origin link for audit, set the system payee `Card Debt Adjustment`, set `Transaction.kind = refund`, set the materialized category to `Inflow: Ready to Assign`, emit positive signed RTA activity of the refund amount `r`, and — in the same atomic mutation, at the same replay position — emit one offsetting synthetic `-r` event to the refunding card's payment category; perform no historical spending-lot mutation. The resolution is permitted only while `projectionBalanceAsIfResolved({row}) <= 0`. The payment-category available may go negative, creating `paymentCashDebt` (§3.5.4) that reduces next month's RTA. This event pair is conserved under the §3.7 oracle: when the origin's funded money is still reserved in the payment envelope, the resolution releases exactly that reservation to RTA; when it is not (the origin was credit-overspent or the card was already paid down), the resulting `paymentCashDebt` claws the transient RTA gain back at the next month boundary, so the recovery never creates cash. Missing-origin, over-refund, and card-positive rows may use the budget-neutral `Card Debt Adjustment` resolution only when `projectionBalanceAsIfResolved({row}) <= 0`; otherwise they remain staged. Every resolution is an audited reclassification and leaves `registerBalance` unchanged.

A positive unlinked event from a credit card is also persisted as `staged` with `stage_reason = unlinkedCardInflow`; it is never left in an ambiguous pending state and is never silently routed to RTA. It may be resolved only as the explicit budget-neutral `Card Debt Adjustment` described above, or remain staged. A genuine unresolved positive-card state also has a non-destructive recovery: after explicit confirmation, the user may close the on-budget account and create an off-budget successor, transfer the link/cursor to that successor, create one audited off-budget opening anchor at the migration snapshot, and leave all historical rows/import identities on the closed account. This resolves future sync/reconciliation without voiding the bank row; in the same atomic workflow, any open snapshot discrepancy on the old account is marked resolved with `resolution_reason = accountClosedOffBudget`, the old account is excluded from budget projection, and no historical row is deleted or silently recategorized.

#### 3.5.4 Cash-like underfunding and month end

`CashOverspendingAtEnd(m)` is:

```
sum(cashDebt for all spending categories in m)
+ sum(paymentCashDebt for all credit-card payment categories in m)
```

It reduces next month's RTA. `CreditOverspendingAtEnd(m)` is a month-local test/oracle term only; it resets at the next month boundary and does not reduce RTA. This is why January's credit overspending is zero in the February category state while January's card debt remains in the account balance.


### 3.6 Credit-card payment events

A cash-account → credit-card payment is represented by two paired transactions: cash outflow `-p` and card inflow `+p`, both `category_id = null`, with one shared `transfer_pair_id` and `p > 0`. There are two mutation cases:

1. **New insertion**: before writing either physical row, compute `projectionBefore` for the card. Require `projectionBefore + p <= 0`; otherwise reject the complete manual pair atomically with no inserted rows. A SimpleFIN-imported positive card row is handled by §4.3 as a staged import, not by this new-pair path.
2. **Resolution/pairing of existing rows**: if the card `+p` row already exists as a staged imported transaction, do not insert or duplicate it. Validate `projectionBalanceAsIfResolved({cardRow}) = projectionBefore + p <= 0`; `registerBalanceAfterResolution = registerBefore` because the physical row was already present. If the matching cash leg also already exists, it is likewise reclassified rather than inserted. A staged row that is resolved as this transfer emits the payment event only once.

On a complete valid pair, replay emits one synthetic `-p` event to that card's payment category. If payment-category available becomes negative, its `paymentCashDebt` is recorded for next-month RTA rollover. The payment never creates RTA. The mutation service must not use `p <= -registerBalance` as a resolution guard for a card row already counted in the register; use the candidate-excluded/as-if-resolved postconditions above.

A credit-card → cash-account advance, card-to-card transfer, and off-budget → credit-card transfer are rejected in v1. Positive `projectionBalance`, projection-positive overpayments, cash advances, and card-to-card balance movements are v1.1 features with a separate signed-asset model. A payment made while an unresolved staged credit makes only the physical `registerBalance` positive is the explicit recovery path in §3.6, not a projection-positive overpayment; it remains visibly staged/paused until the user resolves or soft-voids that credit.

A negative credit-card opening balance is pre-existing debt: it is uncategorized and creates no payment-category or RTA event. The user must assign money to the card payment category if they want to pay it.

A cashback, statement credit, or other positive card event that is not a valid same-month linked refund is imported as `staged`, not as a normal budget transaction. The user may explicitly reclassify an unlinked/missing-origin/over-refund row as a `Card Debt Adjustment` while `projectionBalanceAsIfResolved({row}) <= 0`; its amount was already present in `registerBalance`, so that resolution changes the projection classification but creates no register delta, RTA, or envelope event. A staged `crossMonthRefund` with a known origin instead uses the §3.5.3 recovery path, which emits positive RTA activity plus the offsetting synthetic negative payment-category event. If the adjustment would make the card positive, the staged row and the link remain paused. A cash-back deposit into a checking account is the supported way to create RTA. For a genuine positive-card asset that cannot be resolved under the guard, the user may use the non-destructive off-budget-successor workflow in §3.5.3: close the on-budget account, create an off-budget successor, migrate the link/cursor with an audited snapshot opening, and preserve the historical row/import tombstones on the closed account. As a last-resort explicit destructive action, the user may soft-void an unresolved imported staged positive-card row after confirmation; the import tombstone and an `AuditEvent` remain, the row leaves `registerBalance`, and any resulting snapshot discrepancy remains visible until resolved. Sync never performs either operation automatically.

### 3.7 Conservation oracle

Define two balance notions used throughout the spec:

- **`registerBalance(account)`**: the sum of all non-voided physical transaction amounts for that account, including `posted`, `needsCategory`, and `staged` rows. Each existing physical row is counted exactly once, whether or not it is later paired or resolved. This is what the user sees in the account register and what is compared against the SimpleFIN snapshot in §4.4.
- **`projectionBalance(account)`**: the sum of all non-voided `posted` and `needsCategory` physical transaction amounts for that account, **excluding `staged` rows**. This is what the budget projection and conservation oracle use. A complete transfer pair contributes both of its physical account legs once; logical-event grouping prevents duplicate budget events, not duplicate account deltas.

A posting-state/category/transfer-link resolution of an already-existing staged row is a reclassification, not a new transaction: it changes `projectionBalance` and/or budget effects but changes `registerBalance` by **zero**. A physical insert changes register balance by its amount; a soft void or permitted physical delete removes that row's amount. For any candidate resolution set `C`, `projectionBalanceAsIfResolved(C) = current projectionBalance + sum(amount of staged rows in C that would become posted/needsCategory)`, with complete transfer-pair grouping and card guards applied exactly once. The register-side postcondition for a resolution is `registerBalanceAfter = registerBalanceBefore`; the projection-side postcondition is evaluated against `projectionBalanceAsIfResolved`, not against an artificial second insertion.

The card-balance guard in §3.5.2 and §3.6 uses `projectionBalance` for the pre-transaction balance check. A new physical payment pair is checked against `projectionBalanceAfterInsertion` only; an existing staged row resolution uses `projectionBalanceAsIfResolved` and does not apply an insertion guard or add its amount twice. `registerBalance` remains the display/snapshot/reconciliation balance and may be positive due to unresolved staged credits; it is not a payment rejection condition. The §4.4 snapshot comparison uses `registerBalanceAsOf`. Reconciliation (§3.9) uses `registerBalance`. The UI (§5.2) displays `registerBalance` as the account balance and shows a separate "staged" count.

For a selected replay horizon, after excluding `staged` and `voided` transactions and off-budget/currency-mismatched accounts, v1 guarantees that every linked credit card participating in the envelope projection has a normalized `projectionBalance <= 0`. `needsCategory` rows are **included** because they use the `Uncategorized` spending category. Define:

```
CashLikeAssets = sum(projectionBalance of checking/savings/cash accounts where budgetEligible(account))

CashLikeAssets
  == RTADisplayed(horizon)
   + sum(available of every spending category at horizon)
   + sum(available of every credit-card payment category at horizon)
   + sum(creditDebt bucket at horizon)
```

The `creditDebt` term is required because credit overspending creates negative spending-category available without consuming cash. `cashDebt` and negative payment-category availability need no separate current-horizon RHS term: their corresponding cash outflow/payment — or, for a cross-month refund-recovery resolution, the offsetting positive RTA activity — is already reflected in `CashLikeAssets`, RTA, and the negative category available; at the next month boundary the cash-like bucket reduces RTA before the negative envelope resets. A negative card opening/adjustment is excluded from cash assets and has no budget event. Positive-card assets are forbidden in v1, so no hidden positive-balance term is needed.

The oracle is asserted **after every replayed event**, as well as at each month boundary, using the month-start allocation state and the posted, non-staged budget events in the prefix. It is not a net-worth identity and must not include negative credit-card liabilities on the left. Production `BudgetProjection` maintains checked running scalar totals and throws a redacted `IntegrityError` on any mismatch; the mutation transaction rolls back and records only sanitized diagnostics. The test `ReferenceModel` exposes the full per-category/per-card breakdown and compares it against production after every event. This keeps release replay bounded while preserving the exact differential gate. Production and test code are separate: `ReferenceModel` uses independent state structs and transition code and never calls production projection functions. Randomized differential tests must generate valid and invalid operations, compare accepted-state/verdict/error class, and verify rejection leaves the prior state byte-for-byte unchanged. Unsupported v1 states are tested as rejected/staged, not forced through the model.

Required micro-goldens in addition to §3.10:

1. Negative card -$100, funded purchase -$40, then payment +$40. Per event: the purchase emits spending activity -$40 and a synthetic +$40 event to the card's payment category, moving the card to -$140; the payment pair emits a synthetic -$40 event to the payment category, decreases the cash account by $40, and returns the card to -$100. Final state: spending-category activity -$40, payment-category month activity $0 and available $0, card net unchanged at -$100, net cash-like assets decreased by $40; the oracle holds after each event.
2. Negative card -$100, credit-overspent purchase -$40: spending -$40, creditDebt $40, RTA unchanged.
3. Negative card -$100, linked same-month refund +$40 of a funded purchase: spending +$40, payment -$40, card remains negative.
4. Negative card -$100, linked same-month partial refund +$40 of a $100 fully credit-overspent purchase: spending +$40, creditDebt decreases by $40, card remains negative.
5. Mixed purchase with funded lot $60 and credit lot $40, linked refund $75: creditDebt decreases $40 (to 0), payment decreases $35, spending increases $75, available becomes +$35. Credit-first preserves the bucket identity (`creditDebt == 0` when `available >= 0`).
6. Cross-month refund or repeated over-refund: persisted as staged; no envelope projection mutation until explicit resolution (micro-goldens 16–17 cover the cross-month resolution itself).
7. Staged positive card inflow reclassified as `Card Debt Adjustment` while the card remains negative: the physical row was already in the register, so register balance is unchanged; the projection gains the row once, envelopes/RTA remain unchanged, and a zero-crossing resolution is rejected/staged.
8. Payment transfer that would cross card above zero: rejected/staged, no projection mutation.
9. Negative cash-account reconciliation adjustment: signed negative RTA activity and equal cash decrease.
10. Cash inflow to a spending category with `creditDebt > 0`: staged as `cashInflowWithCreditDebt`, register increases, projection unchanged.
11. Multi-purchase category: assign $100 to Dining, card purchase P1 $100 (fully funded, payment +$100), card purchase P2 $50 (credit-overspent, creditDebt $50). Linked refund $50 of P1: category-scoped credit-first consumes `d = min(50, 50) = 50` from `creditDebt`, `f = 0`; P1's `remainingRefundableLot` falls to $50 and no funded lot is consumed. Result: Dining $0, payment $100, creditDebt $0. Bucket identity holds and the month boundary loses no creditDebt.
12. Sequential category-scoped refunds: after #11, linked refund $50 of P2 is within P2's refundable cap; `d = 0`, `f = 50`, consumed from P1's remaining funded lot in replay order, and emits `-50` to P1's card payment category. P2's refundable lot reaches zero; Dining becomes +$50, payment becomes $50, and the oracle remains conserved.
13. Mixed cash/card debt refund: assign $50, card purchase $100, then cash outflow $30 in the same category, then linked card refund $60. Before refund: available -$80, creditDebt $50, derived cashDebt $30; after `d = 50`, `f = 10`: available -$20, creditDebt $0, derived cashDebt $20, payment decreases by $10. The current oracle and next-month RTA deduction both remain conserved.
14. Same category across two credit cards: a refund's origin must be on the same card, but category-scoped creditDebt/funded lots may include both cards; each consumed funded-lot segment debits that segment's own payment category, and the aggregate oracle plus both card guards remain valid.
15. Funded purchase after payment: negative card -$100, assign $100, card purchase $100 (card -$200), payment $100 (card -$100), then linked same-month refund $40 (card -$60, so the refund's `projectionBalance <= 0` condition holds and it posts). The purchase's remaining funded lot is intentionally still refundable; the refund raises the spending category by $40 and emits `-40` to the card payment category, which creates `paymentCashDebt = $40` and reduces next-month RTA. This deliberate provenance rule is documented and tested rather than silently reassigning the refund to current RTA.
16. Cross-month recovery, funded origin: January — opening checking +$1,000 → RTA, assign Dining $100, funded card purchase -$100 (Dining $0, payment category +$100, card -$100). February — imported card refund +$100 of the January purchase is staged `crossMonthRefund`: register includes it, projection is unchanged, and the oracle holds (cash-like $1,000 == RTA $900 + payment $100). Explicit resolution posts the row to `Inflow: Ready to Assign` with payee `Card Debt Adjustment`: RTA activity +$100 (RTA $1,000) and the same atomic mutation emits the synthetic `-100` payment-category event (payment $0); card `projectionBalance` -$100 → $0; `registerBalance` unchanged; the oracle holds after the event (cash-like $1,000 == RTA $1,000).
17. Cross-month recovery clawback, credit-overspent origin: January — opening checking +$1,000 → RTA, unassigned card purchase -$100 (Dining -$100, `creditDebt` $100; oracle: $1,000 == RTA $1,000 + Dining -$100 + creditDebt $100). At the boundary Dining resets and `creditDebt` resets with no RTA deduction. February — the +$100 card refund is staged `crossMonthRefund`, then resolved: RTA $1,000 → $1,100, payment category $0 → -$100 with `paymentCashDebt` $100; the oracle holds after the event (cash-like $1,000 == RTA $1,100 + payment -$100). March — `paymentCashDebt` reduces RTA to $1,000 and the payment category resets to $0: the transient RTA gain is fully clawed back and no cash was created.

### 3.8 Transfers

A normal internal transfer always has two transaction rows and one shared `TransferPair` parent UUID:

- same-currency on-budget → on-budget: source outflow and destination inflow, both uncategorized and with no envelope effect, except the cash→credit-card payment event in §3.6;
- same-currency on-budget → off-budget: both legs exist when the destination account is represented; the on-budget leg is categorized to a spending category because money leaves the plan, while the off-budget leg is uncategorized;
- same-currency off-budget → on-budget: the on-budget leg is categorized to RTA because money enters the plan, while the off-budget leg is uncategorized;
- card→cash, card→card, card→off-budget, off-budget→card, and any mismatched-currency pair are rejected in v1.

An imported transfer side is not automatically paired in v1. The register offers an explicit “Pair transfer” action that selects the other transaction and validates equal/opposite amounts, compatible accounts, same currency, and a fixed date window of **±7 calendar days**. This window is not user-configurable in v1. Both legs must fall in the same budget month; if they straddle a month boundary, the user must edit one date or the pairing is rejected. The on-budget leg's direct category event (for on↔off) and the synthetic payment-category event (§3.6, for cash→card payments) are therefore both emitted in the pair's single budget month. Pair creation, edit, unpair, and deletion are atomic. A complete pair is assigned status `complete` and replayed only as the single logical `TransferEvent` in §3.2. If a card-payment guard or other staging condition fails for either leg, the complete pair is staged atomically and no payment-category event is emitted; it is never legal to replay one leg while excluding the other. Editing one paired leg mirrors amount/date/account where valid; deleting one leg follows the imported/manual soft-void rules below. Unpairing restores each leg's immutable `TransferPairLegSnapshot` in the same transaction; if a leg has the `requiresUnpairResolution` marker rather than a standalone snapshot, it remains staged with `transferPairUnpairNeedsCategorization` until the user explicitly categorizes it. Unpairing never applies a positive-inflow/RTA sign default. Pair creation, unpairing, and deletion are recorded in `AuditEvent`. The mutation service, not a row-local SQLite `CHECK`, is responsible for the exactly-two-legs/equal-opposite invariant; the parent row prevents orphaned shared UUIDs.

Editing or deleting a transaction with dependents (refund linkage, transfer pair, or reconciliation membership) requires special handling:
- **Editing a transaction with a linked refund**: if the edit changes the amount, date, or category such that the refund no longer satisfies the §3.5.3 same-month/same-card/remaining-lot rules, the refund is atomically re-staged with the appropriate `stage_reason`. The user is warned before the edit commits.
- **Deleting a transaction with a linked refund**: an imported transaction is never physically deleted; the user-confirmed delete is a soft void (`posting_state = voided`) that retains its `SimpleFINImport` identity, and the linked refund is atomically re-staged. A manual transaction may be physically deleted only after explicit confirmation and only when it has no import identity, reconciliation membership, or dependent refund.
- **Deleting a transfer pair**: if either leg has a `SimpleFINImport` row or reconciliation membership, the operation atomically soft-voids both legs and sets `TransferPair.status = voided`; both import tombstones remain for deduplication. A pair consisting only of independent, unreconciled manual rows may be physically deleted after confirmation. A voided pair is excluded from logical replay but remains auditable.
- **Editing/deleting a transfer leg**: both legs are affected as specified above; if an edit breaks the equal/opposite invariant, the pair is unpaired and both legs restore their `TransferPairLegSnapshot` in the same transaction. A leg without a valid standalone snapshot remains staged with `transferPairUnpairNeedsCategorization` until explicit user categorization. Physical deletion uses the imported/manual rules above.
- **Changing transaction account**: an imported transaction's `account_id` is immutable; a manual transaction may change accounts only when it has no import identity, refund/transfer/reconciliation dependency, and both accounts are in the same budget/currency. A transfer pair is edited as a pair under the rules above; the mutation never leaves one leg on the old account.
- **Editing a transaction in a closed month**: rejected until the user explicitly reopens that month; reopen/correction/close is one audited workflow.
- **Editing a reconciled transaction**: rejected unless the user explicitly un-reconciles first and the month is not closed.
- **Editing a transaction with reconciliation membership**: the `ReconciliationTransaction` row is retained; the transaction's `cleared` state may change, which affects the next reconciliation's calculated balance. Physical deletion is blocked until the membership is undone.

### 3.9 Reconciliation

For any on-budget cash/checking/savings/credit-card account A and statement date D, using the immutable budget timezone:

1. Include all non-voided transactions for A with `date <= D` and `cleared in {cleared, reconciled}`. This includes `needsCategory` and staged rows because they are posted register items; remote pending rows were never imported. The calculated value is `clearedBalance(A, D)`, the **cleared register balance** (sum of `cleared` and `reconciled` rows only), not full `registerBalance` (which includes `uncleared` rows).
2. Store and display the statement balance in the account's normalized sign convention. For cash/checking/savings, a positive statement balance is money held. For a credit card, a negative statement balance is debt owed; a positive statement balance is an unsupported positive card asset and the reconciliation cannot complete in v1. The UI shows a sign/example beside the input.
3. Show `clearedBalance(A,D)`, the normalized entered statement balance, and `difference = statementBalance - clearedBalance`.
4. If different on a cash/checking/savings account, offer one adjustment transaction dated D with `kind = adjustment`, payee `Reconciliation Balance Adjustment`, and category `Inflow: Ready to Assign`; its signed amount is `difference` and it is included in signed `RTAActivity` (positive increases RTA, negative reduces RTA). A spending category must never be guessed for the adjustment.
5. If different on a credit-card account, offer one adjustment transaction dated D with `kind = adjustment`, payee `Card Debt Adjustment`, `category_id = null`, and amount `difference`. It changes the card register balance but emits no envelope/RTA/payment-category event. The mutation service computes `candidateProjection = projectionBalance(A) + difference` because the new adjustment is posted while existing staged rows remain excluded from projection; it permits completion only when `candidateProjection <= 0`. A staged row is not silently resolved by reconciliation and remains staged until its own explicit resolution.
6. On confirmation, create a `Reconciliation` plus `ReconciliationTransaction` rows only for transactions newly marked reconciled. Each join stores the canonical accounting fingerprint at that instant; transactions already marked reconciled remain reconciled and retain their earlier membership. The adjustment, when any, is included in the new reconciliation and its nullable `adjustment_transaction_id` and fingerprint are stored. All pair/card/state validations apply atomically.
7. Undo is allowed only for the most recent completed reconciliation, only if every newly marked transaction's current fingerprint equals its stored `transaction_fingerprint_at_reconciliation` and the generated adjustment's current fingerprint equals `adjustment_fingerprint_at_creation`. It removes reconciled state only from rows linked through `ReconciliationTransaction.was_newly_marked_reconciled`, deletes the generated adjustment if unchanged, marks the reconciliation undone, and leaves earlier reconciliation history intact. Reconciled transactions require explicit un-reconcile confirmation before editing.

Off-budget reconciliation is not part of the v1 UI; off-budget accounts remain register-only and any future reconciliation must be budget-neutral.

### 3.11 Split transactions

A split allocates one physical outflow across several spending categories. It is a category edit, not a new transaction: the row keeps its account, date, amount, payee, import identity, cleared state, and reconciliation membership; only `category_id` (null while split) and `splits` change.

Invariants (service-enforced, tested):

- Only `kind = normal`, non-positive rows on budget-eligible accounts may be split. Inflows point at RTA only; refunds, transfer legs, opening balances, and adjustments are never split. A split row cannot be paired as a transfer.
- At least two components; each component amount is nonzero with the parent's sign; the checked sum equals the parent amount exactly. The engine never adjusts a component to fix rounding; rule-created percentage splits use the largest-remainder method so the sum is exact by construction.
- Every component targets a `kind = spending` category. `Uncategorized` is permitted and leaves the row `needsCategory` (partial categorization).
- Replay emits one envelope event per component in component order. For a credit card each component gets its own provenance lot keyed by `(transaction, component index)`; the funded/credit split of §3.5.2 is computed per component.
- A linked card refund of a split purchase names `refund_of_component_index`; its materialized category is that component's category and its refundable cap is that component's lot. A refund without a component address whose origin is (or becomes) split, or whose component no longer exists, is staged `missingRefundOrigin` — the §3.8 origin-edit rule. Categorizing a split row to one category removes the split; dependent refunds drop their component address and follow the single category.
- Amount edits on a split manual row are rejected until the split is removed or re-entered; date, memo, payee, approval, and cleared edits are unaffected.
- Reports, the assistant, and schedule matching aggregate per component (`docs/DESIGN.md` D3.4); the register shows the parent once.

### 3.12 Schedules

A schedule is an *expected* event, never a transaction. Occurrences are stored only when matched, entered, or skipped; every other occurrence is derived from the recurrence rule. Matching links an existing row to an expected occurrence by a deterministic score (`docs/DESIGN.md` D5.3) and opens a Review Queue item when ambiguous; "Enter" creates a manual row through `addManualTransaction`/`createManualTransferPair` exactly once; nothing is created automatically. Projected balances add unmatched expected amounts to the register balance and are never part of replay, the oracle, or the register.

### 3.10 Worked three-month golden scenario

Use USD, one checking account, one credit card, categories `Rent`, `Dining`, `Groceries`, and one credit-card payment category. The credit card begins at -$200 with pre-existing debt and no payment-category funding.

January:

- Opening checking +$1,000 → RTA.
- Assign Rent $500, Dining $300, Groceries $100; RTA=$100.
- Pay Rent $500 from checking.
- Spend Groceries $150 from checking: Groceries ends at -$50 cash overspending.
- Spend Dining $350 on the card: Dining ends at -$50; $300 is funded and moves to the card payment category; $50 is credit overspending.
- Pay $300 from checking to the card: payment category returns to $0; checking ends at $50; card ends at -$250.

February:

- RTA starts at $50 because January cash overspending was $50; negative January categories reset to zero.
- Income +$500 → RTA=$550; assign Rent $300 and Dining $100 → RTA=$150.
- Pay Rent $300 from checking; spend Dining $100 on the card → Dining $0, payment category $100.
- Receive a $50 refund on the card linked to the Dining purchase → Dining $50, payment category $50.
- Pay $50 from checking to the card → checking $200, payment category $0, card -$250.

March:

- RTA starts at $150; Dining carries $50. Assign $50 to Dining → RTA=$100, Dining=$100.
- Spend Dining $150 on the card → Dining=-$50, payment category=$100, credit overspending=$50; checking remains $200, card becomes -$400.

At the listed month-end checkpoints, the conservation RHS includes **all** spending categories, not just Dining:

| Checkpoint | Cash-like assets | RTA | Rent available | Dining available | Groceries available | CC payment available | Credit overspending | RHS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Jan after assignments | 1000 | 100 | 500 | 300 | 100 | 0 | 0 | 1000 |
| Jan after rent | 500 | 100 | 0 | 300 | 100 | 0 | 0 | 500 |
| Jan after cash groceries | 350 | 100 | 0 | 300 | -50 | 0 | 0 | 350 |
| Jan after CC dining | 350 | 100 | 0 | -50 | -50 | 300 | 50 | 350 |
| Jan after CC payment | 50 | 100 | 0 | -50 | -50 | 0 | 50 | 50 |
| Feb after assignments | 550 | 150 | 300 | 100 | 0 | 0 | 0 | 550 |
| Feb after rent + card spend | 250 | 150 | 0 | 0 | 0 | 100 | 0 | 250 |
| Feb after refund | 250 | 150 | 0 | 50 | 0 | 50 | 0 | 250 |
| Feb after payment | 200 | 150 | 0 | 50 | 0 | 0 | 0 | 200 |
| Mar after card overspend | 200 | 100 | 0 | -50 | 0 | 100 | 50 | 200 |

The implementation test must include the full category set and the exact balances shown above; it must not use an abbreviated display row as the oracle.

---

## 4. SimpleFIN integration

### 4.1 Connection lifecycle and trust boundary

v1 supports one Access URL per budget. The Access URL may expose many institutions; `remote_connection_key` distinguishes them. No credential or Setup Token is written to the repository, SQLite, UserDefaults, logs, crash reports, or test fixtures.

1. The user pastes a Base64 Setup Token into a secure, non-persisting field.
2. Base64-decode it strictly to UTF-8 and parse it with `URLComponents`.
3. Before making the claim request, require `https`, a nonempty host, no userinfo, no fragment, and port 443 or the explicitly approved HTTPS port. Canonicalize the host to lowercase and require it to be the official `bridge.simplefin.org` host or a host the user explicitly added to the app's trusted-host list before claiming. Test/beta hosts are never implicitly trusted. The decoded URL is untrusted input; never POST to an arbitrary decoded host.
4. POST an empty body with `Content-Length: 0` to the validated claim URL. The response is plain text containing the Access URL.
5. Parse the returned Access URL with `URLComponents`. Its `.user` and `.password` properties are decoded views; do **not** percent-decode them a second time. Require nonempty decoded username and password, HTTPS, a nonempty host/path, no fragment, and a host/port on the approved list. Retain the returned `percentEncodedPath` as an opaque path prefix and retain its existing query items; do not reconstruct the URL by string splitting. If the returned host differs from the claim host, show the canonical host and require explicit user confirmation before storing it.
6. Build and store a structured credential object in one Keychain generic-password item: sanitized base host/port, opaque percent-encoded path prefix, existing query items, decoded username, decoded password, and approved host/port. SQLite stores only the Keychain item reference. The only permitted request paths are the exact returned prefix for diagnostics/health and that prefix with exactly one `/accounts` suffix; no other path is accepted.
7. For `/accounts`, append exactly one `/accounts` component to the opaque returned path prefix. Preserve existing query items byte-for-byte and reject a duplicate of any reserved request key (`start-date`, `end-date`, `account`, `balances-only`, `pending`, or `version`) rather than silently overwriting it; append only the adapter's validated values using `URLComponents`. Construct `Authorization: Basic <base64(UTF-8(username + ":" + password))>` explicitly. Never rely on URLSession to interpret embedded URL credentials. Redact the header and all URL userinfo in diagnostics.
8. Refuse all HTTP redirects. In `willPerformHTTPRedirection`, cancel instead of forwarding Basic Auth. Validate the destination of every request against the approved host/port and exact path-prefix allowlist before sending.
9. The Setup Token is single-use. Discard it immediately after a successful or terminal claim attempt. A claim `403` is shown as used/invalid/possibly compromised; an accounts `401`/`403` is shown as revoked/invalid access and requires a new claim flow. Do not conflate the two.

The URLSession delegate is defense in depth, not the only firewall. Every request validates its final URL independently. Requests use finite connect/resource timeouts and a bounded response body; oversized responses are aborted before decoding or logging. The URLSession configuration must use `.ephemeral` (or set `urlCache = nil` and `requestCachePolicy = .reloadIgnoringLocalCacheData`) to prevent full transaction payloads from being persisted to the on-disk URL cache outside the SQLite file. Add the cache-disabled configuration to the redaction test list.


### 4.2 Fetch and response compatibility

Before freezing Codable models, Phase 3 begins with a user-run capture command against the user's own account. The capture command must obtain its credential only from the app's Keychain or an interactive protected prompt; it must not accept an Access URL, Setup Token, username, password, or Authorization header in argv, shell history, ordinary environment variables, or source. The raw response is written only to a permission-restricted, gitignored temporary path; the implementation must never request, receive, or preserve the user's credentials or Access URL. The command emits a sanitized fixture with account IDs, names, descriptions, and amounts redacted or synthetic, then removes the raw capture file and any temporary unsanitized copy. Note: secure erasure is not guaranteed on APFS/SSD; the removal is best-effort file deletion, not cryptographic erasure. If a real capture is unavailable, the decoder gate and live-sync release gate remain blocked; the hand-authored documented-type fixture is for unit tests only. A fixture-only development shell may build with live sync disabled, but it cannot pass Phases 3–5 or the v1 Definition of Done until a sanitized real capture has exercised the deployed response shape.

Use `URLComponents` query items for `/accounts`. `start-date`, `end-date`, `balance-date`, and all posted epochs in the adapter are integer Unix seconds in UTC; date arithmetic uses checked `86400`-second units, never local-calendar subtraction. The supported query parameters are `start-date`, `end-date`, `account` (filter by account id), `balances-only` (return balances without transactions), and `pending` (include pending transactions). v1 never sends `pending=1` — pending rows are remote-protocol artifacts excluded by design, and the defensive decoding of `pending` in responses is belt-and-braces rather than the mechanism. The `version=2` parameter is sent only when the §4.2 capture determines it is required by the deployed Bridge; it is not treated as a universal server contract. For a recurring sync, the adapter sends `start-date = checked(last_successful_posted_epoch - 5*86400)` and omits `end-date` (equivalently, it may send the current UTC epoch); a request window is never defined in terms of its own response. `new_upper_bound` — the maximum valid normalized posted epoch observed in the response, or the prior cursor if no posted rows are returned — is the cursor-commit value derived from the response, not a request parameter. The adapter then locally filters rows by exact epoch rules before deduplication: recurring sync imports only `start < posted <= new_upper_bound`. The initial link is an explicit two-request sequence: first fetch the balance snapshot with `balances-only=1` to obtain `B` and its `balance-date` `T` (§4.4), then request history for the anchor interval ending at `T` and locally filter to `S < posted <= T`. If the endpoint treats `end-date` as exclusive, send `T + 1` (one UTC second) as that history request's upper bound; if it treats it as inclusive, send `T`. The fixture-backed adapter test must make this choice explicit. Never rely on endpoint boundary behavior alone. There is no pagination; narrow by account and date windows. The approximately 90-day history window and quota behavior are provider constraints, not assumptions the engine may silently expand.

The defensive decoder accepts both the deployed legacy shape and the documented 2.0.0-draft shape:

- decimal strings for `balance`, `available-balance`, and transaction `amount`;
- epoch integer values for `balance-date`, `posted`, and `transacted_at`;
- optional `available-balance`, `transactions`, `transacted_at`, `pending`, and `extra`;
- top-level `errlist` (draft 2.0.0) and `errors` (deployed); accept both without labeling either as deprecated, and let the §4.2 capture record which the deployed Bridge actually returns;
- draft `connections`/`conn_id` when present;
- legacy per-account `org` and its `id`, `domain`, `name`, `sfin-url`, and related fields;
- a distinct `payee` field when the deployed capture contains it, preferred for normalization, with `description` as fallback.

Unknown fields are ignored but raw `org` and `extra` are retained only in the sanitized model for troubleshooting. A posted transaction without a stable remote transaction ID is not imported; pause that account with a visible protocol error rather than inventing a collision-prone identity. Derive `remote_connection_key` from `conn_id`, otherwise normalized `org.id`, otherwise normalized `org.domain`. Detect duplicate `(remote_connection_key, remote_account_id)` identities in one response or across links and pause rather than merging accounts. If a valid legacy `org` has only `name` and no stable ID/domain, pause and require the user to approve a stable key derived from canonicalized org JSON; never silently use a mutable display name.

For every linked credit card, the onboarding UI displays a representative balance and transaction sign sample and requires the user to confirm the normalization direction. Store `amount_sign_normalization` in `SimpleFINLink`: multiply raw balance and amounts by `+1` for the normal convention or `-1` for an inverted provider convention so purchases become negative, refunds/payments positive, and debt balances non-positive. If the direction cannot be confirmed, pause the link. For checking/savings/cash, require the normal convention (inflows positive, outflows negative) in v1.

### 4.3 Sync and import review flow

- Initial history request: up to 90 days, or the maximum supported window, ending at the returned `balance-date` `T`; local filtering uses the exact `(S,T]` rule in §4.2.
- Later requests start at each linked account's last successful posted epoch minus five days. Cursor advances only after that account's posted imports, staged rows, remote metadata, and account-state updates commit successfully.
- Remote rows marked `pending` by SimpleFIN are intentionally not imported in v1 because their IDs, amounts, and dates can change when posted. They are counted in the sync result as ignored remote-pending rows and will be reconsidered on a later posted response; there is no local budget/register row for them.
- Track all-account and individual-account request timestamps separately. v1 enforces a minimum 24-hour interval for an automatic all-account refresh unless the user taps “Sync Now”; manual sync is still subject to HTTP 429/`Retry-After` and never bypasses a server refusal. Handle HTTP 429 and `Retry-After` as authoritative. `Retry-After` may be either an integer number of seconds or an HTTP-date; parse both forms.
- Sync is single-flight. Network work occurs outside the database write transaction; a single mutation service then commits each account's imported posted rows, staged rows, remote metadata, cursor, and last-seen state atomically.
- Every imported posted transaction gets a `SimpleFINImport` row before the account commit completes. `remotePending` is a protocol field, not a local `posting_state`.
- Import classification follows this ordered decision list (first match wins):
  0. **Future posted date**: if normalized `posted` converts to a future budget date, do not insert a transaction or `SimpleFINImport`; pause the link with `pause_reason = futurePostedEpoch`, record a redacted sync error, and do not advance that account cursor.
  1. **Currency mismatch**: if the account currency differs from the budget currency, import as off-budget, no category.
  2. **Closed-month append**: if normalized `posted` converts to a budget date in a `ClosedMonth`, append the new remote row as `staged` with `stage_reason = closedMonthImport`, no category, and no automatic card/refund reclassification. It is included in that account's register, excluded from projection, and the cursor may advance after this append-only account commit. Existing closed-month rows are never modified by this pass; after an audited reopen, the normal replay/re-staging workflow may resolve them.
  3. **Card guard/staging**: if the account is an on-budget credit card and the row would make `projectionBalance` positive, or is an oversized/cross-month/missing-origin refund, or is an unlinked positive card inflow → `staged` with the appropriate `stage_reason`, no category. For any staged-row resolution guard, `projectionBalance` is recomputed as if that row were posted; the staged row's register-only inclusion is not used as the guard input.
  4. **Transfer detection**: not automatic in v1; proceeds as a normal row (step 5–6).
  4½. **Automation rules** (`docs/DESIGN.md` D4): enabled rules run once here, in order, against the raw `imported_description`; a rule category replaces the defaults of steps 5–6, a rule split replaces the category, a rule payee rename keeps the raw description. Rules never run on the closed-month append of step 2, never change amounts/dates/identity, and every application is audited. The same pass runs for file imports (D6).
  5. **Payee auto-categorization**: normalize `payee` using NFKC + uppercase + whitespace collapse. If an exact normalized payee with a `last_used_category_id` exists, auto-categorize only when the referenced category is visible (`hidden = false`), belongs to this budget, is not `cc_payment`, and its category kind matches the sign: positive amount → `kind = inflow`; non-positive amount → `kind = spending`. Set `posting_state = posted`, `approved = false`. A normal non-positive row can never be assigned to the RTA/inflow category, and a normal positive row can never be assigned to a spending category. If the remembered category is hidden, system-ineligible, or sign-incompatible, fall through to the sign default.
  6. **Sign default**: if no auto-categorization matched, for a non-positive on-budget amount set `posting_state = needsCategory`, `category_id = Uncategorized`, `approved = false`; for a positive on-budget amount set `category_id = Inflow: Ready to Assign`, `posting_state = posted`, `approved = false`. Off-budget rows remain register-only with no category.
- When the user explicitly categorizes or recategorizes a normal transaction to a visible, non-system, sign-eligible category, update that payee's `last_used_category_id` in the same mutation. Do not update it for `Uncategorized`, RTA, `cc_payment`, hidden/system categories, staged rows, or automatic fallback. This makes future auto-categorization deterministic and auditable.
- Unapproved posted transactions still affect the budget; approval is a workflow flag, not an accounting filter. The user may explicitly toggle `approved` for a non-voided, non-closed-month transaction; sync never changes a user-approved flag, and automatic import fallback leaves it `false`. Approval changes no amount, category, posting-state, or projection value and is recorded in the audit/revision stream.
- An imported posted card row that would make the `projectionBalance` positive, is an oversized/cross-month/missing-origin refund, or is an unlinked positive card inflow is stored with `posting_state = staged`, a precise `stage_reason`, and no category. It affects the account register, is excluded from the envelope projection, and is visible in the Staged/Needs Resolution filter.
- A staged row may be resolved only by (a) linking a valid same-month refund origin and satisfying the remaining-lot rule, (b) explicitly reclassifying it to a budget-neutral `Card Debt Adjustment` while `projectionBalanceAsIfResolved({row})` remains `<= 0`, (c) explicitly resolving a `crossMonthRefund` row through the §3.5.3 recovery path — positive RTA activity plus the offsetting synthetic negative payment-category event — while `projectionBalanceAsIfResolved({row})` remains `<= 0`, or (d) explicitly pairing it with a matching imported outflow from another linked account as a transfer under §3.8, which clears both categories, validates the debt guard, and emits the payment-category synthetic event. All four are reclassifications of existing rows unless the user is creating a genuinely new manual transfer; no existing staged row is inserted a second time. Resolution is an atomic mutation, leaves `registerBalance` unchanged for reclassified rows, and is recorded in the audit log. If none are valid, it remains staged; sync never drops it.
- If a previously seen composite remote identity changes amount, date, payee, or raw payload hash, update only a row that is untouched, `needsCategory`, and not user-edited. For posted/approved/reconciled/staged or user-edited rows, retain the local row and create a `SyncConflict` with old/new sanitized metadata; never overwrite user-owned fields.
- v1 does not automatically match imported rows to manual rows and does not automatically pair transfers. Manual transactions are allowed on linked accounts and carry `source_kind = manual`; the user can explicitly pair two already-imported sides under §3.8, no silent merge is allowed. If a later SimpleFIN row appears to duplicate a manual row (same account/date/amount after normalization), retain both physical rows, create a `SyncConflict` with `event_kind = manualPotentialDuplicate`, and offer explicit user choices: keep both, soft-void the imported row, or delete/void the manual row subject to reconciliation/dependency rules. Snapshot discrepancies remain open until the user resolves the duplicate or confirms the difference; the sync engine never guesses.
- **Re-staging pass**: after every mutation touching affected months — including sync commits, allocation changes (`setBudgeted`/`moveMoney`), transaction insert/edit/delete, refund link/unlink, transfer pair changes, and category recategorization — the mutation service runs a deterministic replay pass **inside the same `DatabasePool.write` transaction** over eligible unclosed affected months. The closed-month gate runs first: existing rows in a closed month are not re-staged or reclassified; a new remote row in such a month is appended only as `closedMonthImport` by the sync-specific exception in §2.1, and the account cursor commits with it. A previously `posted` row that the replay finds violates a staging condition (e.g. a backfilled card purchase created `creditDebt` in a category where a later `posted` cash inflow now sits) is re-classified to `staged` with the appropriate `stage_reason`. A previously `staged` row whose staging condition no longer applies (e.g. the user assigned money eliminating `creditDebt`, or the user linked a valid refund origin) is re-classified to `posted` (or `needsCategory` if uncategorized). Before the forward pass, the replay builder groups complete `TransferPair` rows into the atomic logical events in §3.2; therefore pair staging never removes an earlier leg after an intervening event has been evaluated. **Transfer-pair atomicity**: if either leg of a `TransferPair` is re-staged, both legs are staged atomically (or the pair is unpaired and both legs restore their `TransferPairLegSnapshot`; a leg without a standalone snapshot remains staged with `transferPairUnpairNeedsCategorization`). A re-staged pair emits no payment-category synthetic event. The pass is a single forward pass over logical standalone rows and `TransferEvent`s in §3.2 replay order; it does not iterate to a fixpoint (rehabilitating a logical event only affects positions after it, and pair grouping is rebuilt before the pass). The pass is idempotent: running it twice is a no-op. This pass is an explicit mutation-service step, not a side effect of the projection. It must complete before the UI refreshes and before the snapshot comparison in §4.4. Re-staging a `reconciled` row is permitted silently for `posting_state` (register and `clearedBalance` math are unaffected since staged rows are included in both), but the `cleared` value is unchanged.
- A remote row that disappears from a later **successful response for the same `(connection_id, remote_connection_key, remote_account_id)` within the requested overlap interval** (reversal, re-posting after pending, or provider data correction) is retained locally and never auto-voided. The mutation service creates a `SyncConflict` with status `open` and sanitized old/new metadata so the user can decide whether to void, edit, or keep the local row. Absence outside that account/window, a failed/partial response, or a cursor overlap that was not successfully fetched is not treated as disappearance.

### 4.4 Initial-link balance algorithm

Never set an account's opening balance to the snapshot balance and then add the same period's transactions.

For a **new local account with no existing transactions**:

1. Fetch a balance snapshot `B` with `balance-date = T` and posted-only semantics for the linked account (the `balances-only=1` first request of the §4.2 two-request sequence), then fetch posted transaction history for a requested interval `(S_requested, T]`. Both initial-link requests use `pending=0`; before accepting `B`, the capture/decoder must establish that the provider's balance excludes pending activity. If the deployed response cannot establish posted-only semantics, automatic snapshot-minus-history linking is blocked and the user must enter a known posted balance under option (a). Set the effective anchor `S = max(S_requested, start of budget.first_month)` using the immutable budget timezone. If this truncates history, show the user the interval and require confirmation.
2. Exclude remote-pending rows, rows with `posted = 0`, and rows outside `(S,T]`. Normalize all amounts using the link's confirmed sign direction.
3. SimpleFIN does not certify that an institution returned a complete history. If completeness is unknown or the response indicates missing data, stop automatic linking and require one explicit user attestation. The user chooses exactly one branch:
   - **Option (a) — user-entered opening balance**: enter a known opening balance `O` at `S`; use `O` as the opening-balance transaction amount and import all posted rows in `(S,T]`. The resulting register balance is `O + Σ(posted (S,T])`, which may differ from `B`. Create a `SnapshotDiscrepancy` for the difference and mark the account `history_incomplete = true`.
   - **Option (b) — snapshot-minus-history opening**: authorize the app to compute `opening = B - Σ(normalized posted amounts in (S,T])` and use that as the opening-balance amount. The resulting register balance equals `B` exactly. Mark the account `history_incomplete = true` to indicate the opening is derived, not user-attested.
   If completeness is evidenced by the capture/protocol and the requested interval is accepted as complete, use option (b) without the attestation but still show the computed opening and interval. The app must never label the result “complete 90-day history” without evidence.
4. Compute the opening amount exactly once from the selected branch: `O` for option (a), or `B - Σ(normalized posted amounts in (S,T])` for option (b). Do not set the opening to `B` and then add the same transactions.
5. Create one opening-balance transaction at `S`, then import every posted transaction with `S < posted <= T` in one database transaction. For option (b), the resulting local **posted register balance** is exactly `B` without double-counting. For option (a), the resulting register balance is `O + Σ(posted (S,T])`, which may differ from `B`; the `SnapshotDiscrepancy` is created in the same commit. Staged card rows are included in the register balance, even though they are excluded from the budget projection.
6. An opening of either sign on an on-budget non-card account is categorized to RTA as signed activity; a negative derived opening is an overdraft that reduces RTA. A negative credit-card opening is allowed as pre-existing debt with no category/payment movement. A positive credit-card opening pauses the `SimpleFINLink` with `pause_reason = positiveCardSnapshot`; it cannot be silently normalized into v1.
7. Set the per-account cursor to `T` only after the opening row, imports/staged rows, link metadata, and import identities commit successfully. A staged positive-card row or unresolved snapshot does not block cursor advancement, but it leaves the link paused and visible.

For an existing local account with any transaction but no SimpleFIN cursor/link, v1 refuses automatic first linking: there is no safe matching primitive for the user's manual history. The user must create a new local account for the link or deliberately rebuild the local account after exporting it. An account already linked with a cursor uses the cursor path. After each sync, compare the latest normalized snapshot with `registerBalanceAsOf(account, T)`: sum all non-voided `posted`, `needsCategory`, and `staged` local rows whose replay-order effective timestamp is `<= T` (imported rows use `effective_at_epoch`; manual rows use immutable-budget-timezone date-noon). v1 rejects/quarantines future-dated rows before they become local rows, so this cutoff is also a defensive invariant. Create a `SnapshotDiscrepancy` when they differ. For a cash account, the user may confirm a signed RTA adjustment; for a credit card, the user may confirm a budget-neutral `Card Debt Adjustment` only if the normalized `projectionBalance` remains `<= 0`. If either adjustment would cross a card above zero, pause the link and leave the discrepancy open.

### 4.5 Error behavior

- `402`: Bridge payment required.
- `403` on claim: token already used, invalid, or compromised; require a new token.
- `401` or `403` on accounts: credential revoked/invalid; require a new Setup Token. Preserve the distinction in the UI.
- Decode and display both `errlist` and legacy `errors`.
- Redact credentials from all errors, URLs, request descriptions, and logs. Unit-test that the username/password and full Access URL never occur in captured logs.

### 4.6 Keychain

Use one generic-password item with:

- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`;
- `kSecAttrSynchronizable = false`;
- `kSecUseDataProtectionKeychain = true`;
- stable service/account identifiers.

If a background wake occurs while Keychain access is unavailable/locked, skip sync and retry on activation/foreground. Do not store Setup Tokens in UserDefaults, SQLite, logs, crash reports, or source. Disconnecting a SimpleFIN connection has two levels:
- **Unlink a single account** (`SimpleFINLink.status = paused`): pauses sync for that account only, retains the Keychain item and import/cursor identity, and preserves the ability to re-activate. The local ledger (transactions, categories, imports) is never deleted.
- **Disconnect the entire connection**: after explicit confirmation, delete the Keychain item, set `SimpleFINConnection.status = disconnected` and `keychain_item_ref = null`, pause all associated `SimpleFINLink` rows, and preserve the local ledger, `SimpleFINImport` rows, and cursors as tombstones. A later reconnect reuses the same `SimpleFINConnection.id`, replaces the Keychain item, increments `credential_generation`, and does not create a second connection row. When the fetched remote identity matches an existing paused link, reactivate that same `SimpleFINLink` and preserve its local account, import identities, and cursor. If the remote identity is genuinely new, create a new link and require a new local account rather than reusing an account whose old link still owns it; the old link remains paused and auditable. Reconnecting never deletes or recreates transaction/import identity solely because credentials changed.

Note: `kSecUseDataProtectionKeychain = true` on macOS requires an `application-identifier`/`keychain-access-group` entitlement; ad-hoc signing (`CODE_SIGN_IDENTITY=-`) commonly yields `errSecMissingEntitlement` (-34018). Phase 3 must spike the Keychain round-trip under ad-hoc signing first and pre-authorize a fallback (dev-signed build) rather than improvising one later. A file-based keychain wrapper is permitted only in test targets with synthetic credentials; production builds must use the real Keychain with a correctly signed build.

---

## 5. Native macOS UI

### 5.1 Menu bar

Use `MenuBarExtra` with `.menuBarExtraStyle(.window)`. The popover is intentionally read-only to avoid first-responder and dismissal problems in a menu-bar text form. It shows:

- current-month RTA, total assigned, activity, and needs-category/staged counts;
- sync state, last successful sync, and the actual last error summary;
- “Sync Now”;
- “Open LedgerBar”;
- Settings;
- Quit.

Set `LSUIElement = true` in Info.plist. Use the SwiftUI `openWindow` environment action to open the full window, then call the current macOS `NSApplication.shared.activate()` API where available; avoid deprecated `activate(ignoringOtherApps:)` and avoid activation-policy toggling unless the implementation proves it does not flicker.

### 5.2 Full window

Use a native `NavigationSplitView`:

- Accounts sidebar with account register balances, needs-category/staged counts, and closed state; per-account rename and close (§2.1 close guard) actions, and a toggle to show or hide closed accounts, also offered as a row at the end of the account list whenever a closed account exists. Closing an account (plain close or void-history close) settles that account's open review items in the same mutation: sync conflicts become `dismissed` and snapshot discrepancies are resolved with `resolution_reason = manualAttestation` and no adjustment, each with an `AuditEvent` whose metadata carries `cause = accountClosed`. The ledger does not change. Items left open on an account closed before this rule existed are shown in the Review Queue with a single dismissal action that applies the same settlement. Sync skips any link whose local account is closed, leaving the workspace and cursor untouched, so a closed account never receives imports or new review items.
- Category groups and categories with Budgeted, Activity, and Available; current-month “Move Money…” action with source/destination validation, including payment-category sources and an explanation when assigning to a credit-overspent category retroactively funds card spending.
- Current and historical month navigation; future months are visibly read-only in v1.
- Transaction register with search, filters, category-required validation, posting state, cleared state, approval, manual transfer pairing, and reconciliation.
- Transaction sheets for adding, categorizing, editing, refunding, and reconciling transactions; existing-row transfer pairing remains an explicit register action.
- Review Queue destination for open balance discrepancies and sync conflicts, with explicit resolution actions and redacted diagnostics.
- Onboarding content in the main window; a separate Settings scene with SimpleFIN and Backup tabs.

### 5.3 Accessibility and formatting

Support VoiceOver labels, full keyboard access, Increase Contrast, dark mode, and native macOS focus behavior. Do not mention iOS “Dynamic Type.” Use `NumberFormatter` with the budget currency and user locale for display/input, set `generatesDecimalNumbers = true`, and then perform checked Decimal→milliunit conversion.

### 5.4 Account/category lifecycle

- A category with nonzero positive available cannot be hidden/archived until the user moves its money to another category or RTA first. Hidden categories remain in historical calculations. Non-system categories support hide/archive only; physical deletion is never used.
- System categories cannot be deleted, hidden, or renamed.
- An account cannot be closed with a nonzero register balance or needs-category/staged rows; the sole exception is the explicit positive-card off-budget-successor workflow in §3.5.3, which atomically records the successor, migrates the link/cursor, creates the audited migration opening, marks the old account closed/excluded from projection, and preserves its staged/import history.
- The `on_budget` flag of an account is immutable after creation in v1. Toggling it would invalidate historical projections. An off-budget account that should become on-budget (or vice versa) must be closed and a new account created; currency-mismatch `budgetEligible` is derived as specified in §2.3 and does not mutate this flag.
- Deleting a payee replaces its display name with `Deleted Payee` but never changes transaction amounts/categories.
- Reconciled rows require explicit un-reconcile confirmation.

---

## 6. Technical architecture and build system

### 6.1 Stack

- Swift 6 with strict concurrency.
- SwiftUI, macOS 15+ (Sequoia).
- SQLite through GRDB 7.11.1, the only runtime third-party dependency. Pin the exact GRDB version as `.exact("7.11.1")` in `Package.swift` and record the resolved revision in `Package.resolved`; review dependency updates separately. `DatabasePool` is Sendable/thread-safe and is passed directly; do not wrap it in a needless actor.
- Hand-rolled SimpleFIN client using URLSession.
- Keychain Services.
- Swift Testing with `@Test`/`#expect`.
- Deterministic test PRNG (for example SplitMix64) implemented in the test target; Swift Testing itself is not property-based.
- `ValueObservation` bridged manually into `@Observable` view models; do not add GRDBQuery because the runtime dependency budget is intentionally one library.

### 6.2 Build layout

Use a Swift Package for the headless core plus an XcodeGen-generated app project. The package/app boundary is explicit:

```
LedgerBar/
├── Package.swift                 # LedgerCore product + LedgerCoreTests; GRDB dependency
├── project.yml                   # XcodeGen source; never hand-author pbxproj
├── LedgerBar.xcodeproj            # generated by xcodegen
├── Sources/
│   └── LedgerCore/
│       ├── Database/
│       ├── Budget/
│       ├── SimpleFIN/
│       └── Security/
├── Tests/
│   └── LedgerCoreTests/
├── LedgerBar/
│   ├── App/                       # LedgerBarApp, Info.plist, entitlements
│   ├── UI/                        # menu bar, onboarding, budget, register, Review Queue, sheets, settings
│   └── Resources/
├── LedgerBarTests/                # app-host integration tests, including Keychain/entitlements
├── Config/
│   └── LocalSigning.xcconfig       # local-only DEVELOPMENT_TEAM/bundle signing; never contains credentials
└── Tools/
    └── xcodegen-version.txt        # exactly 2.46.0
```

`project.yml` consumes the local `LedgerCore` package product; app-only SwiftUI code is not duplicated in the package. `xcodegen` is a development/build tool, not a runtime dependency; require `xcodegen --version` to report exactly `2.46.0` before generation and fail otherwise. Keep `Config/LocalSigning.xcconfig` local or template it with a non-secret team identifier; it must not contain passwords, tokens, or API keys. Regenerate the project in CI rather than editing the generated project by hand.

The plan must give these verification commands:

```bash
swift --version
xcodebuild -version
xcodegen --version                         # must be exactly 2.46.0
swift test --package-path .
xcodegen generate
xcodebuild -project LedgerBar.xcodeproj -scheme LedgerBar \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedDataUnsigned \
  CODE_SIGNING_ALLOWED=NO build
# Compile-only ad-hoc check; it is not sufficient for Keychain access-group tests.
xcodebuild -project LedgerBar.xcodeproj -scheme LedgerBar \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedDataAdHoc \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
# Required development-signed host/entitlement gate. LocalSigning.xcconfig supplies DEVELOPMENT_TEAM.
xcodebuild -project LedgerBar.xcodeproj -scheme LedgerBar \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedDataDevSigned \
  -xcconfig Config/LocalSigning.xcconfig \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY='Apple Development' test
```

`Package.swift` must use `.exact("7.11.1")`; `Tools/xcodegen-version.txt` must contain `2.46.0`; CI must fail on version drift. The development-signed host test is the only gate that may claim Keychain access-group/Data Protection behavior was exercised. Signing identity changes invalidate previously stored Keychain items, so the test instructions must use a clean test account/keychain fixture. If `Config/LocalSigning.xcconfig` or a development team is unavailable, the unsigned/ad-hoc checks may run but the signed host gate remains **blocked**, not passed.


### 6.3 Database and query shape

All schema migrations are explicit GRDB migrations. Every child table has `budget_id` and a composite/ordinary FK as appropriate. Migrations `v10`–`v15` (splits/imported description/file source, automation rules, file import, reports, schedules, app settings) are additive; the `transactions` mirror was rebuilt once (v10) to admit `source_kind = 'file'`. The database may hold several budgets (D8); the loaded `BudgetWorkspace` is always exactly one of them, mirror identities that were global sentinels are scoped by budget, and `app_settings.activeBudgetID` records the active one. SQLite row-local `CHECK` constraints/triggers enforce enum values, Int64-range/storage bounds, unique allocation/import identities, foreign keys, one `cc_payment` category per credit-card account, system-category immutability, and parent/child transfer/reconciliation references. `MonthlyCategoryAllocation.budgeted_milliunits` intentionally has no unconditional SQL `>= 0` check because an audited negative row is legal only as the result of `moveMoney`; the mutation service enforces that provenance, while `setBudgeted` inputs remain nonnegative. The mutation service also enforces derived or cross-row rules that SQLite cannot express in an ordinary `CHECK`: no positive normalized credit-card balance, valid card payment amount, exactly two equal/opposite transfer legs, category-required matrix, staged-resolution rules, and month-aware conservation. The plan must label each rule as SQL-enforced or service-enforced rather than claiming a cross-row `CHECK`.

Required schema-level rules include:

- unique `(budget_id, category_id, month)` allocations;
- one `cc_payment` category per credit-card account;
- `SimpleFINImport` composite identity;
- `TransferPair` and `ReconciliationTransaction` foreign keys;
- nullable payee/category only for the explicit off-budget/opening/transfer/staged/adjustment exceptions;
- `voided` rows excluded from projection by the query layer and mutation service;
- a `flag_color` column if the UI exposes flags;
- a monotonic budget `revision` incremented by every mutation;
- per-month projection checkpointing: the projection engine caches the carry-in state (RTA, per-category available, per-card state) at the end of each month. On mutation, invalidate checkpoints from the earliest affected month forward and replay from that checkpoint rather than from `first_month`. This prevents a full multi-year replay after every keystroke-level allocation change;
- `stage_reason`, sanitized stage metadata, link pause state, account history-incomplete state, sync conflicts, snapshot discrepancies, and trusted-host records.

Add indexes on `transactions(account_id, date, effective_at_epoch)`, `transactions(category_id, date)`, `transactions(posting_state, date)`, allocation identity, reconciliation membership, transfer pair IDs, conflict/discrepancy status, and all SimpleFIN composite identity columns. Physical category deletion is not used: categories are hidden/archived so historical foreign keys remain valid.

The production budget projection batch-loads allocation rows and posted transaction rows for the required horizon, folds them in its own `BudgetProjection`/`BudgetEvent` implementation, and memoizes a projection keyed by budget revision/month. The test target separately builds the `ReferenceModel`; production code must not import or call test/reference types. A write invalidates the revision. Add a performance test with multi-year data and 50 categories; do not issue one query per cell.


### 6.4 Concurrency

A single `actor BudgetMutationService` is the sole coordinator for budget writes and user mutation intents. It accepts `Sendable` commands, serializes them in arrival order, and uses GRDB `DatabasePool.write` transactions for each atomic mutation; views and sync code never write directly. Network requests run outside the database transaction. A single-flight `actor SyncCoordinator` hands normalized remote rows to the mutation service, which commits each account's import/cursor update atomically. If a user edit commits while a fetch is in flight, the later sync commit may add new remote rows but may not overwrite user-owned category, memo, payee, flag, approval, cleared, or reconciliation fields. Changed remote metadata becomes a conflict warning rather than silent overwrite. The affected-month replay/re-staging pass runs **inside the same `DatabasePool.write` transaction** as the triggering user mutation or per-account sync commit, before the cursor/revision is committed and before success is returned. A sync pass examines only newly inserted/changed rows plus their dependency closure for that account; it does not sweep unrelated historical months. Closed-month rows are skipped except for the explicit append-only `closedMonthImport` insertion rule, and the cursor advances only if that bounded transaction, including re-staging, commits successfully. The service emits an observation refresh only after commit.

ValueObservation updates open registers after a committed write. Sync-on-launch, sync-on-activation, and wake notifications use elapsed-time checks; a six-hour `Timer` alone is not a dependable scheduler across sleep/App Nap. DatabasePool is passed directly to services because it is Sendable; do not invent a second database actor that can reorder writes.


---

## 7. Security, export, and backup

### 7.1 Security

Use App Sandbox, Hardened Runtime, and these entitlements:

- `com.apple.security.app-sandbox`;
- `com.apple.security.network.client`;
- `com.apple.security.files.user-selected.read-write` for user-selected export/backup destinations;
- `keychain-access-groups` containing only the app's designated application access group. The signed product must also expose the matching `application-identifier` supplied by the signing identity; the entitlement/Keychain host test runs `codesign -d --entitlements :-` and verifies that the Keychain item is accessible only under that designated group, not under an arbitrary app.

Validate every claim/access URL and refuse redirects as specified in §4.1. “No data leaving the machine” means no automatic telemetry or LedgerBar server; user-selected backup destinations may be iCloud Drive. The local SQLite file is unencrypted and relies on FileVault for at-rest protection.

### 7.2 CSV export

CSV import/export is v1.1. Do not create a partial export surface in v1 or claim compatibility with an external budgeting format without a tested format.


### 7.3 Backup

Provide a consistent SQLite backup using GRDB `backup(to:)` to a new temporary path inside the app's container while all domain writes are quiesced (ValueObservation subscriptions torn down, no concurrent writes). The flow must create a destination `DatabaseQueue` at the temp path, then `try sourceWriter.backup(to: destQueue)`. `backup(to:)` is preferred over `VACUUM INTO` because it produces a consistent snapshot with explicit WAL handling. The temporary destination must not already exist. Run SQLite `PRAGMA integrity_check` on the temporary database after the backup completes. Only after verification should the app use the user-selected `NSSavePanel` destination and a coordinated copy/replace; do not claim a cross-volume rename is atomic. The backup is an unencrypted SQLite file; warn the user to protect the selected destination with FileVault/access controls. Restore UI is v1.1; a future restore must tear down observations and remove/recreate `-wal`/`-shm` sidecars safely. A documented manual restore procedure is required for v1: the README must describe closing the app, placing the backup SQLite file in the Application Support directory (removing any existing `-wal`/`-shm` sidecars first), and relaunching. The app must detect a replaced database on launch (via a stored file modification timestamp or schema version check) and rebuild ValueObservation subscriptions from scratch.


---

## 8. Definition of done for v1

The user can:

1. Launch the native menu-bar app and complete first-run onboarding.
2. Create a single-currency local budget with default categories and an immutable timezone.
3. Claim one SimpleFIN Setup Token through a validated HTTPS host and store credentials only in Keychain.
4. See linked accounts, confirm credit-card sign direction, map them to local accounts, and reject mismatched currencies/positive-card states.
5. Perform the anchor-date initial link without double-counting and verify the snapshot balance or complete the explicit incomplete-history attestation.
6. Sync posted transactions with composite-key dedup, per-account cursors, request error handling, Needs Category and Staged/Needs Resolution register filters, and a Review Queue for open balance discrepancies and sync conflicts.
7. Categorize imported rows, create manual transactions, assign/reallocate the current month's income, and see derived Budgeted/Activity/Available/RTA values.
8. Use deterministic credit-card automation for funded spending, credit overspending, linked refunds, and supported negative-debt payments. Unsupported positive-balance/cash-advance/card-to-card operations are visibly staged/rejected.
9. Create/edit/delete/unpair explicit same-currency transfer pairs.
10. Reconcile a cash account or a still-negative credit card using statement-date membership and deterministic adjustment rules.
11. Sync after launch, activation, and wake when the elapsed-time threshold requires it.
12. Produce a verified local SQLite backup.
13. Pass Milestone 0 headless tests and all three exact `xcodebuild` verification commands in §6.2 (unsigned build, ad-hoc build, development-signed host test). Per §6.2, an unavailable signing team leaves the signed gate blocked, not passed, and v1 is therefore not done.


## 9. Required tests

Before UI work:

- signed amount parsing with explicit rounding mode and checked Decimal→milliunit conversion;
- checked replay arithmetic overflow handling;
- immutable budget timezone epoch-to-date conversion;
- RTA base case, signed RTA activity, monthly recurrence, negative RTA, and cash-like underfunding carry;
- category recurrence with positive carry and negative reset;
- cash overspending, credit overspending, payment-category underfunding, and mixed cash-first overspending;
- funded credit-card purchase → that card's payment category;
- multiple cards isolated from each other;
- negative-debt opening balance with no automatic payment funding;
- linked same-month refund reversal with credit-first remaining-lot consumption; partial/mixed/full refund, cross-month staging and its §3.5.3 recovery resolution (positive RTA activity plus the offsetting synthetic payment-category event, including the `paymentCashDebt` clawback case, asserted against the conservation oracle), repeated over-refund staging, and unsupported unlinked positive card inflow;
- staged-row resolution as a budget-neutral Card Debt Adjustment and rejection/staging when it would cross zero;
- supported cash→card payment and rejection/staging of overpayment/crossing zero;
- rejection of card→cash, card→card, off-budget→card, and mismatched-currency transfers;
- on↔on and on↔off transfer pairing, edit/delete/unpair atomicity;
- opening balance reconstructed as snapshot minus imported net activity;
- incomplete-history attestation, budget-first-month anchor constraint, and nonempty-existing-account refusal;
- posted imported outflow without selected category uses immutable `Uncategorized`, posted imported positive inflow defaults to RTA/unapproved, and both remain in the projection; remote-pending protocol rows are ignored/re-fetched rather than stored;
- SimpleFIN composite dedup, changed-remote-row conflict, staged-row persistence/resolution, legacy/draft decoder compatibility, `errlist`/`errors`, optional fields, payee fallback, duplicate-identity detection, and org-key fallback;
- URL/host/redirect/credential-redaction/sign-normalization tests;
- Keychain behavior through a protocol-based fake and the development-signed app-host test per §6.2; the ad-hoc-signed round-trip is the §4.6 spike, whose expected outcome may be `errSecMissingEntitlement`;
- reconciliation membership, posted/staged register inclusion, remote-pending exclusion, adjustment, undo, lock behavior, and credit-card nonpositive guard;
- backup `integrity_check` and sidecar/quiescence behavior;
- deterministic randomized reference-model test over N operation sequences within the supported state space;
- the exact three-month golden scenario in §3.10 plus every §3.7 micro-golden.

The conservation test uses the exact §3.7 oracle. It must not substitute the false invariant that sums negative credit-card liabilities or omits the credit-overspending term. Unsupported operations must be tested as rejected/staged, not forced through the model.


## 10. Deliverables

1. `Package.swift`, `project.yml`, generated Xcode project, Swift sources, Info.plist, entitlements, and README.
2. GRDB migrations and schema documentation with all fields/constraints/indexes.
3. Headless `LedgerCore` budget projection and tests passing before UI.
4. Native macOS menu-bar and full-window SwiftUI app.
5. SimpleFIN client with host validation, explicit Basic Auth, no redirects, defensive legacy/draft Codable models, sign-normalization confirmation, and sync actor.
6. Hand-authored fixture matching documented types plus a one-command capture script the user can run against their own account. The real captured fixture is user-provided; it must never be fabricated.
7. Verified local SQLite backup.
8. A final verification report containing actual `swift test`, `xcodegen generate`, and the output of all three §6.2 `xcodebuild` commands (unsigned build, ad-hoc build, development-signed host test). If no development team is available, the report must state the signed gate as blocked, not passed. Do not claim success without those outputs.


## 11. Implementation plan required before coding

Produce a file-by-file implementation plan before writing application code. It must contain:

### Milestone 0 — headless correctness gate
- schema for `LedgerCore`;
- signed money parser with explicit rounding/overflow behavior;
- reference replay projection;
- RTA recurrence, category recurrence, overspending buckets, and current-month move-money;
- exact supported negative-debt credit-card event algorithm and rejection paths;
- conservation oracle;
- golden/micro-golden scenarios and randomized fixed-seed tests;
- `swift test --package-path .` passing.

No UI, SimpleFIN network code, or signing work begins until Milestone 0 is green.

### Phase 1 — schema and migrations
List every migration, column, FK, unique constraint, CHECK constraint, and index. Resolve every `budget_id` consistently. Include the transaction constraint matrix, transfer-pair cardinality, flag field, remote metadata/conflict fields, and hidden-category archival policy. Do not create v1.1 tables.



### Phase 2 — reference engine
Give exact Swift types and pseudocode for `BudgetProjection`, `BudgetEvent`, card state, category provenance lots, RTA state, month boundaries, `needsCategory`/`Uncategorized`, staged rows and resolutions, refunds, and transfers. The implementation must replay from first month rather than mutate stored available values. Gate: all reference-engine tests and the conservation oracle pass.

### Phase 3 — SimpleFIN
At the start of this phase, run the user-owned real-response capture gate before freezing Codable models. Specify claim/access URL validation, redirect refusal, Keychain object, defensive response models, sign-normalization confirmation, source-connection fallback key, initial-link anchor/attestation algorithm, incomplete-history path, per-account cursors, quota state, changed-remote conflict handling, and transactional import. Gate: sanitized fixtures, protocol tests, Keychain host test, and signed app build pass.

### Phase 4 — native UI
Specify onboarding content, the menu-bar read-only summary and its Sync Now/Open LedgerBar/Settings/Quit controls, the budget grid, current-month Move Money flow, account sidebar, transaction register with Needs Category and Staged/Needs Resolution filters, Review Queue for balance discrepancies and sync conflicts, category editing, staged-row resolution, manual transfer pairing, reconciliation, Settings, accessibility, transaction sheets, and error surfaces. Gate: generated project builds and app-host tests pass.

### Phase 5 — backup/polish
Specify backup temp-path/`PRAGMA integrity_check`/quiescence flow, sync-on-wake, performance observations, accessibility checks, and final verification of all three §6.2 `xcodebuild` commands (unsigned, ad-hoc, development-signed host test). CSV and restore remain v1.1.

For every phase, include a green build/test gate and list risks/mitigations. The implementation must not invent accounting formulas, transfer semantics, SimpleFIN wire types, or build-system decisions that are absent from this specification.
