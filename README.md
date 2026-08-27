# Live Photo Bridge

A privacy-first iOS application for importing large photo/video collections from a computer into the iPhone Photos library, with special handling for Apple Live Photos and other computational-photo features.

## Core rules

- **Original files first:** no intentional image/video transcoding or recompression.
- Ordinary photos and videos are imported as ordinary Photos assets unless metadata gives a credible reason to treat them as Live Photo components.
- A filename match is **never** enough for automatic Live Photo reconstruction.
- Exact `ContentIdentifier` matches are high-confidence candidates.
- Suspicious cases (for example, same filename but different identifiers) go to **Live Photo Incomplete** for manual review.
- A successful import must be followed by verification where the Photos APIs allow it.
- Source files on the PC are never deleted automatically.
- Interrupted large transfers must be resumable.
- Import sessions are permanently summarized in an on-device history.
- Errors and warnings are retained in a copyable/shareable log.
- PC-to-iPhone transfer is local-network only; no cloud service is required.

## Current implementation

The first core scaffold is now in the repository:

- `MediaResource` models HEIC/JPEG still resources and MOV/MP4 video resources.
- `ContentIdentifierReader` reads the Apple Live Photo identifier from still-image MakerApple metadata and QuickTime movie metadata.
- `LivePhotoMatcher` provides conservative pairing decisions.
- `MediaClassifier` separates ordinary media from resources that contain Live Photo evidence before pairing is attempted.
- `ImportModels` defines import disposition, stages, progress and persistent summary data.
- `BridgeLogger` provides structured, copyable log entries for diagnostics.
- `LivePhotoImporter` is the PhotoKit import boundary; it is deliberately kept separate from transfer and matching logic.
- Unit tests cover the initial conservative classification rules.

## Planned import pipeline

```text
PC files
   ↓
local transfer
   ↓
metadata scan
   ↓
media classification
   ↓
Live Photo matching
   ├─ ordinary photo/video → normal Photos import
   ├─ exact Live Photo match → Live Photo import
   └─ suspicious/ambiguous → Live Photo Incomplete
   ↓
PhotoKit import
   ↓
verification
   ↓
persistent import history + error log
```

## Live Photo matching policy

The app supports HEIC/JPEG and MOV/MP4 at the discovery layer. Extensions are not sufficient to declare a Live Photo. The validator will inspect metadata and resource compatibility before using `PHAssetCreationRequest` with `.photo` and `.pairedVideo`.

Examples:

- matching identifier + valid resources → automatic Live Photo candidate;
- different identifiers but same filename/other compatible evidence → manual review;
- missing counterpart → Live Photo Incomplete;
- no Live Photo evidence → ordinary media import;
- ambiguous pairing → manual review, never silent pairing.

## Development roadmap

1. Validate the supplied real-world HEIC + MP4 sample and other real iPhone samples.
2. Build the on-device diagnostic screen for one-pair import and post-import verification.
3. Expand metadata validation, including Live Photo movie metadata and Portrait/depth detection.
4. Build the local browser-based PC transfer service with automatic device discovery and pairing.
5. Add large-transfer queueing, checksums, pause/resume and progress reporting.
6. Add the Live Photo Incomplete review queue.
7. Add permanent import history, duplicate detection and error logs.
8. Build the final SwiftUI interface.
9. Configure development signing and SideStore-compatible builds for real-device testing.
10. Add regression fixtures/tests for ordinary media, Live Photos, Portrait/depth, HDR, slow-motion and other computational media.

## Safety principle

If the app cannot preserve a special capability reliably through the public Photos APIs, it must report that limitation rather than silently converting or degrading the user's media.
