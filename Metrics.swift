import Foundation

// Nullable measurements are deliberately distinct from measured zero.
struct ApplicationTelemetry: Codable, Identifiable, Sendable {
    var id: String
    var name: String
    var bundleIdentifier: String?
    var mainPID: Int32
    var processCount: Int
    var cpuPercent: Double?
    var cpuSecondsDelta: Double?
    var residentBytes: UInt64?
    var receivedBytesDelta: UInt64?
    var sentBytesDelta: UInt64?
    var cpuEnergyJoulesDelta: Double?
    var instanceID: String? = nil
    // Known member totals remain useful when helpers appear, exit, or are unreadable.
    // These metric keys describe lower bounds, never a complete application total.
    var partialMetrics: [String]? = nil
}

struct TelemetrySnapshot: Codable, Identifiable, Sendable {
    var id: Double { timestamp }
    var timestamp: Double
    var uptime: Double
    var bootID: String
    var intervalSeconds: Double?
    var lidClosed: Bool?
    var sleepDisabled: Bool?
    var guardPhase: String?
    var thermalLevel: Int
    var chipTemperatureC: Double?
    var batteryTemperatureC: Double?
    var temperatureSource: String?
    var systemCPUPercent: Double?
    var memoryUsedBytes: UInt64?
    var memoryTotalBytes: UInt64
    var memoryPressure: Int?
    var receivedBytesDelta: UInt64?
    var sentBytesDelta: UInt64?
    var interfaceNames: [String]
    var batteryPercent: Double?
    var onAC: Bool?
    var isCharging: Bool?
    var batteryDischargeWatts: Double?
    var systemPowerWatts: Double?
    var powerSource: String?
    var applications: [ApplicationTelemetry]
    var limitations: [String]
    var collectionDurationSeconds: Double
    var systemSleepObserved = false

    var date: Date { Date(timeIntervalSince1970: timestamp) }
    var estimatedLoadWatts: Double? {
        systemPowerWatts ?? (onAC == false ? batteryDischargeWatts : nil)
    }
    var receivedBytesPerSecond: Double? {
        guard let seconds = intervalSeconds, seconds > 0, let bytes = receivedBytesDelta else { return nil }
        return Double(bytes) / seconds
    }
    var sentBytesPerSecond: Double? {
        guard let seconds = intervalSeconds, seconds > 0, let bytes = sentBytesDelta else { return nil }
        return Double(bytes) / seconds
    }
}
