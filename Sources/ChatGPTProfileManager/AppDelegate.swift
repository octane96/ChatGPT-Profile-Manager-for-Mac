import AppKit

private final class ProfileCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.72).cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class ProfileBadgeView: NSView {
    private let label: NSTextField

    init(text: String, color: NSColor) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor

        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private enum AccountStorageChoice: Int {
        case existingEnvironment
        case newIsolatedProfile
        case existingIsolatedProfile
    }

    private enum UsageResetDateStyle {
        case timeOnly
        case monthDayAndTime
    }

    private let launcher = CodexLauncher()
    private let accountPasteboardType = NSPasteboard.PasteboardType(
        "com.local.chatgpt-profile-manager.account"
    )
    private var window: NSWindow?
    private var guideWindow: NSWindow?
    private var guidePages: [NSAttributedString] = []
    private var guidePageIndex = 0
    private var guideDotButtons: [NSButton] = []
    private weak var guidePageTextView: NSTextView?
    private weak var guideProgressLabel: NSTextField?
    private weak var guidePreviousButton: NSButton?
    private weak var guideNextButton: NSButton?
    private var shouldPrepareInitialAccountAfterGuide = false
    private weak var launchStatusTitleLabel: NSTextField?
    private weak var launchStatusDetailLabel: NSTextField?
    private var statusLabel: NSTextField?
    private var accountCountLabel: NSTextField?
    private var tableView: NSTableView?
    private var tableHeightConstraint: NSLayoutConstraint?
    private var addButton: NSButton?
    private var revealButton: NSButton?
    private var storageChoiceButtons: [NSButton] = []
    private var usageByAccountID: [UUID: AccountUsageSnapshot] = [:]
    private var usageRefreshTask: Task<Void, Never>?
    private var isSwitching = false {
        didSet {
            updateControlAvailability()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        configureMainMenu()
        configureWindow()
        refreshUI()
        refreshUsage()
        showMainWindow()

        DispatchQueue.main.async { [weak self] in
            self?.prepareInitialExperience()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshUI()
        refreshUsage()
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        true
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showMainWindow()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard
            let closingWindow = notification.object as? NSWindow,
            closingWindow === guideWindow
        else {
            return
        }

        guard shouldPrepareInitialAccountAfterGuide else {
            return
        }

        shouldPrepareInitialAccountAfterGuide = false
        prepareInitialAccount()
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let applicationMenuItem = NSMenuItem()
        mainMenu.addItem(applicationMenuItem)
        let applicationMenu = NSMenu(title: "ChatGPT Profile Manager")
        applicationMenu.addItem(
            withTitle: "ChatGPT Profile Managerについて",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            withTitle: "ChatGPT Profile Managerを終了",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        applicationMenuItem.submenu = applicationMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "ウィンドウ")
        windowMenu.addItem(
            withTitle: "ウィンドウを閉じる",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        windowMenu.addItem(
            withTitle: "しまう",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    private func configureWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ChatGPT Profile Manager"
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 560, height: 500)
        window.isReleasedWhenClosed = false
        window.center()

        let contentView = NSView()
        window.contentView = contentView

        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 10
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            mainStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            mainStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            mainStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
        ])

        let heroStack = NSStackView()
        heroStack.orientation = .horizontal
        heroStack.alignment = .top
        heroStack.spacing = 12
        heroStack.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView(image: NSApp.applicationIconImage)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        heroStack.addArrangedSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 54),
            iconView.heightAnchor.constraint(equalToConstant: 54)
        ])

        let heroLabels = NSStackView()
        heroLabels.orientation = .vertical
        heroLabels.alignment = .leading
        heroLabels.spacing = 5

        let titleLabel = NSTextField(labelWithString: "ChatGPT Profile Manager")
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        heroLabels.addArrangedSubview(titleLabel)

        let descriptionLabel = NSTextField(
            wrappingLabelWithString: "ChatGPTアカウントごとに保存先を分け、ChatGPTを安全に切り替えます。"
        )
        descriptionLabel.font = .systemFont(ofSize: 13)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.maximumNumberOfLines = 2
        heroLabels.addArrangedSubview(descriptionLabel)
        heroStack.addArrangedSubview(heroLabels)
        mainStack.addArrangedSubview(heroStack)

        let launchStatusCard = ProfileCardView()
        launchStatusCard.layer?.cornerRadius = 10
        launchStatusCard.layer?.backgroundColor = NSColor.controlAccentColor
            .withAlphaComponent(0.08)
            .cgColor
        launchStatusCard.layer?.borderColor = NSColor.controlAccentColor
            .withAlphaComponent(0.22)
            .cgColor
        launchStatusCard.translatesAutoresizingMaskIntoConstraints = false
        launchStatusCard.setAccessibilityLabel("最後に起動したアカウント")

        let launchStatusStack = NSStackView()
        launchStatusStack.orientation = .horizontal
        launchStatusStack.alignment = .centerY
        launchStatusStack.spacing = 10
        launchStatusStack.translatesAutoresizingMaskIntoConstraints = false
        launchStatusCard.addSubview(launchStatusStack)
        NSLayoutConstraint.activate([
            launchStatusStack.leadingAnchor.constraint(equalTo: launchStatusCard.leadingAnchor, constant: 14),
            launchStatusStack.trailingAnchor.constraint(equalTo: launchStatusCard.trailingAnchor, constant: -14),
            launchStatusStack.topAnchor.constraint(equalTo: launchStatusCard.topAnchor, constant: 10),
            launchStatusStack.bottomAnchor.constraint(equalTo: launchStatusCard.bottomAnchor, constant: -10)
        ])

        let launchStatusIcon = NSImageView(
            image: NSImage(
                systemSymbolName: "clock.arrow.circlepath",
                accessibilityDescription: "最後に起動"
            ) ?? NSImage()
        )
        launchStatusIcon.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 17,
            weight: .semibold
        )
        launchStatusIcon.contentTintColor = .controlAccentColor
        launchStatusIcon.imageScaling = .scaleProportionallyUpOrDown
        launchStatusIcon.translatesAutoresizingMaskIntoConstraints = false
        launchStatusStack.addArrangedSubview(launchStatusIcon)
        NSLayoutConstraint.activate([
            launchStatusIcon.widthAnchor.constraint(equalToConstant: 24),
            launchStatusIcon.heightAnchor.constraint(equalToConstant: 24)
        ])

        let launchStatusLabels = NSStackView()
        launchStatusLabels.orientation = .vertical
        launchStatusLabels.alignment = .leading
        launchStatusLabels.spacing = 2

        let launchStatusTitleLabel = NSTextField(labelWithString: "最後に起動")
        launchStatusTitleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        launchStatusTitleLabel.textColor = .secondaryLabelColor
        launchStatusLabels.addArrangedSubview(launchStatusTitleLabel)

        let launchStatusDetailLabel = NSTextField(labelWithString: "—")
        launchStatusDetailLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        launchStatusDetailLabel.textColor = .labelColor
        launchStatusDetailLabel.lineBreakMode = .byTruncatingTail
        launchStatusDetailLabel.maximumNumberOfLines = 1
        launchStatusDetailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        launchStatusLabels.addArrangedSubview(launchStatusDetailLabel)
        launchStatusStack.addArrangedSubview(launchStatusLabels)
        launchStatusLabels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let launchStatusSpacer = NSView()
        launchStatusSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        launchStatusStack.addArrangedSubview(launchStatusSpacer)

        mainStack.addArrangedSubview(launchStatusCard)
        launchStatusCard.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        launchStatusCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        self.launchStatusTitleLabel = launchStatusTitleLabel
        self.launchStatusDetailLabel = launchStatusDetailLabel

        let accountHeader = NSStackView()
        accountHeader.orientation = .horizontal
        accountHeader.alignment = .centerY
        accountHeader.translatesAutoresizingMaskIntoConstraints = false

        let accountHeaderLabel = NSTextField(labelWithString: "アカウント")
        accountHeaderLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        accountHeader.addArrangedSubview(accountHeaderLabel)

        let accountCountLabel = NSTextField(labelWithString: "")
        accountCountLabel.font = .systemFont(ofSize: 12, weight: .medium)
        accountCountLabel.textColor = .secondaryLabelColor
        accountHeader.addArrangedSubview(accountCountLabel)
        self.accountCountLabel = accountCountLabel

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        accountHeader.addArrangedSubview(headerSpacer)

        let addButton = NSButton(
            title: "アカウントを追加",
            target: self,
            action: #selector(addAccount)
        )
        addButton.bezelStyle = .rounded
        addButton.controlSize = .large
        addButton.keyEquivalent = "+"
        addButton.setAccessibilityLabel("アカウントを追加")
        accountHeader.addArrangedSubview(addButton)
        mainStack.addArrangedSubview(accountHeader)
        accountHeader.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        self.addButton = addButton

        let tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowHeight = 156
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.setAccessibilityLabel("登録済みアカウント")
        tableView.dataSource = self
        tableView.delegate = self
        tableView.registerForDraggedTypes([accountPasteboardType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.verticalMotionCanBeginDrag = true

        let accountColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Account"))
        accountColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(accountColumn)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 10
        scrollView.layer?.borderWidth = 0
        mainStack.addArrangedSubview(scrollView)

        scrollView.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        tableHeightConstraint = scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 76)
        tableHeightConstraint?.isActive = true
        self.tableView = tableView

        let statusLabel = NSTextField(wrappingLabelWithString: "")
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.alignment = .left
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 1
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.isHidden = true
        mainStack.addArrangedSubview(statusLabel)
        self.statusLabel = statusLabel

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        mainStack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true

        let managementHeader = NSTextField(labelWithString: "管理")
        managementHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        managementHeader.alignment = .left
        managementHeader.textColor = .secondaryLabelColor
        mainStack.addArrangedSubview(managementHeader)

        let utilityButtons = NSStackView()
        utilityButtons.orientation = .horizontal
        utilityButtons.alignment = .centerY
        utilityButtons.spacing = 12
        utilityButtons.translatesAutoresizingMaskIntoConstraints = false

        let revealButton = NSButton(
            title: "保存先を開く",
            target: self,
            action: #selector(revealProfiles)
        )
        revealButton.bezelStyle = .rounded
        revealButton.controlSize = .regular
        revealButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        revealButton.contentTintColor = .controlAccentColor
        revealButton.setAccessibilityLabel("プロファイル保存先を開く")

        let guideButton = NSButton(
            title: "仕組みを見る",
            target: self,
            action: #selector(showMechanismGuide)
        )
        guideButton.bezelStyle = .rounded
        guideButton.controlSize = .regular
        guideButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        guideButton.contentTintColor = .controlAccentColor
        guideButton.setAccessibilityLabel("このアプリの仕組みを見る")

        utilityButtons.addArrangedSubview(revealButton)
        utilityButtons.addArrangedSubview(guideButton)
        mainStack.addArrangedSubview(utilityButtons)

        self.revealButton = revealButton

        self.window = window
    }

    private func showMainWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshUI() {
        let accounts = launcher.accounts
        accountCountLabel?.stringValue = accounts.isEmpty ? "未登録" : "\(accounts.count)件"

        updateLaunchStatus()
        statusLabel?.stringValue = ""
        statusLabel?.isHidden = true

        tableView?.reloadData()
        updateTableHeight(accountCount: accounts.count)
        updateControlAvailability()
    }

    private func updateLaunchStatus() {
        launchStatusTitleLabel?.stringValue = "最後に起動"
        if let lastAccount = launcher.lastLaunchedAccount {
            let environment = lastAccount.id == launcher.existingEnvironmentAccount?.id
                ? "既存環境"
                : "分離プロファイル"
            launchStatusDetailLabel?.stringValue = "\(lastAccount.name)（\(environment)）"
        } else if launcher.accounts.isEmpty {
            launchStatusDetailLabel?.stringValue = "アカウントを追加するとここに表示されます"
        } else {
            launchStatusDetailLabel?.stringValue = "このアプリから起動したアカウントはありません"
        }
    }

    private func showTransientStatus(_ message: String) {
        statusLabel?.stringValue = message
        statusLabel?.isHidden = false
    }

    private func refreshUsage() {
        usageRefreshTask?.cancel()

        let accountHomes: [(accountID: UUID, codexHome: URL)] = launcher.accounts.compactMap { account in
            guard let codexHome = launcher.codexHomeDirectory(for: account) else {
                return nil
            }
            return (accountID: account.id, codexHome: codexHome)
        }

        guard !accountHomes.isEmpty else {
            usageByAccountID = [:]
            return
        }

        usageRefreshTask = Task { [weak self] in
            var snapshots: [UUID: AccountUsageSnapshot] = [:]
            await withTaskGroup(of: (UUID, AccountUsageSnapshot?).self) { group in
                for (accountID, codexHome) in accountHomes {
                    group.addTask {
                        (accountID, await UsageService.fetch(codexHome: codexHome))
                    }
                }

                for await (accountID, snapshot) in group {
                    if let snapshot {
                        snapshots[accountID] = snapshot
                    }
                }
            }

            guard !Task.isCancelled else { return }
            self?.usageByAccountID = snapshots
            self?.tableView?.reloadData()
        }
    }

    private func updateTableHeight(accountCount: Int) {
        let visibleRowCount = max(accountCount, 1)
        let desiredHeight = CGFloat(visibleRowCount * 156 + 1)
        tableHeightConstraint?.constant = min(max(desiredHeight, 76), 420)
    }

    private func updateControlAvailability() {
        addButton?.isEnabled = !isSwitching
        tableView?.isEnabled = !isSwitching
        revealButton?.isEnabled = !isSwitching
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        launcher.accounts.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        let accounts = launcher.accounts
        guard accounts.indices.contains(row) else {
            return nil
        }
        let account = accounts[row]

        let cell = NSTableCellView()
        let rowCard = ProfileCardView()
        rowCard.layer?.cornerRadius = 8
        rowCard.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(rowCard)
        NSLayoutConstraint.activate([
            rowCard.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            rowCard.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            rowCard.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5),
            rowCard.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -5)
        ])

        let rowStack = NSStackView()
        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = 8
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowCard.addSubview(rowStack)

        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: rowCard.leadingAnchor, constant: 10),
            rowStack.trailingAnchor.constraint(equalTo: rowCard.trailingAnchor, constant: -10),
            rowStack.topAnchor.constraint(equalTo: rowCard.topAnchor, constant: 6),
            rowStack.bottomAnchor.constraint(equalTo: rowCard.bottomAnchor, constant: -6)
        ])

        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let dragContainer = NSView()
        dragContainer.translatesAutoresizingMaskIntoConstraints = false
        dragContainer.setContentHuggingPriority(.required, for: .horizontal)
        dragContainer.widthAnchor.constraint(equalToConstant: 30).isActive = true
        dragContainer.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let dragHandle = NSImageView(
            image: NSImage(
                systemSymbolName: "line.3.horizontal",
                accessibilityDescription: "ドラッグして並び替え"
            ) ?? NSImage()
        )
        dragHandle.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 13,
            weight: .medium
        )
        dragHandle.contentTintColor = .secondaryLabelColor
        dragHandle.toolTip = "ドラッグして並び替え"
        dragHandle.setAccessibilityLabel("\(account.name)をドラッグして並び替え")
        dragHandle.translatesAutoresizingMaskIntoConstraints = false
        dragContainer.addSubview(dragHandle)
        NSLayoutConstraint.activate([
            dragHandle.centerXAnchor.constraint(equalTo: dragContainer.centerXAnchor),
            dragHandle.centerYAnchor.constraint(equalTo: dragContainer.centerYAnchor),
            dragHandle.widthAnchor.constraint(equalToConstant: 22),
            dragHandle.heightAnchor.constraint(equalToConstant: 22)
        ])
        rowStack.addArrangedSubview(dragContainer)

        let nameLabel = NSTextField(labelWithString: account.name)
        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        labels.addArrangedSubview(nameLabel)

        let isExisting = account.id == launcher.existingEnvironmentAccount?.id
        let usageSnapshot = usageByAccountID[account.id]
        let metadataStack = NSStackView()
        metadataStack.orientation = .horizontal
        metadataStack.alignment = .centerY
        metadataStack.spacing = 6

        let badge = ProfileBadgeView(
            text: isExisting ? "既存環境" : "分離プロファイル",
            color: isExisting ? .systemBlue : .systemPurple
        )
        metadataStack.addArrangedSubview(badge)

        let planLabel = NSTextField(
            labelWithString: "プラン: \(usageSnapshot?.displayPlanName ?? "—")"
        )
        planLabel.font = .systemFont(ofSize: 11, weight: .medium)
        planLabel.textColor = usageSnapshot?.displayPlanName == nil
            ? .tertiaryLabelColor
            : .secondaryLabelColor
        planLabel.setContentHuggingPriority(.required, for: .horizontal)
        metadataStack.addArrangedSubview(planLabel)

        labels.addArrangedSubview(metadataStack)

        let usageStack = NSStackView()
        usageStack.orientation = .vertical
        usageStack.alignment = .leading
        usageStack.spacing = 1
        usageStack.addArrangedSubview(
            makeUsageLabel(
                title: "5H",
                window: usageSnapshot?.primary,
                resetDateStyle: .timeOnly
            )
        )
        usageStack.addArrangedSubview(
            makeUsageLabel(
                title: "週間",
                window: usageSnapshot?.secondary,
                resetDateStyle: .monthDayAndTime
            )
        )
        if let resetCredits = usageSnapshot?.rateLimitResetCredits,
           resetCredits.availableCount > 0 {
            makeResetCreditLabels(resetCredits).forEach {
                usageStack.addArrangedSubview($0)
            }
        }
        usageStack.setContentCompressionResistancePriority(.required, for: .vertical)
        labels.addArrangedSubview(usageStack)

        let directoryLabel = NSTextField(
            labelWithString: isExisting
                ? "保存先: ChatGPTの既定環境"
                : "保存先: \(account.directoryName)"
        )
        directoryLabel.font = .systemFont(ofSize: 11)
        directoryLabel.textColor = .tertiaryLabelColor
        directoryLabel.lineBreakMode = .byTruncatingMiddle
        directoryLabel.maximumNumberOfLines = 1
        directoryLabel.toolTip = isExisting
            ? "ChatGPTの既定環境"
            : account.directoryName
        directoryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labels.addArrangedSubview(directoryLabel)
        rowStack.addArrangedSubview(labels)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rowStack.addArrangedSubview(spacer)

        let renameButton = NSButton(
            title: "名前を変更…",
            target: self,
            action: #selector(renameAccount(_:))
        )
        renameButton.bezelStyle = .inline
        renameButton.controlSize = .regular
        renameButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        renameButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        renameButton.identifier = NSUserInterfaceItemIdentifier(account.id.uuidString)
        renameButton.setAccessibilityLabel("\(account.name)の名前を変更")
        rowStack.addArrangedSubview(renameButton)

        let openButton = NSButton(
            title: "開く",
            target: self,
            action: #selector(switchAccount(_:))
        )
        openButton.bezelStyle = .rounded
        openButton.controlSize = .large
        openButton.isBordered = false
        openButton.wantsLayer = true
        openButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        openButton.layer?.cornerRadius = 7
        openButton.contentTintColor = .white
        openButton.font = .systemFont(ofSize: 13, weight: .semibold)
        openButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true
        openButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        openButton.identifier = NSUserInterfaceItemIdentifier(account.id.uuidString)
        openButton.setAccessibilityLabel("\(account.name)を開く")
        rowStack.addArrangedSubview(openButton)

        if !isExisting {
            let deleteButton = NSButton(
                title: "削除…",
                target: self,
                action: #selector(deleteAccount(_:))
            )
            deleteButton.bezelStyle = .inline
            deleteButton.controlSize = .regular
            deleteButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
            deleteButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
            deleteButton.contentTintColor = .systemRed
            deleteButton.identifier = NSUserInterfaceItemIdentifier(account.id.uuidString)
            deleteButton.hasDestructiveAction = true
            deleteButton.isEnabled = !isSwitching
            deleteButton.setAccessibilityLabel("\(account.name)の登録を削除")
            deleteButton.toolTip = "アカウント登録だけを削除（保存先は保持）"
            rowStack.addArrangedSubview(deleteButton)
        }

        return cell
    }

    private func makeUsageLabel(
        title: String,
        window: UsageWindow?,
        resetDateStyle: UsageResetDateStyle
    ) -> NSTextField {
        let value: String
        if let window {
            let resetDescription = window.resetsAt.map {
                "\(formatResetDate($0, style: resetDateStyle))にリセット"
            } ?? "リセット時刻不明"
            value = "\(title) 残り \(window.remainingPercent)% \(resetDescription)"
        } else {
            value = "\(title) —"
        }

        let label = NSTextField(labelWithString: value)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = usageColor(for: window)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        if let window {
            let resetTooltip = window.resetsAt.map {
                formatResetDate($0, style: resetDateStyle)
            } ?? "不明"
            label.toolTip = "\(title)：使用済み \(window.usedPercent)%、残り \(window.remainingPercent)%\n\(resetTooltip)にリセット"
        } else {
            label.toolTip = "\(title)の利用状況を取得できませんでした。ChatGPTを開いてから再度確認してください。"
        }
        return label
    }

    private func makeResetCreditLabels(
        _ summary: RateLimitResetCreditsSummary
    ) -> [NSTextField] {
        var labels: [NSTextField] = []
        let titleLabel = NSTextField(
            labelWithString: "上限リセット\(summary.availableCount)件"
        )
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .systemOrange
        titleLabel.toolTip = "利用できる上限リセットクレジット: \(summary.availableCount)件"
        labels.append(titleLabel)

        if let credits = summary.credits, !credits.isEmpty {
            for credit in credits {
                let expiryText = credit.expiresAt.map {
                    formatResetDate($0, style: .monthDayAndTime)
                } ?? "有効期限不明"
                let expiryLabel = NSTextField(labelWithString: "・\(expiryText)")
                expiryLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
                expiryLabel.textColor = .secondaryLabelColor
                expiryLabel.setContentHuggingPriority(.required, for: .horizontal)
                expiryLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
                labels.append(expiryLabel)
            }

            let missingCount = summary.availableCount - credits.count
            if missingCount > 0 {
                let missingLabel = NSTextField(
                    labelWithString: "・有効期限不明 \(missingCount)件"
                )
                missingLabel.font = .systemFont(ofSize: 10)
                missingLabel.textColor = .tertiaryLabelColor
                labels.append(missingLabel)
            }
        } else {
            let unavailableLabel = NSTextField(labelWithString: "・有効期限は未取得")
            unavailableLabel.font = .systemFont(ofSize: 10)
            unavailableLabel.textColor = .tertiaryLabelColor
            labels.append(unavailableLabel)
        }

        return labels
    }

    private func usageColor(for window: UsageWindow?) -> NSColor {
        guard let window else {
            return .tertiaryLabelColor
        }
        if window.remainingPercent <= 10 {
            return .systemRed
        }
        if window.remainingPercent <= 25 {
            return .systemOrange
        }
        return .secondaryLabelColor
    }

    private func formatResetDate(
        _ date: Date,
        style: UsageResetDateStyle
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        switch style {
        case .timeOnly:
            formatter.dateFormat = "HH:mm"
        case .monthDayAndTime:
            formatter.dateFormat = "M月d日 HH:mm"
        }
        return formatter.string(from: date)
    }

    func tableView(
        _ tableView: NSTableView,
        pasteboardWriterForRow row: Int
    ) -> NSPasteboardWriting? {
        let accounts = launcher.accounts
        guard !isSwitching, accounts.indices.contains(row) else {
            return nil
        }

        let item = NSPasteboardItem()
        item.setString(accounts[row].id.uuidString, forType: accountPasteboardType)
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard
            !isSwitching,
            let sourceTable = info.draggingSource as? NSTableView,
            sourceTable === tableView
        else {
            return []
        }

        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard
            !isSwitching,
            dropOperation == .above,
            let rawID = info.draggingPasteboard.string(forType: accountPasteboardType),
            let accountID = UUID(uuidString: rawID),
            let account = launcher.accounts.first(where: { $0.id == accountID })
        else {
            return false
        }

        do {
            try launcher.moveAccount(id: accountID, toInsertionIndex: row)
            refreshUI()
            showTransientStatus("\(account.name) の並び順を変更しました。")
            return true
        } catch {
            presentError(error, title: "並び順を変更できませんでした")
            return false
        }
    }

    @objc
    private func addAccount() {
        presentAddAccount()
    }

    private func presentProfileDirectoryChoice(
        for name: String,
        candidates: [IsolatedProfileCandidate]
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "使用する分離プロファイルを選択"
        alert.informativeText = "「\(name)」で使う分離プロファイルを選択してください。フォルダの内容はコピー・移動せず、選択した保存先をそのまま登録します。ChatGPTの既存環境とは別の保存先です。"
        alert.addButton(withTitle: "この保存先で追加")
        alert.addButton(withTitle: "キャンセル")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 430, height: 26))
        popup.controlSize = .regular
        popup.setAccessibilityLabel("使用する分離プロファイルの保存先")
        candidates.forEach { popup.addItem(withTitle: $0.directoryName) }
        alert.accessoryView = popup

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        let selectedIndex = popup.indexOfSelectedItem
        guard candidates.indices.contains(selectedIndex) else {
            presentError(
                ProfileManagerError.profileDirectoryNotFound,
                title: "既存フォルダを登録できませんでした"
            )
            return
        }

        createAccount(
            named: name,
            linkToExistingEnvironment: false,
            directoryName: candidates[selectedIndex].directoryName
        )
    }

    @objc
    private func showMechanismGuide() {
        if let guideWindow, guideWindow.isVisible {
            guideWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        launcher.markMechanismGuideShown()

        let bodyFont = NSFont.systemFont(ofSize: 14)
        let pageTitleFont = NSFont.systemFont(ofSize: 23, weight: .bold)
        let sectionFont = NSFont.systemFont(ofSize: 16, weight: .semibold)
        let bodyParagraphStyle = NSMutableParagraphStyle()
        bodyParagraphStyle.lineSpacing = 4
        bodyParagraphStyle.paragraphSpacing = 7

        let titleParagraphStyle = NSMutableParagraphStyle()
        titleParagraphStyle.paragraphSpacing = 12

        let sectionParagraphStyle = NSMutableParagraphStyle()
        sectionParagraphStyle.paragraphSpacingBefore = 10
        sectionParagraphStyle.paragraphSpacing = 4

        let codeParagraphStyle = NSMutableParagraphStyle()
        codeParagraphStyle.lineSpacing = 2
        codeParagraphStyle.paragraphSpacing = 6

        func appendGuideText(
            _ content: NSMutableAttributedString,
            _ text: String,
            font: NSFont,
            color: NSColor = .labelColor,
            paragraphStyle: NSParagraphStyle
        ) {
            content.append(
                NSAttributedString(
                    string: text,
                    attributes: [
                        .font: font,
                        .foregroundColor: color,
                        .paragraphStyle: paragraphStyle
                    ]
                )
            )
        }

        func appendGuideCode(_ content: NSMutableAttributedString, _ text: String) {
            content.append(
                NSAttributedString(
                    string: "\(text)\n",
                    attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium),
                        .foregroundColor: NSColor.controlAccentColor,
                        .backgroundColor: NSColor.controlBackgroundColor,
                        .paragraphStyle: codeParagraphStyle
                    ]
                )
            )
        }

        func makeGuidePage(
            title: String,
            build: (NSMutableAttributedString) -> Void
        ) -> NSAttributedString {
            let content = NSMutableAttributedString()
            appendGuideText(
                content,
                "\(title)\n",
                font: pageTitleFont,
                paragraphStyle: titleParagraphStyle
            )
            build(content)
            return content.copy() as! NSAttributedString
        }

        guidePages = [
            makeGuidePage(title: "はじめに") { content in
                appendGuideText(
                    content,
                    "ChatGPT Profile Managerは、ChatGPTアカウントごとに使う保存先を選び、切り替えて起動するためのアプリです。アカウントやクラウド上のプロジェクトを移動・コピーするものではありません。\n\n",
                    font: bodyFont,
                    color: .secondaryLabelColor,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideText(
                    content,
                    "全体の流れ\n",
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    "1　初回アカウントを確認\n2　保存先を選択\n3　必要ならログイン\n4　一覧の「開く」で切り替え\n\n",
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideText(
                    content,
                    "大切な前提\n",
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    "既存環境がある場合、最初の起動時にメールアドレスを表示名として自動登録します。既存環境がない場合や2件目以降は、アカウント追加から保存先を選びます。アカウント間でプロジェクトやチャットをコピーすることはありません。",
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
            },
            makeGuidePage(title: "アカウントを登録") { content in
                appendGuideText(
                    content,
                    "アプリを起動する\n",
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    "ChatGPT Profile Managerを起動します。既存環境がある場合は、最初のアカウントをメールアドレスの表示名で自動登録します。登録しただけではChatGPTは起動せず、一覧の「開く」を押したときだけ選択した環境を起動します。\n\n",
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideText(
                    content,
                    "アカウントを追加する\n",
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    "既存環境が自動登録されなかった場合や、別のアカウントを追加する場合は、「アカウントを追加」を押して一覧で表示する名前を入力します。メールアドレス以外の名前にも変更できます。アカウントは任意の数を追加できます。名前は1文字以上60文字以内で、同じ名前は登録できません。",
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
            },
            makeGuidePage(title: "保存先を選ぶ") { content in
                appendGuideText(
                    content,
                    "名前の入力後、「このアカウントで使う保存先を選択」と表示されます。次の3つから、アカウントで使う環境を選びます。\n\n",
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideText(
                    content,
                    "ChatGPTの既存環境を使う\n",
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    "普段のChatGPTのプロジェクト、チャット、設定、ログイン状態をそのまま使います。割り当てられるのは1アカウントだけです。\n\n",
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideText(
                    content,
                    "新しい分離プロファイルを作る\n",
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    "このアカウント専用の保存先を新しく作ります。既存環境のデータはコピーされません。\n\n",
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideText(
                    content,
                    "既存の分離プロファイルを使う\n",
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    "すでにある保存フォルダを選んで登録します。フォルダのコピーや移動は行いません。",
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
            },
            makeGuidePage(title: "ログインして切り替える") { content in
                appendGuideText(
                    content,
                    "初回ログイン\n",
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    "新しい分離プロファイルを初めて開くときは、その保存先で使うChatGPTアカウントへログインします。ログイン状態、プロジェクト、チャットは、その分離プロファイル内に保存されます。既存環境を選んだ場合は、普段のログイン状態をそのまま使います。\n\n",
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideText(
                    content,
                    "「開く」で切り替える\n",
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    "一覧からアカウントを選び、「開く」を押します。実行中のChatGPTを通常終了してから、選択した保存先で再起動します。ChatGPTが10秒以内に終了しない場合は強制終了せず、切り替えを止めます。切り替え前に実行中のローカルタスクがないことを確認してください。",
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
            },
            makeGuidePage(title: "アカウントを整理する") { content in
                appendGuideText(
                    content,
                    "別のアカウントを追加する\n",
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    "同じ手順で何件でも追加できます。既存環境を割り当てた後は、その選択肢が無効になり、分離プロファイルを使います。未登録の保存フォルダを使う場合は、保存先の選択画面で「既存の分離プロファイルを使う」を選びます。\n\n",
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideText(
                    content,
                    "一覧を整える\n",
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    "「名前を変更…」は表示名だけを変更します。行をドラッグすると表示順だけを変更します。\n\n",
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideText(
                    content,
                    "分離プロファイルを登録から外す\n",
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    "分離プロファイルの「削除…」は登録情報だけを外し、保存フォルダやデータは残します。既存環境に割り当てたアカウントは削除できません。",
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
            },
            makeGuidePage(title: "仕組みと保存場所") { content in
                appendGuideText(
                    content,
                    "保存先は2種類\n",
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    "ChatGPTの既存環境は、ChatGPTが普段使っている保存先です。分離プロファイルは、ChatGPT Profile Managerがアカウントごとに用意する専用の保存先です。ログイン状態やアプリデータをアカウントごとに分けます。\n\n",
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideText(
                    content,
                    "起動時に保存先を指定する仕組み\n",
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    "既存環境を使う場合は、ChatGPTを通常起動します。分離プロファイルを使う場合は、起動時だけ専用の保存先を環境変数と引数で指定します。ChatGPT Profile Managerがデータをコピー・移動するのではなく、ChatGPTが読み込む場所を起動ごとに切り替えます。\n\n",
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideText(
                    content,
                    "指定する場所の役割\n",
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    "CODEX_HOMEはCodexの設定、認証、セッション、ログなどを保存します。CODEX_ELECTRON_USER_DATA_PATHと--user-data-dirは、ChatGPTデスクトップアプリ側のCookie、ログイン状態、アプリデータの保存先を指定します。この2つを同じ分離プロファイル内で指定することで、アカウントごとの環境を分けます。\n\n",
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideText(
                    content,
                    "保存場所\n",
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideCode(
                    content,
                    "~/Library/Application Support/\n└── ChatGPT Profile Manager/\n    └── Profiles/\n        └── account-<表示名>-<短いID>/\n            ├── CodexHome/\n            └── ElectronUserData/"
                )
                appendGuideText(
                    content,
                    "利用上限の表示\n",
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    "アカウント一覧には取得できたプラン名も表示します。「5H」は5時間枠、「週間」は週間枠です。5Hは残りの割合と24時間表記の時刻、週間は残りの割合と月日・24時間表記の時刻を同じ行に表示します。利用できる上限リセットクレジットがある場合は、週間行の下に件数と有効期限を表示します。複数件ある場合は期限を一行ずつ表示します。ラベルにカーソルを合わせると、使用済みの割合と詳細なリセット日時を確認できます。Codexコマンドが見つからない場合、未ログインの場合、または通信できない場合は「—」と表示します。利用状況や認証情報をこのアプリの設定へ保存することはありません。",
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
            },
            makeGuidePage(title: "困ったとき・安全に使う") { content in
                appendGuideText(
                    content,
                    "初回登録について\n",
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    "初回起動時に既存環境が見つかると、メールアドレスを表示名にして自動登録します。登録後も「名前を変更…」から表示名だけ変更できます。\n\n",
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideText(
                    content,
                    "アプリを開く場所\n",
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    "複数アカウントを使うときは、普段のChatGPTアイコンではなく、このアプリの「開く」から起動してください。切り替え前には、実行中のローカルタスクがないことを確認してください。\n\n",
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideText(
                    content,
                    "注意\n",
                    font: sectionFont,
                    color: .systemOrange,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    "このアプリはOpenAI公式機能ではありません。アカウントの利用上限を回避する目的では使用しないでください。",
                    font: bodyFont,
                    color: .secondaryLabelColor,
                    paragraphStyle: bodyParagraphStyle
                )
            }
        ]

        let guideWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        guideWindow.title = "このアプリの仕組み"
        guideWindow.tabbingMode = .disallowed
        guideWindow.minSize = NSSize(width: 560, height: 480)
        guideWindow.isReleasedWhenClosed = false
        guideWindow.center()

        let headerStack = NSStackView()
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 12
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let headerTitleLabel = NSTextField(labelWithString: "使い方チュートリアル")
        headerTitleLabel.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        headerTitleLabel.textColor = .labelColor

        let progressLabel = NSTextField(labelWithString: "")
        progressLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.alignment = .right

        headerStack.addArrangedSubview(headerTitleLabel)
        headerStack.addArrangedSubview(NSView())
        headerStack.addArrangedSubview(progressLabel)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let guideTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 1))
        guideTextView.isEditable = false
        guideTextView.isSelectable = true
        guideTextView.drawsBackground = false
        guideTextView.font = bodyFont
        guideTextView.textColor = .labelColor
        guideTextView.textContainerInset = NSSize(width: 22, height: 22)
        guideTextView.isVerticallyResizable = true
        guideTextView.isHorizontallyResizable = false
        guideTextView.autoresizingMask = [.width]
        guideTextView.textContainer?.containerSize = NSSize(
            width: 600,
            height: CGFloat.greatestFiniteMagnitude
        )
        guideTextView.textContainer?.widthTracksTextView = true
        scrollView.documentView = guideTextView

        let dotsStack = NSStackView()
        dotsStack.orientation = .horizontal
        dotsStack.alignment = .centerY
        dotsStack.spacing = 3
        dotsStack.setContentHuggingPriority(.required, for: .horizontal)
        dotsStack.setContentCompressionResistancePriority(.required, for: .horizontal)

        guideDotButtons = guidePages.indices.map { index in
            let button = NSButton(title: "○", target: self, action: #selector(selectGuidePage(_:)))
            button.tag = index
            button.bezelStyle = .inline
            button.isBordered = false
            button.font = NSFont.systemFont(ofSize: 18, weight: .regular)
            button.contentTintColor = .secondaryLabelColor
            button.setAccessibilityLabel("ページ \(index + 1)/\(guidePages.count)へ移動")
            dotsStack.addArrangedSubview(button)
            return button
        }

        let previousButton = NSButton(title: "前へ", target: self, action: #selector(showPreviousGuidePage))
        previousButton.bezelStyle = .rounded
        previousButton.controlSize = .large

        let nextButton = NSButton(title: "次へ", target: self, action: #selector(showNextGuidePage))
        nextButton.bezelStyle = .rounded
        nextButton.controlSize = .large
        nextButton.keyEquivalent = "\r"

        let footerStack = NSStackView()
        footerStack.orientation = .horizontal
        footerStack.alignment = .centerY
        footerStack.spacing = 10
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        footerStack.addArrangedSubview(previousButton)
        footerStack.addArrangedSubview(NSView())
        footerStack.addArrangedSubview(dotsStack)
        footerStack.addArrangedSubview(NSView())
        footerStack.addArrangedSubview(nextButton)

        guideWindow.contentView = NSView()
        guard let contentView = guideWindow.contentView else { return }
        contentView.addSubview(headerStack)
        contentView.addSubview(scrollView)
        contentView.addSubview(footerStack)
        NSLayoutConstraint.activate([
            headerStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            headerStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            headerStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            headerStack.heightAnchor.constraint(equalToConstant: 26),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            scrollView.topAnchor.constraint(equalTo: headerStack.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: footerStack.topAnchor, constant: -12),
            footerStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            footerStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            footerStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),
            footerStack.heightAnchor.constraint(equalToConstant: 34)
        ])

        guideWindow.delegate = self
        self.guideWindow = guideWindow
        guidePageTextView = guideTextView
        guideProgressLabel = progressLabel
        guidePreviousButton = previousButton
        guideNextButton = nextButton
        guidePageIndex = 0
        updateGuidePage()
        guideWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc
    private func showPreviousGuidePage() {
        guard guidePageIndex > 0 else { return }
        guidePageIndex -= 1
        updateGuidePage()
    }

    @objc
    private func showNextGuidePage() {
        if guidePageIndex >= guidePages.count - 1 {
            guideWindow?.performClose(nil)
            return
        }
        guidePageIndex += 1
        updateGuidePage()
    }

    @objc
    private func selectGuidePage(_ sender: NSButton) {
        guard guidePages.indices.contains(sender.tag) else { return }
        guidePageIndex = sender.tag
        updateGuidePage()
    }

    private func updateGuidePage() {
        guard guidePages.indices.contains(guidePageIndex),
              let guidePageTextView,
              let guideProgressLabel,
              let guidePreviousButton,
              let guideNextButton
        else {
            return
        }

        guidePageTextView.textStorage?.setAttributedString(guidePages[guidePageIndex])
        guard let textContainer = guidePageTextView.textContainer,
              let layoutManager = guidePageTextView.layoutManager
        else {
            return
        }
        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = layoutManager.usedRect(for: textContainer).height
        var textViewFrame = guidePageTextView.frame
        textViewFrame.size.height = max(
            1,
            usedHeight + guidePageTextView.textContainerInset.height * 2
        )
        guidePageTextView.frame = textViewFrame
        if let enclosingScrollView = guidePageTextView.enclosingScrollView {
            enclosingScrollView.contentView.scroll(to: .zero)
            enclosingScrollView.reflectScrolledClipView(enclosingScrollView.contentView)
        }

        guideProgressLabel.stringValue = "ページ \(guidePageIndex + 1) / \(guidePages.count)"
        guidePreviousButton.isEnabled = guidePageIndex > 0
        guideNextButton.title = guidePageIndex == guidePages.count - 1 ? "完了" : "次へ"

        for (index, button) in guideDotButtons.enumerated() {
            button.title = index == guidePageIndex ? "●" : "○"
            button.contentTintColor = index == guidePageIndex
                ? .controlAccentColor
                : .secondaryLabelColor
        }
    }

    private func presentAddAccount() {
        showMainWindow()

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = launcher.accounts.isEmpty
            ? "最初のアカウントを追加します"
            : "アカウントを追加します"
        alert.informativeText = "ChatGPT Profile Managerで表示する分かりやすい名前を入力してください。メールアドレスそのものを使う必要はありません。"
        alert.addButton(withTitle: "次へ")
        alert.addButton(withTitle: "キャンセル")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        nameField.placeholderString = "例：メイン、開発チーム、取引先A"
        alert.accessoryView = nameField
        alert.window.initialFirstResponder = nameField

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        let name: String
        do {
            name = try launcher.validateNewAccountName(nameField.stringValue)
        } catch {
            presentError(error, title: "アカウント名を使用できません")
            DispatchQueue.main.async { [weak self] in
                self?.presentAddAccount()
            }
            return
        }

        presentStorageChoice(for: name)
    }

    private func prepareInitialExperience() {
        if guideWindow?.isVisible == true {
            return
        }

        guard !launcher.hasShownMechanismGuide else {
            if launcher.accounts.isEmpty {
                prepareInitialAccount()
            }
            return
        }

        shouldPrepareInitialAccountAfterGuide = launcher.accounts.isEmpty
        showMechanismGuide()
    }

    private func prepareInitialAccount() {
        do {
            if let account = try launcher.registerExistingEnvironmentIfNeeded() {
                refreshUI()
                showTransientStatus("\(account.name) を既存のChatGPT環境へ自動登録しました。")
                refreshUsage()
                return
            }
        } catch {
            presentError(error, title: "既存環境を自動登録できませんでした")
        }

        presentAddAccount()
    }

    private func presentStorageChoice(for name: String) {
        let existingEnvironmentAccount = launcher.existingEnvironmentAccount
        let candidates = launcher.availableIsolatedProfiles

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "「\(name)」で使う保存先を選択"
        alert.informativeText = "このアカウントでChatGPTが使う保存先を選びます。既存環境を使うと普段のプロジェクトやチャットをそのまま開きます。分離プロファイルを使うと、このアカウント専用の保存先を使います。"
        alert.addButton(withTitle: "この保存先で追加")
        alert.addButton(withTitle: "キャンセル")

        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 142))
        let choiceStack = NSStackView()
        choiceStack.orientation = .vertical
        choiceStack.alignment = .leading
        choiceStack.spacing = 10
        choiceStack.translatesAutoresizingMaskIntoConstraints = false
        accessoryView.addSubview(choiceStack)
        NSLayoutConstraint.activate([
            choiceStack.leadingAnchor.constraint(equalTo: accessoryView.leadingAnchor),
            choiceStack.trailingAnchor.constraint(equalTo: accessoryView.trailingAnchor),
            choiceStack.topAnchor.constraint(equalTo: accessoryView.topAnchor),
            choiceStack.bottomAnchor.constraint(equalTo: accessoryView.bottomAnchor)
        ])

        let options = [
            (
                choice: AccountStorageChoice.existingEnvironment,
                title: "ChatGPTの既存環境を使う",
                description: existingEnvironmentAccount.map {
                    "普段のChatGPTのプロジェクト・チャットをそのまま使う（「\($0.name)」に割り当て済み）"
                } ?? "普段のChatGPTのプロジェクト・チャットをそのまま使う",
                isEnabled: existingEnvironmentAccount == nil
            ),
            (
                choice: AccountStorageChoice.newIsolatedProfile,
                title: "新しい分離プロファイルを作る",
                description: "このアカウント専用の保存先を新しく作成する",
                isEnabled: true
            ),
            (
                choice: AccountStorageChoice.existingIsolatedProfile,
                title: "既存の分離プロファイルを使う",
                description: candidates.isEmpty
                    ? "登録できる既存フォルダがありません"
                    : "すでにある分離プロファイルを選んで使う",
                isEnabled: !candidates.isEmpty
            )
        ]

        let defaultChoice: AccountStorageChoice = existingEnvironmentAccount == nil
            ? .existingEnvironment
            : .newIsolatedProfile
        let defaultIndex = defaultChoice.rawValue
        var buttons: [NSButton] = []
        for (index, option) in options.enumerated() {
            let button = NSButton(
                radioButtonWithTitle: "",
                target: self,
                action: #selector(storageChoiceChanged(_:))
            )
            button.tag = index
            button.controlSize = .regular
            button.state = index == defaultIndex ? .on : .off
            button.isEnabled = option.isEnabled
            button.setAccessibilityLabel(option.title)
            button.toolTip = option.description
            button.widthAnchor.constraint(equalToConstant: 20).isActive = true

            let optionLabels = NSStackView()
            optionLabels.orientation = .vertical
            optionLabels.alignment = .leading
            optionLabels.spacing = 2
            optionLabels.translatesAutoresizingMaskIntoConstraints = false

            let titleLabel = NSTextField(labelWithString: option.title)
            titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
            titleLabel.textColor = option.isEnabled ? .labelColor : .tertiaryLabelColor
            titleLabel.maximumNumberOfLines = 1
            optionLabels.addArrangedSubview(titleLabel)

            let descriptionLabel = NSTextField(wrappingLabelWithString: option.description)
            descriptionLabel.font = .systemFont(ofSize: 11)
            descriptionLabel.textColor = option.isEnabled ? .secondaryLabelColor : .tertiaryLabelColor
            descriptionLabel.maximumNumberOfLines = 2
            optionLabels.addArrangedSubview(descriptionLabel)

            let optionRow = NSStackView(views: [button, optionLabels])
            optionRow.orientation = .horizontal
            optionRow.alignment = .top
            optionRow.spacing = 7
            optionRow.translatesAutoresizingMaskIntoConstraints = false
            optionLabels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            choiceStack.addArrangedSubview(optionRow)
            buttons.append(button)
        }

        storageChoiceButtons = buttons
        alert.accessoryView = accessoryView

        defer {
            storageChoiceButtons = []
        }

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        let selectedIndex = buttons.firstIndex(where: { $0.state == .on }) ?? defaultIndex
        guard let choice = AccountStorageChoice(rawValue: selectedIndex) else {
            return
        }

        switch choice {
        case .existingEnvironment:
            confirmExistingEnvironmentAssignment(named: name)
        case .newIsolatedProfile:
            createAccount(named: name, linkToExistingEnvironment: false)
        case .existingIsolatedProfile:
            guard !candidates.isEmpty else {
                presentError(
                    ProfileManagerError.profileDirectoryNotFound,
                    title: "既存の分離プロファイルを選択できませんでした"
                )
                return
            }
            presentProfileDirectoryChoice(for: name, candidates: candidates)
        }
    }

    @objc
    private func storageChoiceChanged(_ sender: NSButton) {
        storageChoiceButtons.forEach { button in
            button.state = button === sender ? .on : .off
        }
    }

    private func confirmExistingEnvironmentAssignment(named name: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "ChatGPTの既存環境を「\(name)」へ固定しますか？"
        alert.informativeText = "ChatGPTの既存環境をこのアカウントに割り当てます。紐づけられるのは1アカウントだけで、既存データのコピーや移動は行いません。確定後に追加するアカウントは、すべて分離プロファイルになります。"
        alert.addButton(withTitle: "ChatGPTの既存環境に固定")
        alert.addButton(withTitle: "戻る")

        guard alert.runModal() == .alertFirstButtonReturn else {
            DispatchQueue.main.async { [weak self] in
                self?.presentStorageChoice(for: name)
            }
            return
        }

        createAccount(named: name, linkToExistingEnvironment: true)
    }

    private func createAccount(
        named name: String,
        linkToExistingEnvironment: Bool,
        directoryName: String? = nil
    ) {
        do {
            let account = try launcher.addAccount(
                named: name,
                linkToExistingEnvironment: linkToExistingEnvironment,
                directoryName: directoryName
            )
            refreshUI()
            refreshUsage()
            if linkToExistingEnvironment {
                showTransientStatus("\(account.name) を既存のChatGPT環境へ固定しました。")
            } else if directoryName != nil {
                showTransientStatus("\(account.name) に既存の分離プロファイルを登録しました。")
            } else {
                showTransientStatus("\(account.name) を新しい分離プロファイルとして追加しました。")
            }
        } catch {
            presentError(error, title: "アカウントを追加できませんでした")
        }
    }

    @objc
    private func renameAccount(_ sender: NSButton) {
        guard
            let rawID = sender.identifier?.rawValue,
            let accountID = UUID(uuidString: rawID),
            let account = launcher.accounts.first(where: { $0.id == accountID })
        else {
            presentError(ProfileManagerError.accountNotFound)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "アカウント名を変更します"
        alert.informativeText = "名前だけを変更します。紐づけ先や保存済みデータは変わりません。"
        alert.addButton(withTitle: "変更")
        alert.addButton(withTitle: "キャンセル")

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        nameField.stringValue = account.name
        alert.accessoryView = nameField
        alert.window.initialFirstResponder = nameField

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        do {
            try launcher.renameAccount(id: account.id, to: nameField.stringValue)
            refreshUI()
        } catch {
            presentError(error, title: "アカウント名を変更できませんでした")
        }
    }

    @objc
    private func deleteAccount(_ sender: NSButton) {
        guard
            let rawID = sender.identifier?.rawValue,
            let accountID = UUID(uuidString: rawID),
            let account = launcher.accounts.first(where: { $0.id == accountID })
        else {
            presentError(ProfileManagerError.accountNotFound, title: "アカウント登録を削除できませんでした")
            return
        }

        guard account.id != launcher.existingEnvironmentAccount?.id else {
            presentError(
                ProfileManagerError.linkedAccountCannotBeDeleted,
                title: "アカウント登録を削除できませんでした"
            )
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "「\(account.name)」の登録を削除しますか？"
        alert.informativeText = "アカウントの登録だけを削除します。分離プロファイルの保存フォルダ、ログイン状態、設定、セッション、ログなどはそのまま残り、後からアカウント追加時に「既存の分離プロファイルを使う」を選ぶと、同じ保存先を再登録できます。既存環境は変更されません。"
        alert.addButton(withTitle: "登録を削除")
        alert.addButton(withTitle: "キャンセル")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        do {
            let deletedAccount = try launcher.removeIsolatedAccountRegistration(id: account.id)
            refreshUI()
            refreshUsage()
            showTransientStatus("\(deletedAccount.name) の登録を削除しました。保存フォルダは保持されています。")
        } catch {
            presentError(error, title: "アカウント登録を削除できませんでした")
        }
    }

    @objc
    private func switchAccount(_ sender: NSButton) {
        guard
            !isSwitching,
            let rawID = sender.identifier?.rawValue,
            let accountID = UUID(uuidString: rawID),
            let account = launcher.accounts.first(where: { $0.id == accountID })
        else {
            return
        }

        isSwitching = true
        showTransientStatus("\(account.name) へ切り替え中…")

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isSwitching = false }

            do {
                try await self.launcher.switchTo(accountID: accountID)
                self.refreshUI()
            } catch {
                self.refreshUI()
                self.presentError(error)
            }
        }
    }

    @objc
    private func revealProfiles() {
        do {
            let directory = try launcher.profileBaseDirectory()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            NSWorkspace.shared.open(directory)
        } catch {
            presentError(error, title: "プロファイル保存先を開けませんでした")
        }
    }

    private func presentError(
        _ error: Error,
        title: String = "アカウントを切り替えられませんでした"
    ) {
        showMainWindow()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
