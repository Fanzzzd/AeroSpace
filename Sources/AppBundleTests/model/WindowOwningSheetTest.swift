@testable import AppBundle
import Common
import XCTest

/// WeChat 4.1.15 with its "storage is full" sheet open, from https://github.com/Fanzzzd/AeroSpace/issues/2: the app's
/// AXFocusedWindow is the sheet, which has no subrole, and only the main window is in AXWindows
final class WindowOwningSheetTest: XCTestCase {
    private let mainWindow = "AXUIElement(AxWindowId=4433, title=\"Weixin\", role=\"AXWindow\", subrole=\"AXStandardWindow\")"

    func testFocusedSheetIsTheWindowItIsAttachedTo() {
        let sheet: [String: Json] = [
            "Aero.axWindowId": .int(10702),
            kAXRoleAttribute: .string(kAXSheetRole),
            kAXWindowAttribute: .string(mainWindow),
        ]
        assertEquals(windowOwningSheet((10702, sheet)).windowId, 4433)
    }

    func testFocusedWindowIsItself() {
        let window: [String: Json] = [
            "Aero.axWindowId": .int(4433),
            kAXRoleAttribute: .string(kAXWindowRole),
        ]
        assertEquals(windowOwningSheet((4433, window)).windowId, 4433)
    }

    func testSheetThatDoesNotSayItsWindowIsItself() {
        let sheet: [String: Json] = [
            "Aero.axWindowId": .int(10702),
            kAXRoleAttribute: .string(kAXSheetRole),
        ]
        assertEquals(windowOwningSheet((10702, sheet)).windowId, 10702)
    }
}
