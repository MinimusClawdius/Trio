import Combine
import Foundation
import Swinject

protocol PebbleManager {
    func sendState(_ state: WatchState)
    var isEnabled: Bool { get set }
    var isRunning: Bool { get }
    var isBLEConnected: Bool { get }
    func start()
    func stop()
}

/// Manages both communication channels to the Pebble watch:
///
/// 1. **HTTP pull** — `PebbleLocalAPIServer` on `127.0.0.1` (PebbleKit JS polls this)
/// 2. **BLE push** — `PebbleBLEBridge` via PebbleKit iOS (direct push through Rebble)
///
/// When the PebbleKit iOS SDK is linked and a watch is connected via BLE, data is
/// **pushed** immediately on each `sendState` call — no polling delay. The HTTP
/// server stays active as a fallback for when BLE is unavailable (e.g., JS-only
/// data sources like Nightscout/Dexcom Share, or SDK not linked).
final class BasePebbleManager: PebbleManager, Injectable {
    private let dataBridge = PebbleDataBridge()
    private let commandManager = PebbleCommandManager()
    private let bleBridge = PebbleBLEBridge()
    private var apiServer: PebbleLocalAPIServer?

    @Injected() private var pebbleServiceManager: PebbleServiceManager!

    @Persisted(key: "BasePebbleManager.isEnabled") var isEnabled: Bool = false {
        didSet {
            if isEnabled { start() } else { stop() }
        }
    }

    @Persisted(key: "BasePebbleManager.port") private var port: UInt16 = 8080

    private(set) var isRunning = false

    var isBLEConnected: Bool { bleBridge.isConnected }

    init(resolver: Resolver) {
        injectServices(resolver)
        bleBridge.delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(Self.pebbleIntegrationConfigurationDidChange),
            name: .pebbleIntegrationConfigurationDidChange,
            object: nil
        )
        applyServiceConfigurationIfNeeded()
        if isEnabled { start() }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func pebbleIntegrationConfigurationDidChange() {
        applyServiceConfigurationIfNeeded()
    }

    private func applyServiceConfigurationIfNeeded() {
        (pebbleServiceManager as? BasePebbleServiceManager)?.applyConfiguration(to: self)
    }

    /// Port from legacy Watch Config when not overridden by `PebbleService`.
    func resolvedLegacyPort() -> UInt16 {
        port
    }

    func start() {
        guard !isRunning else { return }

        // HTTP server (PebbleKit JS fallback)
        let server = PebbleLocalAPIServer(dataBridge: dataBridge, commandManager: commandManager, port: port)
        apiServer = server
        server.start()

        // BLE push (PebbleKit iOS — primary when SDK linked)
        bleBridge.start()

        isRunning = true
        let bleStatus = bleBridge.isRunning ? "BLE active" : "BLE inactive (SDK not linked)"
        debug(.service, "Pebble: integration started — HTTP on port \(port), \(bleStatus)")
    }

    func stop() {
        apiServer?.stop()
        apiServer = nil
        bleBridge.stop()
        isRunning = false
        debug(.service, "Pebble: integration stopped")
    }

    func sendState(_ state: WatchState) {
        guard isEnabled else { return }

        // Keep HTTP bridge informed of BLE status so JS can read it from /api/all
        dataBridge.isBLEPushActive = bleBridge.isConnected

        // Always update the HTTP data bridge (JS may be polling)
        dataBridge.updateFromWatchState(state)

        // Push over BLE if connected (arrives instantly on the watch)
        bleBridge.sendState(state)
    }

    func getCommandManager() -> PebbleCommandManager {
        commandManager
    }

    func getCurrentPort() -> UInt16 {
        port
    }

    func setPort(_ newPort: UInt16) {
        guard newPort >= 1024, newPort <= 65535 else { return }
        port = newPort
        if isRunning { stop(); start() }
    }
}

// MARK: - PebbleBLEBridgeDelegate

extension BasePebbleManager: PebbleBLEBridgeDelegate {
    func pebbleBLE(didReceiveCommand type: Int, amount: Int) {
        guard pebbleServiceManager.isPebbleDataDeliveryEnabled else { return }
        switch type {
        case 1: // bolus
            let units = Double(amount) / 10.0
            if let cmd = commandManager.queueBolus(units: units) {
                debug(.service, "PebbleBLE: queued bolus command \(cmd.id) — \(String(format: "%.2f", units))U")
            }
        case 2: // carbs
            if let cmd = commandManager.queueCarbEntry(grams: Double(amount), absorptionHours: 3.0) {
                debug(.service, "PebbleBLE: queued carb command \(cmd.id) — \(amount)g")
            }
        default:
            debug(.service, "PebbleBLE: unknown command type \(type)")
        }
    }

    func pebbleBLE(didConnect watchName: String) {
        debug(.service, "Pebble: BLE connected to \(watchName) — data will be pushed directly")
    }

    func pebbleBLE(didDisconnect watchName: String) {
        debug(.service, "Pebble: BLE disconnected from \(watchName) — falling back to HTTP")
    }
}

extension BasePebbleManager {
    /// Matches `Persisted` key for the legacy Watch Config toggle when no `PebbleService` exists.
    static let legacyEnabledUserDefaultsKey = "BasePebbleManager.isEnabled"
}
