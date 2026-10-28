import AppKit
import Combine
import CryptoKit
import Darwin
import HostDockCore
import SwiftUI

struct EditDraftStore: Sendable {
    struct Draft: Codable {
        var version = 1
        let contents: Data
        let baseline: String
    }
    let directory: URL
    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("HostDock/EditDrafts")) { self.directory = directory }
    func load(_ key: String) throws -> Draft? {
        let url = directory.appendingPathComponent(key + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let value = try JSONDecoder().decode(Draft.self, from: Data(contentsOf: url))
            guard value.version == 1 else { throw HostDockError("草稿版本不支持。") }
            return value
        } catch { throw HostDockError("本机草稿无法读取，原文件已保留，请先备份草稿。") }
    }
    func save(_ draft: Draft, key: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".draft-\(UUID()).tmp")
        defer { try? fm.removeItem(at: temporary) }
        guard fm.createFile(atPath: temporary.path, contents: try JSONEncoder().encode(draft), attributes: [.posixPermissions: 0o600]) else {
            throw HostDockError("无法保存本机草稿，请检查应用资料目录权限。")
        }
        guard Darwin.rename(temporary.path, directory.appendingPathComponent(key + ".json").path) == 0 else {
            throw HostDockError("本机草稿提交失败。")
        }
    }
    func remove(_ key: String) throws {
        let url = directory.appendingPathComponent(key + ".json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

@MainActor
final class RemoteDocument: ObservableObject {
    static let sizeLimit = 5 * 1024 * 1024
    let session: SessionModel
    let identity: String
    let drafts: EditDraftStore
    @Published private(set) var path: String
    @Published var text: String { didSet { if text != oldValue { scheduleDraft() } } }
    @Published private(set) var saving = false
    @Published private(set) var conflict = false
    @Published private(set) var status = ""
    @Published var isClosing = false
    private var baseline: String
    private var bom: Bool
    private var crlf: Bool
    private var draftTask: Task<Void, Never>?
    var onPathChanged: ((String, String) -> Void)?
    var key: String { Self.key(identity: identity, path: path) }
    var encoded: Data {
        let value = crlf ? text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n") : text
        return (bom ? Data([0xef, 0xbb, 0xbf]) : Data()) + Data(value.utf8)
    }
    var isDirty: Bool { Self.hash(encoded) != baseline }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func key(identity: String, path: String) -> String { hash(Data((identity + "\0" + path).utf8)) }

    init(session: SessionModel, path: String, contents: Data, drafts: EditDraftStore = EditDraftStore()) throws {
        self.session = session; self.path = path; self.drafts = drafts
        identity = session.verifiedRemoteIdentity
        baseline = Self.hash(contents)
        let restored = try drafts.load(Self.key(identity: identity, path: path))
        let data = restored?.contents ?? contents
        let decoded = try Self.decode(data)
        text = decoded.text; bom = decoded.bom; crlf = decoded.crlf
        if let restored {
            baseline = restored.baseline
            status = "已恢复未上传草稿；保存前会检查远端变化。"
        }
    }
    static func decode(_ data: Data) throws -> (text: String, bom: Bool, crlf: Bool) {
        let bom = data.starts(with: [0xef, 0xbb, 0xbf])
        let body = bom ? data.dropFirst(3) : data[...]
        guard data.count <= sizeLimit, !data.contains(0), let value = String(data: body, encoding: .utf8) else {
            throw HostDockError("仅支持不超过 5 MiB 的 UTF-8 文本，二进制文件请下载。")
        }
        let crlf = value.contains("\r\n")
        return (value.replacingOccurrences(of: "\r\n", with: "\n"), bom, crlf)
    }
    func persistDraft() throws {
        draftTask?.cancel()
        if isDirty { try drafts.save(.init(contents: encoded, baseline: baseline), key: key) }
        else { try drafts.remove(key) }
    }
    private func scheduleDraft() {
        draftTask?.cancel()
        draftTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)); try self?.persistDraft() }
            catch is CancellationError {}
            catch { self?.status = "草稿保存失败：\(error.localizedDescription)" }
        }
    }
    @discardableResult
    func save(overwrite: Bool = false, as newPath: String? = nil) async -> Bool {
        guard !saving, !isClosing else { return false }
        guard session.connected, session.verifiedRemoteIdentity == identity, let store = session.remote.store else {
            status = "原服务器已断开，请重连后保存。"; return false
        }
        let target = newPath ?? path
        let data = encoded
        let previousKey = key
        guard data.count <= Self.sizeLimit else { status = "内容超过 5 MiB，请另行传输。"; return false }
        do { try persistDraft() } catch { status = error.localizedDescription; return false }
        let diagnosticSpan = session.diagnostics.begin(.editorSave, id: session.id, origin: session.diagnosticOrigin)
        var diagnosticFailure: DiagnosticFailure?
        defer { session.diagnostics.finish(diagnosticSpan, failure: diagnosticFailure) }
        saving = true; conflict = false; status = "等待保存到 \(target)…"
        defer { saving = false }
        do {
            let expected = newPath == nil ? baseline : nil
            try await session.runFileOperation("保存编辑", remotePaths: [target]) {
                try await TransferEngine().replaceContents(data, at: target, in: store, expectedDigest: expected, overwriteChanged: overwrite)
            }
            baseline = Self.hash(data)
            if target != path {
                path = target
                onPathChanged?(previousKey, key)
                try drafts.remove(previousKey)
            }
            status = isDirty ? "该版本已上传，仍有新的修改未上传。" : "已保存到服务器"
            try persistDraft()
            return true
        } catch {
            diagnosticFailure = .classify(error)
            conflict = error is FileChangedError
            status = error.localizedDescription
            try? persistDraft()
            return false
        }
    }
    func reload() async {
        guard !saving, session.connected, session.verifiedRemoteIdentity == identity, let store = session.remote.store else {
            status = "请先重连原服务器。"; return
        }
        do {
            let data = try await FileOperations.read(at: path, in: store, limit: Self.sizeLimit)
            let decoded = try Self.decode(data)
            text = decoded.text; bom = decoded.bom; crlf = decoded.crlf
            baseline = Self.hash(data); conflict = false; status = "已重新载入服务器内容"
            try persistDraft()
        } catch { status = error.localizedDescription }
    }
    func discardDraft() throws { draftTask?.cancel(); try drafts.remove(key) }
    func report(_ error: Error) { status = error.localizedDescription }
}

@MainActor
final class RemoteEditors: ObservableObject {
    static let shared = RemoteEditors()
    @Published var focused: RemoteDocument?
    private var windows: [String: RemoteEditorWindow] = [:]
    private var opening: Set<String> = []
    private var closingSessions: Set<UUID> = []
    private let drafts: EditDraftStore
    init(drafts: EditDraftStore = EditDraftStore()) { self.drafts = drafts }
    var hasUnuploadedEdits: Bool { windows.values.contains { $0.model.isDirty || $0.model.saving } }
    func hasUnuploadedEdits(in session: SessionModel) -> Bool {
        windows.values.contains { $0.model.session === session && ($0.model.isDirty || $0.model.saving) }
    }
    func closeEditors(in sessions: [SessionModel]) throws {
        let ids = Set(sessions.map(\.id))
        let owned = windows.values.filter { ids.contains($0.model.session.id) }
        closingSessions.formUnion(ids)
        do { for window in owned { window.model.isClosing = true; try window.model.persistDraft() } }
        catch {
            closingSessions.subtract(ids)
            for window in owned { window.model.isClosing = false }
            throw error
        }
        for window in owned { window.forceClose() }
    }
    func finishClosing(_ sessions: [SessionModel]) { closingSessions.subtract(sessions.map(\.id)) }
    func open(_ entry: FileEntry, session: SessionModel) async throws {
        guard session.connected, !session.disconnecting, !closingSessions.contains(session.id) else { throw HostDockError("原会话正在关闭或已断开。") }
        let key = RemoteDocument.key(identity: session.verifiedRemoteIdentity, path: entry.path)
        guard opening.insert(key).inserted else { return }
        defer { opening.remove(key) }
        if let existing = windows[key], existing.model.session === session {
            existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return
        }
        if let old = windows[key] { try old.model.persistDraft(); old.forceClose() }
        guard let store = session.remote.store else { throw HostDockError("服务器目录不可用。") }
        let identity = session.verifiedRemoteIdentity
        let generation = session.connectionGeneration
        let data = try await FileOperations.read(at: entry.path, in: store, limit: RemoteDocument.sizeLimit)
        guard session.connected, !session.disconnecting, session.connectionGeneration == generation,
              session.verifiedRemoteIdentity == identity, !closingSessions.contains(session.id) else { throw HostDockError("原会话已断开或正在关闭。") }
        if let existing = windows[key] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        let document = try RemoteDocument(session: session, path: entry.path, contents: data, drafts: drafts)
        let controller = RemoteEditorWindow(model: document, owner: self)
        windows[key] = controller
        document.onPathChanged = { [weak self] before, after in
            if let value = self?.windows.removeValue(forKey: before) { self?.windows[after] = value }
        }
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    func contains(identity: String, path: String) -> Bool { windows[RemoteDocument.key(identity: identity, path: path)] != nil }
    func remove(_ document: RemoteDocument) {
        if windows[document.key]?.model === document { windows.removeValue(forKey: document.key) }
        if focused === document { focused = nil }
    }
    func persistDraftsForQuit() throws {
        do {
            for controller in windows.values { controller.model.isClosing = true; try controller.model.persistDraft() }
        } catch { for controller in windows.values { controller.model.isClosing = false }; throw error }
    }
    func closeAll() { for window in Array(windows.values) { window.forceClose() } }
}

@MainActor
private final class RemoteEditorWindow: NSWindowController, NSWindowDelegate {
    let model: RemoteDocument
    private weak var registry: RemoteEditors?
    private var forced = false
    private var askingClose = false
    private var changes: AnyCancellable?
    init(model: RemoteDocument, owner: RemoteEditors) {
        self.model = model; self.registry = owner
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "编辑 · \(model.path) · \(model.session.profile.name)"
        window.minSize = NSSize(width: 600, height: 400)
        super.init(window: window)
        window.contentView = NSHostingView(rootView: RemoteEditorView(document: model))
        window.delegate = self
        changes = model.objectWillChange.sink { [weak window, weak model] _ in
            DispatchQueue.main.async {
                guard let model else { return }
                window?.title = "编辑 · \(model.path) · \(model.session.profile.name)"
                window?.isDocumentEdited = model.isDirty
            }
        }
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func forceClose() { forced = true; window?.close() }
    func windowDidBecomeKey(_ notification: Notification) { registry?.focused = model }
    func windowDidResignKey(_ notification: Notification) {
        if registry?.focused === model { registry?.focused = nil }
    }
    func windowWillClose(_ notification: Notification) { registry?.remove(model) }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if forced || (!model.isDirty && !model.saving) { return true }
        guard !askingClose else { return false }
        askingClose = true
        Task {
            let alert = NSAlert()
            alert.messageText = "此文件仍有未上传修改"
            alert.informativeText = model.path
            alert.addButton(withTitle: "保存后关闭"); alert.addButton(withTitle: "放弃修改"); alert.addButton(withTitle: "取消")
            alert.window.preventsApplicationTerminationWhenModal = false
            let response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: sender) { continuation.resume(returning: $0) }
            }
            if response == .alertFirstButtonReturn {
                if await model.save(), !model.isDirty { forceClose() }
            } else if response == .alertSecondButtonReturn {
                do { try model.discardDraft(); forceClose() } catch { model.report(error) }
            }
            askingClose = false
        }
        return false
    }
}

struct RemoteEditorView: View {
    @ObservedObject var document: RemoteDocument
    @ViewState private var askingReload = false
    @ViewState private var askingOverwrite = false
    @ViewState private var askingSaveAs = false
    @ViewState private var filename = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(document.session.profile.name).font(.headline)
                    Text(document.path).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Spacer()
                Button("重新载入") { askingReload = true }
                Button("另存为…") { filename = URL(fileURLWithPath: document.path).lastPathComponent; askingSaveAs = true }
                Button("保存") { Task { await document.save() } }.keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(DockButtonStyle(prominent: true))
            }.buttonStyle(DockButtonStyle()).padding(14).disabled(document.saving || document.isClosing)
            Divider()
            EditorText(document: document)
            Divider()
            HStack {
                if document.saving { ProgressView().controlSize(.small) }
                Text(document.status.isEmpty ? "UTF-8 · 保存后自动上传" : document.status)
                    .font(.system(size: 11)).textSelection(.enabled)
                Spacer()
                Text(document.isDirty ? "未上传修改" : "已同步").font(.system(size: 11)).foregroundStyle(DockTheme.secondary)
                if document.conflict { Button("覆盖远端…") { askingOverwrite = true }.buttonStyle(DockButtonStyle()) }
            }.padding(10)
        }.background(DockTheme.surface).foregroundStyle(DockTheme.text).tint(DockTheme.accent)
        .alert("重新载入将放弃当前修改", isPresented: $askingReload) {
            Button("取消", role: .cancel) {}
            Button("重新载入", role: .destructive) { Task { await document.reload() } }
        }
        .alert("确认覆盖服务器上的新版本？", isPresented: $askingOverwrite) {
            Button("取消", role: .cancel) {}
            Button("覆盖并保留备份", role: .destructive) { Task { await document.save(overwrite: true) } }
        }
        .alert("另存为同目录文件", isPresented: $askingSaveAs) {
            TextField("文件名", text: $filename)
            Button("取消", role: .cancel) {}
            Button("保存") {
                Task {
                    do {
                        let path = try FilePath.join(FilePath.parent(document.path), name: filename)
                        guard !RemoteEditors.shared.contains(identity: document.identity, path: path) else { throw HostDockError("该文件已在其他编辑窗口中打开。") }
                        await document.save(as: path)
                    } catch { document.report(error) }
                }
            }
        }
    }
}

private struct EditorText: NSViewRepresentable {
    @ObservedObject var document: RemoteDocument
    func makeCoordinator() -> Coordinator { Coordinator(document) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        let text = NSTextView(frame: .zero)
        text.isRichText = false; text.allowsUndo = true; text.usesFindBar = true; text.isIncrementalSearchingEnabled = true
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false
        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.textColor = DockTheme.textNS; text.backgroundColor = DockTheme.surfaceNS
        text.textContainerInset = NSSize(width: 16, height: 16)
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.string = document.text; text.delegate = context.coordinator
        scroll.documentView = text
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        if text.string != document.text { text.string = document.text }
        text.isEditable = !document.isClosing
        text.textColor = DockTheme.textNS; text.backgroundColor = DockTheme.surfaceNS
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        let document: RemoteDocument
        init(_ document: RemoteDocument) { self.document = document }
        func textDidChange(_ notification: Notification) {
            if let text = notification.object as? NSTextView { document.text = text.string }
        }
    }
}
