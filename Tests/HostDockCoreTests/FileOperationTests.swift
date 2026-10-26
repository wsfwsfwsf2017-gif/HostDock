import Foundation
import Testing
@testable import HostDockCore

@Test func atomicEditingChecksHashKeepsModeAndRetainsBackup() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hostdock-edit-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalFileStore()
    let file = root.appendingPathComponent("中文.txt")
    try Data("before\r\n".utf8).write(to: file)
    try await store.setPermissions(0o640, at: file.path)
    let baseline = try await FileOperations.digest(at: file.path, in: store)
    try await TransferEngine().replaceContents(Data("after\r\n".utf8), at: file.path, in: store, expectedDigest: baseline)
    #expect(try Data(contentsOf: file) == Data("after\r\n".utf8))
    #expect(try await store.metadata(at: file.path)?.permissions == 0o640)
    let backup = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".hostdock-backup-") })
    #expect(try Data(contentsOf: backup) == Data("before\r\n".utf8))
    await #expect(throws: FileChangedError.self) {
        try await TransferEngine().replaceContents(Data("stale".utf8), at: file.path, in: store, expectedDigest: baseline)
    }
    #expect(try Data(contentsOf: file) == Data("after\r\n".utf8))
    #expect(try !FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".part") })
}

@Test func recursiveRemovalDeletesLinksWithoutFollowingThem() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hostdock-remove-\(UUID())")
    let folder = root.appendingPathComponent("delete")
    let protected = root.appendingPathComponent("keep.txt")
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("empty"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("protected".utf8).write(to: protected)
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link"), withDestinationURL: root)
    let store = LocalFileStore()
    let entry = try #require(await store.metadata(at: folder.path))
    try await FileOperations.remove([entry], in: store)
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    #expect(try String(contentsOf: protected, encoding: .utf8) == "protected")
    await #expect(throws: HostDockError.self) { try await FileOperations.remove([FileEntry(path: "/", kind: .directory)], in: store) }
}

@Test func rsaPEMAndEncryptedOpenSSHUseExistingImporterWithoutPersistingSecrets() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hostdock-rsa-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    func generate(_ name: String, format: String, phrase: String) throws -> String {
        let path = root.appendingPathComponent(name).path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-q", "-t", "rsa", "-b", "2048", "-m", format, "-N", phrase, "-f", path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return path
    }
    let pem = try generate("pem", format: "PEM", phrase: "")
    #expect(try !RSAKeyInfo.inspect(path: pem).requiresPassphrase)
    _ = try SSHAuthentication.rsaKey(path: pem, passphrase: nil).method(username: "姓名@ssta@192.0.2.1")
    let encrypted = try generate("encrypted", format: "RFC4716", phrase: "synthetic-key-phrase")
    #expect(try RSAKeyInfo.inspect(path: encrypted).requiresPassphrase)
    let before = try Data(contentsOf: URL(fileURLWithPath: encrypted))
    #expect(throws: SSHConnectionFailure.self) { try SSHAuthentication.rsaKey(path: encrypted, passphrase: nil).method(username: "test") }
    _ = try SSHAuthentication.rsaKey(path: encrypted, passphrase: "synthetic-key-phrase").method(username: "test")
    #expect(throws: SSHConnectionFailure.keyPassphrase) { try SSHAuthentication.rsaKey(path: encrypted, passphrase: "synthetic-wrong").method(username: "test") }
    #expect(try Data(contentsOf: URL(fileURLWithPath: encrypted)) == before)
    #expect(throws: SSHConnectionFailure.keyFormat) { try RSAKeyInfo.inspect(path: pem + ".pub") }
    #expect(throws: SSHConnectionFailure.self) { try SSHAuthentication.rsaKey(path: root.appendingPathComponent("missing").path, passphrase: nil).method(username: "test") }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 4)
    let damaged = root.appendingPathComponent("damaged")
    for value in ["-----BEGIN OPENSSH PRIVATE KEY-----\ngarbage\n-----END OPENSSH PRIVATE KEY-----", "-----BEGIN ENCRYPTED PRIVATE KEY-----\ngarbage\n-----END ENCRYPTED PRIVATE KEY-----"] {
        try Data(value.utf8).write(to: damaged)
        #expect(throws: SSHConnectionFailure.keyFormat) { try RSAKeyInfo.inspect(path: damaged.path) }
        #expect(throws: SSHConnectionFailure.keyFormat) { try SSHAuthentication.rsaKey(path: damaged.path, passphrase: nil).method(username: "test") }
    }
}
