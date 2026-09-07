import Foundation

/// Shared across map views/windows: only one allocation-heavy build may run.
@MainActor
final class TreemapBuildCoordinator {
    static let shared = TreemapBuildCoordinator()
    private static let defaultOwner = UUID()
    private var latest: [UUID: UUID] = [:]
    private var workerOwner: UUID?
    private var workerID: UUID?
    private var worker: Task<TreemapScene, Error>?

    func build(owner: UUID, tree: ScanTree, nodes: [NodeID], bounds: CGRect, scale: CGFloat,
               onProgress: @escaping @Sendable (TreemapScene.BuildProgress) -> Void) async throws -> TreemapScene {
        try await run(owner: owner) {
            try TreemapScene.build(tree: tree, nodes: nodes, in: bounds, displayScale: scale, onProgress: onProgress)
        }
    }

    func run(owner: UUID? = nil, _ operation: @escaping @Sendable () throws -> TreemapScene) async throws -> TreemapScene {
        let owner = owner ?? Self.defaultOwner
        let request = UUID()
        latest[owner] = request
        defer { if latest[owner] == request { latest[owner] = nil } }
        // Supersede this view's work; other windows wait their turn without
        // cancelling each other's only scene request.
        if workerOwner == owner { worker?.cancel() }
        while let previous = worker {
            let previousID = workerID
            _ = await previous.result
            if workerID == previousID { worker = nil }
            try Task.checkCancellation()
            guard latest[owner] == request else { throw CancellationError() }
        }
        try Task.checkCancellation()
        guard latest[owner] == request else { throw CancellationError() }
        let next = Task.detached(priority: .userInitiated) { try operation() }
        worker = next
        workerOwner = owner
        workerID = request
        defer { if workerID == request { worker = nil; workerOwner = nil; workerID = nil } }
        return try await withTaskCancellationHandler {
            try await next.value
        } onCancel: {
            next.cancel()
        }
    }
}
