import Foundation
import AppKit
import SQLite3
import XCTest
@testable import ChatGPTProfileManager

final class ChatGPTProfileManagerTests: XCTestCase {
    func testMenuBarIconIsMonochromeBrandMarkSizedForStatusItem() {
        let icon = MenuBarIcon.make()

        XCTAssertTrue(icon.isTemplate)
        XCTAssertEqual(icon.size.width, 18, accuracy: 0.01)
        XCTAssertEqual(icon.size.height, 18, accuracy: 0.01)
        XCTAssertFalse(icon.representations.isEmpty)
    }

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

    func testLegacyAccountDecodingUsesRegistrationIDAsProfileID() throws {
        let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let legacy = #"{"id":"11111111-1111-4111-8111-111111111111","name":"Legacy","directoryName":"account-legacy"}"#
        let account = try JSONDecoder().decode(AccountProfile.self, from: Data(legacy.utf8))
        XCTAssertEqual(account.id, id)
        XCTAssertEqual(account.profileID, id)
        XCTAssertNil(account.lastKnownPath)
        XCTAssertFalse(account.isFavorite)
        XCTAssertTrue(account.showsInMenuBar)
    }

    func testMenuBarPreferencesPersistWithAccountRegistry() throws {
        let suiteName = "ChatGPTProfileManagerMenuBarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var store = ProfileStateStore(defaults: defaults)
        let account = try store.addAccount(named: "Work", linkToExistingEnvironment: false)
        try store.setAccountFavorite(id: account.id, isFavorite: true)
        try store.setAccountMenuBarVisibility(id: account.id, isVisible: false)

        let saved = try XCTUnwrap(store.account(id: account.id))
        XCTAssertTrue(saved.isFavorite)
        XCTAssertFalse(saved.showsInMenuBar)

        // A newly initialized store reads the same persisted flags.
        store = ProfileStateStore(defaults: defaults)
        let reloaded = try XCTUnwrap(store.account(id: account.id))
        XCTAssertTrue(reloaded.isFavorite)
        XCTAssertFalse(reloaded.showsInMenuBar)
    }

    @MainActor
    func testMenuBarFavoriteButtonPresentationTracksToggledState() {
        let button = NSButton()

        MenuBarFavoriteButtonPresentation.update(button, isFavorite: false)
        XCTAssertEqual(
            MenuBarFavoriteButtonPresentation.symbolName(isFavorite: false),
            "star"
        )
        XCTAssertEqual(
            button.toolTip,
            L10n.text("profile.menu.favorite", fallback: "お気に入りにする")
        )

        MenuBarFavoriteButtonPresentation.update(button, isFavorite: true)
        XCTAssertEqual(
            MenuBarFavoriteButtonPresentation.symbolName(isFavorite: true),
            "star.fill"
        )
        XCTAssertEqual(
            button.toolTip,
            L10n.text("profile.menu.unfavorite", fallback: "お気に入りを解除")
        )
    }

    @MainActor
    func testApplicationStaysAliveAfterLastWindowCloses() {
        let delegate = AppDelegate()

        XCTAssertFalse(
            delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared)
        )
    }

    func testUnexpectedQuitIsSuppressedImmediatelyAfterMainWindowHides() {
        let hiddenAt = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(ApplicationTerminationPolicy.shouldSuppressUnexpectedTermination(
            explicitTerminationRequested: false,
            menuBarStatusItemEnabled: true,
            mainWindowVisible: false,
            mainWindowHiddenAt: hiddenAt,
            now: hiddenAt.addingTimeInterval(2)
        ))
        XCTAssertFalse(ApplicationTerminationPolicy.shouldSuppressUnexpectedTermination(
            explicitTerminationRequested: false,
            menuBarStatusItemEnabled: true,
            mainWindowVisible: false,
            mainWindowHiddenAt: hiddenAt,
            now: hiddenAt.addingTimeInterval(6)
        ))
    }

    func testExplicitQuitIsNeverSuppressed() {
        let hiddenAt = Date(timeIntervalSince1970: 100)

        XCTAssertFalse(ApplicationTerminationPolicy.shouldSuppressUnexpectedTermination(
            explicitTerminationRequested: true,
            menuBarStatusItemEnabled: true,
            mainWindowVisible: false,
            mainWindowHiddenAt: hiddenAt,
            now: hiddenAt.addingTimeInterval(2)
        ))
    }

    func testAboutPanelShowsMarketingVersionWithoutBuildNumber() {
        let options = ApplicationAboutPanel.options(applicationVersion: "1.1.1")

        XCTAssertEqual(options[.applicationVersion] as? String, "1.1.1")
        XCTAssertEqual(options[.version] as? String, "")
    }

    func testMenuBarUsageSummaryUsesMinimumVisibleValuesAndTwoLineLabels() throws {
        let firstID = UUID()
        let secondID = UUID()
        let first = try XCTUnwrap(AccountUsageSnapshot(
            primary: UsageWindow(usedPercent: 20, windowDurationMinutes: 300, resetsAt: nil),
            secondary: UsageWindow(usedPercent: 40, windowDurationMinutes: 10080, resetsAt: nil)
        ))
        let second = try XCTUnwrap(AccountUsageSnapshot(
            primary: UsageWindow(usedPercent: 65, windowDurationMinutes: 300, resetsAt: nil),
            secondary: UsageWindow(usedPercent: 10, windowDurationMinutes: 10080, resetsAt: nil)
        ))

        let summary = MenuBarUsageSummary.minimum(
            accountIDs: [firstID, secondID],
            snapshots: [firstID: first, secondID: second]
        )
        XCTAssertEqual(summary.fiveHour, 35)
        XCTAssertEqual(summary.weekly, 60)
        XCTAssertEqual(summary.title, "5h 35%\nW 60%")

        let unavailable = MenuBarUsageSummary.minimum(accountIDs: [UUID()], snapshots: [:])
        XCTAssertEqual(unavailable.title, "—")
    }

    func testMenuBarUsageDefaultsToCompactTextAndSupportsOptOut() throws {
        let suiteName = "ChatGPTProfileManagerMenuBarDefaultTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(MenuBarPreferences.compactUsageEnabled(in: defaults))
        defaults.set(false, forKey: MenuBarPreferences.compactUsageStatusKey)
        XCTAssertFalse(MenuBarPreferences.compactUsageEnabled(in: defaults))
    }

    func testMenuBarStatusItemVisibilityDefaultsToEnabledAndSupportsOptOut() throws {
        let suiteName = "ChatGPTProfileManagerMenuBarVisibilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(MenuBarPreferences.statusItemEnabled(in: defaults))
        defaults.set(false, forKey: MenuBarPreferences.statusItemEnabledKey)
        XCTAssertFalse(MenuBarPreferences.statusItemEnabled(in: defaults))
    }

    func testUsageRefreshMergeRetainsStaleValuesForPartialFailures() throws {
        let retainedID = UUID()
        let refreshedID = UUID()
        let removedID = UUID()
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let finishedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let oldSnapshot = try XCTUnwrap(AccountUsageSnapshot(
            primary: UsageWindow(usedPercent: 40, windowDurationMinutes: 300, resetsAt: nil),
            secondary: nil
        ))
        let refreshedSnapshot = try XCTUnwrap(AccountUsageSnapshot(
            primary: UsageWindow(usedPercent: 10, windowDurationMinutes: 300, resetsAt: nil),
            secondary: nil
        ))

        let result = UsageRefreshMerger.merge(
            previousSnapshots: [retainedID: oldSnapshot, removedID: oldSnapshot],
            previousLastUpdatedAt: [retainedID: oldDate, removedID: oldDate],
            fetchedSnapshots: [refreshedID: refreshedSnapshot],
            accountIDs: [retainedID, refreshedID],
            finishedAt: finishedAt
        )

        XCTAssertEqual(result.snapshots[retainedID], oldSnapshot)
        XCTAssertEqual(result.lastUpdatedAt[retainedID], oldDate)
        XCTAssertEqual(result.snapshots[refreshedID], refreshedSnapshot)
        XCTAssertEqual(result.lastUpdatedAt[refreshedID], finishedAt)
        XCTAssertNil(result.snapshots[removedID])
        XCTAssertNil(result.lastUpdatedAt[removedID])
    }

    func testProfileIdentityMarkerRoundTripsWithoutSensitiveFields() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profileID = UUID()
        let paths = ProfilePaths(root: root)
        try paths.ensureMarker(profileID: profileID)
        let marker = try XCTUnwrap(paths.readMarker())
        XCTAssertEqual(marker.profileID, profileID)
        XCTAssertEqual(marker.version, ProfileIdentityMarker.currentVersion)
        let text = try String(contentsOf: paths.markerURL())
        XCTAssertFalse(text.contains("token"))
        XCTAssertFalse(text.contains("cookie"))
    }

    func testInvalidOrUnsupportedMarkerIsNeverOverwritten() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProfilePaths(root: root)
        let invalid = Data("{\"version\":1,\"profileID\":\"not-a-uuid\"}".utf8)
        try invalid.write(to: paths.markerURL())
        XCTAssertEqual(paths.readMarkerState(), .invalid)
        XCTAssertThrowsError(try paths.ensureMarker(profileID: UUID())) { error in
            XCTAssertEqual(error as? ProfileManagerError, .profileMarkerMismatch)
        }
        XCTAssertEqual(try Data(contentsOf: paths.markerURL()), invalid)

        let profileID = UUID()
        let unsupported = Data("{\"version\":99,\"profileID\":\"\(profileID.uuidString)\",\"createdAt\":\"2026-01-01T00:00:00Z\"}".utf8)
        try unsupported.write(to: paths.markerURL(), options: .atomic)
        guard case .unsupported = paths.readMarkerState() else {
            return XCTFail("expected unsupported marker state")
        }
        XCTAssertThrowsError(try paths.ensureMarker(profileID: profileID)) { error in
            XCTAssertEqual(error as? ProfileManagerError, .profileMarkerMismatch)
        }
        XCTAssertEqual(try Data(contentsOf: paths.markerURL()), unsupported)
    }

    func testDiagnosticsDetectsMissingRootWithoutCreatingIt() throws {
        let managerRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: managerRoot) }
        let account = AccountProfile(name: "Missing", profileID: UUID(), directoryName: "missing")
        let report = ProfileDiagnosticsService(baseDirectory: managerRoot).diagnose(profile: account)
        XCTAssertEqual(report.status, ProfileDiagnosticStatus.missing)
        XCTAssertTrue(report.findings.contains(where: { $0.code == "root.missing" }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProfilePaths(profile: account, baseDirectory: managerRoot).root.path))
    }

    @MainActor
    func testInvalidMarkerBlocksMigrationRelocationAndExternalRegistration() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let managerRootParent = root.appendingPathComponent("support", isDirectory: true)
        let managerRoot = managerRootParent.appendingPathComponent("ChatGPT Profile Manager", isDirectory: true)
        try FileManager.default.createDirectory(at: managerRoot, withIntermediateDirectories: true)
        let suiteName = "ChatGPTProfileManagerInvalidMarker-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let stateStore = ProfileStateStore(defaults: defaults)
        let account = try stateStore.addAccount(named: "Invalid", linkToExistingEnvironment: false, directoryName: "invalid")
        let paths = ProfilePaths(profile: account, baseDirectory: managerRoot)
        try paths.createDirectories()
        let invalid = Data("{\"version\":1,\"profileID\":\"bad\"}".utf8)
        try invalid.write(to: paths.markerURL())
        let launcher = CodexLauncher(stateStore: stateStore, applicationSupportDirectory: managerRootParent)
        XCTAssertEqual(stateStore.account(id: account.id)?.profileID, account.profileID)
        XCTAssertEqual(try Data(contentsOf: paths.markerURL()), invalid)
        XCTAssertThrowsError(try launcher.updateProfileLocation(id: account.id, root: paths.root)) { error in
            XCTAssertEqual(error as? ProfileManagerError, .profileMarkerMismatch)
        }

        let external = root.appendingPathComponent("external-invalid", isDirectory: true)
        let externalPaths = ProfilePaths(root: external)
        try externalPaths.createDirectories()
        try invalid.write(to: externalPaths.markerURL())
        XCTAssertThrowsError(try launcher.registerIsolatedProfile(named: "External", root: external)) { error in
            XCTAssertEqual(error as? ProfileManagerError, .profileMarkerMismatch)
        }
        XCTAssertEqual(stateStore.accounts.count, 1)
    }

    func testDiagnosticsReadsManagerLevelSettingsRegistryAndBrokenRulesLink() throws {
        let managerRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: managerRoot) }
        let account = AccountProfile(name: "Settings", profileID: UUID(), directoryName: "settings")
        let paths = ProfilePaths(profile: account, baseDirectory: managerRoot)
        try paths.createDirectories()
        try paths.ensureMarker(profileID: account.profileID)
        let settingsStore = SettingsSharingStore(baseDirectory: managerRoot)
        var registry = SettingsRegistry()
        registry.bindings = [SettingsBinding(profile: .isolatedProfile(profileID: account.profileID), groupID: UUID(), items: [.instructions])]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(registry).write(to: settingsStore.registryURL)
        try FileManager.default.createSymbolicLink(atPath: paths.codexHome.appendingPathComponent("rules").path, withDestinationPath: "/missing/rules")

        let report = ProfileDiagnosticsService(baseDirectory: managerRoot).diagnose(profile: account)
        XCTAssertEqual(settingsStore.registryURL, managerRoot.appendingPathComponent("SettingsRegistry.json"))
        XCTAssertEqual(report.checks["settingsReference"], true)
        XCTAssertTrue(report.findings.contains(where: { $0.code == "settings.symlink-broken" }))
    }

    func testDiagnosticsRepairsOnlyUnambiguousSQLiteRolloutPathAndWritesLog() throws {
        let managerRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: managerRoot) }
        let account = AccountProfile(name: "Repair", profileID: UUID(), directoryName: "repair")
        let paths = ProfilePaths(profile: account, baseDirectory: managerRoot)
        try paths.createDirectories()
        try paths.ensureMarker(profileID: account.profileID)
        let sessionID = UUID().uuidString
        let jsonl = paths.codexHome.appendingPathComponent("rollout-1.jsonl")
        try Data(#"{"type":"session_meta","payload":{"id":"\#(sessionID)"}}"#.utf8).write(to: jsonl)
        let sqlite = paths.codexHome.appendingPathComponent("state_5.sqlite")
        try createFixtureSQLite(at: sqlite, sessionID: sessionID, rolloutPath: "/old/location/rollout-1.jsonl")
        let snapshots = managerRoot.appendingPathComponent("snapshots", isDirectory: true)
        let logs = managerRoot.appendingPathComponent("logs", isDirectory: true)
        let service = ProfileDiagnosticsService(baseDirectory: managerRoot, recoverySnapshotsDirectory: snapshots, diagnosticsLogsDirectory: logs)
        let before = service.diagnose(profile: account)
        XCTAssertTrue(before.findings.contains(where: { $0.code == "sqlite.missing-rollout" }))
        let result = try service.repairIndex(profile: account)
        XCTAssertTrue(result.success)
        XCTAssertFalse(result.rolledBack)
        XCTAssertEqual(result.updatedPathCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.snapshotDirectory.appendingPathComponent("state_5.sqlite").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.logURL.path))
        let after = service.diagnose(profile: account)
        XCTAssertFalse(after.findings.contains(where: { $0.code == "sqlite.missing-rollout" }))
        let log = try XCTUnwrap(service.readLog(at: result.logURL))
        XCTAssertEqual(log.profileID, account.profileID)
        XCTAssertEqual(log.result, "success")
    }

    func testDiagnosticsRefusesRepairWhenProfileIsMarkedRunning() throws {
        let managerRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: managerRoot) }
        let account = AccountProfile(name: "Busy", profileID: UUID(), directoryName: "busy")
        let paths = ProfilePaths(profile: account, baseDirectory: managerRoot)
        try paths.createDirectories()
        try paths.ensureMarker(profileID: account.profileID)
        try createFixtureSQLite(at: paths.codexHome.appendingPathComponent("state_5.sqlite"), sessionID: UUID().uuidString, rolloutPath: "/missing")
        let service = ProfileDiagnosticsService(baseDirectory: managerRoot, isChatGPTRunning: { true })
        XCTAssertThrowsError(try service.repairIndex(profile: account)) { error in
            XCTAssertEqual(error as? ProfileManagerError, .codexMustBeClosed)
        }
    }

    func testDiagnosticsLeavesUnknownSQLiteSchemaUnchanged() throws {
        let managerRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: managerRoot) }
        let account = AccountProfile(name: "Unknown", profileID: UUID(), directoryName: "unknown")
        let paths = ProfilePaths(profile: account, baseDirectory: managerRoot)
        try paths.createDirectories()
        try paths.ensureMarker(profileID: account.profileID)
        let sqlite = paths.codexHome.appendingPathComponent("state_99.sqlite")
        try executeSQLite(at: sqlite, sql: "CREATE TABLE not_threads(value TEXT); PRAGMA user_version = 99;")
        let service = ProfileDiagnosticsService(baseDirectory: managerRoot)
        let report = service.diagnose(profile: account)
        XCTAssertTrue(report.findings.contains(where: { $0.code == "sqlite.unknown-schema" }))
        XCTAssertThrowsError(try service.repairIndex(profile: account)) { error in
            XCTAssertEqual(error as? ProfileManagerError, .unknownProfileSchema)
        }
    }

    func testDiagnosticsRejectsFutureSqlxMigrationSchema() throws {
        let managerRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: managerRoot) }
        let account = AccountProfile(name: "Future", profileID: UUID(), directoryName: "future")
        let paths = ProfilePaths(profile: account, baseDirectory: managerRoot)
        try paths.createDirectories()
        try paths.ensureMarker(profileID: account.profileID)
        let sessionID = UUID().uuidString
        try Data(#"{"type":"session_meta","payload":{"id":"\#(sessionID)"}}"#.utf8).write(to: paths.codexHome.appendingPathComponent("future.jsonl"))
        let sqlite = paths.codexHome.appendingPathComponent("state_53.sqlite")
        try executeSQLite(at: sqlite, sql: "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT); CREATE TABLE _sqlx_migrations (version BIGINT PRIMARY KEY, success BOOLEAN NOT NULL); INSERT INTO _sqlx_migrations(version, success) VALUES (53, 1); INSERT INTO threads(id, rollout_path) VALUES ('\(sessionID)', '/old/future.jsonl'); PRAGMA user_version = 0;")
        let service = ProfileDiagnosticsService(baseDirectory: managerRoot)
        let report = service.diagnose(profile: account)
        XCTAssertTrue(report.findings.contains(where: { $0.code == "sqlite.migration-invalid" }))
        XCTAssertTrue(report.findings.contains(where: { $0.code == "sqlite.unknown-schema" }))
        XCTAssertThrowsError(try service.repairIndex(profile: account)) { error in
            XCTAssertEqual(error as? ProfileManagerError, .unknownProfileSchema)
        }
        XCTAssertEqual(try sqliteScalar(at: sqlite, sql: "SELECT rollout_path FROM threads"), "/old/future.jsonl")
    }

    func testDiagnosticsRejectsStateDatabaseWithoutSuccessfulMigration() throws {
        let managerRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: managerRoot) }
        let account = AccountProfile(name: "Empty migrations", profileID: UUID(), directoryName: "empty-migrations")
        let paths = ProfilePaths(profile: account, baseDirectory: managerRoot)
        try paths.createDirectories()
        try paths.ensureMarker(profileID: account.profileID)
        let sqlite = paths.codexHome.appendingPathComponent("state_5.sqlite")
        try executeSQLite(at: sqlite, sql: "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT); CREATE TABLE _sqlx_migrations (version BIGINT PRIMARY KEY, success BOOLEAN NOT NULL); PRAGMA user_version = 0;")

        let report = ProfileDiagnosticsService(baseDirectory: managerRoot).diagnose(profile: account)
        XCTAssertFalse(report.sqlite.first?.knownSchema ?? true)
        XCTAssertTrue(report.findings.contains(where: { $0.code == "sqlite.unknown-schema" }))
        XCTAssertThrowsError(try ProfileDiagnosticsService(baseDirectory: managerRoot).repairIndex(profile: account)) { error in
            XCTAssertEqual(error as? ProfileManagerError, .unknownProfileSchema)
        }
    }

    func testDiagnosticsDoesNotUseMalformedJSONLAsRepairCandidate() throws {
        let managerRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: managerRoot) }
        let account = AccountProfile(name: "Malformed", profileID: UUID(), directoryName: "malformed")
        let paths = ProfilePaths(profile: account, baseDirectory: managerRoot)
        try paths.createDirectories()
        try paths.ensureMarker(profileID: account.profileID)
        let sessionID = UUID().uuidString
        try Data(#"{"type":"message","payload":{"id":"\#(sessionID)"}}"#.utf8).write(to: paths.codexHome.appendingPathComponent("message.jsonl"))
        let sqlite = paths.codexHome.appendingPathComponent("state_5.sqlite")
        try createFixtureSQLite(at: sqlite, sessionID: sessionID, rolloutPath: "/old/message.jsonl")
        let service = ProfileDiagnosticsService(baseDirectory: managerRoot)
        let report = service.diagnose(profile: account)
        XCTAssertTrue(report.findings.contains(where: { $0.code == "sqlite.missing-rollout" && !$0.repairable }))
        let result = try service.repairIndex(profile: account)
        XCTAssertEqual(result.updatedPathCount, 0)
        XCTAssertEqual(try sqliteScalar(at: sqlite, sql: "SELECT rollout_path FROM threads"), "/old/message.jsonl")
    }

    func testDiagnosticsReportsStateIndexMissingWhenOnlyDerivedHistoryExists() throws {
        let managerRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: managerRoot) }
        let account = AccountProfile(name: "No State", profileID: UUID(), directoryName: "no-state")
        let paths = ProfilePaths(profile: account, baseDirectory: managerRoot)
        try paths.createDirectories()
        try paths.ensureMarker(profileID: account.profileID)
        try Data(#"{"type":"session_meta","payload":{"id":"session"}}"#.utf8).write(to: paths.codexHome.appendingPathComponent("session.jsonl"))
        try executeSQLite(at: paths.codexHome.appendingPathComponent("thread_history_1.sqlite"), sql: "CREATE TABLE history(id TEXT);")
        let report = ProfileDiagnosticsService(baseDirectory: managerRoot).diagnose(profile: account)
        XCTAssertTrue(report.findings.contains(where: { $0.code == "sqlite.state-index-missing" }))
        XCTAssertFalse(report.findings.contains(where: { $0.code == "sqlite.unknown-schema" }))
    }

    func testDiagnosticsDetectsDuplicateSessionIDsAndDoesNotGuess() throws {
        let managerRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: managerRoot) }
        let account = AccountProfile(name: "Duplicate", profileID: UUID(), directoryName: "duplicate")
        let paths = ProfilePaths(profile: account, baseDirectory: managerRoot)
        try paths.createDirectories()
        try paths.ensureMarker(profileID: account.profileID)
        let sessionID = UUID().uuidString
        for name in ["rollout-a.jsonl", "rollout-b.jsonl"] {
            try Data(#"{"type":"session_meta","payload":{"id":"\#(sessionID)"}}"#.utf8).write(to: paths.codexHome.appendingPathComponent(name))
        }
        try createFixtureSQLite(at: paths.codexHome.appendingPathComponent("state_5.sqlite"), sessionID: sessionID, rolloutPath: "/not-present")
        let report = ProfileDiagnosticsService(baseDirectory: managerRoot).diagnose(profile: account)
        XCTAssertTrue(report.findings.contains(where: { $0.code == "session.duplicate-id" }))
        XCTAssertTrue(report.findings.contains(where: { $0.code == "sqlite.ambiguous-rollout" }))
    }

    func testDiagnosticsRestoresSnapshotWhenPostCheckFails() throws {
        let managerRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: managerRoot) }
        let account = AccountProfile(name: "Rollback", profileID: UUID(), directoryName: "rollback")
        let paths = ProfilePaths(profile: account, baseDirectory: managerRoot)
        try paths.createDirectories()
        try paths.ensureMarker(profileID: account.profileID)
        let sessionID = UUID().uuidString
        try Data(#"{"type":"session_meta","payload":{"id":"\#(sessionID)"}}"#.utf8).write(to: paths.codexHome.appendingPathComponent("rollout.jsonl"))
        let sqlite = paths.codexHome.appendingPathComponent("state_5.sqlite")
        try executeSQLite(at: sqlite, sql: "CREATE TABLE parent(id TEXT PRIMARY KEY); CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, parent_id TEXT REFERENCES parent(id)); CREATE TABLE _sqlx_migrations (version BIGINT PRIMARY KEY, success BOOLEAN NOT NULL); INSERT INTO _sqlx_migrations(version, success) VALUES (52, 1); INSERT INTO threads(id, rollout_path, parent_id) VALUES ('\(sessionID)', '/old/rollout.jsonl', 'missing-parent'); PRAGMA user_version = 0;")
        let logs = managerRoot.appendingPathComponent("logs", isDirectory: true)
        let service = ProfileDiagnosticsService(baseDirectory: managerRoot, diagnosticsLogsDirectory: logs)
        XCTAssertThrowsError(try service.repairIndex(profile: account))
        XCTAssertEqual(try sqliteScalar(at: sqlite, sql: "SELECT rollout_path FROM threads"), "/old/rollout.jsonl")
        let logURL = try XCTUnwrap(service.logURLs().first)
        XCTAssertEqual(service.readLog(at: logURL)?.result, "rollback")
    }

    func testDiagnosticsExecutionStateOnlyBlocksTerminationForRepair() {
        XCTAssertFalse(ProfileDiagnosticsExecutionState.idle.blocksApplicationTermination)
        XCTAssertFalse(ProfileDiagnosticsExecutionState.diagnosing.blocksApplicationTermination)
        XCTAssertTrue(ProfileDiagnosticsExecutionState.repairing.blocksApplicationTermination)
        XCTAssertFalse(ProfileDiagnosticsExecutionState.diagnosing.continuesAfterWindowClose)
        XCTAssertTrue(ProfileDiagnosticsExecutionState.repairing.continuesAfterWindowClose)
    }

    func testStableProfileReferenceMigrationKeepsSharedMembership() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceHome = root.appendingPathComponent("source", isDirectory: true)
        let destinationHome = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationHome, withIntermediateDirectories: true)
        try Data("instructions".utf8).write(to: sourceHome.appendingPathComponent("AGENTS.md"))
        let store = SettingsSharingStore(baseDirectory: root.appendingPathComponent("manager", isDirectory: true))
        let oldSource = ProfileStorageReference.isolated(directoryName: "source")
        let oldDestination = ProfileStorageReference.isolated(directoryName: "destination")
        let group = try store.createShareGroup(name: "Legacy", source: oldSource, destinations: [oldDestination], items: [.instructions], codexHomes: [oldSource: sourceHome, oldDestination: destinationHome])
        let stableDestination = ProfileStorageReference.isolatedProfile(profileID: UUID())
        XCTAssertTrue(try store.migrateProfileReference(from: oldDestination, to: stableDestination))
        XCTAssertEqual(store.binding(for: stableDestination)?.groupID, group.id)
        XCTAssertNil(store.binding(for: oldDestination))
        XCTAssertTrue(store.group(id: group.id)?.members.contains(stableDestination) == true)
    }

    @MainActor
    func testRemovedRegistrationCanRediscoverProfileByMarker() throws {
        let managerContainer = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: managerContainer) }
        let support = managerContainer.appendingPathComponent("support", isDirectory: true)
        let managerRoot = support.appendingPathComponent("ChatGPT Profile Manager", isDirectory: true)
        let defaultsName = "ChatGPTProfileManagerRediscovery-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = ProfileStateStore(defaults: defaults)
        let account = try store.addAccount(named: "Retained", linkToExistingEnvironment: false, directoryName: "retained")
        let paths = ProfilePaths(profile: account, baseDirectory: managerRoot)
        try paths.createDirectories()
        try paths.ensureMarker(profileID: account.profileID)
        _ = try store.removeAccount(id: account.id)
        let launcher = CodexLauncher(stateStore: store, applicationSupportDirectory: support)
        let candidate = try XCTUnwrap(launcher.availableIsolatedProfiles.first)
        XCTAssertEqual(candidate.profileID, account.profileID)
        let restored = try launcher.addAccount(named: "Restored", linkToExistingEnvironment: false, directoryName: candidate.directoryName)
        XCTAssertEqual(restored.profileID, account.profileID)
        XCTAssertEqual(ProfilePaths(profile: restored, baseDirectory: managerRoot).root, paths.root)
    }

    @MainActor
    func testRelocatingProfileUpdatesOnlyRegistrationLocatorAndRejectsDuplicateMarker() throws {
        let container = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let support = container.appendingPathComponent("support", isDirectory: true)
        let managerRoot = support.appendingPathComponent("ChatGPT Profile Manager", isDirectory: true)
        let defaultsName = "ChatGPTProfileManagerRelocation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = ProfileStateStore(defaults: defaults)
        let account = try store.addAccount(named: "Moved", linkToExistingEnvironment: false, directoryName: "moved")
        let oldPaths = ProfilePaths(profile: account, baseDirectory: managerRoot)
        try oldPaths.createDirectories()
        try oldPaths.ensureMarker(profileID: account.profileID)
        let newRoot = container.appendingPathComponent("external-profile", isDirectory: true)
        let newPaths = ProfilePaths(root: newRoot)
        try newPaths.createDirectories()
        try newPaths.ensureMarker(profileID: account.profileID)
        try FileManager.default.removeItem(at: oldPaths.root)
        let launcher = CodexLauncher(stateStore: store, applicationSupportDirectory: support)
        let updated = try launcher.updateProfileLocation(id: account.id, root: newRoot)
        XCTAssertEqual(updated.lastKnownPath, newRoot.standardizedFileURL.path)
        XCTAssertEqual(launcher.codexHomeDirectory(for: updated), newPaths.codexHome)

        let secondRoot = container.appendingPathComponent("different-profile", isDirectory: true)
        let secondPaths = ProfilePaths(root: secondRoot)
        try secondPaths.createDirectories()
        try secondPaths.ensureMarker(profileID: account.profileID)
        XCTAssertThrowsError(try launcher.updateProfileLocation(id: account.id, root: secondRoot)) { error in
            XCTAssertEqual(error as? ProfileManagerError, .profileDirectoryAlreadyAssigned)
        }
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

    func testProfileLauncherURLRoundTripsAccountID() {
        let accountID = UUID(uuidString: "48008583-e670-4656-979e-50ea198b9093")!
        let url = ProfileLauncherURL.url(for: accountID)

        XCTAssertEqual(url.scheme, "chatgpt-profile-manager")
        XCTAssertEqual(url.host, "launch")
        XCTAssertEqual(ProfileLauncherURL.accountID(from: url), accountID)
        let externalLaunchURL = URL(
            string: url.absoluteString + "&pid=1234"
        )!
        XCTAssertEqual(
            ProfileLauncherURL.processIdentifier(from: externalLaunchURL),
            1234
        )
        XCTAssertNil(
            ProfileLauncherURL.processIdentifier(
                from: URL(string: url.absoluteString + "&pid=0")!
            )
        )
        XCTAssertNil(
            ProfileLauncherURL.accountID(
                from: URL(string: "chatgpt-profile-manager://launch?profile=not-a-uuid")!
            )
        )
    }

    func testProfileLauncherInitialsRecognizeCamelCaseAndWordSeparators() {
        XCTAssertEqual(ProfileLauncherIconGenerator.initials(for: "ShareFair"), "SF")
        XCTAssertEqual(ProfileLauncherIconGenerator.initials(for: "share-fair"), "SF")
        XCTAssertEqual(ProfileLauncherIconGenerator.initials(for: "share_fair"), "SF")
        XCTAssertEqual(ProfileLauncherIconGenerator.initials(for: "share fair"), "SF")
        XCTAssertEqual(ProfileLauncherIconGenerator.initials(for: "sharefair"), "SH")
    }

    func testProfileLauncherGeneratesStableApplicationBundle() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let accountID = UUID(uuidString: "48008583-e670-4656-979e-50ea198b9093")!
        let account = AccountProfile(id: accountID, name: "開発 チーム")
        let launcherURL = try ProfileLauncherStore(baseDirectory: root).generate(for: account)

        XCTAssertEqual(
            launcherURL.lastPathComponent,
            "ChatGPT 開発 チーム.app"
        )
        let bundle = try XCTUnwrap(Bundle(url: launcherURL))
        XCTAssertEqual(
            bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            "ChatGPT 開発 チーム"
        )
        XCTAssertEqual(
            bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
            "ChatGPT 開発 チーム"
        )
        XCTAssertEqual(
            bundle.object(forInfoDictionaryKey: "ChatGPTProfileManagerAccountID") as? String,
            accountID.uuidString
        )
        XCTAssertEqual(
            bundle.object(forInfoDictionaryKey: "CFBundleIdentifier") as? String,
            "com.local.chatgpt-profile-manager.launcher.48008583e6704656979e50ea198b9093"
        )
        let script = try String(
            contentsOf: launcherURL.appendingPathComponent("Contents/MacOS/LaunchProfile"),
            encoding: .utf8
        )
        let expectedCodexHome = "export CODEX_HOME='" + root.path
            + "/Profiles/" + account.directoryName + "/CodexHome'"
        let expectedElectronUserData = "export CODEX_ELECTRON_USER_DATA_PATH='" + root.path
            + "/Profiles/" + account.directoryName + "/ElectronUserData'"
        XCTAssertTrue(script.contains(expectedCodexHome))
        XCTAssertTrue(script.contains(expectedElectronUserData))
        XCTAssertTrue(
            script.contains(
                "\"$CHATGPT_EXECUTABLE\" \"--user-data-dir=$CODEX_ELECTRON_USER_DATA_PATH\" &"
            )
        )
        XCTAssertTrue(
            script.contains(
                "MARKER_DIRECTORY='" + root.path + "/Launchers/.running'"
            )
        )
        XCTAssertTrue(
            script.contains(
                "MARKER_FILE=\"$MARKER_DIRECTORY/\(accountID.uuidString).pid\""
            )
        )
        XCTAssertTrue(script.contains("CHATGPT_PID=$!"))
        XCTAssertTrue(script.contains("printf '%s\\n' \"$CHATGPT_PID\""))
        XCTAssertTrue(script.contains(ProfileLauncherURL.url(for: accountID).absoluteString))
        XCTAssertTrue(script.contains("/bin/kill -0 \"$ACTIVE_PID\""))
        XCTAssertTrue(script.contains("/bin/rmdir \"$LOCK_DIRECTORY\""))
        XCTAssertTrue(script.contains("OWNER_FILE=\"$LOCK_DIRECTORY/\(ProfileFileLock.ownerFileName)\""))
        XCTAssertTrue(script.contains("/usr/bin/unlink \"$OWNER_FILE\""))
        XCTAssertTrue(script.contains("MARKER_VERSION=$(/usr/bin/plutil -extract version raw"))
        XCTAssertTrue(script.contains(account.profileID.uuidString))
        XCTAssertFalse(script.contains("rm -rf \"$LOCK_DIRECTORY\""))
    }

    func testProfileLauncherStatusDetectsMissingAndOutdatedLaunchers() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let account = AccountProfile(name: "開発")
        let store = ProfileLauncherStore(baseDirectory: root)
        XCTAssertEqual(store.status(for: account), .notCreated)

        let launcherURL = try store.generate(for: account)
        XCTAssertEqual(store.status(for: account), .current)

        let plistURL = launcherURL.appendingPathComponent("Contents/Info.plist")
        let plistData = try Data(contentsOf: plistURL)
        var plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        )
        plist["CFBundleDisplayName"] = "古い名前"
        let updatedPlist = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try updatedPlist.write(to: plistURL, options: .atomic)

        XCTAssertEqual(store.status(for: account), .needsUpdate)
    }

    func testStaleEmptyLauncherLockCanBeRecoveredWithoutRecursiveRemoval() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = AccountProfile(name: "Stale", profileID: UUID(), directoryName: "stale")
        let lock = ProfileLauncherStore.runningLockURL(baseDirectory: root, profileID: account.profileID)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -20)],
            ofItemAtPath: lock.path
        )
        let store = ProfileLauncherStore(baseDirectory: root)
        store.recoverStaleRunningLock(for: account)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path))
    }

    func testRunningLockWithLiveUIOwnerIsNotRecovered() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = AccountProfile(name: "Active", profileID: UUID(), directoryName: "active")
        let lock = ProfileLauncherStore.runningLockURL(baseDirectory: root, profileID: account.profileID)
        let owner = try ProfileFileLock.acquireEmpty(at: lock)
        try owner.setOwnerProcessIdentifier(Int32(ProcessInfo.processInfo.processIdentifier))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -20)],
            ofItemAtPath: lock.path
        )

        ProfileLauncherStore(baseDirectory: root).recoverStaleRunningLock(for: account)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
        owner.release()
    }

    func testDeadUIOwnerLockIsReleasedWithoutGraceDelay() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = AccountProfile(name: "Finished", profileID: UUID(), directoryName: "finished")
        let lock = ProfileLauncherStore.runningLockURL(baseDirectory: root, profileID: account.profileID)
        _ = try ProfileFileLock.acquireOwned(at: lock, processIdentifier: 999_999)

        ProfileLauncherStore(baseDirectory: root).recoverStaleRunningLock(for: account)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path))
    }

    func testMalformedLockOwnerIsPreserved() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = root.appendingPathComponent("malformed.lock", isDirectory: true)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        try Data("not-a-pid".utf8).write(to: lock.appendingPathComponent(ProfileFileLock.ownerFileName))

        XCTAssertEqual(ProfileFileLock.statusOwned(at: lock, isProcessActive: { _ in false }), .invalid)
        XCTAssertFalse(ProfileFileLock.recoverStaleOwned(at: lock, isProcessActive: { _ in false }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
    }

    func testOwnedMaintenanceLockDistinguishesActiveAndStaleOwners() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runningURL = root.appendingPathComponent("running.lock", isDirectory: true)
        let firstRunningLock = try ProfileFileLock.acquireEmpty(at: runningURL)
        XCTAssertThrowsError(try ProfileFileLock.acquireEmpty(at: runningURL)) { error in
            XCTAssertEqual(error as? ProfileFileLockError, .alreadyHeld)
        }
        firstRunningLock.release()

        let lockURL = root.appendingPathComponent("maintenance.lock", isDirectory: true)
        let lock = try ProfileFileLock.acquireOwned(at: lockURL, processIdentifier: 123)
        XCTAssertEqual(
            ProfileFileLock.statusOwned(at: lockURL, isProcessActive: { $0 == 123 }),
            .active
        )
        XCTAssertEqual(
            ProfileFileLock.statusOwned(at: lockURL, isProcessActive: { _ in false }),
            .stale
        )
        lock.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))

        let stale = try ProfileFileLock.acquireOwned(at: lockURL, processIdentifier: 456)
        _ = stale
        XCTAssertTrue(ProfileFileLock.recoverStaleOwned(at: lockURL, isProcessActive: { _ in false }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path))

        let uiLockURL = root.appendingPathComponent("ui.lock", isDirectory: true)
        let uiLock = try ProfileFileLock.acquireEmpty(at: uiLockURL)
        try uiLock.setOwnerProcessIdentifier(789)
        XCTAssertEqual(
            ProfileFileLock.statusOwned(at: uiLockURL, isProcessActive: { $0 == 789 }),
            .active
        )
        uiLock.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: uiLockURL.path))
    }

    func testPresentDanglingMarkerIsInvalidAndNeverTreatedAsMissing() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProfilePaths(root: root)
        try paths.createDirectories()
        let target = root.appendingPathComponent("marker-target.json")
        try FileManager.default.createSymbolicLink(at: paths.markerURL(), withDestinationURL: target)

        if case .invalid = paths.readMarkerState() {
            // expected: a dangling marker is a present but unreadable entry
        } else {
            XCTFail("dangling marker must not be treated as missing")
        }
        XCTAssertThrowsError(try paths.ensureMarker(profileID: UUID())) { error in
            XCTAssertEqual(error as? ProfileManagerError, .profileMarkerMismatch)
        }
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: paths.markerURL().path),
            target.path
        )
    }

    func testDiagnosticLogURLsReturnNewestRepairLogFirst() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logDirectory = root.appendingPathComponent("Diagnostics/Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let old = logDirectory.appendingPathComponent("old.json")
        let new = logDirectory.appendingPathComponent("new.json")
        try Data("{}".utf8).write(to: old)
        try Data("{}".utf8).write(to: new)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -20)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -1)], ofItemAtPath: new.path)

        let service = ProfileDiagnosticsService(baseDirectory: root)
        XCTAssertEqual(service.logURLs().map(\.lastPathComponent), ["new.json", "old.json"])
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

    func testResetCreditsSortKnownExpirationsBeforeUnknownDates() {
        let earliest = Date(timeIntervalSince1970: 1_700_000_000)
        let latest = Date(timeIntervalSince1970: 1_800_000_000)
        let summary = RateLimitResetCreditsSummary(
            availableCount: 4,
            credits: [
                RateLimitResetCredit(expiresAt: nil),
                RateLimitResetCredit(expiresAt: latest),
                RateLimitResetCredit(expiresAt: earliest),
                RateLimitResetCredit(expiresAt: nil)
            ]
        )

        XCTAssertEqual(
            summary.creditsSortedByExpiry.map(\.expiresAt),
            [earliest, latest, nil, nil]
        )
    }

    func testUsageSnapshotPreservesZeroCreditsAndUnknownExpiry() throws {
        let response = Data(
            #"""
            {
              "result": {
                "rateLimits": { "primary": { "usedPercent": 100 } },
                "rateLimitResetCredits": {
                  "availableCount": 0,
                  "credits": [ { "expiresAt": "not-a-date" } ]
                }
              }
            }
            """#.utf8
        )

        let snapshot = try XCTUnwrap(AccountUsageSnapshot(jsonData: response))
        XCTAssertEqual(snapshot.primary?.remainingPercent, 0)
        XCTAssertEqual(snapshot.rateLimitResetCredits?.availableCount, 0)
        XCTAssertEqual(snapshot.rateLimitResetCredits?.credits?.count, 1)
        XCTAssertNil(snapshot.rateLimitResetCredits?.credits?.first?.expiresAt)
    }

    func testUsageSnapshotRejectsResponseWithoutUsageOrCredits() {
        let response = Data(#"{"result":{"rateLimits":{"planType":"plus"}}}"#.utf8)
        XCTAssertNil(AccountUsageSnapshot(jsonData: response))
    }

    func testUsageThresholdEvaluatorOnlyReportsDownwardCrossings() {
        let previous = UsageWindow(usedPercent: 60, windowDurationMinutes: 300, resetsAt: nil)
        let current = UsageWindow(usedPercent: 95, windowDurationMinutes: 300, resetsAt: nil)
        XCTAssertEqual(
            UsageThresholdEvaluator.crossedThresholds(
                previous: previous,
                current: current,
                thresholds: [25, 10]
            ),
            [10, 25]
        )

        let recovered = UsageWindow(usedPercent: 60, windowDurationMinutes: 300, resetsAt: nil)
        XCTAssertEqual(
            UsageThresholdEvaluator.crossedThresholds(
                previous: current,
                current: recovered,
                thresholds: [10, 25]
            ),
            []
        )
        XCTAssertEqual(
            UsageThresholdEvaluator.crossedThresholds(
                previous: nil,
                current: current,
                thresholds: [10, 25]
            ),
            []
        )
    }

    func testUnexpectedUsageResetDetectorOnlyDetectsAnEarlyWeeklyReset() {
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let previousReset = observedAt.addingTimeInterval(24 * 60 * 60)
        let currentReset = observedAt.addingTimeInterval(8 * 24 * 60 * 60)
        let previousWeekly = UsageWindow(
            usedPercent: 70,
            windowDurationMinutes: 10_080,
            resetsAt: previousReset
        )
        let currentWeekly = UsageWindow(
            usedPercent: 5,
            windowDurationMinutes: 10_080,
            resetsAt: currentReset
        )

        XCTAssertTrue(
            UnexpectedUsageResetDetector.weeklyResetWasUnexpected(
                previous: previousWeekly,
                current: currentWeekly,
                observedAt: observedAt
            )
        )

        let previousFiveHour = UsageWindow(
            usedPercent: 70,
            windowDurationMinutes: 300,
            resetsAt: previousReset
        )
        let currentFiveHour = UsageWindow(
            usedPercent: 5,
            windowDurationMinutes: 300,
            resetsAt: currentReset
        )
        XCTAssertFalse(
            UnexpectedUsageResetDetector.weeklyResetWasUnexpected(
                previous: previousFiveHour,
                current: currentFiveHour,
                observedAt: observedAt
            )
        )
    }

    func testUnexpectedUsageResetDetectorIgnoresExpectedOrIncompleteChanges() {
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let previousReset = observedAt.addingTimeInterval(-60)
        let currentReset = observedAt.addingTimeInterval(7 * 24 * 60 * 60)
        let previous = UsageWindow(
            usedPercent: 70,
            windowDurationMinutes: 10_080,
            resetsAt: previousReset
        )
        let current = UsageWindow(
            usedPercent: 5,
            windowDurationMinutes: 10_080,
            resetsAt: currentReset
        )

        XCTAssertFalse(
            UnexpectedUsageResetDetector.weeklyResetWasUnexpected(
                previous: previous,
                current: current,
                observedAt: observedAt
            )
        )

        let unchangedResetDate = UsageWindow(
            usedPercent: 5,
            windowDurationMinutes: 10_080,
            resetsAt: previousReset.addingTimeInterval(24 * 60 * 60)
        )
        XCTAssertFalse(
            UnexpectedUsageResetDetector.weeklyResetWasUnexpected(
                previous: UsageWindow(
                    usedPercent: 70,
                    windowDurationMinutes: 10_080,
                    resetsAt: previousReset.addingTimeInterval(24 * 60 * 60)
                ),
                current: unchangedResetDate,
                observedAt: observedAt
            )
        )

        XCTAssertFalse(
            UnexpectedUsageResetDetector.weeklyResetWasUnexpected(
                previous: previous,
                current: UsageWindow(
                    usedPercent: 5,
                    windowDurationMinutes: 10_080,
                    resetsAt: nil
                ),
                observedAt: observedAt
            )
        )

        XCTAssertFalse(
            UnexpectedUsageResetDetector.weeklyResetWasUnexpected(
                previous: UsageWindow(
                    usedPercent: 70,
                    windowDurationMinutes: nil,
                    resetsAt: observedAt.addingTimeInterval(24 * 60 * 60)
                ),
                current: UsageWindow(
                    usedPercent: 5,
                    windowDurationMinutes: nil,
                    resetsAt: observedAt.addingTimeInterval(8 * 24 * 60 * 60)
                ),
                observedAt: observedAt
            )
        )
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

    @MainActor
    func testNewAccountRegistrationRollsBackWhenStorageCreationFails() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let managerRoot = root.appendingPathComponent("ChatGPT Profile Manager", isDirectory: true)
        try FileManager.default.createDirectory(at: managerRoot, withIntermediateDirectories: true)
        let profiles = managerRoot.appendingPathComponent("Profiles", isDirectory: true)
        try Data("not a directory".utf8).write(to: profiles)
        let suiteName = "ChatGPTProfileManagerRegistrationRollback-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProfileStateStore(defaults: defaults)
        let launcher = CodexLauncher(stateStore: store, applicationSupportDirectory: root)

        XCTAssertThrowsError(try launcher.addAccount(named: "Broken", linkToExistingEnvironment: false))
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profiles.path))
    }

    @MainActor
    func testExistingProfileRegistrationRollsBackWhenMarkerCannotBeCreated() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profileRoot = root.appendingPathComponent("external", isDirectory: true)
        let paths = ProfilePaths(root: profileRoot)
        try paths.createDirectories()
        try FileManager.default.createDirectory(at: paths.markerURL(), withIntermediateDirectories: true)
        let suiteName = "ChatGPTProfileManagerExternalRollback-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProfileStateStore(defaults: defaults)
        let launcher = CodexLauncher(stateStore: store, applicationSupportDirectory: root)

        XCTAssertThrowsError(try launcher.registerIsolatedProfile(named: "External", root: profileRoot))
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.markerURL().path))
    }

    @MainActor
    func testRelocationDoesNotCreateMissingLauncher() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "ChatGPTProfileManagerRelocationLauncher-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProfileStateStore(defaults: defaults)
        let oldRoot = root.appendingPathComponent("old", isDirectory: true)
        let account = try store.addAccount(named: "Move", linkToExistingEnvironment: false, directoryName: "move", lastKnownPath: oldRoot.path)
        try ProfilePaths(root: oldRoot).createDirectories()
        try ProfilePaths(root: oldRoot).ensureMarker(profileID: account.profileID)
        let newRoot = root.appendingPathComponent("new", isDirectory: true)
        try ProfilePaths(root: newRoot).createDirectories()
        try ProfilePaths(root: newRoot).ensureMarker(profileID: account.profileID)
        try FileManager.default.removeItem(at: oldRoot)
        let launcher = CodexLauncher(stateStore: store, applicationSupportDirectory: root)

        _ = try launcher.updateProfileLocation(id: account.id, root: newRoot)
        let launchers = root.appendingPathComponent("Launchers", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: launchers.path))
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

    func testSettingsCopyBacksUpDestinationAndKeepsAuthenticationOut() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceHome = root.appendingPathComponent("source", isDirectory: true)
        let destinationHome = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationHome, withIntermediateDirectories: true)
        try Data("source instructions".utf8).write(to: sourceHome.appendingPathComponent("AGENTS.md"))
        try Data("source config".utf8).write(to: sourceHome.appendingPathComponent("config.toml"))
        try Data("old config".utf8).write(to: destinationHome.appendingPathComponent("config.toml"))
        try Data("destination auth".utf8).write(to: destinationHome.appendingPathComponent("auth.json"))

        let store = SettingsSharingStore(baseDirectory: root.appendingPathComponent("manager", isDirectory: true))
        let source = ProfileStorageReference.isolated(directoryName: "source")
        let destination = ProfileStorageReference.isolated(directoryName: "destination")
        let summary = try store.copy(
            source: source,
            destination: destination,
            items: [.instructions, .config],
            codexHomes: [source: sourceHome, destination: destinationHome]
        )

        XCTAssertEqual(try String(contentsOf: destinationHome.appendingPathComponent("AGENTS.md")), "source instructions")
        XCTAssertEqual(try String(contentsOf: destinationHome.appendingPathComponent("config.toml")), "source config")
        XCTAssertEqual(try String(contentsOf: destinationHome.appendingPathComponent("auth.json")), "destination auth")
        XCTAssertTrue(FileManager.default.fileExists(atPath: summary.backupDirectory.appendingPathComponent("config.toml").path))
        XCTAssertEqual(store.loadRegistry().cloneHistory.count, 1)
    }

    func testSettingsCopyDiffReportsNewChangedSameAndMissingItems() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceHome = root.appendingPathComponent("source", isDirectory: true)
        let destinationHome = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationHome, withIntermediateDirectories: true)
        try Data("same".utf8).write(to: sourceHome.appendingPathComponent("AGENTS.md"))
        try Data("same".utf8).write(to: destinationHome.appendingPathComponent("AGENTS.md"))
        try Data("new source".utf8).write(to: sourceHome.appendingPathComponent("config.toml"))
        try Data("old destination".utf8).write(to: destinationHome.appendingPathComponent("config.toml"))
        try FileManager.default.createDirectory(at: sourceHome.appendingPathComponent("rules"), withIntermediateDirectories: true)
        try Data("allow".utf8).write(to: sourceHome.appendingPathComponent("rules/allow.rules"))

        let store = SettingsSharingStore(baseDirectory: root.appendingPathComponent("manager", isDirectory: true))
        let source = ProfileStorageReference.isolated(directoryName: "source")
        let destination = ProfileStorageReference.isolated(directoryName: "destination")
        let diff = try store.diff(
            source: source,
            destination: destination,
            items: [.instructions, .config, .rules, .override],
            codexHomes: [source: sourceHome, destination: destinationHome]
        )

        XCTAssertEqual(diff.map(\.setting), [.instructions, .config, .rules, .override])
        XCTAssertEqual(diff[0], SettingsCopyDiff(setting: .instructions, sourceExists: true, destinationExists: true, identical: true))
        XCTAssertEqual(diff[1], SettingsCopyDiff(setting: .config, sourceExists: true, destinationExists: true, identical: false))
        XCTAssertEqual(diff[2], SettingsCopyDiff(setting: .rules, sourceExists: true, destinationExists: false, identical: false))
        XCTAssertEqual(diff[3], SettingsCopyDiff(setting: .override, sourceExists: false, destinationExists: false, identical: false))
    }

    func testSettingsCopyCanRestoreDestinationFromBackup() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceHome = root.appendingPathComponent("source", isDirectory: true)
        let destinationHome = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationHome, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: sourceHome.appendingPathComponent("AGENTS.md"))
        try Data("before".utf8).write(to: destinationHome.appendingPathComponent("AGENTS.md"))

        let store = SettingsSharingStore(baseDirectory: root.appendingPathComponent("manager", isDirectory: true))
        let source = ProfileStorageReference.isolated(directoryName: "source")
        let destination = ProfileStorageReference.isolated(directoryName: "destination")
        let summary = try store.copy(
            source: source,
            destination: destination,
            items: [.instructions],
            codexHomes: [source: sourceHome, destination: destinationHome]
        )
        XCTAssertEqual(try String(contentsOf: destinationHome.appendingPathComponent("AGENTS.md")), "source")

        let restored = try store.restoreClone(
            recordID: summary.operationID,
            destination: destination,
            codexHome: destinationHome
        )
        XCTAssertEqual(restored, [.instructions])
        XCTAssertEqual(try String(contentsOf: destinationHome.appendingPathComponent("AGENTS.md")), "before")
        XCTAssertNil(store.latestCloneRecord(destination: destination))
    }

    func testSettingsRegistryHealthDetectsCorruptionAndRestoresLatestBackup() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceHome = root.appendingPathComponent("source", isDirectory: true)
        let destinationHome = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationHome, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: sourceHome.appendingPathComponent("AGENTS.md"))
        let store = SettingsSharingStore(baseDirectory: root.appendingPathComponent("manager", isDirectory: true))
        let source = ProfileStorageReference.isolated(directoryName: "source")
        let destination = ProfileStorageReference.isolated(directoryName: "destination")

        _ = try store.copy(
            source: source,
            destination: destination,
            items: [.instructions],
            codexHomes: [source: sourceHome, destination: destinationHome]
        )
        _ = try store.copy(
            source: source,
            destination: destination,
            items: [.instructions],
            codexHomes: [source: sourceHome, destination: destinationHome]
        )
        try Data("broken".utf8).write(to: store.registryURL, options: .atomic)

        XCTAssertEqual(store.registryHealth(), SettingsRegistryHealth(state: .corrupted, backupAvailable: true))
        let restored = try store.restoreRegistryFromBackup()
        XCTAssertEqual(restored.cloneHistory.count, 1)
        XCTAssertEqual(store.registryHealth().state, .healthy)
    }

    func testProfileRegistryHealthDetectsCorruptionAndRestoresLatestBackup() throws {
        let (store, defaults, suiteName) = try makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = try store.addAccount(named: "最初", linkToExistingEnvironment: false)
        _ = try store.addAccount(named: "次", linkToExistingEnvironment: false)
        defaults.set(Data("not-json".utf8), forKey: "accountsV2")

        XCTAssertEqual(store.registryHealth, ProfileRegistryHealth(state: .corrupted, backupAvailable: true))
        let restored = try store.restoreAccountsFromBackup()
        XCTAssertEqual(restored, [first])
        XCTAssertEqual(store.registryHealth.state, .healthy)
        XCTAssertEqual(store.accounts, [first])
    }

    func testSettingsSharePersistsGroupAndLeaveKeepsCurrentContent() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceHome = root.appendingPathComponent("source", isDirectory: true)
        let destinationHome = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationHome, withIntermediateDirectories: true)
        try Data("shared instructions".utf8).write(to: sourceHome.appendingPathComponent("AGENTS.md"))
        try Data("old instructions".utf8).write(to: destinationHome.appendingPathComponent("AGENTS.md"))

        let store = SettingsSharingStore(baseDirectory: root.appendingPathComponent("manager", isDirectory: true))
        let source = ProfileStorageReference.isolated(directoryName: "source")
        let destination = ProfileStorageReference.isolated(directoryName: "destination")
        let group = try store.createShareGroup(
            name: "Shared",
            source: source,
            destinations: [destination],
            items: [.instructions],
            codexHomes: [source: sourceHome, destination: destinationHome]
        )

        XCTAssertEqual(store.loadRegistry().groups.first?.id, group.id)
        XCTAssertEqual(store.binding(for: destination)?.groupID, group.id)
        XCTAssertEqual(try String(contentsOf: destinationHome.appendingPathComponent("AGENTS.md")), "shared instructions")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("manager/Settings/SharedSettings/\(group.id.uuidString)/manifest.json").path))
        XCTAssertTrue(try FileManager.default.attributesOfItem(atPath: destinationHome.appendingPathComponent("AGENTS.md").path)[.type] as? FileAttributeType == .typeSymbolicLink)

        _ = try store.leaveShareGroup(profile: destination, codexHome: destinationHome)
        XCTAssertEqual(try String(contentsOf: destinationHome.appendingPathComponent("AGENTS.md")), "shared instructions")
        XCTAssertFalse(try FileManager.default.attributesOfItem(atPath: destinationHome.appendingPathComponent("AGENTS.md").path)[.type] as? FileAttributeType == .typeSymbolicLink)
        XCTAssertNil(store.binding(for: destination))
    }

    func testSettingsShareRejectsSensitiveConfigBeforeChangingProfiles() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceHome = root.appendingPathComponent("source", isDirectory: true)
        let destinationHome = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationHome, withIntermediateDirectories: true)
        try Data("api_key = \"secret\"\n".utf8).write(to: sourceHome.appendingPathComponent("config.toml"))
        try Data("destination".utf8).write(to: destinationHome.appendingPathComponent("config.toml"))

        let store = SettingsSharingStore(baseDirectory: root.appendingPathComponent("manager", isDirectory: true))
        let source = ProfileStorageReference.isolated(directoryName: "source")
        let destination = ProfileStorageReference.isolated(directoryName: "destination")
        XCTAssertThrowsError(
            try store.createShareGroup(
                name: "Sensitive",
                source: source,
                destinations: [destination],
                items: [.config],
                codexHomes: [source: sourceHome, destination: destinationHome]
            )
        ) { error in
            XCTAssertEqual(error as? SettingsSharingError, .configContainsSensitiveValues(SettingsSharingStore.unsupportedConfigItems(in: "api_key = \"secret\"\n")))
            XCTAssertFalse(error.localizedDescription.contains("secret"))
        }
        XCTAssertEqual(try String(contentsOf: destinationHome.appendingPathComponent("config.toml")), "destination")
        XCTAssertTrue(store.loadRegistry().groups.isEmpty)
    }

    func testUnsupportedConfigItemsHideValuesAndDeduplicateSections() {
        let items = SettingsSharingStore.unsupportedConfigItems(in: "model = \"allowed\"\nnotify = [\"private-command\"]\n[mcp_servers.private_server]\napi_key = \"secret\"\n[mcp_servers.second.env]\nPRIVATE_TOKEN = \"secret\"\n[projects.\"/private/path\"]\ntrust_level = \"trusted\"\n[\"private-custom-section\"]\n")
        XCTAssertEqual(items.count, 4)
        XCTAssertTrue(items[0].contains("notify"))
        XCTAssertTrue(items[1].contains("mcp_servers"))
        XCTAssertTrue(items[2].contains("projects"))
        XCTAssertFalse(items.joined().contains("private"))
        XCTAssertFalse(items.joined().contains("secret"))
        XCTAssertTrue(SettingsSharingStore.unsupportedConfigItems(in: "# comment\nmodel = \"x\"\nservice_tier = \"fast\"\n").isEmpty)
    }

    private func makeStore() throws -> (ProfileStateStore, UserDefaults, String) {
        let suiteName = "ChatGPTProfileManagerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (ProfileStateStore(defaults: defaults), defaults, suiteName)
    }

    private func createFixtureSQLite(at url: URL, sessionID: String, rolloutPath: String) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        guard let database else { throw ProfileManagerError.unknownProfileSchema }
        defer { sqlite3_close(database) }
        let sql = "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT); CREATE TABLE _sqlx_migrations (version BIGINT PRIMARY KEY, success BOOLEAN NOT NULL); INSERT INTO _sqlx_migrations(version, success) VALUES (52, 1); INSERT INTO threads(id, rollout_path) VALUES ('\(sessionID)', '\(rolloutPath)'); PRAGMA user_version = 0;"
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        if let errorMessage { sqlite3_free(errorMessage) }
        XCTAssertEqual(result, SQLITE_OK)
    }

    private func executeSQLite(at url: URL, sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let database else {
            throw ProfileManagerError.unknownProfileSchema
        }
        defer { sqlite3_close(database) }
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            if let errorMessage { sqlite3_free(errorMessage) }
            throw ProfileManagerError.unknownProfileSchema
        }
    }

    private func sqliteScalar(at url: URL, sql: String) throws -> String? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            throw ProfileManagerError.unknownProfileSchema
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw ProfileManagerError.unknownProfileSchema
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatGPTProfileManagerSettings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }
}
