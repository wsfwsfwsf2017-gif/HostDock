import AppKit
import Foundation
import HostDockCore
import SwiftUI
import Testing
@testable import HostDock

@Test func serverSubtitlesMatchWholeAddressesWithoutChangingStoredIdentity() throws {
    let cases = [
        ("192.0.2.1", "公司服务器 · 192.0.2.1", true),
        ("192.0.2.1", "服务器 192.0.2.10", false),
        ("192.0.2.1", "服务器 192.0.2.1:2222", true),
        ("node.example", "开发 NODE.EXAMPLE", true),
        ("node.example", "开发 other-node.example", false),
        ("node.example", "开发 node.example.org", false),
        ("2001:db8::1", "服务器 [2001:DB8::1]", true),
        ("2001:db8::1", "服务器 2001:db8::1:22", false),
        ("192.0.2.1", "很长的服务器名称，不包含地址", false)
    ]
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    for (host, name, included) in cases {
        let profile = ConnectionProfile(name: name, endpoint: ConnectionEndpoint(host: host, port: 22, username: "tester"))
        let original = try encoder.encode(profile); let account = profile.credentialAccount
        #expect(profile.displaySubtitle == (included ? "tester" : host + " · tester"))
        #expect(profile.displayAddress == host + " · tester")
        #expect(try encoder.encode(profile) == original && profile.credentialAccount == account)
    }
    let jump = ConnectionProfile(name: "公司服务器 · 192.0.2.123", endpoint: ConnectionEndpoint(host: "gateway.example", port: 2222, username: "张三@ssta@192.0.2.123"),
        connectionMode: .jumpServer, jumpServer: JumpServerConfiguration(username: "张三", targetUsername: "ssta", targetHost: "192.0.2.123"))
    #expect(jump.displaySubtitle == "ssta" && jump.endpoint.host == "gateway.example")
}

@Test func simplifiedAccessAddressKeepsIndependentGatewayPortAndCredentials() throws {
    var access = JumpServerAccessProfile()
    access.host = "ssh.example"; access.port = 2207; access.username = "张三"
    access.portalURL = "https://portal.example:8443/login"; access.privateKeyPath = "~/.ssh/example_rsa"
    access.lastValidatedAt = Date(); access.keyRequiresPassphrase = true
    let changed = try access.updatingAddress("https://new-portal.example:9443/auth/login")
    #expect(changed.host == access.host && changed.port == 2207)
    #expect(changed.id == access.id && changed.privateKeyPath == access.privateKeyPath)
    #expect(changed.credentialAccount == access.credentialAccount && changed.lastValidatedAt == access.lastValidatedAt)
    #expect(changed.keyRequiresPassphrase && changed.portalURL == "https://new-portal.example:9443/auth/login")
    access.host = "portal.example"
    let moved = try access.updatingAddress("https://next.example:9443/auth/login")
    #expect(moved.host == "next.example" && moved.port == 2207)
    let fresh = try JumpServerAccessProfile().updatingAddress("http://gateway.example:8080/core/auth/login/")
    #expect(fresh.host == "gateway.example" && fresh.port == 2222)
    #expect(throws: (any Error).self) { try access.updatingAddress("https://user:password@portal.example") }
}

@MainActor
@Test func connectionFormsInitiallyShowBothDefaultDirectories() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    var profile = fixture.profiles[0]; profile.lastValidatedAt = Date()
    let catalog = ConnectionCatalog(storage: MemoryConnectionStorage(ConnectionDocument(profiles: [profile])))
    try catalog.recordSuccess(profile: profile)
    let credentials = MemoryCredentialStore(); try await credentials.save("synthetic", account: profile.credentialAccount)
    let app = AppModel(catalog: catalog, credentials: credentials)
    await app.refreshSavedConnections()
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    for tab in [ConnectionPickerTab.new, .saved, .recent] {
        if tab == .new { app.useDraft(profile) } else { app.selectPickerTab(tab) }
        let hosting = NSHostingView(rootView: ConnectionPickerView(app: app))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        try await Task.sleep(for: .milliseconds(100)); hosting.layoutSubtreeIfNeeded()
        let values = descendants(hosting).compactMap { ($0 as? NSTextField)?.stringValue }
        #expect(values.contains(profile.localStartDirectory!))
        #expect(values.contains(profile.remoteStartDirectory!))
        window.close()
    }
    #expect(catalog.profiles[0].localStartDirectory == profile.localStartDirectory)
    #expect(catalog.profiles[0].remoteStartDirectory == profile.remoteStartDirectory)
    await app.shutdown()
}

@MainActor
@Test func remoteContextMenuKeepsBothDownloadFlowsAfterToolbarRemoval() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let data = Data("context-download-中文".utf8)
    let source = fixture.remote(0) + "/download-check.txt"
    try data.write(to: URL(fileURLWithPath: source))
    let app = fixture.app(transports: [FakeSessionConnection(home: fixture.remote(0))])
    let session = try app.connect(profile: fixture.profiles[0], password: "synthetic", rememberPassword: false)
    try await waitUntil { session.connected && !session.connecting }
    let entry = try #require(session.remote.roots.first { $0.entry.path == source }?.entry)
    let actions = FileActions(session: session, remote: true)
    session.workspaceMode = .terminal
    #expect(actions.menu(entries: [entry], directory: session.remote.path, window: nil).items.contains { $0.title == "下载…" && $0.isEnabled })
    #expect(actions.menu(entries: [], directory: session.remote.path, window: nil).items.contains { $0.title == "下载…" && !$0.isEnabled })
    let destination = fixture.root.appendingPathComponent("downloads")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    await session.local.navigate(to: destination.path)
    session.workspaceMode = .files
    let menu = actions.menu(entries: [entry], directory: session.remote.path, window: nil)
    let index = try #require(menu.items.firstIndex { $0.title == "下载到本机当前目录" && $0.isEnabled })
    menu.performActionForItem(at: index)
    let downloaded = destination.appendingPathComponent("download-check.txt")
    try await waitUntil { FileManager.default.fileExists(atPath: downloaded.path) && !session.transferring }
    #expect(try Data(contentsOf: downloaded) == data)
    await app.shutdown()
}
