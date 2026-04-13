import SwiftUI

struct PebbleCommandConfirmationView: View {
    @ObservedObject var commandManager: PebbleCommandManager

    @State private var showRejectConfirmation = false
    @State private var rejectCommandId: String?

    var body: some View {
        List {
            if commandManager.pendingCommands.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        Text("No pending commands")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
            } else {
                ForEach(commandManager.pendingCommands) { command in
                    Section {
                        commandRow(command)
                    }
                }
            }
        }
        .navigationTitle("Pebble Requests")
        .confirmationDialog(
            String(localized: "Reject this Pebble request?", comment: "Pebble reject confirmation title"),
            isPresented: $showRejectConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                String(localized: "Reject", comment: "Pebble reject confirmation confirm"),
                role: .destructive
            ) {
                if let id = rejectCommandId {
                    PebbleIntegrationFileLogger.log("ui_reject_confirmed", "id=\(id)")
                    commandManager.rejectCommand(id)
                }
                rejectCommandId = nil
            }
            Button(String(localized: "Cancel", comment: "Pebble reject confirmation cancel"), role: .cancel) {
                rejectCommandId = nil
            }
        } message: {
            Text(
                String(
                    localized: "Nothing will be saved to Trio. Use Confirm to add this carb or bolus.",
                    comment: "Pebble reject confirmation message"
                )
            )
        }
    }

    @ViewBuilder
    private func commandRow(_ command: PebbleCommand) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: command.type == .bolus ? "syringe" : "fork.knife")
                    .foregroundColor(command.type == .bolus ? .blue : .orange)
                Text(command.type == .bolus ? "Bolus Request" : "Carb Entry Request")
                    .font(.headline)
            }

            if let units = command.bolusUnits {
                Text(String(format: "%.2f U", units))
                    .font(.title2)
                    .fontWeight(.semibold)
            }

            if let grams = command.carbGrams {
                Text(String(format: "%.0f g carbs", grams))
                    .font(.title2)
                    .fontWeight(.semibold)
            }

            Text("Requested \(command.createdAt, style: .relative) ago")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Button(String(localized: "Confirm", comment: "Pebble pending command confirm")) {
                    PebbleIntegrationFileLogger.log("ui_confirm_tap", "id=\(command.id) type=\(command.type == .bolus ? "bolus" : "carb")")
                    commandManager.confirmCommand(command.id)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.green)
                .cornerRadius(8)

                Spacer()

                Button(String(localized: "Reject", comment: "Pebble pending command reject")) {
                    PebbleIntegrationFileLogger.log("ui_reject_tap", "id=\(command.id) type=\(command.type == .bolus ? "bolus" : "carb")")
                    rejectCommandId = command.id
                    showRejectConfirmation = true
                }
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.red)
                .cornerRadius(8)
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 4)
    }
}

/// Presents **Pebble Requests** as a sheet whenever a new bolus/carb is queued (HTTP or BLE), so confirmation is not buried in Settings.
struct PebblePendingCommandsGlobalPresenter: ViewModifier {
    @State private var showPendingSheet = false

    func body(content: Content) -> some View {
        content
            .onReceive(Foundation.NotificationCenter.default.publisher(for: Foundation.Notification.Name.pebbleDidEnqueuePendingCommand)) { _ in
                guard let pebbleSvc = TrioApp.resolver.resolve(PebbleServiceManager.self),
                      pebbleSvc.isPebbleDataDeliveryEnabled
                else { return }
                guard (TrioApp.resolver.resolve(PebbleManager.self) as? BasePebbleManager)?.getCommandManager()
                    .pendingCommands.isEmpty == false
                else { return }
                PebbleIntegrationFileLogger.log("ui_sheet", "presenting Pebble pending requests sheet")
                showPendingSheet = true
            }
            .sheet(isPresented: $showPendingSheet) {
                Group {
                    if let cmdMgr = (TrioApp.resolver.resolve(PebbleManager.self) as? BasePebbleManager)?.getCommandManager() {
                        NavigationStack {
                            PebbleCommandConfirmationView(commandManager: cmdMgr)
                                .toolbar {
                                    ToolbarItem(placement: .cancellationAction) {
                                        Button(String(localized: "Close", comment: "Dismiss Pebble pending sheet")) {
                                            showPendingSheet = false
                                        }
                                    }
                                }
                        }
                    } else {
                        Text(String(localized: "Pebble is unavailable.", comment: "Pebble sheet error"))
                            .padding()
                    }
                }
            }
    }
}
