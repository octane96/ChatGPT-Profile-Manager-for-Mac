import Darwin
import Foundation

struct AccountProfile: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    /// Registration identity and on-disk profile identity are intentionally
    /// separate. Re-registering a retained folder may create a new `id`,
    /// while `profileID` remains stable in its marker.
    let profileID: UUID
    var name: String
    let directoryName: String
    var lastKnownPath: String?
    var bookmarkData: Data?
    var isFavorite: Bool
    var showsInMenuBar: Bool

    private enum CodingKeys: String, CodingKey {
        case id, profileID, name, directoryName, lastKnownPath, bookmarkData, isFavorite, showsInMenuBar
    }

    init(
        id: UUID = UUID(),
        name: String,
        profileID: UUID? = nil,
        directoryName: String? = nil,
        lastKnownPath: String? = nil,
        bookmarkData: Data? = nil,
        isFavorite: Bool = false,
        showsInMenuBar: Bool = true
    ) {
        self.id = id
        self.profileID = profileID ?? id
        self.name = name
        self.directoryName = directoryName ?? Self.defaultDirectoryName(name: name, id: id)
        self.lastKnownPath = lastKnownPath
        self.bookmarkData = bookmarkData
        self.isFavorite = isFavorite
        self.showsInMenuBar = showsInMenuBar
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        self.id = id
        // Older accounts have no profileID. Their registration id is the
        // safest compatibility identity until a marker is written.
        self.profileID = try container.decodeIfPresent(UUID.self, forKey: .profileID) ?? id
        self.name = try container.decode(String.self, forKey: .name)
        self.directoryName = try container.decode(String.self, forKey: .directoryName)
        self.lastKnownPath = try container.decodeIfPresent(String.self, forKey: .lastKnownPath)
        self.bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
        self.isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        self.showsInMenuBar = try container.decodeIfPresent(Bool.self, forKey: .showsInMenuBar) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(profileID, forKey: .profileID)
        try container.encode(name, forKey: .name)
        try container.encode(directoryName, forKey: .directoryName)
        try container.encodeIfPresent(lastKnownPath, forKey: .lastKnownPath)
        try container.encodeIfPresent(bookmarkData, forKey: .bookmarkData)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encode(showsInMenuBar, forKey: .showsInMenuBar)
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

enum ProfileLoginState: Equatable, Sendable {
    case signedIn(email: String)
    case signedOut
    case unavailable
}

/// A non-sensitive identity marker kept in every isolated profile root.
struct ProfileIdentityMarker: Codable, Equatable, Sendable {
    static let fileName = ".chatgpt-profile-manager-profile.json"
    static let currentVersion = 1

    let version: Int
    let profileID: UUID
    let createdAt: Date

    init(profileID: UUID, createdAt: Date = Date()) {
        version = Self.currentVersion
        self.profileID = profileID
        self.createdAt = createdAt
    }
}

enum ProfileIdentityMarkerState: Equatable, Sendable {
    case missing
    case invalid
    case unsupported(ProfileIdentityMarker)
    case valid(ProfileIdentityMarker)
}

struct ProfilePaths: Equatable, Sendable {
    let root: URL
    let codexHome: URL
    let electronUserData: URL

    init(profile: AccountProfile, baseDirectory: URL) {
        if let lastKnownPath = profile.lastKnownPath,
           !lastKnownPath.isEmpty,
           URL(fileURLWithPath: lastKnownPath).path.hasPrefix("/") {
            root = URL(fileURLWithPath: lastKnownPath, isDirectory: true)
        } else {
            root = baseDirectory
                .appendingPathComponent("Profiles", isDirectory: true)
                .appendingPathComponent(profile.directoryName, isDirectory: true)
        }
        codexHome = root.appendingPathComponent("CodexHome", isDirectory: true)
        electronUserData = root.appendingPathComponent("ElectronUserData", isDirectory: true)
    }

    init(root: URL) {
        self.root = root
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

    func markerURL() -> URL {
        root.appendingPathComponent(ProfileIdentityMarker.fileName, isDirectory: false)
    }

    func maintenanceLockURL() -> URL {
        root.appendingPathComponent(".chatgpt-profile-manager-maintenance.lock", isDirectory: true)
    }

    func readMarkerState(fileManager: FileManager = .default) -> ProfileIdentityMarkerState {
        let markerURL = markerURL()
        // fileExists follows symlinks and reports false for a dangling one.
        // A present-but-unreadable marker must not be mistaken for a legacy
        // profile and overwritten, so inspect the directory entry itself.
        guard markerURL.path.withCString({ path in
            var info = stat()
            return lstat(path, &info) == 0
        }) else {
            return .missing
        }
        guard let data = try? Data(contentsOf: markerURL) else {
            return .invalid
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let marker = try? decoder.decode(ProfileIdentityMarker.self, from: data) else {
            return .invalid
        }
        guard marker.version == ProfileIdentityMarker.currentVersion else {
            return .unsupported(marker)
        }
        return .valid(marker)
    }

    func readMarker(fileManager: FileManager = .default) -> ProfileIdentityMarker? {
        if case let .valid(marker) = readMarkerState(fileManager: fileManager) {
            return marker
        }
        return nil
    }

    @discardableResult
    func ensureMarker(profileID: UUID, fileManager: FileManager = .default) throws -> ProfileIdentityMarker {
        switch readMarkerState(fileManager: fileManager) {
        case .invalid, .unsupported:
            // A present marker that cannot be understood is not a legacy
            // profile. Never overwrite it while trying to initialize storage.
            throw ProfileManagerError.profileMarkerMismatch
        case let .valid(existing):
            guard existing.profileID == profileID else {
                throw ProfileManagerError.profileMarkerMismatch
            }
            if existing.version == ProfileIdentityMarker.currentVersion {
                return existing
            }
            return existing
        case .missing:
            break
        }
        let marker = ProfileIdentityMarker(profileID: profileID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(marker).write(to: markerURL(), options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markerURL().path)
        return marker
    }
}

struct IsolatedProfileCandidate: Equatable, Identifiable, Sendable {
    let directoryName: String
    let root: URL
    let modifiedAt: Date?
    let profileID: UUID?

    init(directoryName: String, root: URL, modifiedAt: Date?, profileID: UUID? = nil) {
        self.directoryName = directoryName
        self.root = root
        self.modifiedAt = modifiedAt
        self.profileID = profileID
    }

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
    case profileRegistryBackupUnavailable
    case linkedAccountCannotBeDeleted
    case invalidAccountName
    case duplicateAccountName
    case invalidProfileDirectory
    case profileDirectoryAlreadyAssigned
    case profileDirectoryNotFound
    case profileMarkerMismatch
    case profileRootMissing
    case profileRootNotDirectory
    case profileRootNotReadable
    case profileMaintenanceInProgress
    case profileLockOwnershipFailed
    case profileRepairRollbackFailed
    case unknownProfileSchema
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
                fallback: "このプロファイルを使用中のChatGPTを終了してから、設定や登録情報を変更してください。"
            )
        case .accountNotFound:
            return L10n.text(
                "error.account-not-found",
                fallback: "選択したアカウントが見つかりませんでした。"
            )
        case .profileRegistryBackupUnavailable:
            return L10n.text(
                "error.profile-registry-backup-unavailable",
                fallback: "プロファイル管理情報の利用可能なバックアップが見つかりませんでした。"
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
        case .profileMarkerMismatch:
            return L10n.text(
                "error.profile-marker-mismatch",
                fallback: "選択した保存先は別の分離プロファイルに紐づいています。"
            )
        case .profileRootMissing:
            return L10n.text(
                "error.profile-root-missing",
                fallback: "分離プロファイルの保存先が見つかりません。保存先を再指定してください。"
            )
        case .profileRootNotDirectory:
            return L10n.text(
                "error.profile-root-not-directory",
                fallback: "分離プロファイルの保存先がフォルダではありません。"
            )
        case .profileRootNotReadable:
            return L10n.text(
                "error.profile-root-not-readable",
                fallback: "分離プロファイルの保存先を読み書きできません。"
            )
        case .profileMaintenanceInProgress:
            return L10n.text(
                "error.profile-maintenance-in-progress",
                fallback: "このプロファイルはメンテナンス中です。完了してから起動してください。"
            )
        case .profileLockOwnershipFailed:
            return L10n.text(
                "error.profile-lock-ownership-failed",
                fallback: "起動を排他管理する情報を保存できませんでした。起動したChatGPTを確認してから再試行してください。"
            )
        case .profileRepairRollbackFailed:
            return L10n.text(
                "error.profile-repair-rollback-failed",
                fallback: "修復失敗後のSQLite復元にも失敗しました。元のデータを保護したまま停止しました。"
            )
        case .unknownProfileSchema:
            return L10n.text(
                "error.unknown-profile-schema",
                fallback: "未対応のプロファイル構造のため、診断のみ実行しました。"
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
