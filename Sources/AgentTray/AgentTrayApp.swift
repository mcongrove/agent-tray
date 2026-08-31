import AppKit
import SwiftUI

@main
struct AgentTrayApp: App {
    @StateObject private var runtime = AppRuntime()

    var body: some Scene {
        Settings {
            SettingsView(store: runtime.store, settings: runtime.settings)
        }
    }
}

@MainActor
final class AppRuntime: ObservableObject {
    let settings: AppSettings
    let store: StatsStore
    private var notch: NotchController?

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let settings = AppSettings()
        let store = StatsStore(settings: settings)
        self.settings = settings
        self.store = store
        notch = NotchController(store: store, settings: settings)
    }
}

enum TrayIcon {
    static let image: NSImage = {
        guard let url = Bundle.module.url(forResource: "bot", withExtension: "png"),
              let image = NSImage(contentsOf: url)
        else { return NSImage(systemSymbolName: "cpu", accessibilityDescription: "Agent Tray")! }
        image.size = NSSize(width: 20, height: 20)
        image.isTemplate = true
        image.accessibilityDescription = "Agent Tray"
        return image
    }()
}
