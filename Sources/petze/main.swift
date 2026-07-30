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

    // Metric toggles, outermost first. Battery hugs the screen edge,
    // CPU stacks inside it, memory inside that.
    private let metricOrder: [(key: String, title: String)] = [
        ("battery", "Battery"),
        ("cpu", "CPU load"),
        ("memory", "Memory used"),
    ]

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
        _ = cpu.sample() // prime tick counters so the first refresh has a delta
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

    private func refresh() {
        let battery = BatteryState.read()
        var metrics: [Metric] = []
        var slot = 0 // enabled metrics keep their row even while a sample is pending

        if isEnabled("battery") {
            if battery.isPresent {
                metrics.append(Metric(key: "battery", slot: slot,
                                      fraction: battery.percent, color: battery.color))
            }
            slot += 1
        }
        if isEnabled("cpu") {
            if let load = cpu.sample() {
                metrics.append(Metric(key: "cpu", slot: slot,
                                      fraction: load, color: loadColor(load)))
            }
            slot += 1
        }
        if isEnabled("memory") {
            if let used = memoryUsedFraction() {
                metrics.append(Metric(key: "memory", slot: slot,
                                      fraction: used, color: loadColor(used)))
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

        let linesHeader = NSMenuItem(title: "Lines (outermost first)", action: nil, keyEquivalent: "")
        linesHeader.isEnabled = false
        menu.addItem(linesHeader)
        for metric in metricOrder {
            let item = NSMenuItem(title: metric.title,
                                  action: #selector(toggleMetric(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = metric.key
            item.state = isEnabled(metric.key) ? .on : .off
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
