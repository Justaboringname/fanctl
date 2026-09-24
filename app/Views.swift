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

struct HistoryChart: View {
    let values: [Double]
    var color: Color = .accentColor
    var maxValue: Double? = nil
    var format: (Double) -> String = { String(format: "%.0f", $0) }

    var body: some View {
        let top = maxValue ?? max(values.max() ?? 0, 0.0001) * 1.15
        Chart(Array(values.enumerated()), id: \.offset) { point in
            AreaMark(x: .value("t", point.offset), y: .value("v", point.element))
                .foregroundStyle(color.opacity(0.18))
            LineMark(x: .value("t", point.offset), y: .value("v", point.element))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.3))
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
        .frame(height: 54)
    }
}

struct DualChart: View {
    let a: [Double], b: [Double]
    let aName: String, bName: String
    var aColor: Color = .blue, bColor: Color = .orange
    var format: (Double) -> String

    var body: some View {
        let top = max(a.max() ?? 0, b.max() ?? 0, 0.0001) * 1.15
        Chart {
            ForEach(Array(a.enumerated()), id: \.offset) { p in
                LineMark(x: .value("t", p.offset), y: .value("v", p.element), series: .value("s", aName))
                    .foregroundStyle(aColor).lineStyle(StrokeStyle(lineWidth: 1.3))
            }
            ForEach(Array(b.enumerated()), id: \.offset) { p in
                LineMark(x: .value("t", p.offset), y: .value("v", p.element), series: .value("s", bName))
                    .foregroundStyle(bColor).lineStyle(StrokeStyle(lineWidth: 1.3))
            }
        }
        .chartXScale(domain: 0...max(Series.capacity - 1, a.count - 1))
        .chartYScale(domain: 0...top)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, top / 2, top]) { v in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel { if let d = v.as(Double.self) { Text(format(d)).font(.system(size: 8)) } }
            }
        }
        .frame(height: 54)
    }
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
            HistoryChart(values: s.history.cpu.values, maxValue: 1, format: { Fmt.pct($0) })
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
                HistoryChart(values: s.history.cpuW.values, color: .orange, format: { Fmt.watts($0) })
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
            HistoryChart(values: s.history.gpu.values, color: .purple, maxValue: 1, format: { Fmt.pct($0) })
            VStack(spacing: 3) {
                Row(label: "渲染器", value: Fmt.pct(n.gpuRenderer))
                Row(label: "Tiler", value: Fmt.pct(n.gpuTiler))
                Row(label: "非关断时间占比", value: Fmt.pct(n.gpuActive))
                Row(label: "占用统一内存", value: Fmt.bytes(n.gpuMem))
            }
            Section(title: "功耗", note: "IOReport") {
                HistoryChart(values: s.history.gpuW.values, color: .orange, format: { Fmt.watts($0) })
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
            HistoryChart(values: s.history.mem.values, color: .green, maxValue: 1, format: { Fmt.pct($0) })
            VStack(spacing: 3) {
                Row(label: "内存压力", value: pressure.0, color: pressure.1)
                Row(label: "App 内存", value: Fmt.bytes(n.memApp), color: .blue)
                Row(label: "联动内存", value: Fmt.bytes(n.memWired), color: .orange)
                Row(label: "被压缩", value: Fmt.bytes(n.memCompressed), color: .purple)
                Row(label: "已缓存文件", value: Fmt.bytes(n.memCached))
                Row(label: "交换", value: "\(Fmt.bytes(n.swapUsed)) / \(Fmt.bytes(n.swapTotal))")
            }
            Section(title: "DRAM 功耗", note: "IOReport") {
                HStack { Spacer(); Text(Fmt.watts(n.dramW)).font(.system(size: 11.5).monospacedDigit()) }
                HistoryChart(values: s.history.dramW.values, color: .orange, format: { Fmt.watts($0) })
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
            DualChart(a: s.history.rx.values, b: s.history.tx.values, aName: "rx", bName: "tx", format: { Fmt.rate($0) })
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
    @Published var slider = 50.0
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
                DualChart(a: s.history.cpuTemp.values, b: s.history.gpuTemp.values, aName: "cpu", bName: "gpu",
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
                HistoryChart(values: s.history.bodyW.values, color: .orange, format: { Fmt.watts($0) })
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
            FilledSegments(labels: presets.map(\.0), selected: presets.firstIndex(where: { $0.1 == d.setting })) {
                apply(presets[$0].1)
            }
            HStack {
                Slider(value: $ui.slider, in: 0...100) { editing in if !editing { apply(String(format: "%.0f%%", ui.slider)) } }
                Text(sliderLabel).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary).frame(width: 92, alignment: .trailing)
            }
            .onAppear { if d.setting.hasSuffix("%"), let v = Double(d.setting.dropLast()) { ui.slider = v } }
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

    private var sliderLabel: String {
        guard let f = s.now.fans.first else { return "" }
        return String(format: "%.0f%% ≈ %.0f rpm", ui.slider, f.min + (f.max - f.min) * ui.slider / 100)
    }

    private func apply(_ setting: String) {
        do { try FanDaemon.apply(setting); ui.error = nil } catch { ui.error = "写入失败：\(error.localizedDescription)" }
    }
}

// MARK: - popover shell

struct PopoverView: View {
    let module: Module
    @ObservedObject var s: Sampler
    @ObservedObject var settings: Settings

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
        .padding(14)
        .frame(width: 320)
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
