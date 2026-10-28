import AppKit
import HostDockCore
import SwiftUI

struct AutomationRecordView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var record: AutomationRecord
    @ObservedObject private var automation: AutomationController
    init(app: AppModel, record: AutomationRecord) { self.app = app; self.record = record; automation = app.automation }
    private var session: SessionModel? { app.backgroundSessions.first { $0.id == record.header.sessionID } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.header.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).help(record.header.name)
                    Text(record.displayAddress).font(.system(size: 11, design: .monospaced)).foregroundStyle(DockTheme.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Label("AI · 只读", systemImage: "eye").font(.system(size: 11)).foregroundStyle(DockTheme.accent)
                if let session {
                    Button("结束并保护") { Task { await app.automation.protectAndStop(session.id) } }
                        .buttonStyle(DockButtonStyle()).disabled(session.disconnecting || automation.endingServers.contains(record.header.serverKey))
                        .help("停止此服务器的全部 AI 连接并保护 5 分钟，人工连接继续运行")
                }
            }.padding(12)
            Divider()
            HStack {
                DockTabs(options: [(false, "操作记录"), (true, "终端")], selection: $record.showingTerminal).frame(width: 210)
                Spacer()
                Text(record.active ? "后台运行中" : record.header.endReason ?? "已结束")
                    .font(.system(size: 11)).foregroundStyle(DockTheme.secondary).lineLimit(1)
            }.padding(.horizontal, 12).padding(.vertical, 6)
            if let notice = record.notice { DockNotice(text: notice).padding(10) }
            Divider()
            if record.loading {
                ProgressView("读取记录…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if record.showingTerminal {
                if record.hasTerminal { TerminalSurface(controller: record.terminal()).padding(8) }
                else { ContentUnavailableView("暂无交互终端输出", systemImage: "terminal", description: Text("命令结果可在「操作记录」中查看")) }
            } else {
                AutomationRecordText(text: operationText)
            }
        }.background(DockTheme.surface).foregroundStyle(DockTheme.text)
            .onAppear { app.diagnostics.record(.recordViewAppeared, id: record.id, layout: app.workspace.layout.rawValue) }
            .onDisappear { app.diagnostics.record(.recordViewDisappeared, id: record.id) }
    }
    private var operationText: String {
        _ = record.revision
        return record.operations.map { event in
            let time = event.time.formatted(date: .numeric, time: .standard)
            var text = "[\(time)] \(event.title)"
            if !event.detail.isEmpty { text += "\n" + event.detail }
            if let failure = event.failure { text += "\n\(failure.code): \(failure.message)" }
            if let result = event.result {
                if case .object(let fields) = result, let stdout = fields["stdout"] {
                    if case .string(let output) = stdout, !output.isEmpty { text += "\nstdout:\n" + output }
                    if case .string(let error) = fields["stderr"], !error.isEmpty { text += "\nstderr:\n" + error }
                    if case .number(let code) = fields["exitCode"] { text += "\n退出码：\(Int(code))" }
                } else {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    if let data = try? encoder.encode(result), let output = String(data: data, encoding: .utf8) { text += "\n" + output }
                }
            }
            return text
        }.joined(separator: "\n\n")
    }
}

private struct AutomationRecordText: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let view = NSTextView()
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.usesFindBar = true; view.isIncrementalSearchingEnabled = true
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = NSSize(width: 16, height: 14)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.setAccessibilityLabel("AI 操作记录，只读")
        scroll.hasVerticalScroller = true; scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        view.textColor = DockTheme.textNS; view.backgroundColor = DockTheme.surfaceNS
        scroll.backgroundColor = DockTheme.surfaceNS
        guard view.string != text else { return }
        let following = view.string.isEmpty || scroll.contentView.bounds.maxY >= view.bounds.maxY - 30
        let selection = view.selectedRange(), origin = scroll.contentView.bounds.origin
        view.string = text
        if NSMaxRange(selection) <= view.string.utf16.count { view.setSelectedRange(selection) }
        if following { view.scrollRangeToVisible(NSRange(location: view.string.utf16.count, length: 0)) }
        else { scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView) }
    }
}

struct AutomationRecordTab: View {
    @ObservedObject var app: AppModel
    @ObservedObject var record: AutomationRecord
    private var region: Int? { app.workspace.slots.prefix(app.workspace.layout.rawValue).firstIndex(of: record.id) }
    var body: some View {
        HStack(spacing: 0) {
            Button { app.selectTab(record.id); NSApp.keyWindow?.makeFirstResponder(nil) } label: {
                HStack(spacing: 7) {
                    Image(systemName: "eye")
                    Text("AI · 只读 · " + record.header.name).lineLimit(1).frame(maxWidth: 210)
                    if let region, app.workspace.layout != .single { Text("\(region + 1)").monospacedDigit() }
                }.font(.system(size: 12)).padding(.leading, 12).padding(.trailing, 5).frame(height: 36).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { app.closeRecord(record.id) } label: { Image(systemName: "xmark").font(.system(size: 9)).frame(width: 30, height: 36).contentShape(Rectangle()) }
                .buttonStyle(.plain).help("关闭查看，AI 后台继续运行").accessibilityLabel("关闭 AI 记录查看")
        }.background(region != nil ? DockTheme.accent.opacity(0.14) : DockTheme.background, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(app.selectedSessionID == record.id ? DockTheme.accent : DockTheme.border,
                lineWidth: app.selectedSessionID == record.id ? 2 : 1))
            .modifier(DockHoverCursor()).help("AI · 只读\n" + record.header.name + "\n" + record.displayAddress)
            .contextMenu {
                Button("关闭查看") { app.closeRecord(record.id) }
                Button("关闭所有标签", action: app.requestCloseAllTabs).disabled(!app.canCloseAllTabs)
            }
    }
}
