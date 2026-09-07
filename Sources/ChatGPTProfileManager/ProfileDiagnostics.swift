import Darwin
import Foundation
import SQLite3

/// Severity is intentionally serializable so diagnostic output can be stored
/// and consumed by support tooling without exposing profile contents.
enum ProfileDiagnosticSeverity: String, Codable, Sendable {
    case info
    case warning
    case error
}

enum ProfileDiagnosticStatus: String, Codable, Sendable {
    case healthy
    case needsAttention
    case missing
    case unknown
}

/// Lifecycle state shared by the UI and the application termination guard.
/// Read-only inspection may be cancelled when its window closes, while a
/// repair must be allowed to finish so its SQLite transaction and repair log
/// are not abandoned halfway through.
enum ProfileDiagnosticsExecutionState: Equatable, Sendable {
    case idle
    case diagnosing
    case repairing

    var blocksApplicationTermination: Bool {
        self == .repairing
    }

    var continuesAfterWindowClose: Bool {
        self == .repairing
    }
}

struct ProfileDiagnosticFinding: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let code: String
    let severity: ProfileDiagnosticSeverity
    let message: String
    let path: String?
    let repairable: Bool

    init(
        code: String,
        severity: ProfileDiagnosticSeverity,
        message: String,
        path: String? = nil,
        repairable: Bool = false
    ) {
        id = UUID()
        self.code = code
        self.severity = severity
        self.message = message
        self.path = path
        self.repairable = repairable
    }
}

struct SQLiteDiagnostic: Codable, Equatable, Sendable {
    let path: String
    let knownSchema: Bool
    let quickCheckPassed: Bool
    let foreignKeyCheckPassed: Bool
    let threadCount: Int
    let indexedSessionIDs: [String]
    let referencedRolloutPaths: [String]
}

struct ProfileDiagnosticReport: Codable, Equatable, Sendable {
    let profileID: UUID
    let root: String
    let status: ProfileDiagnosticStatus
    let createdAt: Date
    let checks: [String: Bool]
    let findings: [ProfileDiagnosticFinding]
    let sqlite: [SQLiteDiagnostic]

    var isHealthy: Bool { status == .healthy }
}

struct ProfileRepairResult: Codable, Equatable, Sendable {
    let operationID: UUID
    let profileID: UUID
    let updatedPathCount: Int
    let skippedAmbiguousCount: Int
    let success: Bool
    let rolledBack: Bool
    let snapshotDirectory: URL
    let logURL: URL
    let findings: [ProfileDiagnosticFinding]
}

struct ProfileRepairLog: Codable, Sendable {
    let operationID: UUID
    let profileID: UUID
    let startedAt: Date
    let finishedAt: Date
    let operation: String
    let result: String
    let updatedPathCount: Int
    let skippedAmbiguousCount: Int
    let findings: [ProfileDiagnosticFinding]
}

private struct JSONLSession {
    let id: String
    let url: URL
}

private struct ThreadRow {
    let id: String
    let rolloutPath: String?
}

/// Read-only inspection and conservative repair of the local Codex indexes.
/// No command line tools are used: SQLite is opened with SQLITE_OPEN_READONLY,
/// and every write is made inside a transaction after a snapshot.
final class ProfileDiagnosticsService {
    private let fileManager: FileManager
    private let baseDirectory: URL
    private let recoverySnapshotsDirectory: URL
    private let diagnosticsLogsDirectory: URL
    private let isChatGPTRunning: () -> Bool

    init(
        baseDirectory: URL,
        fileManager: FileManager = .default,
        recoverySnapshotsDirectory: URL? = nil,
        diagnosticsLogsDirectory: URL? = nil,
        isChatGPTRunning: @escaping () -> Bool = { false }
    ) {
        self.fileManager = fileManager
        self.baseDirectory = baseDirectory
        self.recoverySnapshotsDirectory = recoverySnapshotsDirectory
            ?? baseDirectory.appendingPathComponent("Recovery/RepairSnapshots", isDirectory: true)
        self.diagnosticsLogsDirectory = diagnosticsLogsDirectory
            ?? baseDirectory.appendingPathComponent("Diagnostics/Logs", isDirectory: true)
        self.isChatGPTRunning = isChatGPTRunning
    }

    convenience init(
        profileRoot: URL,
        fileManager: FileManager = .default,
        recoverySnapshotsDirectory: URL? = nil,
        diagnosticsLogsDirectory: URL? = nil,
        isChatGPTRunning: @escaping () -> Bool = { false }
    ) {
        self.init(
            baseDirectory: profileRoot.deletingLastPathComponent().deletingLastPathComponent(),
            fileManager: fileManager,
            recoverySnapshotsDirectory: recoverySnapshotsDirectory,
            diagnosticsLogsDirectory: diagnosticsLogsDirectory,
            isChatGPTRunning: isChatGPTRunning
        )
    }

    func diagnose(profile: AccountProfile) -> ProfileDiagnosticReport {
        diagnose(root: ProfilePaths(profile: profile, baseDirectory: baseDirectory).root, profileID: profile.profileID)
    }

    func diagnose(root: URL, profileID: UUID) -> ProfileDiagnosticReport {
        var findings: [ProfileDiagnosticFinding] = []
        var checks: [String: Bool] = [:]
        let root = root.standardizedFileURL
        let rootExists = fileManager.fileExists(atPath: root.path)
        checks["rootExists"] = rootExists
        guard rootExists else {
            findings.append(ProfileDiagnosticFinding(
                code: "root.missing",
                severity: .error,
                message: L10n.text("diagnostics.finding.root-missing", fallback: "保存先フォルダが見つかりません。"),
                path: root.path,
                repairable: true
            ))
            return report(profileID: profileID, root: root, checks: checks, findings: findings, sqlite: [])
        }

        var isDirectory: ObjCBool = false
        let directory = fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) && isDirectory.boolValue
        checks["rootIsDirectory"] = directory
        if !directory {
            findings.append(ProfileDiagnosticFinding(
                code: "root.not-directory",
                severity: .error,
                message: L10n.text("diagnostics.finding.root-not-directory", fallback: "保存先がフォルダではありません。"),
                path: root.path
            ))
            return report(profileID: profileID, root: root, checks: checks, findings: findings, sqlite: [])
        }
        if isSymlink(root) {
            findings.append(ProfileDiagnosticFinding(
                code: "root.symlink",
                severity: .warning,
                message: L10n.text("diagnostics.finding.root-symlink", fallback: "保存先ルートがシンボリックリンクです。"),
                path: root.path
            ))
        }

        let readable = (try? fileManager.contentsOfDirectory(atPath: root.path)) != nil
        let writable = fileManager.isWritableFile(atPath: root.path)
        checks["rootReadable"] = readable
        checks["rootWritable"] = writable
        if !readable || !writable {
            findings.append(ProfileDiagnosticFinding(
                code: "root.permissions",
                severity: .error,
                message: L10n.text("diagnostics.finding.root-permissions", fallback: "保存先を読み書きできません。"),
                path: root.path
            ))
        }

        let codexHome = root.appendingPathComponent("CodexHome", isDirectory: true)
        let electronUserData = root.appendingPathComponent("ElectronUserData", isDirectory: true)
        var isCodexHomeDirectory: ObjCBool = false
        var isElectronDirectory: ObjCBool = false
        let codexHomeExists = fileManager.fileExists(atPath: codexHome.path, isDirectory: &isCodexHomeDirectory)
        let electronUserDataExists = fileManager.fileExists(atPath: electronUserData.path, isDirectory: &isElectronDirectory)
        checks["codexHomeExists"] = codexHomeExists && isCodexHomeDirectory.boolValue
        checks["electronUserDataExists"] = electronUserDataExists && isElectronDirectory.boolValue
        if !checks["codexHomeExists"]! || !checks["electronUserDataExists"]! {
            findings.append(ProfileDiagnosticFinding(
                code: "profile.layout-incomplete",
                severity: .warning,
                message: L10n.text("diagnostics.finding.layout-incomplete", fallback: "CodexHome または ElectronUserData がありません。"),
                path: root.path,
                repairable: true
            ))
        }

        let paths = ProfilePaths(root: root)
        switch paths.readMarkerState(fileManager: fileManager) {
        case let .valid(marker):
            let matches = marker.version == ProfileIdentityMarker.currentVersion && marker.profileID == profileID
            checks["markerMatches"] = matches
            if !matches {
                findings.append(ProfileDiagnosticFinding(
                    code: "marker.mismatch",
                    severity: .error,
                    message: L10n.text("diagnostics.finding.marker-mismatch", fallback: "保存先の識別マーカーが登録情報と一致しません。"),
                    path: paths.markerURL().path
                ))
            }
        case .missing:
            checks["markerMatches"] = false
            findings.append(ProfileDiagnosticFinding(
                code: "marker.missing",
                severity: .warning,
                message: L10n.text("diagnostics.finding.marker-missing", fallback: "保存先の識別マーカーがありません（旧プロファイル）。"),
                path: paths.markerURL().path,
                repairable: true
            ))
        case .invalid, .unsupported:
            checks["markerMatches"] = false
            findings.append(ProfileDiagnosticFinding(
                code: "marker.invalid",
                severity: .error,
                message: L10n.text("diagnostics.finding.marker-invalid", fallback: "保存先の識別マーカーが不正または未対応形式です。上書きせず、内容を確認してください。"),
                path: paths.markerURL().path,
                repairable: false
            ))
        }

        let maintenanceLockStatus = ProfileFileLock.statusOwned(
            at: paths.maintenanceLockURL(),
            fileManager: fileManager
        )
        checks["maintenanceLockActive"] = maintenanceLockStatus == .active
        switch maintenanceLockStatus {
        case .absent:
            break
        case .active:
            findings.append(ProfileDiagnosticFinding(
                code: "maintenance.active",
                severity: .warning,
                message: L10n.text("diagnostics.finding.maintenance-active", fallback: "このプロファイルはメンテナンス中です。"),
                path: paths.maintenanceLockURL().path
            ))
        case .stale:
            findings.append(ProfileDiagnosticFinding(
                code: "maintenance.stale",
                severity: .warning,
                message: L10n.text("diagnostics.finding.maintenance-stale", fallback: "終了したメンテナンスのロックが残っています。次回操作時に安全に回収できます。"),
                path: paths.maintenanceLockURL().path,
                repairable: true
            ))
        case .invalid:
            findings.append(ProfileDiagnosticFinding(
                code: "maintenance.invalid",
                severity: .error,
                message: L10n.text("diagnostics.finding.maintenance-invalid", fallback: "メンテナンスロックの所有情報を検証できません。上書きせず確認してください。"),
                path: paths.maintenanceLockURL().path
            ))
        }

        inspectSettings(root: root, profileID: profileID, checks: &checks, findings: &findings)
        let jsonl = sessionFiles(in: codexHome)
        let sqliteURLs = sqliteFiles(in: codexHome)
        var sqliteReports: [SQLiteDiagnostic] = []
        var indexedIDs = Set<String>()
        for sqliteURL in sqliteURLs {
            do {
                let inspection = try inspectSQLite(at: sqliteURL, jsonl: jsonl)
                sqliteReports.append(inspection.report)
                indexedIDs.formUnion(inspection.rows.map(\.id))
                findings.append(contentsOf: inspection.findings)
            } catch {
                findings.append(ProfileDiagnosticFinding(
                    code: "sqlite.unreadable",
                    severity: .error,
                    message: L10n.text("diagnostics.finding.sqlite-unreadable", fallback: "SQLite索引を読み取れません。"),
                    path: sqliteURL.path
                ))
            }
        }

        let stateSQLiteURLs = sqliteURLs.filter { $0.lastPathComponent.hasPrefix("state_") }
        if !jsonl.isEmpty && stateSQLiteURLs.isEmpty {
            findings.append(ProfileDiagnosticFinding(
                code: "sqlite.state-index-missing",
                severity: .error,
                message: L10n.text("diagnostics.finding.state-index-missing", fallback: "セッションJSONLはありますが、state SQLite索引が見つかりません。"),
                path: codexHome.path,
                repairable: false
            ))
        }

        let ids = Dictionary(grouping: jsonl, by: \.id)
        for (id, files) in ids where files.count > 1 {
            findings.append(ProfileDiagnosticFinding(
                code: "session.duplicate-id",
                severity: .error,
                message: L10n.text("diagnostics.finding.duplicate-session", fallback: "同じセッションIDのJSONLが複数あります。"),
                path: files.first?.url.path
            ))
            _ = id
        }
        let allSessionIDs = Set(ids.keys)
        let unindexed = allSessionIDs.subtracting(indexedIDs)
        if !unindexed.isEmpty && !sqliteURLs.isEmpty {
            findings.append(ProfileDiagnosticFinding(
                code: "session.unindexed",
                severity: .warning,
                message: L10n.text("diagnostics.finding.unindexed-session", fallback: "SQLiteに登録されていないセッションがあります。"),
                path: codexHome.path,
                repairable: false
            ))
        }

        return report(profileID: profileID, root: root, checks: checks, findings: findings, sqlite: sqliteReports)
    }

    func repairIndex(root: URL, profileID: UUID) throws -> ProfileRepairResult {
        let profile = AccountProfile(
            name: root.lastPathComponent,
            profileID: profileID,
            directoryName: root.lastPathComponent,
            lastKnownPath: root.standardizedFileURL.path
        )
        return try repairIndex(profile: profile)
    }

    func repairIndex(profile: AccountProfile) throws -> ProfileRepairResult {
        let operationID = UUID()
        let startedAt = Date()
        let root = ProfilePaths(profile: profile, baseDirectory: baseDirectory).root.standardizedFileURL
        let snapshot = recoverySnapshotsDirectory.appendingPathComponent(operationID.uuidString, isDirectory: true)
        let logURL = diagnosticsLogsDirectory.appendingPathComponent("\(operationID.uuidString).json", isDirectory: false)
        var findings: [ProfileDiagnosticFinding] = []
        var updated = 0
        var skipped = 0
        var rolledBack = false
        var rollbackFailure: Error?

        do {
            guard !isChatGPTRunning() else { throw ProfileManagerError.codexMustBeClosed }
            var isRootDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isRootDirectory), isRootDirectory.boolValue else {
                throw ProfileManagerError.profileRootMissing
            }
            let profilePaths = ProfilePaths(root: root)
            let maintenanceLockURL = profilePaths.maintenanceLockURL()
            _ = ProfileFileLock.recoverStaleOwned(
                at: maintenanceLockURL,
                fileManager: fileManager,
                minimumAge: 15
            )
            let maintenanceLock: ProfileFileLock
            do {
                maintenanceLock = try ProfileFileLock.acquireOwned(at: maintenanceLockURL, fileManager: fileManager)
            } catch {
                throw ProfileManagerError.profileMaintenanceInProgress
            }
            defer { maintenanceLock.release() }

            let baseDirectory = self.baseDirectory
            let launcherStore = ProfileLauncherStore(baseDirectory: baseDirectory, fileManager: fileManager)
            launcherStore.recoverStaleRunningLock(for: profile)
            let runningLockURL = ProfileLauncherStore.runningLockURL(baseDirectory: baseDirectory, profileID: profile.profileID)
            let runningLock: ProfileFileLock
            do {
                runningLock = try ProfileFileLock.acquireEmpty(at: runningLockURL, fileManager: fileManager)
            } catch {
                throw ProfileManagerError.profileAlreadyRunning
            }
            defer { runningLock.release() }

            let before = diagnose(profile: profile)
            if before.findings.contains(where: { $0.code == "marker.mismatch" || $0.code == "marker.invalid" }) {
                throw ProfileManagerError.profileMarkerMismatch
            }
            let codexHome = root.appendingPathComponent("CodexHome", isDirectory: true)
            let databases = sqliteFiles(in: codexHome)
            guard !databases.isEmpty else { throw ProfileManagerError.unknownProfileSchema }
            try fileManager.createDirectory(at: snapshot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for database in databases {
                let destination = snapshot.appendingPathComponent(database.lastPathComponent)
                try SQLiteSnapshot.copy(from: database.path, to: destination.path)
            }

            let jsonl = sessionFiles(in: codexHome)
            var repairedKnownDatabase = false
            for database in databases {
                let inspection = try inspectSQLite(at: database, jsonl: jsonl)
                if database.lastPathComponent == "thread_history_1.sqlite" {
                    // This is a derived index. It is checked for corruption,
                    // but never rebuilt by this conservative operation.
                    findings.append(contentsOf: inspection.findings)
                    continue
                }
                if !inspection.report.knownSchema {
                    findings.append(contentsOf: inspection.findings)
                    if database.lastPathComponent.hasPrefix("state_") {
                        throw ProfileManagerError.unknownProfileSchema
                    }
                    continue
                }
                repairedKnownDatabase = true
                do {
                    let outcome = try repairSQLite(at: database, jsonl: jsonl)
                    updated += outcome.updated
                    skipped += outcome.skipped
                    findings.append(contentsOf: outcome.findings)
                } catch {
                    throw error
                }
            }
            guard repairedKnownDatabase else { throw ProfileManagerError.unknownProfileSchema }
            let after = diagnose(profile: profile)
            if after.sqlite.contains(where: { !$0.quickCheckPassed || !$0.foreignKeyCheckPassed }) {
                throw ProfileManagerError.unknownProfileSchema
            }
            let result = ProfileRepairResult(
                operationID: operationID,
                profileID: profile.profileID,
                updatedPathCount: updated,
                skippedAmbiguousCount: skipped,
                success: true,
                rolledBack: false,
                snapshotDirectory: snapshot,
                logURL: logURL,
                findings: findings
            )
            try writeLog(ProfileRepairLog(operationID: operationID, profileID: profile.profileID, startedAt: startedAt, finishedAt: Date(), operation: "index-rebuild", result: "success", updatedPathCount: updated, skippedAmbiguousCount: skipped, findings: findings), to: logURL)
            return result
        } catch {
            let operationError = error
            if !rolledBack, fileManager.fileExists(atPath: snapshot.path) {
                do {
                    // A post-check failure may occur after all DBs were
                    // changed. Restore each snapshot through a same-directory
                    // temporary SQLite backup and atomic rename. The original
                    // database is never removed before the replacement exists.
                    try restoreSnapshots(from: snapshot, to: root)
                    rolledBack = true
                } catch let error {
                    rollbackFailure = error
                    findings.append(ProfileDiagnosticFinding(
                        code: "repair.rollback-failed",
                        severity: .error,
                        message: L10n.text(
                            "diagnostics.finding.rollback-failed",
                            fallback: "修復失敗後のSQLite復元にも失敗しました。元のデータを削除せず停止しました。"
                        ),
                        path: snapshot.path
                    ))
                }
            }
            let finalError: Error = rollbackFailure == nil
                ? operationError
                : ProfileManagerError.profileRepairRollbackFailed
            let finding = ProfileDiagnosticFinding(
                code: "repair.failed",
                severity: .error,
                message: operationError.localizedDescription,
                path: root.path
            )
            findings.append(finding)
            let result = rollbackFailure == nil
                ? (rolledBack ? "rollback" : "failure")
                : "rollback-failed"
            try? writeLog(ProfileRepairLog(operationID: operationID, profileID: profile.profileID, startedAt: startedAt, finishedAt: Date(), operation: "index-rebuild", result: result, updatedPathCount: updated, skippedAmbiguousCount: skipped, findings: findings), to: logURL)
            throw finalError
        }
    }

    func logURLs() -> [URL] {
        guard let urls = try? fileManager.contentsOfDirectory(at: diagnosticsLogsDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        return urls.filter { $0.pathExtension == "json" }.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
            if lhsDate != rhsDate {
                return (lhsDate ?? .distantPast) > (rhsDate ?? .distantPast)
            }
            return lhs.lastPathComponent > rhs.lastPathComponent
        }
    }

    func readLog(at url: URL) -> ProfileRepairLog? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ProfileRepairLog.self, from: data)
    }

    private func report(profileID: UUID, root: URL, checks: [String: Bool], findings: [ProfileDiagnosticFinding], sqlite: [SQLiteDiagnostic]) -> ProfileDiagnosticReport {
        let status: ProfileDiagnosticStatus
        if findings.contains(where: { $0.severity == .error }) {
            status = checks["rootExists"] == false ? .missing : .needsAttention
        } else if findings.contains(where: { $0.severity == .warning }) {
            status = .needsAttention
        } else {
            status = .healthy
        }
        return ProfileDiagnosticReport(profileID: profileID, root: root.path, status: status, createdAt: Date(), checks: checks, findings: findings, sqlite: sqlite)
    }

    private func inspectSettings(root: URL, profileID: UUID, checks: inout [String: Bool], findings: inout [ProfileDiagnosticFinding]) {
        // Keep this path sourced from SettingsSharingStore so diagnostics and
        // the writer cannot silently drift apart. The nested path is only a
        // backward-compatible read fallback for pre-migration installations.
        let registryStore = SettingsSharingStore(baseDirectory: baseDirectory, fileManager: fileManager)
        let registryURL = registryStore.registryURL
        let legacyRegistryURL = baseDirectory
            .appendingPathComponent("Settings", isDirectory: true)
            .appendingPathComponent("SettingsRegistry.json", isDirectory: false)
        let data: Data?
        let sourceURL: URL
        if let current = try? Data(contentsOf: registryURL) {
            data = current
            sourceURL = registryURL
        } else {
            data = try? Data(contentsOf: legacyRegistryURL)
            sourceURL = legacyRegistryURL
        }
        guard let data else {
            checks["settingsRegistryReadable"] = true
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let registry = try? decoder.decode(SettingsRegistry.self, from: data) else {
            checks["settingsRegistryReadable"] = false
            findings.append(ProfileDiagnosticFinding(code: "settings.registry-invalid", severity: .warning, message: L10n.text("diagnostics.finding.settings-registry", fallback: "設定共有レジストリを読み取れません。"), path: sourceURL.path))
            return
        }
        let stable = ProfileStorageReference.isolatedProfile(profileID: profileID)
        let legacy = registry.bindings.first { binding in
            if case let .isolated(directoryName) = binding.profile {
                return root.lastPathComponent.compare(directoryName, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame
            }
            return false
        }
        checks["settingsReference"] = registry.bindings.contains { $0.profile == stable } || legacy != nil
        for item in ["AGENTS.md", "AGENTS.override.md", "config.toml", "rules"] {
            let url = root.appendingPathComponent("CodexHome", isDirectory: true).appendingPathComponent(item)
            guard isSymlink(url) else { continue }
            guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
                findings.append(ProfileDiagnosticFinding(code: "settings.symlink-broken", severity: .error, message: L10n.text("diagnostics.finding.settings-symlink-broken", fallback: "設定ファイルのシンボリックリンクを読み取れません。"), path: url.path))
                continue
            }
            let resolved = URL(fileURLWithPath: destination, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
            guard fileManager.fileExists(atPath: resolved.path) else {
                findings.append(ProfileDiagnosticFinding(code: "settings.symlink-broken", severity: .error, message: L10n.text("diagnostics.finding.settings-symlink-broken", fallback: "設定ファイルのシンボリックリンク先が見つかりません。"), path: url.path))
                continue
            }
            if !resolved.path.hasPrefix(baseDirectory.standardizedFileURL.path + "/Settings/") {
                findings.append(ProfileDiagnosticFinding(code: "settings.symlink-outside", severity: .warning, message: L10n.text("diagnostics.finding.settings-symlink", fallback: "設定ファイルが管理外のシンボリックリンクを参照しています。"), path: url.path))
            }
        }
    }

    private func sqliteFiles(in directory: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL, url.pathExtension == "sqlite", url.lastPathComponent.hasPrefix("state_") || url.lastPathComponent == "thread_history_1.sqlite" else { return nil }
            return url
        }.sorted { $0.path < $1.path }
    }

    private func sessionFiles(in directory: URL) -> [JSONLSession] {
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        return enumerator.compactMap { item -> JSONLSession? in
            guard let url = item as? URL, url.pathExtension == "jsonl", let id = sessionID(in: url) else { return nil }
            return JSONLSession(id: id, url: url)
        }
    }

    private func sessionID(in url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1_048_576), let line = String(data: data, encoding: .utf8)?.split(whereSeparator: \.isNewline).first, let lineData = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any], object["type"] as? String == "session_meta", let payload = object["payload"] as? [String: Any], let id = payload["id"] as? String, !id.isEmpty else { return nil }
        return id
    }

    private func inspectSQLite(at url: URL, jsonl: [JSONLSession]) throws -> (report: SQLiteDiagnostic, rows: [ThreadRow], findings: [ProfileDiagnosticFinding]) {
        let db = try SQLiteReadOnly(path: url.path)
        let quick = try db.scalar("PRAGMA quick_check(1)") == "ok"
        let foreign = try db.rows("PRAGMA foreign_key_check").isEmpty
        let tables = try db.rows("SELECT name FROM sqlite_master WHERE type='table'").map { $0["name"] ?? "" }
        let columns = try db.rows("PRAGMA table_info(threads)").compactMap { $0["name"] }
        let isDerivedHistory = url.lastPathComponent == "thread_history_1.sqlite"
        // state_*.sqlite is a sqlx database. The schema version is carried by
        // _sqlx_migrations while PRAGMA user_version intentionally remains 0;
        // accepting a generic `migrations` table or a non-zero pragma would
        // make a future/foreign schema look repairable.
        let migrationColumns = tables.contains("_sqlx_migrations")
            ? try db.rows("PRAGMA table_info(_sqlx_migrations)").compactMap { $0["name"] }
            : []
        let migrationRows = migrationColumns.contains("version") && migrationColumns.contains("success")
            ? try db.rows("SELECT version, success FROM _sqlx_migrations")
            : []
        let migrationVersions = migrationRows.compactMap { Int($0["version"] ?? "") }
        let hasInvalidMigrationVersion = migrationRows.contains { Int($0["version"] ?? "") == nil }
        let hasSuccessfulMigration = migrationRows.contains { row in
            guard let success = row["success"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                return false
            }
            return ["1", "true", "yes"].contains(success)
        }
        let hasFailedMigration = migrationRows.contains { row in
            guard let success = row["success"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                return true
            }
            return ["0", "false", "no"].contains(success)
        }
        let hasInvalidMigrationSuccess = migrationRows.contains { row in
            guard let success = row["success"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                return true
            }
            return !["0", "1", "false", "true", "no", "yes"].contains(success)
        }
        let maxMigration = migrationVersions.max() ?? 0
        let migrationMetadataKnown = tables.contains("_sqlx_migrations")
            && migrationColumns.contains("version")
            && migrationColumns.contains("success")
            && hasSuccessfulMigration
            && !hasInvalidMigrationVersion
            && !hasFailedMigration
            && !hasInvalidMigrationSuccess
            && maxMigration <= 52
        let userVersion = Int(try db.scalar("PRAGMA user_version") ?? "0") ?? -1
        let known = isDerivedHistory || (tables.contains("threads") && columns.contains("id") && columns.contains("rollout_path") && userVersion == 0 && migrationMetadataKnown)
        var findings: [ProfileDiagnosticFinding] = []
        if !quick { findings.append(ProfileDiagnosticFinding(code: "sqlite.quick-check", severity: .error, message: L10n.text("diagnostics.finding.sqlite-quick-check", fallback: "SQLite quick_check が失敗しました。"), path: url.path)) }
        if !foreign { findings.append(ProfileDiagnosticFinding(code: "sqlite.foreign-key", severity: .error, message: L10n.text("diagnostics.finding.sqlite-foreign-key", fallback: "SQLiteの外部キー整合性が壊れています。"), path: url.path)) }
        if hasFailedMigration || hasInvalidMigrationVersion || hasInvalidMigrationSuccess || maxMigration > 52 {
            findings.append(ProfileDiagnosticFinding(code: "sqlite.migration-invalid", severity: .error, message: L10n.text("diagnostics.finding.sqlite-migration-invalid", fallback: "SQLiteのマイグレーション状態が未対応または失敗しています。修復は行いません。"), path: url.path))
        }
        if !known { findings.append(ProfileDiagnosticFinding(code: "sqlite.unknown-schema", severity: .warning, message: L10n.text("diagnostics.finding.sqlite-unknown-schema", fallback: "未対応のSQLiteスキーマです。修復は行いません。"), path: url.path)) }
        var rows: [ThreadRow] = []
        if known && !isDerivedHistory {
            rows = try db.rows("SELECT id, rollout_path FROM threads").compactMap { row in
                guard let id = row["id"] else { return nil }
                return ThreadRow(id: id, rolloutPath: row["rollout_path"])
            }
            let knownByID = Dictionary(grouping: jsonl, by: \.id)
            for row in rows where row.rolloutPath.map({ !fileManager.fileExists(atPath: resolvedRolloutURL($0, relativeTo: url).path) }) ?? false {
                let basename = URL(fileURLWithPath: row.rolloutPath!).lastPathComponent
                let candidates = jsonl.filter { $0.url.lastPathComponent == basename || $0.id == row.id }
                if candidates.isEmpty { findings.append(ProfileDiagnosticFinding(code: "sqlite.missing-rollout", severity: .error, message: L10n.text("diagnostics.finding.missing-rollout", fallback: "スレッドが参照するJSONLがありません。"), path: row.rolloutPath)) }
                else if candidates.count == 1 && candidates[0].id == row.id { findings.append(ProfileDiagnosticFinding(code: "sqlite.missing-rollout", severity: .warning, message: L10n.text("diagnostics.finding.missing-rollout-repairable", fallback: "スレッドのJSONL参照先が移動しています。修復できます。"), path: row.rolloutPath, repairable: true)) }
                else if candidates.count > 1 || (knownByID[row.id]?.count ?? 0) > 1 { findings.append(ProfileDiagnosticFinding(code: "sqlite.ambiguous-rollout", severity: .warning, message: L10n.text("diagnostics.finding.ambiguous-rollout", fallback: "参照先を一意に決められないため修復しません。"), path: row.rolloutPath)) }
            }
            if tables.contains("rollout_migration_skipped_rollouts"),
               try db.rows("PRAGMA table_info(rollout_migration_skipped_rollouts)").contains(where: { $0["name"] == "rollout_path" }) {
                let skippedRows = try db.rows("SELECT rollout_path FROM rollout_migration_skipped_rollouts")
                for row in skippedRows.compactMap({ $0["rollout_path"] }) where !fileManager.fileExists(atPath: resolvedRolloutURL(row, relativeTo: url).path) {
                    findings.append(ProfileDiagnosticFinding(code: "sqlite.missing-skipped-rollout", severity: .warning, message: L10n.text("diagnostics.finding.missing-skipped-rollout", fallback: "移行保留リストが参照するJSONLがありません。"), path: row))
                }
            }
        }
        return (SQLiteDiagnostic(path: url.path, knownSchema: known, quickCheckPassed: quick, foreignKeyCheckPassed: foreign, threadCount: rows.count, indexedSessionIDs: rows.map(\.id), referencedRolloutPaths: rows.compactMap(\.rolloutPath)), rows, findings)
    }

    private func repairSQLite(at url: URL, jsonl: [JSONLSession]) throws -> (updated: Int, skipped: Int, findings: [ProfileDiagnosticFinding]) {
        let db = try SQLiteWritable(path: url.path)
        let before = try inspectSQLite(at: url, jsonl: jsonl)
        guard before.report.knownSchema else { throw ProfileManagerError.unknownProfileSchema }
        let byID = Dictionary(grouping: jsonl, by: \.id)
        let byBasename = Dictionary(grouping: jsonl, by: { $0.url.lastPathComponent })
        try db.exec("BEGIN IMMEDIATE TRANSACTION")
        var updated = 0
        var skipped = 0
        var findings: [ProfileDiagnosticFinding] = []
        do {
            for row in before.rows {
                guard let oldPath = row.rolloutPath, !fileManager.fileExists(atPath: resolvedRolloutURL(oldPath, relativeTo: url).path) else { continue }
                let candidates: [JSONLSession]
                if let exact = byID[row.id], exact.count == 1 {
                    candidates = exact
                } else {
                    // A basename is only a location hint. It is never enough
                    // to rewrite a row unless the session_meta ID also agrees.
                    candidates = (byBasename[URL(fileURLWithPath: oldPath).lastPathComponent] ?? [])
                        .filter { $0.id == row.id }
                }
                guard candidates.count == 1 else {
                    skipped += 1
                    findings.append(ProfileDiagnosticFinding(code: "repair.ambiguous-rollout", severity: .warning, message: L10n.text("diagnostics.finding.repair-skipped", fallback: "候補が一意でない参照は修復しませんでした。"), path: oldPath))
                    continue
                }
                try db.updateThreadsPath(id: row.id, oldPath: oldPath, newPath: candidates[0].url.path)
                updated += 1
            }
            if try db.rows("SELECT name FROM sqlite_master WHERE type='table' AND name='rollout_migration_skipped_rollouts'").first != nil {
                let skippedRows = try db.rows("SELECT rollout_path FROM rollout_migration_skipped_rollouts")
                for oldPath in skippedRows.compactMap({ $0["rollout_path"] }) where !fileManager.fileExists(atPath: resolvedRolloutURL(oldPath, relativeTo: url).path) {
                    let candidates = byBasename[URL(fileURLWithPath: oldPath).lastPathComponent] ?? []
                    guard candidates.count == 1 else {
                        skipped += 1
                        continue
                    }
                    try db.updateSkippedPath(oldPath: oldPath, newPath: candidates[0].url.path)
                    updated += 1
                }
            }
            let quick = try db.scalar("PRAGMA quick_check(1)") == "ok"
            let foreign = try db.rows("PRAGMA foreign_key_check").isEmpty
            guard quick && foreign else { throw ProfileManagerError.unknownProfileSchema }
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
        return (updated, skipped, findings)
    }

    private func writeLog(_ log: ProfileRepairLog, to url: URL) throws {
        try fileManager.createDirectory(at: diagnosticsLogsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(log).write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func resolvedRolloutURL(_ path: String, relativeTo databaseURL: URL) -> URL {
        let url = URL(fileURLWithPath: path)
        guard !url.path.hasPrefix("/") else { return url.standardizedFileURL }
        return databaseURL.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
    }

    private func restoreSnapshots(from snapshot: URL, to root: URL) throws {
        let snapshotDatabases = try fileManager.contentsOfDirectory(
            at: snapshot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "sqlite" }
        guard !snapshotDatabases.isEmpty else {
            throw ProfileManagerError.profileRepairRollbackFailed
        }
        let codexHome = root.appendingPathComponent("CodexHome", isDirectory: true)
        for saved in snapshotDatabases {
            let destination = codexHome.appendingPathComponent(saved.lastPathComponent, isDirectory: false)
            try restoreSQLiteAtomically(from: saved, to: destination)
        }
    }

    private func restoreSQLiteAtomically(from snapshot: URL, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent)-restore-\(UUID().uuidString).sqlite",
            isDirectory: false
        )
        var installed = false
        defer {
            if !installed {
                unlinkKnownFile(at: temporary)
            }
        }

        try SQLiteSnapshot.copy(from: snapshot.path, to: temporary.path)
        if let attributes = try? fileManager.attributesOfItem(atPath: destination.path),
           let permissions = attributes[.posixPermissions] {
            try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
        }

        let renameResult = temporary.path.withCString { source in
            destination.path.withCString { target in
                Darwin.rename(source, target)
            }
        }
        guard renameResult == 0 else {
            throw ProfileManagerError.profileRepairRollbackFailed
        }
        installed = true
        try removeSQLiteSidecarsSafely(for: destination)
    }

    private func removeSQLiteSidecarsSafely(for database: URL) throws {
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: database.path + suffix)
            var info = stat()
            let exists = sidecar.path.withCString { path in
                lstat(path, &info) == 0
            }
            guard exists else { continue }
            // unlink removes a regular file or symlink but refuses a
            // directory, preserving unexpected data instead of recursing.
            guard (info.st_mode & S_IFMT) != S_IFDIR,
                  sidecar.path.withCString({ Darwin.unlink($0) == 0 }) else {
                throw ProfileManagerError.profileRepairRollbackFailed
            }
        }
    }

    private func unlinkKnownFile(at url: URL) {
        _ = url.path.withCString { Darwin.unlink($0) }
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }
}

private final class SQLiteReadOnly {
    let handle: OpaquePointer

    init(path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else { throw ProfileManagerError.unknownProfileSchema }
        self.handle = handle
        sqlite3_busy_timeout(handle, 2_000)
    }

    deinit { sqlite3_close(handle) }

    func scalar(_ sql: String) throws -> String? {
        let rows = try rows(sql)
        return rows.first?.values.first
    }

    func rows(_ sql: String) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw ProfileManagerError.unknownProfileSchema }
        defer { sqlite3_finalize(statement) }
        var result: [[String: String]] = []
        let count = sqlite3_column_count(statement)
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            var row: [String: String] = [:]
            for index in 0..<count {
                let name = String(cString: sqlite3_column_name(statement, index))
                if let value = sqlite3_column_text(statement, index) { row[name] = String(cString: value) }
            }
            result.append(row)
            stepResult = sqlite3_step(statement)
        }
        guard stepResult == SQLITE_DONE else { throw ProfileManagerError.unknownProfileSchema }
        return result
    }
}

private final class SQLiteWritable {
    let handle: OpaquePointer

    init(path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else { throw ProfileManagerError.unknownProfileSchema }
        self.handle = handle
        sqlite3_busy_timeout(handle, 2_000)
    }

    deinit { sqlite3_close(handle) }

    func exec(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        defer { if let errorMessage { sqlite3_free(errorMessage) } }
        guard result == SQLITE_OK else { throw ProfileManagerError.unknownProfileSchema }
    }

    func scalar(_ sql: String) throws -> String? {
        try rows(sql).first?.values.first
    }

    func rows(_ sql: String) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw ProfileManagerError.unknownProfileSchema }
        defer { sqlite3_finalize(statement) }
        var result: [[String: String]] = []
        let count = sqlite3_column_count(statement)
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            var row: [String: String] = [:]
            for index in 0..<count {
                let name = String(cString: sqlite3_column_name(statement, index))
                if let value = sqlite3_column_text(statement, index) { row[name] = String(cString: value) }
            }
            result.append(row)
            stepResult = sqlite3_step(statement)
        }
        guard stepResult == SQLITE_DONE else { throw ProfileManagerError.unknownProfileSchema }
        return result
    }

    func updateThreadsPath(id: String, oldPath: String, newPath: String) throws {
        let sql = "UPDATE threads SET rollout_path = ? WHERE id = ? AND rollout_path = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw ProfileManagerError.unknownProfileSchema }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, newPath, -1, transient)
        sqlite3_bind_text(statement, 2, id, -1, transient)
        sqlite3_bind_text(statement, 3, oldPath, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ProfileManagerError.unknownProfileSchema }
    }

    func updateSkippedPath(oldPath: String, newPath: String) throws {
        let sql = "UPDATE rollout_migration_skipped_rollouts SET rollout_path = ? WHERE rollout_path = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw ProfileManagerError.unknownProfileSchema }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, newPath, -1, transient)
        sqlite3_bind_text(statement, 2, oldPath, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ProfileManagerError.unknownProfileSchema }
    }
}

/// Uses SQLite's online backup API so a snapshot is consistent even when a
/// database is accompanied by WAL/SHM files. The source is opened read-only;
/// no live profile database is modified by this operation.
private enum SQLiteSnapshot {
    static func copy(from sourcePath: String, to destinationPath: String) throws {
        var source: OpaquePointer?
        var destination: OpaquePointer?
        guard sqlite3_open_v2(sourcePath, &source, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let source else {
            if let source { sqlite3_close(source) }
            throw ProfileManagerError.unknownProfileSchema
        }
        defer { sqlite3_close(source) }
        guard sqlite3_open_v2(destinationPath, &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let destination else {
            if let destination { sqlite3_close(destination) }
            throw ProfileManagerError.unknownProfileSchema
        }
        defer { sqlite3_close(destination) }
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw ProfileManagerError.unknownProfileSchema
        }
        var status = SQLITE_OK
        var attempts = 0
        repeat {
            status = sqlite3_backup_step(backup, 128)
            attempts += 1
        } while (status == SQLITE_OK || status == SQLITE_BUSY || status == SQLITE_LOCKED) && attempts < 1000
        let finishStatus = sqlite3_backup_finish(backup)
        guard (status == SQLITE_DONE || status == SQLITE_OK) && finishStatus == SQLITE_OK else {
            throw ProfileManagerError.unknownProfileSchema
        }
    }
}
