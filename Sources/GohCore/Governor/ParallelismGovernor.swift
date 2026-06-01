// Sources/GohCore/Governor/ParallelismGovernor.swift

// MARK: — Wire types (sent between engine and governor)

/// A single per-worker rate sample at a flush boundary.
/// Injected by consumeRange's flush() chokepoint.
public struct WorkerRateSample: Sendable {
    public var workerIndex: Int
    public var bytesPerSecond: Double
    /// Coarse RTT ratio vs observed floor (nil when unavailable or too noisy).
    public var rttRatio: Double?
    public init(workerIndex: Int, bytesPerSecond: Double, rttRatio: Double? = nil) {
        self.workerIndex = workerIndex
        self.bytesPerSecond = bytesPerSecond
        self.rttRatio = rttRatio
    }
}

// MARK: — Governor decision

public enum GovernorDecision: Sendable, Equatable {
    case hold
    case addWorkers(Int)
    /// Reserved for Phase 3 cruise/throttle-response wiring: the live worker pool
    /// cooperatively sheds workers when the cruise controller detects excess concurrency.
    /// `decide()` never emits this in P1 (probe-only); it is not dead code.
    case dropWorkers(Int)
    case commit(Int)
    case backOffPinLow
}

// MARK: — Governor

public struct ParallelismGovernor: Sendable {

    public struct Config: Sendable {
        public var steadyStateWindow: Int
        public var steadyStateThreshold: Double
        public var kneeGainThreshold: Double
        public var rttBufferbloatFactor: Double
        public var hardCap: Int
        public var tinyFileThreshold: UInt64
        public var reproBeCadence: Int
        public var rateAlpha: Double

        public static let `default` = Config(
            steadyStateWindow: 5,
            steadyStateThreshold: 0.05,
            kneeGainThreshold: 0.10,
            rttBufferbloatFactor: 1.5,
            hardCap: 16,
            tinyFileThreshold: 4 * 1024 * 1024,
            reproBeCadence: 20,
            rateAlpha: 0.3)

        public init(
            steadyStateWindow: Int,
            steadyStateThreshold: Double,
            kneeGainThreshold: Double,
            rttBufferbloatFactor: Double,
            hardCap: Int,
            tinyFileThreshold: UInt64,
            reproBeCadence: Int,
            rateAlpha: Double
        ) {
            self.steadyStateWindow = steadyStateWindow
            self.steadyStateThreshold = steadyStateThreshold
            self.kneeGainThreshold = kneeGainThreshold
            self.rttBufferbloatFactor = rttBufferbloatFactor
            self.hardCap = hardCap
            self.tinyFileThreshold = tinyFileThreshold
            self.reproBeCadence = reproBeCadence
            self.rateAlpha = rateAlpha
        }
    }

    public enum Phase: Sendable, Equatable {
        case probe
        case cruise(operatingN: Int)
        case pinned(n: Int)
    }

    private var config: Config
    private var workerRates: [Int: Double]
    private var workerHistory: [Int: [Double]]
    private var rttFloor: Double?
    private var rttSmoothed: Double?
    private var aggregateBeforeLastDouble: Double?
    private var phase: Phase
    private var cruiseTicks: Int
    private var throttleDetected: Bool

    public init(config: Config = .default, rng: some RandomNumberGenerator) {
        self.config = config
        self.workerRates = [:]
        self.workerHistory = [:]
        self.rttFloor = nil
        self.rttSmoothed = nil
        self.aggregateBeforeLastDouble = nil
        self.phase = .probe
        self.cruiseTicks = 0
        self.throttleDetected = false
        // RNG reserved for Phase 3 epsilon-draw probe jitter; ignored here.
        _ = rng
    }

    public mutating func record(sample: WorkerRateSample) {
        let prev = workerRates[sample.workerIndex] ?? sample.bytesPerSecond
        let smoothed = config.rateAlpha * sample.bytesPerSecond + (1 - config.rateAlpha) * prev
        workerRates[sample.workerIndex] = smoothed

        var history = workerHistory[sample.workerIndex] ?? []
        history.append(smoothed)
        if history.count > config.steadyStateWindow * 2 {
            history.removeFirst()
        }
        workerHistory[sample.workerIndex] = history

        if let ratio = sample.rttRatio {
            if let floor = rttFloor {
                rttFloor = min(floor, ratio)
            } else {
                rttFloor = ratio
            }
            let prevRTT = rttSmoothed ?? ratio
            rttSmoothed = config.rateAlpha * ratio + (1 - config.rateAlpha) * prevRTT
        }
    }

    public mutating func notifyThrottleDetected() {
        throttleDetected = true
    }

    /// The governor's converged outcome for the bandit feed. `effectiveN` is
    /// non-nil ONLY when the representative steady-state operating N is a bandit
    /// candidate {2, 4, 8, 16} AND cruise was reached.
    public var outcome: GovernorOutcome {
        switch phase {
        case .cruise(let opN):
            let eff: UInt8? = [2, 4, 8, 16].contains(opN) ? UInt8(opN) : nil
            return GovernorOutcome(effectiveN: eff, stabilized: true)
        case .probe, .pinned:
            return GovernorOutcome(effectiveN: nil, stabilized: false)
        }
    }

    public mutating func decide(liveWorkers: Int, remainingBytes: UInt64) -> GovernorDecision {
        if remainingBytes < config.tinyFileThreshold {
            return .commit(1)
        }
        if throttleDetected {
            return .backOffPinLow
        }
        switch phase {
        case .pinned(let n):
            return .commit(n)
        case .cruise(let opN):
            cruiseTicks += 1
            if cruiseTicks >= config.reproBeCadence {
                cruiseTicks = 0
                let candidate = min(opN + 1, config.hardCap)
                if candidate > opN {
                    return .addWorkers(1)
                }
            }
            return .hold
        case .probe:
            guard allWorkersInSteadyState(liveWorkers: liveWorkers) else {
                return .hold
            }
            let aggregate = aggregateRate()
            if let prevAggregate = aggregateBeforeLastDouble {
                let gain = aggregate > 0 ? (aggregate - prevAggregate) / prevAggregate : 0
                if gain < config.kneeGainThreshold {
                    phase = .cruise(operatingN: liveWorkers)
                    return .commit(liveWorkers)
                }
                if let smoothedRTT = rttSmoothed,
                   let floor = rttFloor,
                   floor > 0,
                   smoothedRTT / floor > config.rttBufferbloatFactor
                {
                    phase = .cruise(operatingN: liveWorkers)
                    return .commit(liveWorkers)
                }
            }
            let nextN = candidateAbove(liveWorkers)
            guard let target = nextN, target <= config.hardCap else {
                phase = .cruise(operatingN: liveWorkers)
                return .commit(liveWorkers)
            }
            aggregateBeforeLastDouble = aggregate
            return .addWorkers(target - liveWorkers)
        }
    }

    private func allWorkersInSteadyState(liveWorkers: Int) -> Bool {
        guard liveWorkers > 0 else { return false }
        for index in 0..<liveWorkers {
            let history = workerHistory[index] ?? []
            guard history.count >= config.steadyStateWindow else { return false }
            let recent = Array(history.suffix(config.steadyStateWindow))
            let mean = recent.reduce(0, +) / Double(recent.count)
            guard mean > 0 else { return false }
            let maxDev = recent.map { abs($0 - mean) / mean }.max() ?? 0
            if maxDev > config.steadyStateThreshold { return false }
        }
        return true
    }

    private func aggregateRate() -> Double {
        workerRates.values.reduce(0, +)
    }

    private func candidateAbove(_ n: Int) -> Int? {
        let candidates = [2, 4, 8, 16]
        return candidates.first { $0 > n }
    }
}
