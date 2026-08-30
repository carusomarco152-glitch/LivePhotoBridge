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
    @State private var showFileImporter = false
    @State private var importerKind: ImportedKind = .photo
    @State private var status = "Seleziona direttamente i file originali HEIC/JPEG e MOV dall'app File."
    @State private var isWorking = false
    @State private var diagnosticLog = UserDefaults.standard.string(forKey: "LivePhotoBridge.log") ?? ""

    private enum ImportedKind { case photo, video }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "livephoto").font(.system(size: 64))
                Text("Live Photo Bridge").font(.largeTitle.bold())
                Text("Ricostruisce una Live Photo usando i file originali, senza ricodificare il video.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button { importerKind = .photo; showFileImporter = true } label: {
                    Label(photoURL == nil ? "Scegli foto HEIC/JPEG" : "Foto selezionata ✓", systemImage: "photo").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent)
                Button { importerKind = .video; showFileImporter = true } label: {
                    Label(videoURL == nil ? "Scegli video MOV" : "Video selezionato ✓", systemImage: "video").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered)
                Button { Task { await importLivePhoto() } } label: {
                    if isWorking { ProgressView().frame(maxWidth: .infinity) }
                    else { Label("Crea Live Photo", systemImage: "wand.and.stars").frame(maxWidth: .infinity) }
                }.buttonStyle(.borderedProminent).disabled(photoURL == nil || videoURL == nil || isWorking)
                Text(status).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Spacer()
            }.padding().navigationTitle("Live Photo Bridge")
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: importerKind == .photo ? [.heic, .jpeg] : [.movie], allowsMultipleSelection: false) { result in
                handleImportedFile(result, kind: importerKind)
            }
        }
    }

    private func log(_ message: String) {
        let line = "[\(Date().formatted(date: .omitted, time: .standard))] \(message)"
        diagnosticLog += line + "\n"
        UserDefaults.standard.set(diagnosticLog, forKey: "LivePhotoBridge.log")
    }

    private func handleImportedFile(_ result: Result<[URL], Error>, kind: ImportedKind) {
        switch result {
        case .success(let urls):
            guard let sourceURL = urls.first else { status = "Nessun file selezionato."; return }
            do {
                let access = sourceURL.startAccessingSecurityScopedResource()
                defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }
                let ext = sourceURL.pathExtension.isEmpty ? (kind == .photo ? "heic" : "mov") : sourceURL.pathExtension
                let destination = FileManager.default.temporaryDirectory.appendingPathComponent("LivePhotoBridge-\(UUID().uuidString).\(ext)")
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: sourceURL, to: destination)
                if kind == .photo { photoURL = destination; status = "Foto originale selezionata: \(sourceURL.lastPathComponent)" }
                else { videoURL = destination; status = "Video originale selezionato: \(sourceURL.lastPathComponent)" }
            } catch { status = "❌ Impossibile copiare il file: \(error.localizedDescription)" }
        case .failure(let error): status = "❌ Selezione annullata/errore: \(error.localizedDescription)" }
    }

    private func importLivePhoto() async {
        guard let photoURL, let videoURL else { return }
        isWorking = true; defer { isWorking = false }
        log("Avvio procedura.")
        do {
            status = "Leggo i file originali..."
            guard ["heic", "jpg", "jpeg"].contains(photoURL.pathExtension.lowercased()) else { throw LivePhotoError.invalidPhoto }
            guard videoURL.pathExtension.lowercased() == "mov" else { throw LivePhotoError.invalidVideo }
            log("File validati: HEIC/JPEG + MOV.")
            log("Lettura identificatore HEIC...")
            guard let photoIdentifier = try readPhotoAssetIdentifier(from: photoURL) else { throw LivePhotoError.photoIdentifierMissing }
            log("HEIC identifier: \(photoIdentifier)")
            log("Lettura content identifier MOV...")
            guard let videoIdentifier = try await readVideoContentIdentifier(from: videoURL) else { throw LivePhotoError.videoIdentifierMissing }
            log("MOV identifier: \(videoIdentifier)")
            guard photoIdentifier.caseInsensitiveCompare(videoIdentifier) == .orderedSame else { throw LivePhotoError.identifiersDoNotMatch(photoIdentifier, videoIdentifier) }
            log("Identificatori corrispondono.")
            let hasStillTime = await videoContainsStillImageTime(videoURL)
            log("still-image-time rilevato: \(hasStillTime ? "SI" : "NO")")

            log("Richiesta autorizzazione Foto...")
            let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            log("Risposta autorizzazione Foto: \(auth.rawValue)")
            guard auth == .authorized || auth == .limited else { throw LivePhotoError.photoLibraryDenied }
            log("Autorizzazione concessa. Avvio PHAssetCreationRequest...")
            status = "Importo la coppia nella libreria Foto..."
            try await saveLivePhoto(photoURL: photoURL, videoURL: videoURL)
            status = "✅ Live Photo creata. Controlla Foto."
            log("Salvataggio completato con successo.")
        } catch { status = "❌ \(error.localizedDescription)"; log("ERRORE: \(error.localizedDescription)") }
    }

    private func readPhotoAssetIdentifier(from url: URL) throws -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { throw LivePhotoError.invalidPhoto }
        if let maker = properties[kCGImagePropertyMakerAppleDictionary] as? [AnyHashable: Any] {
            for (key, value) in maker where String(describing: key) == "17" {
                if let string = value as? String, !string.isEmpty { return string }
                if let string = value as? NSString, string.length > 0 { return string as String }
            }
        }
        return nil
    }

    private func readVideoContentIdentifier(from url: URL) async throws -> String? {
        let asset = AVURLAsset(url: url)
        let metadata = try await asset.load(.metadata)
        for item in metadata where item.identifier == .quickTimeMetadataContentIdentifier {
            if let value = item.value as? String { return value }
            if let value = item.value as? NSString { return value as String }
        }
        return nil
    }

    private func videoContainsStillImageTime(_ url: URL) async -> Bool {
        do {
            let asset = AVURLAsset(url: url)
            let metadata = try await asset.load(.metadata)
            for item in metadata where item.keySpace?.rawValue == "mdta" && String(describing: item.key) == "com.apple.quicktime.still-image-time" { return true }
            return false
        } catch { return false }
    }

    private func saveLivePhoto(photoURL: URL, videoURL: URL) async throws {
        let resources = [NSNumber(value: PHAssetResourceType.photo.rawValue), NSNumber(value: PHAssetResourceType.pairedVideo.rawValue)]
        let supported = PHAssetCreationRequest.supportsAssetResourceTypes(resources)
        log("Preflight Live Photo resource types: \(supported ? "SUPPORTATO" : "NON SUPPORTATO")")
        guard supported else { throw LivePhotoError.unsupportedResourceCombination }
        log("Preflight superato.")
        log("Avvio PHPhotoLibrary.performChanges completion API...")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                self.log("Dentro change block: creo PHAssetCreationRequest...")
                let request = PHAssetCreationRequest.forAsset()
                self.log("PHAssetCreationRequest creata.")
                let photoOptions = PHAssetResourceCreationOptions()
                photoOptions.shouldMoveFile = true
                photoOptions.originalFilename = photoURL.lastPathComponent
                self.log("Aggiungo risorsa PHOTO...")
                request.addResource(with: .photo, fileURL: photoURL, options: photoOptions)
                self.log("Risorsa PHOTO aggiunta.")
                let videoOptions = PHAssetResourceCreationOptions()
                videoOptions.shouldMoveFile = true
                videoOptions.originalFilename = videoURL.lastPathComponent
                self.log("Aggiungo risorsa PAIRED VIDEO...")
                request.addResource(with: .pairedVideo, fileURL: videoURL, options: videoOptions)
                self.log("Risorsa PAIRED VIDEO aggiunta.")
            }, completionHandler: { success, error in
                if let error { self.log("performChanges completion ERROR: \(error.localizedDescription)"); continuation.resume(throwing: error) }
                else if success { self.log("performChanges completion SUCCESS."); continuation.resume(returning: ()) }
                else { self.log("performChanges completion FALLITA senza errore."); continuation.resume(throwing: LivePhotoError.creationFailed) }
            })
            self.log("performChanges completion API chiamato.")
        }
    }

    enum LivePhotoError: LocalizedError {
        case invalidPhoto, invalidVideo, photoIdentifierMissing, videoIdentifierMissing
        case identifiersDoNotMatch(String, String), stillImageTimeMissing, unsupportedResourceCombination, creationFailed, photoLibraryDenied
        var errorDescription: String? { switch self {
        case .invalidPhoto: return "La foto non è un HEIC/JPEG valido."
        case .invalidVideo: return "Per questo test seleziona il MOV originale della Live Photo."
        case .photoIdentifierMissing: return "L'HEIC non espone il pairing identifier Apple. Seleziona il file originale dall'app File."
        case .videoIdentifierMissing: return "Il MOV non contiene il content identifier Apple della Live Photo."
        case let .identifiersDoNotMatch(photo, video): return "Gli identificatori non corrispondono. Foto: \(photo) — Video: \(video)"
        case .stillImageTimeMissing: return "Il MOV non contiene il metadata still-image-time necessario alla Live Photo."
        case .unsupportedResourceCombination: return "Photos non supporta questa combinazione di risorse per una Live Photo."
        case .creationFailed: return "Foto non ha completato la creazione della Live Photo."
        case .photoLibraryDenied: return "Accesso alla libreria Foto non autorizzato."
        } }
    }
}
