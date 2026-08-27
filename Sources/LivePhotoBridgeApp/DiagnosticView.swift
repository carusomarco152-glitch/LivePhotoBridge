import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticView: View {
    @State private var photoURL: URL?
    @State private var videoURL: URL?
    @State private var showingPhotoPicker = false
    @State private var showingVideoPicker = false
    @State private var report: DiagnosticReport?
    @State private var isAnalyzing = false
    @State private var errorMessage: String?

    private let engine = DiagnosticEngine()
    private let history = DiagnosticHistoryStore()

    var body: some View {
        NavigationStack {
            Form {
                Section("File") {
                    Button(photoURL?.lastPathComponent ?? "Seleziona foto") {
                        showingPhotoPicker = true
                    }
                    Button(videoURL?.lastPathComponent ?? "Seleziona video") {
                        showingVideoPicker = true
                    }
                }

                Section {
                    Button {
                        Task { await analyze() }
                    } label: {
                        HStack {
                            Text("Analizza")
                            Spacer()
                            if isAnalyzing { ProgressView() }
                        }
                    }
                    .disabled(photoURL == nil || videoURL == nil || isAnalyzing)
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
                        ShareLink(item: report.plainText) {
                            Label("Condividi report", systemImage: "square.and.arrow.up")
                        }
                        Button("Copia report") {
                            UIPasteboard.general.string = report.plainText
                        }
                    }
                }

                if let errorMessage {
                    Section("Errore") {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Diagnostica")
            .fileImporter(isPresented: $showingPhotoPicker, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
                handle(result, assigningTo: \ .photoURL)
            }
            .fileImporter(isPresented: $showingVideoPicker, allowedContentTypes: [.movie, .mpeg4Movie], allowsMultipleSelection: false) { result in
                handle(result, assigningTo: \ .videoURL)
            }
        }
    }

    private func handle(_ result: Result<[URL], Error>, assigningTo keyPath: ReferenceWritableKeyPath<DiagnosticView, URL?>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            if url.startAccessingSecurityScopedResource() {
                defer { url.stopAccessingSecurityScopedResource() }
            }
            if keyPath == \ .photoURL { photoURL = url } else { videoURL = url }
            report = nil
            errorMessage = nil
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func analyze() async {
        guard let photoURL, let videoURL else { return }
        isAnalyzing = true
        defer { isAnalyzing = false }
        let result = await engine.analyze(photoURL: photoURL, videoURL: videoURL)
        report = result
        try? await history.append(result)
    }
}
