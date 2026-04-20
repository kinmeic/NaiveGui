import Foundation

final class ConfigFileManager {
    static let shared = ConfigFileManager()

    private let fileManager = FileManager.default
    private let appSupportURL: URL

    private init() {
        let urls = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        appSupportURL = urls[0].appendingPathComponent("NaiveGui", isDirectory: true)
    }

    var profilesDirectory: URL {
        appSupportURL.appendingPathComponent("profiles", isDirectory: true)
    }

    var activeConfigURL: URL {
        appSupportURL.appendingPathComponent("active.json")
    }

    func ensureDirectories() {
        try? fileManager.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
    }

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    func loadAllProfiles() -> [ServerProfile] {
        ensureDirectories()
        guard let files = try? fileManager.contentsOfDirectory(at: profilesDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> ServerProfile? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(ServerProfile.self, from: data)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func saveProfile(_ profile: ServerProfile) throws {
        ensureDirectories()
        let url = profilesDirectory.appendingPathComponent("\(profile.id.uuidString).json")
        let data = try encoder.encode(profile)
        try data.write(to: url, options: .atomic)
    }

    func deleteProfile(id: UUID) throws {
        let url = profilesDirectory.appendingPathComponent("\(id.uuidString).json")
        try? fileManager.removeItem(at: url)
    }

    func writeActiveConfig(for profile: ServerProfile) throws -> URL {
        ensureDirectories()
        let data = try GlobalSettings.shared.configJSON(for: profile)
        try data.write(to: activeConfigURL, options: .atomic)
        return activeConfigURL
    }

    func deleteActiveConfig() {
        try? fileManager.removeItem(at: activeConfigURL)
    }

    // MARK: - Geo Data Files

    var geoipURL: URL {
        appSupportURL.appendingPathComponent("geoip.dat")
    }

    var geositeURL: URL {
        appSupportURL.appendingPathComponent("geosite.dat")
    }

    func ensureGeoDataFiles() {
        ensureDirectories()
        copyGeoFile(fromBundle: "geoip.dat", to: geoipURL)
        copyGeoFile(fromBundle: "geosite.dat", to: geositeURL)
    }

    private func copyGeoFile(fromBundle name: String, to destination: URL) {
        // Skip if already exists and is recent (within 24h)
        if let attrs = try? fileManager.attributesOfItem(atPath: destination.path),
           let modDate = attrs[.modificationDate] as? Date,
           abs(modDate.timeIntervalSinceNow) < 86400 {
            return
        }
        // Copy from app bundle
        if let bundleURL = Bundle.main.url(forResource: name, withExtension: nil) {
            try? fileManager.removeItem(at: destination)
            try? fileManager.copyItem(at: bundleURL, to: destination)
        }
    }

    // MARK: - Geo Data Download

    @MainActor
    func updateGeoDataFiles() async throws {
        try await downloadGeoFile(
            name: "geoip.dat",
            to: geoipURL,
            primary: "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat",
            fallback: "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat"
        )
        try await downloadGeoFile(
            name: "geosite.dat",
            to: geositeURL,
            primary: "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat",
            fallback: "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat"
        )
    }

    private func downloadGeoFile(name: String, to destination: URL, primary: String, fallback: String) async throws {
        ensureDirectories()
        do {
            let data = try await fetchData(from: primary)
            try data.write(to: destination, options: .atomic)
        } catch {
            let data = try await fetchData(from: fallback)
            try data.write(to: destination, options: .atomic)
        }
    }

    private func fetchData(from urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
