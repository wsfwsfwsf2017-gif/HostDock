import Foundation
import HostDockCore

struct TransferDestination: Hashable, Sendable {
    let storage: String
    let path: String
    init(storage: String, path: String) throws {
        self.storage = storage
        // 保守合并大小写及 Unicode 等价路径，避免同一目标被并行覆盖。
        self.path = try FilePath.normalize(path).precomposedStringWithCanonicalMapping.lowercased()
    }
    func overlaps(_ other: Self) -> Bool {
        storage == other.storage && (FilePath.isInside(path, directory: other.path) || FilePath.isInside(other.path, directory: path))
    }
}

actor TransferReservations {
    private struct Waiter {
        let id: UUID
        let paths: [TransferDestination]
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var active: [UUID: [TransferDestination]] = [:]
    private var waiters: [Waiter] = []
    var activeCount: Int { active.count }
    var waitingCount: Int { waiters.count }

    func acquire(_ paths: [TransferDestination], id: UUID) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                waiters.append(Waiter(id: id, paths: paths, continuation: continuation))
                drain()
            }
        } onCancel: { Task { await self.cancel(id) } }
    }

    func release(_ id: UUID) { active.removeValue(forKey: id); drain() }

    private func cancel(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            waiters.remove(at: index).continuation.resume(throwing: CancellationError())
            drain()
        }
    }

    private func drain() {
        let pending = waiters
        waiters = []
        var earlier: [TransferDestination] = []
        for waiter in pending {
            let occupied = active.values.flatMap { $0 } + earlier
            if waiter.paths.contains(where: { path in occupied.contains { path.overlaps($0) } }) {
                waiters.append(waiter)
                earlier += waiter.paths
            } else {
                active[waiter.id] = waiter.paths
                waiter.continuation.resume()
            }
        }
    }
}
