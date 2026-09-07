import AppKit
import Darwin
import Foundation

@MainActor
final class CodexLauncher {
    static let codexBundleIdentifier = "com.openai.codex"

    private let fileManager: FileManager
    private let workspace: NSWorkspace
    private let stateStore: ProfileStateStore
    private let homeDirectory: URL
    private let applicationSupportOverride: URL?

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
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationSupportDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.workspace = workspace
        self.stateStore = stateStore
        self.homeDirectory = homeDirectory
        self.applicationSupportOverride = applicationSupportDirectory
        migrateLegacyProfileMarkers()
    }

    /// Completes the v1 -> stable profile identity migration lazily and only
    /// for roots that already exist. No missing root is created during this
    /// pass, which is important for detecting moved/deleted profiles.
    private func migrateLegacyProfileMarkers() {
        guard let base = try? profileBaseDirectory() else { return }
        for account in stateStore.accounts where account.id != stateStore.existingEnvironmentAccountID {
            let paths = ProfilePaths(profile: account, baseDirectory: base)
            guard fileManager.fileExists(atPath: paths.root.path) else { continue }
            switch paths.readMarkerState(fileManager: fileManager) {
            case let .valid(marker):
                // Never silently transfer a marker already claimed by another
                // registration. Leave the mismatch visible to diagnostics
                // and launch validation instead of creating duplicate stable
                // identities in UserDefaults.
                let markerIsClaimedByAnotherAccount = stateStore.accounts.contains {
                    $0.id != account.id && $0.profileID == marker.profileID
                }
                if marker.profileID != account.profileID && !markerIsClaimedByAnotherAccount {
                    _ = try? stateStore.updateProfileIdentity(id: account.id, profileID: marker.profileID)
                }
            case .missing:
                _ = try? paths.ensureMarker(profileID: account.profileID, fileManager: fileManager)
            case .invalid, .unsupported:
                // A present but unreadable marker must remain visible to
                // diagnostics. Never overwrite it as if this were legacy
                // storage.
                continue
            }
        }
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
                    && !stateStore.accounts.contains(where: { account in
                        ProfilePaths(profile: account, baseDirectory: baseDirectory).root.standardizedFileURL == directoryURL.standardizedFileURL
                            || ProfilePaths(root: directoryURL).readMarker(fileManager: fileManager)?.profileID == account.profileID
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
                modifiedAt: values.contentModificationDate,
                profileID: ProfilePaths(root: directoryURL).readMarker(fileManager: fileManager)?.profileID
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
        let processIdentifiers = Set(
            runningChatGPTApplications.map(\.processIdentifier)
        )
        synchronizeExternalLaunchMarkers(processIdentifiers: processIdentifiers)

        // An instance not started by this version of the manager is
        // conservatively treated as the default, existing environment.
        return stateStore.runningAccountIDs(
            processIdentifiers: processIdentifiers
        )
    }

    func isAccountRunning(id: UUID) -> Bool {
        runningAccountIDs.contains(id)
    }

    /// Brings the ChatGPT instance assigned to a profile to the front.
    /// Returns false when the running process cannot be resolved safely.
    @discardableResult
    func activate(accountID: UUID) -> Bool {
        let applications = runningChatGPTApplications
        let processIdentifiers = Set(applications.map(\.processIdentifier))
        synchronizeExternalLaunchMarkers(processIdentifiers: processIdentifiers)
        guard let processIdentifier = stateStore.runningProcessIdentifier(
            for: accountID,
            processIdentifiers: processIdentifiers
        ),
        let application = applications.first(where: {
            $0.processIdentifier == processIdentifier
        }) else {
            return false
        }
        return application.activate(options: [.activateAllWindows])
    }

    @discardableResult
    func addAccount(
        named name: String,
        linkToExistingEnvironment: Bool,
        directoryName: String? = nil
    ) throws -> AccountProfile {
        let candidate: IsolatedProfileCandidate?
        if let directoryName,
           let matchingCandidate = availableIsolatedProfiles.first(where: {
               $0.directoryName.compare(
                   directoryName,
                   options: [.caseInsensitive, .widthInsensitive]
               ) == .orderedSame
           }) {
            candidate = matchingCandidate
        } else if directoryName != nil {
            throw ProfileManagerError.profileDirectoryNotFound
        } else {
            candidate = nil
        }

        let account = try stateStore.addAccount(
            named: name,
            linkToExistingEnvironment: linkToExistingEnvironment,
            directoryName: directoryName,
            profileID: candidate?.profileID
        )
        if !linkToExistingEnvironment {
            let paths = ProfilePaths(profile: account, baseDirectory: try profileBaseDirectory())
            let rootExistedBeforeCreation = fileManager.fileExists(atPath: paths.root.path)
            do {
                if candidate == nil { try paths.createDirectories(fileManager: fileManager) }
                try paths.ensureMarker(profileID: account.profileID, fileManager: fileManager)
            } catch {
                // Account registration and storage initialization are one
                // operation. Do not leave an unusable UserDefaults record.
                _ = try? stateStore.removeAccount(id: account.id)
                if candidate == nil && !rootExistedBeforeCreation {
                    removeEmptyCreatedProfileRoot(paths.root)
                }
                throw error
            }
        }
        return account
    }

    /// Registers an isolated folder selected outside the manager-controlled
    /// Profiles directory. No file is copied or moved.
    @discardableResult
    func registerIsolatedProfile(
        named name: String,
        root: URL,
        bookmarkData: Data? = nil
    ) throws -> AccountProfile {
        let standardized = root.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProfileManagerError.profileDirectoryNotFound
        }
        let paths = ProfilePaths(root: standardized)
        var isCodexHomeDirectory: ObjCBool = false
        var isElectronDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: paths.codexHome.path, isDirectory: &isCodexHomeDirectory), isCodexHomeDirectory.boolValue,
              fileManager.fileExists(atPath: paths.electronUserData.path, isDirectory: &isElectronDirectory), isElectronDirectory.boolValue else {
            throw ProfileManagerError.profileRootNotReadable
        }
        let marker: ProfileIdentityMarker?
        switch paths.readMarkerState(fileManager: fileManager) {
        case .missing:
            marker = nil
        case let .valid(value):
            marker = value
        case .invalid, .unsupported:
            throw ProfileManagerError.profileMarkerMismatch
        }
        if let marker, stateStore.accounts.contains(where: { $0.profileID == marker.profileID }) {
            throw ProfileManagerError.profileDirectoryAlreadyAssigned
        }
        let account = try stateStore.addAccount(
            named: name,
            linkToExistingEnvironment: false,
            directoryName: standardized.lastPathComponent,
            profileID: marker?.profileID,
            lastKnownPath: standardized.path,
            bookmarkData: bookmarkData
        )
        do {
            try paths.ensureMarker(profileID: account.profileID, fileManager: fileManager)
        } catch {
            // The selected folder is user data and must never be removed, but
            // the failed registration itself is safe to roll back.
            _ = try? stateStore.removeAccount(id: account.id)
            throw error
        }
        return account
    }

    /// Removes only the empty directories created during a failed new-profile
    /// registration. POSIX rmdir is intentionally used so a race or an
    /// unexpected file can never trigger recursive deletion of user data.
    private func removeEmptyCreatedProfileRoot(_ root: URL) {
        guard fileManager.fileExists(atPath: root.path) else { return }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return }
        let expectedDirectories = Set(["CodexHome", "ElectronUserData"])
        let expectedFiles = Set([ProfileIdentityMarker.fileName])
        guard entries.allSatisfy({ expectedDirectories.contains($0.lastPathComponent) || expectedFiles.contains($0.lastPathComponent) }) else { return }

        for entry in entries where expectedDirectories.contains(entry.lastPathComponent) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  let children = try? fileManager.contentsOfDirectory(atPath: entry.path), children.isEmpty else { return }
        }
        for entry in entries where expectedFiles.contains(entry.lastPathComponent) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return }
        }
        for entry in entries where expectedDirectories.contains(entry.lastPathComponent) {
            _ = entry.path.withCString { Darwin.rmdir($0) }
        }
        if let marker = entries.first(where: { expectedFiles.contains($0.lastPathComponent) }) {
            _ = marker.path.withCString { Darwin.unlink($0) }
        }
        _ = root.path.withCString { Darwin.rmdir($0) }
    }

    func profilePaths(for account: AccountProfile) throws -> ProfilePaths {
        if account.id == stateStore.existingEnvironmentAccountID {
            throw ProfileManagerError.invalidProfileDirectory
        }
        return ProfilePaths(profile: account, baseDirectory: try profileBaseDirectory())
    }

    func isProfileStorageAvailable(_ account: AccountProfile) -> Bool {
        guard account.id != stateStore.existingEnvironmentAccountID,
              let base = try? profileBaseDirectory() else { return false }
        let paths = ProfilePaths(profile: account, baseDirectory: base)
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: paths.root.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func diagnoseProfile(id: UUID) throws -> ProfileDiagnosticReport {
        let account = try account(for: id)
        let base = try profileBaseDirectory()
        return ProfileDiagnosticsService(baseDirectory: base, fileManager: fileManager, isChatGPTRunning: { [weak self] in
            self?.isAccountRunning(id: id) ?? false
        }).diagnose(profile: account)
    }

    func accountForDiagnostics(id: UUID) throws -> AccountProfile {
        try account(for: id)
    }

    func repairProfileIndex(id: UUID) throws -> ProfileRepairResult {
        let selectedAccount = try account(for: id)
        guard selectedAccount.id != stateStore.existingEnvironmentAccountID else {
            throw ProfileManagerError.invalidProfileDirectory
        }
        let base = try profileBaseDirectory()
        return try ProfileDiagnosticsService(baseDirectory: base, fileManager: fileManager, isChatGPTRunning: { [weak self] in
            self?.isAccountRunning(id: selectedAccount.id) ?? false
        }).repairIndex(profile: selectedAccount)
    }

    func updateProfileLocation(id: UUID, root: URL, bookmarkData: Data? = nil) throws -> AccountProfile {
        let account = try account(for: id)
        guard account.id != stateStore.existingEnvironmentAccountID else {
            throw ProfileManagerError.invalidProfileDirectory
        }
        guard !isAccountRunning(id: id) else { throw ProfileManagerError.codexMustBeClosed }
        let launcherStore = try ProfileLauncherStore(baseDirectory: profileBaseDirectory(), fileManager: fileManager)
        let hadExistingLauncher = launcherStore.hasLauncher(for: account)
        let selected = root.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: selected.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProfileManagerError.profileDirectoryNotFound
        }
        let selectedPaths = ProfilePaths(root: selected)
        var isCodexHomeDirectory: ObjCBool = false
        var isElectronDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: selectedPaths.codexHome.path, isDirectory: &isCodexHomeDirectory), isCodexHomeDirectory.boolValue,
              fileManager.fileExists(atPath: selectedPaths.electronUserData.path, isDirectory: &isElectronDirectory), isElectronDirectory.boolValue else {
            throw ProfileManagerError.profileRootNotReadable
        }
        guard !stateStore.accounts.contains(where: { other in
            other.id != id && (ProfilePaths(profile: other, baseDirectory: (try? profileBaseDirectory()) ?? selected).root.standardizedFileURL == selected
                || other.profileID == account.profileID)
        }) else { throw ProfileManagerError.profileDirectoryAlreadyAssigned }
        if fileManager.fileExists(atPath: selectedPaths.markerURL().path), !fileManager.isReadableFile(atPath: selectedPaths.markerURL().path) {
            throw ProfileManagerError.profileRootNotReadable
        }
        let marker: ProfileIdentityMarker?
        switch selectedPaths.readMarkerState(fileManager: fileManager) {
        case .missing:
            marker = nil
        case let .valid(value):
            marker = value
        case .invalid, .unsupported:
            throw ProfileManagerError.profileMarkerMismatch
        }
        if let marker, marker.profileID != account.profileID { throw ProfileManagerError.profileMarkerMismatch }
        let currentRoot = ProfilePaths(profile: account, baseDirectory: (try? profileBaseDirectory()) ?? selected).root.standardizedFileURL
        if marker?.profileID == account.profileID,
           selected != currentRoot,
           fileManager.fileExists(atPath: currentRoot.path) {
            throw ProfileManagerError.profileDirectoryAlreadyAssigned
        }
        if marker == nil { try ProfilePaths(root: selected).ensureMarker(profileID: account.profileID, fileManager: fileManager) }
        try stateStore.updateProfileLocation(id: id, path: selected, bookmarkData: bookmarkData)
        let updated = try self.account(for: id)
        // Keep shared settings keyed by durable profile identity and update a
        // legacy directory-name reference in place when one exists.
        if let base = try? profileBaseDirectory() {
            _ = try? SettingsSharingStore(baseDirectory: base).migrateProfileReference(
                from: .isolated(directoryName: account.directoryName),
                to: .isolatedProfile(profileID: account.profileID)
            )
        }
        if hadExistingLauncher {
            _ = try? launcherStore.generate(for: updated, createProfileDirectories: false)
        }
        return updated
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
        try ProfileManagerLocations.applicationSupportDirectory(fileManager: fileManager, baseDirectory: applicationSupportOverride)
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
        return .isolatedProfile(profileID: account.profileID)
    }

    func settingsBinding(for account: AccountProfile) -> SettingsBinding? {
        guard let baseDirectory = try? profileBaseDirectory() else {
            return nil
        }
        let store = SettingsSharingStore(baseDirectory: baseDirectory)
        let stable = settingsStorageReference(for: account)
        if case .isolatedProfile = stable {
            _ = try? store.migrateProfileReference(
                from: .isolated(directoryName: account.directoryName),
                to: stable
            )
        }
        return store.binding(for: stable)
    }

    func settingsGroups() -> [SettingsGroup] {
        guard let baseDirectory = try? profileBaseDirectory() else {
            return []
        }
        return SettingsSharingStore(baseDirectory: baseDirectory).loadRegistry().groups
    }

    func profileLauncherURL(for account: AccountProfile) -> URL? {
        guard let baseDirectory = try? profileBaseDirectory() else {
            return nil
        }
        return ProfileLauncherStore(baseDirectory: baseDirectory).launcherURL(for: account)
    }

    func hasProfileLauncher(for account: AccountProfile) -> Bool {
        guard let baseDirectory = try? profileBaseDirectory() else {
            return false
        }
        return ProfileLauncherStore(baseDirectory: baseDirectory).hasLauncher(for: account)
    }

    @discardableResult
    func generateProfileLauncher(for accountID: UUID) throws -> URL {
        let account = try account(for: accountID)
        let baseDirectory = try profileBaseDirectory()
        return try ProfileLauncherStore(baseDirectory: baseDirectory).generate(for: account, createProfileDirectories: false)
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
        var runningLock: ProfileFileLock?
        if account.id == stateStore.existingEnvironmentAccountID {
            launchMode = .existingDefault
        } else {
            let paths = ProfilePaths(
                profile: account,
                baseDirectory: try profileBaseDirectory()
            )
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: paths.root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ProfileManagerError.profileRootMissing
            }
            var isCodexHomeDirectory: ObjCBool = false
            var isElectronDirectory: ObjCBool = false
            guard fileManager.isWritableFile(atPath: paths.root.path),
                  fileManager.fileExists(atPath: paths.codexHome.path, isDirectory: &isCodexHomeDirectory), isCodexHomeDirectory.boolValue,
                  fileManager.fileExists(atPath: paths.electronUserData.path, isDirectory: &isElectronDirectory), isElectronDirectory.boolValue else {
                throw ProfileManagerError.profileRootNotReadable
            }
            _ = ProfileFileLock.recoverStaleOwned(
                at: paths.maintenanceLockURL(),
                fileManager: fileManager,
                minimumAge: 15
            )
            if fileManager.fileExists(atPath: paths.maintenanceLockURL().path) {
                throw ProfileManagerError.profileMaintenanceInProgress
            }
            let baseDirectory = try profileBaseDirectory()
            let launcherStore = ProfileLauncherStore(baseDirectory: baseDirectory, fileManager: fileManager)
            launcherStore.recoverStaleRunningLock(for: account)
            if fileManager.fileExists(atPath: ProfileLauncherStore.runningLockURL(baseDirectory: baseDirectory, profileID: account.profileID).path) {
                throw ProfileManagerError.profileAlreadyRunning
            }
            switch paths.readMarkerState(fileManager: fileManager) {
            case .missing:
                break
            case let .valid(marker):
                if marker.profileID != account.profileID { throw ProfileManagerError.profileMarkerMismatch }
            case .invalid, .unsupported:
                throw ProfileManagerError.profileMarkerMismatch
            }
            try paths.ensureMarker(profileID: account.profileID, fileManager: fileManager)
            do {
                runningLock = try ProfileFileLock.acquireEmpty(
                    at: ProfileLauncherStore.runningLockURL(baseDirectory: baseDirectory, profileID: account.profileID),
                    fileManager: fileManager
                )
            } catch {
                throw ProfileManagerError.profileAlreadyRunning
            }
            launchMode = .isolated(paths)
        }

        let processIdentifier: Int32
        do {
            processIdentifier = try await launchCodex(appURL: appURL, mode: launchMode)
        } catch {
            runningLock?.release()
            throw error
        }
        // The atomic empty lock already serialized this launch with direct
        // launchers. Persist the ChatGPT PID afterwards so a manager restart
        // can safely tell an active UI launch from a stale lock.
        if let runningLock {
            do {
                try runningLock.setOwnerProcessIdentifier(processIdentifier)
            } catch {
                // The ChatGPT process has already been created. Keep the
                // acquired empty lock and persist the running assignment so
                // normal synchronization protects it until the process exits;
                // never release an ownership-ambiguous lock here.
                stateStore.setRunningProfileInstance(
                    accountID: account.id,
                    processIdentifier: processIdentifier
                )
                stateStore.setLastLaunchedAccount(account)
                throw ProfileManagerError.profileLockOwnershipFailed
            }
        }
        stateStore.setRunningProfileInstance(
            accountID: account.id,
            processIdentifier: processIdentifier
        )
        stateStore.setLastLaunchedAccount(account)
    }

    func quit(accountID: UUID) async throws {
        guard let account = stateStore.account(id: accountID) else {
            throw ProfileManagerError.accountNotFound
        }

        let applications = runningChatGPTApplications
        let processIdentifiers = Set(applications.map(\.processIdentifier))
        synchronizeExternalLaunchMarkers(processIdentifiers: processIdentifiers)
        guard let processIdentifier = stateStore.runningProcessIdentifier(
            for: accountID,
            processIdentifiers: processIdentifiers
        ) else {
            if !stateStore.runningAccountIDs(
                processIdentifiers: processIdentifiers
            ).contains(accountID) {
                stateStore.removeRunningProfileInstance(accountID: accountID)
                if let baseDirectory = try? profileBaseDirectory() {
                    _ = ProfileLauncherStore(baseDirectory: baseDirectory, fileManager: fileManager)
                        .releaseRunningLock(for: account)
                }
                return
            }
            throw ProfileManagerError.runningProfileCannotBeIdentified
        }

        guard let application = applications.first(where: {
            $0.processIdentifier == processIdentifier
        }) else {
            stateStore.removeRunningProfileInstance(accountID: accountID)
            if let baseDirectory = try? profileBaseDirectory() {
                _ = ProfileLauncherStore(baseDirectory: baseDirectory, fileManager: fileManager)
                    .releaseRunningLock(for: account)
            }
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
        if let baseDirectory = try? profileBaseDirectory() {
            _ = ProfileLauncherStore(baseDirectory: baseDirectory, fileManager: fileManager)
                .releaseRunningLock(for: account)
        }
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

    /// Direct profile launchers run ChatGPT without keeping the manager in the
    /// process tree. They leave a short-lived PID marker so the manager can
    /// associate that ChatGPT instance with the correct profile when it is
    /// already open or is opened later.
    private func synchronizeExternalLaunchMarkers(
        processIdentifiers: Set<Int32>
    ) {
        guard let baseDirectory = try? profileBaseDirectory() else {
            return
        }
        let markerDirectory = ProfileLauncherStore.runningMarkerDirectory(
            baseDirectory: baseDirectory
        )
        let markerURLs = (try? fileManager.contentsOfDirectory(
            at: markerDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let now = Date()
        for markerURL in markerURLs where markerURL.pathExtension == "pid" {
            guard
                let accountID = UUID(
                    uuidString: markerURL.deletingPathExtension().lastPathComponent
                ),
                let account = stateStore.account(id: accountID),
                let pidText = try? String(
                    contentsOf: markerURL,
                    encoding: .utf8
                ),
                let processIdentifier = Int32(
                    pidText.trimmingCharacters(in: .whitespacesAndNewlines)
                ),
                processIdentifier > 0
            else {
                _ = markerURL.path.withCString { Darwin.unlink($0) }
                continue
            }

            if processIdentifiers.contains(processIdentifier) {
                stateStore.setRunningProfileInstance(
                    accountID: accountID,
                    processIdentifier: processIdentifier
                )
                stateStore.setLastLaunchedAccount(account)
                continue
            }

            // The shell launcher removes its marker on exit. Keep a brief
            // grace period for the launch race where ChatGPT has not yet
            // appeared in NSWorkspace's process list.
            let modifiedAt = (try? markerURL.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? nil
            if let modifiedAt,
               now.timeIntervalSince(modifiedAt) < 15 {
                continue
            }
            _ = markerURL.path.withCString { Darwin.unlink($0) }
        }

        // UI-launched profiles have no shell PID marker. Their state-store
        // assignment protects active locks; all other empty locks may be
        // reclaimed by the same stale-lock helper used by direct launchers.
        let activeInstances = stateStore.activeRunningProfileInstances(
            processIdentifiers: processIdentifiers
        )
        let launcherStore = ProfileLauncherStore(
            baseDirectory: baseDirectory,
            fileManager: fileManager
        )
        for account in stateStore.accounts where account.id != stateStore.existingEnvironmentAccountID {
            guard activeInstances[account.id] == nil else { continue }
            launcherStore.recoverStaleRunningLock(for: account)
        }
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
