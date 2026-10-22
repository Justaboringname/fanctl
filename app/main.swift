// StatMenu — iStat-style menu bar monitor for Apple Silicon: CPU, GPU, memory, network and
// sensors (usage + power), with fan control through fanctld.
import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let settings = Settings()
    private var sampler: Sampler!
    private var items: [Module: NSStatusItem] = [:]
    private var popovers: [Module: NSPopover] = [:]
    private var hosts: [Module: NSHostingController<PopoverView>] = [:]
    private var drawn: [Module: String] = [:]  // signature of the image each item currently shows
    /// Menu bar light/dark changes (e.g. with the wallpaper): an alerting item's image is not a
    /// template, so it has to be redrawn in the new text colour.
    private var appearanceObservers: [Module: NSKeyValueObservation] = [:]
    private var bag = Set<AnyCancellable>()
    private var lastSave = Date()
    private var sigterm: DispatchSourceSignal?

    /// The charts' long-range history (LongHistory), kept across launches and reboots.
    static let historyFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("StatMenu/history.plist")

    func applicationDidFinishLaunching(_ note: Notification) {
        sampler = Sampler(interval: settings.interval, historyFile: Self.historyFile)
        if !sampler.ok {
            let alert = NSAlert()
            alert.messageText = "无法读取 SMC / IOReport"
            alert.runModal()
        }
        settings.$interval.dropFirst().sink { [weak self] in self?.sampler.interval = $0 }.store(in: &bag)
        settings.onModulesChanged = { [weak self] in self?.rebuildItems() }
        sampler.onSample = { [weak self] in self?.updateItems(); self?.resizePopovers(); self?.saveEvery(300) }
        rebuildItems()
        sampler.sample()
        // Save the history before the Mac sleeps or shuts down, and on SIGTERM (pkill, install.sh),
        // which would otherwise end the process without applicationWillTerminate.
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.willPowerOffNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sampler.saveHistory() }
            }
        }
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.sampler.saveHistory() }
            exit(0)
        }
        src.resume()
        sigterm = src
    }

    func applicationWillTerminate(_ note: Notification) { sampler.saveHistory() }

    private func saveEvery(_ seconds: TimeInterval) {
        guard Date().timeIntervalSince(lastSave) >= seconds else { return }
        lastSave = Date()
        sampler.saveHistory()
    }

    private func rebuildItems() {
        // A new status item lands to the left of the existing ones, so create right-to-left to get
        // Module.allCases order left-to-right (network, CPU, GPU, memory, sensors). ⌘-drag reorders
        // and macOS remembers it per autosave name ("v2": the pre-reorder positions are discarded).
        for m in Module.allCases.reversed() {
            if settings.enabled.contains(m), items[m] == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                UserDefaults.standard.removeObject(forKey: "NSStatusItem Preferred Position statmenu.\(m.rawValue)")
                item.autosaveName = "statmenu.v2.\(m.rawValue)"
                item.button?.target = self
                item.button?.action = #selector(toggle(_:))
                item.button?.tag = Module.allCases.firstIndex(of: m)!
                items[m] = item
                appearanceObservers[m] = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.updateItems() }
                }
            } else if !settings.enabled.contains(m), let item = items[m] {
                popovers[m]?.performClose(nil)
                NSStatusBar.system.removeStatusItem(item)
                items[m] = nil
                drawn[m] = nil
                appearanceObservers[m] = nil
            }
        }
        updateItems()
    }

    private func updateItems() {
        let n = sampler.now
        for (m, item) in items {
            typealias Seg = StatusImage.Segment
            let arrowUp = "↑\u{2009}", arrowDown = "↓\u{2009}"  // thin space after the arrows
            let image: (image: NSImage, signature: String)
            let look = item.button?.effectiveAppearance
            switch m {
            case .network:
                image = StatusImage.make(label: "NET", segments: [Seg(text: arrowUp + Fmt.rate(n.tx), key: "net.tx"),
                                                                  Seg(text: arrowDown + Fmt.rate(n.rx), key: "net.rx")])
            case .cpu:
                image = StatusImage.make(label: "CPU", segments: [Seg(text: Fmt.pct(n.cpuTotal), key: "cpu.pct", level: n.cpuLevel),
                                                                  Seg(text: Fmt.watts(n.cpuW), key: "cpu.w")], appearance: look)
            case .gpu:
                image = StatusImage.make(label: "GPU", segments: [Seg(text: Fmt.pct(n.gpuUtil), key: "gpu.pct", level: n.gpuLevel),
                                                                  Seg(text: Fmt.watts(n.gpuW), key: "gpu.w")], appearance: look)
            case .memory:
                image = StatusImage.make(label: "MEM", segments: [Seg(text: Fmt.pct(n.memPressure), key: "mem.pct", level: n.memLevel),
                                                                  Seg(text: Fmt.watts(n.dramW), key: "mem.w")], appearance: look)
            case .sensors:
                image = StatusImage.make(label: nil, symbol: n.fans.contains(where: \.manual) ? "fan.fill" : "thermometer.medium",
                                         segments: [Seg(text: Fmt.temp(n.cpuTemp), key: "sns.cpu", label: "CPU", level: n.cpuTempLevel),
                                                    Seg(text: Fmt.temp(n.gpuTemp), key: "sns.gpu", label: "GPU", level: n.gpuTempLevel),
                                                    Seg(text: Fmt.watts(n.bodyW), key: "sns.w")], appearance: look)
            }
            guard drawn[m] != image.signature else { continue }  // unchanged: don't wake MenuBarAgent
            drawn[m] = image.signature
            item.button?.image = image.image
            item.button?.setAccessibilityLabel(accessibilityText(m, n))
        }
    }

    private func accessibilityText(_ m: Module, _ n: Snapshot) -> String {
        func alert(_ l: Level) -> String { l == .critical ? "（过高）" : l == .warn ? "（偏高）" : "" }
        return switch m {
        case .cpu: "CPU \(Fmt.pct(n.cpuTotal))\(alert(n.cpuLevel)) \(Fmt.watts(n.cpuW))"
        case .gpu: "GPU \(Fmt.pct(n.gpuUtil))\(alert(n.gpuLevel)) \(Fmt.watts(n.gpuW))"
        case .memory: "内存压力 \(Fmt.pct(n.memPressure))\(alert(n.memLevel)) \(Fmt.watts(n.dramW))"
        case .network: "上传 \(Fmt.rate(n.tx)) 下载 \(Fmt.rate(n.rx))"
        case .sensors: "CPU \(Fmt.temp(n.cpuTemp))\(alert(n.cpuTempLevel)) GPU \(Fmt.temp(n.gpuTemp))\(alert(n.gpuTempLevel)) Mac 本体 \(Fmt.watts(n.bodyW))"
        }
    }

    @objc private func toggle(_ sender: NSStatusBarButton) {
        let m = Module.allCases[sender.tag]
        if let p = popovers[m], p.isShown { p.performClose(nil); return }
        popovers.values.filter(\.isShown).forEach { $0.performClose(nil) }
        let p = NSPopover()
        p.behavior = .transient
        p.delegate = self
        // Size the popover ourselves. Left to SwiftUI (sizingOptions = .preferredContentSize), the
        // popover is placed for its first measured size and then resizes without re-anchoring to
        // the status item, so it drifts below the menu bar or grows off the top of the screen.
        let host = NSHostingController(rootView: PopoverView(module: m, s: sampler, settings: settings))
        host.sizingOptions = []
        p.contentViewController = host
        p.contentSize = fittingSize(host)
        popovers[m] = p
        hosts[m] = host
        if m.showsProcesses { sampler.procViewers += 1 }
        // An accessory app is not active on its own; activate so the popover's window can become key
        // (keyboard/slider focus) and .transient closes it when the user clicks elsewhere.
        NSApp.activate()
        p.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        p.contentViewController?.view.window?.makeKey()
    }

    private func fittingSize(_ host: NSHostingController<PopoverView>) -> NSSize {
        host.sizeThatFits(in: CGSize(width: 10_000, height: 10_000))
    }

    /// Content height changes while open (process lists fill in, fan warnings appear); resizing
    /// through contentSize keeps the popover anchored under its menu bar item.
    private func resizePopovers() {
        for (m, p) in popovers where p.isShown {
            guard let host = hosts[m] else { continue }
            let size = fittingSize(host)
            if abs(size.height - p.contentSize.height) > 0.5 || abs(size.width - p.contentSize.width) > 0.5 {
                p.contentSize = size
            }
        }
    }

    func popoverDidClose(_ note: Notification) {
        guard let p = note.object as? NSPopover, let m = popovers.first(where: { $0.value === p })?.key else { return }
        if m.showsProcesses { sampler.procViewers -= 1 }
        popovers[m] = nil  // drop the hosting view so closed popovers cost nothing
        hosts[m] = nil
    }
}

// Top-level code is not main-actor isolated; the process starts on the main thread, so assert it.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()  // NSApplication.delegate is weak; this local lives as long as run()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
