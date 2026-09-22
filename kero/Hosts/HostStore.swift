import Foundation

/// Host definitions are user data, not app state. They live in a small JSON
/// file so they can be inspected and backed up independently of window state.
@MainActor
enum HostStore {
    /// Headless checks redirect storage to a throwaway path; they run against
    /// the real HOME without -DDEBUG and must never touch user state.
    static var storageOverride: URL?

    static var storageURL: URL {
        if let storageOverride { return storageOverride }
        #if DEBUG
        let defaultDirectory = "kero-dev"
        #else
        let defaultDirectory = "kero"
        #endif
        let override = Bundle.main.object(
            forInfoDictionaryKey: "KeroConfigurationNamespace"
        ) as? String
        let directory = override.flatMap { value in
            value.hasPrefix("kero-")
                && value.count <= 64
                && value.utf8.allSatisfy {
                    ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45
                }
                ? value : nil
        } ?? defaultDirectory
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/\(directory)/ssh-hosts.json")
    }

    static func load() throws -> [SSHHostDefinition] {
        let data = try Data(contentsOf: storageURL)
        return try JSONDecoder().decode([SSHHostDefinition].self, from: data)
    }

    static func save(_ hosts: [SSHHostDefinition]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(hosts)
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: storageURL, options: .atomic)
    }
}
