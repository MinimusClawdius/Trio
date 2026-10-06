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
    private var pebbleManager: BasePebbleManager? {
        TrioApp.resolver.resolve(PebbleManager.self) as? BasePebbleManager
    }

    private var pebbleCommandManager: PebbleCommandManager? {
        pebbleManager?.getCommandManager()
    }

    @State private var showPebbleLogShare = false
    @State private var showNoPebbleLogAlert = false
    @State private var statusTick = Date()

    private var pebbleLogExportURL: URL? { PebbleIntegrationFileLogger.exportLogFileURL() }

    private var canExportPebbleLog: Bool {
        guard let url = pebbleLogExportURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber
        else { return false }
        return size.intValue > 0
    }

    private var nativeBLESDKAvailable: Bool {
        PebbleBLEBridge.sdkAvailable
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
                        "Supported path: PebbleKit JavaScript in Rebble polls this loopback port and sends data to the watch. Keep Trio available (or rely on CGM/loop wakes). Adaptive background keep-alive runs only while backgrounded and recently polled, then idles to save battery.",
                        comment: "Pebble service HTTP help footer"
                    )
                )
            }

            Section {
                statusRow(
                    title: String(localized: "HTTP server", comment: "Pebble status HTTP label"),
                    value: httpStatusText,
                    ok: pebbleManager?.httpServerRunning == true && service.isEnabled
                )
                statusRow(
                    title: String(localized: "HTTP keep-alive", comment: "Pebble status keep-alive label"),
                    value: keepAliveStatusText,
                    ok: service.isEnabled && !(pebbleManager?.httpKeepAliveStatusSummary.contains("Idle-suspended") ?? false)
                )
                statusRow(
                    title: String(localized: "Native BLE SDK", comment: "Pebble status BLE SDK label"),
                    value: nativeBLESDKAvailable
                        ? String(localized: "Linked in this build", comment: "Pebble BLE SDK present")
                        : String(localized: "Not linked (HTTP-only build)", comment: "Pebble BLE SDK missing"),
                    ok: nativeBLESDKAvailable
                )
                if service.useNativeBLEPush {
                    statusRow(
                        title: String(localized: "Native BLE link", comment: "Pebble status BLE connected label"),
                        value: bleLinkStatusText,
                        ok: pebbleManager?.isBLEConnected == true
                    )
                }
            } header: {
                Text(String(localized: "Status", comment: "Pebble service status section"))
            } footer: {
                Text(
                    String(
                        localized:
                        "Status reflects the live Pebble manager. Pull to refresh after enabling. Export the Pebble log if HTTP shows offline while Rebble is polling.",
                        comment: "Pebble status footer"
                    )
                )
            }

            Section {
                Toggle(
                    String(localized: "Native iOS BLE data push (experimental)", comment: "Pebble optional PebbleKit iOS BLE toggle"),
                    isOn: $service.useNativeBLEPush
                )
                .disabled(!nativeBLESDKAvailable && !service.useNativeBLEPush)
            } header: {
                Text(String(localized: "Experimental", comment: "Pebble experimental section"))
            } footer: {
                Text(nativeBLEFooterText)
            }

            Section {
                if let cmdMgr = pebbleCommandManager {
                    NavigationLink {
                        PebbleCommandConfirmationView(commandManager: cmdMgr)
                    } label: {
                        Text(String(localized: "Remote command queue", comment: "Pebble service: pending watch commands link"))
                    }
                } else {
                    Text(String(localized: "Remote command queue", comment: "Pebble service: pending watch commands link"))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(String(localized: "Watch requests", comment: "Pebble service section header"))
            } footer: {
                Text(
                    String(
                        localized:
                        "Remote bolus and carbs are sent straight into Trio. This list is normally empty; use it only if you need to inspect a stuck request.",
                        comment: "Pebble service pending requests footer"
                    )
                )
            }

            Section {
                Button {
                    if canExportPebbleLog {
                        showPebbleLogShare = true
                    } else {
                        showNoPebbleLogAlert = true
                    }
                } label: {
                    Text(String(localized: "Export Pebble log", comment: "Pebble: share diagnostic log file"))
                }
            } header: {
                Text(String(localized: "Diagnostics", comment: "Pebble service diagnostics section"))
            } footer: {
                Text(
                    String(
                        localized:
                        "Writes Pebble queue, HTTP, BLE, confirm/reject, and delivery steps to Trio’s Caches folder as Trio-Pebble-Integration.log (also mirrored to the system log). Export after reproducing an issue to attach in support.",
                        comment: "Pebble integration file log footer"
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
        .refreshable {
            statusTick = Date()
        }
        .sheet(isPresented: $showPebbleLogShare) {
            if let url = pebbleLogExportURL {
                ShareSheet(activityItems: [url])
            }
        }
        .alert(
            String(localized: "No Pebble log yet", comment: "Pebble log export empty title"),
            isPresented: $showNoPebbleLogAlert
        ) {
            Button(String(localized: "OK", comment: "Generic OK"), role: .cancel) {}
        } message: {
            Text(
                String(
                    localized: "The log file is empty. Use the Pebble integration, then export again.",
                    comment: "Pebble log export empty message"
                )
            )
        }
        .onChange(of: service.useNativeBLEPush) { _, _ in
            if mode == .settings {
                service.persistUpdate()
            }
        }
        .onAppear {
            statusTick = Date()
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

    private var httpStatusText: String {
        _ = statusTick
        guard service.isEnabled else {
            return String(localized: "Off", comment: "Pebble HTTP off")
        }
        if pebbleManager?.httpServerRunning == true {
            return String(localized: "Listening on loopback", comment: "Pebble HTTP listening")
        }
        return String(localized: "Not listening", comment: "Pebble HTTP down")
    }

    private var keepAliveStatusText: String {
        _ = statusTick
        guard service.isEnabled else {
            return String(localized: "Off", comment: "Pebble keep-alive off")
        }
        return pebbleManager?.httpKeepAliveStatusSummary
            ?? String(localized: "Unknown", comment: "Pebble keep-alive unknown")
    }

    private var bleLinkStatusText: String {
        _ = statusTick
        if !nativeBLESDKAvailable {
            return String(localized: "SDK missing — no-op", comment: "Pebble BLE no SDK")
        }
        if pebbleManager?.isBLEConnected == true {
            return String(localized: "Connected", comment: "Pebble BLE connected")
        }
        if service.useNativeBLEPush {
            return String(localized: "Searching / disconnected", comment: "Pebble BLE not connected")
        }
        return String(localized: "Off", comment: "Pebble BLE off")
    }

    private var nativeBLEFooterText: String {
        if nativeBLESDKAvailable {
            return String(
                localized:
                "Optional. When a modern PebbleKit iOS module is linked, Trio can push AppMessages directly. Prefer JS+HTTP for reliability. Leave off unless you are testing native push.",
                comment: "Pebble BLE footer when SDK present"
            )
        }
        return String(
            localized:
            "Official PebbleKit iOS 4.0 (2016) does not build on current Xcode, so App Store / CI builds ship HTTP-only. The toggle is kept for future Rebble/community SDKs; with this binary it cannot open a native BLE data path. Battery: keep-alive for HTTP is adaptive (background + recent polls only).",
            comment: "Pebble BLE footer when SDK missing"
        )
    }

    @ViewBuilder
    private func statusRow(title: String, value: String, ok: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(ok ? Color.secondary : Color.orange)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
