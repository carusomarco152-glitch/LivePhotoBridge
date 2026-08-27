import AVFoundation
import Foundation
import ImageIO

public enum ContentIdentifierReader {
    /// Reads the Live Photo content identifier from a still image.
    /// The identifier is stored in the MakerApple metadata dictionary.
    public static func imageContentIdentifier(at url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let makerApple = properties[kCGImagePropertyMakerAppleDictionary] as? [CFString: Any] else {
            return nil
        }

        // 17 is the MakerApple key used by Apple's Live Photo still-image metadata.
        return makerApple["17" as CFString] as? String
    }

    /// Reads the QuickTime content identifier from a movie without decoding or rewriting it.
    public static func videoContentIdentifier(at url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        do {
            let metadata = try await asset.load(.metadata)
            return metadata
                .first(where: { $0.identifier == .quickTimeMetadataContentIdentifier })?
                .stringValue
        } catch {
            return nil
        }
    }
}
