import AppKit
import Foundation

@MainActor
final class CodexLauncher {
    static let codexBundleIdentifier = "com.openai.codex"

    private let fileManager: FileManager
    private let workspace: NSWorkspace
    private let stateStore: ProfileStateStore
    private let quitTimeoutNanoseconds: UInt64

    init(
        fileManager: FileManager = .default,
        workspace: NSWorkspace = .shared,
        stateStore: ProfileStateStore = ProfileStateStore(),
        quitTimeoutNanoseconds: UInt64 = 10_000_000_000
    ) {
        self.fileManager = fileManager
        self.workspace = workspace
        self.stateStore = stateStore
        self.quitTimeoutNanoseconds = quitTimeoutNanoseconds
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

    var hasUsedSwitcherSinceSetup: Bool {
        stateStore.hasUsedSwitcherSinceSetup
    }

    var isCodexRunning: Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: Self.codexBundleIdentifier
        ).isEmpty
    }

    @discardableResult
    func addAccount(named name: String, linkToExistingEnvironment: Bool) throws -> AccountProfile {
        try stateStore.addAccount(
            named: name,
            linkToExistingEnvironment: linkToExistingEnvironment
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

    func deleteIsolatedAccount(id: UUID) throws -> AccountProfile {
        guard let account = stateStore.account(id: id) else {
            throw SwitcherError.accountNotFound
        }
        if stateStore.existingEnvironmentAccountID == id {
            throw SwitcherError.linkedAccountCannotBeDeleted
        }
        guard !isCodexRunning else {
            throw SwitcherError.codexMustBeClosed
        }

        let paths = ProfilePaths(
            profile: account,
            baseDirectory: try profileBaseDirectory()
        )
        if fileManager.fileExists(atPath: paths.root.path) {
            var trashedURL: NSURL?
            try fileManager.trashItem(at: paths.root, resultingItemURL: &trashedURL)
        }

        return try stateStore.removeAccount(id: id)
    }

    func removeExistingEnvironmentAssignment() throws {
        guard !isCodexRunning else {
            throw SwitcherError.codexMustBeClosed
        }
        try stateStore.removeExistingEnvironmentAccount()
    }

    func profileBaseDirectory() throws -> URL {
        try SwitcherLocations.applicationSupportDirectory(fileManager: fileManager)
    }

    func switchTo(accountID: UUID) async throws {
        guard let account = stateStore.account(id: accountID) else {
            throw SwitcherError.accountNotFound
        }
        guard let appURL = locateCodexApp() else {
            throw SwitcherError.codexAppNotFound
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
                throw SwitcherError.codexDidNotQuit
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
            throw SwitcherError.launchFailed(status)
        }
    }
}
