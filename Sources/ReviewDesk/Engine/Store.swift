import Foundation
import UserNotifications

enum Paths {
    static let appSupport = Tools.home + "/Library/Application Support/ReviewDesk"
    static let runs = Tools.home + "/Library/Caches/ReviewDesk/runs"
}

/// JSON files in Application Support.
enum Store {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func url(_ name: String) -> URL {
        URL(fileURLWithPath: Paths.appSupport).appendingPathComponent(name)
    }

    /// Loads a stored value. For objects, keys missing from the file take their values from `value`.
    static func load<T: Codable>(_ name: String, default value: T) -> T {
        guard let data = try? Data(contentsOf: url(name)) else { return value }
        if let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let defaultsData = try? encoder.encode(value),
           let defaults = try? JSONSerialization.jsonObject(with: defaultsData) as? [String: Any],
           let merged = try? JSONSerialization.data(withJSONObject: defaults.merging(stored) { _, new in new }),
           let decoded = try? decoder.decode(T.self, from: merged) {
            return decoded
        }
        if let decoded = try? decoder.decode(T.self, from: data) { return decoded }
        let aside = url(name + ".unreadable")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url(name), to: aside)
        return value
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        do {
            try FileManager.default.createDirectory(atPath: Paths.appSupport, withIntermediateDirectories: true)
            try encoder.encode(value).write(to: url(name), options: .atomic)
        } catch {
            NSLog("ReviewDesk: couldn't save \(name): \(error)")
        }
    }
}

enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
