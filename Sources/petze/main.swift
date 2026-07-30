import AppKit
import IOKit.ps

// MARK: - Metric model

struct Metric {
    let key: String
    let slot: Int          // fixed stacking row, so lines never swap places
    let fraction: CGFloat  // 0...1, drawn as line length
    let color: NSColor
}

/// Shared color scale for load-style metrics (CPU, memory).
func loadColor(_ fraction: Double) -> NSColor {
    if fraction < 0.60 { return .systemGreen }
    if fraction < 0.85 { return .systemYellow }
    return .systemRed
}

// MARK: - Battery

struct BatteryState {
    var percent: Double = 0        // 0...1
    var isCharging = false
    var onAC = false
    var isPresent = true

    // Color communicates what the battery is doing:
    //   charging            -> green
    //   full / idle on AC   -> blue
    //   discharging         -> yellow, or red when low
    var color: NSColor {
        if isCharging { return .systemGreen }
        if onAC { return .systemBlue }
        if percent <= 0.20 { return .systemRed }
        return .systemYellow
    }

    static func read() -> BatteryState {
        var state = BatteryState()
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { state.isPresent = false; return state }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            guard info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }

            let current = info[kIOPSCurrentCapacityKey] as? Double ?? 0
            let max = info[kIOPSMaxCapacityKey] as? Double ?? 100
            state.percent = max > 0 ? current / max : 0
            state.isCharging = info[kIOPSIsChargingKey] as? Bool ?? false
            state.onAC = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return state
        }
        state.isPresent = false
        return state
    }
}

// MARK: - CPU

/// Total CPU usage from host tick deltas between samples.
final class CPUSampler {
    private var prev = host_cpu_load_info()
    private var primed = false

    func sample() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        defer { prev = info; primed = true }
        guard primed else { return nil }

        let user = Double(info.cpu_ticks.0 &- prev.cpu_ticks.0)
        let sys = Double(info.cpu_ticks.1 &- prev.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2 &- prev.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3 &- prev.cpu_ticks.3)
        let total = user + sys + idle + nice
        return total > 0 ? (user + sys + nice) / total : nil
    }
}

// MARK: - Memory

/// Fraction of physical RAM in use (active + wired + compressed).
func memoryUsedFraction() -> Double? {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(
        MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    let pageSize = Double(vm_kernel_page_size)
    let used = Double(stats.active_count &+ stats.wire_count &+ stats.compressor_page_count) * pageSize
    return used / Double(ProcessInfo.processInfo.physicalMemory)
}

// MARK: - Network

/// Bytes/sec in and out, summed over non-loopback interfaces.
final class NetworkSampler {
    private var prevIn: UInt64 = 0
    private var prevOut: UInt64 = 0
    private var prevTime: TimeInterval = 0

    func sample() -> (inBps: Double, outBps: Double)? {
        var totalIn: UInt64 = 0, totalOut: UInt64 = 0
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return nil }
        defer { freeifaddrs(addrs) }

        var cursor = addrs
        while let ifa = cursor?.pointee {
            defer { cursor = ifa.ifa_next }
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK),
                  let data = ifa.ifa_data else { continue }
            if String(cString: ifa.ifa_name).hasPrefix("lo") { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            totalIn &+= UInt64(stats.ifi_ibytes)
            totalOut &+= UInt64(stats.ifi_obytes)
        }

        let now = Date().timeIntervalSinceReferenceDate
        defer { prevIn = totalIn; prevOut = totalOut; prevTime = now }
        guard prevTime > 0, now > prevTime else { return nil }
        let dt = now - prevTime
        // per-interface counters can wrap (32-bit); treat a wrap as zero delta
        let dIn = totalIn >= prevIn ? Double(totalIn &- prevIn) : 0
        let dOut = totalOut >= prevOut ? Double(totalOut &- prevOut) : 0
        return (dIn / dt, dOut / dt)
    }
}

/// Throughput has no natural 100%, so the line is log-scaled: 10 KB/s rounds
/// to zero, then each quarter of the line is one decade up to 100 MB/s.
func netFraction(_ bps: Double) -> CGFloat {
    guard bps > 10_000 else { return 0 }
    return CGFloat(min(log10(bps / 10_000) / 4.0, 1))
}

// MARK: - Overlay position

enum LinePosition: String, CaseIterable {
    case top, bottom, perimeter

    var title: String {
        switch self {
        case .top: return "Top edge"
        case .bottom: return "Bottom edge"
        case .perimeter: return "Around screen"
        }
    }
}

// MARK: - Overlay view

/// Each metric is a CAShapeLayer stroked along its full path; the visible
/// length is `strokeEnd`, so length and color changes animate smoothly.
final class OverlayView: NSView {
    var thickness: CGFloat = 4
    private var shapeLayers: [String: CAShapeLayer] = [:]
    private var lastPosition: LinePosition?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(metrics: [Metric], position: LinePosition) {
        let positionChanged = position != lastPosition
        lastPosition = position
        let scale = window?.backingScaleFactor ?? 2

        let liveKeys = Set(metrics.map(\.key))
        for (key, shape) in shapeLayers where !liveKeys.contains(key) {
            shape.removeFromSuperlayer()
            shapeLayers[key] = nil
        }

        for metric in metrics {
            let shape: CAShapeLayer
            if let existing = shapeLayers[metric.key] {
                shape = existing
            } else {
                shape = CAShapeLayer()
                shape.fillColor = nil
                shape.lineCap = .butt
                shape.strokeStart = 0
                shape.strokeEnd = 0 // first update animates the line growing in
                layer!.addSublayer(shape)
                shapeLayers[metric.key] = shape
            }

            // Geometry changes must not animate (morphing a line into a
            // rectangle looks broken) — apply them with actions disabled.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shape.frame = bounds
            shape.contentsScale = scale
            shape.lineWidth = thickness
            shape.path = strokePath(for: position, index: metric.slot)
            if positionChanged {
                shape.strokeEnd = 0 // regrow from the start of the new path
            }
            CATransaction.commit()

            // Value changes glide.
            CATransaction.begin()
            CATransaction.setAnimationDuration(1.2)
            CATransaction.setAnimationTimingFunction(
                CAMediaTimingFunction(name: .easeInEaseOut))
            shape.strokeEnd = min(max(metric.fraction, 0), 1)
            shape.strokeColor = metric.color.cgColor
            CATransaction.commit()
        }
    }

    /// Full-length path for a metric line; `strokeEnd` trims it to the value.
    /// Perimeter paths run clockwise from the top-left corner, nested inward
    /// by stack index.
    private func strokePath(for position: LinePosition, index: Int) -> CGPath {
        let path = CGMutablePath()
        let offset = CGFloat(index) * thickness
        switch position {
        case .top:
            let y = bounds.height - thickness / 2 - offset
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: bounds.width, y: y))
        case .bottom:
            let y = thickness / 2 + offset
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: bounds.width, y: y))
        case .perimeter:
            let inset = thickness / 2 + offset
            let r = bounds.insetBy(dx: inset, dy: inset)
            path.move(to: CGPoint(x: r.minX, y: r.maxY))
            path.addLine(to: CGPoint(x: r.maxX, y: r.maxY)) // top
            path.addLine(to: CGPoint(x: r.maxX, y: r.minY)) // right
            path.addLine(to: CGPoint(x: r.minX, y: r.minY)) // bottom
            path.addLine(to: CGPoint(x: r.minX, y: r.maxY)) // left
        }
        return path
    }
}

// MARK: - Overlay window (transparent, click-through, above everything)

final class OverlayWindow: NSWindow {
    let overlayView = OverlayView()

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless,
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        contentView = overlayView
        setFrame(screen.frame, display: true)
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var windows: [OverlayWindow] = []
    private var timer: Timer?
    private let cpu = CPUSampler()
    private let net = NetworkSampler()

    // Keys of lines auto mode is currently showing; entry and exit use
    // different thresholds so lines don't flap at the boundary.
    private var autoShown: Set<String> = []

    // Stacking order, outermost first. Battery hugs the screen edge,
    // the rest nest inward.
    private let metricOrder: [(key: String, title: String)] = [
        ("battery", "Battery"),
        ("cpu", "CPU load"),
        ("memory", "Memory used"),
        ("netin", "Network in"),
        ("netout", "Network out"),
    ]

    private var autoMode: Bool = {
        UserDefaults.standard.object(forKey: "autoMode") as? Bool ?? true
    }() {
        didSet { UserDefaults.standard.set(autoMode, forKey: "autoMode") }
    }

    private var position: LinePosition = {
        LinePosition(rawValue: UserDefaults.standard.string(forKey: "position") ?? "") ?? .top
    }() {
        didSet { UserDefaults.standard.set(position.rawValue, forKey: "position") }
    }

    private func isEnabled(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: "show.\(key)") as? Bool ?? true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        rebuildOverlays()
        _ = cpu.sample() // prime counters so the first refresh has deltas
        _ = net.sample()
        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func screensChanged() {
        rebuildOverlays()
        refresh()
    }

    private func rebuildOverlays() {
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map { screen in
            let window = OverlayWindow(screen: screen)
            window.orderFrontRegardless()
            return window
        }
    }

    /// Auto mode: memory is the always-on anchor; everything else appears
    /// only while it has something to say. Entry thresholds are higher than
    /// exit thresholds (hysteresis) so lines don't flicker at the boundary.
    private func autoWants(_ key: String, battery: BatteryState,
                           cpuLoad: Double?, netRate: Double?) -> Bool {
        let shown = autoShown.contains(key)
        switch key {
        case "memory":
            return true
        case "battery":
            guard battery.isPresent else { return false }
            if battery.isCharging { return true }
            if battery.onAC { return false } // full / holding: nothing to say
            return battery.percent <= (shown ? 0.45 : 0.40)
        case "cpu":
            guard let load = cpuLoad else { return shown }
            return load >= (shown ? 0.45 : 0.60)
        case "netin", "netout":
            guard let rate = netRate else { return shown }
            return rate >= (shown ? 100_000 : 500_000)
        default:
            return false
        }
    }

    private func refresh() {
        let battery = BatteryState.read()
        let cpuLoad = cpu.sample()
        let memUsed = memoryUsedFraction()
        let netRates = net.sample()

        let values: [String: (fraction: CGFloat, color: NSColor)?] = [
            "battery": battery.isPresent
                ? (CGFloat(battery.percent), battery.color) : nil,
            "cpu": cpuLoad.map { (CGFloat($0), loadColor($0)) },
            "memory": memUsed.map { (CGFloat($0), loadColor($0)) },
            "netin": netRates.map { (netFraction($0.inBps), NSColor.systemTeal) },
            "netout": netRates.map { (netFraction($0.outBps), NSColor.systemPurple) },
        ]

        var metrics: [Metric] = []
        var slot = 0 // active metrics keep their row even while a sample is pending
        for (key, _) in metricOrder {
            let active: Bool
            if autoMode {
                let netRate = key == "netin" ? netRates?.inBps
                            : key == "netout" ? netRates?.outBps : nil
                active = autoWants(key, battery: battery,
                                   cpuLoad: cpuLoad, netRate: netRate)
                if active { autoShown.insert(key) } else { autoShown.remove(key) }
            } else {
                active = isEnabled(key)
            }
            guard active else { continue }
            if let value = values[key] ?? nil {
                metrics.append(Metric(key: key, slot: slot,
                                      fraction: value.fraction, color: value.color))
            }
            slot += 1
        }

        if ProcessInfo.processInfo.environment["PETZE_DEBUG"] != nil {
            let desc = metrics.map { "\($0.key)=\(String(format: "%.2f", $0.fraction))" }
            FileHandle.standardError.write(Data("metrics: \(desc.joined(separator: " "))\n".utf8))
        }
        for window in windows {
            window.overlayView.update(metrics: metrics, position: position)
        }
        updateStatusItem(with: battery)
    }

    private func updateStatusItem(with battery: BatteryState) {
        guard let button = statusItem.button else { return }
        let symbol = battery.isCharging ? "bolt.fill" : "minus"
        let percent = Int((battery.percent * 100).rounded())
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "petze")
        button.title = battery.isPresent ? " \(percent)%" : ""
        button.imagePosition = .imageLeading
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let linesHeader = NSMenuItem(title: "Lines", action: nil, keyEquivalent: "")
        linesHeader.isEnabled = false
        menu.addItem(linesHeader)

        let auto = NSMenuItem(title: "Automatic — only what matters",
                              action: #selector(selectAuto), keyEquivalent: "")
        auto.target = self
        auto.state = autoMode ? .on : .off
        menu.addItem(auto)

        let manual = NSMenuItem(title: "Manual", action: #selector(selectManual), keyEquivalent: "")
        manual.target = self
        manual.state = autoMode ? .off : .on
        menu.addItem(manual)

        for metric in metricOrder {
            let item = NSMenuItem(title: metric.title,
                                  action: autoMode ? nil : #selector(toggleMetric(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.indentationLevel = 1
            item.representedObject = metric.key
            item.state = (autoMode ? autoShown.contains(metric.key)
                                   : isEnabled(metric.key)) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let posHeader = NSMenuItem(title: "Line position", action: nil, keyEquivalent: "")
        posHeader.isEnabled = false
        menu.addItem(posHeader)
        for pos in LinePosition.allCases {
            let item = NSMenuItem(title: pos.title,
                                  action: #selector(selectPosition(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = pos.rawValue
            item.state = pos == position ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit petze",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    @objc private func selectAuto() {
        autoMode = true
        refresh()
    }

    @objc private func selectManual() {
        autoMode = false
        refresh()
    }

    @objc private func toggleMetric(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        UserDefaults.standard.set(!isEnabled(key), forKey: "show.\(key)")
        refresh()
    }

    @objc private func selectPosition(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let pos = LinePosition(rawValue: raw) else { return }
        position = pos
        refresh()
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
