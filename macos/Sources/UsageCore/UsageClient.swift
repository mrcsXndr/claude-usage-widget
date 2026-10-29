import Foundation

/// What one read returned.
public enum UsageReading: Equatable {
    case usage([LimitKey: UsageWindow], limited: Bool)
    /// The token lacks the user:profile scope (setup tokens); use the probe.
    case noScope
    case invalid(Int)
    /// Rate-limited or a server hiccup on the usage API; the probe still works.
    case retry(Int)
    case failed(String)
}

/// Talks to api.anthropic.com. Two ways to read an account's limits:
///   usage API  GET /api/oauth/usage. Free; works for Claude Code logins.
///   probe      A 1-token request; the rate-limit headers on the reply carry the same numbers.
///              Sent to Fable it also carries the Fable weekly limit (header 7d_oi).
public struct UsageClient {
    public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    public static let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let probeModel = "claude-haiku-4-5-20251001"
    public static let fableModel = "claude-fable-5-1"
    /// OAuth tokens only reach models other than Haiku with Claude Code's system prompt.
    static let claudeCodeSystem = "You are Claude Code, Anthropic's official CLI for Claude."
    public static let version = "0.1.0"
    static let userAgent = "claude-usage-widget-mac/\(version) (+https://github.com/mrcsXndr/claude-usage-widget)"

    private let session: URLSession

    public init() {
        // Ephemeral: no cache, no cookies, nothing written to disk.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config)
    }

    private func send(_ method: String, _ url: URL, token: String, body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let body {
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw UsageError.network("no HTTP response") }
            return (data, http)
        } catch let e as UsageError {
            throw e
        } catch {
            throw UsageError.network(error.localizedDescription)
        }
    }

    // MARK: Usage API

    public func readUsageAPI(token: String) async throws -> UsageReading {
        let (data, http) = try await send("GET", Self.usageURL, token: token)
        return Self.parseUsageResponse(status: http.statusCode, data: data)
    }

    public static func parseUsageResponse(status: Int, data: Data) -> UsageReading {
        if status == 200 {
            guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failed("Unreadable usage reply")
            }
            func window(_ any: Any?) -> UsageWindow {
                guard let w = any as? [String: Any] else { return .empty }
                return UsageWindow(pct: number(w["utilization"]), reset: parseDate(w["resets_at"]))
            }
            var fable = window(j["seven_day_fable"])
            // Per-model weekly limits come as limits[] entries of kind weekly_scoped.
            if let limits = j["limits"] as? [[String: Any]] {
                for l in limits where (l["kind"] as? String) == "weekly_scoped" {
                    let scope = l["scope"] as? [String: Any]
                    let model = scope?["model"] as? [String: Any]
                    let name = (model?["display_name"] as? String) ?? ""
                    if name.lowercased().contains("fable") {
                        fable = UsageWindow(pct: number(l["percent"]), reset: parseDate(l["resets_at"]))
                    }
                }
            }
            return .usage([
                .fiveHour: window(j["five_hour"]),
                .sevenDay: window(j["seven_day"]),
                .fable: fable,
            ], limited: false)
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        if status == 403 && (text.contains("oauth_scope_insufficient") || text.contains("scope requirement")) {
            return .noScope
        }
        if status == 401 { return .invalid(401) }
        return .retry(status)
    }

    // MARK: Profile (plan label)

    /// The plan as the profile endpoint reports it, or nil when it can't tell.
    public func readProfilePlan(token: String) async throws -> String? {
        let (data, http) = try await send("GET", Self.profileURL, token: token)
        guard http.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let org = j["organization"] as? [String: Any] else { return nil }
        return ClaudeCode.formatPlan(tier: org["rate_limit_tier"] as? String, subscription: org["organization_type"] as? String)
    }

    // MARK: Probe

    public func readProbe(token: String, model: String = UsageClient.probeModel) async throws -> UsageReading {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "."]],
        ]
        if model != Self.probeModel { body["system"] = Self.claudeCodeSystem }
        let json = try JSONSerialization.data(withJSONObject: body)
        let (_, http) = try await send("POST", Self.messagesURL, token: token, body: json)
        return Self.parseProbe(status: http.statusCode) { http.value(forHTTPHeaderField: $0) }
    }

    /// The numbers ride on the response headers (also on a 429): utilization is a 0-1 fraction,
    /// reset is unix seconds.
    public static func parseProbe(status: Int, header: (String) -> String?) -> UsageReading {
        if status == 401 || status == 403 { return .invalid(status) }
        func value(_ name: String) -> String? {
            header("anthropic-ratelimit-unified-\(name)")?.trimmingCharacters(in: .whitespaces)
        }
        func window(_ key: String) -> UsageWindow {
            let pct = value("\(key)-utilization").flatMap { Double($0) }.map { ($0 * 1000).rounded() / 10 }
            let reset = value("\(key)-reset").flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
            return UsageWindow(pct: pct, reset: reset)
        }
        let five = window("5h"), seven = window("7d"), fable = window("7d_oi")
        if five.pct == nil && seven.pct == nil {
            return .failed("HTTP \(status), no usage headers")
        }
        return .usage([.fiveHour: five, .sevenDay: seven, .fable: fable], limited: value("status") == "rejected")
    }

    // MARK: Dates

    static func parseDate(_ any: Any?) -> Date? {
        if let n = any as? NSNumber { return Date(timeIntervalSince1970: n.doubleValue) }
        guard let s = any as? String, !s.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: s) { return d }
        // Microsecond fractions ("...:00.123456+00:00") trip some formatter versions; drop them.
        let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return plain.date(from: trimmed)
    }
}

/// Reads every account the way the Windows widget does: usage API first, and the probe for
/// tokens that can't use it. Remembers per account which way works. Use from one task at a time.
public final class UsageFetcher {
    private let client: UsageClient
    private var probeOnly = Set<String>()
    private var fableOff = Set<String>()
    private var plans: [String: String] = [:]

    public init(client: UsageClient = UsageClient()) {
        self.client = client
    }

    public func fetch(_ account: AccountConfig) async -> AccountUsage {
        var row = AccountUsage(name: account.name, label: account.displayName, plan: account.plan, status: .error)
        guard account.source == "claude-code" else {
            row.error = "Source '\(account.source)' isn't supported on macOS yet"
            return row
        }

        let login: ClaudeCodeLogin
        switch await Self.loadLogin(dir: account.dir) {
        case .failure(let e):
            row.error = "\(e)"
            Log.write("\(account.name): \(e)")
            return row
        case .success(nil):
            row.error = "Claude Code login not found"
            return row
        case .success(let l?):
            login = l
        }
        if let p = login.plan { row.plan = p }
        if let exp = login.expires, exp <= Date() {
            row.status = .expired
            row.error = "Login expired: open Claude Code to renew it"
            return row
        }

        let token = login.token
        do {
            var reading: UsageReading?
            if !probeOnly.contains(account.name) {
                let r = try await client.readUsageAPI(token: token)
                switch r {
                case .noScope: probeOnly.insert(account.name)
                case .retry: break
                default:
                    reading = r
                    row.method = "usage-api"
                }
            }
            if reading == nil {
                row.method = "probe"
                if account.fable != false && !fableOff.contains(account.name) {
                    do {
                        let r = try await client.readProbe(token: token, model: UsageClient.fableModel)
                        if case .failed = r {
                            fableOff.insert(account.name)
                        } else {
                            reading = r
                            if case .usage(let w, _) = r, w[.fable]?.pct == nil { fableOff.insert(account.name) }
                        }
                    } catch {
                        fableOff.insert(account.name)
                        Log.write("\(account.name): Fable probe failed, using Haiku: \(error)")
                    }
                }
                if reading == nil {
                    reading = try await client.readProbe(token: token, model: UsageClient.probeModel)
                }
            }
            // The plan comes from the API whenever the token may read it; the last good answer covers a failed call.
            if !probeOnly.contains(account.name), let p = try? await client.readProfilePlan(token: token) {
                plans[account.name] = p
            }
            if let p = plans[account.name] { row.plan = p }

            switch reading {
            case .usage(let windows, let limited)?:
                row.windows = windows
                let five = windows[.fiveHour]?.pct ?? 0, seven = windows[.sevenDay]?.pct ?? 0
                row.status = (limited || five >= 100 || seven >= 100) ? .limited : .ok
                row.error = nil
            case .invalid(let code)?:
                row.status = .invalid
                row.error = "Token invalid (HTTP \(code)): sign in to Claude Code again"
            case .failed(let msg)?:
                row.error = msg
            case .retry(let code)?:
                row.error = "Anthropic answered HTTP \(code)"
            case .noScope?, nil:
                row.error = "No usage data"
            }
        } catch {
            row.error = "\(error)"
            Log.write("\(account.name): \(error)")
        }
        row.updated = Date()
        return row
    }

    /// Reads the login off the main thread: `security` can block while the Keychain asks the user.
    static func loadLogin(dir: String?) async -> Result<ClaudeCodeLogin?, Error> {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: Result { try ClaudeCode.login(dir: dir) })
            }
        }
    }
}
