import Foundation
import Darwin

// A single utility queue owns all file work; callers never wait for disk IO.
final class DiagnosticWriter: @unchecked Sendable {
    private struct LogFile {
        var url: URL
        var day: Date
        var size: UInt64
    }

    private let directory: URL
    private let queue = DispatchQueue(label: "local.lidrun.diagnostics", qos: .utility)
    private let byteLimit: UInt64
    private let errorLock = NSLock()
    private var errorMessage: String?
    // Accessed only on queue. Scanning is daily; capacity enforcement uses this cache.
    private var scannedDay: String?
    private var files: [LogFile] = []
    private var totalBytes: UInt64 = 0

    convenience init(directory: URL) {
        self.init(directory: directory, byteLimit: 16 * 1024 * 1024)
    }

    private init(directory: URL, byteLimit: UInt64) {
        self.directory = directory
        self.byteLimit = byteLimit
    }

    var lastError: String? {
        errorLock.lock()
        defer { errorLock.unlock() }
        return errorMessage
    }

    // Data is one diagnostic record. Existing final newlines are not duplicated.
    func enqueue(data: Data, date: Date) {
        guard !data.isEmpty else { return }
        queue.async { [self] in
            do {
                var record = data
                if record.last != 10 { record.append(10) }
                guard UInt64(record.count) <= byteLimit else { throw failure("诊断记录超过容量限制。") }
                guard date.timeIntervalSince1970.isFinite else { throw failure("诊断日期无效。") }
                try ensureDirectory()
                let format = Self.dayFormatter()
                let dayName = format.string(from: date)
                guard let day = format.date(from: dayName) else { throw failure("诊断日期无效。") }
                let url = directory.appendingPathComponent("heartbeat-" + dayName + ".jsonl")
                // Validate the destination before eviction, preserving all other
                // records if this destination was replaced with an unsafe object.
                try validateDestination(url)
                if scannedDay != dayName {
                    try scanAndPrune(day: day, format: format)
                    scannedDay = dayName
                }
                try makeRoom(for: UInt64(record.count))
                try append(record, to: url)
                try updateSize(of: url, day: day)
                // Includes externally enlarged managed files noticed by append.
                try makeRoom(for: 0)
                setError(nil)
            } catch { setError("诊断日志未能保存：" + error.localizedDescription) }
        }
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    private func setError(_ value: String?) {
        errorLock.lock()
        errorMessage = value
        errorLock.unlock()
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "LidRun.Diagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard let info = Self.metadata(directory), Self.isOwned(info),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw failure("诊断目录不是当前用户拥有的普通目录。")
        }
        guard directory.path.withCString({ chmod($0, 0o700) }) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private static func metadata(_ url: URL) -> stat? {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else { return nil }
        return info
    }

    private static func isOwned(_ info: stat) -> Bool { info.st_uid == getuid() }

    private static func isOwnedFile(_ info: stat) -> Bool {
        isOwned(info) && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && info.st_nlink == 1
    }

    private func validateDestination(_ url: URL) throws {
        var info = stat()
        let result = url.path.withCString { lstat($0, &info) }
        if result == 0 {
            guard Self.isOwnedFile(info) else { throw failure("诊断文件不是当前用户拥有的独立普通文件。") }
        } else if errno != ENOENT { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    private func append(_ data: Data, to url: URL) throws {
        let descriptor = url.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        }
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, Self.isOwnedFile(info) else {
            throw failure("诊断文件在追加前发生变化。")
        }
        guard fchmod(descriptor, 0o600) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(written == 0 ? EIO : errno)) }
                offset += written
            }
        }
    }

    private static func dayFormatter() -> DateFormatter {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = Calendar(identifier: .gregorian)
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "yyyy-MM-dd"
        format.isLenient = false
        return format
    }

    private static func fileDay(_ name: String, format: DateFormatter) -> Date? {
        guard name.count == 26, name.hasPrefix("heartbeat-"), name.hasSuffix(".jsonl") else { return nil }
        let text = String(name.dropFirst(10).dropLast(6))
        guard text.count == 10, let date = format.date(from: text), format.string(from: date) == text else { return nil }
        return date
    }

    private func scanAndPrune(day: Date, format: DateFormatter) throws {
        // Today plus the preceding 29 complete UTC days.
        let cutoff = day.addingTimeInterval(-29 * 86_400)
        var retained: [LogFile] = []
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles]) {
            guard let fileDay = Self.fileDay(url.lastPathComponent, format: format),
                  let info = Self.metadata(url), Self.isOwnedFile(info), info.st_size >= 0 else { continue }
            if fileDay < cutoff { try removeOwnedFile(url) }
            else { retained.append(LogFile(url: url, day: fileDay, size: UInt64(info.st_size))) }
        }
        files = retained.sorted { $0.day < $1.day }
        recalculateTotal()
    }

    private func removeOwnedFile(_ url: URL) throws {
        guard let info = Self.metadata(url) else {
            if errno == ENOENT { return }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard Self.isOwnedFile(info) else { throw failure("诊断文件已变为非独立普通文件，未删除。") }
        guard url.path.withCString({ unlink($0) }) == 0 else {
            if errno == ENOENT { return }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func makeRoom(for additional: UInt64) throws {
        while totalBytes > byteLimit || additional > byteLimit - totalBytes {
            guard let oldest = files.first else { throw failure("诊断记录超过容量限制。") }
            try removeOwnedFile(oldest.url)
            files.removeFirst()
            recalculateTotal()
        }
    }

    private func updateSize(of url: URL, day: Date) throws {
        guard let info = Self.metadata(url), Self.isOwnedFile(info), info.st_size >= 0 else {
            throw failure("未能确认诊断文件大小。")
        }
        let value = LogFile(url: url, day: day, size: UInt64(info.st_size))
        if let index = files.firstIndex(where: { $0.url == url }) { files[index] = value }
        else { files.append(value); files.sort { $0.day < $1.day } }
        recalculateTotal()
    }

    private func recalculateTotal() {
        totalBytes = files.reduce(0) { current, file in
            let sum = current.addingReportingOverflow(file.size)
            return sum.overflow ? UInt64.max : sum.partialValue
        }
    }

    static func selfTest() throws -> Int {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw NSError(domain: "LidRun.Diagnostics.Tests", code: 1,
                                               userInfo: [NSLocalizedDescriptionKey: message]) }
            count += 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LidRun-diagnostics-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = dayFormatter()
        guard let today = format.date(from: "2030-01-31") else { throw NSError(domain: "LidRun.Diagnostics.Tests", code: 2) }
        func date(_ offset: Int = 0) -> Date { today.addingTimeInterval(Double(offset) * 86_400) }
        func log(_ folder: URL, _ offset: Int = 0) -> URL {
            folder.appendingPathComponent("heartbeat-" + format.string(from: date(offset)) + ".jsonl")
        }
        func drain(_ writer: DiagnosticWriter) { writer.queue.sync {} }
        func fixture(_ url: URL, _ bytes: Int = 1) throws { try Data(repeating: 120, count: bytes).write(to: url) }

        let folder = root.appendingPathComponent("ordered")
        let ordered = DiagnosticWriter(directory: folder)
        try check(!FileManager.default.fileExists(atPath: folder.path), "initialization does not perform disk IO")
        ordered.enqueue(data: Data("{\"sequence\":1}".utf8), date: today)
        ordered.enqueue(data: Data("{\"sequence\":2}\n".utf8), date: today)
        let flushed = DispatchSemaphore(value: 0)
        Task.detached { await ordered.flush(); flushed.signal() }
        let flushCompleted = flushed.wait(timeout: .now() + 5) == .success
        drain(ordered)
        try check(flushCompleted, "async flush waits for previously queued records without requiring the main thread")
        let orderedText = try String(contentsOf: log(folder), encoding: .utf8)
        try check(orderedText == "{\"sequence\":1}\n{\"sequence\":2}\n", "actual queued appends preserve record order and one newline")
        try check(metadata(folder).map { $0.st_mode & 0o777 == 0o700 } == true &&
                  metadata(log(folder)).map { $0.st_mode & 0o777 == 0o600 } == true,
                  "created directory and file are private to the local user")
        try check(ordered.lastError == nil && ordered.byteLimit == 16 * 1024 * 1024,
                  "default public writer enforces the production capacity without an error")
        for index in 3...66 { ordered.enqueue(data: Data("\(index)".utf8), date: today) }
        drain(ordered)
        let records = try String(contentsOf: log(folder), encoding: .utf8).split(separator: "\n").map(String.init)
        try check(Array(records.dropFirst(2)) == (3...66).map(String.init), "many asynchronous appends retain FIFO order")

        let retentionFolder = root.appendingPathComponent("retention")
        try FileManager.default.createDirectory(at: retentionFolder, withIntermediateDirectories: true)
        try fixture(log(retentionFolder, -30))
        try fixture(log(retentionFolder, -29))
        let unrelated = retentionFolder.appendingPathComponent("other.jsonl")
        try fixture(unrelated)
        let invalid = retentionFolder.appendingPathComponent("heartbeat-2029-02-30.jsonl")
        try fixture(invalid)
        let target = root.appendingPathComponent("preserve.txt")
        try fixture(target)
        let symbolic = log(retentionFolder, -40)
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: target)
        let hardLink = log(retentionFolder, -41)
        try FileManager.default.linkItem(at: target, to: hardLink)
        let retained = DiagnosticWriter(directory: retentionFolder)
        retained.enqueue(data: Data("today".utf8), date: today)
        drain(retained)
        try check(!FileManager.default.fileExists(atPath: log(retentionFolder, -30).path) &&
                  FileManager.default.fileExists(atPath: log(retentionFolder, -29).path),
                  "actual retention keeps today plus 29 prior days and removes older owned logs")
        let targetData = try Data(contentsOf: target)
        try check(FileManager.default.fileExists(atPath: unrelated.path) && FileManager.default.fileExists(atPath: invalid.path) &&
                  metadata(symbolic).map { $0.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) } == true &&
                  FileManager.default.fileExists(atPath: hardLink.path) && targetData == Data([120]),
                  "unrelated, invalid-date, symbolic-link and hard-link files are untouched")
        try fixture(log(retentionFolder, -35))
        retained.enqueue(data: Data("same day".utf8), date: today)
        drain(retained)
        try check(FileManager.default.fileExists(atPath: log(retentionFolder, -35).path),
                  "same-day append does not rescan or repeat age-based pruning")
        retained.enqueue(data: Data("next day".utf8), date: date(1))
        drain(retained)
        try check(!FileManager.default.fileExists(atPath: log(retentionFolder, -35).path) &&
                  !FileManager.default.fileExists(atPath: log(retentionFolder, -29).path),
                  "next UTC day performs the next retention scan")

        let capFolder = root.appendingPathComponent("capacity")
        try FileManager.default.createDirectory(at: capFolder, withIntermediateDirectories: true)
        try fixture(log(capFolder, -2), 80)
        try fixture(log(capFolder, -1), 80)
        let capped = DiagnosticWriter(directory: capFolder, byteLimit: 128)
        capped.enqueue(data: Data("today".utf8), date: today)
        drain(capped)
        try check(!FileManager.default.fileExists(atPath: log(capFolder, -2).path) &&
                  FileManager.default.fileExists(atPath: log(capFolder, -1).path),
                  "capacity evicts oldest dated managed file first")
        capped.enqueue(data: Data(repeating: 121, count: 60), date: today)
        drain(capped)
        let currentSize = metadata(log(capFolder))?.st_size ?? -1
        try check(!FileManager.default.fileExists(atPath: log(capFolder, -1).path) && currentSize == 67 &&
                  capped.lastError == nil, "same-day cached capacity enforcement keeps real disk bytes bounded")
        capped.enqueue(data: Data(repeating: 122, count: 129), date: today)
        drain(capped)
        try check(metadata(log(capFolder))?.st_size == currentSize && capped.lastError != nil,
                  "oversized incoming record leaves existing data intact without crashing")

        let unsafeFolder = root.appendingPathComponent("unsafe")
        try FileManager.default.createDirectory(at: unsafeFolder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: log(unsafeFolder), withDestinationURL: target)
        let unsafe = DiagnosticWriter(directory: unsafeFolder)
        unsafe.enqueue(data: Data("must not append".utf8), date: today)
        drain(unsafe)
        let preserved = try Data(contentsOf: target)
        try check(preserved == targetData && unsafe.lastError != nil,
                  "unsafe append destination is rejected and linked content is preserved")
        return count
    }
}
