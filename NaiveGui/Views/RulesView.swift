import SwiftUI

struct RulesView: View {
    @EnvironmentObject var appState: AppState
    @State private var rules: [RoutingRule] = []
    @State private var selectedRuleId: UUID?

    private let configManager = SingboxConfigManager.shared

    var body: some View {
        HStack(spacing: 0) {
            // Rule list
            List(rules, selection: $selectedRuleId) { rule in
                RuleRow(rule: rule)
                    .tag(rule.id)
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            deleteRule(rule.id)
                        }
                    }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
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
                .background(.bar)
            }
            Divider()

            // Editor
            Group {
                if let rule = rules.first(where: { $0.id == selectedRuleId }) {
                    RuleEditor(rule: rule) { updated in
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

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconForType(rule.type))
                .foregroundStyle(colorForType(rule.type))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                    .font(.body)
                    .lineLimit(1)
                Text("\(rule.conditions.count) condition\(rule.conditions.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

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

// MARK: - Rule Editor

private struct RuleEditor: View {
    let rule: RoutingRule
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
                                    Picker("", selection: $conditions[i].field) {
                                        ForEach(ConditionField.allCases, id: \.self) { f in
                                            Text(f.label).tag(f)
                                        }
                                    }
                                    .frame(width: 140)

                                    TextField("Value", text: $conditions[i].value)
                                        .textFieldStyle(.roundedBorder)

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

    private func save() {
        var updated = rule
        updated.name = name
        updated.type = type
        updated.conditions = conditions.filter { !$0.value.isEmpty }
        onUpdate(updated)
    }
}
