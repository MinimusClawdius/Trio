import Combine
import Foundation
import UIKit

#if canImport(PebbleKit)
import PebbleKit
#endif

// MARK: - PebbleBLEBridgeDelegate

protocol PebbleBLEBridgeDelegate: AnyObject {
    func pebbleBLE(didReceiveCommand type: Int, amount: Int)
    func pebbleBLE(didConnect watchName: String)
    func pebbleBLE(didDisconnect watchName: String)
}

// MARK: - PebbleBLEBridge

/// Optional native push: **Trio → PebbleKit iOS → Rebble → BLE → watch** AppMessages.
///
/// **Off by default** in Trio (`PebbleService.useNativeBLEPush`). The supported primary pipe is
/// PebbleKit **JavaScript** polling `127.0.0.1` and calling `Pebble.sendAppMessage` — same watch handler, fewer iOS lifecycle surprises.
///
/// When `PebbleKit.framework` is absent, `start()` / `sendState()` are no-ops.
///
/// ## Background mode
/// With `bluetooth-central` + `bluetooth-peripheral` UIBackgroundModes, iOS allows
/// the BLE connection to survive backgrounding. PebbleKit can even relaunch Trio
/// if the watch sends a message while Trio is suspended (BLE-only devices, fw ≥ 3.8).
final class PebbleBLEBridge {

    /// trio-pebble watchface UUID from `appinfo.json`
    static let watchfaceUUIDString = "a1b2c3d4-e5f6-7890-abcd-ef1234567890"

    weak var delegate: PebbleBLEBridgeDelegate?

    private(set) var isConnected = false
    private(set) var isRunning = false

    /// Last `WatchState` hash to deduplicate pushes.
    private var lastPushedHash: Int?

    private let lock = NSLock()

    // ──────────────────────────────────────────────
    // MARK: - PebbleKit iOS wrappers (compiled only when SDK is available)
    // ──────────────────────────────────────────────

    #if canImport(PebbleKit)

    private var central: PBPebbleCentral?
    private var connectedWatch: PBWatch?
    /// Opaque handle returned by `appMessagesAddReceiveUpdateHandler:` (PebbleKit `id`).
    private var receiveHandlerHandle: Any?

    func start() {
        guard !isRunning else { return }
        guard let uuid = NSUUID(uuidString: Self.watchfaceUUIDString) else {
            debug(.service, "PebbleBLE: invalid watchface UUID")
            return
        }

        UIDevice.current.isBatteryMonitoringEnabled = true

        let c = PBPebbleCentral.default()
        c.appUUID = uuid as UUID
        c.delegate = self
        c.run()
        central = c

        if let watch = c.lastConnectedWatch() {
            watchDidConnect(watch)
        }

        isRunning = true
        debug(.service, "PebbleBLE: started — looking for Pebble watch")
    }

    func stop() {
        guard isRunning else { return }

        if let watch = connectedWatch, let handle = receiveHandlerHandle {
            watch.appMessagesRemoveUpdateHandler(handle)
        }
        receiveHandlerHandle = nil
        connectedWatch = nil
        lastPushedHash = nil
        central = nil
        isConnected = false
        isRunning = false
        debug(.service, "PebbleBLE: stopped")
    }

    // MARK: Send

    func sendState(_ state: WatchState) {
        guard isRunning, isConnected, let watch = connectedWatch else { return }

        let stateHash = state.hashValue
        lock.lock()
        if stateHash == lastPushedHash { lock.unlock(); return }
        lastPushedHash = stateHash
        lock.unlock()

        let dict = buildAppMessage(from: state)

        watch.appMessagesPushUpdate(dict) { _, _, error in
            if let error = error {
                debug(.service, "PebbleBLE: send failed — \(error.localizedDescription)")
            } else {
                debug(.service, "PebbleBLE: pushed update to watch")
            }
        }
    }

    // MARK: Connection

    private func watchDidConnect(_ watch: PBWatch) {
        connectedWatch = watch
        isConnected = true

        receiveHandlerHandle = watch.appMessagesAddReceiveUpdateHandler { [weak self] _, update -> Bool in
            self?.handleIncoming(update)
            return true // auto-ACK
        }

        let name = watch.name ?? "Pebble"
        debug(.service, "PebbleBLE: connected to \(name)")
        delegate?.pebbleBLE(didConnect: name)
    }

    private func watchDidDisconnect(_ watch: PBWatch) {
        let name = watch.name ?? "Pebble"
        if connectedWatch?.isEqual(watch) == true {
            if let handle = receiveHandlerHandle {
                watch.appMessagesRemoveUpdateHandler(handle)
                receiveHandlerHandle = nil
            }
            connectedWatch = nil
            isConnected = false
            lastPushedHash = nil
        }
        debug(.service, "PebbleBLE: disconnected from \(name)")
        delegate?.pebbleBLE(didDisconnect: name)
    }

    // MARK: Receive

    private func handleIncoming(_ update: [AnyHashable: Any]?) {
        guard let update = update else { return }

        let cmdTypeKey = PebbleAppMessageKey.cmdType.nsKey
        let cmdAmountKey = PebbleAppMessageKey.cmdAmount.nsKey

        if let typeNum = update[cmdTypeKey] as? NSNumber,
           let amountNum = update[cmdAmountKey] as? NSNumber
        {
            delegate?.pebbleBLE(didReceiveCommand: typeNum.intValue, amount: amountNum.intValue)
        }
    }

    #else
    // ──────────────────────────────────────────────
    // MARK: - Stubs (PebbleKit not linked)
    // ──────────────────────────────────────────────

    func start() {
        debug(.service, "PebbleBLE: SDK not linked — BLE bridge inactive, using HTTP fallback")
        isRunning = false
    }

    func stop() {
        isRunning = false
    }

    func sendState(_: WatchState) {
        // no-op without SDK
    }

    #endif

    // ──────────────────────────────────────────────
    // MARK: - AppMessage builder (always compiled)
    // ──────────────────────────────────────────────

    /// Converts a `WatchState` into the same `NSDictionary<NSNumber, id>` format
    /// that `index.js : sendToWatch()` produces, so the watch C code's
    /// `inbox_received` handler works identically for both paths.
    func buildAppMessage(from state: WatchState) -> NSDictionary {
        let msg = NSMutableDictionary()
        let K = PebbleAppMessageKey.self

        // Glucose value — watch expects int16 in its native unit
        if let glucoseStr = state.currentGlucose, glucoseStr != "--" {
            if state.units == .mmolL {
                if let mmol = Double(glucoseStr) {
                    let mgdl = Int(mmol * 18.0)
                    msg[K.glucose.nsKey] = NSNumber(value: Int32(mgdl))
                }
            } else {
                if let mgdl = Int(glucoseStr) {
                    msg[K.glucose.nsKey] = NSNumber(value: Int32(mgdl))
                }
            }
        }

        if let trend = state.trend {
            msg[K.trend.nsKey] = String(trend.prefix(7))
        }
        if let delta = state.delta {
            msg[K.delta.nsKey] = String(delta.prefix(15))
        }
        if let iob = state.iob {
            msg[K.iob.nsKey] = String(iob.prefix(15))
        }
        if let cob = state.cob {
            msg[K.cob.nsKey] = String(cob.prefix(15))
        }
        if let lastLoop = state.lastLoopTime {
            msg[K.lastLoop.nsKey] = String(lastLoop.prefix(15))
        }

        // Do not send KEY_UNITS here — watch display (mmol vs mg/dL) comes from PebbleKit JS settings
        // so it is not overwritten every BLE push with Trio's app units.

        // Stale flag — true if date > 15 min old
        let isStale = Date().timeIntervalSince(state.date) > 15 * 60
        msg[K.glucoseStale.nsKey] = NSNumber(value: isStale ? Int32(1) : Int32(0))

        // Graph: pack glucose history as uint16-LE byte array, matching JS format
        if !state.glucoseValues.isEmpty {
            let count = min(state.glucoseValues.count, 48)
            var bytes = Data(capacity: count * 2)
            for i in 0 ..< count {
                let raw = state.glucoseValues[i].glucose
                let mgdl: Int
                if state.units == .mmolL {
                    mgdl = Int((raw * 18.0).rounded())
                } else {
                    mgdl = Int(raw.rounded())
                }
                let val = UInt16(clamping: max(0, mgdl))
                bytes.append(UInt8(val & 0xFF))
                bytes.append(UInt8((val >> 8) & 0xFF))
            }
            msg[K.graphData.nsKey] = bytes as NSData
            msg[K.graphCount.nsKey] = NSNumber(value: Int32(count))
        }

        // Phone battery
        let batteryLevel = Int(UIDevice.current.batteryLevel * 100)
        if batteryLevel >= 0 {
            msg[K.batteryPhone.nsKey] = NSNumber(value: Int32(batteryLevel))
        }

        return msg
    }
}

// MARK: - PBPebbleCentralDelegate

#if canImport(PebbleKit)
extension PebbleBLEBridge: PBPebbleCentralDelegate {
    func pebbleCentral(_ central: PBPebbleCentral, watchDidConnect watch: PBWatch, isNew _: Bool) {
        watchDidConnect(watch)
    }

    func pebbleCentral(_ central: PBPebbleCentral, watchDidDisconnect watch: PBWatch) {
        watchDidDisconnect(watch)
    }
}
#endif
