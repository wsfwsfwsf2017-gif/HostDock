import AppKit
import HostDockCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var app: SessionModel
    var showConnections: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Circle().fill(app.connectionIndicatorHealthy ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.profile.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(app.profile.displaySubtitle).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DockTheme.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }.help(app.profile.name + "\n" + app.profile.displayAddress)
                Spacer()
                if app.workspaceMode == .files { UploadButton(app: app) }
                DockTabs(options: WorkspaceMode.allCases.map { ($0, $0.rawValue) }, selection: Binding(get: { app.workspaceMode }, set: app.setWorkspaceMode))
                    .frame(width: 190).accessibilityLabel("工作区模式")
                if app.recoveringFiles { Text("正在恢复连接…").font(.caption).foregroundStyle(DockTheme.secondary) }
                if app.connected {
                    Button("断开", action: app.disconnect).help("断开连接，保留标签以便重连").disabled(app.disconnecting)
                }
            }.buttonStyle(DockButtonStyle()).padding(.horizontal, 20).frame(height: 66).background(DockTheme.surface)
            Rectangle().fill(DockTheme.border).frame(height: 1)
            if let request = app.hostTrustRequest {
                HostTrustCard(request: request, trust: app.trustHost).padding(12)
                Button("取消连接", action: app.cancelConnection)
            }
            if app.needsAuthentication {
                Button("修改认证…", action: showConnections).buttonStyle(DockButtonStyle()).padding(8)
            }
            if let notice = app.credentialNotice { DockNotice(text: notice).padding([.top, .horizontal], 12) }
            if let conflict = app.conflictRequest {
                FileConflictCard(app: app, conflict: conflict).padding([.top, .horizontal], 12)
            }
            WorkspacePanes(app: app, showConnections: showConnections).padding(12)
            if !app.fileQueue.jobs.isEmpty {
                Rectangle().fill(DockTheme.border).frame(height: 1)
                FileQueuePanel(session: app, queue: app.fileQueue)
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
                FileBrowserPane(model: app.remote, remote: true, subtitle: app.profile.displaySubtitle, serverName: app.profile.name,
                                connect: showConnections, session: app).frame(maxWidth: .infinity)
            }
        }.clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DockTheme.border))
    }
}

private struct UploadButton: View {
    @ObservedObject var app: SessionModel
    @ObservedObject private var local: BrowserModel
    @ObservedObject private var remote: BrowserModel
    init(app: SessionModel) { self.app = app; self.local = app.local; self.remote = app.remote }

    var body: some View {
        Button { app.transfer(upload: true) } label: {
            Label("上传", systemImage: "arrow.right").fixedSize()
        }.buttonStyle(DockButtonStyle())
            .disabled(!app.connected || app.connecting || app.disconnecting || local.selection.isEmpty || !local.directoryReady || !remote.directoryReady)
            .help("上传到服务器当前目录：\(remote.path)").accessibilityLabel("上传")
    }
}

struct FileConflictCard: View {
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
