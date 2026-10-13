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

/// Counts what AeroSpace spends its time on, written to the closet log once a minute: refresh sessions by event, and
/// window frame changes by app, with how long the app took to answer
enum PerfStats {
    private struct Tally {
        var count = 0
        var totalMs = 0
        var maxMs = 0
        mutating func add(_ ms: Int) {
            count += 1
            totalMs += ms
            maxMs = max(maxMs, ms)
        }
        var text: String { "\(count)x \(totalMs) ms (max \(maxMs))" }
    }

    private static let state = OSAllocatedUnfairLock<(refresh: [String: Tally], frames: [String: Tally], skipped: Int, eui: Int)>(
        initialState: ([:], [:], 0, 0),
    )
    private static let reporter = OSAllocatedUnfairLock<DispatchSourceTimer?>(initialState: nil)

    static func refresh(_ event: String, ms: Int) {
        state.withLock { $0.refresh[event, default: Tally()].add(ms) }
        if ms >= 100 { ClosetLog.write("perf: refresh \(event) took \(ms) ms") }
    }

    static func frame(_ app: String, ms: Int) {
        state.withLock { $0.frames[app, default: Tally()].add(ms) }
        if ms >= 100 { ClosetLog.write("perf: \(app) took \(ms) ms to move a window") }
    }

    /// An app had AXEnhancedUserInterface on, so moving its window switched it off and on again
    static func enhancedUserInterfaceToggled() {
        state.withLock { $0.eui += 1 }
    }

    static func skippedFrame() {
        state.withLock { $0.skipped += 1 }
    }

    static func start() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler {
            let (refresh, frames, skipped, eui) = state.withLock { s in
                defer { s = ([:], [:], 0, 0) }
                return s
            }
            if refresh.isEmpty && frames.isEmpty { return }
            let r = refresh.sorted { $0.value.totalMs > $1.value.totalMs }.map { "\($0.key) \($0.value.text)" }
            let f = frames.sorted { $0.value.totalMs > $1.value.totalMs }.map { "\($0.key) \($0.value.text)" }
            ClosetLog.write("perf minute: refresh [\(r.joined(separator: ", "))]; frames [\(f.joined(separator: ", "))]; frames skipped \(skipped); enhanced UI toggled \(eui)")
        }
        timer.resume()
        reporter.withLock { $0 = timer }
    }
}
