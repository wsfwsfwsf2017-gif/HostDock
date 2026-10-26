import HostDockCore
import SwiftUI

struct AutomationBackgroundButton: View {
    @ObservedObject var app: AppModel
    @ObservedObject private var controller: AutomationController
    @ViewState private var presented = false
    init(app: AppModel) { self.app = app; controller = app.automation }
    private var attention: Bool { !controller.connectionNotices.isEmpty || app.backgroundSessions.contains(where: \.needsAttention) }
    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: attention ? "exclamationmark.circle" : "terminal")
                Text("AI 后台")
                if !app.backgroundSessions.isEmpty { Text("\(app.backgroundSessions.count)").monospacedDigit() }
            }.font(.system(size: 12)).foregroundStyle(attention ? Color.orange : DockTheme.text)
        }.buttonStyle(DockButtonStyle()).help("查看和停止独立的 AI 后台连接")
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                AutomationBackgroundView(app: app, controller: controller, openAuthentication: { profile in
                    presented = false
                    app.showProfile(profile, authenticating: true)
                })
            }
    }
}

struct AutomationBackgroundView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var controller: AutomationController
    var openAuthentication: (ConnectionProfile) -> Void = { _ in }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("AI 后台", systemImage: "terminal").font(.headline)
                Spacer()
                Text(controller.enabled ? "\(controller.activeCount) 个请求" : "未开启").font(.caption).foregroundStyle(DockTheme.secondary)
            }
            if !controller.enabled {
                Text("在设置中开启「允许 AI 操作 HostDock」。").font(.system(size: 12)).foregroundStyle(DockTheme.secondary)
                SettingsLink { Text("打开设置…") }.buttonStyle(DockButtonStyle())
            } else if app.backgroundSessions.isEmpty && controller.connectionNotices.isEmpty {
                Text("暂无后台连接").font(.system(size: 13)).foregroundStyle(DockTheme.secondary).frame(maxWidth: .infinity, minHeight: 75)
            }
            if let notice = controller.notice { DockNotice(text: notice) }
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(app.backgroundSessions) { session in
                        BackgroundSessionRow(session: session, operations: controller.operations(in: session),
                                             stop: { Task { await controller.stopBackground(session.id) } },
                                             authenticate: { openAuthentication(session.profile) })
                    }
                    ForEach(controller.connectionNotices.keys.sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { id in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(app.catalog.profiles.first(where: { $0.id == id })?.name ?? "连接失败").font(.system(size: 13, weight: .semibold))
                            Text(controller.connectionNotices[id] ?? "").font(.system(size: 12)).foregroundStyle(DockTheme.secondary).fixedSize(horizontal: false, vertical: true)
                            HStack {
                                if let profile = app.catalog.profiles.first(where: { $0.id == id }) {
                                    Button("完善认证…") { openAuthentication(profile) }.buttonStyle(DockButtonStyle())
                                }
                                Button("清除提示") { controller.dismissNotice(id) }.buttonStyle(DockButtonStyle())
                            }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(DockTheme.background, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }.frame(maxHeight: 380)
        }.padding(20).frame(width: 460).fixedSize(horizontal: false, vertical: true)
            .background(DockTheme.surface).foregroundStyle(DockTheme.text).tint(DockTheme.accent)
    }
}

private struct BackgroundSessionRow: View {
    @ObservedObject var session: SessionModel
    let operations: [String]
    let stop: () -> Void
    let authenticate: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(session.profile.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).help(session.profile.name)
                    Text(session.profile.displaySubtitle).font(.system(size: 11, design: .monospaced)).foregroundStyle(DockTheme.secondary)
                    Text(session.status).font(.caption).foregroundStyle(session.needsAttention ? Color.orange : DockTheme.secondary)
                }
                Spacer()
                Button("结束", action: stop).buttonStyle(DockButtonStyle()).disabled(session.disconnecting)
            }
            if !operations.isEmpty { Text(operations.joined(separator: " · ")).font(.system(size: 11, design: .monospaced)).foregroundStyle(DockTheme.secondary) }
            if let request = session.hostTrustRequest { HostTrustCard(request: request, trust: session.trustHost) }
            if let conflict = session.conflictRequest { FileConflictCard(app: session, conflict: conflict) }
            if session.passwordRequired { Button("完善认证…", action: authenticate).buttonStyle(DockButtonStyle()) }
            if let error = session.connectionError { DockNotice(text: error) }
            if session.transferring { HStack {
                ProgressView(value: session.progress)
                Button("取消传输", action: session.cancelTransfer).buttonStyle(.plain)
            }.font(.caption) }
        }.padding(12).background(DockTheme.background, in: RoundedRectangle(cornerRadius: 8))
    }
}
