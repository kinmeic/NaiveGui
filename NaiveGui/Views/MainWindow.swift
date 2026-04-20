import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        DetailView()
            .environmentObject(appState)
    }
}
