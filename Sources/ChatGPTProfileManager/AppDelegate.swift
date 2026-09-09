import AppKit
import ServiceManagement
import UserNotifications

private struct DiagnosticsTaskError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

private enum DiagnosticsRepairOutcome: Sendable {
    case success(ProfileRepairResult)
    case failure(String)
}

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

private final class MenuBarUsageLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
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
    private var groupsWindow: NSWindow?
    private var diagnosticsWindow: NSWindow?
    private var diagnosticsAccountID: UUID?
    private weak var diagnosticsTitleLabel: NSTextField?
    private weak var diagnosticsSummaryLabel: NSTextField?
    private weak var diagnosticsDetailsView: NSTextView?
    private weak var diagnosticsRunButton: NSButton?
    private weak var diagnosticsRelocateButton: NSButton?
    private weak var diagnosticsRebuildButton: NSButton?
    private weak var diagnosticsLogsButton: NSButton?
    private weak var diagnosticsMoreButton: NSButton?
    private weak var diagnosticsProgressIndicator: NSProgressIndicator?
    private var diagnosticsTask: Task<Void, Never>?
    private var diagnosticsExecutionState: ProfileDiagnosticsExecutionState = .idle {
        didSet {
            isDiagnosticsRunning = diagnosticsExecutionState != .idle
            isDiagnosticsRepairRunning = diagnosticsExecutionState == .repairing
        }
    }
    private var isDiagnosticsRepairRunning = false
    private var isDiagnosticsRunning = false {
        didSet {
            updateDiagnosticsControls()
        }
    }
    private var guidePages: [NSAttributedString] = []
    private var guidePageIndex = 0
    private var guideDotButtons: [NSButton] = []
    private weak var guidePageTextView: NSTextView?
    private weak var guideProgressLabel: NSTextField?
    private weak var guidePreviousButton: NSButton?
    private weak var guideNextButton: NSButton?
    private var shouldPrepareInitialAccountAfterGuide = false
    private var statusLabel: NSTextField?
    private var accountCountLabel: NSTextField?
    private var tableView: NSTableView?
    private var tableHeightConstraint: NSLayoutConstraint?
    private var addButton: NSButton?
    private var revealButton: NSButton?
    private var settingsButton: NSButton?
    private var usageRefreshButton: NSButton?
    private weak var settingsLanguagePopup: NSPopUpButton?
    private weak var settingsUsageNotificationCheckbox: NSButton?
    private weak var settingsUsageWarningCheckbox: NSButton?
    private weak var settingsUsageCriticalCheckbox: NSButton?
    private weak var settingsCompactUsageCheckbox: NSButton?
    private weak var settingsLoginItemCheckbox: NSButton?
    private weak var settingsProfileHealthLabel: NSTextField?
    private weak var settingsSettingsHealthLabel: NSTextField?
    private weak var settingsProfileRestoreButton: NSButton?
    private weak var settingsSettingsRestoreButton: NSButton?
    private var storageChoiceButtons: [NSButton] = []
    private var usageByAccountID: [UUID: AccountUsageSnapshot] = [:]
    private enum UsageFetchState: Equatable {
        case loading
        case loaded(Date)
        case failed(Date?)
    }
    private var usageFetchStates: [UUID: UsageFetchState] = [:]
    private var usageLastUpdatedAt: [UUID: Date] = [:]
    private var notifiedUsageThresholds: Set<String> = []
    private var usageRefreshTimer: Timer?
    private var lastUsageRefreshAt: Date?
    private var scheduledUsageNotificationIDs: Set<String> = []
    private let usageNotificationsEnabledKey = "usageResetNotificationsEnabled"
    private let usageWarningNotificationsEnabledKey = "usageWarningNotificationsEnabled"
    private let usageCriticalNotificationsEnabledKey = "usageCriticalNotificationsEnabled"
    private let compactUsageStatusEnabledKey = MenuBarPreferences.compactUsageStatusKey
    private let scheduledUsageNotificationIDsKey = "scheduledUsageNotificationIDs"
    private var expandedResetCreditAccountIDs: Set<UUID> = []
    private var expandedMenuBarResetCreditAccountIDs: Set<UUID> = []
    private let collapsedAccountRowHeight: CGFloat = 120
    private let expandedAccountRowHeight: CGFloat = 152
    private var editingAccountID: UUID?
    private weak var editingNameField: NSTextField?
    private var usageRefreshTask: Task<Void, Never>?
    private var statusItem: NSStatusItem?
    private var statusPopover: NSPopover?
    private var statusPopoverDocument: NSView?
    private var statusPopoverStack: NSStackView?
    private weak var statusUsageLabel: MenuBarUsageLabel?
    private let menuBarIcon = MenuBarIcon.make()
    private var launchedInBackground = false
    private var isRebuildingInterface = false
    private var isLaunching = false {
        didSet {
            updateControlAvailability()
        }
    }

    private var usageWarningNotificationsEnabled: Bool {
        UserDefaults.standard.bool(forKey: usageWarningNotificationsEnabledKey)
    }

    private var usageCriticalNotificationsEnabled: Bool {
        UserDefaults.standard.bool(forKey: usageCriticalNotificationsEnabledKey)
    }

    private var compactUsageStatusEnabled: Bool {
        MenuBarPreferences.compactUsageEnabled(in: UserDefaults.standard)
    }

    private func configureStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }
        button.image = menuBarIcon
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = #selector(toggleStatusPopover)

        let usageLabel = MenuBarUsageLabel(labelWithString: "")
        usageLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        usageLabel.alignment = .left
        usageLabel.maximumNumberOfLines = 2
        usageLabel.lineBreakMode = .byClipping
        usageLabel.translatesAutoresizingMaskIntoConstraints = false
        usageLabel.isHidden = true
        button.addSubview(usageLabel)
        NSLayoutConstraint.activate([
            usageLabel.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            usageLabel.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            usageLabel.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])
        statusUsageLabel = usageLabel
        button.setAccessibilityLabel(L10n.text(
            "menubar.accessibility-label",
            fallback: "ChatGPT Profile Managerの利用状況"
        ))
        button.toolTip = L10n.text(
            "menubar.tooltip",
            fallback: "ChatGPT Profile Managerの利用状況を表示"
        )
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        // Replacing the account cards while the popover is open must not
        // animate the popover window itself. The content is updated in place
        // below, so an animated resize only looks like a flash to the user.
        popover.animates = false
        statusPopover = popover
        updateStatusItem()
    }

    private func startUsageRefreshTimer() {
        usageRefreshTimer?.invalidate()
        usageRefreshTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshUsage()
            }
        }
    }

    @objc
    private func systemDidWake(_ notification: Notification) {
        refreshUsage()
    }

    private var menuBarAccounts: [AccountProfile] {
        launcher.accounts
            .enumerated()
            .filter { $0.element.showsInMenuBar }
            .sorted { lhs, rhs in
                if lhs.element.isFavorite != rhs.element.isFavorite {
                    return lhs.element.isFavorite && !rhs.element.isFavorite
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        guard compactUsageStatusEnabled else {
            button.title = ""
            button.font = nil
            button.alignment = .center
            statusUsageLabel?.isHidden = true
            statusItem?.length = NSStatusItem.variableLength
            button.image = menuBarIcon
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = L10n.text(
                "menubar.tooltip",
                fallback: "ChatGPT Profile Managerの利用状況を表示"
            )
            return
        }

        let accounts = menuBarAccounts
        let summary = MenuBarUsageSummary.minimum(
            accountIDs: accounts.map(\.id),
            snapshots: usageByAccountID
        )
        let title = summary.title
        button.title = ""
        button.font = nil
        button.alignment = .center
        button.image = nil
        button.imagePosition = .noImage
        statusUsageLabel?.stringValue = title
        statusUsageLabel?.isHidden = false
        if let labelWidth = statusUsageLabel?.fittingSize.width {
            statusItem?.length = max(NSStatusBar.system.thickness, ceil(labelWidth))
        }
        let scope = L10n.text(
            "menubar.scope-tooltip",
            fallback: "表示中の{count}プロファイルの最小残量",
            replacing: ["count": "\(accounts.count)"]
        )
        let updated = lastUsageRefreshAt.map { formatFetchDate($0) }
            ?? L10n.text("common.unknown", fallback: "不明")
        button.toolTip = "\(scope)（\(L10n.text("usage.last-updated", fallback: "最終確認: {date}", replacing: ["date": updated]))）"
    }

    @objc
    private func toggleStatusPopover() {
        guard let popover = statusPopover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        if lastUsageRefreshAt == nil || Date().timeIntervalSince(lastUsageRefreshAt ?? .distantPast) > 5 * 60 {
            refreshUsage()
        }
        updateStatusPopover()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func updateStatusPopover() {
        guard let popover = statusPopover else { return }
        let stack: NSStackView
        if let existingStack = statusPopoverStack {
            stack = existingStack
            stack.arrangedSubviews.forEach { view in
                stack.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
        } else {
            let root = NSView()
            let scroll = NSScrollView()
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = false
            scroll.autohidesScrollers = true
            scroll.translatesAutoresizingMaskIntoConstraints = false
            // NSScrollView owns the document view's frame. Constraining it
            // to the clip view creates mutually exclusive constraints on
            // recent macOS versions, so keep the frame explicit and let
            // Auto Layout size only the content inside it.
            let document = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 1))
            let newStack = NSStackView()
            newStack.orientation = .vertical
            newStack.alignment = .leading
            newStack.spacing = 10
            newStack.translatesAutoresizingMaskIntoConstraints = false
            document.addSubview(newStack)
            NSLayoutConstraint.activate([
                newStack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 14),
                newStack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -14),
                newStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 14),
                newStack.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -28)
            ])
            scroll.documentView = document
            root.addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                scroll.topAnchor.constraint(equalTo: root.topAnchor),
                scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor)
            ])

            let controller = NSViewController()
            controller.view = root
            popover.contentViewController = controller
            statusPopoverDocument = document
            statusPopoverStack = newStack
            stack = newStack
        }

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: L10n.text(
            "menubar.title",
            fallback: "利用状況"
        ))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        header.addArrangedSubview(title)
        header.addArrangedSubview(NSView())
        let refreshButton = NSButton(
            title: L10n.text("usage.refresh", fallback: "更新"),
            target: self,
            action: #selector(refreshUsageFromStatus(_:))
        )
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .small
        header.addArrangedSubview(refreshButton)
        let mainButton = NSButton(
            title: L10n.text("menubar.open-main", fallback: "メイン画面"),
            target: self,
            action: #selector(showMainWindowFromStatus(_:))
        )
        mainButton.bezelStyle = .rounded
        mainButton.controlSize = .small
        header.addArrangedSubview(mainButton)
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let accounts = menuBarAccounts
        if accounts.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: L10n.text(
                "menubar.no-profiles",
                fallback: "メニューバーに表示するプロファイルがありません。メイン画面の操作メニューから表示を有効にできます。"
            ))
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            empty.maximumNumberOfLines = 3
            stack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        for account in accounts {
            let card = makeMenuBarAccountCard(account)
            // Keep cards aligned with the popover content instead of letting
            // their intrinsic text width leave an empty column on the right.
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        let settingsButton = NSButton(
            title: L10n.text("menubar.settings", fallback: "設定"),
            target: self,
            action: #selector(showSettingsFromButton(_:))
        )
        settingsButton.bezelStyle = .rounded
        settingsButton.controlSize = .small
        footer.addArrangedSubview(settingsButton)
        footer.addArrangedSubview(NSView())
        let quitButton = NSButton(
            title: L10n.text("menu.quit", fallback: "終了"),
            target: NSApp,
            action: #selector(NSApplication.terminate(_:))
        )
        quitButton.bezelStyle = .rounded
        quitButton.controlSize = .small
        footer.addArrangedSubview(quitButton)
        stack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Derive the popover height from the content that is actually laid
        // out. A per-account estimate leaves a large empty area when reset
        // details are collapsed.
        stack.layoutSubtreeIfNeeded()
        let visibleSubviews = stack.arrangedSubviews.filter { !$0.isHidden }
        let contentHeight = visibleSubviews.reduce(CGFloat.zero) { height, view in
            view.layoutSubtreeIfNeeded()
            return height + view.fittingSize.height
        }
        let spacingHeight = CGFloat(max(0, visibleSubviews.count - 1)) * stack.spacing
        let desiredHeight = max(1, contentHeight + spacingHeight + 28)
        let visibleHeight = min(620, desiredHeight)
        if let document = statusPopoverDocument {
            document.setFrameSize(NSSize(width: 420, height: desiredHeight))
        }
        popover.contentSize = NSSize(width: 420, height: visibleHeight)
        updateStatusItem()
    }

    private func makeMenuBarAccountCard(_ account: AccountProfile) -> NSView {
        let card = ProfileCardView()
        card.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 9),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -9)
        ])

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        let name = NSTextField(labelWithString: account.name)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(name)
        header.addArrangedSubview(NSView())
        let openButton = NSButton(
            title: launcher.isAccountRunning(id: account.id)
                ? L10n.text("account.focus", fallback: "開く")
                : L10n.text("account.open", fallback: "起動"),
            target: self,
            action: #selector(openAccount(_:))
        )
        openButton.identifier = NSUserInterfaceItemIdentifier(account.id.uuidString)
        openButton.bezelStyle = .rounded
        openButton.controlSize = .small
        header.addArrangedSubview(openButton)
        if launcher.isAccountRunning(id: account.id) {
            let quit = NSButton(
                title: L10n.text("account.quit", fallback: "終了"),
                target: self,
                action: #selector(quitAccount(_:))
            )
            quit.identifier = NSUserInterfaceItemIdentifier(account.id.uuidString)
            quit.bezelStyle = .rounded
            quit.controlSize = .small
            header.addArrangedSubview(quit)
        }
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let usage = NSStackView()
        usage.orientation = .vertical
        usage.alignment = .leading
        usage.spacing = 2
        let snapshot = usageByAccountID[account.id]
        usage.addArrangedSubview(makeUsageLabel(title: "5H", window: snapshot?.primary, resetDateStyle: .timeOnly))
        usage.addArrangedSubview(makeUsageLabel(title: L10n.text("usage.weekly", fallback: "週間"), window: snapshot?.secondary, resetDateStyle: .monthDayAndTime))
        if let credits = snapshot?.rateLimitResetCredits {
            if credits.availableCount > 0 {
                usage.addArrangedSubview(
                    makeResetCreditDisclosure(
                        accountID: account.id,
                        summary: credits,
                        isExpanded: expandedMenuBarResetCreditAccountIDs.contains(account.id),
                        action: #selector(toggleMenuBarResetCredits(_:))
                    )
                )
            } else if let countLabel = makeResetCreditLabels(credits).first {
                usage.addArrangedSubview(countLabel)
            }
        } else {
            let unavailable = NSTextField(labelWithString: L10n.text("usage.reset-credits.unavailable", fallback: "上限リセット —"))
            unavailable.font = .systemFont(ofSize: 11)
            unavailable.textColor = .tertiaryLabelColor
            usage.addArrangedSubview(unavailable)
        }
        stack.addArrangedSubview(usage)
        usage.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let updatedAt = usageLastUpdatedAt[account.id].map { formatFetchDate($0) }
            ?? L10n.text("common.unknown", fallback: "不明")
        let updated = NSTextField(labelWithString: L10n.text(
            "usage.last-updated",
            fallback: "最終確認: {date}",
            replacing: ["date": updatedAt]
        ))
        updated.font = .systemFont(ofSize: 10)
        updated.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(updated)
        if case .loading = usageFetchStates[account.id] {
            let loading = NSTextField(labelWithString: L10n.text(
                "usage.fetching",
                fallback: "（確認中…）"
            ))
            loading.font = .systemFont(ofSize: 10)
            loading.textColor = .secondaryLabelColor
            stack.addArrangedSubview(loading)
        }
        if case .failed = usageFetchStates[account.id] {
            let failed = NSTextField(labelWithString: L10n.text(
                "usage.fetch-failed",
                fallback: "（確認に失敗）"
            ))
            failed.font = .systemFont(ofSize: 10, weight: .medium)
            failed.textColor = .systemOrange
            stack.addArrangedSubview(failed)
        }
        return card
    }

    @objc
    private func refreshUsageFromStatus(_ sender: NSButton) {
        refreshUsage()
    }

    @objc
    private func showMainWindowFromStatus(_ sender: NSButton) {
        statusPopover?.performClose(nil)
        showMainWindow()
    }

    @objc
    private func toggleMenuBarFavorite(_ sender: NSButton) {
        guard let accountID = accountID(from: sender),
              let account = launcher.accounts.first(where: { $0.id == accountID }) else { return }
        do {
            try launcher.setAccountFavorite(id: accountID, isFavorite: !account.isFavorite)
            refreshUI()
            updateStatusPopover()
        } catch { presentError(error) }
    }

    @objc
    private func toggleMenuBarVisibility(_ sender: NSMenuItem) {
        guard let accountID = accountID(from: sender),
              let account = launcher.accounts.first(where: { $0.id == accountID }) else { return }
        do {
            try launcher.setAccountMenuBarVisibility(id: accountID, isVisible: !account.showsInMenuBar)
            refreshUI()
            updateStatusPopover()
        } catch { presentError(error) }
    }

    @objc
    private func toggleMenuBarVisibilityFromSettings(_ sender: NSButton) {
        guard let accountID = accountID(from: sender),
              let account = launcher.accounts.first(where: { $0.id == accountID }) else { return }
        do {
            try launcher.setAccountMenuBarVisibility(id: accountID, isVisible: !account.showsInMenuBar)
            refreshUI()
            updateStatusPopover()
        } catch { presentError(error) }
    }

    @objc
    private func toggleMenuBarFavoriteFromMenu(_ sender: NSMenuItem) {
        guard let accountID = accountID(from: sender),
              let account = launcher.accounts.first(where: { $0.id == accountID }) else { return }
        do {
            try launcher.setAccountFavorite(id: accountID, isFavorite: !account.isFavorite)
            refreshUI()
            updateStatusPopover()
        } catch { presentError(error) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        configureMainMenu()
        configureWindow()
        configureStatusItem()
        startUsageRefreshTimer()
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
        workspaceNotifications.addObserver(
            self,
            selector: #selector(systemDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        // SMAppService launches the app in the background at login. Keep the
        // menu bar item available without surfacing the main window in that
        // case; an interactive launch remains unchanged.
        launchedInBackground = SMAppService.mainApp.status == .enabled
            && !NSApp.isActive
            && !launcher.accounts.isEmpty
        if !launchedInBackground {
            showMainWindow()
        } else {
            // A user launch can briefly report inactive while LaunchServices
            // finishes activation. Give it one run-loop turn before treating
            // it as a login-item launch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.launchedInBackground, NSApp.isActive else { return }
                self.launchedInBackground = false
                self.showMainWindow()
                self.prepareInitialExperience()
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, !self.launchedInBackground else { return }
            self.prepareInitialExperience()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshUI()
        refreshUsage()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Normal termination is refused while a repair is running (see
        // applicationShouldTerminate). A read-only diagnosis can be
        // cancelled because it has no transaction or snapshot to complete.
        if !diagnosticsExecutionState.continuesAfterWindowClose {
            diagnosticsTask?.cancel()
        }
        usageRefreshTimer?.invalidate()
        usageRefreshTimer = nil
        statusPopover?.performClose(nil)
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard diagnosticsExecutionState.blocksApplicationTermination else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text(
            "diagnostics.termination-blocked-title",
            fallback: "プロファイルの修復中です"
        )
        alert.informativeText = L10n.text(
            "diagnostics.termination-blocked-message",
            fallback: "修復と修復ログの保存が完了してから、もう一度終了してください。"
        )
        alert.addButton(withTitle: L10n.text("common.ok", fallback: "OK"))
        alert.runModal()
        return .terminateCancel
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
        // A direct profile launcher writes its PID marker immediately after
        // ChatGPT is spawned. Retry once after LaunchServices has published
        // the new process so the account row reflects the external launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.refreshUI()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
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

        if closingWindow === groupsWindow {
            groupsWindow = nil
            return
        }

        if closingWindow === diagnosticsWindow {
            if diagnosticsExecutionState.continuesAfterWindowClose {
                // The detached repair owns its snapshot, transaction, and
                // log. Keep its completion task alive and retain the busy
                // state so applicationShouldTerminate can defer quitting.
            } else {
                diagnosticsTask?.cancel()
                diagnosticsTask = nil
                diagnosticsExecutionState = .idle
            }
            diagnosticsWindow = nil
            diagnosticsAccountID = nil
            diagnosticsTitleLabel = nil
            diagnosticsSummaryLabel = nil
            diagnosticsDetailsView = nil
            diagnosticsRunButton = nil
            diagnosticsRelocateButton = nil
            diagnosticsRebuildButton = nil
            diagnosticsLogsButton = nil
            diagnosticsMoreButton = nil
            diagnosticsProgressIndicator = nil
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
                fallback: "ChatGPTプロファイルごとに保存先を分け、複数のプロファイルを並列で起動します。"
            )
        )
        descriptionLabel.font = .systemFont(ofSize: 13)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.maximumNumberOfLines = 2
        heroLabels.addArrangedSubview(descriptionLabel)
        heroStack.addArrangedSubview(heroLabels)
        mainStack.addArrangedSubview(heroStack)

        let accountHeader = NSStackView()
        accountHeader.orientation = .horizontal
        accountHeader.alignment = .centerY
        accountHeader.translatesAutoresizingMaskIntoConstraints = false

        let accountHeaderLabel = NSTextField(
            labelWithString: L10n.text("accounts.title", fallback: "プロファイル")
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
            title: L10n.text("accounts.add", fallback: "プロファイルを追加"),
            target: self,
            action: #selector(addAccount)
        )
        addButton.bezelStyle = .rounded
        addButton.controlSize = .large
        addButton.keyEquivalent = "+"
        addButton.setAccessibilityLabel(
            L10n.text("accounts.add", fallback: "プロファイルを追加")
        )
        accountHeader.addArrangedSubview(addButton)
        mainStack.addArrangedSubview(accountHeader)
        accountHeader.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        self.addButton = addButton

        let tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowHeight = collapsedAccountRowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.setAccessibilityLabel(
            L10n.text(
                "accounts.registered.accessibility-label",
                fallback: "登録済みプロファイル"
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
            action: #selector(showSettingsFromButton(_:))
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
            title: L10n.text("management.open-storage", fallback: "プロファイル保存先を開く"),
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

        let usageRefreshButton = NSButton(
            title: L10n.text("usage.refresh", fallback: "利用状況を更新"),
            target: self,
            action: #selector(refreshUsageManually)
        )
        usageRefreshButton.bezelStyle = .rounded
        usageRefreshButton.controlSize = .regular
        usageRefreshButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        usageRefreshButton.contentTintColor = .controlAccentColor
        usageRefreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        usageRefreshButton.imagePosition = .imageLeading
        usageRefreshButton.setAccessibilityLabel(
            L10n.text("usage.refresh.accessibility-label", fallback: "プロファイルの利用状況を更新")
        )

        let groupsButton = NSButton(
            title: L10n.text("management.shared-groups", fallback: "共有グループ"),
            target: self,
            action: #selector(showSettingsGroups)
        )
        groupsButton.bezelStyle = .rounded
        groupsButton.controlSize = .regular
        groupsButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        groupsButton.contentTintColor = .controlAccentColor
        groupsButton.image = NSImage(systemSymbolName: "person.2", accessibilityDescription: nil)
        groupsButton.imagePosition = .imageLeading
        groupsButton.setAccessibilityLabel(
            L10n.text("management.shared-groups.accessibility-label", fallback: "共有グループの一覧を表示")
        )

        utilityButtons.addArrangedSubview(settingsButton)
        utilityButtons.addArrangedSubview(revealButton)
        utilityButtons.addArrangedSubview(guideButton)
        utilityButtons.addArrangedSubview(usageRefreshButton)
        utilityButtons.addArrangedSubview(groupsButton)
        mainStack.addArrangedSubview(utilityButtons)

        self.revealButton = revealButton
        self.settingsButton = settingsButton
        self.usageRefreshButton = usageRefreshButton

        self.window = window
    }

    private func showMainWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshUI() {
        let accounts = launcher.accounts
        accountCountLabel?.stringValue = L10n.accountCount(accounts.count)

        let profileHealth = launcher.profileRegistryHealth
        let settingsHealth = launcher.settingsRegistryHealth()
        if profileHealth.state == .corrupted || settingsHealth.state == .corrupted {
            statusLabel?.stringValue = L10n.text(
                "management.health-warning",
                fallback: "管理情報の一部を読み込めません。設定からバックアップを確認してください。"
            )
            statusLabel?.textColor = .systemOrange
            statusLabel?.isHidden = false
        } else {
            statusLabel?.stringValue = ""
            statusLabel?.textColor = .secondaryLabelColor
            statusLabel?.isHidden = true
        }

        tableView?.reloadData()
        updateTableHeight(accountCount: accounts.count)
        updateControlAvailability()
        updateStatusItem()
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
            usageFetchStates = [:]
            usageLastUpdatedAt = [:]
            lastUsageRefreshAt = Date()
            scheduleUsageResetNotifications(for: [])
            updateStatusItem()
            updateStatusPopover()
            return
        }

        usageFetchStates = Dictionary(uniqueKeysWithValues: accountHomes.map { ($0.accountID, .loading) })
        tableView?.reloadData()

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
            let finishedAt = Date()
            guard let self else { return }
            let oldSnapshots = self.usageByAccountID
            let accountIDs = Set(accountHomes.map(\.accountID))
            let merged = UsageRefreshMerger.merge(
                previousSnapshots: oldSnapshots,
                previousLastUpdatedAt: self.usageLastUpdatedAt,
                fetchedSnapshots: snapshots,
                accountIDs: accountIDs,
                finishedAt: finishedAt
            )
            self.usageByAccountID = merged.snapshots
            self.usageLastUpdatedAt = merged.lastUpdatedAt
            self.lastUsageRefreshAt = finishedAt
            self.usageFetchStates = Dictionary(uniqueKeysWithValues: accountHomes.map { accountID, _ in
                (accountID, snapshots[accountID] == nil
                    ? .failed(self.usageLastUpdatedAt[accountID])
                    : .loaded(finishedAt))
            })
            self.evaluateUsageThresholdNotifications(previous: oldSnapshots, refreshed: snapshots)
            self.scheduleUsageResetNotifications(
                for: accountHomes.compactMap { accountID, _ in
                    guard let snapshot = self.usageByAccountID[accountID],
                          let account = self.launcher.accounts.first(where: { $0.id == accountID }) else {
                        return nil
                    }
                    return (account, snapshot)
                }
            )
            self.tableView?.reloadData()
            self.updateTableHeight(accountCount: self.launcher.accounts.count)
            self.updateStatusItem()
            if self.statusPopover?.isShown == true {
                self.updateStatusPopover()
            }
        }
    }

    private func evaluateUsageThresholdNotifications(
        previous: [UUID: AccountUsageSnapshot],
        refreshed: [UUID: AccountUsageSnapshot]
    ) {
        let center = UNUserNotificationCenter.current()
        var notifications: [(String, String)] = []
        for (accountID, snapshot) in refreshed {
            guard let account = launcher.accounts.first(where: { $0.id == accountID }) else { continue }
            let old = previous[accountID]
            let windows: [(String, String, UsageWindow?, UsageWindow?)] = [
                ("5H", "primary", old?.primary, snapshot.primary),
                (L10n.text("usage.weekly", fallback: "週間"), "secondary", old?.secondary, snapshot.secondary)
            ]
            for (displayName, key, oldWindow, newWindow) in windows {
                guard let newWindow else { continue }
                let thresholds: [(Int, Bool)] = [(10, usageCriticalNotificationsEnabled), (25, usageWarningNotificationsEnabled)]
                let crossedThresholds = UsageThresholdEvaluator.crossedThresholds(
                    previous: oldWindow,
                    current: newWindow,
                    thresholds: thresholds.map(\.0)
                )
                for (threshold, enabled) in thresholds where enabled && crossedThresholds.contains(threshold) {
                    let notificationKey = "\(accountID.uuidString)-\(key)-\(threshold)"
                    if newWindow.remainingPercent > threshold {
                        notifiedUsageThresholds.remove(notificationKey)
                        continue
                    }
                    guard !notifiedUsageThresholds.contains(notificationKey) else { continue }
                    notifiedUsageThresholds.insert(notificationKey)
                    let level = threshold == 10
                        ? L10n.text("usage.threshold.critical", fallback: "危険")
                        : L10n.text("usage.threshold.warning", fallback: "注意")
                    notifications.append((
                        L10n.text("usage.threshold.title", fallback: "利用上限の{level}", replacing: ["level": level]),
                        L10n.text(
                            "usage.threshold.body",
                            fallback: "{name}の{window}は残り{remaining}%です。",
                            replacing: ["name": account.name, "window": displayName, "remaining": "\(newWindow.remainingPercent)"]
                        )
                    ))
                }
            }
        }
        guard !notifications.isEmpty else { return }
        Task { @MainActor in
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }
            for (title, body) in notifications {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default
                try? await center.add(UNNotificationRequest(
                    identifier: "usage-threshold-\(UUID().uuidString)",
                    content: content,
                    trigger: nil
                ))
            }
        }
    }

    @objc
    private func refreshUsageManually() {
        refreshUsage()
        showTransientStatus(
            L10n.text("usage.refresh.started", fallback: "利用状況を更新しています…")
        )
    }

    private var usageNotificationsEnabled: Bool {
        guard UserDefaults.standard.object(forKey: usageNotificationsEnabledKey) != nil else {
            // Notifications are opt-in so opening the manager never prompts
            // for system permission unexpectedly.
            return false
        }
        return UserDefaults.standard.bool(forKey: usageNotificationsEnabledKey)
    }

    private func scheduleUsageResetNotifications(
        for entries: [(AccountProfile, AccountUsageSnapshot)]
    ) {
        let center = UNUserNotificationCenter.current()
        let persistedIDs = Set(UserDefaults.standard.stringArray(forKey: scheduledUsageNotificationIDsKey) ?? [])
        let oldIDs = Array(scheduledUsageNotificationIDs.union(persistedIDs))
        scheduledUsageNotificationIDs.removeAll()
        UserDefaults.standard.removeObject(forKey: scheduledUsageNotificationIDsKey)
        if !oldIDs.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: oldIDs)
        }
        guard usageNotificationsEnabled else { return }

        let now = Date()
        var requests: [UNNotificationRequest] = []
        for (account, snapshot) in entries {
            let windows: [(String, String, UsageWindow?)] = [
                ("primary", "5H", snapshot.primary),
                ("secondary", L10n.text("usage.weekly", fallback: "週間"), snapshot.secondary)
            ]
            for (kindKey, kind, window) in windows {
                guard let resetDate = window?.resetsAt, resetDate > now.addingTimeInterval(30) else { continue }
                let identifier = "usage-reset-\(account.id.uuidString)-\(kindKey)"
                let content = UNMutableNotificationContent()
                content.title = L10n.text("usage.notification.title", fallback: "利用上限がリセットされました")
                content.body = L10n.text(
                    "usage.notification.body",
                    fallback: "{name}の{kind}枠がリセットされました。",
                    replacing: ["name": account.name, "kind": kind]
                )
                content.sound = .default
                let components = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second],
                    from: resetDate
                )
                requests.append(
                    UNNotificationRequest(
                        identifier: identifier,
                        content: content,
                        trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                    )
                )
                scheduledUsageNotificationIDs.insert(identifier)
            }
        }
        UserDefaults.standard.set(
            scheduledUsageNotificationIDs.sorted(),
            forKey: scheduledUsageNotificationIDsKey
        )
        guard !requests.isEmpty else { return }

        Task { @MainActor in
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }
            for request in requests {
                try? await center.add(request)
            }
        }
    }

    private func updateTableHeight(accountCount: Int) {
        let desiredHeight: CGFloat
        if launcher.accounts.isEmpty {
            desiredHeight = collapsedAccountRowHeight + 1
        } else {
            desiredHeight = launcher.accounts.reduce(CGFloat(1)) { height, account in
                height + accountRowHeight(for: account)
            }
        }
        tableHeightConstraint?.constant = min(max(desiredHeight, 76), 420)
    }

    private func accountRowHeight(for account: AccountProfile) -> CGFloat {
        guard let resetCredits = usageByAccountID[account.id]?.rateLimitResetCredits,
              resetCredits.availableCount > 0,
              expandedResetCreditAccountIDs.contains(account.id) else {
            return collapsedAccountRowHeight
        }
        return expandedAccountRowHeight
    }

    private func updateControlAvailability() {
        addButton?.isEnabled = !isLaunching
        tableView?.isEnabled = !isLaunching
        revealButton?.isEnabled = !isLaunching
        // Settings is read-only while a profile is launching, so keep it
        // available even when the profile table is temporarily locked.
        usageRefreshButton?.isEnabled = !isLaunching
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        launcher.accounts.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard launcher.accounts.indices.contains(row) else {
            return collapsedAccountRowHeight
        }
        return accountRowHeight(for: launcher.accounts[row])
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
            rowCard.topAnchor.constraint(equalTo: cell.topAnchor, constant: 3),
            rowCard.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -3)
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

        let infoStack = NSStackView()
        infoStack.orientation = .horizontal
        infoStack.alignment = .centerY
        infoStack.spacing = 6
        infoStack.translatesAutoresizingMaskIntoConstraints = false
        infoStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rowStack.addArrangedSubview(infoStack)

        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
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
        infoStack.addArrangedSubview(dragContainer)

        let isExisting = account.id == launcher.existingEnvironmentAccount?.id
        let isRunning = launcher.isAccountRunning(id: account.id)
        let isStorageMissing = !isExisting && !launcher.isProfileStorageAvailable(account)
        let usageSnapshot = usageByAccountID[account.id]

        if editingAccountID == account.id {
            let nameEditorStack = NSStackView()
            nameEditorStack.orientation = .horizontal
            nameEditorStack.alignment = .centerY
            nameEditorStack.spacing = 4

            let nameField = NSTextField(frame: .zero)
            nameField.stringValue = account.name
            nameField.font = .systemFont(ofSize: 15, weight: .semibold)
            nameField.lineBreakMode = .byTruncatingTail
            nameField.maximumNumberOfLines = 1
            nameField.translatesAutoresizingMaskIntoConstraints = false
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
            nameField.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
            nameField.heightAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true
            nameField.identifier = NSUserInterfaceItemIdentifier(account.id.uuidString)
            nameField.target = self
            nameField.action = #selector(commitInlineRename(_:))
            nameEditorStack.addArrangedSubview(nameField)

            let saveButton = NSButton(
                title: L10n.text("account.rename.save", fallback: "保存"),
                target: self,
                action: #selector(saveInlineRename(_:))
            )
            saveButton.bezelStyle = .rounded
            saveButton.controlSize = .small
            saveButton.image = NSImage(
                systemSymbolName: "checkmark",
                accessibilityDescription: nil
            )
            saveButton.imagePosition = .imageLeading
            saveButton.contentTintColor = .systemGreen
            saveButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
            saveButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true
            saveButton.setAccessibilityLabel(
                L10n.text(
                    "account.rename.save-accessibility-label",
                    fallback: "{name}の名前を保存",
                    replacing: ["name": account.name]
                )
            )
            saveButton.toolTip = L10n.text(
                "account.rename.save-tooltip",
                fallback: "名前を保存"
            )
            saveButton.identifier = NSUserInterfaceItemIdentifier(account.id.uuidString)
            nameEditorStack.addArrangedSubview(saveButton)

            let cancelButton = NSButton(
                title: L10n.text("account.rename.cancel", fallback: "キャンセル"),
                target: self,
                action: #selector(cancelInlineRename(_:))
            )
            cancelButton.bezelStyle = .rounded
            cancelButton.controlSize = .small
            cancelButton.image = NSImage(
                systemSymbolName: "xmark",
                accessibilityDescription: nil
            )
            cancelButton.imagePosition = .imageLeading
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true
            cancelButton.setAccessibilityLabel(
                L10n.text(
                    "account.rename.cancel-accessibility-label",
                    fallback: "{name}の名前の編集をキャンセル",
                    replacing: ["name": account.name]
                )
            )
            cancelButton.toolTip = L10n.text(
                "account.rename.cancel-tooltip",
                fallback: "名前の編集をキャンセル"
            )
            cancelButton.identifier = NSUserInterfaceItemIdentifier(account.id.uuidString)
            nameEditorStack.addArrangedSubview(cancelButton)

            labels.addArrangedSubview(nameEditorStack)
            editingNameField = nameField
        } else {
            let nameStack = NSStackView()
            nameStack.orientation = .horizontal
            nameStack.alignment = .centerY
            nameStack.spacing = 4

            let nameLabel = NSTextField(labelWithString: account.name)
            nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
            nameLabel.lineBreakMode = .byTruncatingTail
            nameLabel.maximumNumberOfLines = 1
            nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            nameStack.addArrangedSubview(nameLabel)

            let editButton = makeAccountIconButton(
                systemName: "pencil",
                accessibilityLabel: L10n.text(
                    "account.rename.accessibility-label",
                    fallback: "{name}の名前を編集",
                    replacing: ["name": account.name]
                ),
                toolTip: L10n.text(
                    "account.rename.tooltip",
                    fallback: "名前を編集"
                ),
                action: #selector(beginRenameAccount(_:))
            )
            editButton.identifier = NSUserInterfaceItemIdentifier(account.id.uuidString)
            nameStack.addArrangedSubview(editButton)

            labels.addArrangedSubview(nameStack)
        }

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

        if !isExisting,
           launcher.profileLauncherStatus(for: account) == .needsUpdate {
            metadataStack.addArrangedSubview(
                ProfileBadgeView(
                    text: L10n.text("launcher.needs-update-badge", fallback: "ランチャー更新が必要"),
                    color: .systemOrange
                )
            )
        }

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

        if isStorageMissing {
            metadataStack.addArrangedSubview(
                ProfileBadgeView(
                    text: L10n.text("diagnostics.missing-badge", fallback: "保存先不明"),
                    color: .systemRed
                )
            )
        }

        let usageState = usageFetchStates[account.id]
        let planName = usageSnapshot?.displayPlanName ?? "—"
        let planSuffix: String
        switch usageState {
        case .some(.loading):
            planSuffix = L10n.text("usage.fetching", fallback: "（取得中）")
        case .some(.failed):
            planSuffix = L10n.text("usage.fetch-failed", fallback: "（取得失敗）")
        default:
            planSuffix = ""
        }
        let planLabel = NSTextField(
            labelWithString: L10n.text(
                "usage.plan",
                fallback: "プラン: {plan}{suffix}",
                replacing: ["plan": planName, "suffix": planSuffix]
            )
        )
        planLabel.font = .systemFont(ofSize: 11, weight: .medium)
        planLabel.textColor = usageSnapshot?.displayPlanName == nil
            ? .tertiaryLabelColor
            : .secondaryLabelColor
        planLabel.setContentHuggingPriority(.required, for: .horizontal)
        switch usageState {
        case let .some(.loaded(updatedAt)):
            planLabel.toolTip = L10n.text(
                "usage.last-updated",
                fallback: "利用状況の最終確認: {date}",
                replacing: ["date": formatFetchDate(updatedAt)]
            )
        case let .some(.failed(updatedAt)):
            planLabel.toolTip = L10n.text(
                "usage.fetch-failed-tooltip",
                fallback: "利用状況の取得に失敗しました。{date}",
                replacing: [
                    "date": updatedAt.map { "（最終確認: \(formatFetchDate($0))）" } ?? ""
                ]
            )
        case .some(.loading), .none:
            planLabel.toolTip = L10n.text(
                "usage.fetch-status-tooltip",
                fallback: "利用状況を確認しています。"
            )
        }
        metadataStack.addArrangedSubview(planLabel)

        let loginState = launcher.loginState(for: account)
        let loginText: String
        let loginColor: NSColor
        switch loginState {
        case let .signedIn(email):
            loginText = L10n.text(
                "profile.login.signed-in",
                fallback: "ログイン: {email}",
                replacing: ["email": email]
            )
            loginColor = .secondaryLabelColor
        case .signedOut:
            loginText = L10n.text("profile.login.signed-out", fallback: "未ログイン")
            loginColor = .systemOrange
        case .unavailable:
            loginText = L10n.text("profile.login.unavailable", fallback: "ログイン情報を確認できません")
            loginColor = .tertiaryLabelColor
        }
        let loginLabel = NSTextField(labelWithString: loginText)
        loginLabel.font = .systemFont(ofSize: 10, weight: .regular)
        loginLabel.textColor = loginColor
        loginLabel.lineBreakMode = .byTruncatingMiddle
        loginLabel.maximumNumberOfLines = 1
        loginLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        loginLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        loginLabel.toolTip = loginText
        metadataStack.addArrangedSubview(loginLabel)

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

        let usageRow = NSStackView()
        usageRow.orientation = .horizontal
        usageRow.alignment = .top
        usageRow.spacing = 18
        usageRow.setContentCompressionResistancePriority(.required, for: .vertical)
        usageRow.addArrangedSubview(usageStack)

        if let resetCredits = usageSnapshot?.rateLimitResetCredits,
           resetCredits.availableCount > 0 {
            let usageSpacer = NSView()
            usageSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            usageSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            usageRow.addArrangedSubview(usageSpacer)
            usageRow.addArrangedSubview(
                makeResetCreditDisclosure(accountID: account.id, summary: resetCredits)
            )
        }
        labels.addArrangedSubview(usageRow)

        let directoryLabel = NSTextField(
            labelWithString: isStorageMissing
                ? L10n.text("diagnostics.missing-storage", fallback: "保存先: 不明（再指定が必要）")
                : isExisting
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
        infoStack.addArrangedSubview(labels)

        let actionsRow = NSStackView()
        actionsRow.orientation = .horizontal
        actionsRow.alignment = .centerY
        actionsRow.spacing = 6
        actionsRow.translatesAutoresizingMaskIntoConstraints = false
        actionsRow.heightAnchor.constraint(equalToConstant: 30).isActive = true
        actionsRow.setContentHuggingPriority(.required, for: .horizontal)
        actionsRow.setContentCompressionResistancePriority(.required, for: .horizontal)
        rowStack.addArrangedSubview(actionsRow)

        let menuButton = makeAccountIconButton(
            systemName: "ellipsis",
            accessibilityLabel: L10n.text(
                "profile.menu.accessibility-label",
                fallback: "プロファイルの操作メニュー"
            ),
            toolTip: L10n.text(
                "profile.menu.tooltip",
                fallback: "プロファイルの操作を表示"
            ),
            action: #selector(showProfileMenu(_:))
        )
        menuButton.identifier = NSUserInterfaceItemIdentifier(account.id.uuidString)
        actionsRow.addArrangedSubview(menuButton)

        let openButton = NSButton(
            title: isRunning
                ? L10n.text("account.focus", fallback: "開く")
                : L10n.text("account.open", fallback: "起動"),
            target: self,
            action: #selector(openAccount(_:))
        )
        openButton.bezelStyle = .rounded
        openButton.controlSize = .large
        openButton.isBordered = false
        openButton.wantsLayer = true
        openButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        openButton.layer?.cornerRadius = 7
        openButton.contentTintColor = .white
        openButton.font = .systemFont(ofSize: 13, weight: .semibold)
        openButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
        openButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        openButton.identifier = NSUserInterfaceItemIdentifier(account.id.uuidString)
        openButton.isEnabled = !isLaunching
            && (isExisting || !isStorageMissing)
        openButton.setAccessibilityLabel(
            isRunning
                ? L10n.text(
                    "account.focus.accessibility-label",
                    fallback: "{name}のChatGPTを開く",
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
                "account.focus.tooltip",
                fallback: "このプロファイルのChatGPTを前面に表示"
            )
            : (isStorageMissing
                ? L10n.text("diagnostics.missing-tooltip", fallback: "保存先を再指定してから起動してください")
                : nil)
        actionsRow.addArrangedSubview(openButton)

        return cell
    }

    private func makeAccountIconButton(
        systemName: String,
        accessibilityLabel: String,
        toolTip: String,
        action: Selector
    ) -> NSButton {
        let button = NSButton(
            image: NSImage(
                systemSymbolName: systemName,
                accessibilityDescription: accessibilityLabel
            ) ?? NSImage(),
            target: self,
            action: action
        )
        button.bezelStyle = .inline
        button.controlSize = .regular
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        button.setAccessibilityLabel(accessibilityLabel)
        button.toolTip = toolTip
        return button
    }

    private func makeAccountSecondaryActionButton(
        title: String,
        action: Selector,
        systemName: String? = nil,
        tintColor: NSColor = .labelColor
    ) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        button.layer?.cornerRadius = 7
        button.contentTintColor = tintColor
        button.font = .systemFont(ofSize: 12, weight: .semibold)
        button.cell?.font = .systemFont(ofSize: 12, weight: .semibold)
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        if let systemName {
            button.image = NSImage(
                systemSymbolName: systemName,
                accessibilityDescription: nil
            )
            button.imagePosition = .imageLeading
        }
        return button
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
            for credit in summary.creditsSortedByExpiry {
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

    private func makeResetCreditDisclosure(
        accountID: UUID,
        summary: RateLimitResetCreditsSummary,
        isExpanded: Bool? = nil,
        action: Selector = #selector(toggleResetCredits(_:))
    ) -> NSView {
        let labels = makeResetCreditLabels(summary)
        guard let titleLabel = labels.first else {
            return NSView()
        }

        let isExpanded = isExpanded ?? expandedResetCreditAccountIDs.contains(accountID)
        let disclosureButton = NSButton(
            title: titleLabel.stringValue,
            target: self,
            action: action
        )
        disclosureButton.bezelStyle = .inline
        disclosureButton.controlSize = .small
        disclosureButton.isBordered = false
        disclosureButton.imagePosition = .imageLeading
        disclosureButton.image = NSImage(
            systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil
        )
        disclosureButton.contentTintColor = .systemOrange
        disclosureButton.font = titleLabel.font
        disclosureButton.alignment = .left
        disclosureButton.identifier = NSUserInterfaceItemIdentifier(accountID.uuidString)
        let disclosureAccessibilityLabel = L10n.text(
            isExpanded
                ? "usage.reset-credits.collapse"
                : "usage.reset-credits.expand",
            fallback: isExpanded
                ? "上限リセットの期限一覧を折りたたむ"
                : "上限リセットの期限一覧を表示"
        )
        disclosureButton.setAccessibilityLabel(disclosureAccessibilityLabel)
        disclosureButton.toolTip = disclosureAccessibilityLabel
        disclosureButton.setContentHuggingPriority(.required, for: .horizontal)
        disclosureButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let detailsStack = NSStackView()
        detailsStack.orientation = .vertical
        detailsStack.alignment = .leading
        detailsStack.spacing = 1
        detailsStack.isHidden = !isExpanded
        labels.dropFirst().forEach { detailsStack.addArrangedSubview($0) }

        let disclosureStack = NSStackView()
        disclosureStack.orientation = .vertical
        disclosureStack.alignment = .leading
        disclosureStack.spacing = 1
        disclosureStack.setContentHuggingPriority(.required, for: .horizontal)
        disclosureStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        disclosureStack.addArrangedSubview(disclosureButton)
        disclosureStack.addArrangedSubview(detailsStack)
        return disclosureStack
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

    private func formatFetchDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.language.locale
        formatter.dateFormat = L10n.language == .japanese ? "M月d日 HH:mm" : "MMM d, HH:mm"
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

    private func accountID(from sender: NSButton) -> UUID? {
        guard let rawID = sender.identifier?.rawValue else { return nil }
        return UUID(uuidString: rawID)
    }

    private func accountID(from item: NSMenuItem) -> UUID? {
        guard let rawID = item.representedObject as? String else { return nil }
        return UUID(uuidString: rawID)
    }

    @objc
    private func toggleResetCredits(_ sender: NSButton) {
        guard let accountID = accountID(from: sender) else { return }
        if expandedResetCreditAccountIDs.contains(accountID) {
            expandedResetCreditAccountIDs.remove(accountID)
        } else {
            expandedResetCreditAccountIDs.insert(accountID)
        }
        tableView?.reloadData()
        updateTableHeight(accountCount: launcher.accounts.count)
    }

    @objc
    private func toggleMenuBarResetCredits(_ sender: NSButton) {
        guard let accountID = accountID(from: sender) else { return }
        if expandedMenuBarResetCreditAccountIDs.contains(accountID) {
            expandedMenuBarResetCreditAccountIDs.remove(accountID)
        } else {
            expandedMenuBarResetCreditAccountIDs.insert(accountID)
        }
        updateStatusPopover()
    }

    @objc
    private func showProfileMenu(_ sender: NSButton) {
        guard let accountID = accountID(from: sender),
              let account = launcher.accounts.first(where: { $0.id == accountID }) else {
            return
        }

        let isExisting = account.id == launcher.existingEnvironmentAccount?.id
        let isRunning = launcher.isAccountRunning(id: account.id)
        let menu = NSMenu()
        menu.autoenablesItems = false

        func addItem(
            _ title: String,
            action: Selector,
            enabled: Bool = true
        ) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = account.id.uuidString
            item.isEnabled = enabled
            menu.addItem(item)
        }

        if isRunning {
            addItem(
                L10n.text("profile.menu.quit", fallback: "ChatGPTを終了"),
                action: #selector(quitAccountFromMenu(_:)),
                enabled: !isLaunching
            )
        }

        addItem(
            account.showsInMenuBar
                ? L10n.text("profile.menu.hide-menubar", fallback: "メニューバーから隠す")
                : L10n.text("profile.menu.show-menubar", fallback: "メニューバーに表示"),
            action: #selector(toggleMenuBarVisibility(_:))
        )
        addItem(
            account.isFavorite
                ? L10n.text("profile.menu.unfavorite", fallback: "お気に入りを解除")
                : L10n.text("profile.menu.favorite", fallback: "お気に入りにする"),
            action: #selector(toggleMenuBarFavoriteFromMenu(_:))
        )

        if let storageURL = profileStorageURL(for: account) {
            if !menu.items.isEmpty {
                menu.addItem(.separator())
            }
            addItem(
                L10n.text("profile.menu.reveal-storage", fallback: "Finderで保存先を開く"),
                action: #selector(revealProfileStorageFromMenu(_:)),
                enabled: FileManager.default.fileExists(atPath: storageURL.path)
            )
        }

        if !isExisting {
            addItem(
                L10n.text(
                    launcher.hasProfileLauncher(for: account)
                        ? "launcher.update"
                        : "launcher.generate",
                    fallback: launcher.hasProfileLauncher(for: account)
                        ? "Dock用起動アプリを再作成…"
                        : "Dock用起動アプリを作成…"
                ),
                action: #selector(generateProfileLauncherFromMenu(_:)),
                enabled: !isLaunching
            )
        }

        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        let isShared = launcher.settingsBinding(for: account) != nil
        addItem(
            isShared
                ? L10n.text("settings-sharing.manage", fallback: "共有設定を管理…")
                : L10n.text("settings-sharing.share", fallback: "設定の共有…"),
            action: #selector(manageSettingsShareFromMenu(_:)),
            enabled: !isLaunching
        )
        addItem(
            L10n.text(
                "settings-sharing.copy-from-profile",
                fallback: "別のプロファイルから設定をコピー…"
            ),
            action: #selector(copySettingsFromMenu(_:)),
            enabled: launcher.accounts.count > 1 && !isLaunching
        )
        if launcher.latestSettingsCopy(for: account) != nil {
            addItem(
                L10n.text("settings-sharing.restore-last-copy", fallback: "最後の設定コピーを復元…"),
                action: #selector(restoreSettingsCopyFromMenu(_:)),
                enabled: !isLaunching && !isRunning
            )
        }

        if !isExisting {
            menu.addItem(.separator())
            addItem(
                L10n.text("diagnostics.menu", fallback: "プロファイルを診断…"),
                action: #selector(diagnoseProfileFromMenu(_:)),
                enabled: !isDiagnosticsRunning
            )
        }

        if !isExisting {
            menu.addItem(.separator())
            addItem(
                L10n.text("profile.menu.delete", fallback: "プロファイルを削除…"),
                action: #selector(deleteAccountFromMenu(_:)),
                enabled: !isRunning && !isLaunching
            )
        }

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: sender.bounds.minX, y: sender.bounds.maxY + 4),
            in: sender
        )
    }

    @objc
    private func generateProfileLauncherFromMenu(_ sender: NSMenuItem) {
        guard let accountID = accountID(from: sender) else {
            presentError(ProfileManagerError.accountNotFound)
            return
        }
        generateProfileLauncher(accountID: accountID)
    }

    @objc
    private func deleteAccountFromMenu(_ sender: NSMenuItem) {
        guard let accountID = accountID(from: sender) else {
            presentError(ProfileManagerError.accountNotFound)
            return
        }
        deleteAccountRegistration(accountID: accountID)
    }

    @objc
    private func revealProfileStorageFromMenu(_ sender: NSMenuItem) {
        guard let accountID = accountID(from: sender),
              let account = launcher.accounts.first(where: { $0.id == accountID }),
              let storageURL = profileStorageURL(for: account) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([storageURL])
    }

    @objc
    private func manageSettingsShareFromMenu(_ sender: NSMenuItem) {
        guard let accountID = accountID(from: sender),
              let account = launcher.accounts.first(where: { $0.id == accountID }) else { return }
        if launcher.settingsBinding(for: account) == nil {
            presentCreateSettingsShare(sourceAccountID: accountID)
        } else {
            presentManageSettingsShare(accountID: accountID)
        }
    }

    @objc
    private func copySettingsFromMenu(_ sender: NSMenuItem) {
        guard let accountID = accountID(from: sender) else {
            presentError(ProfileManagerError.accountNotFound)
            return
        }
        presentCopySettings(destinationAccountID: accountID)
    }

    @objc
    private func restoreSettingsCopyFromMenu(_ sender: NSMenuItem) {
        guard let accountID = accountID(from: sender),
              let destination = launcher.accounts.first(where: { $0.id == accountID }) else {
            presentError(ProfileManagerError.accountNotFound)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("settings-sharing.restore-title", fallback: "最後の設定コピーを復元")
        alert.informativeText = L10n.text(
            "settings-sharing.restore-message",
            fallback: "「{name}」の設定を、直前のコピー前の状態へ戻します。ChatGPTを終了している必要があります。",
            replacing: ["name": destination.name]
        )
        alert.addButton(withTitle: L10n.text("settings-sharing.restore", fallback: "復元"))
        alert.addButton(withTitle: L10n.text("common.cancel", fallback: "キャンセル"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let restored = try launcher.restoreLatestSettingsCopy(for: accountID)
            refreshUI()
            showTransientStatus(
                L10n.text(
                    "settings-sharing.restored",
                    fallback: "{count}項目をコピー前の状態へ復元しました。",
                    replacing: ["count": "\(restored.count)"]
                )
            )
        } catch {
            presentError(error, title: L10n.text("settings-sharing.restore-failed", fallback: "設定を復元できませんでした"))
        }
    }

    @objc
    private func diagnoseProfileFromMenu(_ sender: NSMenuItem) {
        guard let accountID = accountID(from: sender) else {
            presentError(ProfileManagerError.accountNotFound)
            return
        }
        showDiagnostics(accountID: accountID)
    }

    private func profileStorageURL(for account: AccountProfile) -> URL? {
        if account.id == launcher.existingEnvironmentAccount?.id {
            return launcher.codexHomeDirectory(for: account)
        }
        guard let baseDirectory = try? launcher.profileBaseDirectory() else { return nil }
        return ProfilePaths(profile: account, baseDirectory: baseDirectory).root
    }

    private func openOrFocusAccount(_ account: AccountProfile) {
        guard !isLaunching else { return }
        if launcher.isAccountRunning(id: account.id) {
            if !launcher.activate(accountID: account.id) {
                presentWarning(
                    L10n.text(
                        "account.focus.unavailable",
                        fallback: "起動中のChatGPTを前面に表示できませんでした。"
                    ),
                    title: L10n.text(
                        "account.focus.error-title",
                        fallback: "ChatGPTを開けませんでした"
                    )
                )
            }
            return
        }
        launchAccount(account.id)
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

        let groupNameField = NSTextField(string: L10n.text("settings-sharing.default-name", fallback: "{name}の共有設定", replacing: ["name": sourceAccount.name]))
        groupNameField.placeholderString = L10n.text(
            "settings-sharing.group-placeholder",
            fallback: "共有グループ名"
        )
        groupNameField.translatesAutoresizingMaskIntoConstraints = false
        groupNameField.widthAnchor.constraint(equalToConstant: 460).isActive = true

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
        accessory.spacing = 16
        func section(_ title: String, content: NSView, detail: String? = nil) {
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            let heading = NSTextField(labelWithString: title)
            heading.font = .systemFont(ofSize: 12, weight: .semibold)
            stack.addArrangedSubview(heading)
            stack.addArrangedSubview(content)
            if let detail {
                let note = NSTextField(wrappingLabelWithString: detail)
                note.font = .systemFont(ofSize: 11)
                note.textColor = .secondaryLabelColor
                stack.addArrangedSubview(note)
                note.widthAnchor.constraint(equalToConstant: 460).isActive = true
            }
            accessory.addArrangedSubview(stack)
        }
        let heading = NSTextField(labelWithString: L10n.text("settings-sharing.form-title", fallback: "プロファイル間で設定を共有"))
        heading.font = .systemFont(ofSize: 20, weight: .bold)
        accessory.addArrangedSubview(heading)
        let explanation = NSTextField(wrappingLabelWithString: L10n.text("settings-sharing.form-description", fallback: "選んだ設定を複数のプロファイルで共通に使います。共有後は、設定を変更すると参加プロファイルすべてに反映されます。"))
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        accessory.addArrangedSubview(explanation)
        explanation.widthAnchor.constraint(equalToConstant: 460).isActive = true
        let sourceLabel = NSTextField(labelWithString: sourceAccount.name)
        sourceLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        section(L10n.text("settings-sharing.initial-source", fallback: "共有の元にする設定"), content: sourceLabel,
                detail: L10n.text("settings-sharing.initial-source-note", fallback: "このプロファイルの設定から共有を始めます。このプロファイル自身も共有に参加します。"))
        section(L10n.text("settings-sharing.choose-peers", fallback: "一緒に使うプロファイル（1つ以上）"), content: destinationStack,
                detail: L10n.text("settings-sharing.replace-note", fallback: "選んだ相手の設定はバックアップしてから、共有元の内容に置き換えます。"))
        section(L10n.text("settings-sharing.choose-items", fallback: "共通にする設定（1つ以上）"), content: itemStack.view)
        section(L10n.text("settings-sharing.group-name", fallback: "共有グループ名"), content: groupNameField)
        let notice = NSTextField(wrappingLabelWithString: L10n.text("settings-sharing.before-create", fallback: "作成前に、参加するすべてのプロファイルのChatGPTを終了してください。ログイン情報・チャット・プロジェクトは共有しません。"))
        notice.font = .systemFont(ofSize: 11)
        notice.textColor = .secondaryLabelColor
        accessory.addArrangedSubview(notice)
        notice.widthAnchor.constraint(equalToConstant: 460).isActive = true

        let joinButton = NSButton(title: L10n.text("settings-sharing.use-existing-group", fallback: "既存の共有グループに参加…"), target: self, action: #selector(finishShareDialog(_:)))
        joinButton.tag = NSApplication.ModalResponse.alertSecondButtonReturn.rawValue
        joinButton.bezelStyle = .rounded
        joinButton.isEnabled = launcher.settingsGroups().contains { !$0.members.contains(launcher.settingsStorageReference(for: sourceAccount)) }
        section(L10n.text("settings-sharing.existing-group-heading", fallback: "すでに共有グループがある場合"), content: joinButton)

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.addArrangedSubview(NSView())
        let cancel = NSButton(title: L10n.text("common.cancel", fallback: "キャンセル"), target: self, action: #selector(finishShareDialog(_:)))
        cancel.tag = NSApplication.ModalResponse.cancel.rawValue
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let create = NSButton(title: L10n.text("settings-sharing.create-group", fallback: "共有グループを作成"), target: self, action: #selector(finishShareDialog(_:)))
        create.tag = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        create.bezelStyle = .rounded
        create.keyEquivalent = "\r"
        footer.addArrangedSubview(cancel)
        footer.addArrangedSubview(create)
        accessory.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalToConstant: 460).isActive = true
        accessory.translatesAutoresizingMaskIntoConstraints = false
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 508, height: accessory.fittingSize.height + 48), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = L10n.text("settings-sharing.form-title", fallback: "プロファイル間で設定を共有")
        panel.isReleasedWhenClosed = false
        let content = panel.contentView!
        content.addSubview(accessory)
        NSLayoutConstraint.activate([
            accessory.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            accessory.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            accessory.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            accessory.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)
        ])
        panel.center()
        panel.initialFirstResponder = groupNameField
        defer { panel.orderOut(nil) }
        while true {
        panel.makeKeyAndOrderFront(nil)
        switch NSApp.runModal(for: panel) {
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
                presentWarning(
                    L10n.text(
                        "settings-sharing.selection-required",
                        fallback: "共有先と共有項目を1つ以上選択してください。"
                    ),
                    title: L10n.text(
                        "settings-sharing.selection-required-title",
                        fallback: "選択が必要です"
                    )
                )
                continue
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
                return
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
            panel.orderOut(nil)
            presentJoinSettingsShare(accountID: sourceAccountID)
            return
        default:
            return
        }
        }
    }

    @objc private func finishShareDialog(_ sender: NSButton) {
        NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: sender.tag))
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
        accessory.spacing = 18
        func label(_ text: String, heading: Bool = false) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: text)
            field.font = .systemFont(ofSize: heading ? 12 : 11, weight: heading ? .semibold : .regular)
            field.textColor = heading ? .labelColor : .secondaryLabelColor
            return field
        }
        let title = NSTextField(labelWithString: L10n.text("settings-copy.form-title", fallback: "プロファイルの設定をコピー"))
        title.font = .systemFont(ofSize: 20, weight: .bold)
        accessory.addArrangedSubview(title)
        let intro = label(L10n.text("settings-copy.description", fallback: "別のプロファイルの設定を、選んだ項目だけ取り込みます。コピー後はそれぞれ独立して変更できます。"))
        accessory.addArrangedSubview(intro)
        intro.widthAnchor.constraint(equalToConstant: 460).isActive = true

        let sourceColumn = NSStackView(views: [label(L10n.text("settings-sharing.source", fallback: "コピー元"), heading: true), popup])
        sourceColumn.orientation = .vertical
        sourceColumn.alignment = .leading
        sourceColumn.spacing = 8
        popup.widthAnchor.constraint(equalToConstant: 208).isActive = true
        let destinationName = NSTextField(labelWithString: destination.name)
        destinationName.font = .systemFont(ofSize: 14, weight: .semibold)
        destinationName.lineBreakMode = .byTruncatingMiddle
        destinationName.toolTip = destination.name
        destinationName.widthAnchor.constraint(equalToConstant: 208).isActive = true
        let destinationColumn = NSStackView(views: [label(L10n.text("settings-copy.destination", fallback: "コピー先（このプロファイル）"), heading: true), destinationName])
        destinationColumn.orientation = .vertical
        destinationColumn.alignment = .leading
        destinationColumn.spacing = 8
        let arrow = NSTextField(labelWithString: "→")
        arrow.font = .systemFont(ofSize: 18)
        arrow.textColor = .secondaryLabelColor
        let direction = NSStackView(views: [sourceColumn, arrow, destinationColumn])
        direction.orientation = .horizontal
        direction.alignment = .centerY
        direction.spacing = 12
        accessory.addArrangedSubview(direction)

        let items = NSStackView(views: [label(L10n.text("settings-copy.items", fallback: "コピーする設定（1つ以上）"), heading: true), itemStack.view])
        items.orientation = .vertical
        items.alignment = .leading
        items.spacing = 8
        accessory.addArrangedSubview(items)
        let notes = NSStackView()
        notes.orientation = .vertical
        notes.alignment = .leading
        notes.spacing = 6
        for text in [
            L10n.text("settings-copy.backup", fallback: "コピー先の同名設定は、バックアップしてから置き換えます。"),
            L10n.text("settings-copy.excluded", fallback: "ログイン情報・セッション・チャット・プロジェクトはコピーしません。"),
            L10n.text("settings-copy.config-note", fallback: "config.tomlをコピーする場合は、コピー後に内容を確認してください。")
        ] {
            let note = label(text)
            notes.addArrangedSubview(note)
            note.widthAnchor.constraint(equalToConstant: 460).isActive = true
        }
        accessory.addArrangedSubview(notes)
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.addArrangedSubview(NSView())
        let cancel = NSButton(title: L10n.text("common.cancel", fallback: "キャンセル"), target: self, action: #selector(finishShareDialog(_:)))
        cancel.bezelStyle = .rounded
        cancel.tag = NSApplication.ModalResponse.cancel.rawValue
        cancel.keyEquivalent = "\u{1b}"
        let next = NSButton(title: L10n.text("settings-copy.preview", fallback: "差分を確認"), target: self, action: #selector(finishShareDialog(_:)))
        next.bezelStyle = .rounded
        next.tag = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        next.keyEquivalent = "\r"
        footer.addArrangedSubview(cancel)
        footer.addArrangedSubview(next)
        accessory.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalToConstant: 460).isActive = true
        accessory.translatesAutoresizingMaskIntoConstraints = false
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 508, height: accessory.fittingSize.height + 48), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = title.stringValue
        panel.isReleasedWhenClosed = false
        let content = panel.contentView!
        content.addSubview(accessory)
        NSLayoutConstraint.activate([
            accessory.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            accessory.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            accessory.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            accessory.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)
        ])
        panel.center()
        defer { panel.orderOut(nil) }
        while true {
        panel.makeKeyAndOrderFront(nil)
        guard NSApp.runModal(for: panel) == .alertFirstButtonReturn else { return }

        let selectedItems = Set(
            itemStack.buttons.compactMap { setting, button in
                button.state == .on ? setting : nil
            }
        )
        guard !selectedItems.isEmpty else {
            presentWarning(
                L10n.text(
                    "settings-copy.selection-required",
                    fallback: "コピーする設定を1つ以上選択してください。"
                ),
                title: L10n.text(
                    "settings-sharing.selection-required-title",
                    fallback: "選択が必要です"
                )
            )
            continue
        }

        let source = sources[popup.indexOfSelectedItem]
        do {
            let diff = try launcher.previewSettingsCopy(
                from: source.id,
                to: destinationAccountID,
                items: selectedItems
            )
            panel.orderOut(nil)
            guard presentCopyDiffPreview(
                source: source,
                destination: destination,
                diff: diff
            ) else { continue }
        } catch {
            presentError(
                error,
                title: L10n.text(
                    "settings-sharing.diff-error-title",
                    fallback: "設定の差分を確認できませんでした"
                )
            )
            return
        }

        do {
            let summary = try launcher.copySettings(
                from: source.id,
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
        return
        }
    }

    private func presentCopyDiffPreview(
        source: AccountProfile,
        destination: AccountProfile,
        diff: [SettingsCopyDiff]
    ) -> Bool {
        let statusForEntry: (SettingsCopyDiff) -> (symbol: String, text: String, color: NSColor) = { entry in
            let status: String
            let symbol: String
            let color: NSColor
            if !entry.sourceExists {
                status = L10n.text("settings-sharing.diff.source-missing", fallback: "コピー元にありません")
                symbol = "−"
                color = .systemRed
            } else if !entry.destinationExists {
                status = L10n.text("settings-sharing.diff.new", fallback: "新規追加")
                symbol = "+"
                color = .systemGreen
            } else if entry.identical {
                status = L10n.text("settings-sharing.diff.same", fallback: "変更なし")
                symbol = "✓"
                color = .secondaryLabelColor
            } else {
                status = L10n.text("settings-sharing.diff.changed", fallback: "変更あり")
                symbol = "↔"
                color = .systemOrange
            }
            return (symbol, status, color)
        }

        // Keep the diff in its own panel. NSAlert places accessory views beside its
        // message area and can collapse or clip a multi-row settings summary.
        let diffList = NSStackView()
        diffList.orientation = .vertical
        diffList.alignment = .leading
        diffList.spacing = 6
        diffList.translatesAutoresizingMaskIntoConstraints = false
        for entry in diff {
            let result = statusForEntry(entry)
            let symbol = NSTextField(labelWithString: result.symbol)
            symbol.font = .systemFont(ofSize: 13, weight: .semibold)
            symbol.textColor = result.color
            symbol.alignment = .center
            symbol.setContentHuggingPriority(.required, for: .horizontal)
            symbol.widthAnchor.constraint(equalToConstant: 18).isActive = true

            let setting = NSTextField(labelWithString: entry.setting.displayName)
            setting.font = .systemFont(ofSize: 12, weight: .medium)
            setting.textColor = .labelColor
            setting.lineBreakMode = .byTruncatingMiddle
            setting.setContentHuggingPriority(.defaultLow, for: .horizontal)

            let status = NSTextField(labelWithString: result.text)
            status.font = .systemFont(ofSize: 12)
            status.textColor = result.color
            status.alignment = .right
            status.setContentHuggingPriority(.required, for: .horizontal)

            let row = NSStackView(views: [symbol, setting, status])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: 450).isActive = true
            diffList.addArrangedSubview(row)
        }
        if diff.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: L10n.text(
                "settings-sharing.diff.empty",
                fallback: "選択した設定の差分はありません。"
            ))
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            diffList.addArrangedSubview(empty)
        }

        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 14
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: L10n.text(
            "settings-sharing.diff-title",
            fallback: "設定コピー前の差分"
        ))
        title.font = .systemFont(ofSize: 20, weight: .bold)
        contentStack.addArrangedSubview(title)
        let message = NSTextField(wrappingLabelWithString: L10n.text(
            "settings-sharing.diff.message",
            fallback: "コピー元「{source}」からコピー先「{destination}」へ反映される差分です。内容そのものは表示しません。",
            replacing: ["source": source.name, "destination": destination.name]
        ))
        message.font = .systemFont(ofSize: 12)
        message.textColor = .secondaryLabelColor
        message.widthAnchor.constraint(equalToConstant: 500).isActive = true
        contentStack.addArrangedSubview(message)
        let backupNote = NSTextField(wrappingLabelWithString: L10n.text(
            "settings-sharing.diff-backup-note",
            fallback: "実行するとコピー先の既存設定はバックアップされます。"
        ))
        backupNote.font = .systemFont(ofSize: 12)
        backupNote.textColor = .secondaryLabelColor
        backupNote.widthAnchor.constraint(equalToConstant: 500).isActive = true
        contentStack.addArrangedSubview(backupNote)
        let detailsTitle = NSTextField(labelWithString: L10n.text(
            "settings-sharing.diff.details-title",
            fallback: "項目ごとの結果"
        ))
        detailsTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        detailsTitle.textColor = .secondaryLabelColor
        contentStack.addArrangedSubview(detailsTitle)
        contentStack.addArrangedSubview(diffList)

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.addArrangedSubview(NSView())
        let cancel = NSButton(
            title: L10n.text("common.cancel", fallback: "キャンセル"),
            target: self,
            action: #selector(finishShareDialog(_:))
        )
        cancel.bezelStyle = .rounded
        cancel.tag = NSApplication.ModalResponse.cancel.rawValue
        cancel.keyEquivalent = "\u{1b}"
        let copy = NSButton(
            title: L10n.text("settings-sharing.copy-confirm", fallback: "コピー"),
            target: self,
            action: #selector(finishShareDialog(_:))
        )
        copy.bezelStyle = .rounded
        copy.tag = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        copy.keyEquivalent = "\r"
        footer.addArrangedSubview(cancel)
        footer.addArrangedSubview(copy)
        footer.widthAnchor.constraint(equalToConstant: 500).isActive = true
        contentStack.addArrangedSubview(footer)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 548, height: max(contentStack.fittingSize.height + 48, 300)),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = title.stringValue
        panel.isReleasedWhenClosed = false
        let content = panel.contentView!
        content.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            contentStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            contentStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            contentStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)
        ])
        panel.center()
        panel.initialFirstResponder = copy
        defer { panel.orderOut(nil) }
        panel.makeKeyAndOrderFront(nil)
        return NSApp.runModal(for: panel) == .alertFirstButtonReturn
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

    private func presentManageSettingsShare(accountID: UUID) {
        guard let account = launcher.accounts.first(where: { $0.id == accountID }),
              let binding = launcher.settingsBinding(for: account),
              let group = launcher.settingsGroups().first(where: { $0.id == binding.groupID }) else {
            presentError(ProfileManagerError.accountNotFound)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.text(
            "settings-sharing.manage-title",
            fallback: "共有設定を管理"
        )
        alert.informativeText = L10n.text(
            "settings-sharing.manage-message",
            fallback: "「{name}」の共有設定に参加中です。共有を解除すると、現在の設定を保持したまま独立したファイルに戻します。",
            replacing: ["name": group.name]
        )
        alert.addButton(withTitle: L10n.text("settings-sharing.leave-short", fallback: "共有を解除"))
        alert.addButton(withTitle: L10n.text("common.cancel", fallback: "キャンセル"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        leaveSettingsShare(accountID: accountID)
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

        let visibleFrame = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let settingsHeight = min(860, max(520, visibleFrame.height - 80))
        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: settingsHeight),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = L10n.text(
            "settings.window-title",
            fallback: "設定"
        )
        settingsWindow.tabbingMode = .disallowed
        settingsWindow.minSize = NSSize(width: 560, height: 520)
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
                fallback: "アプリ全体の設定を管理します。"
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
                fallback: "表示言語を変更しても、プロファイル名、保存先、プロジェクト、チャットは変更されません。"
            )
        )
        dataNote.font = .systemFont(ofSize: 11)
        dataNote.textColor = .tertiaryLabelColor
        dataNote.maximumNumberOfLines = 2
        languageStack.addArrangedSubview(dataNote)
        dataNote.widthAnchor.constraint(equalTo: languageStack.widthAnchor).isActive = true

        rootStack.addArrangedSubview(languageCard)
        languageCard.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

        let notificationsCard = ProfileCardView()
        notificationsCard.translatesAutoresizingMaskIntoConstraints = false
        let notificationsStack = NSStackView()
        notificationsStack.orientation = .vertical
        notificationsStack.alignment = .leading
        notificationsStack.spacing = 8
        notificationsStack.translatesAutoresizingMaskIntoConstraints = false
        notificationsCard.addSubview(notificationsStack)
        NSLayoutConstraint.activate([
            notificationsStack.leadingAnchor.constraint(equalTo: notificationsCard.leadingAnchor, constant: 16),
            notificationsStack.trailingAnchor.constraint(equalTo: notificationsCard.trailingAnchor, constant: -16),
            notificationsStack.topAnchor.constraint(equalTo: notificationsCard.topAnchor, constant: 14),
            notificationsStack.bottomAnchor.constraint(equalTo: notificationsCard.bottomAnchor, constant: -14)
        ])
        let notificationsCheckbox = NSButton(
            checkboxWithTitle: L10n.text(
                "settings.notifications.title",
                fallback: "利用上限リセットを通知"
            ),
            target: nil,
            action: nil
        )
        notificationsCheckbox.state = usageNotificationsEnabled ? .on : .off
        notificationsCheckbox.setAccessibilityLabel(
            L10n.text(
                "settings.notifications.accessibility-label",
                fallback: "利用上限リセット通知を有効にする"
            )
        )
        notificationsStack.addArrangedSubview(notificationsCheckbox)
        let notificationsDescription = NSTextField(
            wrappingLabelWithString: L10n.text(
                "settings.notifications.description",
                fallback: "5H・週間の利用枠がリセットされる時刻にmacOS通知を表示します。初回保存時に通知の許可を求めます。"
            )
        )
        notificationsDescription.font = .systemFont(ofSize: 12)
        notificationsDescription.textColor = .secondaryLabelColor
        notificationsDescription.maximumNumberOfLines = 3
        notificationsStack.addArrangedSubview(notificationsDescription)
        notificationsDescription.widthAnchor.constraint(equalTo: notificationsStack.widthAnchor).isActive = true
        rootStack.addArrangedSubview(notificationsCard)
        notificationsCard.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

        let menuBarCard = ProfileCardView()
        menuBarCard.translatesAutoresizingMaskIntoConstraints = false
        let menuBarStack = NSStackView()
        menuBarStack.orientation = .vertical
        menuBarStack.alignment = .leading
        menuBarStack.spacing = 8
        menuBarStack.translatesAutoresizingMaskIntoConstraints = false
        menuBarCard.addSubview(menuBarStack)
        NSLayoutConstraint.activate([
            menuBarStack.leadingAnchor.constraint(equalTo: menuBarCard.leadingAnchor, constant: 16),
            menuBarStack.trailingAnchor.constraint(equalTo: menuBarCard.trailingAnchor, constant: -16),
            menuBarStack.topAnchor.constraint(equalTo: menuBarCard.topAnchor, constant: 14),
            menuBarStack.bottomAnchor.constraint(equalTo: menuBarCard.bottomAnchor, constant: -14)
        ])
        let menuBarTitle = NSTextField(labelWithString: L10n.text(
            "settings.menubar.title",
            fallback: "メニューバー"
        ))
        menuBarTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        menuBarStack.addArrangedSubview(menuBarTitle)
        let loginItemCheckbox = NSButton(
            checkboxWithTitle: L10n.text(
                "settings.menubar.login-item",
                fallback: "ログイン時に起動"
            ),
            target: nil,
            action: nil
        )
        loginItemCheckbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menuBarStack.addArrangedSubview(loginItemCheckbox)
        let compactCheckbox = NSButton(
            checkboxWithTitle: L10n.text(
                "settings.menubar.compact",
                fallback: "メニューバーに残量を表示（最小値）"
            ),
            target: nil,
            action: nil
        )
        compactCheckbox.state = compactUsageStatusEnabled ? .on : .off
        menuBarStack.addArrangedSubview(compactCheckbox)
        let warningCheckbox = NSButton(
            checkboxWithTitle: L10n.text(
                "settings.menubar.warning",
                fallback: "残量25%以下で通知"
            ),
            target: nil,
            action: nil
        )
        warningCheckbox.state = usageWarningNotificationsEnabled ? .on : .off
        menuBarStack.addArrangedSubview(warningCheckbox)
        let criticalCheckbox = NSButton(
            checkboxWithTitle: L10n.text(
                "settings.menubar.critical",
                fallback: "残量10%以下で通知"
            ),
            target: nil,
            action: nil
        )
        criticalCheckbox.state = usageCriticalNotificationsEnabled ? .on : .off
        menuBarStack.addArrangedSubview(criticalCheckbox)
        let profileVisibilityTitle = NSTextField(labelWithString: L10n.text(
            "settings.menubar.profiles-title",
            fallback: "表示するプロファイル"
        ))
        profileVisibilityTitle.font = .systemFont(ofSize: 12, weight: .medium)
        menuBarStack.addArrangedSubview(profileVisibilityTitle)
        for account in launcher.accounts {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            let checkbox = NSButton(
                checkboxWithTitle: account.name,
                target: self,
                action: #selector(toggleMenuBarVisibilityFromSettings(_:))
            )
            checkbox.identifier = NSUserInterfaceItemIdentifier(account.id.uuidString)
            checkbox.state = account.showsInMenuBar ? .on : .off
            row.addArrangedSubview(checkbox)
            row.addArrangedSubview(NSView())
            let favorite = NSButton(
                image: NSImage(systemSymbolName: account.isFavorite ? "star.fill" : "star", accessibilityDescription: nil) ?? NSImage(),
                target: self,
                action: #selector(toggleMenuBarFavorite(_:))
            )
            favorite.isBordered = false
            favorite.identifier = NSUserInterfaceItemIdentifier(account.id.uuidString)
            favorite.toolTip = L10n.text("menubar.favorite", fallback: "お気に入りを切り替え")
            favorite.setAccessibilityLabel(favorite.toolTip!)
            row.addArrangedSubview(favorite)
            menuBarStack.addArrangedSubview(row)
        }
        let menuBarDescription = NSTextField(
            wrappingLabelWithString: L10n.text(
                "settings.menubar.description",
                fallback: "アプリを閉じてもメニューバーに残り、表示中プロファイルの利用状況を確認できます。ログイン時起動と通知は個別に許可を求めます。"
            )
        )
        menuBarDescription.font = .systemFont(ofSize: 12)
        menuBarDescription.textColor = .secondaryLabelColor
        menuBarDescription.maximumNumberOfLines = 4
        menuBarStack.addArrangedSubview(menuBarDescription)
        menuBarDescription.widthAnchor.constraint(equalTo: menuBarStack.widthAnchor).isActive = true
        rootStack.addArrangedSubview(menuBarCard)
        menuBarCard.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

        let healthCard = ProfileCardView()
        healthCard.translatesAutoresizingMaskIntoConstraints = false
        let healthStack = NSStackView()
        healthStack.orientation = .vertical
        healthStack.alignment = .leading
        healthStack.spacing = 8
        healthStack.translatesAutoresizingMaskIntoConstraints = false
        healthCard.addSubview(healthStack)
        NSLayoutConstraint.activate([
            healthStack.leadingAnchor.constraint(equalTo: healthCard.leadingAnchor, constant: 16),
            healthStack.trailingAnchor.constraint(equalTo: healthCard.trailingAnchor, constant: -16),
            healthStack.topAnchor.constraint(equalTo: healthCard.topAnchor, constant: 14),
            healthStack.bottomAnchor.constraint(equalTo: healthCard.bottomAnchor, constant: -14)
        ])
        let healthTitle = NSTextField(
            labelWithString: L10n.text("settings.health.title", fallback: "管理情報の状態")
        )
        healthTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        healthStack.addArrangedSubview(healthTitle)
        let profileHealthRow = makeRegistryHealthRow(
            title: L10n.text("settings.health.profiles", fallback: "プロファイル一覧"),
            health: launcher.profileRegistryHealth,
            action: #selector(restoreProfileRegistryFromSettings(_:))
        )
        let settingsHealthRow = makeSettingsHealthRow(
            title: L10n.text("settings.health.settings", fallback: "共有グループの管理情報"),
            health: launcher.settingsRegistryHealth(),
            action: #selector(restoreSettingsRegistryFromSettings(_:))
        )
        healthStack.addArrangedSubview(profileHealthRow.stack)
        healthStack.addArrangedSubview(settingsHealthRow.stack)
        healthStack.addArrangedSubview(
            makeDependencyHealthRow(
                title: L10n.text("settings.health.chatgpt", fallback: "ChatGPT.app"),
                available: launcher.chatGPTApplicationURL != nil
            )
        )
        healthStack.addArrangedSubview(
            makeDependencyHealthRow(
                title: L10n.text("settings.health.codex", fallback: "Codexコマンド"),
                available: UsageService.codexExecutableURLForDiagnostics() != nil
            )
        )
        rootStack.addArrangedSubview(healthCard)
        healthCard.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

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
        settingsUsageNotificationCheckbox = notificationsCheckbox
        settingsLoginItemCheckbox = loginItemCheckbox
        settingsCompactUsageCheckbox = compactCheckbox
        settingsUsageWarningCheckbox = warningCheckbox
        settingsUsageCriticalCheckbox = criticalCheckbox
        settingsProfileHealthLabel = profileHealthRow.label
        settingsProfileRestoreButton = profileHealthRow.button
        settingsSettingsHealthLabel = settingsHealthRow.label
        settingsSettingsRestoreButton = settingsHealthRow.button
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc
    private func showSettingsFromButton(_ sender: NSButton) {
        showSettings()
    }

    @objc
    private func showSettingsGroups() {
        if let groupsWindow, groupsWindow.isVisible {
            groupsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let groupsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        groupsWindow.title = L10n.text("settings.groups.window-title", fallback: "共有グループ")
        groupsWindow.minSize = NSSize(width: 500, height: 360)
        groupsWindow.isReleasedWhenClosed = false
        groupsWindow.center()
        groupsWindow.delegate = self

        let contentView = NSView()
        groupsWindow.contentView = contentView
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18)
        ])

        let title = NSTextField(labelWithString: L10n.text("settings.groups.title", fallback: "設定共有グループ"))
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        root.addArrangedSubview(title)
        let description = NSTextField(
            wrappingLabelWithString: L10n.text(
                "settings.groups.description",
                fallback: "各プロファイルが参加している共有グループと、共有している設定項目を確認できます。"
            )
        )
        description.font = .systemFont(ofSize: 12)
        description.textColor = .secondaryLabelColor
        description.maximumNumberOfLines = 2
        root.addArrangedSubview(description)
        description.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let groupStack = NSStackView()
        groupStack.orientation = .vertical
        groupStack.alignment = .leading
        groupStack.spacing = 10
        groupStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = groupStack
        root.addArrangedSubview(scrollView)
        scrollView.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        groupStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let groups = launcher.settingsGroups()
        if groups.isEmpty {
            let empty = NSTextField(
                wrappingLabelWithString: L10n.text(
                    "settings.groups.empty",
                    fallback: "共有グループはまだありません。プロファイルの「…」メニューから作成できます。"
                )
            )
            empty.font = .systemFont(ofSize: 13)
            empty.textColor = .secondaryLabelColor
            empty.maximumNumberOfLines = 2
            groupStack.addArrangedSubview(empty)
        } else {
            for group in groups.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                let card = ProfileCardView()
                card.translatesAutoresizingMaskIntoConstraints = false
                let stack = NSStackView()
                stack.orientation = .vertical
                stack.alignment = .leading
                stack.spacing = 5
                stack.translatesAutoresizingMaskIntoConstraints = false
                card.addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
                    stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
                    stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
                    stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12)
                ])
                let groupTitle = NSTextField(labelWithString: group.name)
                groupTitle.font = .systemFont(ofSize: 14, weight: .semibold)
                stack.addArrangedSubview(groupTitle)
                let memberNames = group.members.map(profileDisplayName(for:)).joined(separator: "、")
                let members = NSTextField(
                    wrappingLabelWithString: L10n.text(
                        "settings.groups.members",
                        fallback: "参加プロファイル: {members}",
                        replacing: ["members": memberNames]
                    )
                )
                members.font = .systemFont(ofSize: 12)
                members.textColor = .secondaryLabelColor
                members.maximumNumberOfLines = 2
                stack.addArrangedSubview(members)
                let itemNames = group.items.map(\.displayName).joined(separator: "、")
                let items = NSTextField(
                    wrappingLabelWithString: L10n.text(
                        "settings.groups.items",
                        fallback: "共有項目: {items}",
                        replacing: ["items": itemNames]
                    )
                )
                items.font = .systemFont(ofSize: 12)
                items.textColor = .secondaryLabelColor
                items.maximumNumberOfLines = 2
                stack.addArrangedSubview(items)
                let updated = NSTextField(
                    labelWithString: L10n.text(
                        "settings.groups.updated",
                        fallback: "最終更新: {date}",
                        replacing: ["date": formatFetchDate(group.updatedAt)]
                    )
                )
                updated.font = .systemFont(ofSize: 10)
                updated.textColor = .tertiaryLabelColor
                stack.addArrangedSubview(updated)
                groupStack.addArrangedSubview(card)
                card.widthAnchor.constraint(equalTo: groupStack.widthAnchor).isActive = true
            }
        }

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.translatesAutoresizingMaskIntoConstraints = false
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(spacer)
        let close = NSButton(title: L10n.text("common.close", fallback: "閉じる"), target: self, action: #selector(closeGroupsWindow))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        footer.addArrangedSubview(close)
        root.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        self.groupsWindow = groupsWindow
        groupsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc
    private func closeGroupsWindow() {
        groupsWindow?.performClose(nil)
    }

    private func profileDisplayName(for reference: ProfileStorageReference) -> String {
        launcher.accounts.first(where: { launcher.settingsStorageReference(for: $0) == reference })?.name
            ?? reference.stableKey
    }

    private func makeRegistryHealthRow(
        title: String,
        health: ProfileRegistryHealth,
        action: Selector
    ) -> (stack: NSStackView, label: NSTextField, button: NSButton) {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12)
        let label = NSTextField(labelWithString: profileRegistryHealthText(health))
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = health.state == .corrupted ? .systemRed : .secondaryLabelColor
        label.setContentHuggingPriority(.required, for: .horizontal)
        let button = NSButton(
            title: L10n.text("settings.health.restore", fallback: "バックアップから復元"),
            target: self,
            action: action
        )
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.identifier = NSUserInterfaceItemIdentifier(health.backupAvailable ? "available" : "unavailable")
        button.isHidden = health.state == .healthy || !health.backupAvailable
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(NSView())
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(button)
        stack.widthAnchor.constraint(equalToConstant: 496).isActive = true
        return (stack, label, button)
    }

    private func profileRegistryHealthText(_ health: ProfileRegistryHealth) -> String {
        switch health.state {
        case .healthy:
            return L10n.text("settings.health.healthy", fallback: "正常")
        case .missing:
            return L10n.text("settings.health.missing", fallback: "未作成")
        case .corrupted:
            return health.backupAvailable
                ? L10n.text("settings.health.corrupted-backup", fallback: "読み込み失敗（復元可能）")
                : L10n.text("settings.health.corrupted", fallback: "読み込み失敗")
        }
    }

    private func settingsRegistryHealthText(_ health: SettingsRegistryHealth) -> String {
        switch health.state {
        case .healthy:
            return L10n.text("settings.health.healthy", fallback: "正常")
        case .missing:
            return L10n.text("settings.health.missing", fallback: "未作成")
        case .corrupted:
            return health.backupAvailable
                ? L10n.text("settings.health.corrupted-backup", fallback: "読み込み失敗（復元可能）")
                : L10n.text("settings.health.corrupted", fallback: "読み込み失敗")
        }
    }

    private func makeSettingsHealthRow(
        title: String,
        health: SettingsRegistryHealth,
        action: Selector
    ) -> (stack: NSStackView, label: NSTextField, button: NSButton) {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12)
        let label = NSTextField(labelWithString: settingsRegistryHealthText(health))
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = health.state == .corrupted ? .systemRed : .secondaryLabelColor
        label.setContentHuggingPriority(.required, for: .horizontal)
        let button = NSButton(
            title: L10n.text("settings.health.restore", fallback: "バックアップから復元"),
            target: self,
            action: action
        )
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.isHidden = health.state == .healthy || !health.backupAvailable
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(NSView())
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(button)
        stack.widthAnchor.constraint(equalToConstant: 496).isActive = true
        return (stack, label, button)
    }

    private func makeDependencyHealthRow(title: String, available: Bool) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let statusLabel = NSTextField(
            labelWithString: available
                ? L10n.text("settings.health.detected", fallback: "検出済み")
                : L10n.text("settings.health.not-detected", fallback: "未検出")
        )
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = available ? .systemGreen : .systemOrange
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(spacer)
        stack.addArrangedSubview(statusLabel)
        stack.widthAnchor.constraint(equalToConstant: 496).isActive = true
        return stack
    }

    @objc
    private func restoreProfileRegistryFromSettings(_ sender: NSButton) {
        do {
            _ = try launcher.restoreProfileRegistryFromBackup()
            refreshUI()
            closeSettings()
            showTransientStatus(L10n.text("settings.health.restored", fallback: "プロファイル管理情報を復元しました。"))
        } catch {
            presentError(error, title: L10n.text("settings.health.restore-failed", fallback: "プロファイル管理情報を復元できませんでした"))
        }
    }

    @objc
    private func restoreSettingsRegistryFromSettings(_ sender: NSButton) {
        do {
            _ = try launcher.restoreSettingsRegistryFromBackup()
            closeSettings()
            refreshUI()
            showTransientStatus(L10n.text("settings.health.restored-settings", fallback: "共有グループの管理情報を復元しました。"))
        } catch {
            presentError(error, title: L10n.text("settings.health.restore-failed-settings", fallback: "共有グループの管理情報を復元できませんでした"))
        }
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
        UserDefaults.standard.set(
            settingsUsageNotificationCheckbox?.state == .on,
            forKey: usageNotificationsEnabledKey
        )
        UserDefaults.standard.set(
            settingsUsageWarningCheckbox?.state == .on,
            forKey: usageWarningNotificationsEnabledKey
        )
        UserDefaults.standard.set(
            settingsUsageCriticalCheckbox?.state == .on,
            forKey: usageCriticalNotificationsEnabledKey
        )
        UserDefaults.standard.set(
            settingsCompactUsageCheckbox?.state == .on,
            forKey: compactUsageStatusEnabledKey
        )
        let wantsLoginItem = settingsLoginItemCheckbox?.state == .on
        let loginItemIsEnabled = SMAppService.mainApp.status == .enabled
        if wantsLoginItem != loginItemIsEnabled {
            do {
                if wantsLoginItem {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                presentWarning(
                    error.localizedDescription,
                    title: L10n.text(
                        "settings.menubar.login-item-error",
                        fallback: "ログイン時起動を変更できませんでした"
                    )
                )
            }
        }
        scheduleUsageResetNotifications(
            for: launcher.accounts.compactMap { account in
                guard let snapshot = usageByAccountID[account.id] else { return nil }
                return (account, snapshot)
            }
        )
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

        updateStatusItem()
        if statusPopover?.isShown == true {
            updateStatusPopover()
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

        // Do not move a live view hierarchy between NSWindow instances. The
        // old implementation transferred the replacement window's
        // contentView and then closed that window. AppKit can still have
        // deferred layout/accessibility work queued for the original window,
        // which leaves Objective-C objects released during the next
        // autorelease-pool drain (EXC_BAD_ACCESS after changing language).
        // Rebuild into a fresh window instead and let the old window drain
        // independently.
        guideWindow?.delegate = nil
        guideWindow?.performClose(nil)
        guideWindow = nil
        guidePages = []

        let frame = currentWindow.frame
        let wasVisible = currentWindow.isVisible
        currentWindow.delegate = nil
        currentWindow.close()
        window = nil
        configureMainMenu()
        configureWindow()
        guard let replacementWindow = window else {
            return
        }
        replacementWindow.setFrame(frame, display: false)

        refreshUI()
        refreshUsage()
        if wasVisible {
            showMainWindow()
        }
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
                        fallback: "ChatGPT Profile Managerは、ChatGPTプロファイルごとに使う保存先を分け、異なるプロファイルを同時に起動するためのアプリです。プロファイルやクラウド上のプロジェクトを移動・コピーするものではありません。\n\n"
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
                        fallback: "1　初回プロファイルを確認\n2　保存先を選択\n3　必要ならログイン\n4　一覧の「起動」からプロファイルごとに起動\n\n"
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
                        fallback: "既存環境がある場合、最初の起動時にメールアドレスを表示名として自動登録します。既存環境がない場合や2件目以降は、プロファイル追加から保存先を選びます。プロファイル間でプロジェクトやチャットをコピーすることはありません。"
                    ),
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
            },
            makeGuidePage(
                title: L10n.text("guide.register.title", fallback: "プロファイルを登録")
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
                        fallback: "ChatGPT Profile Managerを起動します。既存環境がある場合は、最初のプロファイルをメールアドレスの表示名で自動登録します。登録しただけではChatGPTは起動せず、一覧の「起動」を押したときだけ選択した環境を起動します。\n\n"
                    ),
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.register.add-heading",
                        fallback: "プロファイルを追加する\n"
                    ),
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.register.add-body",
                        fallback: "既存環境が自動登録されなかった場合や、別のプロファイルを追加する場合は、「プロファイルを追加」を押して一覧で表示する名前を入力します。メールアドレス以外の名前にも変更できます。プロファイルは任意の数を追加できます。名前は1文字以上60文字以内で、同じ名前は登録できません。"
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
                        fallback: "名前の入力後、「このプロファイルで使う保存先を選択」と表示されます。次の3つから、プロファイルで使う環境を選びます。\n\n"
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
                        fallback: "普段のChatGPTのプロジェクト、チャット、設定、ログイン状態をそのまま使います。割り当てられるのは1プロファイルだけです。\n\n"
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
                        fallback: "このプロファイル専用の保存先を新しく作ります。既存環境のデータはコピーされません。\n\n"
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
                        fallback: "一覧からプロファイルを選び、「起動」を押します。他のプロファイルを終了せず、別のChatGPTインスタンスとして起動します。データを保護するため、同じ保存先は複数起動できません。起動中の行では「起動」が「開く」に変わり、既存ウィンドウを前面に表示します。終了はプロファイルの「…」メニューから行います。"
                    ),
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
            },
            makeGuidePage(
                title: L10n.text("guide.organize.title", fallback: "プロファイルを整理する")
            ) { content in
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.organize.add-heading",
                        fallback: "別のプロファイルを追加する\n"
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
                        fallback: "名前の横にある鉛筆アイコンでは表示名だけを変更できます。行をドラッグすると表示順だけを変更できます。\n\n"
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
                        fallback: "分離プロファイルの「プロファイルを削除…」は登録情報だけを外し、保存フォルダやデータは残します。既存環境に割り当てたプロファイルは削除できません。"
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
                        fallback: "プロファイルの「…」メニューから「設定の共有…」を選ぶと、複数のプロファイルを1つの共有グループへ追加できます。作成元プロファイルは自動的に参加し、AGENTS.mdや選択した設定は共通ファイルを参照します。反映はChatGPTの次回起動からです。\n\n"
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
                        fallback: "コピー先プロファイルの「…」メニューから「別のプロファイルから設定をコピー…」を選びます。これは1回だけの複製で、コピー元を後から変更してもコピー先は変わりません。同名の設定はバックアップしてから置き換えます。\n\n"
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
                title: L10n.text("guide.launcher.title", fallback: "Dockから直接起動する")
            ) { content in
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.launcher.generate-heading",
                        fallback: "プロファイル起動用アプリを作成する\n"
                    ),
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.launcher.generate-body",
                        fallback: "分離プロファイルの「…」メニューから「Dock用起動アプリを作成…」を選ぶと、そのプロファイル専用の起動用アプリを作成します。作成後にFinderで表示し、Dockへドラッグして追加してください。ChatGPTの既存環境にはChatGPTアプリ自身のDock機能があるため、この項目は表示されません。\n\n"
                    ),
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.launcher.icon-heading",
                        fallback: "アイコンで見分ける\n"
                    ),
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.launcher.icon-body",
                        fallback: "プロファイル起動用アプリごとにプロファイル名、色・頭文字付きのアイコンを生成します。キャメルケース、空白、ハイフン、アンダースコアを単語の区切りとして認識するため、ShareFair、share-fair、share_fairはいずれもSFになります。単語が1つだけの場合は先頭2文字を使います。名前を変更した後は、分離プロファイルの「…」メニューから「Dock用起動アプリを再作成…」を選ぶと、名前、表示名、アイコンを更新できます。\n\n"
                    ),
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.launcher.behavior-heading",
                        fallback: "起動時の動作\n"
                    ),
                    font: sectionFont,
                    paragraphStyle: sectionParagraphStyle
                )
                appendGuideText(
                    content,
                    L10n.text(
                        "guide.launcher.behavior-body",
                        fallback: "プロファイル起動用アプリは分離プロファイルの保存先を指定してChatGPTを直接起動します。ChatGPTが標準の場所にない場合は、互換用にChatGPT Profile Managerへ処理を引き継ぎます。別プロファイルは並列起動できますが、同じ保存先は二重起動できません。ChatGPTの既存環境はプロファイル起動用アプリの対象外です。プロファイル起動用アプリはプロファイル名を使った名前で保存されます。\n\n"
                    ),
                    font: bodyFont,
                    paragraphStyle: bodyParagraphStyle
                )
                appendGuideCode(
                    content,
                    L10n.text(
                        "guide.launcher.location-tree",
                        fallback: "~/Library/Application Support/\n└── ChatGPT Profile Manager/\n    └── Launchers/\n        └── ChatGPT <プロファイル名>.app"
                    )
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
                        fallback: "ChatGPTの既存環境は、ChatGPTが普段使っている保存先です。分離プロファイルは、ChatGPT Profile Managerがプロファイルごとに用意する専用の保存先です。ログイン状態やアプリデータをプロファイルごとに分けます。\n\n"
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
                        fallback: "初回起動時に既存環境が見つかると、メールアドレスを表示名にして自動登録します。登録後も名前の横にある鉛筆アイコンから表示名だけ変更できます。\n\n"
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
                        fallback: "複数のプロファイルを使うときは、普段のChatGPTアイコンではなく、このアプリの「起動」から起動してください。異なるプロファイルは同時に起動できますが、同じプロファイルは二重起動できません。起動中のプロファイルは一覧に「起動中」と表示され、操作ボタンが「開く」に変わります。終了前には、プロファイルの「…」メニューからChatGPTを終了してください。\n\n"
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
            ? L10n.text("account.add.first-title", fallback: "最初のプロファイルを追加します")
            : L10n.text("account.add.title", fallback: "プロファイルを追加します")
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
                    fallback: "プロファイル名を使用できません"
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
            fallback: "このプロファイルでChatGPTが使う保存先を選びます。既存環境を使うと普段のプロジェクトやチャットをそのまま開きます。分離プロファイルを使うと、このプロファイル専用の保存先を使います。"
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
                    fallback: "このプロファイル専用の保存先を新しく作成する"
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
            fallback: "ChatGPTの既存環境をこのプロファイルに割り当てます。紐づけられるのは1プロファイルだけで、既存データのコピーや移動は行いません。確定後に追加するプロファイルは、すべて分離プロファイルになります。"
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
                    fallback: "プロファイルを追加できませんでした"
                )
            )
        }
    }

    @objc
    private func beginRenameAccount(_ sender: NSButton) {
        guard
            let rawID = sender.identifier?.rawValue,
            let accountID = UUID(uuidString: rawID),
            launcher.accounts.contains(where: { $0.id == accountID })
        else {
            presentError(ProfileManagerError.accountNotFound)
            return
        }

        editingAccountID = accountID
        editingNameField = nil
        tableView?.reloadData()

        DispatchQueue.main.async { [weak self] in
            guard
                let self,
                self.editingAccountID == accountID,
                let nameField = self.editingNameField
            else {
                return
            }
            self.window?.makeFirstResponder(nameField)
            nameField.selectText(nil)
        }
    }

    @objc
    private func saveInlineRename(_ sender: NSButton) {
        guard
            let rawID = sender.identifier?.rawValue,
            let accountID = UUID(uuidString: rawID),
            let nameField = editingNameField,
            nameField.identifier?.rawValue == rawID
        else {
            presentError(ProfileManagerError.accountNotFound)
            return
        }

        finishInlineRename(accountID: accountID, newName: nameField.stringValue)
    }

    @objc
    private func commitInlineRename(_ sender: NSTextField) {
        guard
            let rawID = sender.identifier?.rawValue,
            let accountID = UUID(uuidString: rawID)
        else {
            presentError(ProfileManagerError.accountNotFound)
            return
        }

        finishInlineRename(accountID: accountID, newName: sender.stringValue)
    }

    @objc
    private func cancelInlineRename(_ sender: NSButton) {
        guard
            let rawID = sender.identifier?.rawValue,
            UUID(uuidString: rawID) != nil
        else {
            presentError(ProfileManagerError.accountNotFound)
            return
        }

        editingAccountID = nil
        editingNameField = nil
        tableView?.reloadData()
    }

    private func finishInlineRename(accountID: UUID, newName: String) {
        guard launcher.accounts.contains(where: { $0.id == accountID }) else {
            editingAccountID = nil
            editingNameField = nil
            presentError(ProfileManagerError.accountNotFound)
            return
        }

        do {
            try launcher.renameAccount(id: accountID, to: newName)
            editingAccountID = nil
            editingNameField = nil
            refreshUI()
        } catch {
            // Keep the editor open so the user can correct an invalid or duplicate name.
            presentError(
                error,
                title: L10n.text(
                    "account.rename.error-title",
                    fallback: "プロファイル名を変更できませんでした"
                )
            )
        }
    }

    private func deleteAccountRegistration(accountID: UUID) {
        guard let account = launcher.accounts.first(where: { $0.id == accountID }) else {
            presentError(
                ProfileManagerError.accountNotFound,
                title: L10n.text(
                    "account.delete.error-title",
                    fallback: "プロファイル登録を削除できませんでした"
                )
            )
            return
        }

        guard account.id != launcher.existingEnvironmentAccount?.id else {
            presentError(
                ProfileManagerError.linkedAccountCannotBeDeleted,
                title: L10n.text(
                    "account.delete.error-title",
                    fallback: "プロファイル登録を削除できませんでした"
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
            fallback: "プロファイルの登録だけを削除します。分離プロファイルの保存フォルダ、ログイン状態、設定、セッション、ログなどはそのまま残り、後からプロファイル追加時に「既存の分離プロファイルを使う」を選ぶと、同じ保存先を再登録できます。既存環境は変更されません。"
        )
        alert.addButton(
            withTitle: L10n.text("account.delete.confirm", fallback: "プロファイルを削除")
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
                    fallback: "プロファイル登録を削除できませんでした"
                )
            )
        }
    }

    private func generateProfileLauncher(accountID: UUID) {
        guard let account = launcher.accounts.first(where: { $0.id == accountID }) else {
            presentError(ProfileManagerError.accountNotFound)
            return
        }

        do {
            let launcherURL = try launcher.generateProfileLauncher(for: accountID)
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = L10n.text(
                "launcher.generated-title",
                fallback: "プロファイル起動用アプリを作成しました"
            )
            alert.informativeText = L10n.text(
                "launcher.generated-message",
                fallback: "「{name}」専用のプロファイル起動用アプリを作成しました。Finderで表示し、Dockへドラッグすると、このプロファイルを直接起動できます。",
                replacing: ["name": account.name]
            )
            alert.addButton(
                withTitle: L10n.text(
                    "launcher.show-in-finder",
                    fallback: "Finderで表示"
                )
            )
            alert.addButton(withTitle: L10n.text("common.ok", fallback: "OK"))
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([launcherURL])
            }
            refreshUI()
        } catch {
            presentError(
                error,
                title: L10n.text(
                    "launcher.error.title",
                    fallback: "プロファイル起動用アプリを作成できませんでした"
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
            launcher.accounts.contains(where: { $0.id == accountID })
        else {
            return
        }

        if let account = launcher.accounts.first(where: { $0.id == accountID }) {
            openOrFocusAccount(account)
        }
    }

    private func launchAccountFromLauncher(_ accountID: UUID) {
        launchAccount(accountID)
    }

    private func launchAccount(_ accountID: UUID) {
        guard !isLaunching else {
            presentWarning(
                L10n.text(
                    "launcher.busy",
                    fallback: "別のプロファイルを起動中です。しばらく待ってから再試行してください。"
                ),
                title: L10n.text(
                    "launcher.busy-title",
                    fallback: "別のプロファイルを起動中です"
                )
            )
            return
        }
        guard let account = launcher.accounts.first(where: { $0.id == accountID }) else {
            presentError(
                ProfileManagerError.accountNotFound,
                title: L10n.text(
                    "launcher.error.title",
                    fallback: "プロファイル起動用アプリを実行できませんでした"
                )
            )
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

    private func showDiagnostics(accountID: UUID) {
        guard let account = launcher.accounts.first(where: { $0.id == accountID }),
              account.id != launcher.existingEnvironmentAccount?.id else { return }
        guard !diagnosticsExecutionState.blocksApplicationTermination else { return }
        diagnosticsAccountID = accountID
        if let diagnosticsWindow, diagnosticsWindow.isVisible {
            diagnosticsTitleLabel?.stringValue = account.name
            diagnosticsWindow.makeKeyAndOrderFront(nil)
            startDiagnostics(force: true)
            return
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 380), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.text("diagnostics.window-title", fallback: "プロファイルの診断")
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 540, height: 320)
        window.delegate = self
        let content = NSView()
        window.contentView = content
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])
        let title = NSTextField(labelWithString: account.name)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        stack.addArrangedSubview(title)
        diagnosticsTitleLabel = title
        let summary = NSTextField(wrappingLabelWithString: "")
        summary.font = .systemFont(ofSize: 13, weight: .medium)
        summary.maximumNumberOfLines = 2
        stack.addArrangedSubview(summary)
        diagnosticsSummaryLabel = summary
        let details = NSTextView()
        details.isEditable = false
        details.isSelectable = true
        details.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        details.backgroundColor = .textBackgroundColor
        details.textContainerInset = NSSize(width: 8, height: 8)
        let scroll = NSScrollView()
        scroll.documentView = details
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        diagnosticsDetailsView = details
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let diagnose = NSButton(title: L10n.text("diagnostics.run", fallback: "診断を実行"), target: self, action: #selector(runDiagnosticsAction))
        let relocate = NSButton(title: L10n.text("diagnostics.relocate", fallback: "保存先を再指定"), target: self, action: #selector(relocateProfileAction))
        let rebuild = NSButton(title: L10n.text("diagnostics.rebuild", fallback: "索引を再構築"), target: self, action: #selector(rebuildProfileIndexAction))
        let logs = NSButton(title: L10n.text("diagnostics.logs", fallback: "修復ログを表示"), target: self, action: #selector(showDiagnosticLogsAction))
        diagnose.bezelStyle = .rounded
        diagnose.keyEquivalent = "\r"
        buttons.addArrangedSubview(diagnose)
        let maintenance = NSButton(
            title: L10n.text("diagnostics.more", fallback: "メンテナンス"),
            target: self,
            action: #selector(showDiagnosticsMaintenanceMenu(_:))
        )
        maintenance.bezelStyle = .rounded
        buttons.addArrangedSubview(maintenance)
        diagnosticsRunButton = diagnose
        diagnosticsRelocateButton = relocate
        diagnosticsRebuildButton = rebuild
        diagnosticsLogsButton = logs
        diagnosticsMoreButton = maintenance
        stack.addArrangedSubview(buttons)
        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.isIndeterminate = true
        progress.isDisplayedWhenStopped = false
        progress.translatesAutoresizingMaskIntoConstraints = false
        stack.insertArrangedSubview(progress, at: 2)
        diagnosticsProgressIndicator = progress
        diagnosticsWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        startDiagnostics()
    }

    @objc private func showDiagnosticsMaintenanceMenu(_ sender: NSButton) {
        guard !isDiagnosticsRunning else { return }
        let menu = NSMenu()
        let relocate = NSMenuItem(
            title: L10n.text("diagnostics.relocate", fallback: "保存先を再指定…"),
            action: #selector(relocateProfileAction),
            keyEquivalent: ""
        )
        relocate.target = self
        relocate.isEnabled = diagnosticsRelocateButton?.isEnabled ?? false
        menu.addItem(relocate)

        let rebuild = NSMenuItem(
            title: L10n.text("diagnostics.rebuild", fallback: "索引を再構築…"),
            action: #selector(rebuildProfileIndexAction),
            keyEquivalent: ""
        )
        rebuild.target = self
        rebuild.isEnabled = diagnosticsRebuildButton?.isEnabled ?? false
        menu.addItem(rebuild)

        menu.addItem(.separator())
        let logs = NSMenuItem(
            title: L10n.text("diagnostics.logs", fallback: "修復ログを表示…"),
            action: #selector(showDiagnosticLogsAction),
            keyEquivalent: ""
        )
        logs.target = self
        logs.isEnabled = diagnosticsLogsButton?.isEnabled ?? false
        menu.addItem(logs)
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: sender.bounds.minX, y: sender.bounds.maxY + 4),
            in: sender
        )
    }

    @objc private func runDiagnosticsAction() { startDiagnostics() }

    private func startDiagnostics(force: Bool = false) {
        guard (force || !isDiagnosticsRunning),
              !diagnosticsExecutionState.blocksApplicationTermination,
              let accountID = diagnosticsAccountID,
              let account = launcher.accounts.first(where: { $0.id == accountID }),
              let baseDirectory = try? launcher.profileBaseDirectory()
        else { return }

        if isDiagnosticsRunning {
            diagnosticsTask?.cancel()
            diagnosticsTask = nil
            diagnosticsExecutionState = .idle
        }
        diagnosticsExecutionState = .diagnosing
        diagnosticsSummaryLabel?.stringValue = L10n.text(
            "diagnostics.running",
            fallback: "診断を実行中…"
        )
        diagnosticsDetailsView?.string = ""
        let task = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { @Sendable in
                let service = ProfileDiagnosticsService(
                    baseDirectory: baseDirectory,
                    fileManager: FileManager.default
                )
                return service.diagnose(profile: account)
            }.value

            guard !Task.isCancelled, let self,
                  self.diagnosticsAccountID == accountID,
                  self.diagnosticsWindow != nil
            else { return }
            self.diagnosticsExecutionState = .idle
            self.applyDiagnosticsReport(outcome)
            self.diagnosticsTask = nil
        }
        diagnosticsTask = task
    }

    private func applyDiagnosticsReport(_ report: ProfileDiagnosticReport) {
        let status: String
        switch report.status {
        case .healthy: status = L10n.text("diagnostics.status.healthy", fallback: "正常")
        case .needsAttention: status = L10n.text("diagnostics.status.attention", fallback: "要確認")
        case .missing: status = L10n.text("diagnostics.status.missing", fallback: "保存先不明")
        case .unknown: status = L10n.text("diagnostics.status.unknown", fallback: "不明")
        }
        diagnosticsSummaryLabel?.stringValue = L10n.text(
            "diagnostics.summary",
            fallback: "状態: {status} · 検出件数: {count}",
            replacing: ["status": status, "count": "\(report.findings.count)"]
        )
        let checklist = diagnosticsChecklist(report)
        let findings = report.findings.isEmpty
            ? L10n.text("diagnostics.no-findings", fallback: "問題は検出されませんでした。")
            : report.findings.map { finding in
                let location = finding.path.map { "\n  \($0)" } ?? ""
                return "[\(finding.severity.rawValue.uppercased())] \(finding.code): \(finding.message)\(location)"
            }.joined(separator: "\n\n")
        diagnosticsDetailsView?.string = checklist + "\n\n" + findings
        diagnosticsRebuildButton?.isEnabled = report.sqlite.contains(where: {
            $0.knownSchema && URL(fileURLWithPath: $0.path).lastPathComponent.hasPrefix("state_")
        }) && report.status != .missing
    }

    private func diagnosticsChecklist(_ report: ProfileDiagnosticReport) -> String {
        var lines: [String] = []
        func add(_ key: String, checks: [String]) {
            let present = checks.filter { report.checks[$0] != nil }
            guard !present.isEmpty else { return }
            let passed = present.allSatisfy { report.checks[$0] == true }
            let fallback: String
            switch key {
            case "diagnostics.check.storage": fallback = "プロファイル保存先"
            case "diagnostics.check.codex-home": fallback = "CODEX_HOME"
            case "diagnostics.check.permissions": fallback = "ファイル権限"
            case "diagnostics.check.settings": fallback = "設定ファイル"
            default: fallback = key
            }
            let label = L10n.text(key, fallback: fallback)
            lines.append(
                L10n.text(
                    passed ? "diagnostics.check.passed" : "diagnostics.check.failed",
                    fallback: passed ? "✓ {name}" : "! {name}",
                    replacing: ["name": label]
                )
            )
        }
        add("diagnostics.check.storage", checks: ["rootExists", "rootIsDirectory"])
        add("diagnostics.check.codex-home", checks: ["codexHomeExists", "electronUserDataExists"])
        add("diagnostics.check.permissions", checks: ["rootReadable", "rootWritable"])
        add("diagnostics.check.settings", checks: ["settingsRegistryReadable"])
        if !report.sqlite.isEmpty {
            let passed = report.sqlite.allSatisfy { $0.knownSchema && $0.quickCheckPassed && $0.foreignKeyCheckPassed }
            lines.append(
                L10n.text(
                    passed ? "diagnostics.check.passed" : "diagnostics.check.failed",
                    fallback: passed ? "✓ {name}" : "! {name}",
                    replacing: [
                        "name": L10n.text("diagnostics.check.index", fallback: "SQLite索引")
                    ]
                )
            )
        }
        return lines.joined(separator: "\n")
    }

    private func updateDiagnosticsControls() {
        let enabled = !isDiagnosticsRunning
        diagnosticsRunButton?.isEnabled = enabled
        diagnosticsRelocateButton?.isEnabled = enabled
        diagnosticsRebuildButton?.isEnabled = enabled && diagnosticsRebuildButton?.isEnabled == true
        diagnosticsLogsButton?.isEnabled = enabled
        diagnosticsMoreButton?.isEnabled = enabled
        if isDiagnosticsRunning {
            diagnosticsProgressIndicator?.startAnimation(nil)
        } else {
            diagnosticsProgressIndicator?.stopAnimation(nil)
        }
    }

    @objc private func relocateProfileAction() {
        guard !isDiagnosticsRunning, let accountID = diagnosticsAccountID else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.text("diagnostics.relocate", fallback: "保存先を再指定")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            _ = try launcher.updateProfileLocation(id: accountID, root: url, bookmarkData: bookmark)
            refreshUI()
            startDiagnostics()
            showTransientStatus(L10n.text("diagnostics.relocated", fallback: "保存先を更新しました。"))
        } catch {
            presentError(error, title: L10n.text("diagnostics.error-title", fallback: "保存先を更新できませんでした"))
        }
    }

    @objc private func rebuildProfileIndexAction() {
        guard !isDiagnosticsRunning, let accountID = diagnosticsAccountID else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.text("diagnostics.rebuild-confirm-title", fallback: "SQLiteの参照パスを修復しますか？")
        alert.informativeText = L10n.text("diagnostics.rebuild-confirm-message", fallback: "ChatGPTを終了している必要があります。変更前のSQLiteはスナップショットへ保存されます。一意に対応づけられる移動済みJSONLの参照だけを更新し、欠落行や派生索引は再生成しません。")
        alert.addButton(withTitle: L10n.text("diagnostics.rebuild", fallback: "索引を再構築"))
        alert.addButton(withTitle: L10n.text("common.cancel", fallback: "キャンセル"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard diagnosticsAccountID == accountID,
              let account = launcher.accounts.first(where: { $0.id == accountID }),
              let baseDirectory = try? launcher.profileBaseDirectory()
        else { return }
        let runningAtStart = launcher.isAccountRunning(id: accountID)
        guard !runningAtStart else {
            presentError(
                ProfileManagerError.codexMustBeClosed,
                title: L10n.text("diagnostics.error-title", fallback: "索引を再構築できませんでした")
            )
            return
        }

        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        diagnosticsExecutionState = .repairing
        diagnosticsSummaryLabel?.stringValue = L10n.text(
            "diagnostics.repair-running",
            fallback: "索引の保守的な修復を実行中…"
        )
        diagnosticsDetailsView?.string = ""
        let task = Task { @MainActor [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { @Sendable in
                let service = ProfileDiagnosticsService(
                    baseDirectory: baseDirectory,
                    fileManager: FileManager.default,
                    isChatGPTRunning: { runningAtStart }
                )
                do {
                    return DiagnosticsRepairOutcome.success(try service.repairIndex(profile: account))
                } catch {
                    return DiagnosticsRepairOutcome.failure(error.localizedDescription)
                }
            }.value

            guard let self else { return }
            let shouldReflect = !Task.isCancelled
                && self.diagnosticsAccountID == accountID
                && self.diagnosticsWindow != nil
            self.diagnosticsExecutionState = .idle
            self.diagnosticsTask = nil
            guard shouldReflect else { return }
            switch outcome {
            case let .success(result):
                self.diagnosticsSummaryLabel?.stringValue = L10n.text(
                    "diagnostics.repaired",
                    fallback: "移動済みJSONLの参照パスを修復しました（{count}件）。",
                    replacing: ["count": "\(result.updatedPathCount)"]
                )
                self.diagnosticsDetailsView?.string = [
                    "updated=\(result.updatedPathCount)",
                    "skipped=\(result.skippedAmbiguousCount)",
                    "snapshot=\(result.snapshotDirectory.path)",
                    "log=\(result.logURL.path)"
                ].joined(separator: "\n")
                self.showTransientStatus(L10n.text(
                    "diagnostics.repaired",
                    fallback: "移動済みJSONLの参照パスを修復しました（{count}件）。",
                    replacing: ["count": "\(result.updatedPathCount)"]
                ))
            case let .failure(message):
                self.diagnosticsSummaryLabel?.stringValue = message
                self.diagnosticsDetailsView?.string = L10n.text(
                    "diagnostics.repair-failed",
                    fallback: "修復に失敗しました。詳細は修復ログを確認してください。"
                )
                self.presentError(
                    DiagnosticsTaskError(message: message),
                    title: L10n.text("diagnostics.error-title", fallback: "索引を再構築できませんでした")
                )
            }
        }
        diagnosticsTask = task
    }

    @objc private func showDiagnosticLogsAction() {
        guard !isDiagnosticsRunning, let accountID = diagnosticsAccountID else { return }
        do {
            let account = try launcher.accountForDiagnostics(id: accountID)
            let base = try launcher.profileBaseDirectory()
            let service = ProfileDiagnosticsService(baseDirectory: base)
            let logs = service.logURLs().compactMap { service.readLog(at: $0) }.filter { $0.profileID == account.profileID }
            diagnosticsDetailsView?.string = logs.isEmpty
                ? L10n.text("diagnostics.logs-empty", fallback: "修復ログはありません。")
                : logs.map { "\($0.finishedAt): \($0.result) / updated=\($0.updatedPathCount), rollback=\($0.result == "rollback")" }.joined(separator: "\n")
        } catch {
            diagnosticsDetailsView?.string = error.localizedDescription
        }
    }

    @objc
    private func quitAccount(_ sender: NSButton) {
        guard
            let accountID = accountID(from: sender)
        else {
            refreshUI()
            return
        }
        quitAccount(accountID: accountID)
    }

    @objc
    private func quitAccountFromMenu(_ sender: NSMenuItem) {
        guard let accountID = accountID(from: sender) else {
            presentError(ProfileManagerError.accountNotFound)
            return
        }
        quitAccount(accountID: accountID)
    }

    private func quitAccount(accountID: UUID) {
        guard
            !isLaunching,
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
        presentWarning(
            error.localizedDescription,
            title: title ?? L10n.text(
                "account.open.error-title",
                fallback: "プロファイルを起動できませんでした"
            )
        )
    }

    private func presentWarning(_ message: String, title: String) {
        showMainWindow()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L10n.text("common.ok", fallback: "OK"))
        alert.runModal()
    }
}

extension AppDelegate {
    func application(_ application: NSApplication, open urls: [URL]) -> Bool {
        let accountIDs = urls.compactMap(ProfileLauncherURL.accountID(from:))
        guard !accountIDs.isEmpty else {
            return false
        }

        // Older generated launchers forward a custom URL to the manager. Keep
        // that compatibility path, but do not leave the manager window in
        // front when the user's intent was to launch ChatGPT.
        window?.orderOut(nil)
        for accountID in accountIDs {
            launchAccountFromLauncher(accountID)
        }
        return true
    }
}
