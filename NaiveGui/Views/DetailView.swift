import SwiftUI

struct DetailView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var globalSettings = GlobalSettings.shared
    @State private var selectedTab: GlobalTab = .status

    enum GlobalTab: String, CaseIterable {
        case status = "Status"
        case profiles = "Profiles"
        case rules = "Rules"
        case logs = "Logs"
        case settings = "Settings"
    }

    private var visibleTabs: [GlobalTab] {
        GlobalTab.allCases
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(visibleTabs, id: \.self) { tab in
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
            case .profiles:
                ProfilesTabView()
                    .environmentObject(appState)
            case .logs:
                LogViewerView()
                    .environmentObject(appState)
            case .rules:
                RulesView()
                    .environmentObject(appState)
            case .settings:
                SettingsTabView()
                    .environmentObject(appState)
                    .environmentObject(appState.globalSettings)
            }
        }
    }
}
