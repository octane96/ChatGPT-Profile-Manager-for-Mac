import Foundation
import XCTest
@testable import CodexAccountSwitcher

final class CodexAccountSwitcherTests: XCTestCase {
    func testProfilePathsAreIsolatedForAnyNumberOfAccounts() {
        let base = URL(fileURLWithPath: "/tmp/switcher-test", isDirectory: true)
        let first = AccountProfile(name: "メイン", directoryName: "account-one")
        let second = AccountProfile(name: "開発", directoryName: "account-two")
        let firstPaths = ProfilePaths(profile: first, baseDirectory: base)
        let secondPaths = ProfilePaths(profile: second, baseDirectory: base)

        XCTAssertNotEqual(firstPaths.root, secondPaths.root)
        XCTAssertTrue(firstPaths.codexHome.path.hasSuffix("/Profiles/account-one/CodexHome"))
        XCTAssertTrue(
            secondPaths.electronUserData.path.hasSuffix(
                "/Profiles/account-two/ElectronUserData"
            )
        )
    }

    func testIsolatedLaunchSpecIncludesBothIsolationPaths() {
        let base = URL(fileURLWithPath: "/tmp/switcher test", isDirectory: true)
        let account = AccountProfile(name: "開発")
        let paths = ProfilePaths(profile: account, baseDirectory: base)
        let appURL = URL(fileURLWithPath: "/Applications/Codex.app")
        let spec = CodexLaunchSpec(appURL: appURL, mode: .isolated(paths))

        XCTAssertEqual(spec.executableURL.path, "/usr/bin/open")
        XCTAssertTrue(spec.arguments.contains("CODEX_HOME=\(paths.codexHome.path)"))
        XCTAssertTrue(
            spec.arguments.contains(
                "CODEX_ELECTRON_USER_DATA_PATH=\(paths.electronUserData.path)"
            )
        )
        XCTAssertTrue(
            spec.arguments.contains("--user-data-dir=\(paths.electronUserData.path)")
        )
    }

    func testExistingEnvironmentLaunchSpecUsesDefaultAppProfile() {
        let appURL = URL(fileURLWithPath: "/Applications/Codex.app")
        let spec = CodexLaunchSpec(appURL: appURL, mode: .existingDefault)

        XCTAssertEqual(spec.executableURL.path, "/usr/bin/open")
        XCTAssertEqual(spec.arguments, ["-n", appURL.path])
        XCTAssertFalse(spec.arguments.contains(where: { $0.contains("CODEX_HOME") }))
        XCTAssertFalse(spec.arguments.contains(where: { $0.contains("user-data-dir") }))
    }

    func testCreateDirectoriesBuildsPrivateProfileLayout() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let account = AccountProfile(name: "プロジェクトA")
        let paths = ProfilePaths(profile: account, baseDirectory: temporaryRoot)
        try paths.createDirectories()

        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.root.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.codexHome.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.electronUserData.path))
    }

    func testLegacyApplicationSupportDirectoryMovesToNewAppName() throws {
        let fileManager = FileManager.default
        let applicationSupport = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: applicationSupport) }

        let legacyDirectory = applicationSupport
            .appendingPathComponent("Codex Account Switcher", isDirectory: true)
        let legacyProfile = legacyDirectory
            .appendingPathComponent("Profiles/account-one/CodexHome", isDirectory: true)
        try fileManager.createDirectory(at: legacyProfile, withIntermediateDirectories: true)

        let migratedDirectory = try SwitcherLocations.applicationSupportDirectory(
            fileManager: fileManager,
            baseDirectory: applicationSupport
        )

        XCTAssertEqual(migratedDirectory.lastPathComponent, "ChatGPT Profile Manager")
        XCTAssertFalse(fileManager.fileExists(atPath: legacyDirectory.path))
        XCTAssertTrue(
            fileManager.fileExists(
                atPath: migratedDirectory
                    .appendingPathComponent("Profiles/account-one/CodexHome")
                    .path
            )
        )
    }

    func testLegacyDirectoryMergesWithoutOverwritingExistingData() throws {
        let fileManager = FileManager.default
        let applicationSupport = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: applicationSupport) }

        let legacyDirectory = applicationSupport
            .appendingPathComponent("Codex Account Switcher", isDirectory: true)
        let currentDirectory = applicationSupport
            .appendingPathComponent("ChatGPT Profile Manager", isDirectory: true)
        let legacyOnlyFile = legacyDirectory.appendingPathComponent("legacy.txt")
        let legacySharedFile = legacyDirectory
            .appendingPathComponent("Profiles/shared/state.txt")
        let currentSharedFile = currentDirectory
            .appendingPathComponent("Profiles/shared/state.txt")

        try fileManager.createDirectory(
            at: legacySharedFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: currentSharedFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("legacy".utf8).write(to: legacyOnlyFile)
        try Data("legacy".utf8).write(to: legacySharedFile)
        try Data("current".utf8).write(to: currentSharedFile)

        let migratedDirectory = try SwitcherLocations.applicationSupportDirectory(
            fileManager: fileManager,
            baseDirectory: applicationSupport
        )

        XCTAssertEqual(migratedDirectory, currentDirectory)
        XCTAssertEqual(
            try String(contentsOf: currentSharedFile, encoding: .utf8),
            "current"
        )
        XCTAssertTrue(
            fileManager.fileExists(
                atPath: currentDirectory.appendingPathComponent("legacy.txt").path
            )
        )
        XCTAssertTrue(fileManager.fileExists(atPath: legacySharedFile.path))
    }

    func testCanAddAnyNumberOfIsolatedAccountsWhileExistingEnvironmentIsUnassigned() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for index in 1...5 {
            try store.addAccount(
                named: "アカウント\(index)",
                linkToExistingEnvironment: false
            )
        }

        XCTAssertEqual(store.accounts.count, 5)
        XCTAssertNil(store.existingEnvironmentAccountID)
    }

    func testExistingEnvironmentCanBeAssignedOnALaterAdditionOnlyOnce() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        _ = try store.addAccount(named: "最初", linkToExistingEnvironment: false)
        _ = try store.addAccount(named: "次", linkToExistingEnvironment: false)
        let linked = try store.addAccount(named: "既存環境", linkToExistingEnvironment: true)

        XCTAssertEqual(store.existingEnvironmentAccountID, linked.id)
        XCTAssertThrowsError(
            try store.addAccount(named: "別の既存環境", linkToExistingEnvironment: true)
        ) { error in
            XCTAssertEqual(error as? SwitcherError, .existingEnvironmentAlreadyAssigned)
        }

        let isolated = try store.addAccount(
            named: "追加の分離環境",
            linkToExistingEnvironment: false
        )
        XCTAssertNotEqual(isolated.id, store.existingEnvironmentAccountID)
        XCTAssertEqual(store.accounts.count, 4)
    }

    func testAccountNamesAreTrimmedUniqueAndRenameable() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let account = try store.addAccount(
            named: "  メイン  ",
            linkToExistingEnvironment: false
        )
        XCTAssertEqual(store.account(id: account.id)?.name, "メイン")

        XCTAssertThrowsError(
            try store.addAccount(named: "メイン", linkToExistingEnvironment: false)
        ) { error in
            XCTAssertEqual(error as? SwitcherError, .duplicateAccountName)
        }
        XCTAssertThrowsError(
            try store.addAccount(named: "   ", linkToExistingEnvironment: false)
        ) { error in
            XCTAssertEqual(error as? SwitcherError, .invalidAccountName)
        }

        try store.renameAccount(id: account.id, to: "本番")
        XCTAssertEqual(store.account(id: account.id)?.name, "本番")
    }

    func testOnlyIsolatedAccountsCanBeRemovedFromTheRegistry() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let linked = try store.addAccount(named: "既存環境", linkToExistingEnvironment: true)
        let isolated = try store.addAccount(named: "分離環境", linkToExistingEnvironment: false)

        XCTAssertThrowsError(try store.removeAccount(id: linked.id)) { error in
            XCTAssertEqual(error as? SwitcherError, .linkedAccountCannotBeDeleted)
        }
        XCTAssertEqual(try store.removeAccount(id: isolated.id), isolated)
        XCTAssertEqual(store.accounts, [linked])
        XCTAssertEqual(store.existingEnvironmentAccountID, linked.id)
    }

    func testAccountsCanBeReorderedAndOrderPersists() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = try store.addAccount(named: "1番目", linkToExistingEnvironment: true)
        let second = try store.addAccount(named: "2番目", linkToExistingEnvironment: false)
        let third = try store.addAccount(named: "3番目", linkToExistingEnvironment: false)
        store.setLastLaunchedAccount(second)

        try store.moveAccount(id: third.id, toInsertionIndex: 0)

        XCTAssertEqual(store.accounts.map(\.id), [third.id, first.id, second.id])
        XCTAssertEqual(store.existingEnvironmentAccountID, first.id)
        XCTAssertEqual(store.lastLaunchedAccountID, second.id)

        let reloadedStore = ProfileStateStore(defaults: defaults)
        XCTAssertEqual(reloadedStore.accounts.map(\.id), [third.id, first.id, second.id])

        try reloadedStore.moveAccount(id: third.id, toInsertionIndex: 3)
        XCTAssertEqual(reloadedStore.accounts.map(\.id), [first.id, second.id, third.id])
    }

    func testLaunchHistoryAndRecoveryPreserveIsolatedAccounts() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let isolated = try store.addAccount(
            named: "分離環境",
            linkToExistingEnvironment: false
        )
        let linked = try store.addAccount(
            named: "既存環境",
            linkToExistingEnvironment: true
        )
        store.setLastLaunchedAccount(linked)

        XCTAssertTrue(store.hasUsedSwitcherSinceSetup)
        let removed = try store.removeExistingEnvironmentAccount()

        XCTAssertEqual(removed?.id, linked.id)
        XCTAssertNil(store.existingEnvironmentAccountID)
        XCTAssertNil(store.lastLaunchedAccountID)
        XCTAssertEqual(store.accounts, [isolated])
        XCTAssertFalse(store.hasUsedSwitcherSinceSetup)
    }

    func testLaunchingAnIsolatedAccountBeforeAssignmentDoesNotLockRecoveryState() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let isolated = try store.addAccount(
            named: "先に使う分離環境",
            linkToExistingEnvironment: false
        )
        store.setLastLaunchedAccount(isolated)
        XCTAssertFalse(store.hasUsedSwitcherSinceSetup)

        _ = try store.addAccount(named: "既存環境", linkToExistingEnvironment: true)
        XCTAssertFalse(store.hasUsedSwitcherSinceSetup)
    }

    func testLegacyPersonalAndWorkProfilesMigrateWithoutChangingDirectories() throws {
        let suiteName = "CodexAccountSwitcherTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("work", forKey: "existingEnvironmentProfile")
        defaults.set("personal", forKey: "lastLaunchedProfile")
        defaults.set(true, forKey: "hasUsedSwitcherSinceSetup")

        let store = ProfileStateStore(defaults: defaults)
        let accounts = store.accounts
        let first = try XCTUnwrap(accounts.first(where: { $0.directoryName == "personal" }))
        let second = try XCTUnwrap(accounts.first(where: { $0.directoryName == "work" }))

        XCTAssertEqual(accounts.map(\.name), ["アカウント1", "アカウント2"])
        XCTAssertEqual(store.existingEnvironmentAccountID, second.id)
        XCTAssertEqual(store.lastLaunchedAccountID, first.id)
        XCTAssertTrue(store.hasUsedSwitcherSinceSetup)
        XCTAssertNil(defaults.string(forKey: "existingEnvironmentProfile"))
        XCTAssertNil(defaults.string(forKey: "lastLaunchedProfile"))

        let reloadedStore = ProfileStateStore(defaults: defaults)
        XCTAssertEqual(reloadedStore.accounts, accounts)
    }

    private func makeStore() throws -> (ProfileStateStore, UserDefaults, String) {
        let suiteName = "CodexAccountSwitcherTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (ProfileStateStore(defaults: defaults), defaults, suiteName)
    }
}
