import SwiftUI

/// Every point size in this file is written at the original 780×430 design and multiplied by
/// this factor, so the panel scales as one unit. 4/3 is his 2026-09-26 ask ("1/3 larger in both
/// directions").
let S: CGFloat = 4.0 / 3.0

/// The fixed 1040×600 panel (780×450 × S; the extra 20 design points are room for advice lines that wrap): header, advice strip, three vendor columns, legend footer. Nothing
/// scrolls; the column content is sized to fit the tallest vendor (Claude: two accounts × up to
/// four windows plus the paid line).
struct TanksDashboardView: View {
    static let size = CGSize(width: 780 * S, height: 450 * S)

    @Environment(TanksContainer.self) private var container
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = TanksPalette.forScheme(scheme)
        VStack(spacing: 0 * S) {
            header(p)
            Divider().overlay(p.line)
            AdviceStrip(palette: p)
            Divider().overlay(p.line)
            HStack(spacing: 0 * S) {
                ForEach(Vendor.allCases, id: \.self) { vendor in
                    VendorColumn(vendor: vendor, palette: p)
                    if vendor != .cursor { Divider().overlay(p.line) }
                }
            }
            .frame(maxHeight: .infinity)
            Divider().overlay(p.line)
            footer(p)
        }
        .font(.system(size: 12 * S))
        .foregroundStyle(p.fg)
        .background(p.bg)
        .frame(width: Self.size.width, height: Self.size.height)
        .monospacedDigit()
    }

    private func header(_ p: TanksPalette) -> some View {
        HStack(spacing: 10 * S) {
            Text("Tanks").font(.system(size: 14 * S, weight: .bold))
            Spacer()
            Text(container.headerMeta).font(.system(size: 11.5 * S)).foregroundStyle(p.dim)
        }
        .padding(.horizontal, 14 * S)
        .padding(.top, 9 * S)
        .padding(.bottom, 7 * S)
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    private func footer(_ p: TanksPalette) -> some View {
        HStack(spacing: 14 * S) {
            Button("Refresh") { container.store.refreshAll() }.buttonStyle(.plain).foregroundStyle(p.link)
            Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.plain).foregroundStyle(p.link)
            Spacer()
            Text("solid = used · hatched = projected by reset · red tick = crosses 100% first · blue = idle or not signed in")
                .foregroundStyle(p.dim)
        }
        .font(.system(size: 11 * S))
        .padding(.horizontal, 14 * S)
        .padding(.vertical, 5 * S)
    }
}

// MARK: - Advice strip

private struct AdviceStrip: View {
    @Environment(TanksContainer.self) private var container
    var palette: TanksPalette

    var body: some View {
        let advice = Array(container.store.visibleAdvice.prefix(2))
        let alert = advice.contains { $0.severity == .alert }
        VStack(alignment: .leading, spacing: 3 * S) {
            if advice.isEmpty {
                HStack(spacing: 8 * S) {
                    Circle().fill(palette.green).frame(width: 8 * S, height: 8 * S)
                    Text(container.store.lastTick == nil ? "First readings on their way…" : "All windows on course; no switch needed.")
                }
                .font(.system(size: 12.5 * S))
            }
            ForEach(advice) { item in
                AdviceRow(advice: item, palette: palette)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 50 * S, alignment: .leading)
        .padding(.horizontal, 14 * S)
        .padding(.vertical, 6 * S)
        .background(alert ? palette.alertBg : palette.bg2)
    }
}

private struct AdviceRow: View {
    @Environment(TanksContainer.self) private var container
    var advice: Advice
    var palette: TanksPalette

    var body: some View {
        HStack(alignment: .top, spacing: 8 * S) {
            Circle().fill(palette.severity(advice.severity)).frame(width: 8 * S, height: 8 * S)
                .padding(.top, 5 * S)
            // One paragraph, detail trailing in the dim style, wrapping to a second line when the
            // advice is long (it nearly always is, his observation 2026-09-26); the tooltip
            // carries the full text for the rare third line.
            (Text(advice.text) + Text(advice.detail.map { "  \($0)" } ?? "").foregroundColor(palette.dim).font(.system(size: 11 * S)))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(advice.detail.map { "\(advice.text)  \($0)" } ?? advice.text)
            if case .switchTo(let target) = advice.action {
                Button("Switch to \(container.config.account(target).label)") {
                    container.performSwitch(to: target)
                }
                .buttonStyle(TanksButtonStyle(fill: advice.severity == .alert ? Color(hex: 0xD8453A) : Color(hex: 0x3F6FD8)))
            }
            Button("Dismiss") { container.store.dismiss(advice) }
                .buttonStyle(TanksButtonStyle(fill: .clear, stroke: palette.link, text: palette.link))
        }
        .font(.system(size: 12.5 * S))
    }
}

struct TanksButtonStyle: ButtonStyle {
    var fill: Color
    var stroke: Color? = nil
    var text: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12 * S, weight: .semibold))
            .foregroundStyle(text)
            .padding(.horizontal, 9 * S)
            .padding(.vertical, 3 * S)
            .background(RoundedRectangle(cornerRadius: 6 * S).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 6 * S).stroke(stroke ?? .clear, lineWidth: 1 * S))
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
        VStack(alignment: .leading, spacing: 0 * S) {
            Text(vendor.title)
                .font(.system(size: 12 * S, weight: .bold))
                .tracking(0.6 * S)
                .foregroundStyle(palette.vendor(vendor))
                .padding(.bottom, 4 * S)
            ForEach(states, id: \.account.id) { state in
                AccountBlock(state: state, palette: palette)
            }
            Spacer(minLength: 4 * S)
            paidLine(states)
        }
        .padding(.horizontal, 12 * S)
        .padding(.top, 8 * S)
        .padding(.bottom, 6 * S)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The column's bottom line: a meter the whole team shares (Cursor's on-demand spend against
    /// the team cap). Per-account paid lines live in each account block, so vendors without a team
    /// meter have no bottom line.
    @ViewBuilder
    private func paidLine(_ states: [TankStore.AccountState]) -> some View {
        if let team = states.compactMap({ $0.reading?.teamPaid }).first {
            HStack {
                Text(team.label).foregroundStyle(palette.dim)
                Spacer()
                Text(PaidLine.amount(team))
                    .fontWeight(.semibold)
                    .foregroundStyle(PaidLine.isHot(team) ? palette.red : palette.fg)
            }
            .font(.system(size: 11 * S))
            .padding(.top, 5 * S)
            .overlay(alignment: .top) {
                Rectangle().fill(palette.line).frame(height: 1 * S)
            }
            .help("all members' on-demand spend this cycle against the team cap\(team.windowStart.flatMap { s in team.resetsAt.map { e in ", \(Fmt.fullDate(s)) – \(Fmt.fullDate(e))" } } ?? "")")
        }
    }
}

/// Text for a paid meter: `$41.50 / $50` against a cap, `$129 · no limit` without one.
enum PaidLine {
    static func amount(_ tank: Tank) -> String {
        if tank.limit > 0 { return "\(Fmt.amount(tank.used, tank)) / \(Fmt.amount(tank.limit, tank))" }
        return tank.note.map { "\(Fmt.amount(tank.used, tank)) · \($0)" } ?? Fmt.amount(tank.used, tank)
    }

    static func isHot(_ tank: Tank) -> Bool {
        tank.limit > 0 && tank.fill >= Advisor.creditsGuard
    }
}

private struct AccountBlock: View {
    @Environment(TanksContainer.self) private var container
    var state: TankStore.AccountState
    var palette: TanksPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 0 * S) {
            HStack(spacing: 6 * S) {
                Text(state.account.label)
                    .foregroundStyle(state.isActive ? palette.fg : palette.dim)
                if state.isActive {
                    Text("ACTIVE")
                        .font(.system(size: 9.5 * S, weight: .semibold))
                        .tracking(0.4 * S)
                        .padding(.horizontal, 5 * S).padding(.vertical, 1 * S)
                        .background(RoundedRectangle(cornerRadius: 4 * S).fill(palette.pillBg))
                        .foregroundStyle(palette.pillFg)
                }
                if let plan = state.reading?.plan {
                    Text(plan).font(.system(size: 10 * S)).foregroundStyle(palette.dim2)
                }
                Spacer()
                if !state.isActive {
                    if state.account.id.vendor == .cursor {
                        Text("manual").font(.system(size: 10.5 * S)).foregroundStyle(palette.dim2)
                    } else {
                        Button("switch") { container.performSwitch(to: state.account.id) }
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5 * S))
                            .foregroundStyle(palette.link)
                    }
                }
            }
            .font(.system(size: 11.5 * S))
            .padding(.top, 6 * S)
            .padding(.bottom, 2 * S)

            if let reading = state.reading, case .signedOut(let reason) = reading.status {
                Text(reason).font(.system(size: 10.5 * S)).foregroundStyle(palette.blue).lineLimit(2)
                    .padding(.vertical, 4 * S)
            } else if state.projections.isEmpty {
                Text(state.lastError ?? "waiting for first reading…").font(.system(size: 10.5 * S)).foregroundStyle(palette.dim2)
                    .padding(.vertical, 4 * S)
            }
            ForEach(state.projections.filter { !$0.tank.isPaid }, id: \.tank.key) { projection in
                TankRow(projection: projection, stale: !(state.reading?.isLive ?? false), palette: palette,
                        labelWidth: Self.labelWidth(state.account.id.vendor))
            }
            // Paid meters print per account (his ask 2026-09-26: "show the amount spent for each
            // account separately"): Claude extra usage, Codex flex credits, Cursor on-demand.
            ForEach(state.projections.filter(\.tank.isPaid), id: \.tank.key) { projection in
                let tank = projection.tank
                HStack {
                    Text(tank.label).foregroundStyle(palette.dim)
                    Spacer()
                    Text(PaidLine.amount(tank))
                        .fontWeight(.semibold)
                        .foregroundStyle(PaidLine.isHot(tank) ? palette.red : palette.fg)
                }
                .font(.system(size: 10.5 * S))
                .padding(.leading, (Self.labelWidth(state.account.id.vendor) + 8) * S)
                .padding(.vertical, 1.5 * S)
                .lineLimit(1)
            }
            if let reading = state.reading, !reading.byModel.isEmpty {
                Text(reading.byModel.prefix(4).map { "\($0.model) \(Fmt.dollars($0.dollars))" }.joined(separator: " · "))
                    .font(.system(size: 10.5 * S)).foregroundStyle(palette.dim)
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .padding(.leading, 48 * S)
            }
        }
    }

    /// Design points for the label column: Cursor's pool names ("cursor models") need more than
    /// the window names ("5-hour") do.
    static func labelWidth(_ vendor: Vendor) -> CGFloat {
        vendor == .cursor ? 80 : 40
    }
}

// MARK: - Tank row

private struct TankRow: View {
    var projection: TankProjection
    var stale: Bool
    var palette: TanksPalette
    var labelWidth: CGFloat = 40

    var body: some View {
        let tank = projection.tank
        VStack(spacing: 0 * S) {
            HStack(spacing: 8 * S) {
                Text(tank.label).font(.system(size: 11 * S)).foregroundStyle(palette.dim).frame(width: labelWidth * S, alignment: .leading).lineLimit(1)
                TankBar(projection: projection, stale: stale, palette: palette).frame(height: 11 * S)
                Text(value).font(.system(size: (tank.format == .percent ? 11.5 : 10.5) * S, weight: .semibold)).frame(width: 40 * S, alignment: .trailing).lineLimit(1)
            }
            // Left: the projection. Right: the window as start – end (his ask 2026-09-26: "show
            // when current period starts/ends"); the tooltip carries both endpoints in full.
            HStack {
                Text(leftNote).foregroundStyle(leftColor).minimumScaleFactor(0.85)
                Spacer()
                Text(rightNote).layoutPriority(1).help(windowHelp)
            }
            .font(.system(size: 10.5 * S)).foregroundStyle(palette.dim)
            .padding(.leading, (labelWidth + 8) * S)
            .lineLimit(1)
        }
        .padding(.vertical, 1.5 * S)
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
        let tank = projection.tank
        guard let end = tank.resetsAt else { return "" }
        guard let start = tank.windowStart else { return "↺ \(Fmt.clock(end))" }
        return Fmt.window(start, end)
    }

    private var windowHelp: String {
        let tank = projection.tank
        guard let end = tank.resetsAt else { return "" }
        guard let start = tank.windowStart else { return "resets \(Fmt.fullDate(end))" }
        return "window \(Fmt.fullDate(start)) – \(Fmt.fullDate(end))"
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
                RoundedRectangle(cornerRadius: 3 * S).fill(palette.track)
                RoundedRectangle(cornerRadius: 3 * S)
                    .fill(stale ? palette.dim2 : palette.tier(projection.tier))
                    .frame(width: max(used, projection.fill > 0 ? 3 * S : 0))
                if projected > used + S {
                    Hatch(color: palette.hatch)
                        .frame(width: projected - used)
                        .clipShape(RoundedRectangle(cornerRadius: 3 * S))
                        .offset(x: used)
                }
                if projection.crossesAt != nil {
                    RoundedRectangle(cornerRadius: 2 * S).fill(palette.red)
                        .frame(width: 3 * S, height: geo.size.height + 4 * S)
                        .offset(x: w - S, y: -2 * S)
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
                context.stroke(path, with: .color(color), lineWidth: 2.5 * S)
                x += 6 * S
            }
        }
    }
}
