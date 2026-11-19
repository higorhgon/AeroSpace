@testable import AppBundle
import Common
import Testing

@MainActor
@Suite(.serializedGlobally)
struct WorkspaceTest {
    init() { setUpWorkspacesForTests() }

    @Test(arguments: [(DefaultContainerOrientation.horizontal, Orientation.h), (.vertical, .v)])
    func testBspSplitsFollowLastInsertedWindow(defaultOrientation: DefaultContainerOrientation, rootOrientation: Orientation) throws {
        config.defaultRootContainerLayout = .bsp
        config.defaultRootContainerOrientation = defaultOrientation
        let workspace = Workspace.get(byName: "bsp")
        let root = workspace.rootTilingContainer
        #expect(root.layout == .tiles)
        let first = TestWindow.new(id: 1, parent: root)
        workspace.lastInsertedTilingWindow = first

        let secondBinding = workspace.bindingForBspSplit()
        #expect(secondBinding.parent === root)
        #expect(root.orientation == rootOrientation)
        let second = TestWindow.new(id: 2, parent: secondBinding.parent, adaptiveWeight: secondBinding.adaptiveWeight)
        workspace.lastInsertedTilingWindow = second
        workspace.normalizeContainers()
        second.setWeight(rootOrientation, 200)

        first.markAsMostRecentChild()
        let thirdBinding = workspace.bindingForBspSplit()
        let thirdSplit = try #require(thirdBinding.parent as? TilingContainer)
        #expect(thirdSplit.orientation == rootOrientation.opposite)
        #expect(thirdSplit.getWeight(rootOrientation) == 200)
        #expect(second.parent === thirdSplit)
        #expect(first.parent === root)
        let third = TestWindow.new(id: 3, parent: thirdSplit, adaptiveWeight: thirdBinding.adaptiveWeight)
        workspace.lastInsertedTilingWindow = third
        workspace.normalizeContainers()

        let fourthBinding = workspace.bindingForBspSplit()
        let fourthSplit = try #require(fourthBinding.parent as? TilingContainer)
        #expect(fourthSplit.orientation == rootOrientation)
        #expect(fourthSplit.parent === thirdSplit)
        #expect(third.parent === fourthSplit)
        #expect(second.parent === thirdSplit)
        #expect(fourthBinding.index == 1)
        let fourth = TestWindow.new(id: 4, parent: fourthSplit, adaptiveWeight: fourthBinding.adaptiveWeight)
        workspace.lastInsertedTilingWindow = fourth
        workspace.normalizeContainers()

        let fifthBinding = workspace.bindingForBspSplit()
        let fifthSplit = try #require(fifthBinding.parent as? TilingContainer)
        #expect(fifthSplit.orientation == rootOrientation.opposite)
        #expect(fourth.parent === fifthSplit)
    }

    @Test func testBspSplitsSkipFloatingPreviousWindow() {
        config.defaultRootContainerLayout = .bsp
        let workspace = Workspace.get(byName: "bsp")
        let root = workspace.rootTilingContainer
        let tiled = TestWindow.new(id: 1, parent: root)
        let floating = TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer)
        workspace.lastInsertedTilingWindow = floating

        let binding = workspace.bindingForBspSplit()
        #expect(binding.parent === root)
        #expect(binding.index == 1)
        #expect(tiled.parent === root)
        #expect(floating.isFloating)
        #expect(root.orientation == .h)
    }

    @Test func testGarbageCollectedWorkspaceIsUnbound() {
        let garbage = Workspace.get(byName: "a")
        Workspace.garbageCollectUnusedWorkspaces()
        #expect(garbage.parent == nil)
        #expect(Workspace.get(byName: "a") !== garbage)
    }

    @Test func testGarbageCollectAndForceAssignDontDuplicateWorkspaces() {
        config.workspaceToMonitorForceAssignment = ["a": [.main]]
        for _ in 1 ... 3 {
            Workspace.garbageCollectUnusedWorkspaces()
            Workspace.forceAssignWorkspaces()
        }
        let container = mainMonitorInfo.toMonitorOrRearrangeMonitors().getWorkspacesContainerOrCreate()
        #expect(container.children.filterIsInstance(of: Workspace.self).count { $0.name == "a" } == 1)
    }

    @Test func testUpdateTrayTextAfterGarbageCollection() {
        _ = Workspace.get(byName: "a")
        Workspace.garbageCollectUnusedWorkspaces()
        #expect(Workspace.get(byName: "a").focusWorkspace())
        updateTrayText()
        #expect(mainMonitorInfo.visibleWorkspace === globalFocus.workspace)
    }
}
