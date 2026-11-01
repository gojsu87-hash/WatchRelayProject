import Foundation

struct WatchFailureLogRecord: Codable, Identifiable {
    let id: String
    let timestamp: Int64
    let source: String
    let message: String

    init(source: String, message: String) {
        self.id = UUID().uuidString
        self.timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        self.source = source
        self.message = message
    }
}

enum WatchFailureLogStore {
    private static let fileName = "watch-failure-log-queue.json"
    private static let retentionMs: Int64 = 24 * 60 * 60 * 1000
    private static let maxRecordCount = 1000
    private static let lock = NSLock()

    private static var fileURL: URL {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent(fileName)
    }

    static func append(source: String, message: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var records = try readRecords()
        records.removeAll { Date().timeIntervalSince1970 * 1000 - Double($0.timestamp) > Double(retentionMs) }
        records.append(WatchFailureLogRecord(source: source, message: message))
        if records.count > maxRecordCount {
            records.removeFirst(records.count - maxRecordCount)
        }
        try JSONEncoder().encode(records).write(to: fileURL, options: .atomic)
    }

    static func pendingRecords() throws -> [WatchFailureLogRecord] {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - retentionMs
        return try readRecords().filter { $0.timestamp >= cutoff }
    }

    static func remove(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let records = try readRecords().filter { $0.id != id }
        try JSONEncoder().encode(records).write(to: fileURL, options: .atomic)
    }

    private static func readRecords() throws -> [WatchFailureLogRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([WatchFailureLogRecord].self, from: Data(contentsOf: fileURL))
    }
}
