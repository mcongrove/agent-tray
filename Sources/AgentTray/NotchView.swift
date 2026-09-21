import SwiftUI

struct NotchView: View {
    @ObservedObject var store: StatsStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var hover: NotchHoverState

    private var position: NotchPosition { settings.notchPosition }

    var body: some View {
        let along = NotchMetrics.height(for: max(store.profiles.count, 1))
        meters
            .frame(
                width: position.isHorizontal ? along : NotchMetrics.notchWidth,
                height: position.isHorizontal ? NotchMetrics.notchWidth : along
            )
    }

    private var meters: some View {
        let stack = ForEach(store.profiles) { profile in
            NotchMeter(
                profile: profile,
                snapshot: store.snapshot(for: profile),
                hovered: hover.hoveredID == profile.id
            )
            .onHover { hovering in
                if hovering {
                    hover.hoveredID = profile.id
                } else if hover.hoveredID == profile.id {
                    hover.hoveredID = nil
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel(for: profile))
        }

        return Group {
            if position.isHorizontal {
                HStack(spacing: NotchMetrics.ringGap) { stack }
            } else {
                VStack(spacing: NotchMetrics.ringGap) { stack }
            }
        }
        .padding(position.isHorizontal ? EdgeInsets(
            top: NotchMetrics.inset,
            leading: NotchMetrics.contentTop,
            bottom: NotchMetrics.inset,
            trailing: NotchMetrics.contentTop
        ) : EdgeInsets(
            top: NotchMetrics.contentTop,
            leading: NotchMetrics.inset,
            bottom: NotchMetrics.contentTop,
            trailing: NotchMetrics.inset
        ))
        .background(EdgeNotchShape(position: position).fill(Color.notchFill))
    }

    private func accessibilityLabel(for profile: AgentProfile) -> String {
        let snapshot = store.snapshot(for: profile)
        if profile.kind == .cursor,
           let models = snapshot?.cursorModelsPercent,
           let other = snapshot?.cursorOtherPercent {
            return "\(profile.displayName) Cursor models \(remainingPercent(models)) percent remaining, other models \(remainingPercent(other)) percent remaining"
        }
        if profile.kind == .codex,
           let weekly = snapshot?.codexWeeklyPercent,
           let fiveHour = snapshot?.codexFiveHourPercent {
            return "\(profile.displayName) weekly \(remainingPercent(weekly)) percent remaining, 5-hour \(remainingPercent(fiveHour)) percent remaining"
        }
        let percent = snapshot?.headlinePercent ?? 0
        return "\(profile.displayName) \(remainingPercent(percent)) percent remaining"
    }
}

struct NotchTooltipHost: View {
    @ObservedObject var store: StatsStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var hover: NotchHoverState

    var body: some View {
        Group {
            if let profile = store.profiles.first(where: { $0.id == hover.hoveredID }) {
                UsageTooltip(
                    profile: profile,
                    snapshot: store.snapshot(for: profile),
                    position: settings.notchPosition,
                    caretShift: hover.caretShift
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct NotchMeter: View {
    let profile: AgentProfile
    let snapshot: AgentSnapshot?
    let hovered: Bool

    var body: some View {
        ZStack {
            if profile.kind == .cursor,
               let models = snapshot?.cursorModelsPercent,
               let other = snapshot?.cursorOtherPercent {
                UsageRing(progress: Double(models) / 100, lineWidth: 2.5)
                    .frame(width: NotchMetrics.ringSize, height: NotchMetrics.ringSize)
                UsageRing(progress: Double(other) / 100, lineWidth: 2)
                    .frame(width: NotchMetrics.innerRingSize, height: NotchMetrics.innerRingSize)
            } else if profile.kind == .codex,
                      let weekly = snapshot?.codexWeeklyPercent,
                      let fiveHour = snapshot?.codexFiveHourPercent {
                UsageRing(progress: Double(weekly) / 100, lineWidth: 2.5)
                    .frame(width: NotchMetrics.ringSize, height: NotchMetrics.ringSize)
                UsageRing(progress: Double(fiveHour) / 100, lineWidth: 2)
                    .frame(width: NotchMetrics.innerRingSize, height: NotchMetrics.innerRingSize)
            } else {
                UsageRing(progress: Double(snapshot?.headlinePercent ?? 0) / 100, lineWidth: 2.5)
                    .frame(width: NotchMetrics.ringSize, height: NotchMetrics.ringSize)
            }
            Image(systemName: profile.kind.symbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }
        .scaleEffect(hovered ? 1.06 : 1)
        .frame(width: NotchMetrics.ringSize, height: NotchMetrics.ringSize)
        .contentShape(Rectangle())
    }
}

private struct UsageRing: View {
    let progress: Double
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.14), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0.02), 1))
                .stroke(usageColor(progress), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

private struct UsageTooltip: View {
    let profile: AgentProfile
    let snapshot: AgentSnapshot?
    var position: NotchPosition = .right
    var caretShift: CGSize = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: profile.kind.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                Text("\(profile.displayName) Usage")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)

            if let snapshot, !snapshot.quotaWindows.isEmpty {
                ForEach(snapshot.quotaWindows) { window in
                    tooltipRow(window)
                }
            } else if let message = snapshot?.health.message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Reading usage…")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.72))
            }
        }
        .padding(14)
        .frame(width: NotchMetrics.tooltipWidth, alignment: .leading)
        .background(Color.notchFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(alignment: caretAlignment) {
            TooltipCaret(position: position)
                .fill(Color.notchFill)
                .frame(width: caretSize.width, height: caretSize.height)
                .offset(caretOffset)
        }
    }

    private func tooltipRow(_ window: QuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                if let reset = window.resetsAt {
                    Text("Resets \(reset.resetDescription)")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.48))
                        .lineLimit(1)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(usageColor(window.usedPercent))
                        .frame(width: max(geo.size.width * CGFloat(window.usedPercent) / 100, 4))
                }
            }
            .frame(height: 5)
            Text(window.detail ?? "\(remainingPercent(window.usedPercent))% remaining")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.72))
                .monospacedDigit()
        }
    }

    private var caretAlignment: Alignment {
        switch position {
        case .right: .trailing
        case .left: .leading
        case .top: .bottom
        case .bottom: .top
        }
    }

    private var caretSize: CGSize {
        position.isHorizontal ? CGSize(width: 16, height: 9) : CGSize(width: 9, height: 16)
    }

    private var caretOffset: CGSize {
        let edge: CGSize
        switch position {
        case .right: edge = CGSize(width: 6, height: 0)
        case .left: edge = CGSize(width: -6, height: 0)
        case .top: edge = CGSize(width: 0, height: 6)
        case .bottom: edge = CGSize(width: 0, height: -6)
        }
        return CGSize(width: edge.width + caretShift.width, height: edge.height + caretShift.height)
    }

}

private struct TooltipCaret: Shape {
    var position: NotchPosition = .right

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch position {
        case .right:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        case .left:
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .top:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        case .bottom:
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        path.closeSubpath()
        return path
    }
}

private struct EdgeNotchShape: Shape {
    var position: NotchPosition = .right

    func path(in rect: CGRect) -> Path {
        let thick = position.isHorizontal ? rect.height : rect.width
        let along = position.isHorizontal ? rect.width : rect.height
        let canonical = rightEdgePath(width: thick, height: along)
        switch position {
        case .right:
            return canonical
        case .left:
            return canonical.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.width, ty: 0))
        case .top:
            return canonical.applying(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: thick))
        case .bottom:
            return canonical.applying(CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0))
        }
    }

    private func rightEdgePath(width w: CGFloat, height h: CGFloat) -> Path {
        let e = NotchMetrics.earRadius
        let b = NotchMetrics.bodyRadius
        let ke = 0.5519150244935106 * e
        let kb = 0.5519150244935106 * b
        var path = Path()

        path.move(to: CGPoint(x: w, y: 0))
        path.addLine(to: CGPoint(x: w, y: h))
        path.addCurve(
            to: CGPoint(x: w - e, y: h - e),
            control1: CGPoint(x: w, y: h - ke),
            control2: CGPoint(x: w - e + ke, y: h - e)
        )
        path.addLine(to: CGPoint(x: b, y: h - e))
        path.addCurve(
            to: CGPoint(x: 0, y: h - e - b),
            control1: CGPoint(x: b - kb, y: h - e),
            control2: CGPoint(x: 0, y: h - e - b + kb)
        )
        path.addLine(to: CGPoint(x: 0, y: e + b))
        path.addCurve(
            to: CGPoint(x: b, y: e),
            control1: CGPoint(x: 0, y: e + b - kb),
            control2: CGPoint(x: b - kb, y: e)
        )
        path.addLine(to: CGPoint(x: w - e, y: e))
        path.addCurve(
            to: CGPoint(x: w, y: 0),
            control1: CGPoint(x: w - e + ke, y: e),
            control2: CGPoint(x: w, y: ke)
        )
        path.closeSubpath()
        return path
    }
}

private func remainingPercent(_ usedPercent: Int) -> Int {
    min(max(100 - usedPercent, 0), 100)
}

private func usageColor(_ usedPercent: Int) -> Color {
    if usedPercent >= 75 { return Color.notchDanger }
    if usedPercent >= 50 { return Color.notchWarn }
    return Color.notchAccent
}

private func usageColor(_ progress: Double) -> Color {
    usageColor(Int((progress * 100).rounded()))
}

private extension Color {
    static let notchFill = Color(red: 0.04, green: 0.04, blue: 0.045)
    static let notchAccent = Color(red: 0.45, green: 0.95, blue: 0.38)
    static let notchWarn = Color(red: 0.98, green: 0.78, blue: 0.18)
    static let notchDanger = Color(red: 0.95, green: 0.32, blue: 0.28)
}
