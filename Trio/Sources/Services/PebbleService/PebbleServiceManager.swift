import Foundation
import LoopKit
import LoopKitUI
import Swinject
import UIKit

extension Foundation.Notification.Name {
    /// Posted when `PebbleService` persistence or enabled/port flags change; `BasePebbleManager` syncs from `PebbleServiceManager`.
    static let pebbleIntegrationConfigurationDidChange = Foundation.Notification.Name("PebbleIntegrationConfigurationDidChange")

    /// Posted on the main thread when a bolus or carb request is queued for in-app confirmation (`userInfo`: `commandId` String).
    static let pebbleDidEnqueuePendingCommand = Foundation.Notification.Name("PebbleDidEnqueuePendingCommand")
}

protocol PebbleServiceManager: AnyObject {
    func addPebbleService(service: Service)
    func getPebbleServiceUI() -> ServiceUI?
    func getPebblePluginHost() -> PluginHost?
    /// When `false`, Pebble must not push loop/CGM data or accept remote bolus/carb requests.
    var isPebbleDataDeliveryEnabled: Bool { get }
}

/// Persists `PebbleService`, exposes LoopKit `ServiceDelegate` / `StatefulPluggableDelegate`, and applies settings to `BasePebbleManager`.
final class BasePebbleServiceManager: PebbleServiceManager, Injectable {
    @PersistedProperty(key: "PebbleServiceState") var rawPebbleService: Service.RawValue?

    private(set) var pebbleService: PebbleService?

    init(resolver: Resolver) {
        injectServices(resolver)
        loadFromDisk()
        applyIntegrationConfiguration()
    }

    func addPebbleService(service: Service) {
        guard let ps = service as? PebbleService else { return }
        ps.serviceDelegate = self
        ps.stateDelegate = self
        pebbleService = ps
        rawPebbleService = ps.rawValue
        applyIntegrationConfiguration()
    }

    func getPebbleServiceUI() -> ServiceUI? {
        pebbleService as? ServiceUI
    }

    func getPebblePluginHost() -> PluginHost? {
        self
    }

    var isPebbleDataDeliveryEnabled: Bool {
        if let s = pebbleService, s.isOnboarded {
            return s.isEnabled
        }
        return UserDefaults.standard.object(forKey: BasePebbleManager.legacyEnabledUserDefaultsKey) as? Bool ?? false
    }

    private func loadFromDisk() {
        guard let raw = rawPebbleService,
              let identifier = raw["serviceIdentifier"] as? String,
              identifier == PebbleService.pluginIdentifier,
              let inner = raw["state"] as? Service.RawStateValue,
              let loaded = PebbleService(rawState: inner)
        else {
            return
        }
        loaded.serviceDelegate = self
        loaded.stateDelegate = self
        pebbleService = loaded
    }

    fileprivate func applyIntegrationConfiguration() {
        Foundation.NotificationCenter.default.post(name: .pebbleIntegrationConfigurationDidChange, object: self)
    }

    func applyConfiguration(to manager: BasePebbleManager) {
        let enabled = isPebbleDataDeliveryEnabled
        let port: UInt16 = {
            if let s = pebbleService, s.isOnboarded {
                return s.httpPort
            }
            return manager.resolvedLegacyPort()
        }()
        let nativeBle = (pebbleService?.isOnboarded == true) && (pebbleService?.useNativeBLEPush == true)
        manager.setUseNativeBLEPush(nativeBle)
        if manager.getCurrentPort() != port {
            manager.setPort(port)
        }
        if manager.isEnabled != enabled {
            manager.isEnabled = enabled
        }
    }
}

extension BasePebbleServiceManager: ServiceDelegate {
    var hostIdentifier: String {
        Bundle.main.bundleIdentifier ?? "org.nightscout.Trio"
    }

    var hostVersion: String {
        var semanticVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        while semanticVersion.split(separator: ".").count < 3 {
            semanticVersion += ".0"
        }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return semanticVersion + "+\(build)"
    }

    func issueAlert(_: LoopKit.Alert) {}

    func retractAlert(identifier _: LoopKit.Alert.Identifier) {}

    func enactRemoteOverride(name _: String, durationTime _: TimeInterval?, remoteAddress _: String) async throws {}

    func cancelRemoteOverride() async throws {}

    func deliverRemoteCarbs(
        amountInGrams _: Double,
        absorptionTime _: TimeInterval?,
        foodType _: String?,
        startDate _: Date?
    ) async throws {}

    func deliverRemoteBolus(amountInUnits _: Double) async throws {}
}

extension BasePebbleServiceManager: StatefulPluggableDelegate {
    func pluginDidUpdateState(_ plugin: StatefulPluggable) {
        guard let ps = plugin as? PebbleService else { return }
        rawPebbleService = ps.rawValue
        applyIntegrationConfiguration()
    }

    func pluginWantsDeletion(_ plugin: StatefulPluggable) {
        guard plugin is PebbleService else { return }
        pebbleService = nil
        rawPebbleService = nil
        applyIntegrationConfiguration()
    }
}

extension BasePebbleServiceManager: PluginHost {}
