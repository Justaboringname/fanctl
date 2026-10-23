// Polls the C metrics layer on a timer and publishes plain Swift snapshots plus short histories.
import Foundation
import AppKit

// C fixed-size arrays import as tuples; read them through their raw bytes.
func tupleArray<T, E>(_ tuple: T, _ count: Int, _: E.Type) -> [E] {
    withUnsafeBytes(of: tuple) { Array($0.bindMemory(to: E.self).prefix(count)) }
}

func tupleString<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
}

struct Core: Identifiable { let id: Int; let cluster: Character; let busy: Double }
struct Cluster: Identifiable { let id: Character; let name: String; let count: Int; let busy: Double; let watts: Double }
struct Fan: Identifiable { let id: Int; let actual, target, min, max: Double; let manual: Bool }
struct Proc: Identifiable { let id: Int; let name: String; let value: Double }

/// How alarming a reading is: anything above normal gets a Liquid Glass box, in the menu bar and the
/// popover headers (warn and critical look the same; they differ in the accessibility label and
/// in where the hysteresis releases). Every threshold lives here so the two always agree.
enum Level: Int, Comparable {
    case normal, warn, critical
    static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

    /// CPU / GPU load is judged by power, not usage: 100 % usage on a few cores or at low clocks is
    /// not load. Yellow from 70 % of the chip's maximum, red from 90 %.
    static let warnShare = 0.70, criticalShare = 0.90
    static func power(_ w: Double, max: Double, was: Level = .normal) -> Level {
        step(w / max, was, warn: warnShare, critical: criticalShare, back: 0.05)
    }
    /// Maximum draw measured on a Mac Studio M5 Max: CPU 92 W (18-thread Stockfish), GPU 118 W incl.
    /// AFR (ray tracing + tensor kernels). Other Macs: `defaults write com.justaboringname.statmenu
    /// cpuMaxW 40` (and gpuMaxW).
    static let cpuMaxW = configured("cpuMaxW", 92), gpuMaxW = configured("gpuMaxW", 118)
    private static func configured(_ key: String, _ fallback: Double) -> Double {
        let v = UserDefaults.standard.double(forKey: key)
        return v > 0 ? v : fallback
    }
    /// Hottest CPU / GPU sensor: yellow from 85 °C, red from 95 °C (fanctld's guard trips at 100).
    static func temp(_ c: Double, was: Level = .normal) -> Level { step(c, was, warn: 85, critical: 95, back: 3) }
    /// kern.memorystatus_vm_pressure_level: 2 = warning, 4 = critical (the kernel's own hysteresis).
    static func pressure(_ level: Int) -> Level { level >= 4 ? .critical : level >= 2 ? .warn : .normal }

    /// A level is left only once the value is `back` below its threshold, so a reading that hovers
    /// on a threshold doesn't flash the menu bar every sample.
    private static func step(_ v: Double, _ was: Level, warn: Double, critical: Double, back: Double) -> Level {
        guard v.isFinite else { return .normal }
        if v >= critical || (was == .critical && v >= critical - back) { return .critical }
        if v >= warn || (was >= .warn && v >= warn - back) { return .warn }
        return .normal
    }
}

struct Snapshot {
    var cpuTotal = 0.0, cpuUser = 0.0, cpuSystem = 0.0
    var cpuLevel = Level.normal, gpuLevel = Level.normal, memLevel = Level.normal
    var cpuTempLevel = Level.normal, gpuTempLevel = Level.normal
    var cores: [Core] = [], clusters: [Cluster] = []
    var cpuW = 0.0, gpuW = 0.0, aneW = 0.0, dramW = 0.0, sysW = 0.0, usbW = 0.0
    var gpuUtil = 0.0, gpuRenderer = 0.0, gpuTiler = 0.0, gpuActive = 0.0, gpuMem: UInt64 = 0
    var memTotal: UInt64 = 0, memUsed: UInt64 = 0, memApp: UInt64 = 0, memWired: UInt64 = 0
    var memCompressed: UInt64 = 0, memCached: UInt64 = 0, swapTotal: UInt64 = 0, swapUsed: UInt64 = 0
    var pressure = 1, memPressure = Double.nan  // level 1/2/4; Activity Monitor's pressure graph, 0…1
    var netIface = "", netIP = "", rx = 0.0, tx = 0.0, rxTotal: UInt64 = 0, txTotal: UInt64 = 0
    var cpuTemp = 0.0, cpuTempAvg = 0.0, gpuTemp = 0.0, gpuTempAvg = 0.0, ssdTemp = 0.0
    var fans: [Fan] = []

    /// The Mac itself: PSTR minus what the USB ports hand out to lamps, keyboards, chargers… (PSTR
    /// includes that output). The 12 V→5 V conversion loss for it (~8 % at 14 W) stays in here.
    var bodyW: Double { sysW > 0 ? max(0, sysW - usbW) : .nan }
    /// Body power not attributed to CPU/GPU/ANE/DRAM: display pipeline, fabric, SSD, fans, …
    /// NaN while any component is still sampling.
    var otherW: Double {
        let parts = cpuW + gpuW + aneW + dramW
        return parts.isFinite && bodyW.isFinite ? max(0, bodyW - parts) : .nan
    }
}

/// One round of raw readings from the C layer. Collected off the main thread: the SMC sensor sweep
/// alone takes ~20 ms and would otherwise stall menus and slider drags every tick.
struct RawSample {
    var c = m_cpu(), p = m_power(), g = m_gpu(), m = m_mem(), n = m_net(), s = m_sensors()
    var procs: m_procs?
    var fan: FanDaemon.Status?
}

enum ProcMode { case off, prime, sample }

struct ProcLists { var byCPU: [Proc] = [], byPower: [Proc] = [], byMemory: [Proc] = []; var readable = 0, total = 0 }

/// Every quantity the popover charts plot. `name` keys the saved long-range history, so cases can be
/// added or reordered without losing it.
enum Metric: Int, CaseIterable {
    case cpu, cpuW, gpu, gpuW, mem, dramW, rx, tx, cpuTemp, gpuTemp, bodyW
    var name: String { String(describing: self) }

    /// NaN when there is no valid reading this sample (power still settling, sensor missing).
    func value(_ s: Snapshot) -> Double {
        switch self {
        case .cpu: s.cpuTotal
        case .cpuW: s.cpuW
        case .gpu: s.gpuUtil
        case .gpuW: s.gpuW
        case .mem: s.memPressure
        case .dramW: s.dramW
        case .rx: s.rx
        case .tx: s.tx
        case .cpuTemp: s.cpuTemp > 0 ? s.cpuTemp : .nan
        case .gpuTemp: s.gpuTemp > 0 ? s.gpuTemp : .nan
        case .bodyW: s.bodyW
        }
    }
}

/// Fixed-length history for the popover charts. Each value keeps its sample time (systemUptime), so
/// the hover readout can say how old it is even across skipped samples or interval changes.
struct Series {
    private(set) var values: [Double] = []
    private(set) var times: [TimeInterval] = []
    static let capacity = 150
    mutating func add(_ v: Double, at t: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        values.append(v); times.append(t)
        if values.count > Self.capacity {
            values.removeFirst(values.count - Self.capacity); times.removeFirst(times.count - Self.capacity)
        }
    }
    /// Seconds between sample i and the newest one.
    func age(_ i: Int) -> TimeInterval { times.indices.contains(i) ? times[times.count - 1] - times[i] : 0 }
}

struct Histories {
    private var all = [Series](repeating: Series(), count: Metric.allCases.count)
    subscript(m: Metric) -> Series {
        get { all[m.rawValue] }
        set { all[m.rawValue] = newValue }
    }
}

/// How far back the popover charts reach. 实时 is the per-sample history above; the others come from
/// LongHistory, one point per `step` seconds.
enum HistoryRange: String, CaseIterable, Identifiable {
    case live, hour1, hour6, hour12, hour24
    var id: String { rawValue }
    var label: String {
        switch self {
        case .live: "实时"
        case .hour1: "1 小时"
        case .hour6: "6 小时"
        case .hour12: "12 小时"
        case .hour24: "24 小时"
        }
    }
    /// Seconds per chart point (a multiple of the LongHistory tier it reads) and the point count;
    /// 120–144 points, about what the 150-sample live chart draws across the same width.
    var step: Int { [0, 30, 180, 300, 600][index] }
    var points: Int { [0, 120, 120, 144, 144][index] }
    private var index: Int { Self.allCases.firstIndex(of: self)! }
}

/// What a chart draws for one line: a value per x slot (NaN = no data, drawn as a gap), for long
/// ranges also the peak within each slot, and the hover's time label for a slot.
struct ChartLine {
    var values: [Double]
    var peaks: [Double]? = nil
    /// x domain 0..<slots (a live history that is not full yet fills it from the left).
    var slots: Int
    var when: (Int) -> String
}

/// Long-range chart history: per-metric mean and peak in wall-clock buckets — 10 s for the last
/// 2 hours, 1 min for the last 24 — saved to disk so a relaunch or reboot doesn't empty it.
/// Wall clock, not systemUptime: uptime stops while the Mac sleeps and restarts at boot. A bucket
/// without samples (asleep, app not running) stays empty and shows as a gap.
final class LongHistory {
    struct Tier {
        let seconds: Int, count: Int
        /// Bucket number (epoch seconds / `seconds`) each ring slot holds; -1 = never used.
        var stamps: [Int]
        /// [slot * metrics + metric]
        var sums: [Float], peaks: [Float], counts: [UInt16]
        init(seconds: Int, count: Int) {
            self.seconds = seconds; self.count = count
            stamps = Array(repeating: -1, count: count)
            let n = count * Metric.allCases.count
            sums = Array(repeating: 0, count: n); peaks = Array(repeating: 0, count: n); counts = Array(repeating: 0, count: n)
        }
        var span: Int { seconds * count }
    }

    private(set) var tiers = [Tier(seconds: 10, count: 720), Tier(seconds: 60, count: 1440)]
    private static let metrics = Metric.allCases.count

    func add(_ values: [Double], at t: TimeInterval) {
        for ti in tiers.indices {
            let b = Int((t / Double(tiers[ti].seconds)).rounded(.down)), slot = b % tiers[ti].count
            let base = slot * Self.metrics
            if tiers[ti].stamps[slot] != b {  // slot last held a bucket from a lap ago: start over
                tiers[ti].stamps[slot] = b
                for k in base..<base + Self.metrics { tiers[ti].sums[k] = 0; tiers[ti].peaks[k] = 0; tiers[ti].counts[k] = 0 }
            }
            for (m, v) in values.enumerated() where v.isFinite {
                let k = base + m, f = Float(v)
                tiers[ti].peaks[k] = tiers[ti].counts[k] == 0 ? f : max(tiers[ti].peaks[k], f)
                tiers[ti].sums[k] += f
                if tiers[ti].counts[k] < .max { tiers[ti].counts[k] += 1 }
            }
        }
    }

    /// The chart line for `r`, ending with the point that contains `now` (still filling).
    func line(_ m: Metric, _ r: HistoryRange, now: TimeInterval) -> ChartLine {
        let step = r.step, n = r.points
        guard let tier = tiers.first(where: { $0.span >= step * n && step % $0.seconds == 0 }) else {
            return ChartLine(values: [], slots: 1, when: { _ in "" })
        }
        let per = step / tier.seconds
        let last = Int((now / Double(step)).rounded(.down)) * step  // start of the newest point
        var values = [Double](repeating: .nan, count: n), peaks = values
        for p in 0..<n {
            let first = (last - (n - 1 - p) * step) / tier.seconds
            var sum: Float = 0, count = 0, peak = -Float.infinity
            for b in first..<first + per {
                let slot = b % tier.count, k = slot * Self.metrics + m.rawValue
                guard tier.stamps[slot] == b, tier.counts[k] > 0 else { continue }
                sum += tier.sums[k]; count += Int(tier.counts[k]); peak = max(peak, tier.peaks[k])
            }
            if count > 0 { values[p] = Double(sum) / Double(count); peaks[p] = Double(peak) }
        }
        return ChartLine(values: values, peaks: peaks, slots: n) { p in
            let start = last - (n - 1 - p) * step
            return Fmt.span(from: TimeInterval(start), to: TimeInterval(start + step), now: now)
        }
    }

    // MARK: persistence

    private struct Saved: Codable {
        var version = 1
        var metrics: [String]
        var tiers: [SavedTier]
    }
    private struct SavedTier: Codable {
        var seconds: Int, count: Int
        var stamps: Data, sums: Data, peaks: Data, counts: Data
    }

    func encoded() -> Data? {
        func data<T>(_ a: [T]) -> Data { a.withUnsafeBufferPointer { Data(buffer: $0) } }
        let saved = Saved(metrics: Metric.allCases.map(\.name), tiers: tiers.map {
            SavedTier(seconds: $0.seconds, count: $0.count, stamps: data($0.stamps.map(Int64.init)),
                      sums: data($0.sums), peaks: data($0.peaks), counts: data($0.counts))
        })
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        return try? enc.encode(saved)
    }

    /// Restores what `encoded()` wrote. Tiers whose shape changed are dropped; metrics are matched
    /// by name. Buckets older than a tier's span are simply never read (their stamps don't match).
    func load(_ d: Data) {
        guard let saved = try? PropertyListDecoder().decode(Saved.self, from: d), saved.version == 1 else { return }
        func array<T: Numeric>(_ d: Data, _ n: Int) -> [T]? {
            guard d.count == n * MemoryLayout<T>.stride else { return nil }
            var a = [T](repeating: 0, count: n)
            _ = a.withUnsafeMutableBytes { d.copyBytes(to: $0) }  // copy: plist Data need not be aligned
            return a
        }
        let mine = saved.metrics.map { name in Metric.allCases.first { $0.name == name } }
        for st in saved.tiers {
            guard let ti = tiers.firstIndex(where: { $0.seconds == st.seconds && $0.count == st.count }) else { continue }
            let n = st.count * saved.metrics.count
            guard let stamps: [Int64] = array(st.stamps, st.count), let sums: [Float] = array(st.sums, n),
                  let peaks: [Float] = array(st.peaks, n), let counts: [UInt16] = array(st.counts, n) else { continue }
            var t = Tier(seconds: st.seconds, count: st.count)
            t.stamps = stamps.map { Int($0) }
            for slot in 0..<st.count {
                for (j, m) in mine.enumerated() {
                    guard let m else { continue }
                    let from = slot * saved.metrics.count + j, to = slot * Self.metrics + m.rawValue
                    t.sums[to] = sums[from]; t.peaks[to] = peaks[from]; t.counts[to] = counts[from]
                }
            }
            tiers[ti] = t
        }
    }
}

@MainActor
final class Sampler: ObservableObject {
    @Published private(set) var now = Snapshot()
    @Published private(set) var history = Histories()
    @Published private(set) var procs = ProcLists()
    @Published private(set) var fanDaemon: FanDaemon.Status?
    /// Not @Published: a reference type mutated in place (the module views re-render on `now`
    /// anyway), so the ~240 KB of buckets is never copied per sample.
    let long = LongHistory()
    /// Where the long history is loaded from and saved to; nil (render harness) = memory only.
    private let historyFile: URL?
    let fanUI = FanControlState()
    let ok: Bool
    /// Render tool only: show every alert level as this one.
    static var previewLevel: Level?

    /// Number of open popovers that show process lists; processes are only sampled while > 0.
    var procViewers = 0 { didSet { if procViewers == 0 { procsPrimed = false } } }
    private var procsPrimed = false
    private var inFlight = false
    /// metrics.c keeps per-process baselines in globals; every C call after init runs on this queue.
    private let queue = DispatchQueue(label: "statmenu.sampler", qos: .utility)
    var interval: TimeInterval { didSet { restart() } }
    var onSample: (() -> Void)?

    private var timer: Timer?
    private let clusterNames: [Character: String]
    /// A menu of ours (the popover's gear menu) is open. Ticks are skipped meanwhile: the first SwiftUI
    /// update while it tracks re-applies the 刷新间隔 picker item (measured: 4 NSMenu item changes),
    /// which closes its submenu under the pointer. A Bool, not a count, so it can never get stuck.
    private var menuOpen = false

    init(interval: TimeInterval, historyFile: URL? = nil) {
        self.interval = interval
        self.historyFile = historyFile
        if let historyFile, let d = try? Data(contentsOf: historyFile) { long.load(d) }
        ok = m_open() == 0
        clusterNames = Sampler.clusterNames()
        restart()
        for (name, open) in [(NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false)] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in  // posted on main, synchronously
                MainActor.assumeIsolated { self?.menuOpen = open }
            }
        }
    }

    private func restart() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(t, forMode: .common)  // keep ticking while a slider drag tracks the mouse (menus: see menuOpen)
        timer = t
    }

    /// Cluster-type letters from the device tree, named after the matching hw.perflevelN.name
    /// (perflevel0 is the fastest). M5 Pro/Max: P = "Super", M = "Performance".
    private static func clusterNames() -> [Character: String] {
        var c = m_cpu()
        m_cpu_sample(&c)
        let types = Set(tupleArray(c.cluster, Int(c.ncpu), CChar.self).map { Character(UnicodeScalar(UInt8(bitPattern: $0))) })
        let ordered = "PME".filter { types.contains($0) }
        let zh = ["Super": "超级核心", "Performance": "性能核心", "Efficiency": "能效核心"]
        var names: [Character: String] = [:]
        for (i, type) in ordered.enumerated() {
            var buf = [CChar](repeating: 0, count: 64), len = 64
            let name = sysctlbyname("hw.perflevel\(i).name", &buf, &len, nil, 0) == 0
                ? String(cString: buf) : String(type)
            names[type] = zh[name] ?? name
        }
        return names
    }

    /// Timer path: collect on the background queue, publish on the main actor. Skips a tick if the
    /// previous collection is still running.
    func sample() {
        guard !inFlight, !menuOpen else { return }
        inFlight = true
        let mode = nextProcMode()
        queue.async {
            let raw = Sampler.collect(procs: mode)
            DispatchQueue.main.async { MainActor.assumeIsolated { self.inFlight = false; self.publish(raw) } }
        }
    }

    /// Synchronous variant for the offscreen render harness (no timer, nothing else on the queue).
    func sampleNow() {
        publish(queue.sync { Sampler.collect(procs: nextProcMode()) })
    }

    private func nextProcMode() -> ProcMode {
        guard procViewers > 0 else { return .off }
        if procsPrimed { return .sample }
        procsPrimed = true
        return .prime  // first call only sets the CPU/energy baselines
    }

    nonisolated private static func collect(procs mode: ProcMode) -> RawSample {
        var r = RawSample()
        m_cpu_sample(&r.c); m_power_sample(&r.p); m_gpu_sample(&r.g); m_mem_sample(&r.m); m_net_sample(&r.n)
        m_sensors_sample(&r.s)
        if mode != .off {
            var pr = m_procs()
            m_procs_sample(&pr)
            if mode == .sample { r.procs = pr }
        }
        r.fan = FanDaemon.read()
        return r
    }

    private func publish(_ raw: RawSample) {
        let c = raw.c, p = raw.p, g = raw.g, m = raw.m, n = raw.n, s = raw.s

        var snap = Snapshot()
        let busy = tupleArray(c.core, Int(c.ncpu), Double.self)
        let types = tupleArray(c.cluster, Int(c.ncpu), CChar.self).map { Character(UnicodeScalar(UInt8(bitPattern: $0))) }
        snap.cores = busy.indices.map { Core(id: $0, cluster: types[$0], busy: busy[$0]) }
        snap.cpuTotal = c.total; snap.cpuUser = c.user; snap.cpuSystem = c.system
        let watts: [Character: Double] = ["P": p.cpu_p_w, "M": p.cpu_m_w, "E": p.cpu_e_w]
        snap.clusters = "PME".compactMap { type in
            let members = snap.cores.filter { $0.cluster == type }
            guard !members.isEmpty else { return nil }
            return Cluster(id: type, name: clusterNames[type] ?? String(type), count: members.count,
                           busy: members.map(\.busy).reduce(0, +) / Double(members.count), watts: watts[type] ?? 0)
        }
        // NaN until the channel has two hardware-timestamped readings (a few seconds after launch);
        // Fmt.watts shows it as "–" rather than a fake 0 W.
        snap.cpuW = p.cpu_valid != 0 ? p.cpu_w : .nan
        snap.gpuW = p.gpu_valid != 0 ? p.gpu_w : .nan
        snap.aneW = p.ane_valid != 0 ? p.ane_w : .nan
        snap.dramW = p.dram_valid != 0 ? p.dram_w : .nan
        snap.sysW = Double(s.sys_w); snap.usbW = Double(s.usb_w)
        snap.gpuUtil = g.device; snap.gpuRenderer = g.renderer; snap.gpuTiler = g.tiler
        snap.gpuActive = p.gpu_active; snap.gpuMem = g.mem_in_use
        snap.memTotal = m.total; snap.memUsed = m.used; snap.memApp = m.app; snap.memWired = m.wired
        snap.memCompressed = m.compressed; snap.memCached = m.cached
        snap.swapTotal = m.swap_total; snap.swapUsed = m.swap_used; snap.pressure = Int(m.pressure)
        snap.memPressure = m.free_pct >= 0 ? Double(100 - min(Int(m.free_pct), 100)) / 100 : .nan
        snap.netIface = tupleString(n.iface); snap.netIP = tupleString(n.ipv4)
        snap.rx = n.rx_bps; snap.tx = n.tx_bps; snap.rxTotal = n.rx_total; snap.txTotal = n.tx_total
        snap.cpuTemp = Double(s.cpu_max); snap.cpuTempAvg = Double(s.cpu_avg)
        snap.gpuTemp = Double(s.gpu_max); snap.gpuTempAvg = Double(s.gpu_avg); snap.ssdTemp = Double(s.ssd)
        snap.fans = tupleArray(s.fan, Int(s.nfans), m_fan.self).enumerated().map {
            Fan(id: $0.offset, actual: Double($0.element.actual), target: Double($0.element.target),
                min: Double($0.element.min), max: Double($0.element.max), manual: $0.element.manual != 0)
        }
        snap.cpuLevel = Level.power(snap.cpuW, max: Level.cpuMaxW, was: now.cpuLevel)
        snap.gpuLevel = Level.power(snap.gpuW, max: Level.gpuMaxW, was: now.gpuLevel)
        snap.memLevel = Level.pressure(snap.pressure)
        snap.cpuTempLevel = Level.temp(snap.cpuTemp, was: now.cpuTempLevel)
        snap.gpuTempLevel = Level.temp(snap.gpuTemp, was: now.gpuTempLevel)
        if let forced = Sampler.previewLevel {
            (snap.cpuLevel, snap.gpuLevel, snap.memLevel, snap.cpuTempLevel, snap.gpuTempLevel) = (forced, forced, forced, forced, forced)
        }
        now = snap

        let values = Metric.allCases.map { $0.value(snap) }
        var h = history
        for m in Metric.allCases where values[m.rawValue].isFinite { h[m].add(values[m.rawValue]) }
        history = h
        long.add(values, at: Date().timeIntervalSince1970)

        fanDaemon = raw.fan
        if let pr = raw.procs, procViewers > 0 { publishProcs(pr) }
        onSample?()
    }

    /// The chart line for metric `m` over range `r`.
    func line(_ m: Metric, _ r: HistoryRange) -> ChartLine {
        guard r == .live else { return long.line(m, r, now: Date().timeIntervalSince1970) }
        let series = history[m]
        return ChartLine(values: series.values, slots: Series.capacity) { Fmt.age(series.age($0)) }
    }

    func saveHistory() {
        guard let historyFile, let d = long.encoded() else { return }
        try? FileManager.default.createDirectory(at: historyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: historyFile, options: .atomic)
    }

    private func publishProcs(_ pr: m_procs) {
        let count = Int(pr.n)
        func rows(_ t: (m_proc, m_proc, m_proc, m_proc, m_proc), _ value: (m_proc) -> Double) -> [Proc] {
            tupleArray(t, count, m_proc.self).map { Proc(id: Int($0.pid), name: displayName($0), value: value($0)) }
        }
        procs = ProcLists(byCPU: rows(pr.by_cpu) { $0.cpu }, byPower: rows(pr.by_power) { $0.watts },
                          byMemory: rows(pr.by_mem) { Double($0.mem) }, readable: Int(pr.readable), total: Int(pr.total))
    }

    /// App name for GUI processes (proc_name is truncated and shows helper binary names).
    private func displayName(_ p: m_proc) -> String {
        NSRunningApplication(processIdentifier: p.pid)?.localizedName ?? tupleString(p.name)
    }
}
