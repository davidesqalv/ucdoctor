import AppKit

let home = FileManager.default.homeDirectoryForCurrentUser
let logDir = home.appendingPathComponent("Library/Logs/UC Doctor")
let eventLogURL = logDir.appendingPathComponent("events.log")

/// Run a command and return its exit status and stdout.
@discardableResult
func sh(_ path: String, _ args: [String] = []) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

func onMain<T>(_ work: () -> T) -> T {
    Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
}

/// Poll `cond` until it's true or `timeout` passes.
func waitFor(_ timeout: TimeInterval, every: TimeInterval = 0.5, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if cond() { return true }
        Thread.sleep(forTimeInterval: every)
    }
    return cond()
}

private func formatter(_ format: String, posix: Bool = false) -> DateFormatter {
    let f = DateFormatter()
    if posix { f.locale = Locale(identifier: "en_US_POSIX") }
    f.dateFormat = format
    return f
}

let clockFmt = formatter("h:mm a")
let clockSecFmt = formatter("h:mm:ss a")
let fileStampFmt = formatter("yyyy-MM-dd HH:mm:ss", posix: true)
let logStampFmt = formatter("yyyy-MM-dd HH:mm:ss.SSSSSSZ", posix: true) // `log --style ndjson` timestamps

/// "just now", "42s ago", "7 min ago", "2h 5m ago", or a clock time.
func ago(_ date: Date?, orNoneSince since: Date? = nil) -> String {
    guard let date else { return since.map { "none since \(clockFmt.string(from: $0))" } ?? "never" }
    let s = Int(Date().timeIntervalSince(date))
    if s < 10 { return "just now" }
    if s < 60 { return "\(s)s ago" }
    if s < 3600 { return "\(s / 60) min ago" }
    if s < 12 * 3600 { return "\(s / 3600)h \((s % 3600) / 60)m ago" }
    return formatter("MMM d, h:mm a").string(from: date)
}

func duration(_ seconds: TimeInterval) -> String {
    let s = Int(seconds)
    if s >= 86400 { return "\(s / 86400)d \((s % 86400) / 3600)h" }
    if s >= 3600 { return "\(s / 3600)h \((s % 3600) / 60)m" }
    if s >= 60 { return "\(s / 60)m" }
    return "\(s)s"
}

/// Human-readable event history in ~/Library/Logs/UC Doctor/events.log (rotates at 5 MB).
final class EventLog {
    static let shared = EventLog()
    private let queue = DispatchQueue(label: "ucdoctor.eventlog")

    func append(_ text: String) {
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: eventLogURL.path))?[.size] as? Int, size > 5_000_000 {
                let old = logDir.appendingPathComponent("events.1.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: eventLogURL, to: old)
            }
            if !fm.fileExists(atPath: eventLogURL.path) { fm.createFile(atPath: eventLogURL.path, contents: nil) }
            guard let h = try? FileHandle(forWritingTo: eventLogURL) else { return }
            h.seekToEndOfFile()
            h.write(Data((text + "\n").utf8))
            try? h.close()
        }
    }
}
