# Live Photo Bridge

A privacy-first iOS application for importing large photo/video collections from a computer into the iPhone Photos library, with special handling for Apple Live Photos.

## Project goals

- Import thousands of photos and videos without iTunes/Finder synchronization.
- Preserve original media files whenever possible; do not transcode unnecessarily.
- Detect Live Photo pairs using Apple's ContentIdentifier metadata.
- Support HEIC/JPEG still resources and MOV/MP4 video candidates at the discovery layer.
- Treat suspicious pairs (for example, same filename but different ContentIdentifiers) as **incomplete** instead of silently pairing them.
- Import valid pairs as a single Photos Live Photo using PhotoKit.
- Provide a permanent import history, detailed progress, and an error log.
- Keep the PC-to-iPhone transfer local to the user's network; no cloud service is required.

## Current status

This repository starts from zero. The first milestone is the Live Photo engine, before the transfer UI is built.

Implemented in the first scaffold:

- Domain models for media resources and Live Photo candidates.
- ContentIdentifier readers for still-image MakerApple metadata and QuickTime movie metadata.
- Conservative matching engine:
  - exact ContentIdentifier match -> automatic/high-confidence candidate;
  - same filename with a differing identifier -> probable/manual-review candidate;
  - missing counterpart -> incomplete candidate;
  - ambiguous matches -> manual review.
- PhotoKit importer using `PHAssetCreationRequest` with `.photo` + `.pairedVideo`.
- Unit tests for the matching rules.

Apple documents that a Live Photo appears as one Photos asset but is composed of a still image and a movie, and that `PHAssetCreationRequest` can save those resources together using `.photo` and `.pairedVideo` without requiring an intermediate media render. See the Apple documentation links in the project notes below.

## Development plan

1. Validate real-world Live Photo metadata from exported iPhone assets.
2. Build an on-device diagnostic/test screen that imports one pair and verifies the resulting `PHAsset`.
3. Add robust metadata inspection and validation, including the movie's Live Photo metadata track.
4. Build the local PC/browser transfer service.
5. Add large-transfer queueing, pause/resume, checksums, and progress reporting.
6. Add the Live Photo incomplete review queue.
7. Add permanent import history and error logs.
8. Build the final SwiftUI interface.
9. Produce SideStore-compatible development builds for real-device testing.

## Important design rule

A filename match is never enough for automatic Live Photo reconstruction. The app must prefer the ContentIdentifier and validate the actual resources. A suspicious pair is shown to the user rather than silently creating a potentially incorrect Live Photo.
