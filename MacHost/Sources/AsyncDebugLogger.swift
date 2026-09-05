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
    private let url = URL(fileURLWithPath: "/tmp/sidescreen.log")
    private let maxPendingEntries = 1_024

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

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        handle.seekToEndOfFile()
        fileHandle = handle
        return handle
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}
