import SwiftUI

struct DetailView: View {
    let profile: ServerProfile
    @EnvironmentObject var appState: AppState

    @State private var editProfile: ServerProfile
    @State private var selectedTab: DetailTab = .config

    enum DetailTab: String, CaseIterable {
        case config = "Config"
        case logs = "Logs"
        case status = "Status"
    }

    init(profile: ServerProfile) {
        self.profile = profile
        self._editProfile = State(initialValue: profile)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(DetailTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            switch selectedTab {
            case .config:
                ConfigEditorView(profile: $editProfile)
                    .environmentObject(appState)
            case .logs:
                LogViewerView()
                    .environmentObject(appState)
            case .status:
                ConnectionStatusView()
                    .environmentObject(appState)
            }
        }
        .onChange(of: profile.id) { _ in
            editProfile = profile
            selectedTab = .config
        }
    }
}
