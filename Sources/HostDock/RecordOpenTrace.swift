import AppKit
import SwiftUI

// Each presentation owns its anchor; two popovers can overlap while the first animates out.
struct RecordPopoverAnchor: NSViewRepresentable {
    @MainActor final class Source {
        weak var view: NSView?
        var opening: RecordOpenTrace?
    }
    let source: Source
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        source.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

@MainActor
final class RecordOpenTrace: NSObject {
    let id = UUID()
    private let recordID: UUID
    private let diagnostics: DiagnosticLog
    private weak var window: NSWindow?
    private var seen: Set<DiagnosticEvent> = []

    init(recordID: UUID, window: NSWindow?, diagnostics: DiagnosticLog) {
        self.recordID = recordID
        self.window = window
        self.diagnostics = diagnostics
        super.init()
        if window != nil {
            NotificationCenter.default.addObserver(self, selector: #selector(willClose(_:)),
                                                   name: NSPopover.willCloseNotification, object: nil)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        diagnostics.retireAlias(id)
    }

    @objc private func willClose(_ notification: Notification) {
        guard let window, let popover = notification.object as? NSPopover,
              popover.contentViewController?.viewIfLoaded?.window === window else { return }
        NotificationCenter.default.removeObserver(self, name: NSPopover.willCloseNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didClose(_:)),
                                               name: NSPopover.didCloseNotification, object: popover)
        mark(.popoverWillClose)
    }

    @objc private func didClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: NSPopover.didCloseNotification, object: notification.object)
        mark(.popoverDidClose)
    }

    // Observing a SwiftUI body must not publish a change or log subsequent layout passes.
    func mark(_ event: DiagnosticEvent, focusWindow: DiagnosticFocusWindow? = nil, focusAccepted: Bool? = nil) {
        guard seen.insert(event).inserted else { return }
        diagnostics.record(event, id: recordID, relatedID: id, popoverVisible: window?.isVisible,
                           focusWindow: focusWindow, focusAccepted: focusAccepted, critical: true)
    }

    func focusTarget(_ target: NSWindow?) -> DiagnosticFocusWindow {
        guard let target else { return .noKeyWindow }
        if target === window { return .sourcePopover }
        return target.isMainWindow ? .mainWindow : .otherWindow
    }
}
