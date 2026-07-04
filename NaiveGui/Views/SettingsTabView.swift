import AppKit
import SwiftUI

struct SettingsTabView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var globalSettings: GlobalSettings
    @FocusState private var focusedField: Field?
    @State private var isUpdatingRuleSetCatalog = false
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
                LabeledContent("Proxy Mode") {
                    Picker("", selection: $globalSettings.proxyMode) {
                        ForEach(ProxyMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 320)
                }
                .help("System Proxy: configure macOS proxy settings. Transparent (TUN): virtual interface intercepts all traffic (requires NetworkExtension entitlement, pending approval).")

                if globalSettings.proxyMode == .transparent {
                    Text("Transparent proxy uses a virtual network interface to intercept all traffic (TCP/UDP/DNS). Requires NetworkExtension entitlement — pending Apple approval. Until approved, connections will use the routing proxy without system proxy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

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

                LabeledContent("Connection Limit") {
                    TextField("", value: $globalSettings.maxConnections, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                        .onSubmit {
                            // 钳制到合法范围，避免输入越界。
                            let clamped = min(max(globalSettings.maxConnections, 1), 65535)
                            globalSettings.maxConnections = clamped
                        }
                }
                .help("Reject new connections when active count reaches this limit. Each connection uses 3 threads; lower it if you see high CPU under heavy load. Restart the proxy to apply.")

                Button {
                    updateRuleSetCatalog()
                } label: {
                    if isUpdatingRuleSetCatalog {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Update Rule Set Catalog", systemImage: "list.bullet.rectangle")
                    }
                }
                .disabled(isUpdatingRuleSetCatalog)

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

            Section {
                Toggle("Enable DoH (DNS over HTTPS)", isOn: $globalSettings.dohEnabled)

                if globalSettings.dohEnabled {
                    Picker("Provider", selection: $globalSettings.dohProvider) {
                        ForEach(DNSResolver.Provider.allCases, id: \.rawValue) { provider in
                            Text(provider.displayName).tag(provider.rawValue)
                        }
                        Text("Custom").tag("custom")
                    }
                    .pickerStyle(.menu)

                    if globalSettings.dohProvider == "custom" {
                        TextField("DoH URL (https://.../dns-query)", text: $globalSettings.dohCustomURL)
                            .textFieldStyle(.roundedBorder)
                    }

                    Text("DoH requests are sent through the proxy to enable GeoIP rule matching (e.g. geoip-cn). On failure, it automatically falls back to domain rules without affecting connectivity.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("DNS")
            } footer: {
                Text("Disabled by default. When enabled, the routing engine resolves domains to match IP-based rules; DoH queries are sent through the proxy to prevent DNS leaks.")
                    .font(.caption2)
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

    private func updateRuleSetCatalog() {
        isUpdatingRuleSetCatalog = true
        DispatchQueue.global(qos: .utility).async {
            do {
                let entries = try SingboxConfigManager.shared.updateRuleSetCatalog()
                DispatchQueue.main.async {
                    isUpdatingRuleSetCatalog = false
                    ruleSetUpdateAlert = RuleSetUpdateAlert(
                        title: "Rule Set Catalog Updated",
                        message: "Found \(entries.count) rule sets. They are now available in the rule editor."
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    isUpdatingRuleSetCatalog = false
                    ruleSetUpdateAlert = RuleSetUpdateAlert(
                        title: "Catalog Update Failed",
                        message: error.localizedDescription
                    )
                }
            }
        }
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
