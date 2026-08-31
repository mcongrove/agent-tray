import AppKit

@main
enum AgentTrayMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()
    private var runtime: AppRuntime?

    func applicationDidFinishLaunching(_ notification: Notification) {
        runtime = AppRuntime()
    }
}

@MainActor
final class AppRuntime {
    let settings: AppSettings
    let store: StatsStore
    private var notch: NotchController?

    init() {
        let settings = AppSettings()
        let store = StatsStore()
        self.settings = settings
        self.store = store
        notch = NotchController(store: store, settings: settings)
        settings.enableLaunchAtLoginIfInstalled()
    }
}
