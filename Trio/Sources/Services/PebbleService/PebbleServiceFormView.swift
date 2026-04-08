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
                        "When PebbleKit iOS is linked, Trio pushes CGM and loop data over Bluetooth on each update. The HTTP port is used by PebbleKit JS in the Rebble app as a fallback.",
                        comment: "Pebble service help footer"
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
