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

    private static let name = "AeroSpace Closet"
    private static let vendorId: UInt32 = 0x4145 // "AE"

    /// Where hidden windows go, in AeroSpace coordinates. Nil when the closet couldn't be made
    var rect: Rect? {
        guard let displayId else { return nil }
        return CGDisplayBounds(displayId).asTopLeftRect
    }

    nonisolated static func isCloset(_ screen: NSScreen) -> Bool {
        guard let closet = id.withLock({ $0 }) else { return false }
        return screen.displayId == closet
    }

    func open() {
        if isUnitTest || display != nil { return }
        let size = NSScreen.screens.reduce(CGSize(width: 1280, height: 800)) {
            CGSize(width: max($0.width, $1.frame.width), height: max($0.height, $1.frame.height))
        }
        guard let (display, id) = Self.makeDisplay(width: Int(size.width), height: Int(size.height)) else {
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
    /// it snaps the closet to that corner
    private func place() {
        guard let displayId else { return }
        let others = NSScreen.screens.compactMap(\.displayId).filter { $0 != displayId }
        guard let union = others.map({ CGDisplayBounds($0) }).reduce(nil, { $0?.union($1) ?? $1 }) else { return }
        let bounds = CGDisplayBounds(displayId)
        if bounds.minX == union.maxX && bounds.minY == union.maxY { return }
        var config: CGDisplayConfigRef? = nil
        guard unsafe CGBeginDisplayConfiguration(&config) == .success else { return }
        unsafe CGConfigureDisplayOrigin(config, displayId, Int32(union.maxX), Int32(union.maxY))
        unsafe CGCompleteDisplayConfiguration(config, .forSession)
    }

    private func pushPointerOut() {
        guard let rect, let event = CGEvent(source: nil) else { return }
        let point = event.location
        if !rect.contains(point) { return }
        let others = NSScreen.screens.compactMap(\.displayId).filter { $0 != displayId }.map { CGDisplayBounds($0) }
        let nearest = others.min { $0.distance(to: point) < $1.distance(to: point) }
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

        let initDisplay = NSSelectorFromString("initWithDescriptor:")
        guard let allocated = unsafe displayClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject,
              let display = unsafe allocated.perform(initDisplay, with: descriptor)?.takeUnretainedValue() as? NSObject
        else { return nil }

        typealias InitMode = @convention(c) (AnyObject, Selector, UInt, UInt, Double) -> AnyObject
        let initMode = NSSelectorFromString("initWithWidth:height:refreshRate:")
        guard let modeAllocated = unsafe modeClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() as? NSObject
        else { return nil }
        let mode = unsafe unsafeBitCast(modeAllocated.method(for: initMode), to: InitMode.self)(
            modeAllocated, initMode, UInt(width), UInt(height), 60,
        )
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
