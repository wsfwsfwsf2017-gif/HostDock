import Combine
import Foundation
import HostDockCore

struct FileJobDeferred: Error { let reason: String }

enum FileJobState: String {
    case queued = "排队", waiting = "等待路径", running = "执行中", confirmation = "待确认"
    case cancelling = "取消中", succeeded = "成功", failed = "失败", cancelled = "已取消", review = "待核对"
    var finished: Bool { self == .succeeded || self == .failed || self == .cancelled || self == .review }
}

struct FileJob: Identifiable {
    let id: UUID
    let label: String
    let submitted = Date()
    var started: Date?
    var ended: Date?
    var state = FileJobState.queued
    var detail = ""
    var progress: Double?
}

/// One FIFO per session. Reservations still coordinate conflicting paths across sessions.
@MainActor
final class FileOperationQueue: ObservableObject {
    @Published private(set) var jobs: [FileJob] = []
    @Published private(set) var paused = false
    private struct Pending {
        let id: UUID
        let operation: @MainActor () async throws -> Void
        let continuation: CheckedContinuation<Void, Error>
    }
    private var pending: [Pending] = []
    private var worker: Task<Void, Never>?
    private(set) var activeID: UUID?
    var changed: (() -> Void)?
    var finished: (() -> Void)?
    var cancellingActive: (() -> Void)?
    var hasWork: Bool { activeID != nil || !pending.isEmpty }
    var running: Bool { activeID != nil }

    func submit(_ label: String, operation: @escaping @MainActor () async throws -> Void) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                jobs.append(FileJob(id: id, label: label))
                pending.append(Pending(id: id, operation: operation, continuation: continuation))
                changed?()
                startNext()
            }
        } onCancel: { Task { @MainActor in self.cancel(id) } }
    }

    func update(_ state: FileJobState? = nil, detail: String? = nil, progress: Double? = nil) {
        guard let id = activeID, let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if let state, jobs[index].state != .cancelling { jobs[index].state = state }
        if let detail { jobs[index].detail = detail }
        if let progress { jobs[index].progress = progress }
    }

    private func startNext() {
        guard worker == nil, !paused, !pending.isEmpty else { changed?(); return }
        let next = pending.removeFirst()
        activeID = next.id
        if let index = jobs.firstIndex(where: { $0.id == next.id }) { jobs[index].started = Date(); jobs[index].state = .running }
        changed?()
        worker = Task {
            var failure: Error?
            do { try Task.checkCancellation(); try await next.operation() }
            catch { failure = error }
            if let deferred = failure as? FileJobDeferred, !Task.isCancelled {
                if let index = jobs.firstIndex(where: { $0.id == next.id }) {
                    jobs[index].state = .queued; jobs[index].detail = deferred.reason; jobs[index].started = nil
                }
                pending.insert(next, at: 0)
                paused = true; worker = nil; activeID = nil
                changed?()
                return
            }
            if failure is FileJobDeferred { failure = CancellationError() }
            if let index = jobs.firstIndex(where: { $0.id == next.id }) {
                if failure is FileConnectionFailure {
                    jobs[index].state = .review
                    jobs[index].detail = "连接中断，操作结果待核对；不会自动重发。"
                    paused = true
                } else if let failure {
                    jobs[index].state = failure is CancellationError ? .cancelled : .failed
                    jobs[index].detail = failure.localizedDescription
                } else { jobs[index].state = .succeeded }
                jobs[index].ended = Date()
            }
            worker = nil; activeID = nil
            trim()
            if let failure { next.continuation.resume(throwing: failure) } else { next.continuation.resume() }
            changed?()
            startNext()
            finished?()
        }
    }

    func cancel(_ id: UUID) {
        if activeID == id { update(.cancelling); worker?.cancel(); cancellingActive?(); return }
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let item = pending.remove(at: index)
        if let row = jobs.firstIndex(where: { $0.id == id }) { jobs[row].state = .cancelled; jobs[row].ended = Date() }
        item.continuation.resume(throwing: CancellationError())
        trim(); changed?()
    }
    func cancelWaiting() { for id in pending.map(\.id) { cancel(id) } }
    func cancelAll() { cancelWaiting(); if let activeID { cancel(activeID) } }
    func drain() async { await worker?.value }
    func resumeWhenSafe() { if !jobs.contains(where: { $0.state == .review }) { paused = false; startNext() } }
    func resumeAfterReview() { for index in jobs.indices where jobs[index].state == .review { jobs[index].state = .failed }; paused = false; startNext() }
    func clearCompleted() { jobs.removeAll { $0.state.finished && $0.state != .review }; changed?() }
    private func trim() {
        let ended = jobs.filter { $0.state.finished }.map(\.id)
        let obsolete = Set(ended.dropLast(50))
        jobs.removeAll { obsolete.contains($0.id) }
    }
}
