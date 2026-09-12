import Foundation

/// The restorable record this client has already answered, per device, as a device id to generation
/// map persisted in client settings.
///
/// A device keeps its record until a client answers it, and every status refresh re-reports it, so
/// without this memory the same record would be offered again on every refresh for as long as the user
/// leaves it unanswered elsewhere. A later capture on the same device carries a different generation
/// and is therefore offered, which is exactly the intent: an offer is shown once per record.
enum SessionRestoreAnsweredGenerations {
    static func decode(_ stored: String?) -> [String: String] {
        guard let stored, let map = try? JSONDecoder().decode([String: String].self, from: Data(stored.utf8)) else { return [:] }
        return map
    }

    static func encode(_ generations: [String: String]) -> String {
        guard let data = try? JSONEncoder().encode(generations) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Records one device's answer. One entry per device, replaced rather than appended: only the record
    /// a device is currently offering can be answered, so an older generation's entry can never be asked
    /// about again.
    static func recording(_ generations: [String: String], deviceID: String, generation: String) -> [String: String] {
        var generations = generations
        generations[deviceID] = generation
        return generations
    }
}
