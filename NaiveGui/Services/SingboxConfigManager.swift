import Foundation

final class SingboxConfigManager {
    static let shared = SingboxConfigManager()

    private let fileManager = FileManager.default
    private let appSupportURL: URL

    private init() {
        let urls = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        appSupportURL = urls[0].appendingPathComponent("NaiveGui", isDirectory: true)
    }

    var singboxConfigURL: URL {
        appSupportURL.appendingPathComponent("singbox-config.json")
    }

    var routingRulesURL: URL {
        appSupportURL.appendingPathComponent("routing-rules.json")
    }

    // MARK: - Rules Persistence

    func loadRules() -> [RoutingRule] {
        guard let data = try? Data(contentsOf: routingRulesURL) else { return [] }
        return (try? JSONDecoder().decode([RoutingRule].self, from: data)) ?? []
    }

    func saveRules(_ rules: [RoutingRule]) throws {
        let data = try JSONEncoder().encode(rules)
        try data.write(to: routingRulesURL, options: .atomic)
    }

    // MARK: - CN Direct Template

    func cnDirectTemplate() -> [RoutingRule] {
        [
            RoutingRule(name: "CN GeoIP", type: .direct, conditions: [
                RuleCondition(field: .ruleSet, value: "geoip-cn")
            ]),
            RoutingRule(name: "CN GeoSite", type: .direct, conditions: [
                RuleCondition(field: .ruleSet, value: "geosite-cn")
            ]),
            RoutingRule(name: "Private", type: .direct, conditions: [
                RuleCondition(field: .ruleSet, value: "geosite-private")
            ]),
            RoutingRule(name: "Apple CN", type: .direct, conditions: [
                RuleCondition(field: .ruleSet, value: "geosite-apple@cn")
            ]),
            RoutingRule(name: "Google CN", type: .direct, conditions: [
                RuleCondition(field: .ruleSet, value: "geosite-google@cn")
            ]),
            RoutingRule(name: "Games CN", type: .direct, conditions: [
                RuleCondition(field: .ruleSet, value: "geosite-category-games-cn")
            ])
        ]
    }

    // MARK: - Config Generation

    func writeSingboxConfig(
        naivePort: Int,
        routingPort: Int,
        routingHTTPPort: Int,
        routingListenAddress: String,
        rules: [RoutingRule]
    ) throws -> URL {
        let configManager = ConfigFileManager.shared
        var config: [String: Any] = [
            "log": ["level": "info", "timestamp": true],
            "inbounds": [
                [
                    "type": "socks",
                    "tag": "routed-in",
                    "listen": routingListenAddress,
                    "listen_port": routingPort
                ],
                [
                    "type": "http",
                    "tag": "routed-http-in",
                    "listen": routingListenAddress,
                    "listen_port": routingHTTPPort
                ]
            ],
            "outbounds": [
                [
                    "type": "socks",
                    "tag": "proxy",
                    "server": "127.0.0.1",
                    "server_port": naivePort
                ],
                ["type": "direct", "tag": "direct"],
                ["type": "block", "tag": "block"]
            ]
        ]

        // Collect unique rule_set references
        var ruleSets: [[String: Any]] = []
        var seenRuleSets = Set<String>()

        for rule in rules {
            for cond in rule.conditions where cond.field == .ruleSet {
                if !seenRuleSets.contains(cond.value) {
                    seenRuleSets.insert(cond.value)
                    ruleSets.append(buildRuleSet(tag: cond.value))
                }
            }
        }

        let routeConfig = buildRoute(rules: rules, ruleSets: ruleSets)

        config["route"] = routeConfig

        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: singboxConfigURL, options: .atomic)
        return singboxConfigURL
    }

    func deleteSingboxConfig() {
        try? fileManager.removeItem(at: singboxConfigURL)
    }

    // MARK: - Private Helpers

    private func buildRuleSet(tag: String) -> [String: Any] {
        var rs: [String: Any] = [
            "tag": tag,
            "type": "remote",
            "format": "binary",
            "download_detour": "proxy"
        ]

        if tag.hasPrefix("geoip") {
            rs["url"] = "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/\(tag).srs"
        } else if tag.hasPrefix("geosite") {
            rs["url"] = "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/\(tag).srs"
        }

        return rs
    }

    private func buildRoute(rules: [RoutingRule], ruleSets: [[String: Any]]) -> [String: Any] {
        var route: [String: Any] = [:]

        if !ruleSets.isEmpty {
            route["rule_set"] = ruleSets
        }

        var routeRules: [[String: Any]] = []

        for rule in rules {
            for cond in rule.conditions {
                var r: [String: Any] = [:]

                switch cond.field {
                case .domain:
                    r["domain"] = [cond.value]
                case .domainSuffix:
                    r["domain_suffix"] = [cond.value]
                case .domainKeyword:
                    r["domain_keyword"] = [cond.value]
                case .ipCidr:
                    r["ip_cidr"] = [cond.value]
                case .ruleSet:
                    r["rule_set"] = cond.value
                }

                r["outbound"] = rule.type.rawValue
                routeRules.append(r)
            }
        }

        route["rules"] = routeRules
        return route
    }
}
