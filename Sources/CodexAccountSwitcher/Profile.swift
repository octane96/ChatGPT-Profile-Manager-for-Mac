import Foundation

struct AccountProfile: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    let directoryName: String

    init(
        id: UUID = UUID(),
        name: String,
        directoryName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.directoryName = directoryName ?? "account-\(id.uuidString.lowercased())"
    }
}

struct ProfilePaths: Equatable, Sendable {
    let root: URL
    let codexHome: URL
    let electronUserData: URL

    init(profile: AccountProfile, baseDirectory: URL) {
        root = baseDirectory
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(profile.directoryName, isDirectory: true)
        codexHome = root.appendingPathComponent("CodexHome", isDirectory: true)
        electronUserData = root.appendingPathComponent("ElectronUserData", isDirectory: true)
    }

    func createDirectories(fileManager: FileManager = .default) throws {
        for directory in [root, codexHome, electronUserData] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }
}

enum SwitcherLocations {
    private static let currentDirectoryName = "ChatGPT Profile Manager"
    private static let legacyDirectoryName = "Codex Account Switcher"

    static func applicationSupportDirectory(
        fileManager: FileManager = .default,
        baseDirectory: URL? = nil
    ) throws -> URL {
        let base: URL
        if let baseDirectory {
            base = baseDirectory
        } else if let applicationSupportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            base = applicationSupportDirectory
        } else {
            throw SwitcherError.applicationSupportUnavailable
        }

        let currentDirectory = base.appendingPathComponent(
            currentDirectoryName,
            isDirectory: true
        )
        let legacyDirectory = base.appendingPathComponent(
            legacyDirectoryName,
            isDirectory: true
        )

        return try migrateLegacyDirectory(
            from: legacyDirectory,
            to: currentDirectory,
            fileManager: fileManager
        )
    }

    private static func migrateLegacyDirectory(
        from legacyDirectory: URL,
        to currentDirectory: URL,
        fileManager: FileManager
    ) throws -> URL {
        guard fileManager.fileExists(atPath: legacyDirectory.path) else {
            return currentDirectory
        }

        guard fileManager.fileExists(atPath: currentDirectory.path) else {
            do {
                try fileManager.moveItem(at: legacyDirectory, to: currentDirectory)
                return currentDirectory
            } catch {
                // Keep using the legacy directory if the move cannot be completed.
                // This preserves access to existing profiles instead of risking data loss.
                return legacyDirectory
            }
        }

        guard isDirectory(currentDirectory, fileManager: fileManager) else {
            return legacyDirectory
        }
        guard isDirectory(legacyDirectory, fileManager: fileManager) else {
            return currentDirectory
        }

        try mergeDirectoryContents(
            from: legacyDirectory,
            to: currentDirectory,
            fileManager: fileManager
        )
        return currentDirectory
    }

    private static func mergeDirectoryContents(
        from sourceDirectory: URL,
        to destinationDirectory: URL,
        fileManager: FileManager
    ) throws {
        let entries = try fileManager.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )

        for sourceEntry in entries {
            let destinationEntry = destinationDirectory.appendingPathComponent(
                sourceEntry.lastPathComponent,
                isDirectory: isDirectory(sourceEntry, fileManager: fileManager)
            )

            guard fileManager.fileExists(atPath: destinationEntry.path) else {
                try fileManager.moveItem(at: sourceEntry, to: destinationEntry)
                continue
            }

            guard
                isDirectory(sourceEntry, fileManager: fileManager),
                isDirectory(destinationEntry, fileManager: fileManager)
            else {
                // Never overwrite a same-named file or profile. Leave it in the
                // legacy directory so the user can compare or recover it manually.
                continue
            }

            try mergeDirectoryContents(
                from: sourceEntry,
                to: destinationEntry,
                fileManager: fileManager
            )
        }

        if try fileManager.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: nil,
            options: []
        ).isEmpty {
            try fileManager.removeItem(at: sourceDirectory)
        }
    }

    private static func isDirectory(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        guard
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
            let isDirectory = values.isDirectory
        else {
            return false
        }
        return isDirectory
    }
}

struct CodexLaunchSpec: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]

    init(appURL: URL, mode: ProfileLaunchMode) {
        executableURL = URL(fileURLWithPath: "/usr/bin/open")
        switch mode {
        case .existingDefault:
            arguments = ["-n", appURL.path]
        case let .isolated(paths):
            arguments = [
                "-n",
                "--env", "CODEX_HOME=\(paths.codexHome.path)",
                "--env", "CODEX_ELECTRON_USER_DATA_PATH=\(paths.electronUserData.path)",
                appURL.path,
                "--args",
                "--user-data-dir=\(paths.electronUserData.path)"
            ]
        }
    }
}

enum ProfileLaunchMode: Equatable, Sendable {
    case existingDefault
    case isolated(ProfilePaths)
}

enum SwitcherError: LocalizedError, Equatable {
    case applicationSupportUnavailable
    case codexAppNotFound
    case codexDidNotQuit
    case codexMustBeClosed
    case accountNotFound
    case linkedAccountCannotBeDeleted
    case invalidAccountName
    case duplicateAccountName
    case existingEnvironmentAlreadyAssigned
    case launchFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "プロファイルの保存先を取得できませんでした。"
        case .codexAppNotFound:
            return "Codexデスクトップアプリが見つかりませんでした。"
        case .codexDidNotQuit:
            return "実行中のCodexを終了できませんでした。タスクを確認してから、もう一度お試しください。"
        case .codexMustBeClosed:
            return "設定をやり直す前に、実行中のCodexを終了してください。ChatGPT Profile Managerは終了せず、そのまま再実行できます。"
        case .accountNotFound:
            return "選択したアカウントが見つかりませんでした。"
        case .linkedAccountCannotBeDeleted:
            return "既存のCodex環境に紐づいたアカウントは削除できません。先に紐づけ登録を外してください。"
        case .invalidAccountName:
            return "アカウント名を1文字以上60文字以内で入力してください。"
        case .duplicateAccountName:
            return "同じ名前のアカウントがすでに登録されています。別の名前を入力してください。"
        case .existingEnvironmentAlreadyAssigned:
            return "既存のCodex環境は、すでに別のアカウントへ固定されています。"
        case let .launchFailed(status):
            return "Codexの起動に失敗しました（終了コード: \(status)）。"
        }
    }
}
