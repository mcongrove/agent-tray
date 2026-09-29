import Combine
import Foundation

@MainActor
final class StatsStore: ObservableObject {
    @Published private(set) var profiles: [AgentProfile] = []
    @Published private(set) var snapshots: [String: AgentSnapshot] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?

    private(set) var allProfiles: [AgentProfile] = []

    var availableKinds: [AgentKind] {
        var seen = Set<AgentKind>()
        return allProfiles.compactMap { seen.insert($0.kind).inserted ? $0.kind : nil }
    }

    private let catalog: ProfileCatalog
    private let cache: SnapshotCache
    private let settings: AppSettings
    private var hiddenObserver: AnyCancellable?
    private var refreshLoop: Task<Void, Never>?
    private var started = false

    init(
        catalog: ProfileCatalog = ProfileCatalog(),
        cache: SnapshotCache = SnapshotCache(),
        settings: AppSettings
    ) {
        self.catalog = catalog
        self.cache = cache
        self.settings = settings
        reloadProfiles()
        hiddenObserver = settings.$hiddenKinds
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reloadProfiles()
            }
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
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                if !Task.isCancelled { await self.refresh() }
            }
        }
    }

    func reloadProfiles() {
        allProfiles = catalog.discover()
        profiles = allProfiles.filter { !settings.hiddenKinds.contains($0.kind) }
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
