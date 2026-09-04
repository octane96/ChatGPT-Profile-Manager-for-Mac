import AppKit
import Foundation

enum ProfileLauncherURL {
    static let scheme = "chatgpt-profile-manager"
    static let host = "launch"
    static let queryName = "profile"

    static func url(for accountID: UUID) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [
            URLQueryItem(name: queryName, value: accountID.uuidString)
        ]
        // The fixed scheme, host, and UUID are always valid URL components.
        return components.url!
    }

    static func accountID(from url: URL) -> UUID? {
        guard
            url.scheme?.lowercased() == scheme,
            url.host?.lowercased() == host,
            let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == queryName })?
                .value
        else {
            return nil
        }
        return UUID(uuidString: value)
    }

    static func processIdentifier(from url: URL) -> Int32? {
        guard
            url.scheme?.lowercased() == scheme,
            url.host?.lowercased() == host,
            let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "pid" })?
                .value,
            let processIdentifier = Int32(value),
            processIdentifier > 0
        else {
            return nil
        }
        return processIdentifier
    }
}

struct ProfileLauncherError: LocalizedError, Equatable {
    enum Kind: Equatable {
        case generation
        case signing
    }

    let kind: Kind

    var errorDescription: String? {
        switch kind {
        case .generation:
            return L10n.text(
                "launcher.error.generation",
                fallback: "起動アプリを作成できませんでした。"
            )
        case .signing:
            return L10n.text(
                "launcher.error.signing",
                fallback: "起動アプリの署名に失敗しました。"
            )
        }
    }
}

/// Creates a profile-specific .app bundle that launches ChatGPT with the
/// profile's isolated storage paths. The launcher filename uses the
/// `ChatGPT {profile name}` format so it is easy to identify in Finder and
/// the Dock.
final class ProfileLauncherStore {
    private let fileManager: FileManager
    private let baseDirectory: URL
    private let launchersDirectory: URL
    private let managerBundleIdentifier = "com.local.chatgpt-profile-manager"
    private let accountIdentifierInfoKey = "ChatGPTProfileManagerAccountID"

    init(
        baseDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        self.baseDirectory = baseDirectory
        launchersDirectory = baseDirectory.appendingPathComponent(
            "Launchers",
            isDirectory: true
        )
    }

    static func runningMarkerDirectory(baseDirectory: URL) -> URL {
        baseDirectory
            .appendingPathComponent("Launchers", isDirectory: true)
            .appendingPathComponent(".running", isDirectory: true)
    }

    func launcherURL(for account: AccountProfile) -> URL {
        existingLauncherURL(for: account) ?? preferredLauncherURL(for: account)
    }

    func hasLauncher(for account: AccountProfile) -> Bool {
        existingLauncherURL(for: account) != nil
    }

    @discardableResult
    func generate(for account: AccountProfile) throws -> URL {
        try fileManager.createDirectory(
            at: launchersDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let destination = preferredLauncherURL(for: account)
        let temporary = launchersDirectory.appendingPathComponent(
            ".\(destination.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).tmp",
            isDirectory: true
        )
        let contents = temporary.appendingPathComponent("Contents", isDirectory: true)
        let executableDirectory = contents.appendingPathComponent(
            "MacOS",
            isDirectory: true
        )
        let executableURL = executableDirectory.appendingPathComponent(
            "LaunchProfile",
            isDirectory: false
        )
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)

        do {
            try fileManager.createDirectory(
                at: resources,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.createDirectory(
                at: executableDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try ProfilePaths(
                profile: account,
                baseDirectory: baseDirectory
            ).createDirectories(fileManager: fileManager)
            try writeInfoPlist(for: account, to: contents.appendingPathComponent("Info.plist"))
            try writeLaunchScript(for: account, to: executableURL)
            try writeIcon(for: account, to: resources)
            try sign(bundle: temporary)
            try replace(destination: destination, with: temporary)
            return destination
        } catch let error as ProfileLauncherError {
            try? fileManager.removeItem(at: temporary)
            throw error
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw ProfileLauncherError(kind: .generation)
        }
    }

    private func writeInfoPlist(for account: AccountProfile, to url: URL) throws {
        let identifierSuffix = account.id.uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        let displayName = launcherDisplayName(for: account.name)
        let plist: [String: Any] = [
            "CFBundleDisplayName": displayName,
            "CFBundleExecutable": "LaunchProfile",
            "CFBundleIdentifier": "com.local.chatgpt-profile-manager.launcher.\(identifierSuffix)",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": displayName,
            accountIdentifierInfoKey: account.id.uuidString,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1",
            "CFBundleIconFile": "ProfileIcon.icns",
            "LSMinimumSystemVersion": "14.0",
            "NSHighResolutionCapable": true,
            "NSHumanReadableCopyright": "Generated by ChatGPT Profile Manager."
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func writeLaunchScript(for account: AccountProfile, to url: URL) throws {
        let paths = ProfilePaths(profile: account, baseDirectory: baseDirectory)
        let profileHome = shellQuote(paths.codexHome.path)
        let electronUserData = shellQuote(paths.electronUserData.path)
        let runningMarkerDirectory = shellQuote(
            Self.runningMarkerDirectory(baseDirectory: baseDirectory).path
        )
        let defaultExecutable = shellQuote(
            "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
        )
        let managerBundle = shellQuote(managerBundleIdentifier)
        let script = [
            "#!/bin/sh",
            "set -e",
            "",
            "export CODEX_HOME=\(profileHome)",
            "export CODEX_ELECTRON_USER_DATA_PATH=\(electronUserData)",
            "",
            "CHATGPT_EXECUTABLE=\(defaultExecutable)",
            "if [ ! -x \"$CHATGPT_EXECUTABLE\" ]; then",
            "    CHATGPT_APP=$(/usr/bin/mdfind 'kMDItemCFBundleIdentifier == \"com.openai.codex\"' | /usr/bin/head -n 1)",
            "    CHATGPT_EXECUTABLE=\"$CHATGPT_APP/Contents/MacOS/ChatGPT\"",
            "fi",
            "",
            "if [ -x \"$CHATGPT_EXECUTABLE\" ]; then",
            "    MARKER_DIRECTORY=\(runningMarkerDirectory)",
            "    MARKER_FILE=\"$MARKER_DIRECTORY/\(account.id.uuidString).pid\"",
            "    /bin/mkdir -p \"$MARKER_DIRECTORY\"",
            "    /bin/chmod 700 \"$MARKER_DIRECTORY\"",
            "    \"$CHATGPT_EXECUTABLE\" \"--user-data-dir=$CODEX_ELECTRON_USER_DATA_PATH\" &",
            "    CHATGPT_PID=$!",
            "    /usr/bin/printf '%s\\n' \"$CHATGPT_PID\" > \"$MARKER_FILE\"",
            "    trap '/bin/rm -f \"$MARKER_FILE\"' EXIT HUP INT TERM",
            "    wait \"$CHATGPT_PID\"",
            "    exit $?",
            "fi",
            "",
            "# LaunchServices is a last-resort fallback when the app is installed outside",
            "# the standard locations. The manager handles the URL for older launchers.",
            "exec /usr/bin/open -b \(managerBundle) \(shellQuote(ProfileLauncherURL.url(for: account.id).absoluteString))"
        ].joined(separator: "\n") + "\n"
        try Data(script.utf8).write(to: url, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func writeIcon(for account: AccountProfile, to resources: URL) throws {
        let iconURL = resources.appendingPathComponent("ProfileIcon.icns")
        do {
            try ProfileLauncherIconGenerator.generate(
                account: account,
                destination: iconURL,
                fileManager: fileManager
            )
        } catch {
            // A launcher remains usable even when iconutil is unavailable. Use
            // the manager's icon as a safe fallback instead of failing launch.
            if let baseIcon = Bundle.main.url(
                forResource: "AppIcon",
                withExtension: "icns"
            ) {
                try fileManager.copyItem(at: baseIcon, to: iconURL)
            }
        }
    }

    private func sign(bundle: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--deep", "--sign", "-", bundle.path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ProfileLauncherError(kind: .signing)
        }
        guard process.terminationStatus == 0 else {
            throw ProfileLauncherError(kind: .signing)
        }
    }

    private func replace(destination: URL, with temporary: URL) throws {
        let backup = launchersDirectory.appendingPathComponent(
            ".\(destination.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).backup",
            isDirectory: true
        )
        var movedExisting = false
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.moveItem(at: destination, to: backup)
                movedExisting = true
            }
            try fileManager.moveItem(at: temporary, to: destination)
            if movedExisting {
                try? fileManager.removeItem(at: backup)
            }
        } catch {
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            if movedExisting {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            throw error
        }
    }

    private func preferredLauncherURL(for account: AccountProfile) -> URL {
        let stem = launcherDisplayName(for: sanitizedLauncherName(for: account.name))
        let preferred = launchersDirectory.appendingPathComponent(
            "\(stem).app",
            isDirectory: true
        )

        guard
            fileManager.fileExists(atPath: preferred.path),
            !bundleBelongsToAccount(at: preferred, accountID: account.id)
        else {
            return preferred
        }

        let shortID = account.id.uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(8)
            .lowercased()
        return launchersDirectory.appendingPathComponent(
            "\(stem) - \(shortID).app",
            isDirectory: true
        )
    }

    private func existingLauncherURL(for account: AccountProfile) -> URL? {
        let preferred = preferredLauncherURL(for: account)
        let candidates = [
            preferred,
            legacyLauncherURL(for: account)
        ]

        for candidate in candidates where
            fileManager.fileExists(atPath: candidate.path)
            && bundleBelongsToAccount(at: candidate, accountID: account.id) {
            return candidate
        }

        guard let children = try? fileManager.contentsOfDirectory(
            at: launchersDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return children
            .filter { $0.pathExtension == "app" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .first { bundleBelongsToAccount(at: $0, accountID: account.id) }
    }

    private func legacyLauncherURL(for account: AccountProfile) -> URL {
        launchersDirectory.appendingPathComponent(
            "ChatGPT Profile Manager - \(account.id.uuidString).app",
            isDirectory: true
        )
    }

    private func bundleBelongsToAccount(at url: URL, accountID: UUID) -> Bool {
        guard let bundle = Bundle(url: url) else {
            return false
        }

        if let storedID = bundle.object(
            forInfoDictionaryKey: accountIdentifierInfoKey
        ) as? String,
           UUID(uuidString: storedID) == accountID {
            return true
        }

        let suffix = accountID.uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        return bundle.bundleIdentifier?.hasSuffix(".\(suffix)") == true
    }

    private func sanitizedLauncherName(for name: String) -> String {
        let withoutInvalidCharacters = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "")
        let normalized = withoutInvalidCharacters
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else {
            return "ChatGPT Profile Manager"
        }
        if trimmed.hasPrefix(".") {
            return "Profile \(trimmed.drop(while: { $0 == "." }))"
        }
        return trimmed
    }

    private func launcherDisplayName(for profileName: String) -> String {
        "ChatGPT \(profileName)"
    }
}

enum ProfileLauncherIconGenerator {
    private struct Variant {
        let size: Int
        let name: String
    }

    private static let variants = [
        Variant(size: 16, name: "icon_16x16.png"),
        Variant(size: 32, name: "icon_16x16@2x.png"),
        Variant(size: 32, name: "icon_32x32.png"),
        Variant(size: 64, name: "icon_32x32@2x.png"),
        Variant(size: 128, name: "icon_128x128.png"),
        Variant(size: 256, name: "icon_128x128@2x.png"),
        Variant(size: 256, name: "icon_256x256.png"),
        Variant(size: 512, name: "icon_256x256@2x.png"),
        Variant(size: 512, name: "icon_512x512.png"),
        Variant(size: 1024, name: "icon_512x512@2x.png")
    ]

    static func generate(
        account: AccountProfile,
        destination: URL,
        fileManager: FileManager
    ) throws {
        let iconSet = destination.deletingLastPathComponent()
            .appendingPathComponent("ProfileIcon.iconset", isDirectory: true)
        try fileManager.createDirectory(
            at: iconSet,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: iconSet) }

        for variant in variants {
            let bitmap = makeImage(
                account: account,
                pixelSize: variant.size
            )
            guard
                let png = bitmap.representation(using: .png, properties: [:])
            else {
                throw ProfileLauncherError(kind: .generation)
            }
            try png.write(
                to: iconSet.appendingPathComponent(variant.name),
                options: .atomic
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", iconSet.path, "-o", destination.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              fileManager.fileExists(atPath: destination.path)
        else {
            throw ProfileLauncherError(kind: .generation)
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
    }

    private static func makeImage(
        account: AccountProfile,
        pixelSize: Int
    ) -> NSBitmapImageRep {
        let size = CGFloat(pixelSize)
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        bitmap.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

        let background = NSColor(
            calibratedHue: hue(for: account.id),
            saturation: 0.72,
            brightness: 0.78,
            alpha: 1
        )
        background.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
            xRadius: size * 0.2,
            yRadius: size * 0.2
        ).fill()

        let initials = initials(for: account.name)
        let fontSize = max(size * 0.3, 6)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let textSize = initials.size(withAttributes: attributes)
        initials.draw(
            at: NSPoint(
                x: (size - textSize.width) / 2,
                y: (size - textSize.height) / 2
            ),
            withAttributes: attributes
        )
        return bitmap
    }

    static func initials(for name: String) -> String {
        // Keep the label to two initials so it remains legible in the 16px icon
        // variant. CamelCase and common word separators are treated alike.
        let characters = Array(name.trimmingCharacters(in: .whitespacesAndNewlines))
        var words: [String] = []
        var currentWord = ""

        func appendCurrentWord() {
            guard !currentWord.isEmpty else {
                return
            }
            words.append(currentWord)
            currentWord = ""
        }

        for (index, character) in characters.enumerated() {
            if character.isWhitespace || character == "-" || character == "_" {
                appendCurrentWord()
                continue
            }

            let previous = index > 0 ? characters[index - 1] : nil
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            let startsCamelCaseWord = character.isUppercase
                && !currentWord.isEmpty
                && (previous?.isLowercase == true
                    || (previous?.isUppercase == true && next?.isLowercase == true))
            if startsCamelCaseWord {
                appendCurrentWord()
            }
            currentWord.append(character)
        }
        appendCurrentWord()

        let value: String
        if words.count >= 2 {
            value = words.prefix(2).compactMap { $0.first }.map(String.init).joined()
        } else {
            value = String(characters.prefix(2))
        }
        return value.isEmpty ? "?" : value.uppercased()
    }

    private static func hue(for id: UUID) -> CGFloat {
        let total = id.uuidString.unicodeScalars.reduce(0) { partial, scalar in
            (partial &* 31) &+ Int(scalar.value)
        }
        return CGFloat(abs(total % 360)) / 360
    }
}
