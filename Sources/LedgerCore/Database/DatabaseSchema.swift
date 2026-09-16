import Foundation
import GRDB

/// Explicit schema migrations for the local LedgerBar database.
public enum LedgerDatabaseSchema {
    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: """
            CREATE TABLE budgets (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                currency TEXT NOT NULL CHECK(length(currency) BETWEEN 3 AND 3),
                timezone_identifier TEXT NOT NULL,
                first_month TEXT NOT NULL CHECK(first_month GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]'),
                last_observed_month TEXT NOT NULL CHECK(last_observed_month GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]'),
                next_local_source_sequence INTEGER NOT NULL CHECK(next_local_source_sequence >= 0),
                created_at_epoch INTEGER NOT NULL,
                revision INTEGER NOT NULL CHECK(revision >= 0)
            );

            CREATE TABLE workspace_states (
                budget_id TEXT PRIMARY KEY NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                payload BLOB NOT NULL,
                revision INTEGER NOT NULL CHECK(revision >= 0),
                updated_at_epoch INTEGER NOT NULL
            );

            CREATE TABLE category_groups (
                id TEXT PRIMARY KEY NOT NULL,
                budget_id TEXT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                sort_order INTEGER NOT NULL,
                hidden INTEGER NOT NULL DEFAULT 0 CHECK(hidden IN (0, 1)),
                UNIQUE(budget_id, id)
            );

            CREATE TABLE categories (
                id TEXT PRIMARY KEY NOT NULL,
                budget_id TEXT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                group_id TEXT NOT NULL,
                name TEXT NOT NULL,
                sort_order INTEGER NOT NULL,
                hidden INTEGER NOT NULL DEFAULT 0 CHECK(hidden IN (0, 1)),
                kind TEXT NOT NULL CHECK(kind IN ('inflow', 'cc_payment', 'spending')),
                linked_account_id TEXT,
                system_kind TEXT,
                note TEXT,
                UNIQUE(budget_id, id),
                FOREIGN KEY(budget_id, group_id) REFERENCES category_groups(budget_id, id) ON DELETE RESTRICT
            );

            CREATE TABLE accounts (
                id TEXT PRIMARY KEY NOT NULL,
                budget_id TEXT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                type TEXT NOT NULL CHECK(type IN ('checking', 'savings', 'cash', 'creditCard', 'other')),
                on_budget INTEGER NOT NULL CHECK(on_budget IN (0, 1)),
                closed INTEGER NOT NULL DEFAULT 0 CHECK(closed IN (0, 1)),
                currency TEXT NOT NULL,
                history_incomplete INTEGER NOT NULL DEFAULT 0 CHECK(history_incomplete IN (0, 1)),
                created_at_epoch INTEGER NOT NULL,
                UNIQUE(budget_id, id)
            );

            CREATE TABLE payees (
                id TEXT PRIMARY KEY NOT NULL,
                budget_id TEXT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                system_kind TEXT,
                namespace TEXT NOT NULL CHECK(namespace IN ('system', 'user')),
                normalized_name TEXT NOT NULL,
                display_name TEXT NOT NULL,
                last_used_category_id TEXT,
                hidden INTEGER NOT NULL DEFAULT 0 CHECK(hidden IN (0, 1)),
                UNIQUE(budget_id, id),
                UNIQUE(budget_id, namespace, normalized_name),
                FOREIGN KEY(budget_id, last_used_category_id) REFERENCES categories(budget_id, id)
            );

            CREATE TABLE allocations (
                budget_id TEXT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                category_id TEXT NOT NULL,
                month TEXT NOT NULL CHECK(month GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]'),
                budgeted_milliunits INTEGER NOT NULL,
                PRIMARY KEY(budget_id, category_id, month),
                FOREIGN KEY(budget_id, category_id) REFERENCES categories(budget_id, id) ON DELETE RESTRICT
            );

            CREATE TABLE transfer_pairs (
                id TEXT PRIMARY KEY NOT NULL,
                budget_id TEXT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                status TEXT NOT NULL CHECK(status IN ('complete', 'unpaired', 'voided')),
                created_at_epoch INTEGER NOT NULL,
                UNIQUE(budget_id, id)
            );

            CREATE TABLE transactions (
                id TEXT PRIMARY KEY NOT NULL,
                budget_id TEXT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                account_id TEXT NOT NULL,
                payee_id TEXT,
                source_kind TEXT NOT NULL CHECK(source_kind IN ('manual', 'simplefin', 'system')),
                date TEXT NOT NULL CHECK(date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
                effective_at_epoch INTEGER,
                source_order_key TEXT NOT NULL,
                memo TEXT,
                amount_milliunits INTEGER NOT NULL,
                cleared TEXT NOT NULL CHECK(cleared IN ('uncleared', 'cleared', 'reconciled')),
                approved INTEGER NOT NULL CHECK(approved IN (0, 1)),
                flag_color TEXT,
                posting_state TEXT NOT NULL CHECK(posting_state IN ('needsCategory', 'staged', 'posted', 'voided')),
                stage_reason TEXT,
                stage_metadata BLOB,
                user_edited_at_epoch INTEGER,
                category_id TEXT,
                transfer_pair_id TEXT,
                refund_of_transaction_id TEXT,
                kind TEXT NOT NULL CHECK(kind IN ('normal', 'refund', 'openingBalance', 'adjustment')),
                UNIQUE(budget_id, source_order_key),
                UNIQUE(budget_id, id),
                FOREIGN KEY(budget_id, account_id) REFERENCES accounts(budget_id, id) ON DELETE RESTRICT,
                FOREIGN KEY(budget_id, payee_id) REFERENCES payees(budget_id, id),
                FOREIGN KEY(budget_id, category_id) REFERENCES categories(budget_id, id),
                FOREIGN KEY(budget_id, transfer_pair_id) REFERENCES transfer_pairs(budget_id, id),
                FOREIGN KEY(budget_id, refund_of_transaction_id) REFERENCES transactions(budget_id, id)
            );

            CREATE TABLE transfer_leg_snapshots (
                transfer_pair_id TEXT NOT NULL REFERENCES transfer_pairs(id) ON DELETE CASCADE,
                transaction_id TEXT PRIMARY KEY NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
                payload BLOB NOT NULL
            );

            CREATE TABLE closed_months (
                budget_id TEXT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                month TEXT NOT NULL CHECK(month GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]'),
                status TEXT NOT NULL CHECK(status IN ('closed', 'reopened')),
                closed_at_epoch INTEGER NOT NULL,
                reopened_at_epoch INTEGER,
                PRIMARY KEY(budget_id, month)
            );

            CREATE TABLE audit_events (
                id TEXT PRIMARY KEY NOT NULL,
                budget_id TEXT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                entity_type TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                event_kind TEXT NOT NULL,
                metadata BLOB NOT NULL,
                created_at_epoch INTEGER NOT NULL
            );

            CREATE TABLE reconciliation_membership (
                budget_id TEXT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                transaction_id TEXT NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
                reconciliation_id TEXT NOT NULL,
                PRIMARY KEY(budget_id, transaction_id)
            );

            CREATE TABLE simplefin_connections (
                id TEXT PRIMARY KEY NOT NULL,
                budget_id TEXT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                status TEXT NOT NULL CHECK(status IN ('active', 'disconnected')),
                keychain_item_ref TEXT,
                credential_generation INTEGER NOT NULL CHECK(credential_generation >= 0),
                created_at_epoch INTEGER NOT NULL,
                UNIQUE(budget_id, id)
            );

            CREATE TABLE simplefin_links (
                id TEXT PRIMARY KEY NOT NULL,
                budget_id TEXT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                connection_id TEXT NOT NULL REFERENCES simplefin_connections(id) ON DELETE RESTRICT,
                local_account_id TEXT REFERENCES accounts(id) ON DELETE RESTRICT,
                remote_connection_key TEXT NOT NULL,
                remote_account_id TEXT NOT NULL,
                sign_normalization INTEGER NOT NULL CHECK(sign_normalization IN (1, -1)),
                cursor_posted_epoch INTEGER,
                last_successful_sync_epoch INTEGER,
                last_error_redacted TEXT,
                pause_reason TEXT,
                status TEXT NOT NULL CHECK(status IN ('active', 'paused')),
                UNIQUE(budget_id, remote_connection_key, remote_account_id)
            );

            CREATE TABLE simplefin_imports (
                budget_id TEXT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                connection_id TEXT NOT NULL,
                remote_connection_key TEXT NOT NULL,
                remote_account_id TEXT NOT NULL,
                remote_transaction_id TEXT NOT NULL,
                transaction_id TEXT NOT NULL REFERENCES transactions(id) ON DELETE RESTRICT,
                raw_payload_hash TEXT,
                last_seen_epoch INTEGER,
                PRIMARY KEY(budget_id, remote_connection_key, remote_account_id, remote_transaction_id),
                UNIQUE(transaction_id)
            );

            CREATE TABLE sync_conflicts (
                id TEXT PRIMARY KEY NOT NULL,
                budget_id TEXT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                transaction_id TEXT,
                event_kind TEXT NOT NULL,
                status TEXT NOT NULL CHECK(status IN ('open', 'resolved')),
                old_metadata BLOB NOT NULL,
                new_metadata BLOB NOT NULL,
                created_at_epoch INTEGER NOT NULL,
                resolved_at_epoch INTEGER
            );

            CREATE TABLE snapshot_discrepancies (
                id TEXT PRIMARY KEY NOT NULL,
                budget_id TEXT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE RESTRICT,
                snapshot_epoch INTEGER NOT NULL,
                remote_balance_milliunits INTEGER NOT NULL,
                local_register_milliunits INTEGER NOT NULL,
                difference_milliunits INTEGER NOT NULL,
                status TEXT NOT NULL CHECK(status IN ('open', 'resolved')),
                created_at_epoch INTEGER NOT NULL,
                resolved_at_epoch INTEGER
            );

            CREATE TABLE trusted_hosts (
                budget_id TEXT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                host TEXT NOT NULL,
                port INTEGER NOT NULL CHECK(port BETWEEN 1 AND 65535),
                added_at_epoch INTEGER NOT NULL,
                PRIMARY KEY(budget_id, host, port)
            );

            CREATE UNIQUE INDEX categories_one_cc_payment_per_account
                ON categories(budget_id, linked_account_id)
                WHERE kind = 'cc_payment' AND linked_account_id IS NOT NULL;
            CREATE INDEX transactions_account_date ON transactions(account_id, date, effective_at_epoch);
            CREATE INDEX transactions_category_date ON transactions(category_id, date);
            CREATE INDEX transactions_posting_date ON transactions(posting_state, date);
            CREATE INDEX transactions_transfer_pair ON transactions(transfer_pair_id);
            CREATE INDEX allocations_category_month ON allocations(category_id, month);
            CREATE INDEX reconciliation_membership_transaction ON reconciliation_membership(transaction_id);
            CREATE INDEX conflicts_status ON sync_conflicts(status);
            CREATE INDEX discrepancies_status ON snapshot_discrepancies(status);
            CREATE INDEX simplefin_import_transaction ON simplefin_imports(transaction_id);
            """)
        }
        migrator.registerMigration("v2-simplefin-state") { db in
            try db.execute(sql: """
            CREATE TABLE simplefin_state (
                budget_id TEXT PRIMARY KEY NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                payload BLOB NOT NULL,
                updated_at_epoch INTEGER NOT NULL
            );
            """)
        }
        migrator.registerMigration("v3-reconciliations") { db in
            try db.execute(sql: """
            CREATE TABLE reconciliations (
                id TEXT PRIMARY KEY NOT NULL,
                budget_id TEXT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                account_id TEXT NOT NULL,
                statement_date TEXT NOT NULL,
                statement_balance_milliunits INTEGER NOT NULL,
                cleared_balance_milliunits INTEGER NOT NULL,
                adjustment_transaction_id TEXT,
                adjustment_fingerprint TEXT,
                status TEXT NOT NULL CHECK(status IN ('completed', 'undone')),
                created_at_epoch INTEGER NOT NULL,
                completed_at_epoch INTEGER
            );

            CREATE TABLE reconciliation_transactions (
                reconciliation_id TEXT NOT NULL REFERENCES reconciliations(id) ON DELETE CASCADE,
                budget_id TEXT NOT NULL,
                transaction_id TEXT NOT NULL,
                fingerprint TEXT NOT NULL,
                was_newly_marked INTEGER NOT NULL CHECK(was_newly_marked IN (0, 1)),
                PRIMARY KEY(reconciliation_id, transaction_id)
            );

            CREATE INDEX reconciliations_account ON reconciliations(account_id, status);
            """)
        }
        migrator.registerMigration("v4-simplefin-sync") { db in
            // The v1 shapes of these three tables were never written by any
            // shipped code path (verified: no INSERT existed before this
            // migration), so a drop/recreate to the full §2.1 field lists is
            // safe and loses no data. `connection_id` stays FK-free because the
            // normalized `simplefin_connections` table is still unpopulated;
            // the v1 single connection uses the 'primary' sentinel.
            try db.execute(sql: """
            DROP TABLE sync_conflicts;
            DROP TABLE simplefin_imports;
            DROP TABLE snapshot_discrepancies;

            CREATE TABLE simplefin_imports (
                id TEXT PRIMARY KEY NOT NULL,
                budget_id TEXT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                transaction_id TEXT NOT NULL REFERENCES transactions(id) ON DELETE RESTRICT,
                connection_id TEXT NOT NULL DEFAULT 'primary',
                remote_connection_key TEXT NOT NULL,
                remote_account_id TEXT NOT NULL,
                remote_transaction_id TEXT NOT NULL,
                remote_amount TEXT NOT NULL,
                remote_posted_epoch INTEGER NOT NULL,
                remote_transacted_epoch INTEGER,
                remote_payload_hash TEXT NOT NULL,
                protocol_version TEXT NOT NULL,
                last_seen_epoch INTEGER NOT NULL,
                UNIQUE(transaction_id),
                UNIQUE(connection_id, remote_connection_key, remote_account_id, remote_transaction_id)
            );

            CREATE TABLE sync_conflicts (
                id TEXT PRIMARY KEY NOT NULL,
                budget_id TEXT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                transaction_id TEXT,
                simplefin_import_id TEXT REFERENCES simplefin_imports(id),
                event_kind TEXT NOT NULL CHECK(event_kind IN ('remoteChanged', 'remoteDisappeared', 'manualPotentialDuplicate')),
                status TEXT NOT NULL CHECK(status IN ('open', 'resolved', 'dismissed')),
                old_metadata BLOB NOT NULL,
                new_metadata BLOB NOT NULL,
                created_at_epoch INTEGER NOT NULL,
                resolved_at_epoch INTEGER
            );

            CREATE TABLE snapshot_discrepancies (
                id TEXT PRIMARY KEY NOT NULL,
                budget_id TEXT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE RESTRICT,
                snapshot_epoch INTEGER NOT NULL,
                remote_balance_milliunits INTEGER NOT NULL,
                local_register_milliunits INTEGER NOT NULL,
                difference_milliunits INTEGER NOT NULL,
                status TEXT NOT NULL CHECK(status IN ('open', 'resolved')),
                resolution_reason TEXT CHECK(resolution_reason IS NULL OR resolution_reason IN ('adjustment', 'accountClosedOffBudget', 'manualAttestation')),
                adjustment_transaction_id TEXT REFERENCES transactions(id),
                created_at_epoch INTEGER NOT NULL,
                resolved_at_epoch INTEGER
            );

            CREATE INDEX simplefin_import_transaction ON simplefin_imports(transaction_id);
            CREATE INDEX simplefin_import_window
                ON simplefin_imports(remote_connection_key, remote_account_id, remote_posted_epoch);
            CREATE INDEX conflicts_status ON sync_conflicts(status);
            CREATE INDEX conflicts_transaction ON sync_conflicts(transaction_id);
            CREATE INDEX discrepancies_status ON snapshot_discrepancies(status);
            CREATE INDEX discrepancies_account ON snapshot_discrepancies(account_id, status);
            """)
        }
        migrator.registerMigration("v5-sync-resolution") { db in
            try db.execute(sql: """
            ALTER TABLE simplefin_imports
                ADD COLUMN remote_disappearance_acknowledged INTEGER NOT NULL DEFAULT 0
                CHECK(remote_disappearance_acknowledged IN (0, 1));
            """)
        }
        migrator.registerMigration("v6-snapshot-discrepancy-link") { db in
            try db.execute(sql: """
            ALTER TABLE snapshot_discrepancies
                ADD COLUMN simplefin_link_identity TEXT;
            """)
        }
        migrator.registerMigration("v7-sync-request-log") { db in
            try db.execute(sql: """
            CREATE TABLE sync_request_log (
                id TEXT PRIMARY KEY NOT NULL,
                budget_id TEXT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                connection_id TEXT NOT NULL,
                account_id TEXT REFERENCES accounts(id) ON DELETE SET NULL,
                requested_start_epoch INTEGER,
                requested_end_epoch INTEGER,
                started_at_epoch INTEGER NOT NULL,
                completed_at_epoch INTEGER,
                status TEXT NOT NULL CHECK(status IN ('started', 'succeeded', 'failed')),
                http_status INTEGER CHECK(http_status IS NULL OR http_status BETWEEN 100 AND 599),
                retry_after_seconds INTEGER CHECK(retry_after_seconds IS NULL OR retry_after_seconds >= 0)
            );
            CREATE INDEX sync_request_log_budget_started
                ON sync_request_log(budget_id, started_at_epoch);
            """)
        }
        migrator.registerMigration("v8-derived-projection-cache") { db in
            try db.execute(sql: """
            CREATE TABLE projection_caches (
                budget_id TEXT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                revision INTEGER NOT NULL CHECK(revision >= 0),
                horizon TEXT NOT NULL CHECK(horizon = '' OR horizon GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]'),
                payload BLOB NOT NULL,
                updated_at_epoch INTEGER NOT NULL,
                PRIMARY KEY(budget_id, revision, horizon)
            );
            CREATE INDEX projection_caches_budget_revision
                ON projection_caches(budget_id, revision);
            """)
        }
        migrator.registerMigration("v9-simplefin-link-local-account") {
            db in
            // `simplefin_links` is a derived mirror of the authoritative
            // `simplefin_state` blob and is never used as the source of truth.
            // Clear legacy rows before adding the constraint so an old mirror
            // that contains duplicate bindings cannot brick startup; the next
            // successful state write rebuilds the mirror from the blob.
            try db.execute(sql: """
            DELETE FROM simplefin_links;
            CREATE UNIQUE INDEX simplefin_links_one_local_account_per_connection
                ON simplefin_links(connection_id, local_account_id)
                WHERE local_account_id IS NOT NULL;
            """)
        }
        migrator.registerMigration("v10-splits-imported-description-file-source") { db in
            // The `source_kind` CHECK gains 'file' and three nullable columns
            // are added. SQLite cannot alter a CHECK, so the mirror table is
            // rebuilt with the 12-step procedure (GRDB runs migrations with
            // foreign keys off and checks them at the end). All rows and every
            // identity are copied; child tables keep referencing the same
            // table name.
            try db.execute(sql: """
            CREATE TABLE transactions_new (
                id TEXT PRIMARY KEY NOT NULL,
                budget_id TEXT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                account_id TEXT NOT NULL,
                payee_id TEXT,
                source_kind TEXT NOT NULL CHECK(source_kind IN ('manual', 'simplefin', 'system', 'file')),
                date TEXT NOT NULL CHECK(date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
                effective_at_epoch INTEGER,
                source_order_key TEXT NOT NULL,
                memo TEXT,
                amount_milliunits INTEGER NOT NULL,
                cleared TEXT NOT NULL CHECK(cleared IN ('uncleared', 'cleared', 'reconciled')),
                approved INTEGER NOT NULL CHECK(approved IN (0, 1)),
                flag_color TEXT,
                posting_state TEXT NOT NULL CHECK(posting_state IN ('needsCategory', 'staged', 'posted', 'voided')),
                stage_reason TEXT,
                stage_metadata BLOB,
                user_edited_at_epoch INTEGER,
                category_id TEXT,
                transfer_pair_id TEXT,
                refund_of_transaction_id TEXT,
                kind TEXT NOT NULL CHECK(kind IN ('normal', 'refund', 'openingBalance', 'adjustment')),
                splits BLOB,
                imported_description TEXT,
                refund_of_component_index INTEGER CHECK(refund_of_component_index IS NULL OR refund_of_component_index >= 0),
                UNIQUE(budget_id, source_order_key),
                UNIQUE(budget_id, id),
                FOREIGN KEY(budget_id, account_id) REFERENCES accounts(budget_id, id) ON DELETE RESTRICT,
                FOREIGN KEY(budget_id, payee_id) REFERENCES payees(budget_id, id),
                FOREIGN KEY(budget_id, category_id) REFERENCES categories(budget_id, id),
                FOREIGN KEY(budget_id, transfer_pair_id) REFERENCES transfer_pairs(budget_id, id),
                FOREIGN KEY(budget_id, refund_of_transaction_id) REFERENCES transactions(budget_id, id)
            );
            INSERT INTO transactions_new (
                id, budget_id, account_id, payee_id, source_kind, date, effective_at_epoch,
                source_order_key, memo, amount_milliunits, cleared, approved, flag_color,
                posting_state, stage_reason, stage_metadata, user_edited_at_epoch, category_id,
                transfer_pair_id, refund_of_transaction_id, kind
            )
            SELECT
                id, budget_id, account_id, payee_id, source_kind, date, effective_at_epoch,
                source_order_key, memo, amount_milliunits, cleared, approved, flag_color,
                posting_state, stage_reason, stage_metadata, user_edited_at_epoch, category_id,
                transfer_pair_id, refund_of_transaction_id, kind
            FROM transactions;
            DROP TABLE transactions;
            ALTER TABLE transactions_new RENAME TO transactions;
            CREATE INDEX transactions_account_date ON transactions(account_id, date, effective_at_epoch);
            CREATE INDEX transactions_category_date ON transactions(category_id, date);
            CREATE INDEX transactions_posting_date ON transactions(posting_state, date);
            CREATE INDEX transactions_transfer_pair ON transactions(transfer_pair_id);

            CREATE TABLE transaction_splits (
                transaction_id TEXT NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
                component_index INTEGER NOT NULL CHECK(component_index >= 0),
                budget_id TEXT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                category_id TEXT NOT NULL,
                amount_milliunits INTEGER NOT NULL CHECK(amount_milliunits != 0),
                memo TEXT,
                PRIMARY KEY(transaction_id, component_index),
                FOREIGN KEY(budget_id, category_id) REFERENCES categories(budget_id, id)
            );
            CREATE INDEX transaction_splits_category ON transaction_splits(category_id);

            ALTER TABLE budgets ADD COLUMN archived INTEGER NOT NULL DEFAULT 0 CHECK(archived IN (0, 1));
            ALTER TABLE budgets ADD COLUMN sort_order INTEGER NOT NULL DEFAULT 0;

            UPDATE transactions
               SET imported_description = (
                    SELECT p.display_name FROM payees p
                     WHERE p.id = transactions.payee_id AND p.budget_id = transactions.budget_id
               )
             WHERE source_kind = 'simplefin' AND imported_description IS NULL;
            """)
        }
        migrator.registerMigration("v11-automation-rules") { db in
            try db.execute(sql: """
            CREATE TABLE automation_rules (
                id TEXT PRIMARY KEY NOT NULL,
                budget_id TEXT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                enabled INTEGER NOT NULL CHECK(enabled IN (0, 1)),
                sort_order INTEGER NOT NULL,
                match_mode TEXT NOT NULL CHECK(match_mode IN ('all', 'any')),
                stop_after_match INTEGER NOT NULL CHECK(stop_after_match IN (0, 1)),
                payload BLOB NOT NULL,
                created_at_epoch INTEGER NOT NULL,
                updated_at_epoch INTEGER NOT NULL
            );
            CREATE INDEX automation_rules_budget_order ON automation_rules(budget_id, sort_order);
            """)
        }
        migrator.registerMigration("v12-file-import") { db in
            try db.execute(sql: """
            CREATE TABLE import_batches (
                id TEXT PRIMARY KEY NOT NULL,
                budget_id TEXT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE RESTRICT,
                format TEXT NOT NULL CHECK(format IN ('csv', 'ofx', 'qfx')),
                file_name TEXT NOT NULL,
                imported_at_epoch INTEGER NOT NULL,
                imported_count INTEGER NOT NULL CHECK(imported_count >= 0),
                skipped_count INTEGER NOT NULL CHECK(skipped_count >= 0)
            );
            CREATE TABLE file_imports (
                transaction_id TEXT PRIMARY KEY NOT NULL REFERENCES transactions(id) ON DELETE RESTRICT,
                budget_id TEXT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                batch_id TEXT NOT NULL REFERENCES import_batches(id) ON DELETE RESTRICT,
                external_id TEXT,
                fingerprint TEXT NOT NULL,
                raw_fields BLOB NOT NULL
            );
            CREATE INDEX file_imports_batch ON file_imports(batch_id);
            CREATE INDEX file_imports_external ON file_imports(budget_id, external_id);
            CREATE INDEX file_imports_fingerprint ON file_imports(budget_id, fingerprint);
            CREATE TABLE import_mappings (
                id TEXT PRIMARY KEY NOT NULL,
                budget_id TEXT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                format TEXT NOT NULL CHECK(format IN ('csv', 'ofx', 'qfx')),
                header_fingerprint TEXT,
                payload BLOB NOT NULL,
                created_at_epoch INTEGER NOT NULL,
                last_used_at_epoch INTEGER NOT NULL
            );
            """)
        }
        migrator.registerMigration("v13-reports") { db in
            try db.execute(sql: """
            CREATE TABLE reports (
                id TEXT PRIMARY KEY NOT NULL,
                budget_id TEXT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                kind TEXT NOT NULL,
                sort_order INTEGER NOT NULL,
                payload BLOB NOT NULL,
                created_at_epoch INTEGER NOT NULL,
                updated_at_epoch INTEGER NOT NULL
            );
            """)
        }
        migrator.registerMigration("v14-schedules") { db in
            try db.execute(sql: """
            CREATE TABLE schedules (
                id TEXT PRIMARY KEY NOT NULL,
                budget_id TEXT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE RESTRICT,
                name TEXT NOT NULL,
                status TEXT NOT NULL CHECK(status IN ('active', 'paused', 'ended')),
                amount_milliunits INTEGER NOT NULL,
                start_date TEXT NOT NULL,
                end_date TEXT,
                payload BLOB NOT NULL,
                created_at_epoch INTEGER NOT NULL,
                updated_at_epoch INTEGER NOT NULL
            );
            CREATE TABLE schedule_occurrences (
                schedule_id TEXT NOT NULL REFERENCES schedules(id) ON DELETE CASCADE,
                due_date TEXT NOT NULL,
                budget_id TEXT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                status TEXT NOT NULL CHECK(status IN ('matched', 'entered', 'skipped')),
                transaction_id TEXT REFERENCES transactions(id) ON DELETE SET NULL,
                resolved_at_epoch INTEGER NOT NULL,
                match_score INTEGER,
                PRIMARY KEY(schedule_id, due_date)
            );
            CREATE UNIQUE INDEX schedule_occurrences_transaction
                ON schedule_occurrences(transaction_id) WHERE transaction_id IS NOT NULL;
            CREATE TABLE schedule_reviews (
                id TEXT PRIMARY KEY NOT NULL,
                budget_id TEXT NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                schedule_id TEXT NOT NULL REFERENCES schedules(id) ON DELETE CASCADE,
                due_date TEXT NOT NULL,
                status TEXT NOT NULL CHECK(status IN ('open', 'resolved', 'dismissed')),
                candidates BLOB NOT NULL,
                created_at_epoch INTEGER NOT NULL,
                resolved_at_epoch INTEGER
            );
            CREATE INDEX schedule_reviews_status ON schedule_reviews(budget_id, status);
            """)
        }
        migrator.registerMigration("v15-app-settings") { db in
            try db.execute(sql: """
            CREATE TABLE app_settings (
                key TEXT PRIMARY KEY NOT NULL,
                value TEXT NOT NULL,
                updated_at_epoch INTEGER NOT NULL
            );
            """)
        }
        migrator.registerMigration("v16-assistant-conversations") { db in
            try db.execute(sql: """
            CREATE TABLE assistant_conversations (
                budget_id TEXT PRIMARY KEY NOT NULL REFERENCES budgets(id) ON DELETE CASCADE,
                payload BLOB NOT NULL,
                updated_at_epoch INTEGER NOT NULL
            );
            """)
        }
        return migrator
    }
}
