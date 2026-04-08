import SwiftUI
import Swinject

struct PebbleServiceStartView: BaseView {
    let resolver: Resolver
    @ObservedObject var state: Settings.StateModel

    @State private var shouldDisplayHint: Bool = false
    @State private var hintDetent = PresentationDetent.large

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    var body: some View {
        Form {
            Section(
                header: Text(String(localized: "Pebble / Rebble", comment: "Pebble service section title")),
                content: {
                    VStack {
                        if let serviceUIType = state.pebbleServiceUIType,
                           let pluginHost = state.provider.pebbleServiceManager.getPebblePluginHost()
                        {
                            if state.provider.pebbleServiceManager.getPebbleServiceUI() != nil {
                                Button {
                                    state.setupPebble.toggle()
                                }
                                label: {
                                    HStack {
                                        Text(String(localized: "Pebble integration enabled", comment: "Pebble connected label"))
                                            .font(.title3)
                                        ZStack {
                                            Image(systemName: "applewatch.side.right")
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.green).font(.caption2)
                                                .offset(x: 9, y: 6)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .center)
                                .buttonStyle(.bordered)
                            } else {
                                Button {
                                    state.setupPebble.toggle()
                                }
                                label: {
                                    Text(String(localized: "Set up Pebble", comment: "Pebble setup button"))
                                        .font(.title3)
                                }
                                .frame(maxWidth: .infinity, alignment: .center)
                                .buttonStyle(.bordered)
                            }
                        }

                        HStack(alignment: .center) {
                            Text(
                                String(
                                    localized:
                                    "Push CGM, IOB, COB, predictions, and loop status to your Pebble when glucose or loop data changes. Confirm bolus and carb entries from the watch in Trio.",
                                    comment: "Pebble service description"
                                )
                            )
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .lineLimit(nil)
                            Spacer()
                            Button(
                                action: {
                                    shouldDisplayHint.toggle()
                                },
                                label: {
                                    HStack {
                                        Image(systemName: "questionmark.circle")
                                    }
                                }
                            ).buttonStyle(BorderlessButtonStyle())
                        }.padding(.top)
                    }.padding(.vertical)
                }
            ).listRowBackground(Color.chart)
        }
        .sheet(isPresented: $state.setupPebble) {
            if let serviceUIType = state.pebbleServiceUIType,
               let pluginHost = state.provider.pebbleServiceManager.getPebblePluginHost()
            {
                if let serviceUI = state.provider.pebbleServiceManager.getPebbleServiceUI() {
                    PebbleSettingsView(
                        serviceUI: serviceUI,
                        serviceOnBoardDelegate: state,
                        serviceDelegate: state
                    )
                } else {
                    PebbleSetupView(
                        serviceUIType: serviceUIType,
                        pluginHost: pluginHost,
                        serviceOnBoardDelegate: state,
                        serviceDelegate: state
                    )
                }
            }
        }
        .sheet(isPresented: $shouldDisplayHint) {
            SettingInputHintView(
                hintDetent: $hintDetent,
                shouldDisplayHint: $shouldDisplayHint,
                hintLabel: String(localized: "Pebble / Rebble", comment: "Pebble help title"),
                hintText: Text(
                    String(
                        localized:
                        "Uses the Rebble app: PebbleKit JavaScript polls Trio’s local HTTP server (recommended). Optional native iOS Bluetooth push is off by default — enable only in Pebble service settings if you need it. Bolus and carb requests from the watch use HTTP and appear in Trio for confirmation.",
                        comment: "Pebble help body"
                    )
                ),
                sheetTitle: String(localized: "Help", comment: "Help sheet title")
            )
        }
        .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle(String(localized: "Pebble", comment: "Pebble navigation title"))
        .navigationBarTitleDisplayMode(.automatic)
        .onAppear(perform: configureView)
    }
}
