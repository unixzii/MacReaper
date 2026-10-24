import AppKit
import ReaperEngine
import SwiftUI
import System

/// The candidates, with a checkbox each for marking them for cleanup.
///
/// An AppKit table: SwiftUI's `Table` diffs and builds a view per row, which froze the window
/// for seconds with a thousand candidates when switching categories or scrolling. `NSTableView`
/// makes views for the visible rows only, and the rows on screen are updated in place.
struct CandidateTable: View {

    let model: ScanModel
    /// ``ScanModel/rows``, which the window works out once for everything that shows them.
    let rows: [CandidateRow]

    var body: some View {
        CandidateTableView(
            model: model,
            rows: rows,
            selection: model.selection,
            sort: model.sort,
            list: CandidateTableController.List(filter: model.filter, searchText: model.searchText, sort: model.sort),
            showsCategory: !model.filter.isCategorized,
            isMeasuring: model.isScanning
        )
    }
}

private struct CandidateTableView: NSViewRepresentable {

    let model: ScanModel
    let rows: [CandidateRow]
    let selection: Set<FilePath>
    let sort: CandidateSort
    let list: CandidateTableController.List
    let showsCategory: Bool
    let isMeasuring: Bool

    func makeCoordinator() -> CandidateTableController {
        CandidateTableController(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(rows: rows, selection: selection, sort: sort, list: list, showsCategory: showsCategory, isMeasuring: isMeasuring)
    }
}

/// Owns the table: answers it from the rows, and passes what the user does back to the model.
final class CandidateTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {

    /// What decides which rows the table lists, and in which order. When it changes, the table
    /// starts again from the top; while it stays, as when a scan adds rows, it keeps its place.
    struct List: Equatable {

        var filter: CandidateFilter
        var searchText: String
        var sort: CandidateSort
    }

    private enum ColumnID {
        static let marked = NSUserInterfaceItemIdentifier("marked")
        static let name = NSUserInterfaceItemIdentifier("name")
        static let size = NSUserInterfaceItemIdentifier("size")
        static let category = NSUserInterfaceItemIdentifier("category")
        static let modified = NSUserInterfaceItemIdentifier("modified")
    }

    let scrollView = NSScrollView()
    private let tableView = CandidateNSTableView()
    private let model: ScanModel
    private var rows: [CandidateRow] = []
    private var isMeasuring = false
    private var list: List?
    /// Set while the table is changed to match the model, so the change isn't sent back.
    private var isApplyingModel = false
    /// File icons by path; `NSWorkspace` reads the file system for each.
    private var icons: [FilePath: NSImage] = [:]
    /// What the context menu's items do, by their tags.
    private var menuActions: [() -> Void] = []

    private static let dateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        return formatter
    }()

    init(model: ScanModel) {
        self.model = model
        super.init()

        tableView.style = .inset
        tableView.rowHeight = 32
        tableView.intercellSpacing = NSSize(width: 8, height: 4)
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(revealClicked)
        tableView.onSpace = { [weak self] in self?.toggleSelectedMarks() }
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        addColumn(ColumnID.marked, title: "", width: 20, sortable: false)
        tableView.tableColumns[0].resizingMask = []
        addColumn(ColumnID.name, title: String(localized: "Name"), width: 240, minWidth: 160)
        addColumn(ColumnID.category, title: String(localized: "Category"), width: 130, minWidth: 80)
        addColumn(ColumnID.size, title: String(localized: "Size"), width: 90, minWidth: 70)
        tableView.tableColumns[3].headerCell.alignment = .right
        addColumn(ColumnID.modified, title: String(localized: "Modified"), width: 110, minWidth: 70)
        // Widths and order are saved by AppKit, across launches.
        tableView.autosaveName = "CandidateTable"
        tableView.autosaveTableColumns = true

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
    }

    private func addColumn(_ id: NSUserInterfaceItemIdentifier, title: String, width: CGFloat, minWidth: CGFloat? = nil, sortable: Bool = true) {
        let column = NSTableColumn(identifier: id)
        column.title = title
        column.width = width
        column.minWidth = minWidth ?? width
        if sortable {
            // Sizes start largest first; the rest start in ascending order.
            column.sortDescriptorPrototype = NSSortDescriptor(key: id.rawValue, ascending: id != ColumnID.size)
        }
        tableView.addTableColumn(column)
    }

    // MARK: Updating from the model

    func update(rows: [CandidateRow], selection: Set<FilePath>, sort: CandidateSort, list: List, showsCategory: Bool, isMeasuring: Bool) {
        isApplyingModel = true
        defer { isApplyingModel = false }

        self.rows = rows
        self.isMeasuring = isMeasuring
        // Before anything else: showing or hiding a column, among other changes, makes the table
        // fill in cells for the rows it believes it has, and it must not ask for rows that are gone.
        tableView.noteNumberOfRowsChanged()
        tableView.tableColumn(withIdentifier: ColumnID.category)?.isHidden = !showsCategory
        // An empty table shows only the message over it, without stripes for rows it lacks.
        tableView.usesAlternatingRowBackgroundColors = !rows.isEmpty
        let descriptor = NSSortDescriptor(key: sort.column.rawValue, ascending: sort.ascending)
        if tableView.sortDescriptors != [descriptor] {
            tableView.sortDescriptors = [descriptor]
        }
        // Not reloadData: after it, the table makes every visible cell anew instead of reusing
        // them, about a hundred views on each switch between categories. The cells on screen
        // are updated instead, and the table asks for new ones only as rows come into view.
        tableView.enumerateAvailableRowViews { rowView, index in
            guard rows.indices.contains(index) else {
                return
            }
            for column in 0..<rowView.numberOfColumns {
                if let cell = rowView.view(atColumn: column) as? NSView {
                    configure(cell, as: tableView.tableColumns[column].identifier, for: rows[index])
                }
            }
        }

        if list != self.list {
            self.list = list
            if !rows.isEmpty {
                tableView.scrollRowToVisible(0)
            }
        }

        var selected = IndexSet()
        for (index, row) in rows.enumerated() where selection.contains(row.id) {
            selected.insert(index)
        }
        if selected != tableView.selectedRowIndexes {
            tableView.selectRowIndexes(selected, byExtendingSelection: false)
        }
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard let id = tableColumn?.identifier, rows.indices.contains(index) else {
            return nil
        }
        let cell: NSView? = tableView.makeView(withIdentifier: id, owner: self) ?? {
            let cell: NSView? = switch id {
            case ColumnID.marked: MarkCell(target: self, action: #selector(markToggled(_:)))
            case ColumnID.name: NameCell()
            case ColumnID.size: SizeCell()
            case ColumnID.category, ColumnID.modified: TextCell()
            default: nil
            }
            cell?.identifier = id
            return cell
        }()
        if let cell {
            configure(cell, as: id, for: rows[index])
        }
        return cell
    }

    /// Shows `row` in a cell of the column `id`.
    private func configure(_ cell: NSView, as id: NSUserInterfaceItemIdentifier, for row: CandidateRow) {
        switch (id, cell) {
        case (ColumnID.marked, let cell as MarkCell):
            cell.checkbox.state = row.isMarked ? .on : .off
            cell.checkbox.toolTip = row.isMarked ? String(localized: "Marked for cleanup") : String(localized: "Not marked for cleanup")
        case (ColumnID.name, let cell as NameCell):
            cell.imageView?.image = icon(for: row.claim.path)
            cell.textField?.stringValue = row.name
            cell.location.stringValue = row.location
            cell.toolTip = row.claim.path.string
        case (ColumnID.size, let cell as SizeCell):
            cell.show(row.claim.size, isMeasuring: isMeasuring)
        case (ColumnID.category, let cell as TextCell):
            cell.textField?.stringValue = row.categoryTitle
        case (ColumnID.modified, let cell as TextCell):
            cell.textField?.stringValue = Self.dateFormatter.localizedString(for: row.modified, relativeTo: .now)
            cell.toolTip = row.modified.formatted(date: .long, time: .shortened)
        default:
            break
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isApplyingModel, let descriptor = tableView.sortDescriptors.first,
              let column = descriptor.key.flatMap(CandidateSort.Column.init(rawValue:)) else {
            return
        }
        model.sort = CandidateSort(column: column, ascending: descriptor.ascending)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingModel else {
            return
        }
        model.selection = Set(tableView.selectedRowIndexes.map { rows[$0].id })
    }

    // MARK: Actions

    @objc private func markToggled(_ sender: NSButton) {
        let index = tableView.row(for: sender)
        guard rows.indices.contains(index) else {
            return
        }
        model.setMarked(sender.state == .on, [rows[index].id])
    }

    private func toggleSelectedMarks() {
        if !model.selection.isEmpty {
            model.toggleMarks(model.selection)
        }
    }

    @objc private func revealClicked() {
        let index = tableView.clickedRow
        if rows.indices.contains(index) {
            reveal([rows[index].id])
        }
    }

    /// The rows a context menu acts on: the selection when the click is inside it, otherwise
    /// the clicked row.
    private var menuTargets: Set<FilePath> {
        let index = tableView.clickedRow
        guard rows.indices.contains(index) else {
            return []
        }
        return tableView.selectedRowIndexes.contains(index)
            ? Set(tableView.selectedRowIndexes.map { rows[$0].id })
            : [rows[index].id]
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menuActions = []
        let paths = menuTargets
        guard !paths.isEmpty else {
            return
        }
        addMenuItem(to: menu, String(localized: "Mark")) { [model] in model.setMarked(true, paths) }
        addMenuItem(to: menu, String(localized: "Unmark")) { [model] in model.setMarked(false, paths) }
        menu.addItem(.separator())
        addMenuItem(to: menu, String(localized: "Show in Finder")) { [weak self] in self?.reveal(paths) }
        addMenuItem(to: menu, String(localized: "Copy Path")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(paths.map(\.string).sorted().joined(separator: "\n"), forType: .string)
        }
    }

    private func addMenuItem(to menu: NSMenu, _ title: String, action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(runMenuAction(_:)), keyEquivalent: "")
        item.target = self
        item.tag = menuActions.count
        menuActions.append(action)
        menu.addItem(item)
    }

    @objc private func runMenuAction(_ sender: NSMenuItem) {
        menuActions[sender.tag]()
    }

    private func reveal(_ paths: Set<FilePath>) {
        NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(filePath: $0.string) })
    }

    // MARK: Helpers

    private func icon(for path: FilePath) -> NSImage {
        if let icon = icons[path] {
            return icon
        }
        let icon = NSWorkspace.shared.icon(forFile: path.string)
        icons[path] = icon
        return icon
    }
}

/// A table that toggles the selected rows' marks with Space.
private final class CandidateNSTableView: NSTableView {

    var onSpace: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            onSpace()
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - Cells

private final class MarkCell: NSView {

    let checkbox: NSButton

    init(target: AnyObject, action: Selector) {
        checkbox = NSButton(checkboxWithTitle: "", target: target, action: action)
        super.init(frame: .zero)
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkbox)
        NSLayoutConstraint.activate([
            checkbox.centerXAnchor.constraint(equalTo: centerXAnchor),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}

/// The candidate's icon and name, with the folder it is in below.
private final class NameCell: NSTableCellView {

    let location = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        let icon = NSImageView()
        let name = NSTextField(labelWithString: "")
        name.lineBreakMode = .byTruncatingTail
        location.font = .systemFont(ofSize: NSFont.smallSystemFontSize - 1)
        location.textColor = .secondaryLabelColor
        location.lineBreakMode = .byTruncatingMiddle
        let text = NSStackView(views: [name, location])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        for view in [icon, text] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for label in [name, location] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        imageView = icon
        textField = name
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}

/// One line of text in the secondary color, which every column but Name uses.
private class TextCell: NSTableCellView {

    init(alignment: NSTextAlignment = .left) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: "")
        label.textColor = .secondaryLabelColor
        label.alignment = alignment
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = label
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}

/// A candidate's size, a spinner while the scan measures it, or a dash once it won't be.
private final class SizeCell: TextCell {

    private let spinner = NSProgressIndicator()

    init() {
        super.init(alignment: .right)
        textField?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.trailingAnchor.constraint(equalTo: trailingAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show(_ size: CandidateSize?, isMeasuring: Bool) {
        if let size {
            textField?.stringValue = size.formatted
            toolTip = size.mayFreeLess
                ? String(localized: "Deleting it may free less: some of its files share space with other files.")
                : String(localized: "Deleting it frees this much.")
            spinner.stopAnimation(nil)
        } else if isMeasuring {
            textField?.stringValue = ""
            toolTip = nil
            spinner.startAnimation(nil)
        } else {
            textField?.stringValue = "—"
            toolTip = nil
            spinner.stopAnimation(nil)
        }
    }
}
