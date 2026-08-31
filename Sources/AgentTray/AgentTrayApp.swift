import AppKit
import SwiftUI

@main
struct AgentTrayApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var store: StatsStore

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _store = StateObject(wrappedValue: StatsStore(settings: settings))
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            AgentPanelView(store: store)
        } label: {
            Image(nsImage: TrayIcon.image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .accessibilityLabel("Agent Tray")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store, settings: settings)
        }
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
