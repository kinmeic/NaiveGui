import SwiftUI

struct DetailView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab: GlobalTab = .status

    enum GlobalTab: String, CaseIterable {
        case status = "Status"
        case logs = "Logs"
        case settings = "Settings"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(GlobalTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            switch selectedTab {
            case .status:
                ConnectionStatusView()
                    .environmentObject(appState)
            case .logs:
                LogViewerView()
                    .environmentObject(appState)
            case .settings:
                SettingsTabView()
                    .environmentObject(appState)
                    .environmentObject(appState.globalSettings)
            }
        }
    }
}
