import Foundation

public enum Format {
    /// "2h 14m", "3d 4h", "12m", "now".
    public static func countdown(to date: Date, now: Date = Date()) -> String {
        let secs = Int(date.timeIntervalSince(now))
        if secs <= 0 { return "now" }
        let mins = (secs + 59) / 60
        let days = mins / 1440, hours = (mins % 1440) / 60, m = mins % 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return m > 0 ? "\(hours)h \(m)m" : "\(hours)h" }
        return "\(m)m"
    }

    /// "15:00" today, else "Thu 15:00" (12- or 24-hour as the Mac is set).
    public static func resetTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.calendar = calendar
        if calendar.isDate(date, inSameDayAs: now) {
            f.setLocalizedDateFormatFromTemplate("jmm")
        } else {
            f.setLocalizedDateFormatFromTemplate("EEEjmm")
        }
        return f.string(from: date)
    }

    public static func resetLine(_ date: Date, now: Date = Date()) -> String {
        if date <= now { return "Resetting now" }
        return "Resets in \(countdown(to: date, now: now)) \u{00B7} \(resetTime(date, now: now))"
    }

    public static func percent(_ pct: Double) -> String {
        "\(Int(pct.rounded()))%"
    }

    /// One or two letters per label: the first letter, or the first two where first letters clash.
    /// A label like "me@work.com" uses the part before the @.
    public static func initials(for labels: [String]) -> [String] {
        func letters(_ label: String) -> [Character] {
            let base = label.split(separator: "@").first.map(String.init) ?? label
            return base.filter { $0.isLetter || $0.isNumber }.compactMap { $0.uppercased().first }
        }
        let firsts = labels.map { letters($0).first.map(String.init) ?? "?" }
        return labels.enumerated().map { i, label in
            let clash = firsts.enumerated().contains { j, f in j != i && f == firsts[i] }
            let l = letters(label)
            if clash && l.count >= 2 { return String(l[0]) + String(l[1]).lowercased() }
            return firsts[i]
        }
    }
}
