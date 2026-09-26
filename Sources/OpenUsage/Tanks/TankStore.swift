import Foundation
import Observation

/// The live state of all six accounts: last reading, projection per tank, advice, and the poll loop.
///
/// Six sources poll on their own 60-second cadence, staggered 10 s apart, so no minute ever fires
/// six requests at once. A 429 backs off that one account for `rateLimitBackoff`; any other failure
/// keeps the last good reading on screen marked stale and retries next tick.
@MainActor
@Observable
final class TankStore {
    struct AccountState: Sendable {
        var account: TankAccount
        var isActive: Bool
        var reading: AccountReading?
        var projections: [TankProjection] = []
        var lastError: String?
        var backoffUntil: Date?
    }

    let config: TanksConfig
    private(set) var states: [TankAccountID: AccountState] = [:]
    private(set) var advice: [Advice] = []
    private(set) var lastTick: Date?
    /// Advice keys the user dismissed; the key carries the window stamp, so a dismissal expires
    /// with the window.
    private(set) var dismissed: Set<String> = []

    var onAdvice: (@MainActor ([Advice]) -> Void)?
    var onStates: (@MainActor ([TankAccountID: AccountState]) -> Void)?

    @ObservationIgnored private let sources: [TankSource]
    @ObservationIgnored private var rings: [String: SampleRing] = [:]
    @ObservationIgnored private var pollTasks: [Task<Void, Never>] = []
    @ObservationIgnored private let now: @Sendable () -> Date

    init(config: TanksConfig, sources: [TankSource], now: @escaping @Sendable () -> Date = Date.init) {
        self.config = config
        self.sources = sources
        self.now = now
        for source in sources {
            states[source.account.id] = AccountState(account: source.account, isActive: Self.isActive(source))
        }
    }

    /// Dev harness: feeds synthetic readings through the normal apply path (snapshot fixtures).
    func applyFixture(_ readings: [AccountReading], activeIDs: Set<TankAccountID>) {
        for id in states.keys { states[id]?.isActive = activeIDs.contains(id) }
        for reading in readings { apply(reading, to: reading.account.id) }
    }

    func orderedStates(for vendor: Vendor) -> [AccountState] {
        let pair = AccountSlot.allCases.compactMap { states[TankAccountID(vendor: vendor, slot: $0)] }
        return pair.sorted { $0.isActive && !$1.isActive }
    }

    var worstActiveProjection: TankProjection? {
        states.values.filter(\.isActive).flatMap(\.projections)
            .filter { !$0.tank.isPaid && $0.tank.format == .percent }
            .max { ($0.projectedFill ?? $0.fill) < ($1.projectedFill ?? $1.fill) }
    }

    var attention: Bool {
        advice.contains { $0.severity == .alert && !dismissed.contains($0.key) }
    }

    var visibleAdvice: [Advice] {
        advice.filter { !dismissed.contains($0.key) }
    }

    func dismiss(_ advice: Advice) {
        dismissed.insert(advice.key)
        recomputeAdvice()
    }

    // MARK: - Polling

    func start() {
        stop()
        for (index, source) in sources.enumerated() {
            // First readings land within seconds of launch; the stagger only spaces the steady-state
            // polls so no minute fires all six requests together.
            let delay = Double(index) * 1.5
            pollTasks.append(Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                while !Task.isCancelled {
                    guard let self else { return }
                    await self.poll(source)
                    let first = self.states[source.account.id]?.reading == nil
                    try? await Task.sleep(for: .seconds(first ? 5 : self.config.pollInterval + Double(index) * self.config.staggerInterval / 6))
                }
            })
        }
    }

    func stop() {
        pollTasks.forEach { $0.cancel() }
        pollTasks.removeAll()
    }

    func refreshAll() {
        for id in states.keys { states[id]?.backoffUntil = nil }
        for source in sources {
            Task { [weak self] in await self?.poll(source) }
        }
    }

    private func poll(_ source: TankSource) async {
        let id = source.account.id
        if let until = states[id]?.backoffUntil, until > now() { return }
        states[id]?.isActive = Self.isActive(source)
        do {
            let reading = try await source.fetch()
            apply(reading, to: id)
        } catch let error as TankSourceError {
            AppLog.warn(.refresh, "\(id): \(error.localizedDescription)")
            switch error {
            case .rateLimited(let secs):
                states[id]?.backoffUntil = now().addingTimeInterval(max(60, Double(secs ?? Int(config.rateLimitBackoff))))
                markStale(id, reason: error.localizedDescription)
            case .notSignedIn(let why):
                var reading = states[id]?.reading
                    ?? AccountReading(account: source.account, plan: nil, tanks: [], fetchedAt: now(), status: .signedOut(reason: why))
                reading.status = .signedOut(reason: why)
                states[id]?.reading = reading
                states[id]?.projections = []
                states[id]?.lastError = why
                finishTick()
            default:
                markStale(id, reason: error.localizedDescription)
            }
        } catch {
            AppLog.warn(.refresh, "\(id): \(error.localizedDescription)")
            markStale(id, reason: error.localizedDescription)
        }
    }

    private func apply(_ reading: AccountReading, to id: TankAccountID) {
        let at = reading.fetchedAt
        var projections: [TankProjection] = []
        for tank in reading.tanks {
            let ringKey = "\(id):\(tank.key)"
            var ring = rings[ringKey] ?? SampleRing(horizon: SampleRing.horizon(forPeriod: tank.periodSeconds))
            ring.append(used: tank.used, at: at)
            rings[ringKey] = ring
            projections.append(TankProjection.make(tank: tank, ring: ring, isActiveAccount: states[id]?.isActive ?? false, now: at))
        }
        states[id]?.reading = reading
        states[id]?.projections = projections
        states[id]?.lastError = nil
        states[id]?.backoffUntil = nil
        finishTick()
    }

    private func markStale(_ id: TankAccountID, reason: String) {
        guard let state = states[id] else { return }
        states[id]?.lastError = reason
        if var reading = state.reading {
            reading.status = .stale(reason: reason)
            states[id]?.reading = reading
        } else {
            let placeholder = AccountReading(account: state.account, plan: nil, tanks: [], fetchedAt: now(), status: .error(reason))
            states[id]?.reading = placeholder
        }
        finishTick()
    }

    private func finishTick() {
        lastTick = now()
        recomputeAdvice()
        onStates?(states)
    }

    private func recomputeAdvice() {
        let assessments = states.values.map {
            AccountAssessment(account: $0.account, isActive: $0.isActive, reading: $0.reading, projections: $0.projections)
        }
        advice = Advisor.advise(assessments, now: now())
        onAdvice?(visibleAdvice)
    }

    /// Re-projects from the rings without a network call, so an open panel's "100% at" and colours
    /// track the clock between polls.
    func reproject() {
        let at = now()
        for (id, state) in states {
            guard let reading = state.reading, reading.isLive || {
                if case .stale = reading.status { return true }
                return false
            }() else { continue }
            states[id]?.projections = reading.tanks.map { tank in
                TankProjection.make(tank: tank, ring: rings["\(id):\(tank.key)"], isActiveAccount: state.isActive, now: at)
            }
        }
        recomputeAdvice()
    }

    private static func isActive(_ source: TankSource) -> Bool {
        switch source {
        case let s as ClaudeTankSource: s.isActive()
        case let s as CodexTankSource: s.isActive()
        case let s as CursorTankSource: s.isActive()
        default: false
        }
    }
}
