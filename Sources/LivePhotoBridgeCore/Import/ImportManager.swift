import Foundation

public actor ImportManager {
    private let queue: ImportQueueStore
    private var isRunning = false

    public init(queue: ImportQueueStore) {
        self.queue = queue
    }

    public func start() async throws {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        while let item = await queue.nextPendingItem() {
            try await process(item)
        }
    }

    public func cancel() {
        isRunning = false
    }

    private func process(_ item: ImportQueueItem) async throws {
        try await queue.update(id: item.id, state: .analyzing)
        // Concrete analysis, transfer, PhotoKit import and verification stages
        // will be connected here. Source files are never transcoded by this manager.
        try await queue.update(id: item.id, state: .completed)
    }
}
