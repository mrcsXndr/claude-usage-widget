import XCTest
@testable import UsageCore

final class UsageCoreTests: XCTestCase {

    // MARK: Keychain service names

    func testDefaultDirUsesPlainServiceFirst() {
        let services = ClaudeCode.keychainServices(forDir: nil)
        XCTAssertEqual(services.first, "Claude Code-credentials")
    }

    func testCustomDirServiceIsSha256Prefix() {
        // sha256("/Users/test/.claude-work") starts with 03abf0ee
        XCTAssertEqual(ClaudeCode.hashedService(forConfigDir: "/Users/test/.claude-work"),
                       "Claude Code-credentials-03abf0ee")
        let services = ClaudeCode.keychainServices(forDir: "/Users/test/.claude-work/")
        XCTAssertEqual(services.first, "Claude Code-credentials-03abf0ee")
        XCTAssertFalse(services.contains("Claude Code-credentials"))
    }

    // MARK: Credentials

    func testParseCredentialsJSON() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-abc","refreshToken":"r","expiresAt":1893456000000,"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}"#
        let login = try XCTUnwrap(ClaudeCode.parseCredentials(Data(json.utf8)))
        XCTAssertEqual(login.token, "sk-ant-oat01-abc")
        XCTAssertEqual(login.plan, "Max 20x")
        XCTAssertEqual(login.expires, Date(timeIntervalSince1970: 1_893_456_000))
    }

    func testParseCredentialsHex() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"tok","subscriptionType":"pro"}}"#
        let hex = Data(json.utf8).map { String(format: "%02x", $0) }.joined() + "\n"
        let login = try XCTUnwrap(ClaudeCode.parseCredentials(Data(hex.utf8)))
        XCTAssertEqual(login.token, "tok")
        XCTAssertEqual(login.plan, "Pro")
        XCTAssertNil(login.expires)
    }

    func testParseCredentialsRejectsJunk() {
        XCTAssertNil(ClaudeCode.parseCredentials(Data("".utf8)))
        XCTAssertNil(ClaudeCode.parseCredentials(Data("{}".utf8)))
        XCTAssertNil(ClaudeCode.parseCredentials(Data("not a secret".utf8)))
    }

    // MARK: Usage API

    func testParseUsageResponse() throws {
        let json = """
        {"five_hour":{"utilization":42.0,"resets_at":"2026-10-29T15:00:00.123456+00:00"},
         "seven_day":{"utilization":91,"resets_at":"2026-11-02T08:00:00Z"},
         "seven_day_opus":null,
         "limits":[{"kind":"weekly_scoped","percent":12.5,"resets_at":"2026-11-02T08:00:00+00:00",
                    "scope":{"model":{"display_name":"Claude Fable"}}}]}
        """
        guard case .usage(let w, let limited) = UsageClient.parseUsageResponse(status: 200, data: Data(json.utf8)) else {
            return XCTFail("expected usage")
        }
        XCTAssertFalse(limited)
        XCTAssertEqual(w[.fiveHour]?.pct, 42)
        XCTAssertEqual(w[.sevenDay]?.pct, 91)
        XCTAssertEqual(w[.fable]?.pct, 12.5)
        XCTAssertEqual(try XCTUnwrap(w[.fiveHour]?.reset).timeIntervalSince1970, 1_793_286_000, accuracy: 1)
        XCTAssertNotNil(w[.fable]?.reset)
    }

    func testUsageResponseErrors() {
        let scope = Data(#"{"error":{"type":"permission_error","message":"oauth_scope_insufficient"}}"#.utf8)
        XCTAssertEqual(UsageClient.parseUsageResponse(status: 403, data: scope), .noScope)
        XCTAssertEqual(UsageClient.parseUsageResponse(status: 401, data: Data()), .invalid(401))
        XCTAssertEqual(UsageClient.parseUsageResponse(status: 429, data: Data()), .retry(429))
    }

    // MARK: Probe

    func testParseProbeHeaders() {
        let headers = [
            "anthropic-ratelimit-unified-5h-utilization": "0.913",
            "anthropic-ratelimit-unified-5h-reset": "1793286000",
            "anthropic-ratelimit-unified-7d-utilization": "0.25",
            "anthropic-ratelimit-unified-7d_oi-utilization": "1.0",
            "anthropic-ratelimit-unified-status": "rejected",
        ]
        guard case .usage(let w, let limited) = UsageClient.parseProbe(status: 429, header: { headers[$0] }) else {
            return XCTFail("expected usage")
        }
        XCTAssertTrue(limited)
        XCTAssertEqual(w[.fiveHour]?.pct, 91.3)
        XCTAssertEqual(w[.fiveHour]?.reset, Date(timeIntervalSince1970: 1_793_286_000))
        XCTAssertEqual(w[.sevenDay]?.pct, 25)
        XCTAssertEqual(w[.fable]?.pct, 100)
    }

    func testProbeWithoutHeadersFails() {
        XCTAssertEqual(UsageClient.parseProbe(status: 400, header: { _ in nil }), .failed("HTTP 400, no usage headers"))
        XCTAssertEqual(UsageClient.parseProbe(status: 401, header: { _ in nil }), .invalid(401))
    }

    // MARK: Formatting and config

    func testCountdown() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(Format.countdown(to: now.addingTimeInterval(2 * 3600 + 14 * 60), now: now), "2h 14m")
        XCTAssertEqual(Format.countdown(to: now.addingTimeInterval(3 * 86400 + 4 * 3600), now: now), "3d 4h")
        XCTAssertEqual(Format.countdown(to: now.addingTimeInterval(30), now: now), "1m")
        XCTAssertEqual(Format.countdown(to: now.addingTimeInterval(-5), now: now), "now")
    }

    func testInitials() {
        XCTAssertEqual(Format.initials(for: ["me@work.com", "personal@x.com"]), ["M", "P"])
        XCTAssertEqual(Format.initials(for: ["paul@a.com", "pat@b.com"]), ["Pa", "Pa"])
        XCTAssertEqual(Format.initials(for: ["work", "home"]), ["W", "H"])
    }

    func testPlanFormat() {
        XCTAssertEqual(ClaudeCode.formatPlan(tier: "default_claude_max_5x", subscription: nil), "Max 5x")
        XCTAssertEqual(ClaudeCode.formatPlan(tier: nil, subscription: "claude_pro"), "Pro")
        XCTAssertNil(ClaudeCode.formatPlan(tier: nil, subscription: nil))
    }

    func testMergeAddsNewAccountsOnce() {
        var cfg = AppConfig()
        let found = [AccountConfig(name: "claude-code", label: "me@x.com"),
                     AccountConfig(name: "claude-code-work", label: "me@work.com", dir: "/Users/test/.claude-work")]
        XCTAssertEqual(ClaudeCode.merge(found, into: &cfg), 2)
        XCTAssertEqual(cfg.accounts.filter(\.isInMenuBar).map(\.name), ["claude-code"])
        XCTAssertEqual(ClaudeCode.merge(found, into: &cfg), 0)
    }

    func testConfigRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConfigStore(directory: dir)
        XCTAssertNil(try store.load())
        let cfg = AppConfig(refreshMinutes: 2, accounts: [AccountConfig(name: "a", menuBar: true, limits: ["5h", "bogus"])])
        try store.save(cfg)
        let back = try XCTUnwrap(try store.load())
        XCTAssertEqual(back, cfg)
        XCTAssertEqual(back.effectiveRefreshMinutes, 5)
        XCTAssertEqual(back.accounts[0].limitKeys, [.fiveHour])
    }
}
