import Foundation
import XCTest
@testable import ChatGPTProfileManager

final class ChatGPTProfileManagerTests: XCTestCase {
    func testLanguageResolutionUsesJapaneseOnlyWhenItIsThePrimaryMacLanguage() {
        XCTAssertEqual(
            AppLanguage.resolve(preferredLanguages: ["ja-JP", "en-US"]),
            .japanese
        )
        XCTAssertEqual(
            AppLanguage.resolve(preferredLanguages: ["JA_jp"]),
            .japanese
        )
        XCTAssertEqual(
            AppLanguage.resolve(preferredLanguages: ["en-US", "ja-JP"]),
            .english
        )
        XCTAssertEqual(
            AppLanguage.resolve(preferredLanguages: ["fr-FR", "ja-JP"]),
            .english
        )
        XCTAssertEqual(
            AppLanguage.resolve(preferredLanguages: []),
            .english
        )
    }

    func testLanguagePreferenceDefaultsToAutomaticAndSupportsOverrides() throws {
        let suiteName = "ChatGPTProfileManagerLanguageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AppLanguagePreference.saved(in: defaults), .automatic)
        XCTAssertEqual(
            AppLanguagePreference.automatic.resolve(preferredLanguages: ["ja-JP"]),
            .japanese
        )
        XCTAssertEqual(
            AppLanguagePreference.automatic.resolve(preferredLanguages: ["de-DE"]),
            .english
        )
        XCTAssertEqual(
            AppLanguagePreference.japanese.resolve(preferredLanguages: ["en-US"]),
            .japanese
        )
        XCTAssertEqual(
            AppLanguagePreference.english.resolve(preferredLanguages: ["ja-JP"]),
            .english
        )

        AppLanguagePreference.english.save(in: defaults)
        XCTAssertEqual(AppLanguagePreference.saved(in: defaults), .english)
    }

    func testNewDirectoryNameIncludesReadableNameAndStableSuffix() {
        let id = UUID(uuidString: "48008583-e670-4656-979e-50ea198b9093")!
        let account = AccountProfile(id: id, name: "開発 チーム")

        XCTAssertTrue(account.directoryName.hasPrefix("account-"))
        XCTAssertTrue(account.directoryName.contains("開発-チーム"))
        XCTAssertTrue(account.directoryName.hasSuffix("-48008583"))
    }

    func testProfilePathsAreIsolatedForAnyNumberOfAccounts() {
        let base = URL(fileURLWithPath: "/tmp/profile-manager-test", isDirectory: true)
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
        let base = URL(fileURLWithPath: "/tmp/profile manager test", isDirectory: true)
        let account = AccountProfile(name: "開発")
        let paths = ProfilePaths(profile: account, baseDirectory: base)
        let appURL = URL(fileURLWithPath: "/Applications/Codex.app")
        let spec = CodexLaunchSpec(appURL: appURL, mode: .isolated(paths))

        XCTAssertEqual(spec.applicationURL, appURL)
        XCTAssertEqual(spec.environment["CODEX_HOME"], paths.codexHome.path)
        XCTAssertEqual(
            spec.environment["CODEX_ELECTRON_USER_DATA_PATH"],
            paths.electronUserData.path
        )
        XCTAssertTrue(
            spec.arguments.contains("--user-data-dir=\(paths.electronUserData.path)")
        )
    }

    func testAccountUsageSnapshotParsesFiveHourAndWeeklyWindows() throws {
        let response = Data(
            #"""
            {
              "id": 2,
              "result": {
                "rateLimits": {
                  "primary": {
                    "usedPercent": 15,
                    "windowDurationMins": 300,
                    "resetsAt": 1788387253
                  },
                  "secondary": {
                    "usedPercent": 33,
                    "windowDurationMins": 10080,
                    "resetsAt": 1788755352
                  },
                  "planType": "plus"
                },
                "rateLimitResetCredits": {
                  "availableCount": 2,
                  "credits": [
                    { "expiresAt": 1789000000 },
                    { "expiresAt": 1789100000 }
                  ]
                }
              }
            }
            """#.utf8
        )

        let snapshot = try XCTUnwrap(AccountUsageSnapshot(jsonData: response))

        XCTAssertEqual(snapshot.primary?.usedPercent, 15)
        XCTAssertEqual(snapshot.primary?.remainingPercent, 85)
        XCTAssertEqual(snapshot.primary?.windowDurationMinutes, 300)
        XCTAssertEqual(snapshot.secondary?.usedPercent, 33)
        XCTAssertEqual(snapshot.secondary?.remainingPercent, 67)
        XCTAssertEqual(snapshot.secondary?.windowDurationMinutes, 10080)
        XCTAssertEqual(snapshot.planType, "plus")
        XCTAssertEqual(snapshot.displayPlanName, "Plus")
        XCTAssertEqual(snapshot.rateLimitResetCredits?.availableCount, 2)
        XCTAssertEqual(snapshot.rateLimitResetCredits?.credits?.count, 2)
        XCTAssertEqual(
            snapshot.rateLimitResetCredits?.credits?.first?.expiresAt,
            Date(timeIntervalSince1970: 1789000000)
        )
        XCTAssertEqual(
            snapshot.primary?.resetsAt,
            Date(timeIntervalSince1970: 1788387253)
        )
        XCTAssertEqual(
            snapshot.secondary?.resetsAt,
            Date(timeIntervalSince1970: 1788755352)
        )
    }

    func testAccountUsageSnapshotUsesCodexLimitFromMultipleLimitResponse() throws {
        let response = Data(
            #"""
            {
              "result": {
                "rateLimitsByLimitId": {
                  "other": { "primary": { "usedPercent": 90 } },
                  "codex": {
                    "primary": { "usedPercent": 4 },
                    "secondary": { "usedPercent": 8 },
                    "planType": "pro"
                  }
                }
              }
            }
            """#.utf8
        )

        let snapshot = try XCTUnwrap(AccountUsageSnapshot(jsonData: response))

        XCTAssertEqual(snapshot.primary?.remainingPercent, 96)
        XCTAssertEqual(snapshot.secondary?.remainingPercent, 92)
        XCTAssertEqual(snapshot.displayPlanName, "Pro")
    }

    func testExistingEnvironmentLaunchSpecUsesDefaultAppProfile() {
        let appURL = URL(fileURLWithPath: "/Applications/Codex.app")
        let spec = CodexLaunchSpec(appURL: appURL, mode: .existingDefault)

        XCTAssertEqual(spec.applicationURL, appURL)
        XCTAssertEqual(spec.environment, [:])
        XCTAssertEqual(spec.arguments, [])
        XCTAssertFalse(spec.arguments.contains(where: { $0.contains("user-data-dir") }))
    }

    func testRunningProfileRegistryPrunesExitedProcessesAndPreventsDuplicates() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = try store.addAccount(
            named: "分離プロファイル1",
            linkToExistingEnvironment: false
        )
        let second = try store.addAccount(
            named: "分離プロファイル2",
            linkToExistingEnvironment: false
        )

        store.setRunningProfileInstance(accountID: first.id, processIdentifier: 101)
        store.setRunningProfileInstance(accountID: first.id, processIdentifier: 102)
        store.setRunningProfileInstance(accountID: second.id, processIdentifier: 202)

        XCTAssertEqual(
            store.activeRunningProfileInstances(processIdentifiers: [102, 202]),
            [first.id: 102, second.id: 202]
        )
        XCTAssertEqual(
            store.activeRunningProfileInstances(processIdentifiers: [202]),
            [second.id: 202]
        )
    }

    func testUnknownChatGPTInstanceIsTreatedAsExistingEnvironment() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let existing = try store.addAccount(
            named: "既存環境",
            linkToExistingEnvironment: true
        )
        let isolated = try store.addAccount(
            named: "分離環境",
            linkToExistingEnvironment: false
        )
        store.setRunningProfileInstance(accountID: isolated.id, processIdentifier: 202)

        XCTAssertEqual(
            store.runningAccountIDs(processIdentifiers: [202]),
            [isolated.id]
        )
        XCTAssertEqual(
            store.runningAccountIDs(processIdentifiers: [101, 202]),
            [existing.id, isolated.id]
        )
        XCTAssertEqual(
            store.runningProcessIdentifier(
                for: existing.id,
                processIdentifiers: [101, 202]
            ),
            101
        )
        XCTAssertEqual(
            store.runningProcessIdentifier(
                for: isolated.id,
                processIdentifiers: [101, 202]
            ),
            202
        )
    }

    func testExistingEnvironmentQuitTargetRequiresOneUnassignedProcess() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let existing = try store.addAccount(
            named: "既存環境",
            linkToExistingEnvironment: true
        )

        XCTAssertNil(
            store.runningProcessIdentifier(
                for: existing.id,
                processIdentifiers: [101, 102]
            )
        )
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

    func testCanRegisterAnExistingProfileDirectoryOnce() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let account = try store.addAccount(
            named: "既存プロファイル",
            linkToExistingEnvironment: false,
            directoryName: "account-old-profile"
        )

        XCTAssertEqual(account.directoryName, "account-old-profile")
        XCTAssertThrowsError(
            try store.addAccount(
                named: "同じ保存先",
                linkToExistingEnvironment: false,
                directoryName: "ACCOUNT-OLD-PROFILE"
            )
        ) { error in
            XCTAssertEqual(error as? ProfileManagerError, .profileDirectoryAlreadyAssigned)
        }
    }

    func testInvalidProfileDirectoryNamesAreRejected() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertThrowsError(
            try store.addAccount(
                named: "不正な保存先",
                linkToExistingEnvironment: false,
                directoryName: "../other"
            )
        ) { error in
            XCTAssertEqual(error as? ProfileManagerError, .invalidProfileDirectory)
        }
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
            XCTAssertEqual(error as? ProfileManagerError, .existingEnvironmentAlreadyAssigned)
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
            XCTAssertEqual(error as? ProfileManagerError, .duplicateAccountName)
        }
        XCTAssertThrowsError(
            try store.addAccount(named: "   ", linkToExistingEnvironment: false)
        ) { error in
            XCTAssertEqual(error as? ProfileManagerError, .invalidAccountName)
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
            XCTAssertEqual(error as? ProfileManagerError, .linkedAccountCannotBeDeleted)
        }
        XCTAssertEqual(try store.removeAccount(id: isolated.id), isolated)
        XCTAssertEqual(store.accounts, [linked])
        XCTAssertEqual(store.existingEnvironmentAccountID, linked.id)
    }

    func testRemovingIsolatedAccountRegistrationKeepsProfileDirectories() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: baseDirectory) }

        let account = try store.addAccount(
            named: "保持するプロファイル",
            linkToExistingEnvironment: false
        )
        let paths = ProfilePaths(profile: account, baseDirectory: baseDirectory)
        try paths.createDirectories()

        _ = try store.removeAccount(id: account.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.root.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.codexHome.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.electronUserData.path))
        XCTAssertNil(store.account(id: account.id))
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

    func testLaunchHistoryPreservesExistingAssignment() throws {
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

        XCTAssertEqual(store.accounts, [isolated, linked])
        XCTAssertEqual(store.existingEnvironmentAccountID, linked.id)
        XCTAssertEqual(store.lastLaunchedAccountID, linked.id)
    }

    @MainActor
    func testFirstLaunchRegistersExistingEnvironmentWithEmail() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let codexDirectory = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(
            at: codexDirectory,
            withIntermediateDirectories: true
        )
        let header = Data(#"{"alg":"none"}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let payload = Data(#"{"email":"first@example.com"}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let idToken = "\(header).\(payload).signature"
        let authJSON = "{\"tokens\":{\"id_token\":\"\(idToken)\"}}"
        try Data(authJSON.utf8).write(
            to: codexDirectory.appendingPathComponent("auth.json")
        )

        let launcher = CodexLauncher(
            stateStore: store,
            homeDirectory: homeDirectory
        )
        let account = try XCTUnwrap(
            launcher.registerExistingEnvironmentIfNeeded()
        )

        XCTAssertEqual(account.name, "first@example.com")
        XCTAssertEqual(launcher.existingEnvironmentAccount?.id, account.id)
        XCTAssertEqual(store.accounts, [account])
    }

    @MainActor
    func testSavedEmptyRegistryDoesNotTriggerAutomaticRegistration() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let homeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: homeDirectory) }

        let account = try store.addAccount(
            named: "登録済みアカウント",
            linkToExistingEnvironment: false
        )
        _ = try store.removeAccount(id: account.id)

        try FileManager.default.createDirectory(
            at: homeDirectory.appendingPathComponent(".codex", isDirectory: true),
            withIntermediateDirectories: true
        )

        let launcher = CodexLauncher(
            stateStore: store,
            homeDirectory: homeDirectory
        )

        XCTAssertNil(try launcher.registerExistingEnvironmentIfNeeded())
    }

    func testMechanismGuideShownStatePersists() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(store.hasShownMechanismGuide)

        store.markMechanismGuideShown()

        XCTAssertTrue(store.hasShownMechanismGuide)
        XCTAssertTrue(ProfileStateStore(defaults: defaults).hasShownMechanismGuide)
    }

    private func makeStore() throws -> (ProfileStateStore, UserDefaults, String) {
        let suiteName = "ChatGPTProfileManagerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (ProfileStateStore(defaults: defaults), defaults, suiteName)
    }
}
