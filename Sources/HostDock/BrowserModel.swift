import AppKit
import Combine
import Foundation
import HostDockCore

@MainActor
final class FileNode: NSObject {
    let entry: FileEntry
    var children: [FileNode]?
    var loading = false
    init(_ entry: FileEntry) { self.entry = entry }
}

@MainActor
final class BrowserModel: ObservableObject {
    @Published private(set) var path = ""
    @Published var pathDraft = ""
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var revision = 0
    @Published var selection: Set<String> = []
    var expandedPaths: Set<String> = []
    var scrollOrigin = NSPoint.zero
    private(set) var directoryID = UUID()
    private(set) var roots: [FileNode] = []
    private(set) var store: (any FileStore)?
    private var generation = UUID()
    private(set) var home = ""
    static var localShortcuts: [(name: String, path: String)] {
        var result = [(name: "主目录", path: NSHomeDirectory())]
        for (name, directory) in [("桌面", FileManager.SearchPathDirectory.desktopDirectory), ("下载", .downloadsDirectory), ("文稿", .documentDirectory)] {
            if let url = FileManager.default.urls(for: directory, in: .userDomainMask).first { result.append((name, url.path)) }
        }
        return result
    }
    var directoryReady: Bool { store != nil && !loading && !path.isEmpty && pathDraft == path }
    func report(_ error: Error) { self.error = error.localizedDescription }

    var selectedEntries: [FileEntry] {
        func selected(_ nodes: [FileNode]) -> [FileEntry] {
            nodes.flatMap { node in
                (selection.contains(node.entry.path) ? [node.entry] : []) + selected(node.children ?? [])
            }
        }
        return selected(roots)
    }

    func attach(store: any FileStore, home: String, initialDirectory: String? = nil) async {
        clear()
        self.store = store
        self.home = home
        await navigate(to: initialDirectory ?? home)
    }

    func clear() {
        generation = UUID()
        store = nil
        roots = []
        path = ""
        pathDraft = ""
        home = ""
        loading = false
        error = nil
        selection = []
        expandedPaths = []
        scrollOrigin = .zero
        directoryID = UUID()
        revision += 1
    }

    func navigate(to input: String) async {
        guard let store else { return }
        let token = UUID()
        generation = token
        loading = true
        error = nil
        do {
            let requested: String
            if input == "~" { requested = home }
            else if input.hasPrefix("~/") { requested = home + String(input.dropFirst()) }
            else if input.hasPrefix("/") { requested = input }
            else { requested = (path.isEmpty ? home : path) + "/" + input }
            let canonical = try await store.canonicalDirectory(at: requested)
            let entries = try await store.list(at: canonical)
            guard generation == token else { return }
            if path != canonical {
                selection = []; expandedPaths = []; scrollOrigin = .zero
                directoryID = UUID()
            }
            path = canonical
            pathDraft = canonical
            roots = entries.map(FileNode.init)
            revision += 1
        } catch {
            guard generation == token else { return }
            pathDraft = path.isEmpty ? input : path
            self.error = error.localizedDescription
        }
        if generation == token { loading = false }
    }

    func expand(_ node: FileNode) {
        guard let store, node.entry.kind == .directory, node.children == nil, !node.loading else { return }
        let token = generation
        node.loading = true
        Task {
            do {
                let entries = try await store.list(at: node.entry.path)
                guard generation == token else { return }
                node.children = entries.map(FileNode.init)
            } catch {
                guard generation == token else { return }
                node.children = []
                self.error = "\(node.entry.name)：\(error.localizedDescription)"
            }
            node.loading = false
            revision += 1
        }
    }

    func refresh() async { await navigate(to: path.isEmpty ? pathDraft : path) }

    func chooseLocalDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "打开目录"
        panel.directoryURL = URL(fileURLWithPath: path.isEmpty ? NSHomeDirectory() : path)
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { Task { await self.navigate(to: url.path) } }
            }
        }
    }
}
