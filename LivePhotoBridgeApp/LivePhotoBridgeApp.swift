import SwiftUI
import Photos
import UniformTypeIdentifiers
import ImageIO
import AVFoundation

@main
struct LivePhotoBridgeApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
    @State private var photoURL: URL?
    @State private var videoURL: URL?
    @State private var showPhotoImporter = false
    @State private var showVideoImporter = false
    @State private var status = "Seleziona direttamente i file originali HEIC/JPEG e MOV dall'app File."
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

                Button {
                    showPhotoImporter = true
                } label: {
                    Label(photoURL == nil ? "Scegli foto HEIC/JPEG" : "Foto selezionata ✓", systemImage: "photo")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    showVideoImporter = true
                } label: {
                    Label(videoURL == nil ? "Scegli video MOV" : "Video selezionato ✓", systemImage: "video")
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
                .disabled(photoURL == nil || videoURL == nil || isWorking)

                Text(status)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding()
            .navigationTitle("Live Photo Bridge")
            .fileImporter(
                isPresented: $showPhotoImporter,
                allowedContentTypes: [.heic, .jpeg],
                allowsMultipleSelection: false
            ) { result in
                handleImportedFile(result, kind: .photo)
            }
            .fileImporter(
                isPresented: $showVideoImporter,
                allowedContentTypes: [.movie],
                allowsMultipleSelection: false
            ) { result in
                handleImportedFile(result, kind: .video)
            }
        }
    }

    private enum ImportedKind { case photo, video }

    private func handleImportedFile(_ result: Result<[URL], Error>, kind: ImportedKind) {
        switch result {
        case .success(let urls):
            guard let sourceURL = urls.first else { return }
            do {
                let access = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if access { sourceURL.stopAccessingSecurityScopedResource() }
                }

                let ext = sourceURL.pathExtension.isEmpty ? (kind == .photo ? "heic" : "mov") : sourceURL.pathExtension
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent("LivePhotoBridge-\(UUID().uuidString).\(ext)")
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: sourceURL, to: destination)

                if kind == .photo {
                    photoURL = destination
                    status = "Foto originale selezionata."
                } else {
                    videoURL = destination
                    status = "Video originale selezionato."
                }
            } catch {
                status = "❌ Impossibile copiare il file: \(error.localizedDescription)"
            }
        case .failure(let error):
            status = "❌ Selezione annullata/errore: \(error.localizedDescription)"
        }
    }

    private func importLivePhoto() async {
        guard let photoURL, let videoURL else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            status = "Leggo i file originali..."

            guard photoURL.pathExtension.lowercased() == "heic" || photoURL.pathExtension.lowercased() == "jpg" || photoURL.pathExtension.lowercased() == "jpeg" else {
                throw LivePhotoError.invalidPhoto
            }

            guard videoURL.pathExtension.lowercased() == "mov" else {
                throw LivePhotoError.invalidVideo
            }

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

            status = "Identificatori corretti. Mantengo HEIC e MOV originali..."

            let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard auth == .authorized || auth == .limited else {
                throw LivePhotoError.photoLibraryDenied
            }

            status = "Importo la coppia nella libreria Foto..."
            try await saveLivePhoto(photoURL: photoURL, videoURL: videoURL)
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

        // Apple stores the Live Photo pairing identifier in the MakerApple
        // dictionary under key 17. The original file is read only; nothing is rewritten.
        if let maker = properties[kCGImagePropertyMakerAppleDictionary] as? [AnyHashable: Any] {
            for (key, value) in maker {
                if String(describing: key) == "17" {
                    if let string = value as? String, !string.isEmpty {
                        return string
                    }
                    if let string = value as? NSString, string.length > 0 {
                        return string as String
                    }
                }
            }
        }

        // Some ImageIO versions expose the MakerNote through the EXIF dictionary.
        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let makerData = exif[kCGImagePropertyExifMakerNote] {
            // Do not attempt to rewrite/decode opaque maker-note data here.
            // The public ImageIO MakerApple dictionary above is the preferred path.
            _ = makerData
        }

        return nil
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
            for item in metadata {
                if item.keySpace?.rawValue == "mdta",
                   String(describing: item.key) == "com.apple.quicktime.still-image-time" {
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
        case invalidPhoto
        case invalidVideo
        case photoIdentifierMissing
        case videoIdentifierMissing
        case identifiersDoNotMatch(String, String)
        case stillImageTimeMissing
        case creationFailed
        case photoLibraryDenied

        var errorDescription: String? {
            switch self {
            case .invalidPhoto:
                return "La foto non è un HEIC/JPEG valido."
            case .invalidVideo:
                return "Per questo test seleziona il MOV originale della Live Photo."
            case .photoIdentifierMissing:
                return "L'HEIC non espone il pairing identifier Apple. Seleziona il file originale dall'app File, non una copia nella libreria Foto."
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
