import AVFoundation
import Foundation
import ImageIO

public struct DiagnosticEngine: Sendable {
    public init() {}

    public func analyze(photoURL: URL, videoURL: URL?) async -> DiagnosticReport {
        var items: [DiagnosticItem] = []
        let photoIdentifier = ContentIdentifierReader.imageContentIdentifier(at: photoURL)

        if let photoIdentifier {
            items.append(.init(severity: .success, title: "Photo ContentIdentifier", detail: photoIdentifier))
        } else {
            items.append(.init(severity: .warning, title: "Photo ContentIdentifier", detail: "Not found in MakerApple metadata."))
        }

        if let videoURL {
            let videoIdentifier = await ContentIdentifierReader.videoContentIdentifier(at: videoURL)
            if let videoIdentifier {
                items.append(.init(severity: .success, title: "Video ContentIdentifier", detail: videoIdentifier))
                if let photoIdentifier {
                    if photoIdentifier == videoIdentifier {
                        items.append(.init(severity: .success, title: "Identifier match", detail: "The photo and video ContentIdentifiers match."))
                    } else {
                        items.append(.init(severity: .warning, title: "Identifier mismatch", detail: "The ContentIdentifiers differ. Do not automatically reconstruct this pair."))
                    }
                }
            } else {
                items.append(.init(severity: .warning, title: "Video ContentIdentifier", detail: "Not found in QuickTime metadata."))
            }

            // AVAsset.duration is available on the older deployment targets used by
            // the package, avoiding the macOS 12-only async load API.
            let asset = AVURLAsset(url: videoURL)
            let duration = asset.duration
            if duration.isValid {
                let seconds = CMTimeGetSeconds(duration)
                items.append(.init(severity: .info, title: "Video duration", detail: String(format: "%.3f seconds", seconds)))
            } else {
                items.append(.init(severity: .error, title: "Video inspection", detail: "Unable to read video duration."))
            }
        } else {
            items.append(.init(severity: .warning, title: "Paired video", detail: "No video supplied for this diagnostic run."))
        }

        let recommendation: String
        if photoIdentifier != nil && videoURL != nil {
            recommendation = "Identifier equality is strong evidence, but the final importer must still validate Photos resource compatibility before creating a Live Photo."
        } else {
            recommendation = "Treat this as an ordinary media item unless additional Live Photo evidence is found."
        }

        return DiagnosticReport(sourceFiles: [photoURL.lastPathComponent, videoURL?.lastPathComponent].compactMap { $0 }, items: items, recommendation: recommendation)
    }
}
