import AppKit
import Foundation
import HostDockCore

private actor CopyOutcome {
    var skipped = false
    func record(_ event: TransferEvent) { if case .skipped = event { skipped = true } }
}

@MainActor
final class FileClipboard {
    static let shared = FileClipboard()
    struct Item {
        let id = UUID()
        let session: SessionModel
        let generation: UUID
        let store: any FileStore
        let entries: [FileEntry]
        let remote: Bool
        let cut: Bool
    }
    var item: Item?
}

@MainActor
final class FileActions: NSObject {
    let session: SessionModel
    let remote: Bool
    var browser: BrowserModel { remote ? session.remote : session.local }
    weak var window: NSWindow?
    init(session: SessionModel, remote: Bool) { self.session = session; self.remote = remote }

    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }
    @objc private func invoke(_ sender: NSMenuItem) { (sender.representedObject as? Action)?.run() }

    func menu(entries: [FileEntry], directory: String, window: NSWindow?) -> NSMenu {
        self.window = window
        let menu = NSMenu()
        menu.autoenablesItems = false
        let ready = session.connected && browser.directoryReady && !session.disconnecting
        let one = entries.count == 1 ? entries.first : nil
        let folder = one?.kind == .directory ? one!.path : directory
        let generation = session.connectionGeneration
        func add(_ title: String, enabled: Bool = true, _ operation: @escaping () async throws -> Void) {
            let item = NSMenuItem(title: title, action: #selector(invoke(_:)), keyEquivalent: "")
            item.target = self; item.isEnabled = ready && enabled
            item.representedObject = Action { [weak self] in
                Task { @MainActor in
                    do {
                        guard self?.session.connectionGeneration == generation else { throw HostDockError("原会话已变化，请重新打开菜单。") }
                        try await operation()
                    }
                    catch is CancellationError {}
                    catch { await self?.showError(error) }
                }
            }
            menu.addItem(item)
        }
        add("打开目录", enabled: one?.kind == .directory) { [self] in
            if let one { await browser.navigate(to: one.path) }
        }
        if remote {
            add("编辑", enabled: one?.kind == .file) { [self] in
                if let one { try await RemoteEditors.shared.open(one, session: session) }
            }
        } else {
            add("在访达中显示", enabled: !entries.isEmpty) {
                NSWorkspace.shared.activateFileViewerSelecting(entries.map { URL(fileURLWithPath: $0.path) })
            }
        }
        add(remote ? (session.workspaceMode == .terminal ? "下载…" : "下载到本机当前目录") : "上传到服务器当前目录", enabled: !entries.isEmpty) { [self] in
            if remote && session.workspaceMode == .terminal { await session.downloadSelection(entries: entries, window: window) }
            else { try await copy(entries, toRemote: !remote, directory: (remote ? session.local : session.remote).path, cut: false) }
        }
        menu.addItem(.separator())
        add("新建文件") { [self] in try await create(directory: folder, isDirectory: false) }
        add("新建文件夹") { [self] in try await create(directory: folder, isDirectory: true) }
        add("复制", enabled: !entries.isEmpty) { [self] in try putClipboard(entries, cut: false) }
        add("剪切", enabled: !entries.isEmpty) { [self] in try putClipboard(entries, cut: true) }
        add("粘贴", enabled: canPaste) { [self] in try await paste(directory: folder) }
        add("重命名", enabled: one != nil) { [self] in if let one { try await rename(one) } }
        add(remote ? "删除…" : "移到废纸篓", enabled: !entries.isEmpty) { [self] in try await delete(entries) }
        menu.addItem(.separator())
        add("复制路径") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString((entries.isEmpty ? [directory] : entries.map(\.path)).joined(separator: "\n"), forType: .string)
        }
        add("属性…", enabled: !entries.isEmpty) { [self] in try await properties(entries) }
        add("刷新") { [self] in await browser.refresh() }
        return menu
    }

    var canPaste: Bool {
        guard let item = FileClipboard.shared.item else { return false }
        return (!item.remote && !remote) || item.session === session
    }
    func putClipboard(_ entries: [FileEntry], cut: Bool) throws {
        guard let store = browser.store else { throw HostDockError("目录不可用。") }
        FileClipboard.shared.item = .init(session: session, generation: session.connectionGeneration,
                                         store: store, entries: FilePath.topLevelSelection(entries), remote: remote, cut: cut)
    }
    func paste(directory: String) async throws {
        guard canPaste, let item = FileClipboard.shared.item else { throw HostDockError("暂不支持跨服务器粘贴。") }
        if item.remote && (!item.session.connected || item.generation != item.session.connectionGeneration) {
            throw HostDockError("来源会话已重连或关闭，请重新复制。")
        }
        try await copy(item.entries, source: item.store, sourceRemote: item.remote,
                       toRemote: remote, directory: directory, cut: item.cut)
        if item.cut && FileClipboard.shared.item?.id == item.id { FileClipboard.shared.item = nil }
    }
    func copy(_ entries: [FileEntry], source: (any FileStore)? = nil, sourceRemote: Bool? = nil,
              toRemote: Bool, directory: String, cut: Bool) async throws {
        let sourceRemote = sourceRemote ?? remote
        guard let from = source ?? browser.store,
              let destination = (toRemote ? session.remote : session.local).store else { throw HostDockError("两侧目录尚未就绪。") }
        let destinationDirectory = try await destination.canonicalDirectory(at: directory)
        let entries = FilePath.topLevelSelection(entries)
        let targets = try entries.map { try FilePath.join(destinationDirectory, name: $0.name) }
        if sourceRemote == toRemote {
            for (entry, target) in zip(entries, targets) {
                let sourcePath = entry.path.precomposedStringWithCanonicalMapping.lowercased()
                let targetPath = target.precomposedStringWithCanonicalMapping.lowercased()
                guard sourcePath != targetPath, !(entry.kind == .directory && FilePath.isInside(targetPath, directory: sourcePath)) else {
                    throw HostDockError("不能将项目复制或移动到自身或子目录。")
                }
            }
        }
        let remotePaths = (toRemote ? targets : []) + (cut && sourceRemote ? entries.map(\.path) : [])
        let localPaths = (!toRemote ? targets : []) + (cut && !sourceRemote ? entries.map(\.path) : [])
        let outcome = CopyOutcome()
        try await session.runFileOperation(cut ? "移动" : "复制", localPaths: localPaths, remotePaths: remotePaths) { [session] in
            try await TransferEngine().transfer(entries, from: from, to: destination, directory: destinationDirectory,
                onConflict: { await session.resolve($0) }, onEvent: {
                    await outcome.record($0)
                    await session.record($0)
                })
            if cut {
                guard await !outcome.skipped else { throw HostDockError("部分项目已跳过，移动未删除来源。") }
                for (entry, target) in zip(entries, targets) {
                    try await FileOperations.verify(entry, from: from, at: target, in: destination)
                }
                try Task.checkCancellation()
                try await FileOperations.remove(entries, in: from)
            }
        }
    }

    private func create(directory: String, isDirectory: Bool) async throws {
        guard let store = browser.store,
              let name = await input(isDirectory ? "新建文件夹" : "新建文件", value: isDirectory ? "新建文件夹" : "新文件.txt") else { return }
        let path = try FilePath.join(directory, name: name)
        try await session.runFileOperation("新建", localPaths: remote ? [] : [path], remotePaths: remote ? [path] : []) {
            guard try await store.metadata(at: path) == nil else { throw HostDockError("同名项目已存在。") }
            if isDirectory { try await store.createDirectory(at: path) }
            else { try await TransferEngine().replaceContents(Data(), at: path, in: store, expectedDigest: nil) }
        }
    }
    private func rename(_ entry: FileEntry) async throws {
        guard let store = browser.store, let name = await input("重命名", value: entry.name) else { return }
        let target = try FilePath.join(FilePath.parent(entry.path), name: name)
        if target == entry.path { return }
        try await session.runFileOperation("重命名", localPaths: remote ? [] : [entry.path, target], remotePaths: remote ? [entry.path, target] : []) {
            try await store.move(from: entry.path, to: target)
        }
    }
    private func delete(_ entries: [FileEntry]) async throws {
        guard let store = browser.store else { return }
        let entries = FilePath.topLevelSelection(entries)
        if remote {
            let alert = NSAlert()
            alert.messageText = "永久删除 \(entries.count) 个项目？"
            alert.informativeText = session.profile.name + "\n" + entries.map(\.path).joined(separator: "\n") + "\n远端没有废纸篓，删除后无法恢复。"
            alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "永久删除")
            guard await response(alert) == .alertSecondButtonReturn else { return }
        }
        let remote = remote
        try await session.runFileOperation("删除", localPaths: remote ? [] : entries.map(\.path), remotePaths: remote ? entries.map(\.path) : []) {
            if remote { try await FileOperations.remove(entries, in: store) }
            else {
                for entry in entries {
                    try Task.checkCancellation()
                    guard entry.path != "/" else { throw HostDockError("不能删除根目录。") }
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: nil)
                }
            }
        }
    }
    private func properties(_ entries: [FileEntry]) async throws {
        guard let entry = entries.first, let store = browser.store,
              let current = try await store.metadata(at: entry.path) else { return }
        guard let window, let mode = await FilePropertiesView.present(current, count: entries.count, parent: window) else { return }
        try await session.runFileOperation("修改权限", localPaths: remote ? [] : [current.path], remotePaths: remote ? [current.path] : []) {
            try await store.setPermissions(mode, at: current.path)
        }
    }
    private func input(_ title: String, value: String) async -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        return await response(alert) == .alertFirstButtonReturn ? field.stringValue : nil
    }
    private func response(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window else { return .cancel }
        alert.window.preventsApplicationTerminationWhenModal = false
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }
    private func showError(_ error: Error) async {
        guard session.connected else { return }
        let alert = NSAlert()
        alert.messageText = "文件操作未完成"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "确定")
        _ = await response(alert)
    }
}
