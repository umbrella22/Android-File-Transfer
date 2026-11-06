import AppKit
import SwiftUI

/// Observes double-clicks on the file tables without consuming the event.
///
/// Cell-level SwiftUI tap gestures fight with single-click selection and
/// `.onDrag`, and a table reference captured at layout time can be stale.
/// This monitor resolves the clicked table from the hit-test chain on demand,
/// so selection, drag, keyboard navigation and multi-selection stay native.
struct TableDoubleClickMonitor: NSViewRepresentable {
    let onDoubleClick: (Bool, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDoubleClick: onDoubleClick)
    }

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        context.coordinator.view = view
        view.onWindowChanged = { [weak coordinator = context.coordinator] in
            coordinator?.attachIfNeeded()
        }
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        context.coordinator.onDoubleClick = onDoubleClick
        context.coordinator.attachIfNeeded()
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class MonitorView: NSView {
        var onWindowChanged: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChanged?()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }

    final class Coordinator {
        var onDoubleClick: (Bool, Int) -> Void
        weak var view: NSView?
        private var monitor: Any?
        private weak var window: NSWindow?

        init(onDoubleClick: @escaping (Bool, Int) -> Void) {
            self.onDoubleClick = onDoubleClick
        }

        func attachIfNeeded() {
            guard let window = view?.window else { return }
            self.window = window
            guard monitor == nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(
                matching: .leftMouseDown
            ) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        func detach() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func handle(_ event: NSEvent) {
            guard event.clickCount == 2,
                  let window,
                  event.window === window,
                  let content = window.contentView
            else { return }

            let contentPoint = content.convert(event.locationInWindow, from: nil)
            guard let hit = content.hitTest(contentPoint) else { return }

            var ancestor: NSView? = hit
            while let current = ancestor, !(current is NSTableView) {
                ancestor = current.superview
            }
            guard let table = ancestor as? NSTableView,
                  table.numberOfColumns >= 2
            else { return }

            let point = table.convert(event.locationInWindow, from: nil)
            guard table.bounds.contains(point) else { return }
            let row = table.row(at: point)
            guard row >= 0 else { return }

            let frame = table.convert(table.bounds, to: nil)
            let isLocal = frame.midX < window.frame.width / 2
            DispatchQueue.main.async { [weak self] in
                self?.onDoubleClick(isLocal, row)
            }
        }
    }
}
