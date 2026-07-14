import Foundation

struct RoutingRule: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var type: RuleAction
    var conditions: [RuleCondition]
    /// 是否启用。关闭后路由引擎跳过该规则。默认 true；旧数据反序列化缺失该键时回退 true。
    var enabled: Bool

    init(id: UUID = UUID(), name: String, type: RuleAction, conditions: [RuleCondition] = [], enabled: Bool = true) {
        self.id = id
        self.name = name
        self.type = type
        self.conditions = conditions
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, type, conditions, enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.type = try c.decode(RuleAction.self, forKey: .type)
        self.conditions = try c.decodeIfPresent([RuleCondition].self, forKey: .conditions) ?? []
        // 向后兼容：旧配置无 enabled 键时默认 true。
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
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
