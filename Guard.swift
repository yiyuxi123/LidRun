import Foundation
import Darwin
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import CoreGraphics

// All privileged paths and executable arguments are fixed. No shell is used.
private let stateDirectory = "/Library/Application Support/LidRun"
private let statePath = stateDirectory + "/state.json"
private let baselinePath = stateDirectory + "/baseline.json"
private let helperPath = "/Library/PrivilegedHelperTools/local.lidrun.guard"
private let daemonPlistPath = "/Library/LaunchDaemons/local.lidrun.guard.plist"
private let daemonLabel = "local.lidrun.guard"
private let runningPhases: Set<String> = ["prepared", "activating", "active", "restoring"]
private let minimumDuration = 60
private let maximumDuration = 43_200

private struct GuardError: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

private struct OwnerIdentity: Equatable {
    let pid: Int32
    let uid: UInt32
    let seconds: UInt64
    let microseconds: UInt64
    var startTime: String { "\(seconds).\(String(format: "%06llu", microseconds))" }
}

private struct SessionState: Codable {
    var version = 1
    var sessionID: String
    var phase: String
    var reason: String?
    var error: String?
    var originalDisabled: Bool
    var ownerPID: Int32
    var ownerUID: UInt32
    var ownerStartTime: String
    var bootID: String
    var mode: String
    var durationSeconds: Int
    var createdAt: Double
    var expiresAt: Double
    var expiresUptime: Double
    var updatedAt: Double
    var batteryPercent: Int?
    var onAC: Bool?
    var thermalState: Int?
    var thermalWarningLevel: UInt32?
    var cpuSpeedLimit: Int?
    var cpuSchedulerLimit: Int?
    var lowPowerModeEnabled: Bool?
    var lidClosed: Bool?
    var displaySleepRequestedAt: Double?
    var displaySleepError: String?
    var displaySleepFailureCount: Int?
    var displaySleepVerifiedAt: Double?
    var displayAsleep: Bool?
    var displayEnforcement: String?
    var sleepInitialObservation: SleepObservation?
    var sleepLatestObservation: SleepObservation?
    var sleepCheckAttempts: Int?
    var sleepRecheckElapsed: Double?

    func validate() throws {
        guard version == 1, UUID(uuidString: sessionID) != nil,
              runningPhases.contains(phase) || phase == "restored",
              !originalDisabled, ownerPID > 1, ownerUID > 0,
              !ownerStartTime.isEmpty, !bootID.isEmpty,
              mode == "battery" || mode == "ac",
              (minimumDuration...maximumDuration).contains(durationSeconds),
              createdAt.isFinite, expiresAt.isFinite, expiresUptime.isFinite,
              expiresUptime > 0,
              abs(expiresAt - createdAt - Double(durationSeconds)) < 1 else {
            throw GuardError("Invalid or unsupported saved session; refusing to overwrite its journal.")
        }
    }

    mutating func capture(_ power: PowerSnapshot) {
        batteryPercent = power.batteryPercent
        onAC = power.onAC
        thermalState = power.thermalState
        thermalWarningLevel = power.thermalWarningLevel
        cpuSpeedLimit = power.cpuSpeedLimit
        cpuSchedulerLimit = power.cpuSchedulerLimit
        lowPowerModeEnabled = power.lowPowerModeEnabled
        updatedAt = Date().timeIntervalSince1970
    }
}

private struct PowerSnapshot: Codable {
    var batteryPercent: Int?
    var onAC: Bool?
    var thermalState: Int
    var thermalWarningLevel: UInt32?
    var cpuSpeedLimit: Int?
    var cpuSchedulerLimit: Int?
    var lowPowerModeEnabled: Bool = false

    var thermallyUnsafe: Bool {
        if thermalState >= ProcessInfo.ThermalState.serious.rawValue { return true }
        if let warning = thermalWarningLevel, warning != 255, warning >= 5 { return true }
        // These are additional conservative cutoffs where the older IOKit API is supported.
        if let limit = cpuSpeedLimit, limit >= 0 && limit <= 50 { return true }
        if let limit = cpuSchedulerLimit, limit >= 0 && limit <= 50 { return true }
        return false
    }
}

private struct DisplaySnapshot {
    var lidClosed: Bool?
    var displayAsleep: Bool?
    var displayPowerState: Int?
    var externalDisplayCount: Int?
}

private func displaySnapshot() -> DisplaySnapshot {
    var result = DisplaySnapshot()
    let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    if root != 0 {
        if let value = IORegistryEntryCreateCFProperty(root, kAppleClamshellStateKey as CFString,
                                                       kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
            result.lidClosed = value.boolValue
        }
        IOObjectRelease(root)
    }
    let wrangler = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IODisplayWrangler"))
    if wrangler != 0 {
        if let power = IORegistryEntryCreateCFProperty(wrangler, "IOPowerManagement" as CFString,
                                                       kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
            result.displayPowerState = (power["CurrentPowerState"] as? NSNumber)?.intValue
        }
        IOObjectRelease(wrangler)
    }
    // IODisplayWrangler does not publish a power state on contemporary Apple
    // Silicon machines. Prefer the public CoreGraphics state of the built-in panel.
    var count: UInt32 = 0
    if CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0, count <= 128 {
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        if CGGetOnlineDisplayList(count, &displays, &count) == .success {
            result.externalDisplayCount = 0
            for display in displays.prefix(Int(count)) {
                if CGDisplayIsBuiltin(display) != 0 {
                    result.displayAsleep = CGDisplayIsAsleep(display) != 0
                } else { result.externalDisplayCount! += 1 }
            }
        }
    }
    if result.displayAsleep == nil, let power = result.displayPowerState, power >= 0 {
        result.displayAsleep = power <= 1
    }
    return result
}

private func shouldRequestDisplaySleep(lidClosed: Bool?, displayAsleep: Bool?,
                                       externalDisplayCount: Int?, previousLidClosed: Bool?,
                                       lastAttemptUptime: Double?, uptime: Double) -> Bool {
    guard lidClosed == true, (externalDisplayCount ?? 0) == 0 else { return false }
    if previousLidClosed != true { return true }
    if displayAsleep == true { return false }
    guard let lastAttemptUptime else { return true }
    return uptime - lastAttemptUptime >= 2
}

private struct DisplayEnforcement {
    var sessionID: String?
    var previousLidClosed: Bool?
    var lastAttemptUptime: Double?
    var pendingVerification = false
    var failures = 0

    // Display requests stay outside the activation catch: an initial display
    // failure records diagnostics; only three consecutive failures end the session.
    mutating func enforce(_ state: inout SessionState) -> Bool {
        if sessionID != state.sessionID {
            sessionID = state.sessionID
            previousLidClosed = nil
            lastAttemptUptime = nil
            pendingVerification = false
            failures = state.displaySleepFailureCount ?? 0
        }
        let display = displaySnapshot()
        state.lidClosed = display.lidClosed
        state.displayAsleep = display.displayAsleep
        guard state.phase == "active" else { return false }
        guard let closed = display.lidClosed else {
            state.displaySleepError = "Unable to read the lid state."
            state.displayEnforcement = "unavailable"
            return false
        }
        if !closed || (display.externalDisplayCount ?? 0) > 0 {
            previousLidClosed = closed
            lastAttemptUptime = nil
            pendingVerification = false
            failures = 0
            state.displaySleepFailureCount = 0
            state.displaySleepError = nil
            state.displayEnforcement = closed ? "externalDisplay" : "lidOpen"
            return false
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        if display.displayAsleep == true {
            failures = 0
            pendingVerification = false
            state.displaySleepFailureCount = 0
            state.displaySleepError = nil
            state.displaySleepVerifiedAt = Date().timeIntervalSince1970
            state.displayEnforcement = "asleep"
        } else if pendingVerification, display.displayAsleep == false,
                  let lastAttemptUptime, uptime - lastAttemptUptime >= 2 {
            failures += 1
            pendingVerification = false
            state.displaySleepError = "The built-in display remained awake after a sleep request."
        }
        let request = shouldRequestDisplaySleep(lidClosed: closed, displayAsleep: display.displayAsleep,
                                                externalDisplayCount: display.externalDisplayCount,
                                                previousLidClosed: previousLidClosed,
                                                lastAttemptUptime: lastAttemptUptime, uptime: uptime)
        previousLidClosed = closed
        if failures >= 3 { state.displaySleepFailureCount = failures; return true }
        if request {
            // Recheck immediately before the command so a recent reopening is
            // respected. Opening the lid stops all display enforcement.
            guard displaySnapshot().lidClosed == true else { return false }
            lastAttemptUptime = uptime
            state.displaySleepRequestedAt = Date().timeIntervalSince1970
            state.displayEnforcement = "sleepRequested"
            do {
                let result = try command("/usr/bin/pmset", ["displaysleepnow"], timeout: 2)
                let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                // pmset's display-idle implementation can print an error while
                // returning zero, so stderr/output is also treated as a failure.
                if result.timedOut || result.status != 0 || !message.isEmpty {
                    throw GuardError(message.isEmpty ? "The display sleep request failed." : message)
                }
                state.displaySleepError = nil
                pendingVerification = true
                if display.displayAsleep == nil { failures = 0 }
            } catch {
                failures += 1
                pendingVerification = false
                state.displaySleepError = String(describing: error)
            }
        }
        state.displaySleepFailureCount = failures
        return failures >= 3
    }
}

private struct CommandResult {
    let status: Int32
    let output: String
    let timedOut: Bool
}

private enum SessionSleepStatus {
    case enabled, changed, unavailable
}

private struct SleepObservation: Codable {
    var preferenceReadAt: Double
    var kernelReadAt: Double
    var preferenceDisabled: Bool?
    var kernelDisabled: Bool?
    var preferenceRawLine: String?
    var preferenceExitStatus: Int32?
    var preferenceTimedOut: Bool?
    var preferenceReadError: String?
    var kernelReadError: String?

    var status: SessionSleepStatus {
        guard preferenceReadError == nil, kernelReadError == nil,
              let preferenceDisabled, let kernelDisabled else { return .unavailable }
        return preferenceDisabled && kernelDisabled ? .enabled : .changed
    }
}

private struct SleepVerification {
    let initial: SleepObservation
    let latest: SleepObservation
    let attempts: Int
    let recheckElapsed: Double
    var status: SessionSleepStatus { latest.status }
}

private func rootRequired() throws {
    guard geteuid() == 0 else { throw GuardError("Administrator authorization is required.") }
}

private func processIdentity(_ pid: Int32) -> OwnerIdentity? {
    var info = proc_bsdinfo()
    let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
    guard count == MemoryLayout<proc_bsdinfo>.size,
          info.pbi_pid == UInt32(pid), info.pbi_start_tvsec > 0,
          info.pbi_status != UInt32(SZOMB) else { return nil }
    return OwnerIdentity(pid: pid, uid: info.pbi_uid,
                         seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
}

private func ownerIsAlive(_ state: SessionState) -> Bool {
    guard let identity = processIdentity(state.ownerPID) else { return false }
    return identity.uid == state.ownerUID && identity.startTime == state.ownerStartTime
}

private func currentBootID() throws -> String {
    var boot = timeval()
    var size = MemoryLayout<timeval>.size
    guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0,
          size == MemoryLayout<timeval>.size, boot.tv_sec > 0 else {
        throw GuardError("Unable to read the current boot identity.")
    }
    return "\(boot.tv_sec).\(boot.tv_usec)"
}

private func command(_ executable: String, _ arguments: [String], timeout: Double = 5,
                     terminationGrace: Double = 0.5) throws -> CommandResult {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(20_000) }
    let expired = process.isRunning
    if expired {
        process.terminate()
        let killDeadline = ProcessInfo.processInfo.systemUptime + terminationGrace
        while process.isRunning && ProcessInfo.processInfo.systemUptime < killDeadline { usleep(20_000) }
        if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    }
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return CommandResult(status: process.terminationStatus,
                         output: String(data: data, encoding: .utf8) ?? "", timedOut: expired)
}

private func parseSleepDisabled(_ result: CommandResult) throws -> Bool {
    guard !result.timedOut && result.status == 0 else {
        throw GuardError("pmset could not read the sleep setting: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    for line in result.output.split(separator: "\n") {
        let words = line.split(whereSeparator: { $0.isWhitespace })
        if words.first == "SleepDisabled" {
            guard words.count == 2, words[1] == "0" || words[1] == "1" else {
                throw GuardError("pmset returned an unrecognized SleepDisabled value.")
            }
            return words[1] == "1"
        }
    }
    // pmset omits unset system-wide flags on some macOS versions. A failed command
    // is handled above and is never confused with an absent (default 0) flag.
    return false
}

private func readSleepDisabled() throws -> Bool {
    try parseSleepDisabled(command("/usr/bin/pmset", ["-g"]))
}

private func readKernelSleepDisabled() throws -> Bool {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { throw GuardError("IOPMrootDomain is unavailable.") }
    defer { IOObjectRelease(service) }
    guard let value = IORegistryEntryCreateCFProperty(service, "SleepDisabled" as CFString,
                                                     kCFAllocatorDefault, 0)?.takeRetainedValue(),
          let number = value as? NSNumber else {
        throw GuardError("The kernel sleep flag is unavailable.")
    }
    return number.boolValue
}

private func readSleepObservation(timeout: Double) -> SleepObservation {
    var result = SleepObservation(preferenceReadAt: 0, kernelReadAt: 0)
    do {
        let preferences = try command("/usr/bin/pmset", ["-g"], timeout: timeout,
                                      terminationGrace: timeout < 5 ? 0 : 0.5)
        result.preferenceExitStatus = preferences.status
        result.preferenceTimedOut = preferences.timedOut
        result.preferenceRawLine = preferences.output.split(separator: "\n").first {
            $0.split(whereSeparator: { $0.isWhitespace }).first == "SleepDisabled"
        }.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        result.preferenceDisabled = try parseSleepDisabled(preferences)
    } catch { result.preferenceReadError = String(describing: error) }
    result.preferenceReadAt = Date().timeIntervalSince1970
    // Always read both channels, even if pmset reports false or fails.
    do { result.kernelDisabled = try readKernelSleepDisabled() }
    catch { result.kernelReadError = String(describing: error) }
    result.kernelReadAt = Date().timeIntervalSince1970
    return result
}

private func verifySessionSleep(
    read: (Double) -> SleepObservation = { readSleepObservation(timeout: $0) },
    uptime: () -> Double = { ProcessInfo.processInfo.systemUptime },
    pause: (UInt32) -> Void = { _ = usleep($0) }
) -> SleepVerification {
    let initial = read(5)
    if initial.status == .enabled {
        return SleepVerification(initial: initial, latest: initial, attempts: 1, recheckElapsed: 0)
    }
    let started = uptime()
    let deadline = started + 0.4
    var latest = initial
    var attempts = 1
    // Two extra observations at most. Their waits and command timeouts share
    // the same 0.4-second budget; they never re-enable the sleep override.
    for _ in 0..<2 {
        guard deadline - uptime() > 0.1 else { break }
        pause(100_000)
        let remaining = deadline - uptime()
        guard remaining > 0 else { break }
        latest = read(min(0.1, remaining))
        attempts += 1
        if latest.status == .enabled { break }
    }
    return SleepVerification(initial: initial, latest: latest, attempts: attempts,
                             recheckElapsed: max(0, uptime() - started))
}

private func powerSnapshot() -> PowerSnapshot {
    var percent: Int?
    var onAC: Bool?
    if let sourceInfo = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
       let list = IOPSCopyPowerSourcesList(sourceInfo)?.takeRetainedValue() as? [CFTypeRef] {
        for source in list {
            guard let unmanaged = IOPSGetPowerSourceDescription(sourceInfo, source),
                  let values = unmanaged.takeUnretainedValue() as? [String: Any],
                  values[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  (values[kIOPSIsPresentKey] as? NSNumber)?.boolValue != false,
                  let capacity = values[kIOPSCurrentCapacityKey] as? NSNumber,
                  let maximum = values[kIOPSMaxCapacityKey] as? NSNumber,
                  maximum.doubleValue > 0, capacity.doubleValue >= 0 else { continue }
            percent = min(100, max(0, Int(floor(100 * capacity.doubleValue / maximum.doubleValue))))
            if let power = values[kIOPSPowerSourceStateKey] as? String {
                if power == kIOPSACPowerValue { onAC = true }
                else if power == kIOPSBatteryPowerValue { onAC = false }
            }
            break
        }
    }
    var warning: UInt32 = 0
    let warningResult = IOPMGetThermalWarningLevel(&warning)
    var cpuStatus: Unmanaged<CFDictionary>?
    let cpuResult = IOPMCopyCPUPowerStatus(&cpuStatus)
    let cpu = cpuStatus?.takeRetainedValue() as? [String: Any]
    return PowerSnapshot(batteryPercent: percent, onAC: onAC,
                         thermalState: ProcessInfo.processInfo.thermalState.rawValue,
                         thermalWarningLevel: warningResult == kIOReturnSuccess ? warning : nil,
                         cpuSpeedLimit: cpuResult == kIOReturnSuccess ? (cpu?[kIOPMCPUPowerLimitProcessorSpeedKey] as? NSNumber)?.intValue : nil,
                         cpuSchedulerLimit: cpuResult == kIOReturnSuccess ? (cpu?[kIOPMCPUPowerLimitSchedulerTimeKey] as? NSNumber)?.intValue : nil,
                         lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled)
}

private func checkedFile(_ path: String, directory: Bool = false) throws -> stat {
    var value = stat()
    guard lstat(path, &value) == 0 else { throw GuardError("Cannot inspect \(path): \(String(cString: strerror(errno)))") }
    let expected = directory ? mode_t(S_IFDIR) : mode_t(S_IFREG)
    guard value.st_mode & mode_t(S_IFMT) == expected, value.st_uid == 0,
          value.st_mode & mode_t(0o022) == 0, directory || value.st_nlink == 1 else {
        throw GuardError("Unsafe ownership, permissions, or file type at \(path).")
    }
    return value
}

private func secureDirectory(create: Bool) throws {
    _ = try checkedFile("/Library", directory: true)
    _ = try checkedFile("/Library/Application Support", directory: true)
    var metadata = stat()
    if lstat(stateDirectory, &metadata) != 0 {
        guard errno == ENOENT, create else { throw GuardError("No saved LidRun session.") }
        guard mkdir(stateDirectory, 0o755) == 0 || errno == EEXIST else {
            throw GuardError("Cannot create the root-owned session directory.")
        }
    }
    _ = try checkedFile(stateDirectory, directory: true)
}

private final class FileLock {
    private let descriptor: Int32
    init(_ name: String, nonblocking: Bool = false) throws {
        descriptor = open(stateDirectory + "/" + name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw GuardError("Cannot open session lock.") }
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_uid == 0,
              value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              value.st_mode & mode_t(0o022) == 0, value.st_nlink == 1 else {
            close(descriptor)
            throw GuardError("Session lock has unsafe ownership or permissions.")
        }
        guard flock(descriptor, LOCK_EX | (nonblocking ? LOCK_NB : 0)) == 0 else {
            close(descriptor)
            throw GuardError("Another guard is already running.")
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

private func atomicWrite(_ data: Data, to path: String) throws {
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
    _ = try checkedFile(directory, directory: true)
    var metadata = stat()
    if lstat(path, &metadata) == 0 { _ = try checkedFile(path) }
    else if errno != ENOENT { throw GuardError("Cannot inspect destination \(path).") }
    let temporary = directory + "/.lidrun-" + UUID().uuidString
    let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw GuardError("Cannot create journal temporary file.") }
    var renamed = false
    defer { close(descriptor); if !renamed { unlink(temporary) } }
    try data.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let count = write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw GuardError("Cannot write the session journal.") }
            offset += count
        }
    }
    guard fchmod(descriptor, 0o644) == 0, fsync(descriptor) == 0,
          rename(temporary, path) == 0 else { throw GuardError("Cannot commit the session journal.") }
    renamed = true
    let parent = open(directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard parent >= 0 else { throw GuardError("Cannot open the journal directory for synchronization.") }
    defer { close(parent) }
    guard fsync(parent) == 0 else { throw GuardError("Cannot synchronize the session journal directory.") }
}

private func loadState(at path: String = statePath) throws -> SessionState? {
    var metadata = stat()
    if lstat(path, &metadata) != 0 {
        if errno == ENOENT { return nil }
        throw GuardError("Cannot inspect the saved session.")
    }
    _ = try checkedFile(path)
    guard metadata.st_size <= 65_536 else { throw GuardError("Saved session is unexpectedly large.") }
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw GuardError("Cannot read the saved session.") }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    let data = try handle.readToEnd() ?? Data()
    let state = try JSONDecoder().decode(SessionState.self, from: data)
    try state.validate()
    return state
}

private func saveState(_ state: SessionState) throws {
    try state.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try atomicWrite(encoder.encode(state), to: statePath)
}

private func saveBaseline(_ state: SessionState) throws {
    var baseline = state
    baseline.phase = "prepared"
    baseline.reason = nil
    baseline.error = nil
    try baseline.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try atomicWrite(encoder.encode(baseline), to: baselinePath)
}

private func ensureBaseline(_ state: SessionState) throws {
    if let baseline = try loadState(at: baselinePath) {
        guard baseline.sessionID == state.sessionID else {
            throw GuardError("The baseline journal belongs to a different session.")
        }
        return
    }
    // Upgrade an already-active session using its saved original flag, never the
    // currently enabled live flag. Once saved, the backup is not updated again.
    try saveBaseline(state)
}

private func installDaemonPlist() throws {
    _ = try checkedFile("/Library/PrivilegedHelperTools", directory: true)
    let helper = try checkedFile(helperPath)
    guard helper.st_mode & mode_t(0o111) != 0 else { throw GuardError("The installed helper is not executable.") }
    let plist: [String: Any] = [
        "Label": daemonLabel,
        "ProgramArguments": [helperPath, "--daemon"],
        "RunAtLoad": true,
        "KeepAlive": true,
        "ThrottleInterval": 3,
        "ExitTimeOut": 30,
        "ProcessType": "Background",
        "UserName": "root",
        "WorkingDirectory": "/",
        "Umask": 0o022
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try atomicWrite(data, to: daemonPlistPath)
}

private func setAndVerifySleepDisabled(_ disabled: Bool) throws {
    let result = try command("/usr/bin/pmset", ["-a", "disablesleep", disabled ? "1" : "0"])
    guard !result.timedOut && result.status == 0 else {
        throw GuardError("pmset could not update the sleep setting: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    // Preferences and the kernel can settle at slightly different times.
    var lastError = "Sleep setting did not match the requested value."
    for _ in 0..<10 {
        do {
            if try readSleepDisabled() == disabled && readKernelSleepDisabled() == disabled { return }
        } catch { lastError = String(describing: error) }
        usleep(100_000)
    }
    throw GuardError("Could not verify the sleep setting in both pmset and the kernel: \(lastError)")
}

private func terminalReason(_ state: SessionState, boot: String, alive: Bool,
                            power: PowerSnapshot, uptime: Double, wallTime: Double,
                            stopping: Bool) -> String? {
    if boot != state.bootID { return "rebooted" }
    if stopping { return "helperStopping" }
    if !alive { return "ownerExited" }
    if uptime >= state.expiresUptime || wallTime >= state.expiresAt { return "timeExpired" }
    if power.lowPowerModeEnabled { return "lowPowerMode" }
    if power.thermallyUnsafe { return "thermalPressure" }
    guard let battery = power.batteryPercent, let onAC = power.onAC else { return "powerStatusUnavailable" }
    if battery <= 20 { return "lowBattery" }
    if state.mode == "ac" && !onAC { return "powerDisconnected" }
    return nil
}

// Caller holds state.lock. A restoration failure preserves the baseline and is
// retried by the watchdog (including after a process crash and launchd restart).
@discardableResult
private func restore(_ state: inout SessionState, reason: String) -> Bool {
    state.phase = "restoring"
    state.reason = reason
    state.error = nil
    state.updatedAt = Date().timeIntervalSince1970
    do { try saveState(state) }
    catch { state.error = "Could not journal restoration: \(error)" }
    do {
        try setAndVerifySleepDisabled(state.originalDisabled)
        state.phase = "restored"
        state.error = nil
        state.updatedAt = Date().timeIntervalSince1970
        try saveState(state)
        return true
    } catch {
        state.phase = "restoring"
        state.error = String(describing: error)
        state.updatedAt = Date().timeIntervalSince1970
        try? saveState(state)
        fputs("LidRun restoration will retry: \(error)\n", stderr)
        return false
    }
}

private func printState(_ state: SessionState) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(state)
    print(String(decoding: data, as: UTF8.self))
}

private func prepare(_ args: [String]) throws {
    try rootRequired()
    guard args.count == 2 || args.count == 3,
          let pid = Int32(args[0]), pid > 1,
          let duration = Int(args[1]), (minimumDuration...maximumDuration).contains(duration) else {
        throw GuardError("Usage: --prepare GUARDIAN_PID DURATION_SECONDS [battery|ac]; duration must be 60–43200 seconds.")
    }
    let mode = args.count == 3 ? args[2] : "battery"
    guard mode == "battery" || mode == "ac" else { throw GuardError("Mode must be battery or ac.") }
    try secureDirectory(create: true)
    let lock = try FileLock("state.lock")
    defer { withExtendedLifetime(lock) {} }
    if let previous = try loadState(), runningPhases.contains(previous.phase) {
        throw GuardError("A session is already prepared, active, or awaiting restoration. Stop it before starting another.")
    }
    guard let owner = processIdentity(pid), owner.uid != 0 else {
        throw GuardError("The guardian must be a running process owned by a non-root user.")
    }
    let original = try readSleepDisabled()
    guard !original else { throw GuardError("alreadyDisabled: sleep is already disabled outside LidRun; restore that setting before starting a guarded session.") }
    guard try readKernelSleepDisabled() == original else { throw GuardError("pmset and kernel sleep settings disagree; refusing to start.") }
    let now = Date().timeIntervalSince1970
    let power = powerSnapshot()
    var state = SessionState(sessionID: UUID().uuidString, phase: "prepared",
                             originalDisabled: original, ownerPID: owner.pid, ownerUID: owner.uid,
                             ownerStartTime: owner.startTime, bootID: try currentBootID(), mode: mode,
                             durationSeconds: duration, createdAt: now, expiresAt: now + Double(duration),
                             expiresUptime: ProcessInfo.processInfo.systemUptime + Double(duration), updatedAt: now)
    state.capture(power)
    if let reason = terminalReason(state, boot: state.bootID, alive: true, power: power,
                                   uptime: ProcessInfo.processInfo.systemUptime, wallTime: now, stopping: false) {
        throw GuardError("Cannot start a session: \(reason).")
    }
    // Both files are durable before the daemon can mutate power settings.
    try installDaemonPlist()
    try saveBaseline(state)
    try saveState(state)
    try printState(state)
}

private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func request() { lock.lock(); value = true; lock.unlock() }
    var requested: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private func daemon() throws {
    try rootRequired()
    try secureDirectory(create: true)
    let singleton = try FileLock("daemon.lock", nonblocking: true)
    defer { withExtendedLifetime(singleton) {} }
    let stop = StopFlag()
    var signals: [DispatchSourceSignal] = []
    for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
        source.setEventHandler { stop.request() }
        source.resume()
        signals.append(source)
    }
    defer { signals.forEach { $0.cancel() } }
    var lastKnownSession: SessionState?
    var displayEnforcement = DisplayEnforcement()
    while true {
        var safelyStopped = false
        do {
            let lock = try FileLock("state.lock")
            defer { withExtendedLifetime(lock) {} }
            do {
                let saved = try loadState()
                if saved == nil, var known = try lastKnownSession ?? loadState(at: baselinePath) {
                    safelyStopped = restore(&known, reason: "journalUnavailable")
                    lastKnownSession = runningPhases.contains(known.phase) ? known : nil
                } else if var state = saved, runningPhases.contains(state.phase) {
                    let power = powerSnapshot()
                    state.capture(power)
                    // Retain a validated baseline even if subsequent reads fail.
                    lastKnownSession = state
                    try ensureBaseline(state)
                    let reason = try terminalReason(state, boot: currentBootID(), alive: ownerIsAlive(state), power: power,
                                                    uptime: ProcessInfo.processInfo.systemUptime,
                                                    wallTime: Date().timeIntervalSince1970, stopping: stop.requested)
                    if state.phase == "restoring" {
                        safelyStopped = restore(&state, reason: state.reason ?? "manualRecovery")
                    } else if let reason {
                        safelyStopped = restore(&state, reason: reason)
                    } else if state.phase == "prepared" || state.phase == "activating" {
                        do {
                            state.phase = "activating"
                            state.error = nil
                            try saveState(state)
                            try setAndVerifySleepDisabled(true)
                            state.phase = "active"
                            state.updatedAt = Date().timeIntervalSince1970
                        } catch {
                            state.error = String(describing: error)
                            safelyStopped = restore(&state, reason: "activationFailed")
                        }
                    } else {
                        let verification = verifySessionSleep()
                        state.sleepInitialObservation = verification.initial
                        state.sleepLatestObservation = verification.latest
                        state.sleepCheckAttempts = verification.attempts
                        state.sleepRecheckElapsed = verification.recheckElapsed
                        switch verification.status {
                        case .enabled: break
                        case .changed:
                            safelyStopped = restore(&state, reason: "sleepOverrideChanged")
                        case .unavailable:
                            safelyStopped = restore(&state, reason: "sleepStatusUnavailable")
                        }
                    }
                    if state.phase == "active" {
                        if displayEnforcement.enforce(&state) {
                            safelyStopped = restore(&state, reason: "displaySleepFailed")
                        } else { try saveState(state) }
                    }
                    lastKnownSession = runningPhases.contains(state.phase) ? state : nil
                } else {
                    lastKnownSession = nil
                    safelyStopped = true
                }
            } catch {
                fputs("LidRun watchdog error: \(error)\n", stderr)
                var recovery = lastKnownSession
                var freshJournalRecovered = false
                // The lock remains held throughout recovery. If a transient read
                // failure clears, use the fresh journal and never overwrite a newer
                // valid session UUID with the cached one.
                do {
                    if let fresh = try loadState() {
                        freshJournalRecovered = true
                        recovery = runningPhases.contains(fresh.phase) ? fresh : nil
                        if recovery == nil { safelyStopped = true }
                    }
                } catch { /* Use only the previously validated baseline. */ }
                if recovery == nil && !freshJournalRecovered {
                    recovery = try? loadState(at: baselinePath)
                }
                if var known = recovery {
                    safelyStopped = restore(&known, reason: "journalUnavailable")
                    lastKnownSession = runningPhases.contains(known.phase) ? known : nil
                } else { lastKnownSession = nil }
            }
        } catch {
            fputs("LidRun cannot acquire the session lock; will retry: \(error)\n", stderr)
        }
        if stop.requested && safelyStopped { return }
        // Running the main run loop keeps Foundation thermal notifications live.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
    }
}

private func manualRestore() throws {
    try rootRequired()
    try secureDirectory(create: false)
    let lock = try FileLock("state.lock")
    defer { withExtendedLifetime(lock) {} }
    let saved: SessionState?
    do { saved = try loadState() ?? loadState(at: baselinePath) }
    catch {
        guard let backup = try loadState(at: baselinePath) else { throw error }
        saved = backup
    }
    guard var state = saved else { print("{\"phase\":\"idle\"}"); return }
    guard restore(&state, reason: "manualRecovery") else { throw GuardError(state.error ?? "Restoration failed; the watchdog will retry.") }
    try printState(state)
}

private func diagnose() throws {
    let power = powerSnapshot()
    let display = displaySnapshot()
    var result: [String: Any] = [
        "batteryPercent": power.batteryPercent as Any? ?? NSNull(),
        "onAC": power.onAC as Any? ?? NSNull(),
        "thermalState": power.thermalState,
        "thermalWarningLevel": power.thermalWarningLevel as Any? ?? NSNull(),
        "cpuSpeedLimit": power.cpuSpeedLimit as Any? ?? NSNull(),
        "cpuSchedulerLimit": power.cpuSchedulerLimit as Any? ?? NSNull(),
        "thermallyUnsafe": power.thermallyUnsafe,
        "lowPowerModeEnabled": power.lowPowerModeEnabled,
        "lidClosed": display.lidClosed as Any? ?? NSNull(),
        "displayAsleep": display.displayAsleep as Any? ?? NSNull(),
        "displayPowerState": display.displayPowerState as Any? ?? NSNull(),
        "externalDisplayCount": display.externalDisplayCount as Any? ?? NSNull()
    ]
    var errors: [String] = []
    var disabled: Bool?
    var kernelDisabled: Bool?
    do { disabled = try readSleepDisabled(); result["sleepDisabled"] = disabled }
    catch { errors.append(String(describing: error)); result["sleepDisabled"] = NSNull() }
    do { kernelDisabled = try readKernelSleepDisabled(); result["kernelSleepDisabled"] = kernelDisabled }
    catch { errors.append(String(describing: error)); result["kernelSleepDisabled"] = NSNull() }
    result["safeToStart"] = errors.isEmpty && disabled == false && kernelDisabled == false &&
        (power.batteryPercent ?? 0) > 20 && power.onAC != nil && !power.thermallyUnsafe
        && !power.lowPowerModeEnabled
    result["errors"] = errors
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

private func selfTest() throws {
    var count = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw GuardError("Self-test failed: \(label)") }
        count += 1
    }
    try check(try parseSleepDisabled(CommandResult(status: 0, output: "SleepDisabled\t1\n", timedOut: false)), "parse enabled")
    try check(try !parseSleepDisabled(CommandResult(status: 0, output: "System-wide power settings:\n SleepDisabled 0\n", timedOut: false)), "parse disabled")
    try check(try !parseSleepDisabled(CommandResult(status: 0, output: "Currently in use:\n sleep 1\n", timedOut: false)), "absent flag defaults to zero")
    for invalid in [CommandResult(status: 1, output: "", timedOut: false),
                    CommandResult(status: 0, output: "", timedOut: true),
                    CommandResult(status: 0, output: "SleepDisabled invalid", timedOut: false)] {
        do { _ = try parseSleepDisabled(invalid); throw GuardError("Self-test accepted an invalid pmset result.") }
        catch let error as GuardError {
            if error.description.hasPrefix("Self-test") { throw error }
            count += 1
        }
    }
    let owner = processIdentity(getpid())
    try check(owner != nil, "read PID start identity")
    let boot = try currentBootID()
    try check(!boot.isEmpty, "read boot identity")
    var state = SessionState(sessionID: UUID().uuidString, phase: "prepared", originalDisabled: false,
                             ownerPID: 100, ownerUID: 501, ownerStartTime: "100.000001", bootID: boot,
                             mode: "battery", durationSeconds: 60, createdAt: 100, expiresAt: 160,
                             expiresUptime: 160, updatedAt: 100)
    try state.validate()
    let normal = PowerSnapshot(batteryPercent: 80, onAC: true, thermalState: 0)
    func reason(_ power: PowerSnapshot = normal, _ currentBoot: String = boot,
                _ alive: Bool = true, _ uptime: Double = 120, _ wall: Double = 120,
                _ stopping: Bool = false) -> String? {
        terminalReason(state, boot: currentBoot, alive: alive, power: power, uptime: uptime,
                       wallTime: wall, stopping: stopping)
    }
    try check(reason() == nil, "safe battery session")
    try check(reason(normal, "another boot") == "rebooted", "reboot cutoff")
    try check(reason(normal, boot, false) == "ownerExited", "guardian exit cutoff")
    try check(reason(normal, boot, true, 160) == "timeExpired", "monotonic deadline cutoff")
    try check(reason(normal, boot, true, 120, 160) == "timeExpired", "wall deadline cutoff")
    try check(reason(normal, boot, true, 120, 120, true) == "helperStopping", "termination restoration")
    try check(reason(PowerSnapshot(batteryPercent: 20, onAC: true, thermalState: 0)) == "lowBattery", "20 percent threshold")
    try check(reason(PowerSnapshot(batteryPercent: 80, onAC: false, thermalState: 2)) == "thermalPressure", "serious thermal cutoff")
    try check(reason(PowerSnapshot(batteryPercent: 80, onAC: true, thermalState: 0, thermalWarningLevel: 10)) == "thermalPressure", "IOKit critical thermal cutoff")
    try check(reason(PowerSnapshot(batteryPercent: 80, onAC: true, thermalState: 0, cpuSchedulerLimit: 30)) == "thermalPressure", "CPU thermal limit cutoff")
    try check(reason(PowerSnapshot(batteryPercent: 80, onAC: true, thermalState: 0, lowPowerModeEnabled: true)) == "lowPowerMode", "user low power mode cutoff")
    try check(reason(PowerSnapshot(batteryPercent: nil, onAC: nil, thermalState: 0)) == "powerStatusUnavailable", "unreadable battery cutoff")
    try check(reason(PowerSnapshot(batteryPercent: 80, onAC: false, thermalState: 0)) == nil, "battery mode permits unplugging")
    state.mode = "ac"
    try check(reason(PowerSnapshot(batteryPercent: 80, onAC: false, thermalState: 0)) == "powerDisconnected", "AC mode unplug cutoff")
    let encoded = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(SessionState.self, from: encoded)
    try decoded.validate()
    try check(decoded.ownerStartTime == state.ownerStartTime && decoded.originalDisabled == false, "journal round trip preserves baseline and PID identity")
    var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    for key in ["lowPowerModeEnabled", "lidClosed", "displaySleepRequestedAt", "displaySleepError",
                "displaySleepFailureCount", "displaySleepVerifiedAt", "displayAsleep", "displayEnforcement"] {
        legacy.removeValue(forKey: key)
    }
    let legacyState = try JSONDecoder().decode(SessionState.self, from: JSONSerialization.data(withJSONObject: legacy))
    try legacyState.validate()
    try check(legacyState.lidClosed == nil && legacyState.lowPowerModeEnabled == nil &&
              legacyState.sessionID == state.sessionID, "active pre-upgrade journal remains compatible")
    var invalidBaseline = decoded
    invalidBaseline.originalDisabled = true
    do { try invalidBaseline.validate(); throw GuardError("Self-test accepted an unsafe backup baseline.") }
    catch let error as GuardError {
        if error.description.hasPrefix("Self-test") { throw error }
        count += 1
    }
    var badIdentity = decoded
    badIdentity.ownerUID = 0
    do { try badIdentity.validate(); throw GuardError("Self-test accepted an invalid backup owner.") }
    catch let error as GuardError {
        if error.description.hasPrefix("Self-test") { throw error }
        count += 1
    }
    try check(shouldRequestDisplaySleep(lidClosed: true, displayAsleep: false, externalDisplayCount: 0,
                                        previousLidClosed: nil, lastAttemptUptime: nil, uptime: 100), "restart while closed requests display sleep")
    try check(!shouldRequestDisplaySleep(lidClosed: false, displayAsleep: false, externalDisplayCount: 0,
                                         previousLidClosed: true, lastAttemptUptime: nil, uptime: 100), "open lid stops display enforcement")
    try check(!shouldRequestDisplaySleep(lidClosed: nil, displayAsleep: false, externalDisplayCount: 0,
                                         previousLidClosed: true, lastAttemptUptime: nil, uptime: 100), "unreadable lid never blanks an open screen")
    try check(!shouldRequestDisplaySleep(lidClosed: true, displayAsleep: false, externalDisplayCount: 1,
                                         previousLidClosed: false, lastAttemptUptime: nil, uptime: 100), "external monitor is preserved")
    try check(!shouldRequestDisplaySleep(lidClosed: true, displayAsleep: true, externalDisplayCount: 0,
                                         previousLidClosed: true, lastAttemptUptime: 95, uptime: 100), "already asleep display is not repeatedly requested")
    try check(!shouldRequestDisplaySleep(lidClosed: true, displayAsleep: false, externalDisplayCount: 0,
                                         previousLidClosed: true, lastAttemptUptime: 99, uptime: 100), "retry rate is bounded")
    try check(shouldRequestDisplaySleep(lidClosed: true, displayAsleep: false, externalDisplayCount: 0,
                                        previousLidClosed: true, lastAttemptUptime: 98, uptime: 100), "closed display wakes are retried after two seconds")
    try check(shouldRequestDisplaySleep(lidClosed: true, displayAsleep: nil, externalDisplayCount: nil,
                                        previousLidClosed: true, lastAttemptUptime: 98, uptime: 100), "unknown display status permits bounded retry")
    let enabled = SleepObservation(preferenceReadAt: 100, kernelReadAt: 100,
                                   preferenceDisabled: true, kernelDisabled: true)
    let disabled = SleepObservation(preferenceReadAt: 101, kernelReadAt: 101,
                                    preferenceDisabled: false, kernelDisabled: false)
    let mismatch = SleepObservation(preferenceReadAt: 101, kernelReadAt: 101,
                                    preferenceDisabled: false, kernelDisabled: true)
    let unreadable = SleepObservation(preferenceReadAt: 101, kernelReadAt: 101,
                                      kernelDisabled: true, preferenceReadError: "injected read failure")
    func simulatedSleepCheck(_ observations: [SleepObservation], readCost: Double = 0)
        -> (SleepVerification, [Double]) {
        var clock: Double = 1000
        var index = 0
        var timeouts: [Double] = []
        let result = verifySessionSleep(read: { timeout in
            timeouts.append(timeout)
            if index > 0 { clock += min(readCost, timeout) }
            let observation = observations[min(index, observations.count - 1)]
            index += 1
            return observation
        }, uptime: { clock }, pause: { clock += Double($0) / 1_000_000 })
        return (result, timeouts)
    }
    let normalCheck = simulatedSleepCheck([enabled]).0
    try check(normalCheck.status == .enabled && normalCheck.attempts == 1 && normalCheck.recheckElapsed == 0,
              "normal sleep check requires one observation")
    let transientCheck = simulatedSleepCheck([mismatch, enabled]).0
    try check(transientCheck.status == .enabled && transientCheck.attempts == 2 &&
              transientCheck.initial.preferenceDisabled == false && transientCheck.initial.kernelDisabled == true,
              "transient mismatch continues session and retains both initial values")
    try check(simulatedSleepCheck([disabled, enabled]).0.status == .enabled,
              "transient disabled reading does not stop the session")
    let persistentDisabled = simulatedSleepCheck([disabled]).0
    try check(persistentDisabled.status == .changed && persistentDisabled.attempts == 3,
              "persistently disabled setting ends the session")
    try check(simulatedSleepCheck([mismatch]).0.status == .changed,
              "persistent mismatch ends the session without re-enabling the override")
    let persistentFailure = simulatedSleepCheck([unreadable]).0
    try check(persistentFailure.status == .unavailable && persistentFailure.attempts == 3 &&
              persistentFailure.latest.preferenceReadError != nil && persistentFailure.latest.kernelDisabled == true,
              "persistent read failure requests failure recovery and retains the other channel")
    try check(simulatedSleepCheck([unreadable, enabled]).0.status == .enabled,
              "transient read failure recovers without ending the session")
    let budgeted = simulatedSleepCheck([unreadable], readCost: 1)
    try check(budgeted.0.recheckElapsed <= 0.400_001 &&
              budgeted.1.dropFirst().allSatisfy { $0 > 0 && $0 <= 0.1 },
              "recheck budget includes bounded child command timeouts")
    let observedData = try JSONEncoder().encode(transientCheck.initial)
    let observedRoundTrip = try JSONDecoder().decode(SleepObservation.self, from: observedData)
    try check(observedRoundTrip.preferenceDisabled == false && observedRoundTrip.kernelDisabled == true &&
              observedRoundTrip.preferenceReadAt == 101 && observedRoundTrip.kernelReadAt == 101,
              "journal diagnostics preserve independent values and timestamps")
    print("{\"passed\":\(count),\"powerSettingsChanged\":false}")
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let action = arguments.first else { throw GuardError("Usage: --prepare | --daemon | --restore | --diagnose | --self-test") }
    switch action {
    case "--prepare": try prepare(Array(arguments.dropFirst()))
    case "--daemon":
        guard arguments.count == 1 else { throw GuardError("--daemon takes no arguments.") }
        try daemon()
    case "--restore":
        guard arguments.count == 1 else { throw GuardError("--restore takes no arguments.") }
        try manualRestore()
    case "--diagnose":
        guard arguments.count == 1 else { throw GuardError("--diagnose takes no arguments.") }
        try diagnose()
    case "--self-test":
        guard arguments.count == 1 else { throw GuardError("--self-test takes no arguments.") }
        try selfTest()
    default: throw GuardError("Unknown command.")
    }
} catch {
    fputs("LidRun: \(error)\n", stderr)
    exit(1)
}
