import SwiftUI
import Photos
import PhotosUI

@main
struct LivePhotoBridgeApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State private var photoItem: PhotosPickerItem?
    @State private var videoItem: PhotosPickerItem?
    @State private var status = "Seleziona la foto HEIC e il video abbinato."
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "livephoto")
                    .font(.system(size: 64))
                Text("Live Photo Bridge").font(.largeTitle.bold())
                Text("Ricrea la Live Photo usando i due file originali, senza ricodificarli.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)

                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Scegli foto HEIC", systemImage: "photo")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent)

                PhotosPicker(selection: $videoItem, matching: .videos) {
                    Label("Scegli video MOV", systemImage: "video")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.bordered)

                Button { Task { await importLivePhoto() } } label: {
                    if isWorking { ProgressView().frame(maxWidth: .infinity) }
                    else { Label("Crea Live Photo", systemImage: "wand.and.stars").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(photoItem == nil || videoItem == nil || isWorking)

                Text(status).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Spacer()
            }
            .padding().navigationTitle("Live Photo Bridge")
        }
    }

    private func importLivePhoto() async {
        guard let photoItem, let videoItem else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            guard let photoData = try await photoItem.loadTransferable(type: Data.self),
                  let videoData = try await videoItem.loadTransferable(type: Data.self) else {
                status = "Impossibile leggere uno dei due file."; return
            }
            let dir = FileManager.default.temporaryDirectory
            let photoURL = dir.appendingPathComponent("livephoto-photo.heic")
            let videoURL = dir.appendingPathComponent("livephoto-video.mov")
            try photoData.write(to: photoURL, options: .atomic)
            try videoData.write(to: videoURL, options: .atomic)

            let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard auth == .authorized || auth == .limited else {
                status = "Accesso a Foto non autorizzato."; return
            }

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
                    if let error { continuation.resume(throwing: error) }
                    else if success { continuation.resume() }
                    else { continuation.resume(throwing: ImportError.failed) }
                }
            }
            status = "Fatto! Controlla l'app Foto: dovrebbe comparire come Live Photo."
        } catch { status = "Errore: \(error.localizedDescription)" }
    }

    enum ImportError: LocalizedError {
        case failed
        var errorDescription: String? { "PhotoKit non ha completato la creazione della Live Photo." }
    }
}
