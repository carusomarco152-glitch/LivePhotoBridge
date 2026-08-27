import Foundation

public enum DiagnosticSeverity: String, Codable, Sendable {
    case info
    case success
    case warning
    case error
}

public struct DiagnosticItem: Identifiable, Codable, Sendable {
    public let id: UUID
    public let severity: DiagnosticSeverity
    public let title: String
    public let detail: String

    public init(id: UUID = UUID(), severity: DiagnosticSeverity, title: String, detail: String) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
    }
}

public struct DiagnosticReport: Codable, Sendable {
    public let generatedAt: Date
    public let sourceFiles: [String]
    public let items: [DiagnosticItem]
    public let recommendation: String

    public init(generatedAt: Date = Date(), sourceFiles: [String], items: [DiagnosticItem], recommendation: String) {
        self.generatedAt = generatedAt
        self.sourceFiles = sourceFiles
        self.items = items
        self.recommendation = recommendation
    }

    public var plainText: String {
        var lines = ["LivePhotoBridge Diagnostic Report", "Generated: \(generatedAt)", "Files: \(sourceFiles.joined(separator: ", "))", ""]
        for item in items {
            lines.append("[\(item.severity.rawValue.uppercased())] \(item.title): \(item.detail)")
        }
        lines.append("")
        lines.append("Recommendation: \(recommendation)")
        return lines.joined(separator: "\n")
    }
}
