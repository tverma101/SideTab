import Foundation

/// Non-blocking diagnostic logger for the Mac host.
///
/// Callers only enqueue a small entry under a lock. Timestamp formatting,
/// console output, file open/seek, batching, and disk I/O all happen on a
/// utility queue. The pending queue is bounded so diagnostics can never become
/// an unbounded memory/backpressure source during a reconnect/error storm.
final class AsyncDebugLogger {
    static let shared = AsyncDebugLogger()

    private struct Entry {
        let date: Date
        let message: String
    }

    private let lock = NSLock()
    private let writerQueue = DispatchQueue(label: "com.sidescreen.debuglog", qos: .utility)
    private let directoryURL = AsyncDebugLogger.logDirectory(isTestProcess: AsyncDebugLogger.isTestProcess)
    var logURL: URL { directoryURL.appendingPathComponent("sidescreen.log") }

    /// The live host logs to `~/Library/Logs/SideScreen`. A test process logs to
    /// a scratch directory instead: `swift test` runs as the same user, and its
    /// lines used to interleave with a real session's in the one file that is
    /// read as evidence when diagnosing a tablet.
    static func logDirectory(isTestProcess: Bool) -> URL {
        if isTestProcess {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("SideScreenTests/Logs", isDirectory: true)
        }
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
        return library.appendingPathComponent("Logs/SideScreen", isDirectory: true)
    }

    /// XCTest is loaded into the test runner before any test bundle, and never
    /// into the app.
    static let isTestProcess: Bool = NSClassFromString("XCTestCase") != nil
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    private let maxPendingEntries = 1_024
    private static let maxLogBytes = 4 * 1024 * 1024
    private static let archivedGenerations = 2

    private var pending: [Entry] = []
    private var drainScheduled = false
    private var droppedEntries = 0
    private var fileHandle: FileHandle?

    private init() {}

    func log(_ message: String) {
        lock.lock()
        if pending.count < maxPendingEntries {
            pending.append(Entry(date: Date(), message: message))
        } else {
            droppedEntries += 1
        }
        let shouldSchedule = !drainScheduled
        if shouldSchedule {
            drainScheduled = true
        }
        lock.unlock()

        guard shouldSchedule else { return }
        writerQueue.async { [weak self] in
            self?.drain()
        }
    }

    private func drain() {
        while true {
            let batch: [Entry]
            let dropped: Int

            lock.lock()
            if pending.isEmpty {
                drainScheduled = false
                lock.unlock()
                return
            }
            batch = pending
            pending.removeAll(keepingCapacity: true)
            dropped = droppedEntries
            droppedEntries = 0
            lock.unlock()

            var output = ""
            output.reserveCapacity(batch.count * 96)
            for entry in batch {
                let line = "[\(Self.timestampFormatter.string(from: entry.date))] \(entry.message)\n"
                output.append(line)
                print(entry.message)
            }
            if dropped > 0 {
                output.append("[\(Self.timestampFormatter.string(from: Date()))] debugLog dropped \(dropped) entries (queue full)\n")
            }

            guard let data = output.data(using: .utf8) else { continue }
            let handle = ensureFileHandle()
            handle?.write(data)
        }
    }

    private func ensureFileHandle() -> FileHandle? {
        if let fileHandle { return fileHandle }

        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if let size = currentLogSize(), size >= Self.maxLogBytes {
            rotate()
        }
        // O_NOFOLLOW without O_EXCL: an existing log is reopened and appended
        // to, but a symlink planted at the path is refused instead of
        // redirecting every diagnostic line (and every byte the app can write)
        // to a file the user chose. Mode 0600 keeps the log to its owner.
        let descriptor = logURL.path.withCString { path in
            open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else { return nil }
        // O_APPEND already positions every write at the end.
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        fileHandle = handle
        return handle
    }

    private func currentLogSize() -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path) else { return nil }
        return (attrs[.size] as? NSNumber)?.intValue
    }

    /// Keep `sidescreen.log` plus `archivedGenerations` rotated archives, so a
    /// login session's diagnostics can never grow without bound.
    private func rotate() {
        let fileManager = FileManager.default
        let oldest = logURL.appendingPathExtension("\(Self.archivedGenerations)")
        try? fileManager.removeItem(at: oldest)
        for generation in stride(from: Self.archivedGenerations - 1, through: 1, by: -1) {
            let source = logURL.appendingPathExtension("\(generation)")
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try? fileManager.moveItem(
                at: source,
                to: logURL.appendingPathExtension("\(generation + 1)")
            )
        }
        try? fileManager.moveItem(at: logURL, to: logURL.appendingPathExtension("1"))
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}
