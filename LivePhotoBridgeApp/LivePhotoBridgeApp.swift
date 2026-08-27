import SwiftUI
import PhotosUI
import LivePhotoBridgeCore

@main
struct LivePhotoBridgeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var photoItem: PhotosPickerItem?
    @State private var videoItem: PhotosPickerItem?
    @State private var status = "Seleziona una foto e il relativo video Live Photo."
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "livephoto")
                    .font(.system(size: 64))
                    .symbolRenderingMode(.hierarchical)

                Text("Live Photo Bridge")
                    .font(.largeTitle.bold())

                Text("Ricrea una Live Photo usando il file HEIC originale e il video abbinato.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Scegli foto HEIC", systemImage: "photo")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                PhotosPicker(selection: $videoItem, matching: .videos) {
                    Label("Scegli video", systemImage: "video")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await importLivePhoto() }
                } label: {
                    if isWorking {
                        ProgressView()
                            .frame(maxWidth: .infinity)
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
            guard let photoData = try await photoItem.loadTransferable(type: Data.self),
                  let videoData = try await videoItem.loadTransferable(type: Data.self) else {
                status = "Impossibile leggere uno dei due file."
                return
            }

            let directory = FileManager.default.temporaryDirectory
            let photoURL = directory.appendingPathComponent("livephoto-photo.heic")
            let videoURL = directory.appendingPathComponent("livephoto-video.mov")
            try photoData.write(to: photoURL, options: .atomic)
            try videoData.write(to: videoURL, options: .atomic)

            let importer = PhotoLibraryImporter()
            let result = try await importer.importLivePhoto(photoURL: photoURL, videoURL: videoURL)
            status = result.created ? "Live Photo creata nella libreria Foto." : "Importazione non completata."
        } catch {
            status = "Errore: \(error.localizedDescription)"
        }
    }
}
