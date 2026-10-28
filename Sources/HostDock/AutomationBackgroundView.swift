import HostDockCore
import SwiftUI

struct AutomationBackgroundButton: View {
    @ObservedObject var app: AppModel
    @ObservedObject private var controller: AutomationController
    @ObservedObject private var history: AutomationRecords
    @ViewState private var presented = false
    init(app: AppModel) { self.app = app; controller = app.automation; history = app.automationRecords }
    private var attention: Bool {
        !controller.connectionNotices.isEmpty || app.backgroundSessions.contains(where: \.needsAttention)
            || !history.protectedServers.isEmpty || history.protectionFailure != nil || history.notice != nil
    }
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
                    app.diagnostics.record(.popoverDismissRequested, id: profile.id, critical: true)
                    presented = false
                    app.showProfile(profile, authenticating: true)
                }, openRecord: { record in
                    app.diagnostics.record(.viewRecordClicked, id: record.id, relatedID: record.header.sessionID, critical: true)
                    app.diagnostics.record(.popoverDismissRequested, id: record.id, critical: true)
                    presented = false; app.showRecord(record)
                }).onDisappear { app.diagnostics.record(.popoverDisappeared) }
            }
    }
}

struct AutomationBackgroundView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var controller: AutomationController
    @ObservedObject private var history: AutomationRecords
    var openAuthentication: (ConnectionProfile) -> Void = { _ in }
    var openRecord: (AutomationRecord) -> Void = { _ in }
    @ViewState private var showHistory = false
    @ViewState private var clearing = false
    init(app: AppModel, controller: AutomationController, openAuthentication: @escaping (ConnectionProfile) -> Void = { _ in },
         openRecord: @escaping (AutomationRecord) -> Void = { _ in }) {
        self.app = app; self.controller = controller; self.history = app.automationRecords
        self.openAuthentication = openAuthentication; self.openRecord = openRecord
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("AI 后台", systemImage: "terminal").font(.headline)
                Spacer()
                Text(controller.enabled ? "\(controller.activeCount) 个请求" : "未开启").font(.caption).foregroundStyle(DockTheme.secondary)
            }
            DockTabs(options: [(false, "当前连接"), (true, "历史记录")], selection: $showHistory)
            if !controller.enabled && !showHistory {
                Text("在设置中开启「允许 AI 操作 HostDock」。").font(.system(size: 12)).foregroundStyle(DockTheme.secondary)
                SettingsLink { Text("打开设置…") }.buttonStyle(DockButtonStyle())
            } else if !showHistory && app.backgroundSessions.isEmpty && controller.connectionNotices.isEmpty {
                Text("暂无后台连接").font(.system(size: 13)).foregroundStyle(DockTheme.secondary).frame(maxWidth: .infinity, minHeight: 75)
            }
            if let notice = controller.notice { DockNotice(text: notice) }
            if let notice = history.notice {
                DockNotice(text: notice)
                Button("重试保存") { Task { try? await history.flush() } }.buttonStyle(DockButtonStyle())
            }
            if let failure = history.protectionFailure {
                DockNotice(text: failure)
                Button("重试读取保护状态") { Task { await history.retryProtectionLoad() } }.buttonStyle(DockButtonStyle())
            }
            ScrollView {
                LazyVStack(spacing: 12) {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        ForEach(history.protectedServers) { protection in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(protection.host, systemImage: "lock.shield")
                                    Text("AI 保护 · 剩余 \(max(0, Int(protection.until.timeIntervalSinceNow))) 秒")
                                        .font(.caption).foregroundStyle(DockTheme.secondary)
                                }
                                Spacer()
                                Button("提前解除") { Task { await history.release(protection.serverKey) } }.buttonStyle(DockButtonStyle())
                            }.font(.system(size: 12)).padding(12).background(DockTheme.background, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    if showHistory {
                        ForEach(history.records.filter { !$0.active }) { record in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(record.header.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Text(record.displayAddress).font(.system(size: 11, design: .monospaced)).foregroundStyle(DockTheme.secondary)
                                Text(record.header.startedAt.formatted(date: .abbreviated, time: .shortened) + " · " + (record.header.endReason ?? "已结束"))
                                    .font(.caption).foregroundStyle(DockTheme.secondary)
                                HStack {
                                    Button("查看记录") { openRecord(record) }.buttonStyle(DockButtonStyle())
                                    Spacer()
                                    Button("删除") { Task { await history.delete(record) } }.buttonStyle(.plain)
                                        .disabled(app.recordTabs.contains { $0.id == record.id })
                                }
                            }.padding(12).background(DockTheme.background, in: RoundedRectangle(cornerRadius: 8))
                        }
                        if history.records.allSatisfy(\.active) {
                            Text("暂无历史记录").font(.system(size: 13)).foregroundStyle(DockTheme.secondary).padding(20)
                        }
                    } else {
                    ForEach(app.backgroundSessions) { session in
                        BackgroundSessionRow(session: session, operations: controller.operations(in: session),
                                             stopping: controller.endingServers.contains(AutomationRecords.serverKey(session.profile.targetHost)),
                                             stop: { Task { await controller.protectAndStop(session.id) } },
                                             authenticate: { openAuthentication(session.profile) },
                                             view: {
                                                 if let record = history.record(sessionID: session.id) { openRecord(record) }
                                             })
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
                }
            }.frame(maxHeight: 380)
            if showHistory && history.records.contains(where: { !$0.active }) {
                Button("清空已结束历史…") { clearing = true }.buttonStyle(.plain).font(.caption)
            }
        }.padding(20).frame(width: 460).fixedSize(horizontal: false, vertical: true)
            .background(DockTheme.surface).foregroundStyle(DockTheme.text).tint(DockTheme.accent)
            .confirmationDialog("清空已结束且未打开查看的记录？保护状态将保留。", isPresented: $clearing) {
                Button("清空历史", role: .destructive) { Task { await history.clearHistory() } }
            }
    }
}

private struct BackgroundSessionRow: View {
    @ObservedObject var session: SessionModel
    let operations: [String]
    let stopping: Bool
    let stop: () -> Void
    let authenticate: () -> Void
    let view: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(session.profile.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).help(session.profile.name)
                    Text(session.profile.displaySubtitle).font(.system(size: 11, design: .monospaced)).foregroundStyle(DockTheme.secondary)
                    Text(session.status).font(.caption).foregroundStyle(session.needsAttention ? Color.orange : DockTheme.secondary)
                }
                Spacer()
                Button("查看记录", action: view).buttonStyle(DockButtonStyle())
                Button(stopping ? "结束中…" : "结束并保护", action: stop).buttonStyle(DockButtonStyle()).disabled(session.disconnecting || stopping)
                    .help("停止此服务器的全部 AI 连接并保护 5 分钟")
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
