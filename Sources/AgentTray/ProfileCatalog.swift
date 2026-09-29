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
        let grokHome = environment["GROK_HOME"].map(URL.init(fileURLWithPath:))
            ?? homeDirectory.appendingPathComponent(".grok")
        let grokExecutable = executable(named: "grok", preferred: grokHome.appendingPathComponent("bin/grok"))
        if fileManager.fileExists(atPath: grokHome.path) || grokExecutable != nil {
            profiles.append(AgentProfile(
                id: "grok-default",
                kind: .grok,
                displayName: "Grok",
                codexSelection: nil,
                executableURL: grokExecutable
            ))
        }

        if cursorIsPresent() {
            profiles.append(AgentProfile(
                id: "cursor-default",
                kind: .cursor,
                displayName: "Cursor",
                executableURL: URL(fileURLWithPath: "/Applications/Cursor.app")
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

    static func preferredCodexExecutable(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".local/bin/codex")
    }

    static func wellKnownExecutableLocations(named name: String, homeDirectory: URL) -> [URL] {
        var locations = [
            homeDirectory.appendingPathComponent(".local/bin/\(name)"),
            URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"),
            URL(fileURLWithPath: "/usr/local/bin/\(name)"),
        ]
        if name == "codex" {
            locations.append(contentsOf: [
                URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
                URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
                homeDirectory.appendingPathComponent(".codex/bin/codex"),
            ])
        }
        return locations
    }

    private func executable(named name: String, preferred: URL) -> URL? {
        var candidates = [preferred]
        candidates.append(contentsOf: Self.wellKnownExecutableLocations(named: name, homeDirectory: homeDirectory))
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent(name)
            })
        }
        var seen = Set<String>()
        return candidates.first { candidate in
            seen.insert(candidate.path).inserted && fileManager.isExecutableFile(atPath: candidate.path)
        }
    }

    private func cursorIsPresent() -> Bool {
        let support = homeDirectory.appendingPathComponent("Library/Application Support/Cursor")
        let cursorHome = homeDirectory.appendingPathComponent(".cursor")
        let app = URL(fileURLWithPath: "/Applications/Cursor.app")
        return fileManager.fileExists(atPath: support.path)
            || fileManager.fileExists(atPath: cursorHome.path)
            || fileManager.fileExists(atPath: app.path)
    }

    private func defaultOrder(for profile: AgentProfile) -> Int {
        switch profile.id {
        case "cursor-default": 5_000
        case "grok-default": 10_000
        case "codex-default": 20_000
        default: 30_000
        }
    }
}
