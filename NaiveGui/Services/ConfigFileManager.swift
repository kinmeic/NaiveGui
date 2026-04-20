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
}
