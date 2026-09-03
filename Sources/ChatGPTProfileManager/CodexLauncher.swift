import AppKit
import Foundation

@MainActor
final class CodexLauncher {
    static let codexBundleIdentifier = "com.openai.codex"

    private let fileManager: FileManager
    private let workspace: NSWorkspace
    private let stateStore: ProfileStateStore
    private let homeDirectory: URL

    private struct AuthDocument: Decodable {
        let email: String?
        let tokens: AuthTokens?
    }

    private struct AuthTokens: Decodable {
        let idToken: String?
        let accessToken: String?

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case accessToken = "access_token"
        }
    }

    private struct TokenPayload: Decodable {
        let email: String?
        let profile: TokenProfile?

        enum CodingKeys: String, CodingKey {
            case email
            case profile = "https://api.openai.com/profile"
        }
    }

    private struct TokenProfile: Decodable {
        let email: String?
    }

    init(
        fileManager: FileManager = .default,
        workspace: NSWorkspace = .shared,
        stateStore: ProfileStateStore = ProfileStateStore(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.workspace = workspace
        self.stateStore = stateStore
        self.homeDirectory = homeDirectory
    }

    var accounts: [AccountProfile] {
        stateStore.accounts
    }

    var lastLaunchedAccount: AccountProfile? {
        guard let id = stateStore.lastLaunchedAccountID else {
            return nil
        }
        return stateStore.account(id: id)
    }

    var existingEnvironmentAccount: AccountProfile? {
        guard let id = stateStore.existingEnvironmentAccountID else {
            return nil
        }
        return stateStore.account(id: id)
    }

    var hasShownMechanismGuide: Bool {
        stateStore.hasShownMechanismGuide
    }

    func markMechanismGuideShown() {
        stateStore.markMechanismGuideShown()
    }

    /// Registers the default ChatGPT environment on the first launch when it
    /// already exists. Later empty registries are treated as an intentional
    /// recovery state and continue to show the normal add-account flow.
    @discardableResult
    func registerExistingEnvironmentIfNeeded() throws -> AccountProfile? {
        guard !stateStore.hasSavedAccountState,
              stateStore.accounts.isEmpty,
              hasExistingEnvironment
        else {
            return nil
        }

        let name = existingEnvironmentEmail ?? L10n.text(
            "account.default-existing-environment-name",
            fallback: "既存のChatGPT環境"
        )
        return try addAccount(
            named: name,
            linkToExistingEnvironment: true
        )
    }

    var hasExistingEnvironment: Bool {
        let codexHome = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        let electronUserData = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Codex", isDirectory: true)
        return fileManager.fileExists(atPath: codexHome.path)
            || fileManager.fileExists(atPath: electronUserData.path)
    }

    var existingEnvironmentEmail: String? {
        let authURL = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
        guard let data = try? Data(contentsOf: authURL),
              let document = try? JSONDecoder().decode(AuthDocument.self, from: data)
        else {
            return nil
        }

        let directEmail = normalizedEmail(document.email)
        if let directEmail {
            return directEmail
        }

        for token in [document.tokens?.idToken, document.tokens?.accessToken].compactMap({ $0 }) {
            if let email = emailFromToken(token) {
                return email
            }
        }
        return nil
    }

    /// Returns unregistered profile folders that contain a Codex or ChatGPT
    /// desktop-app data directory. Existing folders are never renamed or moved.
    var availableIsolatedProfiles: [IsolatedProfileCandidate] {
        guard let baseDirectory = try? profileBaseDirectory() else {
            return []
        }

        let profilesDirectory = baseDirectory.appendingPathComponent(
            "Profiles",
            isDirectory: true
        )
        guard let entries = try? fileManager.contentsOfDirectory(
            at: profilesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries.compactMap { directoryURL in
            guard
                let values = try? directoryURL.resourceValues(
                    forKeys: [.isDirectoryKey, .contentModificationDateKey]
                ),
                values.isDirectory == true,
                !stateStore.accounts.contains(where: { account in
                    account.directoryName.compare(
                        directoryURL.lastPathComponent,
                        options: [.caseInsensitive, .widthInsensitive]
                    ) == .orderedSame
                })
            else {
                return nil
            }

            let codexHome = directoryURL.appendingPathComponent(
                "CodexHome",
                isDirectory: true
            )
            let electronUserData = directoryURL.appendingPathComponent(
                "ElectronUserData",
                isDirectory: true
            )
            guard
                fileManager.fileExists(atPath: codexHome.path)
                    || fileManager.fileExists(atPath: electronUserData.path)
            else {
                return nil
            }

            return IsolatedProfileCandidate(
                directoryName: directoryURL.lastPathComponent,
                root: directoryURL,
                modifiedAt: values.contentModificationDate
            )
        }
        .sorted {
            $0.directoryName.localizedStandardCompare($1.directoryName)
                == .orderedAscending
        }
    }

    var isCodexRunning: Bool {
        !runningChatGPTApplications.isEmpty
    }

    var runningAccountIDs: Set<UUID> {
        // An instance not started by this version of the manager is
        // conservatively treated as the default, existing environment.
        stateStore.runningAccountIDs(
            processIdentifiers: Set(
                runningChatGPTApplications.map(\.processIdentifier)
            )
        )
    }

    func isAccountRunning(id: UUID) -> Bool {
        runningAccountIDs.contains(id)
    }

    @discardableResult
    func addAccount(
        named name: String,
        linkToExistingEnvironment: Bool,
        directoryName: String? = nil
    ) throws -> AccountProfile {
        if let directoryName,
           !availableIsolatedProfiles.contains(where: {
               $0.directoryName.compare(
                   directoryName,
                   options: [.caseInsensitive, .widthInsensitive]
               ) == .orderedSame
           }) {
            throw ProfileManagerError.profileDirectoryNotFound
        }

        return try stateStore.addAccount(
            named: name,
            linkToExistingEnvironment: linkToExistingEnvironment,
            directoryName: directoryName
        )
    }

    func validateNewAccountName(_ name: String) throws -> String {
        try stateStore.validateNewAccountName(name)
    }

    func renameAccount(id: UUID, to name: String) throws {
        try stateStore.renameAccount(id: id, to: name)
    }

    func moveAccount(id: UUID, toInsertionIndex insertionIndex: Int) throws {
        try stateStore.moveAccount(id: id, toInsertionIndex: insertionIndex)
    }

    func removeIsolatedAccountRegistration(id: UUID) throws -> AccountProfile {
        guard stateStore.account(id: id) != nil else {
            throw ProfileManagerError.accountNotFound
        }
        if stateStore.existingEnvironmentAccountID == id {
            throw ProfileManagerError.linkedAccountCannotBeDeleted
        }
        guard !isAccountRunning(id: id) else {
            throw ProfileManagerError.codexMustBeClosed
        }

        // Removing an account only removes its registration. The profile directory
        // and all data inside it remain available for later re-registration.
        return try stateStore.removeAccount(id: id)
    }

    func profileBaseDirectory() throws -> URL {
        try ProfileManagerLocations.applicationSupportDirectory(fileManager: fileManager)
    }

    func codexHomeDirectory(for account: AccountProfile) -> URL? {
        if account.id == stateStore.existingEnvironmentAccountID {
            return homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        }

        guard let baseDirectory = try? profileBaseDirectory() else {
            return nil
        }
        return ProfilePaths(profile: account, baseDirectory: baseDirectory).codexHome
    }

    func settingsStorageReference(for account: AccountProfile) -> ProfileStorageReference {
        if account.id == stateStore.existingEnvironmentAccountID {
            return .existingEnvironment
        }
        return .isolated(directoryName: account.directoryName)
    }

    func settingsBinding(for account: AccountProfile) -> SettingsBinding? {
        guard let baseDirectory = try? profileBaseDirectory() else {
            return nil
        }
        return SettingsSharingStore(baseDirectory: baseDirectory).binding(
            for: settingsStorageReference(for: account)
        )
    }

    func settingsGroups() -> [SettingsGroup] {
        guard let baseDirectory = try? profileBaseDirectory() else {
            return []
        }
        return SettingsSharingStore(baseDirectory: baseDirectory).loadRegistry().groups
    }

    @discardableResult
    func copySettings(
        from sourceAccountID: UUID,
        to destinationAccountID: UUID,
        items: Set<ManagedSetting>
    ) throws -> SettingsOperationSummary {
        let sourceAccount = try account(for: sourceAccountID)
        let destinationAccount = try account(for: destinationAccountID)
        guard sourceAccount.id != destinationAccount.id else {
            throw SettingsSharingError.sourceAndDestinationAreSame
        }
        try ensureSettingsProfilesClosed([sourceAccount, destinationAccount])
        let homes = try settingsHomes(for: [sourceAccount, destinationAccount])
        let baseDirectory = try profileBaseDirectory()
        return try SettingsSharingStore(baseDirectory: baseDirectory).copy(
            source: settingsStorageReference(for: sourceAccount),
            destination: settingsStorageReference(for: destinationAccount),
            items: items,
            codexHomes: homes
        )
    }

    @discardableResult
    func createSettingsShare(
        named name: String,
        sourceAccountID: UUID,
        destinationAccountIDs: [UUID],
        items: Set<ManagedSetting>
    ) throws -> SettingsGroup {
        let sourceAccount = try account(for: sourceAccountID)
        let destinationAccounts = try destinationAccountIDs.map { try account(for: $0) }
        let affectedAccounts = [sourceAccount] + destinationAccounts
        try ensureSettingsProfilesClosed(affectedAccounts)
        let homes = try settingsHomes(for: affectedAccounts)
        let references = affectedAccounts.map(settingsStorageReference(for:))
        let baseDirectory = try profileBaseDirectory()
        return try SettingsSharingStore(baseDirectory: baseDirectory).createShareGroup(
            name: name,
            source: settingsStorageReference(for: sourceAccount),
            destinations: Array(references.dropFirst()),
            items: items,
            codexHomes: homes
        )
    }

    @discardableResult
    func leaveSettingsShare(for accountID: UUID) throws -> SettingsGroup {
        let account = try account(for: accountID)
        try ensureSettingsProfilesClosed([account])
        guard let codexHome = codexHomeDirectory(for: account) else {
            throw SettingsSharingError.transactionFailed
        }
        let baseDirectory = try profileBaseDirectory()
        return try SettingsSharingStore(baseDirectory: baseDirectory).leaveShareGroup(
            profile: settingsStorageReference(for: account),
            codexHome: codexHome
        )
    }

    @discardableResult
    func joinSettingsShare(
        groupID: UUID,
        accountID: UUID
    ) throws -> SettingsGroup {
        let account = try account(for: accountID)
        try ensureSettingsProfilesClosed([account])
        guard let codexHome = codexHomeDirectory(for: account) else {
            throw SettingsSharingError.transactionFailed
        }
        let baseDirectory = try profileBaseDirectory()
        return try SettingsSharingStore(baseDirectory: baseDirectory).joinShareGroup(
            groupID: groupID,
            profile: settingsStorageReference(for: account),
            codexHome: codexHome
        )
    }

    private func account(for id: UUID) throws -> AccountProfile {
        guard let account = stateStore.account(id: id) else {
            throw ProfileManagerError.accountNotFound
        }
        return account
    }

    private func settingsHomes(
        for accounts: [AccountProfile]
    ) throws -> [ProfileStorageReference: URL] {
        var homes: [ProfileStorageReference: URL] = [:]
        for account in accounts {
            guard let home = codexHomeDirectory(for: account) else {
                throw SettingsSharingError.transactionFailed
            }
            homes[settingsStorageReference(for: account)] = home
        }
        return homes
    }

    private func ensureSettingsProfilesClosed(_ accounts: [AccountProfile]) throws {
        guard !accounts.contains(where: { isAccountRunning(id: $0.id) }) else {
            throw ProfileManagerError.codexMustBeClosed
        }
    }

    func open(accountID: UUID) async throws {
        guard let account = stateStore.account(id: accountID) else {
            throw ProfileManagerError.accountNotFound
        }
        guard !isAccountRunning(id: accountID) else {
            throw ProfileManagerError.profileAlreadyRunning
        }
        guard let appURL = locateCodexApp() else {
            throw ProfileManagerError.codexAppNotFound
        }

        let launchMode: ProfileLaunchMode
        if account.id == stateStore.existingEnvironmentAccountID {
            launchMode = .existingDefault
        } else {
            let paths = ProfilePaths(
                profile: account,
                baseDirectory: try profileBaseDirectory()
            )
            try paths.createDirectories(fileManager: fileManager)
            launchMode = .isolated(paths)
        }

        let processIdentifier = try await launchCodex(appURL: appURL, mode: launchMode)
        stateStore.setRunningProfileInstance(
            accountID: account.id,
            processIdentifier: processIdentifier
        )
        stateStore.setLastLaunchedAccount(account)
    }

    func quit(accountID: UUID) async throws {
        guard stateStore.account(id: accountID) != nil else {
            throw ProfileManagerError.accountNotFound
        }

        let applications = runningChatGPTApplications
        let processIdentifiers = Set(applications.map(\.processIdentifier))
        guard let processIdentifier = stateStore.runningProcessIdentifier(
            for: accountID,
            processIdentifiers: processIdentifiers
        ) else {
            if !stateStore.runningAccountIDs(
                processIdentifiers: processIdentifiers
            ).contains(accountID) {
                stateStore.removeRunningProfileInstance(accountID: accountID)
                return
            }
            throw ProfileManagerError.runningProfileCannotBeIdentified
        }

        guard let application = applications.first(where: {
            $0.processIdentifier == processIdentifier
        }) else {
            stateStore.removeRunningProfileInstance(accountID: accountID)
            return
        }

        let acceptedQuitRequest = application.terminate()
        if !acceptedQuitRequest && !application.isTerminated {
            throw ProfileManagerError.chatGPTDidNotQuit
        }

        for _ in 0..<80 where !application.isTerminated {
            try await Task.sleep(for: .milliseconds(125))
        }
        guard application.isTerminated else {
            throw ProfileManagerError.chatGPTDidNotQuit
        }

        stateStore.removeRunningProfileInstance(accountID: accountID)
    }

    private func locateCodexApp() -> URL? {
        if let located = workspace.urlForApplication(
            withBundleIdentifier: Self.codexBundleIdentifier
        ) {
            return located
        }

        let fallback = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        return fileManager.fileExists(atPath: fallback.path) ? fallback : nil
    }

    private func emailFromToken(_ token: String) -> String? {
        let components = token.split(separator: ".")
        guard components.count >= 2 else {
            return nil
        }

        var encodedPayload = String(components[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while encodedPayload.count % 4 != 0 {
            encodedPayload.append("=")
        }
        guard let payloadData = Data(base64Encoded: encodedPayload),
              let payload = try? JSONDecoder().decode(TokenPayload.self, from: payloadData)
        else {
            return nil
        }

        return normalizedEmail(payload.email ?? payload.profile?.email)
    }

    private func normalizedEmail(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let email = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.count <= 60,
              email.contains("@"),
              !email.contains("\n"),
              !email.contains("\r")
        else {
            return nil
        }
        return email
    }

    private var runningChatGPTApplications: [NSRunningApplication] {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.codexBundleIdentifier
        ).filter { !$0.isTerminated }
    }

    private func launchCodex(
        appURL: URL,
        mode: ProfileLaunchMode
    ) async throws -> Int32 {
        let spec = CodexLaunchSpec(appURL: appURL, mode: mode)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = spec.arguments
        configuration.environment = spec.environment

        return try await withCheckedThrowingContinuation { continuation in
            workspace.openApplication(
                at: spec.applicationURL,
                configuration: configuration
            ) { application, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let application {
                    continuation.resume(returning: application.processIdentifier)
                } else {
                    continuation.resume(
                        throwing: ProfileManagerError.launchFailed(-1)
                    )
                }
            }
        }
    }
}
