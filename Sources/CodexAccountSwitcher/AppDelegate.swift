import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let launcher = CodexLauncher()
    private let accountPasteboardType = NSPasteboard.PasteboardType(
        "com.local.codex-account-switcher.account"
    )
    private var window: NSWindow?
    private var guideWindow: NSWindow?
    private var assignmentLabel: NSTextField?
    private var statusLabel: NSTextField?
    private var tableView: NSTableView?
    private var addButton: NSButton?
    private var recoveryButton: NSButton?
    private var revealButton: NSButton?
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
        showMainWindow()

        if launcher.accounts.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.presentAddAccount()
            }
        }
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
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 570),
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
        mainStack.spacing = 14
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            mainStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            mainStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            mainStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -22)
        ])

        let titleLabel = NSTextField(labelWithString: "ChatGPT Profile Manager")
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        mainStack.addArrangedSubview(titleLabel)

        let descriptionLabel = NSTextField(
            wrappingLabelWithString: "使用するChatGPTアカウントを選ぶと、実行中のChatGPTデスクトップアプリ（Codex）を通常終了し、対応するプロファイルで再起動します。"
        )
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.maximumNumberOfLines = 0
        mainStack.addArrangedSubview(descriptionLabel)

        let assignmentLabel = NSTextField(wrappingLabelWithString: "")
        assignmentLabel.font = .systemFont(ofSize: 14, weight: .medium)
        assignmentLabel.maximumNumberOfLines = 0
        mainStack.addArrangedSubview(assignmentLabel)
        self.assignmentLabel = assignmentLabel

        let accountHeader = NSStackView()
        accountHeader.orientation = .horizontal
        accountHeader.alignment = .centerY
        accountHeader.translatesAutoresizingMaskIntoConstraints = false

        let accountHeaderLabel = NSTextField(labelWithString: "登録済みアカウント")
        accountHeaderLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        accountHeader.addArrangedSubview(accountHeaderLabel)

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        accountHeader.addArrangedSubview(headerSpacer)

        let addButton = NSButton(
            title: "アカウントを追加…",
            target: self,
            action: #selector(addAccount)
        )
        addButton.bezelStyle = .rounded
        addButton.keyEquivalent = "+"
        accountHeader.addArrangedSubview(addButton)
        mainStack.addArrangedSubview(accountHeader)
        accountHeader.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        self.addButton = addButton

        let tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowHeight = 62
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = .solidHorizontalGridLineMask
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
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        mainStack.addArrangedSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalTo: mainStack.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 190)
        ])
        self.tableView = tableView

        let statusLabel = NSTextField(wrappingLabelWithString: "")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 0
        mainStack.addArrangedSubview(statusLabel)
        self.statusLabel = statusLabel

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        mainStack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true

        let utilityButtons = NSStackView()
        utilityButtons.orientation = .horizontal
        utilityButtons.spacing = 10
        utilityButtons.translatesAutoresizingMaskIntoConstraints = false

        let recoveryButton = NSButton(
            title: "既存環境の紐づけを誤った場合…",
            target: self,
            action: #selector(recoverFromIncorrectAssignment)
        )
        recoveryButton.bezelStyle = .rounded

        let revealButton = NSButton(
            title: "プロファイル保存先を開く",
            target: self,
            action: #selector(revealProfiles)
        )
        revealButton.bezelStyle = .rounded

        let guideButton = NSButton(
            title: "このアプリの仕組み",
            target: self,
            action: #selector(showMechanismGuide)
        )
        guideButton.bezelStyle = .rounded

        utilityButtons.addArrangedSubview(recoveryButton)
        utilityButtons.addArrangedSubview(revealButton)
        utilityButtons.addArrangedSubview(guideButton)
        mainStack.addArrangedSubview(utilityButtons)

        self.recoveryButton = recoveryButton
        self.revealButton = revealButton

        let footerLabel = NSTextField(
            wrappingLabelWithString: "既存のCodex環境はコピーせず、紐づけた1アカウントだけがそのまま使用します。それ以外はアカウントごとに分離されます。"
        )
        footerLabel.font = .systemFont(ofSize: 11)
        footerLabel.textColor = .tertiaryLabelColor
        footerLabel.maximumNumberOfLines = 0
        mainStack.addArrangedSubview(footerLabel)

        self.window = window
    }

    private func showMainWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refreshUI() {
        let accounts = launcher.accounts
        if let assignedAccount = launcher.existingEnvironmentAccount {
            assignmentLabel?.stringValue = "既存のCodex環境：\(assignedAccount.name) に固定済み"
        } else {
            assignmentLabel?.stringValue = "既存のCodex環境は未割り当てです。アカウントを追加するたびに、紐づけるか確認します。"
        }

        if let lastAccount = launcher.lastLaunchedAccount {
            let environment = lastAccount.id == launcher.existingEnvironmentAccount?.id
                ? "既存環境"
                : "分離プロファイル"
            statusLabel?.stringValue = "最後に起動：\(lastAccount.name)（\(environment)）"
        } else if accounts.isEmpty {
            statusLabel?.stringValue = "最初のアカウントを追加してください。"
        } else {
            statusLabel?.stringValue = "まだChatGPT Profile Managerからアカウントを起動していません。"
        }

        tableView?.reloadData()
        updateControlAvailability()
    }

    private func updateControlAvailability() {
        addButton?.isEnabled = !isSwitching
        tableView?.isEnabled = !isSwitching
        recoveryButton?.isEnabled = !isSwitching
        recoveryButton?.isHidden = launcher.existingEnvironmentAccount == nil
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
        let rowStack = NSStackView()
        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = 10
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(rowStack)

        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            rowStack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
            rowStack.topAnchor.constraint(equalTo: cell.topAnchor, constant: 7),
            rowStack.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -7)
        ])

        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2

        let dragHandle = NSImageView(
            image: NSImage(
                systemSymbolName: "line.3.horizontal",
                accessibilityDescription: "ドラッグして並び替え"
            ) ?? NSImage()
        )
        dragHandle.contentTintColor = .tertiaryLabelColor
        dragHandle.toolTip = "ドラッグして並び替え"
        dragHandle.setAccessibilityLabel("\(account.name)をドラッグして並び替え")
        rowStack.addArrangedSubview(dragHandle)

        let nameLabel = NSTextField(labelWithString: account.name)
        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        labels.addArrangedSubview(nameLabel)

        let isExisting = account.id == launcher.existingEnvironmentAccount?.id
        var details = isExisting ? "既存のCodex環境" : "分離プロファイル"
        if account.id == launcher.lastLaunchedAccount?.id {
            details += "・前回使用"
        }
        let detailLabel = NSTextField(labelWithString: details)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        labels.addArrangedSubview(detailLabel)
        rowStack.addArrangedSubview(labels)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rowStack.addArrangedSubview(spacer)

        let renameButton = NSButton(
            title: "名前を変更…",
            target: self,
            action: #selector(renameAccount(_:))
        )
        renameButton.bezelStyle = .rounded
        renameButton.identifier = NSUserInterfaceItemIdentifier(account.id.uuidString)
        rowStack.addArrangedSubview(renameButton)

        let openButton = NSButton(
            title: "開く",
            target: self,
            action: #selector(switchAccount(_:))
        )
        openButton.bezelStyle = .rounded
        openButton.identifier = NSUserInterfaceItemIdentifier(account.id.uuidString)
        rowStack.addArrangedSubview(openButton)

        let deleteButton = NSButton(
            title: "削除…",
            target: self,
            action: #selector(deleteAccount(_:))
        )
        deleteButton.bezelStyle = .rounded
        deleteButton.identifier = NSUserInterfaceItemIdentifier(account.id.uuidString)
        deleteButton.hasDestructiveAction = true
        deleteButton.isEnabled = !isExisting && !isSwitching
        deleteButton.toolTip = isExisting
            ? "既存環境に紐づいたアカウントは削除できません"
            : "分離プロファイルをゴミ箱へ移動して削除"
        rowStack.addArrangedSubview(deleteButton)

        return cell
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
            statusLabel?.stringValue = "\(account.name) の並び順を変更しました。"
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

    @objc
    private func showMechanismGuide() {
        if let guideWindow, guideWindow.isVisible {
            guideWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let guideWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 650, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        guideWindow.title = "このアプリの仕組み"
        guideWindow.tabbingMode = .disallowed
        guideWindow.minSize = NSSize(width: 560, height: 480)
        guideWindow.isReleasedWhenClosed = false
        guideWindow.center()

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let guideTextView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: 580, height: 1_300)
        )
        let bodyFont = NSFont.systemFont(ofSize: 14)
        let titleFont = NSFont.systemFont(ofSize: 24, weight: .bold)
        let sectionFont = NSFont.systemFont(ofSize: 16, weight: .semibold)
        let noteFont = NSFont.systemFont(ofSize: 15, weight: .semibold)

        let bodyParagraphStyle = NSMutableParagraphStyle()
        bodyParagraphStyle.lineSpacing = 4
        bodyParagraphStyle.paragraphSpacing = 4

        let titleParagraphStyle = NSMutableParagraphStyle()
        titleParagraphStyle.paragraphSpacing = 8

        let sectionParagraphStyle = NSMutableParagraphStyle()
        sectionParagraphStyle.paragraphSpacingBefore = 4
        sectionParagraphStyle.paragraphSpacing = 1

        let noteParagraphStyle = NSMutableParagraphStyle()
        noteParagraphStyle.lineSpacing = 3
        noteParagraphStyle.paragraphSpacing = 4

        let guideContent = NSMutableAttributedString()
        func appendGuideText(
            _ text: String,
            font: NSFont,
            color: NSColor = .labelColor,
            paragraphStyle: NSParagraphStyle
        ) {
            guideContent.append(
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

        appendGuideText(
            "このアプリの仕組み\n",
            font: titleFont,
            paragraphStyle: titleParagraphStyle
        )
        appendGuideText(
            "ChatGPT Profile Managerは、ChatGPTデスクトップアプリのアカウント自体を変更するアプリではありません。アカウントごとに用意した保存先を指定して、Codexビューを一度終了・再起動するランチャーです。アカウントの認証やプロジェクトの同期はChatGPT／Codex側が行い、このアプリは起動先と登録情報を管理します。\n\n",
            font: bodyFont,
            color: .secondaryLabelColor,
            paragraphStyle: bodyParagraphStyle
        )

        let guideSections = [
            (
                "1. このアプリが管理する情報",
                "一覧に保存されるのは、表示名、内部ID、プロファイル用ディレクトリ名、既存環境への割り当て、最後に起動したアカウントです。表示名はメールアドレスでなくてもよく、名前を変更しても保存データは変わりません。認証情報やプロジェクトの内容そのものは、この一覧ではなく、既存環境または各アカウントのプロファイル保存先に保持されます。"
            ),
            (
                "2. アカウントの登録",
                "「アカウントを追加…」で任意の表示名を入力します。名前は1文字以上60文字以内で、同じ名前は登録できません。登録数に固定の上限はありません。登録しただけではCodexは起動せず、一覧の「開く」を押した時にだけ対象アカウントの環境を起動します。"
            ),
            (
                "3. 初回登録時の選択",
                "最初のアカウントを追加するとき、または既存環境がまだ未割り当ての間に追加するときは、現在のCodex環境に紐づけるか確認します。「既存環境と紐づける」を選ぶと、そのアカウントを1つだけ既存環境へ固定します。「新規の分離プロファイルにする」を選ぶと、既存環境は未割り当てのままです。この場合、次のアカウント追加時にも同じ確認を行います。"
            ),
            (
                "4. 既存環境に紐づけた場合",
                "紐づけられるのは1アカウントだけです。紐づけたアカウントは、現在Macで通常使用しているCodexの既定の保存先をそのまま使います。既存のプロジェクト、チャット、設定、ログイン状態をコピー・移動・変換しません。紐づけが確定した後に追加するアカウントは、すべて新規の分離プロファイルになります。"
            ),
            (
                "5. 分離プロファイルの保存先",
                "既存環境に紐づけなかったアカウントには、アカウントごとに専用の保存先を作ります。場所は「~/Library/Application Support/ChatGPT Profile Manager/Profiles/」の下で、各アカウントに固有のディレクトリが割り当てられます。その中を「CodexHome」と「ElectronUserData」に分け、Codex側の設定・認証・セッション・ログ・スキルと、ChatGPTデスクトップアプリ側のCookie・ログイン状態・アプリデータを分離します。保存先はメイン画面の「プロファイル保存先を開く」から確認できます。以前の「Codex Account Switcher」フォルダが残っている場合は、初回利用時に新しい名前へ移行します。"
            ),
            (
                "6. 分離プロファイルを初めて使うとき",
                "分離プロファイルを初めて「開く」と、必要なディレクトリを作成してからCodexを起動します。既存環境のデータはコピーされないため、その保存先ではChatGPTアカウントへのログインが必要です。一度ログインした後の認証状態や作成したプロジェクト・チャットは、その分離プロファイル内に保存され、他のアカウントのプロファイルからは自動的に見えません。"
            ),
            (
                "7. アカウントを切り替える流れ",
                "一覧の「開く」を押すと、①実行中のCodexを探す、②実行中なら通常終了を依頼する、③終了を確認する、④選択したアカウントの保存先を指定してCodexを起動する、⑤最後に起動したアカウントを記録する、という順で処理します。Codexが10秒以内に終了しない場合は強制終了せず、エラーを表示して切り替えを止めます。切り替え前に実行中のローカルタスクを確認してください。"
            ),
            (
                "8. 切り替えで引き継がれるもの・引き継がれないもの",
                "引き継がれるのは、ChatGPT Profile Managerに登録した表示名・並び順・紐づけ状態などの管理情報だけです。アカウント間でログインCookie、Codexの設定、セッション、ログ、プロジェクト、チャットをコピーしたり、クラウド上の履歴を統合したりはしません。ChatGPT側で見えるデータは、起動したプロファイルでログインしているアカウントの権限に従います。"
            ),
            (
                "9. 名前変更と並び替え",
                "「名前を変更…」は一覧の表示名だけを変更します。行をドラッグ＆ドロップすると表示順だけを変更します。どちらの操作でも、ログイン状態、プロジェクト、チャット、保存先、既存環境との紐づけ先は変わりません。"
            ),
            (
                "10. 分離プロファイルの削除",
                "分離プロファイルの「削除…」は、Codexが終了している場合にだけ実行できます。確認後、そのアカウントの保存フォルダをmacOSのゴミ箱へ移動し、一覧の登録も削除します。既存環境に紐づいたアカウントは、既存データを保護するため削除できません。フォルダはゴミ箱から戻せますが、登録情報は別に削除されるため、アプリ一覧へ自動的に復帰するわけではありません。"
            ),
            (
                "11. 紐づけを間違えた場合の復旧",
                "メイン画面の「既存環境の紐づけを誤った場合…」から、ChatGPT Profile Manager上の紐づけ登録だけを外せます。Codexが起動中の場合は実行できません。既存環境のプロジェクト、チャット、設定、ログイン情報や、他の分離プロファイルは削除・変更しません。解除後に次のアカウントを追加すると、既存環境へ紐づけるか再び確認します。"
            ),
            (
                "12. アプリ本体とデータの場所",
                "ChatGPT Profile Managerのアプリ本体と、アカウント一覧・プロファイルの保存先は別です。アプリ本体を移動・更新・削除しても、プロファイル保存先のデータは自動削除されません。以前の「Codex Account Switcher」フォルダがある場合は、プロファイルを失わないように新しい保存先へ移行します。新旧両方のフォルダがある場合は、同名データを上書きせず、不足しているデータだけを統合します。不要になった分離プロファイルは、アプリの「削除…」からゴミ箱へ移動してください。"
            )
        ]

        for (heading, body) in guideSections {
            appendGuideText(
                "\(heading)\n",
                font: sectionFont,
                paragraphStyle: sectionParagraphStyle
            )
            appendGuideText(
                "\(body)\n\n",
                font: bodyFont,
                paragraphStyle: bodyParagraphStyle
            )
        }

        appendGuideText(
            "注意\n",
            font: noteFont,
            color: .systemOrange,
            paragraphStyle: sectionParagraphStyle
        )
        appendGuideText(
            "このアプリはOpenAI公式機能ではありません。アカウントの利用上限を回避する目的では使用せず、普段のChatGPT／Codexアイコンから直接起動すると既定の環境が開く場合があるため、切り替え時はこのアプリの「開く」を使ってください。切り替え前には、実行中のローカルタスクがないことを確認してください。",
            font: bodyFont,
            color: .secondaryLabelColor,
            paragraphStyle: noteParagraphStyle
        )

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
            width: 580,
            height: CGFloat.greatestFiniteMagnitude
        )
        guideTextView.textContainer?.widthTracksTextView = true
        guideTextView.textStorage?.setAttributedString(guideContent)
        scrollView.documentView = guideTextView

        guideWindow.contentView = NSView()
        guard let contentView = guideWindow.contentView else { return }
        contentView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18)
        ])

        self.guideWindow = guideWindow
        guideWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

        if launcher.existingEnvironmentAccount == nil {
            presentExistingEnvironmentChoice(for: name)
        } else {
            confirmIsolatedAccountCreation(named: name)
        }
    }

    private func presentExistingEnvironmentChoice(for name: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "「\(name)」を既存環境と紐づけますか？"
        alert.informativeText = "このMacで現在使用しているCodexのプロジェクト、チャット、設定をそのまま使う場合は紐づけてください。紐づけない場合は、新しい分離プロファイルを作成します。"
        alert.addButton(withTitle: "既存環境と紐づける")
        alert.addButton(withTitle: "新規の分離プロファイルにする")
        alert.addButton(withTitle: "キャンセル")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            confirmExistingEnvironmentAssignment(named: name)
        case .alertSecondButtonReturn:
            createAccount(named: name, linkToExistingEnvironment: false)
        default:
            break
        }
    }

    private func confirmExistingEnvironmentAssignment(named name: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "既存環境を「\(name)」へ固定しますか？"
        alert.informativeText = "紐づけられるのは1アカウントだけです。確定後に追加するアカウントは、すべて新規の分離プロファイルになります。誤設定時は専用の復旧画面を使用してください。"
        alert.addButton(withTitle: "紐づけを固定")
        alert.addButton(withTitle: "戻る")

        guard alert.runModal() == .alertFirstButtonReturn else {
            DispatchQueue.main.async { [weak self] in
                self?.presentExistingEnvironmentChoice(for: name)
            }
            return
        }

        createAccount(named: name, linkToExistingEnvironment: true)
    }

    private func confirmIsolatedAccountCreation(named name: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "「\(name)」を追加します"
        alert.informativeText = "既存のCodex環境はすでに「\(launcher.existingEnvironmentAccount?.name ?? "別のアカウント")」へ固定されています。このアカウントには、新しい分離プロファイルを使用します。"
        alert.addButton(withTitle: "分離プロファイルで追加")
        alert.addButton(withTitle: "キャンセル")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        createAccount(named: name, linkToExistingEnvironment: false)
    }

    private func createAccount(named name: String, linkToExistingEnvironment: Bool) {
        do {
            let account = try launcher.addAccount(
                named: name,
                linkToExistingEnvironment: linkToExistingEnvironment
            )
            refreshUI()
            statusLabel?.stringValue = linkToExistingEnvironment
                ? "\(account.name) を既存のCodex環境へ固定しました。"
                : "\(account.name) を分離プロファイルとして追加しました。"
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
            presentError(SwitcherError.accountNotFound)
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
            presentError(SwitcherError.accountNotFound, title: "プロファイルを削除できませんでした")
            return
        }

        guard account.id != launcher.existingEnvironmentAccount?.id else {
            presentError(
                SwitcherError.linkedAccountCannotBeDeleted,
                title: "プロファイルを削除できませんでした"
            )
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "「\(account.name)」を削除しますか？"
        alert.informativeText = "このアカウントの分離プロファイルに保存されたログイン状態、設定、セッション、ログなどとアカウント登録をゴミ箱へ移動します。ゴミ箱から復元できます。既存環境は変更されません。"
        alert.addButton(withTitle: "ゴミ箱へ移動")
        alert.addButton(withTitle: "キャンセル")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        do {
            let deletedAccount = try launcher.deleteIsolatedAccount(id: account.id)
            refreshUI()
            statusLabel?.stringValue = "\(deletedAccount.name) の分離プロファイルをゴミ箱へ移動しました。"
        } catch {
            presentError(error, title: "プロファイルを削除できませんでした")
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
        statusLabel?.stringValue = "\(account.name) へ切り替え中…"

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

    @objc
    private func recoverFromIncorrectAssignment() {
        showMainWindow()

        guard let assignedAccount = launcher.existingEnvironmentAccount else {
            presentAddAccount()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = launcher.hasUsedSwitcherSinceSetup ? .critical : .warning
        alert.messageText = "「\(assignedAccount.name)」の紐づけ登録を外しますか？"
        alert.informativeText = launcher.hasUsedSwitcherSinceSetup
            ? "すでにChatGPT Profile Managerからアカウントを起動しています。登録を外しても、既存環境のプロジェクト、チャット、設定、ログイン情報は削除されません。分離プロファイルもそのまま残ります。\n\n次にアカウントを追加すると、既存環境へ紐づけるか再び確認します。安全のため、Codexを終了してから実行してください。"
            : "ChatGPT Profile Manager内のアカウント登録だけを外します。既存環境のプロジェクト、チャット、設定、ログイン情報は変更しません。\n\n次にアカウントを追加すると、既存環境へ紐づけるか再び確認します。安全のため、Codexを終了してから実行してください。"
        alert.addButton(withTitle: "登録を外してやり直す")
        alert.addButton(withTitle: "キャンセル")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        do {
            try launcher.removeExistingEnvironmentAssignment()
            refreshUI()
            DispatchQueue.main.async { [weak self] in
                self?.presentAddAccount()
            }
        } catch {
            presentError(error, title: "紐づけをやり直せませんでした")
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
