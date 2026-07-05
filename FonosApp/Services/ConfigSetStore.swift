import Foundation

/// A named, saved config bundle ("scenario"). Bundles are stored KEYLESS —
/// API keys live only in the Keychain and are injected at export time.
struct ConfigSet: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var createdAt: Date
    /// Keyless config bundle JSON (ScenarioImporter shape).
    var bundleJSON: Data
}

/// Persists named config sets in the App Group container (read-through, so the
/// main app and any extension see a consistent list). Mirrors VocabStore.
final class ConfigSetStore: @unchecked Sendable {

    private let defaults: UserDefaults
    private let storageKey: String

    private var state: [ConfigSet] {
        get {
            guard let data = defaults.data(forKey: storageKey),
                  let decoded = try? JSONDecoder().decode([ConfigSet].self, from: data) else {
                return []
            }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: storageKey)
            }
        }
    }

    init(defaults: UserDefaults? = UserDefaults(suiteName: AppConfigStorage.appGroupID),
         storageKey: String = "config_sets_v1") {
        self.defaults = defaults ?? .standard
        self.storageKey = storageKey
    }

    /// Saved sets, newest first.
    var sets: [ConfigSet] {
        state.sorted { $0.createdAt > $1.createdAt }
    }

    func set(id: String) -> ConfigSet? {
        state.first { $0.id == id }
    }

    /// Insert or replace by id.
    func save(_ set: ConfigSet) {
        var all = state
        if let index = all.firstIndex(where: { $0.id == set.id }) {
            all[index] = set
        } else {
            all.append(set)
        }
        state = all
    }

    func delete(id: String) {
        state = state.filter { $0.id != id }
    }

    func rename(id: String, to newName: String) {
        var all = state
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].name = newName
        state = all
    }
}
