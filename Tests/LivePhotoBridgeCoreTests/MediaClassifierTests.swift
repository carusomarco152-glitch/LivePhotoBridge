import XCTest
@testable import LivePhotoBridgeCore

final class MediaClassifierTests: XCTestCase {
    func testPhotoWithoutIdentifierIsOrdinaryPhoto() {
        let url = URL(fileURLWithPath: "/tmp/IMG_0001.HEIC")
        let resource = MediaResource(url: url, kind: .photo(.heic))
        XCTAssertEqual(MediaClassifier().classify(resource), .ordinaryPhoto)
    }

    func testPhotoWithIdentifierIsPossibleLivePhotoComponent() {
        let url = URL(fileURLWithPath: "/tmp/IMG_0001.HEIC")
        let resource = MediaResource(url: url, kind: .photo(.heic), contentIdentifier: "abc")
        XCTAssertEqual(MediaClassifier().classify(resource), .possibleLivePhotoPhoto)
    }

    func testVideoWithIdentifierIsPossibleLivePhotoComponent() {
        let url = URL(fileURLWithPath: "/tmp/IMG_0001.MP4")
        let resource = MediaResource(url: url, kind: .video(.mp4), contentIdentifier: "abc")
        XCTAssertEqual(MediaClassifier().classify(resource), .possibleLivePhotoVideo)
    }
}
