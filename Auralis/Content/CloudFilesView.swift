//
//  Auralis
//
//  Created by Elsa on 2024/5/6.
//

import Cocoa
import Foundation
import SwiftUI

struct CloudFilesView: View {
    @EnvironmentObject var userInfo: UserInfo
    var onPlay: ((CloudMusicApi.CloudFile) -> Void)?
    var onAddToPlaylist: ((CloudMusicApi.CloudFile) -> Void)?
    var onViewComments: ((CloudMusicApi.CloudFile) -> Void)?
    @State private var cloudFiles: [CloudMusicApi.CloudFile] = []
    @State private var displayedCloudFiles: [CloudMusicApi.CloudFile] = []
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var hasMoreFiles = true
    @State private var searchText = ""
    @State private var allFilesLoaded = false
    @State private var searchDebounceTask: Task<Void, Never>? = nil
    @State private var isFiltering = false
    private let pageSize = 100

    var body: some View {
        Group {
            VStack {
                CloudFileTableView(
                    cloudFiles: displayedCloudFiles,
                    isLoadingMore: isLoadingMore,
                    hasMoreFiles: hasMoreFiles,
                    pageSize: pageSize,
                    isFiltering: isFiltering,
                    onLoadMore: {
                        if hasMoreFiles && !isLoadingMore {
                            Task {
                                await loadMoreFiles()
                            }
                        }
                    },
                    onPlay: onPlay,
                    onAddToPlaylist: onAddToPlaylist,
                    onViewComments: onViewComments
                )

                if isLoading {
                    LoadingIndicatorView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .searchable(text: $searchText, prompt: Text("cloudfiles.search_prompt"))
        .onChange(of: searchText) { _, newValue in
            searchDebounceTask?.cancel()
            let query = newValue
            searchDebounceTask = Task {
                try? await Task.sleep(nanoseconds: 220_000_000)
                if Task.isCancelled { return }

                await MainActor.run {
                    applySearch(query)
                }

                if !query.isEmpty && !allFilesLoaded {
                    await loadAllFilesInBackground()
                }
            }
        }
        .task {
            await loadCloudFiles()
        }
        .onDisappear {
            searchDebounceTask?.cancel()
        }
    }

    private func loadCloudFiles(reset: Bool = false) async {
        if reset {
            DispatchQueue.main.async {
                self.cloudFiles = []
                self.displayedCloudFiles = []
                self.hasMoreFiles = true
                self.allFilesLoaded = false
                self.isFiltering = false
            }
        }

        isLoading = true
        if let files = await CloudMusicApi().user_cloud(limit: pageSize, offset: 0) {
            DispatchQueue.main.async {
                self.cloudFiles = files
                self.displayedCloudFiles = files
                self.hasMoreFiles = files.count == self.pageSize
                self.isLoading = false
                self.allFilesLoaded = files.count < self.pageSize
                self.isFiltering = false
                if !self.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.applySearch(self.searchText)
                }
            }
        } else {
            DispatchQueue.main.async {
                self.cloudFiles = []
                self.displayedCloudFiles = []
                self.hasMoreFiles = false
                self.isLoading = false
                self.allFilesLoaded = true
                self.isFiltering = false
                if !self.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.applySearch(self.searchText)
                }
            }
        }
    }

    private func loadMoreFiles() async {
        guard !isLoadingMore && hasMoreFiles else { return }

        isLoadingMore = true
        let offset = cloudFiles.count

        if let newFiles = await CloudMusicApi().user_cloud(limit: pageSize, offset: offset) {
            DispatchQueue.main.async {
                self.cloudFiles.append(contentsOf: newFiles)
                self.hasMoreFiles = newFiles.count == self.pageSize
                self.isLoadingMore = false
                if newFiles.count < self.pageSize {
                    self.allFilesLoaded = true
                }

                if self.isFiltering {
                    self.applySearch(self.searchText)
                } else {
                    self.displayedCloudFiles.append(contentsOf: newFiles)
                }
            }
        } else {
            DispatchQueue.main.async {
                self.hasMoreFiles = false
                self.isLoadingMore = false
                self.allFilesLoaded = true
            }
        }
    }

    private func loadAllFilesInBackground() async {
        guard !allFilesLoaded else { return }

        while hasMoreFiles {
            await loadMoreFiles()
            // Add a small delay to prevent blocking the UI
            try? await Task.sleep(nanoseconds: 10_000_000)  // 0.01 second
        }
    }

    private func applySearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            displayedCloudFiles = cloudFiles
            isFiltering = false
            return
        }

        let searchLower = trimmed.lowercased()
        let filtered = cloudFiles.filter { file in
            if file.fileName.lowercased().contains(searchLower) { return true }
            if let simpleSong = file.simpleSong,
                let songName = simpleSong.name?.lowercased()
            {
                if songName.contains(searchLower) { return true }
            }
            return false
        }

        displayedCloudFiles = filtered
        isFiltering = true
}
}

// MARK: - Custom NSTableCellView Classes

class CloudFileNameTableCellView: NSTableCellView {
    private let nameLabel = NSTextField()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        nameLabel.isEditable = false
        nameLabel.isBordered = false
        nameLabel.drawsBackground = false
        nameLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        nameLabel.lineBreakMode = .byTruncatingTail

        addSubview(nameLabel)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(with cloudFile: CloudMusicApi.CloudFile) {
        // Replace \n characters and ensure no line breaks
        let cleanFileName = cloudFile.fileName.replacingOccurrences(of: "\n", with: " ")
        nameLabel.stringValue = cleanFileName
        nameLabel.maximumNumberOfLines = 1
    }
}

class CloudFileStatusTableCellView: NSTableCellView {
    private let statusIcon = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        statusIcon.imageScaling = .scaleProportionallyUpOrDown

        addSubview(statusIcon)
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusIcon.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusIcon.widthAnchor.constraint(equalToConstant: 16),
            statusIcon.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    func configure(with cloudFile: CloudMusicApi.CloudFile) {
        if let image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil) {
            statusIcon.image = image
            statusIcon.contentTintColor = NSColor.secondaryLabelColor
        }
    }
}

class CloudFileInfoTableCellView: NSTableCellView {
    private let infoLabel = NSTextField()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        infoLabel.isEditable = false
        infoLabel.isBordered = false
        infoLabel.drawsBackground = false
        infoLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        infoLabel.textColor = NSColor.labelColor
        infoLabel.lineBreakMode = .byTruncatingTail

        addSubview(infoLabel)
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            infoLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            infoLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            infoLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(with cloudFile: CloudMusicApi.CloudFile) {
        if let simpleSong = cloudFile.simpleSong,
            let artistName = simpleSong.ar?.first?.name,
            let albumName = simpleSong.al?.name,
            let name = simpleSong.name
        {
            // Clean up any newline characters and ensure single line display
            let cleanName = name.replacingOccurrences(of: "\n", with: " ")
            let cleanArtist = artistName.replacingOccurrences(of: "\n", with: " ")
            let cleanAlbum = albumName.replacingOccurrences(of: "\n", with: " ")
            infoLabel.stringValue = "\(cleanName) - \(cleanArtist) - \(cleanAlbum)"
        } else {
            infoLabel.stringValue = ""
        }
        infoLabel.maximumNumberOfLines = 1
    }
}

class CloudFileSizeTableCellView: NSTableCellView {
    private let sizeLabel = NSTextField()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        sizeLabel.isEditable = false
        sizeLabel.isBordered = false
        sizeLabel.drawsBackground = false
        sizeLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        sizeLabel.textColor = NSColor.secondaryLabelColor
        sizeLabel.alignment = .right

        addSubview(sizeLabel)
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sizeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            sizeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            sizeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(with cloudFile: CloudMusicApi.CloudFile) {
        sizeLabel.stringValue = cloudFile.parseFileSize()
    }
}

class CloudFileActionTableCellView: NSTableCellView {
    let actionButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        actionButton.isBordered = false
        actionButton.imagePosition = .imageOnly
        actionButton.bezelStyle = .inline
        if let image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil) {
            actionButton.image = image
        }
        actionButton.contentTintColor = NSColor.secondaryLabelColor

        addSubview(actionButton)
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            actionButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionButton.widthAnchor.constraint(equalToConstant: 28),
            actionButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }
}

// MARK: - CloudFile Table View Controller

class CloudFileTableViewController: NSViewController {
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    private enum CellIdentifier {
        static let status = NSUserInterfaceItemIdentifier("CloudStatusCell")
        static let fileName = NSUserInterfaceItemIdentifier("CloudFileNameCell")
        static let info = NSUserInterfaceItemIdentifier("CloudFileInfoCell")
        static let size = NSUserInterfaceItemIdentifier("CloudFileSizeCell")
        static let action = NSUserInterfaceItemIdentifier("CloudFileActionCell")
    }

    var cloudFiles: [CloudMusicApi.CloudFile] = [] {
        didSet {
            let previousCount = oldValue.count
            let newCount = cloudFiles.count

            let isAppending: Bool
            if !isFiltering,
                newCount > previousCount,
                previousCount > 0,
                cloudFiles.prefix(previousCount).enumerated().allSatisfy({ index, element in
                    element.id == oldValue[index].id
                })
            {
                isAppending = true
            } else {
                isAppending = false
            }

            if isAppending {
                let indexSet = IndexSet(integersIn: previousCount..<newCount)
                tableView.beginUpdates()
                tableView.insertRows(at: indexSet, withAnimation: [])
                tableView.endUpdates()
            } else {
                tableView.reloadData()
            }
        }
    }

    var isLoadingMore: Bool = false
    var hasMoreFiles: Bool = true
    var pageSize: Int = 100
    var onLoadMore: (() -> Void)?
    var onPlay: ((CloudMusicApi.CloudFile) -> Void)?
    var onAddToPlaylist: ((CloudMusicApi.CloudFile) -> Void)?
    var onViewComments: ((CloudMusicApi.CloudFile) -> Void)?
    var isFiltering: Bool = false

    // Bottom padding configuration - number of blank rows to add at the bottom
    private let bottomPaddingRows = 3

    override func loadView() {
        view = NSView()
        setupTableView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupColumns()
    }

    private func setupTableView() {
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        // Add scroll notification observer for infinite scrolling
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll(_:)),
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView
        )

        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsColumnSelection = false
        tableView.allowsMultipleSelection = false
        tableView.allowsColumnReordering = false
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowSizeStyle = .default
        tableView.target = self
        tableView.doubleAction = #selector(doubleClickRow(_:))

        view.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func setupColumns() {
        // Status column
        let statusColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
        statusColumn.title = ""
        statusColumn.width = 16
        statusColumn.minWidth = 16
        statusColumn.maxWidth = 16
        statusColumn.resizingMask = []
        tableView.addTableColumn(statusColumn)

        // File Name column
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("fileName"))
        nameColumn.title = LanguageManager.shared.string("cloudfiles.file_name")
        nameColumn.width = 300
        nameColumn.minWidth = 80
        tableView.addTableColumn(nameColumn)

        // Matched Song Info column
        let infoColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("matchedInfo"))
        infoColumn.title = LanguageManager.shared.string("cloudfiles.matched_song")
        infoColumn.width = 300
        infoColumn.minWidth = 80
        tableView.addTableColumn(infoColumn)

        // File Size column
        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("fileSize"))
        sizeColumn.title = LanguageManager.shared.string("cloudfiles.size")
        sizeColumn.width = 80
        sizeColumn.minWidth = 40
        sizeColumn.maxWidth = 100
        tableView.addTableColumn(sizeColumn)

        // Action column (3-dot menu button)
        let actionColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action"))
        actionColumn.title = ""
        actionColumn.width = 32
        actionColumn.minWidth = 32
        actionColumn.maxWidth = 32
        actionColumn.resizingMask = []
        tableView.addTableColumn(actionColumn)
    }

    @objc private func scrollViewDidScroll(_ notification: Notification) {
        guard let scrollView = notification.object as? NSScrollView else { return }

        let visibleRect = scrollView.documentVisibleRect
        // let documentRect = scrollView.documentView?.bounds ?? .zero

        // Calculate remaining rows to trigger loading more aggressively
        let rowHeight: CGFloat = 24  // As defined in heightOfRow
        let totalRows = cloudFiles.count
        let visibleRowsFromTop = Int(visibleRect.minY / rowHeight)
        let visibleRowsCount = Int(visibleRect.height / rowHeight)
        let lastVisibleRow = visibleRowsFromTop + visibleRowsCount

        // Trigger loading when we have pageSize/3 or fewer items remaining
        let remainingRows = totalRows - lastVisibleRow
        let loadThreshold = pageSize / 3  // About 33 items with pageSize = 100
        let shouldLoadMore = remainingRows <= loadThreshold

        if shouldLoadMore && hasMoreFiles && !isLoadingMore {
            onLoadMore?()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - NSTableViewDataSource

extension CloudFileTableViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        // 如果有文件，添加额外的空白行用于底部填充
        let fileCount = cloudFiles.count
        return fileCount > 0 ? fileCount + bottomPaddingRows : 0
    }
}

// MARK: - NSTableViewDelegate

extension CloudFileTableViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        guard !cloudFiles.isEmpty else { return nil }

        // 判断是否为空白填充行
        if row >= cloudFiles.count {
            return NSView()
        }

        let cloudFile = cloudFiles[row]
        guard let identifier = tableColumn?.identifier else { return nil }

        switch identifier.rawValue {
        case "status":
            let cellView: CloudFileStatusTableCellView
            if let reused = tableView.makeView(withIdentifier: CellIdentifier.status, owner: self) as? CloudFileStatusTableCellView {
                cellView = reused
            } else {
                let newView = CloudFileStatusTableCellView()
                newView.identifier = CellIdentifier.status
                cellView = newView
            }
            cellView.configure(with: cloudFile)
            return cellView

        case "fileName":
            let cellView: CloudFileNameTableCellView
            if let reused = tableView.makeView(withIdentifier: CellIdentifier.fileName, owner: self) as? CloudFileNameTableCellView {
                cellView = reused
            } else {
                let newView = CloudFileNameTableCellView()
                newView.identifier = CellIdentifier.fileName
                cellView = newView
            }
            cellView.configure(with: cloudFile)
            return cellView

        case "matchedInfo":
            let cellView: CloudFileInfoTableCellView
            if let reused = tableView.makeView(withIdentifier: CellIdentifier.info, owner: self) as? CloudFileInfoTableCellView {
                cellView = reused
            } else {
                let newView = CloudFileInfoTableCellView()
                newView.identifier = CellIdentifier.info
                cellView = newView
            }
            cellView.configure(with: cloudFile)
            return cellView

        case "fileSize":
            let cellView: CloudFileSizeTableCellView
            if let reused = tableView.makeView(withIdentifier: CellIdentifier.size, owner: self) as? CloudFileSizeTableCellView {
                cellView = reused
            } else {
                let newView = CloudFileSizeTableCellView()
                newView.identifier = CellIdentifier.size
                cellView = newView
            }
            cellView.configure(with: cloudFile)
            return cellView

        case "action":
            let cellView: CloudFileActionTableCellView
            if let reused = tableView.makeView(withIdentifier: CellIdentifier.action, owner: self) as? CloudFileActionTableCellView {
                cellView = reused
            } else {
                let newView = CloudFileActionTableCellView()
                newView.identifier = CellIdentifier.action
                cellView = newView
            }
            cellView.actionButton.target = self
            cellView.actionButton.action = #selector(showActionMenu(_:))
            cellView.actionButton.tag = row
            return cellView

        default:
            return nil
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        return 24
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        // 只允许选中文件行，不允许选中空白填充行
        return row < cloudFiles.count
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = tableView.convert(event.locationInWindow, from: nil)
        let row = tableView.row(at: point)

        guard row >= 0, row < cloudFiles.count else { return }

        // Select the row if it's not already selected
        if !tableView.selectedRowIndexes.contains(row) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }

        let cloudFile = cloudFiles[row]
        let menu = createContextMenu(for: cloudFile, row: row)

        NSMenu.popUpContextMenu(menu, with: event, for: tableView)
    }

    private func createContextMenu(for cloudFile: CloudMusicApi.CloudFile, row: Int) -> NSMenu {
        let menu = NSMenu()

        // Add Play item
        let playItem = NSMenuItem(
            title: LanguageManager.shared.string("playlist.play"),
            action: #selector(playCloudFile(_:)),
            keyEquivalent: ""
        )
        playItem.target = self
        playItem.tag = row
        playItem.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        menu.addItem(playItem)

        return menu
    }

    @objc private func showActionMenu(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < cloudFiles.count else { return }
        let cloudFile = cloudFiles[row]

        let menu = NSMenu()

        let playItem = NSMenuItem(
            title: LanguageManager.shared.string("playlist.play"),
            action: #selector(playCloudFile(_:)),
            keyEquivalent: ""
        )
        playItem.target = self
        playItem.tag = row
        playItem.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        menu.addItem(playItem)

        if cloudFile.simpleSong?.id != nil {
            menu.addItem(.separator())

            let addItem = NSMenuItem(
                title: LanguageManager.shared.string("cloudfiles.add_to_playlist"),
                action: #selector(addToPlaylist(_:)),
                keyEquivalent: ""
            )
            addItem.target = self
            addItem.tag = row
            addItem.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
            menu.addItem(addItem)

            let commentItem = NSMenuItem(
                title: LanguageManager.shared.string("playlist.view_comments"),
                action: #selector(viewComments(_:)),
                keyEquivalent: ""
            )
            commentItem.target = self
            commentItem.tag = row
            commentItem.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: nil)
            menu.addItem(commentItem)
        }

        let frame = tableView.rect(ofRow: row)
        let point = NSPoint(x: frame.maxX - 16, y: frame.midY)
        menu.popUp(positioning: nil, at: point, in: tableView)
    }
}

// MARK: - Context Menu Actions

extension CloudFileTableViewController {
    @objc private func doubleClickRow(_ sender: NSTableView) {
        let row = sender.clickedRow
        guard row >= 0 && row < cloudFiles.count else { return }
        let cloudFile = cloudFiles[row]
        guard cloudFile.simpleSong != nil else { return }
        play(cloudFile)
    }

    @objc private func playCloudFile(_ sender: NSMenuItem) {
        let row = sender.tag
        guard row >= 0 && row < cloudFiles.count else { return }
        play(cloudFiles[row])
    }

    @objc private func addToPlaylist(_ sender: NSMenuItem) {
        let row = sender.tag
        guard row >= 0 && row < cloudFiles.count else { return }
        onAddToPlaylist?(cloudFiles[row])
    }

    @objc private func viewComments(_ sender: NSMenuItem) {
        let row = sender.tag
        guard row >= 0 && row < cloudFiles.count else { return }
        onViewComments?(cloudFiles[row])
    }

    private func play(_ cloudFile: CloudMusicApi.CloudFile) {
        guard cloudFile.simpleSong != nil else { return }
        onPlay?(cloudFile)
    }
}

// MARK: - SwiftUI Wrapper

struct CloudFileTableView: NSViewControllerRepresentable {
    let cloudFiles: [CloudMusicApi.CloudFile]
    let isLoadingMore: Bool
    let hasMoreFiles: Bool
    let pageSize: Int
    let isFiltering: Bool
    let onLoadMore: () -> Void
    let onPlay: ((CloudMusicApi.CloudFile) -> Void)?
    let onAddToPlaylist: ((CloudMusicApi.CloudFile) -> Void)?
    let onViewComments: ((CloudMusicApi.CloudFile) -> Void)?

    func makeNSViewController(context: Context) -> CloudFileTableViewController {
        let controller = CloudFileTableViewController()
        controller.onLoadMore = onLoadMore
        controller.onPlay = onPlay
        controller.onAddToPlaylist = onAddToPlaylist
        controller.onViewComments = onViewComments
        controller.pageSize = pageSize
        controller.isFiltering = isFiltering
        return controller
    }

    func updateNSViewController(_ nsViewController: CloudFileTableViewController, context: Context)
    {
        nsViewController.isFiltering = isFiltering
        nsViewController.cloudFiles = cloudFiles
        nsViewController.isLoadingMore = isLoadingMore
        nsViewController.hasMoreFiles = hasMoreFiles
        nsViewController.pageSize = pageSize
        nsViewController.onPlay = onPlay
        nsViewController.onAddToPlaylist = onAddToPlaylist
        nsViewController.onViewComments = onViewComments
    }
}
