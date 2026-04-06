import SwiftUI

struct PebbleCommandConfirmationView: View {
    @ObservedObject private var viewModel: PebbleCommandViewModel

    init(commandManager: PebbleCommandManager) {
        _viewModel = ObservedObject(wrappedValue: PebbleCommandViewModel(commandManager: commandManager))
    }

    var body: some View {
        Group {
            if viewModel.pendingCommands.isEmpty {
                emptyState
            } else {
                commandList
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 48))
                .foregroundColor(.green)
            Text("No Pending Requests")
                .font(.headline)
            Text("Requests from your Pebble watch will appear here.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var commandList: some View {
        List {
            Section(header: Text("Awaiting Confirmation")) {
                ForEach(viewModel.pendingCommands) { command in
                    PebbleCommandRow(
                        command: command,
                        onConfirm: { viewModel.confirm(command) },
                        onReject: { viewModel.reject(command) }
                    )
                }
            }

            Section(footer: safetyNotice) {
                EmptyView()
            }
        }
    }

    private var safetyNotice: some View {
        Text("All commands from your Pebble watch require explicit confirmation. Commands expire after 5 minutes if not confirmed.")
            .font(.caption)
            .foregroundColor(.secondary)
    }
}

private struct PebbleCommandRow: View {
    let command: PebbleCommand
    let onConfirm: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: commandIcon)
                    .foregroundColor(commandColor)
                    .font(.title2)

                VStack(alignment: .leading) {
                    Text(commandTitle)
                        .font(.headline)
                    Text(command.timestamp, style: .relative)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }

            Text(command.confirmationMessage)
                .font(.body)

            HStack {
                Button(action: onReject) {
                    Label("Reject", systemImage: "xmark.circle.fill")
                        .foregroundColor(.red)
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(action: onConfirm) {
                    Label("Confirm", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.white)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        }
        .padding(.vertical, 8)
    }

    private var commandIcon: String {
        switch command.type {
        case .bolus: return "syringe"
        case .carbEntry: return "fork.knife"
        }
    }

    private var commandColor: Color {
        switch command.type {
        case .bolus: return .blue
        case .carbEntry: return .orange
        }
    }

    private var commandTitle: String {
        switch command.type {
        case .bolus: return "Bolus Request"
        case .carbEntry: return "Carb Entry"
        }
    }
}

final class PebbleCommandViewModel: ObservableObject {
    @Published var pendingCommands: [PebbleCommand] = []

    private let commandManager: PebbleCommandManager

    init(commandManager: PebbleCommandManager) {
        self.commandManager = commandManager
        self.commandManager.confirmationDelegate = self
        refresh()
    }

    func refresh() {
        pendingCommands = commandManager.getPendingCommands()
    }

    func confirm(_ command: PebbleCommand) {
        commandManager.confirmCommand(command.id)
        refresh()
    }

    func reject(_ command: PebbleCommand) {
        commandManager.rejectCommand(command.id)
        refresh()
    }
}

extension PebbleCommandViewModel: PebbleCommandConfirmationDelegate {
    func pendingCommandRequiresConfirmation(_: PebbleCommand) {
        DispatchQueue.main.async { self.refresh() }
    }

    func commandExecuted(_: PebbleCommand) {
        DispatchQueue.main.async { self.refresh() }
    }

    func commandFailed(_: PebbleCommand, error _: String) {
        DispatchQueue.main.async { self.refresh() }
    }
}
