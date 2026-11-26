import AppKit
import SwiftUI

/// A native drag source can offer a separate file promise for every selected phone row.
struct DeviceFileTable: NSViewRepresentable {
    let model: AppModel
    let items: [BrowserItem]
    @Binding var selection: Set<String>
    let titles: [String]
    let open: (Set<String>) -> Void
    let menu: (Set<String>) -> NSMenu

    private enum Column: String, CaseIterable {
        case name, size, date

        var comparator: KeyPathComparator<BrowserItem> {
            switch self {
            case .name: return BrowserItem.defaultSortOrder[0]
            case .size: return KeyPathComparator(\BrowserItem.sortSize)
            case .date: return KeyPathComparator(\BrowserItem.sortDate)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = PhoneTableView()
        table.style = .inset
        table.allowsMultipleSelection = true
        table.allowsTypeSelect = true
        table.rowSizeStyle = .medium
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        for (column, widths) in zip(Column.allCases, [(140, 220), (60, 80), (120, 160)]) {
            let field = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            field.minWidth = CGFloat(widths.0)
            field.width = CGFloat(widths.1)
            field.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: true)
            table.addTableColumn(field)
        }
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openSelection)
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.actions = context.coordinator
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let coordinator = context.coordinator
        coordinator.updating = true
        defer { coordinator.updating = false }
        let changed = coordinator.parent.items != items
        coordinator.parent = self
        for (column, title) in zip(Column.allCases, titles) {
            table.tableColumn(withIdentifier: .init(column.rawValue))?.title = title
        }
        let descriptors = model.device.sortOrder.compactMap { comparator -> NSSortDescriptor? in
            guard let column = Column.allCases.first(where: { $0.comparator.keyPath == comparator.keyPath }) else { return nil }
            return NSSortDescriptor(key: column.rawValue, ascending: comparator.order == .forward)
        }
        if table.sortDescriptors != descriptors { table.sortDescriptors = descriptors }
        if changed || table.numberOfRows != items.count { table.reloadData() }
        let indexes = IndexSet(items.indices.filter { selection.contains(items[$0].id) })
        if table.selectedRowIndexes != indexes { table.selectRowIndexes(indexes, byExtendingSelection: false) }
    }

    final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        var parent: DeviceFileTable
        var updating = false

        init(_ parent: DeviceFileTable) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.items.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let identifier = tableColumn?.identifier, let column = Column(rawValue: identifier.rawValue) else { return nil }
            let item = parent.items[row]
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView) ?? {
                let cell = NSTableCellView()
                cell.identifier = identifier
                let label = NSTextField(labelWithString: "")
                label.lineBreakMode = .byTruncatingMiddle
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(label)
                cell.textField = label
                var leading = cell.leadingAnchor
                if column == .name {
                    let icon = NSImageView()
                    icon.translatesAutoresizingMaskIntoConstraints = false
                    cell.addSubview(icon)
                    cell.imageView = icon
                    NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 16),
                        icon.leadingAnchor.constraint(equalTo: leading), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
                    leading = icon.trailingAnchor
                } else {
                    label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                    label.textColor = .secondaryLabelColor
                }
                NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: leading, constant: column == .name ? 6 : 0),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
                return cell
            }()
            switch column {
            case .name:
                cell.textField?.stringValue = item.name
                cell.imageView?.image = NSImage(systemSymbolName: item.systemImage, accessibilityDescription: nil)
                cell.imageView?.contentTintColor = item.isFolder ? .controlAccentColor : .secondaryLabelColor
                cell.toolTip = item.name
            case .size: cell.textField?.stringValue = item.sizeText
            case .date: cell.textField?.stringValue = item.dateText
            }
            return cell
        }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            parent.items[row].name
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table = notification.object as? NSTableView else { return }
            parent.selection = Set(table.selectedRowIndexes.map { parent.items[$0].id })
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !updating else { return }
            parent.model.device.sortOrder = tableView.sortDescriptors.compactMap { descriptor in
                guard let key = descriptor.key, let column = Column(rawValue: key) else { return nil }
                var comparator = column.comparator
                comparator.order = descriptor.ascending ? .forward : .reverse
                return comparator
            }
        }

        @objc func openSelection() { parent.open(parent.selection) }

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            parent.model.filePromise(for: parent.items[row])
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
            parent.model.beginDeviceDrag(sequence: session.draggingSequenceNumber, items: rowIndexes.map { parent.items[$0] })
        }

        func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                       endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            parent.model.endDeviceDrag(sequence: session.draggingSequenceNumber)
        }
    }

    final class PhoneTableView: NSTableView {
        weak var actions: Coordinator?

        override func keyDown(with event: NSEvent) {
            if let actions, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                switch event.charactersIgnoringModifiers {
                case " " where actions.parent.model.canPreviewDeviceSelection:
                    actions.parent.model.quickLookSelection(preferDevice: true)
                    return
                case "\r", "\u{3}":
                    actions.openSelection()
                    return
                default: break
                }
            }
            super.keyDown(with: event)
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            guard let actions else { return nil }
            let row = row(at: convert(event.locationInWindow, from: nil))
            guard row >= 0 else { return actions.parent.menu([]) }
            if !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            return actions.parent.menu(actions.parent.selection)
        }
    }
}

/// Present only during a phone drag, leaving normal local table input and accessibility intact.
struct DeviceDownloadDropTarget: NSViewRepresentable {
    let sequence: Int
    let accept: (Int) -> Bool
    @Binding var isTargeted: Bool

    func makeNSView(context: Context) -> Target {
        let view = Target()
        view.registerForDraggedTypes(NSFilePromiseReceiver.readableDraggedTypes.map(NSPasteboard.PasteboardType.init(rawValue:)))
        return view
    }

    func updateNSView(_ view: Target, context: Context) { view.target = self }

    final class Target: NSView {
        var target: DeviceDownloadDropTarget?

        private func matches(_ sender: NSDraggingInfo) -> Bool {
            sender.draggingSource is DeviceFileTable.PhoneTableView && target?.sequence == sender.draggingSequenceNumber
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            let matches = matches(sender)
            target?.isTargeted = matches
            return matches ? .copy : []
        }

        override func draggingExited(_ sender: NSDraggingInfo?) { target?.isTargeted = false }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { matches(sender) }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            target?.isTargeted = false
            return matches(sender) && target?.accept(sender.draggingSequenceNumber) == true
        }
    }
}
