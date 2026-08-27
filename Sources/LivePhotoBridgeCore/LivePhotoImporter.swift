#if os(iOS)
import Foundation
import Photos

public enum LivePhotoImportError: LocalizedError, Sendable {
    case missingPhoto
    case missingVideo
    case unsupportedPair
    case photoLibraryDenied
    case importFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingPhoto: return "The Live Photo photo resource is missing."
        case .missingVideo: return "The Live Photo paired video resource is missing."
        case .unsupportedPair: return "Photos does not accept this pair as a Live Photo resource combination."
        case .photoLibraryDenied: return "Photo Library access was not granted."
        case .importFailed(let message): return message
        }
    }
}

@available(iOS 17.0, *)
public final class LivePhotoImporter: @unchecked Sendable {
    public init() {}

    /// Imports the original photo and movie resources without transcoding them.
    public func importPair(
        photoURL: URL,
        videoURL: URL,
        shouldMoveVideoFile: Bool = false
    ) async throws {
        guard FileManager.default.fileExists(atPath: photoURL.path) else {
            throw LivePhotoImportError.missingPhoto
        }
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            throw LivePhotoImportError.missingVideo
        }

        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            let newStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard newStatus == .authorized || newStatus == .limited else {
                throw LivePhotoImportError.photoLibraryDenied
            }
        } else if status != .authorized && status != .limited {
            throw LivePhotoImportError.photoLibraryDenied
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()

                let photoOptions = PHAssetResourceCreationOptions()
                photoOptions.shouldMoveFile = false
                request.addResource(with: .photo, fileURL: photoURL, options: photoOptions)

                let videoOptions = PHAssetResourceCreationOptions()
                videoOptions.shouldMoveFile = shouldMoveVideoFile
                request.addResource(with: .pairedVideo, fileURL: videoURL, options: videoOptions)
            }, completionHandler: { success, error in
                if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: LivePhotoImportError.importFailed(
                        error?.localizedDescription ?? "Photos rejected the Live Photo import."
                    ))
                }
            })
        }
    }
}
#endif
