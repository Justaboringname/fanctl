// Draws the menu bar items on one line: a small tag, then each value. Template image, so it
// follows the menu bar's light/dark appearance — except while a value is alerting (yellow / red box
// behind it), which needs colour. Everything is drawn at one opacity (mixed light/dark text looked
// patchy) at full opacity; tags are told apart by their smaller, bolder font.
import AppKit

@MainActor
enum StatusImage {
    struct Segment {
        let text: String
        /// Identifies the value across updates (e.g. "cpu.pct"); the item's width memory is keyed
        /// by the first segment's key.
        let key: String
        /// Small bold tag drawn right before the value ("CPU" in the sensors item).
        var label: String? = nil
        /// Warn / critical: the value sits in a yellow / red rounded box.
        var level: Level = .normal
    }

    // Values at the menu bar's own font size (13 pt, measured against the system clock's digits on
    // macOS 27) so they line up with the clock instead of looking smaller and narrower.
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
    private static let labelFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    // Spacing hierarchy: a tag hugs its value, values inside one item sit clearly apart, and items
    // are separated by the system's own (~18 pt) spacing. Every gap is fixed; any slack from the
    // width memory goes to the end of the item, never between a tag and its value.
    private static let tagGap: CGFloat = 3
    private static let valueGap: CGFloat = 8
    private static let alpha: CGFloat = 1
    /// Alert box: this much wider than the value on each side, and this tall.
    private static let boxPad: CGFloat = 3
    private static let boxHeight: CGFloat = 16

    /// Item widths: grow at once, shrink only after the content has stayed narrower for a while, so
    /// the menu bar doesn't jitter every time a digit count changes.
    private static var widths: [String: (width: CGFloat, narrowerSince: Date?)] = [:]
    private static let shrinkAfter: TimeInterval = 8

    private static func itemWidth(_ key: String, _ needed: CGFloat) -> CGFloat {
        let now = Date()
        guard var slot = widths[key], slot.width > needed else {
            widths[key] = (needed, nil)
            return needed
        }
        if slot.width - needed < 1 { slot.narrowerSince = nil }
        else if let since = slot.narrowerSince, now.timeIntervalSince(since) > shrinkAfter { slot = (needed, nil) }
        else if slot.narrowerSince == nil { slot.narrowerSince = now }
        widths[key] = slot
        return slot.width
    }

    private enum Run { case text(NSAttributedString), image(NSImage), box(NSAttributedString, NSColor) }

    /// Returns the image plus a signature of everything drawn in it; callers skip re-assigning an
    /// identical image, because every status item update costs macOS's MenuBarAgent CPU time.
    /// `appearance` is the status item button's: it picks the text colour while the image can't be
    /// a template (a value is alerting).
    static func make(label: String?, symbol: String? = nil, segments: [Segment],
                     appearance: NSAppearance? = nil) -> (image: NSImage, signature: String) {
        let height: CGFloat = 22
        let colored = segments.contains { $0.level != .normal }
        let dark = appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let ink: NSColor = colored && dark ? .white : .black  // template images are drawn black, then tinted
        func string(_ text: String, _ font: NSFont, _ color: NSColor = ink) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color.withAlphaComponent(alpha)])
        }
        /// System yellow / red in the menu bar's appearance (they differ slightly between light and dark).
        func boxFill(_ level: Level) -> NSColor {
            let c: NSColor = level == .critical ? .systemRed : .systemYellow
            var out = c
            (appearance ?? NSAppearance(named: .aqua)!).performAsCurrentDrawingAppearance { out = c.usingColorSpace(.sRGB) ?? c }
            return out
        }
        func width(_ run: Run) -> CGFloat {
            switch run {
            case .text(let t): ceil(t.size().width)
            case .image(let i): i.size.width
            case .box(let t, _): ceil(t.size().width) + 2 * boxPad
            }
        }
        // Runs left to right, each with the gap before it.
        var runs: [(run: Run, gap: CGFloat)] = []
        var config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        if colored { config = config.applying(.init(paletteColors: [ink])) }
        if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            runs.append((.image(img), 0))
        } else if let label {
            runs.append((.text(string(label, labelFont)), 0))
        }
        for (i, seg) in segments.enumerated() {
            // The item's tag/icon binds to the first value; each later value starts a new group.
            let gap = i > 0 ? valueGap : runs.isEmpty ? 0 : tagGap
            // Black on yellow, white on red: the menu bar's own text colour is unreadable on one of them.
            let value: Run = seg.level == .normal ? .text(string(seg.text, valueFont))
                : .box(string(seg.text, valueFont, seg.level == .critical ? .white : .black), boxFill(seg.level))
            if let tag = seg.label {
                runs.append((.text(string(tag, labelFont)), gap))
                runs.append((value, tagGap))
            } else {
                runs.append((value, gap))
            }
        }
        let content = runs.reduce(0) { $0 + $1.gap + width($1.run) }
        let total = itemWidth(segments.first?.key ?? label ?? symbol ?? "", content)
        let signature = ([label ?? "", symbol ?? ""] + segments.map { ($0.label ?? "") + $0.text + "\($0.level.rawValue)" }
                         + [colored ? (dark ? "dark" : "light") : "template", "\(total)"])
            .joined(separator: "|")

        // One shared baseline for tags and values: centring each string's own box put the smaller
        // tag higher than the digits. Centre the digits' cap height, snapped to the pixel grid.
        let baseline = (round((height - valueFont.capHeight) / 2 * 2) / 2)
        let drawn = NSImage(size: NSSize(width: total, height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (run, gap) in runs {
                x += gap
                switch run {
                case .text(let t):
                    // Without .usesLineFragmentOrigin the rect's origin is the baseline of the line.
                    t.draw(with: NSRect(x: x, y: baseline, width: 1000, height: height), options: [])
                case .image(let img):
                    let mid = baseline + valueFont.capHeight / 2
                    img.draw(in: NSRect(x: x, y: round((mid - img.size.height / 2) * 2) / 2,
                                        width: img.size.width, height: img.size.height))
                case .box(let t, let fill):
                    let mid = baseline + valueFont.capHeight / 2
                    fill.setFill()
                    NSBezierPath(roundedRect: NSRect(x: x, y: round((mid - boxHeight / 2) * 2) / 2, width: width(run), height: boxHeight),
                                 xRadius: 4, yRadius: 4).fill()
                    t.draw(with: NSRect(x: x + boxPad, y: baseline, width: 1000, height: height), options: [])
                }
                x += width(run)
            }
            return true
        }
        drawn.isTemplate = !colored
        return (drawn, signature)
    }
}

enum Fmt {
    static func pct(_ v: Double) -> String { v.isFinite ? String(format: "%.0f%%", v * 100) : "–" }

    static func watts(_ v: Double) -> String {
        guard v.isFinite else { return "–" }
        // Idle GPU/DRAM draw is tens of milliwatts, so keep two decimals below 1 W.
        // Thresholds on the rounded value, so 9.96 W reads "10W" rather than "10.0W".
        return v >= 9.95 ? String(format: "%.0fW", v) : v >= 0.995 ? String(format: "%.1fW", v) : String(format: "%.2fW", v)
    }

    static func temp(_ v: Double) -> String { v > 0 ? String(format: "%.0f°", v) : "–" }

    /// Age of a chart sample, for the hover readout.
    static func age(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return s < 1 ? "最新" : s < 60 ? "\(s) 秒前" : String(format: "%d 分 %02d 秒前", s / 60, s % 60)
    }

    // The system's own clock style (12/24-hour), with or without seconds.
    private static let time: [Bool: DateFormatter] = [false: DateFormatter.Style.short, true: .medium].mapValues { style in
        let f = DateFormatter()
        f.timeStyle = style
        return f
    }
    private static let interval: [Bool: DateIntervalFormatter] = [false: DateIntervalFormatter.Style.short, true: .medium].mapValues { style in
        let f = DateIntervalFormatter()
        f.dateStyle = .none
        f.timeStyle = style
        return f
    }

    /// Hover label for a long-range chart point: the clock time it spans and how long ago it ended,
    /// e.g. "昨天 下午11:50至凌晨12:00 · 14 小时前"; the newest point (still filling) reads "下午2:20 至今".
    static func span(from start: TimeInterval, to end: TimeInterval, now: TimeInterval) -> String {
        let a = Date(timeIntervalSince1970: start), b = Date(timeIntervalSince1970: end)
        let secs = end - start < 60, cal = Calendar.current
        let day = cal.isDateInYesterday(a) ? "昨天 " : ""
        guard end <= now else { return day + time[secs]!.string(from: a) + " 至今" }
        // The interval formatter adds full dates to a span that crosses midnight; join two times instead.
        let span = cal.isDate(a, inSameDayAs: b) ? interval[secs]!.string(from: a, to: b)
            : time[secs]!.string(from: a) + "至" + time[secs]!.string(from: b)
        let m = Int((now - end) / 60)
        let ago = m < 1 ? "刚刚" : m < 60 ? "\(m) 分钟前" : m % 60 == 0 ? "\(m / 60) 小时前" : "\(m / 60) 小时 \(m % 60) 分前"
        return day + span + " · " + ago
    }

    /// Network rates, 1000-based like Activity Monitor / iStat.
    static func rate(_ bytesPerSec: Double) -> String {
        switch bytesPerSec {
        case ..<1_000: return String(format: "%.0f B/s", bytesPerSec)
        case ..<1_000_000: return String(format: "%.0f KB/s", bytesPerSec / 1e3)
        case ..<1_000_000_000: return String(format: "%.1f MB/s", bytesPerSec / 1e6)
        default: return String(format: "%.2f GB/s", bytesPerSec / 1e9)
        }
    }

    static func bytes(_ b: UInt64) -> String { format(b, .memory) }

    static func dataSize(_ b: UInt64) -> String { format(b, .decimal) }

    private static func format(_ b: UInt64, _ style: ByteCountFormatter.CountStyle) -> String {
        let f = ByteCountFormatter()
        f.countStyle = style
        f.allowsNonnumericFormatting = false  // "0 KB", not "Zero KB"
        return f.string(fromByteCount: Int64(b))
    }
}
