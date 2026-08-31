import Combine
import Foundation
import ServiceManagement

struct ManualCodexProfile: Codable, Hashable, Identifiable {
    var id: String { "codex-provider-\(providerID.lowercased())" }
    var providerID: String
    var displayName: String
}

struct ProfilePreference: Codable, Hashable, Identifiable {
    let id: String
    var displayName: String
    var isEnabled: Bool
}

final class AppSettings: ObservableObject {
    @Published var refreshMinutes: Int {
        didSet { defaults.set(refreshMinutes, forKey: Keys.refreshMinutes) }
    }

    @Published private(set) var launchAtLoginEnabled: Bool = false
    @Published private(set) var launchAtLoginError: String?
    @Published var preferences: [ProfilePreference] {
        didSet { persist(preferences, key: Keys.preferences) }
    }
    @Published var manualProfiles: [ManualCodexProfile] {
        didSet { persist(manualProfiles, key: Keys.manualProfiles) }
    }
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

    private let defaults: UserDefaults

    private enum Keys {
        static let refreshMinutes = "refreshMinutes"
        static let preferences = "profilePreferences"
        static let manualProfiles = "manualCodexProfiles"
        static let notchPosition = "notchPosition"
        static let notchOffset = "notchOffset"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        refreshMinutes = 1
        defaults.set(1, forKey: Keys.refreshMinutes)
        preferences = Self.decode([ProfilePreference].self, key: Keys.preferences, defaults: defaults) ?? []
        manualProfiles = Self.decode([ManualCodexProfile].self, key: Keys.manualProfiles, defaults: defaults) ?? []
        notchPosition = NotchPosition(rawValue: defaults.string(forKey: Keys.notchPosition) ?? "") ?? .right
        notchOffset = defaults.object(forKey: Keys.notchOffset) == nil ? nil : CGFloat(defaults.double(forKey: Keys.notchOffset))
        refreshLaunchAtLoginStatus()
    }

    func placeNotch(on position: NotchPosition) {
        notchPosition = position
        notchOffset = nil
    }

    func preference(for profile: AgentProfile) -> ProfilePreference {
        preferences.first(where: { $0.id == profile.id })
            ?? ProfilePreference(id: profile.id, displayName: profile.displayName, isEnabled: true)
    }

    func updateProfile(id: String, displayName: String? = nil, isEnabled: Bool? = nil) {
        if let index = preferences.firstIndex(where: { $0.id == id }) {
            if let displayName { preferences[index].displayName = displayName }
            if let isEnabled { preferences[index].isEnabled = isEnabled }
        } else {
            preferences.append(ProfilePreference(
                id: id,
                displayName: displayName ?? id,
                isEnabled: isEnabled ?? true
            ))
        }
    }

    func movePreference(id: String, offset: Int, profiles: [AgentProfile]) {
        for profile in profiles where !preferences.contains(where: { $0.id == profile.id }) {
            preferences.append(ProfilePreference(id: profile.id, displayName: profile.displayName, isEnabled: true))
        }
        guard let current = preferences.firstIndex(where: { $0.id == id }) else { return }
        let destination = current + offset
        guard preferences.indices.contains(destination) else { return }
        preferences.swapAt(current, destination)
    }

    func addManualProvider(id: String, displayName: String) {
        let cleanID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanID.isEmpty else { return }
        guard !manualProfiles.contains(where: { $0.providerID.caseInsensitiveCompare(cleanID) == .orderedSame }) else { return }
        manualProfiles.append(ManualCodexProfile(
            providerID: cleanID,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Codex \(cleanID.capitalized)"
                : displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
    }

    func removeManualProvider(_ profile: ManualCodexProfile) {
        manualProfiles.removeAll { $0.id == profile.id }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
#if os(macOS)
        if #available(macOS 13.0, *) {
            do {
                let service = SMAppService.mainApp
                if enabled {
                    try service.register()
                } else {
                    try service.unregister()
                }
            } catch {
                launchAtLoginError = error.localizedDescription
            }
        }
#endif
        refreshLaunchAtLoginStatus()
    }

    func refreshLaunchAtLoginStatus() {
#if os(macOS)
        if #available(macOS 13.0, *) {
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        }
#endif
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
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

    func discover(settings: AppSettings, includeDisabled: Bool = false) -> [AgentProfile] {
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
        let codexExecutable = executable(named: "codex", preferred: homeDirectory.appendingPathComponent(".local/bin/codex"))
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

        for manual in settings.manualProfiles where !profiles.contains(where: { $0.id == manual.id }) {
            profiles.append(AgentProfile(
                id: manual.id,
                kind: .codex,
                displayName: manual.displayName,
                codexSelection: .modelProvider(manual.providerID),
                executableURL: codexExecutable,
                supportsQuota: false
            ))
        }

        let preferenceOrder = Dictionary(uniqueKeysWithValues: settings.preferences.enumerated().map { ($0.element.id, $0.offset) })
        return profiles
            .map { profile in
                var adjusted = profile
                adjusted.displayName = settings.preference(for: profile).displayName
                return adjusted
            }
            .filter { includeDisabled || settings.preference(for: $0).isEnabled }
            .sorted {
                let left = preferenceOrder[$0.id] ?? defaultOrder(for: $0)
                let right = preferenceOrder[$1.id] ?? defaultOrder(for: $1)
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

    private func executable(named name: String, preferred: URL) -> URL? {
        var candidates = [preferred]
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent(name)
            })
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/\(name)"))
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
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
