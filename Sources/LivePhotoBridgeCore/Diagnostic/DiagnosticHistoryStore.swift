import Foundation

public actor DiagnosticHistoryStore {
    private let fileURL: URL

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.fileURL = base.appendingPathComponent("LivePhotoBridge", isDirectory: true).appendingPathComponent("diagnostic-history.json")
    }

    public func append(_ report: DiagnosticReport) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var reports: [DiagnosticReport] = []
        if let data = try? Data(contentsOf: fileURL) {
            reports = (try? JSONDecoder().decode([DiagnosticReport].self, from: data)) ?? []
        }
        reports.append(report)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(reports).write(to: fileURL, options: .atomic)
    }

    public func allReports() throws -> [DiagnosticReport] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return try JSONDecoder().decode([DiagnosticReport].self, from: data)
    }
}
