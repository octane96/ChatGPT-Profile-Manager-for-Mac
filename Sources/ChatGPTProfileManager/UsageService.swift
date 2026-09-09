import Foundation

struct UsageWindow: Equatable, Sendable {
    let usedPercent: Int
    let windowDurationMinutes: Int?
    let resetsAt: Date?

    var remainingPercent: Int {
        max(0, min(100, 100 - usedPercent))
    }
}

struct MenuBarUsageSummary: Equatable, Sendable {
    let fiveHour: Int?
    let weekly: Int?

    var title: String {
        let lines = [
            fiveHour.map { "5h \($0)%" },
            weekly.map { "W \($0)%" }
        ].compactMap { $0 }
        return lines.isEmpty ? "—" : lines.joined(separator: "\n")
    }

    static func minimum(
        accountIDs: [UUID],
        snapshots: [UUID: AccountUsageSnapshot]
    ) -> MenuBarUsageSummary {
        MenuBarUsageSummary(
            fiveHour: accountIDs.compactMap { snapshots[$0]?.primary?.remainingPercent }.min(),
            weekly: accountIDs.compactMap { snapshots[$0]?.secondary?.remainingPercent }.min()
        )
    }
}

struct UsageRefreshMergeResult: Equatable, Sendable {
    let snapshots: [UUID: AccountUsageSnapshot]
    let lastUpdatedAt: [UUID: Date]
}

enum UsageRefreshMerger {
    /// Retains the last successful snapshot for accounts whose current fetch
    /// failed, while dropping registrations that no longer exist.
    static func merge(
        previousSnapshots: [UUID: AccountUsageSnapshot],
        previousLastUpdatedAt: [UUID: Date],
        fetchedSnapshots: [UUID: AccountUsageSnapshot],
        accountIDs: Set<UUID>,
        finishedAt: Date
    ) -> UsageRefreshMergeResult {
        var snapshots = previousSnapshots.filter { accountIDs.contains($0.key) }
        var lastUpdatedAt = previousLastUpdatedAt.filter { accountIDs.contains($0.key) }
        for (accountID, snapshot) in fetchedSnapshots {
            snapshots[accountID] = snapshot
            lastUpdatedAt[accountID] = finishedAt
        }
        return UsageRefreshMergeResult(
            snapshots: snapshots,
            lastUpdatedAt: lastUpdatedAt
        )
    }
}

enum MenuBarPreferences {
    static let compactUsageStatusKey = "compactUsageStatusEnabled"

    static func compactUsageEnabled(in defaults: UserDefaults) -> Bool {
        (defaults.object(forKey: compactUsageStatusKey) as? Bool) ?? true
    }
}

enum UsageThresholdEvaluator {
    /// Returns thresholds crossed while remaining usage moved downward.
    /// Thresholds are intentionally returned in ascending order so callers
    /// can produce deterministic notifications.
    static func crossedThresholds(
        previous: UsageWindow?,
        current: UsageWindow?,
        thresholds: [Int]
    ) -> [Int] {
        guard let previous, let current else { return [] }
        return thresholds
            .filter {
                previous.remainingPercent > $0
                    && current.remainingPercent <= $0
            }
            .sorted()
    }
}

struct RateLimitResetCreditsSummary: Equatable, Sendable {
    let availableCount: Int
    let credits: [RateLimitResetCredit]?

    /// Presents known expirations first in chronological order. Credits with
    /// no expiry are kept at the end so an incomplete API response never
    /// changes the meaning of the known dates.
    var creditsSortedByExpiry: [RateLimitResetCredit] {
        guard let credits else { return [] }
        return credits.enumerated()
            .sorted { left, right in
                switch (left.element.expiresAt, right.element.expiresAt) {
                case let (leftDate?, rightDate?):
                    if leftDate != rightDate {
                        return leftDate < rightDate
                    }
                    return left.offset < right.offset
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return left.offset < right.offset
                }
            }
            .map(\.element)
    }
}

struct RateLimitResetCredit: Equatable, Sendable {
    let expiresAt: Date?
}

struct AccountUsageSnapshot: Equatable, Sendable {
    let primary: UsageWindow?
    let secondary: UsageWindow?
    let planType: String?
    let rateLimitResetCredits: RateLimitResetCreditsSummary?

    var displayPlanName: String? {
        guard let planType else {
            return nil
        }

        switch planType.lowercased() {
        case "free":
            return "Free"
        case "plus":
            return "Plus"
        case "pro":
            return "Pro"
        case "team":
            return "Team"
        case "business":
            return "Business"
        case "enterprise":
            return "Enterprise"
        default:
            return planType
        }
    }

    init?(jsonData: Data) {
        guard
            let root = try? JSONSerialization.jsonObject(with: jsonData),
            let response = root as? [String: Any],
            let result = response["result"] as? [String: Any],
            let rateLimits = AccountUsageSnapshot.rateLimits(from: result)
        else {
            return nil
        }

        primary = Self.window(from: rateLimits["primary"])
        secondary = Self.window(from: rateLimits["secondary"])
        let rawPlanType = (rateLimits["planType"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        planType = rawPlanType?.isEmpty == false ? rawPlanType : nil
        rateLimitResetCredits = Self.resetCredits(from: result["rateLimitResetCredits"])

        guard primary != nil || secondary != nil || rateLimitResetCredits != nil else {
            return nil
        }
    }

    init?(
        primary: UsageWindow?,
        secondary: UsageWindow?,
        planType: String? = nil,
        rateLimitResetCredits: RateLimitResetCreditsSummary? = nil
    ) {
        guard primary != nil || secondary != nil || rateLimitResetCredits != nil else {
            return nil
        }
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
        self.rateLimitResetCredits = rateLimitResetCredits
    }

    private static func rateLimits(from result: [String: Any]) -> [String: Any]? {
        if let rateLimits = result["rateLimits"] as? [String: Any] {
            return rateLimits
        }

        guard
            let allRateLimits = result["rateLimitsByLimitId"] as? [String: Any],
            let codexRateLimits = allRateLimits["codex"] as? [String: Any]
        else {
            return nil
        }
        return codexRateLimits
    }

    private static func window(from value: Any?) -> UsageWindow? {
        guard
            let value = value as? [String: Any],
            let usedPercent = value["usedPercent"] as? NSNumber
        else {
            return nil
        }

        let windowDurationMinutes = (value["windowDurationMins"] as? NSNumber)
            .map { $0.intValue }
        let resetsAt = (value["resetsAt"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue) }

        return UsageWindow(
            usedPercent: usedPercent.intValue,
            windowDurationMinutes: windowDurationMinutes,
            resetsAt: resetsAt
        )
    }

    private static func resetCredits(from value: Any?) -> RateLimitResetCreditsSummary? {
        guard let value = value as? [String: Any] else {
            return nil
        }

        let availableCount = (value["availableCount"] as? NSNumber)
            ?? (value["available_count"] as? NSNumber)
        guard let availableCount else {
            return nil
        }

        let credits: [RateLimitResetCredit]?
        if let rawCredits = value["credits"] as? [Any] {
            credits = rawCredits.compactMap { resetCredit(from: $0) }
        } else {
            credits = nil
        }

        return RateLimitResetCreditsSummary(
            availableCount: max(0, availableCount.intValue),
            credits: credits
        )
    }

    private static func resetCredit(from value: Any) -> RateLimitResetCredit? {
        guard let value = value as? [String: Any] else {
            return nil
        }

        let expiresAt: Date?
        if let timestamp = (value["expiresAt"] as? NSNumber)
            ?? (value["expires_at"] as? NSNumber) {
            expiresAt = Date(timeIntervalSince1970: timestamp.doubleValue)
        } else if let rawDate = (value["expiresAt"] as? String)
            ?? (value["expires_at"] as? String) {
            expiresAt = ISO8601DateFormatter().date(from: rawDate)
        } else {
            expiresAt = nil
        }

        return RateLimitResetCredit(expiresAt: expiresAt)
    }
}

enum UsageService {
    private static let requestTimeout: TimeInterval = 15

    /// Reads the same account/rateLimits endpoint used by Codex itself through
    /// the local Codex app-server. No credentials are written or persisted by
    /// the manager; CODEX_HOME selects the profile whose Codex state is used.
    static func fetch(codexHome: URL) async -> AccountUsageSnapshot? {
        guard let executableURL = codexExecutableURL() else {
            return nil
        }

        let client = AppServerClient(
            executableURL: executableURL,
            codexHome: codexHome,
            timeout: requestTimeout
        )
        return await withTaskCancellationHandler {
            await Task.detached(priority: .utility) {
                await client.run()
            }.value
        } onCancel: {
            client.cancel()
        }
    }

    static func codexExecutableURLForDiagnostics(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        codexExecutableURL(fileManager: fileManager, homeDirectory: homeDirectory)
    }

    private static func codexExecutableURL(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        let candidates = [
            homeDirectory.appendingPathComponent(".local/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            URL(fileURLWithPath: "/usr/bin/codex")
        ]
        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }
}

private final class AppServerClient: @unchecked Sendable {
    private let executableURL: URL
    private let codexHome: URL
    private let timeout: TimeInterval
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let stateLock = NSLock()

    private var outputBuffer = Data()
    private var hasFinished = false
    private var completion: ((AccountUsageSnapshot?) -> Void)?

    init(executableURL: URL, codexHome: URL, timeout: TimeInterval) {
        self.executableURL = executableURL
        self.codexHome = codexHome
        self.timeout = timeout
    }

    func run() async -> AccountUsageSnapshot? {
        await withCheckedContinuation { continuation in
            completion = { data in
                continuation.resume(returning: data)
            }
            start()
        }
    }

    func cancel() {
        finish(nil)
    }

    private func start() {
        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome.path
        process.environment = environment

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
        process.terminationHandler = { [weak self] _ in
            self?.finish(nil)
        }

        do {
            try process.run()
            try inputPipe.fileHandleForWriting.write(contentsOf: requestData())
        } catch {
            finish(nil)
            return
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(nil)
        }
    }

    private func requestData() throws -> Data {
        let messages: [[String: Any]] = [
            [
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "chatgpt-profile-manager",
                        "version": "1.0.0"
                    ],
                    "capabilities": [
                        "experimentalApi": true
                    ]
                ]
            ],
            ["method": "initialized"],
            [
                "id": 2,
                "method": "account/rateLimits/read",
                "params": NSNull()
            ]
        ]

        let lines = try messages.map { message in
            let data = try JSONSerialization.data(withJSONObject: message)
            return String(decoding: data, as: UTF8.self)
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else {
            finish(nil)
            return
        }

        stateLock.lock()
        guard !hasFinished else {
            stateLock.unlock()
            return
        }
        outputBuffer.append(data)

        var responseData: Data?
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)),
                let response = object as? [String: Any],
                let id = response["id"] as? NSNumber,
                id.intValue == 2
            else {
                continue
            }
            responseData = Data(line)
            break
        }
        stateLock.unlock()

        guard let responseData else {
            return
        }
        let snapshot = AccountUsageSnapshot(jsonData: responseData)
        finish(snapshot)
    }

    private func finish(_ snapshot: AccountUsageSnapshot?) {
        stateLock.lock()
        guard !hasFinished else {
            stateLock.unlock()
            return
        }
        hasFinished = true
        let completion = self.completion
        self.completion = nil
        stateLock.unlock()

        outputPipe.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
        if process.isRunning {
            process.terminate()
        }
        completion?(snapshot)
    }
}
