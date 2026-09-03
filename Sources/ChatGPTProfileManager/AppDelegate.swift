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
    private var settingsWindow: NSWindow?
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
    private var settingsButton: NSButton?
    private weak var settingsLanguagePopup: NSPopUpButton?
    private var storageChoiceButtons: [NSButton] = []
    private var usageByAccountID: [UUID: AccountUsageSnapshot] = [:]
    private var usageRefreshTask: Task<Void, Never>?
    private var isRebuildingInterface = false
    private var isLaunching = false {
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
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.addObserver(
            self,
            selector: #selector(chatGPTApplicationStateChanged(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        workspaceNotifications.addObserver(
            self,
            selector: #selector(chatGPTApplicationStateChanged(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        showMainWindow()

        DispatchQueue.main.async { [weak self] in
            self?.prepareInitialExperience()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshUI()
        refreshUsage()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc
    private func chatGPTApplicationStateChanged(_ notification: Notification) {
        guard
            let application = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication,
            application.bundleIdentifier == CodexLauncher.codexBundleIdentifier
        else {
            return
        }

        refreshUI()
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        !isRebuildingInterface
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
            let closingWindow = notification.object as? NSWindow
        else {
            return
        }

        if closingWindow === settingsWindow {
            settingsWindow = nil
            settingsLanguagePopup = nil
            return
        }

        guard closingWindow === guideWindow else {
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
            withTitle: L10n.text(
                "menu.about",
                fallback: "ChatGPT Profile Managerについて"
            ),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            withTitle: L10n.text(
                "menu.quit",
                fallback: "ChatGPT Profile Managerを終了"
            ),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        applicationMenuItem.submenu = applicationMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(
            title: L10n.text("menu.window", fallback: "ウィンドウ")
        )
        windowMenu.addItem(
            withTitle: L10n.text("menu.window.close", fallback: "ウィンドウを閉じる"),
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        windowMenu.addItem(
            withTitle: L10n.text("menu.window.minimize", fallback: "しまう"),
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
            wrappingLabelWithString: L10n.text(
                "main.subtitle",
                fallback: "ChatGPTアカウントごとに保存先を分け、複数のプロファイルを並列で起動します。"
            )
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
        launchStatusCard.setAccessibilityLabel(
            L10n.text(
                "last-launched.accessibility-label",
                fallback: "最後に起動したアカウント"
            )
        )

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
                accessibilityDescription: L10n.text(
                    "last-launched.title",
                    fallback: "最後に起動"
                )
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

        let launchStatusTitleLabel = NSTextField(
            labelWithString: L10n.text(
                "last-launched.title",
                fallback: "最後に起動"
            )
        )
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

        let accountHeaderLabel = NSTextField(
            labelWithString: L10n.text("accounts.title", fallback: "アカウント")
        )
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
            title: L10n.text("accounts.add", fallback: "アカウントを追加"),
            target: self,
            action: #selector(addAccount)
        )
        addButton.bezelStyle = .rounded
        addButton.controlSize = .large
        addButton.keyEquivalent = "+"
        addButton.setAccessibilityLabel(
            L10n.text("accounts.add", fallback: "アカウントを追加")
        )
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
        tableView.setAccessibilityLabel(
            L10n.text(
                "accounts.registered.accessibility-label",
                fallback: "登録済みアカウント"
            )
        )
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

        let managementHeader = NSTextField(
            labelWithString: L10n.text("management.title", fallback: "管理")
        )
        managementHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        managementHeader.alignment = .left
        managementHeader.textColor = .secondaryLabelColor
        mainStack.addArrangedSubview(managementHeader)

        let utilityButtons = NSStackView()
        utilityButtons.orientation = .horizontal
        utilityButtons.alignment = .centerY
        utilityButtons.spacing = 12
        utilityButtons.translatesAutoresizingMaskIntoConstraints = false

        let settingsButton = NSButton(
            title: L10n.text("management.settings", fallback: "設定"),
            target: self,
            action: #selector(showSettings)
        )
        settingsButton.bezelStyle = .rounded
        settingsButton.controlSize = .regular
        settingsButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        settingsButton.contentTintColor = .controlAccentColor
        settingsButton.image = NSImage(
            systemSymbolName: "gearshape",
            accessibilityDescription: nil
        )
        settingsButton.imagePosition = .imageLeading
        settingsButton.setAccessibilityLabel(
            L10n.text(
                "management.settings.accessibility-label",
                fallback: "アプリの設定を開く"
            )
        )

        let revealButton = NSButton(
            title: L10n.text("management.open-storage", fallback: "保存先を開く"),
            target: self,
            action: #selector(revealProfiles)
        )
        revealButton.bezelStyle = .rounded
        revealButton.controlSize = .regular
        revealButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        revealButton.contentTintColor = .controlAccentColor
        revealButton.setAccessibilityLabel(
            L10n.text(
                "management.open-storage.accessibility-label",
                fallback: "プロファイル保存先を開く"
            )
        )

        let guideButton = NSButton(
            title: L10n.text("management.show-guide", fallback: "仕組みを見る"),
            target: self,
            action: #selector(showMechanismGuide)
        )
        guideButton.bezelStyle = .rounded
        guideButton.controlSize = .regular
        guideButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        guideButton.contentTintColor = .controlAccentColor
        guideButton.setAccessibilityLabel(
            L10n.text(
                "management.show-guide.accessibility-label",
                fallback: "このアプリの仕組みを見る"
            )
        )

        utilityButtons.addArrangedSubview(settingsButton)
        utilityButtons.addArrangedSubview(revealButton)
        utilityButtons.addArrangedSubview(guideButton)
        mainStack.addArrangedSubview(utilityButtons)

        self.revealButton = revealButton
        self.settingsButton = settingsButton

        self.window = window
    }

    private func showMainWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshUI() {
        let accounts = launcher.accounts
        accountCountLabel?.stringValue = L10n.accountCount(accounts.count)

        updateLaunchStatus()
        statusLabel?.stringValue = ""
        statusLabel?.isHidden = true

        tableView?.reloadData()
        updateTableHeight(accountCount: accounts.count)
        updateControlAvailability()
    }

    private func updateLaunchStatus() {
        launchStatusTitleLabel?.stringValue = L10n.text(
            "last-launched.title",
            fallback: "最後に起動"
        )
        if let lastAccount = launcher.lastLaunchedAccount {
            let environment = lastAccount.id == launcher.existingEnvironmentAccount?.id
                ? L10n.text("profile.existing", fallback: "既存環境")
                : L10n.text("profile.isolated", fallback: "分離プロファイル")
            launchStatusDetailLabel?.stringValue = L10n.text(
                "last-launched.detail",
                fallback: "{name}（{environment}）",
                replacing: [
                    "name": lastAccount.name,
                    "environment": environment
                ]
            )
        } else if launcher.accounts.isEmpty {
            launchStatusDetailLabel?.stringValue = L10n.text(
                "last-launched.empty",
                fallback: "アカウントを追加するとここに表示されます"
            )
        } else {
            launchStatusDetailLabel?.stringValue = L10n.text(
                "last-launched.none",
                fallback: "このアプリから起動したアカウントはありません"
            )
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
        addButton?.isEnabled = !isLaunching
        tableView?.isEnabled = !isLaunching
        revealButton?.isEnabled = !isLaunching
        settingsButton?.isEnabled = !isLaunching
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
                accessibilityDescription: L10n.text(
                    "account.reorder",
                    fallback: "ドラッグして並び替え"
                )
            ) ?? NSImage()
        )
        dragHandle.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 13,
            weight: .medium
        )
        dragHandle.contentTintColor = .secondaryLabelColor
        dragHandle.toolTip = L10n.text(
            "account.reorder",
            fallback: "ドラッグして並び替え"
        )
        dragHandle.setAccessibilityLabel(
            L10n.text(
                "account.reorder.accessibility-label",
                fallback: "{name}をドラッグして並び替え",
                replacing: ["name": account.name]
            )
        )
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
        let isRunning = launcher.isAccountRunning(id: account.id)
        let usageSnapshot = usageByAccountID[account.id]
        let metadataStack = NSStackView()
        metadataStack.orientation = .horizontal
        metadataStack.alignment = .centerY
        metadataStack.spacing = 6

        let badge = ProfileBadgeView(
            text: isExisting
                ? L10n.text("profile.existing", fallback: "既存環境")
                : L10n.text("profile.isolated", fallback: "分離プロファイル"),
            color: isExisting ? .systemBlue : .systemPurple
        )
        metadataStack.addArrangedSubview(badge)

        if let binding = launcher.settingsBinding(for: account),
           let group = launcher.settingsGroups().first(where: { $0.id == binding.groupID }) {
            metadataStack.addArrangedSubview(
                ProfileBadgeView(
                    text: L10n.text(
                        "settings-sharing.badge",
                        fallback: "共有中：{name}",
                        replacing: ["name": group.name]
                    ),
                    color: .systemOrange
                )
            )
        }

        if isRunning {
            metadataStack.addArrangedSubview(
                ProfileBadgeView(
                    text: L10n.text("profile.running", fallback: "起動中"),
                    color: .systemGreen
                )
            )
        }

        let planLabel = NSTextField(
            labelWithString: L10n.text(
                "usage.plan",
                fallback: "プラン: {plan}",
                replacing: ["plan": usageSnapshot?.displayPlanName ?? "—"]
            )
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
                title: L10n.text("usage.weekly", fallback: "週間"),
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
                ? L10n.text(
                    "profile.storage.existing",
                    fallback: "保存先: ChatGPTの既定環境"
                )
                : L10n.text(
                    "profile.storage.isolated",
                    fallback: "保存先: {directory}",
                    replacing: ["directory": account.directoryName]
                )
        )
        directoryLabel.font = .systemFont(ofSize: 11)
        directoryLabel.textColor = .tertiaryLabelColor
        directoryLabel.lineBreakMode = .byTruncatingMiddle
        directoryLabel.maximumNumberOfLines = 1
        directoryLabel.toolTip = isExisting
            ? L10n.text(
                "profile.storage.existing-name",
                fallback: "ChatGPTの既定環境"
            )
            : account.directoryName
        directoryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labels.addArrangedSubview(directoryLabel)
        rowStack.addArrangedSubview(labels)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rowStack.addArrangedSubview(spacer)

        let renameButton = NSButton(
            title: L10n.text("account.rename", fallback: "名前を変更"),
            target: self,
            action: #selector(renameAccount(_:))
        )
        renameButton.bezelStyle = .inline
        renameButton.controlSize = .regular
        renameButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        renameButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        renameButton.identifier = NSUserInterfaceItemIdentifier(account.id.uuidString)
        renameButton.setAccessibilityLabel(
            L10n.text(
                "account.rename.accessibility-label",
                fallback: "{name}の名前を変更",
                replacing: ["name": account.name]
            )
        )
        rowStack.addArrangedSubview(renameButton)

        let settingsButton = NSButton(
            title: L10n.text("settings-sharing.manage", fallback: "設定"),
            target: self,
            action: #selector(manageAccountSettings(_:))
        )
        settingsButton.bezelStyle = .inline
        settingsButton.controlSize = .regular
        settingsButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        settingsButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        settingsButton.identifier = NSUserInterfaceItemIdentifier(account.id.uuidString)
        settingsButton.setAccessibilityLabel(
            L10n.text(
                "settings-sharing.manage.accessibility-label",
                fallback: "{name}の設定を管理",
                replacing: ["name": account.name]
            )
        )
        rowStack.addArrangedSubview(settingsButton)

        let openButton = NSButton(
            title: isRunning
                ? L10n.text("account.quit", fallback: "終了")
                : L10n.text("account.open", fallback: "起動"),
            target: self,
            action: isRunning
                ? #selector(quitAccount(_:))
                : #selector(openAccount(_:))
        )
        openButton.bezelStyle = .rounded
        openButton.controlSize = .large
        openButton.isBordered = false
        openButton.wantsLayer = true
        openButton.layer?.backgroundColor = isRunning
            ? NSColor.systemRed.withAlphaComponent(0.88).cgColor
            : NSColor.controlAccentColor.cgColor
        openButton.layer?.cornerRadius = 7
        openButton.contentTintColor = .white
        openButton.font = .systemFont(ofSize: 13, weight: .semibold)
        openButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true
        openButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        openButton.identifier = NSUserInterfaceItemIdentifier(account.id.uuidString)
        openButton.isEnabled = !isLaunching
        openButton.setAccessibilityLabel(
            isRunning
                ? L10n.text(
                    "account.quit.accessibility-label",
                    fallback: "{name}のChatGPTを終了",
                    replacing: ["name": account.name]
                )
                : L10n.text(
                    "account.open.accessibility-label",
                    fallback: "{name}のChatGPTを起動",
                    replacing: ["name": account.name]
                )
        )
        openButton.toolTip = isRunning
            ? L10n.text(
                "account.quit.tooltip",
                fallback: "このプロファイルのChatGPTを終了"
            )
            : nil
        rowStack.addArrangedSubview(openButton)

        if !isExisting {
            let deleteButton = NSButton(
                title: L10n.text("account.delete", fallback: "削除"),
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
            deleteButton.isEnabled = !isLaunching && !isRunning
            deleteButton.setAccessibilityLabel(
                L10n.text(
                    "account.delete.accessibility-label",
                    fallback: "{name}の登録を削除",
                    replacing: ["name": account.name]
                )
            )
            deleteButton.toolTip = L10n.text(
                "account.delete.tooltip",
                fallback: "アカウント登録だけを削除（保存先は保持）"
            )
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
                L10n.text(
                    "usage.resets-at",
                    fallback: "{date}にリセット",
                    replacing: [
                        "date": formatResetDate($0, style: resetDateStyle)
                    ]
                )
            } ?? L10n.text(
                "usage.reset-time-unavailable",
                fallback: "リセット時刻不明"
            )
            value = L10n.text(
                "usage.remaining",
                fallback: "{title} 残り {remaining}% {reset}",
                replacing: [
                    "title": title,
                    "remaining": "\(window.remainingPercent)",
                    "reset": resetDescription
                ]
            )
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
            } ?? L10n.text("common.unknown", fallback: "不明")
            label.toolTip = L10n.text(
                "usage.tooltip",
                fallback: "{title}：使用済み {used}%、残り {remaining}%\n{date}にリセット",
                replacing: [
                    "title": title,
                    "used": "\(window.usedPercent)",
                    "remaining": "\(window.remainingPercent)",
                    "date": resetTooltip
                ]
            )
        } else {
            label.toolTip = L10n.text(
                "usage.unavailable.tooltip",
                fallback: "{title}の利用状況を取得できませんでした。ChatGPTを開いてから再度確認してください。",
                replacing: ["title": title]
            )
        }
        return label
    }

    private func makeResetCreditLabels(
        _ summary: RateLimitResetCreditsSummary
    ) -> [NSTextField] {
        var labels: [NSTextField] = []
        let titleLabel = NSTextField(
            labelWithString: L10n.resetCreditCount(summary.availableCount)
        )
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .systemOrange
        titleLabel.toolTip = L10n.text(
            summary.availableCount == 1
                ? "usage.reset-credits.tooltip.one"
                : "usage.reset-credits.tooltip.other",
            fallback: "利用できる上限リセットクレジット: {count}件",
            replacing: ["count": "\(summary.availableCount)"]
        )
        labels.append(titleLabel)

        if let credits = summary.credits, !credits.isEmpty {
            for credit in credits {
                let expiryText = credit.expiresAt.map {
                    formatResetDate($0, style: .monthDayAndTime)
                } ?? L10n.text(
                    "usage.reset-credit.expiry-unknown",
                    fallback: "有効期限不明"
                )
                let expiryLabel = NSTextField(
                    labelWithString: L10n.text(
                        "usage.reset-credit.expiry",
                        fallback: "・{date}",
                        replacing: ["date": expiryText]
                    )
                )
                expiryLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
                expiryLabel.textColor = .secondaryLabelColor
                expiryLabel.setContentHuggingPriority(.required, for: .horizontal)
                expiryLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
                labels.append(expiryLabel)
            }

            let missingCount = summary.availableCount - credits.count
            if missingCount > 0 {
                let missingLabel = NSTextField(
                    labelWithString: L10n.text(
                        missingCount == 1
                            ? "usage.reset-credit.missing.one"
                            : "usage.reset-credit.missing.other",
                        fallback: "・有効期限不明 {count}件",
                        replacing: ["count": "\(missingCount)"]
                    )
                )
                missingLabel.font = .systemFont(ofSize: 10)
                missingLabel.textColor = .tertiaryLabelColor
                labels.append(missingLabel)
            }
        } else {
            let unavailableLabel = NSTextField(
                labelWithString: L10n.text(
                    "usage.reset-credit.expiry-unavailable",
                    fallback: "・有効期限は未取得"
                )
            )
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
        formatter.locale = L10n.language.locale
        switch style {
        case .timeOnly:
            formatter.dateFormat = "HH:mm"
        case .monthDayAndTime:
            formatter.dateFormat = L10n.language == .japanese
                ? "M月d日 HH:mm"
                : "MMM d, HH:mm"
        }
        return formatter.string(from: date)
    }

    func tableView(
        _ tableView: NSTableView,
        pasteboardWriterForRow row: Int
    ) -> NSPasteboardWriting? {
        let accounts = launcher.accounts
        guard !isLaunching, accounts.indices.contains(row) else {
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
            !isLaunching,
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
            !isLaunching,
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
            showTransientStatus(
                L10n.text(
                    "account.reorder.success",
                    fallback: "{name} の並び順を変更しました。",
                    replacing: ["name": account.name]
                )
            )
            return true
        } catch {
            presentError(
                error,
                title: L10n.text(
                    "account.reorder.error-title",
                    fallback: "並び順を変更できませんでした"
                )
            )
            return false
        }
    }

    @objc
    private func addAccount() {
        presentAddAccount()
    }

    @objc
    private func manageAccountSettings(_ sender: NSButton) {
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
        alert.messageText = L10n.text(
            "settings-sharing.manage-title",
            fallback: "「{name}」の設定を管理",
            replacing: ["name": account.name]
        )
        alert.informativeText = L10n.text(
            "settings-sharing.manage-message",
            fallback: "ChatGPTのアカウント、チャット、プロジェクト、ログイン状態は対象外です。ここで扱うのはCodexのローカル設定だけです。"
        )
        let isShared = launcher.settingsBinding(for: account) != nil
        if isShared {
            alert.addButton(
                withTitle: L10n.text(
                    "settings-sharing.leave",
                    fallback: "共有を解除して現在の設定を保持"
                )
            )
        } else {
            alert.addButton(
                withTitle: L10n.text(
                    "settings-sharing.share",
                    fallback: "設定を共有"
                )
            )
        }
        alert.addButton(
            withTitle: L10n.text(
                "settings-sharing.copy",
                fallback: "設定をコピー"
            )
        )
        alert.addButton(withTitle: L10n.text("common.cancel", fallback: "キャンセル"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if isShared {
                leaveSettingsShare(accountID: accountID)
            } else {
                presentCreateSettingsShare(sourceAccountID: accountID)
            }
        case .alertSecondButtonReturn:
            presentCopySettings(destinationAccountID: accountID)
        default:
            break
        }
    }

    private func presentCreateSettingsShare(sourceAccountID: UUID) {
        guard let sourceAccount = launcher.accounts.first(where: { $0.id == sourceAccountID }) else {
            presentError(ProfileManagerError.accountNotFound)
            return
        }
        let destinations = launcher.accounts.filter { $0.id != sourceAccountID }
        guard !destinations.isEmpty else {
            presentError(
                SettingsSharingError.sourceAndDestinationAreSame,
                title: L10n.text(
                    "settings-sharing.error.title",
                    fallback: "設定を共有できませんでした"
                )
            )
            return
        }

        let groupNameField = NSTextField(string: "\(sourceAccount.name) 共有")
        groupNameField.placeholderString = L10n.text(
            "settings-sharing.group-placeholder",
            fallback: "共有グループ名"
        )
        groupNameField.translatesAutoresizingMaskIntoConstraints = false
        groupNameField.widthAnchor.constraint(equalToConstant: 420).isActive = true

        let destinationStack = NSStackView()
        destinationStack.orientation = .vertical
        destinationStack.alignment = .leading
        destinationStack.spacing = 4
        var destinationButtons: [UUID: NSButton] = [:]
        for destination in destinations {
            let button = NSButton(
                checkboxWithTitle: destination.name,
                target: nil,
                action: nil
            )
            button.setButtonType(.switch)
            button.identifier = NSUserInterfaceItemIdentifier(destination.id.uuidString)
            destinationStack.addArrangedSubview(button)
            destinationButtons[destination.id] = button
        }

        let itemStack = makeManagedSettingCheckboxes(
            defaults: [.instructions]
        )
        let accessory = NSStackView()
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 10
        accessory.addArrangedSubview(
            NSTextField(labelWithString: L10n.text("settings-sharing.group-name", fallback: "共有グループ名"))
        )
        accessory.addArrangedSubview(groupNameField)
        accessory.addArrangedSubview(
            NSTextField(labelWithString: L10n.text("settings-sharing.members", fallback: "共有するプロファイル"))
        )
        accessory.addArrangedSubview(destinationStack)
        accessory.addArrangedSubview(
            NSTextField(labelWithString: L10n.text("settings-sharing.items", fallback: "共有する設定"))
        )
        accessory.addArrangedSubview(itemStack.view)
        accessory.setFrameSize(NSSize(width: 430, height: accessory.fittingSize.height))

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text(
            "settings-sharing.create-title",
            fallback: "設定共有を作成"
        )
        alert.informativeText = L10n.text(
            "settings-sharing.create-message",
            fallback: "共有設定はアプリ管理下の共通ファイルになります。参加するすべてのChatGPTを終了してから適用します。"
        )
        alert.addButton(
            withTitle: L10n.text("settings-sharing.create", fallback: "共有を作成")
        )
        alert.addButton(
            withTitle: L10n.text("settings-sharing.join-existing", fallback: "既存の共有へ参加")
        )
        alert.addButton(withTitle: L10n.text("common.cancel", fallback: "キャンセル"))
        alert.accessoryView = accessory

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let selectedDestinations = destinations.filter {
                destinationButtons[$0.id]?.state == .on
            }
            let selectedItems = Set(
                itemStack.buttons.compactMap { setting, button in
                    button.state == .on ? setting : nil
                }
            )
            guard !selectedDestinations.isEmpty, !selectedItems.isEmpty else {
                showTransientStatus(
                    L10n.text(
                        "settings-sharing.selection-required",
                        fallback: "共有先と共有項目を1つ以上選択してください。"
                    )
                )
                return
            }
            do {
                let group = try launcher.createSettingsShare(
                    named: groupNameField.stringValue,
                    sourceAccountID: sourceAccountID,
                    destinationAccountIDs: selectedDestinations.map(\.id),
                    items: selectedItems
                )
                refreshUI()
                showTransientStatus(
                    L10n.text(
                        "settings-sharing.created-success",
                        fallback: "設定共有「{name}」を作成しました。ChatGPTの次回起動から反映されます。",
                        replacing: ["name": group.name]
                    )
                )
            } catch {
                presentError(
                    error,
                    title: L10n.text(
                        "settings-sharing.error.title",
                        fallback: "設定を共有できませんでした"
                    )
                )
            }
        case .alertSecondButtonReturn:
            presentJoinSettingsShare(accountID: sourceAccountID)
        default:
            break
        }
    }

    private func presentJoinSettingsShare(accountID: UUID) {
        guard let account = launcher.accounts.first(where: { $0.id == accountID }) else {
            presentError(ProfileManagerError.accountNotFound)
            return
        }
        let profile = launcher.settingsStorageReference(for: account)
        let groups = launcher.settingsGroups().filter { !$0.members.contains(profile) }
        guard !groups.isEmpty else {
            presentError(
                SettingsSharingError.groupNotFound,
                title: L10n.text(
                    "settings-sharing.error.title",
                    fallback: "既存の共有へ参加できませんでした"
                )
            )
            return
        }

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 26))
        popup.addItems(withTitles: groups.map(\.name))
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text(
            "settings-sharing.join-title",
            fallback: "既存の設定共有へ参加"
        )
        alert.informativeText = L10n.text(
            "settings-sharing.join-message",
            fallback: "「{name}」の選択した設定を共通ファイルへ切り替えます。現在の設定はバックアップされます。",
            replacing: ["name": account.name]
        )
        alert.accessoryView = popup
        alert.addButton(withTitle: L10n.text("settings-sharing.join", fallback: "参加"))
        alert.addButton(withTitle: L10n.text("common.cancel", fallback: "キャンセル"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let group = try launcher.joinSettingsShare(
                groupID: groups[popup.indexOfSelectedItem].id,
                accountID: accountID
            )
            refreshUI()
            showTransientStatus(
                L10n.text(
                    "settings-sharing.joined-success",
                    fallback: "「{name}」の設定共有へ参加しました。ChatGPTの次回起動から反映されます。",
                    replacing: ["name": group.name]
                )
            )
        } catch {
            presentError(
                error,
                title: L10n.text(
                    "settings-sharing.error.title",
                    fallback: "設定共有へ参加できませんでした"
                )
            )
        }
    }

    private func presentCopySettings(destinationAccountID: UUID) {
        guard let destination = launcher.accounts.first(where: { $0.id == destinationAccountID }) else {
            presentError(ProfileManagerError.accountNotFound)
            return
        }
        let sources = launcher.accounts.filter { $0.id != destinationAccountID }
        guard !sources.isEmpty else {
            presentError(
                SettingsSharingError.sourceAndDestinationAreSame,
                title: L10n.text(
                    "settings-sharing.error.title",
                    fallback: "設定をコピーできませんでした"
                )
            )
            return
        }

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 26))
        popup.addItems(withTitles: sources.map(\.name))
        let itemStack = makeManagedSettingCheckboxes(
            defaults: [.instructions, .config]
        )
        let accessory = NSStackView()
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 10
        accessory.addArrangedSubview(
            NSTextField(labelWithString: L10n.text("settings-sharing.source", fallback: "コピー元"))
        )
        accessory.addArrangedSubview(popup)
        accessory.addArrangedSubview(
            NSTextField(labelWithString: L10n.text("settings-sharing.items", fallback: "コピーする設定"))
        )
        accessory.addArrangedSubview(itemStack.view)
        accessory.setFrameSize(NSSize(width: 430, height: accessory.fittingSize.height))

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text(
            "settings-sharing.copy-title",
            fallback: "別のプロファイルから設定をコピー"
        )
        alert.informativeText = L10n.text(
            "settings-sharing.copy-message",
            fallback: "コピー先「{name}」の同名設定はバックアップして置き換えます。auth.json、セッション、チャット、プロジェクトはコピーしません。config.tomlを選ぶ場合は内容を確認してください。",
            replacing: ["name": destination.name]
        )
        alert.accessoryView = accessory
        alert.addButton(withTitle: L10n.text("settings-sharing.copy-confirm", fallback: "コピー"))
        alert.addButton(withTitle: L10n.text("common.cancel", fallback: "キャンセル"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let selectedItems = Set(
            itemStack.buttons.compactMap { setting, button in
                button.state == .on ? setting : nil
            }
        )
        guard !selectedItems.isEmpty else {
            showTransientStatus(
                L10n.text(
                    "settings-sharing.selection-required",
                    fallback: "コピーする設定を1つ以上選択してください。"
                )
            )
            return
        }

        do {
            let summary = try launcher.copySettings(
                from: sources[popup.indexOfSelectedItem].id,
                to: destinationAccountID,
                items: selectedItems
            )
            showTransientStatus(
                L10n.text(
                    "settings-sharing.copied-success",
                    fallback: "{count}項目を「{name}」へコピーしました。ChatGPTの次回起動から反映されます。",
                    replacing: [
                        "count": "\(summary.changedItems.count)",
                        "name": destination.name
                    ]
                )
            )
        } catch {
            presentError(
                error,
                title: L10n.text(
                    "settings-sharing.error.title",
                    fallback: "設定をコピーできませんでした"
                )
            )
        }
    }

    private func leaveSettingsShare(accountID: UUID) {
        do {
            let group = try launcher.leaveSettingsShare(for: accountID)
            refreshUI()
            showTransientStatus(
                L10n.text(
                    "settings-sharing.left-success",
                    fallback: "「{name}」の共有を解除し、現在の設定を保持しました。",
                    replacing: ["name": group.name]
                )
            )
        } catch {
            presentError(
                error,
                title: L10n.text(
                    "settings-sharing.error.title",
                    fallback: "設定共有を解除できませんでした"
                )
            )
        }
    }

    private func makeManagedSettingCheckboxes(
        defaults: Set<ManagedSetting>
    ) -> (view: NSStackView, buttons: [ManagedSetting: NSButton]) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        var buttons: [ManagedSetting: NSButton] = [:]
        for setting in ManagedSetting.allCases {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 4

            let button = NSButton(
                checkboxWithTitle: setting.displayName,
                target: nil,
                action: nil
            )
            button.state = defaults.contains(setting) ? .on : .off
            row.addArrangedSubview(button)

            let helpButton = NSButton(
                image: NSImage(
                    systemSymbolName: "questionmark.circle",
                    accessibilityDescription: L10n.text(
                        "settings-sharing.help-tooltip",
                        fallback: "この設定項目の説明を表示"
                    )
                ) ?? NSImage(),
                target: self,
                action: #selector(showManagedSettingExplanation(_:))
            )
            helpButton.bezelStyle = .inline
            helpButton.isBordered = false
            helpButton.contentTintColor = .secondaryLabelColor
            helpButton.imagePosition = .imageOnly
            helpButton.identifier = NSUserInterfaceItemIdentifier(setting.rawValue)
            helpButton.widthAnchor.constraint(equalToConstant: 20).isActive = true
            helpButton.heightAnchor.constraint(equalToConstant: 20).isActive = true
            helpButton.setContentHuggingPriority(.required, for: .horizontal)
            helpButton.setContentCompressionResistancePriority(.required, for: .horizontal)
            helpButton.toolTip = L10n.text(
                "settings-sharing.help-tooltip",
                fallback: "この設定項目の説明を表示"
            )
            helpButton.setAccessibilityLabel(
                L10n.text(
                    "settings-sharing.help-accessibility-label",
                    fallback: "{setting}の説明を表示",
                    replacing: ["setting": setting.displayName]
                )
            )
            row.addArrangedSubview(helpButton)

            stack.addArrangedSubview(row)
            buttons[setting] = button
        }
        return (stack, buttons)
    }

    @objc
    private func showManagedSettingExplanation(_ sender: NSButton) {
        guard
            let rawValue = sender.identifier?.rawValue,
            let setting = ManagedSetting(rawValue: rawValue)
        else {
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = setting.displayName
        var message = setting.explanation
        if let warning = setting.warning {
            message += "\n\n" + L10n.text(
                "settings-sharing.explanation-caution",
                fallback: "注意：{warning}",
                replacing: ["warning": warning]
            )
        }
        alert.informativeText = message
        alert.addButton(withTitle: L10n.text("common.ok", fallback: "OK"))
        alert.runModal()
    }

    private func presentProfileDirectoryChoice(
        for name: String,
        candidates: [IsolatedProfileCandidate]
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.text(
            "profile-choice.title",
            fallback: "使用する分離プロファイルを選択"
        )
        alert.informativeText = L10n.text(
            "profile-choice.message",
            fallback: "「{name}」で使う分離プロファイルを選択してください。フォルダの内容はコピー・移動せず、選択した保存先をそのまま登録します。ChatGPTの既存環境とは別の保存先です。",
            replacing: ["name": name]
        )
        alert.addButton(
            withTitle: L10n.text(
                "storage-choice.add-button",
                fallback: "この保存先で追加"
            )
        )
        alert.addButton(
            withTitle: L10n.text("common.cancel", fallback: "キャンセル")
        )

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 430, height: 26))
        popup.controlSize = .regular
        popup.setAccessibilityLabel(
            L10n.text(
                "profile-choice.accessibility-label",
                fallback: "使用する分離プロファイルの保存先"
            )
        )
        candidates.forEach { popup.addItem(withTitle: $0.directoryName) }
        alert.accessoryView = popup

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        let selectedIndex = popup.indexOfSelectedItem
        guard candidates.indices.contains(selectedIndex) else {
            presentError(
                ProfileManagerError.profileDirectoryNotFound,
                title: L10n.text(
                    "profile-choice.error-title",
                    fallback: "既存フォルダを登録できませんでした"
                )
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
    private func showSettings() {
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = L10n.text(
            "settings.window-title",
            fallback: "設定"
        )
        settingsWindow.tabbingMode = .disallowed
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.center()
        settingsWindow.delegate = self

        let contentView = NSView()
        settingsWindow.contentView = contentView

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 18
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -22)
        ])

        let headerStack = NSStackView()
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 12
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView(
            image: NSImage(
                systemSymbolName: "gearshape.fill",
                accessibilityDescription: nil
            ) ?? NSImage()
        )
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 24,
            weight: .medium
        )
        iconView.contentTintColor = .controlAccentColor
        iconView.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 34),
            iconView.heightAnchor.constraint(equalToConstant: 34)
        ])

        let headerLabels = NSStackView()
        headerLabels.orientation = .vertical
        headerLabels.alignment = .leading
        headerLabels.spacing = 3

        let titleLabel = NSTextField(
            labelWithString: L10n.text(
                "settings.header-title",
                fallback: "ChatGPT Profile Managerの設定"
            )
        )
        titleLabel.font = .systemFont(ofSize: 19, weight: .semibold)

        let subtitleLabel = NSTextField(
            wrappingLabelWithString: L10n.text(
                "settings.header-subtitle",
                fallback: "アプリの表示言語を設定します。"
            )
        )
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor

        headerLabels.addArrangedSubview(titleLabel)
        headerLabels.addArrangedSubview(subtitleLabel)
        headerStack.addArrangedSubview(iconView)
        headerStack.addArrangedSubview(headerLabels)
        rootStack.addArrangedSubview(headerStack)
        headerStack.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

        let languageCard = ProfileCardView()
        languageCard.translatesAutoresizingMaskIntoConstraints = false

        let languageStack = NSStackView()
        languageStack.orientation = .vertical
        languageStack.alignment = .leading
        languageStack.spacing = 10
        languageStack.translatesAutoresizingMaskIntoConstraints = false
        languageCard.addSubview(languageStack)
        NSLayoutConstraint.activate([
            languageStack.leadingAnchor.constraint(equalTo: languageCard.leadingAnchor, constant: 16),
            languageStack.trailingAnchor.constraint(equalTo: languageCard.trailingAnchor, constant: -16),
            languageStack.topAnchor.constraint(equalTo: languageCard.topAnchor, constant: 14),
            languageStack.bottomAnchor.constraint(equalTo: languageCard.bottomAnchor, constant: -14)
        ])

        let languageRow = NSStackView()
        languageRow.orientation = .horizontal
        languageRow.alignment = .centerY
        languageRow.spacing = 12
        languageRow.translatesAutoresizingMaskIntoConstraints = false

        let languageTitle = NSTextField(
            labelWithString: L10n.text(
                "settings.language.title",
                fallback: "表示言語"
            )
        )
        languageTitle.font = .systemFont(ofSize: 13, weight: .semibold)

        let languagePopup = NSPopUpButton()
        languagePopup.controlSize = .regular
        languagePopup.setAccessibilityLabel(
            L10n.text(
                "settings.language.accessibility-label",
                fallback: "アプリの表示言語"
            )
        )
        let automaticLanguageName = localizedLanguageName(L10n.systemLanguage)
        let preferenceTitles = [
            L10n.text(
                "settings.language.automatic",
                fallback: "Macの設定に従う（現在：{language}）",
                replacing: ["language": automaticLanguageName]
            ),
            L10n.text("settings.language.japanese", fallback: "日本語"),
            L10n.text("settings.language.english", fallback: "English")
        ]
        languagePopup.addItems(withTitles: preferenceTitles)
        if let selectedIndex = AppLanguagePreference.allCases.firstIndex(
            of: L10n.languagePreference
        ) {
            languagePopup.selectItem(at: selectedIndex)
        }
        languagePopup.setContentHuggingPriority(.required, for: .horizontal)

        languageRow.addArrangedSubview(languageTitle)
        languageRow.addArrangedSubview(NSView())
        languageRow.addArrangedSubview(languagePopup)
        languageStack.addArrangedSubview(languageRow)
        languageRow.widthAnchor.constraint(equalTo: languageStack.widthAnchor).isActive = true

        let languageDescription = NSTextField(
            wrappingLabelWithString: L10n.text(
                "settings.language.description",
                fallback: "「Macの設定に従う」では、Macの第一優先言語が日本語なら日本語、それ以外なら英語で表示します。日本語またはEnglishを選ぶと、Macの設定より優先されます。"
            )
        )
        languageDescription.font = .systemFont(ofSize: 12)
        languageDescription.textColor = .secondaryLabelColor
        languageDescription.maximumNumberOfLines = 3
        languageStack.addArrangedSubview(languageDescription)
        languageDescription.widthAnchor.constraint(equalTo: languageStack.widthAnchor).isActive = true

        let dataNote = NSTextField(
            wrappingLabelWithString: L10n.text(
                "settings.language.data-note",
                fallback: "表示言語を変更しても、アカウント名、保存先、プロジェクト、チャットは変更されません。"
            )
        )
        dataNote.font = .systemFont(ofSize: 11)
        dataNote.textColor = .tertiaryLabelColor
        dataNote.maximumNumberOfLines = 2
        languageStack.addArrangedSubview(dataNote)
        dataNote.widthAnchor.constraint(equalTo: languageStack.widthAnchor).isActive = true

        rootStack.addArrangedSubview(languageCard)
        languageCard.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

        let footerStack = NSStackView()
        footerStack.orientation = .horizontal
        footerStack.alignment = .centerY
        footerStack.spacing = 10
        footerStack.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(
            title: L10n.text("common.cancel", fallback: "キャンセル"),
            target: self,
            action: #selector(closeSettings)
        )
        cancelButton.bezelStyle = .rounded

        let applyButton = NSButton(
            title: L10n.text("settings.apply", fallback: "適用"),
            target: self,
            action: #selector(applySettings)
        )
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"

        footerStack.addArrangedSubview(NSView())
        footerStack.addArrangedSubview(cancelButton)
        footerStack.addArrangedSubview(applyButton)
        rootStack.addArrangedSubview(footerStack)
        footerStack.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

        self.settingsWindow = settingsWindow
        settingsLanguagePopup = languagePopup
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func localizedLanguageName(_ language: AppLanguage) -> String {
        switch language {
        case .japanese:
            return L10n.text("settings.language.japanese", fallback: "日本語")
        case .english:
            return L10n.text("settings.language.english", fallback: "English")
        }
    }

    @objc
    private func closeSettings() {
        settingsWindow?.performClose(nil)
    }

    @objc
    private func applySettings() {
        guard
            let selectedIndex = settingsLanguagePopup?.indexOfSelectedItem,
            AppLanguagePreference.allCases.indices.contains(selectedIndex)
        else {
            return
        }

        let previousLanguage = L10n.language
        let preference = AppLanguagePreference.allCases[selectedIndex]
        L10n.setLanguagePreference(preference)
        let languageChanged = previousLanguage != L10n.language
        if languageChanged {
            isRebuildingInterface = true
        }
        settingsWindow?.performClose(nil)

        if languageChanged {
            rebuildInterfaceForLanguageChange()
            DispatchQueue.main.async { [weak self] in
                self?.isRebuildingInterface = false
            }
        }

        showTransientStatus(
            L10n.text(
                "settings.applied",
                fallback: "表示言語の設定を適用しました。"
            )
        )
    }

    private func rebuildInterfaceForLanguageChange() {
        guard let currentWindow = window else {
            return
        }

        guideWindow?.performClose(nil)
        guideWindow = nil
        guidePages = []

        window = nil
        configureMainMenu()
        configureWindow()
        guard
            let replacementWindow = window,
            let replacementContentView = replacementWindow.contentView
        else {
            window = currentWindow
            return
        }

        replacementWindow.contentView = nil
        currentWindow.contentView = replacementContentView
        currentWindow.title = replacementWindow.title
        currentWindow.minSize = replacementWindow.minSize
        currentWindow.delegate = self
        window = currentWindow

        replacementWindow.isReleasedWhenClosed = true
        replacementWindow.close()

        refreshUI()
        refreshUsage()
        showMainWindow()
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
            makeGuidePage(
                title: L10n.text("guide.introduction.title", fallback: "はじめに")
            ) { content in
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.introduction.summary",
                        fallback: "ChatGPT Profile Managerは、ChatGPTアカウントごとに使う保存先を分け、異なるプロファイルを同時に起動するためのアプリです。アカウントやクラウド上のプロジェクトを移動・コピーするものではありません。\n\n"
                    ),
                    font: bodyFont,
                    color: .secondaryLabelColor,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.introduction.flow-heading",
                        fallback: "全体の流れ\n"
                    ),
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.introduction.flow-body",
                        fallback: "1　初回アカウントを確認\n2　保存先を選択\n3　必要ならログイン\n4　一覧の「起動」からプロファイルごとに起動\n\n"
                    ),
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.introduction.prerequisite-heading",
                        fallback: "大切な前提\n"
                    ),
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.introduction.prerequisite-body",
                        fallback: "既存環境がある場合、最初の起動時にメールアドレスを表示名として自動登録します。既存環境がない場合や2件目以降は、アカウント追加から保存先を選びます。アカウント間でプロジェクトやチャットをコピーすることはありません。"
                    ),
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
            },
            makeGuidePage(
                title: L10n.text("guide.register.title", fallback: "アカウントを登録")
            ) { content in
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.register.launch-heading",
                        fallback: "アプリを起動する\n"
                    ),
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.register.launch-body",
                        fallback: "ChatGPT Profile Managerを起動します。既存環境がある場合は、最初のアカウントをメールアドレスの表示名で自動登録します。登録しただけではChatGPTは起動せず、一覧の「起動」を押したときだけ選択した環境を起動します。\n\n"
                    ),
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.register.add-heading",
                        fallback: "アカウントを追加する\n"
                    ),
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.register.add-body",
                        fallback: "既存環境が自動登録されなかった場合や、別のアカウントを追加する場合は、「アカウントを追加」を押して一覧で表示する名前を入力します。メールアドレス以外の名前にも変更できます。アカウントは任意の数を追加できます。名前は1文字以上60文字以内で、同じ名前は登録できません。"
                    ),
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
            },
            makeGuidePage(
                title: L10n.text("guide.storage.title", fallback: "保存先を選ぶ")
            ) { content in
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.storage.introduction",
                        fallback: "名前の入力後、「このアカウントで使う保存先を選択」と表示されます。次の3つから、アカウントで使う環境を選びます。\n\n"
                    ),
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.storage.existing-heading",
                        fallback: "ChatGPTの既存環境を使う\n"
                    ),
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.storage.existing-body",
                        fallback: "普段のChatGPTのプロジェクト、チャット、設定、ログイン状態をそのまま使います。割り当てられるのは1アカウントだけです。\n\n"
                    ),
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.storage.new-heading",
                        fallback: "新しい分離プロファイルを作る\n"
                    ),
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.storage.new-body",
                        fallback: "このアカウント専用の保存先を新しく作ります。既存環境のデータはコピーされません。\n\n"
                    ),
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.storage.existing-isolated-heading",
                        fallback: "既存の分離プロファイルを使う\n"
                    ),
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.storage.existing-isolated-body",
                        fallback: "すでにある保存フォルダを選んで登録します。フォルダのコピーや移動は行いません。"
                    ),
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
            },
            makeGuidePage(
                title: L10n.text("guide.switch.title", fallback: "ログインして起動する")
            ) { content in
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.switch.login-heading",
                        fallback: "初回ログイン\n"
                    ),
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.switch.login-body",
                        fallback: "新しい分離プロファイルを初めて起動するときは、その保存先で使うChatGPTアカウントへログインします。ログイン状態、プロジェクト、チャットは、その分離プロファイル内に保存されます。既存環境を選んだ場合は、普段のログイン状態をそのまま使います。\n\n"
                    ),
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.switch.open-heading",
                        fallback: "プロファイルを並列で起動\n"
                    ),
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.switch.open-body",
                        fallback: "一覧からアカウントを選び、「起動」を押します。他のプロファイルを終了せず、別のChatGPTインスタンスとして起動します。データを保護するため、同じ保存先は複数起動できません。起動中の行では「起動」が「終了」に変わります。確認後、そのプロファイルのChatGPTだけを終了します。"
                    ),
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
            },
            makeGuidePage(
                title: L10n.text("guide.organize.title", fallback: "アカウントを整理する")
            ) { content in
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.organize.add-heading",
                        fallback: "別のアカウントを追加する\n"
                    ),
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.organize.add-body",
                        fallback: "同じ手順で何件でも追加できます。既存環境を割り当てた後は、その選択肢が無効になり、分離プロファイルを使います。未登録の保存フォルダを使う場合は、保存先の選択画面で「既存の分離プロファイルを使う」を選びます。\n\n"
                    ),
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.organize.list-heading",
                        fallback: "一覧を整える\n"
                    ),
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.organize.list-body",
                        fallback: "「名前を変更」は表示名だけを変更します。行をドラッグすると表示順だけを変更します。\n\n"
                    ),
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.organize.remove-heading",
                        fallback: "分離プロファイルを登録から外す\n"
                    ),
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.organize.remove-body",
                        fallback: "分離プロファイルの「削除」は登録情報だけを外し、保存フォルダやデータは残します。既存環境に割り当てたアカウントは削除できません。"
                    ),
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
            },
            makeGuidePage(
                title: L10n.text("guide.settings.title", fallback: "設定を共有・コピーする")
            ) { content in
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.settings.share-heading",
                        fallback: "設定を共有\n"
                    ),
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.settings.share-body",
                        fallback: "アカウント行の「設定」から「設定を共有」を選ぶと、複数のプロファイルを1つの共有グループへ追加できます。AGENTS.mdや選択した設定は共通ファイルを参照し、どのプロファイルから変更しても共有されます。反映はChatGPTの次回起動からです。\n\n"
                    ),
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.settings.copy-heading",
                        fallback: "設定をコピー\n"
                    ),
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.settings.copy-body",
                        fallback: "「設定をコピー」は1回だけの複製です。コピー元を後から変更しても、コピー先は変わりません。同名の設定はバックアップしてから置き換えます。\n\n"
                    ),
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.settings.scope-heading",
                        fallback: "共有されないもの\n"
                    ),
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.settings.scope-body",
                        fallback: "認証情報、セッション、ログ、SQLite索引、Cookie、ChatGPTのプロジェクトやチャットは共有・コピーしません。rulesは実行許可に影響するため、選択時に確認が必要です。設定変更の前には対象プロファイルのChatGPTを終了してください。"
                    ),
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
            },
            makeGuidePage(
                title: L10n.text("guide.mechanism.title", fallback: "仕組みと保存場所")
            ) { content in
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.mechanism.storage-heading",
                        fallback: "保存先は2種類\n"
                    ),
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.mechanism.storage-body",
                        fallback: "ChatGPTの既存環境は、ChatGPTが普段使っている保存先です。分離プロファイルは、ChatGPT Profile Managerがアカウントごとに用意する専用の保存先です。ログイン状態やアプリデータをアカウントごとに分けます。\n\n"
                    ),
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.mechanism.launch-heading",
                        fallback: "起動時に保存先を指定する仕組み\n"
                    ),
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.mechanism.launch-body",
                        fallback: "既存環境はChatGPTの既定の保存先で起動します。分離プロファイルは、インスタンスごとに専用の保存先を環境変数と引数で指定します。ChatGPT Profile Managerがデータをコピー・移動するのではなく、同時に起動するChatGPTそれぞれに別の読み込み先を指定します。\n\n"
                    ),
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.mechanism.paths-heading",
                        fallback: "指定する場所の役割\n"
                    ),
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.mechanism.paths-body",
                        fallback: "CODEX_HOMEはCodexの設定、認証、セッション、ログなどを保存します。CODEX_ELECTRON_USER_DATA_PATHと--user-data-dirは、ChatGPTデスクトップアプリ側のCookie、ログイン状態、アプリデータの保存先を指定します。この2つを同じ分離プロファイル内で指定することで、アカウントごとの環境を分けます。\n\n"
                    ),
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.mechanism.location-heading",
                        fallback: "保存場所\n"
                    ),
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideCode(
                    content,
                    L10n.text(
                        "guide.mechanism.location-tree",
                        fallback: "~/Library/Application Support/\n└── ChatGPT Profile Manager/\n    └── Profiles/\n        └── account-<表示名>-<短いID>/\n            ├── CodexHome/\n            └── ElectronUserData/"
                    )
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.mechanism.settings-heading",
                        fallback: "設定共有の保存場所\n"
                    ),
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.mechanism.settings-body",
                        fallback: "設定の共有グループとバックアップは、プロファイル本体とは別のアプリ管理領域に保存します。共有対象のAGENTS.mdやrulesはこの領域を参照します。認証情報、セッション、ログ、ElectronUserDataはこの機能の対象外です。\n\n"
                    ),
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideCode(
                    content,
                    L10n.text(
                        "guide.mechanism.settings-tree",
                        fallback: "~/Library/Application Support/\n└── ChatGPT Profile Manager/\n    ├── Profiles/\n    ├── Settings/\n    │   ├── SharedSettings/\n    │   └── Backups/\n    └── SettingsRegistry.json"
                    )
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.mechanism.usage-heading",
                        fallback: "利用上限の表示\n"
                    ),
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.mechanism.usage-body",
                        fallback: "アカウント一覧には取得できたプラン名も表示します。「5H」は5時間枠、「週間」は週間枠です。5Hは残りの割合と24時間表記の時刻、週間は残りの割合と月日・24時間表記の時刻を同じ行に表示します。利用できる上限リセットクレジットがある場合は、週間行の下に件数と有効期限を表示します。複数件ある場合は期限を一行ずつ表示します。ラベルにカーソルを合わせると、使用済みの割合と詳細なリセット日時を確認できます。Codexコマンドが見つからない場合、未ログインの場合、または通信できない場合は「—」と表示します。利用状況や認証情報をこのアプリの設定へ保存することはありません。"
                    ),
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
            },
            makeGuidePage(
                title: L10n.text("guide.safety.title", fallback: "困ったとき・安全に使う")
            ) { content in
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.safety.registration-heading",
                        fallback: "初回登録について\n"
                    ),
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.safety.registration-body",
                        fallback: "初回起動時に既存環境が見つかると、メールアドレスを表示名にして自動登録します。登録後も「名前を変更」から表示名だけ変更できます。\n\n"
                    ),
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.safety.launch-heading",
                        fallback: "ChatGPTを起動する場所\n"
                    ),
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.safety.launch-body",
                        fallback: "複数アカウントを使うときは、普段のChatGPTアイコンではなく、このアプリの「起動」から起動してください。異なるプロファイルは同時に起動できますが、同じプロファイルは二重起動できません。起動中のプロファイルは一覧に「起動中」と表示され、操作ボタンが「終了」に変わります。終了前には、進行中の作業がないか確認してください。\n\n"
                    ),
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text("guide.safety.warning-heading", fallback: "注意\n"),
                    font: sectionFont,
                    color: .systemOrange,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.safety.warning-body",
                        fallback: "このアプリはOpenAI公式機能ではありません。アカウントの利用上限を回避する目的では使用しないでください。"
                    ),
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
        guideWindow.title = L10n.text(
            "guide.window-title",
            fallback: "このアプリの仕組み"
        )
        guideWindow.tabbingMode = .disallowed
        guideWindow.minSize = NSSize(width: 560, height: 480)
        guideWindow.isReleasedWhenClosed = false
        guideWindow.center()

        let headerStack = NSStackView()
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 12
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let headerTitleLabel = NSTextField(
            labelWithString: L10n.text(
                "guide.header-title",
                fallback: "使い方チュートリアル"
            )
        )
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
            button.setAccessibilityLabel(
                L10n.text(
                    "guide.page.accessibility-label",
                    fallback: "ページ {current}/{total}へ移動",
                    replacing: [
                        "current": "\(index + 1)",
                        "total": "\(guidePages.count)"
                    ]
                )
            )
            dotsStack.addArrangedSubview(button)
            return button
        }

        let previousButton = NSButton(
            title: L10n.text("guide.previous", fallback: "前へ"),
            target: self,
            action: #selector(showPreviousGuidePage)
        )
        previousButton.bezelStyle = .rounded
        previousButton.controlSize = .large

        let nextButton = NSButton(
            title: L10n.text("guide.next", fallback: "次へ"),
            target: self,
            action: #selector(showNextGuidePage)
        )
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

        guideProgressLabel.stringValue = L10n.text(
            "guide.progress",
            fallback: "ページ {current} / {total}",
            replacing: [
                "current": "\(guidePageIndex + 1)",
                "total": "\(guidePages.count)"
            ]
        )
        guidePreviousButton.isEnabled = guidePageIndex > 0
        guideNextButton.title = guidePageIndex == guidePages.count - 1
            ? L10n.text("guide.done", fallback: "完了")
            : L10n.text("guide.next", fallback: "次へ")

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
            ? L10n.text("account.add.first-title", fallback: "最初のアカウントを追加します")
            : L10n.text("account.add.title", fallback: "アカウントを追加します")
        alert.informativeText = L10n.text(
            "account.add.message",
            fallback: "ChatGPT Profile Managerで表示する分かりやすい名前を入力してください。メールアドレスそのものを使う必要はありません。"
        )
        alert.addButton(withTitle: L10n.text("common.next", fallback: "次へ"))
        alert.addButton(withTitle: L10n.text("common.cancel", fallback: "キャンセル"))

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        nameField.placeholderString = L10n.text(
            "account.add.placeholder",
            fallback: "例：メイン、開発チーム、取引先A"
        )
        alert.accessoryView = nameField
        alert.window.initialFirstResponder = nameField

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        let name: String
        do {
            name = try launcher.validateNewAccountName(nameField.stringValue)
        } catch {
            presentError(
                error,
                title: L10n.text(
                    "account.name-invalid-title",
                    fallback: "アカウント名を使用できません"
                )
            )
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
                showTransientStatus(
                    L10n.text(
                        "account.existing-auto-registered",
                        fallback: "{name} を既存のChatGPT環境へ自動登録しました。",
                        replacing: ["name": account.name]
                    )
                )
                refreshUsage()
                return
            }
        } catch {
            presentError(
                error,
                title: L10n.text(
                    "account.existing-auto-register-error-title",
                    fallback: "既存環境を自動登録できませんでした"
                )
            )
        }

        presentAddAccount()
    }

    private func presentStorageChoice(for name: String) {
        let existingEnvironmentAccount = launcher.existingEnvironmentAccount
        let candidates = launcher.availableIsolatedProfiles

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.text(
            "storage-choice.title",
            fallback: "「{name}」で使う保存先を選択",
            replacing: ["name": name]
        )
        alert.informativeText = L10n.text(
            "storage-choice.message",
            fallback: "このアカウントでChatGPTが使う保存先を選びます。既存環境を使うと普段のプロジェクトやチャットをそのまま開きます。分離プロファイルを使うと、このアカウント専用の保存先を使います。"
        )
        alert.addButton(
            withTitle: L10n.text("storage-choice.add-button", fallback: "この保存先で追加")
        )
        alert.addButton(withTitle: L10n.text("common.cancel", fallback: "キャンセル"))

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
                title: L10n.text(
                    "storage-choice.existing.title",
                    fallback: "ChatGPTの既存環境を使う"
                ),
                description: existingEnvironmentAccount.map {
                    L10n.text(
                        "storage-choice.existing.assigned-description",
                        fallback: "普段のChatGPTのプロジェクト・チャットをそのまま使う（「{name}」に割り当て済み）",
                        replacing: ["name": $0.name]
                    )
                } ?? L10n.text(
                    "storage-choice.existing.description",
                    fallback: "普段のChatGPTのプロジェクト・チャットをそのまま使う"
                ),
                isEnabled: existingEnvironmentAccount == nil
            ),
            (
                choice: AccountStorageChoice.newIsolatedProfile,
                title: L10n.text(
                    "storage-choice.new.title",
                    fallback: "新しい分離プロファイルを作る"
                ),
                description: L10n.text(
                    "storage-choice.new.description",
                    fallback: "このアカウント専用の保存先を新しく作成する"
                ),
                isEnabled: true
            ),
            (
                choice: AccountStorageChoice.existingIsolatedProfile,
                title: L10n.text(
                    "storage-choice.existing-isolated.title",
                    fallback: "既存の分離プロファイルを使う"
                ),
                description: candidates.isEmpty
                    ? L10n.text(
                        "storage-choice.existing-isolated.empty-description",
                        fallback: "登録できる既存フォルダがありません"
                    )
                    : L10n.text(
                        "storage-choice.existing-isolated.description",
                        fallback: "すでにある分離プロファイルを選んで使う"
                    ),
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
                    title: L10n.text(
                        "storage-choice.existing-isolated.error-title",
                        fallback: "既存の分離プロファイルを選択できませんでした"
                    )
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
        alert.messageText = L10n.text(
            "existing-assignment.title",
            fallback: "ChatGPTの既存環境を「{name}」へ固定しますか？",
            replacing: ["name": name]
        )
        alert.informativeText = L10n.text(
            "existing-assignment.message",
            fallback: "ChatGPTの既存環境をこのアカウントに割り当てます。紐づけられるのは1アカウントだけで、既存データのコピーや移動は行いません。確定後に追加するアカウントは、すべて分離プロファイルになります。"
        )
        alert.addButton(
            withTitle: L10n.text(
                "existing-assignment.confirm",
                fallback: "ChatGPTの既存環境に固定"
            )
        )
        alert.addButton(withTitle: L10n.text("common.back", fallback: "戻る"))

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
                showTransientStatus(
                    L10n.text(
                        "account.created.existing",
                        fallback: "{name} を既存のChatGPT環境へ固定しました。",
                        replacing: ["name": account.name]
                    )
                )
            } else if directoryName != nil {
                showTransientStatus(
                    L10n.text(
                        "account.created.existing-isolated",
                        fallback: "{name} に既存の分離プロファイルを登録しました。",
                        replacing: ["name": account.name]
                    )
                )
            } else {
                showTransientStatus(
                    L10n.text(
                        "account.created.new-isolated",
                        fallback: "{name} を新しい分離プロファイルとして追加しました。",
                        replacing: ["name": account.name]
                    )
                )
            }
        } catch {
            presentError(
                error,
                title: L10n.text(
                    "account.add.error-title",
                    fallback: "アカウントを追加できませんでした"
                )
            )
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
        alert.messageText = L10n.text(
            "account.rename.title",
            fallback: "アカウント名を変更します"
        )
        alert.informativeText = L10n.text(
            "account.rename.message",
            fallback: "名前だけを変更します。紐づけ先や保存済みデータは変わりません。"
        )
        alert.addButton(withTitle: L10n.text("account.rename.confirm", fallback: "変更"))
        alert.addButton(withTitle: L10n.text("common.cancel", fallback: "キャンセル"))

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
            presentError(
                error,
                title: L10n.text(
                    "account.rename.error-title",
                    fallback: "アカウント名を変更できませんでした"
                )
            )
        }
    }

    @objc
    private func deleteAccount(_ sender: NSButton) {
        guard
            let rawID = sender.identifier?.rawValue,
            let accountID = UUID(uuidString: rawID),
            let account = launcher.accounts.first(where: { $0.id == accountID })
        else {
            presentError(
                ProfileManagerError.accountNotFound,
                title: L10n.text(
                    "account.delete.error-title",
                    fallback: "アカウント登録を削除できませんでした"
                )
            )
            return
        }

        guard account.id != launcher.existingEnvironmentAccount?.id else {
            presentError(
                ProfileManagerError.linkedAccountCannotBeDeleted,
                title: L10n.text(
                    "account.delete.error-title",
                    fallback: "アカウント登録を削除できませんでした"
                )
            )
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text(
            "account.delete.title",
            fallback: "「{name}」の登録を削除しますか？",
            replacing: ["name": account.name]
        )
        alert.informativeText = L10n.text(
            "account.delete.message",
            fallback: "アカウントの登録だけを削除します。分離プロファイルの保存フォルダ、ログイン状態、設定、セッション、ログなどはそのまま残り、後からアカウント追加時に「既存の分離プロファイルを使う」を選ぶと、同じ保存先を再登録できます。既存環境は変更されません。"
        )
        alert.addButton(
            withTitle: L10n.text("account.delete.confirm", fallback: "登録を削除")
        )
        alert.addButton(withTitle: L10n.text("common.cancel", fallback: "キャンセル"))

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        do {
            let deletedAccount = try launcher.removeIsolatedAccountRegistration(id: account.id)
            refreshUI()
            refreshUsage()
            showTransientStatus(
                L10n.text(
                    "account.deleted.success",
                    fallback: "{name} の登録を削除しました。保存フォルダは保持されています。",
                    replacing: ["name": deletedAccount.name]
                )
            )
        } catch {
            presentError(
                error,
                title: L10n.text(
                    "account.delete.error-title",
                    fallback: "アカウント登録を削除できませんでした"
                )
            )
        }
    }

    @objc
    private func openAccount(_ sender: NSButton) {
        guard
            !isLaunching,
            let rawID = sender.identifier?.rawValue,
            let accountID = UUID(uuidString: rawID),
            let account = launcher.accounts.first(where: { $0.id == accountID })
        else {
            return
        }

        isLaunching = true
        showTransientStatus(
            L10n.text(
                "account.opening",
                fallback: "{name} を起動中…",
                replacing: ["name": account.name]
            )
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isLaunching = false }

            do {
                try await self.launcher.open(accountID: accountID)
                self.refreshUI()
            } catch {
                self.refreshUI()
                self.presentError(error)
            }
        }
    }

    @objc
    private func quitAccount(_ sender: NSButton) {
        guard
            !isLaunching,
            let rawID = sender.identifier?.rawValue,
            let accountID = UUID(uuidString: rawID),
            let account = launcher.accounts.first(where: { $0.id == accountID }),
            launcher.isAccountRunning(id: accountID)
        else {
            refreshUI()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text(
            "account.quit.confirmation-title",
            fallback: "「{name}」のChatGPTを終了しますか？",
            replacing: ["name": account.name]
        )
        alert.informativeText = L10n.text(
            "account.quit.confirmation-message",
            fallback: "進行中の作業がある場合、中断される可能性があります。"
        )
        alert.addButton(withTitle: L10n.text("account.quit", fallback: "終了"))
        alert.addButton(withTitle: L10n.text("common.cancel", fallback: "キャンセル"))

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        isLaunching = true
        showTransientStatus(
            L10n.text(
                "account.quitting",
                fallback: "{name} を終了中…",
                replacing: ["name": account.name]
            )
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isLaunching = false }

            do {
                try await self.launcher.quit(accountID: accountID)
                self.refreshUI()
            } catch {
                self.refreshUI()
                self.presentError(
                    error,
                    title: L10n.text(
                        "account.quit.error-title",
                        fallback: "ChatGPTを終了できませんでした"
                    )
                )
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
            presentError(
                error,
                title: L10n.text(
                    "profiles.open-error-title",
                    fallback: "プロファイル保存先を開けませんでした"
                )
            )
        }
    }

    private func presentError(
        _ error: Error,
        title: String? = nil
    ) {
        showMainWindow()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title ?? L10n.text(
            "account.open.error-title",
            fallback: "アカウントを起動できませんでした"
        )
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L10n.text("common.ok", fallback: "OK"))
        alert.runModal()
    }
}
