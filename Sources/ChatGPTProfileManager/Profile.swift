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
        self.directoryName = directoryName ?? Self.defaultDirectoryName(name: name, id: id)
    }

    private static func defaultDirectoryName(name: String, id: UUID) -> String {
        let slug = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
            .unicodeScalars
            .filter { scalar in
                CharacterSet.alphanumerics.contains(scalar)
                    || scalar == "-"
                    || scalar == "_"
            }
            .map(String.init)
            .joined()
            .lowercased()

        let readableSlug = String(slug.prefix(32)).trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        let shortID = id.uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        return "account-\(readableSlug.isEmpty ? "profile" : readableSlug)-\(shortID)"
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

struct IsolatedProfileCandidate: Equatable, Identifiable, Sendable {
    let directoryName: String
    let root: URL
    let modifiedAt: Date?

    var id: String { directoryName }
}

enum ProfileManagerLocations {
    private static let currentDirectoryName = "ChatGPT Profile Manager"

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
            throw ProfileManagerError.applicationSupportUnavailable
        }

        return base.appendingPathComponent(
            currentDirectoryName,
            isDirectory: true
        )
    }
}

struct CodexLaunchSpec: Equatable, Sendable {
    let applicationURL: URL
    let environment: [String: String]
    let arguments: [String]

    init(appURL: URL, mode: ProfileLaunchMode) {
        applicationURL = appURL
        switch mode {
        case .existingDefault:
            environment = [:]
            arguments = []
        case let .isolated(paths):
            environment = [
                "CODEX_HOME": paths.codexHome.path,
                "CODEX_ELECTRON_USER_DATA_PATH": paths.electronUserData.path
            ]
            arguments = ["--user-data-dir=\(paths.electronUserData.path)"]
        }
    }
}

enum ProfileLaunchMode: Equatable, Sendable {
    case existingDefault
    case isolated(ProfilePaths)
}

enum ProfileManagerError: LocalizedError, Equatable {
    case applicationSupportUnavailable
    case codexAppNotFound
    case codexMustBeClosed
    case accountNotFound
    case linkedAccountCannotBeDeleted
    case invalidAccountName
    case duplicateAccountName
    case invalidProfileDirectory
    case profileDirectoryAlreadyAssigned
    case profileDirectoryNotFound
    case existingEnvironmentAlreadyAssigned
    case profileAlreadyRunning
    case runningProfileCannotBeIdentified
    case chatGPTDidNotQuit
    case launchFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return L10n.text(
                "error.application-support-unavailable",
                fallback: "プロファイルの保存先を取得できませんでした。"
            )
        case .codexAppNotFound:
            return L10n.text(
                "error.chatgpt-app-not-found",
                fallback: "ChatGPTデスクトップアプリが見つかりませんでした。"
            )
        case .codexMustBeClosed:
            return L10n.text(
                "error.chatgpt-must-be-closed",
                fallback: "このプロファイルを使用中のChatGPTを終了してから、登録情報を変更してください。"
            )
        case .accountNotFound:
            return L10n.text(
                "error.account-not-found",
                fallback: "選択したアカウントが見つかりませんでした。"
            )
        case .linkedAccountCannotBeDeleted:
            return L10n.text(
                "error.existing-account-cannot-be-deleted",
                fallback: "ChatGPTの既存環境に紐づいたアカウントは削除できません。"
            )
        case .invalidAccountName:
            return L10n.text(
                "error.invalid-account-name",
                fallback: "アカウント名を1文字以上60文字以内で入力してください。"
            )
        case .duplicateAccountName:
            return L10n.text(
                "error.duplicate-account-name",
                fallback: "同じ名前のアカウントがすでに登録されています。別の名前を入力してください。"
            )
        case .invalidProfileDirectory:
            return L10n.text(
                "error.invalid-profile-directory",
                fallback: "分離プロファイルの保存先名が無効です。"
            )
        case .profileDirectoryAlreadyAssigned:
            return L10n.text(
                "error.profile-directory-already-assigned",
                fallback: "その分離プロファイルは、すでに別のアカウントへ紐づいています。"
            )
        case .profileDirectoryNotFound:
            return L10n.text(
                "error.profile-directory-not-found",
                fallback: "選択した分離プロファイルが見つかりませんでした。"
            )
        case .existingEnvironmentAlreadyAssigned:
            return L10n.text(
                "error.existing-environment-already-assigned",
                fallback: "ChatGPTの既存環境は、すでに別のアカウントへ固定されています。"
            )
        case .profileAlreadyRunning:
            return L10n.text(
                "error.profile-already-running",
                fallback: "このプロファイルはすでに起動中です。同じ保存先を使うChatGPTは複数起動できません。"
            )
        case .runningProfileCannotBeIdentified:
            return L10n.text(
                "error.running-profile-cannot-be-identified",
                fallback: "終了するChatGPTを一意に特定できませんでした。対象のChatGPTを直接終了してください。"
            )
        case .chatGPTDidNotQuit:
            return L10n.text(
                "error.chatgpt-did-not-quit",
                fallback: "ChatGPTが終了しませんでした。進行中の確認画面などがないか、ChatGPT側を確認してください。"
            )
        case let .launchFailed(status):
            return L10n.text(
                "error.chatgpt-launch-failed",
                fallback: "ChatGPTの起動に失敗しました（終了コード: {status}）。",
                replacing: ["status": "\(status)"]
            )
        }
    }
}
