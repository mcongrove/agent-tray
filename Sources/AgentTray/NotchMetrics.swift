import AppKit

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
        resolvedOffset(stored, maxOffset: maxOffset(size: size, in: screen, position: position), position: position)
    }

    static func resolvedOffset(_ stored: CGFloat?, maxOffset: CGFloat, position: NotchPosition) -> CGFloat {
        if let stored { return min(max(stored, 0), maxOffset) }
        return position == .bottom ? maxOffset : maxOffset / 2
    }

    static func hostFrame(in screen: NSRect, position: NotchPosition) -> NSRect {
        let thick = notchWidth
        switch position {
        case .right:
            return NSRect(x: screen.maxX - thick, y: screen.minY, width: thick, height: screen.height)
        case .left:
            return NSRect(x: screen.minX, y: screen.minY, width: thick, height: screen.height)
        case .top:
            return NSRect(x: screen.minX, y: screen.maxY - thick, width: screen.width, height: thick)
        case .bottom:
            return NSRect(x: screen.minX, y: screen.minY, width: screen.width, height: thick)
        }
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

    static func tooltipPlacement(
        size: NSSize,
        meter: CGPoint,
        position: NotchPosition,
        in bounds: NSRect
    ) -> TooltipPlacement {
        let gap: CGFloat = 0
        let margin: CGFloat = 10
        let preferred: NSRect
        switch position {
        case .right:
            preferred = NSRect(x: meter.x - gap - size.width, y: meter.y - size.height / 2, width: size.width, height: size.height)
        case .left:
            preferred = NSRect(x: meter.x + gap, y: meter.y - size.height / 2, width: size.width, height: size.height)
        case .top:
            preferred = NSRect(x: meter.x - size.width / 2, y: meter.y - gap - size.height, width: size.width, height: size.height)
        case .bottom:
            preferred = NSRect(x: meter.x - size.width / 2, y: meter.y + gap, width: size.width, height: size.height)
        }

        let inset = bounds.insetBy(dx: margin, dy: margin)
        let frame = clamp(preferred, to: inset)
        let maxShift = CGSize(
            width: max(0, size.width / 2 - 22),
            height: max(0, size.height / 2 - 22)
        )
        var caret = CGSize(
            width: meter.x - frame.midX,
            height: frame.midY - meter.y
        )
        switch position {
        case .top, .bottom:
            caret.height = 0
        case .left, .right:
            caret.width = 0
        }
        caret.width = min(max(caret.width, -maxShift.width), maxShift.width)
        caret.height = min(max(caret.height, -maxShift.height), maxShift.height)
        return TooltipPlacement(frame: frame, caretShift: caret)
    }

    private static func clamp(_ rect: NSRect, to bounds: NSRect) -> NSRect {
        var frame = rect
        if frame.width >= bounds.width {
            frame.origin.x = bounds.midX - frame.width / 2
        } else {
            frame.origin.x = min(max(frame.minX, bounds.minX), bounds.maxX - frame.width)
        }
        if frame.height >= bounds.height {
            frame.origin.y = bounds.midY - frame.height / 2
        } else {
            frame.origin.y = min(max(frame.minY, bounds.minY), bounds.maxY - frame.height)
        }
        return frame
    }
}

struct TooltipPlacement: Equatable {
    var frame: NSRect
    var caretShift: CGSize
}

