import AppKit
import Darwin

// A native run-loop check of the production presentation classes. It creates
// only a temporary menu-bar item with synthetic values: no profile store,
// credentials, network requests, or changes to the installed app.
@MainActor
private final class CountingUsageLabel: MenuBarUsageLabel {
    var draws = 0
    var layouts = 0

    override func draw(_ dirtyRect: NSRect) {
        draws += 1
        super.draw(dirtyRect)
    }

    override func layout() {
        layouts += 1
        super.layout()
    }
}

private func cpuTime() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}

private func log(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
}

@MainActor
private final class PerformanceCheck: NSObject, NSApplicationDelegate {
    let duration: TimeInterval
    private var item: NSStatusItem?
    private var presentation: MenuBarStatusPresentation?
    private lazy var label = CountingUsageLabel()
    private var timer: Timer?
    private var startedAt = 0.0
    private var startedCPU = 0.0
    private var previousCPU = 0.0
    private var previousTime = 0.0
    private var previousDraws = 0
    private var previousLayouts = 0
    private var refreshes = 0
    private var excessiveRedraws = false

    init(duration: TimeInterval) { self.duration = duration }

    func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.item = item
        presentation = MenuBarStatusPresentation(
            statusItem: item,
            icon: NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil) ?? NSImage(),
            usageLabel: label
        )
        refresh()
        log("Synthetic menu-bar check; duration=\(Int(duration))s; refresh interval=180s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
            startedAt = ProcessInfo.processInfo.systemUptime
            previousTime = startedAt
            startedCPU = cpuTime()
            previousCPU = startedCPU
            previousDraws = label.draws
            previousLayouts = label.layouts
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    private func refresh() {
        // Include duplicate values, a width change, unavailable data, and
        // icon/text transitions across refreshes.
        let titles = ["5h 33%\nW 48%", "5h 33%\nW 48%", "5h 100%\nW 100%", "—"]
        if refreshes == 3 { presentation?.showIcon(toolTip: "Synthetic icon") }
        let title = titles[refreshes % titles.count]
        presentation?.showUsage(
            title: title,
            toolTip: "Synthetic check \(refreshes)",
            accessibilityValue: title.replacingOccurrences(of: "\n", with: ", ")
        )
        refreshes += 1
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let cpu = cpuTime()
        let elapsed = now - startedAt
        let draws = label.draws - previousDraws
        let layouts = label.layouts - previousLayouts
        excessiveRedraws = excessiveRedraws || draws > 1_000 || layouts > 1_000
        log(String(format: "t=%.0fs cpu=%.3f%% draws=%d layouts=%d", elapsed,
                   100 * (cpu - previousCPU) / (now - previousTime), draws, layouts))
        previousCPU = cpu
        previousTime = now
        previousDraws = label.draws
        previousLayouts = label.layouts

        if elapsed >= duration {
            let average = 100 * (cpu - startedCPU) / elapsed
            let passed = average < 1 && !excessiveRedraws
            log(String(format: "%@ average_cpu=%.3f%% refreshes=%d", passed ? "PASS" : "FAIL", average, refreshes))
            timer?.invalidate()
            presentation?.invalidate()
            if let item { NSStatusBar.system.removeStatusItem(item) }
            exit(passed ? 0 : 1)
        }
        if elapsed >= Double(refreshes) * 180 {
            refresh()
        }
    }
}

@main
private enum MenuBarPerformanceMain {
    @MainActor
    static func main() {
        let argument = CommandLine.arguments.dropFirst().first ?? "600"
        guard let duration = TimeInterval(argument), duration.isFinite, duration >= 30 else {
            log("Usage: check-menu-bar-performance.sh [seconds >= 30; default 600]")
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let check = PerformanceCheck(duration: duration)
        app.delegate = check
        DispatchQueue.main.async { check.start() }
        withExtendedLifetime(check) { app.run() }
    }
}
