import Foundation

struct RuleSetCatalogEntry: Codable, Identifiable, Equatable {
    let tag: String
    let source: RuleSetCatalogSource
    let url: URL

    var id: String { tag }

    var displayName: String {
        tag
    }
}

extension Notification.Name {
    static let ruleSetCatalogDidChange = Notification.Name("NaiveGuiRuleSetCatalogDidChange")
}

enum RuleSetCatalogSource: String, Codable, CaseIterable {
    case geoip = "GeoIP"
    case geosite = "GeoSite"
}

final class SingboxConfigManager: @unchecked Sendable {
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

    var ruleSetCatalogURL: URL {
        appSupportURL.appendingPathComponent("rule-set-catalog.json")
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

    // MARK: - Rule Set Catalog

    func loadRuleSetCatalog() -> [RuleSetCatalogEntry] {
        if let data = try? Data(contentsOf: ruleSetCatalogURL),
           let entries = try? JSONDecoder().decode([RuleSetCatalogEntry].self, from: data),
           !entries.isEmpty {
            return entries.sorted { $0.tag.localizedStandardCompare($1.tag) == .orderedAscending }
        }
        if let entries = Self.bundledRuleSetCatalog(), !entries.isEmpty {
            return entries
        }
        return Self.defaultRuleSetCatalog()
    }

    func updateRuleSetCatalog() throws -> [RuleSetCatalogEntry] {
        let entries = try Self.fetchRuleSetCatalog()
        try fileManager.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entries)
        try data.write(to: ruleSetCatalogURL, options: .atomic)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .ruleSetCatalogDidChange, object: nil)
        }
        return entries
    }

    // MARK: - Templates

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
            RoutingRule(name: "Microsoft CN", type: .direct, conditions: [
                RuleCondition(field: .ruleSet, value: "geosite-microsoft@cn")
            ]),
            RoutingRule(name: "Games CN", type: .direct, conditions: [
                RuleCondition(field: .ruleSet, value: "geosite-category-games-cn")
            ]),
            RoutingRule(name: "OpenAI", type: .proxy, conditions: [
                RuleCondition(field: .ruleSet, value: "geosite-openai")
            ]),
            RoutingRule(name: "Anthropic", type: .proxy, conditions: [
                RuleCondition(field: .ruleSet, value: "geosite-anthropic")
            ]),
            RoutingRule(name: "GitHub", type: .proxy, conditions: [
                RuleCondition(field: .ruleSet, value: "geosite-github")
            ]),
            RoutingRule(name: "GitHub Copilot", type: .proxy, conditions: [
                RuleCondition(field: .ruleSet, value: "geosite-github-copilot")
            ]),
            RoutingRule(name: "Google Gemini", type: .proxy, conditions: [
                RuleCondition(field: .ruleSet, value: "geosite-google-gemini")
            ]),
            RoutingRule(name: "Google", type: .proxy, conditions: [
                RuleCondition(field: .ruleSet, value: "geosite-google")
            ]),
            RoutingRule(name: "YouTube", type: .proxy, conditions: [
                RuleCondition(field: .ruleSet, value: "geosite-youtube")
            ]),
            RoutingRule(name: "Telegram", type: .proxy, conditions: [
                RuleCondition(field: .ruleSet, value: "geosite-telegram")
            ]),
            RoutingRule(name: "Geolocation !CN", type: .proxy, conditions: [
                RuleCondition(field: .ruleSet, value: "geosite-geolocation-!cn")
            ])
        ]
    }

    // MARK: - Config Generation

    func writeSingboxConfig(
        naivePort: Int,
        routingPort: Int,
        routingHTTPPort: Int,
        routingListenAddress: String,
        defaultOutbound: RuleAction,
        rules: [RoutingRule]
    ) throws -> URL {
        let activeRules = rules.filter(\.enabled)
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

        for rule in activeRules {
            for cond in rule.conditions where cond.field == .ruleSet {
                if !seenRuleSets.contains(cond.value) {
                    seenRuleSets.insert(cond.value)
                    ruleSets.append(buildRuleSet(tag: cond.value))
                }
            }
        }

        let routeConfig = buildRoute(
            rules: activeRules,
            ruleSets: ruleSets,
            defaultOutbound: defaultOutbound
        )

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

    private static func defaultRuleSetCatalog() -> [RuleSetCatalogEntry] {
        NativeRoutingProxyManager.builtInRuleSetTags.compactMap { tag in
            guard let url = RuleSetStoreURL.remoteURL(for: tag) else { return nil }
            return RuleSetCatalogEntry(
                tag: tag,
                source: tag.hasPrefix("geoip") ? .geoip : .geosite,
                url: url
            )
        }
        .sorted { $0.tag.localizedStandardCompare($1.tag) == .orderedAscending }
    }

    private static func bundledRuleSetCatalog() -> [RuleSetCatalogEntry]? {
        guard let url = Bundle.main.url(
            forResource: "catalog",
            withExtension: "json",
            subdirectory: "rule-sets"
        ) else {
            return nil
        }
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([RuleSetCatalogEntry].self, from: data) else {
            return nil
        }
        return entries.sorted { $0.tag.localizedStandardCompare($1.tag) == .orderedAscending }
    }

    private static func fetchRuleSetCatalog() throws -> [RuleSetCatalogEntry] {
        let geosite = try fetchRuleSetTree(
            source: .geosite,
            apiURL: URL(string: "https://api.github.com/repos/SagerNet/sing-geosite/git/trees/rule-set?recursive=1")!,
            rawBaseURL: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/"
        )
        let geoip = try fetchRuleSetTree(
            source: .geoip,
            apiURL: URL(string: "https://api.github.com/repos/SagerNet/sing-geoip/git/trees/rule-set?recursive=1")!,
            rawBaseURL: "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/"
        )
        return (geosite + geoip)
            .uniquedByTag()
            .sorted { $0.tag.localizedStandardCompare($1.tag) == .orderedAscending }
    }

    private static func fetchRuleSetTree(
        source: RuleSetCatalogSource,
        apiURL: URL,
        rawBaseURL: String
    ) throws -> [RuleSetCatalogEntry] {
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("NaiveGui", forHTTPHeaderField: "User-Agent")

        let data = try URLSession.shared.synchronousData(for: request)
        let response = try JSONDecoder().decode(GitHubTreeResponse.self, from: data)

        return response.tree.compactMap { item in
            guard item.type == "blob", item.path.hasSuffix(".srs") else { return nil }
            let tag = String(item.path.dropLast(4))
            guard let url = URL(string: rawBaseURL + item.path) else { return nil }
            return RuleSetCatalogEntry(tag: tag, source: source, url: url)
        }
    }

    private struct GitHubTreeResponse: Decodable {
        let tree: [GitHubTreeItem]
    }

    private struct GitHubTreeItem: Decodable {
        let path: String
        let type: String
    }

    private func buildRoute(
        rules: [RoutingRule],
        ruleSets: [[String: Any]],
        defaultOutbound: RuleAction
    ) -> [String: Any] {
        var route: [String: Any] = [
            "final": defaultOutbound.rawValue
        ]

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

private enum RuleSetStoreURL {
    static func remoteURL(for tag: String) -> URL? {
        if tag.hasPrefix("geoip") {
            return URL(string: "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/\(tag).srs")
        }
        if tag.hasPrefix("geosite") {
            return URL(string: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/\(tag).srs")
        }
        return nil
    }
}

private extension URLSession {
    func synchronousData(for request: URLRequest) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedBox<Result<Data, Error>?>(nil)

        dataTask(with: request) { data, response, error in
            if let error {
                result.withLock { $0 = .failure(error) }
            } else if let httpResponse = response as? HTTPURLResponse,
                      !(200..<300).contains(httpResponse.statusCode) {
                result.withLock { $0 = .failure(URLError(.badServerResponse)) }
            } else {
                result.withLock { $0 = .success(data ?? Data()) }
            }
            semaphore.signal()
        }.resume()

        semaphore.wait()
        return try result.withLock {
            guard let completed = $0 else { throw URLError(.unknown) }
            return try completed.get()
        }
    }
}

private extension Array where Element == RuleSetCatalogEntry {
    func uniquedByTag() -> [RuleSetCatalogEntry] {
        var seen = Set<String>()
        return filter { entry in
            seen.insert(entry.tag).inserted
        }
    }
}
