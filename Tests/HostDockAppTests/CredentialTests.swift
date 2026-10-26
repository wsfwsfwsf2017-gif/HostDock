import Foundation
import Testing
@testable import HostDock

@Test func encryptedCredentialsPersistUpdateAndDeleteWithoutPlaintext() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hostdock-credentials-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EncryptedFileCredentialStore(directory: root)
    let secret = "synthetic-本机密码-\(UUID())"
    #expect(try await store.read(account: "one") == nil)
    #expect(!FileManager.default.fileExists(atPath: root.path))
    try await store.save(secret, account: "one")
    try await store.save(secret, account: "two")
    let restarted = EncryptedFileCredentialStore(directory: root)
    #expect(try await restarted.read(account: "one") == secret)
    #expect(try await restarted.read(account: "different-identity") == nil)
    let data = try Data(contentsOf: root.appendingPathComponent("credentials.json"))
    #expect(data.range(of: Data(secret.utf8)) == nil)
    #expect(try Data(contentsOf: root.appendingPathComponent("credentials.key")).count == 32)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let items = try #require(json["items"] as? [String: String])
    #expect(items["one"] != items["two"])
    for (url, permission) in [(root, 0o700), (root.appendingPathComponent("credentials.json"), 0o600), (root.appendingPathComponent("credentials.key"), 0o600)] {
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == permission)
    }
    try await restarted.save("synthetic-updated", account: "one")
    #expect(try await EncryptedFileCredentialStore(directory: root).read(account: "one") == "synthetic-updated")
    #expect(try await store.read(account: "two") == secret)
    try await restarted.remove(account: "one")
    try await restarted.remove(account: "one")
    #expect(try await store.read(account: "one") == nil)
    #expect(try await store.read(account: "two") == secret)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["credentials.json", "credentials.key"])
}

@Test func concurrentCredentialWritesKeepEveryAccount() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hostdock-credentials-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EncryptedFileCredentialStore(directory: root)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<20 { group.addTask { try await store.save("synthetic-\(index)", account: "account-\(index)") } }
        try await group.waitForAll()
    }
    let restarted = EncryptedFileCredentialStore(directory: root)
    for index in 0..<20 { #expect(try await restarted.read(account: "account-\(index)") == "synthetic-\(index)") }
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
}

@Test(arguments: ["missing-key", "invalid-key", "corrupt-cipher", "wrong-account", "future-version", "invalid-json"])
func damagedCredentialsAreNeverReplacedOrRegenerated(scenario: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hostdock-credentials-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = EncryptedFileCredentialStore(directory: root)
    try await store.save("synthetic-only", account: "original")
    let documentURL = root.appendingPathComponent("credentials.json"), keyURL = root.appendingPathComponent("credentials.key")
    switch scenario {
    case "missing-key": try FileManager.default.removeItem(at: keyURL)
    case "invalid-key": try Data([1, 2, 3]).write(to: keyURL)
    case "invalid-json": try Data("broken".utf8).write(to: documentURL)
    default:
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: documentURL)) as? [String: Any])
        var items = try #require(json["items"] as? [String: String])
        if scenario == "future-version" { json["version"] = 99 }
        else if scenario == "wrong-account" { items["other"] = items.removeValue(forKey: "original"); json["items"] = items }
        else { items["original"] = Data(repeating: 0, count: 40).base64EncodedString(); json["items"] = items }
        try JSONSerialization.data(withJSONObject: json).write(to: documentURL)
    }
    let original = try Data(contentsOf: documentURL)
    let key = try? Data(contentsOf: keyURL)
    let restarted = EncryptedFileCredentialStore(directory: root)
    await #expect(throws: (any Error).self) { try await restarted.read(account: "original") }
    await #expect(throws: (any Error).self) { try await restarted.save("synthetic-new", account: "original") }
    await #expect(throws: (any Error).self) { try await restarted.remove(account: "original") }
    #expect(try Data(contentsOf: documentURL) == original)
    #expect((try? Data(contentsOf: keyURL)) == key)
}

@Test func credentialsRecoverAfterWriteFailureWithoutLeavingTemporaryFiles() async throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent("hostdock-credentials-\(UUID())")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    let root = parent.appendingPathComponent("private")
    let store = EncryptedFileCredentialStore(directory: root)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path); try? FileManager.default.removeItem(at: parent) }
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
    await #expect(throws: (any Error).self) { try await store.save("synthetic-only", account: "one") }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("credentials.json").path))
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
    try await store.save("synthetic-only", account: "one")
    #expect(try await EncryptedFileCredentialStore(directory: root).read(account: "one") == "synthetic-only")
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["credentials.json", "credentials.key"])
}
