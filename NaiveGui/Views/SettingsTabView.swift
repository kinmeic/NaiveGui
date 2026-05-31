import AppKit
import SwiftUI

struct SettingsTabView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var globalSettings: GlobalSettings
    @FocusState private var focusedField: Field?
    @State private var isUpdatingRuleSets = false
    @State private var ruleSetUpdateAlert: RuleSetUpdateAlert?

    private enum Field: Hashable {
        case naiveBinaryPath
    }

    var body: some View {
        Form {
            Section("Naive Binary") {
                LabeledContent("Path") {
                    HStack {
                        TextField("", text: $globalSettings.naiveBinaryPath)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .focused($focusedField, equals: .naiveBinaryPath)
                        Button("Browse...") {
                            globalSettings.naiveBinaryPath = selectExecutable(initialPath: globalSettings.naiveBinaryPath) ?? globalSettings.naiveBinaryPath
                            focusedField = nil
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

                LabeledContent("Listen Address") {
                    TextField("", text: $globalSettings.listenAddress)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }

                LabeledContent("SOCKS Port") {
                    TextField("", value: $globalSettings.socksPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }

                Toggle("Enable HTTP", isOn: $globalSettings.httpEnabled)
                if globalSettings.httpEnabled {
                    LabeledContent("HTTP Port") {
                        TextField("", value: $globalSettings.httpPort, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                }
            }

            Section("Routing") {
                LabeledContent("Default Outbound") {
                    Picker("", selection: $globalSettings.routingDefaultOutbound) {
                        Text(RuleAction.direct.label).tag(RuleAction.direct)
                        Text(RuleAction.proxy.label).tag(RuleAction.proxy)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }

                LabeledContent("Routing Listen Address") {
                    TextField("", text: $globalSettings.routingListenAddress)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }

                LabeledContent("Routing SOCKS Port") {
                    TextField("", value: $globalSettings.routingPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }

                LabeledContent("Routing HTTP Port") {
                    TextField("", value: $globalSettings.routingHTTPPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }

                Toggle("Set system proxy automatically", isOn: $globalSettings.autoSystemProxy)

                Button {
                    updateRuleSets()
                } label: {
                    if isUpdatingRuleSets {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Update Rule Sets", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(isUpdatingRuleSets)
            }
        }
        .formStyle(.grouped)
        .padding()
        .alert(item: $ruleSetUpdateAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func selectExecutable(initialPath: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.prompt = "Select"
        panel.message = "Choose the executable file to use."

        if !initialPath.isEmpty {
            let url = URL(fileURLWithPath: initialPath)
            panel.directoryURL = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: initialPath) {
                panel.nameFieldStringValue = url.lastPathComponent
            }
        }

        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func updateRuleSets() {
        isUpdatingRuleSets = true
        DispatchQueue.global(qos: .utility).async {
            do {
                try NativeRoutingProxyManager.updateBuiltInRuleSets()
                DispatchQueue.main.async {
                    isUpdatingRuleSets = false
                    ruleSetUpdateAlert = RuleSetUpdateAlert(
                        title: "Rule Sets Updated",
                        message: "The bundled routing rule sets were downloaded to the local cache."
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    isUpdatingRuleSets = false
                    ruleSetUpdateAlert = RuleSetUpdateAlert(
                        title: "Update Failed",
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private struct RuleSetUpdateAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }
}
