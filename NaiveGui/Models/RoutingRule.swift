import Foundation

struct RoutingRule: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var type: RuleAction
    var conditions: [RuleCondition]

    init(id: UUID = UUID(), name: String, type: RuleAction, conditions: [RuleCondition] = []) {
        self.id = id
        self.name = name
        self.type = type
        self.conditions = conditions
    }
}

enum RuleAction: String, Codable, CaseIterable {
    case direct
    case proxy
    case block

    var label: String {
        switch self {
        case .direct: return "Direct"
        case .proxy: return "Proxy"
        case .block: return "Block"
        }
    }
}

struct RuleCondition: Codable, Equatable {
    var field: ConditionField
    var value: String

    init(field: ConditionField, value: String) {
        self.field = field
        self.value = value
    }
}

enum ConditionField: String, Codable, CaseIterable {
    case domain
    case domainSuffix
    case domainKeyword
    case ipCidr
    case ruleSet

    var label: String {
        switch self {
        case .domain: return "Domain"
        case .domainSuffix: return "Domain Suffix"
        case .domainKeyword: return "Domain Keyword"
        case .ipCidr: return "IP CIDR"
        case .ruleSet: return "Rule Set"
        }
    }
}
