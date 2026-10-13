import AppKit
import Common

/// A desktop picture that names the closet, so it's told apart from real monitors in System Settings, which lists it
/// with a thumbnail of its desktop
enum ClosetDesktopPicture {
    /// Bump when the picture changes, so the cached file is drawn again
    private static let version = 1

    @MainActor
    static func set(on screen: NSScreen) -> Bool {
        do {
            try NSWorkspace.shared.setDesktopImageURL(try file(), for: screen, options: [
                .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                .allowClipping: true,
            ])
            return true
        } catch {
            ClosetLog.write("label: failed: \(error)")
            return false
        }
    }

    /// The picture, drawn once into the caches folder
    private static func file() throws -> URL {
        let folder = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(aeroSpaceAppId, isDirectory: true)
        let url = folder.appendingPathComponent("closet-\(version).png")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png().write(to: url)
        return url
    }

    private static func png() throws -> Data {
        let image = NSImage(size: NSSize(width: 1600, height: 1000), flipped: false) { rect in
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
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        return png
    }
}
