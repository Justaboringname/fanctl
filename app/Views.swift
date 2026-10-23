// Popover contents for each menu bar module.
import SwiftUI
import Charts
import ServiceManagement

enum Module: String, CaseIterable, Identifiable {
    case network, cpu, gpu, memory, sensors  // menu bar order, left to right
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "内存"
        case .network: "网络"
        case .sensors: "传感器"
        }
    }
    var showsProcesses: Bool { self == .cpu || self == .memory }
}

// MARK: - building blocks

/// The sample under the pointer on a history chart. ObservableObject + @StateObject: @State is a
/// macro in the macOS 27 SDK and a Command Line Tools build cannot expand it.
final class ChartHover: ObservableObject {
    /// Render tool only: draw every chart as if hovered at this fraction (0…1) of its samples.
    static var preview: Double?
    @Published private(set) var index: Int?
    /// @Published fires on every assignment, so skip the per-pixel no-ops (each one redraws the chart).
    func set(_ i: Int?) { if i != index { index = i } }
    func shown(count: Int) -> Int? {
        guard count > 0 else { return nil }
        if let i = index { return min(i, count - 1) }
        return ChartHover.preview.map { Int(($0 * Double(count - 1)).rounded()) }
    }
}

/// Tracks the pointer over a chart — hovering, or dragging with the button down — and draws the
/// readout beside the hovered sample. Lives in .chartOverlay, so it never changes the chart's size
/// (a size change would resize, and re-anchor, the popover).
private struct HoverLayer<Readout: View>: View {
    let proxy: ChartProxy
    let count: Int
    @ObservedObject var hover: ChartHover
    @ViewBuilder let readout: (Int) -> Readout

    var body: some View {
        GeometryReader { geo in
            let plot = proxy.plotFrame.map { geo[$0] } ?? CGRect(origin: .zero, size: geo.size)
            ZStack(alignment: .topLeading) {
                PointerTracker { x in if let x { pick(x, plot) } else { hover.set(nil) } }
                if let i = hover.shown(count: count), let x = proxy.position(forX: i) {
                    BesideX(x: plot.minX + x, area: plot) { readout(i) }.allowsHitTesting(false)
                }
            }
        }
    }

    private func pick(_ x: CGFloat, _ plot: CGRect) {
        // Round, not truncate: the nearest sample, not the one to the left. Clamp so the empty
        // right-hand part of a not yet full history reads the newest sample.
        guard count > 0, let v = proxy.value(atX: x - plot.minX, as: Double.self) else { return }
        hover.set(min(max(Int(v.rounded()), 0), count - 1))
    }
}

/// Reports the pointer's x while it hovers over (or drags across) the view; nil when it leaves.
/// AppKit tracking area with .activeAlways rather than SwiftUI's onContinuousHover: clicking a status
/// item does not make this accessory app active (the previous app stays frontmost), and SwiftUI
/// hover only fires in the active app — measured: drag worked, hover never did.
private struct PointerTracker: NSViewRepresentable {
    let onMove: (CGFloat?) -> Void

    func makeNSView(context: Context) -> TrackingView { TrackingView() }
    func updateNSView(_ v: TrackingView, context: Context) { v.onMove = onMove }

    final class TrackingView: NSView {
        var onMove: ((CGFloat?) -> Void)?
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        private func report(_ e: NSEvent) { onMove?(convert(e.locationInWindow, from: nil).x) }
        override func mouseEntered(with e: NSEvent) { report(e) }
        override func mouseMoved(with e: NSEvent) { report(e) }
        override func mouseDown(with e: NSEvent) { report(e) }
        override func mouseDragged(with e: NSEvent) { report(e) }
        override func mouseExited(with e: NSEvent) { onMove?(nil) }
    }
}

/// Places its one subview at the top of `area`, just right of x — or left of it when it would not
/// fit — and never outside `area`.
private struct BesideX: Layout {
    let x: CGFloat, area: CGRect

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let label = subviews.first else { return }
        let size = label.sizeThatFits(.unspecified), gap: CGFloat = 5
        var left = x + gap
        if left + size.width > area.maxX { left = x - gap - size.width }
        left = max(area.minX, min(left, area.maxX - size.width))
        label.place(at: CGPoint(x: bounds.minX + left, y: bounds.minY + area.minY + 2),
                    anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}

/// The hover label: the value line(s), then when the sample was taken.
private struct ReadoutBox<Values: View>: View {
    let when: String
    @ViewBuilder let values: Values
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            values.font(.system(size: 11, weight: .semibold).monospacedDigit())
            Text(when).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 5).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(.background).shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5))
        .fixedSize()
    }
}

/// A line's drawable points: the finite values, each tagged with its run of consecutive finite
/// values. Each run is its own chart series, so a gap (Mac asleep, app not running) breaks the line
/// instead of bridging it; a run of one point gets a dot, since a one-point line draws nothing.
private struct Drawn { let i: Int, run: Int, lone: Bool }

private func drawable(_ v: [Double]) -> [Drawn] {
    var out: [Drawn] = [], run = 0
    for (i, x) in v.enumerated() {
        if x.isFinite {
            let lone = !(v[safe: i - 1]?.isFinite ?? false) && !(v[safe: i + 1]?.isFinite ?? false)
            out.append(Drawn(i: i, run: run, lone: lone))
        } else if v[safe: i - 1]?.isFinite ?? false { run += 1 }
    }
    return out
}

/// Top of a chart's y axis: headroom above the highest value or peak.
private func chartTop(_ lines: ChartLine...) -> Double {
    let all = lines.flatMap { $0.values + ($0.peaks ?? []) }.filter(\.isFinite)
    return max(all.max() ?? 0, 0.0001) * 1.15
}

struct HistoryChart: View {
    let line: ChartLine
    var color: Color = .accentColor
    var maxValue: Double? = nil
    var format: (Double) -> String = { String(format: "%.0f", $0) }
    @StateObject private var hover = ChartHover()

    var body: some View {
        let values = line.values, peaks = line.peaks
        let top = maxValue ?? chartTop(line)
        let hovered = hover.shown(count: values.count)
        Chart {
            ForEach(drawable(values), id: \.i) { p in
                if let peaks {
                    // Long ranges: the line is each point's mean, the faint band above it reaches the
                    // peak within that point's time span (a 24 h mean alone hides every spike).
                    AreaMark(x: .value("t", p.i), yStart: .value("v", values[p.i]), yEnd: .value("v", peaks[p.i]),
                             series: .value("s", "peak\(p.run)"))
                        .foregroundStyle(color.opacity(0.13))
                }
                AreaMark(x: .value("t", p.i), y: .value("v", values[p.i]), series: .value("s", "area\(p.run)"), stacking: .unstacked)
                    .foregroundStyle(color.opacity(0.18))
                LineMark(x: .value("t", p.i), y: .value("v", values[p.i]), series: .value("s", "line\(p.run)"))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.3))
                if p.lone {
                    PointMark(x: .value("t", p.i), y: .value("v", values[p.i])).foregroundStyle(color).symbolSize(8)
                }
            }
            if let i = hovered {
                RuleMark(x: .value("t", i)).foregroundStyle(Color.primary.opacity(0.3)).lineStyle(StrokeStyle(lineWidth: 1))
                if values[i].isFinite {
                    PointMark(x: .value("t", i), y: .value("v", values[i])).foregroundStyle(color).symbolSize(22)
                }
            }
        }
        .chartXScale(domain: 0...max(line.slots - 1, values.count - 1))
        .chartYScale(domain: 0...top)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, top / 2, top]) { v in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { if let d = v.as(Double.self) { Text(format(d)).font(.system(size: 8)) } }
            }
        }
        .chartOverlay { proxy in
            HoverLayer(proxy: proxy, count: values.count, hover: hover) { i in
                ReadoutBox(when: line.when(i)) {
                    if !values[i].isFinite {
                        Text("无数据").foregroundStyle(.secondary)
                    } else if let p = peaks?[i] {
                        HStack(spacing: 6) {
                            Text("平均 \(format(values[i]))")
                            Text("峰值 \(format(p))").foregroundStyle(.secondary)
                        }
                    } else {
                        Text(format(values[i]))
                    }
                }
            }
        }
        .frame(height: 54)
    }
}

/// Two series on one chart. The names label the hover readout (the network popover has no colour
/// legend, so the readout must say which line is which).
struct DualChart: View {
    let a: ChartLine, b: ChartLine
    let aName: String, bName: String
    var aColor: Color = .blue, bColor: Color = .orange
    var format: (Double) -> String
    @StateObject private var hover = ChartHover()

    var body: some View {
        let top = chartTop(a, b)
        let count = max(a.values.count, b.values.count)
        let hovered = hover.shown(count: count)
        Chart {
            ForEach(drawable(a.values), id: \.i) { p in
                if let peaks = a.peaks {
                    AreaMark(x: .value("t", p.i), yStart: .value("v", a.values[p.i]), yEnd: .value("v", peaks[p.i]),
                             series: .value("s", "\(aName)peak\(p.run)"))
                        .foregroundStyle(aColor.opacity(0.12))
                }
                LineMark(x: .value("t", p.i), y: .value("v", a.values[p.i]), series: .value("s", "\(aName)\(p.run)"))
                    .foregroundStyle(aColor).lineStyle(StrokeStyle(lineWidth: 1.3))
                if p.lone { PointMark(x: .value("t", p.i), y: .value("v", a.values[p.i])).foregroundStyle(aColor).symbolSize(8) }
            }
            ForEach(drawable(b.values), id: \.i) { p in
                if let peaks = b.peaks {
                    AreaMark(x: .value("t", p.i), yStart: .value("v", b.values[p.i]), yEnd: .value("v", peaks[p.i]),
                             series: .value("s", "\(bName)peak\(p.run)"))
                        .foregroundStyle(bColor.opacity(0.12))
                }
                LineMark(x: .value("t", p.i), y: .value("v", b.values[p.i]), series: .value("s", "\(bName)\(p.run)"))
                    .foregroundStyle(bColor).lineStyle(StrokeStyle(lineWidth: 1.3))
                if p.lone { PointMark(x: .value("t", p.i), y: .value("v", b.values[p.i])).foregroundStyle(bColor).symbolSize(8) }
            }
            if let i = hovered {
                RuleMark(x: .value("t", i)).foregroundStyle(Color.primary.opacity(0.3)).lineStyle(StrokeStyle(lineWidth: 1))
                if let v = a.values[safe: i], v.isFinite {
                    PointMark(x: .value("t", i), y: .value("v", v)).foregroundStyle(aColor).symbolSize(22)
                }
                if let v = b.values[safe: i], v.isFinite {
                    PointMark(x: .value("t", i), y: .value("v", v)).foregroundStyle(bColor).symbolSize(22)
                }
            }
        }
        .chartXScale(domain: 0...max(a.slots - 1, count - 1))
        .chartYScale(domain: 0...top)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, top / 2, top]) { v in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { if let d = v.as(Double.self) { Text(format(d)).font(.system(size: 8)) } }
            }
        }
        .chartOverlay { proxy in
            HoverLayer(proxy: proxy, count: count, hover: hover) { i in
                ReadoutBox(when: (a.values.count >= b.values.count ? a : b).when(i)) {
                    if a.peaks != nil || b.peaks != nil {
                        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 1) {
                            GridRow {
                                Text("平均")
                                entry(aName, aColor, a.values[safe: i])
                                entry(bName, bColor, b.values[safe: i])
                            }
                            GridRow {
                                Text("峰值")
                                entry(aName, nil, a.peaks?[safe: i])
                                entry(bName, nil, b.peaks?[safe: i])
                            }
                            .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack(spacing: 8) {
                            entry(aName, aColor, a.values[safe: i])
                            entry(bName, bColor, b.values[safe: i])
                        }
                    }
                }
            }
        }
        .frame(height: 54)
    }

    /// One series' value in the readout. The dot (its line colour) is drawn once, on the first row;
    /// the 峰值 row passes nil and gets a same-width blank in its place.
    private func entry(_ name: String, _ color: Color?, _ v: Double?) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color ?? .clear).frame(width: 6, height: 6)
            Text(name).foregroundStyle(.secondary)
            Text(v.map { $0.isFinite ? format($0) : "–" } ?? "–")
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// One headline number: a label above its value, which sits in a glass box when alerting.
struct Stat {
    let label: String, value: String
    var level: Level
    init(_ label: String, _ value: String, _ level: Level = .normal) { self.label = label; self.value = value; self.level = level }
}

/// Popover header: title, then each headline number in its own labelled column (usage and power
/// are never run together). `columnWidth` fixes the columns' width, for a popover that lines
/// other numbers up under them (otherwise each column moves whenever a value's width changes).
struct StatHeader: View {
    static let spacing: CGFloat = 16
    static let valueFont = Font.system(size: 15, weight: .semibold).monospacedDigit()
    let title: String
    let stats: [Stat]
    var columnWidth: CGFloat? = nil
    var body: some View {
        HStack(alignment: .bottom) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            HStack(alignment: .bottom, spacing: Self.spacing) {
                ForEach(stats.indices, id: \.self) { i in
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(stats[i].label).font(.system(size: 9.5)).foregroundStyle(.secondary)
                        AlertValue(text: stats[i].value, level: stats[i].level).font(Self.valueFont)
                    }
                    .frame(minWidth: columnWidth, alignment: .trailing)
                }
            }
        }
    }
}

/// A value in its alert box: the same clear Liquid Glass as the menu bar item. The padding
/// grows the glass past the text and the negative padding gives that space back, so switching it on
/// or off never moves the text or resizes the popover.
struct AlertValue: View {
    /// Render tool only: cacheDisplay cannot capture glass (the whole header row comes out blank),
    /// so draw the flat fallback instead.
    static var flat = false
    let text: String, level: Level
    var body: some View {
        if level == .normal {
            Text(text)
        } else if #available(macOS 26, *), !Self.flat {
            Text(text).padding(.horizontal, 5).padding(.vertical, 1)
                .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, -5).padding(.vertical, -1)
        } else {
            Text(text).background {
                RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: AlertBoxes.flatFill)).padding(.horizontal, -5).padding(.vertical, -1)
            }
        }
    }
}

struct Row: View {
    let label: String, value: String
    var color: Color? = nil
    var body: some View {
        HStack(spacing: 6) {
            if let color { Circle().fill(color).frame(width: 7, height: 7) }
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.system(size: 11.5))
    }
}

struct Section<Content: View>: View {
    let title: String
    var note: String? = nil
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if let note { Text(note).font(.system(size: 9.5)).foregroundStyle(.tertiary) }
            }
            content
        }
    }
}

struct ProcList: View {
    let rows: [Proc]
    let format: (Double) -> String
    var body: some View {
        VStack(spacing: 2) {
            ForEach(rows) { p in
                HStack {
                    Text(p.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(format(p.value)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.system(size: 11.5))
            }
            if rows.isEmpty { Text("采样中…").font(.system(size: 11)).foregroundStyle(.tertiary) }
        }
    }
}

struct CoreBars: View {
    let cores: [Core]
    let clusters: [Cluster]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(clusters) { cl in
                HStack(spacing: 6) {
                    Text(cl.name).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(cores.filter { $0.cluster == cl.id }) { c in
                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 1.5).fill(.quaternary)
                                RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor)
                                    .frame(height: max(1, 26 * c.busy))
                            }
                            .frame(width: 9, height: 26)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - modules

struct CPUView: View {
    @ObservedObject var s: Sampler
    @ObservedObject var settings: Settings
    var body: some View {
        let n = s.now, r = settings.range
        VStack(alignment: .leading, spacing: 10) {
            StatHeader(title: "CPU", stats: [Stat("占用率", Fmt.pct(n.cpuTotal)), Stat("功耗", Fmt.watts(n.cpuW), n.cpuLevel)])
            HistoryChart(line: s.line(.cpu, r), maxValue: 1, format: { Fmt.pct($0) })
            HStack(spacing: 14) {
                Row(label: "用户", value: Fmt.pct(n.cpuUser), color: .accentColor)
                Row(label: "系统", value: Fmt.pct(n.cpuSystem), color: .red)
                Row(label: "空闲", value: Fmt.pct(max(0, 1 - n.cpuTotal)))
            }
            Section(title: "核心") {
                CoreBars(cores: n.cores, clusters: n.clusters)
                ForEach(n.clusters) { cl in
                    Row(label: "\(cl.name) ×\(cl.count)", value: "\(Fmt.pct(cl.busy))   \(Fmt.watts(cl.watts))")
                }
            }
            Section(title: "功耗", note: "IOReport") {
                HistoryChart(line: s.line(.cpuW, r), color: .orange, format: { Fmt.watts($0) })
            }
            Section(title: "CPU 占用最高", note: "仅当前用户进程") {
                ProcList(rows: s.procs.byCPU) { Fmt.pct($0) }
            }
            Section(title: "功耗最高", note: "CPU 能耗 · 仅当前用户进程") {
                ProcList(rows: s.procs.byPower) { Fmt.watts($0) }
            }
            LoadRow()
        }
    }
}

struct LoadRow: View {
    var body: some View {
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        let up = ProcessInfo.processInfo.systemUptime
        let d = Int(up) / 86400, h = Int(up) % 86400 / 3600, m = Int(up) % 3600 / 60
        return HStack {
            Text(String(format: "负载 %.2f  %.2f  %.2f", load[0], load[1], load[2]))
            Spacer()
            Text(d > 0 ? "运行 \(d) 天 \(h) 小时" : "运行 \(h) 小时 \(m) 分")
        }
        .font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
    }
}

struct GPUView: View {
    @ObservedObject var s: Sampler
    @ObservedObject var settings: Settings
    var body: some View {
        let n = s.now, r = settings.range
        VStack(alignment: .leading, spacing: 10) {
            StatHeader(title: "GPU", stats: [Stat("占用率", Fmt.pct(n.gpuUtil)), Stat("功耗", Fmt.watts(n.gpuW), n.gpuLevel)])
            HistoryChart(line: s.line(.gpu, r), color: .purple, maxValue: 1, format: { Fmt.pct($0) })
            VStack(spacing: 3) {
                Row(label: "渲染器", value: Fmt.pct(n.gpuRenderer))
                Row(label: "Tiler", value: Fmt.pct(n.gpuTiler))
                Row(label: "非关断时间占比", value: Fmt.pct(n.gpuActive))
                Row(label: "占用统一内存", value: Fmt.bytes(n.gpuMem))
            }
            Section(title: "功耗", note: "IOReport") {
                HistoryChart(line: s.line(.gpuW, r), color: .orange, format: { Fmt.watts($0) })
            }
        }
    }
}

struct MemoryView: View {
    @ObservedObject var s: Sampler
    @ObservedObject var settings: Settings
    var body: some View {
        let n = s.now, r = settings.range
        let pressure: (String, Color) = n.memLevel == .critical ? ("严重", .red) : n.memLevel == .warn ? ("警告", .yellow) : ("正常", .green)
        VStack(alignment: .leading, spacing: 10) {
            StatHeader(title: "内存", stats: [Stat("压力", Fmt.pct(n.memPressure), n.memLevel),
                                              Stat("已用", "\(Fmt.bytes(n.memUsed)) / \(Fmt.bytes(n.memTotal))"),
                                              Stat("DRAM 功耗", Fmt.watts(n.dramW))])
            // Activity Monitor's pressure graph: height = 100 − kern.memorystatus_level, colour = level.
            HistoryChart(line: s.line(.mem, r), color: pressure.1, maxValue: 1, format: { Fmt.pct($0) })
            VStack(spacing: 3) {
                Row(label: "内存压力", value: "\(Fmt.pct(n.memPressure)) · \(pressure.0)", color: pressure.1)
                Row(label: "App 内存", value: Fmt.bytes(n.memApp), color: .blue)
                Row(label: "联动内存", value: Fmt.bytes(n.memWired), color: .orange)
                Row(label: "被压缩", value: Fmt.bytes(n.memCompressed), color: .purple)
                Row(label: "已缓存文件", value: Fmt.bytes(n.memCached))
                Row(label: "交换", value: "\(Fmt.bytes(n.swapUsed)) / \(Fmt.bytes(n.swapTotal))")
            }
            Section(title: "DRAM 功耗", note: "IOReport") {
                HStack { Spacer(); Text(Fmt.watts(n.dramW)).font(.system(size: 11.5).monospacedDigit()) }
                HistoryChart(line: s.line(.dramW, r), color: .orange, format: { Fmt.watts($0) })
            }
            Section(title: "内存占用最高", note: "仅当前用户进程") {
                ProcList(rows: s.procs.byMemory) { Fmt.bytes(UInt64($0)) }
            }
        }
    }
}

struct NetworkView: View {
    @ObservedObject var s: Sampler
    @ObservedObject var settings: Settings
    /// Width of the header's rate columns: the widest Fmt.rate below 1 GB/s (digits are monospaced).
    /// Fixed, so the totals at the bottom stay right under the rates.
    private static let column = ceil(("888.8 MB/s" as NSString).size(withAttributes:
        [.font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)]).width)

    var body: some View {
        let n = s.now
        VStack(alignment: .leading, spacing: 10) {
            StatHeader(title: "网络", stats: [Stat("↓ 下载", Fmt.rate(n.rx)), Stat("↑ 上传", Fmt.rate(n.tx))],
                       columnWidth: Self.column)
            HStack(spacing: 14) {
                Row(label: "接口", value: n.netIface.isEmpty ? "未连接" : n.netIface)
                Row(label: "IP", value: n.netIP.isEmpty ? "–" : n.netIP)
            }
            DualChart(a: s.line(.rx, settings.range), b: s.line(.tx, settings.range), aName: "↓", bName: "↑", format: { Fmt.rate($0) })
            Section(title: "本次启动以来") {
                HStack(spacing: StatHeader.spacing) {
                    Spacer(minLength: 0)
                    total("↓", n.rxTotal)
                    total("↑", n.txTotal)
                }
            }
        }
    }

    /// Arrow beside its total, right-aligned in the same column as the header's rate.
    private func total(_ arrow: String, _ bytes: UInt64) -> some View {
        HStack(spacing: 4) {
            Text(arrow).foregroundStyle(.secondary)
            Text(Fmt.dataSize(bytes)).monospacedDigit()
        }
        .font(.system(size: 11.5))
        .frame(minWidth: Self.column, alignment: .trailing)
    }
}

/// Segmented control that spans the full row with equal segments (SwiftUI's .segmented picker keeps
/// its intrinsic width on macOS, so it neither lines up with the rows above nor shrinks to fit).
struct FilledSegments: NSViewRepresentable {
    let labels: [String]
    let selected: Int?  // nil: no segment highlighted
    var size: NSControl.ControlSize = .regular
    let onSelect: (Int) -> Void

    func makeNSView(context: Context) -> NSSegmentedControl {
        let c = NSSegmentedControl(labels: labels, trackingMode: .selectOne,
                                   target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        c.controlSize = size
        c.font = .systemFont(ofSize: NSFont.systemFontSize(for: size))
        c.segmentDistribution = .fillEqually
        c.setContentHuggingPriority(.defaultLow, for: .horizontal)
        c.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return c
    }

    func updateNSView(_ c: NSSegmentedControl, context: Context) {
        context.coordinator.onSelect = onSelect
        c.selectedSegment = selected ?? -1
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelect) }

    final class Coordinator: NSObject {
        var onSelect: (Int) -> Void
        init(_ onSelect: @escaping (Int) -> Void) { self.onSelect = onSelect }
        @objc func changed(_ c: NSSegmentedControl) { if c.selectedSegment >= 0 { onSelect(c.selectedSegment) } }
    }
}

/// Popover-local UI state. Plain ObservableObject: @State is a macro in the macOS 27 SDK and its
/// plugin ships only with Xcode, so a Command Line Tools build cannot expand it.
final class FanControlState: ObservableObject {
    /// The slider's value while the user drags it. Otherwise the slider shows the fans' state.
    @Published var slider = 0.0
    @Published var dragging = false
    var dragStart = 0.0
    /// A setting just written that fanctld (polling once a second) has not echoed yet. Shown
    /// meanwhile, so the presets and the slider do not snap back to the old setting for a tick.
    @Published var pending: (setting: String, at: Date)?
    @Published var error: String?
}

struct SensorsView: View {
    @ObservedObject var s: Sampler
    @ObservedObject var ui: FanControlState
    @ObservedObject var settings: Settings

    var body: some View {
        let n = s.now, r = settings.range
        VStack(alignment: .leading, spacing: 10) {
            StatHeader(title: "传感器", stats: [Stat("CPU", Fmt.temp(n.cpuTemp), n.cpuTempLevel), Stat("GPU", Fmt.temp(n.gpuTemp), n.gpuTempLevel),
                                               Stat("Mac 本体", Fmt.watts(n.bodyW))])
            Section(title: "温度") {
                Row(label: "CPU（最高 / 平均）", value: "\(Fmt.temp(n.cpuTemp)) / \(Fmt.temp(n.cpuTempAvg))", color: .blue)
                Row(label: "GPU（最高 / 平均）", value: "\(Fmt.temp(n.gpuTemp)) / \(Fmt.temp(n.gpuTempAvg))", color: .purple)
                // The chart plots the CPU and GPU rows (blue/purple), so it sits right under them; SSD
                // below it, or the chart read as the SSD's.
                DualChart(a: s.line(.cpuTemp, r), b: s.line(.gpuTemp, r), aName: "CPU", bName: "GPU",
                          aColor: .blue, bColor: .purple, format: { String(format: "%.0f°", $0) })
                if n.ssdTemp > 0 { Row(label: "SSD", value: Fmt.temp(n.ssdTemp)) }
            }
            Section(title: "功耗", note: "本体 = 整机 − USB 口对外供电") {
                Row(label: "整机（SMC PSTR）", value: Fmt.watts(n.sysW))
                Row(label: "USB 口对外供电（台灯、键盘…）", value: Fmt.watts(n.usbW))
                Row(label: "Mac 本体", value: Fmt.watts(n.bodyW), color: .orange)
                Divider()
                Row(label: "CPU", value: Fmt.watts(n.cpuW), color: .blue)
                Row(label: "GPU", value: Fmt.watts(n.gpuW), color: .purple)
                Row(label: "神经网络引擎", value: Fmt.watts(n.aneW), color: .pink)
                Row(label: "DRAM", value: Fmt.watts(n.dramW), color: .green)
                Row(label: "其他（显示、总线、SSD、风扇…）", value: Fmt.watts(n.otherW))
                HistoryChart(line: s.line(.bodyW, r), color: .orange, format: { Fmt.watts($0) })
            }
            Section(title: "风扇") {
                ForEach(n.fans) { f in
                    Row(label: "风扇 \(f.id + 1)", value: String(format: "%.0f rpm", f.actual) + (f.manual ? "  手动" : "  自动"))
                }
                fanControls
            }
        }
    }

    @ViewBuilder private var fanControls: some View {
        if let d = s.fanDaemon {
            if let warning = warning(for: d) {
                Text(warning).font(.system(size: 11)).foregroundStyle(.orange)
            }
            let presets: [(String, String)] = [("自动", "auto"), ("30%", "30%"), ("50%", "50%"), ("70%", "70%"), ("全速", "100%")]
            // Always exactly these five segments: a sixth "自定义" one made the control wider than the
            // popover and it overflowed the right edge. A slider value (not a preset) selects none;
            // the slider and its label show it instead.
            let setting = shownSetting(d)
            FilledSegments(labels: presets.map(\.0), selected: presets.firstIndex(where: { $0.1 == setting })) {
                apply(presets[$0].1)
            }
            let position = sliderPosition(setting)
            HStack {
                Slider(value: Binding(get: { ui.dragging ? ui.slider : position },
                                      set: { beginDrag(at: position); ui.slider = $0 }), in: 0...100) { editing in
                    if editing { beginDrag(at: position) } else { endDrag() }
                }
                Text(sliderLabel(setting, position)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .trailing)
            }
            .onDisappear { ui.dragging = false }
            if let error = ui.error { Text(error).font(.system(size: 10.5)).foregroundStyle(.red) }
        } else {
            Text("调速需要后台服务 fanctld（装一次，之后无需密码）").font(.system(size: 11)).foregroundStyle(.secondary)
            Button("拷贝安装命令") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(FanDaemon.installCommand, forType: .string)
            }
        }
    }

    private func warning(for d: FanDaemon.Status) -> String? {
        if d.guardTripped { return "⚠︎ 温度超过 100 °C：风扇已全速，降到 85 °C 以下自动恢复" }
        switch d.reason {
        case "no-sensors": return "⚠︎ 读不到温度传感器，已交还系统自动控制"
        case "read-error": return "⚠︎ 读不到风扇状态，已交还系统自动控制"
        default: return nil
        }
    }

    private func shownSetting(_ d: FanDaemon.Status) -> String {
        if let p = ui.pending, p.setting != d.setting, Date().timeIntervalSince(p.at) < 5 { return p.setting }
        return d.setting
    }

    private var actualRPM: Double {
        let fans = s.now.fans
        return fans.isEmpty ? 0 : fans.map(\.actual).reduce(0, +) / Double(fans.count)
    }

    /// Where the slider rests (0…100 % of the fan's min…max range): the requested speed, or in auto
    /// the speed the firmware is running the fans at right now.
    private func sliderPosition(_ setting: String) -> Double {
        guard let f = s.now.fans.first, f.max > f.min else { return 0 }
        if setting.hasSuffix("%"), let v = Double(setting.dropLast()) { return min(max(v, 0), 100) }
        let rpm = Double(setting) ?? actualRPM  // "<rpm>" from the CLI; auto (or invalid): actual
        return min(max((rpm - f.min) / (f.max - f.min) * 100, 0), 100)
    }

    private func sliderLabel(_ setting: String, _ position: Double) -> String {
        guard let f = s.now.fans.first else { return "" }
        if !ui.dragging, setting == "auto" { return String(format: "自动 · %.0f rpm", actualRPM) }
        let pct = ui.dragging ? ui.slider : position
        return String(format: "%.0f%% ≈ %.0f rpm", pct, f.min + (f.max - f.min) * pct / 100)
    }

    /// Called from both the value setter and onEditingChanged(true); AppKit sends them in either order.
    private func beginDrag(at position: Double) {
        guard !ui.dragging else { return }
        ui.dragging = true
        ui.dragStart = position
        ui.slider = position
    }

    private func endDrag() {
        guard ui.dragging else { return }
        ui.dragging = false
        // A click that leaves the knob where it was changes nothing (it must not turn auto into manual).
        if abs(ui.slider - ui.dragStart) >= 0.5 { apply(String(format: "%.0f%%", ui.slider)) }
    }

    private func apply(_ setting: String) {
        do { try FanDaemon.apply(setting); ui.pending = (setting, Date()); ui.error = nil }
        catch { ui.pending = nil; ui.error = "写入失败：\(error.localizedDescription)" }
    }
}

// MARK: - popover shell

struct PopoverView: View {
    let module: Module
    // Not observed here: each module view observes the sampler itself. If this shell re-rendered on
    // every sample, SwiftUI would re-apply the gear menu's 刷新间隔 picker item each time (measured:
    // 4 NSMenu item changes per sample), which closes its submenu under the pointer.
    let s: Sampler
    let settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch module {
            case .cpu: CPUView(s: s, settings: settings)
            case .gpu: GPUView(s: s, settings: settings)
            case .memory: MemoryView(s: s, settings: settings)
            case .network: NetworkView(s: s, settings: settings)
            case .sensors: SensorsView(s: s, ui: s.fanUI, settings: settings)
            }
            RangePicker(settings: settings)
            Divider()
            PopoverFooter(settings: settings)
        }
        .padding(14)
        .frame(width: 320)
    }
}

/// How far back every chart reaches; one setting shared by all popovers.
struct RangePicker: View {
    @ObservedObject var settings: Settings
    var body: some View {
        FilledSegments(labels: HistoryRange.allCases.map(\.label), selected: HistoryRange.allCases.firstIndex(of: settings.range),
                       size: .small) { settings.range = HistoryRange.allCases[$0] }
    }
}

/// Gear menu + quit. Observes only the settings, so sampler updates never touch the open menu.
struct PopoverFooter: View {
    @ObservedObject var settings: Settings

    var body: some View {
        HStack {
            Menu {
                ForEach(Module.allCases) { m in
                    Toggle(m.title, isOn: Binding(get: { settings.enabled.contains(m) },
                                                  set: { settings.setEnabled(m, $0) }))
                }
                Divider()
                Picker("刷新间隔", selection: $settings.interval) {
                    Text("1 秒").tag(1.0); Text("2 秒").tag(2.0); Text("5 秒").tag(5.0)
                }
                if settings.loginNeedsApproval {
                    Button("登录时启动：需在系统设置中允许…") { SMAppService.openSystemSettingsLoginItems() }
                } else {
                    Toggle("登录时启动", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) }))
                }
            } label: { Image(systemName: "gearshape") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Spacer()
            Button("退出 StatMenu") { NSApp.terminate(nil) }.buttonStyle(.borderless).font(.system(size: 11))
        }
    }
}

@MainActor
final class Settings: ObservableObject {
    @Published private(set) var enabled: Set<Module>
    @Published var interval: Double { didSet { UserDefaults.standard.set(interval, forKey: "interval") } }
    @Published var range: HistoryRange { didSet { UserDefaults.standard.set(range.rawValue, forKey: "historyRange") } }
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// The user turned StatMenu off under System Settings › Login Items; register() cannot override that.
    @Published private(set) var loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    var onModulesChanged: (() -> Void)?

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: "modules")
        enabled = Set((saved ?? Module.allCases.map(\.rawValue)).compactMap(Module.init))
        let iv = UserDefaults.standard.double(forKey: "interval")
        interval = iv > 0 ? iv : 2
        range = UserDefaults.standard.string(forKey: "historyRange").flatMap(HistoryRange.init) ?? .hour12
    }

    func setEnabled(_ m: Module, _ on: Bool) {
        if on { enabled.insert(m) } else if enabled.count > 1 { enabled.remove(m) }  // keep at least one item
        UserDefaults.standard.set(Module.allCases.filter(enabled.contains).map(\.rawValue), forKey: "modules")
        onModulesChanged?()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
        launchAtLogin = SMAppService.mainApp.status == .enabled
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }
}
