import Foundation

public actor ImportManager {
    public enum ManagerError: Error, LocalizedError {
        case noPendingItems
        public var errorDescription: String? {
            switch self { case .noPendingItems: return "No pending import items." }
        }
    }

    private let queue: ImportQueueStore
    private var isRunning = false

    public init(queue: ImportQueueStore) {
        self.queue = queue
    }

    public func start() async throws {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        while let item = try await queue.nextPendingItem() {
            try await process(item)
        }
    }

    public func cancel() {
        isRunning = false
    }

    private func process(_ item: ImportQueueItem) async throws {
        // The manager deliberately does not alter or transcode source media.
        // Concrete transport/PhotoKit stages will be injected in the next layer.
        try await queue.update(id: item.id, status: .analyzing, error: nil)
        try await queue.update(id: item.id, status: .ready, error: nil)
    }
}
