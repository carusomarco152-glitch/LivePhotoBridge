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
    @State private var status = "Seleziona i file per i test."
    @State private var isWorking = false
    @State private var diagnosticLog = UserDefaults.standard.string(forKey: "LivePhotoBridge.log") ?? ""

    private enum ImportedKind { case photo, video }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
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
                    Text(status).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text("Log diagnostico").font(.headline); Spacer(); Button("Copia") { UIPasteboard.general.string = diagnosticLog }; Button("Cancella") { diagnosticLog = ""; UserDefaults.standard.removeObject(forKey: "LivePhotoBridge.log") } }
                        TextEditor(text: $diagnosticLog).font(.system(.footnote, design: .monospaced)).frame(minHeight: 220, maxHeight: 320).padding(4).overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.3))).textSelection(.enabled)
                    }
                }.padding()
            }.navigationTitle("Live Photo Bridge")
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: importerKind == .photo ? [.heic, .jpeg] : [.movie], allowsMultipleSelection: false) { result in handleImportedFile(result, kind: importerKind) }
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
                let access = sourceURL.startAccessingSecurityScopedResource(); defer { if access { sourceURL.stopAccessingSecurityScopedResource() } }
                let ext = sourceURL.pathExtension.isEmpty ? (kind == .photo ? "heic" : "mov") : sourceURL.pathExtension
                let destination = FileManager.default.temporaryDirectory.appendingPathComponent("LivePhotoBridge-\(UUID().uuidString).\(ext)")
                try? FileManager.default.removeItem(at: destination); try FileManager.default.copyItem(at: sourceURL, to: destination)
                if kind == .photo { photoURL = destination; status = "Foto originale selezionata: \(sourceURL.lastPathComponent)" } else { videoURL = destination; status = "Video originale selezionato: \(sourceURL.lastPathComponent)" }
            } catch { status = "❌ Impossibile copiare il file: \(error.localizedDescription)" }
        case .failure(let error): status = "❌ Selezione annullata/errore: \(error.localizedDescription)" }
    }

    private func ensurePhotoAuthorization() async throws {
        let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        log("Autorizzazione Foto: \(auth.rawValue)")
        guard auth == .authorized || auth == .limited else { throw LivePhotoError.photoLibraryDenied }
    }

    private func testPhotoOnly() async {
        guard let photoURL else { status = "Seleziona prima l'HEIC/JPEG."; return }
        isWorking = true; defer { isWorking = false }
        log("=== TEST 1: SOLO FOTO ===")
        do {
            try await ensurePhotoAuthorization(); log("Chiamo performChanges per una sola foto...")
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges({
                    self.log("Dentro change block FOTO.")
                    guard let request = PHAssetCreationRequest.creationRequestForAsset(from: photoURL) else { self.log("creationRequestForAsset(from:) ha restituito nil."); return }
                    self.log("PHAssetCreationRequest FOTO creata.")
                    _ = request
                }, completionHandler: { success, error in
                    if let error { self.log("FOTO completion ERROR: \(error.localizedDescription)"); continuation.resume(throwing: error) }
                    else if success { self.log("FOTO completion SUCCESS."); continuation.resume(returning: ()) }
                    else { self.log("FOTO completion FALLITA senza errore."); continuation.resume(throwing: LivePhotoError.creationFailed) }
                })
                self.log("performChanges FOTO chiamato.")
            }
            status = "✅ Test foto completato."
        } catch { status = "❌ Test foto: \(error.localizedDescription)"; log("TEST 1 ERRORE: \(error.localizedDescription)") }
    }

    private func testVideoOnly() async {
        guard let videoURL else { status = "Seleziona prima il MOV."; return }
        isWorking = true; defer { isWorking = false }
        log("=== TEST 2: SOLO VIDEO ===")
        do {
            try await ensurePhotoAuthorization(); log("Chiamo performChanges per un solo video...")
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges({
                    self.log("Dentro change block VIDEO.")
                    let request = PHAssetCreationRequest.forAsset(); self.log("PHAssetCreationRequest VIDEO creata.")
                    request.addResource(with: .video, fileURL: videoURL, options: nil); self.log("Risorsa VIDEO aggiunta.")
                }, completionHandler: { success, error in
                    if let error { self.log("VIDEO completion ERROR: \(error.localizedDescription)"); continuation.resume(throwing: error) }
                    else if success { self.log("VIDEO completion SUCCESS."); continuation.resume(returning: ()) }
                    else { self.log("VIDEO completion FALLITA senza errore."); continuation.resume(throwing: LivePhotoError.creationFailed) }
                })
                self.log("performChanges VIDEO chiamato.")
            }
            status = "✅ Test video completato."
        } catch { status = "❌ Test video: \(error.localizedDescription)"; log("TEST 2 ERRORE: \(error.localizedDescription)") }
    }

    private func testLivePhotoPair() async {
        guard let photoURL, let videoURL else { status = "Seleziona prima HEIC/JPEG e MOV."; return }
        isWorking = true; defer { isWorking = false }
        log("=== TEST 3: LIVE PHOTO ===")
        do {
            try await ensurePhotoAuthorization()
            let resources = [NSNumber(value: PHAssetResourceType.photo.rawValue), NSNumber(value: PHAssetResourceType.pairedVideo.rawValue)]
            let supported = PHAssetCreationRequest.supportsAssetResourceTypes(resources)
            log("Preflight coppia: \(supported ? "SUPPORTATO" : "NON SUPPORTATO")")
            guard supported else { throw LivePhotoError.unsupportedResourceCombination }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges({
                    self.log("Dentro change block LIVE PHOTO.")
                    let request = PHAssetCreationRequest.forAsset(); self.log("PHAssetCreationRequest LIVE PHOTO creata.")
                    request.addResource(with: .photo, fileURL: photoURL, options: nil); self.log("PHOTO aggiunta.")
                    request.addResource(with: .pairedVideo, fileURL: videoURL, options: nil); self.log("PAIRED VIDEO aggiunto.")
                }, completionHandler: { success, error in
                    if let error { self.log("LIVE PHOTO completion ERROR: \(error.localizedDescription)"); continuation.resume(throwing: error) }
                    else if success { self.log("LIVE PHOTO completion SUCCESS."); continuation.resume(returning: ()) }
                    else { self.log("LIVE PHOTO completion FALLITA senza errore."); continuation.resume(throwing: LivePhotoError.creationFailed) }
                })
                self.log("performChanges LIVE PHOTO chiamato.")
            }
            status = "✅ Test Live Photo completato."
        } catch { status = "❌ Test Live Photo: \(error.localizedDescription)"; log("TEST 3 ERRORE: \(error.localizedDescription)") }
    }

    enum LivePhotoError: LocalizedError {
        case unsupportedResourceCombination, creationFailed, photoLibraryDenied
        var errorDescription: String? { switch self { case .unsupportedResourceCombination: return "Photos non supporta questa combinazione di risorse."; case .creationFailed: return "Photos non ha completato la creazione."; case .photoLibraryDenied: return "Accesso alla libreria Foto non autorizzato." } }
    }
}
