import Foundation

public enum ImportDisposition: String, Codable, Sendable {
    case importAsOrdinaryAsset
    case importAsLivePhoto
    case manualReview
    case rejected
}

public struct ImportItem: Identifiable, Codable, Sendable {
    public let id: UUID
    public let sourceURL: URL
    public let disposition: ImportDisposition
    public let reason: String?

    public init(id: UUID = UUID(), sourceURL: URL, disposition: ImportDisposition, reason: String? = nil) {
        self.id = id
        self.sourceURL = sourceURL
        self.disposition = disposition
        self.reason = reason
    }
}

public struct ImportSummary: Codable, Sendable {
    public var startedAt: Date
    public var finishedAt: Date?
    public var totalFiles: Int
    public var completedFiles: Int
    public var failedFiles: Int
    public var skippedFiles: Int
    public var photos: Int
    public var videos: Int
    public var livePhotosRecognized: Int
    public var livePhotosIncomplete: Int
    public var bytesTransferred: Int64

    public init(startedAt: Date = Date()) {
        self.startedAt = startedAt
        self.finishedAt = nil
        self.totalFiles = 0
        self.completedFiles = 0
        self.failedFiles = 0
        self.skippedFiles = 0
        self.photos = 0
        self.videos = 0
        self.livePhotosRecognized = 0
        self.livePhotosIncomplete = 0
        self.bytesTransferred = 0
    }

    public var progress: Double {
        totalFiles == 0 ? 0 : Double(completedFiles + failedFiles + skippedFiles) / Double(totalFiles)
    }
}

public enum ImportStage: String, Codable, Sendable {
    case connecting
    case transferring
    case analyzing
    case matching
    case importing
    case verifying
    case completed
    case failed
    case paused
}

public struct ImportProgress: Sendable {
    public let stage: ImportStage
    public let completed: Int
    public let total: Int
    public let currentFile: String?
    public let bytesTransferred: Int64
    public let totalBytes: Int64

    public var fraction: Double {
        guard totalBytes > 0 else {
            return total > 0 ? Double(completed) / Double(total) : 0
        }
        return min(1, max(0, Double(bytesTransferred) / Double(totalBytes)))
    }

    public init(stage: ImportStage, completed: Int, total: Int, currentFile: String? = nil, bytesTransferred: Int64 = 0, totalBytes: Int64 = 0) {
        self.stage = stage
        self.completed = completed
        self.total = total
        self.currentFile = currentFile
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
    }
}
