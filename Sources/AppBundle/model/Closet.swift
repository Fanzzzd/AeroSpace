import AppKit
import Common
import os

/// A virtual display that holds the windows of invisible workspaces.
///
/// macOS doesn't let a window sit entirely outside the visible area, and apps pull a window that hangs off screen
/// back onto a screen whenever a display is added or removed. Windows parked on a display of their own are on screen
/// as far as apps and macOS can tell, so nothing pulls them back, and nothing of them shows on the user's monitors.
///
/// The closet sits diagonally off the bottom-right corner of the monitors, where only a pointer crossing that exact
/// corner could reach it, and AeroSpace pushes the pointer back if it does. It isn't a monitor: no workspace shows on
/// it and it doesn't count in monitor lists.
///
/// The display is made with the private `CGVirtualDisplay` API (macOS 11 and later), looked up at runtime. It lives as
/// long as AeroSpace runs: if AeroSpace quits or crashes, macOS moves the windows on it to the remaining monitors.
@MainActor
final class Closet {
    static let shared = Closet()

    private var display: NSObject? = nil
    /// Read off the main actor too: ``mainMonitor`` isn't isolated
    private nonisolated static let id = OSAllocatedUnfairLock<CGDirectDisplayID?>(initialState: nil)
    var displayId: CGDirectDisplayID? { Self.id.withLock { $0 } }
    private var pointerMonitor: Any? = nil
    /// The origin ``place()`` last asked for, and how many times
    private var placement: (origin: CGPoint, attempts: Int)? = nil

    private static let name = "AeroSpace Closet"
    private static let vendorId: UInt32 = 0x4145 // "AE"

    /// Where hidden windows go, in AeroSpace coordinates. Nil when the closet couldn't be made, or when it's the main
    /// display, which happens when it's the only one left or the user picks it in System Settings
    var rect: Rect? {
        guard let displayId, CGDisplayIsMain(displayId) == 0 else { return nil }
        return CGDisplayBounds(displayId).asTopLeftRect
    }

    /// The main display is never the closet: AeroSpace needs at least one monitor
    nonisolated static func isCloset(_ screen: NSScreen) -> Bool {
        guard let closet = id.withLock({ $0 }) else { return false }
        return screen.displayId == closet && CGDisplayIsMain(closet) == 0
    }

    func open() {
        if isUnitTest || display != nil { return }
        // As large as the largest monitor, so hidden windows fit. A window that doesn't fit still stays: its top left
        // corner is on the closet, and nothing is right of or below the closet
        let size = NSScreen.screens.reduce(CGSize(width: 1280, height: 800)) {
            CGSize(width: max($0.width, $1.frame.width), height: max($0.height, $1.frame.height))
        }
        // Virtual displays are at most 16384 pixels wide and high, and the closet is Retina
        let width = min(Int(size.width), 8192)
        let height = min(Int(size.height), 8192)
        ClosetLog.startWatchdog()
        PerfStats.start()
        ClosetLog.write("open: making a \(width)x\(height) closet; displays \(Self.describeDisplays()), load \(ClosetLog.loadAverage)")
        let making = DispatchTime.now()
        let made = Self.makeDisplay(width: width, height: height)
        ClosetLog.write("open: made display \(made.map { "\($0.1)" } ?? "none") in \(ClosetLog.milliseconds(since: making)) ms")
        guard let (display, id) = made else {
            MessageModel.shared.message = Message(
                description: "Hiding windows",
                body: "AeroSpace couldn't create its closet display, so windows of invisible workspaces stay on screen",
                containsWarnings: true,
            )
            return
        }
        self.display = display
        Self.id.withLock { $0 = id }
        place()
        label()
        // macOS calls back once per display for each change: handle the change once, after the last call
        unsafe CGDisplayRegisterReconfigurationCallback({ display, flags, _ in
            ClosetLog.write("reconfiguration: display \(display) \(Closet.describe(flags))")
            if flags.contains(.beginConfigurationFlag) { return }
            Task { @MainActor in
                if Closet.shared.changeScheduled { return }
                Closet.shared.changeScheduled = true
                Task { @MainActor in
                    Closet.shared.changeScheduled = false
                    ClosetLog.timed("place") { Closet.shared.place() }
                    ClosetLog.timed("label") { Closet.shared.label() }
                }
            }
        }, nil)
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged],
        ) { _ in
            Task { @MainActor in Closet.shared.pushPointerOut() }
        }
    }

    private var labeled = false

    /// A desktop picture that names the closet, so it's told apart from real monitors in System Settings, which lists
    /// it with a thumbnail of its desktop. The closet's NSScreen may show up only after a reconfiguration, so this is
    /// tried again on each until it works
    private func label() {
        guard !labeled, let screen = NSScreen.screens.first(where: Self.isCloset) else { return }
        let size = NSSize(width: 1600, height: 1000)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.14, alpha: 1).setFill()
            rect.fill()
            let center = NSMutableParagraphStyle()
            center.alignment = .center
            func draw(_ text: String, _ font: NSFont, _ alpha: CGFloat, _ y: CGFloat) {
                (text as NSString).draw(
                    in: NSRect(x: 0, y: y, width: rect.width, height: font.pointSize * 1.4),
                    withAttributes: [.font: font, .foregroundColor: NSColor(white: 1, alpha: alpha), .paragraphStyle: center],
                )
            }
            draw("AeroSpace Closet", .boldSystemFont(ofSize: 130), 1, 520)
            draw("Windows of hidden workspaces wait here", .systemFont(ofSize: 60), 0.75, 380)
            draw("Leave this display where it is", .systemFont(ofSize: 60), 0.75, 290)
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
              let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                  .appendingPathComponent(aeroSpaceAppId, isDirectory: true)
        else { return }
        let url = folder.appendingPathComponent("closet.png")
        let started = DispatchTime.now()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: url)
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                .allowClipping: true,
            ])
            labeled = true
            ClosetLog.write("label: set in \(ClosetLog.milliseconds(since: started)) ms")
        } catch {
            ClosetLog.write("label: failed after \(ClosetLog.milliseconds(since: started)) ms: \(error)")
        }
    }

    /// Moving the closet is a display reconfiguration too, which calls ``place()`` again. A display WindowServer has
    /// only just added ignores the first move, so ``place()`` tries the same origin a few times, then gives up until
    /// the other displays change: if macOS keeps the closet elsewhere, asking forever would reconfigure the displays
    /// forever
    private var changeScheduled = false

    private func place() {
        guard let displayId, CGDisplayIsMain(displayId) == 0, !moving else { return }
        let bounds = CGDisplayBounds(displayId)
        guard let origin = Self.target(size: bounds.size, others: Self.otherDisplayBounds) else { return }
        if bounds.origin == origin {
            // In place: a later move, such as the user's drag, gets its own attempts
            placement = nil
            return
        }
        let attempts = placement?.origin == origin ? placement?.attempts ?? 0 : 0
        if attempts >= 3 {
            ClosetLog.write("place: closet at \(bounds.origin), target \(origin): gave up after 3 attempts")
            return
        }
        // A safety net while the cause of the 2026-10-13 freeze is open: however place() is reached, it moves the
        // closet at most 10 times a minute, then rests for 5 minutes
        let now = Date()
        recentMoves.removeAll { now.timeIntervalSince($0) > 60 }
        if let restingUntil, now < restingUntil { return }
        if recentMoves.count >= 10 {
            restingUntil = now.addingTimeInterval(300)
            ClosetLog.write("place: BREAKER: 10 moves within a minute, resting 5 minutes; displays \(Self.describeDisplays())")
            return
        }
        recentMoves.append(now)
        placement = (origin, attempts + 1)
        ClosetLog.write("place: closet at \(bounds.origin), target \(origin), attempt \(attempts + 1); displays \(Self.describeDisplays())")
        // A display configuration blocks its thread for 0.3 to 2 s, so it runs off the main thread, one at a time.
        // The change it makes calls place() again, which checks the result
        moving = true
        Self.configuring.async {
            let started = DispatchTime.now()
            var config: CGDisplayConfigRef? = nil
            let began = unsafe CGBeginDisplayConfiguration(&config)
            if began == .success {
                unsafe CGConfigureDisplayOrigin(config, displayId, Int32(origin.x), Int32(origin.y))
                let completed = unsafe CGCompleteDisplayConfiguration(config, .forSession)
                ClosetLog.write(
                    "place: completed \(completed.rawValue) in \(ClosetLog.milliseconds(since: started)) ms; closet now at \(CGDisplayBounds(displayId).origin)",
                )
            } else {
                ClosetLog.write("place: CGBeginDisplayConfiguration failed: \(began.rawValue)")
            }
            Task { @MainActor in
                Closet.shared.moving = false
                // A refused move makes no display change, so nothing calls place() back: check here
                Closet.shared.place()
            }
        }
    }

    private var moving = false
    private static let configuring = DispatchQueue(label: "bobko.aerospace.closet-placement", qos: .userInitiated)

    /// Where the closet goes: the bottom-right corner of one of the other displays, the lowest, then rightmost, where
    /// the closet would neither overlap a display nor share an edge with one. Then a pointer reaches it only through
    /// that exact corner, and macOS keeps it there, as it keeps every display touching another
    private static func target(size: CGSize, others: [CGRect]) -> CGPoint? {
        let corners = others.map { CGPoint(x: $0.maxX, y: $0.maxY) }
            .sorted { ($0.y, $0.x) > ($1.y, $1.x) }
        let clear = corners.first { corner in
            let closet = CGRect(origin: corner, size: size)
            return others.allSatisfy { other in
                // Overlapping or sharing an edge: the rectangles touch along a line, not just at a corner
                let overlapX = min(closet.maxX, other.maxX) - max(closet.minX, other.minX)
                let overlapY = min(closet.maxY, other.maxY) - max(closet.minY, other.minY)
                return !(overlapX >= 0 && overlapY >= 0 && (overlapX > 0 || overlapY > 0))
            }
        }
        return clear ?? corners.first
    }

    private var recentMoves: [Date] = []
    private var restingUntil: Date? = nil

    /// Every active display, for the log: id, vendor and bounds
    private static func describeDisplays() -> String {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard unsafe CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return "?" }
        return ids.prefix(Int(count)).map { d in
            let b = CGDisplayBounds(d)
            return "\(d)/\(String(CGDisplayVendorNumber(d), radix: 16))@\(Int(b.minX)),\(Int(b.minY)) \(Int(b.width))x\(Int(b.height))"
        }.joined(separator: " ")
    }

    nonisolated static func describe(_ flags: CGDisplayChangeSummaryFlags) -> String {
        let names: [(CGDisplayChangeSummaryFlags, String)] = [
            (.beginConfigurationFlag, "begin"), (.movedFlag, "moved"), (.setMainFlag, "main"), (.setModeFlag, "mode"),
            (.addFlag, "add"), (.removeFlag, "remove"), (.enabledFlag, "enabled"), (.disabledFlag, "disabled"),
            (.mirrorFlag, "mirror"), (.unMirrorFlag, "unmirror"), (.desktopShapeChangedFlag, "shape"),
        ]
        return names.filter { flags.contains($0.0) }.map(\.1).joined(separator: ",")
    }

    /// Bounds of the active displays other than the closet. Mirrored displays share their source's bounds and aren't
    /// in the list
    private static var otherDisplayBounds: [CGRect] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        guard unsafe CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        let closet = id.withLock { $0 }
        return ids.prefix(Int(count)).filter { $0 != closet }.map { CGDisplayBounds($0) }
    }

    private func pushPointerOut() {
        guard let rect, let event = CGEvent(source: nil) else { return }
        let point = event.location
        if !rect.contains(point) { return }
        let nearest = Self.otherDisplayBounds.min { $0.distance(to: point) < $1.distance(to: point) }
        guard let nearest else { return }
        ClosetLog.write("pointer: pushed out of the closet from \(point)")
        CGWarpMouseCursorPosition(CGPoint(
            x: point.x.coerce(in: nearest.minX ... nearest.maxX - 1),
            y: point.y.coerce(in: nearest.minY ... nearest.maxY - 1),
        ))
    }

    private static func makeDisplay(width: Int, height: Int) -> (NSObject, CGDirectDisplayID)? {
        guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let displayClass = NSClassFromString("CGVirtualDisplay") as? NSObject.Type,
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let modeClass = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type
        else { return nil }
        let descriptor = descriptorClass.init()
        descriptor.setValue(name, forKey: "name")
        descriptor.setValue(width * 2, forKey: "maxPixelsWide")
        descriptor.setValue(height * 2, forKey: "maxPixelsHigh")
        // ~110 ppi, so macOS picks sensible scaling
        let mm = 25.4 / 110
        descriptor.setValue(NSValue(size: NSSize(width: Double(width) * mm, height: Double(height) * mm)), forKey: "sizeInMillimeters")
        descriptor.setValue(vendorId, forKey: "vendorID")
        descriptor.setValue(UInt32(1), forKey: "productID")
        descriptor.setValue(UInt32(1), forKey: "serialNum")
        descriptor.setValue(DispatchQueue.main, forKey: "queue")

        // `alloc` returns a retained object that `init...` consumes, and `init...` returns a retained object. So the
        // result of `alloc` is taken unretained and the result of `init...` retained
        let initDisplay = NSSelectorFromString("initWithDescriptor:")
        guard let allocated = unsafe displayClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject,
              let display = unsafe allocated.perform(initDisplay, with: descriptor)?.takeRetainedValue() as? NSObject
        else { return nil }

        typealias InitMode = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> Unmanaged<AnyObject>?
        let initMode = NSSelectorFromString("initWithWidth:height:refreshRate:")
        guard let modeAllocated = unsafe modeClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject,
              let mode = unsafe unsafeBitCast(modeAllocated.method(for: initMode), to: InitMode.self)(
                  modeAllocated, initMode, UInt32(width), UInt32(height), 60,
              )?.takeRetainedValue()
        else { return nil }
        let settings = settingsClass.init()
        settings.setValue([mode], forKey: "modes")
        // Retina, so windows keep the backing scale they have on Retina monitors
        settings.setValue(UInt32(1), forKey: "hiDPI")
        typealias Apply = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let apply = NSSelectorFromString("applySettings:")
        guard unsafe unsafeBitCast(display.method(for: apply), to: Apply.self)(display, apply, settings) else { return nil }
        guard let id = (display.value(forKey: "displayID") as? NSNumber)?.uint32Value, id != 0 else { return nil }
        return (display, id)
    }
}

extension NSScreen {
    var displayId: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

extension CGRect {
    /// `CGDisplayBounds` already has its origin at the main screen's top left, with y going down, like AeroSpace's
    /// ``Rect``
    fileprivate var asTopLeftRect: Rect { Rect(topLeftX: minX, topLeftY: minY, width: width, height: height) }

    fileprivate func distance(to point: CGPoint) -> CGFloat {
        let dx = max(minX - point.x, 0, point.x - maxX)
        let dy = max(minY - point.y, 0, point.y - maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
