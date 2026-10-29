import Foundation

/// One account in config.json. Same field names as the Windows widget where they overlap,
/// except `menuBar` (the Windows `taskbar`).
public struct AccountConfig: Codable, Equatable, Sendable {
    public var name: String
    public var label: String?
    /// Only "claude-code" is supported on macOS for now.
    public var source: String
    /// Claude Code config folder; nil means ~/.claude.
    public var dir: String?
    /// Show this account's rings in the menu bar.
    public var menuBar: Bool?
    /// Which rings to draw in the menu bar ("5h", "7d", "fable"). Nil = all available.
    public var limits: [String]?
    /// 1-2 letters shown before the rings when several accounts are in the menu bar.
    public var short: String?
    public var hidden: Bool?
    /// false skips the Fable probe for this account.
    public var fable: Bool?
    /// Plan label fallback when the API can't tell.
    public var plan: String?

    public init(name: String, label: String? = nil, source: String = "claude-code", dir: String? = nil,
                menuBar: Bool? = nil, limits: [String]? = nil, short: String? = nil,
                hidden: Bool? = nil, fable: Bool? = nil, plan: String? = nil) {
        self.name = name
        self.label = label
        self.source = source
        self.dir = dir
        self.menuBar = menuBar
        self.limits = limits
        self.short = short
        self.hidden = hidden
        self.fable = fable
        self.plan = plan
    }

    public var displayName: String { (label?.isEmpty == false ? label : nil) ?? name }
    public var isVisible: Bool { hidden != true }
    public var isInMenuBar: Bool { isVisible && menuBar == true }

    public var limitKeys: [LimitKey] {
        guard let limits else { return LimitKey.allCases }
        let keys = limits.compactMap { LimitKey(rawValue: $0) }
        return keys.isEmpty ? LimitKey.allCases : keys
    }
}

public struct AppConfig: Codable, Equatable, Sendable {
    /// Minutes between refreshes; 5 at the lowest, 30 by default.
    public var refreshMinutes: Int?
    /// What goes inside each ring: "percent" (default) or "none".
    public var inside: String?
    public var accounts: [AccountConfig]

    public init(refreshMinutes: Int? = 30, inside: String? = "percent", accounts: [AccountConfig] = []) {
        self.refreshMinutes = refreshMinutes
        self.inside = inside
        self.accounts = accounts
    }

    public var effectiveRefreshMinutes: Int { max(5, refreshMinutes ?? 30) }
    public var showPercentInside: Bool { (inside ?? "percent") == "percent" }
}

/// config.json and the log live in ~/Library/Application Support/claude-usage-widget.
public final class ConfigStore {
    public let directory: URL
    public var configURL: URL { directory.appendingPathComponent("config.json") }
    public var logURL: URL { directory.appendingPathComponent("widget.log") }

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.directory = base.appendingPathComponent("claude-usage-widget", isDirectory: true)
        }
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: configURL.path) }

    /// nil when there is no config file yet. Throws when the file is there but unreadable.
    public func load() throws -> AppConfig? {
        guard exists else { return nil }
        let data = try Data(contentsOf: configURL)
        return try JSONDecoder().decode(AppConfig.self, from: data)
    }

    public func save(_ config: AppConfig) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let data = try enc.encode(config)
        try data.write(to: configURL, options: .atomic)
    }
}

public enum Log {
    private static let queue = DispatchQueue(label: "claude-usage-widget.log")
    public static var url: URL = ConfigStore().logURL

    /// Never pass a token here.
    public static func write(_ message: String) {
        let line = "\(stamp())  \(message)\n"
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}
