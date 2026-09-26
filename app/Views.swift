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

/// The hover label: the value line(s), then how long ago the sample was taken.
private struct ReadoutBox<Values: View>: View {
    let age: TimeInterval
    @ViewBuilder let values: Values
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            values.font(.system(size: 11, weight: .semibold).monospacedDigit())
            Text(Fmt.age(age)).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 5).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(.background).shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5))
        .fixedSize()
    }
}

struct HistoryChart: View {
    let series: Series
    var color: Color = .accentColor
    var maxValue: Double? = nil
    var format: (Double) -> String = { String(format: "%.0f", $0) }
    @StateObject private var hover = ChartHover()

    var body: some View {
        let values = series.values
        let top = maxValue ?? max(values.max() ?? 0, 0.0001) * 1.15
        let hovered = hover.shown(count: values.count)
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { point in
                AreaMark(x: .value("t", point.offset), y: .value("v", point.element))
                    .foregroundStyle(color.opacity(0.18))
                LineMark(x: .value("t", point.offset), y: .value("v", point.element))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.3))
            }
            if let i = hovered {
                RuleMark(x: .value("t", i)).foregroundStyle(Color.primary.opacity(0.3)).lineStyle(StrokeStyle(lineWidth: 1))
                if values[i].isFinite {
                    PointMark(x: .value("t", i), y: .value("v", values[i])).foregroundStyle(color).symbolSize(22)
                }
            }
        }
        .chartXScale(domain: 0...max(Series.capacity - 1, values.count - 1))
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
                ReadoutBox(age: series.age(i)) { Text(values[i].isFinite ? format(values[i]) : "–") }
            }
        }
        .frame(height: 54)
    }
}

/// Two series on one chart. The names label the hover readout (the network popover has no colour
/// legend, so the readout must say which line is which).
struct DualChart: View {
    let a: Series, b: Series
    let aName: String, bName: String
    var aColor: Color = .blue, bColor: Color = .orange
    var format: (Double) -> String
    @StateObject private var hover = ChartHover()

    var body: some View {
        let top = max(a.values.max() ?? 0, b.values.max() ?? 0, 0.0001) * 1.15
        let count = max(a.values.count, b.values.count)
        let hovered = hover.shown(count: count)
        Chart {
            ForEach(Array(a.values.enumerated()), id: \.offset) { p in
                LineMark(x: .value("t", p.offset), y: .value("v", p.element), series: .value("s", aName))
                    .foregroundStyle(aColor).lineStyle(StrokeStyle(lineWidth: 1.3))
            }
            ForEach(Array(b.values.enumerated()), id: \.offset) { p in
                LineMark(x: .value("t", p.offset), y: .value("v", p.element), series: .value("s", bName))
                    .foregroundStyle(bColor).lineStyle(StrokeStyle(lineWidth: 1.3))
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
        .chartXScale(domain: 0...max(Series.capacity - 1, count - 1))
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
                ReadoutBox(age: (a.values.count >= b.values.count ? a : b).age(i)) {
                    HStack(spacing: 8) {
                        entry(aName, aColor, a.values[safe: i])
                        entry(bName, bColor, b.values[safe: i])
                    }
                }
            }
        }
        .frame(height: 54)
    }

    private func entry(_ name: String, _ color: Color, _ v: Double?) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(name).foregroundStyle(.secondary)
            Text(v.map { $0.isFinite ? format($0) : "–" } ?? "–")
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Popover header: title, then each headline number in its own labelled column (usage and power
/// are never run together).
struct StatHeader: View {
    let title: String
    let stats: [(label: String, value: String)]
    var body: some View {
        HStack(alignment: .bottom) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer()
            HStack(alignment: .bottom, spacing: 16) {
                ForEach(stats.indices, id: \.self) { i in
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(stats[i].label).font(.system(size: 9.5)).foregroundStyle(.secondary)
                        Text(stats[i].value).font(.system(size: 15, weight: .semibold).monospacedDigit())
                    }
                }
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
    var body: some View {
        let n = s.now
        VStack(alignment: .leading, spacing: 10) {
            StatHeader(title: "CPU", stats: [("占用率", Fmt.pct(n.cpuTotal)), ("功耗", Fmt.watts(n.cpuW))])
            HistoryChart(series: s.history.cpu, maxValue: 1, format: { Fmt.pct($0) })
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
                HistoryChart(series: s.history.cpuW, color: .orange, format: { Fmt.watts($0) })
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
    var body: some View {
        let n = s.now
        VStack(alignment: .leading, spacing: 10) {
            StatHeader(title: "GPU", stats: [("占用率", Fmt.pct(n.gpuUtil)), ("功耗", Fmt.watts(n.gpuW))])
            HistoryChart(series: s.history.gpu, color: .purple, maxValue: 1, format: { Fmt.pct($0) })
            VStack(spacing: 3) {
                Row(label: "渲染器", value: Fmt.pct(n.gpuRenderer))
                Row(label: "Tiler", value: Fmt.pct(n.gpuTiler))
                Row(label: "非关断时间占比", value: Fmt.pct(n.gpuActive))
                Row(label: "占用统一内存", value: Fmt.bytes(n.gpuMem))
            }
            Section(title: "功耗", note: "IOReport") {
                HistoryChart(series: s.history.gpuW, color: .orange, format: { Fmt.watts($0) })
            }
        }
    }
}

struct MemoryView: View {
    @ObservedObject var s: Sampler
    var body: some View {
        let n = s.now
        let pressure: (String, Color) = n.pressure >= 4 ? ("严重", .red) : n.pressure >= 2 ? ("警告", .yellow) : ("正常", .green)
        VStack(alignment: .leading, spacing: 10) {
            StatHeader(title: "内存", stats: [("占用率", Fmt.pct(n.memFraction)),
                                              ("已用", "\(Fmt.bytes(n.memUsed)) / \(Fmt.bytes(n.memTotal))"),
                                              ("DRAM 功耗", Fmt.watts(n.dramW))])
            HistoryChart(series: s.history.mem, color: .green, maxValue: 1, format: { Fmt.pct($0) })
            VStack(spacing: 3) {
                Row(label: "内存压力", value: pressure.0, color: pressure.1)
                Row(label: "App 内存", value: Fmt.bytes(n.memApp), color: .blue)
                Row(label: "联动内存", value: Fmt.bytes(n.memWired), color: .orange)
                Row(label: "被压缩", value: Fmt.bytes(n.memCompressed), color: .purple)
                Row(label: "已缓存文件", value: Fmt.bytes(n.memCached))
            }
            Section(title: "DRAM 功耗", note: "IOReport") {
                HStack { Spacer(); Text(Fmt.watts(n.dramW)).font(.system(size: 11.5).monospacedDigit()) }
                HistoryChart(series: s.history.dramW, color: .orange, format: { Fmt.watts($0) })
            }
            Section(title: "内存占用最高", note: "仅当前用户进程") {
                ProcList(rows: s.procs.byMemory) { Fmt.bytes(UInt64($0)) }
            }
        }
    }
}

struct NetworkView: View {
    @ObservedObject var s: Sampler
    var body: some View {
        let n = s.now
        VStack(alignment: .leading, spacing: 10) {
            StatHeader(title: "网络", stats: [("↓ 下载", Fmt.rate(n.rx)), ("↑ 上传", Fmt.rate(n.tx))])
            HStack(spacing: 14) {
                Row(label: "接口", value: n.netIface.isEmpty ? "未连接" : n.netIface)
                Row(label: "IP", value: n.netIP.isEmpty ? "–" : n.netIP)
            }
            DualChart(a: s.history.rx, b: s.history.tx, aName: "↓", bName: "↑", format: { Fmt.rate($0) })
            Section(title: "本次启动以来") {
                HStack(spacing: 14) {
                    Row(label: "↓", value: Fmt.dataSize(n.rxTotal))
                    Row(label: "↑", value: Fmt.dataSize(n.txTotal))
                }
            }
        }
    }
}

/// Segmented control that spans the full row with equal segments (SwiftUI's .segmented picker keeps
/// its intrinsic width on macOS, so it neither lines up with the rows above nor shrinks to fit).
struct FilledSegments: NSViewRepresentable {
    let labels: [String]
    let selected: Int?  // nil: no segment highlighted
    let onSelect: (Int) -> Void

    func makeNSView(context: Context) -> NSSegmentedControl {
        let c = NSSegmentedControl(labels: labels, trackingMode: .selectOne,
                                   target: context.coordinator, action: #selector(Coordinator.changed(_:)))
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

    var body: some View {
        let n = s.now
        VStack(alignment: .leading, spacing: 10) {
            StatHeader(title: "传感器", stats: [("CPU", Fmt.temp(n.cpuTemp)), ("GPU", Fmt.temp(n.gpuTemp)),
                                               ("Mac 本体", Fmt.watts(n.bodyW))])
            Section(title: "温度") {
                Row(label: "CPU（最高 / 平均）", value: "\(Fmt.temp(n.cpuTemp)) / \(Fmt.temp(n.cpuTempAvg))", color: .blue)
                Row(label: "GPU（最高 / 平均）", value: "\(Fmt.temp(n.gpuTemp)) / \(Fmt.temp(n.gpuTempAvg))", color: .purple)
                // The chart plots the CPU and GPU rows (blue/purple), so it sits right under them; SSD
                // below it, or the chart read as the SSD's.
                DualChart(a: s.history.cpuTemp, b: s.history.gpuTemp, aName: "CPU", bName: "GPU",
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
                HistoryChart(series: s.history.bodyW, color: .orange, format: { Fmt.watts($0) })
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
            case .cpu: CPUView(s: s)
            case .gpu: GPUView(s: s)
            case .memory: MemoryView(s: s)
            case .network: NetworkView(s: s)
            case .sensors: SensorsView(s: s, ui: s.fanUI)
            }
            Divider()
            PopoverFooter(settings: settings)
        }
        .padding(14)
        .frame(width: 320)
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
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// The user turned StatMenu off under System Settings › Login Items; register() cannot override that.
    @Published private(set) var loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    var onModulesChanged: (() -> Void)?

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: "modules")
        enabled = Set((saved ?? Module.allCases.map(\.rawValue)).compactMap(Module.init))
        let iv = UserDefaults.standard.double(forKey: "interval")
        interval = iv > 0 ? iv : 2
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
