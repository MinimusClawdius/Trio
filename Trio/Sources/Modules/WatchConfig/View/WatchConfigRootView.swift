import SwiftUI
import Swinject

extension WatchConfig {
    struct RootView: BaseView {
        let resolver: Resolver
        @StateObject var state = StateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            List {
                Section(
                    header: Text("Smartwatch Configuration"),
                    content: {
                        NavigationLink("Apple Watch", destination: WatchConfigAppleWatchView(resolver: resolver, state: state))
                        NavigationLink("Garmin", destination: WatchConfigGarminView(state: state))
                        pebbleRelocatedNoticeRow
                    }
                ).listRowBackground(Color.chart)
            }
            .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
            .navigationTitle("Watch")
            .navigationBarTitleDisplayMode(.automatic)
        }

        /// Legacy Watch → Pebble duplicated **Settings → Services → Pebble / Rebble** and could fight that source of truth; Pebble is configured only under Services now.
        private var pebbleRelocatedNoticeRow: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Pebble / Rebble", comment: "Watch settings: Pebble row title"))
                    .foregroundColor(.primary)
                Text(
                    String(
                        localized:
                        "Configure Pebble under Settings → Services → Pebble / Rebble. Enable the integration, HTTP port, and pending watch requests there.",
                        comment: "Watch settings: Pebble moved to Services explanation"
                    )
                )
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }
}
