@testable import AppBundle
import Testing

@MainActor
@Suite(.serializedGlobally)
struct WorkspaceTest {
    init() { setUpWorkspacesForTests() }

    @Test func testAlternatingSplitsFollowLastInsertedWindow() throws {
        config.defaultRootContainerOrientation = .vertical
        let workspace = Workspace.get(byName: "alternating")
        let root = workspace.rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        workspace.lastInsertedTilingWindow = first

        let secondBinding = workspace.bindingForAlternatingSplit()
        #expect(secondBinding.parent === root)
        #expect(root.orientation == .h)
        let second = TestWindow.new(id: 2, parent: secondBinding.parent, adaptiveWeight: secondBinding.adaptiveWeight)
        workspace.lastInsertedTilingWindow = second
        workspace.normalizeContainers()
        second.hWeight = 200

        first.markAsMostRecentChild()
        let thirdBinding = workspace.bindingForAlternatingSplit()
        let vertical = try #require(thirdBinding.parent as? TilingContainer)
        #expect(vertical.orientation == .v)
        #expect(vertical.hWeight == 200)
        #expect(second.parent === vertical)
        #expect(first.parent === root)
        let third = TestWindow.new(id: 3, parent: vertical, adaptiveWeight: thirdBinding.adaptiveWeight)
        workspace.lastInsertedTilingWindow = third
        workspace.normalizeContainers()

        let fourthBinding = workspace.bindingForAlternatingSplit()
        let horizontal = try #require(fourthBinding.parent as? TilingContainer)
        #expect(horizontal.orientation == .h)
        #expect(horizontal.parent === vertical)
        #expect(third.parent === horizontal)
        #expect(second.parent === vertical)
        #expect(fourthBinding.index == 1)
        let fourth = TestWindow.new(id: 4, parent: horizontal, adaptiveWeight: fourthBinding.adaptiveWeight)
        workspace.lastInsertedTilingWindow = fourth
        workspace.normalizeContainers()

        let fifthBinding = workspace.bindingForAlternatingSplit()
        let nextVertical = try #require(fifthBinding.parent as? TilingContainer)
        #expect(nextVertical.orientation == .v)
        #expect(fourth.parent === nextVertical)
    }

    @Test func testAlternatingSplitsSkipFloatingPreviousWindow() {
        let workspace = Workspace.get(byName: "alternating")
        let root = workspace.rootTilingContainer
        let tiled = TestWindow.new(id: 1, parent: root)
        let floating = TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer)
        workspace.lastInsertedTilingWindow = floating

        let binding = workspace.bindingForAlternatingSplit()
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
