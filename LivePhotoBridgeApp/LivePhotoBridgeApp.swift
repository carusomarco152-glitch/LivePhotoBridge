import SwiftUI
import Photos
import UniformTypeIdentifiers
import ImageIO
import AVFoundation

@main
struct LivePhotoBridgeApp: App { var body: some Scene { WindowGroup { ContentView() } } }

struct ContentView: View {
    @State private var photoURL: URL?
    @State private var videoURL: URL?
    @State private var showFileImporter = false
    @State private var importerKind: ImportedKind = .photo
    @State private var status = "Seleziona i file per i test."
    @State private var isWorking = false
    @State private var diagnosticLog = UserDefaults.standard.string(forKey: "LivePhotoBridge.log") ?? ""
    @State private var createdLivePhotoIdentifier: String?
    @State private var showExportPicker = false
    @State private var exportURLs: [URL] = []
    private enum ImportedKind { case photo, video }
    var body: some View {
        NavigationStack { ScrollView { VStack(spacing: 16) {
            Image(systemName: "livephoto").font(.system(size: 64))
            Text("Live Photo Bridge – Test").font(.largeTitle.bold())
            Text("Test separati di PhotoKit prima della ricostruzione della Live Photo.").multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button { importerKind = .photo; showFileImporter = true } label: { Label(photoURL == nil ? "Scegli foto HEIC/JPEG" : "Foto selezionata ✓", systemImage: "photo").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
            Button { importerKind = .video; showFileImporter = true } label: { Label(videoURL == nil ? "Scegli video MOV" : "Video selezionato ✓", systemImage: "video").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
            Divider()
            Text("Test 1 – Solo foto").font(.headline)
            Button { Task { await testPhotoOnly() } } label: { Label("Importa solo foto", systemImage: "photo.badge.plus").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
            Text("Test 2 – Solo video").font(.headline)
            Button { Task { await testVideoOnly() } } label: { Label("Importa solo video", systemImage: "video.badge.plus").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
            Text("Test 3 – Live Photo").font(.headline)
            Button { Task { await testLivePhotoPair() } } label: { Label("Importa coppia HEIC + MOV", systemImage: "livephoto.badge.automatic").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
            Button { Task { await exportCreatedLivePhotoResources() } } label: { Label("Esporta risorse Live Photo", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity) }.buttonStyle(.bordered).disabled(createdLivePhotoIdentifier == nil || isWorking)
            Text(createdLivePhotoIdentifier == nil ? "Il pulsante si abilita dopo aver creato una Live Photo con il Test 3." : "Live Photo pronta: puoi esportarne le due risorse originali.").font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Text(status).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("Log diagnostico").font(.headline); Spacer(); Button("Copia") { UIPasteboard.general.string = diagnosticLog }; Button("Cancella") { diagnosticLog = ""; UserDefaults.standard.removeObject(forKey: "LivePhotoBridge.log") } }
                TextEditor(text: $diagnosticLog).font(.system(.footnote, design: .monospaced)).frame(minHeight: 220, maxHeight: 320).padding(4).overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.3))).textSelection(.enabled)
            }
        }.padding() }.navigationTitle("Live Photo Bridge")
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: importerKind == .photo ? [.heic, .jpeg] : [.movie], allowsMultipleSelection: false) { result in handleImportedFile(result, kind: importerKind) }
        .sheet(isPresented: $showExportPicker) { if !exportURLs.isEmpty { ExportDocumentPicker(urls: exportURLs) } }
        }
    }
    private func log(_ message: String) { let line = "[\(Date().formatted(date: .omitted, time: .standard))] \(message)"; diagnosticLog += line + "\n"; UserDefaults.standard.set(diagnosticLog, forKey: "LivePhotoBridge.log") }
    private func handleImportedFile(_ result: Result<[URL], Error>, kind: ImportedKind) {
        switch result {
        case .success(let urls):
            guard let sourceURL = urls.first else { status = "Nessun file selezionato."; return }
            do { let access = sourceURL.startAccessingSecurityScopedResource(); defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }; let ext = sourceURL.pathExtension.isEmpty ? (kind == .photo ? "heic" : "mov") : sourceURL.pathExtension; let destination = FileManager.default.temporaryDirectory.appendingPathComponent("LivePhotoBridge-\(UUID().uuidString).\(ext)"); try? FileManager.default.removeItem(at: destination); try FileManager.default.copyItem(at: sourceURL, to: destination); if kind == .photo { photoURL = destination; status = "Foto originale selezionata: \(sourceURL.lastPathComponent)" } else { videoURL = destination; status = "Video originale selezionato: \(sourceURL.lastPathComponent)" } } catch { status = "❌ Impossibile copiare il file: \(error.localizedDescription)" }
        case .failure(let error): status = "❌ Selezione annullata/errore: \(error.localizedDescription)" }
    }
    private func ensurePhotoAuthorization() async throws { let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly); log("Autorizzazione Foto: \(auth.rawValue)"); guard auth == .authorized || auth == .limited else { throw LivePhotoError.photoLibraryDenied } }
    private func testPhotoOnly() async {
        guard let photoURL else { status = "Seleziona prima l'HEIC/JPEG."; return }
        isWorking = true; defer { isWorking = false }; log("=== TEST 1: SOLO FOTO ===")
        do { try await ensurePhotoAuthorization(); log("Invio file originale a PhotoKit (nessuna UIImage/decodifica)..."); log("Chiamo performChanges per una sola foto..."); try await PhotoKitTestHelper.savePhoto(at: photoURL); log("FOTO completion SUCCESS."); status = "✅ Test foto completato." } catch { status = "❌ Test foto: \(error.localizedDescription)"; log("TEST 1 ERRORE: \(error.localizedDescription)") }
    }
    private func testVideoOnly() async {
        guard let videoURL else { status = "Seleziona prima il MOV."; return }
        isWorking = true; defer { isWorking = false }; log("=== TEST 2: SOLO VIDEO ===")
        do { try await ensurePhotoAuthorization(); log("Chiamo performChanges per un solo video..."); try await PhotoKitTestHelper.saveVideo(at: videoURL); log("VIDEO completion SUCCESS."); status = "✅ Test video completato." } catch { status = "❌ Test video: \(error.localizedDescription)"; log("TEST 2 ERRORE: \(error.localizedDescription)") }
    }
    private func testLivePhotoPair() async {
        guard let photoURL, let videoURL else { status = "Seleziona prima HEIC/JPEG e MOV."; return }
        isWorking = true; defer { isWorking = false }; log("=== TEST 3: LIVE PHOTO ===")
        do {
            try await ensurePhotoAuthorization()
            let resources = [NSNumber(value: PHAssetResourceType.photo.rawValue), NSNumber(value: PHAssetResourceType.pairedVideo.rawValue)]
            let supported = PHAssetCreationRequest.supportsAssetResourceTypes(resources)
            log("Preflight coppia: \(supported ? "SUPPORTATO" : "NON SUPPORTATO")")
            guard supported else { throw LivePhotoError.unsupportedResourceCombination }
            log("Chiamo performChanges LIVE PHOTO senza catturare ContentView...")
            let identifier = try await PhotoKitTestHelper.saveLivePhoto(photoURL: photoURL, videoURL: videoURL)
            createdLivePhotoIdentifier = identifier
            log("LIVE PHOTO completion SUCCESS. Asset: \(identifier)")
            status = "✅ Test Live Photo completato. Ora puoi esportare le risorse."
        } catch { status = "❌ Test Live Photo: \(error.localizedDescription)"; log("TEST 3 ERRORE: \(error.localizedDescription)") }
    }
    private func exportCreatedLivePhotoResources() async {
        guard let identifier = createdLivePhotoIdentifier else { status = "Crea prima una Live Photo con il Test 3."; return }
        isWorking = true; defer { isWorking = false }
        log("=== ESPORTAZIONE RISORSE LIVE PHOTO ===")
        do {
            try await ensurePhotoAuthorization()
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { throw LivePhotoError.assetNotFound }
            let resources = PHAssetResource.assetResources(for: asset)
            guard let photoResource = resources.first(where: { $0.type == .photo }), let videoResource = resources.first(where: { $0.type == .pairedVideo }) else { throw LivePhotoError.resourcesNotFound }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LivePhotoBridge_Export_\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let photoOut = folder.appendingPathComponent("created_photo.heic")
            let videoOut = folder.appendingPathComponent("created_video.mov")
            log("Risorse trovate. Estraggo direttamente PhotoKit senza ricodifica...")
            try await PhotoKitTestHelper.exportResource(photoResource, to: photoOut)
            try await PhotoKitTestHelper.exportResource(videoResource, to: videoOut)
            exportURLs = [photoOut, videoOut]
            log("Esportazione completata: HEIC + MOV pronti per il salvataggio.")
            status = "✅ Risorse estratte. Scegli la destinazione in File."
            showExportPicker = true
        } catch { status = "❌ Esportazione: \(error.localizedDescription)"; log("ESPORTAZIONE ERRORE: \(error.localizedDescription)") }
    }
    enum LivePhotoError: LocalizedError { case invalidPhoto, unsupportedResourceCombination, creationFailed, photoLibraryDenied, assetNotFound, resourcesNotFound; var errorDescription: String? { switch self { case .invalidPhoto: return "Il file foto non può essere aperto come immagine."; case .unsupportedResourceCombination: return "Photos non supporta questa combinazione di risorse."; case .creationFailed: return "Photos non ha completato la creazione."; case .photoLibraryDenied: return "Accesso alla libreria Foto non autorizzato."; case .assetNotFound: return "Non riesco a trovare la Live Photo appena creata."; case .resourcesNotFound: return "Non riesco a trovare entrambe le risorse della Live Photo." } } }
}

private struct ExportDocumentPicker: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController { UIDocumentPickerViewController(forExporting: urls, asCopy: true) }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
}

private nonisolated enum PhotoKitTestHelper {
    static nonisolated func savePhoto(at url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges { guard PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url) != nil else { return } }
    }
    static nonisolated func saveVideo(at url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges { let request = PHAssetCreationRequest.forAsset(); request.addResource(with: .video, fileURL: url, options: nil) }
    }
    static nonisolated func saveLivePhoto(photoURL: URL, videoURL: URL) async throws -> String {
        var identifier: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: photoURL, options: nil)
            request.addResource(with: .pairedVideo, fileURL: videoURL, options: nil)
            identifier = request.placeholderForCreatedAsset?.localIdentifier
        }
        guard let identifier else { throw ContentView.LivePhotoError.creationFailed }
        return identifier
    }
    @MainActor static func exportResource(_ resource: PHAssetResource, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: ()) }
            }
        }
    }
}