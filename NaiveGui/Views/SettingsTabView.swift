import SwiftUI

struct SettingsTabView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var globalSettings: GlobalSettings

    @State private var showBinaryPicker = false
    @State private var showSingboxPicker = false

    var body: some View {
        Form {
            Section("Naive Binary") {
                LabeledContent("Path") {
                    HStack {
                        TextField("", text: $globalSettings.naiveBinaryPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse...") {
                            showBinaryPicker = true
                        }
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

            Section("Routing (sing-box)") {
                Toggle("Enable routing", isOn: $globalSettings.routingEnabled)

                if globalSettings.routingEnabled {
                    LabeledContent("sing-box Path") {
                        HStack {
                            TextField("", text: $globalSettings.singboxBinaryPath)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse...") {
                                showSingboxPicker = true
                            }
                        }
                    }

                    if !globalSettings.singboxBinaryPath.isEmpty {
                        let exists = FileManager.default.fileExists(atPath: globalSettings.singboxBinaryPath)
                        HStack(spacing: 4) {
                            Image(systemName: exists ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(exists ? .green : .red)
                            Text(exists ? "sing-box found" : "sing-box not found")
                                .font(.caption)
                                .foregroundStyle(exists ? .green : .red)
                        }
                    }

                    LabeledContent("Routing Port") {
                        TextField("", value: $globalSettings.routingPort, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }

                    Toggle("Set system proxy automatically", isOn: $globalSettings.autoSystemProxy)
                }
            }

            Section("Listen Address") {
                TextField("Address", text: $globalSettings.listenAddress)
                    .textFieldStyle(.roundedBorder)
            }

            Section("SOCKS Proxy") {
                Toggle("Enable SOCKS", isOn: $globalSettings.socksEnabled)
                if globalSettings.socksEnabled {
                    LabeledContent("Port") {
                        TextField("", value: $globalSettings.socksPort, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                }
            }

            Section("HTTP Proxy") {
                Toggle("Enable HTTP", isOn: $globalSettings.httpEnabled)
                if globalSettings.httpEnabled {
                    LabeledContent("Port") {
                        TextField("", value: $globalSettings.httpPort, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                }
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
        .fileImporter(
            isPresented: $showSingboxPicker,
            allowedContentTypes: [.executable],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    globalSettings.singboxBinaryPath = url.path
                }
            case .failure:
                break
            }
        }
    }
}
