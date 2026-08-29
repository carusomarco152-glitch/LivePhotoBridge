import SwiftUI
import Photos
import PhotosUI
import ImageIO
import AVFoundation
import UniformTypeIdentifiers
import CoreTransferable

@main
struct LivePhotoBridgeApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct PickerPhotoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .image) { item in
            SentTransferredFile(item.url)
        } importing: { received in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickerPhotoFile(url: destination)
        }
    }
}

struct PickerVideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { item in
            SentTransferredFile(item.url)
        } importing: { received in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickerVideoFile(url: destination)
        }
        FileRepresentation(contentType: .quickTimeMovie) { item in
            SentTransferredFile(item.url)
        } importing: { received in
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickerVideoFile(url: destination)
        }
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
                Image(systemName: "livephoto").font(.system(size: 64))
                Text("Live Photo Bridge").font(.largeTitle.bold())
                Text("Ricrea una Live Photo associando foto e video tramite l'asset identifier Apple.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Scegli foto HEIC", systemImage: "photo").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent)
                PhotosPicker(selection: $videoItem, matching: .videos) {
                    Label("Scegli video MOV", systemImage: "video").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered)
                Button { Task { await importLivePhoto() } } label: {
                    if isWorking { ProgressView().frame(maxWidth: .infinity) }
                    else { Label("Crea Live Photo", systemImage: "wand.and.stars").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(photoItem == nil || videoItem == nil || isWorking)
                Text(status).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Spacer()
            }.padding().navigationTitle("Live Photo Bridge")
        }
    }

    private func importLivePhoto() async {
        guard let photoItem, let videoItem else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            status = "Preparo i file..."
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LivePhotoBridge", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let identifier = UUID().uuidString.uppercased()
            let sourcePhoto = dir.appendingPathComponent("source.heic")
            let sourceVideo = dir.appendingPathComponent("source.mov")
            let pairedPhoto = dir.appendingPathComponent("paired.heic")
            let pairedVideo = dir.appendingPathComponent("paired.mov")

            guard let pickedPhoto = try await photoItem.loadTransferable(type: PickerPhotoFile.self),
                  let pickedVideo = try await videoItem.loadTransferable(type: PickerVideoFile.self) else {
                throw LivePhotoError.invalidInput
            }
            try? FileManager.default.removeItem(at: sourcePhoto)
            try? FileManager.default.removeItem(at: sourceVideo)
            try FileManager.default.copyItem(at: pickedPhoto.url, to: sourcePhoto)
            try FileManager.default.copyItem(at: pickedVideo.url, to: sourceVideo)

            status = "Preparo la foto..."
            try addAssetIdentifier(identifier, toImage: sourcePhoto, destination: pairedPhoto)
            status = "Preparo il video e i metadati Live Photo..."
            try await createPairedVideo(from: sourceVideo, identifier: identifier, destination: pairedVideo)

            let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard auth == .authorized || auth == .limited else { throw LivePhotoError.photoLibraryDenied }
            status = "Salvo nella libreria Foto..."
            try await saveLivePhoto(photoURL: pairedPhoto, videoURL: pairedVideo)
            status = "✅ Live Photo creata. Controlla Foto."
        } catch {
            status = "❌ Errore: \(error.localizedDescription)"
        }
    }

    private func addAssetIdentifier(_ identifier: String, toImage source: URL, destination: URL) throws {
        guard let sourceRef = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(sourceRef, 0, nil),
              var properties = CGImageSourceCopyPropertiesAtIndex(sourceRef, 0, nil) as? [CFString: Any] else {
            throw LivePhotoError.invalidPhoto
        }
        let sourceType = CGImageSourceGetType(sourceRef) ?? (UTType.heic.identifier as CFString)
        guard let destinationRef = CGImageDestinationCreateWithURL(destination as CFURL, sourceType, 1, nil) else {
            throw LivePhotoError.invalidPhoto
        }
        properties[kCGImagePropertyMakerAppleDictionary] = ["17": identifier]
        CGImageDestinationAddImage(destinationRef, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destinationRef) else { throw LivePhotoError.invalidPhoto }
    }

    private func createPairedVideo(from source: URL, identifier: String, destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.load(.tracks)
        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else { throw LivePhotoError.invalidVideo }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        guard reader.canAdd(videoOutput) else { throw LivePhotoError.videoReaderFailed }
        reader.add(videoOutput)

        let audioTrack = tracks.first(where: { $0.mediaType == .audio })
        var audioReader: AVAssetReader?
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let ar = try AVAssetReader(asset: asset)
            let ao = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            if ar.canAdd(ao) { ar.add(ao); audioReader = ar; audioOutput = ao }
        }

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil)
        videoInput.transform = transform
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw LivePhotoError.videoWriterFailed }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioTrack != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); audioInput = input }
        }

        let identifierItem = AVMutableMetadataItem()
        identifierItem.identifier = .quickTimeMetadataContentIdentifier
        identifierItem.value = identifier as NSString
        identifierItem.dataType = kCMMetadataBaseDataType_UTF8 as String
        writer.metadata = [identifierItem]

        let metadataInput = try makeStillImageTimeInput()
        guard writer.canAdd(metadataInput) else { throw LivePhotoError.metadataFailed }
        writer.add(metadataInput)
        let metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)

        guard writer.startWriting() else { throw writer.error ?? LivePhotoError.videoWriterFailed }
        writer.startSession(atSourceTime: .zero)

        let stillItem = AVMutableMetadataItem()
        stillItem.key = "com.apple.quicktime.still-image-time" as (NSCopying & NSObjectProtocol)
        stillItem.keySpace = AVMetadataKeySpace.quickTimeMetadata
        stillItem.value = NSNumber(value: -1)
        stillItem.dataType = kCMMetadataBaseDataType_SInt8 as String
        guard metadataAdaptor.append(AVTimedMetadataGroup(
            items: [stillItem],
            timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 600))
        )) else {
            writer.cancelWriting()
            throw LivePhotoError.metadataFailed
        }

        guard reader.startReading() else { throw reader.error ?? LivePhotoError.videoReaderFailed }
        videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "LivePhotoBridge.video")) {
            while videoInput.isReadyForMoreMediaData {
                guard let sample = videoOutput.copyNextSampleBuffer() else {
                    videoInput.markAsFinished(); return
                }
                if !videoInput.append(sample) {
                    reader.cancelReading(); videoInput.markAsFinished(); return
                }
            }
        }

        if let audioReader, let audioOutput, let audioInput {
            guard audioReader.startReading() else { throw audioReader.error ?? LivePhotoError.audioReaderFailed }
            audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "LivePhotoBridge.audio")) {
                while audioInput.isReadyForMoreMediaData {
                    guard let sample = audioOutput.copyNextSampleBuffer() else {
                        audioInput.markAsFinished(); return
                    }
                    if !audioInput.append(sample) {
                        audioReader.cancelReading(); audioInput.markAsFinished(); return
                    }
                }
            }
        }

        while writer.status == .writing { try await Task.sleep(for: .milliseconds(50)) }
        guard writer.status == .completed else { throw writer.error ?? LivePhotoError.videoWriterFailed }
    }

    private func makeStillImageTimeInput() throws -> AVAssetWriterInput {
        var formatDescription: CMMetadataFormatDescription?
        let specifications: [[String: Any]] = [[
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8
        ]]
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: specifications as CFArray,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else { throw LivePhotoError.metadataFailed }
        return AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: formatDescription)
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
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume(returning: ()) }
                else { continuation.resume(throwing: LivePhotoError.creationFailed) }
            }
        }
    }

    enum LivePhotoError: LocalizedError {
        case invalidInput, invalidPhoto, invalidVideo, videoReaderFailed, videoWriterFailed
        case audioReaderFailed, metadataFailed, creationFailed, photoLibraryDenied
        var errorDescription: String? {
            switch self {
            case .invalidInput: return "Impossibile leggere foto o video selezionati."
            case .invalidPhoto: return "La foto non è un'immagine valida."
            case .invalidVideo: return "Il video non contiene una traccia video valida."
            case .videoReaderFailed: return "Impossibile leggere il video."
            case .videoWriterFailed: return "Impossibile preparare il video Live Photo."
            case .audioReaderFailed: return "Impossibile leggere l'audio del video."
            case .metadataFailed: return "Impossibile creare i metadati Live Photo."
            case .creationFailed: return "Foto non ha completato la creazione della Live Photo."
            case .photoLibraryDenied: return "Accesso alla libreria Foto non autorizzato."
            }
        }
    }
}
