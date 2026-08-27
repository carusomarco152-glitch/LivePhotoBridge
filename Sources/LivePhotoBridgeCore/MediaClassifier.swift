import Foundation

/// Classifies an individual resource before any pairing is attempted.
/// The classifier is intentionally conservative: an ordinary photo/video is
/// never treated as a Live Photo component solely because its filename matches.
public enum MediaClassification: String, Sendable {
    case ordinaryPhoto
    case ordinaryVideo
    case possibleLivePhotoPhoto
    case possibleLivePhotoVideo
    case unsupported
}

public struct MediaClassifier: Sendable {
    public init() {}

    public func classify(_ resource: MediaResource) -> MediaClassification {
        switch resource.kind {
        case .photo:
            // A ContentIdentifier is evidence that the resource may belong to
            // a Live Photo. It is not, by itself, sufficient to create one.
            return resource.contentIdentifier == nil
                ? .ordinaryPhoto
                : .possibleLivePhotoPhoto
        case .video:
            return resource.contentIdentifier == nil
                ? .ordinaryVideo
                : .possibleLivePhotoVideo
        }
    }
}
