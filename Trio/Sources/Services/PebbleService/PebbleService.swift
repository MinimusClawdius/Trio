import Combine
import Foundation
import LoopKit

/// LoopKit `Service` for Pebble / Rebble watch integration (PebbleKit iOS + local HTTP bridge).
/// State is persisted by `BasePebbleServiceManager`; `BasePebbleManager` applies `isEnabled` and HTTP port.
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
    private(set) var isOnboarded: Bool

    init(hostIdentifier _: String, hostVersion _: String) {
        id = UUID().uuidString
        isEnabled = true
        httpPort = 8080
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
        isOnboarded = rawState["isOnboarded"] as? Bool ?? false
    }

    var rawState: RawStateValue {
        [
            "id": id,
            "isEnabled": isEnabled,
            "httpPort": Int(httpPort),
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
