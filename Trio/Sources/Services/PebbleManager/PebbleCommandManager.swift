import Combine
import Foundation

/// Manages a queue of commands (bolus/carb requests) from the Pebble watch.
/// Commands are **executed immediately** after validation (no iPhone confirmation step).
///
/// All mutations to `pendingCommands` run on the main queue so SwiftUI observes updates
/// (the Pebble HTTP server handles requests on a background queue).
final class PebbleCommandManager: ObservableObject {
    @Published var pendingCommands: [PebbleCommand] = []

    var executeBolus: ((Double) -> Void)?
    var executeCarbs: ((Double, Double) -> Void)?

    var maxBolus: Decimal = 10.0
    var maxCarbs: Decimal = 250.0

    private let expiryInterval: TimeInterval = 300

    private func performOnMainSync(_ block: () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.sync(execute: block)
        }
    }

    func queueBolus(units: Double) -> PebbleCommand? {
        guard Decimal(units) <= maxBolus, units > 0 else { return nil }

        let command = PebbleCommand(
            id: UUID().uuidString,
            type: .bolus,
            bolusUnits: units,
            carbGrams: nil,
            absorptionHours: nil,
            createdAt: Date()
        )

        performOnMainSync {
            pendingCommands.append(command)
            purgeExpired()
            PebbleIntegrationFileLogger.log("pending_queued", "bolus id=\(command.id) units=\(String(format: "%.2f", units))U pending=\(pendingCommands.count)")
            confirmCommand(command.id)
        }
        return command
    }

    func queueCarbEntry(grams: Double, absorptionHours: Double) -> PebbleCommand? {
        guard Decimal(grams) <= maxCarbs, grams > 0 else { return nil }

        let command = PebbleCommand(
            id: UUID().uuidString,
            type: .carbEntry,
            bolusUnits: nil,
            carbGrams: grams,
            absorptionHours: absorptionHours,
            createdAt: Date()
        )

        performOnMainSync {
            pendingCommands.append(command)
            purgeExpired()
            PebbleIntegrationFileLogger.log(
                "pending_queued",
                "carb id=\(command.id) grams=\(String(format: "%.0f", grams))g absorption=\(String(format: "%.1f", absorptionHours))h pending=\(pendingCommands.count)"
            )
            confirmCommand(command.id)
        }
        return command
    }

    func confirmCommand(_ commandId: String) {
        performOnMainSync {
            guard let index = pendingCommands.firstIndex(where: { $0.id == commandId }) else {
                PebbleIntegrationFileLogger.log("confirm_skipped", "id=\(commandId) not in pending queue")
                return
            }
            let command = pendingCommands.remove(at: index)

            guard !command.isExpired(expiryInterval) else {
                debug(.service, "Pebble: command \(commandId) expired, skipping execution")
                PebbleIntegrationFileLogger.log("confirm_expired", "id=\(commandId) type=\(command.typeLogLabel)")
                return
            }

            switch command.type {
            case .bolus:
                guard let units = command.bolusUnits else {
                    debug(.service, "Pebble: bolus command missing units")
                    PebbleIntegrationFileLogger.log("confirm_failed", "id=\(commandId) reason=missing_units")
                    return
                }
                guard let runBolus = executeBolus else {
                    debug(.service, "Pebble: executeBolus not wired — carb/bolus handlers are set in AppleWatchManager; check app launch / DI.")
                    PebbleIntegrationFileLogger.log("confirm_failed", "id=\(commandId) reason=executeBolus_nil")
                    return
                }
                debug(.service, "Pebble: executing confirmed bolus of \(String(format: "%.2f", units))U")
                PebbleIntegrationFileLogger.log("confirm_execute", "bolus id=\(commandId) units=\(String(format: "%.2f", units))U")
                runBolus(units)
            case .carbEntry:
                guard let grams = command.carbGrams, grams > 0 else {
                    debug(.service, "Pebble: carb command missing grams")
                    PebbleIntegrationFileLogger.log("confirm_failed", "id=\(commandId) reason=missing_grams")
                    return
                }
                // Do not require absorptionHours: older queued commands or edge paths may omit it.
                let hours = command.absorptionHours ?? 3.0
                guard let runCarbs = executeCarbs else {
                    debug(.service, "Pebble: executeCarbs not wired — carb/bolus handlers are set in AppleWatchManager; check app launch / DI.")
                    PebbleIntegrationFileLogger.log("confirm_failed", "id=\(commandId) reason=executeCarbs_nil")
                    return
                }
                debug(.service, "Pebble: executing confirmed carb entry of \(String(format: "%.0f", grams))g (absorption \(String(format: "%.1f", hours))h)")
                PebbleIntegrationFileLogger.log(
                    "confirm_execute",
                    "carb id=\(commandId) grams=\(String(format: "%.0f", grams))g absorption=\(String(format: "%.1f", hours))h"
                )
                runCarbs(grams, hours)
            }
        }
    }

    func rejectCommand(_ commandId: String) {
        performOnMainSync {
            pendingCommands.removeAll { $0.id == commandId }
            debug(.service, "Pebble: rejected command \(commandId)")
            PebbleIntegrationFileLogger.log("rejected", "id=\(commandId) pending_remaining=\(pendingCommands.count)")
        }
    }

    func pendingCommandsJSON() -> String {
        var json = "[]"
        performOnMainSync {
            purgeExpired()
            let commands = pendingCommands

            let items = commands.map { cmd -> String in
                let typeStr = cmd.type == .bolus ? "bolus" : "carbEntry"
                let bolusStr = cmd.bolusUnits.map { String(format: "%.2f", $0) } ?? "null"
                let carbStr = cmd.carbGrams.map { String(format: "%.0f", $0) } ?? "null"
                return "{\"id\":\"\(cmd.id)\",\"type\":\"\(typeStr)\",\"bolusUnits\":\(bolusStr),\"carbGrams\":\(carbStr),\"createdAt\":\"\(ISO8601DateFormatter().string(from: cmd.createdAt))\"}"
            }

            json = "[\(items.joined(separator: ","))]"
        }
        return json
    }

    private func purgeExpired() {
        pendingCommands.removeAll { $0.isExpired(expiryInterval) }
    }
}

struct PebbleCommand: Identifiable {
    let id: String
    let type: PebbleCommandType
    let bolusUnits: Double?
    let carbGrams: Double?
    let absorptionHours: Double?
    let createdAt: Date

    func isExpired(_ interval: TimeInterval) -> Bool {
        Date().timeIntervalSince(createdAt) > interval
    }
}

enum PebbleCommandType {
    case bolus
    case carbEntry
}

private extension PebbleCommand {
    var typeLogLabel: String {
        switch type {
        case .bolus: return "bolus"
        case .carbEntry: return "carbEntry"
        }
    }
}

/// Append-only UTF-8 log under Caches (`Trio-Pebble-Integration.log`) for Pebble HTTP/BLE confirm flows; mirrored to `debug(.service, …)`.
enum PebbleIntegrationFileLogger {
    private static let fileName = "Trio-Pebble-Integration.log"
    private static let maxBytes = 384 * 1024
    private static let queue = DispatchQueue(label: "net.nightscout.Trio.pebbleIntegrationFileLog", qos: .utility)

    /// Share or upload this file from **Settings → Services → Pebble → Export Pebble log**.
    static func exportLogFileURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(fileName, isDirectory: false)
    }

    static func log(_ tag: String, _ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] [\(tag)] \(message)\n"
        debug(.service, "Pebble file log [\(tag)] \(message)")

        queue.async {
            guard let url = exportLogFileURL() else { return }
            var combined = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            combined.append(line)
            if let data = combined.data(using: .utf8), data.count > maxBytes {
                let slice = data.suffix(maxBytes)
                combined = String(data: slice, encoding: .utf8) ?? ""
            }
            try? combined.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
