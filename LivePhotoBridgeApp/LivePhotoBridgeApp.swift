import SwiftUI
import Photos
import UniformTypeIdentifiers
import ImageIO
import AVFoundation
import Network

@main
struct LivePhotoBridgeApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

@MainActor
final class TransferServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var address = ""
    @Published private(set) var logText = ""

    private var listener: NWListener?
    private var port: NWEndpoint.Port = 8080
    private let fileManager = FileManager.default
    let inbox: URL

    init() {
        inbox = fileManager.temporaryDirectory.appendingPathComponent("LivePhotoBridge-PC-Inbox", isDirectory: true)
        try? fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
    }

    func start() {
        guard listener == nil else { return }
        do {
            listener = try NWListener(using: .tcp, on: port)
        } catch {
            appendLog("ERROR server: \(error.localizedDescription)")
            return
        }
        listener?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isRunning = true
                    self.address = "http://\(LocalNetworkInfo.ipv4Address() ?? "iPhone.local"):8080"
                    self.appendLog("Server PC pronto: \(self.address)")
                case .failed(let error):
                    self.isRunning = false
                    self.appendLog("ERROR server: \(error.localizedDescription)")
                    self.listener?.cancel()
                    self.listener = nil
                case .cancelled:
                    self.isRunning = false
                default: break
                }
            }
        }
        listener?.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global(qos: .userInitiated))
            HTTPConnection(connection: connection, inbox: self?.inbox ?? FileManager.default.temporaryDirectory) { message in
                Task { @MainActor in self?.appendLog(message) }
            }.start()
        }
        listener?.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        address = ""
    }

    func clearInbox() {
        try? fileManager.removeItem(at: inbox)
        try? fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
        appendLog("PC inbox svuotata.")
    }

    func appendLog(_ message: String) {
        let line = "[\(Date().formatted(date: .omitted, time: .standard))] \(message)"
        logText += line + "\n"
    }
}

struct ContentView: View {
    @StateObject private var server = TransferServer()
    @State private var photoURL: URL?
    @State private var videoURL: URL?
    @State private var showFileImporter = false
    @State private var importerKind: ImportedKind = .photo
    @State private var status = "Seleziona i file per i test oppure collega il PC dal browser."
    @State private var isWorking = false
    @State private var diagnosticLog = UserDefaults.standard.string(forKey: "LivePhotoBridge.log") ?? ""
    @State private var createdLivePhotoIdentifier: String?
    @State private var showExportPicker = false
    @State private var exportURLs: [URL] = []
    private enum ImportedKind { case photo, video }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: "livephoto").font(.system(size: 64))
                    Text("Live Photo Bridge").font(.largeTitle.bold())
                    Text("Trasferimento PC → iPhone e test controllati senza ricodifica.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)

                    GroupBox("PC → iPhone") {
                        VStack(alignment: .leading, spacing: 10) {
                            if server.isRunning {
                                Text("Apri dal PC:").font(.headline)
                                Text(server.address).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                Text("Seleziona file o cartella dal browser. La prima classificazione avviene sul PC, prima dell'invio.")
                                    .font(.footnote).foregroundStyle(.secondary)
                                HStack {
                                    Button("Riavvia server") { server.stop(); server.start() }
                                    Button("Svuota inbox") { server.clearInbox() }
                                }
                            } else {
                                Button { server.start() } label: {
                                    Label("Avvia interfaccia PC", systemImage: "desktopcomputer")
                                        .frame(maxWidth: .infinity)
                                }.buttonStyle(.borderedProminent)
                                Text("Il browser del PC analizzerà localmente estensioni, nomi e gruppi; l'iPhone riceverà solo ciò che confermi.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }

                    Divider()
                    Text("Test PhotoKit locali").font(.headline)
                    Button { importerKind = .photo; showFileImporter = true } label: { Label(photoURL == nil ? "Scegli foto HEIC/JPEG" : "Foto selezionata ✓", systemImage: "photo").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
                    Button { importerKind = .video; showFileImporter = true } label: { Label(videoURL == nil ? "Scegli video MOV" : "Video selezionato ✓", systemImage: "video").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
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
                        HStack { Text("Log app").font(.headline); Spacer(); Button("Copia") { UIPasteboard.general.string = diagnosticLog }; Button("Cancella") { diagnosticLog = ""; UserDefaults.standard.removeObject(forKey: "LivePhotoBridge.log") } }
                        TextEditor(text: $diagnosticLog).font(.system(.footnote, design: .monospaced)).frame(minHeight: 180, maxHeight: 280).padding(4).overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.3))).textSelection(.enabled)
                    }
                    if !server.logText.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text("Log PC / rete").font(.headline); Spacer(); Button("Copia") { UIPasteboard.general.string = server.logText } }
                            TextEditor(text: .constant(server.logText)).font(.system(.footnote, design: .monospaced)).frame(minHeight: 140, maxHeight: 240).padding(4).overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.3))).textSelection(.enabled)
                        }
                    }
                }.padding()
            }.navigationTitle("Live Photo Bridge")
            .onAppear { server.start() }
            .onDisappear { server.stop() }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: importerKind == .photo ? [.heic, .jpeg] : [.movie], allowsMultipleSelection: false) { result in handleImportedFile(result, kind: importerKind) }
            .sheet(isPresented: $showExportPicker) { if !exportURLs.isEmpty { ExportDocumentPicker(urls: exportURLs) } }
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
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: sourceURL, to: destination)
                if kind == .photo { photoURL = destination; status = "Foto originale selezionata: \(sourceURL.lastPathComponent)" }
                else { videoURL = destination; status = "Video originale selezionato: \(sourceURL.lastPathComponent)" }
            } catch { status = "❌ Impossibile copiare il file: \(error.localizedDescription)" }
        case .failure(let error): status = "❌ Selezione annullata/errore: \(error.localizedDescription)"
        }
    }

    private func ensurePhotoAuthorization() async throws {
        let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        log("Autorizzazione Foto: \(auth.rawValue)")
        guard auth == .authorized || auth == .limited else { throw LivePhotoError.photoLibraryDenied }
    }

    private func testPhotoOnly() async {
        guard let photoURL else { status = "Seleziona prima l'HEIC/JPEG."; return }
        isWorking = true; defer { isWorking = false }; log("=== TEST 1: SOLO FOTO ===")
        do { try await ensurePhotoAuthorization(); log("Invio file originale a PhotoKit (nessuna UIImage/decodifica)..."); log("Chiamo performChanges per una sola foto..."); try await PhotoKitTestHelper.savePhoto(at: photoURL); log("FOTO completion SUCCESS."); status = "✅ Test foto completato." }
        catch { status = "❌ Test foto: \(error.localizedDescription)"; log("TEST 1 ERRORE: \(error.localizedDescription)") }
    }

    private func testVideoOnly() async {
        guard let videoURL else { status = "Seleziona prima il MOV."; return }
        isWorking = true; defer { isWorking = false }; log("=== TEST 2: SOLO VIDEO ===")
        do { try await ensurePhotoAuthorization(); log("Chiamo performChanges per un solo video..."); try await PhotoKitTestHelper.saveVideo(at: videoURL); log("VIDEO completion SUCCESS."); status = "✅ Test video completato." }
        catch { status = "❌ Test video: \(error.localizedDescription)"; log("TEST 2 ERRORE: \(error.localizedDescription)") }
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
            let identifier = try await PhotoKitTestHelper.saveLivePhoto(photoURL: photoURL, videoURL: videoURL)
            createdLivePhotoIdentifier = identifier
            log("LIVE PHOTO completion SUCCESS. Asset: \(identifier)")
            status = "✅ Test Live Photo completato. Ora puoi esportare le risorse."
        } catch { status = "❌ Test Live Photo: \(error.localizedDescription)"; log("TEST 3 ERRORE: \(error.localizedDescription)") }
    }

    private func exportCreatedLivePhotoResources() async {
        guard let identifier = createdLivePhotoIdentifier else { status = "Crea prima una Live Photo con il Test 3."; return }
        isWorking = true; defer { isWorking = false }; log("=== ESPORTAZIONE RISORSE LIVE PHOTO ===")
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

    enum LivePhotoError: LocalizedError {
        case invalidPhoto, unsupportedResourceCombination, creationFailed, photoLibraryDenied, assetNotFound, resourcesNotFound
        var errorDescription: String? {
            switch self {
            case .invalidPhoto: return "Il file foto non può essere aperto come immagine."
            case .unsupportedResourceCombination: return "Photos non supporta questa combinazione di risorse."
            case .creationFailed: return "Photos non ha completato la creazione."
            case .photoLibraryDenied: return "Accesso alla libreria Foto non autorizzato."
            case .assetNotFound: return "Non riesco a trovare la Live Photo appena creata."
            case .resourcesNotFound: return "Non riesco a trovare entrambe le risorse della Live Photo."
            }
        }
    }
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
            let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = true
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: ()) }
            }
        }
    }
}

private enum LocalNetworkInfo {
    static func ipv4Address() -> String? {
        var address: String?
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            if isUp && !isLoopback, let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                address = String(cString: host)
                if address != nil { break }
            }
            pointer = current.pointee.ifa_next
        }
        return address
    }
}

private final class HTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let inbox: URL
    private let log: (String) -> Void
    private var buffer = Data()
    private var expectedBody = 0
    private var headersParsed = false
    private var requestPath = ""
    private var requestHeaders: [String: String] = [:]
    private var bodyFile: URL?
    private var bodyHandle: FileHandle?

    init(connection: NWConnection, inbox: URL, log: @escaping (String) -> Void) {
        self.connection = connection; self.inbox = inbox; self.log = log
    }

    func start() { receive() }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.consume(data) }
            if let error { self.log("ERROR rete: \(error.localizedDescription)"); self.finish(); return }
            if isComplete { self.finish(); return }
            self.receive()
        }
    }

    private func consume(_ data: Data) {
        if !headersParsed {
            buffer.append(data)
            guard let range = buffer.range(of: Data([13, 10, 13, 10])) else { return }
            let headerData = buffer.subdata(in: 0..<range.lowerBound)
            let bodyStart = range.upperBound
            parseHeaders(headerData)
            headersParsed = true
            buffer.removeSubrange(0..<bodyStart)
            if expectedBody > 0 { prepareBodyFile() }
        } else {
            buffer.append(data)
        }
        drainBodyIfPossible()
    }

    private func parseHeaders(_ data: Data) {
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.components(separatedBy: "\r\n")
        if let first = lines.first {
            let parts = first.split(separator: " ", maxSplits: 2).map(String.init)
            if parts.count >= 2 { requestPath = parts[1] }
        }
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 { requestHeaders[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        expectedBody = Int(requestHeaders["content-length"] ?? "0") ?? 0
    }

    private func prepareBodyFile() {
        let rawName = requestHeaders["x-lpb-filename"] ?? "upload.bin"
        let name = sanitize(rawName)
        let destination = inbox.appendingPathComponent("\(UUID().uuidString)_\(name)")
        bodyFile = destination
        fileManagerCreate(destination)
        bodyHandle = try? FileHandle(forWritingTo: destination)
        log("Upload avviato: \(name) (\(expectedBody) byte)")
    }

    private func drainBodyIfPossible() {
        guard expectedBody >= 0 else { return }
        let needed = min(buffer.count, expectedBody)
        if needed > 0 {
            if let chunk = bodyHandle { try? chunk.write(contentsOf: buffer.prefix(needed)) }
            buffer.removeFirst(needed)
            expectedBody -= needed
        }
        if expectedBody == 0 && headersParsed {
            bodyHandle?.closeFile(); bodyHandle = nil
            let name = requestHeaders["x-lpb-filename"] ?? "upload.bin"
            log("Upload completato: \(name)")
            sendJSON("{\"ok\":true}")
            expectedBody = -1
        }
    }

    private func sendJSON(_ body: String) {
        let bytes = Data(body.utf8)
        var response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n".data(using: .utf8) ?? Data()
        response.append(bytes)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in self?.finish() })
    }

    private func finish() { bodyHandle?.closeFile(); bodyHandle = nil; connection.cancel() }

    private func sanitize(_ name: String) -> String {
        let decoded = name.removingPercentEncoding ?? name
        return decoded.replacingOccurrences(of: "..", with: "_").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
    }

    private func fileManagerCreate(_ url: URL) { FileManager.default.createFile(atPath: url.path, contents: nil) }
}
