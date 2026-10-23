// Renders each module's popover offscreen to PNG (light + dark), for checking layout without
// clicking the menu bar. Build/run: make render   → build/render/<module>-<appearance>.png
import AppKit
import SwiftUI

MainActor.assumeIsolated {
    _ = NSApplication.shared
    let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/render")
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    // RENDER_RANGE=live|hour1|hour6|hour12|hour24 picks the charts' range (default live). Long ranges
    // plot a synthetic 24 h timeline with a 3-hour sleep gap, or with RENDER_HISTORY=<file> the
    // app's saved history (read only: the harness never saves).
    let env = ProcessInfo.processInfo.environment
    let range = env["RENDER_RANGE"].flatMap(HistoryRange.init) ?? .live
    let historyFile = env["RENDER_HISTORY"].map { URL(fileURLWithPath: $0) }
    let sampler = Sampler(interval: 3600, historyFile: historyFile)  // timer effectively off; sample manually below
    // RENDER_LEVEL=warn|critical shows every alert (menu bar boxes, header boxes) at that level.
    Sampler.previewLevel = ["warn": Level.warn, "critical": .critical][env["RENDER_LEVEL"] ?? ""]
    if range != .live, historyFile == nil {
        let now = Date().timeIntervalSince1970
        func wave(_ t: Double, _ period: Double) -> Double { (sin(t / period * 2 * .pi) + 1) / 2 }
        for t in stride(from: now - 86_400, to: now, by: 10) where !(now - 10 * 3600 ..< now - 7 * 3600).contains(t) {
            var rng = SplitMix(seed: UInt64(t))
            let burst = rng.next() < 0.002 ? 1.0 : 0  // a short spike now and then, for the peak band
            let cpu = min(1, 0.06 + 0.3 * wave(t, 5 * 3600) + 0.06 * rng.next() + 0.8 * burst)
            let gpu = min(1, 0.03 + 0.4 * wave(t + 4000, 3 * 3600) * wave(t, 40 * 60) + 0.5 * burst)
            let values: [Metric: Double] = [
                .cpu: cpu, .cpuW: 4 + 70 * cpu, .gpu: gpu, .gpuW: 1 + 90 * gpu, .mem: 0.35 + 0.2 * wave(t, 8 * 3600),
                .dramW: 0.6 + 2 * cpu, .rx: 2e4 + 3e6 * pow(wave(t, 2 * 3600), 6) + 4e7 * burst, .tx: 5e3 + 4e5 * wave(t, 3600),
                .cpuTemp: 42 + 45 * cpu, .gpuTemp: 38 + 40 * gpu, .bodyW: 12 + 70 * cpu + 90 * gpu,
            ]
            sampler.long.add(Metric.allCases.map { values[$0]! }, at: t)
        }
    }
    sampler.procViewers = 1
    for _ in 0..<6 {  // hardware energy counters update in 1–2 s batches; give them two updates
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        sampler.sampleNow()
    }
    // Menu bar strip (same drawing code as the real status items), light and dark.
    let n = sampler.now
    typealias Seg = StatusImage.Segment
    // The alert boxes are real glass views in the app; here the flat stand-in.
    // Like the app with 告警高亮 off (its default): boxes only when RENDER_LEVEL forces them.
    let lv: (Level) -> Level = { Sampler.previewLevel == nil ? .normal : $0 }
    @MainActor func strip() -> [(image: NSImage, boxes: [StatusImage.Box], signature: String)] {
        [
            StatusImage.make(label: "NET", segments: [Seg(text: "↑\u{2009}" + Fmt.rate(n.tx), key: "net.tx"),
                                                      Seg(text: "↓\u{2009}" + Fmt.rate(n.rx), key: "net.rx")]),
            StatusImage.make(label: "CPU", segments: [Seg(text: Fmt.pct(n.cpuTotal), key: "cpu.pct", level: lv(n.cpuLevel)),
                                                      Seg(text: Fmt.watts(n.cpuW), key: "cpu.w")]),
            StatusImage.make(label: "GPU", segments: [Seg(text: Fmt.pct(n.gpuUtil), key: "gpu.pct", level: lv(n.gpuLevel)),
                                                      Seg(text: Fmt.watts(n.gpuW), key: "gpu.w")]),
            StatusImage.make(label: "MEM", segments: [Seg(text: Fmt.pct(n.memPressure), key: "mem.pct", level: lv(n.memLevel)),
                                                      Seg(text: Fmt.watts(n.dramW), key: "mem.w")]),
            StatusImage.make(label: nil, symbol: "thermometer.medium",
                             segments: [Seg(text: Fmt.temp(n.cpuTemp), key: "sns.cpu", label: "CPU", level: lv(n.cpuTempLevel)),
                                        Seg(text: Fmt.temp(n.gpuTemp), key: "sns.gpu", label: "GPU", level: lv(n.gpuTempLevel)),
                                        Seg(text: Fmt.watts(n.bodyW), key: "sns.w")]),
        ]
    }
    let icons = strip()
    for (name, bg, fg) in [("light", NSColor(white: 0.93, alpha: 1), NSColor.black), ("dark", NSColor(white: 0.12, alpha: 1), NSColor.white)] {
        let spacing: CGFloat = 12, width = icons.reduce(0) { $0 + $1.image.size.width + spacing } + spacing
        let img = NSImage(size: NSSize(width: width, height: 26), flipped: false) { rect in
            bg.setFill(); rect.fill()
            var x = spacing
            for (icon, boxes, _) in icons {
                for b in boxes {
                    AlertBoxes.flatFill.setFill()
                    let path = NSBezierPath(roundedRect: b.rect.offsetBy(dx: x, dy: 2).insetBy(dx: AlertBoxes.rimWidth / 2, dy: AlertBoxes.rimWidth / 2),
                                            xRadius: StatusImage.boxRadius, yRadius: StatusImage.boxRadius)
                    path.fill()
                    AlertBoxes.rim.setStroke(); path.lineWidth = AlertBoxes.rimWidth; path.stroke()
                }
                // Template images are tinted by the menu bar; emulate by masking with the foreground colour.
                let tinted = NSImage(size: icon.size, flipped: false) { r in
                    icon.draw(in: r); fg.set(); r.fill(using: .sourceAtop); return true
                }
                tinted.draw(at: NSPoint(x: x, y: 2), from: .zero, operation: .sourceOver, fraction: 1)
                x += icon.size.width + spacing
            }
            return true
        }
        // Render at 2x like the real (Retina) menu bar, so 1-pixel misalignments are visible.
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: 52, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = img.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(origin: .zero, size: img.size))
        NSGraphicsContext.restoreGraphicsState()
        let url = out.appendingPathComponent("menubar-\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print(url.path)
    }

    // RENDER_HOVER=0…1 draws every chart as if the pointer were at that fraction of its samples,
    // with the histories filled to capacity so the readout's edge placement shows.
    ChartHover.preview = ProcessInfo.processInfo.environment["RENDER_HOVER"].flatMap(Double.init)
    if ChartHover.preview != nil {
        for _ in 0..<Series.capacity {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            sampler.sampleNow()
        }
    }
    let settings = Settings()
    settings.range = range
    AlertValue.flat = true
    for module in Module.allCases {
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: PopoverView(module: module, s: sampler, settings: settings))
            host.appearance = NSAppearance(named: appearance)
            host.wantsLayer = true  // cacheDisplay captures only the view, so give it the popover's backdrop
            host.layer?.backgroundColor = (appearance == .darkAqua ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.96, alpha: 1)).cgColor
            let size = host.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.backgroundColor = appearance == .darkAqua ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.96, alpha: 1)
            window.contentView = host
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            // cacheDisplay renders in the display's colour space; its ICC profile carries the
            // display's serial number, so convert before writing a PNG that may get published.
            guard let rep = rep.converting(to: .sRGB, renderingIntent: .default) else { continue }
            let url = out.appendingPathComponent("\(module.rawValue)-\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print(url.path, Int(size.width), "x", Int(size.height))
            window.orderOut(nil)
        }
    }
}

/// Deterministic noise for the synthetic history (the same picture every run).
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}
