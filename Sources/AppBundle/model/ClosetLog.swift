import Foundation
import os

/// What the closet does, with timings, in `~/Library/Logs/AeroSpace/closet.log` and the unified log (subsystem
/// `bobko.aerospace`, category `closet`). The file outlives a restart, which the unified log's debug messages don't, so
/// a freeze can be traced afterwards.
///
/// A watchdog also notes when the main thread doesn't answer for 250 ms or more, with the load average and what the
/// closet was doing then.
enum ClosetLog {
    private static let logger = Logger(subsystem: "bobko.aerospace", category: "closet")
    private static let queue = DispatchQueue(label: "bobko.aerospace.closet-log")
    private static let maxBytes = 5_000_000
    private static let url: URL? = {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let folder = library.appendingPathComponent("Logs/AeroSpace", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("closet.log")
    }()
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// What the main thread is busy with, for the watchdog
    private static let doing = OSAllocatedUnfairLock<String>(initialState: "idle")
    private static let watchdog = OSAllocatedUnfairLock<DispatchSourceTimer?>(initialState: nil)

    static func write(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        let line = "\(time.string(from: Date())) \(message)\n"
        queue.async {
            guard let url, let data = line.data(using: .utf8) else { return }
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > maxBytes {
                let old = url.deletingPathExtension().appendingPathExtension("1.log")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: url, to: old)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Run `body`, noting it for the watchdog, and log it when it takes 50 ms or more
    @MainActor
    static func timed<T>(_ what: String, _ body: () -> T) -> T {
        doing.withLock { $0 = what }
        let started = DispatchTime.now()
        let result = body()
        let ms = milliseconds(since: started)
        doing.withLock { $0 = "idle" }
        if ms >= 50 { write("slow: \(what) took \(ms) ms") }
        return result
    }

    static func milliseconds(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }

    static var loadAverage: String {
        var load = [Double](repeating: 0, count: 3)
        guard unsafe getloadavg(&load, 3) == 3 else { return "?" }
        return load.map { (($0 * 10).rounded() / 10).description }.joined(separator: " ")
    }

    static func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        let waiting = OSAllocatedUnfairLock<DispatchTime?>(initialState: nil)
        timer.schedule(deadline: .now() + 1, repeating: 0.5)
        timer.setEventHandler {
            if let since = waiting.withLock({ $0 }) {
                // The previous ping hasn't come back: the main thread is stuck
                let ms = milliseconds(since: since)
                if ms >= 250 {
                    write("main thread blocked for \(ms) ms so far, doing: \(doing.withLock { $0 }), load \(loadAverage)")
                }
                return
            }
            let sent = DispatchTime.now()
            waiting.withLock { $0 = sent }
            DispatchQueue.main.async {
                let ms = milliseconds(since: sent)
                waiting.withLock { $0 = nil }
                if ms >= 250 { write("main thread answered after \(ms) ms, load \(loadAverage)") }
            }
        }
        timer.resume()
        watchdog.withLock { $0 = timer }
    }
}
