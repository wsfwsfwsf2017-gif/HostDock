import AppKit
import HostDockCore
import SwiftUI
import UniformTypeIdentifiers

private struct SessionTabTransfer: Codable, Transferable {
    let id: UUID
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "app.hostdock.session-tab", conformingTo: .data))
    }
}

@MainActor
func focusWorkspaceSession(_ app: AppModel, id: UUID) {
    func focus() -> Bool {
        guard !app.connectionPickerPresented, app.selectedSessionID == id, let session = app.selectedSession, session.connected,
              let window = session.terminal.view.window else { return false }
        let files = session.workspaceMode == .files && (app.workspace.layout == .single || app.workspace.expandedSessionID == id)
        window.makeFirstResponder(files ? nil : session.terminal.view)
        return true
    }
    if !focus() { DispatchQueue.main.async { _ = focus() } }
}

struct WorkspaceView: View {
    @ObservedObject var app: AppModel
    let windowReady: Bool
    @ObservedObject private var catalog: ConnectionCatalog

    init(app: AppModel, windowReady: Bool = true) { self.app = app; self.windowReady = windowReady; catalog = app.catalog }

    private var visibleIDs: Set<UUID> {
        if let expanded = app.workspace.expandedSessionID { return [expanded] }
        return Set(app.workspace.slots.prefix(app.workspace.layout.rawValue).compactMap { $0 })
    }
    private var focusTarget: UUID? {
        !app.connectionPickerPresented && app.selectedSession?.connected == true ? app.selectedSessionID : nil
    }

    var body: some View {
        HStack(spacing: 0) {
            ServerSidebar(app: app).frame(width: 238)
            Rectangle().fill(DockTheme.border).frame(width: 1)
            VStack(spacing: 0) {
                WorkspaceTabs(app: app)
                Rectangle().fill(DockTheme.border).frame(height: 1)
                if let error = catalog.loadError { DockNotice(text: error).padding(12) }
                if let notice = app.workspaceNotice {
                    HStack { DockNotice(text: notice); Button("关闭") { app.workspaceNotice = nil } }.padding(10)
                }
                WorkspaceGrid(app: app)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DockTheme.background).foregroundStyle(DockTheme.text).tint(DockTheme.accent)
        .sheet(isPresented: Binding(get: { windowReady && app.connectionPickerPresented }, set: { app.connectionPickerPresented = $0 })) {
            ConnectionPickerView(app: app)
        }
        .confirmationDialog("关闭会话？传输将取消，未上传的编辑保留为本机草稿。", isPresented: Binding(get: { app.closingSessionID != nil }, set: { if !$0 { app.closingSessionID = nil } })) {
            if let session = app.sessions.first(where: { $0.id == app.closingSessionID }) {
                Button("保留草稿并关闭“\(session.profile.name)”", role: .destructive) { Task { await app.closeTab(session) } }
            }
        }
        .onChange(of: visibleIDs, initial: true) { _, ids in
            for session in app.sessions { session.setVisible(ids.contains(session.id)) }
        }
        .onChange(of: focusTarget) { _, id in
            if let id {
                let otherFocused = app.sessions.contains { session in
                    session.id != id && visibleIDs.contains(session.id) && session.terminal.view.window?.firstResponder === session.terminal.view
                }
                if !otherFocused { focusWorkspaceSession(app, id: id) }
            }
            else if !app.connectionPickerPresented {
                for session in app.sessions {
                    if let window = session.terminal.view.window, window.firstResponder === session.terminal.view { window.makeFirstResponder(nil) }
                }
            }
        }
    }
}

private struct ServerSidebar: View {
    @ObservedObject var app: AppModel
    @ObservedObject private var catalog: ConnectionCatalog
    @ViewState private var category = ConnectionPickerTab.saved
    @ViewState private var search = ""
    @ViewState private var pendingExpanded = false
    @ViewState private var deleting: ConnectionProfile?
    @ViewState private var clearingHistory = false
    init(app: AppModel) { self.app = app; catalog = app.catalog }

    private func matches(_ profile: ConnectionProfile) -> Bool {
        search.isEmpty || "\(profile.name) \(profile.displaySubtitle) \(profile.endpoint.address)".localizedStandardContains(search)
    }
    private func open(_ profile: ConnectionProfile) {
        do { try app.openProfile(profile); if let id = app.selectedSessionID { focusWorkspaceSession(app, id: id) } }
        catch { app.workspaceNotice = error.localizedDescription }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HostDockMark().frame(width: 25, height: 25).foregroundStyle(DockTheme.accent)
                Text("HostDock").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button(action: app.showConnections) { Image(systemName: "plus").frame(width: 16, height: 16) }
                    .buttonStyle(DockButtonStyle()).help("新建连接（⌘K）").accessibilityLabel("新建连接")
                    .disabled(app.pickerCancelling || app.shuttingDown)
            }.padding(.horizontal, 16).frame(height: 60)
            DockTabs(options: [(ConnectionPickerTab.saved, "已保存"), (.recent, "最近访问")], selection: $category)
                .padding(.horizontal, 10).accessibilityLabel("服务器分类")
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(DockTheme.secondary)
                TextField("搜索服务器", text: $search).textFieldStyle(.plain).accessibilityLabel("搜索服务器")
            }.font(.system(size: 12)).padding(11).background(DockTheme.surface, in: RoundedRectangle(cornerRadius: 8)).padding(10)
            ScrollView {
                LazyVStack(spacing: 5) {
                    if category == .saved {
                        ForEach(app.savedProfiles.filter(matches)) { profile in serverRow(profile) }
                        if !app.pendingProfiles.isEmpty {
                            DisclosureGroup("待完善（\(app.pendingProfiles.count)）", isExpanded: $pendingExpanded) {
                                ForEach(app.pendingProfiles.filter(matches)) { profile in serverRow(profile) }
                            }.font(.system(size: 12)).foregroundStyle(DockTheme.secondary).padding(.horizontal, 4).padding(.top, 12)
                        }
                        if catalog.profiles.isEmpty { empty("尚未保存服务器") }
                        else if !catalog.profiles.contains(where: matches) { empty("没有匹配的服务器") }
                    } else {
                        ForEach(catalog.recent.filter { matches($0.draft()) }) { recent in
                            serverRow(catalog.profile(for: recent.endpoint) ?? recent.draft())
                        }
                        if catalog.recent.isEmpty { empty("暂无最近访问") }
                        else if !catalog.recent.contains(where: { matches($0.draft()) }) { empty("没有匹配的服务器") }
                    }
                }.padding(.horizontal, 10).padding(.bottom, 12)
            }
            if category == .recent && !catalog.recent.isEmpty {
                HStack { Spacer(); Button("清空历史") { clearingHistory = true }.buttonStyle(.plain).font(.caption).foregroundStyle(DockTheme.secondary) }
                    .padding(14).disabled(catalog.loadError != nil || app.updatingRecords)
            }
        }
        .background(DockTheme.background).disabled(app.shuttingDown)
        .confirmationDialog("删除服务器记录及已保存的认证？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            if let profile = deleting { Button("删除“\(profile.name)”", role: .destructive) {
                Task { do { try await app.removeProfile(profile) } catch { app.workspaceNotice = error.localizedDescription }; deleting = nil }
            } }
        }
        .confirmationDialog("清空最近访问？已保存服务器和认证将保留。", isPresented: $clearingHistory) {
            Button("清空历史", role: .destructive) { do { try catalog.clearHistory() } catch { app.workspaceNotice = error.localizedDescription } }
        }
    }

    private func empty(_ message: String) -> some View {
        Text(message).font(.system(size: 12)).foregroundStyle(DockTheme.secondary).padding(.vertical, 22)
    }

    private func serverRow(_ profile: ConnectionProfile) -> some View {
        let opened = app.sessions.first { $0.profile.id == profile.id || $0.profile.endpoint == profile.endpoint }
        return Button { open(profile) } label: {
            HStack(spacing: 6) {
                SidebarLabel(name: profile.name, address: profile.displaySubtitle, symbol: "server.rack")
                Spacer(minLength: 0)
                if let opened { Circle().fill(opened.needsAttention ? Color.orange : opened.connected ? Color.green : DockTheme.secondary).frame(width: 5, height: 5) }
            }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                .background(opened?.id == app.selectedSessionID && opened != nil ? DockTheme.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).modifier(DockHoverCursor())
            .contextMenu {
                Button("打开连接") { open(profile) }
                Button("编辑服务器…") { app.showProfile(profile, editing: true) }.disabled(app.isActive(profile))
                Button("修改认证…") { app.showProfile(profile, authenticating: true) }.disabled(app.isActive(profile))
                if catalog.profiles.contains(where: { $0.id == profile.id }) {
                    Divider()
                    Button("删除服务器…", role: .destructive) { deleting = profile }.disabled(app.isActive(profile))
                }
            }
    }
}

private struct WorkspaceTabs: View {
    @ObservedObject var app: AppModel
    var body: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(app.sessions) { session in
                        ConnectionTab(app: app, session: session)
                            .draggable(SessionTabTransfer(id: session.id))
                            .dropDestination(for: SessionTabTransfer.self) { values, _ in
                                guard let id = values.first?.id, app.sessions.contains(where: { $0.id == id }) else { return false }
                                app.moveTab(id, before: session.id); return true
                            }
                    }
                    Color.clear.frame(width: 20, height: 36).contentShape(Rectangle())
                        .dropDestination(for: SessionTabTransfer.self) { values, _ in
                            guard let id = values.first?.id, app.sessions.contains(where: { $0.id == id }) else { return false }
                            app.moveTab(id, before: nil); return true
                        }
                }.padding(.horizontal, 8)
            }.scrollIndicators(.hidden).frame(maxWidth: .infinity)
            DockTabs(options: WorkspaceLayout.allCases.map { ($0, $0.title) }, selection: Binding(get: { app.workspace.layout }, set: app.setLayout))
                .frame(width: 186).accessibilityLabel("工作区布局")
            AutomationBackgroundButton(app: app).padding(.trailing, 12)
        }.frame(height: 60).background(DockTheme.surface)
    }
}

private struct ConnectionTab: View {
    @ObservedObject var app: AppModel
    @ObservedObject var session: SessionModel
    var body: some View {
        HStack(spacing: 0) {
            Button { app.selectedSessionID = session.id; focusWorkspaceSession(app, id: session.id) } label: {
                HStack(spacing: 7) {
                    Circle().fill(session.needsAttention ? Color.orange : session.connected ? Color.green : DockTheme.secondary).frame(width: 6, height: 6)
                    Text(session.profile.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        .frame(maxWidth: 170, alignment: .leading)
                    if session.transferring { ProgressView(value: session.progress).frame(width: 28) }
                }.padding(.leading, 12).padding(.trailing, 5).frame(height: 36).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { app.requestCloseTab(session) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 30, height: 36).contentShape(Rectangle()) }
                .buttonStyle(.plain).help("关闭会话并断开").accessibilityLabel("关闭“\(session.profile.name)”")
        }
        .background(app.selectedSessionID == session.id ? DockTheme.accent.opacity(0.14) : DockTheme.background, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(app.selectedSessionID == session.id ? DockTheme.accent.opacity(0.45) : DockTheme.border))
        .help(session.profile.name + "\n" + session.profile.displaySubtitle + "\n" + session.status)
        .contextMenu {
            Button("断开连接，保留标签", action: session.disconnect).disabled(!session.connected || session.disconnecting)
            Button("重新连接…") { app.showConnection(session) }.disabled(session.busy || session.connected)
            Button("关闭会话并断开") { app.requestCloseTab(session) }
        }.modifier(DockHoverCursor())
    }
}

private struct WorkspaceGrid: View {
    @ObservedObject var app: AppModel
    @ViewState private var columnStart: Double?
    @ViewState private var rowStart: Double?
    var body: some View {
        GeometryReader { geometry in
            if let expanded = app.workspace.expandedSessionID, let session = app.sessions.first(where: { $0.id == expanded }) {
                VStack(spacing: 0) {
                    HStack { Button { app.workspace.expandedSessionID = nil } label: { Label("返回分屏", systemImage: "rectangle.split.2x2") }.buttonStyle(DockButtonStyle()); Spacer() }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                    SessionPanel(app: app, session: session).id(session.id)
                }
            } else if app.workspace.layout == .single { cell(0) }
            else {
                let width = max(1, geometry.size.width - 7)
                let height = max(1, geometry.size.height - 7)
                VStack(spacing: 0) {
                    row(0, width: width).frame(height: app.workspace.layout == .quad ? height * app.workspace.rowFraction : geometry.size.height)
                    if app.workspace.layout == .quad {
                        Rectangle().fill(DockTheme.border).frame(height: 1).frame(height: 7).contentShape(Rectangle())
                            .modifier(DockHoverCursor(cursor: .resizeUpDown)).help("拖动调整上下区域")
                            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                                if rowStart == nil { rowStart = app.workspace.rowFraction }
                                app.workspace.rowFraction = min(0.8, max(0.2, (rowStart ?? 0.5) + value.translation.height / height))
                            }.onEnded { _ in rowStart = nil })
                        row(2, width: width)
                    }
                }
            }
        }.padding(10)
    }
    private func row(_ first: Int, width: Double) -> some View {
        HStack(spacing: 0) {
            cell(first).frame(width: width * app.workspace.columnFraction)
            Rectangle().fill(DockTheme.border).frame(width: 1).frame(width: 7).contentShape(Rectangle())
                .modifier(DockHoverCursor(cursor: .resizeLeftRight)).help("拖动调整左右区域")
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    if columnStart == nil { columnStart = app.workspace.columnFraction }
                    app.workspace.columnFraction = min(0.8, max(0.2, (columnStart ?? 0.5) + value.translation.width / width))
                }.onEnded { _ in columnStart = nil })
            cell(first + 1)
        }
    }
    private func cell(_ index: Int) -> some View {
        let session = app.sessions.first { $0.id == app.workspace.slots[index] }
        return WorkspaceCell(app: app, session: session, index: index)
            .dropDestination(for: SessionTabTransfer.self) { values, _ in
                guard let id = values.first?.id, app.sessions.contains(where: { $0.id == id }) else { return false }
                app.placeTab(id, at: index); focusWorkspaceSession(app, id: id); return true
            }
    }
}

private struct WorkspaceCell: View {
    @ObservedObject var app: AppModel
    let session: SessionModel?
    let index: Int
    private var active: Bool { app.workspace.activeSlot == index }
    var body: some View {
        VStack(spacing: 0) {
            if let session {
                if app.workspace.layout != .single {
                    SplitPaneHeader(app: app, session: session)
                    Rectangle().fill(DockTheme.border).frame(height: 1)
                }
                SessionPanel(app: app, session: session, compact: app.workspace.layout != .single).id(session.id)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "server.rack").font(.system(size: 28, weight: .light)).foregroundStyle(DockTheme.accent)
                    Text(app.sessions.isEmpty ? "选择服务器，开始工作" : "选择服务器或拖入标签")
                        .font(.system(size: 14, weight: .medium))
                    Button("新建连接", action: app.showConnections).buttonStyle(DockButtonStyle())
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(DockTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(active && app.workspace.layout != .single ? DockTheme.accent : DockTheme.border, lineWidth: active && app.workspace.layout != .single ? 2 : 1).allowsHitTesting(false))
        .simultaneousGesture(TapGesture().onEnded {
            app.workspace.focus(index)
            app.selectedSessionID = session?.id
        })
        .accessibilityElement(children: .contain).accessibilityLabel("区域 \(index + 1)\(active ? "，活动区域" : "")")
    }
}

private struct SplitPaneHeader: View {
    @ObservedObject var app: AppModel
    @ObservedObject var session: SessionModel
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(session.needsAttention ? Color.orange : session.connected ? Color.green : DockTheme.secondary).frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.profile.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(session.profile.displaySubtitle).font(.system(size: 10, design: .monospaced)).foregroundStyle(DockTheme.secondary).lineLimit(1)
            }.help(session.profile.name + "\n" + session.profile.displaySubtitle)
            Spacer(minLength: 0)
            Button {
                app.selectedSessionID = session.id
                app.workspace.expandedSessionID = session.id
            } label: { Label("文件", systemImage: "folder").font(.system(size: 12)) }
                .buttonStyle(.plain).padding(8).background(DockTheme.background, in: RoundedRectangle(cornerRadius: 6))
                .help("放大此区域，打开完整文件工作区").disabled(!session.connected)
        }.padding(.horizontal, 12).frame(height: 52)
    }
}
