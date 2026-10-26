import AppKit
import SwiftTerm
import SwiftUI

// 原生终端会消费点击，活动区域需跟随 AppKit 焦点与鼠标事件。
final class SessionTerminalView: TerminalView {
    var onFocus: (() -> Void)?
    var onMount: (() -> Void)?
    private var focused = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self, weak mountedWindow = window, weak responder = window?.firstResponder] in
            // 挂载期间用户已选择其他控件时，不抢回输入焦点。
            guard let self, let mountedWindow, self.window === mountedWindow, mountedWindow.firstResponder === responder else { return }
            self.onMount?()
        }
    }
    override func mouseDown(with event: NSEvent) {
        onFocus?()
        super.mouseDown(with: event)
    }
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onFocus?()
        super.rightMouseDown(with: event)
    }
    override var hasFocus: Bool {
        get { super.hasFocus }
        set {
            let becameFocused = newValue && !focused
            focused = newValue
            super.hasFocus = newValue
            if becameFocused {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.window?.firstResponder === self else { return }
                    self.onFocus?()
                }
            }
        }
    }
}

@MainActor
final class TerminalController: NSObject, TerminalViewDelegate {
    let view = SessionTerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 600), font: .monospacedSystemFont(ofSize: 12, weight: .regular))
    var columns = 100
    var rows = 16
    var ready = false
    var onInput: ((Data) -> Void)?
    var onResize: ((Int, Int) -> Void)?
    private var darkAppearance: Bool?

    override init() {
        super.init()
        view.terminalDelegate = self
        view.nativeForegroundColor = DockTheme.textNS
        view.nativeBackgroundColor = DockTheme.surfaceNS
        view.setAccessibilityLabel("SSH 交互终端")
    }

    func feed(_ data: Data) { view.feed(byteArray: Array(data)[...]) }
    func message(_ text: String) { feed(Data(("\r\n" + text + "\r\n").utf8)) }
    func reset() { view.feed(byteArray: [0x1b, 0x63][...]) }

    func applyAppearance(dark: Bool) {
        guard darkAppearance != dark else { return }
        darkAppearance = dark
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            view.nativeForegroundColor = DockTheme.textNS.usingColorSpace(.sRGB) ?? DockTheme.textNS
            view.nativeBackgroundColor = DockTheme.surfaceNS.usingColorSpace(.sRGB) ?? DockTheme.surfaceNS
        }
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if ready { onInput?(Data(data)) }
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        columns = newCols
        rows = newRows
        if ready { onResize?(newCols, newRows) }
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
}

// SwiftUI 拥有每次挂载的容器；会话终端可安全移入新容器，不被旧分支清理移除。
private final class TerminalMount: NSView {
    private var terminal: TerminalView?
    func bind(_ terminal: TerminalView) {
        guard self.terminal !== terminal else { return }
        if self.terminal?.superview === self { self.terminal?.removeFromSuperview() }
        self.terminal = terminal
        if window != nil { attach() }
    }
    private func attach() {
        guard let terminal else { return }
        guard terminal.superview !== self else { return }
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = true
        terminal.autoresizingMask = [.width, .height]
        terminal.frame = bounds
        addSubview(terminal)
        terminal.needsDisplay = true
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { attach() }
    }
}

private struct TerminalSurface: NSViewRepresentable {
    let controller: TerminalController
    @Environment(\.colorScheme) private var colorScheme
    func makeNSView(context: Context) -> TerminalMount {
        let mount = TerminalMount()
        mount.bind(controller.view)
        return mount
    }
    func updateNSView(_ mount: TerminalMount, context: Context) {
        mount.bind(controller.view)
        controller.applyAppearance(dark: colorScheme == .dark)
    }
}

struct TerminalPane: View {
    @ObservedObject var app: SessionModel
    var showHeader = true
    var body: some View {
        VStack(spacing: 0) {
            if showHeader || !app.terminalRunning {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                Text("终端").fontWeight(.medium)
                Text(app.terminalReady ? app.remoteLabel : app.terminalRunning ? "正在打开终端…" : app.connected ? "会话已结束" : "未连接")
                    .foregroundStyle(DockTheme.secondary).lineLimit(1)
                Spacer()
                if app.connected && !app.terminalRunning {
                    Button("打开终端", action: app.startTerminal)
                }
            }.buttonStyle(DockButtonStyle()).font(.system(size: 12)).padding(.horizontal, 14).frame(height: 48)
                .background(DockTheme.surface)
            Divider()
            }
            TerminalSurface(controller: app.terminal).padding(.horizontal, 8).padding(.top, 5)
        }.background(DockTheme.surface)
    }
}
