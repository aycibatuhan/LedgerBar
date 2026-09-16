import Foundation

// MARK: - JSON value (docs/LOCAL-AI.md A3)

/// Minimal JSON model for tool arguments and results. Tool results are data,
/// never instructions (A8); they are serialized from this type only.
public indirect enum JSONValue: Sendable, Equatable, Codable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let b = try? container.decode(Bool.self) { self = .bool(b); return }
        if let n = try? container.decode(Double.self) { self = .number(n); return }
        if let s = try? container.decode(String.self) { self = .string(s); return }
        if let a = try? container.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? container.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var doubleValue: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }
    public var intValue: Int? { doubleValue.flatMap { $0.rounded() == $0 && abs($0) < 9e15 ? Int($0) : nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var stringArray: [String]? { arrayValue?.compactMap(\.stringValue) }

    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    public func serialized(pretty: Bool = false) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
}

// MARK: - Tool schema and validation

/// A subset of JSON Schema sufficient for tool parameters: object with typed
/// properties, `required`, `enum`, integer ranges, arrays of strings.
public struct ToolParameter: Sendable, Equatable {
    public enum Kind: String, Sendable { case string, integer, number, boolean, stringArray }
    public var name: String
    public var kind: Kind
    public var description: String
    public var required: Bool
    public var enumValues: [String]?
    public var minimum: Double?
    public var maximum: Double?

    public init(_ name: String, _ kind: Kind, _ description: String, required: Bool = false, enumValues: [String]? = nil, minimum: Double? = nil, maximum: Double? = nil) {
        self.name = name
        self.kind = kind
        self.description = description
        self.required = required
        self.enumValues = enumValues
        self.minimum = minimum
        self.maximum = maximum
    }

    var schema: JSONValue {
        var object: [String: JSONValue] = ["description": .string(description)]
        switch kind {
        case .string: object["type"] = .string("string")
        case .integer: object["type"] = .string("integer")
        case .number: object["type"] = .string("number")
        case .boolean: object["type"] = .string("boolean")
        case .stringArray: object["type"] = .string("array"); object["items"] = .object(["type": .string("string")])
        }
        if let enumValues { object["enum"] = .array(enumValues.map(JSONValue.string)) }
        if let minimum { object["minimum"] = .number(minimum) }
        if let maximum { object["maximum"] = .number(maximum) }
        return .object(object)
    }
}

public enum ToolPermission: String, Sendable, Codable {
    /// Read-only query over the loaded budget.
    case read
    /// Produces a proposal or navigation; never mutates.
    case draft
}

public struct AssistantToolDescriptor: Sendable, Equatable, Identifiable {
    public var name: String
    public var description: String
    public var parameters: [ToolParameter]
    public var permission: ToolPermission
    public var id: String { name }

    public var parametersSchema: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(Dictionary(uniqueKeysWithValues: parameters.map { ($0.name, $0.schema) })),
            "required": .array(parameters.filter(\.required).map { .string($0.name) })
        ])
    }

    /// OpenAI/Ollama-style function definition.
    public var functionDefinition: JSONValue {
        .object([
            "type": .string("function"),
            "function": .object([
                "name": .string(name),
                "description": .string(description),
                "parameters": parametersSchema
            ])
        ])
    }
}

public struct AssistantToolCall: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var arguments: JSONValue

    public init(id: String = UUID().uuidString, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct AssistantToolError: Error, Equatable, Sendable, Codable {
    public enum Code: String, Sendable, Codable {
        case unknownTool
        case invalidArguments
        case notPermitted
        case notFound
        case unsupported
    }
    public var code: Code
    public var message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }
}

/// A tool result: structured payload plus provenance (category line ids and
/// the filter that produced it) so the UI can show "the transactions
/// behind this number". `truncated` tells the model to narrow.
public struct AssistantToolResult: Sendable, Equatable, Codable, Identifiable {
    public var id: String { callID }
    public var callID: String
    public var name: String
    public var payload: JSONValue
    public var provenanceLineIDs: [String]
    public var truncated: Bool
    public var error: AssistantToolError?
    /// Set when a tool produced a report the UI can render natively.
    public var reportDefinition: ReportDefinition?
    /// Set when a draft tool produced a proposal the UI can offer to apply.
    public var proposal: ProposedAction?

    public init(callID: String, name: String, payload: JSONValue, provenanceLineIDs: [String] = [], truncated: Bool = false, error: AssistantToolError? = nil, reportDefinition: ReportDefinition? = nil, proposal: ProposedAction? = nil) {
        self.callID = callID
        self.name = name
        self.payload = payload
        self.provenanceLineIDs = provenanceLineIDs
        self.truncated = truncated
        self.error = error
        self.reportDefinition = reportDefinition
        self.proposal = proposal
    }

    /// The text the model sees: a data envelope. Content inside is never an
    /// instruction (A8).
    public var modelText: String {
        var object: [String: JSONValue] = ["tool": .string(name), "data": payload]
        if truncated { object["truncated"] = .bool(true) }
        if let error { object["error"] = .object(["code": .string(error.code.rawValue), "message": .string(error.message)]) }
        return "<data>" + JSONValue.object(object).serialized() + "</data>"
    }
}

// MARK: - Money formatting for tool payloads

enum AssistantFormat {
    static func decimal(_ milliunits: Milliunits) -> String {
        MoneyParser.decimalString(fromMilliunits: milliunits)
    }

    static func money(_ milliunits: Milliunits, currency: String) -> JSONValue {
        .object(["amount": .string(decimal(milliunits)), "currency": .string(currency), "milliunits": .number(Double(milliunits))])
    }
}
