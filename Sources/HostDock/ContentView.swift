import AppKit
import HostDockCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var app: SessionModel
    var showConnections: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Circle().fill(app.connected ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.profile.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(app.profile.displayAddress).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DockTheme.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }.help(app.profile.displayAddress)
                Spacer()
                DockTabs(options: WorkspaceMode.allCases.map { ($0, $0.rawValue) }, selection: $app.workspaceMode)
                    .frame(width: 190).accessibilityLabel("工作区模式")
                TransferButtons(app: app, terminalMode: app.workspaceMode == .terminal)
                if app.connected {
                    Button("断开", action: app.disconnect).help("断开连接，保留侧栏会话以便重连").disabled(app.disconnecting)
                }
            }.buttonStyle(DockButtonStyle()).padding(.horizontal, 20).frame(height: 66).background(DockTheme.surface)
            Rectangle().fill(DockTheme.border).frame(height: 1)
            if let notice = app.credentialNotice { DockNotice(text: notice).padding([.top, .horizontal], 12) }
            if let conflict = app.conflictRequest {
                FileConflictCard(app: app, conflict: conflict).padding([.top, .horizontal], 12)
            }
            WorkspacePanes(app: app, showConnections: showConnections).padding(12)
            if app.transferring || app.logs.contains(where: { $0.warning }) {
                Rectangle().fill(DockTheme.border).frame(height: 1)
                TransferStatus(app: app)
            }
        }
        .background(DockTheme.background).foregroundStyle(DockTheme.text).tint(DockTheme.accent)
    }
}

private struct WorkspacePanes: View {
    @ObservedObject var app: SessionModel
    let showConnections: () -> Void
    @ViewState private var dragStart: Double?
    private var files: Bool { app.workspaceMode == .files }
    var body: some View {
        GeometryReader { geometry in
            let available = max(1, geometry.size.width - 7)
            let fraction = files ? app.fileFraction : app.terminalFraction
            let width = min(max(available * fraction, files ? 300 : 360), max(360, available - 300))
            HStack(spacing: 0) {
                ZStack {
                    TerminalPane(app: app).opacity(files ? 0 : 1).allowsHitTesting(!files).accessibilityHidden(files)
                    FileBrowserPane(model: app.local, remote: false, subtitle: "macOS", session: app)
                        .opacity(files ? 1 : 0).allowsHitTesting(files).accessibilityHidden(!files)
                }.frame(width: width)
                Rectangle().fill(DockTheme.border).frame(width: 1).frame(width: 7).contentShape(Rectangle())
                    .modifier(DockHoverCursor(cursor: .resizeLeftRight))
                    .help("拖动调整终端和文件列表宽度")
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        if dragStart == nil { dragStart = width / available }
                        let next = min(0.85, max(0.15, (dragStart ?? fraction) + value.translation.width / available))
                        if files { app.fileFraction = next } else { app.terminalFraction = next }
                    }.onEnded { _ in dragStart = nil })
                FileBrowserPane(model: app.remote, remote: true, subtitle: app.profile.displayAddress, serverName: app.profile.name,
                                connect: showConnections, session: app).frame(maxWidth: .infinity)
            }
        }.clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DockTheme.border))
            .onChange(of: app.workspaceMode) { _, mode in
                if mode == .terminal {
                    app.startTerminal()
                    app.terminal.view.window?.makeFirstResponder(app.terminal.view)
                } else { app.terminal.view.window?.makeFirstResponder(nil) }
            }
    }
}

private struct TransferButtons: View {
    @ObservedObject var app: SessionModel
    @ObservedObject private var local: BrowserModel
    @ObservedObject private var remote: BrowserModel
    let terminalMode: Bool
    init(app: SessionModel, terminalMode: Bool = false) { self.app = app; self.local = app.local; self.remote = app.remote; self.terminalMode = terminalMode }

    var body: some View {
        if terminalMode {
            Button("下载…") { Task { await app.downloadSelection() } }
                .disabled(remote.selection.isEmpty || app.transferring || !remote.directoryReady)
        } else {
        HStack(spacing: 8) {
            transferButton(title: "上传", symbol: "arrow.right", enabled: !local.selection.isEmpty) { app.transfer(upload: true) }
                .help("上传到服务器当前目录：\(remote.path)")
            transferButton(title: "下载", symbol: "arrow.left", enabled: !remote.selection.isEmpty) { app.transfer(upload: false) }
                .help("下载到本机当前目录：\(local.path)")
        }
        }
    }

    private func transferButton(title: String, symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).fixedSize()
        }.buttonStyle(DockButtonStyle())
            .disabled(!app.connected || app.connecting || app.transferring || app.disconnecting || !enabled || !local.directoryReady || !remote.directoryReady)
            .accessibilityLabel(title)
    }
}

private struct TransferStatus: View {
    @ObservedObject var app: SessionModel
    @ViewState private var showLog = false
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: app.transferring ? "arrow.left.arrow.right" : "checkmark.circle")
                .foregroundStyle(.secondary)
            Text(app.transferLabel).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 10)
            if app.transferring {
                ProgressView(value: app.progress).frame(width: 110)
                Button("取消", action: app.cancelTransfer).controlSize(.small)
            }
            if !app.logs.isEmpty {
                Button { showLog.toggle() } label: {
                    Label("记录 \(app.logs.count)", systemImage: "list.bullet.rectangle")
                }.controlSize(.small)
                    .popover(isPresented: $showLog) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 9) {
                                ForEach(app.logs) { log in
                                    Text(log.text).font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(log.warning ? Color.orange : Color.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                                }
                            }.padding(15)
                        }.frame(width: 560, height: 310)
                    }
            }
        }.foregroundStyle(DockTheme.secondary).padding(.horizontal, 20).frame(height: 38).background(DockTheme.surface)
    }
}

private struct FileConflictCard: View {
    @ObservedObject var app: SessionModel
    let conflict: FileConflict
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\(app.profile.name) · 目标已有同名文件", systemImage: "exclamationmark.circle").font(.system(size: 13, weight: .medium))
            Text(app.profile.endpoint.address + "\n" + conflict.destination.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            HStack {
                Button("跳过") { app.finishConflict(.skip) }
                Button("覆盖") { app.finishConflict(.overwrite) }
                Button("取消传输", action: app.cancelTransfer)
            }.buttonStyle(DockButtonStyle())
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(DockTheme.surface, in: RoundedRectangle(cornerRadius: 8))
    }
}
