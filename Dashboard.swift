import AppKit
import SwiftUI
import Charts

// Use the property wrapper explicitly with the Command Line Tools SDK, which
// also exports a similarly named macro that requires Xcode's macro plug-in.
typealias LidViewState<Value> = SwiftUI.State<Value>

enum DashboardSection: String, CaseIterable {
    case live = "实时监控", history = "合盖历史", settings = "保持运行"
    var shortcut: KeyEquivalent { self == .live ? "1" : self == .history ? "2" : "3" }
}

@MainActor final class MonitorController: ObservableObject {
    @Published var section: DashboardSection = .live
    @Published var snapshot: TelemetrySnapshot?
    @Published var liveSamples: [TelemetrySnapshot] = []
    @Published var historyReports: [LidSessionReport] = []
    @Published var selectedHistoryID: String?
    @Published var sampling = false
    @Published var storageWarning: String?
    @Published var autoShowReport: Bool {
        didSet { UserDefaults.standard.set(autoShowReport, forKey: "autoShowReport") }
    }
    var windowVisible = true
    var onReopen: (() -> Void)?
    private let sampler = TelemetrySampler()
    private let store = HistoryStore()
    private var timer: Timer?
    private var lastSampleUptime = -Double.infinity
    private var lastNotifiedLid: Bool?
    private var lastSampledLid: Bool?
    private var sleepEventCount = 0
    private var handledSleepEventCount = 0
    private var pendingSample = false
    private var stopping = false
    private var observers: [NSObjectProtocol] = []

    init() {
        autoShowReport = UserDefaults.standard.object(forKey: "autoShowReport") as? Bool ?? true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.sleepEventCount += 1
                    self?.requestSample()
                }
            })
        }
        Task { historyReports = await store.reports(); requestSample() }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 0.3
    }

    func noteLid(_ closed: Bool?) {
        if let closed, closed != lastNotifiedLid {
            lastNotifiedLid = closed
            requestSample()
        }
    }

    private func tick() {
        var interval: Double = lastNotifiedLid == true ? 10 : (windowVisible ? 5 : 30)
        if snapshot?.thermalLevel ?? 0 >= 2 { interval = max(interval, 15) }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { interval = max(interval, 60) }
        if ProcessInfo.processInfo.systemUptime - lastSampleUptime >= interval { requestSample() }
    }

    func requestSample() {
        guard !stopping else { return }
        if sampling { pendingSample = true; return }
        sampling = true
        lastSampleUptime = ProcessInfo.processInfo.systemUptime
        Task {
            var reading = await sampler.sample()
            guard !stopping else { sampling = false; return }
            let eventCount = sleepEventCount
            reading.systemSleepObserved = eventCount != handledSleepEventCount
            handledSleepEventCount = eventCount
            if reading.systemSleepObserved || (reading.intervalSeconds ?? 0) > 90 {
                // Never present a sleep-spanning delta as current activity.
                reading.systemCPUPercent = nil
                reading.receivedBytesDelta = nil
                reading.sentBytesDelta = nil
                for index in reading.applications.indices {
                    reading.applications[index].cpuPercent = nil
                    reading.applications[index].cpuSecondsDelta = nil
                    reading.applications[index].receivedBytesDelta = nil
                    reading.applications[index].sentBytesDelta = nil
                    reading.applications[index].cpuEnergyJoulesDelta = nil
                }
                reading.limitations.append("睡眠或长停采后的第一帧仅显示即时读数，跨缺口的 CPU 与流量差分未计入。")
            }
            let reopened = lastSampledLid == true && reading.lidClosed == false
            if let closed = reading.lidClosed { lastSampledLid = closed }
            let reports = await store.ingest(reading)
            storageWarning = await store.storageWarning()
            snapshot = reading
            liveSamples.append(reading)
            liveSamples.removeAll { $0.timestamp < reading.timestamp - 1800 }
            if liveSamples.count > 360 { liveSamples.removeFirst(liveSamples.count - 360) }
            historyReports = reports
            if reopened, let latest = reports.first, !latest.isActive {
                selectedHistoryID = latest.id
                if autoShowReport { section = .history; onReopen?() }
            }
            sampling = false
            if pendingSample { pendingSample = false; requestSample() }
        }
    }

    func finish() async {
        stopping = true
        timer?.invalidate()
        await store.flush(endReason: "softwareExited")
    }

    var selectedReport: LidSessionReport? {
        historyReports.first(where: { $0.id == selectedHistoryID }) ?? historyReports.first
    }
}

enum MetricFormat {
    static func partial(_ formatted: String, keys: [String]?, metric: String) -> String {
        formatted == "—" ? formatted : (keys?.contains(metric) == true ? "≥ " + formatted : formatted)
    }
    static func number(_ value: Double?, digits: Int = 1, suffix: String = "") -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.*f", digits, value) + suffix
    }
    static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        if value == 0 { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: Int64(min(value, UInt64(Int64.max))), countStyle: .file)
    }
    static func rate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return bytes(UInt64(min(value, Double(Int64.max)))) + "/s"
    }
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "—" }
        guard seconds < Double(Int.max / 2), seconds > -Double(Int.max / 2) else { return "超出范围" }
        let total = max(0, Int(seconds))
        if total >= 3600 { return "\(total / 3600)小时\(total % 3600 / 60)分" }
        if total >= 60 { return "\(total / 60)分\(total % 60)秒" }
        return "\(total)秒"
    }
    static func cpuTime(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        return seconds < 60 ? number(seconds, digits: 2, suffix: "秒") : duration(seconds)
    }
    static func energy(_ wh: Double?) -> String {
        guard let wh, wh.isFinite else { return "—" }
        if wh > 0 && wh < 0.01 { return String(format: "%.2f mWh", wh * 1000) }
        return String(format: "%.3f Wh", wh)
    }
    static func thermal(_ level: Int) -> String { ["正常", "略高", "较高", "严重"][min(3, max(0, level))] }
    static func memoryPressure(_ level: Int?) -> String {
        switch level { case 1: return "正常"; case 2: return "警告"; case 4: return "严重"; default: return "未知" }
    }
    static func priority(_ name: String) -> Bool {
        ["chatgpt", "codex", "vpn", "lightxtreme", "闪连"].contains { name.lowercased().contains($0) }
    }
    static func displayName(_ name: String) -> String {
        name.lowercased() == "lightxtremeservice" ? "闪连 VPN 后台服务" : name
    }
    static func date(_ timestamp: Double, detailed: Bool = false) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = detailed ? "M月d日 HH:mm:ss" : "M月d日 HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}

struct MetricTile: View {
    var title: String
    var icon: String
    var value: String
    var detail: String
    var tint: Color = .accentColor
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.callout).foregroundStyle(tint)
            Text(value).font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }.frame(maxWidth: .infinity, minHeight: 106, alignment: .leading)
            .padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.05)))
            .accessibilityElement(children: .combine)
    }
}

private struct NavigationActivationClick: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            // Only navigation accepts the click that activates an inactive window.
            content.allowsWindowActivationEvents(true)
        } else {
            content
        }
    }
}

struct LidRunDashboard: View {
    @ObservedObject var controller: Controller
    @ObservedObject var monitor: MonitorController
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 43, height: 43)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("LidRun").font(.title3.bold())
                        Text("合盖熄屏 · 后台运行").font(.caption2).foregroundStyle(.secondary)
                    }
                }.padding(.bottom, 8)
                ForEach(DashboardSection.allCases, id: \.self) { section in
                    Button { monitor.section = section } label: {
                        Label(section.rawValue, systemImage: section == .live ? "waveform.path.ecg" : section == .history ? "clock.arrow.circlepath" : "laptopcomputer.and.arrow.down")
                            .font(.system(size: 14, weight: monitor.section == section ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(monitor.section == section ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).modifier(NavigationActivationClick())
                        .keyboardShortcut(section.shortcut, modifiers: .command)
                        .accessibilityAddTraits(monitor.section == section ? .isSelected : [])
                }
                Spacer()
                Label(controller.isActive ? "合盖保护已开启" : "合盖保护未开启", systemImage: controller.isActive ? "checkmark.shield.fill" : "moon.zzz")
                    .font(.caption).foregroundStyle(controller.isActive ? .green : .secondary)
                Text("监控不会自动开启保护，\n也不会关闭其他应用。")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("诊断日志") { controller.openLogs() }.font(.caption)
                Text("v2.1.1 · 数据只保存在本机").font(.caption2).foregroundStyle(.tertiary)
            }.padding(20).frame(width: 198).background(.ultraThinMaterial)
            Divider()
            Group {
                switch monitor.section {
                case .live: LiveMonitorView(monitor: monitor, controller: controller)
                case .history: HistoryPanel(monitor: monitor)
                case .settings:
                    ScrollView {
                        VStack(spacing: 18) {
                            MainView(controller: controller)
                            Toggle("开盖后自动显示本次合盖报告", isOn: $monitor.autoShowReport)
                                .font(.callout).padding(.horizontal, 26).frame(width: 490)
                            Text("前台查看每 5 秒采样；合盖每 10 秒，关闭或最小化窗口后每 30 秒。温度压力较高或低电量模式下会降低频率。历史最多保留 30 天、64 MB。")
                                .font(.caption).foregroundStyle(.secondary).frame(width: 438, alignment: .leading)
                        }.padding(.bottom, 26).frame(maxWidth: .infinity)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(minWidth: 980, minHeight: 700).background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct LiveMonitorView: View {
    @ObservedObject var monitor: MonitorController
    @ObservedObject var controller: Controller
    @LidViewState private var chartMetric: ChartMetric = .temperature
    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("运行一目了然").font(.system(size: 27, weight: .bold))
                        Text(monitor.snapshot.map { "更新于 " + MetricFormat.date($0.timestamp, detailed: true) } ?? "正在读取本机数据…")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if monitor.sampling { ProgressView().controlSize(.small) }
                    Button { monitor.requestSample() } label: { Image(systemName: "arrow.clockwise") }
                        .help("刷新监控（⌘R）").accessibilityLabel("刷新监控").keyboardShortcut("r", modifiers: .command)
                }
                if let sample = monitor.snapshot {
                    LazyVGrid(columns: columns, spacing: 12) {
                        MetricTile(title: "芯片温度", icon: "thermometer.medium", value: MetricFormat.number(sample.chipTemperatureC, suffix: "°C"), detail: "系统温度压力：" + MetricFormat.thermal(sample.thermalLevel), tint: sample.thermalLevel >= 2 ? .orange : .purple)
                        MetricTile(title: "CPU 使用率", icon: "cpu", value: MetricFormat.number(sample.systemCPUPercent, suffix: "%"), detail: "全机 CPU 总容量为 100%", tint: .blue)
                        MetricTile(title: "内存占用（含缓存）", icon: "memorychip", value: MetricFormat.bytes(sample.memoryUsedBytes), detail: "总内存 " + MetricFormat.bytes(sample.memoryTotalBytes) + " · 压力" + MetricFormat.memoryPressure(sample.memoryPressure), tint: .indigo)
                        MetricTile(title: "整机接口流量", icon: "arrow.up.arrow.down", value: MetricFormat.rate(sample.receivedBytesPerSecond), detail: "↓ 下载   ↑ " + MetricFormat.rate(sample.sentBytesPerSecond), tint: .cyan)
                        MetricTile(title: sample.systemPowerWatts != nil ? "整机估算功率" : "电池放电功率", icon: "bolt.fill", value: MetricFormat.number(sample.estimatedLoadWatts, suffix: " W"), detail: sample.systemPowerWatts != nil ? "整机直流负载遥测" : sample.estimatedLoadWatts != nil ? "电池放电遥测" : "没有可用能量遥测", tint: .orange)
                        MetricTile(title: "电池状态", icon: sample.onAC == true ? "battery.100percent.bolt" : "battery.75percent", value: MetricFormat.number(sample.batteryPercent, digits: 0, suffix: "%"), detail: (sample.onAC == true ? "接着电源" : sample.onAC == false ? "使用电池" : "电源状态未知") + " · " + MetricFormat.number(sample.batteryTemperatureC, suffix: "°C"), tint: .green)
                    }
                    chartPicker
                    MetricChart(points: PlotPoint.from(samples: monitor.liveSamples, metric: chartMetric), metric: chartMetric)
                    HStack {
                        Label("最近 30 分钟", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("采样耗时 " + MetricFormat.number(sample.collectionDurationSeconds * 1000, digits: 0, suffix: " ms"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    liveApplications(sample)
                    MeasurementNotes(limitations: sample.limitations)
                } else {
                    ProgressView("正在准备温度与性能监控…").frame(maxWidth: .infinity, minHeight: 300)
                }
            }.padding(26)
        }
    }
    private var chartPicker: some View {
        Picker("历史曲线", selection: $chartMetric) { ForEach(ChartMetric.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
    }
    private func liveApplications(_ sample: TelemetrySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("当前应用与后台服务").font(.headline)
            Table(sample.applications.sorted {
                if MetricFormat.priority($0.name) != MetricFormat.priority($1.name) { return MetricFormat.priority($0.name) }
                return ($0.cpuPercent ?? -1) > ($1.cpuPercent ?? -1)
            }) {
                TableColumn("应用") { app in Label(MetricFormat.displayName(app.name), systemImage: MetricFormat.priority(app.name) ? "star.fill" : "app").lineLimit(1).help(app.name) }.width(min: 150, ideal: 190)
                TableColumn("CPU") { app in Text(MetricFormat.partial(MetricFormat.number(app.cpuPercent, suffix: "%"), keys: app.partialMetrics, metric: "cpu")) }.width(75)
                TableColumn("驻留内存") { app in Text(MetricFormat.partial(MetricFormat.bytes(app.residentBytes), keys: app.partialMetrics, metric: "memory")) }.width(90)
                TableColumn("下载 / 上传") { app in
                    VStack(alignment: .leading) {
                        Text("↓ " + MetricFormat.partial(appRate(app.receivedBytesDelta, sample.intervalSeconds), keys: app.partialMetrics, metric: "received"))
                        Text("↑ " + MetricFormat.partial(appRate(app.sentBytesDelta, sample.intervalSeconds), keys: app.partialMetrics, metric: "sent")).foregroundStyle(.secondary)
                    }.font(.caption)
                }.width(min: 130, ideal: 155)
                TableColumn("进程") { app in Text("\(app.processCount)") }.width(45)
            }.frame(height: 265)
            Text("应用 CPU 的 100% 表示占用一个核心；应用包含可归属的辅助进程。≥ 表示仅统计到部分进程；星标优先显示 VPN、ChatGPT 与 Codex。").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func appRate(_ bytes: UInt64?, _ interval: Double?) -> String {
        guard let bytes, let interval, interval > 0 else { return "—" }
        return MetricFormat.rate(Double(bytes) / interval)
    }
}

enum ChartMetric: String, CaseIterable, Identifiable {
    case temperature = "温度", cpu = "CPU", memory = "内存", network = "网络", power = "功率", battery = "电量"
    var id: String { rawValue }
    var unit: String {
        switch self { case .temperature: return "°C"; case .cpu, .battery: return "%"; case .memory: return "GB"; case .network: return "MB/s"; case .power: return "W" }
    }
}

struct PlotPoint: Identifiable {
    var date: Date
    var value: Double
    var series: String
    var segment = 0
    var id: String { "\(date.timeIntervalSince1970)-\(series)-\(segment)" }
    var lineID: String { "\(series)-\(segment)" }
    static func values(date: Date, metric: ChartMetric, chip: Double?, batteryTemp: Double?, cpu: Double?, memory: UInt64?, incoming: Double?, outgoing: Double?, power: Double?, battery: Double?) -> [PlotPoint] {
        let pairs: [(String, Double?)]
        switch metric {
        case .temperature: pairs = [("芯片", chip), ("电池", batteryTemp)]
        case .cpu: pairs = [("全机 CPU", cpu)]
        case .memory: pairs = [("使用内存", memory.map { Double($0) / 1_000_000_000 })]
        case .network: pairs = [("下载", incoming.map { $0 / 1_000_000 }), ("上传", outgoing.map { $0 / 1_000_000 })]
        case .power: pairs = [("估算功率", power)]
        case .battery: pairs = [("电量", battery)]
        }
        return pairs.compactMap { name, value in
            guard let value, value.isFinite else { return nil }
            return PlotPoint(date: date, value: value, series: name)
        }
    }
    static func from(samples: [TelemetrySnapshot], metric: ChartMetric) -> [PlotPoint] {
        var output: [PlotPoint] = [], segments: [String: Int] = [:], previous: Set<String> = []
        for sample in samples {
            let gap = sample.systemSleepObserved || (sample.intervalSeconds ?? 0) > 90
            let items = values(date: sample.date, metric: metric, chip: sample.chipTemperatureC, batteryTemp: sample.batteryTemperatureC, cpu: sample.systemCPUPercent, memory: sample.memoryUsedBytes, incoming: sample.receivedBytesPerSecond, outgoing: sample.sentBytesPerSecond, power: sample.estimatedLoadWatts, battery: sample.batteryPercent)
            append(items, gap: gap, segments: &segments, previous: &previous, output: &output)
        }
        return output
    }
    static func from(report: LidSessionReport, metric: ChartMetric) -> [PlotPoint] {
        var output: [PlotPoint] = [], segments: [String: Int] = [:], previous: Set<String> = []
        for point in report.curve {
            let items = values(date: Date(timeIntervalSince1970: point.timestamp), metric: metric, chip: point.chipTemperatureC, batteryTemp: point.batteryTemperatureC, cpu: point.systemCPUPercent, memory: point.memoryUsedBytes, incoming: point.receivedBytesPerSecond, outgoing: point.sentBytesPerSecond, power: point.powerWatts, battery: point.batteryPercent)
            append(items, gap: point.gapBefore, segments: &segments, previous: &previous, output: &output)
        }
        return output
    }
    private static func append(_ items: [PlotPoint], gap: Bool, segments: inout [String: Int], previous: inout Set<String>, output: inout [PlotPoint]) {
        for var item in items {
            if gap || !previous.contains(item.series) { segments[item.series, default: 0] += 1 }
            item.segment = segments[item.series, default: 0]
            output.append(item)
        }
        previous = Set(items.map(\.series))
    }
    static func selfTest() throws -> Int {
        var output: [PlotPoint] = [], segments: [String: Int] = [:], previous: Set<String> = []
        func add(_ time: Double, _ names: [String], gap: Bool = false) {
            append(names.map { PlotPoint(date: Date(timeIntervalSince1970: time), value: time, series: $0) }, gap: gap, segments: &segments, previous: &previous, output: &output)
        }
        var count = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "LidRun.Chart", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
            count += 1
        }
        add(0, ["芯片"]); add(1, ["芯片"])
        try check(output[0].lineID == output[1].lineID, "single readable temperature remains continuous")
        add(2, ["芯片", "电池"]); add(3, ["芯片"])
        try check(output[1].lineID == output[4].lineID, "missing battery does not split chip curve")
        add(4, ["芯片", "电池"])
        try check(output[3].lineID != output[6].lineID, "battery gap splits only battery curve")
        add(5, ["芯片", "电池"], gap: true)
        try check(output[5].lineID != output[7].lineID && output[6].lineID != output[8].lineID, "sleep gap splits both curves")
        add(6, []); add(7, ["芯片"])
        try check(output[7].lineID != output[9].lineID, "missing sample splits next readable curve")
        return count
    }
}

struct MetricChart: View {
    var points: [PlotPoint]
    var metric: ChartMetric
    @LidViewState private var hoverDate: Date? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(metric.rawValue + "曲线").font(.headline)
                Spacer()
                Text(metric.unit).font(.caption).foregroundStyle(.secondary)
            }
            if Set(points.map(\.date)).count < 2 {
                VStack(spacing: 12) {
                    Image(systemName: "chart.xyaxis.line").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text(points.isEmpty ? "当前没有可用读数" : "正在积累曲线，下一次采样后可查看").font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, minHeight: 160)
            } else {
                Chart {
                    ForEach(points) { point in
                        LineMark(x: .value("时间", point.date), y: .value(metric.unit, point.value), series: .value("连续区间", point.lineID))
                            .foregroundStyle(by: .value("项目", point.series)).lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    if let hoverDate { RuleMark(x: .value("查看时间", hoverDate)).foregroundStyle(.secondary.opacity(0.5)) }
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisGridLine(); AxisTick(); AxisValueLabel(format: axisTimeFormat) } }
                .chartYAxis { AxisMarks(position: .leading) }
                .chartLegend(position: .bottom, alignment: .leading)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle()).onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard #available(macOS 14.0, *), let anchor = proxy.plotFrame else { hoverDate = nil; return }
                                let frame = geometry[anchor]
                                if frame.contains(location) { hoverDate = proxy.value(atX: location.x - frame.origin.x, as: Date.self) }
                                else { hoverDate = nil }
                            case .ended: hoverDate = nil
                            }
                        }
                    }
                }.frame(height: 195)
                Text(hoverDescription).font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(minHeight: 18)
            }
        }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }
    private var hoverDescription: String {
        guard let hoverDate, let closest = points.min(by: { abs($0.date.timeIntervalSince(hoverDate)) < abs($1.date.timeIntervalSince(hoverDate)) }) else { return "将鼠标移到曲线上查看当时读数" }
        let nearby = points.filter { $0.date == closest.date }
        return MetricFormat.date(closest.date.timeIntervalSince1970, detailed: true) + "   " + nearby.map { $0.series + " " + MetricFormat.number($0.value, digits: 2, suffix: " " + metric.unit) }.joined(separator: "   ")
    }
    private var axisTimeFormat: Date.FormatStyle {
        let duration = (points.map(\.date).max()?.timeIntervalSince1970 ?? 0) - (points.map(\.date).min()?.timeIntervalSince1970 ?? 0)
        return duration < 300 ? .dateTime.hour().minute().second() : .dateTime.hour().minute()
    }
}

private struct HistoryPanel: View {
    @ObservedObject var monitor: MonitorController
    @LidViewState private var metric: ChartMetric = .temperature
    var body: some View {
        if monitor.historyReports.isEmpty {
            VStack(spacing: 18) {
                Image(systemName: "moon.zzz.fill").font(.system(size: 46)).foregroundStyle(.purple)
                Text("下一次合盖，从这里回看").font(.title2.bold())
                Text("软件保持打开时，会自动记录合盖期间的应用、运行时长、流量、温度和耗电。开盖后即可查看报告与曲线。")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                Text("以前的合盖记录没有这些测量数据，不会补造历史。").font(.caption).foregroundStyle(.tertiary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text("合盖期间，发生了什么").font(.system(size: 26, weight: .bold))
                        Spacer()
                        Picker("选择合盖记录", selection: Binding(get: { monitor.selectedReport?.id ?? "" }, set: { monitor.selectedHistoryID = $0 })) {
                            ForEach(monitor.historyReports) { report in
                                Text(MetricFormat.date(report.startedAt) + (report.isActive ? " · 记录中" : " · " + MetricFormat.duration(report.durationSeconds))).tag(report.id)
                            }
                        }.frame(maxWidth: 250)
                    }
                    if let report = monitor.selectedReport {
                        reportContent(report)
                    }
                }.padding(26)
            }
        }
    }
    @ViewBuilder private func reportContent(_ report: LidSessionReport) -> some View {
        HStack {
            Label(report.isActive ? "合盖中，持续记录" : "合盖报告", systemImage: report.isActive ? "record.circle" : "checkmark.circle")
                .foregroundStyle(report.isActive ? .orange : .green)
            Spacer()
            Text(MetricFormat.date(report.startedAt, detailed: true) + " → " + MetricFormat.date(report.endedAt ?? report.lastObservedAt, detailed: true)).font(.caption).foregroundStyle(.secondary)
        }
        Text("最高芯片温度 " + MetricFormat.number(report.peakChipTemperatureC, suffix: "°C") + "  ·  峰值 CPU " + MetricFormat.number(report.peakSystemCPUPercent, suffix: "%") + "  ·  峰值内存 " + MetricFormat.bytes(report.peakMemoryUsedBytes))
            .font(.caption).foregroundStyle(.secondary)
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            MetricTile(title: "本次合盖时长", icon: "clock", value: MetricFormat.duration(report.durationSeconds), detail: "连续采样覆盖 " + MetricFormat.duration(report.observedSeconds), tint: .purple)
            MetricTile(title: "整机接口流量", icon: "arrow.up.arrow.down", value: MetricFormat.bytes(report.receivedBytes), detail: "↓ 下载   ↑ " + MetricFormat.bytes(report.sentBytes), tint: .cyan)
                .help("下载覆盖 " + MetricFormat.duration(report.receivedCoverageSeconds) + "；上传覆盖 " + MetricFormat.duration(report.sentCoverageSeconds))
            MetricTile(title: "估算耗电", icon: "bolt.fill", value: MetricFormat.energy(report.energyWh), detail: energySource(report.energySource) + " · 覆盖 " + MetricFormat.duration(report.energyCoverageSeconds), tint: .orange)
            MetricTile(title: "电量变化", icon: "battery.75percent", value: MetricFormat.number(report.batteryStartPercent, digits: 0, suffix: "%") + " → " + MetricFormat.number(report.batteryEndPercent, digits: 0, suffix: "%"), detail: batteryChange(report), tint: .green)
        }
        if report.gapSeconds > 0 || report.startIncomplete || report.endIncomplete {
            Label("记录存在未覆盖时段：" + MetricFormat.duration(report.gapSeconds) + "。未采到的时段不计为持续运行或零耗电。", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.orange)
        }
        Text("运行过的应用与服务（\(report.applications.count)）").font(.headline)
        Table(report.applications.sorted {
            if MetricFormat.priority($0.name) != MetricFormat.priority($1.name) { return MetricFormat.priority($0.name) }
            return $0.observedRunningSeconds > $1.observedRunningSeconds
        }) {
            TableColumn("应用") { app in Label(MetricFormat.displayName(app.name), systemImage: MetricFormat.priority(app.name) ? "star.fill" : "app").lineLimit(1).help(app.name) }.width(min: 140, ideal: 170)
            TableColumn("观测时长") { app in Text(MetricFormat.duration(app.observedRunningSeconds)) }.width(90)
            TableColumn("CPU 时间") { app in Text(MetricFormat.partial(MetricFormat.cpuTime(app.cpuSeconds), keys: app.partialMetrics, metric: "cpu")).help("可读覆盖：" + MetricFormat.duration(app.cpuCoverageSeconds)) }.width(85)
            TableColumn("下载 / 上传") { app in
                VStack(alignment: .leading) { Text("↓ " + MetricFormat.partial(MetricFormat.bytes(app.receivedBytes), keys: app.partialMetrics, metric: "received")); Text("↑ " + MetricFormat.partial(MetricFormat.bytes(app.sentBytes), keys: app.partialMetrics, metric: "sent")).foregroundStyle(.secondary) }.font(.caption)
                    .help("下载覆盖 " + MetricFormat.duration(app.receivedCoverageSeconds) + "；上传覆盖 " + MetricFormat.duration(app.sentCoverageSeconds))
            }.width(min: 105, ideal: 120)
            TableColumn("CPU 估算耗电") { app in Text(MetricFormat.partial(MetricFormat.energy(app.cpuEnergyJoules.map { $0 / 3600 }), keys: app.partialMetrics, metric: "energy")).help("可读覆盖：" + MetricFormat.duration(app.energyCoverageSeconds)) }.width(110)
            TableColumn("峰值内存") { app in Text(MetricFormat.partial(MetricFormat.bytes(app.peakResidentBytes), keys: app.partialMetrics, metric: "memory")) }.width(90)
        }.frame(height: 310)
        Text("观测时长表示连续采样时应用进程仍存在，不代表一直占用 CPU。≥ 表示只有部分进程数据；CPU 耗电为可读进程的 CPU 归因估算，不包含该应用的全部硬件耗电。").font(.caption).foregroundStyle(.secondary)
        Picker("查看曲线", selection: $metric) { ForEach(ChartMetric.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
        MetricChart(points: PlotPoint.from(report: report, metric: metric), metric: metric)
        if let reason = report.endReason { Text("记录结束：" + endReason(reason)).font(.caption).foregroundStyle(.secondary) }
        MeasurementNotes(limitations: report.limitations)
        if let warning = monitor.storageWarning { Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
    }
    private func batteryChange(_ report: LidSessionReport) -> String {
        guard let start = report.batteryStartPercent, let end = report.batteryEndPercent else { return "电量读数不完整" }
        let delta = end - start
        return delta < 0 ? "电量下降 " + MetricFormat.number(-delta, suffix: " 个百分点") : delta > 0 ? "电量增加 " + MetricFormat.number(delta, suffix: " 个百分点") : "电量没有变化；接电时仍可能耗电"
    }
    private func energySource(_ source: String?) -> String {
        guard let source else { return "没有可用功率读数" }
        if source == "mixed" { return "多个测量来源；仅积分有效区间" }
        if source == "batteryDischargeWatts" { return "电池放电能量" }
        return "整机直流负载遥测"
    }
    private func endReason(_ reason: String) -> String {
        switch reason {
        case "lidOpened": return "打开盖子"
        case "softwareExited": return "软件退出"
        case "rebooted": return "电脑重启"
        case "monitorRestarted": return "监控重新启动，之前尾部未观测"
        default: return reason
        }
    }
}

struct MeasurementNotes: View {
    var limitations: [String]
    var body: some View {
        DisclosureGroup("数据口径与覆盖范围") {
            VStack(alignment: .leading, spacing: 8) {
                Text("整机流量按物理网络接口统计，包含局域网通信。应用流量按其网络连接统计；VPN 可能同时记到原应用和隧道服务，不能把应用数值相加当作整机流量。")
                Text("VPN 的界面与后台传输服务分开列出；查看流量时请结合后台服务行。部分受系统保护的服务只能确认运行状态，性能或能量读数会显示空缺。")
                Text("芯片温度为可用芯片传感器的最高有效读数。系统温度压力仍负责保护条件；没有可靠温度读数时显示空缺。")
                Text("CPU 归因能量不包含 GPU、屏幕等全部组件；整机功率也属于遥测估算。采样空档、计数重置或权限不足会保留缺口，空缺不是零。")
                Text("应用辅助进程新出现、结束或不可读取时，保留已知进程的统计，并用 ≥ 标出部分合计。覆盖时长表示取得了可读数据的区间，不表示读到了每个辅助进程。")
                Text("整机功率测量的是直流负载，不是插座交流电量；电源遥测约每 20–30 秒刷新，5 秒采样不代表每次都有新的功率值。")
                Text("内存占用包含可回收缓存；应用驻留内存合计可能重复计入共享页，判断紧张程度请结合内存压力。短暂出现后结束的进程或连接可能未被采样捕获。")
                ForEach(Array(Set(limitations)).sorted(), id: \.self) { Text($0) }
            }.font(.caption).foregroundStyle(.secondary).padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.caption)
    }
}
