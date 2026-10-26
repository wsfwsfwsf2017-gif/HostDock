import AppKit
import Foundation
import HostDockCore
import SwiftUI
import Testing
@testable import HostDock

private func v7JumpProfile() -> ConnectionProfile {
    ConnectionProfile(name: "开发服务器", endpoint: ConnectionEndpoint(host: "gateway.example", port: 2222, username: ""),
        authenticationKind: .rsaKey, privateKeyPath: "~/.ssh/example", connectionMode: .jumpServer,
        jumpServer: JumpServerConfiguration(username: "张三", targetUsername: "deploy", targetHost: "192.0.2.123"))
}
private func v7Socket() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("hda-" + UUID().uuidString.prefix(8)).appendingPathComponent("agent.sock")
}

@Test func jumpPortalDoesNotBecomeSSHPortAndKeepsCredentialIdentity() throws {
    var profile = try v7JumpProfile().validated()
    let originalAccount = profile.credentialAccount
    var draft = ConnectionFormDraft(profile)
    draft.gatewayAddress = "http://gateway.example:8080/core/auth/login/"
    let resolved = try draft.validated()
    #expect(resolved.endpoint == profile.endpoint && resolved.credentialAccount == originalAccount)
    #expect(resolved.jumpServer?.portalURL == draft.gatewayAddress)
    #expect(resolved.endpoint.port == 2222)
    #expect(resolved.displayAddress == "192.0.2.123 · deploy")
    #expect(try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(resolved)) == resolved)
    draft.gatewayOverride = "ssh-gateway.example"
    #expect(try draft.validated().endpoint.host == "ssh-gateway.example")
    #expect(try draft.validated().credentialAccount != originalAccount)
    for address in ["file:///tmp/key", "https://user:password@example.org", "http://", "server/path", "host:8080"] {
        #expect(throws: (any Error).self) { try JumpServerAddress(address) }
    }
    profile.jumpServer?.portalURL = "file:///tmp/private"
    #expect(throws: (any Error).self) { try profile.validated() }
    var fresh = ConnectionFormDraft(sampleProfile()); var secret = "synthetic"
    fresh.changeMode(to: .jumpServer, secret: &secret)
    #expect(fresh.jumpServer.targetUsername == "ssta" && secret.isEmpty)
}

@Test func permissionDescriptionsAreReadOnlyAndChangesKeepSpecialBits() {
    #expect(FilePermissions.summary(0o644) == "所有者可读写，其他人只读")
    #expect(FilePermissions.summary(0o700).contains("其他用户：无权限"))
    #expect(FilePermissions.summary(nil).contains("未提供"))
    #expect(FilePermissions.changing(0o7644, bit: 0o100, enabled: true) == 0o7744)
    #expect(FilePermissions.changing(0o7744, bit: 0o100, enabled: false) == 0o7644)
}

@MainActor
@Test func versionThreeUpgradeKeepsAllIdentityFieldsAndBacksUpExactBytes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hdv7-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("connections.json")
    let profile = try v7JumpProfile().validated()
    var document = ConnectionDocument(profiles: [profile]); document.version = 3
    let original = try JSONEncoder().encode(document); try original.write(to: url)
    let catalog = ConnectionCatalog(storage: FileConnectionStorage(url: url))
    var enriched = profile; enriched.jumpServer?.portalURL = "https://gateway.example/core/auth/login/"
    try catalog.save(enriched)
    let backup = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("connections-v3-") })
    #expect(try Data(contentsOf: backup) == original)
    #expect(catalog.document.version == 5 && catalog.profiles.first?.credentialAccount == profile.credentialAccount)
    #expect(catalog.profiles.first?.id == profile.id)
}

@MainActor
@Test func terminalStartsAutomaticallyAndWorkspaceModesKeepSessionState() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let transport = FakeSessionConnection(home: fixture.remote(0))
    let app = fixture.app(transports: [transport])
    let session = try app.connect(profile: fixture.profiles[0], password: "synthetic", rememberPassword: false)
    try await waitUntil { session.terminalReady }
    #expect(session.workspaceMode == .terminal && session.terminalFraction == 0.7)
    let entry = try #require(session.remote.roots.first).entry.path
    session.remote.selection = [entry]; session.local.scrollOrigin = NSPoint(x: 0, y: 100)
    session.workspaceMode = .files
    await transport.emit("background-console-output\r\n")
    try await Task.sleep(for: .milliseconds(20))
    session.workspaceMode = .terminal
    #expect(session.remote.selection == [entry] && session.local.scrollOrigin.y == 100)
    #expect(session.terminalRunning && String(decoding: session.terminal.view.getBufferAsData(), as: UTF8.self).contains("background-console-output"))
    #expect(BrowserModel.localShortcuts.map(\.name) == ["主目录", "桌面", "下载", "文稿"])
    await app.shutdown()
}

@MainActor
@Test func automationPreferenceRestoresOnlyAfterExplicitEnable() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let app = fixture.app(transports: [])
    let suite = "HostDock-v7-test-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
    let socket = v7Socket(); defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
    let first = AutomationController(app: app, defaults: defaults, socketURL: socket)
    await first.restore()
    #expect(!first.enabled && !FileManager.default.fileExists(atPath: socket.path))
    await first.setEnabled(true)
    #expect(first.enabled)
    await first.shutdown()
    let second = AutomationController(app: app, defaults: defaults, socketURL: socket)
    await second.restore()
    #expect(second.enabled)
    await second.setEnabled(false)
    #expect(!defaults.bool(forKey: "HostDock.AutomationEnabled"))
    await app.shutdown()
}

@MainActor
@Test func automationDoesNotAcceptFingerprintsAndDisablingCancelsPendingConnections() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    var profile = try fixture.profiles[0].validated(); profile.lastValidatedAt = Date()
    let store = MemoryConnectionStorage(ConnectionDocument(profiles: [profile]))
    let credentials = MemoryCredentialStore()
    try await credentials.save("synthetic-credential", account: profile.credentialAccount)
    let transport = FakeSessionConnection(home: fixture.remote(0), requiresTrust: true)
    let app = AppModel(catalog: ConnectionCatalog(storage: store), credentials: credentials, makeConnection: { transport })
    let suite = "HostDock-v7-test-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
    let socket = v7Socket(); defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
    let controller = AutomationController(app: app, defaults: defaults, socketURL: socket)
    await controller.setEnabled(true)
    let response = await controller.handle(ControlRequest(command: "connect", arguments: ["profile": profile.id.uuidString]))
    #expect(!response.ok && response.error?.code == "NEEDS_USER_ACTION")
    #expect(app.backgroundSessions.first?.hostTrustRequest != nil && app.backgroundSessions.first?.connected == false)
    #expect(!app.connectionPickerPresented && app.sessions.isEmpty && app.catalog.profiles == [profile])
    await controller.setEnabled(false)
    #expect(app.backgroundSessions.isEmpty)
    #expect(try await credentials.read(account: profile.credentialAccount) == "synthetic-credential")
    await app.shutdown()
}

@MainActor
@Test func switchingWorkspaceAndServersRestoresNativeFileScrollPosition() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    for index in 0..<150 {
        try Data().write(to: URL(fileURLWithPath: fixture.remote(0)).appendingPathComponent(String(format: "%03d.txt", index)))
    }
    let app = fixture.app(transports: [FakeSessionConnection(home: fixture.remote(0)), FakeSessionConnection(home: fixture.remote(1))])
    let a = try app.connect(profile: fixture.profiles[0], password: "synthetic", rememberPassword: false)
    let b = try app.connect(profile: fixture.profiles[1], password: "synthetic", rememberPassword: false)
    try await waitUntil { a.connected && b.connected && !a.connecting && !b.connecting }
    app.connectionPickerPresented = false; app.selectedSessionID = a.id
    let hosting = NSHostingView(rootView: WorkspaceView(app: app))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = hosting
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    func remoteScroll() -> NSScrollView? {
        descendants(hosting).compactMap { $0 as? NSScrollView }.first {
            guard let outline = $0.documentView as? NSOutlineView, let node = outline.item(atRow: 0) as? FileNode else { return false }
            return node.entry.path.hasPrefix(fixture.remote(0) + "/")
        }
    }
    try await Task.sleep(for: .milliseconds(120)); hosting.layoutSubtreeIfNeeded()
    let first = try #require(remoteScroll())
    first.contentView.scroll(to: NSPoint(x: 0, y: 500)); first.reflectScrolledClipView(first.contentView)
    #expect(first.contentView.bounds.origin.y >= 490)
    a.workspaceMode = .files
    try await Task.sleep(for: .milliseconds(80)); hosting.layoutSubtreeIfNeeded()
    #expect(remoteScroll() === first && first.contentView.bounds.origin.y >= 490)
    app.selectedSessionID = b.id
    try await Task.sleep(for: .milliseconds(100)); hosting.layoutSubtreeIfNeeded()
    app.selectedSessionID = a.id
    try await Task.sleep(for: .milliseconds(120)); hosting.layoutSubtreeIfNeeded()
    let restored = try #require(remoteScroll())
    #expect(restored.contentView.bounds.origin.y >= 490)
    window.close(); await app.shutdown()
}

@MainActor
@Test func checkingWhetherFolderCanExpandDoesNotLoadOrExpandIt() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let folder = URL(fileURLWithPath: fixture.remote(0)).appendingPathComponent("child")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("child".utf8).write(to: folder.appendingPathComponent("inside.txt"))
    let model = BrowserModel(); await model.attach(store: LocalFileStore(), home: fixture.remote(0))
    let hosting = NSHostingView(rootView: FileBrowserPane(model: model, remote: true, subtitle: "test"))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = hosting
    defer { window.close() }
    try await Task.sleep(for: .milliseconds(100)); hosting.layoutSubtreeIfNeeded()
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let outline = try #require(descendants(hosting).first { $0 is NSOutlineView } as? NSOutlineView)
    let node = try #require(model.roots.first { $0.entry.kind == .directory })
    #expect(outline.delegate?.outlineView?(outline, shouldExpandItem: node) == true)
    try await Task.sleep(for: .milliseconds(30))
    #expect(node.children == nil && !node.loading && model.expandedPaths.isEmpty)
    outline.expandItem(node)
    try await waitUntil { node.children != nil }
    #expect(model.expandedPaths.contains(node.entry.path) && node.children?.first?.entry.name == "inside.txt")
    outline.collapseItem(node)
    #expect(!model.expandedPaths.contains(node.entry.path))
}
