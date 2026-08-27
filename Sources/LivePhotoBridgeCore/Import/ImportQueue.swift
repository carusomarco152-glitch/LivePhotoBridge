import Foundation

public enum ImportItemKind: String, Codable, Sendable {
    case photo
    case video
    case livePhoto
    case incompleteLivePhoto
    case unknown
}

public enum ImportItemState: String, Codable, Sendable {
    case pending
    case analyzing
    case transferring
    case importing
    case verifying
    case completed
    case skipped
    case failed
}

public struct ImportQueueItem: Identifiable, Codable, Sendable {
    public let id: UUID
    public let sourcePath: String
    public let fileName: String
    public let byteCount: Int64
    public var kind: ImportItemKind
    public var state: ImportItemState
    public var errorMessage: String?

    public init(id: UUID = UUID(), sourcePath: String, fileName: String, byteCount: Int64, kind: ImportItemKind = .unknown, state: ImportItemState = .pending, errorMessage: String? = nil) {
        self.id = id
        self.sourcePath = sourcePath
        self.fileName = fileName
        self.byteCount = byteCount
        self.kind = kind
        self.state = state
        self.errorMessage = errorMessage
    }
}

public struct ImportQueueSnapshot: Codable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var updatedAt: Date
    public var items: [ImportQueueItem]

    public init(id: UUID = UUID(), createdAt: Date = Date(), updatedAt: Date = Date(), items: [ImportQueueItem] = []) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.items = items
    }

    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.byteCount } }
    public var completedCount: Int { items.filter { $0.state == .completed }.count }
    public var failedCount: Int { items.filter { $0.state == .failed }.count }
    public var pendingCount: Int { items.filter { $0.state == .pending }.count }
    public var progress: Double { items.isEmpty ? 0 : Double(completedCount + failedCount) / Double(items.count) }
}

public actor ImportQueueStore {
    private let fileURL: URL
    private var snapshot: ImportQueueSnapshot

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.fileURL = base.appendingPathComponent("LivePhotoBridge", isDirectory: true).appendingPathComponent("import-queue.json")
        self.snapshot = Self.load(from: fileURL) ?? ImportQueueSnapshot()
    }

    public func replace(items: [ImportQueueItem]) throws {
        snapshot = ImportQueueSnapshot(id: snapshot.id, createdAt: snapshot.createdAt, updatedAt: Date(), items: items)
        try persist()
    }

    public func nextPendingItem() -> ImportQueueItem? {
        snapshot.items.first { $0.state == .pending }
    }

    public func update(id: UUID, state: ImportItemState, errorMessage: String? = nil) throws {
        guard let index = snapshot.items.firstIndex(where: { $0.id == id }) else { return }
        snapshot.items[index].state = state
        snapshot.items[index].errorMessage = errorMessage
        snapshot.updatedAt = Date()
        try persist()
    }

    public func current() -> ImportQueueSnapshot { snapshot }

    public func clear() throws {
        snapshot = ImportQueueSnapshot()
        try persist()
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }

    private static func load(from url: URL) -> ImportQueueSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ImportQueueSnapshot.self, from: data)
    }
}
