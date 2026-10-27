import Foundation
import HostDockCore
import Testing
@testable import HostDock

private let assetPath = "/192.0.2.10"

private actor JumpDirectoryStore: FileStore {
    let directories: [String: [FileEntry]]
    let deniedPath: String?
    private var pausePath: String?
    private var pending: CheckedContinuation<Void, Never>?
    private(set) var paused = false
    private(set) var listed: [String] = []

    init(root: [FileEntry] = [FileEntry(path: assetPath, kind: .directory)],
         deniedPath: String? = nil, pausePath: String? = nil) {
        directories = ["/": root,
                       assetPath: [FileEntry(path: assetPath + "/home", kind: .directory), FileEntry(path: assetPath + "/tmp", kind: .directory)],
                       assetPath + "/home": [FileEntry(path: assetPath + "/home/readme.txt", kind: .file)],
                       "/denied": []]
        self.deniedPath = deniedPath; self.pausePath = pausePath
    }

    func canonicalDirectory(at path: String) throws -> String {
        let normalized = try FilePath.normalize(path)
        guard directories[normalized] != nil else { throw HostDockError("测试目录不存在。") }
        return normalized
    }
    func list(at path: String) async throws -> [FileEntry] {
        listed.append(path)
        if pausePath == path {
            pausePath = nil; paused = true
            // 模拟 SFTP 已发出的请求在取消后仍返回响应。
            await withCheckedContinuation { pending = $0 }
        }
        guard path != deniedPath else { throw HostDockError("测试目录无访问权限。") }
        return directories[path] ?? []
    }
    func releaseListing() { pending?.resume(); pending = nil }
    func metadata(at path: String) -> FileEntry? {
        if path == "/" { return FileEntry(path: path, kind: .directory) }
        return directories[FilePath.parent(path)]?.first { $0.path == path }
    }
    func createDirectory(at path: String) throws { throw HostDockError("只读测试目录。") }
    func move(from: String, to: String) throws { throw HostDockError("只读测试目录。") }
    func removeFile(at path: String) throws { throw HostDockError("只读测试目录。") }
    func openReader(at path: String) throws -> any FileReader { throw HostDockError("只读目录替身不提供文件内容。") }
    func createWriter(at path: String) throws -> any FileWriter { throw HostDockError("只读测试目录。") }
}

@MainActor
private func jumpDirectoryProfile(_ fixture: SessionFixture, start: String? = nil, direct: Bool = false) -> ConnectionProfile {
    var profile = fixture.profiles[0]
    profile.remoteStartDirectory = start
    profile.endpoint = ConnectionEndpoint(host: direct ? "192.0.2.10" : "gateway.example", port: direct ? 22 : 2222, username: "demo")
    profile.connectionMode = direct ? .direct : .jumpServer
    profile.jumpServer = direct ? nil : JumpServerConfiguration(username: "测试用户", targetUsername: "demo", targetHost: "192.0.2.10")
    return profile
}

@Suite(.serialized)
@MainActor
struct JumpServerDirectoryTests {
    @Test(arguments: ["", "/", "~", "/./"])
    func entersAssetOnConnectAndReconnectButManualRootStaysAccessible(start: String) async throws {
        let fixture = try SessionFixture(); defer { fixture.clean() }
        let profile = jumpDirectoryProfile(fixture, start: start.isEmpty ? nil : start)
        let store = JumpDirectoryStore()
        let transport = FakeSessionConnection(home: "/", store: store)
        let app = fixture.app(transports: [transport], storage: MemoryConnectionStorage(ConnectionDocument(profiles: [profile])))
        let session = try app.connect(profile: profile, password: "synthetic-only", rememberPassword: true)
        try await waitUntil { session.terminalReady && !session.connecting }
        #expect(session.remote.path == assetPath && session.remote.pathDraft == assetPath)
        #expect(session.remote.directoryReady && session.remote.home == "/")
        #expect(Set(session.remote.roots.map { $0.entry.path }) == [assetPath + "/home", assetPath + "/tmp"])
        session.remote.selection = [assetPath + "/home"]
        #expect(session.remote.selectedEntries.map(\.path) == [assetPath + "/home"])
        session.workspaceMode = .files
        #expect(session.remote.path == assetPath)
        await session.remote.navigate(to: FilePath.parent(session.remote.path))
        #expect(session.remote.path == "/" && session.remote.roots.first?.entry.path == assetPath)
        await session.remote.refresh()
        #expect(session.remote.path == "/")
        await session.shutdown()
        app.reconnect(session)
        try await waitUntil { session.terminalReady && !session.connecting }
        #expect(session.remote.path == assetPath && app.sessions.count == 1)
        #expect(app.catalog.profiles.first?.remoteStartDirectory == profile.remoteStartDirectory)
        #expect(await transport.connects == 2)
        #expect(await transport.usernames.allSatisfy { $0 == "测试用户@demo@192.0.2.10" })
        await app.shutdown()
    }

    @Test(arguments: ["multiple", "missing", "prefix", "symlink", "file", "direct", "mapped-home"])
    func onlyEntersTheExactDirectoryOfTheSelectedJumpAsset(scenario: String) async throws {
        let fixture = try SessionFixture(); defer { fixture.clean() }
        let profile = jumpDirectoryProfile(fixture, direct: scenario == "direct")
        let root: [FileEntry]
        switch scenario {
        case "multiple": root = [FileEntry(path: "/192.0.2.11", kind: .directory), FileEntry(path: assetPath, kind: .directory)]
        case "missing": root = [FileEntry(path: "/192.0.2.11", kind: .directory)]
        case "prefix": root = [FileEntry(path: "/192.0.2.100", kind: .directory)]
        case "symlink": root = [FileEntry(path: assetPath, kind: .symbolicLink)]
        case "file": root = [FileEntry(path: assetPath, kind: .file)]
        default: root = [FileEntry(path: assetPath, kind: .directory)]
        }
        let store = JumpDirectoryStore(root: root)
        let home = scenario == "mapped-home" ? assetPath + "/home" : "/"
        let app = fixture.app(transports: [FakeSessionConnection(home: home, store: store)])
        let session = try app.connect(profile: profile, password: "synthetic-only", rememberPassword: false)
        try await waitUntil { session.terminalReady && !session.connecting }
        let expected = scenario == "multiple" ? assetPath : home
        #expect(session.remote.path == expected && session.remote.directoryReady)
        #expect(await store.listed == (scenario == "multiple" ? ["/", assetPath] : [home]))
        await app.shutdown()
    }

    @Test(arguments: ["/192.0.2.10/home", "/missing", "/denied"])
    func explicitDirectoriesKeepTheirContentsAndErrors(start: String) async throws {
        let fixture = try SessionFixture(); defer { fixture.clean() }
        let profile = jumpDirectoryProfile(fixture, start: start)
        let store = JumpDirectoryStore(deniedPath: "/denied")
        let app = fixture.app(transports: [FakeSessionConnection(home: "/", store: store)])
        let session = try app.connect(profile: profile, password: "synthetic-only", rememberPassword: false)
        try await waitUntil { session.terminalReady && !session.connecting }
        if start == assetPath + "/home" {
            #expect(session.remote.path == start && session.remote.directoryReady)
            #expect(session.remote.roots.first?.entry.path == start + "/readme.txt")
        } else {
            #expect(session.remote.path.isEmpty && session.remote.error != nil && !session.remote.directoryReady)
        }
        #expect(await !store.listed.contains("/"))
        await app.shutdown()
    }

    @Test func inaccessibleAssetKeepsSSHButDisablesTransfers() async throws {
        let fixture = try SessionFixture(); defer { fixture.clean() }
        let store = JumpDirectoryStore(deniedPath: assetPath)
        let app = fixture.app(transports: [FakeSessionConnection(home: "/", store: store)])
        let session = try app.connect(profile: jumpDirectoryProfile(fixture), password: "synthetic-only", rememberPassword: false)
        try await waitUntil { session.terminalReady && !session.connecting }
        #expect(session.connected && session.connectionError == nil)
        #expect(session.remote.path.isEmpty && session.remote.pathDraft == assetPath)
        #expect(session.remote.error?.contains("无访问权限") == true && !session.remote.directoryReady)
        session.local.selection = [try #require(session.local.roots.first?.entry.path)]
        session.transfer(upload: true)
        #expect(!session.transferring)
        await session.remote.navigate(to: session.remote.home)
        #expect(session.remote.directoryReady && session.remote.path == "/")
        await app.shutdown()
    }

    @Test func cancelledAssetReadCannotReplaceAReconnectedDirectory() async throws {
        let fixture = try SessionFixture(); defer { fixture.clean() }
        let store = JumpDirectoryStore(pausePath: assetPath)
        let transport = FakeSessionConnection(home: "/", store: store)
        let app = fixture.app(transports: [transport])
        let profile = jumpDirectoryProfile(fixture)
        let session = try app.connect(profile: profile, password: "synthetic-only", rememberPassword: false)
        do {
            for _ in 0..<200 {
                if await store.paused { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(await store.paused)
            session.cancelConnection()
            try await waitUntil { !session.busy }
            var updated = profile; updated.remoteStartDirectory = assetPath + "/home"
            #expect(try app.connect(profile: updated, password: "synthetic-only", rememberPassword: false, reusing: session) === session)
            try await waitUntil { session.terminalReady && !session.connecting }
            await store.releaseListing()
            try await Task.sleep(for: .milliseconds(50))
            #expect(session.remote.path == assetPath + "/home" && session.remote.error == nil)
            #expect(session.remote.roots.map { $0.entry.path } == [assetPath + "/home/readme.txt"])
            #expect(session.connected && app.sessions.count == 1)
            await app.shutdown()
        } catch {
            await store.releaseListing(); await app.shutdown(); throw error
        }
    }
}
