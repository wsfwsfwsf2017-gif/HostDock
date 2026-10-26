import AppKit
import HostDockCore
import SwiftUI

enum FilePermissions {
    static func summary(_ permissions: UInt32?) -> String {
        guard let permissions else { return "服务端未提供权限信息" }
        if permissions & 0o777 == 0o644 { return "所有者可读写，其他人只读" }
        return [("所有者", 6), ("同组用户", 3), ("其他用户", 0)].map { name, shift in
            let bits = (permissions >> shift) & 7
            let access = [(UInt32(4), "读"), (2, "写"), (1, "执行")].filter { bits & $0.0 != 0 }.map(\.1)
            return name + "：" + (access.isEmpty ? "无权限" : access.joined(separator: "、"))
        }.joined(separator: "；")
    }
    static func changing(_ original: UInt32, bit: UInt32, enabled: Bool) -> UInt32 {
        enabled ? original | bit : original & ~bit
    }
}

struct FilePropertiesView: View {
    let entry: FileEntry
    let count: Int
    let finish: (UInt32?) -> Void
    let onResize: (CGFloat) -> Void
    @ViewState private var editing = false
    @ViewState private var details = false
    @ViewState private var permissions: UInt32
    init(entry: FileEntry, count: Int = 1, onResize: @escaping (CGFloat) -> Void = { _ in }, finish: @escaping (UInt32?) -> Void = { _ in }) {
        self.entry = entry; self.count = count; self.finish = finish; self.onResize = onResize
        _permissions = ViewState(initialValue: entry.permissions ?? 0)
    }
    private var canEdit: Bool { count == 1 && entry.permissions != nil && [.file, .directory].contains(entry.kind) }
    private var height: CGFloat { 360 + (editing ? 150 : 0) + (details ? 70 : 0) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editing ? "修改权限" : "文件属性").font(.system(size: 20, weight: .semibold))
            Text(entry.name).font(.headline).textSelection(.enabled)
            if count > 1 { Text("共选择 \(count) 项，以下显示第一项的信息").font(.caption).foregroundStyle(DockTheme.secondary) }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                row("路径", entry.path)
                row("类型", entry.kind == .directory ? "文件夹" : entry.kind == .file ? "文件" : entry.kind == .symbolicLink ? "符号链接" : "特殊文件")
                row("大小", ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.size), countStyle: .file))
                row("修改时间", entry.modified?.formatted(date: .numeric, time: .standard) ?? "未知")
            }
            Text(FilePermissions.summary(entry.permissions)).font(.system(size: 12)).textSelection(.enabled)
            if editing {
                Grid(horizontalSpacing: 22, verticalSpacing: 10) {
                    GridRow { Text(""); Text("读取"); Text("写入"); Text("执行") }
                    ForEach(Array([("所有者", 6), ("同组用户", 3), ("其他用户", 0)].enumerated()), id: \.offset) { _, item in
                        GridRow {
                            Text(item.0)
                            ForEach([4, 2, 1], id: \.self) { flag in
                                let bit = UInt32(flag << item.1)
                                Toggle("", isOn: Binding(get: { permissions & bit != 0 }, set: { permissions = FilePermissions.changing(permissions, bit: bit, enabled: $0) }))
                                    .labelsHidden().toggleStyle(.checkbox).accessibilityLabel(item.0 + (flag == 4 ? "读取" : flag == 2 ? "写入" : "执行"))
                            }
                        }
                    }
                }.font(.system(size: 12)).padding(12).background(DockTheme.background, in: RoundedRectangle(cornerRadius: 8))
            }
            DisclosureGroup("技术详情", isExpanded: $details) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("权限代码：" + (entry.permissions.map { String(format: "%04o", $0) } ?? "未知"))
                    Text("所有者用户 ID：" + (entry.owner.map(String.init) ?? "未知"))
                    Text("群组 ID：" + (entry.group.map(String.init) ?? "未知"))
                }.font(.system(size: 11, design: .monospaced)).textSelection(.enabled).padding(.top, 8)
            }.font(.system(size: 12)).foregroundStyle(DockTheme.secondary)
            Spacer(minLength: 0)
            HStack {
                if canEdit && !editing { Button("修改权限…") { editing = true }.buttonStyle(DockButtonStyle()) }
                Spacer()
                Button(editing ? "取消" : "关闭") { finish(nil) }.keyboardShortcut(.cancelAction).buttonStyle(DockButtonStyle())
                if editing { Button("保存权限") { finish(permissions) }.keyboardShortcut(.defaultAction).buttonStyle(DockButtonStyle(prominent: true)) }
            }
        }.padding(24).frame(width: 500, height: height).background(DockTheme.surface).foregroundStyle(DockTheme.text).tint(DockTheme.accent)
            .onChange(of: editing) { _, _ in onResize(height) }
            .onChange(of: details) { _, _ in onResize(height) }
    }
    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(DockTheme.secondary)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 12))
    }
    @MainActor static func present(_ entry: FileEntry, count: Int, parent: NSWindow) async -> UInt32? {
        await withCheckedContinuation { continuation in
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
            sheet.preventsApplicationTerminationWhenModal = false
            sheet.contentView = NSHostingView(rootView: FilePropertiesView(entry: entry, count: count, onResize: { height in sheet.setContentSize(NSSize(width: 500, height: height)) }) { mode in
                parent.endSheet(sheet); continuation.resume(returning: mode)
            })
            parent.beginSheet(sheet)
        }
    }
}

extension SessionModel {
    func downloadSelection(entries: [FileEntry]? = nil, window: NSWindow? = nil) async {
        let entries = entries ?? remote.selectedEntries
        guard connected, !transferring, !entries.isEmpty, let parent = window ?? NSApp.keyWindow else { return }
        let generation = connectionGeneration
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.prompt = "下载到此目录"; panel.message = "选择这些服务器文件的本机保存位置"
        panel.directoryURL = URL(fileURLWithPath: local.path.isEmpty ? NSHomeDirectory() : local.path)
        guard await panel.beginSheetModal(for: parent) == .OK, let directory = panel.url else { return }
        guard connected, connectionGeneration == generation else { remote.report(HostDockError("原连接已变化，下载未开始。")); return }
        do { try await FileActions(session: self, remote: true).copy(entries, toRemote: false, directory: directory.path, cut: false) }
        catch { remote.report(error) }
    }
}
