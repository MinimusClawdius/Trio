import ConnectIQ
import SwiftUI

enum AwConfig: String, JSON, CaseIterable, Identifiable, Codable {
    var id: String { rawValue }
    case HR
    case BGTarget
    case steps
    case isf
    case override

    var displayName: String {
        switch self {
        case .BGTarget:
            return NSLocalizedString("Glucose Target", comment: "")
        case .HR:
            return NSLocalizedString("Heart Rate", comment: "")
        case .steps:
            return NSLocalizedString("Steps", comment: "")
        case .isf:
            return NSLocalizedString("ISF", comment: "")
        case .override:
            return NSLocalizedString("% Override", comment: "")
        }
    }
}

extension WatchConfig {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() private var garmin: GarminManager!
        @Injected() private var pebble: PebbleManager!
        @Published var devices: [IQDevice] = []
        @Published var selectedAwConfig: AwConfig = .HR
        @Published var displayFatAndProteinOnWatch = false
        @Published var confirmBolusFaster = false
        @Published var pebbleEnabled = false
        @Published var pebbleRunning = false
        @Published var pebblePort: UInt16 = 8080

        private(set) var preferences = Preferences()

        var pebbleCommandManager: PebbleCommandManager {
            (pebble as? BasePebbleManager)?.getCommandManager() ?? PebbleCommandManager()
        }

        override func subscribe() {
            preferences = provider.preferences

            subscribeSetting(\.displayFatAndProteinOnWatch, on: $displayFatAndProteinOnWatch) { displayFatAndProteinOnWatch = $0 }
            subscribeSetting(\.confirmBolusFaster, on: $confirmBolusFaster) { confirmBolusFaster = $0 }
            subscribeSetting(\.displayOnWatch, on: $selectedAwConfig) { selectedAwConfig = $0 }
            didSet: { [weak self] value in
                // for compatibility with old displayHR
                switch value {
                case .HR:
                    self?.settingsManager.settings.displayHR = true
                default:
                    self?.settingsManager.settings.displayHR = false
                }
            }

            devices = garmin.devices

            pebbleEnabled = pebble.isEnabled
            pebbleRunning = pebble.isRunning
            if let basePebble = pebble as? BasePebbleManager {
                pebblePort = basePebble.getCurrentPort()
            }

            $pebbleEnabled
                .dropFirst()
                .sink { [weak self] enabled in
                    self?.pebble.isEnabled = enabled
                    self?.pebbleRunning = self?.pebble.isRunning ?? false
                }
                .store(in: &lifetime)
        }

        func selectGarminDevices() {
            garmin.selectDevices()
                .receive(on: DispatchQueue.main)
                .weakAssign(to: \.devices, on: self)
                .store(in: &lifetime)
        }

        func deleteGarminDevice() {
            garmin.updateListDevices(devices: devices)
        }
    }
}
