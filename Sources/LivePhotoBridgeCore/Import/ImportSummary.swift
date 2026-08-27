import Foundation

public struct ImportSummary: Codable, Sendable {
    public var startedAt: Date
    public var finishedAt: Date?
    public var totalFiles: Int
    public var completedFiles: Int
    public var failedFiles: Int
    public var skippedFiles: Int
    public var photos: Int
    public var videos: Int
    public var livePhotos: Int
    public var incompleteLivePhotos: Int
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
        self.livePhotos = 0
        self.incompleteLivePhotos = 0
        self.bytesTransferred = 0
    }

    public var progress: Double {
        totalFiles == 0 ? 0 : Double(completedFiles + failedFiles + skippedFiles) / Double(totalFiles)
    }
}
