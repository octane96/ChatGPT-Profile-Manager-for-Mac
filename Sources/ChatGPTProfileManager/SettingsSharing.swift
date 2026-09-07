import Foundation

/// A storage identity that survives removing and re-registering an account.
/// AccountProfile.id is a registration id and can change when a folder is
/// registered again, so settings associations must use this value instead.
enum ProfileStorageReference: Codable, Equatable, Hashable, Sendable {
    case existingEnvironment
    case isolated(directoryName: String)
    case isolatedProfile(profileID: UUID)

    var stableKey: String {
        switch self {
        case .existingEnvironment:
            return "existing-environment"
        case let .isolated(directoryName):
            return "isolated:\(directoryName.lowercased())"
        case let .isolatedProfile(profileID):
            return "isolated-profile:\(profileID.uuidString.lowercased())"
        }
    }
}

enum ManagedSetting: String, Codable, CaseIterable, Hashable, Sendable {
    case instructions
    case config
    case rules
    case override

    var fileName: String {
        switch self {
        case .instructions:
            return "AGENTS.md"
        case .config:
            return "config.toml"
        case .rules:
            return "rules"
        case .override:
            return "AGENTS.override.md"
        }
    }

    var isDirectory: Bool {
        self == .rules
    }

    var displayName: String {
        switch self {
        case .instructions:
            return L10n.text("settings-sharing.instructions", fallback: "AGENTS.md（指示）")
        case .config:
            return L10n.text("settings-sharing.config", fallback: "config.toml（一般設定）")
        case .rules:
            return L10n.text("settings-sharing.rules", fallback: "rules（実行ルール）")
        case .override:
            return L10n.text("settings-sharing.override", fallback: "AGENTS.override.md（上書き指示）")
        }
    }

    var warning: String? {
        switch self {
        case .rules:
            return L10n.text(
                "settings-sharing.rules-warning",
                fallback: "サンドボックス外で実行できるコマンドの許可設定に影響します。"
            )
        case .override:
            return L10n.text(
                "settings-sharing.override-warning",
                fallback: "AGENTS.mdより優先される一時的な上書き指示です。"
            )
        case .config:
            return L10n.text(
                "settings-sharing.config-warning",
                fallback: "MCP接続先、環境変数、HTTPヘッダー、ワークスペース指定などが含まれる場合があります。"
            )
        case .instructions:
            return nil
        }
    }

    var explanation: String {
        switch self {
        case .instructions:
            return L10n.text(
                "settings-sharing.instructions-explanation",
                fallback: "AGENTS.mdは、Codexが作業するときに従う指示を記述するMarkdownファイルです。作業ディレクトリやプロジェクトに置いた指示が読み込まれ、回答の方針、編集ルール、確認手順などに影響します。共有すると、参加しているすべてのプロファイルが同じ指示を読み込みます。"
            )
        case .config:
            return L10n.text(
                "settings-sharing.config-explanation",
                fallback: "config.tomlは、使用するモデル、推論設定、検索などのCodex全体の設定ファイルです。MCP接続先、環境変数、HTTPヘッダー、ワークスペース指定などを記述できるため、アカウント固有の情報や機密値が含まれることがあります。共有は安全な項目だけに制限し、通常はコピー後に内容を確認してください。"
            )
        case .rules:
            return L10n.text(
                "settings-sharing.rules-explanation",
                fallback: "rulesは、Codexがコマンドを実行するときの許可・確認ルールを置くディレクトリです。共有すると、参加プロファイルで同じコマンド実行ルールが適用されます。サンドボックス外で実行できる操作の範囲が変わるため、信頼できる内容だけを共有してください。"
            )
        case .override:
            return L10n.text(
                "settings-sharing.override-explanation",
                fallback: "AGENTS.override.mdは、通常のAGENTS.mdより優先される上書き指示ファイルです。特定のディレクトリ以下だけに一時的なルールを適用したい場合に使います。共有・コピーすると意図せず既存の指示を上書きする可能性があるため、内容と配置場所を確認してください。"
            )
        }
    }
}

struct SettingsBinding: Codable, Equatable, Sendable {
    let profile: ProfileStorageReference
    let groupID: UUID
    var items: [ManagedSetting]
}

struct SettingsGroup: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var members: [ProfileStorageReference]
    var items: [ManagedSetting]
    let createdAt: Date
    var updatedAt: Date
}

struct SettingsCloneRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let source: ProfileStorageReference
    let destination: ProfileStorageReference
    let items: [ManagedSetting]
    let createdAt: Date
    let backupDirectoryName: String
}

struct SettingsRegistry: Codable, Equatable, Sendable {
    var groups: [SettingsGroup] = []
    var bindings: [SettingsBinding] = []
    var cloneHistory: [SettingsCloneRecord] = []
}

enum SettingsSharingError: LocalizedError, Equatable {
    case invalidGroupName
    case sourceAndDestinationAreSame
    case profileAlreadyShared
    case groupNotFound
    case bindingNotFound
    case sourceSettingMissing(ManagedSetting)
    case configContainsSensitiveValues
    case unsupportedSymlink
    case transactionFailed

    var errorDescription: String? {
        switch self {
        case .invalidGroupName:
            return L10n.text(
                "settings-sharing.error.invalid-group-name",
                fallback: "共有グループ名を1文字以上60文字以内で入力してください。"
            )
        case .sourceAndDestinationAreSame:
            return L10n.text(
                "settings-sharing.error.same-profile",
                fallback: "コピー元とコピー先には別のプロファイルを指定してください。"
            )
        case .profileAlreadyShared:
            return L10n.text(
                "settings-sharing.error.already-shared",
                fallback: "選択した設定は、すでに別の共有グループに紐づいています。先に共有を解除してください。"
            )
        case .groupNotFound:
            return L10n.text(
                "settings-sharing.error.group-not-found",
                fallback: "設定共有グループが見つかりませんでした。"
            )
        case .bindingNotFound:
            return L10n.text(
                "settings-sharing.error.binding-not-found",
                fallback: "このプロファイルには設定共有がありません。"
            )
        case let .sourceSettingMissing(setting):
            return L10n.text(
                "settings-sharing.error.source-missing",
                fallback: "コピー元に{setting}がありません。",
                replacing: ["setting": setting.displayName]
            )
        case .configContainsSensitiveValues:
            return L10n.text(
                "settings-sharing.error.config-sensitive",
                fallback: "config.tomlに認証情報・アカウント固有値、または共有対象外の項目が含まれているため、共有できません。設定をコピーしてください。"
            )
        case .unsupportedSymlink:
            return L10n.text(
                "settings-sharing.error.symlink",
                fallback: "既存設定に対応できないシンボリックリンクがあるため、安全に処理できません。"
            )
        case .transactionFailed:
            return L10n.text(
                "settings-sharing.error.transaction",
                fallback: "設定の変更に失敗しました。変更前の状態へ戻しました。"
            )
        }
    }
}

struct SettingsOperationSummary: Equatable, Sendable {
    let operationID: UUID
    let changedItems: [ManagedSetting]
    let backupDirectory: URL
}

final class SettingsSharingStore {
    private let fileManager: FileManager
    private let roots: SettingsRoots

    init(
        baseDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.roots = SettingsRoots(baseDirectory: baseDirectory)
    }

    var registryURL: URL { roots.registryURL }

    func loadRegistry() -> SettingsRegistry {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for url in [roots.registryURL, roots.legacyRegistryURL] {
            guard let data = try? Data(contentsOf: url),
                  let registry = try? decoder.decode(SettingsRegistry.self, from: data)
            else {
                continue
            }
            return registry
        }
        return SettingsRegistry()
    }

    func binding(for profile: ProfileStorageReference) -> SettingsBinding? {
        loadRegistry().bindings.first { $0.profile == profile }
    }

    /// Migrates a pre-stable-identity reference in SettingsRegistry.json. It
    /// updates the registry atomically and leaves the shared files/symlinks
    /// untouched, so a moved profile keeps its sharing membership.
    @discardableResult
    func migrateProfileReference(
        from oldReference: ProfileStorageReference,
        to newReference: ProfileStorageReference
    ) throws -> Bool {
        guard oldReference != newReference else { return false }
        var registry = loadRegistry()
        var changed = false

        for index in registry.bindings.indices where registry.bindings[index].profile == oldReference {
            registry.bindings[index] = SettingsBinding(
                profile: newReference,
                groupID: registry.bindings[index].groupID,
                items: registry.bindings[index].items
            )
            changed = true
        }
        for index in registry.groups.indices {
            var members = registry.groups[index].members
            let originalCount = members.count
            members.removeAll { $0 == oldReference }
            if members.count != originalCount {
                if !members.contains(newReference) { members.append(newReference) }
                members.sort { $0.stableKey < $1.stableKey }
                registry.groups[index].members = members
                registry.groups[index].updatedAt = Date()
                let groupDirectory = roots.sharedSettings.appendingPathComponent(registry.groups[index].id.uuidString, isDirectory: true)
                if fileManager.fileExists(atPath: groupDirectory.path) {
                    try saveGroupManifest(registry.groups[index], in: groupDirectory)
                }
                changed = true
            }
        }
        for index in registry.cloneHistory.indices {
            let record = registry.cloneHistory[index]
            let source = record.source == oldReference ? newReference : record.source
            let destination = record.destination == oldReference ? newReference : record.destination
            if source != record.source || destination != record.destination {
                registry.cloneHistory[index] = SettingsCloneRecord(
                    id: record.id,
                    source: source,
                    destination: destination,
                    items: record.items,
                    createdAt: record.createdAt,
                    backupDirectoryName: record.backupDirectoryName
                )
                changed = true
            }
        }
        if changed {
            try saveRegistry(registry)
        }
        return changed
    }

    func group(id: UUID) -> SettingsGroup? {
        loadRegistry().groups.first { $0.id == id }
    }

    func ensureDirectories() throws {
        for directory in [roots.root, roots.sharedSettings, roots.profileSettings, roots.backups] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    func copy(
        source: ProfileStorageReference,
        destination: ProfileStorageReference,
        items: Set<ManagedSetting>,
        codexHomes: [ProfileStorageReference: URL]
    ) throws -> SettingsOperationSummary {
        guard source != destination else {
            throw SettingsSharingError.sourceAndDestinationAreSame
        }
        guard let sourceHome = codexHomes[source], let destinationHome = codexHomes[destination] else {
            throw SettingsSharingError.transactionFailed
        }
        try ensureDirectories()

        let operationID = UUID()
        let backupDirectory = roots.backups.appendingPathComponent(operationID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        var backups: [(target: URL, backup: URL)] = []
        var changedTargets: [URL] = []
        do {
            for item in ordered(items) {
                let sourceURL = sourceHome.appendingPathComponent(item.fileName, isDirectory: item.isDirectory)
                let destinationURL = destinationHome.appendingPathComponent(item.fileName, isDirectory: item.isDirectory)
                guard fileManager.fileExists(atPath: resolvedURL(sourceURL).path) else {
                    continue
                }
                try validateNoUnsupportedSymlink(at: sourceURL)
                try fileManager.createDirectory(at: destinationHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                if fileManager.fileExists(atPath: destinationURL.path) || isSymlink(destinationURL) {
                    let backupURL = backupDirectory.appendingPathComponent(item.fileName, isDirectory: item.isDirectory)
                    try fileManager.moveItem(at: destinationURL, to: backupURL)
                    backups.append((destinationURL, backupURL))
                }
                changedTargets.append(destinationURL)
                try copyResolved(sourceURL, to: destinationURL, isDirectory: item.isDirectory)
            }

            var registry = loadRegistry()
            registry.cloneHistory.insert(
                SettingsCloneRecord(
                    id: operationID,
                    source: source,
                    destination: destination,
                    items: ordered(items),
                    createdAt: Date(),
                    backupDirectoryName: operationID.uuidString
                ),
                at: 0
            )
            registry.cloneHistory = Array(registry.cloneHistory.prefix(20))
            try saveRegistry(registry)
            return SettingsOperationSummary(operationID: operationID, changedItems: ordered(items), backupDirectory: backupDirectory)
        } catch {
            removeTargets(changedTargets)
            restore(backups)
            throw error is SettingsSharingError ? error : SettingsSharingError.transactionFailed
        }
    }

    func createShareGroup(
        name: String,
        source: ProfileStorageReference,
        destinations: [ProfileStorageReference],
        items: Set<ManagedSetting>,
        codexHomes: [ProfileStorageReference: URL]
    ) throws -> SettingsGroup {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, normalizedName.count <= 60 else {
            throw SettingsSharingError.invalidGroupName
        }
        let members = Array(Set([source] + destinations))
        guard members.count >= 2 else {
            throw SettingsSharingError.sourceAndDestinationAreSame
        }
        guard let sourceHome = codexHomes[source] else {
            throw SettingsSharingError.transactionFailed
        }
        let selectedItems = ordered(items)
        guard !selectedItems.isEmpty else {
            throw SettingsSharingError.transactionFailed
        }

        let currentRegistry = loadRegistry()
        for member in members {
            if currentRegistry.bindings.contains(where: { $0.profile == member }) {
                throw SettingsSharingError.profileAlreadyShared
            }
        }

        try ensureDirectories()
        let operationID = UUID()
        let groupID = UUID()
        let groupDirectory = roots.sharedSettings.appendingPathComponent(groupID.uuidString, isDirectory: true)
        let backupDirectory = roots.backups.appendingPathComponent(operationID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: groupDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        var backups: [(target: URL, backup: URL)] = []
        var linkedTargets: [URL] = []
        do {
            for item in selectedItems {
                let sourceURL = sourceHome.appendingPathComponent(item.fileName, isDirectory: item.isDirectory)
                let canonicalURL = groupDirectory.appendingPathComponent(item.fileName, isDirectory: item.isDirectory)
                if item == .config, fileManager.fileExists(atPath: resolvedURL(sourceURL).path) {
                    guard !configContainsSensitiveValues(at: sourceURL) else {
                        throw SettingsSharingError.configContainsSensitiveValues
                    }
                }
                if fileManager.fileExists(atPath: resolvedURL(sourceURL).path) {
                    try validateNoUnsupportedSymlink(at: sourceURL)
                    try copyResolved(sourceURL, to: canonicalURL, isDirectory: item.isDirectory)
                } else if item.isDirectory {
                    try fileManager.createDirectory(at: canonicalURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                } else {
                    try Data().write(to: canonicalURL, options: .atomic)
                    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: canonicalURL.path)
                }
            }

            for member in members {
                guard let home = codexHomes[member] else { throw SettingsSharingError.transactionFailed }
                try fileManager.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                for item in selectedItems {
                    let target = home.appendingPathComponent(item.fileName, isDirectory: item.isDirectory)
                    let canonical = groupDirectory.appendingPathComponent(item.fileName, isDirectory: item.isDirectory)
                    if fileManager.fileExists(atPath: target.path) || isSymlink(target) {
                        let backupURL = backupDirectory.appendingPathComponent("\(member.stableKey.replacingOccurrences(of: ":", with: "_"))_\(item.fileName)", isDirectory: item.isDirectory)
                        try fileManager.moveItem(at: target, to: backupURL)
                        backups.append((target, backupURL))
                    }
                    linkedTargets.append(target)
                    try fileManager.createSymbolicLink(at: target, withDestinationURL: canonical)
                }
            }

            let now = Date()
            let group = SettingsGroup(id: groupID, name: normalizedName, members: members.sorted { $0.stableKey < $1.stableKey }, items: selectedItems, createdAt: now, updatedAt: now)
            var registry = currentRegistry
            registry.groups.append(group)
            for member in members {
                registry.bindings.removeAll { $0.profile == member }
                registry.bindings.append(SettingsBinding(profile: member, groupID: groupID, items: selectedItems))
            }
            try saveGroupManifest(group, in: groupDirectory)
            try saveRegistry(registry)
            return group
        } catch {
            removeTargets(linkedTargets)
            restore(backups)
            try? fileManager.removeItem(at: groupDirectory)
            throw error is SettingsSharingError ? error : SettingsSharingError.transactionFailed
        }
    }

    func joinShareGroup(
        groupID: UUID,
        profile: ProfileStorageReference,
        codexHome: URL
    ) throws -> SettingsGroup {
        guard let group = group(id: groupID) else {
            throw SettingsSharingError.groupNotFound
        }
        let currentRegistry = loadRegistry()
        if let binding = currentRegistry.bindings.first(where: { $0.profile == profile }) {
            if binding.groupID == groupID { return group }
            throw SettingsSharingError.profileAlreadyShared
        }

        let groupDirectory = roots.sharedSettings.appendingPathComponent(groupID.uuidString, isDirectory: true)
        guard fileManager.fileExists(atPath: groupDirectory.path) else {
            throw SettingsSharingError.groupNotFound
        }
        try ensureDirectories()
        let operationID = UUID()
        let backupDirectory = roots.backups.appendingPathComponent(operationID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var backups: [(target: URL, backup: URL)] = []
        var linkedTargets: [URL] = []

        do {
            try fileManager.createDirectory(at: codexHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for item in group.items {
                let canonical = groupDirectory.appendingPathComponent(item.fileName, isDirectory: item.isDirectory)
                guard fileManager.fileExists(atPath: canonical.path) else {
                    throw SettingsSharingError.groupNotFound
                }
                let target = codexHome.appendingPathComponent(item.fileName, isDirectory: item.isDirectory)
                if fileManager.fileExists(atPath: target.path) || isSymlink(target) {
                    let backupURL = backupDirectory.appendingPathComponent(item.fileName, isDirectory: item.isDirectory)
                    try fileManager.moveItem(at: target, to: backupURL)
                    backups.append((target, backupURL))
                }
                linkedTargets.append(target)
                try fileManager.createSymbolicLink(at: target, withDestinationURL: canonical)
            }

            var registry = currentRegistry
            registry.bindings.append(SettingsBinding(profile: profile, groupID: groupID, items: group.items))
            if let groupIndex = registry.groups.firstIndex(where: { $0.id == groupID }) {
                registry.groups[groupIndex].members.append(profile)
                registry.groups[groupIndex].members.sort { $0.stableKey < $1.stableKey }
                registry.groups[groupIndex].updatedAt = Date()
            }
            if let updatedGroup = registry.groups.first(where: { $0.id == groupID }) {
                try saveGroupManifest(updatedGroup, in: groupDirectory)
            }
            try saveRegistry(registry)
            return registry.groups.first(where: { $0.id == groupID }) ?? group
        } catch {
            removeTargets(linkedTargets)
            restore(backups)
            throw error is SettingsSharingError ? error : SettingsSharingError.transactionFailed
        }
    }

    func leaveShareGroup(
        profile: ProfileStorageReference,
        codexHome: URL
    ) throws -> SettingsGroup {
        guard let binding = binding(for: profile), let group = group(id: binding.groupID) else {
            throw SettingsSharingError.bindingNotFound
        }
        try ensureDirectories()

        var sharedTargets: [(target: URL, canonical: URL)] = []
        for item in binding.items {
            let target = codexHome.appendingPathComponent(item.fileName, isDirectory: item.isDirectory)
            if isSymlink(target), !fileManager.fileExists(atPath: resolvedURL(target).path) {
                throw SettingsSharingError.transactionFailed
            }
            if isSymlink(target) {
                sharedTargets.append(
                    (
                        target,
                        resolvedURL(target)
                    )
                )
            }
        }

        do {
            for item in binding.items {
                let target = codexHome.appendingPathComponent(item.fileName, isDirectory: item.isDirectory)
                guard isSymlink(target) else { continue }
                let temporary = codexHome.appendingPathComponent(".profile-manager-unshare-\(UUID().uuidString)", isDirectory: item.isDirectory)
                try copyResolved(target, to: temporary, isDirectory: item.isDirectory)
                try fileManager.removeItem(at: target)
                try fileManager.moveItem(at: temporary, to: target)
            }
            var registry = loadRegistry()
            registry.bindings.removeAll { $0.profile == profile }
            if let groupIndex = registry.groups.firstIndex(where: { $0.id == group.id }) {
                registry.groups[groupIndex].members.removeAll { $0 == profile }
                registry.groups[groupIndex].updatedAt = Date()
                let groupDirectory = roots.sharedSettings.appendingPathComponent(group.id.uuidString, isDirectory: true)
                try saveGroupManifest(registry.groups[groupIndex], in: groupDirectory)
            }
            try saveRegistry(registry)
            return group
        } catch {
            for entry in sharedTargets.reversed() {
                if fileManager.fileExists(atPath: entry.target.path) || isSymlink(entry.target) {
                    try? fileManager.removeItem(at: entry.target)
                }
                try? fileManager.createSymbolicLink(at: entry.target, withDestinationURL: entry.canonical)
            }
            throw error is SettingsSharingError ? error : SettingsSharingError.transactionFailed
        }
    }

    private func ordered(_ items: Set<ManagedSetting>) -> [ManagedSetting] {
        ManagedSetting.allCases.filter { items.contains($0) }
    }

    private func saveRegistry(_ registry: SettingsRegistry) throws {
        try ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(registry)
        let temporary = roots.registryURL.deletingLastPathComponent()
            .appendingPathComponent(".SettingsRegistry-\(UUID().uuidString).json")
        try data.write(to: temporary, options: .atomic)
        if fileManager.fileExists(atPath: roots.registryURL.path) {
            _ = try fileManager.replaceItemAt(roots.registryURL, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: roots.registryURL)
        }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: roots.registryURL.path)
    }

    private func saveGroupManifest(_ group: SettingsGroup, in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(group)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        try data.write(to: manifestURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
    }

    private func copyResolved(_ source: URL, to destination: URL, isDirectory: Bool) throws {
        let resolvedSource = resolvedURL(source)
        if fileManager.fileExists(atPath: destination.path) || isSymlink(destination) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.copyItem(at: resolvedSource, to: destination)
        if !isDirectory {
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
    }

    private func restore(_ backups: [(target: URL, backup: URL)]) {
        for entry in backups.reversed() {
            if fileManager.fileExists(atPath: entry.target.path) || isSymlink(entry.target) {
                try? fileManager.removeItem(at: entry.target)
            }
            try? fileManager.moveItem(at: entry.backup, to: entry.target)
        }
    }

    private func removeTargets(_ targets: [URL]) {
        for target in targets.reversed() {
            if fileManager.fileExists(atPath: target.path) || isSymlink(target) {
                try? fileManager.removeItem(at: target)
            }
        }
    }

    private func isSymlink(_ url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return false
        }
        return (attributes[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    private func resolvedURL(_ url: URL) -> URL {
        guard isSymlink(url), let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return url
        }
        let destinationURL = URL(fileURLWithPath: destination, relativeTo: url.deletingLastPathComponent())
        return destinationURL.standardizedFileURL
    }

    private func validateNoUnsupportedSymlink(at url: URL) throws {
        if isSymlink(url) {
            let resolved = resolvedURL(url)
            let rootPath = roots.root.standardizedFileURL.path
            guard resolved.path == rootPath || resolved.path.hasPrefix(rootPath + "/") else {
                throw SettingsSharingError.unsupportedSymlink
            }
        }
    }

    private func configContainsSensitiveValues(at url: URL) -> Bool {
        guard let text = try? String(contentsOf: resolvedURL(url), encoding: .utf8) else {
            return true
        }
        // Live sharing accepts only a small set of scalar, account-neutral
        // values. Any table, nested setting, unknown key, or malformed line is
        // rejected so new Codex settings cannot accidentally expose a secret.
        let shareableKeys: Set<String> = [
            "model",
            "model_reasoning_effort",
            "model_context_window",
            "service_tier",
            "personality",
            "web_search",
            "show_raw_agent_reasoning",
            "hide_agent_reasoning",
            "file_opener"
        ]
        return text.split(whereSeparator: \.isNewline).contains { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !line.isEmpty, !line.hasPrefix("#") else { return false }
            guard !line.hasPrefix("[") else { return true }
            guard let equalsIndex = line.firstIndex(of: "=") else { return true }
            let key = line[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            return !shareableKeys.contains(String(key))
        }
    }
}

private struct SettingsRoots {
    let root: URL
    let sharedSettings: URL
    let profileSettings: URL
    let backups: URL
    let registryURL: URL
    let legacyRegistryURL: URL

    init(baseDirectory: URL) {
        root = baseDirectory.appendingPathComponent("Settings", isDirectory: true)
        sharedSettings = root.appendingPathComponent("SharedSettings", isDirectory: true)
        profileSettings = root.appendingPathComponent("ProfileSettings", isDirectory: true)
        backups = root.appendingPathComponent("Backups", isDirectory: true)
        // The registry is a manager-level manifest, alongside Profiles and
        // Settings. Keep the old nested location as a read-only migration
        // source so existing installations are not abandoned.
        registryURL = baseDirectory.appendingPathComponent("SettingsRegistry.json")
        legacyRegistryURL = root.appendingPathComponent("SettingsRegistry.json")
    }
}
