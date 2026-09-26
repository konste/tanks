import SwiftUI

/// The fixed 780×430 panel: header, advice strip, three vendor columns, legend footer. Nothing
/// scrolls; the column content is sized to fit the tallest vendor (Claude: two accounts × up to
/// four windows plus the paid line).
struct TanksDashboardView: View {
    static let size = CGSize(width: 780, height: 430)

    @Environment(TanksContainer.self) private var container
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = TanksPalette.forScheme(scheme)
        VStack(spacing: 0) {
            header(p)
            Divider().overlay(p.line)
            AdviceStrip(palette: p)
            Divider().overlay(p.line)
            HStack(spacing: 0) {
                ForEach(Vendor.allCases, id: \.self) { vendor in
                    VendorColumn(vendor: vendor, palette: p)
                    if vendor != .cursor { Divider().overlay(p.line) }
                }
            }
            .frame(maxHeight: .infinity)
            Divider().overlay(p.line)
            footer(p)
        }
        .font(.system(size: 12))
        .foregroundStyle(p.fg)
        .background(p.bg)
        .frame(width: Self.size.width, height: Self.size.height)
        .monospacedDigit()
    }

    private func header(_ p: TanksPalette) -> some View {
        HStack(spacing: 10) {
            Text("Tanks").font(.system(size: 14, weight: .bold))
            Spacer()
            Text(container.headerMeta).font(.system(size: 11.5)).foregroundStyle(p.dim)
        }
        .padding(.horizontal, 14)
        .padding(.top, 9)
        .padding(.bottom, 7)
    }

    private func footer(_ p: TanksPalette) -> some View {
        HStack(spacing: 14) {
            Button("Refresh") { container.store.refreshAll() }.buttonStyle(.plain).foregroundStyle(p.link)
            Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.plain).foregroundStyle(p.link)
            Spacer()
            Text("solid = used · hatched = projected by reset · red tick = crosses 100% first · blue = idle or not signed in")
                .foregroundStyle(p.dim)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }
}

// MARK: - Advice strip

private struct AdviceStrip: View {
    @Environment(TanksContainer.self) private var container
    var palette: TanksPalette

    var body: some View {
        let advice = Array(container.store.visibleAdvice.prefix(2))
        let alert = advice.contains { $0.severity == .alert }
        VStack(alignment: .leading, spacing: 3) {
            if advice.isEmpty {
                HStack(spacing: 8) {
                    Circle().fill(palette.green).frame(width: 8, height: 8)
                    Text(container.store.lastTick == nil ? "First readings on their way…" : "All windows on course; no switch needed.")
                }
                .font(.system(size: 12.5))
            }
            ForEach(advice) { item in
                AdviceRow(advice: item, palette: palette)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(alert ? palette.alertBg : palette.bg2)
    }
}

private struct AdviceRow: View {
    @Environment(TanksContainer.self) private var container
    var advice: Advice
    var palette: TanksPalette

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(palette.severity(advice.severity)).frame(width: 8, height: 8)
            HStack(spacing: 6) {
                Text(advice.text).lineLimit(1).truncationMode(.tail)
                if let detail = advice.detail {
                    Text(detail).foregroundStyle(palette.dim).font(.system(size: 11))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if case .switchTo(let target) = advice.action {
                Button("Switch to \(container.config.account(target).label)") {
                    container.performSwitch(to: target)
                }
                .buttonStyle(TanksButtonStyle(fill: advice.severity == .alert ? Color(hex: 0xD8453A) : Color(hex: 0x3F6FD8)))
            }
            Button("Dismiss") { container.store.dismiss(advice) }
                .buttonStyle(TanksButtonStyle(fill: .clear, stroke: palette.link, text: palette.link))
        }
        .font(.system(size: 12.5))
    }
}

struct TanksButtonStyle: ButtonStyle {
    var fill: Color
    var stroke: Color? = nil
    var text: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(text)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(stroke ?? .clear, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Vendor column

private struct VendorColumn: View {
    @Environment(TanksContainer.self) private var container
    var vendor: Vendor
    var palette: TanksPalette

    var body: some View {
        let states = container.store.orderedStates(for: vendor)
        VStack(alignment: .leading, spacing: 0) {
            Text(vendor.title)
                .font(.system(size: 12, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(palette.vendor(vendor))
                .padding(.bottom, 4)
            ForEach(states, id: \.account.id) { state in
                AccountBlock(state: state, palette: palette)
            }
            Spacer(minLength: 4)
            paidLine(states)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The column's bottom line: the paid overflow for the active account, or the team total for
    /// Cursor (both accounts' spend against the shared limit).
    @ViewBuilder
    private func paidLine(_ states: [TankStore.AccountState]) -> some View {
        let paid = states.first(where: \.isActive)?.projections.first { $0.tank.isPaid }
        HStack {
            switch vendor {
            case .cursor:
                let spends = states.compactMap { $0.projections.first { $0.tank.key == "spend" }?.tank }
                let total = spends.map(\.used).reduce(0, +)
                let limit = spends.map(\.limit).reduce(0, +)
                Text("spend this cycle, both").foregroundStyle(palette.dim)
                Spacer()
                Text(spends.isEmpty ? "—" : "\(Fmt.dollars(total))\(limit > 0 ? " / \(Fmt.dollars(limit))" : "")").fontWeight(.semibold)
            default:
                if let paid {
                    Text(paid.tank.label).foregroundStyle(palette.dim)
                    Spacer()
                    Text(paid.tank.limit > 0 ? "\(Fmt.amount(paid.tank.used, paid.tank)) / \(Fmt.amount(paid.tank.limit, paid.tank))" : (paid.tank.note ?? Fmt.amount(paid.tank.used, paid.tank)))
                        .fontWeight(.semibold)
                        .foregroundStyle(paid.tank.limit > 0 && paid.fill >= Advisor.creditsGuard ? palette.red : palette.fg)
                } else {
                    Text(vendor == .codex ? "flex credits" : "credits (paid)").foregroundStyle(palette.dim)
                    Spacer()
                    Text("none").fontWeight(.semibold)
                }
            }
        }
        .font(.system(size: 11))
        .padding(.top, 5)
        .overlay(alignment: .top) {
            Rectangle().fill(palette.line).frame(height: 1)
        }
    }
}

private struct AccountBlock: View {
    @Environment(TanksContainer.self) private var container
    var state: TankStore.AccountState
    var palette: TanksPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(state.account.label)
                    .foregroundStyle(state.isActive ? palette.fg : palette.dim)
                if state.isActive {
                    Text("ACTIVE")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.4)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(palette.pillBg))
                        .foregroundStyle(palette.pillFg)
                }
                if let plan = state.reading?.plan {
                    Text(plan).font(.system(size: 10)).foregroundStyle(palette.dim2)
                }
                Spacer()
                if !state.isActive {
                    if state.account.id.vendor == .cursor {
                        Text("manual").font(.system(size: 10.5)).foregroundStyle(palette.dim2)
                    } else {
                        Button("switch") { container.performSwitch(to: state.account.id) }
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5))
                            .foregroundStyle(palette.link)
                    }
                }
            }
            .font(.system(size: 11.5))
            .padding(.top, 6)
            .padding(.bottom, 2)

            if let reading = state.reading, case .signedOut(let reason) = reading.status {
                Text(reason).font(.system(size: 10.5)).foregroundStyle(palette.blue).lineLimit(2)
                    .padding(.vertical, 4)
            } else if state.projections.isEmpty {
                Text(state.lastError ?? "waiting for first reading…").font(.system(size: 10.5)).foregroundStyle(palette.dim2)
                    .padding(.vertical, 4)
            }
            ForEach(state.projections.filter { !$0.tank.isPaid }, id: \.tank.key) { projection in
                TankRow(projection: projection, stale: !(state.reading?.isLive ?? false), palette: palette)
            }
            if let reading = state.reading, !reading.byModel.isEmpty {
                Text(reading.byModel.prefix(4).map { "\($0.model) \(Fmt.dollars($0.dollars))" }.joined(separator: " · "))
                    .font(.system(size: 10.5)).foregroundStyle(palette.dim)
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .padding(.leading, 48)
            }
        }
    }
}

// MARK: - Tank row

private struct TankRow: View {
    var projection: TankProjection
    var stale: Bool
    var palette: TanksPalette

    var body: some View {
        let tank = projection.tank
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(tank.label).font(.system(size: 11)).foregroundStyle(palette.dim).frame(width: 40, alignment: .leading).lineLimit(1)
                TankBar(projection: projection, stale: stale, palette: palette).frame(height: 11)
                Text(value).font(.system(size: tank.format == .percent ? 11.5 : 10.5, weight: .semibold)).frame(width: 40, alignment: .trailing).lineLimit(1)
            }
            HStack {
                Text(leftNote).foregroundStyle(leftColor)
                Spacer()
                Text(rightNote)
            }
            .font(.system(size: 10.5)).foregroundStyle(palette.dim)
            .padding(.leading, 48)
            .lineLimit(1)
        }
        .padding(.vertical, 1.5)
    }

    private var value: String {
        switch projection.tank.format {
        case .percent: Fmt.percent(projection.tank.fill)
        case .dollars: Fmt.dollars(projection.tank.used)
        case .credits: Fmt.percent(projection.tank.fill)
        }
    }

    private var leftNote: String {
        let tank = projection.tank
        if stale { return "stale" }
        if let crosses = projection.crossesAt { return "100% at \(Fmt.clock(crosses))" }
        if let projected = projection.projectedAtReset {
            switch tank.format {
            case .percent, .credits: return "→ \(Fmt.percent(min(1, projected / max(tank.limit, 0.0001)))) at reset"
            case .dollars: return "→ \(Fmt.dollars(projected)) of \(tank.limit > 0 ? Fmt.dollars(tank.limit) : "no limit")"
            }
        }
        if tank.format == .dollars { return "of \(tank.limit > 0 ? Fmt.dollars(tank.limit) : "no limit")" }
        if let note = tank.note { return note }
        return projection.ratePerHour == nil && tank.used == 0 ? "idle" : ""
    }

    private var leftColor: Color {
        if projection.crossesAt != nil { return palette.red }
        if projection.tier == .amber { return palette.amber }
        return palette.dim
    }

    private var rightNote: String {
        projection.tank.resetsAt.map { "↺ \(Fmt.clock($0))" } ?? ""
    }
}

private struct TankBar: View {
    var projection: TankProjection
    var stale: Bool
    var palette: TanksPalette

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let used = w * projection.fill
            let projected = w * (projection.projectedFill ?? projection.fill)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(palette.track)
                RoundedRectangle(cornerRadius: 3)
                    .fill(stale ? palette.dim2 : palette.tier(projection.tier))
                    .frame(width: max(used, projection.fill > 0 ? 3 : 0))
                if projected > used + 1 {
                    Hatch(color: palette.hatch)
                        .frame(width: projected - used)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .offset(x: used)
                }
                if projection.crossesAt != nil {
                    RoundedRectangle(cornerRadius: 2).fill(palette.red)
                        .frame(width: 3, height: geo.size.height + 4)
                        .offset(x: w - 1, y: -2)
                }
            }
        }
    }
}

/// 45° hatching, the "projected by reset" texture.
private struct Hatch: View {
    var color: Color

    var body: some View {
        Canvas { context, size in
            var x = -size.height
            while x < size.width + size.height {
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                context.stroke(path, with: .color(color), lineWidth: 2.5)
                x += 6
            }
        }
    }
}
