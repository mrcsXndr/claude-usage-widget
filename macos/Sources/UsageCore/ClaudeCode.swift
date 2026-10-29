import Foundation
import CryptoKit

/// A Claude Code login as stored on this Mac. Read-only: the widget never refreshes it,
/// because refreshing rotates the refresh token and would sign Claude Code out.
public struct ClaudeCodeLogin {
    public let token: String
    public let expires: Date?
    public let plan: String?
}

public struct ClaudeCodeIdentity {
    public let email: String?
    public let accountUuid: String?
}

/// Finds and reads Claude Code logins.
///
/// On macOS Claude Code keeps its login in the login Keychain as a generic password:
///   service "Claude Code-credentials" for the default ~/.claude, and
///   "Claude Code-credentials-<first 8 hex of SHA-256 of the config dir path>" when
///   CLAUDE_CONFIG_DIR is set. The account is the macOS short user name.
/// It is read with /usr/bin/security, which Claude Code itself uses to write the item, so
/// macOS doesn't ask for a password. A <dir>/.credentials.json file is the fallback.
public enum ClaudeCode {
    public static let keychainService = "Claude Code-credentials"

    public static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    public static var defaultDir: URL { home.appendingPathComponent(".claude", isDirectory: true) }

    // MARK: Paths

    /// "/Users/me/.claude-work/" -> "/Users/me/.claude-work"; "~" expanded.
    public static func normalize(_ path: String) -> String {
        var p = (path as NSString).expandingTildeInPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    public static func isDefault(_ dir: String?) -> Bool {
        guard let dir, !dir.isEmpty else { return true }
        return normalize(dir) == normalize(defaultDir.path)
    }

    public static func hashedService(forConfigDir path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(keychainService)-\(hex.prefix(8))"
    }

    /// Keychain services to try for a config dir, most likely first.
    public static func keychainServices(forDir dir: String?) -> [String] {
        let path = normalize(dir ?? defaultDir.path)
        var services: [String] = []
        if isDefault(dir) { services.append(keychainService) }
        // CLAUDE_CONFIG_DIR is hashed as typed; cover the path with and without a trailing slash.
        for variant in [path, path + "/"] {
            let s = hashedService(forConfigDir: variant)
            if !services.contains(s) { services.append(s) }
        }
        return services
    }

    // MARK: Reading a login

    /// The login for a config dir (nil = ~/.claude), or nil when there is none.
    public static func login(dir: String?) throws -> ClaudeCodeLogin? {
        var keychainError: Error?
        for service in keychainServices(forDir: dir) {
            do {
                if let data = try readKeychain(service: service), let login = parseCredentials(data) {
                    return login
                }
            } catch {
                keychainError = error
            }
        }
        let file = URL(fileURLWithPath: normalize(dir ?? defaultDir.path)).appendingPathComponent(".credentials.json")
        if let data = try? Data(contentsOf: file), let login = parseCredentials(data) {
            return login
        }
        if let keychainError { throw keychainError }
        return nil
    }

    /// The raw secret for a Keychain item, or nil when there is no such item.
    static func readKeychain(service: String) throws -> Data? {
        let base = ["find-generic-password", "-s", service, "-w"]
        var result = try Shell.run("/usr/bin/security", base + ["-a", NSUserName()], timeout: 60)
        if result.status == 44 {  // errSecItemNotFound: try without the account name
            result = try Shell.run("/usr/bin/security", base, timeout: 60)
        }
        if result.status == 44 { return nil }
        if result.status != 0 {
            let why = result.stderrLastLine
            throw UsageError.keychain(why.isEmpty ? "security exited \(result.status)" : why)
        }
        return result.stdout
    }

    /// Parses Claude Code's credentials JSON ({"claudeAiOauth": {...}}). `security -w` prints
    /// the secret as hex when it isn't plain text, so hex is accepted too.
    public static func parseCredentials(_ raw: Data) -> ClaudeCodeLogin? {
        guard var text = String(data: raw, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        if !text.hasPrefix("{"), let decoded = decodeHex(text), let s = String(data: decoded, encoding: .utf8) {
            text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        var expires: Date?
        if let ms = number(oauth["expiresAt"]) {
            expires = Date(timeIntervalSince1970: ms / 1000)
        }
        let plan = formatPlan(tier: oauth["rateLimitTier"] as? String, subscription: oauth["subscriptionType"] as? String)
        return ClaudeCodeLogin(token: token, expires: expires, plan: plan)
    }

    static func decodeHex(_ s: String) -> Data? {
        let chars = Array(s)
        guard chars.count % 2 == 0, chars.allSatisfy({ $0.isHexDigit }) else { return nil }
        var data = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
            data.append(b)
            i += 2
        }
        return data
    }

    /// "default_claude_max_20x" -> "Max 20x"; else the subscription type, e.g. "claude_pro" -> "Pro".
    public static func formatPlan(tier: String?, subscription: String?) -> String? {
        if let tier, let r = tier.range(of: #"max_(\d+x)"#, options: .regularExpression) {
            let m = tier[r].dropFirst("max_".count)
            return "Max \(m)"
        }
        if let subscription, !subscription.isEmpty {
            var s = subscription
            if s.hasPrefix("claude_") { s.removeFirst("claude_".count) }
            return s.replacingOccurrences(of: "_", with: " ").capitalized
        }
        return nil
    }

    // MARK: Identity and discovery

    /// Who a config dir is signed in as: ~/.claude.json sits beside ~/.claude; a custom dir
    /// keeps .claude.json inside.
    public static func identity(dir: String?) -> ClaudeCodeIdentity? {
        let path = normalize(dir ?? defaultDir.path)
        for candidate in [path + ".json", path + "/.claude.json"] {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: candidate)),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let acct = root["oauthAccount"] as? [String: Any] else { continue }
            return ClaudeCodeIdentity(email: acct["emailAddress"] as? String, accountUuid: acct["accountUuid"] as? String)
        }
        return nil
    }

    /// ~/.claude and every other ~/.claude* folder (one per account via CLAUDE_CONFIG_DIR),
    /// plus CLAUDE_CONFIG_DIR itself when the app was started with it.
    public static func candidateDirs() -> [String] {
        var dirs: [String] = []
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !env.isEmpty {
            dirs.append(normalize(env))
        }
        dirs.append(normalize(defaultDir.path))
        let fm = FileManager.default
        if let names = try? fm.contentsOfDirectory(atPath: home.path) {
            for name in names.sorted() where name.hasPrefix(".claude") {
                let full = home.appendingPathComponent(name).path
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                    dirs.append(normalize(full))
                }
            }
        }
        var seen = Set<String>()
        return dirs.filter { seen.insert($0.lowercased()).inserted }
    }

    /// Every Claude Code login on this Mac, as config entries. Calls `security`, so run it off the main thread.
    public static func discover() -> [AccountConfig] {
        var result: [AccountConfig] = []
        var seenAccounts = Set<String>()
        for dir in candidateDirs() {
            let maybeLogin: ClaudeCodeLogin?
            do { maybeLogin = try self.login(dir: dir) } catch {
                Log.write("discovery: \(dir): \(error)")
                continue
            }
            guard maybeLogin != nil else { continue }
            let id = identity(dir: dir)
            if let uuid = id?.accountUuid {
                if seenAccounts.contains(uuid) { continue }
                seenAccounts.insert(uuid)
            }
            let isDefaultDir = isDefault(dir)
            var name = "claude-code"
            if !isDefaultDir {
                let leaf = URL(fileURLWithPath: dir).lastPathComponent
                var suffix = leaf.replacingOccurrences(of: #"^\.claude[-_.]?"#, with: "", options: .regularExpression)
                if suffix.isEmpty { suffix = leaf }
                name = "claude-code-" + suffix
            }
            result.append(AccountConfig(
                name: name,
                label: id?.email ?? (isDefaultDir ? "Claude Code" : URL(fileURLWithPath: dir).lastPathComponent),
                source: "claude-code",
                dir: isDefaultDir ? nil : dir
            ))
        }
        return result
    }

    /// Adds logins the config doesn't have yet; returns how many were added. The first account
    /// ever added goes in the menu bar; later ones are ticked from the dropdown.
    @discardableResult
    public static func merge(_ found: [AccountConfig], into config: inout AppConfig) -> Int {
        var added = 0
        for var a in found {
            let known = config.accounts.contains { c in
                c.name == a.name || (c.source == "claude-code" && a.source == "claude-code"
                    && normalize(c.dir ?? defaultDir.path) == normalize(a.dir ?? defaultDir.path))
            }
            if known { continue }
            a.menuBar = !config.accounts.contains { $0.isInMenuBar }
            config.accounts.append(a)
            added += 1
        }
        return added
    }
}

func number(_ any: Any?) -> Double? {
    if let n = any as? NSNumber { return n.doubleValue }
    if let s = any as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
    return nil
}
