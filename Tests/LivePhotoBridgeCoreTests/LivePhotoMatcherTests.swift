import XCTest
@testable import LivePhotoBridgeCore

final class LivePhotoMatcherTests: XCTestCase {
    func testExactContentIdentifierIsHighConfidence() async {
        let photo = MediaResource(
            url: URL(fileURLWithPath: "/tmp/IMG_0001.HEIC"),
            kind: .photo(.heic),
            contentIdentifier: "ABC"
        )
        let video = MediaResource(
            url: URL(fileURLWithPath: "/tmp/IMG_0001.MOV"),
            kind: .video(.mov),
            contentIdentifier: "ABC"
        )

        let matcher = LivePhotoMatcher()
        let result = await matcher.match(photos: [photo], videos: [video])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].confidence, .exact)
        XCTAssertTrue(result[0].issues.isEmpty)
    }

    func testSameNameButDifferentIdentifiersIsNotAutomatic() async {
        let photo = MediaResource(
            url: URL(fileURLWithPath: "/tmp/IMG_0002.HEIC"),
            kind: .photo(.heic),
            contentIdentifier: "PHOTO-ID"
        )
        let video = MediaResource(
            url: URL(fileURLWithPath: "/tmp/IMG_0002.MOV"),
            kind: .video(.mov),
            contentIdentifier: "VIDEO-ID"
        )

        let matcher = LivePhotoMatcher()
        let result = await matcher.match(photos: [photo], videos: [video])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].confidence, .probable)
        XCTAssertTrue(result[0].issues.contains(.contentIdentifierMismatch))
    }

    func testMissingVideoIsSurfaced() async {
        let photo = MediaResource(
            url: URL(fileURLWithPath: "/tmp/IMG_0003.JPEG"),
            kind: .photo(.jpeg),
            contentIdentifier: "MISSING-VIDEO"
        )

        let matcher = LivePhotoMatcher()
        let result = await matcher.match(photos: [photo], videos: [])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].confidence, .incomplete)
        XCTAssertTrue(result[0].issues.contains(.videoMissing))
    }

    func testUnmatchedVideoIsSurfaced() async {
        let video = MediaResource(
            url: URL(fileURLWithPath: "/tmp/IMG_0004.MP4"),
            kind: .video(.mp4),
            contentIdentifier: "ORPHAN"
        )

        let matcher = LivePhotoMatcher()
        let result = await matcher.match(photos: [], videos: [video])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].confidence, .incomplete)
        XCTAssertTrue(result[0].issues.contains(.photoMissing))
    }
}
