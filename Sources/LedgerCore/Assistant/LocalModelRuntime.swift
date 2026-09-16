import Foundation

// MARK: - Loopback-only endpoint policy (docs/LOCAL-AI.md A1)

public enum LocalEndpointError: Error, Equatable, Sendable {
    case notLoopback(String)
    case invalidURL
}

public enum LocalEndpointPolicy {
    /// Accepts only `http`/`https` URLs whose host is a loopback address.
    /// There is no override.
    public static func validate(_ string: String) throws -> URL {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else {
            throw LocalEndpointError.invalidURL
        }
        guard isLoopback(host) else { throw LocalEndpointError.notLoopback(host) }
        guard url.user == nil, url.password == nil else { throw LocalEndpointError.invalidURL }
        return url
    }

    public static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h.hasSuffix(".localhost") { return true }
        if h == "::1" || h == "0:0:0:0:0:0:0:1" { return true }
        if h.hasPrefix("127.") {
            let parts = h.split(separator: ".")
            return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
        }
        return false
    }
}

// MARK: - Runtime abstraction (A2)

public enum LocalRuntimeKind: String, Sendable, Codable, CaseIterable {
    case none
    case ollama
    case openAICompatible

    public var title: String {
        switch self {
        case .none: return "No model (structured answers only)"
        case .ollama: return "Ollama (local)"
        case .openAICompatible: return "OpenAI-compatible local server"
        }
    }
}

public struct LocalModelInfo: Sendable, Equatable, Identifiable, Codable {
    public var name: String
    public var sizeBytes: Int64?
    public var parameterSize: String?
    public var supportsTools: Bool?
    public var contextLength: Int?
    public var id: String { name }

    public init(name: String, sizeBytes: Int64? = nil, parameterSize: String? = nil, supportsTools: Bool? = nil, contextLength: Int? = nil) {
        self.name = name
        self.sizeBytes = sizeBytes
        self.parameterSize = parameterSize
        self.supportsTools = supportsTools
        self.contextLength = contextLength
    }
}

public enum ChatRole: String, Sendable, Codable {
    case system, user, assistant, tool
}

public struct ChatMessage: Sendable, Equatable, Codable {
    public var role: ChatRole
    public var content: String
    public var toolCalls: [AssistantToolCall]?
    /// For `tool` messages: the call this answers.
    public var toolCallID: String?
    public var toolName: String?

    public init(role: ChatRole, content: String, toolCalls: [AssistantToolCall]? = nil, toolCallID: String? = nil, toolName: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.toolName = toolName
    }
}

public struct ChatRequest: Sendable, Equatable {
    public var model: String
    public var messages: [ChatMessage]
    public var tools: [AssistantToolDescriptor]
    public var temperature: Double
    public var maxTokens: Int?
    public var keepAliveSeconds: Int?
    /// When set, ask for a JSON object (used by the no-tools fallback, A5.2).
    public var jsonMode: Bool

    public init(model: String, messages: [ChatMessage], tools: [AssistantToolDescriptor], temperature: Double = 0.1, maxTokens: Int? = nil, keepAliveSeconds: Int? = nil, jsonMode: Bool = false) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.keepAliveSeconds = keepAliveSeconds
        self.jsonMode = jsonMode
    }
}

public enum ChatEvent: Sendable, Equatable {
    case token(String)
    case toolCalls([AssistantToolCall])
    case done
}

public enum LocalRuntimeError: Error, Equatable, Sendable {
    case unavailable(String)
    case httpStatus(Int)
    case malformedResponse
    case timeout
    case cancelled
}

public struct RuntimeDescriptor: Sendable, Equatable {
    public var kind: LocalRuntimeKind
    public var endpoint: String
    public var supportsToolCalling: Bool
}

public protocol LocalModelRuntime: Sendable {
    var descriptor: RuntimeDescriptor { get }
    func listModels() async throws -> [LocalModelInfo]
    func chat(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
    func unload(model: String) async
}

// MARK: - Ollama (A2.1)

/// Ollama's native API over loopback only. Streaming NDJSON; tool calls are
/// delivered as `message.tool_calls`. The session is ephemeral (no cache).
public struct OllamaRuntime: LocalModelRuntime {
    public let baseURL: URL
    public let descriptor: RuntimeDescriptor
    private let session: URLSession

    public init(endpoint: String = "http://127.0.0.1:11434", requestTimeout: TimeInterval = 120) throws {
        self.baseURL = try LocalEndpointPolicy.validate(endpoint)
        self.descriptor = RuntimeDescriptor(kind: .ollama, endpoint: baseURL.absoluteString, supportsToolCalling: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout * 4
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
    }

    private func request(_ path: String, body: JSONValue?) throws -> URLRequest {
        let url = try LocalEndpointPolicy.validate(baseURL.appendingPathComponent(path).absoluteString)
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.serialized().utf8)
        }
        return request
    }

    public func listModels() async throws -> [LocalModelInfo] {
        let (data, response) = try await session.data(for: request("api/tags", body: nil))
        guard let http = response as? HTTPURLResponse else { throw LocalRuntimeError.malformedResponse }
        guard http.statusCode == 200 else { throw LocalRuntimeError.httpStatus(http.statusCode) }
        let json = try JSONValue.parse(data)
        return (json["models"]?.arrayValue ?? []).compactMap { entry in
            guard let name = entry["name"]?.stringValue ?? entry["model"]?.stringValue else { return nil }
            let capabilities = entry["capabilities"]?.stringArray
            return LocalModelInfo(
                name: name,
                sizeBytes: entry["size"]?.doubleValue.map { Int64($0) },
                parameterSize: entry["details"]?["parameter_size"]?.stringValue,
                supportsTools: capabilities.map { $0.contains("tools") },
                contextLength: entry["details"]?["context_length"]?.intValue
            )
        }
    }

    public func chat(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var body: [String: JSONValue] = [
                        "model": .string(request.model),
                        "messages": .array(request.messages.map(Self.encode)),
                        "stream": .bool(true),
                        "options": .object(["temperature": .number(request.temperature)] .merging(request.maxTokens.map { ["num_predict": .number(Double($0))] } ?? [:]) { $1 })
                    ]
                    if !request.tools.isEmpty { body["tools"] = .array(request.tools.map(\.functionDefinition)) }
                    if let keepAlive = request.keepAliveSeconds { body["keep_alive"] = .number(Double(keepAlive)) }
                    if request.jsonMode { body["format"] = .string("json") }
                    let (bytes, response) = try await session.bytes(for: self.request("api/chat", body: .object(body)))
                    guard let http = response as? HTTPURLResponse else { throw LocalRuntimeError.malformedResponse }
                    guard http.statusCode == 200 else { throw LocalRuntimeError.httpStatus(http.statusCode) }
                    for try await line in bytes.lines {
                        guard !line.isEmpty, let json = try? JSONValue.parse(line) else { continue }
                        if let calls = json["message"]?["tool_calls"]?.arrayValue, !calls.isEmpty {
                            continuation.yield(.toolCalls(calls.compactMap(Self.decodeToolCall)))
                        }
                        if let content = json["message"]?["content"]?.stringValue, !content.isEmpty {
                            continuation.yield(.token(content))
                        }
                        if json["done"]?.boolValue == true { break }
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: LocalRuntimeError.cancelled)
                } catch let error as URLError where error.code == .timedOut {
                    continuation.finish(throwing: LocalRuntimeError.timeout)
                } catch let error as URLError {
                    continuation.finish(throwing: LocalRuntimeError.unavailable(error.localizedDescription))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func unload(model: String) async {
        _ = try? await session.data(for: request("api/generate", body: .object(["model": .string(model), "keep_alive": .number(0)])))
    }

    static func encode(_ message: ChatMessage) -> JSONValue {
        var object: [String: JSONValue] = ["role": .string(message.role.rawValue), "content": .string(message.content)]
        if let calls = message.toolCalls, !calls.isEmpty {
            object["tool_calls"] = .array(calls.map {
                .object(["function": .object(["name": .string($0.name), "arguments": $0.arguments])])
            })
        }
        if let name = message.toolName { object["tool_name"] = .string(name) }
        return .object(object)
    }

    static func decodeToolCall(_ value: JSONValue) -> AssistantToolCall? {
        guard let name = value["function"]?["name"]?.stringValue else { return nil }
        let arguments = value["function"]?["arguments"] ?? .object([:])
        let parsed: JSONValue
        if let text = arguments.stringValue, let decoded = try? JSONValue.parse(text) { parsed = decoded } else { parsed = arguments }
        return AssistantToolCall(name: name, arguments: parsed)
    }
}

// MARK: - OpenAI-compatible local server (A2.2)

/// Any loopback server speaking `/v1/chat/completions` (LM Studio,
/// llama.cpp server, vLLM on localhost). Non-streaming for simplicity; the
/// same loopback policy applies.
public struct OpenAICompatibleLocalRuntime: LocalModelRuntime {
    public let baseURL: URL
    public let descriptor: RuntimeDescriptor
    private let session: URLSession

    public init(endpoint: String = "http://127.0.0.1:1234", requestTimeout: TimeInterval = 120) throws {
        self.baseURL = try LocalEndpointPolicy.validate(endpoint)
        self.descriptor = RuntimeDescriptor(kind: .openAICompatible, endpoint: baseURL.absoluteString, supportsToolCalling: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration)
    }

    private func request(_ path: String, body: JSONValue?) throws -> URLRequest {
        let url = try LocalEndpointPolicy.validate(baseURL.appendingPathComponent(path).absoluteString)
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.serialized().utf8)
        }
        return request
    }

    public func listModels() async throws -> [LocalModelInfo] {
        let (data, response) = try await session.data(for: request("v1/models", body: nil))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw LocalRuntimeError.malformedResponse }
        let json = try JSONValue.parse(data)
        return (json["data"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue.map { LocalModelInfo(name: $0) } }
    }

    public func chat(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var body: [String: JSONValue] = [
                        "model": .string(request.model),
                        "messages": .array(request.messages.map(Self.encode)),
                        "temperature": .number(request.temperature),
                        "stream": .bool(false)
                    ]
                    if let maxTokens = request.maxTokens { body["max_tokens"] = .number(Double(maxTokens)) }
                    if !request.tools.isEmpty { body["tools"] = .array(request.tools.map(\.functionDefinition)) }
                    if request.jsonMode { body["response_format"] = .object(["type": .string("json_object")]) }
                    let (data, response) = try await session.data(for: self.request("v1/chat/completions", body: .object(body)))
                    guard let http = response as? HTTPURLResponse else { throw LocalRuntimeError.malformedResponse }
                    guard http.statusCode == 200 else { throw LocalRuntimeError.httpStatus(http.statusCode) }
                    let json = try JSONValue.parse(data)
                    guard let message = json["choices"]?.arrayValue?.first?["message"] else { throw LocalRuntimeError.malformedResponse }
                    if let calls = message["tool_calls"]?.arrayValue, !calls.isEmpty {
                        continuation.yield(.toolCalls(calls.compactMap { call in
                            guard let name = call["function"]?["name"]?.stringValue else { return nil }
                            let raw = call["function"]?["arguments"]
                            let arguments = raw?.stringValue.flatMap { try? JSONValue.parse($0) } ?? raw ?? .object([:])
                            return AssistantToolCall(id: call["id"]?.stringValue ?? UUID().uuidString, name: name, arguments: arguments)
                        }))
                    }
                    if let content = message["content"]?.stringValue, !content.isEmpty { continuation.yield(.token(content)) }
                    continuation.yield(.done)
                    continuation.finish()
                } catch let error as URLError where error.code == .timedOut {
                    continuation.finish(throwing: LocalRuntimeError.timeout)
                } catch let error as URLError {
                    continuation.finish(throwing: LocalRuntimeError.unavailable(error.localizedDescription))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func unload(model: String) async {}

    static func encode(_ message: ChatMessage) -> JSONValue {
        var object: [String: JSONValue] = ["role": .string(message.role.rawValue), "content": .string(message.content)]
        if let calls = message.toolCalls, !calls.isEmpty {
            object["tool_calls"] = .array(calls.map {
                .object(["id": .string($0.id), "type": .string("function"), "function": .object(["name": .string($0.name), "arguments": .string($0.arguments.serialized())])])
            })
        }
        if let id = message.toolCallID { object["tool_call_id"] = .string(id) }
        return .object(object)
    }
}

// MARK: - Assistant settings (A12)

public struct AssistantSettings: Sendable, Codable, Equatable {
    public var enabled: Bool
    public var runtimeKind: LocalRuntimeKind
    public var endpoint: String
    public var model: String
    public var keepAliveSeconds: Int
    public var saveHistory: Bool
    public var temperature: Double
    public var maxTokens: Int
    public var maxToolRounds: Int

    public init(
        enabled: Bool = false,
        runtimeKind: LocalRuntimeKind = .ollama,
        endpoint: String = "http://127.0.0.1:11434",
        model: String = "",
        keepAliveSeconds: Int = 300,
        saveHistory: Bool = false,
        temperature: Double = 0.1,
        maxTokens: Int = 1_024,
        maxToolRounds: Int = 8
    ) {
        self.enabled = enabled
        self.runtimeKind = runtimeKind
        self.endpoint = endpoint
        self.model = model
        self.keepAliveSeconds = keepAliveSeconds
        self.saveHistory = saveHistory
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.maxToolRounds = maxToolRounds
    }

    public static let settingKey = "assistantSettings"

    /// Builds the runtime, or nil for `.none`. Throws for a non-loopback
    /// endpoint so a bad setting can never produce a remote client.
    public func makeRuntime() throws -> (any LocalModelRuntime)? {
        switch runtimeKind {
        case .none: return nil
        case .ollama: return try OllamaRuntime(endpoint: endpoint)
        case .openAICompatible: return try OpenAICompatibleLocalRuntime(endpoint: endpoint)
        }
    }
}
