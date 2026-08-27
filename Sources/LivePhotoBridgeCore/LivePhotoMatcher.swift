import Foundation

public actor LivePhotoMatcher {
    public init() {}

    /// Matches photo/video resources conservatively.
    /// ContentIdentifier equality is the only automatic high-confidence match.
    /// Same-name / differing-identifier pairs are deliberately classified as probable
    /// and must be shown in the "Live Photo incomplete" review queue.
    public func match(
        photos: [MediaResource],
        videos: [MediaResource]
    ) async -> [LivePhotoPairCandidate] {
        var candidates: [LivePhotoPairCandidate] = []
        var consumedPhotos = Set<UUID>()
        var consumedVideos = Set<UUID>()

        // Pass 1: exact ContentIdentifier matches.
        for photo in photos {
            guard let photoIdentifier = photo.contentIdentifier,
                  !photoIdentifier.isEmpty else { continue }

            let matches = videos.filter {
                $0.contentIdentifier == photoIdentifier
            }

            if matches.count == 1, let video = matches.first {
                candidates.append(
                    LivePhotoPairCandidate(
                        photo: photo,
                        video: video,
                        confidence: .exact
                    )
                )
                consumedPhotos.insert(photo.id)
                consumedVideos.insert(video.id)
            } else if matches.count > 1 {
                candidates.append(
                    LivePhotoPairCandidate(
                        photo: photo,
                        video: nil,
                        confidence: .ambiguous,
                        issues: [.ambiguousPair]
                    )
                )
                consumedPhotos.insert(photo.id)
            }
        }

        // Pass 2: suspicious same-stem matches. Never auto-import these.
        for photo in photos where !consumedPhotos.contains(photo.id) {
            let stem = Self.normalizedStem(photo.fileName)
            let sameStem = videos.filter {
                !consumedVideos.contains($0.id) &&
                Self.normalizedStem($0.fileName) == stem
            }

            if sameStem.count == 1, let video = sameStem.first {
                let identifiersDiffer = photo.contentIdentifier != video.contentIdentifier
                let issue: LivePhotoIssue = identifiersDiffer
                    ? .contentIdentifierMismatch
                    : .contentIdentifierMissing

                candidates.append(
                    LivePhotoPairCandidate(
                        photo: photo,
                        video: video,
                        confidence: .probable,
                        issues: [issue]
                    )
                )
                consumedPhotos.insert(photo.id)
                consumedVideos.insert(video.id)
            } else if sameStem.isEmpty {
                candidates.append(
                    LivePhotoPairCandidate(
                        photo: photo,
                        video: nil,
                        confidence: .incomplete,
                        issues: [.videoMissing]
                    )
                )
                consumedPhotos.insert(photo.id)
            } else {
                candidates.append(
                    LivePhotoPairCandidate(
                        photo: photo,
                        video: nil,
                        confidence: .ambiguous,
                        issues: [.ambiguousPair]
                    )
                )
                consumedPhotos.insert(photo.id)
            }
        }

        // Videos without a matched photo are also surfaced rather than silently ignored.
        for video in videos where !consumedVideos.contains(video.id) {
            candidates.append(
                LivePhotoPairCandidate(
                    photo: nil,
                    video: video,
                    confidence: .incomplete,
                    issues: [.photoMissing]
                )
            )
        }

        return candidates
    }

    private static func normalizedStem(_ fileName: String) -> String {
        URL(fileURLWithPath: fileName)
            .deletingPathExtension()
            .lastPathComponent
            .lowercased()
    }
}
