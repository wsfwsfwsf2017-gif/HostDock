import AppKit
import Foundation
import HostDockCore
import SwiftUI
import Testing
@testable import HostDock

private func contrast(_ foreground: NSColor, _ background: NSColor) -> CGFloat {
    func luminance(_ color: NSColor) -> CGFloat {
        let rgb = color.usingColorSpace(.sRGB)!
        let values = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map {
            $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
        }
        return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722
    }
    let values = [luminance(foreground), luminance(background)].sorted()
    return (values[1] + 0.05) / (values[0] + 0.05)
}

@Suite(.serialized)
@MainActor
struct AppearanceTests {
    @Test func appearancePreferenceRestoresAllChoicesAndInvalidValuesFollowSystem() throws {
        let fixture = try SessionFixture(); defer { fixture.clean() }
        let suite = "HostDock.AppearanceTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous; defaults.removePersistentDomain(forName: suite) }
        #expect(fixture.app(transports: [], preferences: defaults).appearance == .system)
        defaults.set("unknown", forKey: AppAppearance.preferenceKey)
        #expect(fixture.app(transports: [], preferences: defaults).appearance == .system)
        let app = fixture.app(transports: [], preferences: defaults)
        for choice in AppAppearance.allCases {
            app.appearance = choice
            #expect(defaults.string(forKey: AppAppearance.preferenceKey) == choice.rawValue)
            #expect(fixture.app(transports: [], preferences: defaults).appearance == choice)
            #expect(NSApp.appearance?.name == choice.nsAppearance?.name)
        }
        app.appearance = .system
        #expect(NSApp.appearance == nil)
    }

    @Test func terminalThemeKeepsBufferAndMakesTextCursorAndSelectionReadable() throws {
        _ = NSApplication.shared
        let terminal = TerminalController()
        terminal.feed(Data("PERSISTENT_TERMINAL\r\n\u{1b}[31mANSI_RED\u{1b}[0m\r\n".utf8))
        let before = Data(terminal.view.getBufferAsData())
        for dark in [true, false, true] {
            terminal.applyAppearance(dark: dark)
            #expect(Data(terminal.view.getBufferAsData()) == before)
            #expect(contrast(terminal.view.nativeForegroundColor, terminal.view.nativeBackgroundColor) >= 4.5)
            #expect(contrast(terminal.view.caretColor, terminal.view.nativeBackgroundColor) >= 3)
            #expect(contrast(terminal.view.selectedTextForegroundColor, terminal.view.selectedTextBackgroundColor) >= 4.5)
        }
    }

    @Test func liveThemeSwitchKeepsWindowsSessionsFocusHiddenOutputAndEditorSelection() async throws {
        let fixture = try SessionFixture(); defer { fixture.clean() }
        let suite = "HostDock.AppearanceWindows.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous; defaults.removePersistentDomain(forName: suite) }
        let first = FakeSessionConnection(home: fixture.remote(0)), second = FakeSessionConnection(home: fixture.remote(1))
        let agent = FakeSessionConnection(home: fixture.remote(0))
        let app = fixture.app(transports: [first, second, agent], preferences: defaults)
        let a = try app.connect(profile: fixture.profiles[0], password: "synthetic-only", rememberPassword: true)
        let b = try app.connect(profile: fixture.profiles[1], password: "synthetic-only", rememberPassword: true)
        try await waitUntil { a.terminalReady && b.terminalReady && !a.connecting && !b.connecting }
        let background = try app.connectBackground(profile: a.profile)
        try await waitUntil { background.connected && !background.connecting }
        background.startTerminal()
        try await waitUntil { background.terminalReady }
        a.remote.selection = [fixture.remote(0) + "/payload.txt"]
        await first.emit("VISIBLE_THEME_MARKER\r\n"); await second.emit("HIDDEN_THEME_MARKER\r\n")
        try await waitUntil { String(decoding: a.terminal.view.getBufferAsData(), as: UTF8.self).contains("VISIBLE_THEME_MARKER") }
        try await waitUntil { String(decoding: b.terminal.view.getBufferAsData(), as: UTF8.self).contains("HIDDEN_THEME_MARKER") }
        let document = try RemoteDocument(session: a, path: fixture.remote(0) + "/payload.txt", contents: Data("original".utf8),
                                          drafts: EditDraftStore(directory: fixture.root.appendingPathComponent("drafts")))
        document.text = "unsaved 中文 draft"
        func window<V: View>(_ view: V, width: CGFloat = 1100) -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = NSHostingView(rootView: view)
            return window
        }
        let main = window(WorkspaceView(app: app)), settings = window(AppSettingsView(app: app), width: 560), editor = window(RemoteEditorView(document: document))
        defer { main.close(); settings.close(); editor.close() }
        func layout() async throws {
            try await Task.sleep(for: .milliseconds(120))
            for window in [main, settings, editor] { window.contentView?.layoutSubtreeIfNeeded() }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for layoutMode in [WorkspaceLayout.dual, .single] {
            app.setLayout(layoutMode); app.selectTab(a.id)
            try await layout()
            #expect(main.makeFirstResponder(a.terminal.view))
            let focused = main.firstResponder, slots = app.workspace.slots, selected = app.selectedSessionID
            let text = try #require(descendants(editor.contentView!).compactMap { $0 as? NSTextView }.first { $0.string == document.text })
            text.setSelectedRange(NSRange(location: 2, length: 3))
            let directory = a.remote.path, selection = a.remote.selection
            for appearance in [AppAppearance.dark, .light, .system] {
                app.appearance = appearance
                try await layout()
                let effective = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
                #expect([main, settings, editor].allSatisfy { $0.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == effective })
                #expect(main.firstResponder === focused && app.selectedSessionID == selected && app.workspace.slots == slots)
                #expect(a.remote.path == directory && a.remote.selection == selection)
                #expect(document.text == "unsaved 中文 draft" && document.isDirty && text.selectedRange() == NSRange(location: 2, length: 3))
                #expect(String(decoding: a.terminal.view.getBufferAsData(), as: UTF8.self).contains("VISIBLE_THEME_MARKER"))
                #expect(contrast(a.terminal.view.nativeForegroundColor, a.terminal.view.nativeBackgroundColor) >= 4.5)
                #expect((a.terminal.view.nativeBackgroundColor.usingColorSpace(.sRGB)!.redComponent < 0.2) == (effective == .darkAqua))
                main.effectiveAppearance.performAsCurrentDrawingAppearance {
                    #expect(contrast(text.textColor!, text.backgroundColor) >= 4.5)
                }
                #expect(background.terminal.view.window == nil && app.backgroundSessions.count == 1)
            }
        }
        await second.emit("HIDDEN_AFTER_THEME\r\n"); await agent.emit("BACKGROUND_AFTER_THEME\r\n")
        try await waitUntil { String(decoding: b.terminal.view.getBufferAsData(), as: UTF8.self).contains("HIDDEN_AFTER_THEME") }
        try await waitUntil { String(decoding: background.terminal.view.getBufferAsData(), as: UTF8.self).contains("BACKGROUND_AFTER_THEME") }
        app.selectTab(b.id); try await layout()
        #expect(b.terminal.view.window === main)
        #expect(String(decoding: b.terminal.view.getBufferAsData(), as: UTF8.self).contains("HIDDEN_THEME_MARKER"))
        for transport in [first, second, agent] {
            #expect(await transport.connects == 1)
            #expect(await transport.inputs.isEmpty)
        }
        await app.shutdown()
    }
}
