import Foundation

public enum LogLevel: String, Codable, Sendable {
    case debug
    case info
    case warning
    case error
}

public struct LogEntry: Identifiable, Codable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let level: LogLevel
    public let message: String
    public let fileName: String?
    public let code: String?

    public init(id: UUID = UUID(), timestamp: Date = Date(), level: LogLevel, message: String, fileName: String? = nil, code: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.message = message
        self.fileName = fileName
        self.code = code
    }
}

public actor BridgeLogger {
    private var entries: [LogEntry] = []

    public init() {}

    public func append(_ entry: LogEntry) {
        entries.append(entry)
    }

    public func allEntries() -> [LogEntry] {
        entries
    }

    public func clear() {
        entries.removeAll(keepingCapacity: true)
    }

    public func plainText() -> String {
        let formatter = ISO8601DateFormatter()
        return entries.map { entry in
            let date = formatter.string(from: entry.timestamp)
            let file = entry.fileName.map { " [\($0)]" } ?? ""
            let code = entry.code.map { " (\($0))" } ?? ""
            return "[\(date)] [\(entry.level.rawValue.uppercased())]\(file)\(code) \(entry.message)"
        }.joined(separator: "\n")
    }
}
