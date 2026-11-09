import Combine
import Foundation
import ServiceManagement

final class AppSettings: ObservableObject {
    @Published var notchPosition: NotchPosition {
        didSet { defaults.set(notchPosition.rawValue, forKey: Keys.notchPosition) }
    }
    @Published var notchOffset: CGFloat? {
        didSet {
            if let notchOffset {
                defaults.set(notchOffset, forKey: Keys.notchOffset)
            } else {
                defaults.removeObject(forKey: Keys.notchOffset)
            }
        }
    }
    @Published var hiddenKinds: Set<AgentKind> {
        didSet { defaults.set(hiddenKinds.map(\.rawValue).sorted(), forKey: Keys.hiddenKinds) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let notchPosition = "notchPosition"
        static let notchOffset = "notchOffset"
        static let hiddenKinds = "hiddenKinds"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        notchPosition = NotchPosition(rawValue: defaults.string(forKey: Keys.notchPosition) ?? "") ?? .right
        notchOffset = defaults.object(forKey: Keys.notchOffset) == nil ? nil : CGFloat(defaults.double(forKey: Keys.notchOffset))
        hiddenKinds = Set((defaults.stringArray(forKey: Keys.hiddenKinds) ?? []).compactMap(AgentKind.init(rawValue:)))
    }

    func isHidden(_ kind: AgentKind) -> Bool {
        hiddenKinds.contains(kind)
    }

    func toggleHidden(_ kind: AgentKind) {
        var next = hiddenKinds
        if next.contains(kind) {
            next.remove(kind)
        } else {
            next.insert(kind)
        }
        hiddenKinds = next
    }

    func enableLaunchAtLoginIfInstalled() {
        let bundleURL = Bundle.main.bundleURL
        let applications = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first
            ?? URL(fileURLWithPath: "/Applications")
        let userApplications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        let installed = bundleURL.path.hasPrefix(applications.path)
            || bundleURL.path.hasPrefix(userApplications.path)
        guard installed else { return }
#if os(macOS)
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            guard service.status != .enabled else { return }
            try? service.register()
        }
#endif
    }
}

struct ProfileCatalog {
    let fileManager: FileManager
    let environment: [String: String]
    let homeDirectory: URL

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    func discover() -> [AgentProfile] {
        var profiles: [AgentProfile] = []

        // Cursor and Grok share one bill, so Grok is not its own notch entry.
        if cursorIsPresent() {
            profiles.append(AgentProfile(
                id: "cursor-default",
                kind: .cursor,
                displayName: "Cursor",
                executableURL: URL(fileURLWithPath: "/Applications/Cursor.app")
            ))
        }

        if claudeIsPresent() {
            let claudeHome = environment["CLAUDE_CONFIG_DIR"].map(URL.init(fileURLWithPath:))
                ?? homeDirectory.appendingPathComponent(".claude")
            profiles.append(AgentProfile(
                id: "claude-default",
                kind: .claude,
                displayName: "Claude",
                executableURL: executable(named: "claude", preferred: claudeHome.appendingPathComponent("bin/claude"))
            ))
        }

        let codexHome = environment["CODEX_HOME"].map(URL.init(fileURLWithPath:))
            ?? homeDirectory.appendingPathComponent(".codex")
        let codexExecutable = executable(named: "codex", preferred: Self.preferredCodexExecutable(homeDirectory: homeDirectory))
        if fileManager.fileExists(atPath: codexHome.path) || codexExecutable != nil {
            profiles.append(AgentProfile(
                id: "codex-default",
                kind: .codex,
                displayName: "Codex",
                codexSelection: .defaultProfile,
                executableURL: codexExecutable
            ))

            let namedProfiles = namedCodexProfiles(in: codexHome, executable: codexExecutable)
            profiles.append(contentsOf: namedProfiles)
            let namedProviderIDs = Set(namedProfiles.compactMap { profile -> String? in
                guard case .namedProfile(let name)? = profile.codexSelection else { return nil }
                return Self.topLevelModelProvider(
                    in: codexHome.appendingPathComponent("\(name).config.toml")
                )
            })

            let configURL = codexHome.appendingPathComponent("config.toml")
            for providerID in Self.modelProviderIDs(in: configURL).filter({ $0 != "openai" && !namedProviderIDs.contains($0) }) {
                profiles.append(AgentProfile(
                    id: "codex-provider-\(providerID.lowercased())",
                    kind: .codex,
                    displayName: "Codex \(providerID.capitalized)",
                    codexSelection: .modelProvider(providerID),
                    executableURL: codexExecutable,
                    supportsQuota: false
                ))
            }
        }

        return profiles.sorted {
            let left = defaultOrder(for: $0)
            let right = defaultOrder(for: $1)
            return left == right ? $0.displayName < $1.displayName : left < right
        }
    }

    static func modelProviderIDs(in configURL: URL) -> [String] {
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else { return [] }
        return modelProviderIDs(in: contents)
    }

    static func modelProviderIDs(in contents: String) -> [String] {
        var result: [String] = []
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let prefix = "[model_providers."
            guard line.hasPrefix(prefix), line.hasSuffix("]") else { continue }
            var id = String(line.dropFirst(prefix.count).dropLast())
            id = id.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !id.isEmpty, !result.contains(id) { result.append(id) }
        }
        return result
    }

    static func topLevelModelProvider(in configURL: URL) -> String? {
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else { return nil }
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { return nil }
            let pieces = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard pieces.count == 2, pieces[0].trimmingCharacters(in: .whitespaces) == "model_provider" else { continue }
            return pieces[1].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
        }
        return nil
    }

    private func namedCodexProfiles(in directory: URL, executable: URL?) -> [AgentProfile] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return files.compactMap { url in
            guard url.lastPathComponent.hasSuffix(".config.toml"), url.lastPathComponent != "config.toml" else { return nil }
            let name = String(url.lastPathComponent.dropLast(".config.toml".count))
            guard !name.isEmpty else { return nil }
            let providerID = Self.topLevelModelProvider(in: url)
            return AgentProfile(
                id: "codex-profile-\(name.lowercased())",
                kind: .codex,
                displayName: "Codex \(name.capitalized)",
                codexSelection: .namedProfile(name),
                executableURL: executable,
                supportsQuota: providerID == nil || providerID == "openai"
            )
        }
    }

    static func bundledClaudeExecutables(homeDirectory: URL) -> [URL] {
        let root = homeDirectory.appendingPathComponent("Library/Application Support/Claude/claude-code")
        guard let versions = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let sorted = versions.sorted {
            $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending
        }
        return sorted.flatMap { version in
            let builds = (try? FileManager.default.contentsOfDirectory(
                at: version,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            return builds.map { $0.appendingPathComponent("claude.app/Contents/MacOS/claude") }
        }
    }

    static func preferredCodexExecutable(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".local/bin/codex")
    }

    static func wellKnownExecutableLocations(named name: String, homeDirectory: URL) -> [URL] {
        var locations = [
            homeDirectory.appendingPathComponent(".local/bin/\(name)"),
            URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"),
            URL(fileURLWithPath: "/usr/local/bin/\(name)"),
        ]
        if name == "claude" {
            locations.append(contentsOf: bundledClaudeExecutables(homeDirectory: homeDirectory))
        }
        if name == "codex" {
            locations.append(contentsOf: [
                URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
                URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
                homeDirectory.appendingPathComponent(".codex/bin/codex"),
            ])
            locations.append(contentsOf: npmCodexLocations(homeDirectory: homeDirectory))
        }
        return locations
    }

    static func nativeCodexVendorPath(packageRoot: URL) -> URL {
        packageRoot
            .appendingPathComponent("node_modules/@openai/\(codexPlatformPackage)/vendor/\(codexTargetTriple)/bin/codex")
    }

    static var codexTargetTriple: String {
        #if arch(arm64)
        "aarch64-apple-darwin"
        #else
        "x86_64-apple-darwin"
        #endif
    }

    static var codexPlatformPackage: String {
        #if arch(arm64)
        "codex-darwin-arm64"
        #else
        "codex-darwin-x64"
        #endif
    }

    static func npmCodexLocations(homeDirectory: URL) -> [URL] {
        var packageRoots = [
            URL(fileURLWithPath: "/usr/local/lib/node_modules/@openai/codex"),
            URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/@openai/codex"),
        ]
        packageRoots.append(contentsOf: nodeInstallPackageRoots(
            in: homeDirectory.appendingPathComponent(".nvm/versions/node"),
            relativePath: "lib/node_modules/@openai/codex"
        ))
        packageRoots.append(contentsOf: nodeInstallPackageRoots(
            in: homeDirectory.appendingPathComponent(".harness/runtime"),
            relativePath: "lib/node_modules/@openai/codex"
        ))

        return packageRoots.flatMap { root in
            [
                nativeCodexVendorPath(packageRoot: root),
                root.appendingPathComponent("bin/codex.js"),
            ]
        }
    }

    private static func nodeInstallPackageRoots(in directory: URL, relativePath: String) -> [URL] {
        guard let versions = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return versions.map { $0.appendingPathComponent(relativePath) }
    }

    static func resolvedExecutable(at url: URL, name: String, fileManager: FileManager) -> URL? {
        let real = url.resolvingSymlinksInPath()
        guard fileManager.isExecutableFile(atPath: url.path) || fileManager.isExecutableFile(atPath: real.path) else {
            return nil
        }
        guard name == "codex" else { return real }

        if let native = nativeCodexBinary(near: real, fileManager: fileManager) {
            return native
        }
        return isCurrentArchitectureMachO(real) ? real : nil
    }

    static func nativeCodexBinary(near url: URL, fileManager: FileManager) -> URL? {
        if isCurrentArchitectureMachO(url) { return url }

        var packageRoots: [URL] = []
        if url.lastPathComponent == "codex.js" || url.lastPathComponent == "codex" {
            let parent = url.deletingLastPathComponent()
            if parent.lastPathComponent == "bin" {
                packageRoots.append(parent.deletingLastPathComponent())
            }
        }

        for root in packageRoots {
            let vendor = nativeCodexVendorPath(packageRoot: root)
            if fileManager.isExecutableFile(atPath: vendor.path), isCurrentArchitectureMachO(vendor) {
                return vendor
            }
        }
        return nil
    }

    static func isCurrentArchitectureMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: 8),
              data.count >= 8
        else { return false }
        try? handle.close()

        let magic = data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
        if magic == 0xcafebabe || magic == 0xbebafeca || magic == 0xcafebabf || magic == 0xbfbafeca {
            return true
        }
        guard magic == 0xfeedfacf || magic == 0xcffaedfe else { return false }
        let cpuType = data.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self) }
        let hostCPU: UInt32
        #if arch(arm64)
        hostCPU = magic == 0xfeedfacf ? 0x0100000c : 0x0c000001
        #else
        hostCPU = magic == 0xfeedfacf ? 0x01000007 : 0x07000001
        #endif
        return cpuType == hostCPU
    }

    static func executableCandidates(
        named name: String,
        preferred: URL,
        homeDirectory: URL,
        environment: [String: String]
    ) -> [URL] {
        var candidates = [preferred]
        candidates.append(contentsOf: wellKnownExecutableLocations(named: name, homeDirectory: homeDirectory))
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent(name)
            })
        }
        // Keep every existing CLI installation ahead of the new bundle fallback.
        if name == "codex" {
            candidates.append(contentsOf: [
                URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"),
                URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"),
            ])
        }
        return candidates
    }

    private func executable(named name: String, preferred: URL) -> URL? {
        let candidates = Self.executableCandidates(
            named: name, preferred: preferred, homeDirectory: homeDirectory, environment: environment
        )
        var seen = Set<String>()
        return candidates.compactMap { candidate -> URL? in
            guard seen.insert(candidate.path).inserted else { return nil }
            return Self.resolvedExecutable(at: candidate, name: name, fileManager: fileManager)
        }.first
    }

    private func cursorIsPresent() -> Bool {
        let support = homeDirectory.appendingPathComponent("Library/Application Support/Cursor")
        let cursorHome = homeDirectory.appendingPathComponent(".cursor")
        let app = URL(fileURLWithPath: "/Applications/Cursor.app")
        return fileManager.fileExists(atPath: support.path)
            || fileManager.fileExists(atPath: cursorHome.path)
            || fileManager.fileExists(atPath: app.path)
    }

    private func claudeIsPresent() -> Bool {
        let claudeHome = environment["CLAUDE_CONFIG_DIR"].map(URL.init(fileURLWithPath:))
            ?? homeDirectory.appendingPathComponent(".claude")
        let support = homeDirectory.appendingPathComponent("Library/Application Support/Claude")
        let app = URL(fileURLWithPath: "/Applications/Claude.app")
        return fileManager.fileExists(atPath: claudeHome.path)
            || fileManager.fileExists(atPath: support.path)
            || fileManager.fileExists(atPath: app.path)
            || executable(named: "claude", preferred: claudeHome.appendingPathComponent("bin/claude")) != nil
    }

    private func defaultOrder(for profile: AgentProfile) -> Int {
        switch profile.id {
        case "cursor-default": 5_000
        case "claude-default": 7_500
        case "codex-default": 20_000
        default: 30_000
        }
    }
}
