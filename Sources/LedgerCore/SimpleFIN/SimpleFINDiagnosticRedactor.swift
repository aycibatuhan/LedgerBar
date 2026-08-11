import Foundation

/// Central trust boundary for provider-controlled SimpleFIN diagnostics.
///
/// Provider `errors`/`errlist` strings are useful when they contain ordinary
/// institution status text, but they are untrusted and may echo credentials.
/// This deterministic sanitizer removes credential-shaped material before a
/// diagnostic can enter protocol errors, sync outcomes, UI summaries, or the
/// serialized connection state. Inputs and outputs are bounded so a provider
/// cannot create an unbounded diagnostic surface.
public enum SimpleFINDiagnosticRedactor {
    public static let replacement = "[REDACTED]"
    public static let maximumMessageLength = 512
    public static let maximumSummaryLength = 2_048
    public static let maximumDiagnosticCount = 8

    private static let maximumInputLength = 8_192

    /// Ordered from structured credential contexts to more general opaque
    /// credential shapes. Each match is replaced wholesale so partial secret
    /// prefixes cannot survive.
    private static let sensitivePatterns = [
        #"(?i)\b(?:authorization|proxy[\s_-]*authorization)\b\s*(?:=|:)\s*(?:basic|bearer)\s+[^\s,;]+"#,
        #"(?i)\b(?:access[\s_-]*url|api[\s_-]*key|access[\s_-]*token|refresh[\s_-]*token|token|password|passwd|pwd|secret|client[\s_-]*secret|connection[\s_-]*string|user(?:name)?)\b\s*(?:=|:)\s*(?:\"[^\"\r\n]*\"|'[^'\r\n]*'|[^\s,;]+)"#,
        #"(?i)\b(?:basic|bearer)\s+[A-Za-z0-9._~+/=-]{4,}"#,
        #"(?i)\b[a-z][a-z0-9+.-]{1,31}://[^\s<>\"']+"#,
        #"(?i)\bwww\.[^\s<>\"']+"#,
        #"(?i)\bhttps?%3a%2f%2f[^\s<>\"']+"#,
        #"\b[^\s/@:]+:[^\s/@]+@[A-Za-z0-9.-]+(?::[0-9]{1,5})?(?:/[^\s<>\"']*)?"#,
        #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}(?:\.[A-Za-z0-9_-]{8,})?\b"#,
        #"\b(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9_-]{8,}\b"#,
        #"\bgh[pousr]_[A-Za-z0-9]{8,}\b"#,
        #"\bAKIA[A-Z0-9]{12,}\b"#,
        #"(?<![A-Za-z0-9+/_=-])[A-Za-z0-9+/_=-]{32,}(?![A-Za-z0-9+/_=-])"#
    ]

    public static func redact(
        _ diagnostic: String,
        maximumLength: Int = maximumMessageLength
    ) -> String {
        let boundedLength = max(1, maximumLength)
        var sanitized = String(diagnostic.prefix(maximumInputLength))

        for pattern in sensitivePatterns {
            sanitized = sanitized.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }

        sanitized = sanitized.replacingOccurrences(
            of: #"\p{C}+"#,
            with: " ",
            options: .regularExpression
        )
        sanitized = sanitized
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !sanitized.isEmpty else { return replacement }
        guard sanitized.count > boundedLength else { return sanitized }
        if boundedLength == 1 { return "…" }
        return String(sanitized.prefix(boundedLength - 1)) + "…"
    }

    /// Sanitizes and bounds a provider error array without erasing the fact
    /// that additional diagnostics existed.
    public static func redact(_ diagnostics: [String]) -> [String] {
        guard !diagnostics.isEmpty else { return [] }
        var result = diagnostics.prefix(maximumDiagnosticCount).map { redact($0) }
        if diagnostics.count > maximumDiagnosticCount {
            result.append("Additional provider diagnostics omitted.")
        }
        return result
    }

    /// Safe aggregate used by outward error and sync-summary surfaces. It
    /// deliberately re-sanitizes its input so callers cannot bypass the
    /// response-model boundary by constructing an error directly.
    public static func summary(_ diagnostics: [String]) -> String {
        redact(
            redact(diagnostics).joined(separator: "; "),
            maximumLength: maximumSummaryLength
        )
    }

    /// Final UI/status boundary for summaries assembled from many accounts.
    /// Unlike provider-diagnostic aggregation, this preserves the leading
    /// status fragments while bounding the final text independently of link
    /// and account cardinality.
    public static func statusSummary(_ fragments: [String]) -> String {
        redact(
            fragments.joined(separator: " "),
            maximumLength: maximumSummaryLength
        )
    }
}
