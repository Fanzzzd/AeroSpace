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
        guard let (display, id) = Self.makeDisplay(width: width, height: height) else {
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
        unsafe CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            if flags.contains(.beginConfigurationFlag) { return }
            Task { @MainActor in Closet.shared.place() }
        }, nil)
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged],
        ) { _ in
            Task { @MainActor in Closet.shared.pushPointerOut() }
        }
    }

    /// Diagonally off the bottom-right corner of the other displays. macOS keeps every display touching another, so
    /// it snaps the closet to that corner.
    ///
    /// Moving the closet is a display reconfiguration too, which calls ``place()`` again. A display WindowServer has
    /// only just added ignores the first move, so ``place()`` tries the same origin a few times, then gives up until
    /// the other displays change: if macOS keeps the closet elsewhere, asking forever would reconfigure the displays
    /// forever
    private func place() {
        guard let displayId, CGDisplayIsMain(displayId) == 0 else { return }
        guard let union = Self.otherDisplayBounds.reduce(nil, { $0?.union($1) ?? $1 }) else { return }
        let bounds = CGDisplayBounds(displayId)
        if bounds.minX == union.maxX && bounds.minY == union.maxY { return }
        let origin = CGPoint(x: union.maxX, y: union.maxY)
        let attempts = placement?.origin == origin ? placement?.attempts ?? 0 : 0
        if attempts >= 3 { return }
        placement = (origin, attempts + 1)
        var config: CGDisplayConfigRef? = nil
        guard unsafe CGBeginDisplayConfiguration(&config) == .success else { return }
        unsafe CGConfigureDisplayOrigin(config, displayId, Int32(origin.x), Int32(origin.y))
        unsafe CGCompleteDisplayConfiguration(config, .forSession)
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
