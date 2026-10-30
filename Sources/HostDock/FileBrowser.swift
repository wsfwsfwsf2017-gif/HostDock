import AppKit
import HostDockCore
import SwiftUI

struct FileBrowserPane: View {
    @ObservedObject var model: BrowserModel
    let remote: Bool
    let subtitle: String
    var serverName = "服务器"
    var connect: () -> Void = {}
    var session: SessionModel?

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                HStack(spacing: 9) {
                    Image(systemName: remote ? "server.rack" : "laptopcomputer").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(remote ? serverName : "本机").fontWeight(.semibold).lineLimit(1).help(remote ? serverName : "本机")
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(DockTheme.secondary).lineLimit(1).truncationMode(.middle).help(subtitle)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if model.loading { ProgressView().controlSize(.small) }
                    Menu {
                        if remote {
                            Button("主目录") { Task { await model.navigate(to: model.home) } }
                            Button("SFTP 根目录") { Task { await model.navigate(to: "/") } }
                        } else {
                            ForEach(BrowserModel.localShortcuts, id: \.path) { shortcut in
                                Button(shortcut.name) { Task { await model.navigate(to: shortcut.path) } }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                            if geometry.size.width >= 400 { Text("快捷目录").font(.system(size: 12)) }
                        }.padding(.horizontal, 8).frame(height: 36).contentShape(Rectangle())
                            .background(DockTheme.background, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .menuStyle(.borderlessButton).fixedSize().frame(height: 36).modifier(DockHoverCursor())
                    .help("快捷目录").accessibilityLabel(remote ? "远端快捷目录" : "本机快捷目录")
                    if !remote {
                        Button(action: model.chooseLocalDirectory) { Image(systemName: "folder.badge.gearshape") }
                            .buttonStyle(DockButtonStyle())
                            .help("选择本机目录").accessibilityLabel("选择本机目录")
                    }
                }.font(.system(size: 13)).padding(.horizontal, 16).frame(height: 48)
            }.frame(height: 48).background(DockTheme.surface)
            Divider()
            HStack(spacing: 8) {
                Button { Task { await model.navigate(to: FilePath.parent(model.path)) } } label: {
                    Image(systemName: "arrow.up")
                }.help("返回上级目录").accessibilityLabel("返回上级目录")
                TextField(model.store == nil ? "连接后浏览远端文件" : "输入目录路径", text: $model.pathDraft)
                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                    .onSubmit { Task { await model.navigate(to: model.pathDraft) } }
                    .help("输入目录路径后按回车打开")
                    .accessibilityLabel(remote ? "服务器当前目录" : "本机当前目录")
                if model.pathDraft != model.path {
                    Button("前往") { Task { await model.navigate(to: model.pathDraft) } }.font(.system(size: 11))
                }
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("刷新目录").accessibilityLabel("刷新目录")
            }
            .buttonStyle(.borderless).padding(.horizontal, 12).frame(height: 36)
            .background(DockTheme.background, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 12).padding(.vertical, 12)
            .disabled(model.store == nil || model.loading)
            Divider()
            ZStack {
                FileOutline(model: model, session: session, remote: remote)
                if model.store == nil {
                    ContentUnavailableView {
                        Label("连接你的服务器", systemImage: "server.rack")
                    } description: { Text("通过 SSH 安全浏览和传输文件") }
                    actions: { Button("连接服务器", action: connect).buttonStyle(.borderedProminent) }
                } else if model.roots.isEmpty && !model.loading && model.error == nil {
                    ContentUnavailableView("文件夹为空", systemImage: "folder", description: Text("可将另一侧的文件传入此目录"))
                        .allowsHitTesting(false)
                }
            }
            if let error = model.error {
                Divider()
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                if model.store != nil {
                    Button("打开主目录") { Task { await model.navigate(to: model.home) } }
                        .buttonStyle(DockButtonStyle()).padding(.bottom, 10).disabled(model.loading)
                }
            }
            Divider()
            HStack {
                Text(model.store == nil ? "未连接" : "\(model.roots.count) 个项目")
                Spacer()
                if !model.selection.isEmpty { Text("已选 \(model.selection.count) 项") }
            }.font(.system(size: 11)).foregroundStyle(DockTheme.secondary).padding(.horizontal, 16).frame(height: 30)
        }
        .background(DockTheme.surface)
    }
}

private struct FileOutline: NSViewRepresentable {
    @ObservedObject var model: BrowserModel
    var session: SessionModel?
    var remote: Bool

    func makeCoordinator() -> Coordinator { Coordinator(model: model, session: session, remote: remote) }

    func makeNSView(context: Context) -> FileScrollView {
        let outline = ActionOutline()
        outline.makeMenu = { [weak coordinator = context.coordinator] outline in
            guard let coordinator, let actions = coordinator.actions else { return nil }
            return actions.menu(entries: coordinator.model.selectedEntries, directory: coordinator.model.path, window: outline.window)
        }
        outline.fileKey = { [weak coordinator = context.coordinator] command in
            guard let coordinator, let actions = coordinator.actions else { return }
            actions.window = coordinator.outline?.window
            Task { @MainActor in
                do {
                    switch command {
                    case "c": try actions.putClipboard(coordinator.model.selectedEntries, cut: false)
                    case "x": try actions.putClipboard(coordinator.model.selectedEntries, cut: true)
                    case "v": try await actions.paste(directory: coordinator.model.path)
                    default: break
                    }
                } catch { coordinator.model.report(error) }
            }
        }
        outline.style = .inset
        outline.rowHeight = 31
        outline.backgroundColor = DockTheme.surfaceNS
        outline.intercellSpacing = NSSize(width: 6, height: 0)
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.autoresizesOutlineColumn = false
        let name = NSTableColumn(identifier: .init("name"))
        name.title = "名称"
        name.minWidth = 130
        name.width = 250
        name.resizingMask = .autoresizingMask
        let size = NSTableColumn(identifier: .init("size"))
        size.title = "大小"
        size.width = 76
        size.minWidth = 60
        let modified = NSTableColumn(identifier: .init("modified"))
        modified.title = "修改时间"
        modified.width = 118
        modified.minWidth = 92
        for column in [name, size, modified] {
            column.headerCell.font = .systemFont(ofSize: 11, weight: .medium)
            column.headerCell.textColor = DockTheme.secondaryNS
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = name
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.openDirectory(_:))
        outline.setAccessibilityLabel("文件树，可多选文件或展开文件夹")
        let scroll = FileScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = outline
        scroll.backgroundColor = DockTheme.surfaceNS
        context.coordinator.outline = outline
        return scroll
    }

    func updateNSView(_ scroll: FileScrollView, context: Context) {
        let coordinator = context.coordinator
        guard coordinator.revision != model.revision, let outline = coordinator.outline else { return }
        let firstLoad = coordinator.revision < 0
        let sameDirectory = coordinator.directoryID == model.directoryID
        coordinator.revision = model.revision
        coordinator.directoryID = model.directoryID
        var expanded = model.expandedPaths
        for row in 0..<outline.numberOfRows where sameDirectory {
            if let node = outline.item(atRow: row) as? FileNode, outline.isItemExpanded(node) {
                expanded.insert(node.entry.path)
            }
        }
        let selection = model.selection
        let origin = firstLoad || !sameDirectory ? model.scrollOrigin : scroll.contentView.bounds.origin
        coordinator.reloading = true
        outline.reloadData()
        func restore(_ nodes: [FileNode]) {
            for node in nodes where expanded.contains(node.entry.path) {
                outline.expandItem(node)
                restore(node.children ?? [])
            }
        }
        restore(model.roots)
        var indexes = IndexSet()
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? FileNode, selection.contains(node.entry.path) { indexes.insert(row) }
        }
        outline.selectRowIndexes(indexes, byExtendingSelection: false)
        scroll.restoreViewport(to: origin)
        scroll.layoutSubtreeIfNeeded()
        coordinator.reloading = false
    }

    static func dismantleNSView(_ scroll: FileScrollView, coordinator: Coordinator) {
        guard coordinator.directoryID == coordinator.model.directoryID else { return }
        coordinator.model.scrollOrigin = scroll.pendingOrigin ?? scroll.contentView.bounds.origin
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        let model: BrowserModel
        let actions: FileActions?
        weak var outline: NSOutlineView?
        var revision = -1
        var directoryID: UUID?
        var reloading = false
        private let dateFormat: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm"
            return formatter
        }()
        init(model: BrowserModel, session: SessionModel?, remote: Bool) {
            self.model = model
            actions = session.map { FileActions(session: $0, remote: remote) }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? FileNode)?.children?.count ?? (item == nil ? model.roots.count : 0)
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? FileNode)?.children?[index] ?? model.roots[index]
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? FileNode)?.entry.kind == .directory
        }
        func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
            return true
        }
        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { FileRowView() }
        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !reloading, let node = notification.userInfo?["NSObject"] as? FileNode else { return }
            model.expandedPaths.insert(node.entry.path)
            model.expand(node)
        }
        func outlineViewItemDidCollapse(_ notification: Notification) {
            if !reloading, let node = notification.userInfo?["NSObject"] as? FileNode { model.expandedPaths.remove(node.entry.path) }
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !reloading, let outline else { return }
            model.selection = Set(outline.selectedRowIndexes.compactMap {
                (outline.item(atRow: $0) as? FileNode)?.entry.path
            })
        }
        @objc func openDirectory(_ sender: NSOutlineView) {
            guard sender.clickedRow >= 0, let node = sender.item(atRow: sender.clickedRow) as? FileNode,
                  node.entry.kind == .directory else { return }
            Task { await model.navigate(to: node.entry.path) }
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor column: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? FileNode, let column else { return nil }
            let entry = node.entry
            let isName = column.identifier.rawValue == "name"
            let identifier = NSUserInterfaceItemIdentifier(column.identifier.rawValue + "Cell")
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? FileCellView) ?? FileCellView(nameColumn: isName)
            cell.identifier = identifier
            if isName {
                let symbol = entry.kind == .directory ? "folder.fill" : entry.kind == .symbolicLink ? "link" : "doc"
                cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                cell.iconColor = entry.kind == .directory ? DockTheme.accentNS : DockTheme.secondaryNS
                cell.textField?.stringValue = entry.name
                cell.toolTip = entry.path + (entry.kind == .symbolicLink ? "（符号链接，传输时跳过）" : "")
            } else if column.identifier.rawValue == "size" {
                cell.textField?.alignment = .right
                cell.textField?.stringValue = entry.kind == .file ? ByteCountFormatter.string(fromByteCount: Int64(clamping: entry.size), countStyle: .file) : "—"
            } else { cell.textField?.stringValue = entry.modified.map(dateFormat.string) ?? "—" }
            cell.refreshColors()
            return cell
        }
    }
}

private final class FileRowView: NSTableRowView {
    override var isSelected: Bool { didSet { refreshCells() } }
    override var isEmphasized: Bool { didSet { refreshCells() } }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshCells() }
    private func refreshCells() { subviews.compactMap { $0 as? FileCellView }.forEach { $0.refreshColors() } }
}

private final class FileCellView: NSTableCellView {
    let nameColumn: Bool
    var iconColor = DockTheme.secondaryNS
    override var backgroundStyle: NSView.BackgroundStyle { didSet { refreshColors() } }
    init(nameColumn: Bool) {
        self.nameColumn = nameColumn
        super.init(frame: .zero)
        let text = NSTextField(labelWithString: "")
        text.font = nameColumn ? .systemFont(ofSize: 13) : .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        text.lineBreakMode = nameColumn ? .byTruncatingMiddle : .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false; addSubview(text); textField = text
        if nameColumn {
            let icon = NSImageView(); icon.translatesAutoresizingMaskIntoConstraints = false; addSubview(icon); imageView = icon
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor), icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            ])
        } else { text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3).isActive = true }
        NSLayoutConstraint.activate([text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3), text.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); refreshColors() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshColors() }
    func refreshColors() {
        let row = superview as? NSTableRowView
        let selected = backgroundStyle == .emphasized || row?.isSelected == true
        let color = selected ? (backgroundStyle == .emphasized || row?.isEmphasized == true ? NSColor.alternateSelectedControlTextColor : .unemphasizedSelectedTextColor)
            : nameColumn ? DockTheme.textNS : DockTheme.secondaryNS
        textField?.textColor = color
        imageView?.contentTintColor = selected ? color : iconColor
    }
}

private final class ActionOutline: NSOutlineView {
    var makeMenu: ((NSOutlineView) -> NSMenu?)?
    var fileKey: ((String) -> Void)?
    override func layout() {
        super.layout()
        updateColumnVisibility(width: enclosingScrollView?.contentSize.width ?? bounds.width)
    }
    func updateColumnVisibility(width: CGFloat) {
        for column in tableColumns {
            let hidden = column.identifier.rawValue == "size" ? width < 420 : column.identifier.rawValue == "modified" && width < 340
            if column.isHidden != hidden { column.isHidden = hidden }
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let index = row(at: convert(event.locationInWindow, from: nil))
        if index < 0 { deselectAll(nil) }
        else if !selectedRowIndexes.contains(index) { selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        window?.makeFirstResponder(self)
        return makeMenu?(self)
    }
    @objc func copy(_ sender: Any?) { fileKey?("c") }
    @objc func cut(_ sender: Any?) { fileKey?("x") }
    @objc func paste(_ sender: Any?) { fileKey?("v") }
}

private final class FileScrollView: NSScrollView {
    private(set) var pendingOrigin: NSPoint?
    func restoreViewport(to origin: NSPoint) {
        // 重载时可能仍是零尺寸，等表格完成布局后再约束并恢复位置。
        pendingOrigin = origin
        needsLayout = true
    }
    override func layout() {
        super.layout()
        guard let origin = pendingOrigin, contentView.bounds.width > 0, contentView.bounds.height > 0 else { return }
        pendingOrigin = nil
        let target = contentView.constrainBoundsRect(NSRect(origin: origin, size: contentView.bounds.size))
        contentView.scroll(to: target.origin)
        reflectScrolledClipView(contentView)
    }
    override func scrollWheel(with event: NSEvent) {
        pendingOrigin = nil
        super.scrollWheel(with: event)
    }
    override func tile() {
        super.tile()
        (documentView as? ActionOutline)?.updateColumnVisibility(width: contentSize.width)
    }
}
