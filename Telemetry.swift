import Foundation
import AppKit
import Darwin
import IOKit
import IOKit.ps

private struct TelemetryIdentity: Hashable, Sendable {
    var pid: Int32
    var uid: UInt32
    var seconds: UInt64
    var microseconds: UInt64
}

private struct TelemetryBytes: Equatable, Sendable {
    var received: UInt64
    var sent: UInt64
}

private struct TelemetryApplication: Sendable {
    var pid: Int32
    var name: String
    var bundleID: String?
    var bundlePath: String?
    var stableID: String { "app:" + (bundleID ?? bundlePath ?? name) }
}

private struct TelemetryProcess: Sendable {
    var identity: TelemetryIdentity
    var parentPID: Int32
    var name: String
    var path: String?
    var userTicks: UInt64?
    var systemTicks: UInt64?
    var residentBytes: UInt64?
    var energyNanojoules: UInt64?
    var network: TelemetryBytes?
}

private struct TelemetryRaw: Sendable {
    var timestamp: Double
    var uptime: Double
    var bootID: String
    var cpuTicks: [UInt32]?
    var secondsPerTick: Double?
    var interfaces: [String: TelemetryBytes]?
    var processes: [Int32: TelemetryProcess]
    var guiApplications: [TelemetryApplication]
    var energySupported: Bool
    var snapshot: TelemetrySnapshot
}

private struct TelemetryResult: Sendable {
    var raw: TelemetryRaw
    var snapshot: TelemetrySnapshot
}

// Sampling has no timers or application controls. The UI chooses its cadence.
// Coalescing concurrent requests prevents overlapping nettop children and baselines.
actor TelemetrySampler {
    private var previous: TelemetryRaw?
    private var pending: (UUID, Task<TelemetryResult, Never>)?

    func sample() async -> TelemetrySnapshot {
        if let pending { return await pending.1.value.snapshot }
        let token = UUID()
        let prior = previous
        let task = Task.detached(priority: .utility) {
            let started = ProcessInfo.processInfo.systemUptime
            let applications = await MainActor.run {
                NSWorkspace.shared.runningApplications.compactMap { application -> TelemetryApplication? in
                    guard !application.isTerminated, application.activationPolicy != .prohibited else { return nil }
                    return TelemetryApplication(pid: application.processIdentifier,
                                                name: application.localizedName ?? "PID \(application.processIdentifier)",
                                                bundleID: application.bundleIdentifier,
                                                bundlePath: application.bundleURL?.path)
                }
            }
            var raw = TelemetryCollector.collect(applications: applications)
            var snapshot = TelemetryCollector.finish(&raw, previous: prior)
            snapshot.collectionDurationSeconds = max(0, ProcessInfo.processInfo.systemUptime - started)
            return TelemetryResult(raw: raw, snapshot: snapshot)
        }
        pending = (token, task)
        let result = await task.value
        if pending?.0 == token {
            previous = result.raw
            pending = nil
        }
        return result.snapshot
    }

    nonisolated static func selfTest() throws -> Int {
        try TelemetryCollector.selfTest()
    }
}

private enum TelemetryCollector {
    static func instanceID(_ identity: TelemetryIdentity?) -> String? {
        identity.map { "\($0.pid):\($0.seconds).\($0.microseconds)" }
    }

    static func priorityBackground(_ members: [TelemetryProcess]) -> Bool {
        let text = members.map { $0.name + " " + ($0.path ?? "") }.joined(separator: " ").lowercased()
        return ["chatgpt", "codex", "vpn", "lightxtreme", "leigod", "闪连"].contains { text.contains($0) }
    }

    static func counterDelta(_ current: UInt64?, _ previous: UInt64?) -> UInt64? {
        guard let current, let previous, current >= previous else { return nil }
        return current - previous
    }

    static func sumComplete(_ values: [UInt64?]) -> UInt64? {
        guard !values.isEmpty else { return nil }
        var total: UInt64 = 0
        for value in values {
            guard let value else { return nil }
            let result = total.addingReportingOverflow(value)
            guard !result.overflow else { return nil }
            total = result.partialValue
        }
        return total
    }

    static func sumKnownUnsigned(_ values: [UInt64?]) -> (value: UInt64?, partial: Bool) {
        let known = values.compactMap { $0 }
        guard !known.isEmpty else { return (nil, false) }
        var total: UInt64 = 0
        for value in known {
            let result = total.addingReportingOverflow(value)
            guard !result.overflow else { return (nil, false) }
            total = result.partialValue
        }
        return (total, known.count < values.count)
    }

    static func sumKnownSeconds(_ values: [Double?]) -> (value: Double?, partial: Bool) {
        let known = values.compactMap { $0 }
        guard !known.isEmpty, known.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return (nil, false) }
        let total = known.reduce(0, +)
        guard total.isFinite else { return (nil, false) }
        return (total, known.count < values.count)
    }

    static func systemCPU(_ current: [UInt32]?, _ previous: [UInt32]?) -> Double? {
        guard let current, let previous, current.count == 4, previous.count == 4 else { return nil }
        let changes = zip(current, previous).map { counterDelta(UInt64($0), UInt64($1)) }
        guard let total = sumComplete(changes), total > 0,
              let idle = changes[Int(CPU_STATE_IDLE)] else { return nil }
        return 100 * Double(total - idle) / Double(total)
    }

    static func cpuSeconds(_ current: TelemetryProcess, _ previous: TelemetryProcess?,
                           secondsPerTick: Double?) -> Double? {
        guard let previous, current.identity == previous.identity,
              let factor = secondsPerTick, factor.isFinite, factor > 0,
              let user = counterDelta(current.userTicks, previous.userTicks),
              let system = counterDelta(current.systemTicks, previous.systemTicks) else { return nil }
        let seconds = (Double(user) + Double(system)) * factor
        return seconds.isFinite ? seconds : nil
    }

    static func physicalInterface(_ name: String, type: UInt8, flags: UInt32) -> Bool {
        name.hasPrefix("en") && type == UInt8(IFT_ETHER) && flags & UInt32(IFF_UP) != 0 &&
            flags & UInt32(IFF_LOOPBACK) == 0
    }

    static func interfaceDelta(_ current: [String: TelemetryBytes]?,
                               _ previous: [String: TelemetryBytes]?, received: Bool) -> UInt64? {
        guard let current, let previous, !current.isEmpty,
              Set(current.keys) == Set(previous.keys) else { return nil }
        return sumComplete(current.keys.sorted().map { key in
            counterDelta(received ? current[key]?.received : current[key]?.sent,
                         received ? previous[key]?.received : previous[key]?.sent)
        })
    }

    static func readBootID() -> String {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else { return "unavailable" }
        return "\(boot.tv_sec).\(boot.tv_usec)"
    }

    static func systemCounters() -> ([UInt32]?, UInt64?, Int?, Double?) {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var cpu = host_cpu_load_info()
        var cpuCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let cpuResult = withUnsafeMutablePointer(to: &cpu) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &cpuCount)
            }
        }
        let ticks: [UInt32]? = cpuResult == KERN_SUCCESS ?
            [cpu.cpu_ticks.0, cpu.cpu_ticks.1, cpu.cpu_ticks.2, cpu.cpu_ticks.3] : nil
        var vm = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &vmCount)
            }
        }
        var pageSize: vm_size_t = 0
        let pageResult = host_page_size(host, &pageSize)
        var used: UInt64?
        if vmResult == KERN_SUCCESS, pageResult == KERN_SUCCESS {
            let free = (UInt64(vm.free_count) + UInt64(vm.speculative_count)) * UInt64(pageSize)
            let total = ProcessInfo.processInfo.physicalMemory
            if free <= total { used = total - free }
        }
        var pressure: Int32 = 0
        var pressureSize = MemoryLayout<Int32>.size
        let pressureResult = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0)
        var timebase = mach_timebase_info_data_t()
        let timeResult = mach_timebase_info(&timebase)
        let factor = timeResult == KERN_SUCCESS && timebase.denom > 0 ?
            Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000 : nil
        return (ticks, used, pressureResult == 0 ? Int(pressure) : nil, factor)
    }

    static func readInterfaces() -> [String: TelemetryBytes]? {
        if let counters = readPhysicalNetwork64() {
            return counters.mapValues { TelemetryBytes(received: $0.received, sent: $0.sent) }
        }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var result: [String: TelemetryBytes] = [:]
        var cursor = list
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let entry = current.pointee
            guard let address = entry.ifa_addr, Int32(address.pointee.sa_family) == AF_LINK,
                  let data = entry.ifa_data, let namePointer = entry.ifa_name else { continue }
            let name = String(cString: namePointer)
            let statistics = data.assumingMemoryBound(to: if_data.self).pointee
            guard physicalInterface(name, type: statistics.ifi_type, flags: entry.ifa_flags) else { continue }
            result[name] = TelemetryBytes(received: UInt64(statistics.ifi_ibytes), sent: UInt64(statistics.ifi_obytes))
        }
        return result
    }

    static func readBSD(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        if bytes <= 0 && errno == EPERM {
            // Some root VPN services deny libproc metadata while exposing the same
            // immutable process identity through the unprivileged BSD sysctl.
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            var kernelInfo = kinfo_proc()
            var length = MemoryLayout<kinfo_proc>.size
            let result = mib.withUnsafeMutableBufferPointer {
                sysctl($0.baseAddress, UInt32($0.count), &kernelInfo, &length, nil, 0)
            }
            guard result == 0, length == MemoryLayout<kinfo_proc>.size else { return nil }
            return bsdFromKernel(kernelInfo, pid: pid)
        }
        guard bytes == MemoryLayout<proc_bsdinfo>.size, info.pbi_start_tvsec > 0,
              info.pbi_status != UInt32(SZOMB) else { return nil }
        return info
    }

    static func bsdFromKernel(_ kernelInfo: kinfo_proc, pid: Int32) -> proc_bsdinfo? {
        let birth = kernelInfo.kp_proc.p_un.__p_starttime
        guard kernelInfo.kp_proc.p_pid == pid, pid > 0, birth.tv_sec > 0,
              birth.tv_usec >= 0, birth.tv_usec < 1_000_000,
              kernelInfo.kp_proc.p_stat > 0, Int32(kernelInfo.kp_proc.p_stat) != SZOMB else { return nil }
        var info = proc_bsdinfo()
        info.pbi_pid = UInt32(pid)
        info.pbi_ppid = UInt32(max(0, kernelInfo.kp_eproc.e_ppid))
        info.pbi_uid = kernelInfo.kp_eproc.e_ucred.cr_uid
        info.pbi_status = UInt32(kernelInfo.kp_proc.p_stat)
        info.pbi_start_tvsec = UInt64(birth.tv_sec)
        info.pbi_start_tvusec = UInt64(birth.tv_usec)
        // The sysctl comm field is truncated. Leave pbi_name empty so the existing
        // proc_pidpath basename supplies a full service name when it is readable.
        return info
    }

    static func identity(_ pid: Int32, _ info: proc_bsdinfo) -> TelemetryIdentity {
        TelemetryIdentity(pid: pid, uid: info.pbi_uid,
                          seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }

    static func processPath(_ pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let capacity = UInt32(buffer.count)
        let size = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, capacity) }
        guard size > 0 else { return nil }
        return String(bytes: buffer.prefix { $0 != 0 }, encoding: .utf8)
    }

    static func readProcesses() -> [Int32: TelemetryProcess] {
        let capacity = min(32_768, max(128, Int(proc_listallpids(nil, 0)) + 128))
        var pids = [Int32](repeating: 0, count: capacity)
        let bufferSize = Int32(capacity * MemoryLayout<Int32>.size)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, bufferSize) }
        guard count > 0 else { return [:] }
        var result: [Int32: TelemetryProcess] = [:]
        for pid in pids.prefix(min(Int(count), capacity)) where pid > 0 {
            guard let info = readBSD(pid), info.pbi_uid == getuid() || info.pbi_uid == 0 else { continue }
            var usage = rusage_info_v6()
            let status = withUnsafeMutablePointer(to: &usage) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6,
                                UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self))
            }
            var user: UInt64?, system: UInt64?, resident: UInt64?, energy: UInt64?
            if status == 0 {
                user = usage.ri_user_time
                system = usage.ri_system_time
                resident = usage.ri_resident_size
                energy = usage.ri_energy_nj
            } else {
                var older = rusage_info_v4()
                let olderStatus = withUnsafeMutablePointer(to: &older) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4,
                                    UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self))
                }
                if olderStatus == 0 {
                    user = older.ri_user_time
                    system = older.ri_system_time
                    resident = older.ri_resident_size
                }
            }
            let path = processPath(pid)
            var nameBuffer = info.pbi_name
            let name = withUnsafeBytes(of: &nameBuffer) {
                String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8)
            }
            result[pid] = TelemetryProcess(identity: identity(pid, info), parentPID: Int32(info.pbi_ppid),
                                           name: name?.isEmpty == false ? name! : (path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "PID \(pid)"),
                                           path: path, userTicks: user, systemTicks: system,
                                           residentBytes: resident, energyNanojoules: energy, network: nil)
        }
        return result
    }

    static func ancestor(_ pid: Int32, is target: Int32, processes: [Int32: TelemetryProcess]) -> Bool {
        var next = pid
        var visited: Set<Int32> = []
        for _ in 0..<64 {
            guard next > 1, visited.insert(next).inserted else { return false }
            if next == target { return true }
            guard let process = processes[next] else { return false }
            next = process.parentPID
        }
        return false
    }

    static func guiOwner(_ pid: Int32, processes: [Int32: TelemetryProcess],
                         applications: [TelemetryApplication]) -> TelemetryApplication? {
        var next = pid
        var visited: Set<Int32> = []
        for _ in 0..<64 {
            guard next > 1, visited.insert(next).inserted else { break }
            if let app = applications.first(where: { $0.pid == next }) { return app }
            guard let process = processes[next] else { break }
            next = process.parentPID
        }
        guard let path = processes[pid]?.path else { return nil }
        return applications.filter { app in
            guard let bundle = app.bundlePath else { return false }
            return path.hasPrefix(bundle + "/")
        }.max { ($0.bundlePath?.count ?? 0) < ($1.bundlePath?.count ?? 0) }
    }

    static func parseCSV(_ text: String) -> [[String]]? {
        let characters = Array(text)
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if quoted && index + 1 < characters.count && characters[index + 1] == "\"" {
                    field.append("\""); index += 1
                } else if quoted || field.isEmpty { quoted.toggle() }
                else { return nil }
            } else if character == "," && !quoted {
                row.append(field); field = ""
            } else if character == "\n" && !quoted {
                row.append(field.trimmingCharacters(in: .newlines)); rows.append(row)
                row = []; field = ""
            } else { field.append(character) }
            index += 1
        }
        guard !quoted else { return nil }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func processID(_ name: String) -> Int32? {
        guard let dot = name.lastIndex(of: "."), let pid = Int32(name[name.index(after: dot)...]), pid > 0 else { return nil }
        return pid
    }

    static func parseNettop(_ text: String) -> ([Int32: TelemetryBytes], Set<Int32>)? {
        guard let rows = parseCSV(text), let headerIndex = rows.firstIndex(where: { $0.contains("bytes_in") && $0.contains("bytes_out") }),
              let receivedIndex = rows[headerIndex].firstIndex(of: "bytes_in"),
              let sentIndex = rows[headerIndex].firstIndex(of: "bytes_out") else { return nil }
        var counters: [Int32: TelemetryBytes] = [:]
        var unavailable: Set<Int32> = []
        for row in rows.dropFirst(headerIndex + 1) {
            guard let pid = row.first.flatMap(processID) else { continue }
            guard row.count > max(receivedIndex, sentIndex),
                  let received = UInt64(row[receivedIndex]), let sent = UInt64(row[sentIndex]) else {
                unavailable.insert(pid); counters.removeValue(forKey: pid); continue
            }
            let value = TelemetryBytes(received: received, sent: sent)
            if let previous = counters[pid], previous != value {
                unavailable.insert(pid); counters.removeValue(forKey: pid)
            } else if !unavailable.contains(pid) { counters[pid] = value }
        }
        return (counters, unavailable)
    }

    // Drain while the owned child is running: waiting first can deadlock when
    // nettop's process table grows beyond the kernel pipe capacity.
    static func readChildOutput(_ child: Process, timeout: Double = 2,
                                maximumBytes: Int = 2_000_000) -> (data: Data?, failure: String?) {
        guard timeout.isFinite, timeout > 0, maximumBytes >= 0 else { return (nil, "configuration") }
        let output = Pipe()
        defer {
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        let fd = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return (nil, "read") }
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output
        child.standardError = output
        child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        do { try child.run() } catch { return (nil, "launch") }
        // The child has its own duplicated descriptor; the parent's writer must
        // close so the reader can observe EOF when that child closes its output.
        try? output.fileHandleForWriting.close()
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var eof = false
        var failure: String?
        while failure == nil {
            while !eof {
                let size = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if size > 0 {
                    guard size <= maximumBytes - data.count else { failure = "overflow"; break }
                    data.append(contentsOf: buffer.prefix(size))
                } else if size == 0 {
                    eof = true
                    break
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    break
                } else if errno != EINTR {
                    failure = "read"
                    break
                }
                if ProcessInfo.processInfo.systemUptime >= deadline { failure = "timeout"; break }
            }
            if failure != nil { break }
            if !child.isRunning && eof { break }
            if ProcessInfo.processInfo.systemUptime >= deadline { failure = "timeout"; break }
            usleep(10_000)
        }
        if failure != nil && child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
        child.waitUntilExit()
        guard failure == nil else { return (nil, failure) }
        guard child.terminationStatus == 0 else { return (nil, "exit") }
        return (data, nil)
    }

    // This is the only sampling subprocess. It reads one cumulative CSV sample,
    // without DNS resolution. A timeout terminates only this sampler's own child.
    static func nettop(pids: [Int32]) -> ([Int32: TelemetryBytes], Set<Int32>, String?)? {
        guard !pids.isEmpty else { return ([:], [], nil) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        // nettop caps repeated -p filters at a small platform-dependent count.
        // Read one table and retain only the already-authorized process IDs below.
        child.arguments = ["-P", "-L", "1", "-x", "-n", "-J", "bytes_in,bytes_out"]
        guard let data = readChildOutput(child).data,
              let text = String(data: data, encoding: .utf8), let parsed = parseNettop(text) else { return nil }
        let selected = Set(pids)
        let counters = parsed.0.filter { selected.contains($0.key) }
        let unavailable = parsed.1.intersection(selected)
        return (counters, unavailable, unavailable.isEmpty ? nil : "部分进程网络计数不可读，保留为空值。")
    }

    static func registry(_ name: String) -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(name))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return nil }
        return properties?.takeRetainedValue() as? [String: Any]
    }

    static func battery() -> (Double?, Bool?, Bool?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (nil, nil, nil) }
        for source in list {
            guard let dictionary = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  dictionary[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let capacity = dictionary[kIOPSCurrentCapacityKey] as? NSNumber,
                  let maximum = dictionary[kIOPSMaxCapacityKey] as? NSNumber, maximum.doubleValue > 0 else { continue }
            let state = dictionary[kIOPSPowerSourceStateKey] as? String
            let onAC: Bool? = state == kIOPSACPowerValue ? true : (state == kIOPSBatteryPowerValue ? false : nil)
            return (min(100, max(0, 100 * capacity.doubleValue / maximum.doubleValue)), onAC,
                    (dictionary[kIOPSIsChargingKey] as? NSNumber)?.boolValue)
        }
        return (nil, nil, nil)
    }

    static func power(_ battery: [String: Any]?, onAC: Bool?) -> (Double?, Double?, String?) {
        let telemetry = battery?["PowerTelemetryData"] as? [String: Any]
        var total: Double?
        var discharge: Double?
        if let load = (telemetry?["SystemLoad"] as? NSNumber)?.doubleValue, load > 0, load <= 250_000 {
            total = load / 1000
        }
        if let power = (telemetry?["BatteryPower"] as? NSNumber)?.int64Value, abs(Double(power)) <= 250_000 {
            discharge = power < 0 ? -Double(power) / 1000 : 0
        } else if let current = (battery?["InstantAmperage"] as? NSNumber)?.int64Value,
                  let voltage = (battery?["Voltage"] as? NSNumber)?.doubleValue,
                  abs(Double(current)) < 30_000, voltage > 0, voltage < 30_000 {
            discharge = current < 0 ? -Double(current) * voltage / 1_000_000 : 0
        }
        let source: String
        if total != nil {
            source = "整机DC负载传感器估算；遥测刷新可能延迟，应用能量只统计CPU。"
        } else if onAC == false, discharge != nil {
            source = "整机功率传感器不可用；电池供电下可改用电池放电功率估算。"
        } else {
            source = "整机功率传感器不可用，未用CPU百分比估算功率。"
        }
        return (total, discharge, source)
    }

    static func temperatures() -> (Double?, Double?, String?) {
        typealias Create = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
        typealias Match = @convention(c) (CFTypeRef, CFDictionary) -> Void
        typealias Services = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
        typealias Property = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
        typealias Event = @convention(c) (CFTypeRef, UInt32, CFTypeRef?, UInt32) -> Unmanaged<CFTypeRef>?
        typealias FloatValue = @convention(c) (CFTypeRef, UInt32) -> Double
        guard let library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return (nil, nil, nil) }
        defer { dlclose(library) }
        guard let createSymbol = dlsym(library, "IOHIDEventSystemClientCreate"),
              let matchSymbol = dlsym(library, "IOHIDEventSystemClientSetMatching"),
              let servicesSymbol = dlsym(library, "IOHIDEventSystemClientCopyServices"),
              let propertySymbol = dlsym(library, "IOHIDServiceClientCopyProperty"),
              let eventSymbol = dlsym(library, "IOHIDServiceClientCopyEvent"),
              let floatSymbol = dlsym(library, "IOHIDEventGetFloatValue") else { return (nil, nil, nil) }
        let create = unsafeBitCast(createSymbol, to: Create.self)
        let match = unsafeBitCast(matchSymbol, to: Match.self)
        let services = unsafeBitCast(servicesSymbol, to: Services.self)
        let property = unsafeBitCast(propertySymbol, to: Property.self)
        let event = unsafeBitCast(eventSymbol, to: Event.self)
        let value = unsafeBitCast(floatSymbol, to: FloatValue.self)
        guard let client = create(kCFAllocatorDefault)?.takeRetainedValue() else { return (nil, nil, nil) }
        match(client, ["PrimaryUsagePage": 65280, "PrimaryUsage": 5] as CFDictionary)
        guard let list = services(client)?.takeRetainedValue() else { return (nil, nil, nil) }
        var chip: Double?, battery: Double?
        for index in 0..<CFArrayGetCount(list) {
            guard let pointer = CFArrayGetValueAtIndex(list, index) else { continue }
            let service = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
            guard let name = property(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  let reading = event(service, 15, nil, 0)?.takeRetainedValue() else { continue }
            let celsius = value(reading, 15 << 16)
            guard celsius.isFinite, celsius > 0, celsius <= 150 else { continue }
            if name.lowercased().contains("tdie") { chip = max(chip ?? celsius, celsius) }
            else if name.lowercased().contains("battery") { battery = max(battery ?? celsius, celsius) }
        }
        return (chip, battery, chip == nil && battery == nil ? nil : "IOHID温度传感器；芯片取最高有效结温，未猜测CPU/GPU映射。")
    }

    static func guardPhase() -> String? {
        let url = URL(fileURLWithPath: "/Library/Application Support/LidRun/state.json")
        guard let data = try? Data(contentsOf: url), data.count <= 65_536,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return value["phase"] as? String
    }

    static func collect(applications: [TelemetryApplication]) -> TelemetryRaw {
        let started = ProcessInfo.processInfo.systemUptime
        let timestamp = Date().timeIntervalSince1970
        let boot = readBootID()
        let system = systemCounters()
        let interfaces = readInterfaces()
        var processes = readProcesses()
        let own = getpid()
        let guiPIDs = Set(applications.map(\.pid))
        let excluded = processes.keys.filter { pid in
            (pid != own || !guiPIDs.contains(own)) && ancestor(pid, is: own, processes: processes)
        }
        excluded.forEach { processes.removeValue(forKey: $0) }
        let userApps = applications.filter { processes[$0.pid]?.identity.uid == getuid() }
        var limitations: [String] = []
        if let network = nettop(pids: Array(processes.keys)) {
            if let note = network.2 { limitations.append(note) }
            for pid in Array(processes.keys) {
                guard let old = processes[pid], let currentBSD = readBSD(pid),
                      identity(pid, currentBSD) == old.identity else { continue }
                if !network.1.contains(pid) {
                    processes[pid]?.network = network.0[pid] ?? TelemetryBytes(received: 0, sent: 0)
                }
            }
        } else { limitations.append("应用网络采样不可用或超时，未请求管理员权限。") }
        let root = registry("IOPMrootDomain")
        let smartBattery = registry("AppleSmartBattery")
        let batteryState = battery()
        let powerState = power(smartBattery, onAC: batteryState.1)
        let temperature = temperatures()
        if temperature.0 == nil { limitations.append("芯片温度传感器不可用，仍显示系统热压力。") }
        if interfaces == nil || interfaces?.isEmpty == true { limitations.append("物理网络接口计数不可用。") }
        limitations.append("应用流量是socket累计差分，VPN可在独立服务另计，不能与物理接口总量相加。")
        limitations.append("应用内存为当前进程RSS合计，共享页可能重复；新PID或计数回绕重建基线。")
        let snapshot = TelemetrySnapshot(timestamp: timestamp, uptime: started, bootID: boot,
                                         lidClosed: (root?["AppleClamshellState"] as? NSNumber)?.boolValue,
                                         sleepDisabled: (root?["SleepDisabled"] as? NSNumber)?.boolValue,
                                         guardPhase: guardPhase(), thermalLevel: ProcessInfo.processInfo.thermalState.rawValue,
                                         chipTemperatureC: temperature.0, batteryTemperatureC: temperature.1,
                                         temperatureSource: temperature.2, memoryUsedBytes: system.1,
                                         memoryTotalBytes: ProcessInfo.processInfo.physicalMemory,
                                         memoryPressure: system.2, interfaceNames: interfaces?.keys.sorted() ?? [],
                                         batteryPercent: batteryState.0, onAC: batteryState.1, isCharging: batteryState.2,
                                         batteryDischargeWatts: powerState.1, systemPowerWatts: powerState.0,
                                         powerSource: powerState.2, applications: [], limitations: limitations,
                                         collectionDurationSeconds: max(0, ProcessInfo.processInfo.systemUptime - started))
        return TelemetryRaw(timestamp: timestamp, uptime: started, bootID: boot, cpuTicks: system.0,
                            secondsPerTick: system.3, interfaces: interfaces, processes: processes,
                            guiApplications: userApps, energySupported: processes.values.contains { ($0.energyNanojoules ?? 0) > 0 },
                            snapshot: snapshot)
    }

    static func finish(_ raw: inout TelemetryRaw, previous: TelemetryRaw?) -> TelemetrySnapshot {
        let prior = previous.flatMap { $0.bootID == raw.bootID && raw.bootID != "unavailable" ? $0 : nil }
        let interval = prior.map { raw.uptime - $0.uptime }.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
        raw.energySupported = raw.energySupported || (prior?.energySupported ?? false)
        var snapshot = raw.snapshot
        snapshot.intervalSeconds = interval
        snapshot.systemCPUPercent = systemCPU(raw.cpuTicks, prior?.cpuTicks)
        snapshot.receivedBytesDelta = interfaceDelta(raw.interfaces, prior?.interfaces, received: true)
        snapshot.sentBytesDelta = interfaceDelta(raw.interfaces, prior?.interfaces, received: false)
        snapshot.limitations.append("后台列表始终保留重点服务，其余仅列活动前12项；不是完整系统进程清单。")
        if !raw.energySupported { snapshot.limitations.append("尚未确认可读CPU能量计数，未把CPU占用率换算成瓦数。") }
        var groups: [String: [TelemetryProcess]] = [:]
        var labels: [String: TelemetryApplication] = [:]
        var priorAppMembers: [String: Set<TelemetryIdentity>] = [:]
        if let prior {
            for process in prior.processes.values {
                if let owner = guiOwner(process.identity.pid, processes: prior.processes, applications: prior.guiApplications) {
                    priorAppMembers[owner.stableID, default: []].insert(process.identity)
                }
            }
        }
        for process in raw.processes.values {
            if let owner = guiOwner(process.identity.pid, processes: raw.processes, applications: raw.guiApplications) {
                groups[owner.stableID, default: []].append(process)
                labels[owner.stableID] = owner
            } else {
                let id = "process:\(process.identity.pid):\(process.identity.seconds).\(process.identity.microseconds)"
                groups[id] = [process]
                labels[id] = TelemetryApplication(pid: process.identity.pid, name: process.name,
                                                  bundleID: nil, bundlePath: nil)
            }
        }
        var foreground: [ApplicationTelemetry] = [], preferredBackground: [ApplicationTelemetry] = [], background: [ApplicationTelemetry] = []
        for (id, members) in groups {
            guard let label = labels[id] else { continue }
            let isApplication = id.hasPrefix("app:")
            let disappeared = isApplication && !(priorAppMembers[id] ?? []).subtracting(Set(members.map(\.identity))).isEmpty
            let cpuValues = members.map { cpuSeconds($0, prior?.processes[$0.identity.pid], secondsPerTick: raw.secondsPerTick) }
            let cpuAggregate = sumKnownSeconds(cpuValues)
            let cpu: Double? = isApplication || !cpuAggregate.partial ? cpuAggregate.value : nil
            let receivedValues = members.map { current -> UInt64? in
                guard let old = prior?.processes[current.identity.pid], old.identity == current.identity else { return nil }
                return counterDelta(current.network?.received, old.network?.received)
            }
            let sentValues = members.map { current -> UInt64? in
                guard let old = prior?.processes[current.identity.pid], old.identity == current.identity else { return nil }
                return counterDelta(current.network?.sent, old.network?.sent)
            }
            let energyValues = members.map { current -> UInt64? in
                guard raw.energySupported else { return nil }
                guard let old = prior?.processes[current.identity.pid], old.identity == current.identity else { return nil }
                return counterDelta(current.energyNanojoules, old.energyNanojoules)
            }
            let memoryValues = members.map(\.residentBytes)
            let receivedAggregate = sumKnownUnsigned(receivedValues)
            let sentAggregate = sumKnownUnsigned(sentValues)
            let energyAggregate = sumKnownUnsigned(energyValues)
            let memoryAggregate = sumKnownUnsigned(memoryValues)
            let received = isApplication ? receivedAggregate.value : sumComplete(receivedValues)
            let sent = isApplication ? sentAggregate.value : sumComplete(sentValues)
            let energy = (isApplication ? energyAggregate.value : sumComplete(energyValues)).map { Double($0) / 1_000_000_000 }
            let memory = isApplication ? memoryAggregate.value : sumComplete(memoryValues)
            var partial: [String] = []
            if isApplication {
                if cpu != nil && (cpuAggregate.partial || disappeared) { partial.append("cpu") }
                if received != nil && (receivedAggregate.partial || disappeared) { partial.append("received") }
                if sent != nil && (sentAggregate.partial || disappeared) { partial.append("sent") }
                if energy != nil && (energyAggregate.partial || disappeared) { partial.append("energy") }
                if memory != nil && memoryAggregate.partial { partial.append("memory") }
            }
            let value = ApplicationTelemetry(id: id, name: label.name, bundleIdentifier: label.bundleID,
                                              mainPID: label.pid, processCount: members.count,
                                              cpuPercent: cpu.flatMap { value in interval.map { 100 * value / $0 } },
                                              cpuSecondsDelta: cpu, residentBytes: memory,
                                              receivedBytesDelta: received, sentBytesDelta: sent,
                                              cpuEnergyJoulesDelta: energy,
                                              instanceID: instanceID(raw.processes[label.pid]?.identity),
                                              partialMetrics: partial.isEmpty ? nil : partial)
            if id.hasPrefix("app:") { foreground.append(value) }
            else if priorityBackground(members) { preferredBackground.append(value) }
            else if (value.cpuPercent ?? 0) >= 0.1 || (received ?? 0) > 0 || (sent ?? 0) > 0 ||
                        (value.residentBytes ?? 0) >= 150_000_000 {
                background.append(value)
            }
        }
        func ordering(_ lhs: ApplicationTelemetry, _ rhs: ApplicationTelemetry) -> Bool {
            if (lhs.cpuPercent ?? -1) != (rhs.cpuPercent ?? -1) { return (lhs.cpuPercent ?? -1) > (rhs.cpuPercent ?? -1) }
            if (lhs.residentBytes ?? 0) != (rhs.residentBytes ?? 0) { return (lhs.residentBytes ?? 0) > (rhs.residentBytes ?? 0) }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        snapshot.applications = foreground.sorted(by: ordering) + preferredBackground.sorted(by: ordering) +
            background.sorted(by: ordering).prefix(12)
        return snapshot
    }

    static func selfTest() throws -> Int {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
            guard condition() else { throw NSError(domain: "LidRun.Telemetry", code: 1,
                                                     userInfo: [NSLocalizedDescriptionKey: name]) }
            count += 1
        }
        try check(counterDelta(20, 10) == 10, "monotonic counter difference")
        try check(counterDelta(1, UInt64(UInt32.max)) == nil, "32-bit interface wrap never creates a giant rate")
        try check(counterDelta(nil, 10) == nil, "unreadable counter stays nullable")
        try check(systemCPU([120, 60, 210, 10], [100, 50, 150, 0]) == 40, "system CPU includes all active tick states")
        try check(systemCPU([1, 0, 2, 0], [2, 0, 2, 0]) == nil, "CPU counter reset rebuilds baseline")
        try check(physicalInterface("en0", type: UInt8(IFT_ETHER), flags: UInt32(IFF_UP)), "physical ethernet is included")
        for name in ["lo0", "utun2", "bridge0", "awdl0", "llw0"] {
            try check(!physicalInterface(name, type: UInt8(IFT_ETHER), flags: UInt32(IFF_UP)), "virtual interface excluded: " + name)
        }
        let bytes = ["en0": TelemetryBytes(received: 100, sent: 70)]
        try check(interfaceDelta(bytes, ["en0": TelemetryBytes(received: 50, sent: 20)], received: true) == 50,
                  "physical aggregate counts each interface once")
        try check(interfaceDelta(bytes, ["en1": TelemetryBytes(received: 50, sent: 20)], received: true) == nil,
                  "interface topology change rebuilds baseline")
        let csv = ",bytes_in,bytes_out,\n\"应用, A.123\",100,200,\nVPN.service.456,300,400,\n"
        let parsed = parseNettop(csv)
        try check(parsed?.0[123] == TelemetryBytes(received: 100, sent: 200), "quoted localized CSV process names")
        try check(parsed?.0[456]?.sent == 400, "PID comes from final dot, not bundle-name punctuation")
        try check(parseNettop(",bytes_in,bytes_out,\nA.123,1,2,\nA.123,3,4,\n")?.1.contains(123) == true,
                  "conflicting duplicate rows stay unknown instead of double counting")
        try check(parseNettop(",bytes_in,bytes_out,\nA.123,-,2,\n")?.1.contains(123) == true,
                  "permission placeholder stays nullable")
        try check(parseNettop("permission denied") == nil && parseCSV("\"unfinished") == nil,
                  "malformed output cannot masquerade as measured zero")
        let firstID = TelemetryIdentity(pid: 123, uid: 501, seconds: 100, microseconds: 1)
        var before = TelemetryProcess(identity: firstID, parentPID: 1, name: "App", userTicks: 10,
                                      systemTicks: 10, residentBytes: 1, energyNanojoules: 0)
        var after = before
        after.userTicks = 34
        try check(cpuSeconds(after, before, secondsPerTick: 1.0 / 24) == 1,
                  "Mach CPU time uses timebase conversion")
        after.identity.seconds = 101
        try check(cpuSeconds(after, before, secondsPerTick: 1) == nil, "PID reuse never inherits old process CPU")
        before.userTicks = nil
        try check(cpuSeconds(before, before, secondsPerTick: 1) == nil, "CPU permission failure is not zero")
        let parent = TelemetryApplication(pid: 123, name: "App", bundleID: "test.app", bundlePath: "/Apps/App.app")
        var child = after
        child.identity = TelemetryIdentity(pid: 124, uid: 501, seconds: 100, microseconds: 1)
        child.parentPID = 123
        child.path = "/Apps/App.app/Contents/Helpers/Child"
        try check(guiOwner(124, processes: [123: before, 124: child], applications: [parent])?.stableID == parent.stableID,
                  "helper ancestry resolves to GUI app")
        child.parentPID = 1
        try check(guiOwner(124, processes: [124: child], applications: [parent])?.pid == 123,
                  "reparented helper uses exact bundle prefix")
        child.path = "/Apps/App.app.fake/Helper"
        try check(guiOwner(124, processes: [124: child], applications: [parent]) == nil,
                  "similarly named independent VPN/service is not attributed to a bundle")
        try check(sumComplete([1, nil]) == nil && sumComplete([UInt64.max, 1]) == nil,
                  "partial or overflowed memory/energy sums remain nullable")
        let onBattery = power(["PowerTelemetryData": ["SystemLoad": NSNumber(value: 17_011),
                                                       "BatteryPower": NSNumber(value: -17_011)]], onAC: false)
        try check(onBattery.0 == 17.011 && onBattery.1 == 17.011, "DC load uses mW and battery discharge sign")
        try check(power(["InstantAmperage": NSNumber(value: -512), "Voltage": NSNumber(value: 12_458)], onAC: true).0 == nil,
                  "AC battery power cannot stand in for whole-system power")
        let batteryOnly = power(["PowerTelemetryData": ["BatteryPower": NSNumber(value: -8_000)]], onAC: false)
        try check(batteryOnly.0 == nil && batteryOnly.1 == 8 && batteryOnly.2?.contains("电池放电功率估算") == true,
                  "missing DC load preserves battery discharge as a separate fallback channel")
        let separatePower = power(["PowerTelemetryData": ["SystemLoad": NSNumber(value: 12_000),
                                                           "BatteryPower": NSNumber(value: -8_000)]], onAC: false)
        try check(separatePower.0 == 12 && separatePower.1 == 8,
                  "present DC and battery sensors retain distinct power readings")
        let acWithoutLoad = power(["PowerTelemetryData": ["BatteryPower": NSNumber(value: 0)]], onAC: true)
        try check(acWithoutLoad.0 == nil && acWithoutLoad.1 == 0 &&
                    acWithoutLoad.2?.contains("电池放电功率估算") == false,
                  "zero battery discharge on AC never becomes fake whole-system power")
        try check(counterDelta(0, 0) == 0, "known supported zero CPU-energy delta is measured zero")
        try check(instanceID(firstID) != instanceID(after.identity), "same PID with a new birth identity starts a new application instance")
        var idleVPN = before
        idleVPN.name = "lightxtremecore"
        idleVPN.residentBytes = nil
        idleVPN.userTicks = nil
        idleVPN.systemTicks = nil
        let emptySnapshot = TelemetrySnapshot(timestamp: 1, uptime: 1, bootID: "fixture",
                                               thermalLevel: 0, memoryTotalBytes: 1, interfaceNames: [],
                                               applications: [], limitations: [], collectionDurationSeconds: 0)
        var fixtureProcesses = [idleVPN.identity.pid: idleVPN]
        for index in 0..<13 {
            var worker = before
            worker.identity.pid = Int32(1000 + index)
            worker.name = "worker\(index)"
            worker.residentBytes = 200_000_000
            fixtureProcesses[worker.identity.pid] = worker
        }
        var fixture = TelemetryRaw(timestamp: 1, uptime: 1, bootID: "fixture", processes: fixtureProcesses,
                                   guiApplications: [], energySupported: false, snapshot: emptySnapshot)
        let selected = finish(&fixture, previous: nil).applications
        try check(selected.count == 13 && selected.contains { $0.name == "lightxtremecore" && $0.cpuPercent == nil },
                  "idle or unreadable priority service survives beside twelve other activity rows")
        fixture.processes = [before.identity.pid: before]
        fixture.guiApplications = [parent]
        let instance = finish(&fixture, previous: nil).applications.first?.instanceID
        try check(instance == instanceID(before.identity), "GUI telemetry exposes the main process birth identity")
        var knownBefore = before
        knownBefore.userTicks = 10
        knownBefore.systemTicks = 10
        knownBefore.residentBytes = 10
        knownBefore.energyNanojoules = 1_000_000_000
        knownBefore.network = TelemetryBytes(received: 100, sent: 200)
        var knownAfter = knownBefore
        knownAfter.userTicks = 14
        knownAfter.systemTicks = 12
        knownAfter.residentBytes = 20
        knownAfter.energyNanojoules = 2_000_000_000
        knownAfter.network = TelemetryBytes(received: 160, sent: 230)
        var unknownHelper = TelemetryProcess(identity: TelemetryIdentity(pid: 124, uid: 501, seconds: 101, microseconds: 1),
                                             parentPID: 123, name: "Helper", path: "/Apps/App.app/Contents/Helpers/Child")
        let appPrior = TelemetryRaw(timestamp: 1, uptime: 1, bootID: "fixture", secondsPerTick: 1,
                                    processes: [123: knownBefore], guiApplications: [parent],
                                    energySupported: true, snapshot: emptySnapshot)
        var appCurrent = TelemetryRaw(timestamp: 11, uptime: 11, bootID: "fixture", secondsPerTick: 1,
                                      processes: [123: knownAfter, 124: unknownHelper], guiApplications: [parent],
                                      energySupported: true, snapshot: emptySnapshot)
        let partialApp = finish(&appCurrent, previous: appPrior).applications.first
        try check(partialApp?.cpuSecondsDelta == 6 && partialApp?.receivedBytesDelta == 60 &&
                    partialApp?.sentBytesDelta == 30 && partialApp?.cpuEnergyJoulesDelta == 1 &&
                    partialApp?.residentBytes == 20 && Set(partialApp?.partialMetrics ?? []) ==
                    Set(["cpu", "received", "sent", "energy", "memory"]),
                  "known helper subset yields labeled lower bounds instead of discarding observed work")
        let baselineApp = finish(&appCurrent, previous: nil).applications.first
        try check(baselineApp?.cpuSecondsDelta == nil && baselineApp?.receivedBytesDelta == nil &&
                    baselineApp?.sentBytesDelta == nil && baselineApp?.cpuEnergyJoulesDelta == nil,
                  "first application sample has no invented counter differences")
        var unknownMain = knownAfter
        unknownMain.userTicks = nil
        unknownMain.systemTicks = nil
        unknownMain.residentBytes = nil
        unknownMain.energyNanojoules = nil
        unknownMain.network = nil
        appCurrent.processes = [123: unknownMain, 124: unknownHelper]
        let unknownApp = finish(&appCurrent, previous: appPrior).applications.first
        try check(unknownApp?.cpuSecondsDelta == nil && unknownApp?.receivedBytesDelta == nil &&
                    unknownApp?.sentBytesDelta == nil && unknownApp?.cpuEnergyJoulesDelta == nil &&
                    unknownApp?.residentBytes == nil && unknownApp?.partialMetrics == nil,
                  "entirely unreadable application is unknown rather than a false zero")
        var exitedPrior = appPrior
        unknownHelper.identity.seconds = 99
        exitedPrior.processes[124] = unknownHelper
        appCurrent.processes = [123: knownAfter]
        let exitedApp = finish(&appCurrent, previous: exitedPrior).applications.first
        try check(exitedApp?.cpuSecondsDelta == 6 && exitedApp?.receivedBytesDelta == 60 &&
                    exitedApp?.sentBytesDelta == 30 && exitedApp?.cpuEnergyJoulesDelta == 1 &&
                    Set(exitedApp?.partialMetrics ?? []) == Set(["cpu", "received", "sent", "energy"]),
                  "disappeared helper marks interval work partial but does not mark current readable memory")
        try check(sumKnownUnsigned([UInt64.max, 1, nil]).value == nil &&
                    sumKnownUnsigned([nil, nil]).value == nil && sumKnownSeconds([nil, nil]).value == nil,
                  "partial aggregate overflow and all-unknown values remain nullable")
        let measuredZero = sumKnownUnsigned([0, nil])
        try check(measuredZero.value == 0 && measuredZero.partial,
                  "known zero is distinguished from unknown and labeled as a subset")
        var kernelFixture = kinfo_proc()
        kernelFixture.kp_proc.p_pid = 833
        kernelFixture.kp_proc.p_stat = 2
        kernelFixture.kp_proc.p_un.__p_starttime = timeval(tv_sec: 100, tv_usec: 123456)
        kernelFixture.kp_eproc.e_ppid = 1
        kernelFixture.kp_eproc.e_ucred.cr_uid = 0
        let fallback = bsdFromKernel(kernelFixture, pid: 833)
        try check(fallback.map { identity(833, $0) } == TelemetryIdentity(pid: 833, uid: 0, seconds: 100, microseconds: 123456) &&
                    fallback?.pbi_ppid == 1,
                  "unprivileged sysctl metadata preserves root-service birth identity")
        kernelFixture.kp_proc.p_pid = 834
        try check(bsdFromKernel(kernelFixture, pid: 833) == nil,
                  "sysctl fallback rejects a different process instead of inventing identity")
        let largeChild = Process()
        largeChild.executableURL = URL(fileURLWithPath: "/usr/bin/head")
        largeChild.arguments = ["-c", "524288", "/dev/zero"]
        let largeOutput = readChildOutput(largeChild)
        try check(largeOutput.failure == nil && largeOutput.data?.count == 524_288 &&
                    largeOutput.data?.allSatisfy { $0 == 0 } == true && !largeChild.isRunning,
                  "owned child output beyond pipe capacity drains completely before deadline")
        let overflowChild = Process()
        overflowChild.executableURL = URL(fileURLWithPath: "/usr/bin/head")
        overflowChild.arguments = ["-c", "1048576", "/dev/zero"]
        let overflowOutput = readChildOutput(overflowChild, maximumBytes: 262_144)
        try check(overflowOutput.data == nil && overflowOutput.failure == "overflow" && !overflowChild.isRunning,
                  "bounded collector rejects oversized output and reaps only its owned child")
        let timeoutChild = Process()
        timeoutChild.executableURL = URL(fileURLWithPath: "/bin/sleep")
        timeoutChild.arguments = ["5"]
        let timeoutStarted = ProcessInfo.processInfo.systemUptime
        let timeoutOutput = readChildOutput(timeoutChild, timeout: 0.1)
        try check(timeoutOutput.data == nil && timeoutOutput.failure == "timeout" && !timeoutChild.isRunning &&
                    ProcessInfo.processInfo.systemUptime - timeoutStarted < 2,
                  "collector deadline ends and reaps its owned sleeping child")
        return count
    }
}
