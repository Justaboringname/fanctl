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

struct Snapshot {
    var cpuTotal = 0.0, cpuUser = 0.0, cpuSystem = 0.0
    var cores: [Core] = [], clusters: [Cluster] = []
    var cpuW = 0.0, gpuW = 0.0, aneW = 0.0, dramW = 0.0, sysW = 0.0, usbW = 0.0
    var gpuUtil = 0.0, gpuRenderer = 0.0, gpuTiler = 0.0, gpuActive = 0.0, gpuMem: UInt64 = 0
    var memTotal: UInt64 = 0, memUsed: UInt64 = 0, memApp: UInt64 = 0, memWired: UInt64 = 0
    var memCompressed: UInt64 = 0, memCached: UInt64 = 0, swapTotal: UInt64 = 0, swapUsed: UInt64 = 0
    var pressure = 1
    var netIface = "", netIP = "", rx = 0.0, tx = 0.0, rxTotal: UInt64 = 0, txTotal: UInt64 = 0
    var cpuTemp = 0.0, cpuTempAvg = 0.0, gpuTemp = 0.0, gpuTempAvg = 0.0, ssdTemp = 0.0
    var fans: [Fan] = []

    var memFraction: Double { memTotal > 0 ? Double(memUsed) / Double(memTotal) : 0 }
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
    var cpu = Series(), cpuW = Series(), gpu = Series(), gpuW = Series(), mem = Series(), dramW = Series()
    var rx = Series(), tx = Series(), cpuTemp = Series(), gpuTemp = Series(), bodyW = Series()
}

@MainActor
final class Sampler: ObservableObject {
    @Published private(set) var now = Snapshot()
    @Published private(set) var history = Histories()
    @Published private(set) var procs = ProcLists()
    @Published private(set) var fanDaemon: FanDaemon.Status?
    let fanUI = FanControlState()
    let ok: Bool

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

    init(interval: TimeInterval) {
        self.interval = interval
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
        snap.netIface = tupleString(n.iface); snap.netIP = tupleString(n.ipv4)
        snap.rx = n.rx_bps; snap.tx = n.tx_bps; snap.rxTotal = n.rx_total; snap.txTotal = n.tx_total
        snap.cpuTemp = Double(s.cpu_max); snap.cpuTempAvg = Double(s.cpu_avg)
        snap.gpuTemp = Double(s.gpu_max); snap.gpuTempAvg = Double(s.gpu_avg); snap.ssdTemp = Double(s.ssd)
        snap.fans = tupleArray(s.fan, Int(s.nfans), m_fan.self).enumerated().map {
            Fan(id: $0.offset, actual: Double($0.element.actual), target: Double($0.element.target),
                min: Double($0.element.min), max: Double($0.element.max), manual: $0.element.manual != 0)
        }
        now = snap

        var h = history
        h.cpu.add(snap.cpuTotal); h.gpu.add(snap.gpuUtil); h.mem.add(snap.memFraction); h.rx.add(snap.rx); h.tx.add(snap.tx)
        if snap.cpuW.isFinite { h.cpuW.add(snap.cpuW) }
        if snap.gpuW.isFinite { h.gpuW.add(snap.gpuW) }
        if snap.dramW.isFinite { h.dramW.add(snap.dramW) }
        h.cpuTemp.add(snap.cpuTemp); h.gpuTemp.add(snap.gpuTemp)
        if snap.bodyW.isFinite { h.bodyW.add(snap.bodyW) }
        history = h

        fanDaemon = raw.fan
        if let pr = raw.procs, procViewers > 0 { publishProcs(pr) }
        onSample?()
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
