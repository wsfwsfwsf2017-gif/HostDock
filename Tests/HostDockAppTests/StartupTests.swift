import AppKit
import SwiftUI
import Testing
@testable import HostDock

@MainActor
@Test func initialWindowIsPreparedSynchronouslyWithoutAnimation() throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let screens = NSScreen.screens
    let index = WindowPlacement.screen(containing: NSEvent.mouseLocation, screens: screens.map(\.frame)) ?? 0
    let screen = try #require(screens.indices.contains(index) ? screens[index] : nil)
    let window = NSWindow(contentRect: NSRect(x: screen.frame.midX, y: screen.frame.midY, width: 400, height: 300),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.delegate = nil; window.close() }
    let coordinator = WorkspaceWindow.Coordinator()
    coordinator.attach(window)
    #expect(!window.isVisible)
    #expect(window.frame == screen.visibleFrame)
    #expect(window.animationBehavior == .none)
    #expect(!window.isRestorable)
}

@MainActor
@Test func startupPickerWaitsForReadyWindowAndOnlyPresentsOnce() async throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.delegate = nil; window.close() }
    let coordinator = WorkspaceWindow.Coordinator()
    var callbacks = 0
    coordinator.onReady = { callbacks += 1 }
    coordinator.attach(window)
    #expect(callbacks == 0)
    coordinator.didLayout()
    try await Task.sleep(for: .milliseconds(20))
    #expect(callbacks == 1)
    let adjusted = NSRect(x: window.frame.minX + 30, y: window.frame.minY + 30, width: 1050, height: 700)
    window.setFrame(adjusted, display: false)
    coordinator.attach(window)
    coordinator.didLayout()
    try await Task.sleep(for: .milliseconds(20))
    #expect(callbacks == 1 && window.frame == adjusted)
}

@MainActor
@Test func backgroundWindowLayoutPresentsStartupPickerWithoutNeedingFocus() async throws {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.delegate = nil; window.close() }
    var callbacks = 0
    let hosting = NSHostingView(rootView: Color.clear.background(WorkspaceWindow(maximizeRequest: 0, onReady: { callbacks += 1 })))
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    #expect(!window.isKeyWindow && callbacks == 1)
}
