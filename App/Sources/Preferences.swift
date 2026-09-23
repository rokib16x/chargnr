import Foundation

/// App-only settings (the charging config lives in the helper).
enum Preferences {
    enum Key: String {
        case showPercent, notifyLimit, notifyHeat, notifyTopUp, notifyDischarge, notifyHelper
    }

    private static var defaults: UserDefaults { .standard }

    static func bool(_ key: Key, default value: Bool = true) -> Bool {
        defaults.object(forKey: key.rawValue) as? Bool ?? value
    }

    static func set(_ key: Key, _ value: Bool) {
        defaults.set(value, forKey: key.rawValue)
    }
}
