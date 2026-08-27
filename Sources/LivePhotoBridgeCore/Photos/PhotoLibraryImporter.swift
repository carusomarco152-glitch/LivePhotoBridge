#if os(iOS)
import Foundation
import Photos

public struct PhotoLibraryImportResult: Sendable {
    public let localIdentifier: String?
    public let created: Bool

    public init(localIdentifier: String?, created: Bool) {
        self.localIdentifier = localIdentifier
        self.created = created
    }
}

public enum PhotoLibraryImporterError: Error, LocalizedError, Sendable {
    case authorizationDenied
    case assetCreationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return "Photos access was not authorized."
        case .assetCreationFailed(let message):
            return "Photos asset creation failed: \(message)"
        }
    }
}

/// Imports the original photo/video resources without transcoding them.
/// A Live Photo is created by supplying the original still image and its
/// paired video as `.photo` and `.pairedVideo` resources to PhotoKit.
public final class PhotoLibraryImporter: @unchecked Sendable {
    public init() {}

    public func requestAuthorization() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    public func importLivePhoto(photoURL: URL, videoURL: URL) async throws -> PhotoLibraryImportResult {
        guard await requestAuthorization() else {
            throw PhotoLibraryImporterError.authorizationDenied
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PhotoLibraryImportResult, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()

                let photoOptions = PHAssetResourceCreationOptions()
                photoOptions.shouldMoveFile = false
                request.addResource(with: .photo, fileURL: photoURL, options: photoOptions)

                let videoOptions = PHAssetResourceCreationOptions()
                videoOptions.shouldMoveFile = false
                request.addResource(with: .pairedVideo, fileURL: videoURL, options: videoOptions)

                let localIdentifier = request.placeholderForCreatedAsset?.localIdentifier
                // The identifier is captured as an immutable value for the completion closure.
                Task { @MainActor in
                    _ = localIdentifier
                }
            }, completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: PhotoLibraryImporterError.assetCreationFailed(error.localizedDescription))
                } else if success {
                    // PhotoKit's change request has completed successfully. The placeholder
                    // identifier is not required by the import pipeline, so return nil here.
                    continuation.resume(returning: PhotoLibraryImportResult(localIdentifier: nil, created: true))
                } else {
                    continuation.resume(throwing: PhotoLibraryImporterError.assetCreationFailed("PhotoKit returned an unsuccessful change request without an error."))
                }
            })
        }
    }

    public func importSinglePhoto(photoURL: URL) async throws -> PhotoLibraryImportResult {
        guard await requestAuthorization() else {
            throw PhotoLibraryImporterError.authorizationDenied
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PhotoLibraryImportResult, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                request.addResource(with: .photo, fileURL: photoURL, options: options)
            }, completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: PhotoLibraryImporterError.assetCreationFailed(error.localizedDescription))
                } else if success {
                    continuation.resume(returning: PhotoLibraryImportResult(localIdentifier: nil, created: true))
                } else {
                    continuation.resume(throwing: PhotoLibraryImporterError.assetCreationFailed("PhotoKit returned an unsuccessful change request without an error."))
                }
            })
        }
    }

    public func importSingleVideo(videoURL: URL) async throws -> PhotoLibraryImportResult {
        guard await requestAuthorization() else {
            throw PhotoLibraryImporterError.authorizationDenied
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PhotoLibraryImportResult, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                request.addResource(with: .video, fileURL: videoURL, options: options)
            }, completionHandler: { success, error in
                if let error {
                    continuation.resume(throwing: PhotoLibraryImporterError.assetCreationFailed(error.localizedDescription))
                } else if success {
                    continuation.resume(returning: PhotoLibraryImportResult(localIdentifier: nil, created: true))
                } else {
                    continuation.resume(throwing: PhotoLibraryImporterError.assetCreationFailed("PhotoKit returned an unsuccessful change request without an error."))
                }
            })
        }
    }
}
#endif
