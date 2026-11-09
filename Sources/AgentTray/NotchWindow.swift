import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchController {
    let hover = NotchHoverState()
    private let store: StatsStore
    private let settings: AppSettings
    private let notchPanel: NotchPanel
    private let tooltipPanel: NotchPanel
    private let menuActions = NotchMenuActions()
    private var screenObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var appObserver: NSObjectProtocol?
    private var mouseMonitor: Any?
    private var dragGlobalMonitor: Any?
    private var fullscreenTimer: Timer?
    private var chromeHidden = true
    private var profileObserver: AnyCancellable?
    private var hoverObserver: AnyCancellable?
    private var snapshotObserver: AnyCancellable?
    private var positionObserver: AnyCancellable?
    private var offsetObserver: AnyCancellable?
    private var drag: DragSession?
    private var mouseDownAt: NSPoint?
    private var dragging = false
    private var pinning = false

    private struct DragSession {
        var clickAlong: CGFloat
    }

    init(store: StatsStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        notchPanel = Self.makePanel(size: NotchMetrics.panelSize(profileCount: 2, position: settings.notchPosition))
        tooltipPanel = Self.makePanel(size: NSSize(width: NotchMetrics.tooltipWidth, height: 160))
        tooltipPanel.alphaValue = 0
        tooltipPanel.ignoresMouseEvents = true
        menuActions.onRefresh = { [weak store] in
            Task { @MainActor in await store?.refresh() }
        }
        menuActions.onToggleKind = { [weak self] kind in
            guard let self else { return }
            let revealing = self.settings.isHidden(kind)
            self.settings.toggleHidden(kind)
            if revealing {
                Task { await self.store.refresh() }
            }
        }

        let container = NotchHitView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        let notchHost = NSHostingView(rootView: NotchView(store: store, settings: settings, hover: hover))
        notchHost.wantsLayer = true
        notchHost.layer?.backgroundColor = NSColor.clear.cgColor
        notchHost.unregisterDraggedTypes()
        notchHost.frame = NSRect(
            origin: .zero,
            size: NotchMetrics.panelSize(profileCount: 2, position: settings.notchPosition)
        )
        container.addSubview(notchHost)
        notchPanel.contentView = container

        let tooltipHost = NSHostingView(rootView: NotchTooltipHost(store: store, settings: settings, hover: hover))
        tooltipHost.wantsLayer = true
        tooltipHost.layer?.backgroundColor = NSColor.clear.cgColor
        tooltipPanel.contentView = tooltipHost

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reposition()
            self.applyFullscreenVisibility()
        }

        profileObserver = store.$profiles
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reposition()
            }

        hoverObserver = hover.$hoveredID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                self?.updateTooltip(for: id)
            }

        snapshotObserver = store.$snapshots
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateTooltip(for: self.hover.hoveredID)
            }

        positionObserver = settings.$notchPosition
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reposition()
            }

        offsetObserver = settings.$notchOffset
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.layoutNotch()
            }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reposition()
                self?.applyFullscreenVisibility()
            }
        }

        let workspace = NSWorkspace.shared.notificationCenter
        spaceObserver = workspace.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyFullscreenVisibility()
            }
        }
        appObserver = workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyFullscreenVisibility()
            }
        }

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.applyFullscreenVisibility()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fullscreenTimer = timer

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: notchPanel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.snapBackIfOffEdge()
            }
        }

        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown]) { [weak self] event in
            guard let self, self.handleNotchMouse(event) else { return event }
            return nil
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        if let appObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appObserver)
        }
        fullscreenTimer?.invalidate()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let dragGlobalMonitor { NSEvent.removeMonitor(dragGlobalMonitor) }
    }

    func reposition() {
        let screen = currentScreen()
        applyHostFrame(NotchMetrics.hostFrame(in: screen, position: settings.notchPosition))
        layoutNotch()
    }

    private func layoutNotch() {
        if let hitView = notchPanel.contentView as? NotchHitView,
           let host = hitView.subviews.first {
            let frame = notchRectInHost()
            host.frame = frame
            hitView.hitRect = frame
        }
        updateTooltip(for: hover.hoveredID)
    }

    private func currentDisplay() -> NSScreen? {
        if drag != nil {
            return NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        }
        return NSScreen.screens.first { $0.frame.intersects(notchPanel.frame) } ?? NSScreen.main
    }

    private func currentScreen() -> NSRect {
        currentDisplay()?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func applyHostFrame(_ target: NSRect) {
        notchPanel.allowedFrame = target
        notchPanel.minSize = target.size
        notchPanel.maxSize = target.size
        guard !NotchMetrics.framesMatch(notchPanel.frame, target) else { return }
        pinning = true
        notchPanel.setFrame(target, display: true)
        pinning = false
    }

    private func snapBackIfOffEdge() {
        guard !pinning, drag == nil else { return }
        let target = NotchMetrics.hostFrame(in: currentScreen(), position: settings.notchPosition)
        guard !NotchMetrics.framesMatch(notchPanel.frame, target) else { return }
        applyHostFrame(target)
        layoutNotch()
    }

    private func notchScreenFrame() -> NSRect {
        guard let container = notchPanel.contentView,
              let host = container.subviews.first else { return .zero }
        return notchPanel.convertToScreen(container.convert(host.frame, to: nil))
    }

    private func notchRectInHost() -> NSRect {
        let size = NotchMetrics.panelSize(profileCount: max(store.profiles.count, 1), position: settings.notchPosition)
        let host = notchPanel.frame
        let offset = NotchMetrics.resolvedOffset(
            settings.notchOffset,
            size: size,
            in: currentScreen(),
            position: settings.notchPosition
        )
        if settings.notchPosition.isHorizontal {
            return NSRect(x: offset, y: 0, width: size.width, height: host.height)
        }
        return NSRect(x: 0, y: offset, width: host.width, height: size.height)
    }

    private func handleNotchMouse(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            guard event.window == notchPanel else { return false }
            mouseDownAt = NSEvent.mouseLocation
            dragging = false
            hover.hoveredID = nil
            startGlobalTrack()
            return true
        case .leftMouseDragged:
            guard mouseDownAt != nil else { return false }
            let now = NSEvent.mouseLocation
            if !dragging, let start = mouseDownAt, hypot(now.x - start.x, now.y - start.y) > 4 {
                dragging = true
                drag = DragSession(clickAlong: NotchMetrics.clickAlong(
                    point: start,
                    panel: notchScreenFrame(),
                    position: settings.notchPosition
                ))
            }
            if dragging {
                updateDrag(at: now)
            }
            return true
        case .leftMouseUp:
            guard mouseDownAt != nil else { return false }
            finishDrag()
            return true
        case .rightMouseDown:
            guard event.window == notchPanel else { return false }
            showContextMenu(event)
            return true
        default:
            return false
        }
    }

    private func updateDrag(at point: NSPoint) {
        guard var session = drag else { return }
        let screen = Self.screen(for: point)
        let position = NotchMetrics.nearestEdge(to: point, in: screen, current: settings.notchPosition)
        let size = NotchMetrics.panelSize(profileCount: max(store.profiles.count, 1), position: position)
        let t = NotchMetrics.edgeCoordinate(point, in: screen, position: position)
        let maxOffset = NotchMetrics.maxOffset(size: size, in: screen, position: position)
        let clamped = min(max(t - session.clickAlong, 0), maxOffset)
        session.clickAlong = t - clamped
        drag = session
        settings.notchPosition = position
        settings.notchOffset = clamped
    }

    private func startGlobalTrack() {
        if dragGlobalMonitor != nil { return }
        dragGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handleGlobalTrack(event)
        }
    }

    private func stopGlobalTrack() {
        if let dragGlobalMonitor { NSEvent.removeMonitor(dragGlobalMonitor) }
        dragGlobalMonitor = nil
    }

    private func handleGlobalTrack(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDragged:
            if dragging {
                updateDrag(at: NSEvent.mouseLocation)
            } else if let start = mouseDownAt {
                let now = NSEvent.mouseLocation
                if hypot(now.x - start.x, now.y - start.y) > 4 {
                    dragging = true
                    drag = DragSession(clickAlong: NotchMetrics.clickAlong(
                        point: start,
                        panel: notchScreenFrame(),
                        position: settings.notchPosition
                    ))
                    updateDrag(at: now)
                }
            }
        case .leftMouseUp:
            finishDrag()
        default:
            break
        }
    }

    private func finishDrag() {
        if dragging {
            updateDrag(at: NSEvent.mouseLocation)
        }
        drag = nil
        dragging = false
        mouseDownAt = nil
        stopGlobalTrack()
        reposition()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            self.snapBackIfOffEdge()
        }
    }

    private static func screen(for point: NSPoint) -> NSRect {
        (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.frame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func showContextMenu(_ event: NSEvent) {
        hover.hoveredID = nil
        let menu = NSMenu()
        let refresh = NSMenuItem(
            title: store.isRefreshing ? "Refreshing…" : "Refresh",
            action: #selector(NotchMenuActions.refresh),
            keyEquivalent: ""
        )
        refresh.target = menuActions
        refresh.isEnabled = !store.isRefreshing
        menu.addItem(refresh)

        let kinds = store.availableKinds
        if !kinds.isEmpty {
            menu.addItem(.separator())
            for kind in kinds {
                let hidden = settings.isHidden(kind)
                let item = NSMenuItem(
                    title: hidden ? "Show \(kind.displayName)" : "Hide \(kind.displayName)",
                    action: #selector(NotchMenuActions.toggleKind(_:)),
                    keyEquivalent: ""
                )
                item.target = menuActions
                item.representedObject = kind.rawValue
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let exit = NSMenuItem(
            title: "Exit",
            action: #selector(NotchMenuActions.exit),
            keyEquivalent: ""
        )
        exit.target = menuActions
        menu.addItem(exit)
        let click = notchPanel.convertPoint(toScreen: event.locationInWindow)
        menu.popUp(positioning: nil, at: click, in: nil)
    }

    private func applyFullscreenVisibility() {
        let shouldHide = drag == nil && displayHasFullscreenCover()
        guard shouldHide != chromeHidden else { return }
        chromeHidden = shouldHide
        if shouldHide {
            hover.hoveredID = nil
            tooltipPanel.alphaValue = 0
            tooltipPanel.orderOut(nil)
            notchPanel.orderOut(nil)
        } else {
            reposition()
            notchPanel.orderFrontRegardless()
        }
    }

    private func displayHasFullscreenCover() -> Bool {
        guard let screen = currentDisplay(),
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else {
            return NSApp.currentSystemPresentationOptions.contains(.fullScreen)
        }

        let screenBounds = CGDisplayBounds(displayID)
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return NSApp.currentSystemPresentationOptions.contains(.fullScreen)
        }

        let ourPID = Int(ProcessInfo.processInfo.processIdentifier)
        for window in windows {
            if (window[kCGWindowOwnerPID as String] as? NSNumber)?.intValue == ourPID { continue }
            if (window[kCGWindowLayer as String] as? NSNumber)?.intValue != 0 { continue }
            if let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha < 0.05 { continue }
            guard let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"]
            else { continue }
            if coversScreen(CGRect(x: x, y: y, width: width, height: height), screen: screenBounds) {
                return true
            }
        }
        return false
    }

    private func coversScreen(_ window: CGRect, screen: CGRect) -> Bool {
        let visible = window.intersection(screen)
        guard !visible.isNull, screen.width > 0, screen.height > 0 else { return false }
        let coverage = (visible.width * visible.height) / (screen.width * screen.height)
        return coverage >= 0.98 && window.height >= screen.height - 2
    }

    private func updateTooltip(for profileID: String?) {
        guard !chromeHidden, let profileID,
              let index = store.profiles.firstIndex(where: { $0.id == profileID })
        else {
            hover.caretShift = .zero
            tooltipPanel.alphaValue = 0
            tooltipPanel.orderOut(nil)
            return
        }

        guard let tooltipHost = tooltipPanel.contentView else { return }
        tooltipHost.layoutSubtreeIfNeeded()
        let size = tooltipHost.fittingSize
        let meter = NotchMetrics.meterCenter(
            index: index,
            count: store.profiles.count,
            in: notchScreenFrame(),
            position: settings.notchPosition
        )
        let placement = NotchMetrics.tooltipPlacement(
            size: size,
            meter: meter,
            position: settings.notchPosition,
            in: currentDisplay()?.visibleFrame ?? currentScreen()
        )
        hover.caretShift = placement.caretShift
        tooltipPanel.allowedFrame = placement.frame
        tooltipPanel.setFrame(placement.frame, display: true)
        tooltipPanel.alphaValue = 1
        tooltipPanel.orderFrontRegardless()
    }

    private static func makePanel(size: NSSize) -> NotchPanel {
        let panel = NotchPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenDisallowsTiling,
            .stationary,
        ]
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        panel.isFloatingPanel = true
        panel.acceptsMouseMovedEvents = true
        return panel
    }
}

@MainActor
final class NotchHoverState: ObservableObject {
    @Published var hoveredID: String?
    @Published var caretShift: CGSize = .zero
}

final class NotchMenuActions: NSObject {
    var onRefresh: (() -> Void)?
    var onToggleKind: ((AgentKind) -> Void)?

    @objc func refresh() {
        onRefresh?()
    }

    @objc func toggleKind(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let kind = AgentKind(rawValue: raw)
        else { return }
        onToggleKind?(kind)
    }

    @objc func exit() {
        NSApp.terminate(nil)
    }
}

final class NotchPanel: NSPanel {
    var allowsKey = false
    var allowedFrame: NSRect?
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    override func performDrag(with event: NSEvent) {}

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        allowedFrame ?? super.constrainFrameRect(frameRect, to: screen)
    }
}

final class NotchHitView: NSView {
    var hitRect: NSRect = .zero

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        hitRect.contains(point) ? super.hitTest(point) : nil
    }
}
