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
        FileRepresentation(contentType: .image) { item in SentTransferredFile(item.url) } importing: { received in
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickerPhotoFile(url: destination)
        }
    }
}

struct PickerVideoFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { item in SentTransferredFile(item.url) } importing: { received in
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickerVideoFile(url: destination)
        }
        FileRepresentation(contentType: .quickTimeMovie) { item in SentTransferredFile(item.url) } importing: { received in
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickerVideoFile(url: destination)
        }
    }
}

struct ContentView: View {
    @State private var photoItem: PhotosPickerItem?
    @State private var videoItem: PhotosPickerItem?
    @State private var status = "Seleziona la foto HEIC/JPEG e il video MOV/MP4 abbinato."
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "livephoto").font(.system(size: 64))
                Text("Live Photo Bridge").font(.largeTitle.bold())
                Text("Ricrea una Live Photo associando foto e video tramite l'asset identifier Apple.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                PhotosPicker(selection: $photoItem, matching: .images) { Label("Scegli foto HEIC/JPEG", systemImage: "photo").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
                PhotosPicker(selection: $videoItem, matching: .videos) { Label("Scegli video MOV/MP4", systemImage: "video").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                Button { Task { await importLivePhoto() } } label: {
                    if isWorking { ProgressView().frame(maxWidth: .infinity) } else { Label("Crea Live Photo", systemImage: "wand.and.stars").frame(maxWidth: .infinity) }
                }.buttonStyle(.borderedProminent).disabled(photoItem == nil || videoItem == nil || isWorking)
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
            guard let pickedPhoto = try await photoItem.loadTransferable(type: PickerPhotoFile.self), let pickedVideo = try await videoItem.loadTransferable(type: PickerVideoFile.self) else { throw LivePhotoError.invalidInput }

            let photoExtension = pickedPhoto.url.pathExtension.isEmpty ? "heic" : pickedPhoto.url.pathExtension.lowercased()
            let videoExtension = pickedVideo.url.pathExtension.isEmpty ? "mp4" : pickedVideo.url.pathExtension.lowercased()
            let sourcePhoto = dir.appendingPathComponent("source.\(photoExtension)")
            let sourceVideo = dir.appendingPathComponent("source.\(videoExtension)")
            let pairedPhoto = dir.appendingPathComponent("paired.\(photoExtension)")
            // Apple Photos expects the paired Live Photo movie as a QuickTime movie.
            // MP4 input is therefore REMUXED to MOV: compressed audio/video samples are
            // copied without decoding or re-encoding, so there is no generation loss.
            // MOV input is also passed through the same sample-copy path so the required
            // Live Photo metadata can be added without transcoding it.
            let pairedVideo = dir.appendingPathComponent("paired.mov")
            try? FileManager.default.removeItem(at: sourcePhoto); try? FileManager.default.removeItem(at: sourceVideo); try? FileManager.default.removeItem(at: pairedPhoto); try? FileManager.default.removeItem(at: pairedVideo)
            try FileManager.default.copyItem(at: pickedPhoto.url, to: sourcePhoto)
            try FileManager.default.copyItem(at: pickedVideo.url, to: sourceVideo)
            status = "Preparo la foto..."
            try addAssetIdentifier(identifier, toImage: sourcePhoto, destination: pairedPhoto)
            status = "Preparo il video Live Photo senza ricodifica..."
            try await createPairedVideo(from: sourceVideo, identifier: identifier, destination: pairedVideo)
            let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard auth == .authorized || auth == .limited else { throw LivePhotoError.photoLibraryDenied }
            status = "Salvo nella libreria Foto..."
            try await saveLivePhoto(photoURL: pairedPhoto, videoURL: pairedVideo)
            status = "✅ Live Photo creata. Controlla Foto."
        } catch { status = "❌ Errore: \(error.localizedDescription)" }
    }

    private func addAssetIdentifier(_ identifier: String, toImage source: URL, destination: URL) throws {
        guard let sourceRef = CGImageSourceCreateWithURL(source as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(sourceRef, 0, nil), var properties = CGImageSourceCopyPropertiesAtIndex(sourceRef, 0, nil) as? [CFString: Any] else { throw LivePhotoError.invalidPhoto }
        guard let sourceType = CGImageSourceGetType(sourceRef), let destinationRef = CGImageDestinationCreateWithURL(destination as CFURL, sourceType, 1, nil) else { throw LivePhotoError.invalidPhoto }

        // Preserve every existing MakerApple entry and change only the asset identifier.
        // In particular, do not replace the whole MakerApple dictionary with just key 17.
        var makerApple = properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any] ?? [:]
        makerApple["17"] = identifier
        properties[kCGImagePropertyMakerAppleDictionary] = makerApple

        CGImageDestinationAddImage(destinationRef, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destinationRef) else { throw LivePhotoError.invalidPhoto }
    }

    private func createPairedVideo(from source: URL, identifier: String, destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.load(.tracks)
        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else { throw LivePhotoError.invalidVideo }
        guard let firstVideoDescription = videoTrack.formatDescriptions.first else { throw LivePhotoError.videoReaderFailed }
        let videoFormat = firstVideoDescription as! CMFormatDescription
        let transform = try await videoTrack.load(.preferredTransform)
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        guard reader.canAdd(videoOutput) else { throw LivePhotoError.videoReaderFailed }
        reader.add(videoOutput)
        let audioTrack = tracks.first(where: { $0.mediaType == .audio })
        var audioReader: AVAssetReader?
        var audioOutput: AVAssetReaderTrackOutput?
        var audioFormat: CMFormatDescription?
        if let audioTrack = audioTrack {
            let ar = try AVAssetReader(asset: asset)
            let ao = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            if ar.canAdd(ao) {
                ar.add(ao)
                audioReader = ar
                audioOutput = ao
                if let firstAudioDescription = audioTrack.formatDescriptions.first {
                    audioFormat = firstAudioDescription as! CMFormatDescription
                }
            }
        }

        // Always write a QuickTime container because this is the container expected by
        // Apple's Live Photo paired-video resource. AVAssetReaderTrackOutput and
        // AVAssetWriterInput both use nil settings: the compressed samples are copied
        // as-is. This is a remux, not a video/audio re-encode.
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        videoInput.transform = transform
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw LivePhotoError.videoWriterFailed }
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if let audioFormat = audioFormat {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); audioInput = input }
        }

        // Preserve all source top-level metadata. The only existing item we replace is
        // Apple's content identifier, because it must match the still image's identifier.
        // No other source metadata is intentionally removed or rewritten.
        var writerMetadata = asset.metadata
        writerMetadata.removeAll { $0.identifier == .quickTimeMetadataContentIdentifier }
        let identifierItem = AVMutableMetadataItem()
        identifierItem.identifier = .quickTimeMetadataContentIdentifier
        identifierItem.value = identifier as NSString
        identifierItem.dataType = kCMMetadataBaseDataType_UTF8 as String
        writerMetadata.append(identifierItem)
        writer.metadata = writerMetadata

        let metadataInput = try makeStillImageTimeInput()
        guard writer.canAdd(metadataInput) else { throw LivePhotoError.metadataFailed }
        writer.add(metadataInput)
        let metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
        guard writer.startWriting() else { throw writer.error ?? LivePhotoError.videoWriterFailed }
        writer.startSession(atSourceTime: .zero)
        let stillItem = AVMutableMetadataItem()
        stillItem.key = "com.apple.quicktime.still-image-time" as NSString
        stillItem.keySpace = .quickTimeMetadata
        stillItem.value = NSNumber(value: -1)
        stillItem.dataType = kCMMetadataBaseDataType_SInt8 as String
        let stillGroup = AVTimedMetadataGroup(items: [stillItem], timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 600)))
        guard metadataAdaptor.append(stillGroup) else {
            writer.cancelWriting()
            throw LivePhotoError.metadataFailed
        }
        metadataInput.markAsFinished()

        guard reader.startReading() else {
            writer.cancelWriting()
            throw reader.error ?? LivePhotoError.videoReaderFailed
        }
        if let audioReader = audioReader {
            guard audioReader.startReading() else {
                writer.cancelWriting()
                throw audioReader.error ?? LivePhotoError.audioReaderFailed
            }
        }

        let videoQueue = DispatchQueue(label: "LivePhotoBridge.video")
        videoInput.requestMediaDataWhenReady(on: videoQueue) {
            while videoInput.isReadyForMoreMediaData {
                guard let sample = videoOutput.copyNextSampleBuffer() else {
                    videoInput.markAsFinished()
                    return
                }
                if !videoInput.append(sample) {
                    videoInput.markAsFinished()
                    return
                }
            }
        }
        if let audioReader = audioReader, let audioOutput = audioOutput, let audioInput = audioInput {
            let audioQueue = DispatchQueue(label: "LivePhotoBridge.audio")
            audioInput.requestMediaDataWhenReady(on: audioQueue) {
                while audioInput.isReadyForMoreMediaData {
                    guard let sample = audioOutput.copyNextSampleBuffer() else {
                        audioInput.markAsFinished()
                        return
                    }
                    if !audioInput.append(sample) {
                        audioInput.markAsFinished()
                        return
                    }
                }
            }
        }

        try await waitForWriterToFinish(writer, timeout: 120)
        guard writer.status == .completed else { throw writer.error ?? LivePhotoError.videoWriterFailed }
    }

    private func waitForWriterToFinish(_ writer: AVAssetWriter, timeout: Double) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while writer.status == .writing {
            if Date() > deadline {
                writer.cancelWriting()
                throw LivePhotoError.videoWriterTimeout
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func makeStillImageTimeInput() throws -> AVAssetWriterInput {
        var formatDescription: CMMetadataFormatDescription?
        let specifications: [[String: Any]] = [[kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time", kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8]]
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: specifications as CFArray, formatDescriptionOut: &formatDescription)
        guard status == noErr, let formatDescription = formatDescription else { throw LivePhotoError.metadataFailed }
        return AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: formatDescription)
    }

    private func saveLivePhoto(photoURL: URL, videoURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                let photoOptions = PHAssetResourceCreationOptions(); photoOptions.shouldMoveFile = false
                request.addResource(with: .photo, fileURL: photoURL, options: photoOptions)
                let videoOptions = PHAssetResourceCreationOptions(); videoOptions.shouldMoveFile = false
                request.addResource(with: .pairedVideo, fileURL: videoURL, options: videoOptions)
            }) { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume(returning: ()) }
                else { continuation.resume(throwing: LivePhotoError.creationFailed) }
            }
        }
    }

    enum LivePhotoError: LocalizedError {
        case invalidInput, invalidPhoto, invalidVideo, videoReaderFailed, videoWriterFailed, audioReaderFailed, metadataFailed, creationFailed, photoLibraryDenied, videoWriterTimeout
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
            case .videoWriterTimeout: return "La preparazione del video è rimasta bloccata oltre 2 minuti."
            }
        }
    }
}
