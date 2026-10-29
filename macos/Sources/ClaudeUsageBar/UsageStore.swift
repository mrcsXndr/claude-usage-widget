import Foundation
import UsageCore

/// The app's state: config, the last usage per account, and refresh scheduling.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var config = AppConfig()
    @Published private(set) var usage: [String: AccountUsage] = [:]
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var refreshing = false
    @Published private(set) var scanning = false
    /// A short message under the list ("Added 1 account").
    @Published var notice: String?

    let configStore = ConfigStore()
    private let fetcher = UsageFetcher()
    private var lastManualRefresh: Date?

    var visibleAccounts: [AccountConfig] { config.accounts.filter(\.isVisible) }
    var menuBarAccounts: [AccountConfig] { config.accounts.filter(\.isInMenuBar) }

    /// Manual refresh at most once a minute, like the Windows widget.
    func canRefreshManually(now: Date = Date()) -> Bool {
        guard let last = lastManualRefresh else { return true }
        return now.timeIntervalSince(last) >= 60
    }

    /// First launch: no config yet, so find the Claude Code logins and write one.
    func start() {
        Log.url = configStore.logURL
        if configStore.exists {
            reloadConfig()
        }
        if configStore.exists && !config.accounts.isEmpty {
            refresh()
        } else {
            // First run, or no logins found last time: look again.
            scan(firstRun: true)
        }
    }

    func reloadConfig() {
        do {
            if let c = try configStore.load() { config = c }
        } catch {
            notice = "config.json couldn't be read; using the last good settings"
            Log.write("config: \(error)")
        }
    }

    private func save() {
        do { try configStore.save(config) } catch {
            notice = "Couldn't save settings"
            Log.write("save config: \(error)")
        }
    }

    func refreshIfDue(now: Date = Date()) {
        guard let last = lastRefresh else { refresh(); return }
        if now.timeIntervalSince(last) >= Double(config.effectiveRefreshMinutes * 60) {
            refresh()
        }
    }

    func refresh(manual: Bool = false) {
        guard !refreshing, !scanning else { return }
        if manual {
            guard canRefreshManually() else { return }
            lastManualRefresh = Date()
            notice = nil
        }
        // Picks up hand edits to config.json.
        reloadConfig()
        let accounts = visibleAccounts
        refreshing = true
        Task {
            for account in accounts {
                let result = await fetcher.fetch(account)
                usage[account.name] = result
            }
            // Forget accounts that were removed from the config.
            let names = Set(config.accounts.map(\.name))
            usage = usage.filter { names.contains($0.key) }
            lastRefresh = Date()
            refreshing = false
        }
    }

    func setInMenuBar(_ name: String, _ on: Bool) {
        reloadConfig()
        guard let i = config.accounts.firstIndex(where: { $0.name == name }) else { return }
        config.accounts[i].menuBar = on
        save()
    }

    /// Looks for Claude Code logins that aren't in the config yet.
    func scan(firstRun: Bool = false) {
        guard !scanning else { return }
        scanning = true
        notice = firstRun ? nil : "Looking for Claude Code logins\u{2026}"
        Task {
            let found = await Task.detached(priority: .utility) { ClaudeCode.discover() }.value
            if !firstRun { reloadConfig() }
            var cfg = config
            let added = ClaudeCode.merge(found, into: &cfg)
            config = cfg
            if added > 0 || firstRun { save() }
            scanning = false
            if firstRun {
                notice = nil
            } else {
                notice = added == 0 ? "No new Claude Code logins found"
                    : "Added \(added) account\(added == 1 ? "" : "s")"
            }
            refresh()
        }
    }
}
