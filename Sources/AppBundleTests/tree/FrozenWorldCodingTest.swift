@testable import AppBundle
import XCTest

@MainActor
final class FrozenWorldCodingTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testWorldSavedAtQuitReadsBackTheSame() throws {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
        }
        TestWindow.new(id: 4, parent: workspace.floatingWindowsContainer)
        let frozen = FrozenWorkspace(workspace)

        let read = try JSONDecoder().decode(FrozenWorkspace.self, from: JSONEncoder().encode(frozen))
        assertEquals(read.name, workspace.name)
        assertEquals(read.floatingWindows.map(\.id), [4])
        assertEquals(describe(.container(read.rootTilingNode)), describe(.container(frozen.rootTilingNode)))
        assertEquals(describe(.container(read.rootTilingNode)), "h_tiles(1, v_tiles(2, 3))")
    }

    private func describe(_ node: FrozenTreeNode) -> String {
        switch node {
            case .window(let window): "\(window.id)"
            case .container(let container):
                "\(container.orientation == .h ? "h" : "v")_\(container.layout.rawValue)(\(container.children.map(describe).joined(separator: ", ")))"
        }
    }
}
