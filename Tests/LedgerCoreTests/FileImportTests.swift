import Foundation
import Testing
@testable import LedgerCore

@Suite("File import — D6")
struct FileImportTests {

    private func fixture() throws -> (ws: BudgetWorkspace, checking: AccountID) {
        var ws = try makeWorkspace(firstMonth: "2025-01", currentMonth: "2025-02")
        let checking = try ws.addAccount(
            name: "Checking", type: .checking, onBudget: true,
            openingBalance: usd(1000), openingDate: date("2025-01-01"), nowEpoch: testEpoch
        )
        return (ws, checking)
    }

    private let bankCSV = """
    Date,Description,Debit,Credit,Balance
    01/05/2025,"TRADER JOE'S #123, SF",42.10,,957.90
    01/06/2025,PAYROLL ACME INC,,2000.00,2957.90
    01/07/2025,"Coffee ""Bean"" Co",4.50,,2953.40
    01/07/2025,Coffee "Bean" Co,4.50,,2948.90
    """

    private func mapping() -> CSVImportMapping {
        CSVImportMapping(
            dateColumn: 0, dateFormat: "MM/dd/yyyy",
            amountLayout: .debitCredit(debit: 2, credit: 3), payeeColumn: 1
        )
    }

    @Test("CSV parser handles quotes, doubled quotes, embedded delimiters, CRLF, and BOM")
    func csvParsing() throws {
        let text = "\u{FEFF}a,b\r\n\"x, y\",\"he said \"\"hi\"\"\"\r\n1,2\n"
        let data = Data(text.utf8)
        let decoded = try #require(CSVParser.decode(data))
        #expect(!decoded.hasPrefix("\u{FEFF}"))
        let rows = CSVParser.parse(decoded)
        #expect(rows == [["a", "b"], ["x, y", "he said \"hi\""], ["1", "2"]])
        #expect(CSVParser.guessDelimiter("a;b;c\n1;2;3") == ";")
        #expect(CSVParser.parse("a\tb\n1\t2", delimiter: "\t") == [["a", "b"], ["1", "2"]])
    }

    @Test("Amount and date parsing conventions")
    func amountsAndDates() throws {
        #expect(try ImportAmountParser.milliunits(from: "$1,234.56") == 1_234_560)
        #expect(try ImportAmountParser.milliunits(from: "(12.34)") == -12_340)
        #expect(try ImportAmountParser.milliunits(from: "12.34-") == -12_340)
        #expect(try ImportAmountParser.milliunits(from: "-$0.5") == -500)
        #expect(try ImportAmountParser.milliunits(from: "1.234,56", decimalSeparator: ",") == 1_234_560)
        #expect(try ImportAmountParser.milliunits(from: "15.00 DR") == -15_000)
        #expect(throws: MoneyParseError.self) { _ = try ImportAmountParser.milliunits(from: "abc") }
        #expect(ImportDateParser.date(from: "01/05/2025", format: "MM/dd/yyyy") == date("2025-01-05"))
        #expect(ImportDateParser.date(from: "2025-02-29", format: "yyyy-MM-dd") == nil, "non-leap year")
        #expect(ImportDateParser.date(from: "2024-02-29", format: "yyyy-MM-dd") == date("2024-02-29"))
        #expect(ImportDateParser.guessFormat(samples: ["2025-01-05", "2025-12-31"]) == "yyyy-MM-dd")
        #expect(ImportDateParser.guessFormat(samples: ["25/12/2025"]) == "dd/MM/yyyy")
        #expect(ImportDateParser.ofxDate("20250115120000.000[-5:EST]") == date("2025-01-15"))
        #expect(ImportDateParser.ofxDate("2025") == nil)
    }

    @Test("Header heuristics produce a usable mapping")
    func mappingGuess() throws {
        let rows = CSVParser.parse(bankCSV)
        let guessed = try #require(CSVParser.guessMapping(header: rows[0], sampleRows: Array(rows.dropFirst()), delimiter: ","))
        #expect(guessed.dateColumn == 0)
        #expect(guessed.payeeColumn == 1)
        #expect(guessed.amountLayout == .debitCredit(debit: 2, credit: 3))
        #expect(guessed.dateFormat == "MM/dd/yyyy")
        let signedRows = CSVParser.parse("Transaction Date,Amount,Name\n2025-01-05,-4.20,Cafe")
        let signed = try #require(CSVParser.guessMapping(header: signedRows[0], sampleRows: Array(signedRows.dropFirst()), delimiter: ","))
        #expect(signed.amountLayout == .signed(column: 1))
        #expect(signed.dateFormat == "yyyy-MM-dd")
    }

    @Test("CSV import end to end: normalize, classify, commit, rules, identity, provenance")
    func csvEndToEnd() throws {
        var f = try fixture()
        let groceries = f.ws.categoryID(named: "Groceries")
        try f.ws.addRule(name: "tj", conditions: [.importedDescription(.contains, "trader joe")],
                         actions: [.setPayee("Trader Joe's"), .setCategory(groceries)], nowEpoch: testEpoch)
        let records = try ImportPipeline.parse(data: Data(bankCSV.utf8), format: .csv, csvMapping: mapping())
        #expect(records.count == 4)
        let (rows, issues) = ImportPipeline.normalize(records, format: .csv, csvMapping: mapping(),
                                                      firstMonth: month("2025-01"), currentMonth: month("2025-02"))
        #expect(issues.isEmpty)
        #expect(rows.map(\.amountMilliunits) == [-42_100, 2_000_000, -4_500, -4_500])
        #expect(rows[0].rawFields["Balance"] == "957.90", "raw fields retained for audit")
        let preview = f.ws.classifyImportRows(rows, accountID: f.checking)
        #expect(preview.map(\.status) == [.new, .new, .new, .duplicate(existing: nil, reason: .withinFile)],
                "two identical lines in one file import once")
        let summary = try f.ws.commitImportBatch(accountID: f.checking, format: .csv, fileName: "bank.csv", rows: preview, nowEpoch: testEpoch)
        #expect(summary.importedCount == 3 && summary.skippedCount == 1)
        #expect(summary.needsCategoryCount == 1, "the coffee row still needs a category")
        let fileRows = f.ws.transactions.values.filter { $0.sourceKind == .file }.sorted { $0.date < $1.date }
        #expect(fileRows.count == 3)
        let tj = try #require(fileRows.first)
        #expect(tj.categoryID == groceries && tj.postingState == .posted)
        #expect(f.ws.payees[tj.payeeID!]?.displayName == "Trader Joe's")
        #expect(tj.importedDescription == "TRADER JOE'S #123, SF")
        #expect(f.ws.fileImports[tj.id]?.batchID == summary.batchID)
        #expect(f.ws.fileImports[tj.id]?.rawFields["Description"] == "TRADER JOE'S #123, SF")
        #expect(fileRows[1].categoryID == f.ws.rtaCategoryID && fileRows[1].postingState == .posted)
        #expect(try f.ws.projection().registerBalances[f.checking] == usd(1000) - 42_100 + 2_000_000 - 4_500)
        #expect(try ConservationCheck.compute(f.ws, month: month("2025-01")).holds)
        #expect(f.ws.importBatches.count == 1)
        #expect(f.ws.importBatches[summary.batchID]?.importedCount == 3)

        // Re-importing the same file is a no-op: every row is a certain duplicate.
        let again = f.ws.classifyImportRows(rows, accountID: f.checking)
        #expect(again.allSatisfy { if case .duplicate = $0.status { return true } else { return false } })
        let before = f.ws
        let second = try f.ws.commitImportBatch(accountID: f.checking, format: .csv, fileName: "bank.csv", rows: again, nowEpoch: testEpoch)
        #expect(second.importedCount == 0)
        #expect(f.ws.transactions.count == before.transactions.count)
        // Forcing a certain duplicate to import is still refused by the commit.
        var forced = again
        forced[0].decision = .import
        let third = try f.ws.commitImportBatch(accountID: f.checking, format: .csv, fileName: "bank.csv", rows: forced, nowEpoch: testEpoch)
        #expect(third.importedCount == 0 && third.skippedCount == 4)
    }

    @Test("Possible duplicates against manual rows default to skip and can be imported deliberately")
    func fuzzyDuplicates() throws {
        var f = try fixture()
        let groceries = f.ws.categoryID(named: "Groceries")
        _ = try f.ws.addManualTransaction(
            accountID: f.checking, date: date("2025-01-04"), payeeName: "Trader Joe's", categoryID: groceries,
            amountMilliunits: -42_100, nowEpoch: testEpoch
        )
        let records = try ImportPipeline.parse(data: Data(bankCSV.utf8), format: .csv, csvMapping: mapping())
        let rows = ImportPipeline.normalize(records, format: .csv, csvMapping: mapping(), firstMonth: month("2025-01"), currentMonth: month("2025-02")).rows
        var preview = f.ws.classifyImportRows(rows, accountID: f.checking)
        guard case .possibleDuplicate(let candidates) = preview[0].status else {
            Issue.record("expected a possible duplicate within ±3 days"); return
        }
        #expect(candidates.count == 1)
        #expect(preview[0].decision == .skip)
        let summary = try f.ws.commitImportBatch(accountID: f.checking, format: .csv, fileName: "b.csv", rows: preview, nowEpoch: testEpoch)
        #expect(summary.importedCount == 2)
        // The user overrides: the row imports and both rows exist.
        preview = f.ws.classifyImportRows(rows, accountID: f.checking)
        preview[0].decision = .import
        let second = try f.ws.commitImportBatch(accountID: f.checking, format: .csv, fileName: "b.csv", rows: preview, nowEpoch: testEpoch)
        #expect(second.importedCount == 1)
        #expect(f.ws.transactions.values.filter { $0.amountMilliunits == -42_100 && $0.postingState != .voided }.count == 2)
    }

    @Test("OFX (SGML) and QFX (XML) parse FITIDs, dates, amounts, and balances")
    func ofxParsing() throws {
        let sgml = """
        OFXHEADER:100
        DATA:OFXSGML
        VERSION:102

        <OFX>
        <BANKMSGSRSV1><STMTTRNRS><TRNUID>1<STATUS><CODE>0<SEVERITY>INFO</STATUS>
        <STMTRS><CURDEF>USD<BANKACCTFROM><BANKID>123456<ACCTID>987654321<ACCTTYPE>CHECKING</BANKACCTFROM>
        <BANKTRANLIST><DTSTART>20250101<DTEND>20250131
        <STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20250105120000[-5:EST]<TRNAMT>-42.10<FITID>2025010500001<NAME>TRADER JOE'S #123<MEMO>POS PURCHASE</STMTTRN>
        <STMTTRN><TRNTYPE>CREDIT<DTPOSTED>20250106<TRNAMT>2000.00<FITID>2025010600002<NAME>PAYROLL ACME &amp; CO</STMTTRN>
        <STMTTRN><TRNTYPE>CHECK<DTPOSTED>20250110<TRNAMT>-100.00<FITID>2025011000003<CHECKNUM>1042<NAME>CHECK 1042</STMTTRN>
        </BANKTRANLIST><LEDGERBAL><BALAMT>2857.90<DTASOF>20250131</LEDGERBAL></STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>
        """
        let statements = try OFXParser.parse(sgml)
        #expect(statements.count == 1)
        let statement = try #require(statements.first)
        #expect(statement.accountID == "987654321" && statement.currency == "USD")
        #expect(statement.ledgerBalanceDecimalString == "2857.90" && statement.ledgerBalanceDate == date("2025-01-31"))
        #expect(statement.records.count == 3)
        #expect(statement.records[0].externalID == "2025010500001")
        #expect(statement.records[0].description == "TRADER JOE'S #123" && statement.records[0].memo == "POS PURCHASE")
        #expect(statement.records[1].description == "PAYROLL ACME & CO")
        #expect(statement.records[2].checkNumber == "1042")

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <?OFX OFXHEADER="200" VERSION="220"?>
        <OFX><CREDITCARDMSGSRSV1><CCSTMTTRNRS><CCSTMTRS><CURDEF>USD</CURDEF>
        <CCACCTFROM><ACCTID>4111</ACCTID></CCACCTFROM>
        <BANKTRANLIST><STMTTRN><TRNTYPE>DEBIT</TRNTYPE><DTPOSTED>20250115</DTPOSTED><TRNAMT>-19.99</TRNAMT><FITID>X1</FITID><NAME>NETFLIX.COM</NAME></STMTTRN></BANKTRANLIST>
        </CCSTMTRS></CCSTMTTRNRS></CREDITCARDMSGSRSV1></OFX>
        """
        let cc = try OFXParser.parse(xml)
        #expect(cc.first?.accountID == "4111")
        #expect(cc.first?.records.first?.description == "NETFLIX.COM")
        #expect(cc.first?.records.first?.rawAmount == "-19.99")

        // End to end: normalize + FITID dedup across two imports of overlapping files.
        var f = try fixture()
        let records = try ImportPipeline.parse(data: Data(sgml.utf8), format: .ofx, csvMapping: nil)
        let rows = ImportPipeline.normalize(records, format: .ofx, csvMapping: nil, firstMonth: month("2025-01"), currentMonth: month("2025-02")).rows
        #expect(rows.map(\.amountMilliunits) == [-42_100, 2_000_000, -100_000])
        try f.ws.commitImportBatch(accountID: f.checking, format: .ofx, fileName: "jan.ofx", rows: f.ws.classifyImportRows(rows, accountID: f.checking), nowEpoch: testEpoch)
        let overlap = f.ws.classifyImportRows(rows, accountID: f.checking)
        #expect(overlap.allSatisfy { if case .duplicate(_, .externalID) = $0.status { return true } else { return false } },
                "FITIDs make a second import of overlapping history a no-op")
        #expect(ImportFormat.detect(fileName: "x.qfx", data: Data()) == .qfx)
        #expect(ImportFormat.detect(fileName: "download", data: Data(sgml.utf8)) == .ofx)
        #expect(ImportFormat.detect(fileName: "download", data: Data("a,b\n1,2".utf8)) == .csv)
    }

    @Test("Normalization reports unparsable, zero, and out-of-range rows instead of dropping them")
    func normalizationIssues() throws {
        let csv = """
        Date,Description,Amount
        13/40/2025,Bad date,-1.00
        01/05/2025,Zero,0
        01/05/2025,Not a number,abc
        12/31/2024,Before first month,-5.00
        03/01/2025,Future,-5.00
        01/08/2025,OK,-8.00
        """
        let mapping = CSVImportMapping(dateColumn: 0, dateFormat: "MM/dd/yyyy", amountLayout: .signed(column: 2), payeeColumn: 1)
        let records = try ImportPipeline.parse(data: Data(csv.utf8), format: .csv, csvMapping: mapping)
        let (rows, issues) = ImportPipeline.normalize(records, format: .csv, csvMapping: mapping, firstMonth: month("2025-01"), currentMonth: month("2025-02"))
        #expect(rows.count == 1 && rows[0].description == "OK")
        #expect(issues.map(\.kind) == [.unparsableDate, .zeroAmount, .unparsableAmount, .dateBeforeFirstMonth, .futureDate])
        #expect(issues.map(\.lineNumber) == [2, 3, 4, 5, 6])
    }

    @Test("A later bank sync flags a file-imported row as a possible duplicate; file rows soft-void")
    func fileThenSync() throws {
        var f = try fixture()
        let csv = "Date,Description,Amount\n01/05/2025,TRADER JOE'S,-42.10\n"
        let mapping = CSVImportMapping(dateColumn: 0, dateFormat: "MM/dd/yyyy", amountLayout: .signed(column: 2), payeeColumn: 1)
        let records = try ImportPipeline.parse(data: Data(csv.utf8), format: .csv, csvMapping: mapping)
        let rows = ImportPipeline.normalize(records, format: .csv, csvMapping: mapping, firstMonth: month("2025-01"), currentMonth: month("2025-02")).rows
        try f.ws.commitImportBatch(accountID: f.checking, format: .csv, fileName: "a.csv", rows: f.ws.classifyImportRows(rows, accountID: f.checking), nowEpoch: testEpoch)
        let fileRow = try #require(f.ws.transactions.values.first { $0.sourceKind == .file })
        let synced = try f.ws.importPostedTransaction(
            accountID: f.checking, connectionKey: "c1", remoteAccountID: "a", remoteTransactionID: "r1",
            postedEpoch: try f.ws.calendar.noonEpoch(of: date("2025-01-05")),
            payeeName: "TRADER JOE'S", amountMilliunits: -42_100, nowEpoch: testEpoch
        )
        let conflicts = f.ws.recordManualPotentialDuplicateConflicts(for: synced, nowEpoch: testEpoch)
        #expect(conflicts.count == 1)
        let conflict = try #require(f.ws.syncConflicts[conflicts[0]])
        #expect(conflict.transactionID == fileRow.id && conflict.eventKind == .manualPotentialDuplicate)
        // "Delete manual row" on a file row is a soft void that keeps identity.
        try f.ws.deleteTransaction(fileRow.id, nowEpoch: testEpoch)
        #expect(f.ws.transactions[fileRow.id]?.postingState == .voided)
        #expect(f.ws.fileImports[fileRow.id] != nil)
        // Re-importing the file does not resurrect the voided row.
        let again = f.ws.classifyImportRows(rows, accountID: f.checking)
        #expect(again.allSatisfy { if case .duplicate = $0.status { return true } else { return false } })
        // File amounts are provider-owned.
        #expect(throws: MutationError.transactionImmutable) {
            try f.ws.updateAmount(transactionID: synced, amountMilliunits: -1, nowEpoch: testEpoch)
        }
    }

    @Test("Closed-month file rows are staged append-only; mappings save and persist")
    func closedMonthAndMappings() throws {
        var f = try fixture()
        try f.ws.closeMonth(month("2025-01"), nowEpoch: testEpoch)
        let csv = "Date,Description,Amount\n01/05/2025,OLD,-1.00\n02/05/2025,NEW,-2.00\n"
        let mapping = CSVImportMapping(dateColumn: 0, dateFormat: "MM/dd/yyyy", amountLayout: .signed(column: 2), payeeColumn: 1)
        let records = try ImportPipeline.parse(data: Data(csv.utf8), format: .csv, csvMapping: mapping)
        let rows = ImportPipeline.normalize(records, format: .csv, csvMapping: mapping, firstMonth: month("2025-01"), currentMonth: month("2025-02")).rows
        let summary = try f.ws.commitImportBatch(accountID: f.checking, format: .csv, fileName: "c.csv", rows: f.ws.classifyImportRows(rows, accountID: f.checking), nowEpoch: testEpoch)
        #expect(summary.stagedCount == 1 && summary.needsCategoryCount == 1)
        let old = try #require(f.ws.transactions.values.first { $0.importedDescription == "OLD" })
        #expect(old.postingState == .staged && old.stageReason == .closedMonthImport)
        #expect(try ConservationCheck.compute(f.ws, month: month("2025-02")).holds)

        let header = ["Date", "Description", "Amount"]
        let fingerprint = CSVImportMapping.headerFingerprint(header)
        let id = try f.ws.saveImportMapping(name: "My Bank", headerFingerprint: fingerprint, mapping: mapping, nowEpoch: testEpoch)
        #expect(f.ws.importMapping(matchingHeader: fingerprint)?.id == id)
        #expect(f.ws.importMapping(matchingHeader: CSVImportMapping.headerFingerprint(["x"])) == nil)
        let sameName = try f.ws.saveImportMapping(name: "my bank", headerFingerprint: fingerprint, mapping: mapping, nowEpoch: testEpoch + 1)
        #expect(sameName == id && f.ws.importMappings.count == 1)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledgerbar-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LedgerWorkspaceStore(databaseURL: directory.appendingPathComponent("db.sqlite"))
        try store.save(f.ws, nowEpoch: testEpoch)
        let restored = try store.load(budgetID: f.ws.budget.id)
        #expect(restored.snapshot() == f.ws.snapshot())
        let counts = try store.pool.read { db -> (Int, Int, Int) in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM file_imports") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM import_batches") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM import_mappings") ?? 0)
        }
        #expect(counts == (2, 1, 1))
    }
}
