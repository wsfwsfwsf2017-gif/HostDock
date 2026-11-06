import Foundation
import HostDockCore

/// Captured queued operations keep the same endpoint, while a repaired channel can replace its transport.
actor SessionFileStore: FileStore {
    private var store: any FileStore
    private var available = true
    private var generation = UUID()
    let failed: @Sendable (Error) async -> Void
    init(_ store: any FileStore, failed: @escaping @Sendable (Error) async -> Void) { self.store = store; self.failed = failed }
    func replace(_ store: any FileStore) { self.store = store; available = true; generation = UUID() }
    private func call<T>(_ operation: (any FileStore) async throws -> T) async throws -> T {
        guard available else { throw FileConnectionFailure.closed }
        let token = generation
        do { return try await operation(store) }
        catch {
            if error is FileConnectionFailure && generation == token { available = false; await failed(error) }
            throw error
        }
    }
    func canonicalDirectory(at path: String) async throws -> String { try await call { try await $0.canonicalDirectory(at: path) } }
    func list(at path: String) async throws -> [FileEntry] { try await call { try await $0.list(at: path) } }
    func metadata(at path: String) async throws -> FileEntry? { try await call { try await $0.metadata(at: path) } }
    func createDirectory(at path: String) async throws { try await call { try await $0.createDirectory(at: path) } }
    func move(from: String, to: String) async throws { try await call { try await $0.move(from: from, to: to) } }
    func removeFile(at path: String) async throws { try await call { try await $0.removeFile(at: path) } }
    func removeEmptyDirectory(at path: String) async throws { try await call { try await $0.removeEmptyDirectory(at: path) } }
    func setPermissions(_ permissions: UInt32, at path: String) async throws { try await call { try await $0.setPermissions(permissions, at: path) } }
    func openReader(at path: String) async throws -> any FileReader { try await call { try await $0.openReader(at: path) } }
    func createWriter(at path: String) async throws -> any FileWriter { try await call { try await $0.createWriter(at: path) } }
}
