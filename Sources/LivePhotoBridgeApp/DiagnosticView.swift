import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct DiagnosticView: View {
    @State private var photoURL: URL?
    @State private var videoURL: URL?
    @State private var showingPhotoPicker = false
    @State private var showingVideoPicker = false
    @State private var report: DiagnosticReport?
    @State private var importResult: String?
    @State private var isBusy = false
    @State private var errorMessage: String?

    private let engine = DiagnosticEngine()
    private let history = DiagnosticHistoryStore()
    private let photoImporter = PhotoKitImporter()

    var body: some View {
        NavigationStack {
            Form {
                Section("File") {
                    Button(photoURL?.lastPathComponent ?? "Seleziona foto") { showingPhotoPicker = true }
                    Button(videoURL?.lastPathComponent ?? "Seleziona video") { showingVideoPicker = true }
                }

                Section {
                    Button { Task { await analyze() } } label: { actionLabel("Analizza") }
                        .disabled(photoURL == nil || videoURL == nil || isBusy)
                    Button { Task { await importLivePhoto() } } label: { actionLabel("Importa come Live Photo") }
                        .disabled(photoURL == nil || videoURL == nil || isBusy || report == nil)
                }

                if let report {
                    Section("Risultato") {
                        ForEach(report.items) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(.headline)
                                Text(item.detail).font(.subheadline).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    Section("Azioni") {
                        ShareLink(item: report.plainText) { Label("Condividi report", systemImage: "square.and.arrow.up") }
                        Button("Copia report") { UIPasteboard.general.string = report.plainText }
                    }
                }
                if let importResult { Section("Importazione") { Text(importResult) } }
                if let errorMessage { Section("Errore") { Text(errorMessage).foregroundStyle(.red) } }
            }
            .navigationTitle("Diagnostica")
            .overlay { if isBusy { ProgressView().controlSize(.large) } }
            .fileImporter(isPresented: $showingPhotoPicker, allowedContentTypes: [.image], allowsMultipleSelection: false) { handle($0, isPhoto: true) }
            .fileImporter(isPresented: $showingVideoPicker, allowedContentTypes: [.movie, .mpeg4Movie], allowsMultipleSelection: false) { handle($0, isPhoto: false) }
        }
    }

    @ViewBuilder private func actionLabel(_ title: String) -> some View {
        HStack { Text(title); Spacer(); if isBusy { ProgressView() } }
    }

    private func handle(_ result: Result<[URL], Error>, isPhoto: Bool) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            if isPhoto { photoURL = url } else { videoURL = url }
            report = nil; importResult = nil; errorMessage = nil
        case .failure(let error): errorMessage = error.localizedDescription
        }
    }

    private func analyze() async {
        guard let photoURL, let videoURL else { return }
        isBusy = true; defer { isBusy = false }
        let result = await engine.analyze(photoURL: photoURL, videoURL: videoURL)
        report = result
        try? await history.append(result)
    }

    private func importLivePhoto() async {
        guard let photoURL, let videoURL else { return }
        isBusy = true; importResult = nil; errorMessage = nil; defer { isBusy = false }
        do {
            let localIdentifier = try await photoImporter.importLivePhoto(photoURL: photoURL, videoURL: videoURL)
            importResult = "Importazione completata. Asset: \(localIdentifier)"
        } catch { errorMessage = error.localizedDescription }
    }
}
