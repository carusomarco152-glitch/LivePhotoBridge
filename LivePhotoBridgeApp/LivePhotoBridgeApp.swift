import SwiftUI
import Combine
import Photos
import Network
import Darwin
import Foundation

@main
struct LivePhotoBridgeApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

@MainActor
final class TransferServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var address = ""
    @Published private(set) var logText = ""
    @Published private(set) var inboxRevision = 0

    private var listener: NWListener?
    private let port: NWEndpoint.Port = 8080
    private let fileManager = FileManager.default
    let inbox: URL

    init() {
        inbox = fileManager.temporaryDirectory.appendingPathComponent("LivePhotoBridge-PC-Inbox", isDirectory: true)
        try? fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
    }

    func start() {
        guard listener == nil else { return }
        do { listener = try NWListener(using: .tcp, on: port) }
        catch { appendLog("ERROR server: \(error.localizedDescription)"); return }
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
                    self.listener?.cancel(); self.listener = nil
                case .cancelled: self.isRunning = false
                default: break
                }
            }
        }
        listener?.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global(qos: .userInitiated))
            let inbox = self?.inbox ?? FileManager.default.temporaryDirectory
            HTTPConnection(connection: connection, inbox: inbox) { message, changed in
                Task { @MainActor in
                    self?.appendLog(message)
                    if changed { self?.inboxRevision += 1 }
                }
            }.start()
        }
        listener?.start(queue: .global(qos: .userInitiated))
    }

    func stop() { listener?.cancel(); listener = nil; isRunning = false; address = "" }

    func clearInbox() {
        try? fileManager.removeItem(at: inbox)
        try? fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
        inboxRevision += 1
        appendLog("PC inbox svuotata.")
    }

    func appendLog(_ message: String) {
        let line = "[\(Date().formatted(date: .omitted, time: .standard))] \(message)"
        logText += line + "\n"
    }
}

struct ReceivedGroup: Identifiable {
    let id: String
    let name: String
    let folder: URL
    let photo: URL?
    let video: URL?
    let aae: URL?
    let otherFiles: [URL]
    var kind: String {
        if photo != nil && video != nil { return "LIVE PHOTO" }
        if photo != nil { return "FOTO" }
        if video != nil { return "VIDEO" }
        return "ALTRO"
    }
}

struct ContentView: View {
    @StateObject private var server = TransferServer()
    @State private var status = "Avvia il collegamento dal PC."
    @State private var groups: [ReceivedGroup] = []
    @State private var isWorking = false
    @State private var diagnosticLog = UserDefaults.standard.string(forKey: "LivePhotoBridge.log") ?? ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: "livephoto").font(.system(size: 64))
                    Text("Live Photo Bridge").font(.largeTitle.bold())
                    Text("Trasferimento PC → iPhone. In questa fase l'app riceve e organizza i file senza conversioni.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)

                    GroupBox("Collegamento PC") {
                        VStack(alignment: .leading, spacing: 10) {
                            if server.isRunning {
                                Label("Server attivo", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                                Text("Apri dal PC:").font(.headline)
                                Text(server.address).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                Text("Nel browser puoi selezionare file o una cartella. La classificazione e la scelta degli AAE avvengono sul PC prima dell'upload.")
                                    .font(.footnote).foregroundStyle(.secondary)
                                HStack {
                                    Button("Riavvia") { server.stop(); server.start() }
                                    Button("Svuota inbox") { server.clearInbox() }
                                }
                            } else {
                                Button { server.start() } label: {
                                    Label("Avvia interfaccia PC", systemImage: "desktopcomputer")
                                        .frame(maxWidth: .infinity)
                                }.buttonStyle(.borderedProminent)
                            }
                        }
                    }

                    Text(status).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)

                    GroupBox("File ricevuti dal PC") {
                        VStack(alignment: .leading, spacing: 10) {
                            if groups.isEmpty {
                                Text("Nessun file ricevuto.").foregroundStyle(.secondary)
                            } else {
                                Text("\(groups.count) gruppi ricevuti").font(.subheadline.bold())
                                ForEach(groups) { group in
                                    ReceivedGroupRow(group: group) { Task { await buildLivePhoto(group) } }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Log app").font(.headline); Spacer()
                            Button("Copia") { UIPasteboard.general.string = diagnosticLog }
                            Button("Cancella") { diagnosticLog = ""; UserDefaults.standard.removeObject(forKey: "LivePhotoBridge.log") }
                        }
                        TextEditor(text: $diagnosticLog)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(minHeight: 180, maxHeight: 280)
                            .padding(4)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.3)))
                            .textSelection(.enabled)
                    }

                    if !server.logText.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text("Log PC / rete").font(.headline); Spacer(); Button("Copia") { UIPasteboard.general.string = server.logText } }
                            TextEditor(text: .constant(server.logText))
                                .font(.system(.footnote, design: .monospaced))
                                .frame(minHeight: 140, maxHeight: 240)
                                .padding(4)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.3)))
                                .textSelection(.enabled)
                        }
                    }
                }.padding()
            }
            .navigationTitle("Live Photo Bridge")
            .onAppear { server.start(); scanInbox() }
            .onDisappear { server.stop() }
            .onChange(of: server.inboxRevision) { _, _ in scanInbox() }
        }
    }

    private func log(_ message: String) {
        let line = "[\(Date().formatted(date: .omitted, time: .standard))] \(message)"
        diagnosticLog += line + "\n"
        UserDefaults.standard.set(diagnosticLog, forKey: "LivePhotoBridge.log")
    }

    private func scanInbox() {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: server.inbox, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { groups = []; return }
        groups = folders.compactMap { folder in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
            let photo = files.first { ["heic", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            let video = files.first { ["mov", "mp4"].contains($0.pathExtension.lowercased()) }
            let aae = files.first { $0.pathExtension.lowercased() == "aae" }
            let other = files.filter { $0 != photo && $0 != video && $0 != aae }
            return ReceivedGroup(id: folder.path, name: folder.lastPathComponent, folder: folder, photo: photo, video: video, aae: aae, otherFiles: other)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func ensurePhotoAuthorization() async throws {
        let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        log("Autorizzazione Foto: \(auth.rawValue)")
        guard auth == .authorized || auth == .limited else { throw LivePhotoError.photoLibraryDenied }
    }

    private func buildLivePhoto(_ group: ReceivedGroup) async {
        guard let photo = group.photo, let video = group.video else { status = "⚠️ \(group.name) non contiene sia foto che video."; return }
        guard !isWorking else { return }
        isWorking = true; defer { isWorking = false }
        log("=== COSTRUISCI LIVE PHOTO: \(group.name) ===")
        log("HEIC/MOV originali ricevuti dal PC: nessuna conversione.")
        if group.aae != nil { log("AAE presente: conservato byte-per-byte come sidecar; non ancora usato per l'editing.") }
        do {
            try await ensurePhotoAuthorization()
            let supported = PHAssetCreationRequest.supportsAssetResourceTypes([
                NSNumber(value: PHAssetResourceType.photo.rawValue),
                NSNumber(value: PHAssetResourceType.pairedVideo.rawValue)
            ])
            log("Preflight coppia Live Photo: \(supported ? "SUPPORTATO" : "NON SUPPORTATO")")
            guard supported else { throw LivePhotoError.unsupportedResourceCombination }
            let identifier = try await PhotoKitLivePhotoBuilder.create(photoURL: photo, videoURL: video)
            log("LIVE PHOTO creata. Asset: \(identifier)")
            status = "✅ \(group.name): Live Photo ricostruita nella libreria Foto."
        } catch {
            log("COSTRUZIONE LIVE PHOTO ERRORE: \(error.localizedDescription)")
            status = "❌ \(group.name): \(error.localizedDescription)"
        }
    }

    enum LivePhotoError: LocalizedError {
        case unsupportedResourceCombination, creationFailed, photoLibraryDenied
        var errorDescription: String? {
            switch self {
            case .unsupportedResourceCombination: return "Photos non supporta questa combinazione di risorse."
            case .creationFailed: return "Photos non ha completato la creazione della Live Photo."
            case .photoLibraryDenied: return "Accesso alla libreria Foto non autorizzato."
            }
        }
    }
}

private struct ReceivedGroupRow: View {
    let group: ReceivedGroup
    let buildAction: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: group.kind == "LIVE PHOTO" ? "livephoto" : group.kind == "FOTO" ? "photo" : "video")
                Text(group.name).font(.headline)
                Spacer(); Text(group.kind).font(.caption.bold()).foregroundStyle(.secondary)
            }
            if let photo = group.photo { Label(photo.lastPathComponent, systemImage: "photo") }
            if let video = group.video { Label(video.lastPathComponent, systemImage: "video") }
            if let aae = group.aae { Label("AAE: \(aae.lastPathComponent) — conservato", systemImage: "doc.text") }
            if !group.otherFiles.isEmpty { Text("Altri file: \(group.otherFiles.count)").font(.caption).foregroundStyle(.secondary) }
            if group.photo != nil && group.video != nil {
                Button("Costruisci Live Photo") { buildAction() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}

private enum PhotoKitLivePhotoBuilder {
    static func create(photoURL: URL, videoURL: URL) async throws -> String {
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
}

private enum LocalNetworkInfo {
    static func ipv4Address() -> String? {
        var result: String?
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return nil }
        defer { if let interfaces { freeifaddrs(interfaces) } }
        var pointer = interfaces
        while let current = pointer {
            let flags = Int32(current.pointee.ifa_flags)
            if (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
               let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                result = String(cString: host); if result != nil { break }
            }
            pointer = current.pointee.ifa_next
        }
        return result
    }
}

private final class HTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let inbox: URL
    private let log: (String, Bool) -> Void
    private var buffer = Data()
    private var headersParsed = false
    private var method = ""
    private var headers: [String: String] = [:]
    private var expectedBody = 0
    private var bodyHandle: FileHandle?
    private var finished = false

    init(connection: NWConnection, inbox: URL, log: @escaping (String, Bool) -> Void) { self.connection = connection; self.inbox = inbox; self.log = log }
    func start() { receive() }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty { self.consume(data) }
            if let error { self.log("ERROR rete: \(error.localizedDescription)", false); self.finish(); return }
            if isComplete { self.finish(); return }
            self.receive()
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        if !headersParsed { parseHeaderIfReady() }
        drainBody()
    }

    private func parseHeaderIfReady() {
        guard let range = buffer.range(of: Data([13, 10, 13, 10])) else { return }
        let headerData = buffer.subdata(in: 0..<range.lowerBound)
        buffer.removeSubrange(0..<range.upperBound)
        let text = String(data: headerData, encoding: .utf8) ?? ""
        let lines = text.components(separatedBy: "\r\n")
        if let first = lines.first {
            let parts = first.split(separator: " ", maxSplits: 2).map(String.init)
            if parts.count >= 2 { method = parts[0] }
        }
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 { headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        headersParsed = true
        expectedBody = Int(headers["content-length"] ?? "0") ?? 0
        if method == "GET" { sendHTML(PCWebUI.pageHTML); return }
        if method != "POST" && method != "PUT" { sendText("Metodo non supportato", status: "405 Method Not Allowed"); return }
        if expectedBody > 0 { prepareBodyFile() }
    }

    private func prepareBodyFile() {
        let rawName = headers["x-lpb-filename"] ?? "upload.bin"
        let rawGroup = headers["x-lpb-group"] ?? "Ungrouped"
        let groupName = sanitize(rawGroup)
        let groupFolder = inbox.appendingPathComponent(groupName, isDirectory: true)
        try? FileManager.default.createDirectory(at: groupFolder, withIntermediateDirectories: true)
        let name = sanitize(rawName)
        let destination = groupFolder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        bodyHandle = try? FileHandle(forWritingTo: destination)
        log("Upload avviato: \(name) | gruppo=\(groupName) | \(expectedBody) byte", false)
    }

    private func drainBody() {
        guard headersParsed, method != "GET" else { return }
        let count = min(buffer.count, expectedBody)
        if count > 0 {
            if let bodyHandle { try? bodyHandle.write(contentsOf: buffer.prefix(count)) }
            buffer.removeFirst(count); expectedBody -= count
        }
        if expectedBody == 0 && !finished {
            bodyHandle?.closeFile(); bodyHandle = nil
            let name = headers["x-lpb-filename"] ?? "upload.bin"
            let category = headers["x-lpb-category"] ?? "unknown"
            let group = headers["x-lpb-group"] ?? ""
            let aae = headers["x-lpb-aae"] ?? "false"
            log("Upload completato: \(name) | categoria=\(category) | gruppo=\(group) | AAE=\(aae)", true)
            sendText("{\"ok\":true}", contentType: "application/json")
        }
    }

    private func sendHTML(_ html: String) { sendRaw(Data(html.utf8), contentType: "text/html; charset=utf-8", status: "200 OK") }
    private func sendText(_ text: String, status: String = "200 OK", contentType: String = "text/plain; charset=utf-8") { sendRaw(Data(text.utf8), contentType: contentType, status: status) }
    private func sendRaw(_ body: Data, contentType: String, status: String) {
        guard !finished else { return }
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in self?.finish() })
    }
    private func finish() { guard !finished else { return }; finished = true; bodyHandle?.closeFile(); bodyHandle = nil; connection.cancel() }
    private func sanitize(_ name: String) -> String {
        let decoded = name.removingPercentEncoding ?? name
        return decoded.replacingOccurrences(of: "..", with: "_").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
    }
}

private enum PCWebUI {
    static let pageHTML = #"""
<!doctype html><html lang="it"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Live Photo Bridge</title>
<style>body{font-family:system-ui,-apple-system,Segoe UI,sans-serif;background:#f5f5f7;margin:0;color:#111}main{max-width:1000px;margin:30px auto;padding:20px}h1{margin-bottom:4px}.muted{color:#666}.card{background:white;border-radius:16px;padding:18px;margin:16px 0;box-shadow:0 2px 12px #0001}.actions{display:flex;gap:10px;flex-wrap:wrap}button{border:0;border-radius:10px;padding:11px 15px;font-weight:600;cursor:pointer}button.primary{background:#111;color:white}input[type=file]{display:none}.pick{display:inline-block;background:#111;color:#fff;border-radius:10px;padding:11px 15px;cursor:pointer}.group{border:1px solid #ddd;border-radius:12px;padding:12px;margin:9px 0}.row{display:flex;align-items:center;justify-content:space-between;gap:10px}.tag{display:inline-block;background:#eee;border-radius:8px;padding:3px 7px;font-size:12px;margin-right:5px}.warn{color:#9a6500}pre{white-space:pre-wrap;background:#111;color:#ddd;padding:14px;border-radius:12px;min-height:120px}.small{font-size:13px}</style></head>
<body><main><h1>Live Photo Bridge</h1><div class="muted">Selezione, classificazione e scelta AAE avvengono sul PC. L'iPhone riceve solo ciò che confermi.</div>
<div class="card"><div class="actions"><label class="pick">Seleziona file<input id="files" type="file" multiple></label><label class="pick">Seleziona cartella<input id="folder" type="file" multiple webkitdirectory directory></label><button onclick="clearAll()">Azzera</button></div><p id="summary" class="muted">Nessun file selezionato.</p></div>
<div class="card"><h2>File classificati</h2><div id="groups">Seleziona una cartella o dei file.</div></div>
<div class="card"><h2>Trasferimento</h2><p class="small">L'AAE, se incluso, viene trasferito <b>inalterato</b> come sidecar originale. Non viene convertito né riscritto. La costruzione della Live Photo avviene sull'iPhone.</p><div class="actions"><button class="primary" onclick="uploadAll()">Trasferisci selezione su iPhone</button></div><p id="progress"></p></div>
<div class="card"><h2>Log PC</h2><pre id="log"></pre></div></main>
<script>
const state={files:[],groups:[]};const $=id=>document.getElementById(id);
function esc(s){return s.replace(/[&<>\"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','\"':'&quot;'}[c]));}
function base(name){return name.replace(/\.[^.]+$/,'').toLowerCase();}
function ext(name){let m=name.toLowerCase().match(/\.([^.]+)$/);return m?m[1]:'';}
function classify(g){let ex=g.files.map(f=>ext(f.name));if(ex.includes('heic')&&ex.includes('mov'))return 'LIVE PHOTO';if(ex.includes('heic')||ex.includes('jpg')||ex.includes('jpeg')||ex.includes('png')||ex.includes('webp')||ex.includes('gif'))return 'FOTO';if(ex.includes('mov')||ex.includes('mp4'))return 'VIDEO';return 'NON CLASSIFICATO';}
function log(s){$('log').textContent+='['+new Date().toLocaleTimeString()+'] '+s+'\n';}
function ingest(list){state.files=Array.from(list);const map=new Map();for(const f of state.files){const b=base(f.name);if(!map.has(b))map.set(b,[]);map.get(b).push(f)}state.groups=Array.from(map,([key,files])=>({key,files,type:classify({files}),includeAAE:true}));render();log('Rilevati '+state.files.length+' file in '+state.groups.length+' gruppi.');}
function render(){let html='';for(let i=0;i<state.groups.length;i++){const g=state.groups[i];let aae=g.files.find(f=>ext(f.name)==='aae');html+=`<div class="group"><div class="row"><div><b>${esc(g.key)}</b><div>${g.type} <span class="tag">${g.files.length} file</span>${aae?'<span class="tag">AAE</span>':''}</div></div><div>${aae?`<label><input type="checkbox" ${g.includeAAE?'checked':''} onchange="state.groups[${i}].includeAAE=this.checked"> Includi AAE</label>`:''}</div></div><div class="small muted">${g.files.map(f=>esc(f.name)).join(' · ')}</div></div>`}$('groups').innerHTML=html||'Nessun file.';$('summary').textContent=state.files.length+' file · '+state.groups.length+' gruppi · '+state.groups.filter(g=>g.files.some(f=>ext(f.name)==='aae')).length+' gruppi con AAE';}
function clearAll(){state.files=[];state.groups=[];$('groups').textContent='Seleziona una cartella o dei file.';$('summary').textContent='Nessun file selezionato.';$('progress').textContent='';log('Selezione azzerata.');}
$('files').onchange=e=>ingest(e.target.files);$('folder').onchange=e=>ingest(e.target.files);
async function uploadOne(f,g,includeAAE){let h={'Content-Type':f.type||'application/octet-stream','Content-Length':String(f.size),'X-LPB-Filename':encodeURIComponent(f.name),'X-LPB-Category':encodeURIComponent(g.type),'X-LPB-Group':encodeURIComponent(g.key),'X-LPB-AAE':includeAAE?'true':'false'};let r=await fetch('/upload',{method:'POST',headers:h,body:f});if(!r.ok)throw new Error(f.name+' HTTP '+r.status);}
async function uploadAll(){let todo=[];for(const g of state.groups){for(const f of g.files){if(ext(f.name)==='aae'&&!g.includeAAE)continue;todo.push({f,g,includeAAE:g.includeAAE})}}$('progress').textContent='Trasferimento 0/'+todo.length;log('Avvio trasferimento di '+todo.length+' file.');let n=0;for(const x of todo){try{await uploadOne(x.f,x.g,x.includeAAE);n++;$('progress').textContent='Trasferimento '+n+'/'+todo.length;log('OK '+x.f.name+' → iPhone inbox');}catch(e){log('ERRORE '+e.message);}}log('Trasferimento terminato: '+n+'/'+todo.length+' riusciti.');}
</script></body></html>
"""
}
