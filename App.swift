import AppKit
import SwiftUI
import IOKit
import Darwin

private let helperPath = "/Library/PrivilegedHelperTools/local.lidrun.guard"
private let daemonPath = "/Library/LaunchDaemons/local.lidrun.guard.plist"
private let statePath = "/Library/Application Support/LidRun/state.json"
private let service = "system/local.lidrun.guard"

func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func appleQuote(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\""
}

func command(_ path: String, _ arguments: [String]) throws -> String {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(data: data, encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else { throw NSError(domain: "LidRun", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: output]) }
    return output
}

func powerProperty(_ name: String) -> Bool? {
    let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard entry != 0 else { return nil }
    defer { IOObjectRelease(entry) }
    return IORegistryEntryCreateCFProperty(entry, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
}

@MainActor final class Controller: ObservableObject {
    @Published var duration = 3600 { didSet { UserDefaults.standard.set(duration, forKey: "duration") } }
    @Published var mode = "battery" { didSet { UserDefaults.standard.set(mode, forKey: "mode") } }
    @Published var busy = false
    @Published var sleepDisabled: Bool? = nil
    @Published var phase = "idle"
    @Published var reason = ""
    @Published var expiresAt = 0.0
    @Published var battery = ""
    @Published var message = "请选择时长，然后开启。"
    @Published var errorText = ""
    @Published var remainingSeconds = 0
    var guardian: Process?
    var guardianInput: Pipe?
    var timer: Timer?
    var lastLoggedUptime = -Double.infinity
    var lastLid: Bool?
    var lastLoggedPhase = ""
    private lazy var diagnosticWriter = DiagnosticWriter(directory: logsURL)
    private let heartbeatFormatter = ISO8601DateFormatter()
    var foreignSession = false
    var ownerPID = 0
    var startingAt: Date?
    var onChange: (() -> Void)?

    var isActive: Bool { phase == "active" && sleepDisabled == true && ownsSession }
    var ownsSession: Bool { guardian != nil && ownerPID == Int(guardian!.processIdentifier) }
    var pending: Bool { ["prepared", "activating", "active", "restoring"].contains(phase) }
    var canStop: Bool { guardian != nil || (pending && !foreignSession) }
    var remaining: String {
        let seconds = remainingSeconds
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    var headline: String {
        if busy { return "等待系统授权…" }
        if isActive { return "合盖保持运行已开启" }
        if phase == "restoring" { return "正在恢复睡眠设置…" }
        if ["prepared", "activating"].contains(phase) && guardian != nil { return "正在启动保护进程…" }
        if sleepDisabled == nil { return "未能读取系统睡眠状态" }
        if sleepDisabled == true { return "系统睡眠已被其他设置禁用" }
        return "正常睡眠模式"
    }

    init() {
        let saved = UserDefaults.standard.integer(forKey: "duration")
        if [1800, 3600, 7200, 14400, 28800].contains(saved) { duration = saved }
        if let savedMode = UserDefaults.standard.string(forKey: "mode"), ["battery", "ac"].contains(savedMode) { mode = savedMode }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 0.3
    }

    private func publish<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<Controller, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    func refresh() {
        publish(\.sleepDisabled, powerProperty("SleepDisabled"))
        foreignSession = false
        if let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            publish(\.phase, json["phase"] as? String ?? "idle")
            publish(\.reason, json["reason"] as? String ?? "")
            publish(\.expiresAt, json["expiresAt"] as? Double ?? 0)
            ownerPID = json["ownerPID"] as? Int ?? 0
            foreignSession = pending && !ownsSession
            if phase == "restoring", let error = json["error"] as? String, !error.isEmpty { publish(\.errorText, error) }
            if phase == "restored" && !busy {
                if guardian != nil { closeGuardian() }
                publish(\.message, reasonMessage(reason))
            }
        } else { publish(\.phase, "idle"); ownerPID = 0 }
        if let started = startingAt, !busy, guardian != nil, !isActive,
           Date().timeIntervalSince(started) > 20 {
            closeGuardian()
            startingAt = nil
            errorText = "保护进程未确认开启。请使用“恢复睡眠”检查并恢复，然后重试。"
        }
        if isActive { startingAt = nil }
        let remaining = isActive ? max(0, min(86_400, expiresAt - Date().timeIntervalSince1970)) : 0
        publish(\.remainingSeconds, Int(remaining.isFinite ? remaining : 0))
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if entry != 0 {
            let percent = IORegistryEntryCreateCFProperty(entry, "CurrentCapacity" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
            let plugged = IORegistryEntryCreateCFProperty(entry, "ExternalConnected" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool ?? false
            publish(\.battery, "\(plugged ? "接着电源" : "使用电池") · 电量 \(percent.map(String.init) ?? "未知")%")
            IOObjectRelease(entry)
        }
        logHeartbeat()
        onChange?()
    }

    func start() {
        guard !busy, !pending, guardian == nil else { return }
        guard sleepDisabled == false else {
            errorText = "无法确认当前睡眠设置正常，或已有其他工具禁用了睡眠。请先恢复。"
            return
        }
        let child = Process(), input = Pipe()
        child.executableURL = Bundle.main.executableURL
        child.arguments = ["--hold"]
        child.standardInput = input
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        do { try child.run() } catch { errorText = error.localizedDescription; return }
        // Only this UI owns the writer. A crash or logout closes it, and the child exits.
        try? input.fileHandleForReading.close()
        guardian = child
        guardianInput = input
        ownerPID = Int(child.processIdentifier)
        busy = true
        errorText = ""
        startingAt = Date()
        let resource = Bundle.main.url(forResource: "LidRunGuard", withExtension: nil)!.path
        let duration = self.duration, mode = self.mode, pid = child.processIdentifier
        let script = """
        set -eu
        /usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
        if test -e \(shellQuote(helperPath)); then
          if ! /usr/bin/cmp -s \(shellQuote(resource)) \(shellQuote(helperPath)); then
            echo '后台工具版本不同，请先在更多菜单卸载后台保护进程，再重试。' >&2
            exit 1
          fi
        else
          /usr/bin/install -o root -g wheel -m 755 \(shellQuote(resource)) \(shellQuote(helperPath))
        fi
        \(shellQuote(helperPath)) --prepare \(pid) \(duration) \(shellQuote(mode))
        if ! /bin/launchctl print \(service) >/dev/null 2>&1; then
          if ! /bin/launchctl bootstrap system \(shellQuote(daemonPath)); then
            \(shellQuote(helperPath)) --restore
            exit 1
          fi
        fi
        /bin/launchctl kickstart \(service)
        """
        Task {
            let result = await Task.detached { () -> String? in
                do { _ = try command("/usr/bin/osascript", ["-e", "do shell script " + appleQuote(script) + " with administrator privileges"]); return nil }
                catch { return error.localizedDescription }
            }.value
            busy = false
            if let failure = result {
                closeGuardian()
                startingAt = nil
                errorText = failure.contains("-128") ? "已取消授权，未开启。" : failure
            } else { startingAt = Date(); message = "正在核验系统设置…" }
            refresh()
        }
    }

    func closeGuardian() {
        try? guardianInput?.fileHandleForWriting.close()
        guardianInput = nil
        guardian = nil
    }

    func stop() {
        guard !busy else { return }
        closeGuardian()
        startingAt = nil
        message = "已请求结束，保护进程会恢复原设置。"
        refresh()
    }

    func recover() {
        guard !busy else { return }
        closeGuardian()
        busy = true
        errorText = ""
        let script = "\(shellQuote(helperPath)) --restore"
        Task {
            let failure = await Task.detached { () -> String? in
                do { _ = try command("/usr/bin/osascript", ["-e", "do shell script " + appleQuote(script) + " with administrator privileges"]); return nil }
                catch { return error.localizedDescription }
            }.value
            busy = false
            if let failure { errorText = failure } else { message = "已恢复原来的睡眠设置。" }
            refresh()
        }
    }

    func uninstall() {
        guard !busy else { return }
        closeGuardian()
        busy = true
        let script = """
        set -eu
        \(shellQuote(helperPath)) --restore
        if /bin/launchctl print \(service) >/dev/null 2>&1; then
          /bin/launchctl bootout \(service)
        fi
        /bin/rm -f \(shellQuote(daemonPath)) \(shellQuote(helperPath))
        """
        Task {
            let failure = await Task.detached { () -> String? in
                do { _ = try command("/usr/bin/osascript", ["-e", "do shell script " + appleQuote(script) + " with administrator privileges"]); return nil }
                catch { return error.localizedDescription }
            }.value
            busy = false
            if let failure { errorText = failure } else { message = "后台保护进程已移除，睡眠设置已恢复。" }
            refresh()
        }
    }

    func reasonMessage(_ reason: String) -> String {
        switch reason {
        case "timeExpired": return "设定时长已结束，已恢复正常睡眠。"
        case "lowBattery": return "电量降至 20% 或更低，已恢复正常睡眠。"
        case "thermalPressure": return "系统报告较高温度压力，已恢复正常睡眠。"
        case "powerDisconnected": return "电源已断开，已恢复正常睡眠。"
        case "rebooted": return "检测到重启，已恢复之前的睡眠设置。"
        case "activationFailed": return "开启失败，已恢复原来的睡眠设置。"
        case "displaySleepFailed": return "未能可靠请求熄屏，已恢复正常睡眠。"
        case "lowPowerMode": return "已进入低电量模式，已恢复正常睡眠。"
        case "journalUnavailable": return "会话记录不可读，已按备份恢复睡眠设置。"
        case "sleepOverrideChanged": return "防睡眠设置已关闭，合盖保持运行已结束。需要继续时请重新开启。"
        case "sleepStatusUnavailable": return "未能确认系统睡眠状态，已恢复正常睡眠。"
        default: return "已结束，睡眠设置已恢复。"
        }
    }

    var logsURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/LidRun")
    }
    func logHeartbeat() {
        let lid = powerProperty("AppleClamshellState")
        let uptime = ProcessInfo.processInfo.systemUptime
        let interval: Double = pending || guardian != nil ? 10 : 60
        guard uptime - lastLoggedUptime >= interval || lid != lastLid || phase != lastLoggedPhase else { return }
        lastLoggedUptime = uptime; lastLid = lid; lastLoggedPhase = phase
        let now = Date()
        let row: [String: Any] = ["time": heartbeatFormatter.string(from: now), "uptime": uptime,
                                  "lidClosed": lid as Any? ?? NSNull(), "sleepDisabled": sleepDisabled as Any? ?? NSNull(), "phase": phase,
                                  "reason": reason]
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        diagnosticWriter.enqueue(data: data, date: now)
    }
    func flushLogs() async { await diagnosticWriter.flush() }
    func openLogs() { try? FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true); NSWorkspace.shared.open(logsURL) }
}

struct MainView: View {
    @ObservedObject var controller: Controller
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("合盖熄屏，后台运行").font(.title2.bold())
                    Text("LidRun · 本机任务保持运行").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Label(controller.headline, systemImage: controller.isActive ? "checkmark.circle.fill" : "moon.zzz.fill")
                    .font(.headline).foregroundStyle(controller.isActive ? .green : .primary)
                Text(controller.battery).font(.callout).foregroundStyle(.secondary)
                if controller.isActive { Text("剩余 \(controller.remaining)").font(.system(.title, design: .monospaced)).monospacedDigit() }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))

            Picker("保持时长", selection: $controller.duration) {
                Text("30 分钟").tag(1800); Text("1 小时").tag(3600); Text("2 小时").tag(7200)
                Text("4 小时").tag(14400); Text("8 小时").tag(28800)
            }.disabled(controller.busy || controller.pending || controller.guardian != nil)
            Picker("电源模式", selection: $controller.mode) {
                Text("接电和电池均可").tag("battery")
                Text("仅接电，拔电后结束").tag("ac")
            }.disabled(controller.busy || controller.pending || controller.guardian != nil)

            Text("合盖时自动请求熄屏；开盖后停止熄屏请求。")
                .font(.callout).foregroundStyle(.secondary)

            Text("到时、电量 ≤20%、低电量模式、系统温度压力较高，或软件退出时，自动恢复原睡眠设置。重启后也会恢复。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("合盖运行时请放在通风的桌面上，勿放入包中。开启需要系统管理员授权。")
                .font(.callout).fixedSize(horizontal: false, vertical: true)

            HStack {
                if controller.guardian != nil {
                    Button("结束并恢复睡眠") { controller.stop() }.buttonStyle(.borderedProminent).disabled(controller.busy)
                } else {
                    Button("开启合盖运行") { controller.start() }.buttonStyle(.borderedProminent)
                        .disabled(controller.busy || controller.pending || controller.sleepDisabled != false)
                }
                if controller.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("诊断日志") { controller.openLogs() }
            }
            Text(controller.message).font(.caption).foregroundStyle(.secondary)
            if !controller.errorText.isEmpty {
                Text(controller.errorText).font(.caption).foregroundStyle(.red).textSelection(.enabled).lineLimit(5)
            }
            HStack {
                Button("恢复睡眠") { controller.recover() }.disabled(controller.busy || !FileManager.default.fileExists(atPath: helperPath))
                Spacer()
                Menu("更多") {
                    Button("卸载后台保护进程") { controller.uninstall() }.disabled(controller.busy || !FileManager.default.fileExists(atPath: helperPath))
                    Button("退出并恢复睡眠") { NSApp.terminate(nil) }.disabled(controller.busy)
                }.frame(width: 90)
            }.font(.caption)
        }.padding(26).frame(width: 490)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let controller = Controller()
    let monitor = MonitorController()
    var window: NSWindow!
    var statusItem: NSStatusItem!
    private var keyboardMonitor: Any?
    private var lastStatusKey = ""
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "合盖继续运行 · LidRun"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: LidRunDashboard(controller: controller, monitor: monitor))
        window.minSize = NSSize(width: 1000, height: 730)
        window.setFrameAutosaveName("LidRunDashboardWindow")
        if !window.setFrameUsingName("LidRunDashboardWindow") { window.center() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemInvoked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        installNativeMenu()
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleShortcut(event)
        }
        controller.onChange = { [weak self] in
            self?.updateStatus()
            self?.monitor.noteLid(powerProperty("AppleClamshellState"))
        }
        monitor.onReopen = { [weak self] in self?.showWindow() }
        updateStatus(); showWindow()
    }
    func updateStatus() {
        let key = "\(controller.isActive):\(controller.headline)"
        guard key != lastStatusKey else { return }
        lastStatusKey = key
        statusItem?.button?.image = NSImage(systemSymbolName: controller.isActive ? "laptopcomputer.and.arrow.down" : "laptopcomputer", accessibilityDescription: "合盖继续运行")
        statusItem?.button?.title = controller.isActive ? " 运行中" : ""
        statusItem?.button?.toolTip = controller.headline
        statusItem?.button?.setAccessibilityLabel("合盖继续运行，" + controller.headline)
    }
    @objc private func statusItemInvoked() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp || event.modifierFlags.contains(.control),
           let button = statusItem.button {
            _ = statusMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: button)
        } else { showWindow() }
    }
    private func menuItem(_ title: String, _ action: Selector?, key: String = "", enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self; item.isEnabled = enabled
        return item
    }
    private func statusMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.addItem(menuItem(controller.headline, nil, enabled: false))
        menu.addItem(.separator())
        menu.addItem(menuItem("实时监控", #selector(showLive), key: "1"))
        menu.addItem(menuItem("合盖历史", #selector(showHistory), key: "2"))
        menu.addItem(menuItem("保持运行设置…", #selector(showSettings), key: "3"))
        if controller.canStop { menu.addItem(menuItem("结束并恢复睡眠", #selector(stopSession), enabled: !controller.busy)) }
        menu.addItem(.separator())
        menu.addItem(menuItem("诊断日志", #selector(showLogs)))
        menu.addItem(menuItem("退出并恢复睡眠", #selector(quitApplication), key: "q", enabled: !controller.busy))
        return menu
    }
    private func installNativeMenu() {
        let main = NSMenu()
        let appRoot = NSMenuItem(title: "LidRun", action: nil, keyEquivalent: ""); let app = NSMenu(title: "LidRun")
        app.autoenablesItems = false
        app.addItem(menuItem("关于合盖继续运行", #selector(showAbout)))
        app.addItem(.separator())
        app.addItem(menuItem("保持运行设置…", #selector(showSettings), key: ","))
        app.addItem(menuItem("隐藏合盖继续运行", #selector(hideApplication), key: "h"))
        app.addItem(.separator())
        app.addItem(menuItem("退出并恢复睡眠", #selector(quitApplication), key: "q"))
        appRoot.submenu = app; main.addItem(appRoot)
        let windowRoot = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        let windows = NSMenu(title: "窗口"); windows.autoenablesItems = false
        windows.addItem(menuItem("实时监控", #selector(showLive), key: "1"))
        windows.addItem(menuItem("合盖历史", #selector(showHistory), key: "2"))
        windows.addItem(menuItem("保持运行", #selector(showSettings), key: "3"))
        windows.addItem(.separator())
        windows.addItem(menuItem("刷新监控", #selector(refreshMonitor), key: "r"))
        windows.addItem(menuItem("关闭窗口", #selector(closeWindow), key: "w"))
        windows.addItem(menuItem("最小化", #selector(minimizeWindow), key: "m"))
        windowRoot.submenu = windows; main.addItem(windowRoot)
        NSApp.mainMenu = main; NSApp.windowsMenu = windows
    }
    private func handleShortcut(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers == .command, window.isKeyWindow || NSApp.isActive else { return event }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "1": showLive()
        case "2": showHistory()
        case "3", ",": showSettings()
        case "r": refreshMonitor()
        case "w": closeWindow()
        case "m": minimizeWindow()
        case "h": hideApplication()
        case "q": quitApplication()
        default: return event
        }
        return nil
    }
    @objc private func showLive() { monitor.section = .live; showWindow() }
    @objc private func showHistory() { monitor.section = .history; showWindow() }
    @objc private func showSettings() { monitor.section = .settings; showWindow() }
    @objc private func refreshMonitor() { monitor.requestSample() }
    @objc private func stopSession() { controller.stop() }
    @objc private func showLogs() { controller.openLogs() }
    @objc private func showAbout() { NSApp.orderFrontStandardAboutPanel(nil) }
    @objc private func quitApplication() { NSApp.terminate(nil) }
    @objc private func closeWindow() {
        if let key = NSApp.keyWindow { key.performClose(nil) } else { window.performClose(nil) }
    }
    @objc private func minimizeWindow() {
        if let key = NSApp.keyWindow { key.performMiniaturize(nil) } else { window.performMiniaturize(nil) }
    }
    @objc private func hideApplication() { NSApp.hide(nil) }
    @objc func showWindow() {
        monitor.windowVisible = true
        monitor.requestSample()
        if window.isMiniaturized { window.deminiaturize(nil) }
        if NSApp.isHidden { NSApp.unhide(nil) }
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) { monitor.windowVisible = false }
    func windowWillMiniaturize(_ notification: Notification) { monitor.windowVisible = false }
    private func updateWindowVisibility() {
        let visible = window.isVisible && !window.isMiniaturized && !NSApp.isHidden && window.occlusionState.contains(.visible)
        let changed = visible != monitor.windowVisible
        monitor.windowVisible = visible
        if visible && changed { monitor.requestSample() }
    }
    func windowDidDeminiaturize(_ notification: Notification) { updateWindowVisibility() }
    func windowDidChangeOcclusionState(_ notification: Notification) { updateWindowVisibility() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationDidHide(_ notification: Notification) { monitor.windowVisible = false }
    func applicationDidUnhide(_ notification: Notification) {
        updateWindowVisibility()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if controller.busy { showWindow(); return .terminateCancel }
        controller.closeGuardian()
        Task {
            await monitor.finish()
            await controller.flushLogs()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        controller.timer?.invalidate()
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main struct Entry {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--hold") {
            while !FileHandle.standardInput.readData(ofLength: 1).isEmpty {}
            return
        }
        if CommandLine.arguments.contains("--self-test") {
            precondition(shellQuote("a'b") == "'a'\\''b'")
            precondition(appleQuote("a\"b\\c") == "\"a\\\"b\\\\c\"")
            precondition(powerProperty("SleepDisabled") != nil)
            print("UI quoting and read-only power diagnostics passed")
            return
        }
        if CommandLine.arguments.contains("--monitor-self-test") {
            do {
                let samplingTests = try TelemetrySampler.selfTest()
                let historyTests = try HistoryStore.selfTest()
                let chartTests = try PlotPoint.selfTest()
                let diagnosticTests = try DiagnosticWriter.selfTest()
                print("Monitor tests passed: telemetry=\(samplingTests), history=\(historyTests), chart=\(chartTests), diagnostics=\(diagnosticTests)")
            } catch { fputs("Monitor self-test failed: \(error)\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.contains("--telemetry-probe") {
            Task {
                let sampler = TelemetrySampler()
                let first = await sampler.sample()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let second = await sampler.sample()
                do { print(String(data: try JSONEncoder().encode([first, second]), encoding: .utf8)!) }
                catch { fputs("Telemetry probe failed: \(error)\n", stderr) }
                CFRunLoopStop(CFRunLoopGetMain())
            }
            CFRunLoopRun()
            return
        }
        if let id = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0.processIdentifier != getpid() }) {
            existing.activate(options: [.activateAllWindows]); return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
