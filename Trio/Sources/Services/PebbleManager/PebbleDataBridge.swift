import Foundation

/// Translates Trio's dev-branch WatchState into JSON endpoint responses
/// for the Pebble local HTTP API.
///
/// **Primary transport (supported):** PebbleKit **JavaScript** in the Rebble app polls this API
/// (`GET /api/all`) and forwards data to the watch via `Pebble.sendAppMessage`. That path matches
/// where community development happens and stays future-proof relative to optional native iOS BLE.
///
/// **Persistence vs Garmin:** Garmin uses Connect IQ to push JSON to the watch when Trio runs.
/// This API is an HTTP server on `127.0.0.1`; when iOS **suspends** Trio (Safari or Rebble in front),
/// the process stops serving — there is no always-on socket like a desktop server. A short
/// background task runs only when a request is accepted. Last-good JSON is cached on-device so
/// a brief foreground session can still return readings if Core Data is momentarily empty.
final class PebbleDataBridge {
    private let lock = NSLock()

    private static let cachedCGMJSONKey = "PebbleDataBridge.cached.cgmJSON"
    private static let cachedCGMJSONAtKey = "PebbleDataBridge.cached.cgmJSON.at"
    private static let cacheMaxAge: TimeInterval = 24 * 3600

    /// Monotonic counter bumped on each `WatchState` snapshot — PebbleKit JS can log or detect stalls.
    private(set) var stateRevision: UInt64 = 0

    /// User/service toggle: Trio's native PebbleKit iOS bridge may push AppMessages (optional).
    var nativeIosBlePushEnabled: Bool = false

    /// `true` when native iOS BLE push is enabled **and** PebbleKit reports a connected watch.
    var isBLEPushActive: Bool = false

    private var currentGlucose: String?
    private var currentGlucoseColor: String?
    private var trend: String?
    private var delta: String?
    private var iob: String?
    private var cob: String?
    private var lastLoopTime: String?
    private var glucoseValues: [(date: Date, glucose: Double, color: String)] = []
    private var maxBolus: Decimal = 10.0
    private var maxCarbs: Decimal = 250.0
    private var units: String = "mgdL"
    private var stateDate: Date?
    private var pumpReservoirUnits: Double?
    private var pumpBatteryPercent: Int?

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func updateFromWatchState(_ state: WatchState) {
        lock.lock()
        defer { lock.unlock() }

        currentGlucose = state.currentGlucose
        currentGlucoseColor = state.currentGlucoseColorString
        trend = state.trend
        delta = state.delta
        iob = state.iob
        cob = state.cob
        lastLoopTime = state.lastLoopTime
        maxBolus = state.maxBolus
        maxCarbs = state.maxCarbs
        units = state.units.rawValue
        stateDate = state.date
        pumpReservoirUnits = state.pumpReservoirUnits
        pumpBatteryPercent = state.pumpBatteryPercent

        glucoseValues = state.glucoseValues.map { gv in
            (date: gv.date, glucose: gv.glucose, color: gv.color)
        }

        stateRevision &+= 1
    }

    // MARK: - JSON Endpoints

    func cgmJSON() -> String {
        let fresh = buildCgmJSONLocked()
        if shouldFallbackToCachedCGM(fresh) {
            if let cached = UserDefaults.standard.string(forKey: Self.cachedCGMJSONKey),
               let ts = UserDefaults.standard.object(forKey: Self.cachedCGMJSONAtKey) as? TimeInterval,
               Date().timeIntervalSince1970 - ts < Self.cacheMaxAge
            {
                return cached
            }
        } else {
            UserDefaults.standard.set(fresh, forKey: Self.cachedCGMJSONKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.cachedCGMJSONAtKey)
        }
        return fresh
    }

    func loopJSON() -> String {
        buildLoopJSONLocked()
    }

    private func buildCgmJSONLocked() -> String {
        lock.lock()
        defer { lock.unlock() }

        let glucoseStr = jsonQuoted(currentGlucose)
        let trendStr = jsonQuoted(trend)
        let deltaStr = jsonQuoted(delta)
        let dateStr = stateDate.map { "\"\(isoFormatter.string(from: $0))\"" } ?? "null"
        let stale = isGlucoseStale()

        return "{\"glucose\":\(glucoseStr),\"trend\":\(trendStr),\"delta\":\(deltaStr),\"date\":\(dateStr),\"isStale\":\(stale),\"units\":\"\(units)\"}"
    }

    private func buildLoopJSONLocked() -> String {
        lock.lock()
        defer { lock.unlock() }

        let iobStr = jsonQuoted(iob)
        let cobStr = jsonQuoted(cob)
        let lastLoopStr = jsonQuoted(lastLoopTime)
        let historyStr = formatGlucoseHistory()

        return "{\"iob\":\(iobStr),\"cob\":\(cobStr),\"lastLoopTime\":\(lastLoopStr),\"glucoseHistory\":\(historyStr)}"
    }

    private func shouldFallbackToCachedCGM(_ json: String) -> Bool {
        json.contains("\"glucose\":null") || json.contains("\"glucose\":\"--\"") || json.contains("\"glucose\":\"\"")
    }

    func pumpJSON() -> String {
        buildPumpJSONLocked()
    }

    private func buildPumpJSONLocked() -> String {
        lock.lock()
        defer { lock.unlock() }

        let res: String
        if let u = pumpReservoirUnits, u.isFinite, u >= 0 {
            if u.rounded() == u {
                res = "\(Int(u.rounded()))"
            } else {
                res = String(format: "%.1f", u)
            }
        } else {
            res = "null"
        }

        let bat = pumpBatteryPercent.map { "\($0)" } ?? "null"
        return "{\"reservoir\":\(res),\"battery\":\(bat)}"
    }

    func allDataJSON() -> String {
        let timestamp = isoFormatter.string(from: Date())
        let ble = isBLEPushActive ? "true" : "false"
        let nativeOn = nativeIosBlePushEnabled ? "true" : "false"
        return "{\"pebbleProtocolVersion\":1,\"stateRevision\":\(stateRevision),\"transportProfile\":\"jsPrimary\",\"nativeIosBlePushEnabled\":\(nativeOn),\"blePushActive\":\(ble),\"timestamp\":\"\(timestamp)\",\"cgm\":\(cgmJSON()),\"loop\":\(loopJSON()),\"pump\":\(pumpJSON()),\"maxBolus\":\(maxBolus),\"maxCarbs\":\(maxCarbs)}"
    }

    /// Tiny JSON for `GET /api/pebble/v1/ping` — cheap reachability + revision check for PebbleKit JS.
    func pingJSON() -> String {
        lock.lock()
        let rev = stateRevision
        lock.unlock()
        let ts = isoFormatter.string(from: Date())
        return "{\"pebbleProtocolVersion\":1,\"stateRevision\":\(rev),\"serverTime\":\"\(ts)\"}"
    }

    // MARK: - Helpers

    private func isGlucoseStale() -> Bool {
        guard let date = stateDate else { return true }
        return Date().timeIntervalSince(date) > 15 * 60
    }

    private func formatGlucoseHistory() -> String {
        guard !glucoseValues.isEmpty else { return "[]" }
        let isMmol = units.contains("mmol")
        let items = glucoseValues.map { pt -> String in
            if isMmol {
                return String(format: "%.1f", pt.glucose)
            }
            return "\(Int(pt.glucose.rounded()))"
        }
        return "[\(items.joined(separator: ","))]"
    }

    private func jsonQuoted(_ value: String?) -> String {
        value.map { "\"\($0)\"" } ?? "null"
    }
}
