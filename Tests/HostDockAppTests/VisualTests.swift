import AppKit
import Foundation
import HostDockCore
import SwiftUI
import Testing
@testable import HostDock

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["HOSTDOCK_RENDER_CHECK"] == "1"))
func renderReadOnlyAutomationRecordsInBothAppearances() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let app = fixture.app(transports: [])
    let history = app.automationRecords; await history.restore()
    let record = history.begin(profile: ConnectionProfile(name: "演示服务器", endpoint: ConnectionEndpoint(host: "192.0.2.10", port: 22, username: "demo")), sessionID: UUID())
    history.emit(record, kind: .request, title: "exec", detail: "printf 'HostDock\\n'")
    history.emit(record, kind: .result, title: "完成", result: .object(["stdout": .string("HostDock\n"), "stderr": .string(""), "exitCode": .number(0)]))
    history.emit(record, kind: .terminal, data: Data("demo@host:~$ pwd\r\n/home/demo\r\n".utf8))
    history.protect(host: record.header.host, sessionIDs: [record.header.sessionID!])
    history.end(sessionID: record.header.sessionID!, reason: "用户结束并保护 5 分钟")
    app.showRecord(record)
    try await waitUntil { record.loaded && !record.loading }
    for dark in [false, true] {
        try await renderView(WorkspaceView(app: app), name: "build26-ai-record-\(dark ? "dark" : "light")", dark: dark, size: NSSize(width: 1220, height: 760))
        try await renderView(AutomationBackgroundView(app: app, controller: app.automation), name: "build26-ai-background-\(dark ? "dark" : "light")", dark: dark, size: NSSize(width: 500, height: 400))
        try await renderView(TerminalSurface(controller: record.terminal()), name: "build26-ai-terminal-\(dark ? "dark" : "light")", dark: dark, size: NSSize(width: 800, height: 500))
    }
    await app.closeAllTabs(); try await history.flush(); await app.shutdown()
}

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["HOSTDOCK_RENDER_CHECK"] == "1"))
func renderAutomationSettingsInBothAppearances() async throws {
    let fixture = try SessionFixture()
    defer { fixture.clean() }
    let diagnostics = DiagnosticLog(directory: fixture.root.appendingPathComponent("diagnostics"))
    let app = fixture.app(transports: [], diagnostics: diagnostics)
    for dark in [false, true] {
        try await renderView(AppSettingsView(app: app), name: "build28-settings-\(dark ? "dark" : "light")", dark: dark, size: NSSize(width: 560, height: 620))
    }
    await app.shutdown()
}

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["HOSTDOCK_RENDER_CHECK"] == "1"))
func renderWorkspaceInBothAppearances() async throws {
    let fixture = try SessionFixture()
    defer { fixture.clean() }
    let keyPath = fixture.root.appendingPathComponent("visual-rsa").path
    let keygen = Process(); keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    keygen.arguments = ["-q", "-t", "rsa", "-b", "2048", "-m", "PEM", "-N", "", "-f", keyPath]
    keygen.standardOutput = FileHandle.nullDevice; keygen.standardError = FileHandle.nullDevice
    try keygen.run(); keygen.waitUntilExit(); #expect(keygen.terminationStatus == 0)
    let first = FakeSessionConnection(home: fixture.remote(0))
    let second = FakeSessionConnection(home: fixture.remote(1))
    let app = fixture.app(transports: [first, second])
    app.connectionPickerPresented = false
    let a = try app.connect(profile: fixture.profiles[0], password: "synthetic", rememberPassword: true)
    let b = try app.connect(profile: fixture.profiles[1], password: "synthetic", rememberPassword: true)
    try await waitUntil { a.connected && b.connected && !a.connecting && !b.connecting }
    await app.refreshSavedConnections()
    let editPath = fixture.remote(0) + "/payload.txt"
    let document = try RemoteDocument(session: a, path: editPath,
        contents: Data(contentsOf: URL(fileURLWithPath: editPath)), drafts: EditDraftStore(directory: fixture.root.appendingPathComponent("drafts")))
    document.text = "# HostDock\nmode = development\n\n中文配置编辑\n"
    var access = JumpServerAccessProfile(); access.name = "团队堡垒机"; access.host = "gateway.example"; access.username = "张三"
    access.privateKeyPath = keyPath; access.portalURL = "https://jump.example.com/core/auth/login/"; access.lastValidatedAt = Date()
    try app.catalog.saveAccessProfile(access)
    for dark in [false, true] {
        app.selectPickerTab(.saved)
        try await renderView(ConnectionPickerView(app: app), name: "v08-picker-saved-\(dark ? "dark" : "light")", dark: dark, size: NSSize(width: 920, height: 700))
        try await renderView(RemoteEditorView(document: document), name: "v08-editor-\(dark ? "dark" : "light")", dark: dark, size: NSSize(width: 900, height: 650))
        app.selectPickerTab(.new)
        try await renderView(ConnectionPickerView(app: app), name: "v08-picker-new-\(dark ? "dark" : "light")", dark: dark, size: NSSize(width: 920, height: 700))
        let jump = try access.applying(to: ConnectionProfile(name: "JumpServer 开发环境", endpoint: ConnectionEndpoint(host: "gateway.example", port: 2222, username: ""),
            authenticationKind: .rsaKey, privateKeyPath: keyPath, connectionMode: .jumpServer,
            jumpServer: JumpServerConfiguration(username: "张三", targetUsername: "ssta", targetHost: "192.0.2.10", accessProfileID: access.id)))
        app.useDraft(jump)
        try await renderView(ConnectionPickerView(app: app), name: "v08-picker-jump-key-\(dark ? "dark" : "light")", dark: dark, size: NSSize(width: 920, height: 700))
        try await renderView(JumpServerHelpView(), name: "v08-jump-help-\(dark ? "dark" : "light")", dark: dark, size: NSSize(width: 450, height: 580))
        try await renderView(JumpServerAccessEditor(app: app, access: access, asset: jump, saved: { _, _ in }, cancel: {}), name: "v08-access-editor-\(dark ? "dark" : "light")", dark: dark, size: NSSize(width: 620, height: 620))
        app.useDraft(ConnectionProfile(name: "", endpoint: ConnectionEndpoint(host: "", port: 22, username: "")))
    }
    a.showTerminal = true; b.showTerminal = true
    try await waitUntil { a.terminalReady && b.terminalReady }
    await second.emit("developer@dev:~$ echo HostDock\r\nHostDock\r\n")
    b.remote.selection = Set(b.remote.roots.prefix(1).map { $0.entry.path })
    for dark in [false, true] {
        try await renderView(WorkspaceView(app: app), name: "v08-workspace-\(dark ? "dark" : "light")", dark: dark, size: NSSize(width: 1440, height: 900))
        b.workspaceMode = .files
        try await renderView(WorkspaceView(app: app), name: "v08-workspace-files-\(dark ? "dark" : "light")", dark: dark, size: NSSize(width: 1440, height: 900), emphasizedSelection: true)
        let labels = ConnectionProfile(name: "开发环境 · 192.0.2.123", endpoint: ConnectionEndpoint(host: "192.0.2.123", port: 22, username: "tester"))
        try await renderView(FileBrowserPane(model: b.remote, remote: true, subtitle: labels.displaySubtitle, serverName: labels.name, session: b),
            name: "build14-file-header-\(dark ? "dark" : "light")", dark: dark, size: NSSize(width: 500, height: 600))
        try await renderView(FileBrowserPane(model: b.remote, remote: true, subtitle: labels.displaySubtitle, serverName: "用于检查省略、快捷入口与边缘留白的很长服务器名称 · 192.0.2.123", session: b),
            name: "build14-file-header-compact-\(dark ? "dark" : "light")", dark: dark, size: NSSize(width: 320, height: 600))
        b.workspaceMode = .terminal
        try await renderView(FilePropertiesView(entry: FileEntry(path: "/home/demo/example.txt", kind: .file, size: 1234, modified: Date(), permissions: 0o644, owner: 1000, group: 1000)), name: "v08-properties-\(dark ? "dark" : "light")", dark: dark, size: NSSize(width: 500, height: 360))
        app.selectPickerTab(.recent)
        try await renderView(ConnectionPickerView(app: app), name: "v08-picker-recent-\(dark ? "dark" : "light")", dark: dark, size: NSSize(width: 920, height: 700))
    }
    try await renderView(WorkspaceView(app: app), name: "v08-workspace-compact", dark: false, size: NSSize(width: 1000, height: 620))
    await a.shutdown(); await b.shutdown()
    app.selectPickerTab(.saved)
    for dark in [false, true] {
        try await renderView(ConnectionPickerView(app: app), name: "v08-picker-saved-\(dark ? "dark" : "light")", dark: dark, size: NSSize(width: 920, height: 700))
    }
    await app.shutdown()
}

@MainActor
@Test func nativeFileTreesAndTerminalBindingsFollowSelectedSession() async throws {
    let fixture = try SessionFixture()
    defer { fixture.clean() }
    let app = fixture.app(transports: [FakeSessionConnection(home: fixture.remote(0)), FakeSessionConnection(home: fixture.remote(1))])
    let a = try app.connect(profile: fixture.profiles[0], password: "synthetic", rememberPassword: false)
    let b = try app.connect(profile: fixture.profiles[1], password: "synthetic", rememberPassword: false)
    try await waitUntil { a.connected && b.connected && !a.connecting && !b.connecting }
    a.toggleTerminal(); b.toggleTerminal()
    try await waitUntil { a.terminalReady && b.terminalReady }
    a.local.selection = [try #require(a.local.roots.first).entry.path]
    app.connectionPickerPresented = false
    let hosting = NSHostingView(rootView: WorkspaceView(app: app))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hosting
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    for selected in [a, b, a] {
        app.selectTab(selected.id)
        try await Task.sleep(for: .milliseconds(120))
        hosting.layoutSubtreeIfNeeded()
        let views = descendants(hosting)
        let outlines = views.compactMap { $0 as? NSOutlineView }
        #expect(outlines.count == 2)
        let entries = outlines.compactMap { ($0.item(atRow: 0) as? FileNode)?.entry.path }
        #expect(Set(entries) == Set([selected.local.roots.first?.entry.path, selected.remote.roots.first?.entry.path].compactMap { $0 }))
        #expect(views.contains { $0 === selected.terminal.view })
        #expect(!views.contains { $0 === (selected === a ? b : a).terminal.view })
        if selected === a { #expect(outlines.contains { !$0.selectedRowIndexes.isEmpty }) }
    }
    window.close()
    #expect(a.connected && b.connected && a.terminalRunning && b.terminalRunning)
    await app.shutdown()
}

@MainActor
private func renderView<V: View>(_ view: V, name: String, dark: Bool, size: NSSize, emphasizedSelection: Bool = false) async throws {
    let originalIcon = NSApp.applicationIconImage
    let iconURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("packaging/Icon/HostDock.png")
    NSApp.applicationIconImage = try #require(NSImage(contentsOf: iconURL))
    defer { NSApp.applicationIconImage = originalIcon }
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOSTDOCK_RENDER_DIR"] ?? FileManager.default.currentDirectoryPath + "/.build/visuals")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let hosting = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
    window.contentView = hosting
    hosting.setFrameSize(size)
    hosting.layoutSubtreeIfNeeded()
    if emphasizedSelection {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for outline in descendants(hosting).compactMap({ $0 as? NSOutlineView }) {
            for row in outline.selectedRowIndexes { outline.rowView(atRow: row, makeIfNecessary: true)?.isEmphasized = true }
        }
    }
    try await Task.sleep(for: .milliseconds(350))
    hosting.layoutSubtreeIfNeeded()
    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    window.appearance?.performAsCurrentDrawingAppearance {
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    }
    // cacheDisplay 不包含终端的 CALayer 背景，将透明区域合成到同色面板。
    let composed = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide,
        pixelsHigh: bitmap.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let context = try #require(NSGraphicsContext(bitmapImageRep: composed)?.cgContext)
    let rectangle = CGRect(x: 0, y: 0, width: composed.pixelsWide, height: composed.pixelsHigh)
    window.appearance?.performAsCurrentDrawingAppearance {
        context.setFillColor(DockTheme.surfaceNS.cgColor)
        context.fill(rectangle)
    }
    context.setBlendMode(.normal)
    context.draw(try #require(bitmap.cgImage), in: rectangle)
    #expect(composed.colorAt(x: composed.pixelsWide / 2, y: composed.pixelsHigh - 90)?.alphaComponent == 1)
    let png = try #require(composed.representation(using: .png, properties: [:]))
    try png.write(to: directory.appendingPathComponent(name + ".png"))
    #expect(png.count > 10_000)
    window.close()
}

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["HOSTDOCK_RENDER_CHECK"] == "1"))
func renderTabbedSplitWorkspaceAndBackgroundPanel() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let connections = (0..<6).map { _ in FakeSessionConnection(home: fixture.remote(0)) }
        + [FakeSessionConnection(home: fixture.remote(0), requiresTrust: true)]
    let app = fixture.app(transports: connections, storage: MemoryConnectionStorage())
    for index in 0..<6 {
        var profile = index == 5 ? app.sessions[0].profile : fixture.profiles[0]
        if index != 5 {
            profile.id = UUID(); profile.endpoint.host = "192.0.2.\(index + 10)"
            profile.name = index == 0 ? "开发环境" : index == 4 ? "用于检查标签省略和提示的长服务器别称" : "应用服务器 \(index + 1)"
        }
        _ = try app.connect(profile: profile, password: "synthetic-only", rememberPassword: true)
    }
    try await waitUntil { app.sessions.allSatisfy(\.terminalReady) }
    await app.refreshSavedConnections()
    for index in 0..<6 { await connections[index].emit("tester@demo-\(index + 1):~$ pwd\r\n/home/tester\r\ntester@demo-\(index + 1):~$ ") }
    for dark in [false, true] {
        app.setLayout(.single)
        try await renderView(WorkspaceView(app: app), name: "build19-single-\(dark ? "dark" : "light")", dark: dark, size: NSSize(width: 1440, height: 900))
        app.setLayout(.dual)
        try await renderView(WorkspaceView(app: app), name: "build19-dual-\(dark ? "dark" : "light")", dark: dark, size: NSSize(width: 1440, height: 900))
        app.setLayout(.quad)
        try await renderView(WorkspaceView(app: app), name: "build19-quad-\(dark ? "dark" : "light")", dark: dark, size: NSSize(width: 1440, height: 900))
        try await renderView(WorkspaceView(app: app), name: "build19-quad-compact-\(dark ? "dark" : "light")", dark: dark, size: NSSize(width: 1000, height: 620))
        app.workspace.expandedSessionID = app.selectedSessionID
        try await renderView(WorkspaceView(app: app), name: "build19-expanded-\(dark ? "dark" : "light")", dark: dark, size: NSSize(width: 1440, height: 900))
        app.workspace.expandedSessionID = nil
        app.showConnections()
        try await renderView(ConnectionPickerView(app: app), name: "build19-new-\(dark ? "dark" : "light")", dark: dark, size: NSSize(width: 780, height: 670))
        app.connectionPickerPresented = false
    }
    let suite = "HostDock-visual19-" + UUID().uuidString
    let preferences = try #require(UserDefaults(suiteName: suite))
    let socket = FileManager.default.temporaryDirectory.appendingPathComponent("hdv-" + UUID().uuidString.prefix(8)).appendingPathComponent("control.sock")
    defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
    let controller = AutomationController(app: app, defaults: preferences, socketURL: socket)
    await controller.setEnabled(true)
    #expect(controller.enabled)
    let background = try app.connectBackground(profile: app.sessions[0].profile)
    try await waitUntil { background.hostTrustRequest != nil }
    for dark in [false, true] {
        try await renderView(AutomationBackgroundView(app: app, controller: controller), name: "build19-background-\(dark ? "dark" : "light")", dark: dark, size: NSSize(width: 460, height: 500))
        try await renderView(AutomationSettingsView(controller: controller), name: "build19-settings-\(dark ? "dark" : "light")", dark: dark, size: NSSize(width: 560, height: 190))
    }
    await controller.setEnabled(false); await app.shutdown()
}
