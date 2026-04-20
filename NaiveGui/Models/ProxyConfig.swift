import Foundation

// Represents a single proxy server profile (remote server info)
struct ServerProfile: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var serverAddress: String       // e.g. "hk.example.com"
    var serverPort: Int             // e.g. 443
    var username: String
    var password: String
    var proxyProtocol: ProxyProtocol // https or quic
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), name: String, serverAddress: String, serverPort: Int = 443,
         username: String, password: String, proxyProtocol: ProxyProtocol = .https) {
        self.id = id
        self.name = name
        self.serverAddress = serverAddress
        self.serverPort = serverPort
        self.username = username
        self.password = password
        self.proxyProtocol = proxyProtocol
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    // Generate the proxy URL string: "https://user:pass@host:port"
    var proxyURL: String {
        "\(proxyProtocol.rawValue)://\(username):\(password)@\(serverAddress):\(serverPort)"
    }
}

enum ProxyProtocol: String, CaseIterable, Codable {
    case https
    case quic
}

enum ListenProtocol: String, CaseIterable, Codable {
    case socks
    case http
}
