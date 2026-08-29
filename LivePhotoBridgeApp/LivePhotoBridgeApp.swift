import SwiftUI
import Photos
import PhotosUI
import ImageIO
import AVFoundation
import UniformTypeIdentifiers
import CoreTransferable

@main
struct LivePhotoBridgeApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct PickerPhotoFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .image) { item in
            SentTransferredFile(item.url)
        } importing: { received in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickerPhotoFile(url: destination)
        }
    }
}

struct PickerVideoFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { item in
            SentTransferredFile(item.url)
        } importing: { received in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickerVideoFile(url: destination)
        }
    }
}

struct ContentView: View {
    @State private var photoItem: PhotosPickerItem?
    @State private var videoItem: PhotosPickerItem?
    @State private var status = "Seleziona la foto e il video originali della stessa Live Photo."
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "livephoto")
                    .font(.system(size: 64))
                Text("Live Photo Bridge")
                    .font(.largeTitle.bold())
                Text("Ricostruisce una Live Photo usando i file originali, senza ricodificare il video.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Scegli foto HEIC/JPEG", systemImage: "photo")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                PhotosPicker(selection: $videoItem, matching: .videos) {
                    Label("Scegli video MOV", systemImage: "video")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await importLivePhoto() }
                } label: {
                    if isWorking {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Label("Crea Live Photo", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(photoItem == nil || videoItem == nil || isWorking)

                Text(status)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding()
            .navigationTitle("Live Photo Bridge")
        }
    }

    private func importLivePhoto() async {
        guard let photoItem, let videoItem else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            status = "Leggo i file originali..."
            guard let pickedPhoto = try await photoItem.loadTransferable(type: PickerPhotoFile.self),
                  let pickedVideo = try await videoItem.loadTransferable(type: PickerVideoFile.self) else {
                throw LivePhotoError.invalidInput
            }

            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("LivePhotoBridge", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let photoExt = pickedPhoto.url.pathExtension.isEmpty ? "heic" : pickedPhoto.url.pathExtension
            let photoURL = dir.appendingPathComponent("original.\(photoExt)")
            let videoURL = dir.appendingPathComponent("original.mov")

            try? FileManager.default.removeItem(at: photoURL)
            try? FileManager.default.removeItem(at: videoURL)
            try FileManager.default.copyItem(at: pickedPhoto.url, to: photoURL)
            try FileManager.default.copyItem(at: pickedVideo.url, to: videoURL)

            status = "Controllo gli identificatori Apple..."
            guard let photoIdentifier = try readPhotoAssetIdentifier(from: photoURL) else {
                throw LivePhotoError.photoIdentifierMissing
            }

            guard let videoIdentifier = try await readVideoContentIdentifier(from: videoURL) else {
                throw LivePhotoError.videoIdentifierMissing
            }

            guard photoIdentifier.caseInsensitiveCompare(videoIdentifier) == .orderedSame else {
                throw LivePhotoError.identifiersDoNotMatch(photoIdentifier, videoIdentifier)
            }

            guard await videoContainsStillImageTime(videoURL) else {
                throw LivePhotoError.stillImageTimeMissing
            }

            status = "Identificatori già corretti. Mantengo il MOV originale..."

            // IMPORTANT: for a genuine Apple backup, the HEIC and MOV already contain
            // the Live Photo identifiers. We therefore do NOT rebuild either file.
            // The video is copied byte-for-byte and is not decoded, re-encoded or remuxed.
            let pairedPhoto = dir.appendingPathComponent("paired.\(photoExt)")
            let pairedVideo = dir.appendingPathComponent("paired.mov")
            try? FileManager.default.removeItem(at: pairedPhoto)
            try? FileManager.default.removeItem(at: pairedVideo)
            try FileManager.default.copyItem(at: photoURL, to: pairedPhoto)
            try FileManager.default.copyItem(at: videoURL, to: pairedVideo)

            let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard auth == .authorized || auth == .limited else {
                throw LivePhotoError.photoLibraryDenied
            }

            status = "Importo la coppia nella libreria Foto..."
            try await saveLivePhoto(photoURL: pairedPhoto, videoURL: pairedVideo)
            status = "✅ Live Photo creata. Controlla Foto."
        } catch {
            status = "❌ \(error.localizedDescription)"
        }
    }

    private func readPhotoAssetIdentifier(from url: URL) throws -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw LivePhotoError.invalidPhoto
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw LivePhotoError.invalidPhoto
        }
        let maker = properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any]
        return maker?["17"] as? String
    }

    private func readVideoContentIdentifier(from url: URL) async throws -> String? {
        let asset = AVURLAsset(url: url)
        let metadata = try await asset.load(.metadata)
        for item in metadata {
            if item.identifier == .quickTimeMetadataContentIdentifier {
                if let value = item.value as? String { return value }
                if let value = item.value as? NSString { return value as String }
            }
        }
        return nil
    }

    private func videoContainsStillImageTime(_ url: URL) async -> Bool {
        do {
            let asset = AVURLAsset(url: url)
            let metadata = try await asset.load(.metadata)

            // There is no public AVMetadataIdentifier constant for
            // com.apple.quicktime.still-image-time on the current SDK.
            // Detect the metadata by its QuickTime key + metadata key space.
            for item in metadata {
                let key = item.key as? String
                let keySpace = item.keySpace?.rawValue
                if key == "com.apple.quicktime.still-image-time" && keySpace == "mdta" {
                    return true
                }
            }
            return false
        } catch {
            return false
        }
    }

    private func saveLivePhoto(photoURL: URL, videoURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()

                let photoOptions = PHAssetResourceCreationOptions()
                photoOptions.shouldMoveFile = false
                request.addResource(with: .photo, fileURL: photoURL, options: photoOptions)

                let videoOptions = PHAssetResourceCreationOptions()
                videoOptions.shouldMoveFile = false
                request.addResource(with: .pairedVideo, fileURL: videoURL, options: videoOptions)
            }) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: LivePhotoError.creationFailed)
                }
            }
        }
    }

    enum LivePhotoError: LocalizedError {
        case invalidInput
        case invalidPhoto
        case photoIdentifierMissing
        case videoIdentifierMissing
        case identifiersDoNotMatch(String, String)
        case stillImageTimeMissing
        case creationFailed
        case photoLibraryDenied

        var errorDescription: String? {
            switch self {
            case .invalidInput:
                return "Impossibile leggere la foto o il video selezionato."
            case .invalidPhoto:
                return "La foto non è un'immagine valida."
            case .photoIdentifierMissing:
                return "L'HEIC non contiene l'asset identifier Apple della Live Photo."
            case .videoIdentifierMissing:
                return "Il MOV non contiene il content identifier Apple della Live Photo."
            case let .identifiersDoNotMatch(photo, video):
                return "Gli identificatori non corrispondono. Foto: \(photo) — Video: \(video)"
            case .stillImageTimeMissing:
                return "Il MOV non contiene il metadata still-image-time necessario alla Live Photo."
            case .creationFailed:
                return "Foto non ha completato la creazione della Live Photo."
            case .photoLibraryDenied:
                return "Accesso alla libreria Foto non autorizzato."
            }
        }
    }
}
