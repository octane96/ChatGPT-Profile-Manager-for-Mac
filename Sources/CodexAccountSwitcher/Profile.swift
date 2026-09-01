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
    static func applicationSupportDirectory(fileManager: FileManager = .default) throws -> URL {
        guard let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw SwitcherError.applicationSupportUnavailable
        }

        return base.appendingPathComponent("Codex Account Switcher", isDirectory: true)
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
