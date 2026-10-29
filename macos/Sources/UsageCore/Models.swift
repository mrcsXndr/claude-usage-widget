import Foundation

/// The three limits the widget shows.
public enum LimitKey: String, CaseIterable, Codable, Sendable {
    case fiveHour = "5h"
    case sevenDay = "7d"
    case fable = "fable"

    public var caption: String {
        switch self {
        case .fiveHour: return "5h"
        case .sevenDay: return "7d"
        case .fable: return "Fable"
        }
    }

    public var longName: String {
        switch self {
        case .fiveHour: return "5-hour window"
        case .sevenDay: return "7-day window"
        case .fable: return "Fable weekly"
        }
    }
}

/// One limit: how much is used (0-100) and when it resets.
public struct UsageWindow: Equatable, Sendable {
    public var pct: Double?
    public var reset: Date?

    public init(pct: Double? = nil, reset: Date? = nil) {
        self.pct = pct
        self.reset = reset
    }

    public static let empty = UsageWindow()
}

public enum AccountStatus: String, Sendable {
    case loading, ok, limited, error, invalid, expired

    public var isProblem: Bool {
        switch self {
        case .error, .invalid, .expired: return true
        default: return false
        }
    }
}

/// What one refresh learned about one account. Never contains a token.
public struct AccountUsage: Equatable, Sendable {
    public var name: String
    public var label: String
    public var plan: String?
    public var status: AccountStatus
    public var error: String?
    /// "usage-api" or "probe".
    public var method: String?
    public var windows: [LimitKey: UsageWindow]
    public var updated: Date?

    public init(name: String, label: String, plan: String? = nil, status: AccountStatus = .loading,
                error: String? = nil, method: String? = nil,
                windows: [LimitKey: UsageWindow] = [:], updated: Date? = nil) {
        self.name = name
        self.label = label
        self.plan = plan
        self.status = status
        self.error = error
        self.method = method
        self.windows = windows
        self.updated = updated
    }

    public func window(_ key: LimitKey) -> UsageWindow {
        windows[key] ?? .empty
    }
}

/// Ring colour bands, same as the Windows widget: green below 70%, amber below 90%, red from 90%.
public enum Severity: Sendable {
    case ok, warn, high

    public init(pct: Double) {
        if pct >= 90 { self = .high } else if pct >= 70 { self = .warn } else { self = .ok }
    }
}

public enum UsageError: Error, CustomStringConvertible {
    case network(String)
    case keychain(String)
    case timeout(String)

    public var description: String {
        switch self {
        case .network(let m): return "Network: \(m)"
        case .keychain(let m): return "Keychain: \(m)"
        case .timeout(let m): return "Timed out: \(m)"
        }
    }
}
