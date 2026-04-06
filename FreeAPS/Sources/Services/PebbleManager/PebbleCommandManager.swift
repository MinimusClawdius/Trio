import Foundation

enum PebbleCommandType: String, Codable {
    case bolus
    case carbEntry
}

enum PebbleCommandStatus: String, Codable {
    case pendingConfirmation
    case confirmed
    case rejected
    case executed
    case failed
    case expired
}

struct PebbleCommand: Codable, Identifiable {
    let id: String
    let type: PebbleCommandType
    let timestamp: Date
    let parameters: [String: String]
    var status: PebbleCommandStatus
    var confirmedAt: Date?
    var executedAt: Date?
    var errorMessage: String?

    init(type: PebbleCommandType, parameters: [String: String]) {
        self.id = UUID().uuidString
        self.type = type
        self.timestamp = Date()
        self.parameters = parameters
        self.status = .pendingConfirmation
    }

    var isExpired: Bool {
        status == .pendingConfirmation && Date().timeIntervalSince(timestamp) > 300
    }

    var confirmationMessage: String {
        switch type {
        case .bolus:
            let units = parameters["units"] ?? "?"
            return "Pebble requests bolus: \(units) units"
        case .carbEntry:
            let grams = parameters["grams"] ?? "?"
            let absorption = parameters["absorptionHours"] ?? "3"
            return "Pebble requests carb entry: \(grams)g (\(absorption)h absorption)"
        }
    }
}

protocol PebbleCommandConfirmationDelegate: AnyObject {
    func pendingCommandRequiresConfirmation(_ command: PebbleCommand)
    func commandExecuted(_ command: PebbleCommand)
    func commandFailed(_ command: PebbleCommand, error: String)
}

/// Manages the command queue for Pebble-originated bolus/carb requests.
/// All commands require explicit confirmation on iPhone before execution.
final class PebbleCommandManager {
    private var pendingCommands: [String: PebbleCommand] = [:]
    private let queue = DispatchQueue(label: "PebbleCommandManager.queue")

    weak var confirmationDelegate: PebbleCommandConfirmationDelegate?

    /// Closures set by the integration layer to execute confirmed commands via Trio's APSManager / CarbsStorage.
    var executeBolus: ((Double) -> Void)?
    var executeCarbs: ((Double, Double) -> Void)?

    var maxBolus: Double = 10.0
    var maxCarbs: Double = 200.0

    // MARK: - Queue Commands

    func queueBolus(units: Double) -> PebbleCommand? {
        guard units > 0, units <= maxBolus else {
            debug(.service, "Pebble: bolus rejected \(units)U (limit \(maxBolus)U)")
            return nil
        }

        let command = PebbleCommand(
            type: .bolus,
            parameters: ["units": String(format: "%.2f", units)]
        )

        queue.sync { pendingCommands[command.id] = command }
        debug(.service, "Pebble: bolus \(units)U queued, awaiting confirmation")

        DispatchQueue.main.async { [weak self] in
            self?.confirmationDelegate?.pendingCommandRequiresConfirmation(command)
        }
        return command
    }

    func queueCarbEntry(grams: Double, absorptionHours: Double = 3.0) -> PebbleCommand? {
        guard grams > 0, grams <= maxCarbs else {
            debug(.service, "Pebble: carbs rejected \(grams)g (limit \(maxCarbs)g)")
            return nil
        }

        let command = PebbleCommand(
            type: .carbEntry,
            parameters: [
                "grams": String(format: "%.1f", grams),
                "absorptionHours": String(format: "%.1f", absorptionHours),
            ]
        )

        queue.sync { pendingCommands[command.id] = command }
        debug(.service, "Pebble: carb entry \(grams)g queued, awaiting confirmation")

        DispatchQueue.main.async { [weak self] in
            self?.confirmationDelegate?.pendingCommandRequiresConfirmation(command)
        }
        return command
    }

    // MARK: - Confirm / Reject

    func confirmCommand(_ commandId: String) {
        queue.sync {
            guard var command = pendingCommands[commandId],
                  command.status == .pendingConfirmation
            else {
                debug(.service, "Pebble: cannot confirm command \(commandId)")
                return
            }

            command.status = .confirmed
            command.confirmedAt = Date()

            switch command.type {
            case .bolus:
                if let unitsStr = command.parameters["units"], let units = Double(unitsStr) {
                    debug(.service, "Pebble: executing confirmed bolus \(units)U")
                    executeBolus?(units)
                    command.status = .executed
                    command.executedAt = Date()
                } else {
                    command.status = .failed
                    command.errorMessage = "Invalid bolus amount"
                }

            case .carbEntry:
                if let gramsStr = command.parameters["grams"], let grams = Double(gramsStr),
                   let absStr = command.parameters["absorptionHours"], let abs = Double(absStr)
                {
                    debug(.service, "Pebble: executing confirmed carb entry \(grams)g")
                    executeCarbs?(grams, abs)
                    command.status = .executed
                    command.executedAt = Date()
                } else {
                    command.status = .failed
                    command.errorMessage = "Invalid carb entry"
                }
            }

            pendingCommands[commandId] = command

            DispatchQueue.main.async { [weak self] in
                if command.status == .executed {
                    self?.confirmationDelegate?.commandExecuted(command)
                } else if let err = command.errorMessage {
                    self?.confirmationDelegate?.commandFailed(command, error: err)
                }
            }
        }
    }

    func rejectCommand(_ commandId: String) {
        queue.sync {
            guard var command = pendingCommands[commandId],
                  command.status == .pendingConfirmation
            else { return }
            command.status = .rejected
            pendingCommands[commandId] = command
            debug(.service, "Pebble: command \(commandId) rejected")
        }
    }

    // MARK: - Query

    func getPendingCommands() -> [PebbleCommand] {
        queue.sync {
            pendingCommands.values
                .filter { $0.status == .pendingConfirmation && !$0.isExpired }
                .sorted { $0.timestamp < $1.timestamp }
        }
    }

    func cleanupExpired() {
        queue.sync {
            for (id, command) in pendingCommands where command.isExpired {
                pendingCommands[id]?.status = .expired
            }
            pendingCommands = pendingCommands.filter {
                $0.value.status == .pendingConfirmation ||
                    ($0.value.status == .confirmed && $0.value.executedAt == nil)
            }
        }
    }

    func pendingCommandsJSON() -> String {
        let pending = getPendingCommands()
        if pending.isEmpty { return "{\"pending\":[]}" }

        let items = pending.map { cmd in
            "{\"id\":\"\(cmd.id)\",\"type\":\"\(cmd.type.rawValue)\",\"message\":\"\(cmd.confirmationMessage)\"}"
        }.joined(separator: ",")

        return "{\"pending\":[\(items)]}"
    }
}
