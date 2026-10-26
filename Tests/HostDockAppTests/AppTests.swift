import AppKit
import Foundation
import HostDockCore
import Testing
@testable import HostDock

@MainActor
@Test func themesKeepTextReadableInBothAppearances() throws {
    func luminance(_ color: NSColor) -> CGFloat {
        let rgb = color.usingColorSpace(.sRGB)!
        let values = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map {
            $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
        }
        return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722
    }
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            for foreground in [DockTheme.textNS, DockTheme.secondaryNS] {
                for background in [DockTheme.surfaceNS, DockTheme.backgroundNS] {
                    let values = [luminance(foreground), luminance(background)].sorted()
                    #expect((values[1] + 0.05) / (values[0] + 0.05) >= 4.5)
                }
            }
        }
    }
}

@MainActor
@Test func unfinishedOrFailedNavigationCannotChangeTransferDestination() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hostdock-app-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let browser = BrowserModel()
    await browser.attach(store: LocalFileStore(), home: root.path)
    let opened = browser.path
    #expect(browser.directoryReady)
    browser.pathDraft = opened + "/missing"
    #expect(!browser.directoryReady)
    await browser.navigate(to: browser.pathDraft)
    #expect(browser.error != nil)
    #expect(browser.path == opened)
    #expect(browser.pathDraft == opened)
    #expect(browser.directoryReady)
    browser.clear()
    #expect(!browser.directoryReady)
    #expect(browser.roots.isEmpty)
}

@MainActor
@Test func terminalHandlesTextControlCAndResizeWithoutGlobalInput() throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let terminal = TerminalController()
    var input = Data()
    var resized: (Int, Int)?
    terminal.onInput = { input.append($0) }
    terminal.onResize = { resized = ($0, $1) }
    let view = terminal.view
    view.insertText("ignored" as NSString, replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(input.isEmpty)
    terminal.ready = true
    view.insertText("echo 测试" as NSString, replacementRange: NSRange(location: NSNotFound, length: 0))
    let interrupt = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
        timestamp: 0, windowNumber: 0, context: nil, characters: "\u{03}",
        charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
    view.keyDown(with: interrupt)
    #expect(input == Data("echo 测试\u{03}".utf8))
    view.setFrameSize(NSSize(width: 640, height: 180))
    let before = (terminal.columns, terminal.rows)
    view.setFrameSize(NSSize(width: 1024, height: 300))
    #expect(terminal.columns > before.0)
    #expect(terminal.rows > before.1)
    #expect(resized?.0 == terminal.columns)
    #expect(resized?.1 == terminal.rows)
    terminal.feed(Data("HOSTDOCK_RENDER_OK\r\n".utf8))
    #expect(String(decoding: view.getBufferAsData(), as: UTF8.self).contains("HOSTDOCK_RENDER_OK"))
    terminal.applyAppearance(dark: true)
    let darkBackground = try #require(view.nativeBackgroundColor.usingColorSpace(.sRGB))
    terminal.applyAppearance(dark: false)
    let lightBackground = try #require(view.nativeBackgroundColor.usingColorSpace(.sRGB))
    #expect(darkBackground.redComponent < 0.2 && lightBackground.redComponent > 0.9)
}
