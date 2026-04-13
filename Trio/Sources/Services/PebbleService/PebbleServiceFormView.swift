import LoopKit
import SwiftUI

/// Configuration UI for `PebbleService` (onboarding and settings).
struct PebbleServiceFormView: View {
    enum Mode {
        case create
        case settings
    }

    @ObservedObject var service: PebbleService
    let mode: Mode
    let dismiss: () -> Void
    /// Only used in `.create` — called before `notifyServiceCreatedAndOnboarded` on the navigation controller.
    let onCreateFinished: (() -> Void)?

    /// Never substitute a throwaway manager — it would not match the instance wired to `PebbleLocalAPIServer`.
    private var pebbleCommandManager: PebbleCommandManager? {
        (TrioApp.resolver.resolve(PebbleManager.self) as? BasePebbleManager)?.getCommandManager()
    }

    var body: some View {
        NavigationStack {
            formContent
        }
    }

    private var formContent: some View {
        Form {
            Section {
                Toggle(
                    String(localized: "Enable Pebble integration", comment: "Pebble service toggle"),
                    isOn: $service.isEnabled
                )
                Toggle(
                    String(localized: "Native iOS BLE data push (experimental)", comment: "Pebble optional PebbleKit iOS BLE toggle"),
                    isOn: $service.useNativeBLEPush
                )
                HStack {
                    Text(String(localized: "Local HTTP port", comment: "Pebble JS fallback server port label"))
                    Spacer()
                    TextField(
                        "8080",
                        text: Binding(
                            get: { String(service.httpPort) },
                            set: {
                                if let v = UInt16($0.filter(\.isNumber)), v >= 1024 {
                                    service.httpPort = v
                                }
                            }
                        )
                    )
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 80)
                }
            } header: {
                Text(String(localized: "Connection", comment: "Pebble service section header"))
            } footer: {
                Text(
                    String(
                        localized:
                        "Recommended: leave native BLE off. PebbleKit JavaScript in Rebble polls this port and sends data to the watch — that is the supported, future-proof path. Enable native iOS BLE only if you understand it may be unreliable when Trio is backgrounded.",
                        comment: "Pebble service help footer"
                    )
                )
            }

            Section {
                if let cmdMgr = pebbleCommandManager {
                    NavigationLink {
                        PebbleCommandConfirmationView(commandManager: cmdMgr)
                    } label: {
                        Text(String(localized: "Pending bolus & carb requests", comment: "Pebble service: pending watch commands link"))
                    }
                } else {
                    Text(String(localized: "Pending bolus & carb requests", comment: "Pebble service: pending watch commands link"))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(String(localized: "Watch requests", comment: "Pebble service section header"))
            } footer: {
                Text(
                    String(
                        localized:
                        "Bolus and carb entries initiated on the Pebble appear here for confirmation before Trio delivers them.",
                        comment: "Pebble service pending requests footer"
                    )
                )
            }

            if mode == .settings {
                Section {
                    Button(
                        String(localized: "Delete Pebble Integration", comment: "Delete Pebble service button"),
                        role: .destructive
                    ) {
                        service.deleteService()
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(String(localized: "Pebble", comment: "Pebble service navigation title"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: service.useNativeBLEPush) { _, _ in
            if mode == .settings {
                service.persistUpdate()
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(mode == .create ? String(localized: "Continue", comment: "Pebble onboarding continue") : String(
                    localized: "Done",
                    comment: "Pebble settings done"
                )) {
                    if mode == .create {
                        service.completeCreateForOnboarding()
                        onCreateFinished?()
                    } else {
                        service.persistUpdate()
                    }
                    dismiss()
                }
            }
        }
    }
}
