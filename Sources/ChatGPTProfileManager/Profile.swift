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

enum ProfileManagerError: LocalizedError, Equatable {
    case applicationSupportUnavailable
    case codexAppNotFound
    case codexDidNotQuit
    case codexMustBeClosed
    case accountNotFound
    case linkedAccountCannotBeDeleted
    case invalidAccountName
    case duplicateAccountName
    case invalidProfileDirectory
    case profileDirectoryAlreadyAssigned
    case profileDirectoryNotFound
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
        case .invalidProfileDirectory:
            return "分離プロファイルの保存先名が無効です。"
        case .profileDirectoryAlreadyAssigned:
            return "その分離プロファイルは、すでに別のアカウントへ紐づいています。"
        case .profileDirectoryNotFound:
            return "選択した分離プロファイルが見つかりませんでした。"
        case .existingEnvironmentAlreadyAssigned:
            return "既存のCodex環境は、すでに別のアカウントへ固定されています。"
        case let .launchFailed(status):
            return "Codexの起動に失敗しました（終了コード: \(status)）。"
        }
    }
}
