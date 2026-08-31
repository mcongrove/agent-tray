import Combine
import Foundation

@MainActor
final class StatsStore: ObservableObject {
    @Published private(set) var profiles: [AgentProfile] = []
    @Published private(set) var allProfiles: [AgentProfile] = []
    @Published private(set) var snapshots: [String: AgentSnapshot] = [:]
    @Published var selectedProfileID: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?

    let settings: AppSettings
    private let catalog: ProfileCatalog
    private let cache: SnapshotCache
    private var refreshLoop: Task<Void, Never>?
    private var started = false

    init(
        settings: AppSettings,
        catalog: ProfileCatalog = ProfileCatalog(),
        cache: SnapshotCache = SnapshotCache()
    ) {
        self.settings = settings
        self.catalog = catalog
        self.cache = cache
        reloadProfiles()
        Task { await start() }
    }

    deinit {
        refreshLoop?.cancel()
    }

    func start() async {
        guard !started else { return }
        started = true
        snapshots = await cache.load()
        await refresh()
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let seconds = UInt64(max(self.settings.refreshMinutes, 1) * 60)
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                if !Task.isCancelled { await self.refresh() }
            }
        }
    }

    func reloadProfiles() {
        allProfiles = catalog.discover(settings: settings, includeDisabled: true)
        profiles = catalog.discover(settings: settings)
        if selectedProfileID == nil || !profiles.contains(where: { $0.id == selectedProfileID }) {
            selectedProfileID = profiles.first?.id
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        reloadProfiles()
        isRefreshing = true
        let requestedProfiles = profiles

        await withTaskGroup(of: AgentSnapshot.self) { group in
            for profile in requestedProfiles {
                group.addTask {
                    await Self.loadSnapshot(for: profile)
                }
            }
            for await snapshot in group {
                snapshots[snapshot.profileID] = snapshot
            }
        }

        lastRefresh = Date()
        isRefreshing = false
        await cache.save(snapshots)
    }

    private static func loadSnapshot(for profile: AgentProfile) async -> AgentSnapshot {
        await withTimeout(seconds: 12, fallback: .unavailable(
            profileID: profile.id,
            message: "Timed out reading \(profile.displayName) stats."
        )) {
            switch profile.kind {
            case .grok:
                return await GrokStatsProvider().snapshot(for: profile)
            case .cursor:
                return await CursorStatsProvider().snapshot(for: profile)
            case .codex:
                return await CodexStatsProvider().snapshot(for: profile)
            }
        }
    }

    func snapshot(for profile: AgentProfile) -> AgentSnapshot? {
        snapshots[profile.id]
    }
}
