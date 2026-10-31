import AppKit
import SwiftUI
import Testing
@testable import HostDock
@testable import SwiftTerm

@MainActor
private struct TerminalFixture {
    let terminal: TerminalController
    let window: NSWindow
    private let clipboard: [NSPasteboardItem]

    init(readOnly: Bool = false) {
        _ = NSApplication.shared
        clipboard = (NSPasteboard.general.pasteboardItems ?? []).map { original in
            let item = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { item.setData(data, forType: type) }
            }
            return item
        }
        terminal = TerminalController(readOnly: readOnly)
        terminal.ready = true
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = terminal.view
        window.contentView?.layoutSubtreeIfNeeded()
        window.makeFirstResponder(terminal.view)
    }

    func close() {
        window.close()
        NSPasteboard.general.clearContents()
        if !clipboard.isEmpty { NSPasteboard.general.writeObjects(clipboard) }
    }

    func clipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func mouse(_ type: NSEvent.EventType, col: Int = 2, row: Int = 0, count: Int = 1, in target: SessionTerminalView? = nil) throws -> NSEvent {
        let view = target ?? terminal.view
        let point = NSPoint(x: (CGFloat(col) + 0.4) * view.cellDimension.width,
                            y: view.bounds.height - (CGFloat(row) + 0.5) * view.cellDimension.height)
        return try #require(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: view.window?.windowNumber ?? window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1))
    }

    func select(count: Int) throws {
        terminal.view.mouseDown(with: try mouse(.leftMouseDown, count: count))
        terminal.view.mouseUp(with: try mouse(.leftMouseUp, count: count))
    }
}

@Suite(.serialized)
@MainActor
struct TerminalInteractionTests {
    @Test func mouseSelectionCopiesOnReleaseButEmptyClickOutputAndFindDoNot() throws {
        let fixture = TerminalFixture(); defer { fixture.close() }
        let view = fixture.terminal.view
        fixture.terminal.feed(Data("alpha beta\r\nsecond line\r\n".utf8))
        fixture.clipboard("UNCHANGED")
        view.mouseDown(with: try fixture.mouse(.leftMouseDown, col: 0))
        view.mouseDragged(with: try fixture.mouse(.leftMouseDragged, col: 5))
        #expect(NSPasteboard.general.string(forType: .string) == "UNCHANGED")
        view.mouseUp(with: try fixture.mouse(.leftMouseUp, col: 5))
        #expect(NSPasteboard.general.string(forType: .string) == view.getSelection())
        #expect(view.getSelection() == "alpha")
        fixture.clipboard("WORD")
        try fixture.select(count: 2)
        #expect(NSPasteboard.general.string(forType: .string) == "alpha")
        fixture.clipboard("LINE")
        try fixture.select(count: 3)
        #expect(NSPasteboard.general.string(forType: .string)?.contains("alpha beta") == true)
        fixture.clipboard("KEEP")
        view.mouseDown(with: try fixture.mouse(.leftMouseDown, col: 25, row: 4))
        view.mouseUp(with: try fixture.mouse(.leftMouseUp, col: 25, row: 4))
        fixture.terminal.feed(Data("more output\r\n".utf8))
        _ = view.findNext("alpha")
        #expect(NSPasteboard.general.string(forType: .string) == "KEEP")
    }

    @Test func rightClickPastesExactlyOnceInNormalAndRemoteMouseModes() async throws {
        let fixture = TerminalFixture(); defer { fixture.close() }
        let terminal = fixture.terminal, view = terminal.view
        var received = Data()
        terminal.onInput = { received.append($0) }
        for mode in ["", "\u{1b}[?1000h", "\u{1b}[?1002h"] {
            terminal.reset(); terminal.feed(Data(mode.utf8))
            fixture.clipboard("first\nsecond")
            received = Data()
            view.rightMouseDown(with: try fixture.mouse(.rightMouseDown))
            view.rightMouseDragged(with: try fixture.mouse(.rightMouseDragged, col: 6))
            view.rightMouseUp(with: try fixture.mouse(.rightMouseUp, col: 6))
            try await Task.sleep(for: .milliseconds(20))
            #expect(received == Data("first\rsecond".utf8))
            #expect(fixture.window.firstResponder === view)
            terminal.feed(Data("\u{1b}[?2004h".utf8))
            received = Data()
            view.rightMouseDown(with: try fixture.mouse(.rightMouseDown))
            view.rightMouseUp(with: try fixture.mouse(.rightMouseUp))
            try await Task.sleep(for: .milliseconds(20))
            #expect(received == Data("\u{1b}[200~first\nsecond\u{1b}[201~".utf8))
            received = Data()
            view.paste(NSNull())
            try await Task.sleep(for: .milliseconds(20))
            #expect(received == Data("\u{1b}[200~first\nsecond\u{1b}[201~".utf8))
            fixture.clipboard("")
            received = Data()
            view.rightMouseDown(with: try fixture.mouse(.rightMouseDown))
            view.rightMouseUp(with: try fixture.mouse(.rightMouseUp))
            try await Task.sleep(for: .milliseconds(20))
            #expect(!String(decoding: received, as: UTF8.self).contains("\u{1b}[<"))
        }
    }

    @Test func commonKeysReachTheTerminalAndReadOnlyNeverSendsInput() throws {
        for readOnly in [false, true] {
            let fixture = TerminalFixture(readOnly: readOnly); defer { fixture.close() }
            let terminal = fixture.terminal, view = terminal.view
            var received = Data()
            terminal.onInput = { received.append($0) }
            let cases: [(UInt16, String, NSEvent.ModifierFlags, String)] = [
                (48, "\t", [], "\t"), (126, "\u{f700}", [], "\u{1b}[A"), (125, "\u{f701}", [], "\u{1b}[B"),
                (123, "\u{f702}", [], "\u{1b}[D"), (124, "\u{f703}", [], "\u{1b}[C"),
                (51, "\u{7f}", [], "\u{7f}"), (117, "\u{f728}", [], "\u{1b}[3~"),
                (115, "\u{f729}", [], "\u{1b}[H"), (119, "\u{f72b}", [], "\u{1b}[F"),
                (8, "c", .control, "\u{03}"), (2, "d", .control, "\u{04}"), (6, "z", .control, "\u{1a}"),
                (37, "l", .control, "\u{0c}"), (15, "r", .control, "\u{12}"), (0, "a", .control, "\u{01}"),
                (14, "e", .control, "\u{05}"), (32, "u", .control, "\u{15}"), (40, "k", .control, "\u{0b}"),
                (13, "w", .control, "\u{17}")
            ]
            for (code, characters, modifiers, expected) in cases {
                received = Data()
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                    timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
                view.keyDown(with: event)
                #expect(received == (readOnly ? Data() : Data(expected.utf8)), "key code \(code)")
                #expect(fixture.window.firstResponder === view)
            }
            received = Data()
            view.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(received.isEmpty)
            view.insertText("中文", replacementRange: NSRange(location: NSNotFound, length: 0))
            #expect(received == (readOnly ? Data() : Data("中文".utf8)))
        }
    }

    @Test func remoteMouseClickDoesNotCopyAnOldFindSelection() async throws {
        let fixture = TerminalFixture(); defer { fixture.close() }
        fixture.terminal.feed(Data("alpha beta\r\n\u{1b}[?1000h".utf8))
        #expect(fixture.terminal.view.findNext("alpha"))
        fixture.clipboard("KEEP")
        var received = Data()
        fixture.terminal.onInput = { received.append($0) }
        fixture.terminal.view.mouseDown(with: try fixture.mouse(.leftMouseDown))
        fixture.terminal.view.mouseUp(with: try fixture.mouse(.leftMouseUp))
        try await Task.sleep(for: .milliseconds(20))
        #expect(NSPasteboard.general.string(forType: .string) == "KEEP")
        #expect(!received.isEmpty)
    }

    @Test func readOnlyCopiesButRightPasteAndResizeNeverReachBackground() async throws {
        let fixture = TerminalFixture(readOnly: true); defer { fixture.close() }
        let terminal = fixture.terminal, view = terminal.view
        terminal.feed(Data("alpha beta\r\n".utf8))
        var forwarded = false
        terminal.onInput = { _ in forwarded = true }
        terminal.onResize = { _, _ in forwarded = true }
        fixture.clipboard("PREVIOUS")
        try fixture.select(count: 2)
        #expect(NSPasteboard.general.string(forType: .string) == "alpha")
        view.rightMouseDown(with: try fixture.mouse(.rightMouseDown))
        view.rightMouseDragged(with: try fixture.mouse(.rightMouseDragged))
        view.rightMouseUp(with: try fixture.mouse(.rightMouseUp))
        view.paste(NSNull())
        terminal.sizeChanged(source: view, newCols: 80, newRows: 20)
        try await Task.sleep(for: .milliseconds(20))
        #expect(!forwarded)
    }

    @Test func commandCopyPasteAndSelectAllStayLocalAndFindUsesTheFocusedTerminal() async throws {
        let fixture = TerminalFixture(); defer { fixture.close() }
        let terminal = fixture.terminal, view = terminal.view
        terminal.feed(Data("needle alpha needle\r\n".utf8))
        var received = Data()
        terminal.onInput = { received.append($0) }
        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu }
        let menu = NSMenu()
        let edit = NSMenuItem(); menu.addItem(edit)
        let submenu = NSMenu(); edit.submenu = submenu
        for (title, action, key) in [("复制", #selector(TerminalView.copy(_:)), "c"),
                                     ("粘贴", #selector(TerminalView.paste(_:)), "v"),
                                     ("全选", #selector(TerminalView.selectAll(_:)), "a")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = view; submenu.addItem(item)
        }
        NSApp.mainMenu = menu
        for (code, text) in [(UInt16(0), "a"), (UInt16(8), "c")] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
            view.keyDown(with: event)
        }
        #expect(NSPasteboard.general.string(forType: .string)?.contains("needle alpha needle") == true)
        #expect(received.isEmpty)
        fixture.clipboard("paste once")
        let paste = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil, characters: "v",
            charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        view.keyDown(with: paste)
        try await Task.sleep(for: .milliseconds(20))
        #expect(received == Data("paste once".utf8))
        received = Data()
        let find = NSMenuItem(); find.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        #expect(NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: view, from: find))
        let bar = try #require(view.subviews.compactMap { $0 as? TerminalFindBarView }.first)
        #expect(!bar.isHidden)
        bar.searchText = "needle"; bar.onSearchChanged?("needle")
        #expect(view.getSelection() == "needle")
        let first = view.selection.start
        bar.onFindNext?()
        #expect(view.selection.start != first)
        bar.onFindPrevious?()
        #expect(view.selection.start == first)
        bar.onClose?()
        #expect(bar.isHidden && fixture.window.firstResponder === view)
        #expect(received.isEmpty)
        #expect(NSPasteboard.general.string(forType: .string) == "paste once")
    }

    @Test func pasteFollowsClickedSplitPaneAndSurvivesHiddenTabAndModeSwitches() async throws {
        let clipboard = TerminalFixture(); defer { clipboard.close() }
        let fixture = try SessionFixture(); defer { fixture.clean() }
        let transports = [FakeSessionConnection(home: fixture.remote(0)), FakeSessionConnection(home: fixture.remote(1))]
        let app = fixture.app(transports: transports)
        let first = try app.connect(profile: fixture.profiles[0], password: "synthetic", rememberPassword: false)
        let second = try app.connect(profile: fixture.profiles[1], password: "synthetic", rememberPassword: false)
        try await waitUntil { first.terminalReady && second.terminalReady }
        app.setLayout(.dual)
        let hosting = NSHostingView(rootView: WorkspaceView(app: app))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(120)); hosting.layoutSubtreeIfNeeded()
        let directories = [first.remote.path, second.remote.path]
        let slots = app.workspace.slots
        clipboard.clipboard("FIRST_PANE")
        first.terminal.view.rightMouseDown(with: try clipboard.mouse(.rightMouseDown, in: first.terminal.view))
        first.terminal.view.rightMouseUp(with: try clipboard.mouse(.rightMouseUp, in: first.terminal.view))
        try await waitUntil { String(decoding: first.terminal.view.getBufferAsData(), as: UTF8.self).contains("FIRST_PANE") }
        #expect(await transports[0].inputs == [Data("FIRST_PANE".utf8)])
        #expect(app.selectedSessionID == first.id && window.firstResponder === first.terminal.view)
        #expect(await transports[1].inputs.isEmpty)
        app.setLayout(.single); app.selectTab(second.id)
        await transports[0].emit("HIDDEN_OUTPUT\r\n")
        try await waitUntil { String(decoding: first.terminal.view.getBufferAsData(), as: UTF8.self).contains("HIDDEN_OUTPUT") }
        app.selectTab(first.id)
        first.setWorkspaceMode(.files); first.setWorkspaceMode(.terminal)
        try await Task.sleep(for: .milliseconds(120)); hosting.layoutSubtreeIfNeeded()
        clipboard.clipboard("RESTORED_PANE")
        first.terminal.view.paste(NSNull())
        try await waitUntil { String(decoding: first.terminal.view.getBufferAsData(), as: UTF8.self).contains("RESTORED_PANE") }
        #expect(await transports[0].inputs.count == 2)
        #expect(await transports[0].inputs.last == Data("RESTORED_PANE".utf8))
        #expect(await transports[1].inputs.isEmpty)
        #expect([first.remote.path, second.remote.path] == directories)
        #expect(await transports[0].connects == 1)
        #expect(await transports[1].connects == 1)
        app.setLayout(.dual)
        #expect(Set(app.workspace.slots.compactMap { $0 }) == Set(slots.compactMap { $0 }))
        await app.shutdown()
    }
}
