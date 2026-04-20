import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var globalSettings: GlobalSettings

    var body: some View {
        TabView {
            GeneralSettingsView()
                .environmentObject(appState)
                .environmentObject(globalSettings)
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            ListenSettingsView()
                .environmentObject(globalSettings)
                .tabItem {
                    Label("Listening", systemImage: "antenna.radiowaves.left.and.right")
                }
        }
        .frame(width: 450, height: 320)
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var globalSettings: GlobalSettings

    @State private var showBinaryPicker = false

    var body: some View {
        Form {
            Section("Naive Binary") {
                HStack {
                    TextField("Path", text: $globalSettings.naiveBinaryPath)
                        .textFieldStyle(.roundedBorder)

                    Button("Browse...") {
                        showBinaryPicker = true
                    }
                }

                if !globalSettings.naiveBinaryPath.isEmpty {
                    let exists = FileManager.default.fileExists(atPath: globalSettings.naiveBinaryPath)
                    HStack(spacing: 4) {
                        Image(systemName: exists ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(exists ? .green : .red)
                        Text(exists ? "Binary found" : "Binary not found")
                            .font(.caption)
                            .foregroundStyle(exists ? .green : .red)
                    }
                }
            }

            Section {
                Toggle("Set system proxy automatically", isOn: $globalSettings.autoSystemProxy)
            }
        }
        .formStyle(.grouped)
        .padding()
        .fileImporter(
            isPresented: $showBinaryPicker,
            allowedContentTypes: [.executable],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    globalSettings.naiveBinaryPath = url.path
                }
            case .failure:
                break
            }
        }
    }
}

struct ListenSettingsView: View {
    @EnvironmentObject var globalSettings: GlobalSettings

    var body: some View {
        Form {
            Section("Listen Address") {
                TextField("Address", text: $globalSettings.listenAddress)
                    .textFieldStyle(.roundedBorder)
            }

            Section("SOCKS Proxy") {
                Toggle("Enable SOCKS", isOn: $globalSettings.socksEnabled)
                if globalSettings.socksEnabled {
                    HStack {
                        Text("Port")
                        TextField("", value: $globalSettings.socksPort, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Spacer()
                    }
                }
            }

            Section("HTTP Proxy") {
                Toggle("Enable HTTP", isOn: $globalSettings.httpEnabled)
                if globalSettings.httpEnabled {
                    HStack {
                        Text("Port")
                        TextField("", value: $globalSettings.httpPort, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Spacer()
                    }
                }
            }

            Section("Preview") {
                ForEach(globalSettings.listenURLs, id: \.self) { url in
                    Text(url)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
