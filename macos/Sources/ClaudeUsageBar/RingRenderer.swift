import AppKit
import UsageCore

/// One ring in the menu bar.
struct RingSpec {
    enum State { case value(Double), loading, problem }
    let state: State
}

/// One account's group of rings, with optional initials in front.
struct AccountRings {
    let initials: String?
    let rings: [RingSpec]
}

/// Draws the menu bar image: for each shown account, its initials (when several are shown)
/// and one ring per limit. Colours are resolved at draw time, so the image follows a light
/// or dark menu bar.
enum RingRenderer {
    static let height: CGFloat = 22
    static let diameter: CGFloat = 17
    static let lineWidth: CGFloat = 2.3
    static let ringGap: CGFloat = 3
    static let accountGap: CGFloat = 8
    static let labelGap: CGFloat = 3

    static let labelFont = NSFont.systemFont(ofSize: 10, weight: .semibold)

    static func color(for pct: Double) -> NSColor {
        switch Severity(pct: pct) {
        case .ok: return .systemGreen
        case .warn: return .systemOrange
        case .high: return .systemRed
        }
    }

    static func image(for accounts: [AccountRings], showPercent: Bool) -> NSImage {
        let groups = accounts.isEmpty ? [AccountRings(initials: nil, rings: [RingSpec(state: .loading)])] : accounts

        var width: CGFloat = 0
        for (i, g) in groups.enumerated() {
            if i > 0 { width += accountGap }
            if let s = g.initials { width += textSize(s, font: labelFont).width + labelGap }
            width += CGFloat(g.rings.count) * diameter + CGFloat(max(0, g.rings.count - 1)) * ringGap
        }
        width = ceil(max(width, diameter))

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (i, g) in groups.enumerated() {
                if i > 0 { x += accountGap }
                if let s = g.initials {
                    let size = textSize(s, font: labelFont)
                    let attrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.labelColor]
                    (s as NSString).draw(at: NSPoint(x: x, y: (height - size.height) / 2), withAttributes: attrs)
                    x += size.width + labelGap
                }
                for (j, ring) in g.rings.enumerated() {
                    if j > 0 { x += ringGap }
                    drawRing(ring, in: NSRect(x: x, y: (height - diameter) / 2, width: diameter, height: diameter),
                             showPercent: showPercent)
                    x += diameter
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawRing(_ ring: RingSpec, in rect: NSRect, showPercent: Bool) {
        let inset = lineWidth / 2
        let circle = rect.insetBy(dx: inset, dy: inset)
        let center = NSPoint(x: circle.midX, y: circle.midY)
        let radius = circle.width / 2

        let track = NSBezierPath(ovalIn: circle)
        track.lineWidth = lineWidth
        NSColor.labelColor.withAlphaComponent(0.22).setStroke()
        track.stroke()

        var text: String?
        var textColor = NSColor.labelColor
        switch ring.state {
        case .value(let pct):
            let clamped = min(max(pct, 0), 100)
            if clamped >= 100 {
                // A 360-degree arc can collapse to nothing; draw the full circle instead.
                let full = NSBezierPath(ovalIn: circle)
                full.lineWidth = lineWidth
                color(for: pct).setStroke()
                full.stroke()
            } else if clamped > 0 {
                // Flat caps: round caps stick out and make the arc read larger than it is.
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                              endAngle: 90 - 360 * CGFloat(clamped) / 100, clockwise: true)
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .butt
                color(for: pct).setStroke()
                arc.stroke()
            }
            if showPercent { text = "\(Int(pct.rounded()))" }
        case .loading:
            text = showPercent ? "\u{00B7}" : nil
            textColor = .secondaryLabelColor
        case .problem:
            text = "!"
            textColor = .secondaryLabelColor
        }

        if let text {
            let size: CGFloat = text.count >= 3 ? 5.8 : 7.2
            let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
            let s = textSize(text, font: font)
            (text as NSString).draw(at: NSPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2),
                                    withAttributes: attrs)
        }
    }

    private static func textSize(_ s: String, font: NSFont) -> NSSize {
        (s as NSString).size(withAttributes: [.font: font])
    }

    /// The menu bar groups for the accounts the user ticked.
    static func groups(accounts: [AccountConfig], usage: [String: AccountUsage]) -> [AccountRings] {
        let labels = accounts.map { $0.short?.isEmpty == false ? $0.short! : $0.displayName }
        let auto = Format.initials(for: labels)
        return accounts.enumerated().map { i, a in
            let initials: String? = accounts.count > 1 ? (a.short?.isEmpty == false ? a.short! : auto[i]) : nil
            guard let u = usage[a.name] else {
                return AccountRings(initials: initials, rings: [RingSpec(state: .loading)])
            }
            if u.status.isProblem || u.windows.isEmpty {
                return AccountRings(initials: initials, rings: [RingSpec(state: .problem)])
            }
            let rings = a.limitKeys.compactMap { key -> RingSpec? in
                guard let pct = u.window(key).pct else { return nil }
                return RingSpec(state: .value(pct))
            }
            return AccountRings(initials: initials, rings: rings.isEmpty ? [RingSpec(state: .problem)] : rings)
        }
    }

    /// Hover text for the menu bar item.
    static func tooltip(accounts: [AccountConfig], usage: [String: AccountUsage], now: Date = Date()) -> String {
        if accounts.isEmpty { return "Claude usage: tick an account in the list to show it here" }
        return accounts.map { a in
            var lines = [a.displayName]
            if let u = usage[a.name] {
                if u.status.isProblem, let e = u.error {
                    lines.append("  \(e)")
                } else {
                    for key in a.limitKeys {
                        let w = u.window(key)
                        guard let pct = w.pct else { continue }
                        var line = "  \(key.caption): \(Format.percent(pct))"
                        if let r = w.reset { line += ", resets in \(Format.countdown(to: r, now: now))" }
                        lines.append(line)
                    }
                }
            } else {
                lines.append("  Loading\u{2026}")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }
}
