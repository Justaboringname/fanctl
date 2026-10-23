// Draws the menu bar items on one line: a small tag, then each value. Template image, so it
// follows the menu bar's light/dark appearance. Everything is drawn at one opacity (mixed
// light/dark text looked patchy) at full opacity; tags are told apart by their smaller, bolder font.
// An alerting item also reports where its glass box goes (AlertBoxes draws it).
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
        /// Warn / critical: a glass box behind the whole item, or for a tagged value (the sensors
        /// item's temperatures) behind the tag and value.
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
    /// Alert box: padding around what it encloses, height, corner radius.
    private static let boxPad: CGFloat = 5
    private static let boxHeight: CGFloat = 19
    static let boxRadius: CGFloat = 6

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

    /// An alert box behind part of the item, in the image's coordinates.
    struct Box: Equatable { let rect: NSRect; let level: Level }

    /// Returns the image, where its alert boxes go, and a signature of everything drawn; callers
    /// skip re-assigning an identical image, because every status item update costs macOS's
    /// MenuBarAgent CPU time.
    static func make(label: String?, symbol: String? = nil, segments: [Segment]) -> (image: NSImage, boxes: [Box], signature: String) {
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
        // Which alert box each part sits in (nil = none): the whole item when one of its untagged
        // values alerts (CPU, GPU, MEM: "CPU 94% 48W" in one box), otherwise a tagged value together
        // with its tag (each temperature in the sensors item is its own reading).
        let itemLevel = segments.filter { $0.label == nil }.map(\.level).max() ?? .normal
        func box(_ seg: Int?) -> (id: Int, level: Level)? {
            if itemLevel != .normal { return (0, itemLevel) }
            guard let seg, segments[seg].label != nil, segments[seg].level != .normal else { return nil }
            return (seg + 1, segments[seg].level)
        }
        // Runs left to right: the run, the gap before it, and its segment (nil = the item's tag/icon).
        var runs: [(run: Run, gap: CGFloat, seg: Int?)] = []
        if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) {
            runs.append((.image(img), 0, nil))
        } else if let label {
            runs.append((.text(string(label, labelFont)), 0, nil))
        }
        for (i, seg) in segments.enumerated() {
            // The item's tag/icon binds to the first value; each later value starts a new group.
            let gap = i > 0 ? valueGap : runs.isEmpty ? 0 : tagGap
            if let tag = seg.label {
                runs.append((.text(string(tag, labelFont)), gap, i))
                runs.append((.text(string(seg.text, valueFont)), tagGap, i))
            } else {
                runs.append((.text(string(seg.text, valueFont)), gap, i))
            }
        }
        // One shared baseline for tags and values: centring each string's own box put the smaller
        // tag higher than the digits. Centre the digits' cap height, snapped to the pixel grid.
        let baseline = (round((height - valueFont.capHeight) / 2 * 2) / 2)
        let mid = baseline + valueFont.capHeight / 2
        let boxY = round((mid - boxHeight / 2) * 2) / 2
        // Lay out left to right; a box adds its padding before its first run and after its last.
        var xs: [CGFloat] = [], x: CGFloat = 0
        var boxes: [Box] = []
        for (k, r) in runs.enumerated() {
            let here = box(r.seg), before = k > 0 ? box(runs[k - 1].seg) : nil
            if before != nil, before?.id != here?.id { x += boxPad }  // close the previous box
            x += r.gap
            if let here, before?.id != here.id {
                x += boxPad
                boxes.append(Box(rect: NSRect(x: x - boxPad, y: boxY, width: 0, height: boxHeight), level: here.level))
            }
            xs.append(x)
            x += width(r.run)
            if here != nil {
                let b = boxes.removeLast()
                boxes.append(Box(rect: NSRect(x: b.rect.minX, y: boxY, width: x + boxPad - b.rect.minX, height: boxHeight), level: b.level))
            }
        }
        if let last = runs.last, box(last.seg) != nil { x += boxPad }
        let total = itemWidth(segments.first?.key ?? label ?? symbol ?? "", x)
        let signature = ([label ?? "", symbol ?? ""] + segments.map { ($0.label ?? "") + $0.text + "\($0.level.rawValue)" } + ["\(total)"])
            .joined(separator: "|")

        let drawn = NSImage(size: NSSize(width: total, height: height), flipped: false) { _ in
            for (k, r) in runs.enumerated() {
                switch r.run {
                case .text(let t):
                    // Without .usesLineFragmentOrigin the rect's origin is the baseline of the line.
                    t.draw(with: NSRect(x: xs[k], y: baseline, width: 1000, height: height), options: [])
                case .image(let img):
                    img.draw(in: NSRect(x: xs[k], y: round((mid - img.size.height / 2) * 2) / 2,
                                        width: img.size.width, height: img.size.height))
                }
            }
            return true
        }
        drawn.isTemplate = true
        return (drawn, boxes, signature)
    }
}

/// The alert boxes of one status item: untinted clear Liquid Glass (NSGlassEffectView, macOS 26+)
/// with a thin red rim, placed behind the status button in its superview, so the item's text stays
/// the menu bar's own template rendering on top. Picked live by the user over tinting the glass
/// itself (yellow / red / pink washes all looked muddy over the wallpaper) and over coloured text.
/// Older systems get a faint translucent rectangle with the same rim.
@MainActor
final class AlertBoxes {
    private let button: NSStatusBarButton
    private var views: [NSView] = []
    private var boxes: [StatusImage.Box] = []
    private var imageSize = NSSize.zero
    private var observer: NSObjectProtocol?

    init(button: NSStatusBarButton) {
        self.button = button
        // The button resizes after its image changes (and the item moves when others change width);
        // keep the boxes under the text.
        button.postsFrameChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: button,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
    }

    /// `boxes` are in the coordinates of an image of `imageSize`, which the button draws centred.
    func show(_ boxes: [StatusImage.Box], imageSize: NSSize) {
        self.imageSize = imageSize
        if boxes.count != views.count {
            views.forEach { $0.removeFromSuperview() }
            views = boxes.map { _ in Self.makeView() }
        }
        self.boxes = boxes
        layout()
    }

    func removeAll() { show([], imageSize: imageSize) }

    private func layout() {
        // A just-created status item's button may not be in its window yet; attach once it is.
        guard let host = button.superview else { return }
        let origin = NSPoint(x: button.frame.minX + round((button.bounds.width - imageSize.width) / 2),
                             y: button.frame.minY + round((button.bounds.height - imageSize.height) / 2))
        for (v, box) in zip(views, boxes) {
            if v.superview !== host { host.addSubview(v, positioned: .below, relativeTo: button) }
            let rect = box.rect.offsetBy(dx: origin.x, dy: origin.y)
            if v.frame != rect {
                v.frame = rect
                v.subviews.forEach { $0.frame = v.bounds }
            }
        }
    }

    static let rim = NSColor.systemRed.withAlphaComponent(0.9)
    static let rimWidth: CGFloat = 1.7  // 1.2 + one Retina pixel, at the user's request
    /// Pre-macOS 26 stand-in for the glass, also used by the render tool (it cannot capture glass).
    static let flatFill = NSColor.white.withAlphaComponent(0.22)

    /// The glass with the rim on top, both filling a container that `layout()` positions.
    private static func makeView() -> NSView {
        let radius = StatusImage.boxRadius
        let box = NSView()
        let glass: NSView
        if #available(macOS 26, *) {
            let g = NSGlassEffectView()
            g.style = .clear
            g.cornerRadius = radius
            glass = g
        } else {
            glass = NSView()
            glass.wantsLayer = true
            glass.layer?.backgroundColor = flatFill.cgColor
            glass.layer?.cornerRadius = radius
        }
        let edge = NSView()
        edge.wantsLayer = true
        edge.layer?.cornerRadius = radius
        edge.layer?.borderWidth = rimWidth
        edge.layer?.borderColor = rim.cgColor
        for v in [glass, edge] {
            v.autoresizingMask = [.width, .height]
            box.addSubview(v)
        }
        return box
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
