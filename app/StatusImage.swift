// Draws the menu bar items on one line: a small tag, then each value. Template image, so it
// follows the menu bar's light/dark appearance. Everything is drawn at one opacity (mixed
// light/dark text looked patchy) at full opacity; tags are told apart by their smaller, bolder font.
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

    private enum Run { case text(NSAttributedString), image(NSImage) }

    /// Returns the image plus a signature of everything drawn in it; callers skip re-assigning an
    /// identical image, because every status item update costs macOS's MenuBarAgent CPU time.
    static func make(label: String?, symbol: String? = nil, segments: [Segment]) -> (image: NSImage, signature: String) {
        let height: CGFloat = 22
        func string(_ text: String, _ font: NSFont) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black.withAlphaComponent(alpha)])
        }
        func width(_ run: Run) -> CGFloat {
            switch run {
            case .text(let t): ceil(t.size().width)
            case .image(let i): i.size.width
            }
        }
        // Runs left to right, each with the gap before it.
        var runs: [(run: Run, gap: CGFloat)] = []
        if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) {
            runs.append((.image(img), 0))
        } else if let label {
            runs.append((.text(string(label, labelFont)), 0))
        }
        for (i, seg) in segments.enumerated() {
            // The item's tag/icon binds to the first value; each later value starts a new group.
            let gap = i > 0 ? valueGap : runs.isEmpty ? 0 : tagGap
            if let tag = seg.label {
                runs.append((.text(string(tag, labelFont)), gap))
                runs.append((.text(string(seg.text, valueFont)), tagGap))
            } else {
                runs.append((.text(string(seg.text, valueFont)), gap))
            }
        }
        let content = runs.reduce(0) { $0 + $1.gap + width($1.run) }
        let total = itemWidth(segments.first?.key ?? label ?? symbol ?? "", content)
        let signature = ([label ?? "", symbol ?? ""] + segments.map { ($0.label ?? "") + $0.text } + ["\(total)"])
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
                }
                x += width(run)
            }
            return true
        }
        drawn.isTemplate = true
        return (drawn, signature)
    }
}

enum Fmt {
    static func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

    static func watts(_ v: Double) -> String {
        guard v.isFinite else { return "–" }
        // Idle GPU/DRAM draw is tens of milliwatts, so keep two decimals below 1 W.
        // Thresholds on the rounded value, so 9.96 W reads "10W" rather than "10.0W".
        return v >= 9.95 ? String(format: "%.0fW", v) : v >= 0.995 ? String(format: "%.1fW", v) : String(format: "%.2fW", v)
    }

    static func temp(_ v: Double) -> String { v > 0 ? String(format: "%.0f°", v) : "–" }

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
