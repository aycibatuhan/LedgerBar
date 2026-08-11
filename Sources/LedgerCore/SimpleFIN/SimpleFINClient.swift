import Foundation

public enum SimpleFINHTTPError: Error, Equatable, Sendable {
    case status(code: Int, retryAfterSeconds: Int64?)
    case responseTooLarge
    case invalidUTF8Response
    case redirectRefused
    case transport(String)
}

public struct SimpleFINClaimResult: Sendable, Equatable {
    public var credential: SimpleFINCredential
    public var returnedHostDiffersFromClaimHost: Bool

    public init(credential: SimpleFINCredential, returnedHostDiffersFromClaimHost: Bool) {
        self.credential = credential
        self.returnedHostDiffersFromClaimHost = returnedHostDiffersFromClaimHost
    }
}

public struct SimpleFINRequest: Sendable, Equatable {
    public var window: SimpleFINRequestWindow?
    public var accountID: String?
    public var balancesOnly: Bool
    public var version2: Bool

    public init(
        window: SimpleFINRequestWindow? = nil,
        accountID: String? = nil,
        balancesOnly: Bool = false,
        version2: Bool = false
    ) {
        self.window = window
        self.accountID = accountID
        self.balancesOnly = balancesOnly
        self.version2 = version2
    }
}

public enum SimpleFINURLValidator {
    public static let officialBridgeHost = "bridge.simplefin.org"
    private static let reservedQueryKeys: Set<String> = [
        "start-date", "end-date", "account", "balances-only", "pending", "version"
    ]

    public static func decodeSetupToken(_ token: String, trustedHosts: Set<SimpleFINHost> = []) throws -> URL {
        guard let data = Data(base64Encoded: token),
              let string = String(data: data, encoding: .utf8),
              let url = URL(string: string) else {
            throw SimpleFINProtocolError.invalidSetupToken
        }
        try validateClaimURL(url, trustedHosts: trustedHosts)
        return url
    }

    public static func validateClaimURL(_ url: URL, trustedHosts: Set<SimpleFINHost> = []) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              !components.path.isEmpty else {
            throw SimpleFINProtocolError.invalidClaimEndpoint
        }
        let port = components.port ?? 443
        guard port == 443 || trustedHosts.contains(where: { $0.host == host && $0.port == port }) else {
            throw SimpleFINProtocolError.untrustedHost(host)
        }
        guard host == officialBridgeHost || trustedHosts.contains(where: { $0.host == host && $0.port == port }) else {
            throw SimpleFINProtocolError.untrustedHost(host)
        }
    }

    public static func parseAccessURL(_ url: URL, approvedHosts: Set<SimpleFINHost>) throws -> SimpleFINCredential {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              components.fragment == nil,
              !components.path.isEmpty,
              let username = components.user,
              let password = components.password,
              !username.isEmpty,
              !password.isEmpty else {
            throw SimpleFINProtocolError.invalidAccessURL
        }
        let port = components.port ?? 443
        let remoteHost = try SimpleFINHost(host: host, port: port)
        guard port == 443 || approvedHosts.contains(remoteHost),
              host == officialBridgeHost || approvedHosts.contains(remoteHost) else {
            throw SimpleFINProtocolError.untrustedHost(host)
        }
        let queryItems = try parseQueryItems(components.percentEncodedQuery)
        return try SimpleFINCredential(
            host: remoteHost,
            opaquePercentEncodedPathPrefix: components.percentEncodedPath,
            existingQueryItems: queryItems,
            existingPercentEncodedQuery: components.percentEncodedQuery,
            username: username,
            password: password,
            approvedHost: remoteHost
        )
    }

    static func parseQueryItems(_ query: String?) throws -> [SimpleFINQueryItem] {
        guard let query, !query.isEmpty else { return [] }
        guard let components = URLComponents(string: "https://invalid.example/?\(query)"),
              let items = components.queryItems else {
            throw SimpleFINProtocolError.invalidAccessURL
        }
        return items.map { SimpleFINQueryItem(name: $0.name, value: $0.value) }
    }

    static func appendQueryPair(_ name: String, _ value: String) -> String {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: name, value: value)]
        return components.percentEncodedQuery ?? ""
    }

    static func isReserved(_ name: String) -> Bool { reservedQueryKeys.contains(name) }
}

fileprivate final class SimpleFINResponseAccumulator: @unchecked Sendable {
    private let maxResponseBytes: Int
    private let lock = NSLock()
    private var data = Data()
    private var response: URLResponse?
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var finished = false

    init(maxResponseBytes: Int) {
        self.maxResponseBytes = maxResponseBytes
    }

    func install(_ continuation: CheckedContinuation<(Data, URLResponse), Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func receive(response: URLResponse) -> URLSession.ResponseDisposition {
        if response.expectedContentLength > Int64(maxResponseBytes) {
            finish(.failure(SimpleFINHTTPError.responseTooLarge))
            return .cancel
        }

        lock.lock()
        guard !finished else {
            lock.unlock()
            return .cancel
        }
        self.response = response
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(response.expectedContentLength), maxResponseBytes))
        }
        lock.unlock()
        return .allow
    }

    func receive(data chunk: Data) -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return false
        }
        guard chunk.count <= maxResponseBytes - data.count else {
            lock.unlock()
            finish(.failure(SimpleFINHTTPError.responseTooLarge))
            return false
        }
        data.append(chunk)
        lock.unlock()
        return true
    }

    func complete(error: Error?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        let result: Result<(Data, URLResponse), Error>
        if let error {
            result = .failure(error)
        } else if let response {
            result = .success((data, response))
        } else {
            result = .failure(SimpleFINHTTPError.transport("missing HTTP response"))
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func finish(_ result: Result<(Data, URLResponse), Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

public final class SimpleFINURLSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let redirectLock = NSLock()
    private var redirectWasRefused = false
    private let responseLock = NSLock()
    private var responseAccumulators: [Int: SimpleFINResponseAccumulator] = [:]

    public override init() { super.init() }

    func consumeRedirectRefusal() -> Bool {
        redirectLock.lock()
        defer { redirectLock.unlock() }
        let refused = redirectWasRefused
        redirectWasRefused = false
        return refused
    }

    fileprivate func register(_ accumulator: SimpleFINResponseAccumulator, for task: URLSessionDataTask) {
        responseLock.lock()
        responseAccumulators[task.taskIdentifier] = accumulator
        responseLock.unlock()
    }

    private func accumulator(for task: URLSessionTask) -> SimpleFINResponseAccumulator? {
        responseLock.lock()
        defer { responseLock.unlock() }
        return responseAccumulators[task.taskIdentifier]
    }

    private func removeAccumulator(for task: URLSessionTask) -> SimpleFINResponseAccumulator? {
        responseLock.lock()
        defer { responseLock.unlock() }
        return responseAccumulators.removeValue(forKey: task.taskIdentifier)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Never forward Basic Auth across a redirect.
        redirectLock.lock()
        redirectWasRefused = true
        redirectLock.unlock()
        completionHandler(nil)
    }

    public func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        completionHandler(accumulator(for: dataTask)?.receive(response: response) ?? .cancel)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard accumulator(for: dataTask)?.receive(data: data) == true else {
            dataTask.cancel()
            return
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        removeAccumulator(for: task)?.complete(error: error)
    }
}

public final class SimpleFINClient: @unchecked Sendable {
    private let credential: SimpleFINCredential
    private let delegate: SimpleFINURLSessionDelegate
    private let session: URLSession
    private let timeout: TimeInterval
    private let maxResponseBytes: Int

    public init(
        credential: SimpleFINCredential,
        timeout: TimeInterval = 30,
        maxResponseBytes: Int = 5 * 1024 * 1024,
        urlSession: URLSession? = nil
    ) {
        self.credential = credential
        self.timeout = timeout
        self.maxResponseBytes = maxResponseBytes
        self.delegate = SimpleFINURLSessionDelegate()
        // Clone an injected session's configuration instead of using its
        // delegate. This preserves URLProtocol-based tests while ensuring
        // every request uses our redirect refusal and bounded collector.
        let configuration = urlSession?.configuration ?? URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = max(timeout, 120)
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func claimSetupToken(
        setupToken: String,
        trustedHosts: Set<SimpleFINHost> = [],
        now: Date = Date()
    ) async throws -> SimpleFINClaimResult {
        try await Self.claim(setupToken: setupToken, trustedHosts: trustedHosts, now: now)
    }

    /// Claiming is unauthenticated and therefore intentionally static: an
    /// Access-URL client must never be used to POST a Setup Token.
    public static func claim(
        setupToken: String,
        trustedHosts: Set<SimpleFINHost> = [],
        now: Date = Date()
    ) async throws -> SimpleFINClaimResult {
        let timeout: TimeInterval = 30
        let maxResponseBytes = 5 * 1024 * 1024
        let claimURL = try SimpleFINURLValidator.decodeSetupToken(setupToken, trustedHosts: trustedHosts)
        let claimHost = URLComponents(url: claimURL, resolvingAgainstBaseURL: false)?.host?.lowercased()
        var request = URLRequest(url: claimURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = Data()
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        let delegate = SimpleFINURLSessionDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = max(timeout, 120)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await readBoundedResponse(
                session: session,
                delegate: delegate,
                request: request,
                maxResponseBytes: maxResponseBytes
            )
        } catch let error as SimpleFINHTTPError {
            throw error
        } catch {
            if delegate.consumeRedirectRefusal() {
                throw SimpleFINHTTPError.redirectRefused
            }
            throw SimpleFINHTTPError.transport("claim request failed")
        }
        guard let http = response as? HTTPURLResponse else {
            throw SimpleFINHTTPError.transport("missing HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let retry = retryAfterSeconds(http.value(forHTTPHeaderField: "Retry-After"), now: now)
            throw SimpleFINHTTPError.status(code: http.statusCode, retryAfterSeconds: retry)
        }
        guard let text = String(data: data, encoding: .utf8),
              let accessURL = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw SimpleFINProtocolError.invalidAccessURL
        }
        var approved = trustedHosts
        if let claimHost { approved.insert(try SimpleFINHost(host: claimHost)) }
        let credential = try SimpleFINURLValidator.parseAccessURL(accessURL, approvedHosts: approved)
        return SimpleFINClaimResult(
            credential: credential,
            returnedHostDiffersFromClaimHost: credential.host.host != claimHost
        )
    }

    public func fetchAccounts(_ request: SimpleFINRequest = SimpleFINRequest(), now: Date = Date()) async throws -> SimpleFINAccountsResponse {
        let url = try makeAccountsURL(request)
        var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue(basicAuthorizationHeader(), forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await perform(urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw SimpleFINHTTPError.transport("missing HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw try await httpError(http, now: now)
        }
        guard data.count <= maxResponseBytes else { throw SimpleFINHTTPError.responseTooLarge }
        do {
            let decoded = try JSONDecoder().decode(SimpleFINAccountsResponse.self, from: data)
            try decoded.validateUniqueAccountIdentities()
            return decoded
        } catch let error as SimpleFINProtocolError {
            throw error
        } catch {
            throw SimpleFINProtocolError.invalidResponse("accounts payload did not match supported shapes")
        }
    }

    /// Raw `/accounts` fetch for the §4.2 capture command: identical URL
    /// construction, validation, redirect refusal, and size bounds as
    /// `fetchAccounts`, but returns the undecoded body so the deployed
    /// response *shape* can be captured before Codable models are frozen.
    /// The caller (capture tool) is responsible for restricted-permission
    /// storage, sanitization, and deletion of the raw bytes.
    public func fetchAccountsRawForCapture(
        _ request: SimpleFINRequest = SimpleFINRequest(),
        now: Date = Date()
    ) async throws -> Data {
        let url = try makeAccountsURL(request)
        var urlRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue(basicAuthorizationHeader(), forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await perform(urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw SimpleFINHTTPError.transport("missing HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw try await httpError(http, now: now)
        }
        guard data.count <= maxResponseBytes else { throw SimpleFINHTTPError.responseTooLarge }
        return data
    }

    public func makeAccountsURL(_ request: SimpleFINRequest) throws -> URL {
        let existingNames = Set(credential.existingQueryItems.map(\.name))
        guard existingNames.isDisjoint(with: ["start-date", "end-date", "account", "balances-only", "pending", "version"]) else {
            throw SimpleFINProtocolError.invalidAccessURL
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = credential.host.host
        if credential.host.port != 443 { components.port = credential.host.port }
        components.percentEncodedPath = accountsPath
        var query = credential.existingPercentEncodedQuery ?? ""
        func append(_ name: String, _ value: String) {
            let pair = SimpleFINURLValidator.appendQueryPair(name, value)
            query = query.isEmpty ? pair : query + "&" + pair
        }
        if let window = request.window {
            append("start-date", String(window.startEpoch))
            if let end = window.endEpoch { append("end-date", String(end)) }
        }
        if let accountID = request.accountID { append("account", accountID) }
        if request.balancesOnly { append("balances-only", "1") }
        // v1 never requests pending rows. Explicit 0 makes the posted-only
        // initial-link contract visible without ever sending pending=1.
        append("pending", "0")
        if request.version2 { append("version", "2") }
        components.percentEncodedQuery = query.isEmpty ? nil : query
        guard let url = components.url,
              url.scheme == "https",
              url.host?.lowercased() == credential.host.host,
              (url.port ?? 443) == credential.host.port else {
            throw SimpleFINProtocolError.invalidAccessURL
        }
        return url
    }

    private func basicAuthorizationHeader() -> String {
        let raw = Data("\(credential.username):\(credential.password)".utf8).base64EncodedString()
        return "Basic \(raw)"
    }

    private var accountsPath: String {
        let prefix = credential.opaquePercentEncodedPathPrefix.hasSuffix("/")
            ? String(credential.opaquePercentEncodedPathPrefix.dropLast())
            : credential.opaquePercentEncodedPathPrefix
        return prefix + "/accounts"
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == credential.host.host,
              (url.port ?? 443) == credential.host.port,
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath == accountsPath else {
            throw SimpleFINProtocolError.invalidAccessURL
        }
        do {
            return try await Self.readBoundedResponse(
                session: session,
                delegate: delegate,
                request: request,
                maxResponseBytes: maxResponseBytes
            )
        } catch let error as SimpleFINHTTPError {
            throw error
        } catch {
            if delegate.consumeRedirectRefusal() {
                throw SimpleFINHTTPError.redirectRefused
            }
            throw SimpleFINHTTPError.transport("request failed")
        }
    }

    private static func readBoundedResponse(
        session: URLSession,
        delegate: SimpleFINURLSessionDelegate,
        request: URLRequest,
        maxResponseBytes: Int
    ) async throws -> (Data, URLResponse) {
        return try await withCheckedThrowingContinuation { continuation in
            let accumulator = SimpleFINResponseAccumulator(maxResponseBytes: maxResponseBytes)
            accumulator.install(continuation)
            let task = session.dataTask(with: request)
            delegate.register(accumulator, for: task)
            task.resume()
        }
    }

    private func httpError(_ response: HTTPURLResponse, now: Date) async throws -> Error {
        let retry = Self.retryAfterSeconds(response.value(forHTTPHeaderField: "Retry-After"), now: now)
        return SimpleFINHTTPError.status(code: response.statusCode, retryAfterSeconds: retry)
    }

    private static let maximumRetryAfterSeconds: Int64 = 86_400

    static func retryAfterSeconds(_ value: String?, now: Date) -> Int64? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.utf8.allSatisfy({ (48...57).contains($0) }) {
            // All-digit values are valid non-negative delta-seconds even when
            // they overflow Int64; saturate instead of treating an enormous
            // requested backoff as absent (fail closed, not fail open).
            return min(Int64(value) ?? Int64.max, Self.maximumRetryAfterSeconds)
        }

        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz", // IMF-fixdate / RFC 1123
            "EEEE, dd-MMM-yy HH:mm:ss zzz",  // RFC 850 obsolete form
            "EEE MMM d HH:mm:ss yyyy"         // ANSI C asctime obsolete form
        ]
        let date: Date? = formats.lazy.compactMap { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            formatter.isLenient = false
            return formatter.date(from: value)
        }.first
        guard let date else { return nil }
        let delta = date.timeIntervalSince(now)
        guard delta.isFinite else { return nil }
        if delta <= 0 { return 0 }
        return min(
            Self.saturatingWholeSeconds(fromPositiveDelta: delta),
            Self.maximumRetryAfterSeconds
        )
    }

    /// Non-trapping ceiling conversion of a positive, finite time interval to
    /// whole seconds, saturating at `Int64.max`. `Double(Int64.max)` rounds up
    /// to exactly 2^63, which is outside `Int64`'s range, so the boundary must
    /// be compared against 2^63 rather than produced by a trapping conversion.
    static func saturatingWholeSeconds(fromPositiveDelta delta: TimeInterval) -> Int64 {
        let rounded = delta.rounded(.up)
        guard rounded < 0x1p63 else { return Int64.max }
        return Int64(rounded)
    }
}
