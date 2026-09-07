import Darwin
import Foundation

enum ProfileFileLockStatus: Equatable, Sendable {
    case absent
    case active
    case stale
    case invalid
}

enum ProfileFileLockError: Error, Equatable {
    case alreadyHeld
    case ownerWriteFailed
}

/// A filesystem lock represented by a directory created atomically with
/// mkdir. Empty locks are used for profile running exclusion. Owned locks
/// contain one known owner file so a force-terminated maintenance operation
/// can be identified and recovered without recursive deletion.
final class ProfileFileLock {
    /// The only file that this helper ever removes from an owned lock.
    /// Keeping it as plain text makes the marker useful to shell launchers
    /// without putting any sensitive information in the lock directory.
    static let ownerFileName = ".owner.pid"

    private let url: URL
    private var ownerURL: URL?
    private let fileManager: FileManager
    private var released = false

    private init(url: URL, ownerURL: URL?, fileManager: FileManager) {
        self.url = url
        self.ownerURL = ownerURL
        self.fileManager = fileManager
    }

    static func acquireEmpty(
        at url: URL,
        fileManager: FileManager = .default
    ) throws -> ProfileFileLock {
        try createParent(for: url, fileManager: fileManager)
        do {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ProfileFileLockError.alreadyHeld
        }
        return ProfileFileLock(url: url, ownerURL: nil, fileManager: fileManager)
    }

    static func acquireOwned(
        at url: URL,
        processIdentifier: Int32 = Int32(ProcessInfo.processInfo.processIdentifier),
        fileManager: FileManager = .default
    ) throws -> ProfileFileLock {
        try createParent(for: url, fileManager: fileManager)
        do {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ProfileFileLockError.alreadyHeld
        }
        let ownerURL = url.appendingPathComponent(ownerFileName, isDirectory: false)
        do {
            try writeOwner(processIdentifier, to: ownerURL, fileManager: fileManager)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ownerURL.path)
        } catch {
            _ = ownerURL.path.withCString { Darwin.unlink($0) }
            _ = url.path.withCString { Darwin.rmdir($0) }
            throw ProfileFileLockError.ownerWriteFailed
        }
        return ProfileFileLock(url: url, ownerURL: ownerURL, fileManager: fileManager)
    }

    /// Records ownership after an empty lock has been acquired. This is used
    /// by the in-process UI launch path: mkdir closes the launch race, then
    /// the ChatGPT PID is persisted so a manager restart can distinguish an
    /// active UI launch from a stale lock.
    func setOwnerProcessIdentifier(_ processIdentifier: Int32) throws {
        guard processIdentifier > 0 else {
            throw ProfileFileLockError.ownerWriteFailed
        }
        let ownerURL = url.appendingPathComponent(Self.ownerFileName, isDirectory: false)
        do {
            try Self.writeOwner(processIdentifier, to: ownerURL, fileManager: fileManager)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ownerURL.path)
            self.ownerURL = ownerURL
        } catch {
            throw ProfileFileLockError.ownerWriteFailed
        }
    }

    func release() {
        guard !released else { return }
        released = true
        if let ownerURL {
            _ = ownerURL.path.withCString { Darwin.unlink($0) }
        }
        // rmdir fails safely if an unexpected file was added to the lock.
        _ = url.path.withCString { Darwin.rmdir($0) }
    }

    @discardableResult
    static func releaseEmpty(
        at url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let children = try? fileManager.contentsOfDirectory(atPath: url.path), children.isEmpty else {
            return false
        }
        return url.path.withCString { Darwin.rmdir($0) == 0 }
    }

    /// Releases a lock whose owner marker is known to this helper. Unknown
    /// files are deliberately preserved; this is never a recursive delete.
    @discardableResult
    static func releaseOwned(
        at url: URL,
        fileManager: FileManager = .default,
        isProcessActive: (Int32) -> Bool = defaultProcessIsActive
    ) -> Bool {
        guard let children = try? fileManager.contentsOfDirectory(atPath: url.path) else {
            return false
        }
        guard children.isEmpty || children.allSatisfy({ $0 == ownerFileName }) else {
            return false
        }
        if children.contains(ownerFileName) {
            let ownerURL = url.appendingPathComponent(ownerFileName, isDirectory: false)
            guard let processIdentifier = readOwner(at: ownerURL), !isProcessActive(processIdentifier) else {
                // Never release another live launcher's lock as a side effect
                // of synchronizing a stale state-store assignment.
                return false
            }
            _ = ownerURL.path.withCString { Darwin.unlink($0) }
        }
        guard (try? fileManager.contentsOfDirectory(atPath: url.path))?.isEmpty == true else {
            return false
        }
        return url.path.withCString { Darwin.rmdir($0) == 0 }
    }

    static func statusOwned(
        at url: URL,
        fileManager: FileManager = .default,
        isProcessActive: (Int32) -> Bool = defaultProcessIsActive
    ) -> ProfileFileLockStatus {
        guard fileManager.fileExists(atPath: url.path) else { return .absent }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .invalid
        }
        let ownerURL = url.appendingPathComponent(ownerFileName, isDirectory: false)
        guard let processIdentifier = readOwner(at: ownerURL) else {
            guard let children = try? fileManager.contentsOfDirectory(atPath: url.path), children.isEmpty else {
                return .invalid
            }
            return .stale
        }
        return isProcessActive(processIdentifier) ? .active : .stale
    }

    @discardableResult
    static func recoverStaleOwned(
        at url: URL,
        fileManager: FileManager = .default,
        isProcessActive: (Int32) -> Bool = defaultProcessIsActive,
        minimumAge: TimeInterval = 0
    ) -> Bool {
        if minimumAge > 0,
           let modifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(modifiedAt) < minimumAge {
            return false
        }
        guard statusOwned(at: url, fileManager: fileManager, isProcessActive: isProcessActive) == .stale else {
            return false
        }
        guard let children = try? fileManager.contentsOfDirectory(atPath: url.path),
              children.isEmpty || children.allSatisfy({ $0 == ownerFileName }) else {
            return false
        }
        let ownerURL = url.appendingPathComponent(ownerFileName, isDirectory: false)
        if fileManager.fileExists(atPath: ownerURL.path) {
            _ = ownerURL.path.withCString { Darwin.unlink($0) }
        }
        guard (try? fileManager.contentsOfDirectory(atPath: url.path))?.isEmpty == true else { return false }
        return url.path.withCString { Darwin.rmdir($0) == 0 }
    }

    @discardableResult
    static func recoverStaleEmpty(
        at url: URL,
        markerURL: URL? = nil,
        fileManager: FileManager = .default,
        isProcessActive: (Int32) -> Bool = defaultProcessIsActive
    ) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        if let markerURL,
           let text = try? String(contentsOf: markerURL, encoding: .utf8),
           let processIdentifier = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           processIdentifier > 0,
           isProcessActive(processIdentifier) {
            return false
        }
        guard let children = try? fileManager.contentsOfDirectory(atPath: url.path), children.isEmpty else {
            return false
        }
        return url.path.withCString { Darwin.rmdir($0) == 0 }
    }

    private static func createParent(for url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private static func writeOwner(
        _ processIdentifier: Int32,
        to url: URL,
        fileManager: FileManager
    ) throws {
        guard processIdentifier > 0 else {
            throw ProfileFileLockError.ownerWriteFailed
        }
        try Data("\(processIdentifier)\n".utf8).write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func readOwner(at url: URL) -> Int32? {
        guard let data = try? Data(contentsOf: url),
              let value = String(data: data, encoding: .utf8),
              let processIdentifier = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              processIdentifier > 0 else {
            return nil
        }
        return processIdentifier
    }

    private static func defaultProcessIsActive(_ processIdentifier: Int32) -> Bool {
        guard processIdentifier > 0 else { return false }
        let result = Darwin.kill(processIdentifier, 0)
        return result == 0 || errno == EPERM
    }
}
