import SwiftUI
import UsageCore

/// Actions the dropdown's buttons call (the same ones as the right-click menu).
struct PopoverActions {
    var refresh: () -> Void
    var scan: () -> Void
    var openConfig: () -> Void
    var openLog: () -> Void
    var quit: () -> Void
}

/// The dropdown: every account with its 5h / 7d / Fable usage and reset countdowns.
struct PopoverView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var loginItem: LoginItem
    let actions: PopoverActions

    var body: some View {
        // Re-render every 30 s so countdowns and "updated" stay current while it's open.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: context.date)
        }
        .padding(14)
        .frame(width: 330)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Claude usage").font(.headline)
                Spacer()
                if store.refreshing || store.scanning {
                    ProgressView().controlSize(.small)
                }
            }

            let accounts = store.visibleAccounts
            if accounts.isEmpty {
                Text(store.scanning
                     ? "Looking for Claude Code logins\u{2026}"
                     : "No Claude Code logins found. Sign in with claude in Terminal, then choose Scan for accounts.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(Array(accounts.enumerated()), id: \.element.name) { index, account in
                if index > 0 { Divider() }
                AccountCard(account: account, usage: store.usage[account.name], now: now) { on in
                    store.setInMenuBar(account.name, on)
                }
            }

            if let notice = store.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 10) {
                Text(updatedText(now: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: actions.refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(store.refreshing || !store.canRefreshManually(now: now))
                .help("Refresh now (at most once a minute)")

                Menu {
                    Button("Scan for accounts", action: actions.scan)
                    Toggle("Launch at login", isOn: Binding(
                        get: { loginItem.isEnabled },
                        set: { loginItem.setEnabled($0) }
                    ))
                    Divider()
                    Button("Open config file\u{2026}", action: actions.openConfig)
                    Button("Open log", action: actions.openLog)
                    Divider()
                    Button("Quit Claude Usage", action: actions.quit)
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
        }
    }

    private func updatedText(now: Date) -> String {
        if store.refreshing { return "Refreshing\u{2026}" }
        guard let last = store.lastRefresh else { return "Not updated yet" }
        let mins = Int(now.timeIntervalSince(last) / 60)
        let ago = mins < 1 ? "just now" : (mins < 60 ? "\(mins) min ago" : "\(mins / 60) h ago")
        return "Updated \(ago) \u{00B7} every \(store.config.effectiveRefreshMinutes) min"
    }
}

private struct AccountCard: View {
    let account: AccountConfig
    let usage: AccountUsage?
    let now: Date
    let onToggle: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Toggle(isOn: Binding(get: { account.menuBar == true }, set: onToggle)) {
                    Text(account.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .toggleStyle(.checkbox)
                .help("Show in the menu bar")

                Spacer(minLength: 4)

                if let plan = usage?.plan ?? account.plan {
                    Text(plan)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
            }

            if let u = usage {
                if u.status.isProblem || u.windows.isEmpty {
                    Label(u.error ?? "No usage data", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(LimitKey.allCases, id: \.self) { key in
                        let w = u.window(key)
                        if let pct = w.pct {
                            LimitRow(key: key, pct: pct, reset: w.reset, now: now)
                        }
                    }
                    if u.status == .limited {
                        Text("At the limit").font(.caption).foregroundStyle(.red)
                    }
                }
            } else {
                Text("Loading\u{2026}").font(.caption).foregroundStyle(.secondary)
            }
        }
        .help(helpText)
    }

    private var helpText: String {
        guard let u = usage, let method = u.method else { return account.displayName }
        return method == "usage-api"
            ? "Read with the free usage API"
            : "Read with a 1-token probe (this login can't use the usage API)"
    }
}

private struct LimitRow: View {
    let key: LimitKey
    let pct: Double
    let reset: Date?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(key.caption)
                    .font(.caption.weight(.medium))
                    .frame(width: 36, alignment: .leading)
                UsageBar(fraction: pct / 100, color: barColor)
                Text(Format.percent(pct))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .frame(width: 38, alignment: .trailing)
            }
            if let reset {
                Text(Format.resetLine(reset, now: now))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 44)
            }
        }
        .help(key.longName)
    }

    private var barColor: Color {
        switch Severity(pct: pct) {
        case .ok: return .green
        case .warn: return .orange
        case .high: return .red
        }
    }
}

private struct UsageBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(color).frame(width: geo.size.width * CGFloat(min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}
