import Foundation
import os

/// What the closet does, in `~/Library/Logs/AeroSpace/closet.log` and the unified log (subsystem `bobko.aerospace`,
/// category `closet`). The file outlives a restart, so display trouble can be traced afterwards.
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
}
