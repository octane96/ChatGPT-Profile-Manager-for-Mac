import AppKit
import Foundation

@MainActor
final class CodexLauncher {
    static let codexBundleIdentifier = "com.openai.codex"

    private let fileManager: FileManager
    private let workspace: NSWorkspace
    private let stateStore: ProfileStateStore
    private let quitTimeoutNanoseconds: UInt64
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
        quitTimeoutNanoseconds: UInt64 = 10_000_000_000,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.workspace = workspace
        self.stateStore = stateStore
        self.quitTimeoutNanoseconds = quitTimeoutNanoseconds
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

        let name = existingEnvironmentEmail ?? "既存のChatGPT環境"
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
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.codexBundleIdentifier
        ).isEmpty
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
        guard !isCodexRunning else {
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

    func switchTo(accountID: UUID) async throws {
        guard let account = stateStore.account(id: accountID) else {
            throw ProfileManagerError.accountNotFound
        }
        guard let appURL = locateCodexApp() else {
            throw ProfileManagerError.codexAppNotFound
        }

        try await terminateRunningCodexInstances()

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

        try await launchCodex(appURL: appURL, mode: launchMode)
        stateStore.setLastLaunchedAccount(account)
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

    private func terminateRunningCodexInstances() async throws {
        let runningApps = NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.codexBundleIdentifier
        )

        guard !runningApps.isEmpty else {
            return
        }

        for app in runningApps where !app.isTerminated {
            _ = app.terminate()
        }

        let pollInterval: UInt64 = 100_000_000
        var waited: UInt64 = 0
        while runningApps.contains(where: { !$0.isTerminated }) {
            guard waited < quitTimeoutNanoseconds else {
                throw ProfileManagerError.codexDidNotQuit
            }
            try await Task.sleep(nanoseconds: pollInterval)
            waited += pollInterval
        }
    }

    private func launchCodex(appURL: URL, mode: ProfileLaunchMode) async throws {
        let spec = CodexLaunchSpec(appURL: appURL, mode: mode)
        let process = Process()
        process.executableURL = spec.executableURL
        process.arguments = spec.arguments

        let status = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { completedProcess in
                continuation.resume(returning: completedProcess.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }

        guard status == 0 else {
            throw ProfileManagerError.launchFailed(status)
        }
    }
}
