import Foundation

struct LidApplicationReport: Codable, Identifiable, Sendable {
    var id: String
    var name: String
    var bundleIdentifier: String?
    var firstSeenAt: Double
    var lastSeenAt: Double
    // Presence in both ends of a continuously observed interval, not CPU time.
    var observedRunningSeconds = 0.0
    var observationCount = 0
    var lastProcessCount = 0
    var peakProcessCount = 0
    var cpuSeconds: Double?
    // Coverage is time with a known counter delta; partialMetrics identifies
    // totals measured for only the readable subset of an application's processes.
    var cpuCoverageSeconds = 0.0
    var receivedBytes: UInt64?
    var sentBytes: UInt64?
    var receivedCoverageSeconds = 0.0
    var sentCoverageSeconds = 0.0
    var cpuEnergyJoules: Double?
    var energyCoverageSeconds = 0.0
    var peakResidentBytes: UInt64?
    var partialMetrics: [String]? = nil

    var cpuEnergyWh: Double? { cpuEnergyJoules.map { $0 / 3600 } }
    var averageCPUPercent: Double? {
        guard let cpuSeconds, cpuCoverageSeconds > 0 else { return nil }
        return 100 * cpuSeconds / cpuCoverageSeconds
    }
}

struct LidHistoryGap: Codable, Identifiable, Sendable {
    var id = UUID().uuidString
    var startedAt: Double
    var endedAt: Double
    var reason: String
}

struct LidCurvePoint: Codable, Identifiable, Sendable {
    var id: Double { timestamp }
    var timestamp: Double
    var systemCPUPercent: Double?
    var memoryUsedBytes: UInt64?
    var memoryTotalBytes: UInt64?
    var memoryPressure: Int?
    var receivedBytesPerSecond: Double?
    var sentBytesPerSecond: Double?
    var chipTemperatureC: Double?
    var batteryTemperatureC: Double?
    var temperatureSource: String?
    var thermalLevel: Int?
    var batteryPercent: Double?
    var onAC: Bool?
    var systemPowerWatts: Double?
    var batteryDischargeWatts: Double?
    var powerWatts: Double?
    var energySource: String?
    var sleepDisabled: Bool?
    var guardPhase: String?
    var lidClosed: Bool?
    var collectionDurationSeconds: Double?
    var gapBefore: Bool
}

struct LidSessionReport: Codable, Identifiable, Sendable {
    var id: String
    var startedAt: Double
    var endedAt: Double?
    var lastObservedAt: Double
    var bootID: String
    var startIncomplete: Bool
    var endIncomplete = false
    var endReason: String?
    var observedSeconds = 0.0
    var gapSeconds = 0.0
    var gapCount = 0
    var gaps: [LidHistoryGap] = []
    var sampleCount = 0
    var applications: [LidApplicationReport] = []
    var curve: [LidCurvePoint] = []
    var curvePointCount = 0
    var curveDownsampled = false
    var receivedBytes: UInt64?
    var sentBytes: UInt64?
    var receivedCoverageSeconds = 0.0
    var sentCoverageSeconds = 0.0
    var energyWh: Double?
    var energyCoverageSeconds = 0.0
    var energySources: [String] = []
    var batteryStartPercent: Double?
    var batteryEndPercent: Double?
    var peakChipTemperatureC: Double?
    var peakSystemCPUPercent: Double?
    var peakMemoryUsedBytes: UInt64?
    var peakSystemPowerWatts: Double?
    var interfaceNames: [String] = []
    var limitations: [String] = []

    var isActive: Bool { endedAt == nil }
    var durationSeconds: Double { max(0, (endedAt ?? lastObservedAt) - startedAt) }
    var energySource: String? {
        if energySources.isEmpty { return nil }
        return energySources.count == 1 ? energySources[0] : "mixed"
    }
    var applicationCPUEnergyJoules: Double? {
        let known = applications.compactMap(\.cpuEnergyJoules)
        return known.isEmpty ? nil : known.reduce(0, +)
    }
}

private enum HistoryRules {
    static let curveLimit = 1200
    static let gapLimit = 128
    static let applicationLimit = 1024
    static let retainedDays = 30.0
    static let storageLimit: UInt64 = 64 * 1024 * 1024
    static let saveInterval = 60.0
    static let maximumInterval = 90.0

    static func valid(_ value: Double?, minimum: Double = 0) -> Double? {
        guard let value, value.isFinite, value >= minimum else { return nil }
        return value
    }

    static func add(_ value: UInt64, to total: inout UInt64?) -> Bool {
        let result = (total ?? 0).addingReportingOverflow(value)
        guard !result.overflow else { return false }
        total = result.partialValue
        return true
    }

    static func markPartial(_ metric: String, from sample: ApplicationTelemetry,
                            in report: inout LidApplicationReport) {
        guard sample.partialMetrics?.contains(metric) == true else { return }
        let allowed: Set<String> = ["cpu", "received", "sent", "energy", "memory"]
        guard allowed.contains(metric) else { return }
        report.partialMetrics = Set((report.partialMetrics ?? []).filter { allowed.contains($0) })
            .union([metric]).sorted()
    }

    static func energy(_ sample: TelemetrySnapshot) -> (watts: Double, source: String)? {
        if let watts = valid(sample.systemPowerWatts) {
            return (watts, "system:" + String((sample.powerSource ?? "systemPowerWatts").prefix(160)))
        }
        if sample.onAC == false, sample.isCharging != true,
           let watts = valid(sample.batteryDischargeWatts) {
            return (watts, "batteryDischargeWatts")
        }
        return nil
    }

    static func point(_ sample: TelemetrySnapshot, gap: Bool) -> LidCurvePoint {
        let energy = energy(sample)
        return LidCurvePoint(timestamp: sample.timestamp,
                             systemCPUPercent: gap ? nil : valid(sample.systemCPUPercent),
                             memoryUsedBytes: sample.memoryUsedBytes,
                             memoryTotalBytes: sample.memoryTotalBytes > 0 ? sample.memoryTotalBytes : nil,
                             memoryPressure: sample.memoryPressure,
                             receivedBytesPerSecond: gap ? nil : valid(sample.receivedBytesPerSecond),
                             sentBytesPerSecond: gap ? nil : valid(sample.sentBytesPerSecond),
                             chipTemperatureC: valid(sample.chipTemperatureC, minimum: -50),
                             batteryTemperatureC: valid(sample.batteryTemperatureC, minimum: -50),
                             temperatureSource: sample.temperatureSource.map { String($0.prefix(160)) },
                             thermalLevel: sample.thermalLevel >= 0 ? sample.thermalLevel : nil,
                             batteryPercent: valid(sample.batteryPercent).map { min(100, $0) },
                             onAC: sample.onAC,
                             systemPowerWatts: valid(sample.systemPowerWatts),
                             batteryDischargeWatts: valid(sample.batteryDischargeWatts),
                             powerWatts: energy?.watts, energySource: energy?.source,
                             sleepDisabled: sample.sleepDisabled, guardPhase: sample.guardPhase.map { String($0.prefix(160)) },
                             lidClosed: sample.lidClosed,
                             collectionDurationSeconds: valid(sample.collectionDurationSeconds), gapBefore: gap)
    }

    static func compress(_ points: [LidCurvePoint]) -> [LidCurvePoint] {
        guard points.count > curveLimit else { return points }
        var reduced: [LidCurvePoint] = []
        reduced.reserveCapacity((points.count + 1) / 2 + 1)
        var gap = false
        for index in points.indices {
            gap = gap || points[index].gapBefore
            if index % 2 == 0 || index == points.count - 1 {
                var point = points[index]
                point.gapBefore = gap
                reduced.append(point)
                gap = false
            }
        }
        return reduced
    }

    static func evictionIDs(_ files: [(id: String, size: UInt64, modified: Double)], activeID: String?,
                            limit: UInt64 = storageLimit) -> [String] {
        var total = files.reduce(UInt64(0)) { total, file in
            let sum = total.addingReportingOverflow(file.size)
            return sum.overflow ? UInt64.max : sum.partialValue
        }
        var result: [String] = []
        for file in files.sorted(by: { $0.modified < $1.modified }) where total > limit {
            guard file.id != activeID else { continue }
            result.append(file.id)
            total -= file.size
        }
        return result
    }
}

private struct HistoryAccumulator {
    var savedReports: [LidSessionReport]
    var previous: TelemetrySnapshot?
    var activeID: String? = nil
    var recoveryPending = false
    var dirtyIDs: Set<String> = []

    init(reports: [LidSessionReport] = []) {
        savedReports = reports.sorted { $0.startedAt > $1.startedAt }
        let active = savedReports.indices.filter { savedReports[$0].isActive }
        activeID = active.first.map { savedReports[$0].id }
        recoveryPending = activeID != nil
        for index in active.dropFirst() {
            savedReports[index].endedAt = savedReports[index].lastObservedAt
            savedReports[index].endIncomplete = true
            savedReports[index].endReason = "duplicateRecovery"
            dirtyIDs.insert(savedReports[index].id)
        }
    }

    var activeIndex: Int? {
        guard let activeID else { return nil }
        return savedReports.firstIndex { $0.id == activeID }
    }

    mutating func ingest(_ sample: TelemetrySnapshot) -> Bool {
        guard sample.timestamp.isFinite, sample.uptime.isFinite, sample.uptime >= 0,
              !sample.bootID.isEmpty else { return false }
        var transitioned = false
        var recoveredInterval = false
        if let index = activeIndex {
            if recoveryPending && sample.timestamp - savedReports[index].lastObservedAt > HistoryRules.retainedDays * 86_400 {
                finish(reason: "recoveryExpired", incomplete: true)
                transitioned = true
            } else if savedReports[index].bootID != sample.bootID {
                addGap(index, from: savedReports[index].lastObservedAt, to: sample.timestamp, reason: "rebooted")
                finish(reason: "rebooted", at: sample.timestamp, incomplete: true)
                transitioned = true
            } else if recoveryPending {
                addGap(index, from: savedReports[index].lastObservedAt, to: sample.timestamp, reason: "monitorRestarted")
                recoveredInterval = true
                recoveryPending = false
                if sample.lidClosed == false {
                    savedReports[index].batteryEndPercent = nil
                    finish(reason: "openedWhileUnobserved", at: sample.timestamp, incomplete: true)
                    transitioned = true
                }
            }
        }
        if activeIndex == nil, sample.lidClosed == true {
            let incomplete = entryBoundaryIncomplete(previous, sample)
            begin(sample, incomplete: incomplete)
            previous = sample
            return true
        }
        if let index = activeIndex {
            if sample.lidClosed == false {
                let tailGap = openingGap(previous, sample)
                let uncertain = recoveredInterval || tailGap != nil
                if !recoveredInterval {
                    addGap(index, from: previous?.timestamp ?? savedReports[index].lastObservedAt,
                           to: sample.timestamp, reason: tailGap ?? "openingBoundaryUnobserved")
                }
                savedReports[index].lastObservedAt = max(savedReports[index].lastObservedAt, sample.timestamp)
                savedReports[index].batteryEndPercent = HistoryRules.valid(sample.batteryPercent).map { min(100, $0) }
                savedReports[index].curvePointCount += 1
                savedReports[index].curve.append(HistoryRules.point(sample, gap: true))
                if savedReports[index].curve.count > HistoryRules.curveLimit {
                    savedReports[index].curve = HistoryRules.compress(savedReports[index].curve)
                    savedReports[index].curveDownsampled = true
                }
                finish(reason: "lidOpened", at: sample.timestamp, incomplete: uncertain)
                transitioned = true
            } else {
                let gapReason = continuityGap(previous, sample)
                if let gapReason, !recoveredInterval {
                    // Recovery already recorded its interval above; do not count it twice.
                    if previous != nil {
                        addGap(index, from: previous!.timestamp, to: sample.timestamp, reason: gapReason)
                    }
                }
                if !recoveredInterval, gapReason == nil, let prior = previous {
                    accumulate(index, previous: prior, current: sample)
                }
                observe(index, sample: sample, gap: recoveredInterval || gapReason != nil || previous == nil)
            }
        }
        previous = sample
        recoveryPending = false
        return transitioned
    }

    private mutating func begin(_ sample: TelemetrySnapshot, incomplete: Bool) {
        var report = LidSessionReport(id: UUID().uuidString, startedAt: sample.timestamp,
                                      lastObservedAt: sample.timestamp, bootID: sample.bootID,
                                      startIncomplete: incomplete)
        report.batteryStartPercent = HistoryRules.valid(sample.batteryPercent).map { min(100, $0) }
        report.limitations = ["开合盖时刻取首次观测到状态变化的采样时刻；应用观测时长只统计连续合盖样本间隔。",
                              "应用 CPU 能量是 CPU 归因估算，不是应用全部硬件耗电。",
                              "应用列表包含 GUI 应用与采样到的活跃后台摘要，不涵盖所有系统进程；指标覆盖取决于系统可读性。"]
        if incomplete { report.limitations.append("开始记录时已合盖，缺少合盖开头。") }
        savedReports.insert(report, at: 0)
        activeID = report.id
        observe(0, sample: sample, gap: true)
    }

    mutating func finish(reason: String, at timestamp: Double? = nil, incomplete: Bool = true) {
        guard let index = activeIndex else { return }
        savedReports[index].endedAt = max(savedReports[index].startedAt,
                                          timestamp ?? savedReports[index].lastObservedAt)
        savedReports[index].endIncomplete = incomplete
        savedReports[index].endReason = String(reason.prefix(160))
        if incomplete { addLimitation(index, "监测结束时缺少完整的开盖观测，结束时间或覆盖不完整。") }
        dirtyIDs.insert(savedReports[index].id)
        activeID = nil
        recoveryPending = false
    }

    private func continuityGap(_ prior: TelemetrySnapshot?, _ current: TelemetrySnapshot) -> String? {
        guard let prior else { return "noPreviousSample" }
        if prior.bootID != current.bootID { return "rebooted" }
        if current.systemSleepObserved { return "systemSlept" }
        if prior.lidClosed != true || current.lidClosed != true { return "lidStateUnavailable" }
        let elapsed = current.timestamp - prior.timestamp
        let uptime = current.uptime - prior.uptime
        if elapsed <= 0 || uptime <= 0 { return "clockChanged" }
        if abs(elapsed - uptime) > max(2, elapsed * 0.05) { return "sleepOrClockChanged" }
        if elapsed > HistoryRules.maximumInterval { return "samplingGap" }
        guard let interval = current.intervalSeconds, interval.isFinite, interval > 0,
              abs(interval - uptime) <= max(2, uptime * 0.1) else { return "counterBaselineUnavailable" }
        return nil
    }

    private func openingGap(_ prior: TelemetrySnapshot?, _ current: TelemetrySnapshot) -> String? {
        guard let prior, prior.lidClosed == true else { return "openingStateUnobserved" }
        var boundary = current
        // Validate time/counter coverage while allowing this genuinely observed opening.
        boundary.lidClosed = true
        return continuityGap(prior, boundary)
    }

    private func entryBoundaryIncomplete(_ prior: TelemetrySnapshot?, _ current: TelemetrySnapshot) -> Bool {
        guard var prior, prior.bootID == current.bootID, prior.lidClosed == false else { return true }
        prior.lidClosed = true
        return continuityGap(prior, current) != nil
    }

    private mutating func addGap(_ index: Int, from start: Double, to end: Double, reason: String) {
        guard start.isFinite, end.isFinite else { return }
        savedReports[index].gapCount += 1
        savedReports[index].gapSeconds += max(0, end - start)
        if savedReports[index].gaps.count < HistoryRules.gapLimit {
            savedReports[index].gaps.append(LidHistoryGap(startedAt: start, endedAt: end, reason: reason))
        }
        addLimitation(index, "存在监测缺口；缺口期间不累计应用运行、CPU、网络或能量。")
        dirtyIDs.insert(savedReports[index].id)
    }

    private mutating func addLimitation(_ index: Int, _ text: String) {
        let limited = String(text.prefix(512))
        if !savedReports[index].limitations.contains(limited), savedReports[index].limitations.count < 64 {
            savedReports[index].limitations.append(limited)
        }
    }

    private mutating func observe(_ index: Int, sample: TelemetrySnapshot, gap: Bool) {
        savedReports[index].lastObservedAt = max(savedReports[index].lastObservedAt, sample.timestamp)
        savedReports[index].sampleCount += 1
        savedReports[index].curvePointCount += 1
        savedReports[index].curve.append(HistoryRules.point(sample, gap: gap))
        if savedReports[index].curve.count > HistoryRules.curveLimit {
            savedReports[index].curve = HistoryRules.compress(savedReports[index].curve)
            savedReports[index].curveDownsampled = true
            addLimitation(index, "曲线已降采样；累计统计仍按所有有效原始样本计算。")
        }
        savedReports[index].batteryEndPercent = HistoryRules.valid(sample.batteryPercent).map { min(100, $0) }
        if let value = HistoryRules.valid(sample.chipTemperatureC, minimum: -50) {
            savedReports[index].peakChipTemperatureC = max(savedReports[index].peakChipTemperatureC ?? value, value)
        }
        if !gap, let value = HistoryRules.valid(sample.systemCPUPercent) {
            savedReports[index].peakSystemCPUPercent = max(savedReports[index].peakSystemCPUPercent ?? value, value)
        }
        if let value = sample.memoryUsedBytes {
            savedReports[index].peakMemoryUsedBytes = max(savedReports[index].peakMemoryUsedBytes ?? value, value)
        }
        if let value = HistoryRules.valid(sample.systemPowerWatts) {
            savedReports[index].peakSystemPowerWatts = max(savedReports[index].peakSystemPowerWatts ?? value, value)
        }
        for name in sample.interfaceNames.prefix(64) where !savedReports[index].interfaceNames.contains(name) {
            if savedReports[index].interfaceNames.count < 64 {
                savedReports[index].interfaceNames.append(String(name.prefix(160)))
            }
        }
        for limitation in sample.limitations.prefix(32) { addLimitation(index, limitation) }
        let currentIDs = Set(sample.applications.map(\.id))
        for appIndex in savedReports[index].applications.indices where !currentIDs.contains(savedReports[index].applications[appIndex].id) {
            savedReports[index].applications[appIndex].lastProcessCount = 0
        }
        for application in sample.applications.prefix(HistoryRules.applicationLimit) {
            guard !application.id.isEmpty else { continue }
            let appIndex: Int
            if let existing = savedReports[index].applications.firstIndex(where: { $0.id == application.id }) {
                appIndex = existing
            } else {
                guard savedReports[index].applications.count < HistoryRules.applicationLimit else {
                    addLimitation(index, "应用历史数量达到保存上限，部分应用未单独记录。")
                    break
                }
                savedReports[index].applications.append(LidApplicationReport(id: String(application.id.prefix(512)),
                    name: String(application.name.prefix(256)), bundleIdentifier: application.bundleIdentifier.map { String($0.prefix(256)) },
                    firstSeenAt: sample.timestamp, lastSeenAt: sample.timestamp))
                appIndex = savedReports[index].applications.count - 1
            }
            savedReports[index].applications[appIndex].lastSeenAt = sample.timestamp
            savedReports[index].applications[appIndex].observationCount += 1
            savedReports[index].applications[appIndex].lastProcessCount = max(0, application.processCount)
            savedReports[index].applications[appIndex].peakProcessCount = max(savedReports[index].applications[appIndex].peakProcessCount,
                                                                            max(0, application.processCount))
            if let resident = application.residentBytes {
                savedReports[index].applications[appIndex].peakResidentBytes = max(savedReports[index].applications[appIndex].peakResidentBytes ?? resident, resident)
                HistoryRules.markPartial("memory", from: application, in: &savedReports[index].applications[appIndex])
            }
        }
        dirtyIDs.insert(savedReports[index].id)
    }

    private mutating func accumulate(_ index: Int, previous: TelemetrySnapshot, current: TelemetrySnapshot) {
        let seconds = current.uptime - previous.uptime
        savedReports[index].observedSeconds += seconds
        if let received = current.receivedBytesDelta {
            if HistoryRules.add(received, to: &savedReports[index].receivedBytes) { savedReports[index].receivedCoverageSeconds += seconds }
            else { addLimitation(index, "接收字节累计溢出，超出部分未计入。") }
        }
        if let sent = current.sentBytesDelta {
            if HistoryRules.add(sent, to: &savedReports[index].sentBytes) { savedReports[index].sentCoverageSeconds += seconds }
            else { addLimitation(index, "发送字节累计溢出，超出部分未计入。") }
        }
        if let from = HistoryRules.energy(previous), let to = HistoryRules.energy(current) {
            if from.source == to.source {
                let wh = (from.watts + to.watts) * 0.5 * seconds / 3600
                if wh.isFinite {
                    savedReports[index].energyWh = (savedReports[index].energyWh ?? 0) + wh
                    savedReports[index].energyCoverageSeconds += seconds
                    if !savedReports[index].energySources.contains(to.source), savedReports[index].energySources.count < 16 {
                        savedReports[index].energySources.append(to.source)
                    }
                    if savedReports[index].energySources.count > 1 {
                        addLimitation(index, "整机能量包含不同测量范围的来源（mixed）；来源切换区间未积分，未将同时存在的两个功率通道重复累加。")
                    }
                }
            } else { addLimitation(index, "能量来源切换区间未积分，功率范围可能不同。") }
        }
        for application in current.applications {
            guard let prior = previous.applications.first(where: { $0.id == application.id }),
                  prior.mainPID == application.mainPID else { continue }
            if let from = prior.instanceID, let to = application.instanceID, from != to { continue }
            guard let appIndex = savedReports[index].applications.firstIndex(where: { $0.id == application.id }) else { continue }
            savedReports[index].applications[appIndex].observedRunningSeconds += seconds
            if let cpu = HistoryRules.valid(application.cpuSecondsDelta) {
                savedReports[index].applications[appIndex].cpuSeconds = (savedReports[index].applications[appIndex].cpuSeconds ?? 0) + cpu
                savedReports[index].applications[appIndex].cpuCoverageSeconds += seconds
                HistoryRules.markPartial("cpu", from: application, in: &savedReports[index].applications[appIndex])
            }
            if let received = application.receivedBytesDelta,
               HistoryRules.add(received, to: &savedReports[index].applications[appIndex].receivedBytes) {
                savedReports[index].applications[appIndex].receivedCoverageSeconds += seconds
                HistoryRules.markPartial("received", from: application, in: &savedReports[index].applications[appIndex])
            }
            if let sent = application.sentBytesDelta,
               HistoryRules.add(sent, to: &savedReports[index].applications[appIndex].sentBytes) {
                savedReports[index].applications[appIndex].sentCoverageSeconds += seconds
                HistoryRules.markPartial("sent", from: application, in: &savedReports[index].applications[appIndex])
            }
            if let joules = HistoryRules.valid(application.cpuEnergyJoulesDelta) {
                savedReports[index].applications[appIndex].cpuEnergyJoules = (savedReports[index].applications[appIndex].cpuEnergyJoules ?? 0) + joules
                savedReports[index].applications[appIndex].energyCoverageSeconds += seconds
                HistoryRules.markPartial("energy", from: application, in: &savedReports[index].applications[appIndex])
            }
        }
    }
}

private struct HistoryDocument: Codable {
    var version = 1
    var report: LidSessionReport
}

actor HistoryStore {
    private var accumulator: HistoryAccumulator
    private let directory: URL
    private var lastSaveUptime = -Double.infinity
    private var persistenceError: String?
    private var hasLoaded = false
    private var expiredIDs: Set<String> = []

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
        accumulator = HistoryAccumulator()
    }

    private nonisolated static func defaultDirectory() -> URL {
        let library = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return library.appendingPathComponent("LidRun/History", isDirectory: true)
    }

    func ingest(_ snapshot: TelemetrySnapshot) async -> [LidSessionReport] {
        ensureLoaded()
        let transitioned = accumulator.ingest(snapshot)
        let now = ProcessInfo.processInfo.systemUptime
        if transitioned || now - lastSaveUptime >= HistoryRules.saveInterval { save() }
        return reports()
    }

    func reports() -> [LidSessionReport] {
        ensureLoaded()
        return accumulator.savedReports.sorted { $0.startedAt > $1.startedAt }
    }

    func flush(endReason: String? = nil) {
        ensureLoaded()
        if let endReason { accumulator.finish(reason: endReason) }
        save()
    }

    func finish(reason: String) {
        ensureLoaded()
        accumulator.finish(reason: reason)
        save()
    }

    func storageWarning() -> String? { persistenceError }

    private func ensureLoaded() {
        guard !hasLoaded else { return }
        let loaded = Self.readStorage(in: directory)
        accumulator = HistoryAccumulator(reports: loaded.reports)
        expiredIDs = loaded.expiredIDs
        hasLoaded = true
    }

    private func save() {
        lastSaveUptime = ProcessInfo.processInfo.systemUptime
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            for report in accumulator.savedReports where accumulator.dirtyIDs.contains(report.id) {
                guard UUID(uuidString: report.id) != nil else { continue }
                let data = try encoder.encode(HistoryDocument(report: report))
                // Only this report is rewritten, at most once per minute during sampling.
                try Self.writeDocument(data, id: report.id, directory: directory)
                accumulator.dirtyIDs.remove(report.id)
            }
            try trimStorage()
            persistenceError = nil
        } catch { persistenceError = "历史记录未能保存：\(error.localizedDescription)" }
    }

    private func trimStorage() throws {
        let cutoff = Date().timeIntervalSince1970 - HistoryRules.retainedDays * 86_400
        for id in expiredIDs where id != accumulator.activeID {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(id + ".json"))
        }
        expiredIDs.removeAll()
        for report in accumulator.savedReports where !report.isActive && (report.endedAt ?? report.lastObservedAt) < cutoff {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(report.id + ".json"))
            accumulator.dirtyIDs.remove(report.id)
        }
        accumulator.savedReports.removeAll { !$0.isActive && ($0.endedAt ?? $0.lastObservedAt) < cutoff }
        let files = try Self.managedFiles(in: directory).map { url -> (URL, UInt64, Date) in
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (url, UInt64(max(0, values.fileSize ?? 0)), values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        let plan = Set(HistoryRules.evictionIDs(files.map {
            (id: $0.0.deletingPathExtension().lastPathComponent, size: $0.1, modified: $0.2.timeIntervalSince1970)
        }, activeID: accumulator.activeID))
        for candidate in files where plan.contains(candidate.0.deletingPathExtension().lastPathComponent) {
            let id = candidate.0.deletingPathExtension().lastPathComponent
            try FileManager.default.removeItem(at: candidate.0)
            accumulator.savedReports.removeAll { $0.id == id }
            accumulator.dirtyIDs.remove(id)
        }
    }

    private nonisolated static func managedFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]).filter { url in
                guard url.pathExtension == "json", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
                return values.isRegularFile == true && values.isSymbolicLink != true
            }
    }

    private nonisolated static func writeDocument(_ data: Data, id: String, directory: URL) throws {
        let url = directory.appendingPathComponent(id + ".json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private nonisolated static func readReports(in directory: URL) -> [LidSessionReport] {
        readStorage(in: directory).reports
    }

    private nonisolated static func readStorage(in directory: URL) -> (reports: [LidSessionReport], expiredIDs: Set<String>) {
        guard let files = try? managedFiles(in: directory) else { return ([], []) }
        var reports: [LidSessionReport] = []
        var loaded: UInt64 = 0
        var expired: Set<String> = []
        let cutoff = Date().timeIntervalSince1970 - HistoryRules.retainedDays * 86_400
        let ordered = files.sorted {
            let first = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let second = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return first > second
        }
        for url in ordered {
            let id = url.deletingPathExtension().lastPathComponent
            if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               modified.timeIntervalSince1970 < cutoff {
                expired.insert(id)
                continue
            }
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size >= 0, size <= 8 * 1024 * 1024,
                  loaded + UInt64(size) <= HistoryRules.storageLimit,
                  let data = try? Data(contentsOf: url) else { continue }
            loaded += UInt64(size)
            guard let document = try? JSONDecoder().decode(HistoryDocument.self, from: data),
                  document.version == 1,
                  document.report.id == url.deletingPathExtension().lastPathComponent,
                  document.report.startedAt.isFinite, document.report.lastObservedAt.isFinite,
                  document.report.curve.count <= HistoryRules.curveLimit,
                  document.report.applications.count <= HistoryRules.applicationLimit else { continue }
            guard document.report.isActive || (document.report.endedAt ?? document.report.lastObservedAt) >= cutoff else {
                expired.insert(id)
                continue
            }
            reports.append(document.report)
        }
        return (reports, expired)
    }

    nonisolated static func selfTest() throws -> Int {
        let count = try HistorySelfTests.run()
        return count + (try persistenceSelfTest())
    }

    private nonisolated static func persistenceSelfTest() throws -> Int {
        struct Failure: Error { let message: String }
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw Failure(message: message) }
            count += 1
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LidRun-history-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date().timeIntervalSince1970
        var report = LidSessionReport(id: UUID().uuidString, startedAt: now - 20,
                                      endedAt: now, lastObservedAt: now, bootID: "test",
                                      startIncomplete: false)
        report.observedSeconds = 10
        let encoder = JSONEncoder()
        try writeDocument(encoder.encode(HistoryDocument(report: report)), id: report.id, directory: directory)
        try check(readReports(in: directory).first?.observedSeconds == 10,
                  "actual atomic checkpoint can be decoded with exact aggregate")
        report.observedSeconds = 25
        try writeDocument(encoder.encode(HistoryDocument(report: report)), id: report.id, directory: directory)
        try check(readReports(in: directory).count == 1 && readReports(in: directory).first?.observedSeconds == 25,
                  "atomic replacement updates a single independent session document")
        var old = report
        old.id = UUID().uuidString
        old.startedAt = now - 32 * 86_400
        old.lastObservedAt = now - 31 * 86_400
        old.endedAt = old.lastObservedAt
        try writeDocument(encoder.encode(HistoryDocument(report: old)), id: old.id, directory: directory)
        try check(readReports(in: directory).count == 1, "completed reports older than 30 days are not loaded")
        try check(readStorage(in: directory).expiredIDs.contains(old.id),
                  "expired decoded records are retained in deletion plan for the next save batch")
        let unrelated = directory.appendingPathComponent("other.json")
        try Data("{}".utf8).write(to: unrelated)
        let link = directory.appendingPathComponent(UUID().uuidString + ".json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.appendingPathComponent(report.id + ".json"))
        let managed = try managedFiles(in: directory)
        try check(managed.count == 2,
                  "only owned regular UUID report filenames participate in pruning")
        let mode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(report.id + ".json").path)[.posixPermissions] as? NSNumber
        try check(mode?.intValue == 0o600, "checkpoint stays private to the local user")
        return count
    }
}

private enum HistorySelfTests {
    private struct Failure: Error { let message: String }

    static func run() throws -> Int {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw Failure(message: message) }
            count += 1
        }
        func sample(_ time: Double, closed: Bool? = true, boot: String = "boot1",
                    apps: [ApplicationTelemetry]? = nil, interval: Double? = 10) -> TelemetrySnapshot {
            TelemetrySnapshot(timestamp: time, uptime: time, bootID: boot, intervalSeconds: interval,
                lidClosed: closed, sleepDisabled: true, guardPhase: "active", thermalLevel: 0,
                chipTemperatureC: 42, batteryTemperatureC: nil, temperatureSource: "test",
                systemCPUPercent: 20, memoryUsedBytes: 1_000, memoryTotalBytes: 8_000,
                memoryPressure: 0, receivedBytesDelta: 100, sentBytesDelta: 50,
                interfaceNames: ["en0"], batteryPercent: 80, onAC: false, isCharging: false,
                batteryDischargeWatts: 10, systemPowerWatts: nil, powerSource: "battery",
                applications: apps ?? [ApplicationTelemetry(id: "app", name: "Test", bundleIdentifier: "test.app",
                    mainPID: 1, processCount: 3, cpuPercent: 20, cpuSecondsDelta: 2, residentBytes: 100,
                    receivedBytesDelta: 30, sentBytesDelta: 20, cpuEnergyJoulesDelta: 5)],
                limitations: [], collectionDurationSeconds: 0.01)
        }
        var engine = HistoryAccumulator()
        _ = engine.ingest(sample(100, closed: false))
        try check(engine.savedReports.isEmpty, "open snapshots do not create a report")
        _ = engine.ingest(sample(110))
        try check(engine.savedReports.count == 1 && !engine.savedReports[0].startIncomplete,
                  "observed open-to-closed transition starts a complete report")
        _ = engine.ingest(sample(120))
        let report = engine.savedReports[0]
        try check(report.observedSeconds == 10 && report.receivedBytes == 100 && report.sentBytes == 50,
                  "system deltas only accumulate within a continuously closed interval")
        try check(report.applications[0].observedRunningSeconds == 10 && report.applications[0].cpuSeconds == 2,
                  "application presence time is distinct from CPU seconds")
        try check(report.applications[0].cpuEnergyJoules == 5 && report.applications[0].peakResidentBytes == 100,
                  "application CPU energy and peak RSS remain separate")
        try check(abs((report.energyWh ?? -1) - 10 * 10 / 3600) < 0.000001,
                  "battery power is integrated in watt-hours")
        _ = engine.ingest(sample(130, closed: false))
        try check(!engine.savedReports[0].isActive && engine.savedReports[0].endedAt == 130,
                  "closed-to-open transition finishes report")
        try check(engine.savedReports[0].observedSeconds == 10, "opening boundary is not falsely integrated")
        try check(engine.savedReports[0].gapSeconds == 10 && engine.savedReports[0].gapCount == 1 &&
                  engine.savedReports[0].gaps.last?.reason == "openingBoundaryUnobserved",
                  "unintegrated opening boundary is explicit coverage gap")
        var openingGap = HistoryAccumulator()
        _ = openingGap.ingest(sample(100))
        _ = openingGap.ingest(sample(500, closed: false, interval: 400))
        try check(openingGap.savedReports[0].endIncomplete && openingGap.savedReports[0].gapSeconds == 400 &&
                  openingGap.savedReports[0].gaps.last?.reason == "samplingGap",
                  "long unobserved opening marks incomplete ending and missing coverage")
        var openingSleep = HistoryAccumulator()
        _ = openingSleep.ingest(sample(100))
        var openAfterSleep = sample(110, closed: false)
        openAfterSleep.systemSleepObserved = true
        _ = openingSleep.ingest(openAfterSleep)
        try check(openingSleep.savedReports[0].endIncomplete && openingSleep.savedReports[0].gaps.last?.reason == "systemSlept",
                  "sleep before opening is an incomplete endpoint even for short interval")
        var uncertainStart = HistoryAccumulator()
        _ = uncertainStart.ingest(sample(100, closed: false))
        _ = uncertainStart.ingest(sample(500, interval: 400))
        try check(uncertainStart.savedReports[0].startIncomplete,
                  "a distant prior open sample cannot establish a complete beginning")

        var incomplete = HistoryAccumulator()
        _ = incomplete.ingest(sample(200))
        try check(incomplete.savedReports[0].startIncomplete, "startup already closed is explicitly incomplete")
        _ = incomplete.ingest(sample(210))
        var slept = sample(220)
        slept.systemSleepObserved = true
        _ = incomplete.ingest(slept)
        try check(incomplete.savedReports[0].observedSeconds == 10 && incomplete.savedReports[0].gapCount == 1,
                  "explicit sleep event excludes even a short interval")
        try check(incomplete.savedReports[0].curve.last?.systemCPUPercent == nil &&
                  incomplete.savedReports[0].curve.last?.chipTemperatureC == 42,
                  "interval CPU is unknown across gap while instantaneous temperature is retained")
        _ = incomplete.ingest(sample(400, interval: 180))
        try check(incomplete.savedReports[0].observedSeconds == 10 && incomplete.savedReports[0].gapCount == 2,
                  "long sampling gap excludes runtime and metrics")
        var clockChanged = sample(410)
        clockChanged.uptime = 401
        _ = incomplete.ingest(clockChanged)
        try check(incomplete.savedReports[0].observedSeconds == 10 && incomplete.savedReports[0].gapCount == 3,
                  "wall and uptime discrepancy is a gap")
        _ = incomplete.ingest(sample(420, boot: "boot2"))
        try check(incomplete.savedReports.count == 2 && incomplete.savedReports[1].endReason == "rebooted" &&
                  incomplete.savedReports[0].startIncomplete, "reboot closes incomplete old report and starts separate report")

        var unknown = HistoryAccumulator()
        var unknownSample = sample(500)
        unknownSample.receivedBytesDelta = nil
        unknownSample.sentBytesDelta = nil
        unknownSample.batteryDischargeWatts = nil
        unknownSample.systemPowerWatts = nil
        unknownSample.applications[0].cpuSecondsDelta = nil
        unknownSample.applications[0].receivedBytesDelta = nil
        unknownSample.applications[0].sentBytesDelta = nil
        unknownSample.applications[0].cpuEnergyJoulesDelta = nil
        _ = unknown.ingest(unknownSample)
        unknownSample.timestamp = 510; unknownSample.uptime = 510
        _ = unknown.ingest(unknownSample)
        try check(unknown.savedReports[0].receivedBytes == nil && unknown.savedReports[0].energyWh == nil &&
                  unknown.savedReports[0].applications[0].cpuSeconds == nil,
                  "unknown readings remain nil rather than zero")
        var fewer = sample(520)
        fewer.applications[0].processCount = 1
        _ = unknown.ingest(fewer)
        try check(unknown.savedReports[0].applications[0].peakProcessCount == 3 &&
                  unknown.savedReports[0].applications[0].lastProcessCount == 1 &&
                  unknown.savedReports[0].applications[0].receivedBytes == 30,
                  "process-count decline never becomes a byte delta")
        _ = unknown.ingest(sample(530, apps: []))
        _ = unknown.ingest(sample(540))
        try check(unknown.savedReports[0].applications[0].observedRunningSeconds == 20,
                  "application absence and reappearance do not fill unobserved runtime")
        var replacement = sample(550)
        replacement.applications[0].mainPID = 2
        _ = unknown.ingest(replacement)
        try check(unknown.savedReports[0].applications[0].observedRunningSeconds == 20 &&
                  unknown.savedReports[0].applications[0].receivedBytes == 30,
                  "application main-process replacement is not falsely counted as continuous runtime")
        var reusedPID = HistoryAccumulator()
        var firstInstance = sample(560)
        firstInstance.applications[0].instanceID = "pid1.birth1"
        _ = reusedPID.ingest(firstInstance)
        var secondInstance = sample(570)
        secondInstance.applications[0].instanceID = "pid1.birth2"
        _ = reusedPID.ingest(secondInstance)
        try check(reusedPID.savedReports[0].applications[0].observedRunningSeconds == 0 &&
                  reusedPID.savedReports[0].applications[0].cpuSeconds == nil,
                  "known changed birth identity excludes runtime and deltas even when PID number is reused")

        var partial = HistoryAccumulator()
        var partialBaseline = sample(580)
        partialBaseline.applications[0].cpuSecondsDelta = nil
        partialBaseline.applications[0].receivedBytesDelta = nil
        partialBaseline.applications[0].sentBytesDelta = nil
        partialBaseline.applications[0].cpuEnergyJoulesDelta = nil
        partialBaseline.applications[0].residentBytes = nil
        partialBaseline.applications[0].partialMetrics = ["cpu", "received", "sent", "energy", "memory"]
        _ = partial.ingest(partialBaseline)
        partialBaseline.timestamp = 590; partialBaseline.uptime = 590
        _ = partial.ingest(partialBaseline)
        try check(partial.savedReports[0].applications[0].partialMetrics == nil &&
                  partial.savedReports[0].applications[0].cpuCoverageSeconds == 0,
                  "unknown baseline counters do not create partial flags or counter coverage")
        var partialKnown = sample(600)
        partialKnown.applications[0].sentBytesDelta = nil
        partialKnown.applications[0].partialMetrics = ["cpu", "received", "sent", "energy", "memory", "unknown"]
        _ = partial.ingest(partialKnown)
        let partialReport = partial.savedReports[0].applications[0]
        try check(partialReport.cpuSeconds == 2 && partialReport.receivedBytes == 30 &&
                  partialReport.sentBytes == nil && partialReport.cpuEnergyJoules == 5 &&
                  partialReport.partialMetrics == ["cpu", "energy", "memory", "received"],
                  "known partial deltas accumulate while only contributed metrics are flagged")
        try check(partialReport.cpuCoverageSeconds == 10 && partialReport.receivedCoverageSeconds == 10 &&
                  partialReport.sentCoverageSeconds == 0 && partialReport.energyCoverageSeconds == 10 &&
                  partialReport.observedRunningSeconds == 20 && partialReport.peakResidentBytes == 100,
                  "partial counter coverage measures known subset intervals, distinct from observed presence")
        _ = partial.ingest(sample(610))
        try check(partial.savedReports[0].applications[0].partialMetrics == partialReport.partialMetrics &&
                  partial.savedReports[0].applications[0].cpuSeconds == 4 &&
                  partial.savedReports[0].applications[0].receivedBytes == 60,
                  "later complete observations retain the historical partial union")
        var measuredZero = partialBaseline
        measuredZero.timestamp = 620; measuredZero.uptime = 620
        measuredZero.applications[0].sentBytesDelta = 0
        measuredZero.applications[0].partialMetrics = ["sent"]
        _ = partial.ingest(measuredZero)
        try check(partial.savedReports[0].applications[0].sentBytes == 20 &&
                  partial.savedReports[0].applications[0].sentCoverageSeconds == 20 &&
                  partial.savedReports[0].applications[0].partialMetrics == ["cpu", "energy", "memory", "received", "sent"],
                  "measured zero partial delta is known coverage and unions its flag")
        let partialEncoded = try JSONEncoder().encode(HistoryDocument(report: partial.savedReports[0]))
        let partialDecoded = try JSONDecoder().decode(HistoryDocument.self, from: partialEncoded)
        try check(partialDecoded.report.applications[0].partialMetrics == partial.savedReports[0].applications[0].partialMetrics &&
                  partialDecoded.report.applications[0].cpuSeconds == 4,
                  "checkpoint serialization preserves partial scope with accumulated totals")
        let legacyAppEncoded = try JSONEncoder().encode(partialReport)
        guard var legacyApp = try JSONSerialization.jsonObject(with: legacyAppEncoded) as? [String: Any] else {
            throw Failure(message: "legacy report fixture is not a JSON object")
        }
        legacyApp.removeValue(forKey: "partialMetrics")
        let legacyDecoded = try JSONDecoder().decode(LidApplicationReport.self,
            from: JSONSerialization.data(withJSONObject: legacyApp))
        try check(legacyDecoded.partialMetrics == nil && legacyDecoded.cpuSeconds == 2,
                  "old application report JSON without partialMetrics remains decodable")
        let legacyTelemetryEncoded = try JSONEncoder().encode(partialKnown.applications[0])
        guard var legacyTelemetry = try JSONSerialization.jsonObject(with: legacyTelemetryEncoded) as? [String: Any] else {
            throw Failure(message: "legacy telemetry fixture is not a JSON object")
        }
        legacyTelemetry.removeValue(forKey: "partialMetrics")
        let legacyTelemetryDecoded = try JSONDecoder().decode(ApplicationTelemetry.self,
            from: JSONSerialization.data(withJSONObject: legacyTelemetry))
        try check(legacyTelemetryDecoded.partialMetrics == nil && legacyTelemetryDecoded.receivedBytesDelta == 30,
                  "old telemetry JSON without partialMetrics remains decodable")
        var partialGap = HistoryAccumulator()
        _ = partialGap.ingest(sample(700))
        var gapKnown = partialKnown
        gapKnown.timestamp = 1000; gapKnown.uptime = 1000; gapKnown.intervalSeconds = 300
        gapKnown.applications[0].residentBytes = nil
        _ = partialGap.ingest(gapKnown)
        try check(partialGap.savedReports[0].applications[0].partialMetrics == nil &&
                  partialGap.savedReports[0].applications[0].cpuSeconds == nil,
                  "partial deltas excluded by a monitoring gap do not affect totals or flags")
        var partialReplaced = HistoryAccumulator()
        _ = partialReplaced.ingest(sample(700))
        var replacedKnown = partialKnown
        replacedKnown.timestamp = 710; replacedKnown.uptime = 710
        replacedKnown.applications[0].mainPID = 2; replacedKnown.applications[0].residentBytes = nil
        _ = partialReplaced.ingest(replacedKnown)
        try check(partialReplaced.savedReports[0].applications[0].partialMetrics == nil &&
                  partialReplaced.savedReports[0].applications[0].observedRunningSeconds == 0,
                  "partial deltas across an application replacement are not accumulated or flagged")

        var energy = HistoryAccumulator()
        var power = sample(600)
        power.systemPowerWatts = 20; power.powerSource = "systemDC"
        _ = energy.ingest(power)
        power.timestamp = 610; power.uptime = 610
        _ = energy.ingest(power)
        try check(abs((energy.savedReports[0].energyWh ?? -1) - 20 * 10 / 3600) < 0.000001,
                  "reliable system power takes priority without double counting battery power")
        _ = energy.ingest(sample(620))
        _ = energy.ingest(sample(630))
        try check(energy.savedReports[0].energySource == "mixed" && energy.savedReports[0].energyCoverageSeconds == 20,
                  "different energy scopes are disclosed and switching interval is excluded")

        var recovered = HistoryAccumulator(reports: [report])
        _ = recovered.ingest(sample(700))
        try check(recovered.savedReports[0].observedSeconds == 10 && recovered.savedReports[0].gapCount == 1,
                  "crash recovery cannot integrate the unobserved interval")
        var recoveredWithPrior = HistoryAccumulator(reports: [report])
        recoveredWithPrior.previous = sample(120)
        _ = recoveredWithPrior.ingest(sample(700))
        try check(recoveredWithPrior.savedReports[0].gapCount == 1 &&
                  recoveredWithPrior.savedReports[0].gapSeconds == 580,
                  "recovered interval cannot be counted again as a sampling gap")
        recovered.finish(reason: "applicationExited")
        try check(recovered.savedReports[0].endIncomplete && recovered.savedReports[0].endReason == "applicationExited",
                  "explicit application exit seals incomplete monitoring")
        let recoveredEncoded = try JSONEncoder().encode(HistoryDocument(report: recovered.savedReports[0]))
        let decoded = try JSONDecoder().decode(HistoryDocument.self, from: recoveredEncoded)
        try check(decoded.report.observedSeconds == 10 && decoded.report.curve.last?.gapBefore == true,
                  "report checkpoint retains exact cumulative totals and gap marker")

        var long = HistoryAccumulator()
        _ = long.ingest(sample(1000))
        for step in 1...2500 { _ = long.ingest(sample(1000 + Double(step * 10))) }
        try check(long.savedReports[0].curve.count <= 1200 && long.savedReports[0].curveDownsampled,
                  "curve is bounded and downsampling disclosed")
        try check(long.savedReports[0].observedSeconds == 25_000 && long.savedReports[0].receivedBytes == 250_000 &&
                  long.savedReports[0].applications[0].cpuSeconds == 5000,
                  "curve downsampling does not approximate cumulative statistics")
        var bytes: UInt64? = UInt64.max
        try check(!HistoryRules.add(1, to: &bytes) && bytes == UInt64.max, "overflow is rejected without wrapping")
        let megabyte: UInt64 = 1024 * 1024
        let evictions = HistoryRules.evictionIDs([(id: "old", size: 32 * megabyte, modified: 1),
                                                 (id: "newer", size: 32 * megabyte, modified: 2),
                                                 (id: "active", size: 2 * megabyte, modified: 3)], activeID: "active")
        try check(evictions == ["old"], "64 MB storage cap evicts oldest closed report and keeps active report")
        try check(HistoryRules.evictionIDs([(id: "active", size: megabyte, modified: 0)], activeID: "active").isEmpty,
                  "bounded active checkpoint is retained rather than deleted")
        return count
    }
}
