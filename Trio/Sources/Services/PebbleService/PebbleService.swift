import Combine
import Foundation
import LoopKit

/// LoopKit `Service` for Pebble / Rebble watch integration.
///
/// **Default path:** PebbleKit **JavaScript** in Rebble polls Trio's loopback HTTP API; commands use HTTP POST.
/// **Optional:** native PebbleKit **iOS** BLE AppMessage push (`useNativeBLEPush`) — off by default.
final class PebbleService: Service, ObservableObject {
    static let pluginIdentifier = "PebbleService"

    static var localizedTitle: String {
        String(localized: "Pebble / Rebble", comment: "Title of the Pebble watch integration service")
    }

    weak var serviceDelegate: ServiceDelegate?
    weak var stateDelegate: StatefulPluggableDelegate?

    private let id: String

    @Published var isEnabled: Bool
    @Published var httpPort: UInt16
    /// Native PebbleKit iOS BLE data push — experimental; **off** by default (JS + HTTP is primary).
    @Published var useNativeBLEPush: Bool
    private(set) var isOnboarded: Bool

    init(hostIdentifier _: String, hostVersion _: String) {
        id = UUID().uuidString
        isEnabled = true
        httpPort = 8080
        useNativeBLEPush = false
        isOnboarded = false
    }

    init?(rawState: RawStateValue) {
        guard let id = rawState["id"] as? String else {
            return nil
        }
        self.id = id
        isEnabled = rawState["isEnabled"] as? Bool ?? true
        if let p = rawState["httpPort"] as? Int {
            httpPort = UInt16(clamping: p)
        } else {
            httpPort = 8080
        }
        useNativeBLEPush = rawState["useNativeBLEPush"] as? Bool ?? false
        isOnboarded = rawState["isOnboarded"] as? Bool ?? false
    }

    var rawState: RawStateValue {
        [
            "id": id,
            "isEnabled": isEnabled,
            "httpPort": Int(httpPort),
            "useNativeBLEPush": useNativeBLEPush,
            "isOnboarded": isOnboarded
        ]
    }

    /// Call immediately before `notifyServiceCreatedAndOnboarded` so `ServiceOnboardingDelegate` precondition passes.
    func completeCreateForOnboarding() {
        isOnboarded = true
    }

    func persistUpdate() {
        stateDelegate?.pluginDidUpdateState(self)
    }

    func deleteService() {
        stateDelegate?.pluginWantsDeletion(self)
    }
}
