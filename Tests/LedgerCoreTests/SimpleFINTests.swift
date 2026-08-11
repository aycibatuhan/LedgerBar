import Foundation
import Testing
@testable import LedgerCore

private final class FixedBodyURLProtocol: URLProtocol {
    static let body = Data(repeating: 0x41, count: 64)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class RedirectingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func reset() {
        lock.lock()
        requests.removeAll()
        lock.unlock()
    }

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        Self.lock.unlock()

        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 302,
                httpVersion: nil,
                headerFields: ["Location": "https://example.invalid/redirect"]
              ),
              let redirectedURL = URL(string: "https://example.invalid/redirect") else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(
            self,
            wasRedirectedTo: URLRequest(url: redirectedURL),
            redirectResponse: response
        )
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }

    override func stopLoading() {}
}

@Suite("SimpleFIN protocol and security boundaries")
struct SimpleFINTests {
    private let approvedHost = try! SimpleFINHost(host: SimpleFINURLValidator.officialBridgeHost)

    @Test("Setup token and Access URL validation reject unsafe forms")
    func strictURLValidation() throws {
        let claim = Data("https://bridge.simplefin.org/claim".utf8).base64EncodedString()
        let claimURL = try SimpleFINURLValidator.decodeSetupToken(claim)
        #expect(claimURL.host == SimpleFINURLValidator.officialBridgeHost)

        let betaHost = try SimpleFINHost(host: "beta-bridge.simplefin.org")
        let betaClaim = Data("https://beta-bridge.simplefin.org/claim".utf8).base64EncodedString()
        #expect(throws: SimpleFINProtocolError.untrustedHost(betaHost.host)) {
            try SimpleFINURLValidator.decodeSetupToken(betaClaim)
        }
        let approvedBetaClaim = try SimpleFINURLValidator.decodeSetupToken(
            betaClaim,
            trustedHosts: [betaHost]
        )
        #expect(approvedBetaClaim.host == betaHost.host)
        let approvedBetaCredential = try SimpleFINURLValidator.parseAccessURL(
            URL(string: "https://user:[REDACTED]@beta-bridge.simplefin.org/access")!,
            approvedHosts: [betaHost]
        )
        #expect(approvedBetaCredential.host == betaHost)

        #expect(throws: SimpleFINProtocolError.self) {
            try SimpleFINURLValidator.decodeSetupToken(Data("http://bridge.simplefin.org/claim".utf8).base64EncodedString())
        }
        #expect(throws: SimpleFINProtocolError.untrustedHost("example.invalid")) {
            try SimpleFINURLValidator.decodeSetupToken(
                Data("https://example.invalid/claim".utf8).base64EncodedString()
            )
        }
        let credentialWithReservedKey = try SimpleFINURLValidator.parseAccessURL(
            URL(string: "https://user:[REDACTED]@bridge.simplefin.org/access?start-date=1")!,
            approvedHosts: [approvedHost]
        )
        let client = SimpleFINClient(credential: credentialWithReservedKey)
        #expect(throws: SimpleFINProtocolError.self) {
            try client.makeAccountsURL(SimpleFINRequest())
        }
        #expect(throws: SimpleFINProtocolError.untrustedHost("example.invalid")) {
            try SimpleFINURLValidator.parseAccessURL(
                URL(string: "https://user:[REDACTED]@example.invalid/access")!,
                approvedHosts: []
            )
        }

        for path in ["/access/../token", "/access/%2e%2e/token", "/access/%2E/token"] {
            #expect(throws: SimpleFINProtocolError.invalidAccessURL) {
                try SimpleFINCredential(
                    host: approvedHost,
                    opaquePercentEncodedPathPrefix: path,
                    existingQueryItems: [],
                    existingPercentEncodedQuery: nil,
                    username: "unit-user",
                    password: "unit-password-not-a-secret",
                    approvedHost: approvedHost
                )
            }
        }

        let validCredential = try SimpleFINCredential(
            host: approvedHost,
            opaquePercentEncodedPathPrefix: "/access",
            existingQueryItems: [],
            existingPercentEncodedQuery: nil,
            username: "unit-user",
            password: "unit-password-not-a-secret",
            approvedHost: approvedHost
        )
        var malformedObject = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(validCredential)
            ) as? [String: Any]
        )
        malformedObject["opaquePercentEncodedPathPrefix"] = "/access/../token"
        let malformedCredential = try JSONSerialization.data(withJSONObject: malformedObject)
        #expect(throws: SimpleFINProtocolError.invalidAccessURL) {
            _ = try JSONDecoder().decode(SimpleFINCredential.self, from: malformedCredential)
        }
    }

    @Test("Existing query bytes are preserved and reserved request keys are rejected")
    func queryConstruction() throws {
        let credential = try SimpleFINURLValidator.parseAccessURL(
            URL(string: "https://test-user:[REDACTED]@bridge.simplefin.org/access%2Fopaque?keep=bar%20baz")!,
            approvedHosts: [approvedHost]
        )
        let client = SimpleFINClient(credential: credential)
        let window = try SimpleFINRequestWindow(startEpoch: 100, endEpoch: 200)
        let url = try client.makeAccountsURL(SimpleFINRequest(window: window, balancesOnly: true))
        #expect(url.path == "/access/opaque/accounts")
        #expect(url.absoluteString.contains("keep=bar%20baz"))
        #expect(url.absoluteString.contains("start-date=100"))
        #expect(url.absoluteString.contains("end-date=200"))
        #expect(url.absoluteString.contains("balances-only=1"))
        #expect(url.absoluteString.contains("pending=0"))
        #expect(!url.absoluteString.contains("pending=1"))
    }

    @Test("Recurring and initial windows use checked epoch arithmetic")
    func windows() throws {
        let recurring = try SimpleFINRequestWindow.recurring(lastSuccessfulPostedEpoch: 1_000_000)
        #expect(recurring.startEpoch == 568_000)
        #expect(recurring.endEpoch == nil)
        let initial = try SimpleFINRequestWindow.initial(
            startEpoch: 10,
            balanceDateEpoch: 20,
            endpointEndDateIsInclusive: false
        )
        #expect(initial.endEpoch == 21)
        #expect(throws: SimpleFINProtocolError.self) {
            try SimpleFINRequestWindow.initial(
                startEpoch: 0,
                balanceDateEpoch: Int64.max,
                endpointEndDateIsInclusive: false
            )
        }
    }

    @Test("Supported account and transaction payload shapes decode deterministically")
    func responseDecoding() throws {
        let data = Data(#"{"accounts":[{"id":"acct-1","name":"Checking","currency":"USD","balance":"123.45","available-balance":123.40,"balance-date":"1700000000","conn_id":"conn-1","org":{"id":"org-1","name":"Example"},"transactions":[{"id":"txn-1","amount":-12.34,"posted":1700000000,"transacted_at":"1699990000","description":"Coffee","payee":"Cafe","pending":false}]}],"errors":[]}"#.utf8)
        let response = try JSONDecoder().decode(SimpleFINAccountsResponse.self, from: data)
        #expect(response.accounts.count == 1)
        #expect(response.accounts[0].balance == "123.45")
        #expect(response.accounts[0].transactions[0].postedEpoch == 1_700_000_000)
        #expect(try response.accounts[0].remoteConnectionKey() == "conn:conn-1")
    }

    @Test("Duplicate composite remote identities are rejected")
    func duplicateIdentities() throws {
        let account1 = SimpleFINRemoteAccount(id: "same", currency: "USD", balance: "1", connectionID: "conn")
        let account2 = SimpleFINRemoteAccount(id: "same", currency: "USD", balance: "2", connectionID: "conn")
        #expect(throws: SimpleFINProtocolError.self) {
            try SimpleFINAccountsResponse(accounts: [account1, account2])
        }
    }

    @Test("Credential diagnostics are redacted")
    func credentialRedaction() throws {
        // The password is a synthetic sentinel, not a secret: the negative
        // assertions prove a real-looking value cannot leak into diagnostics,
        // which the exact-equality checks alone would not detect.
        let sentinel = "unit-password-not-a-secret"
        let credential = try SimpleFINCredential(
            host: approvedHost,
            opaquePercentEncodedPathPrefix: "/access",
            existingQueryItems: [],
            existingPercentEncodedQuery: nil,
            username: "unit-user",
            password: sentinel,
            approvedHost: approvedHost
        )
        #expect(String(describing: credential) == "[REDACTED SimpleFIN credential]")
        #expect(String(reflecting: credential) == "[REDACTED SimpleFIN credential]")
        #expect(!String(describing: credential).contains(sentinel))
        #expect(!String(reflecting: credential).contains(sentinel))
    }

    @Test("HTTP response size is bounded while bytes are streamed")
    func streamedResponseSizeLimit() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixedBodyURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let credential = try SimpleFINCredential(
            host: approvedHost,
            opaquePercentEncodedPathPrefix: "/access",
            existingQueryItems: [],
            existingPercentEncodedQuery: nil,
            username: "unit-user",
            password: "unit-password-not-a-secret",
            approvedHost: approvedHost
        )
        let client = SimpleFINClient(
            credential: credential,
            maxResponseBytes: 16,
            urlSession: session
        )
        await #expect(throws: SimpleFINHTTPError.responseTooLarge) {
            _ = try await client.fetchAccounts()
        }
    }

    @Test("Injected URLSession cannot bypass redirect refusal")
    func injectedSessionUsesSecureDelegate() async throws {
        RedirectingURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let credential = try SimpleFINCredential(
            host: approvedHost,
            opaquePercentEncodedPathPrefix: "/access",
            existingQueryItems: [],
            existingPercentEncodedQuery: nil,
            username: "unit-user",
            password: "unit-password-not-a-secret",
            approvedHost: approvedHost
        )
        let client = SimpleFINClient(credential: credential, urlSession: session)

        await #expect(throws: SimpleFINHTTPError.redirectRefused) {
            _ = try await client.fetchAccounts()
        }
        #expect(RedirectingURLProtocol.requestCount == 1)
    }

    @Test("HTTP redirects are refused without forwarding Basic Auth")
    func redirectsAreRefusedWithoutForwardingAuthorization() throws {
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://bridge.simplefin.org/access/accounts")!)
        let response = try #require(
            HTTPURLResponse(
                url: URL(string: "https://bridge.simplefin.org/access/accounts")!,
                statusCode: 302,
                httpVersion: nil,
                headerFields: ["Location": "https://example.invalid/redirect"]
            )
        )
        var redirectedRequest = URLRequest(url: URL(string: "https://example.invalid/redirect")!)
        redirectedRequest.setValue("Basic [REDACTED]", forHTTPHeaderField: "Authorization")
        var acceptedRequest: URLRequest?
        let delegate = SimpleFINURLSessionDelegate()

        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: redirectedRequest
        ) { request in
            acceptedRequest = request
        }

        #expect(acceptedRequest == nil)
        #expect(delegate.consumeRedirectRefusal())
        #expect(!delegate.consumeRedirectRefusal())
    }

    @Test("Retry-After accepts delta-seconds and all HTTP-date forms")
    func retryAfterForms() throws {
        let now = Date(timeIntervalSince1970: 1_445_412_390)
        #expect(SimpleFINClient.retryAfterSeconds("120", now: now) == 120)
        #expect(SimpleFINClient.retryAfterSeconds("Wed, 21 Oct 2015 07:28:00 GMT", now: now) == 90)
        #expect(SimpleFINClient.retryAfterSeconds("Wednesday, 21-Oct-15 07:28:00 GMT", now: now) == 90)
        #expect(SimpleFINClient.retryAfterSeconds("Wed Oct 21 07:28:00 2015", now: now) == 90)
        #expect(SimpleFINClient.retryAfterSeconds("not-a-date", now: now) == nil)
    }

    @Test("Retry-After saturates on oversized values and never traps at Int64 boundaries")
    func retryAfterSaturation() throws {
        let now = Date(timeIntervalSince1970: 1_445_412_390)

        // Delta-seconds: zero, negative, exact-boundary, and oversized values.
        #expect(SimpleFINClient.retryAfterSeconds("0", now: now) == 0)
        #expect(SimpleFINClient.retryAfterSeconds("-5", now: now) == nil)
        #expect(SimpleFINClient.retryAfterSeconds("172800", now: now) == 86_400)
        #expect(SimpleFINClient.retryAfterSeconds("9223372036854775807", now: now) == 86_400)
        #expect(SimpleFINClient.retryAfterSeconds("9223372036854775808", now: now) == 86_400)
        #expect(SimpleFINClient.retryAfterSeconds("99999999999999999999", now: now) == 86_400)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let twoDaysLater = formatter.string(from: now.addingTimeInterval(172_800))
        #expect(SimpleFINClient.retryAfterSeconds(twoDaysLater, now: now) == 86_400)

        // HTTP-date: a past date clamps to 0 (existing contract).
        #expect(SimpleFINClient.retryAfterSeconds("Wed, 21 Oct 2015 07:00:00 GMT", now: Date(timeIntervalSince1970: 1_445_500_000)) == 0)

        // The former conversion trapped when the rounded delta reached exactly
        // 2^63 (Double(Int64.max)). The helper must saturate, not trap.
        #expect(SimpleFINClient.saturatingWholeSeconds(fromPositiveDelta: 0x1p63) == Int64.max)
        #expect(SimpleFINClient.saturatingWholeSeconds(fromPositiveDelta: 1.0e19) == Int64.max)
        #expect(SimpleFINClient.saturatingWholeSeconds(fromPositiveDelta: 9_223_372_036_854_774_784.0) == 9_223_372_036_854_774_784)
        #expect(SimpleFINClient.saturatingWholeSeconds(fromPositiveDelta: 89.2) == 90)
        #expect(SimpleFINClient.saturatingWholeSeconds(fromPositiveDelta: 1.0) == 1)

        // An astronomically distant HTTP-date must not trap regardless of
        // whether the platform date parser accepts the year width: the only
        // legal outcomes are "unparseable" (nil) or the 24-hour cap.
        let distant = SimpleFINClient.retryAfterSeconds("Fri, 01 Jan 999999999999 00:00:00 GMT", now: now)
        #expect(distant == nil || distant == 86_400)
    }
}

@Suite("§4.2 capture sanitizer")
struct CaptureSanitizerTests {
    @Test("shape survives, identity does not")
    func sanitizerShapeAndRedaction() throws {
        let raw = Data("""
        {
          "errors": ["Connection to Real Bank needs attention"],
          "accounts": [
            {
              "org": {"domain": "realbank.example", "name": "Real Bank", "sfin-url": "https://sfin.example/x"},
              "id": "ACT-12345",
              "name": "Household Checking",
              "currency": "USD",
              "balance": "-1234.56",
              "available-balance": "1200.00",
              "balance-date": 1735689600,
              "extra": {"secret-ish": "internal"},
              "transactions": [
                {"id": "TXN-1", "posted": 1735603200, "amount": "-45.67",
                 "description": "COFFEE SHOP 42", "payee": "Coffee Shop", "pending": false},
                {"id": "TXN-1", "posted": 1735603200, "amount": "-45.67",
                 "description": "COFFEE SHOP 42", "payee": "Coffee Shop", "pending": false}
              ]
            }
          ]
        }
        """.utf8)
        let sanitized = try SimpleFINCaptureSanitizer.sanitizedFixture(fromRawJSON: raw)
        let text = String(decoding: sanitized, as: UTF8.self)

        // Identity is gone.
        for leaked in ["ACT-12345", "TXN-1", "Household", "Real Bank", "realbank.example",
                       "COFFEE", "Coffee Shop", "1234.56", "45.67", "internal", "needs attention"] {
            #expect(!text.contains(leaked), "leaked: \(leaked)")
        }
        // Shape survives: keys, epoch values, decimal formatting, error list.
        #expect(text.contains("\"errors\""))
        #expect(text.contains("1735689600"))
        #expect(text.contains("1735603200"))
        #expect(text.contains("-1111.11"))   // "-1234.56" digits replaced, format kept
        #expect(text.contains("\"USD\""))
        #expect(text.contains("\"pending\" : false"))

        // Stable pseudonyms: the duplicated transaction id maps to one token.
        let object = try JSONSerialization.jsonObject(with: sanitized) as! [String: Any]
        let account = (object["accounts"] as! [[String: Any]])[0]
        let transactions = account["transactions"] as! [[String: Any]]
        #expect((transactions[0]["id"] as? String) == (transactions[1]["id"] as? String))
        #expect((account["id"] as? String) != (transactions[0]["id"] as? String))
        // The `extra` blob is emptied, not carried.
        #expect((account["extra"] as? [String: Any])?.isEmpty == true)

        // The sanitized shape still decodes with the defensive models.
        let decoded = try JSONDecoder().decode(SimpleFINAccountsResponse.self, from: sanitized)
        #expect(decoded.accounts.count == 1)
        #expect(decoded.accounts[0].transactions.count == 2)
    }

    @Test("custom currency identifiers are redacted")
    func customCurrencyIdentifierIsRedacted() {
        var sanitizer = SimpleFINCaptureSanitizer()
        let cleaned = sanitizer.sanitize(["currency": "https://currency.example/USD"])
        let dictionary = cleaned as! [String: Any]
        #expect(dictionary["currency"] as? String == "[REDACTED]")
    }

    @Test("unknown numeric keys are sanitized; booleans and approved epochs survive")
    func unknownNumericKeysAreSanitized() throws {
        let raw = Data("""
        {
          "accounts": [
            {
              "id": "ACT-9",
              "currency": "USD",
              "balance": "10.00",
              "balance-date": 1735689600,
              "account_number": 4111111111111111,
              "routing-code": 21000021,
              "internal-score": 987.65,
              "some-flag": true,
              "transactions": []
            }
          ]
        }
        """.utf8)
        let sanitized = try SimpleFINCaptureSanitizer.sanitizedFixture(fromRawJSON: raw)
        let text = String(decoding: sanitized, as: UTF8.self)

        // Unknown numeric values never survive verbatim.
        for leaked in ["4111111111111111", "21000021", "987.65"] {
            #expect(!text.contains(leaked), "leaked: \(leaked)")
        }
        let object = try JSONSerialization.jsonObject(with: sanitized) as! [String: Any]
        let account = (object["accounts"] as! [[String: Any]])[0]
        #expect((account["account_number"] as? NSNumber)?.int64Value == 1)
        #expect((account["routing-code"] as? NSNumber)?.int64Value == 1)
        #expect((account["internal-score"] as? NSNumber)?.int64Value == 1)
        // Approved shape data is retained: epochs on allowlisted keys and
        // one-bit booleans (rendered as a JSON bool, not a number).
        #expect((account["balance-date"] as? NSNumber)?.int64Value == 1_735_689_600)
        #expect(text.contains("\"some-flag\" : true"))
    }
}
