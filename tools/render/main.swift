// Renders each module's popover offscreen to PNG (light + dark), for checking layout without
// clicking the menu bar. Build/run: make render   → build/render/<module>-<appearance>.png
import AppKit
import SwiftUI

MainActor.assumeIsolated {
    _ = NSApplication.shared
    let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/render")
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let sampler = Sampler(interval: 3600)  // timer effectively off; sample manually below
    sampler.procViewers = 1
    for _ in 0..<6 {  // hardware energy counters update in 1–2 s batches; give them two updates
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        sampler.sampleNow()
    }
    // Menu bar strip (same drawing code as the real status items), light and dark.
    let n = sampler.now
    typealias Seg = StatusImage.Segment
    let strip: [NSImage] = [NSImage]() + [
        StatusImage.make(label: "NET", segments: [Seg(text: "↑\u{2009}" + Fmt.rate(n.tx), key: "net.tx"),
                                                  Seg(text: "↓\u{2009}" + Fmt.rate(n.rx), key: "net.rx")]),
        StatusImage.make(label: "CPU", segments: [Seg(text: Fmt.pct(n.cpuTotal), key: "cpu.pct"),
                                                  Seg(text: Fmt.watts(n.cpuW), key: "cpu.w")]),
        StatusImage.make(label: "GPU", segments: [Seg(text: Fmt.pct(n.gpuUtil), key: "gpu.pct"),
                                                  Seg(text: Fmt.watts(n.gpuW), key: "gpu.w")]),
        StatusImage.make(label: "MEM", segments: [Seg(text: Fmt.pct(n.memFraction), key: "mem.pct"),
                                                  Seg(text: Fmt.watts(n.dramW), key: "mem.w")]),
        StatusImage.make(label: nil, symbol: "thermometer.medium",
                         segments: [Seg(text: Fmt.temp(n.cpuTemp), key: "sns.cpu", label: "CPU"),
                                    Seg(text: Fmt.temp(n.gpuTemp), key: "sns.gpu", label: "GPU"),
                                    Seg(text: Fmt.watts(n.bodyW), key: "sns.w")]),
    ].map(\.image)
    for (name, bg, fg) in [("light", NSColor(white: 0.93, alpha: 1), NSColor.black), ("dark", NSColor(white: 0.12, alpha: 1), NSColor.white)] {
        let spacing: CGFloat = 12, width = strip.reduce(0) { $0 + $1.size.width + spacing } + spacing
        let img = NSImage(size: NSSize(width: width, height: 26), flipped: false) { rect in
            bg.setFill(); rect.fill()
            var x = spacing
            for icon in strip {
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

    let settings = Settings()
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
