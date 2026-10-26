import AppKit
import SwiftTerm
import SwiftUI

@MainActor
final class TerminalController: NSObject, TerminalViewDelegate {
    let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 900, height: 600), font: .monospacedSystemFont(ofSize: 12, weight: .regular))
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

private struct TerminalSurface: NSViewRepresentable {
    let controller: TerminalController
    @Environment(\.colorScheme) private var colorScheme
    func makeNSView(context: Context) -> TerminalView { controller.view }
    func updateNSView(_ view: TerminalView, context: Context) { controller.applyAppearance(dark: colorScheme == .dark) }
}

struct TerminalPane: View {
    @ObservedObject var app: SessionModel
    var body: some View {
        VStack(spacing: 0) {
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
            TerminalSurface(controller: app.terminal).padding(.horizontal, 8).padding(.top, 5)
        }.background(DockTheme.surface)
    }
}
