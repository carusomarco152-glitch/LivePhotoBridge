import Foundation

public enum PhotoResourceKind: String, Sendable {
    case heic
    case jpeg
}

public enum VideoResourceKind: String, Sendable {
    case mov
    case mp4
}

public struct MediaResource: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let url: URL
    public let kind: Kind
    public let contentIdentifier: String?
    public let fileName: String

    public enum Kind: Sendable, Hashable {
        case photo(PhotoResourceKind)
        case video(VideoResourceKind)
    }

    public init(
        id: UUID = UUID(),
        url: URL,
        kind: Kind,
        contentIdentifier: String? = nil
    ) {
        self.id = id
        self.url = url
        self.kind = kind
        self.contentIdentifier = contentIdentifier
        self.fileName = url.lastPathComponent
    }
}

public enum LivePhotoMatchConfidence: String, Sendable {
    case exact
    case probable
    case ambiguous
    case incomplete
    case invalid
}

public enum LivePhotoIssue: String, Sendable, CaseIterable {
    case photoMissing
    case videoMissing
    case contentIdentifierMissing
    case contentIdentifierMismatch
    case unsupportedPhotoType
    case unsupportedVideoType
    case unreadableMetadata
    case ambiguousPair
    case incompatibleResources
}

public struct LivePhotoPairCandidate: Identifiable, Sendable {
    public let id: UUID
    public let photo: MediaResource?
    public let video: MediaResource?
    public let confidence: LivePhotoMatchConfidence
    public let issues: [LivePhotoIssue]

    public init(
        id: UUID = UUID(),
        photo: MediaResource?,
        video: MediaResource?,
        confidence: LivePhotoMatchConfidence,
        issues: [LivePhotoIssue] = []
    ) {
        self.id = id
        self.photo = photo
        self.video = video
        self.confidence = confidence
        self.issues = issues
    }
}

public struct LivePhotoScanResult: Sendable {
    public let photos: [MediaResource]
    public let videos: [MediaResource]
    public let candidates: [LivePhotoPairCandidate]

    public init(
        photos: [MediaResource],
        videos: [MediaResource],
        candidates: [LivePhotoPairCandidate]
    ) {
        self.photos = photos
        self.videos = videos
        self.candidates = candidates
    }
}
