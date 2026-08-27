import SwiftUI
import Photos
import PhotosUI
import ImageIO
import AVFoundation
import UniformTypeIdentifiers

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
                Text("Ricrea una Live Photo associando foto e video tramite l'asset identifier Apple.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Scegli foto HEIC", systemImage: "photo")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                PhotosPicker(selection: $videoItem, matching: .videos) {
                    Label("Scegli video MOV", systemImage: "video")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button { Task { await importLivePhoto() } } label: {
                    if isWorking {
                        ProgressView().frame(maxWidth: .infinity)
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
            status = "Leggo i file..."
            guard let photoData = try await photoItem.loadTransferable(type: Data.self),
                  let videoData = try await videoItem.loadTransferable(type: Data.self) else {
                throw LivePhotoError.invalidInput
            }

            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("LivePhotoBridge", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let identifier = UUID().uuidString.uppercased()
            let sourcePhotoURL = dir.appendingPathComponent("source.heic")
            let sourceVideoURL = dir.appendingPathComponent("source.mov")
            let pairedPhotoURL = dir.appendingPathComponent("paired.heic")
            let pairedVideoURL = dir.appendingPathComponent("paired.mov")

            try photoData.write(to: sourcePhotoURL, options: .atomic)
            try videoData.write(to: sourceVideoURL, options: .atomic)

            status = "Preparo la foto..."
            try addAssetIdentifier(identifier, toImage: sourcePhotoURL, destination: pairedPhotoURL)

            status = "Preparo il video e i metadati Live Photo..."
            try await createPairedVideo(from: sourceVideoURL, identifier: identifier, destination: pairedVideoURL)

            guard FileManager.default.fileExists(atPath: pairedPhotoURL.path),
                  FileManager.default.fileExists(atPath: pairedVideoURL.path) else {
                throw LivePhotoError.creationFailed
            }

            let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard auth == .authorized || auth == .limited else {
                throw LivePhotoError.photoLibraryDenied
            }

            status = "Salvo nella libreria Foto..."
            try await saveLivePhoto(photoURL: pairedPhotoURL, videoURL: pairedVideoURL)
            status = "✅ Live Photo creata. Controlla Foto."
        } catch {
            status = "❌ Errore: \(error.localizedDescription)"
        }
    }

    private func addAssetIdentifier(_ identifier: String, toImage source: URL, destination: URL) throws {
        guard let sourceRef = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(sourceRef, 0, nil),
              let sourceProperties = CGImageSourceCopyPropertiesAtIndex(sourceRef, 0, nil) as? [CFString: Any] else {
            throw LivePhotoError.invalidPhoto
        }

        let sourceType = CGImageSourceGetType(sourceRef) ?? UTType.heic.identifier as CFString
        let type = sourceType as String
        guard let destinationRef = CGImageDestinationCreateWithURL(
            destination as CFURL,
            type as CFString,
            1,
            nil
        ) else {
            throw LivePhotoError.invalidPhoto
        }

        var properties = sourceProperties
        properties[kCGImagePropertyMakerAppleDictionary] = ["17": identifier]

        CGImageDestinationAddImage(destinationRef, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destinationRef) else {
            throw LivePhotoError.invalidPhoto
        }
    }

    private func createPairedVideo(from source: URL, identifier: String, destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.load(.tracks)
        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
            throw LivePhotoError.invalidVideo
        }

        let duration = try await asset.load(.duration)
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
            if ar.canAdd(ao) {
                ar.add(ao)
                audioReader = ar
                audioOutput = ao
            }
        }

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(naturalSize.width),
                AVVideoHeightKey: Int(naturalSize.height)
            ]
        )
        videoInput.transform = transform
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw LivePhotoError.videoWriterFailed }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioTrack != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        let identifierItem = AVMutableMetadataItem()
        identifierItem.identifier = .quickTimeMetadataContentIdentifier
        identifierItem.value = identifier as NSString
        identifierItem.dataType = kCMMetadataBaseDataType_UTF8 as String
        writer.metadata = [identifierItem]

        guard writer.startWriting() else {
            throw writer.error ?? LivePhotoError.videoWriterFailed
        }
        writer.startSession(atSourceTime: .zero)

        let metadataAdaptor = try makeStillImageTimeAdaptor()
        guard writer.canAdd(metadataAdaptor.assetWriterInput) else {
            throw LivePhotoError.videoWriterFailed
        }
        writer.add(metadataAdaptor.assetWriterInput)

        let durationSeconds = CMTimeGetSeconds(duration)
        let stillTime = CMTime(seconds: max(0, min(durationSeconds * 0.5, durationSeconds)), preferredTimescale: 600)
        let stillItem = AVMutableMetadataItem()
        stillItem.identifier = .quickTimeMetadataStillImageTime
        stillItem.value = NSNumber(value: 0xFF)
        stillItem.dataType = kCMMetadataBaseDataType_SInt8 as String
        metadataAdaptor.append(
            AVTimedMetadataGroup(items: [stillItem], timeRange: CMTimeRange(start: stillTime, duration: CMTime(value: 1, timescale: 600)))
        )

        guard reader.startReading() else {
            throw reader.error ?? LivePhotoError.videoReaderFailed
        }

        videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "LivePhotoBridge.video")) {
            while videoInput.isReadyForMoreMediaData {
                if let sample = videoOutput.copyNextSampleBuffer() {
                    if !videoInput.append(sample) {
                        reader.cancelReading()
                        videoInput.markAsFinished()
                        return
                    }
                } else {
                    videoInput.markAsFinished()
                    return
                }
            }
        }

        if let audioReader, let audioOutput, let audioInput {
            guard audioReader.startReading() else {
                audioInput.markAsFinished()
                throw audioReader.error ?? LivePhotoError.audioReaderFailed
            }
            audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "LivePhotoBridge.audio")) {
                while audioInput.isReadyForMoreMediaData {
                    if let sample = audioOutput.copyNextSampleBuffer() {
                        if !audioInput.append(sample) {
                            audioReader.cancelReading()
                            audioInput.markAsFinished()
                            return
                        }
                    } else {
                        audioInput.markAsFinished()
                        return
                    }
                }
            }
        }

        while writer.status == .writing {
            try await Task.sleep(for: .milliseconds(50))
        }

        if writer.status != .completed {
            throw writer.error ?? LivePhotoError.videoWriterFailed
        }
    }

    private func makeStillImageTimeAdaptor() throws -> AVAssetWriterInputMetadataAdaptor {
        var spec: CMMetadataFormatDescription?
        let specifications: [[String: Any]] = [[
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
                AVMetadataIdentifier.quickTimeMetadataStillImageTime.rawValue,
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
                kCMMetadataBaseDataType_SInt8
        ]]
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: specifications as CFArray,
            formatDescriptionOut: &spec
        )
        guard status == noErr, let spec else { throw LivePhotoError.metadataFailed }
        let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil)
        input.mediaTimeScale = 600
        return AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
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
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: LivePhotoError.creationFailed)
                }
            }
        }
    }

    enum LivePhotoError: LocalizedError {
        case invalidInput
        case invalidPhoto
        case invalidVideo
        case videoReaderFailed
        case videoWriterFailed
        case audioReaderFailed
        case metadataFailed
        case creationFailed
        case photoLibraryDenied

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
