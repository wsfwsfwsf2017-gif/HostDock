import AppKit
import HostDockCore
import SwiftUI
import Testing
@testable import HostDock

@MainActor
private func elements(_ root: AnyObject) -> [NSObject] {
    var visited = Set<ObjectIdentifier>()
    func walk(_ item: AnyObject) -> [NSObject] {
        guard visited.insert(ObjectIdentifier(item)).inserted else { return [] }
        var result: [NSObject] = []
        if let object = item as? NSObject {
            result.append(object)
            let selector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [AnyObject] {
                for child in children { result += walk(child) }
            }
        }
        if let view = item as? NSView { for child in view.subviews { result += walk(child) } }
        return result
    }
    return walk(root)
}

@MainActor
private func modeButton(_ title: String, in window: NSWindow) throws -> NSObject {
    try #require(elements(window.contentView!).first { object in
        let label = NSSelectorFromString("accessibilityLabel"), press = NSSelectorFromString("accessibilityPerformPress")
        return object.responds(to: label) && object.responds(to: press)
            && object.perform(label)?.takeUnretainedValue() as? String == title
    })
}

@MainActor
private func press(_ button: NSObject) -> Bool {
    let selector = NSSelectorFromString("accessibilityPerformPress")
    typealias Action = @convention(c) (AnyObject, Selector) -> Bool
    return unsafeBitCast(button.method(for: selector), to: Action.self)(button, selector)
}

@MainActor
private func frame(_ button: NSObject) throws -> NSRect {
    try #require((button.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue)
}

@MainActor
private func interactionWindow(app: AppModel) -> NSWindow {
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1200, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "HostDock 工作区交互检查"
    window.contentView = NSHostingView(rootView: WorkspaceView(app: app))
    return window
}

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["HOSTDOCK_INTERACTION_CHECK"] == "1"))
func workspaceModeButtonsSwitchTheRealSessionOnceAndKeepBothFileTrees() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let transport = FakeSessionConnection(home: fixture.remote(0))
    let app = fixture.app(transports: [transport])
    let session = try app.connect(profile: fixture.profiles[0], password: "synthetic", rememberPassword: false)
    try await waitUntil { session.terminalReady }
    let window = interactionWindow(app: app); defer { window.close() }
    try await checkModeLayouts(app: app, session: session, transport: transport, window: window)
    await app.shutdown()
}

@MainActor
private func checkModeLayouts(app: AppModel, session: SessionModel, transport: FakeSessionConnection, window: NSWindow) async throws {
    for layout in WorkspaceLayout.allCases {
        app.setLayout(layout)
        if layout != .single { app.workspace.expandedSessionID = session.id }
        try await checkModeButtons(session: session, transport: transport, window: window)
        app.workspace.expandedSessionID = nil
    }
    app.setLayout(.single)
}

@MainActor
private func checkModeButtons(session: SessionModel, transport: FakeSessionConnection, window: NSWindow) async throws {
    func layout() async throws {
        try await Task.sleep(for: .milliseconds(100)); window.contentView?.layoutSubtreeIfNeeded()
    }
    try await layout()
    let terminalFrame = try frame(modeButton("终端", in: window))
    let filesFrame = try frame(modeButton("文件传输", in: window))
    await transport.emit("WORKSPACE_MODE_BUFFER\r\n")
    try await waitUntil { String(decoding: session.terminal.view.getBufferAsData(), as: UTF8.self).contains("WORKSPACE_MODE_BUFFER") }
    for _ in 0..<10 {
        guard window.makeFirstResponder(session.terminal.view), press(try modeButton("文件传输", in: window)) else { throw HostDockError("文件传输按钮未响应") }
        try await layout()
        guard session.workspaceMode == .files, window.firstResponder !== session.terminal.view else { throw HostDockError("文件传输布局或焦点未切换") }
        guard try frame(modeButton("终端", in: window)) == terminalFrame,
              try frame(modeButton("文件传输", in: window)) == filesFrame else { throw HostDockError("模式切换按钮发生移位") }
        guard press(try modeButton("终端", in: window)) else { throw HostDockError("终端按钮未响应") }
        try await layout()
        guard session.workspaceMode == .terminal, window.firstResponder === session.terminal.view else { throw HostDockError("终端布局或焦点未切换") }
    }
    guard String(decoding: session.terminal.view.getBufferAsData(), as: UTF8.self).contains("WORKSPACE_MODE_BUFFER"),
          await transport.connects == 1, await transport.inputs.isEmpty else { throw HostDockError("切换改变了终端内容、连接或输入") }
}

@MainActor
@Test func explicitModeSwitchAndMenuToggleKeepTheirSessionAndConnection() async throws {
    let fixture = try SessionFixture(); defer { fixture.clean() }
    let transports = [FakeSessionConnection(home: fixture.remote(0)), FakeSessionConnection(home: fixture.remote(1))]
    let app = fixture.app(transports: transports)
    let first = try app.connect(profile: fixture.profiles[0], password: "synthetic", rememberPassword: false)
    let other = try app.connect(profile: fixture.profiles[1], password: "synthetic", rememberPassword: false)
    try await waitUntil { first.terminalReady && other.terminalReady }
    for _ in 0..<10 {
        first.setWorkspaceMode(.files); first.setWorkspaceMode(.files)
        #expect(first.workspaceMode == .files && other.workspaceMode == .terminal)
        first.toggleTerminal()
        #expect(first.workspaceMode == .terminal && first.terminalReady)
    }
    #expect(await transports[0].connects == 1)
    #expect(await transports[1].connects == 1)
    await app.shutdown()
}

// 测试专用入口：由隔离运行器加载，供坐标点击检查使用，不进入应用包。
@_cdecl("HostDockWorkspaceProbeStart")
func startWorkspaceProbe() {
    Task { @MainActor in
        do {
            let fixture = try SessionFixture(); defer { fixture.clean() }
            let transport = FakeSessionConnection(home: fixture.remote(0))
            var profile = fixture.profiles[0]
            profile.name = "演示服务器"; profile.endpoint = ConnectionEndpoint(host: "192.0.2.10", port: 22, username: "demo")
            let app = fixture.app(transports: [transport], storage: MemoryConnectionStorage(ConnectionDocument(profiles: [profile])))
            let session = try app.connect(profile: profile, password: "synthetic", rememberPassword: false)
            try await waitUntil { session.terminalReady }
            NSApp.setActivationPolicy(.accessory)
            let window = interactionWindow(app: app)
            window.orderBack(nil)
            print("WORKSPACE_PROBE_ROOT", fixture.root.path)
            if ProcessInfo.processInfo.environment["HOSTDOCK_WORKSPACE_CHECK"] == "1" {
                for _ in 0..<600 {
                    if elements(window.contentView!).contains(where: { object in
                        let selector = NSSelectorFromString("accessibilityLabel")
                        return object.responds(to: selector) && object.perform(selector)?.takeUnretainedValue() as? String == "文件传输"
                    }) { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                try await checkModeLayouts(app: app, session: session, transport: transport, window: window)
                print("WORKSPACE_BUTTON_CHECK_PASS")
            }
            for count in 0..<1800 {
                if count % 10 == 0 { await transport.emit("demo output \(count / 10)\r\n") }
                try await Task.sleep(for: .milliseconds(100))
            }
            window.close(); await app.shutdown(); fixture.clean()
            NSApp.terminate(nil)
        } catch {
            print("WORKSPACE_PROBE_FAILED", error.localizedDescription)
            NSApp.terminate(nil)
        }
    }
}
