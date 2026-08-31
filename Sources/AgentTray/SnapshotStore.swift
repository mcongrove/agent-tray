import Foundation

actor SnapshotCache {
    private let fileManager: FileManager
    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        fileURL = base.appendingPathComponent("AgentTray/snapshots.json")
    }

    func load() -> [String: AgentSnapshot] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: AgentSnapshot].self, from: data)) ?? [:]
    }

    func save(_ snapshots: [String: AgentSnapshot]) {
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Cache persistence is opportunistic; current in-memory data remains valid.
        }
    }
}
