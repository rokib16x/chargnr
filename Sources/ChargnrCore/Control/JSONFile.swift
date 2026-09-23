import Foundation

/// A Codable value stored as JSON. Saves go to a temporary file first and are
/// renamed into place, so a crash or power loss never leaves a half-written file.
public struct JSONFile<Value: Codable & Sendable>: Sendable {
    public let url: URL

    public init(_ url: URL) {
        self.url = url
    }

    /// The stored value, or nil if the file is missing or unreadable.
    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Where the helper keeps its files.
public enum HelperPaths {
    public static let directory = URL(fileURLWithPath: "/Library/Application Support/chargnr", isDirectory: true)
    public static var config: URL { directory.appendingPathComponent("config.json") }
    /// Present while chargnr has any switch away from normal. If the helper
    /// starts and finds it, the previous run died and everything is reset.
    public static var dirtyMarker: URL { directory.appendingPathComponent("switched.json") }
}
