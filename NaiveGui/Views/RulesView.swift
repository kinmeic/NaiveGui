import SwiftUI

struct RulesView: View {
    @EnvironmentObject var appState: AppState
    @State private var rules: [RoutingRule] = []
    @State private var selectedRuleId: UUID?
    @State private var ruleSetStatuses: [String: RuleSetLoadStatus] = [:]
    @State private var ruleSetCatalog: [RuleSetCatalogEntry] = []

    private let configManager = SingboxConfigManager.shared
    private let sidebarWidth: CGFloat = 280

    var body: some View {
        HStack(spacing: 0) {
            // Rule list
            VStack(spacing: 0) {
                List(rules, selection: $selectedRuleId) { rule in
                    RuleRow(rule: rule, ruleSetStatuses: ruleSetStatuses)
                        .tag(rule.id)
                        .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                deleteRule(rule.id)
                            }
                        }
                }
                .listStyle(.sidebar)
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: 44)
                }
                .overlay {
                    if rules.isEmpty {
                        VStack(spacing: 12) {
                            Text("No Rules")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                            Button("Load Templates") {
                                loadTemplate()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.accentColor)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.background)
                    }
                }
                .overlay(alignment: .bottom) {
                    HStack {
                        Button {
                            let rule = RoutingRule(name: "New Rule", type: .proxy)
                            rules.append(rule)
                            selectedRuleId = rule.id
                            saveRules()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)

                        Spacer()

                        Button {
                            loadTemplate()
                        } label: {
                            Image(systemName: "text.badge.star")
                        }
                        .buttonStyle(.borderless)
                        .help("Load Templates")
                    }
                    .padding(8)
                    .frame(width: sidebarWidth)
                    .background(.bar)
                }
            }
            .frame(width: sidebarWidth)
            Divider()

            // Editor
            Group {
                if let rule = rules.first(where: { $0.id == selectedRuleId }) {
                    RuleEditor(rule: rule, ruleSetCatalog: ruleSetCatalog) { updated in
                        updateRule(updated)
                    }
                    .id(rule.id)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("No Rule Selected")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("Add a rule or load templates")
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 400)
        }
        .onAppear {
            rules = configManager.loadRules()
            ruleSetCatalog = configManager.loadRuleSetCatalog()
            refreshRuleSetStatuses()
        }
        .onChange(of: rules) { _ in
            refreshRuleSetStatuses()
        }
        .onReceive(NotificationCenter.default.publisher(for: NativeRoutingProxyManager.ruleSetStatusDidChange)) { _ in
            refreshRuleSetStatuses()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ruleSetCatalogDidChange)) { _ in
            ruleSetCatalog = configManager.loadRuleSetCatalog()
        }
    }

    private func deleteRule(_ id: UUID) {
        rules.removeAll { $0.id == id }
        if selectedRuleId == id {
            selectedRuleId = rules.first?.id
        }
        saveRules()
    }

    private func updateRule(_ rule: RoutingRule) {
        if let idx = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[idx] = rule
        }
        saveRules()
    }

    private func saveRules() {
        try? configManager.saveRules(rules)
    }

    private func refreshRuleSetStatuses() {
        let tags = Set(rules.flatMap { rule in
            rule.conditions.compactMap { condition in
                condition.field == .ruleSet && !condition.value.isEmpty ? condition.value : nil
            }
        })
        ruleSetStatuses = NativeRoutingProxyManager.shared.ruleSetStatuses(for: tags)
    }

    private func loadTemplate() {
        let template = configManager.cnDirectTemplate()
        for t in template {
            if !rules.contains(where: { $0.name == t.name }) {
                rules.append(t)
            }
        }
        selectedRuleId = rules.first?.id
        saveRules()
    }
}

// MARK: - Rule Row

struct RuleRow: View {
    let rule: RoutingRule
    let ruleSetStatuses: [String: RuleSetLoadStatus]

    private var ruleSetTags: [String] {
        rule.conditions.compactMap { condition in
            condition.field == .ruleSet && !condition.value.isEmpty ? condition.value : nil
        }
    }

    private var aggregateRuleSetStatus: RuleSetLoadStatus? {
        guard !ruleSetTags.isEmpty else { return nil }
        let statuses = ruleSetTags.map { ruleSetStatuses[$0] ?? .notLoaded }
        if statuses.contains(.failed) { return .failed }
        if statuses.contains(.loading) { return .loading }
        if statuses.contains(.notLoaded) { return .notLoaded }
        return .ready
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconForType(rule.type))
                .foregroundStyle(colorForType(rule.type))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(rule.name)
                        .font(.body)
                        .lineLimit(1)

                    if aggregateRuleSetStatus == .ready {
                        RuleSetLoadedIcon()
                    }
                }

                if ruleSetTags.isEmpty {
                    Text("\(rule.conditions.count) condition\(rule.conditions.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(ruleSetTags.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            Text(rule.type.label)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(colorForType(rule.type).opacity(0.15))
                .foregroundStyle(colorForType(rule.type))
                .clipShape(Capsule())
        }
        .padding(.vertical, 2)
    }

    private func iconForType(_ type: RuleAction) -> String {
        switch type {
        case .direct: return "arrow.right"
        case .proxy: return "arrow.uturn.right"
        case .block: return "xmark.shield"
        }
    }

    private func colorForType(_ type: RuleAction) -> Color {
        switch type {
        case .direct: return .green
        case .proxy: return .blue
        case .block: return .red
        }
    }
}

private struct RuleSetLoadedIcon: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.green)
            .help("Rule set loaded successfully")
    }
}

// MARK: - Rule Editor

private struct RuleEditor: View {
    let rule: RoutingRule
    let ruleSetCatalog: [RuleSetCatalogEntry]
    let onUpdate: (RoutingRule) -> Void

    @State private var name: String = ""
    @State private var type: RuleAction = .proxy
    @State private var conditions: [RuleCondition] = []
    @State private var hasChanges = false
    @State private var isLoaded = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(name.isEmpty ? "New Rule" : name)
                        .font(.title2)
                        .fontWeight(.semibold)

                    Form {
                        Section("Rule") {
                            LabeledContent("Name") {
                                TextField("", text: $name)
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            LabeledContent("Action") {
                                Picker("", selection: $type) {
                                    ForEach(RuleAction.allCases, id: \.self) { t in
                                        Text(t.label).tag(t)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }
                        }

                        Section("Conditions") {
                            ForEach(conditions.indices, id: \.self) { i in
                                HStack {
                                    Picker("", selection: fieldBinding(for: i)) {
                                        ForEach(ConditionField.allCases, id: \.self) { f in
                                            Text(f.label).tag(f)
                                        }
                                    }
                                    .frame(width: 140)

                                    if conditions[i].field == .ruleSet {
                                        RuleSetPicker(value: $conditions[i].value, catalog: ruleSetCatalog)
                                    } else {
                                        TextField("Value", text: $conditions[i].value)
                                            .textFieldStyle(.roundedBorder)
                                    }

                                    Button {
                                        conditions.remove(at: i)
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }

                            Button("Add Condition") {
                                conditions.append(RuleCondition(field: .domain, value: ""))
                            }
                        }
                    }
                    .formStyle(.grouped)
                }
                .padding(20)
            }

            Divider()

            HStack {
                if hasChanges {
                    Text("Unsaved changes")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Save") {
                    save()
                    hasChanges = false
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(!hasChanges)
            }
            .padding()
        }
        .onAppear {
            isLoaded = false
            name = rule.name
            type = rule.type
            conditions = rule.conditions.isEmpty
                ? [RuleCondition(field: .domain, value: "")]
                : rule.conditions
            DispatchQueue.main.async { isLoaded = true }
        }
        .onChange(of: name) { _ in if isLoaded { hasChanges = true } }
        .onChange(of: type) { _ in if isLoaded { hasChanges = true } }
        .onChange(of: conditions) { _ in if isLoaded { hasChanges = true } }
    }

    private func fieldBinding(for index: Int) -> Binding<ConditionField> {
        Binding(
            get: { conditions[index].field },
            set: { newField in
                conditions[index].field = newField
                if newField == .ruleSet {
                    if conditions[index].value.isEmpty ||
                        !ruleSetCatalog.contains(where: { $0.tag == conditions[index].value }) {
                        conditions[index].value = ruleSetCatalog.first?.tag ?? ""
                    }
                } else if conditions[index].value.hasPrefix("geoip-") || conditions[index].value.hasPrefix("geosite-") {
                    conditions[index].value = ""
                }
            }
        )
    }

    private func save() {
        var updated = rule
        updated.name = name
        updated.type = type
        updated.conditions = conditions.filter { !$0.value.isEmpty }
        onUpdate(updated)
    }
}

private struct RuleSetPicker: View {
    @Binding var value: String
    let catalog: [RuleSetCatalogEntry]

    private var selectedEntryExists: Bool {
        value.isEmpty || catalog.contains { $0.tag == value }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("", selection: $value) {
                if !selectedEntryExists {
                    Text("Missing: \(value)").tag(value)
                }

                ForEach(RuleSetCatalogSource.allCases, id: \.self) { source in
                    let entries = catalog.filter { $0.source == source }
                    if !entries.isEmpty {
                        Section(source.rawValue) {
                            ForEach(entries) { entry in
                                Text(entry.displayName).tag(entry.tag)
                            }
                        }
                    }
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)

            if !selectedEntryExists {
                Text("This rule set is not in the catalog. Update the catalog or choose another rule set.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}
