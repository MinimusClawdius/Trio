import Combine
import Foundation
import Swinject

protocol PebbleManager {
    func sendState(_ state: WatchState)
    var isEnabled: Bool { get set }
    var isRunning: Bool { get }
    var isBLEConnected: Bool { get }
    /// Trio's optional native PebbleKit iOS AppMessage push. **Off by default** — PebbleKit JS polling `127.0.0.1` is the supported primary pipe.
    var useNativeBLEPush: Bool { get set }
    func start()
    func stop()
}

/// Pebble / Rebble integration:
///
/// 1. **Primary (supported):** `PebbleLocalAPIServer` on `127.0.0.1` — PebbleKit **JavaScript** in Rebble polls `/api/all`, normalizes data, and `Pebble.sendAppMessage`s the watch. This matches community workflow and stays maintainable.
/// 2. **Optional:** native PebbleKit **iOS** BLE push (`PebbleBLEBridge`) when `useNativeBLEPush` is enabled in **Settings → Services → Pebble** — experimental; can be flaky under iOS background rules.
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

    /// Persisted only via `PebbleService` when onboarded; otherwise stays `false`.
    var useNativeBLEPush: Bool = false

    /// Block-based observer (`BasePebbleManager` is not `NSObject`; `#selector` observers do not compile).
    private var pebbleIntegrationConfigObserver: NSObjectProtocol?

    init(resolver: Resolver) {
        injectServices(resolver)
        bleBridge.delegate = self
        pebbleIntegrationConfigObserver = Foundation.NotificationCenter.default.addObserver(
            forName: .pebbleIntegrationConfigurationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] (_: Notification) in
            self?.applyServiceConfigurationIfNeeded()
        }
        applyServiceConfigurationIfNeeded()
        if isEnabled { start() }
    }

    deinit {
        if let observer = pebbleIntegrationConfigObserver {
            Foundation.NotificationCenter.default.removeObserver(observer)
        }
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

        // HTTP server — PebbleKit JS primary transport
        let server = PebbleLocalAPIServer(dataBridge: dataBridge, commandManager: commandManager, port: port)
        apiServer = server
        server.start()

        if useNativeBLEPush {
            bleBridge.start()
        } else {
            bleBridge.stop()
            dataBridge.isBLEPushActive = false
        }

        isRunning = true
        let bleStatus = useNativeBLEPush
            ? (bleBridge.isRunning ? "native BLE bridge on" : "native BLE bridge inactive (SDK?)")
            : "native BLE off (JS + HTTP only)"
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

        dataBridge.nativeIosBlePushEnabled = useNativeBLEPush
        dataBridge.isBLEPushActive = useNativeBLEPush && bleBridge.isConnected

        // Always refresh HTTP snapshot — PebbleKit JS is the default consumer.
        dataBridge.updateFromWatchState(state)

        if useNativeBLEPush {
            bleBridge.sendState(state)
        }
    }

    /// Syncs optional native BLE transport without restarting the HTTP server.
    func setUseNativeBLEPush(_ enabled: Bool) {
        guard useNativeBLEPush != enabled else { return }
        useNativeBLEPush = enabled
        guard isRunning else { return }
        if enabled {
            dataBridge.nativeIosBlePushEnabled = true
            bleBridge.start()
        } else {
            bleBridge.stop()
            dataBridge.isBLEPushActive = false
            dataBridge.nativeIosBlePushEnabled = false
        }
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
