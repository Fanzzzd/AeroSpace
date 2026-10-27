import AppKit
import Common
import MachO

/// Windows on desktops (macOS Spaces) that their monitor doesn't show.
///
/// AeroSpace works with one desktop per monitor: macOS leaves windows of the other desktops out of the accessibility
/// API, so AeroSpace can't see or move them. A monitor gets a second desktop when the user adds one, or when macOS moves
/// the desktop of a display that went away onto it, with the windows that were there.
///
/// Each refresh asks WindowServer for the desktops, which takes about 0.1 ms, and only when a monitor has more than one,
/// for the windows on the hidden ones, which takes about 0.05 ms more. A window found there is moved to the desktop its
/// monitor shows, where macOS lets an app do that, and otherwise reported, once.
@MainActor
final class OtherDesktops {
    static let shared = OtherDesktops()

    /// Windows asked to move, so that each is asked once
    private var moveAsked: Set<UInt32> = []
    /// Windows the user was told about, so that a message comes only for new ones
    private var reported: Set<UInt32> = []

    func check() {
        guard let sky = SkyLight.shared else { return }
        let monitorUuids = Set(monitorDisplayIds.compactMap(Self.uuid))
        var hidden: [UInt64: UInt64] = [:] // Hidden desktop -> the desktop its monitor shows
        var shown: [UInt64] = []
        for display in sky.displaySpaces() where monitorUuids.contains(display.uuid) {
            shown.append(display.current)
            for space in display.userSpaces where space != display.current {
                hidden[space] = display.current
            }
        }
        if hidden.isEmpty {
            moveAsked = []
            reported = []
            return
        }
        // Windows shown on all desktops are on the shown ones too
        let onShown = Set(sky.windows(onSpaces: shown))
        let candidates = sky.windows(onSpaces: Array(hidden.keys)).filter { !onShown.contains($0) }
        let pids = Set(MacApp.allAppsMap.values.filter { $0.nsApp.activationPolicy == .regular }.map(\.pid))
        let windows = Self.describe(candidates).filter { pids.contains($0.pid) }
        let ids = Set(windows.map(\.id))
        moveAsked.formIntersection(ids)
        reported.formIntersection(ids)
        if windows.isEmpty { return }

        var askedNow: Set<UInt32> = []
        if sky.canMoveWindowsBetweenSpaces {
            for window in windows where !moveAsked.contains(window.id) {
                guard let space = sky.spaces(of: window.id).first(where: { hidden[$0] != nil }), let target = hidden[space] else { continue }
                ClosetLog.write("desktops: moving window \(window.id) of \(window.appName) from desktop \(space) to \(target)")
                sky.move(window.id, toSpace: target)
                askedNow.insert(window.id)
            }
            moveAsked.formUnion(askedNow)
        }
        // A moved window is on the shown desktop by a later refresh. One that is still here then couldn't move
        let stuck = windows.filter { !askedNow.contains($0.id) && !reported.contains($0.id) }
        if stuck.isEmpty { return }
        reported.formUnion(stuck.map(\.id))
        let apps = Dictionary(grouping: windows, by: \.appName).map { "\($0.key) (\($0.value.count))" }.sorted()
        ClosetLog.write("desktops: windows on hidden desktops: \(apps.joined(separator: ", "))")
        MessageModel.shared.message = Message(
            description: "Windows on another desktop",
            body: """
                These windows are on a desktop that a monitor doesn't show, where AeroSpace can't see them: \
                \(apps.joined(separator: ", ")).

                Open Mission Control, drag them onto the desktop the monitor shows, and remove the other desktop. \
                AeroSpace works with one desktop per monitor.
                """,
            containsWarnings: true,
        )
    }

    private struct Found {
        let id: UInt32
        let pid: pid_t
        let appName: String
    }

    /// Normal windows among `ids`, without the small ones apps keep around, such as Chromium's 30 point high bars
    private static func describe(_ ids: [UInt32]) -> [Found] {
        if ids.isEmpty { return [] }
        let array = CFArrayCreateMutable(nil, ids.count, nil)
        for id in ids { unsafe CFArrayAppendValue(array, UnsafeRawPointer(bitPattern: UInt(id))) }
        guard let info = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] else { return [] }
        return info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let id = w[kCGWindowNumber as String] as? Int,
                  let pid = w[kCGWindowOwnerPID as String] as? Int,
                  let bounds = (w[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  bounds.width >= 100 && bounds.height >= 100
            else { return nil }
            return Found(id: UInt32(id), pid: pid_t(pid), appName: w[kCGWindowOwnerName as String] as? String ?? "?")
        }
    }

    private static func uuid(_ display: CGDirectDisplayID) -> String? {
        guard let uuid = unsafe CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}

/// The private WindowServer calls that know about desktops. They take window and desktop ids, no accessibility
/// elements, and work with System Integrity Protection on
@safe private struct SkyLight {
    static let shared: SkyLight? = SkyLight()

    private typealias ConnectionId = @convention(c) () -> Int32
    private typealias CopyDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopyWindows = @convention(c) (Int32, Int32, CFArray, UInt32, UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>) -> Unmanaged<CFArray>?
    private typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias Perform = @convention(c) (AnyObject) -> Void
    private typealias InitOperation = @convention(c) (AnyObject, Selector, CFArray, UInt64) -> Unmanaged<AnyObject>?

    private let connection: Int32
    private let copyDisplaySpaces: CopyDisplaySpaces
    private let copyWindows: CopyWindows
    private let copySpaces: CopySpaces
    /// How yabai moves windows between desktops: macOS 14.5 made `SLSMoveWindowsToManagedSpace` do nothing for windows
    /// of other apps. Reported to work on macOS 26.4. Nil where SkyLight doesn't have it
    private let perform: Perform?

    private init?() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
        guard let handle = unsafe dlopen(path, RTLD_LAZY),
              let connectionId = unsafe dlsym(handle, "SLSMainConnectionID"),
              let copyDisplaySpaces = unsafe dlsym(handle, "SLSCopyManagedDisplaySpaces"),
              let copyWindows = unsafe dlsym(handle, "SLSCopyWindowsWithOptionsAndTags"),
              let copySpaces = unsafe dlsym(handle, "SLSCopySpacesForWindows")
        else { return nil }
        connection = unsafe unsafeBitCast(connectionId, to: ConnectionId.self)()
        unsafe self.copyDisplaySpaces = unsafeBitCast(copyDisplaySpaces, to: CopyDisplaySpaces.self)
        unsafe self.copyWindows = unsafeBitCast(copyWindows, to: CopyWindows.self)
        unsafe self.copySpaces = unsafeBitCast(copySpaces, to: CopySpaces.self)
        let symbol = "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation"
        perform = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation") == nil ? nil
            : unsafe findLocalSymbol(image: path, symbol).map { unsafe unsafeBitCast($0, to: Perform.self) }
    }

    var canMoveWindowsBetweenSpaces: Bool { perform != nil }

    struct DisplaySpaces {
        let uuid: String
        let current: UInt64
        /// Desktops the user can switch to, without fullscreen ones
        let userSpaces: [UInt64]
    }

    func displaySpaces() -> [DisplaySpaces] {
        guard let displays = unsafe copyDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return displays.compactMap { display in
            guard let uuid = display["Display Identifier"] as? String,
                  let current = ((display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.uint64Value
            else { return nil }
            let spaces = (display["Spaces"] as? [[String: Any]]) ?? []
            let user = spaces.filter { ($0["type"] as? Int) == 0 }.compactMap { ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value }
            return DisplaySpaces(uuid: uuid, current: current, userSpaces: user)
        }
    }

    func windows(onSpaces spaces: [UInt64]) -> [UInt32] {
        if spaces.isEmpty { return [] }
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        let ids = spaces.map { NSNumber(value: $0) } as CFArray
        let windows = unsafe copyWindows(connection, 0, ids, 0x2, &setTags, &clearTags)?.takeRetainedValue() as? [NSNumber]
        return windows?.map(\.uint32Value) ?? []
    }

    func spaces(of window: UInt32) -> [UInt64] {
        let spaces = unsafe copySpaces(connection, 0x7, [NSNumber(value: window)] as CFArray)?.takeRetainedValue() as? [NSNumber]
        return spaces?.map(\.uint64Value) ?? []
    }

    /// Asynchronous: the window is on the desktop by a later refresh, if macOS lets it move
    func move(_ window: UInt32, toSpace space: UInt64) {
        guard let perform, let operationClass = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation") as? NSObject.Type else { return }
        let initSelector = NSSelectorFromString("initWithWindows:spaceID:")
        guard let allocated = unsafe operationClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject,
              let operation = unsafe unsafeBitCast(allocated.method(for: initSelector), to: InitOperation.self)(
                  allocated, initSelector, [NSNumber(value: window)] as CFArray, space,
              )?.takeRetainedValue()
        else { return }
        perform(operation)
    }
}

/// The address of a symbol that the image doesn't export, from its symbol table, the way yabai finds it
private func findLocalSymbol(image: String, _ symbol: String) -> UnsafeMutableRawPointer? {
    for i in 0 ..< _dyld_image_count() {
        guard let name = unsafe _dyld_get_image_name(i), unsafe String(cString: name) == image,
              let header = unsafe _dyld_get_image_header(i)
        else { continue }
        let slide = _dyld_get_image_vmaddr_slide(i)
        var linkedit: segment_command_64? = nil
        var symtab: symtab_command? = nil
        var command = unsafe UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        let commandCount = unsafe header.pointee.ncmds
        for _ in 0 ..< commandCount {
            let load = unsafe command.load(as: load_command.self)
            if load.cmd == LC_SEGMENT_64 {
                let segment = unsafe command.load(as: segment_command_64.self)
                let segname = unsafe withUnsafeBytes(of: segment.segname) { unsafe String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                if segname == SEG_LINKEDIT { linkedit = segment }
            } else if load.cmd == LC_SYMTAB {
                symtab = unsafe command.load(as: symtab_command.self)
            }
            unsafe command = command.advanced(by: Int(load.cmdsize))
        }
        guard let linkedit, let symtab else { return nil }
        let base = Int(linkedit.vmaddr) - Int(linkedit.fileoff) + slide
        guard let strings = unsafe UnsafeRawPointer(bitPattern: base + Int(symtab.stroff)),
              let symbols = unsafe UnsafeRawPointer(bitPattern: base + Int(symtab.symoff))
        else { return nil }
        for k in 0 ..< Int(symtab.nsyms) {
            let entry = unsafe symbols.advanced(by: k * MemoryLayout<nlist_64>.size).load(as: nlist_64.self)
            let entryName = unsafe strings.advanced(by: Int(entry.n_un.n_strx)).assumingMemoryBound(to: CChar.self)
            if unsafe strcmp(entryName, symbol) == 0 {
                return unsafe UnsafeMutableRawPointer(bitPattern: Int(entry.n_value) + slide)
            }
        }
        return nil
    }
    return nil
}
