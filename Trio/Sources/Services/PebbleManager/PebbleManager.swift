import Combine
import CoreData
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
    @Injected() private var bolusCalculationManager: BolusCalculationManager!
    @Injected() private var apsManager: APSManager!
    @Injected() private var determinationStorage: DeterminationStorage!

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
        let server = PebbleLocalAPIServer(
            dataBridge: dataBridge,
            commandManager: commandManager,
            port: port,
            recommendBolusForCarbsGrams: { [weak self] grams in
                guard let self else { return 0 }
                return await self.pebbleRecommendedBolusUnits(forCarbsGrams: grams)
            }
        )
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

    /// Uses the same bolus calculator path as Apple Watch recommendations (`BolusCalculationManager`).
    private func pebbleRecommendedBolusUnits(forCarbsGrams grams: Double) async -> Decimal {
        var minPredBG: Decimal = 54
        let bgContext = CoreDataStack.shared.newTaskContext()
        do {
            let determinationIds = try await determinationStorage.fetchLastDeterminationObjectID(
                predicate: NSPredicate.predicateFor30MinAgoForDetermination
            )
            let determinationObjects: [OrefDetermination] = try await CoreDataStack.shared.getNSManagedObject(
                with: determinationIds,
                context: bgContext
            )
            if let first = determinationObjects.first {
                minPredBG = first.minPredBGFromReason ?? 54
            }
        } catch {
            debug(.service, "Pebble: bolus recommendation minPredBG fetch failed: \(error)")
        }

        let result = await bolusCalculationManager.handleBolusCalculation(
            carbs: Decimal(grams),
            useFattyMealCorrection: false,
            useSuperBolus: false,
            lastLoopDate: apsManager.lastLoopDate,
            minPredBG: minPredBG,
            simulatedCOB: nil,
            isBackdated: false
        )
        let rounded = apsManager.roundBolus(amount: result.insulinCalculated)
        return Swift.max(Decimal(0), rounded)
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
                PebbleIntegrationFileLogger.log("ble_inbound", "bolus id=\(cmd.id) units=\(String(format: "%.2f", units))U (raw_tenths=\(amount))")
            }
        case 2: // carbs
            if let cmd = commandManager.queueCarbEntry(grams: Double(amount), absorptionHours: 3.0) {
                debug(.service, "PebbleBLE: queued carb command \(cmd.id) — \(amount)g")
                PebbleIntegrationFileLogger.log("ble_inbound", "carb id=\(cmd.id) grams=\(Double(amount))g")
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
