import Foundation

enum ProfileRegistryHealthState: Equatable, Sendable {
    case healthy
    case missing
    case corrupted
}

struct ProfileRegistryHealth: Equatable, Sendable {
    let state: ProfileRegistryHealthState
    let backupAvailable: Bool
}

struct RunningProfileInstance: Codable, Equatable, Sendable {
    let accountID: UUID
    let processIdentifier: Int32
}

struct ProfileStateStore {
    private let defaults: UserDefaults

    private let accountsKey = "accountsV2"
    private let accountsBackupKey = "accountsV2Backup"
    private let lastLaunchedAccountIDKey = "lastLaunchedAccountID"
    private let existingEnvironmentAccountIDKey = "existingEnvironmentAccountID"
    private let hasShownMechanismGuideKey = "hasShownMechanismGuide"
    private let runningProfileInstancesKey = "runningProfileInstances"

    private let legacyLastLaunchedProfileKey = "lastLaunchedProfile"
    private let legacyExistingEnvironmentProfileKey = "existingEnvironmentProfile"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateLegacyStateIfNeeded()
    }

    var accounts: [AccountProfile] {
        guard
            let data = defaults.data(forKey: accountsKey),
            let decoded = try? JSONDecoder().decode([AccountProfile].self, from: data)
        else {
            return []
        }
        return decoded
    }

    /// Distinguishes a first launch from a registry that exists but can no
    /// longer be decoded. The latter must not silently look like an empty
    /// profile list because it can hide the user's registrations.
    var registryHealth: ProfileRegistryHealth {
        guard let data = defaults.data(forKey: accountsKey) else {
            return ProfileRegistryHealth(
                state: .missing,
                backupAvailable: validBackupData != nil
            )
        }
        let state: ProfileRegistryHealthState = (try? JSONDecoder().decode([AccountProfile].self, from: data)) != nil
            ? .healthy
            : .corrupted
        return ProfileRegistryHealth(state: state, backupAvailable: validBackupData != nil)
    }

    @discardableResult
    func restoreAccountsFromBackup() throws -> [AccountProfile] {
        guard let data = validBackupData else {
            throw ProfileManagerError.profileRegistryBackupUnavailable
        }
        let restored = try JSONDecoder().decode([AccountProfile].self, from: data)
        try saveAccounts(restored)
        return restored
    }

    /// Indicates whether this app has written an account registry before.
    /// An empty saved registry is intentionally different from a first launch,
    /// so recovery does not trigger the initial automatic registration again.
    var hasSavedAccountState: Bool {
        defaults.object(forKey: accountsKey) != nil
    }

    var hasShownMechanismGuide: Bool {
        defaults.bool(forKey: hasShownMechanismGuideKey)
    }

    func markMechanismGuideShown() {
        defaults.set(true, forKey: hasShownMechanismGuideKey)
    }

    var lastLaunchedAccountID: UUID? {
        uuid(forKey: lastLaunchedAccountIDKey)
    }

    var existingEnvironmentAccountID: UUID? {
        uuid(forKey: existingEnvironmentAccountIDKey)
    }

    func activeRunningProfileInstances(
        processIdentifiers: Set<Int32>
    ) -> [UUID: Int32] {
        let savedInstances = runningProfileInstances
        var activeInstances: [UUID: Int32] = [:]

        for instance in savedInstances where
            processIdentifiers.contains(instance.processIdentifier)
                && account(id: instance.accountID) != nil
        {
            activeInstances[instance.accountID] = instance.processIdentifier
        }

        let normalizedInstances = activeInstances
            .map {
                RunningProfileInstance(
                    accountID: $0.key,
                    processIdentifier: $0.value
                )
            }
            .sorted { $0.accountID.uuidString < $1.accountID.uuidString }
        if normalizedInstances != savedInstances.sorted(
            by: { $0.accountID.uuidString < $1.accountID.uuidString }
        ) {
            saveRunningProfileInstances(normalizedInstances)
        }

        return activeInstances
    }

    func runningAccountIDs(processIdentifiers: Set<Int32>) -> Set<UUID> {
        let assignedInstances = activeRunningProfileInstances(
            processIdentifiers: processIdentifiers
        )
        var accountIDs = Set(assignedInstances.keys)

        if let existingEnvironmentAccountID {
            let assignedProcessIdentifiers = Set(assignedInstances.values)
            if !processIdentifiers.subtracting(assignedProcessIdentifiers).isEmpty {
                accountIDs.insert(existingEnvironmentAccountID)
            }
        }

        return accountIDs
    }

    /// Resolves the one running process that belongs to an account.
    ///
    /// Isolated profiles and manager-launched existing environments use the
    /// saved process assignment. An existing environment that was launched
    /// outside the manager can be resolved only when exactly one unassigned
    /// ChatGPT process is running. This prevents quitting the wrong instance.
    func runningProcessIdentifier(
        for accountID: UUID,
        processIdentifiers: Set<Int32>
    ) -> Int32? {
        let assignedInstances = activeRunningProfileInstances(
            processIdentifiers: processIdentifiers
        )
        if let assignedProcessIdentifier = assignedInstances[accountID] {
            return assignedProcessIdentifier
        }

        guard existingEnvironmentAccountID == accountID else {
            return nil
        }

        let unassignedProcessIdentifiers = processIdentifiers.subtracting(
            Set(assignedInstances.values)
        )
        guard unassignedProcessIdentifiers.count == 1 else {
            return nil
        }
        return unassignedProcessIdentifiers.first
    }

    func setRunningProfileInstance(accountID: UUID, processIdentifier: Int32) {
        var instances = runningProfileInstances.filter { $0.accountID != accountID }
        instances.append(
            RunningProfileInstance(
                accountID: accountID,
                processIdentifier: processIdentifier
            )
        )
        saveRunningProfileInstances(instances)
    }

    func removeRunningProfileInstance(accountID: UUID) {
        saveRunningProfileInstances(
            runningProfileInstances.filter { $0.accountID != accountID }
        )
    }

    func account(id: UUID) -> AccountProfile? {
        accounts.first(where: { $0.id == id })
    }

    func validateNewAccountName(_ name: String) throws -> String {
        let normalizedName = try validatedName(name)
        guard !containsName(normalizedName, in: accounts) else {
            throw ProfileManagerError.duplicateAccountName
        }
        return normalizedName
    }

    @discardableResult
    func addAccount(
        named name: String,
        linkToExistingEnvironment: Bool,
        directoryName: String? = nil,
        profileID: UUID? = nil,
        lastKnownPath: String? = nil,
        bookmarkData: Data? = nil
    ) throws -> AccountProfile {
        let normalizedName = try validateNewAccountName(name)
        var currentAccounts = accounts

        if linkToExistingEnvironment, existingEnvironmentAccountID != nil {
            throw ProfileManagerError.existingEnvironmentAlreadyAssigned
        }
        if linkToExistingEnvironment, directoryName != nil {
            throw ProfileManagerError.invalidProfileDirectory
        }

        let normalizedDirectoryName: String?
        if let directoryName {
            let validatedDirectoryName = try validateProfileDirectoryName(directoryName)
            guard !containsDirectoryName(validatedDirectoryName, in: currentAccounts) else {
                throw ProfileManagerError.profileDirectoryAlreadyAssigned
            }
            normalizedDirectoryName = validatedDirectoryName
        } else {
            normalizedDirectoryName = nil
        }

        if let profileID,
           currentAccounts.contains(where: { $0.profileID == profileID }) {
            throw ProfileManagerError.profileDirectoryAlreadyAssigned
        }

        let account = AccountProfile(
            name: normalizedName,
            profileID: profileID,
            directoryName: normalizedDirectoryName,
            lastKnownPath: lastKnownPath,
            bookmarkData: bookmarkData
        )
        currentAccounts.append(account)
        try saveAccounts(currentAccounts)

        if linkToExistingEnvironment {
            defaults.set(account.id.uuidString, forKey: existingEnvironmentAccountIDKey)
        }

        return account
    }

    /// Updates only the locator for an isolated profile. The stable profileID
    /// and registration id never change when a folder is moved.
    func updateProfileLocation(
        id: UUID,
        path: URL,
        bookmarkData: Data? = nil
    ) throws {
        var currentAccounts = accounts
        guard let index = currentAccounts.firstIndex(where: { $0.id == id }) else {
            throw ProfileManagerError.accountNotFound
        }
        guard currentAccounts[index].id != existingEnvironmentAccountID else {
            throw ProfileManagerError.invalidProfileDirectory
        }
        guard path.standardizedFileURL.path.hasPrefix("/") else {
            throw ProfileManagerError.invalidProfileDirectory
        }
        currentAccounts[index].lastKnownPath = path.standardizedFileURL.path
        currentAccounts[index].bookmarkData = bookmarkData
        try saveAccounts(currentAccounts)
    }

    /// Replaces a legacy profile locator with the stable profile identity read
    /// from its on-disk marker. This is intentionally idempotent.
    func updateProfileIdentity(id: UUID, profileID: UUID) throws {
        var currentAccounts = accounts
        guard let index = currentAccounts.firstIndex(where: { $0.id == id }) else {
            throw ProfileManagerError.accountNotFound
        }
        guard !currentAccounts.contains(where: { $0.id != id && $0.profileID == profileID }) else {
            throw ProfileManagerError.profileDirectoryAlreadyAssigned
        }
        currentAccounts[index] = AccountProfile(
            id: currentAccounts[index].id,
            name: currentAccounts[index].name,
            profileID: profileID,
            directoryName: currentAccounts[index].directoryName,
            lastKnownPath: currentAccounts[index].lastKnownPath,
            bookmarkData: currentAccounts[index].bookmarkData,
            isFavorite: currentAccounts[index].isFavorite,
            showsInMenuBar: currentAccounts[index].showsInMenuBar
        )
        try saveAccounts(currentAccounts)
    }

    func setAccountMenuBarVisibility(id: UUID, isVisible: Bool) throws {
        var currentAccounts = accounts
        guard let index = currentAccounts.firstIndex(where: { $0.id == id }) else {
            throw ProfileManagerError.accountNotFound
        }
        currentAccounts[index].showsInMenuBar = isVisible
        try saveAccounts(currentAccounts)
    }

    func setAccountFavorite(id: UUID, isFavorite: Bool) throws {
        var currentAccounts = accounts
        guard let index = currentAccounts.firstIndex(where: { $0.id == id }) else {
            throw ProfileManagerError.accountNotFound
        }
        currentAccounts[index].isFavorite = isFavorite
        try saveAccounts(currentAccounts)
    }

    func renameAccount(id: UUID, to name: String) throws {
        let normalizedName = try validatedName(name)
        var currentAccounts = accounts

        guard let index = currentAccounts.firstIndex(where: { $0.id == id }) else {
            throw ProfileManagerError.accountNotFound
        }
        guard !containsName(normalizedName, in: currentAccounts, excluding: id) else {
            throw ProfileManagerError.duplicateAccountName
        }

        currentAccounts[index].name = normalizedName
        try saveAccounts(currentAccounts)
    }

    @discardableResult
    func removeAccount(id: UUID) throws -> AccountProfile {
        guard let account = account(id: id) else {
            throw ProfileManagerError.accountNotFound
        }
        if existingEnvironmentAccountID == id {
            throw ProfileManagerError.linkedAccountCannotBeDeleted
        }

        var currentAccounts = accounts
        currentAccounts.removeAll(where: { $0.id == id })
        try saveAccounts(currentAccounts)

        if lastLaunchedAccountID == id {
            defaults.removeObject(forKey: lastLaunchedAccountIDKey)
        }
        removeRunningProfileInstance(accountID: id)

        return account
    }

    func moveAccount(id: UUID, toInsertionIndex insertionIndex: Int) throws {
        var currentAccounts = accounts
        guard let sourceIndex = currentAccounts.firstIndex(where: { $0.id == id }) else {
            throw ProfileManagerError.accountNotFound
        }

        var destinationIndex = min(max(0, insertionIndex), currentAccounts.count)
        if sourceIndex < destinationIndex {
            destinationIndex -= 1
        }

        let account = currentAccounts.remove(at: sourceIndex)
        destinationIndex = min(destinationIndex, currentAccounts.count)
        currentAccounts.insert(account, at: destinationIndex)
        try saveAccounts(currentAccounts)
    }

    func setLastLaunchedAccount(_ account: AccountProfile) {
        defaults.set(account.id.uuidString, forKey: lastLaunchedAccountIDKey)
    }

    private func validatedName(_ name: String) throws -> String {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 60 else {
            throw ProfileManagerError.invalidAccountName
        }
        return normalized
    }

    private func validateProfileDirectoryName(_ directoryName: String) throws -> String {
        let normalized = directoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !normalized.isEmpty,
            normalized.count <= 120,
            normalized != ".",
            normalized != "..",
            !normalized.contains("/"),
            !normalized.contains("\\")
        else {
            throw ProfileManagerError.invalidProfileDirectory
        }
        return normalized
    }

    private func containsName(
        _ name: String,
        in accounts: [AccountProfile],
        excluding excludedID: UUID? = nil
    ) -> Bool {
        accounts.contains { account in
            account.id != excludedID
                && account.name.compare(name, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame
        }
    }

    private func containsDirectoryName(
        _ directoryName: String,
        in accounts: [AccountProfile]
    ) -> Bool {
        accounts.contains { account in
            account.directoryName.compare(
                directoryName,
                options: [.caseInsensitive, .widthInsensitive]
            ) == .orderedSame
        }
    }

    private func uuid(forKey key: String) -> UUID? {
        guard let rawValue = defaults.string(forKey: key) else {
            return nil
        }
        return UUID(uuidString: rawValue)
    }

    private func saveAccounts(_ accounts: [AccountProfile]) throws {
        if let currentData = defaults.data(forKey: accountsKey),
           (try? JSONDecoder().decode([AccountProfile].self, from: currentData)) != nil {
            defaults.set(currentData, forKey: accountsBackupKey)
        }
        let data = try JSONEncoder().encode(accounts)
        defaults.set(data, forKey: accountsKey)
    }

    private var validBackupData: Data? {
        guard
            let data = defaults.data(forKey: accountsBackupKey),
            (try? JSONDecoder().decode([AccountProfile].self, from: data)) != nil
        else {
            return nil
        }
        return data
    }

    private var runningProfileInstances: [RunningProfileInstance] {
        guard
            let data = defaults.data(forKey: runningProfileInstancesKey),
            let instances = try? JSONDecoder().decode(
                [RunningProfileInstance].self,
                from: data
            )
        else {
            return []
        }
        return instances
    }

    private func saveRunningProfileInstances(_ instances: [RunningProfileInstance]) {
        guard let data = try? JSONEncoder().encode(instances) else {
            return
        }
        defaults.set(data, forKey: runningProfileInstancesKey)
    }

    private func migrateLegacyStateIfNeeded() {
        guard defaults.object(forKey: accountsKey) == nil else {
            return
        }
        guard
            let existingLegacyProfile = defaults.string(
                forKey: legacyExistingEnvironmentProfileKey
            ),
            ["personal", "work"].contains(existingLegacyProfile)
        else {
            return
        }

        let firstAccount = AccountProfile(
            name: L10n.text("account.legacy-first-name", fallback: "アカウント1"),
            directoryName: "personal"
        )
        let secondAccount = AccountProfile(
            name: L10n.text("account.legacy-second-name", fallback: "アカウント2"),
            directoryName: "work"
        )
        let migratedAccounts = [firstAccount, secondAccount]

        guard let data = try? JSONEncoder().encode(migratedAccounts) else {
            return
        }
        defaults.set(data, forKey: accountsKey)
        defaults.set(data, forKey: accountsBackupKey)

        let existingAccount = existingLegacyProfile == "personal"
            ? firstAccount
            : secondAccount
        defaults.set(existingAccount.id.uuidString, forKey: existingEnvironmentAccountIDKey)

        if let lastLegacyProfile = defaults.string(forKey: legacyLastLaunchedProfileKey) {
            let lastAccount: AccountProfile?
            switch lastLegacyProfile {
            case "personal":
                lastAccount = firstAccount
            case "work":
                lastAccount = secondAccount
            default:
                lastAccount = nil
            }
            if let lastAccount {
                defaults.set(lastAccount.id.uuidString, forKey: lastLaunchedAccountIDKey)
            }
        }

        defaults.removeObject(forKey: legacyExistingEnvironmentProfileKey)
        defaults.removeObject(forKey: legacyLastLaunchedProfileKey)
    }
}
