import Foundation

// A task group waits for an unresponsive child even after cancelAll(). Resume once,
// and close the transport independently so NIO also releases outstanding promises.
private final class FileRequestResult<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?
    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    @discardableResult func finish(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return false }
        self.result = result
        let continuation = self.continuation; self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
        return true
    }
}

public func fileRequestDeadline<T>(seconds: Double, abort: @escaping @Sendable () async -> Void,
                                   operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try Task.checkCancellation()
    let result = FileRequestResult<T>()
    let work = Task { do { try Task.checkCancellation(); result.finish(.success(try await operation())) } catch { result.finish(.failure(error)) } }
    let timer = Task {
        do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
        if result.finish(.failure(FileConnectionFailure.timedOut)) { work.cancel(); await abort() }
    }
    defer { timer.cancel() }
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { result.install($0) }
    } onCancel: {
        if result.finish(.failure(FileConnectionFailure.interrupted)) {
            work.cancel(); timer.cancel(); Task { await abort() }
        }
    }
}
