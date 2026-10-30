import AppKit
import HostDockCore
import SwiftUI
import Testing
@testable import HostDock

private struct DelayedDirectoryStore: FileStore {
    let base = LocalFileStore()
    let delayedPath: String
    let gate: TestGate
    func canonicalDirectory(at path: String) async throws -> String { try await base.canonicalDirectory(at: path) }
    func list(at path: String) async throws -> [FileEntry] {
        let entries = try await base.list(at: path)
        if path == delayedPath { try await gate.wait() }
        return entries
    }
    func metadata(at path: String) async throws -> FileEntry? { try await base.metadata(at: path) }
    func createDirectory(at path: String) async throws { try await base.createDirectory(at: path) }
    func move(from: String, to: String) async throws { try await base.move(from: from, to: to) }
    func removeFile(at path: String) async throws { try await base.removeFile(at: path) }
    func openReader(at path: String) async throws -> any FileReader { try await base.openReader(at: path) }
    func createWriter(at path: String) async throws -> any FileWriter { try await base.createWriter(at: path) }
}

@Suite(.serialized)
@MainActor
struct BrowserNavigationTests {
    @Test func anOldDirectoryReadCannotResetANewerViewport() async throws {
        let fixture = try SessionFixture(); defer { fixture.clean() }
        let root = URL(fileURLWithPath: fixture.remote(0))
        let child = root.appendingPathComponent("delayed")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let gate = TestGate(), model = BrowserModel()
        await model.attach(store: DelayedDirectoryStore(delayedPath: child.path, gate: gate), home: root.path)
        let old = Task { await model.navigate(to: child.path) }
        for _ in 0..<200 {
            if await gate.entered { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await gate.entered)
        await model.navigate(to: fixture.remote(1))
        let directory = model.directoryID
        model.scrollOrigin = NSPoint(x: 0, y: 300)
        await gate.open(); await old.value
        #expect(model.path == fixture.remote(1) && model.directoryID == directory)
        #expect(model.scrollOrigin.y == 300)
    }

    @Test func newDirectoriesStartAtTopWhileRefreshAndRemountKeepTheViewport() async throws {
        let fixture = try SessionFixture(); defer { fixture.clean() }
        let root = URL(fileURLWithPath: fixture.remote(0))
        let child = root.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        for index in 0..<160 {
            for directory in [root, child] {
                try Data().write(to: directory.appendingPathComponent(String(format: "%03d.txt", index)))
            }
        }
        let model = BrowserModel()
        await model.attach(store: LocalFileStore(), home: root.path)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        func mount() { window.contentView = NSHostingView(rootView: FileBrowserPane(model: model, remote: true, subtitle: "demo")) }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func tree() throws -> NSScrollView {
            try #require(descendants(window.contentView!).compactMap { $0 as? NSScrollView }.first { $0.documentView is NSOutlineView })
        }
        func layout() async throws {
            try await Task.sleep(for: .milliseconds(100))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        func scroll(_ tree: NSScrollView, to y: CGFloat) {
            tree.contentView.scroll(to: NSPoint(x: 0, y: y)); tree.reflectScrolledClipView(tree.contentView)
        }
        mount(); try await layout()
        let first = try tree()
        #expect(first.contentView.bounds.minY < 20)
        scroll(first, to: 500)
        model.selection = [root.appendingPathComponent("030.txt").path]
        await model.refresh(); try await layout()
        #expect(first.contentView.bounds.minY >= 490)
        #expect(model.selection == [root.appendingPathComponent("030.txt").path])

        await model.navigate(to: child.path); try await layout()
        #expect(model.path == child.path)
        #expect(first.contentView.bounds.minY < 20)
        scroll(first, to: 700)
        await model.navigate(to: child.appendingPathComponent("missing").path); try await layout()
        #expect(model.error != nil && model.path == child.path)
        #expect(first.contentView.bounds.minY >= 690)

        window.contentView = nil; try await layout()
        mount(); try await layout()
        let restored = try tree()
        #expect(restored.contentView.bounds.minY >= 690)
        await model.navigate(to: root.path); try await layout()
        #expect(restored.contentView.bounds.minY < 20)
        scroll(restored, to: 900)
        await model.attach(store: LocalFileStore(), home: root.path); try await layout()
        #expect(restored.contentView.bounds.minY < 20)

        scroll(restored, to: 400)
        window.setContentSize(NSSize(width: 800, height: 650)); try await layout()
        #expect(restored.contentView.bounds.minY >= 390)
        model.clear()
        #expect(model.scrollOrigin == .zero)
    }
}
