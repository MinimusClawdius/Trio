import Foundation

/// Translates Trio WatchState JSON into endpoint-specific JSON responses
/// for the Pebble local HTTP API.
final class PebbleDataBridge {
    private let lock = NSLock()

    private var glucose: String?
    private var trend: String?
    private var trendRaw: String?
    private var delta: String?
    private var glucoseDate: Date?
    private var glucoseDateInterval: UInt64?
    private var lastLoopDate: Date?
    private var lastLoopDateInterval: UInt64?
    private var iob: Decimal?
    private var cob: Decimal?
    private var bolusRecommended: Decimal?
    private var maxBolus: Decimal?
    private var maxCOB: Decimal?
    private var eventualBG: String?
    private var eventualBGRaw: String?
    private var isf: Decimal?
    private var overrideStr: String?
    private var glucoseHistory: [Int]?

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func updateFromWatchStateJSON(_ data: Data) {
        guard let state = try? JSONDecoder().decode(WatchState.self, from: data) else { return }
        lock.lock()
        defer { lock.unlock() }

        glucose = state.glucose
        trend = state.trend
        trendRaw = state.trendRaw
        delta = state.delta
        glucoseDate = state.glucoseDate
        glucoseDateInterval = state.glucoseDateInterval
        lastLoopDate = state.lastLoopDate
        lastLoopDateInterval = state.lastLoopDateInterval
        iob = state.iob
        cob = state.cob
        bolusRecommended = state.bolusRecommended
        maxBolus = state.maxBolus
        maxCOB = state.maxCOB
        eventualBG = state.eventualBG
        eventualBGRaw = state.eventualBGRaw
        isf = state.isf
        overrideStr = state.override
        glucoseHistory = state.glucoseHistory
    }

    // MARK: - JSON Endpoints

    func cgmJSON() -> String {
        lock.lock()
        defer { lock.unlock() }

        let glucoseStr = jsonStr(glucose)
        let trendStr = jsonQuoted(trend)
        let deltaStr = jsonStr(delta)
        let dateStr = glucoseDate.map { "\"\(isoFormatter.string(from: $0))\"" } ?? "null"
        let stale = isGlucoseStale()

        return """
        {"glucose":\(glucoseStr),"trend":\(trendStr),"delta":\(deltaStr),"date":\(dateStr),"isStale":\(stale)}
        """
    }

    func loopJSON() -> String {
        lock.lock()
        defer { lock.unlock() }

        let iobStr = jsonDecimal(iob)
        let cobStr = jsonDecimal(cob)
        let lastRunStr = lastLoopDate.map { "\"\(isoFormatter.string(from: $0))\"" } ?? "null"
        let lastLoopMins = lastLoopDate.map { Int(Date().timeIntervalSince($0) / 60) }
        let lastLoopMinsStr = lastLoopMins.map { "\($0)" } ?? "null"
        let bolusStr = jsonDecimal(bolusRecommended)
        let eventualStr = jsonQuoted(eventualBGRaw)
        let historyStr = formatGlucoseHistory()

        return """
        {"iob":\(iobStr),"cob":\(cobStr),"lastRun":\(lastRunStr),"lastLoopMins":\(lastLoopMinsStr),"recommendedBolus":\(bolusStr),"eventualBG":\(eventualStr),"glucoseHistory":\(historyStr)}
        """
    }

    func pumpJSON() -> String {
        return """
        {"reservoir":null,"battery":null}
        """
    }

    func allDataJSON() -> String {
        let timestamp = isoFormatter.string(from: Date())
        let cgm = cgmJSON()
        let loop = loopJSON()
        let pump = pumpJSON()

        return """
        {"timestamp":"\(timestamp)","cgm":\(cgm),"loop":\(loop),"pump":\(pump)}
        """
    }

    // MARK: - Helpers

    private func isGlucoseStale() -> Bool {
        guard let date = glucoseDate else { return true }
        return Date().timeIntervalSince(date) > 15 * 60
    }

    private func formatGlucoseHistory() -> String {
        guard let values = glucoseHistory, !values.isEmpty else { return "[]" }
        return "[\(values.map { "\($0)" }.joined(separator: ","))]"
    }

    private func jsonStr(_ value: String?) -> String {
        value.map { "\"\($0)\"" } ?? "null"
    }

    private func jsonQuoted(_ value: String?) -> String {
        value.map { "\"\($0)\"" } ?? "null"
    }

    private func jsonDecimal(_ value: Decimal?) -> String {
        value.map { "\($0)" } ?? "null"
    }
}
