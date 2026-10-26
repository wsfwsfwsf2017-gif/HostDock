import AppKit
import SwiftUI

// shortcut: CLT 27 缺少 SwiftUIMacros，工具链补齐后可恢复 @State 拼写。
typealias ViewState<Value> = SwiftUI.State<Value>

@main
struct HostDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @ViewState private var windowReady = false

    var body: some Scene {
        mainWindow
        Settings { AutomationSettingsView(controller: model.automation) }
    }

    private var mainWindow: some Scene {
        Window("HostDock", id: "main") {
            WorkspaceView(app: model, windowReady: windowReady).frame(minWidth: 1000, minHeight: 620)
                .background(WorkspaceWindow(maximizeRequest: model.maximizeRequest, onReady: { windowReady = true }))
                .task { delegate.model = model; await model.automation.restore() }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: NSScreen.main?.visibleFrame.width ?? 1200, height: NSScreen.main?.visibleFrame.height ?? 800)
        .commands { HostDockCommands(model: model) }
    }
}

private struct HostDockCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject private var editors = RemoteEditors.shared
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建连接…", action: model.showConnections).keyboardShortcut("k", modifiers: .command)
        }
        CommandGroup(replacing: .saveItem) {
            Button("保存") { if let document = editors.focused { Task { await document.save() } } }
                .keyboardShortcut("s", modifiers: .command).disabled(editors.focused == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("查找…") {
                let item = NSMenuItem()
                item.tag = 1
                NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: item)
            }.keyboardShortcut("f", modifiers: .command).disabled(editors.focused == nil)
        }
        CommandMenu("连接") {
            Button("断开当前连接，保留会话") { model.selectedSession?.disconnect() }
                .disabled(model.selectedSession?.connected != true || model.selectedSession?.disconnecting == true)
            Divider()
            Button(model.selectedSession?.showTerminal == true ? "切换到文件传输" : "切换到终端") { model.selectedSession?.toggleTerminal() }
                .keyboardShortcut("t", modifiers: [.command, .shift]).disabled(model.selectedSession?.connected != true)
        }
    }
}

@MainActor
enum WindowPlacement {
    static func screen(containing point: NSPoint, screens: [NSRect]) -> Int? {
        screens.firstIndex { $0.contains(point) }
    }
    static func maximize(_ window: NSWindow, initial: Bool = false) {
        let screens = NSScreen.screens
        let pointerScreen = screen(containing: NSEvent.mouseLocation, screens: screens.map(\.frame)).map { screens[$0] }
        let frameScreen = screen(containing: NSPoint(x: window.frame.midX, y: window.frame.midY), screens: screens.map(\.frame)).map { screens[$0] }
        let screen = initial ? pointerScreen ?? frameScreen ?? NSScreen.main : frameScreen ?? window.screen ?? pointerScreen ?? NSScreen.main
        if let screen { window.setFrame(screen.visibleFrame, display: window.isVisible, animate: false) }
    }
}

struct WorkspaceWindow: NSViewRepresentable {
    let maximizeRequest: Int
    var onReady: () -> Void = {}
    func makeCoordinator() -> Coordinator { let coordinator = Coordinator(); coordinator.onReady = onReady; return coordinator }
    func makeNSView(context: Context) -> NSView {
        let view = WindowReader()
        view.attached = { [weak coordinator = context.coordinator] window in coordinator?.attach(window) }
        view.laidOut = { [weak coordinator = context.coordinator] in coordinator?.didLayout() }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        guard context.coordinator.request != maximizeRequest else { return }
        context.coordinator.request = maximizeRequest
        if let window = view.window { WindowPlacement.maximize(window) }
    }
    final class WindowReader: NSView {
        var attached: (@MainActor (NSWindow) -> Void)?
        var laidOut: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { attached?(window); needsLayout = true }
        }
        override func layout() { super.layout(); if window != nil { laidOut?() } }
    }
    final class Coordinator: NSObject, NSWindowDelegate {
        var request = 0
        var onReady: () -> Void = {}
        private var readyScheduled = false
        private weak var window: NSWindow?
        private var original: (any NSWindowDelegate)?
        @MainActor func attach(_ window: NSWindow) {
            guard self.window !== window else { return }
            self.window = window
            original = window.delegate
            window.delegate = self
            window.animationBehavior = .none
            window.isRestorable = false
            WindowPlacement.maximize(window, initial: true)
        }
        func didLayout() {
            guard window != nil, !readyScheduled else { return }
            readyScheduled = true
            // 布局完成后再呈现弹窗，后台启动也不依赖获得焦点的通知。
            DispatchQueue.main.async { [weak self] in self?.onReady() }
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }
        override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || original?.responds(to: selector) == true }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            if original?.responds(to: selector) == true { return original }
            return super.forwardingTarget(for: selector)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var terminating = false
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !terminating else { return .terminateCancel }
        terminating = true
        Task {
            if model.hasTransfers || RemoteEditors.shared.hasUnuploadedEdits {
                let alert = NSAlert()
                alert.messageText = "仍有传输或未上传的编辑内容"
                alert.informativeText = "退出将保留本机编辑草稿，取消所有会话的传输并清理临时文件，已完成的项目保留。"
                alert.addButton(withTitle: "继续使用")
                alert.addButton(withTitle: "保留草稿并退出")
                guard let window = sender.keyWindow ?? sender.windows.first(where: { $0.isVisible }) else {
                    terminating = false; sender.reply(toApplicationShouldTerminate: false); return
                }
                let response = await withCheckedContinuation { continuation in
                    alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
                }
                guard response == .alertSecondButtonReturn else {
                    terminating = false; sender.reply(toApplicationShouldTerminate: false); return
                }
            }
            do { try RemoteEditors.shared.persistDraftsForQuit() }
            catch {
                terminating = false
                sender.reply(toApplicationShouldTerminate: false)
                let alert = NSAlert()
                alert.messageText = "草稿未能保存，退出已取消"
                alert.informativeText = error.localizedDescription
                if let window = sender.keyWindow { await alert.beginSheetModal(for: window) }
                return
            }
            await model.shutdown()
            RemoteEditors.shared.closeAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
