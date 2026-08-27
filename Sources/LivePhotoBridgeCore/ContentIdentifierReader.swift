import AVFoundation
import CoreImage
import ImageIO
import Foundation

public enum ContentIdentifierReader {
    /// Reads the Live Photo content identifier from a still image.
    /// Apple associates this identifier with the image's Maker Apple metadata.
    public static func imageContentIdentifier(at url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }

        guard let makerApple = properties[kCGImagePropertyMakerAppleDictionary] as? [CFString: Any] else {
            return nil
        }

        // Apple documents the Live Photo identifier in MakerApple metadata.
        // Key 17 is the identifier used by iOS/iPhone Live Photo stills.
        if let value = makerApple[kCGImagePropertyMakerAppleDictionary as CFString] as? String {
            return value
        }

        if let value = makerApple["17" as CFString] as? String {
            return value
        }

        if let value = makerApple[17 as NSNumber] as? String {
            return value
        }

        return nil
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
