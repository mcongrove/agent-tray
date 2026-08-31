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
    private var mouseMonitor: Any?
    private var dragGlobalMonitor: Any?
    private var profileObserver: AnyCancellable?
    private var hoverObserver: AnyCancellable?
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

        let notchHost = NSHostingView(rootView: NotchView(store: store, settings: settings, hover: hover))
        notchHost.wantsLayer = true
        notchHost.layer?.backgroundColor = NSColor.clear.cgColor
        notchHost.unregisterDraggedTypes()
        notchPanel.contentView = notchHost

        let tooltipHost = NSHostingView(rootView: NotchTooltipHost(store: store, settings: settings, hover: hover))
        tooltipHost.wantsLayer = true
        tooltipHost.layer?.backgroundColor = NSColor.clear.cgColor
        tooltipPanel.contentView = tooltipHost

        reposition()
        notchPanel.orderFrontRegardless()

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

        positionObserver = settings.$notchPosition
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reposition()
            }

        offsetObserver = settings.$notchOffset
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reposition()
            }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reposition()
            }
        }

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
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let dragGlobalMonitor { NSEvent.removeMonitor(dragGlobalMonitor) }
    }

    func reposition() {
        let screen = currentScreen()
        let position = settings.notchPosition
        let size = NotchMetrics.panelSize(profileCount: max(store.profiles.count, 1), position: position)
        let offset = NotchMetrics.resolvedOffset(
            settings.notchOffset,
            size: size,
            in: screen,
            position: position
        )
        applyPinnedFrame(size: size, offset: offset, in: screen, position: position)
        updateTooltip(for: hover.hoveredID)
    }

    private func currentScreen() -> NSRect {
        if drag != nil {
            return Self.screen(for: NSEvent.mouseLocation)
        }
        return (NSScreen.screens.first { $0.frame.intersects(notchPanel.frame) } ?? NSScreen.main)?.frame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func applyPinnedFrame(size: NSSize, offset: CGFloat, in screen: NSRect, position: NotchPosition) {
        let origin = NotchMetrics.panelOrigin(size: size, offset: offset, in: screen, position: position)
        let target = NSRect(origin: origin, size: size)
        guard !NotchMetrics.framesMatch(notchPanel.frame, target) else { return }
        pinning = true
        notchPanel.setFrame(target, display: true)
        pinning = false
    }

    private func snapBackIfOffEdge() {
        guard !pinning, drag == nil else { return }
        let screen = currentScreen()
        let position = settings.notchPosition
        guard !NotchMetrics.isFlush(notchPanel.frame, to: position, in: screen) else { return }
        let size = NotchMetrics.panelSize(profileCount: max(store.profiles.count, 1), position: position)
        settings.notchOffset = NotchMetrics.offsetFromFrame(notchPanel.frame, in: screen, position: position)
        applyPinnedFrame(size: size, offset: settings.notchOffset ?? 0, in: screen, position: position)
        updateTooltip(for: hover.hoveredID)
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
                    panel: notchPanel.frame,
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
                        panel: notchPanel.frame,
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
        let exit = NSMenuItem(
            title: "Exit",
            action: #selector(NotchMenuActions.exit),
            keyEquivalent: ""
        )
        exit.target = menuActions
        menu.addItem(exit)
        if let view = notchPanel.contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
    }

    private func updateTooltip(for profileID: String?) {
        guard let profileID,
              let index = store.profiles.firstIndex(where: { $0.id == profileID })
        else {
            tooltipPanel.alphaValue = 0
            tooltipPanel.orderOut(nil)
            return
        }

        let windows = store.snapshot(for: store.profiles[index])?.quotaWindows.count ?? 1
        let tooltipHeight = NotchMetrics.tooltipHeight(windowCount: max(windows, 1))
        let size = NSSize(width: NotchMetrics.tooltipWidth + 8, height: tooltipHeight)
        let meter = NotchMetrics.meterCenter(
            index: index,
            count: store.profiles.count,
            in: notchPanel.frame,
            position: settings.notchPosition
        )
        tooltipPanel.setFrame(
            NotchMetrics.tooltipFrame(size: size, meter: meter, position: settings.notchPosition),
            display: true
        )
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        return panel
    }
}

@MainActor
final class NotchHoverState: ObservableObject {
    @Published var hoveredID: String?
}

final class NotchMenuActions: NSObject {
    var onRefresh: (() -> Void)?

    @objc func refresh() {
        onRefresh?()
    }

    @objc func exit() {
        NSApp.terminate(nil)
    }
}

enum NotchMetrics {
    static let ringSize: CGFloat = 44
    static let inset: CGFloat = 10
    static let earRadius: CGFloat = 12
    static let bodyRadius: CGFloat = 24
    static let tooltipWidth: CGFloat = 248

    static var notchWidth: CGFloat { ringSize + inset * 2 }
    static var ringGap: CGFloat { inset }
    static var innerRingSize: CGFloat { ringSize - inset }
    static var contentTop: CGFloat { earRadius + inset }
    static var rowHeight: CGFloat { ringSize + ringGap }

    static func height(for profileCount: Int) -> CGFloat {
        let rings = CGFloat(profileCount) * ringSize + CGFloat(max(profileCount - 1, 0)) * ringGap
        return contentTop + rings + contentTop
    }

    static func panelSize(profileCount: Int, position: NotchPosition) -> NSSize {
        let along = height(for: profileCount)
        let thick = notchWidth
        return position.isHorizontal ? NSSize(width: along, height: thick) : NSSize(width: thick, height: along)
    }

    static func along(for size: NSSize, position: NotchPosition) -> CGFloat {
        position.isHorizontal ? size.width : size.height
    }

    static func edgeLength(in screen: NSRect, position: NotchPosition) -> CGFloat {
        position.isHorizontal ? screen.width : screen.height
    }

    static func maxOffset(size: NSSize, in screen: NSRect, position: NotchPosition) -> CGFloat {
        max(0, edgeLength(in: screen, position: position) - along(for: size, position: position))
    }

    static func defaultOffset(size: NSSize, in screen: NSRect, position: NotchPosition) -> CGFloat {
        let maxOff = maxOffset(size: size, in: screen, position: position)
        return position == .bottom ? maxOff : maxOff / 2
    }

    static func resolvedOffset(_ stored: CGFloat?, size: NSSize, in screen: NSRect, position: NotchPosition) -> CGFloat {
        let maxOff = maxOffset(size: size, in: screen, position: position)
        if let stored { return min(max(stored, 0), maxOff) }
        return defaultOffset(size: size, in: screen, position: position)
    }

    static func offsetFromFrame(_ frame: NSRect, in screen: NSRect, position: NotchPosition) -> CGFloat {
        switch position {
        case .right, .left:
            return screen.maxY - frame.maxY
        case .top, .bottom:
            return frame.minX - screen.minX
        }
    }

    static func isFlush(_ frame: NSRect, to position: NotchPosition, in screen: NSRect) -> Bool {
        switch position {
        case .right: return abs(frame.maxX - screen.maxX) < 1
        case .left: return abs(frame.minX - screen.minX) < 1
        case .top: return abs(frame.maxY - screen.maxY) < 1
        case .bottom: return abs(frame.minY - screen.minY) < 1
        }
    }

    static func framesMatch(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.minX - b.minX) < 0.5
            && abs(a.minY - b.minY) < 0.5
            && abs(a.width - b.width) < 0.5
            && abs(a.height - b.height) < 0.5
    }

    static func panelOrigin(size: NSSize, offset: CGFloat, in screen: NSRect, position: NotchPosition) -> NSPoint {
        let o = resolvedOffset(offset, size: size, in: screen, position: position)
        switch position {
        case .right:
            return NSPoint(x: screen.maxX - size.width, y: screen.maxY - o - size.height)
        case .left:
            return NSPoint(x: screen.minX, y: screen.maxY - o - size.height)
        case .top:
            return NSPoint(x: screen.minX + o, y: screen.maxY - size.height)
        case .bottom:
            return NSPoint(x: screen.minX + o, y: screen.minY)
        }
    }

    static func nearestEdge(to point: NSPoint, in screen: NSRect, current: NotchPosition) -> NotchPosition {
        let nearest = ([NotchPosition.top, .right, .bottom, .left].min { a, b in
            distance(point, to: a, in: screen) < distance(point, to: b, in: screen)
        }) ?? current
        if nearest == current { return current }
        let dCurrent = distance(point, to: current, in: screen)
        let dNew = distance(point, to: nearest, in: screen)
        return dNew + 24 < dCurrent ? nearest : current
    }

    static func distance(_ point: NSPoint, to position: NotchPosition, in screen: NSRect) -> CGFloat {
        switch position {
        case .top: return abs(screen.maxY - point.y)
        case .right: return abs(screen.maxX - point.x)
        case .bottom: return abs(point.y - screen.minY)
        case .left: return abs(point.x - screen.minX)
        }
    }

    static func edgeCoordinate(_ point: NSPoint, in screen: NSRect, position: NotchPosition) -> CGFloat {
        position.isHorizontal ? point.x - screen.minX : screen.maxY - point.y
    }

    static func clickAlong(point: NSPoint, panel: NSRect, position: NotchPosition) -> CGFloat {
        position.isHorizontal ? point.x - panel.minX : panel.maxY - point.y
    }

    static func tooltipHeight(windowCount: Int) -> CGFloat {
        56 + CGFloat(windowCount) * 62
    }

    static func meterCenter(
        index: Int,
        count: Int,
        in frame: NSRect,
        position: NotchPosition
    ) -> CGPoint {
        let along = contentTop + CGFloat(index) * rowHeight + ringSize / 2
        switch position {
        case .right:
            return CGPoint(x: frame.minX, y: frame.maxY - along)
        case .left:
            return CGPoint(x: frame.maxX, y: frame.maxY - along)
        case .top:
            return CGPoint(x: frame.minX + along, y: frame.minY)
        case .bottom:
            return CGPoint(x: frame.minX + along, y: frame.maxY)
        }
    }

    static func tooltipFrame(size: NSSize, meter: CGPoint, position: NotchPosition) -> NSRect {
        let gap: CGFloat = 10
        switch position {
        case .right:
            return NSRect(x: meter.x - gap - size.width, y: meter.y - size.height / 2, width: size.width, height: size.height)
        case .left:
            return NSRect(x: meter.x + gap, y: meter.y - size.height / 2, width: size.width, height: size.height)
        case .top:
            return NSRect(x: meter.x - size.width / 2, y: meter.y - gap - size.height, width: size.width, height: size.height)
        case .bottom:
            return NSRect(x: meter.x - size.width / 2, y: meter.y + gap, width: size.width, height: size.height)
        }
    }
}

final class NotchPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}
