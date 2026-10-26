import Foundation
import Testing
@testable import HostDockCore

@Test func pathsCannotEscapeOrChangeNames() throws {
    #expect(try FilePath.normalize("/a/../b//./") == "/b")
    #expect(try FilePath.join("/.", name: "中文 ' $; .txt") == "/中文 ' $; .txt")
    for name in ["", ".", "..", "../etc", "a/b", "a\0b"] {
        #expect(throws: HostDockError.self) { try FilePath.join("/safe", name: name) }
    }
    #expect(!FilePath.isInside("/safe-other/file", directory: "/safe"))
    #expect(throws: HostDockError.self) { try FilePath.normalize("relative") }
    let folder = FileEntry(path: "/a", kind: .directory)
    let child = FileEntry(path: "/a/file", kind: .file)
    let other = FileEntry(path: "/ab", kind: .file)
    #expect(Set(FilePath.topLevelSelection([child, folder, folder, other])) == Set([folder, other]))
}

private struct Fixture {
    let root: URL
    let source: URL
    let destination: URL
    let store = LocalFileStore()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hostdock-unit-\(UUID().uuidString)")
        source = root.appendingPathComponent("source")
        destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func write(_ data: Data, to path: URL) throws { try data.write(to: path) }
}

private actor Events {
    var skipped = 0
    var completed = 0
    func record(_ event: TransferEvent) {
        if case .skipped = event { skipped += 1 }
        if case .completed = event { completed += 1 }
    }
}

@Test func copiesNestedEmptyAndUnicodeFoldersWithoutFollowingLinks() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let folder = fixture.source.appendingPathComponent("中文 空格")
    let empty = folder.appendingPathComponent("空目录")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    let bytes = Data((0..<180_000).map { UInt8($0 % 251) })
    try fixture.write(bytes, to: folder.appendingPathComponent("file '$;.bin"))
    try fixture.write(Data(), to: folder.appendingPathComponent(".empty"))
    try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("cycle").path, withDestinationPath: folder.path)
    let events = Events()
    try await TransferEngine().transfer(try await fixture.store.list(at: fixture.source.path),
        from: fixture.store, to: fixture.store, directory: fixture.destination.path,
        onEvent: { await events.record($0) })
    let target = fixture.destination.appendingPathComponent("中文 空格")
    #expect(try Data(contentsOf: target.appendingPathComponent("file '$;.bin")) == bytes)
    #expect(try await fixture.store.metadata(at: target.appendingPathComponent("空目录").path)?.kind == .directory)
    #expect(try await fixture.store.metadata(at: target.appendingPathComponent(".empty").path)?.size == 0)
    #expect(try await fixture.store.metadata(at: target.appendingPathComponent("cycle").path) == nil)
    #expect(await events.skipped == 1)
}

@Test func defaultsToSkippingAndCanOverwriteSafely() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let file = fixture.source.appendingPathComponent("file")
    let target = fixture.destination.appendingPathComponent("file")
    try fixture.write(Data("new".utf8), to: file)
    try fixture.write(Data("original".utf8), to: target)
    let entries = try await fixture.store.list(at: fixture.source.path)
    try await TransferEngine().transfer(entries, from: fixture.store, to: fixture.store, directory: fixture.destination.path)
    #expect(try String(contentsOf: target, encoding: .utf8) == "original")
    try await TransferEngine().transfer(entries, from: fixture.store, to: fixture.store,
        directory: fixture.destination.path, onConflict: { _ in .overwrite })
    #expect(try String(contentsOf: target, encoding: .utf8) == "new")
    #expect(try await fixture.store.list(at: fixture.destination.path).count == 1)
}

@Test func fileDirectoryConflictsAndDestinationLinksArePreserved() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = fixture.source.appendingPathComponent("folder")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    try fixture.write(Data("payload".utf8), to: source.appendingPathComponent("child"))
    let outside = fixture.root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    let target = fixture.destination.appendingPathComponent("folder")
    try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: outside.path)
    let events = Events()
    try await TransferEngine().transfer(try await fixture.store.list(at: fixture.source.path),
        from: fixture.store, to: fixture.store, directory: fixture.destination.path,
        onConflict: { _ in .overwrite }, onEvent: { await events.record($0) })
    #expect(try await fixture.store.list(at: outside.path).isEmpty)
    #expect(try await fixture.store.metadata(at: target.path)?.kind == .symbolicLink)
    #expect(await events.skipped == 1)
}

@Test func cancellationRemovesPartialFileAndPreservesOriginal() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.write(Data(repeating: 7, count: 250_000), to: fixture.source.appendingPathComponent("file"))
    let target = fixture.destination.appendingPathComponent("file")
    try fixture.write(Data("original".utf8), to: target)
    let entries = try await fixture.store.list(at: fixture.source.path)
    let transfer = Task {
        try await TransferEngine().transfer(entries, from: fixture.store, to: fixture.store,
            directory: fixture.destination.path, onConflict: { _ in .overwrite }, onEvent: { event in
                if case .progress(_, let bytes, _) = event, bytes > 0 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            })
    }
    await #expect(throws: CancellationError.self) { try await transfer.value }
    #expect(try String(contentsOf: target, encoding: .utf8) == "original")
    #expect(try await fixture.store.list(at: fixture.destination.path).count == 1)
}

private actor FailingCommitStore: FileStore {
    let base: LocalFileStore
    var shouldFailCommit = true
    let denyRestore: Bool
    init(base: LocalFileStore, denyRestore: Bool = false) { self.base = base; self.denyRestore = denyRestore }
    func canonicalDirectory(at path: String) async throws -> String { try await base.canonicalDirectory(at: path) }
    func list(at path: String) async throws -> [FileEntry] { try await base.list(at: path) }
    func metadata(at path: String) async throws -> FileEntry? { try await base.metadata(at: path) }
    func createDirectory(at path: String) async throws { try await base.createDirectory(at: path) }
    func move(from: String, to: String) async throws {
        if from.hasSuffix(".part"), shouldFailCommit {
            shouldFailCommit = false
            throw HostDockError("injected commit failure")
        }
        if denyRestore, from.contains(".hostdock-backup-") { throw HostDockError("injected restore failure") }
        try await base.move(from: from, to: to)
    }
    func removeFile(at path: String) async throws { try await base.removeFile(at: path) }
    func openReader(at path: String) async throws -> any FileReader { try await base.openReader(at: path) }
    func createWriter(at path: String) async throws -> any FileWriter { try await base.createWriter(at: path) }
}

@Test(arguments: [false, true]) func failedCommitRestoresOrPreservesRecoverableBackup(denyRestore: Bool) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    try fixture.write(Data("new".utf8), to: fixture.source.appendingPathComponent("file"))
    let target = fixture.destination.appendingPathComponent("file")
    try fixture.write(Data("original".utf8), to: target)
    let entries = try await fixture.store.list(at: fixture.source.path)
    await #expect(throws: HostDockError.self) {
        try await TransferEngine().transfer(entries, from: fixture.store,
            to: FailingCommitStore(base: fixture.store, denyRestore: denyRestore), directory: fixture.destination.path,
            onConflict: { _ in .overwrite })
    }
    let remaining = try await fixture.store.list(at: fixture.destination.path)
    #expect(remaining.count == 1)
    if denyRestore {
        #expect(remaining.first?.name.hasPrefix(".hostdock-backup-") == true)
        #expect(try String(contentsOfFile: #require(remaining.first?.path), encoding: .utf8) == "original")
    } else { #expect(try String(contentsOf: target, encoding: .utf8) == "original") }
}

@Test func localWriterAndRenameNeverClobberExistingFiles() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let source = fixture.source.appendingPathComponent("file")
    let target = fixture.destination.appendingPathComponent("file")
    try fixture.write(Data("source".utf8), to: source)
    try fixture.write(Data("target".utf8), to: target)
    await #expect(throws: (any Error).self) { _ = try await fixture.store.createWriter(at: target.path) }
    await #expect(throws: (any Error).self) { try await fixture.store.move(from: source.path, to: target.path) }
    #expect(try String(contentsOf: target, encoding: .utf8) == "target")
    #expect(try String(contentsOf: source, encoding: .utf8) == "source")
}
