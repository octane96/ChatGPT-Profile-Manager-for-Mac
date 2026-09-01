import Foundation

struct ProfileStateStore {
    private let defaults: UserDefaults

    private let accountsKey = "accountsV2"
    private let lastLaunchedAccountIDKey = "lastLaunchedAccountID"
    private let existingEnvironmentAccountIDKey = "existingEnvironmentAccountID"
    private let hasUsedSwitcherSinceSetupKey = "hasUsedSwitcherSinceSetup"

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

    var lastLaunchedAccountID: UUID? {
        uuid(forKey: lastLaunchedAccountIDKey)
    }

    var existingEnvironmentAccountID: UUID? {
        uuid(forKey: existingEnvironmentAccountIDKey)
    }

    var hasUsedSwitcherSinceSetup: Bool {
        guard existingEnvironmentAccountID != nil else {
            return false
        }

        if defaults.object(forKey: hasUsedSwitcherSinceSetupKey) != nil {
            return defaults.bool(forKey: hasUsedSwitcherSinceSetupKey)
        }

        return lastLaunchedAccountID != nil
    }

    func account(id: UUID) -> AccountProfile? {
        accounts.first(where: { $0.id == id })
    }

    func validateNewAccountName(_ name: String) throws -> String {
        let normalizedName = try validatedName(name)
        guard !containsName(normalizedName, in: accounts) else {
            throw SwitcherError.duplicateAccountName
        }
        return normalizedName
    }

    @discardableResult
    func addAccount(named name: String, linkToExistingEnvironment: Bool) throws -> AccountProfile {
        let normalizedName = try validateNewAccountName(name)
        var currentAccounts = accounts

        if linkToExistingEnvironment, existingEnvironmentAccountID != nil {
            throw SwitcherError.existingEnvironmentAlreadyAssigned
        }

        let account = AccountProfile(name: normalizedName)
        currentAccounts.append(account)
        try saveAccounts(currentAccounts)

        if linkToExistingEnvironment {
            defaults.set(account.id.uuidString, forKey: existingEnvironmentAccountIDKey)
            defaults.set(false, forKey: hasUsedSwitcherSinceSetupKey)
        }

        return account
    }

    func renameAccount(id: UUID, to name: String) throws {
        let normalizedName = try validatedName(name)
        var currentAccounts = accounts

        guard let index = currentAccounts.firstIndex(where: { $0.id == id }) else {
            throw SwitcherError.accountNotFound
        }
        guard !containsName(normalizedName, in: currentAccounts, excluding: id) else {
            throw SwitcherError.duplicateAccountName
        }

        currentAccounts[index].name = normalizedName
        try saveAccounts(currentAccounts)
    }

    @discardableResult
    func removeAccount(id: UUID) throws -> AccountProfile {
        guard let account = account(id: id) else {
            throw SwitcherError.accountNotFound
        }
        if existingEnvironmentAccountID == id {
            throw SwitcherError.linkedAccountCannotBeDeleted
        }

        var currentAccounts = accounts
        currentAccounts.removeAll(where: { $0.id == id })
        try saveAccounts(currentAccounts)

        if lastLaunchedAccountID == id {
            defaults.removeObject(forKey: lastLaunchedAccountIDKey)
        }

        return account
    }

    func moveAccount(id: UUID, toInsertionIndex insertionIndex: Int) throws {
        var currentAccounts = accounts
        guard let sourceIndex = currentAccounts.firstIndex(where: { $0.id == id }) else {
            throw SwitcherError.accountNotFound
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
        if existingEnvironmentAccountID != nil {
            defaults.set(true, forKey: hasUsedSwitcherSinceSetupKey)
        }
    }

    @discardableResult
    func removeExistingEnvironmentAccount() throws -> AccountProfile? {
        guard let existingID = existingEnvironmentAccountID else {
            return nil
        }

        var currentAccounts = accounts
        let removedAccount = currentAccounts.first(where: { $0.id == existingID })
        currentAccounts.removeAll(where: { $0.id == existingID })
        try saveAccounts(currentAccounts)

        defaults.removeObject(forKey: existingEnvironmentAccountIDKey)
        defaults.set(false, forKey: hasUsedSwitcherSinceSetupKey)
        if lastLaunchedAccountID == existingID {
            defaults.removeObject(forKey: lastLaunchedAccountIDKey)
        }

        return removedAccount
    }

    private func validatedName(_ name: String) throws -> String {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 60 else {
            throw SwitcherError.invalidAccountName
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

    private func uuid(forKey key: String) -> UUID? {
        guard let rawValue = defaults.string(forKey: key) else {
            return nil
        }
        return UUID(uuidString: rawValue)
    }

    private func saveAccounts(_ accounts: [AccountProfile]) throws {
        let data = try JSONEncoder().encode(accounts)
        defaults.set(data, forKey: accountsKey)
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

        let firstAccount = AccountProfile(name: "アカウント1", directoryName: "personal")
        let secondAccount = AccountProfile(name: "アカウント2", directoryName: "work")
        let migratedAccounts = [firstAccount, secondAccount]

        guard let data = try? JSONEncoder().encode(migratedAccounts) else {
            return
        }
        defaults.set(data, forKey: accountsKey)

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
