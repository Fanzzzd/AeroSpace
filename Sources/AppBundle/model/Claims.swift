import AppKit
import Common

/// What the apps that make ignored displays, such as Agent Screen, say is theirs: their displays and their windows.
/// Each such process writes `claims/<pid>.json` in AeroSpace's Application Support directory, see AGENT-SCREEN.md.
/// While a live process claims, AeroSpace leaves its windows alone and takes every other window back, instead of
/// guessing whose a window is from where it is
@MainActor
final class Claims {
    static let shared = Claims()
    /// Claiming apps look for this in the binary to know that this AeroSpace reads claims
    static let protocolMarker = "aerospace-claims-v1"

    private var byPid: [pid_t: Claim] = [:]
    private var watcher: DirectoryWatcher? = nil

    private struct Claim: Decodable {
        let displays: [CGDirectDisplayID]
        let windows: [UInt32]
    }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "AeroSpace/claims", directoryHint: .isDirectory)
    }

    /// Nil while no live process claims: AeroSpace guesses then
    var windows: Set<UInt32>? {
        dropDead()
        return byPid.isEmpty ? nil : byPid.values.flatMap(\.windows).toSet()
    }

    var isActive: Bool {
        dropDead()
        return !byPid.isEmpty
    }

    var displays: Set<CGDirectDisplayID> {
        dropDead()
        return byPid.values.flatMap(\.displays).toSet()
    }

    func start() {
        if isUnitTest { return }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        ClosetLog.write("claims: \(Self.protocolMarker), reading \(Self.directory.path)")
        reload()
        watcher = DirectoryWatcher(url: Self.directory) { [weak self] in
            self?.reload()
            scheduleCancellableCompleteRefreshSession(.claimsChanged)
        }
    }

    /// Every refresh session reads the directory first, so a command that comes right after a claim changed sees the
    /// change, whether or not the watcher has fired yet
    func reload() {
        if isUnitTest { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        var byPid: [pid_t: Claim] = [:]
        for file in files where file.pathExtension == "json" {
            guard let pid = pid_t(file.deletingPathExtension().lastPathComponent) else { continue }
            if !isAlive(pid) {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            guard let data = try? Data(contentsOf: file), let claim = try? JSONDecoder().decode(Claim.self, from: data) else {
                // A writer renames a whole file into place, so this is a file it never finished: keep what it said last
                if let last = self.byPid[pid] { byPid[pid] = last }
                continue
            }
            byPid[pid] = claim
        }
        if byPid.keys.toSet() != self.byPid.keys.toSet() {
            ClosetLog.write("claims: from processes \(byPid.keys.sorted()) now")
        }
        self.byPid = byPid
    }

    /// A process that crashed leaves its file behind, and the directory doesn't change
    private func dropDead() {
        for pid in byPid.keys where !isAlive(pid) {
            byPid[pid] = nil
            try? FileManager.default.removeItem(at: Self.directory.appending(path: "\(pid).json"))
            ClosetLog.write("claims: process \(pid) is gone")
        }
    }
}

private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

private struct DirectoryWatcher: ~Copyable {
    private let source: DispatchSourceFileSystemObject

    init?(url: URL, onChange: @escaping @MainActor () -> Void) {
        let fd = unsafe open(url.path, O_EVTONLY)
        if fd < 0 { return nil }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: .main)
        source.setEventHandler { MainActor.checkIsolated { onChange() } }
        source.setCancelHandler { close(fd) }
        source.activate()
    }

    deinit {
        source.cancel()
    }
}
