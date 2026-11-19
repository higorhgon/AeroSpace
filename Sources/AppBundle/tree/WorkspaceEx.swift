import Common

extension Workspace {
    @MainActor var rootTilingContainer: TilingContainer {
        let containers = children.filterIsInstance(of: TilingContainer.self)
        switch containers.count {
            case 0:
                let orientation: Orientation = switch config.defaultRootContainerOrientation {
                    case .horizontal: .h
                    case .vertical: .v
                    case .auto: workspaceMonitorInfo.then { $0.width >= $0.height } ? .h : .v
                }
                return TilingContainer(parent: self, adaptiveWeight: 1, orientation, config.defaultRootContainerLayout.containerLayout, index: INDEX_BIND_LAST)
            case 1:
                return containers.singleOrNil().orDie()
            default:
                die("Workspace must contain zero or one tiling container as its child")
        }
    }

    @MainActor
    var floatingWindows: [Window] {
        floatingWindowsContainer.children.filterIsInstance(of: Window.self)
    }

    @MainActor
    var floatingWindowsContainer: FloatingWindowsContainer {
        let containers = children.filterIsInstance(of: FloatingWindowsContainer.self)
        return switch containers.count {
            case 0: FloatingWindowsContainer(parent: self)
            case 1: containers.singleOrNil().orDie()
            default: dieT("Workspace must contain zero or one FloatingWindowsContainer")
        }
    }

    @MainActor var macOsNativeFullscreenWindowsContainer: MacosFullscreenWindowsContainer {
        let containers = children.filterIsInstance(of: MacosFullscreenWindowsContainer.self)
        return switch containers.count {
            case 0: MacosFullscreenWindowsContainer(parent: self)
            case 1: containers.singleOrNil().orDie()
            default: dieT("Workspace must contain zero or one MacosFullscreenWindowsContainer")
        }
    }

    @MainActor var macOsNativeHiddenAppsWindowsContainer: MacosHiddenAppsWindowsContainer {
        let containers = children.filterIsInstance(of: MacosHiddenAppsWindowsContainer.self)
        return switch containers.count {
            case 0: MacosHiddenAppsWindowsContainer(parent: self)
            case 1: containers.singleOrNil().orDie()
            default: dieT("Workspace must contain zero or one MacosHiddenAppsWindowsContainer")
        }
    }

    @MainActor var isVisible: Bool { (parent as? WorkspacesContainer)?.visibleWorkspaceNameOrStale == self.name }

    @MainActor var workspaceMonitorInfo: MonitorInfo { // todo revisit this API (rename)
        return nodeMonitorInfo.orDie() // todo
    }

    @MainActor var forceAssignedMonitorInfo: MonitorInfo? {
        guard let monitorDescriptions = config.workspaceToMonitorForceAssignment[name] else { return nil }
        let sortedMonitors = globalSortedMonitorInfos
        return monitorDescriptions.lazy
            .compactMap { $0.resolveMonitorInfo(sortedMonitors: sortedMonitors) }
            .first
    }

    @MainActor
    func bindingForBspSplit() -> BindingData {
        let root = rootTilingContainer
        var previous = lastInsertedTilingWindow
        if previous?.nodeWorkspace !== self || !(previous?.parent is TilingContainer) || previous?.lifeStatus != .alive {
            var recent: TreeNode? = root
            while let container = recent as? TilingContainer {
                recent = container.mostRecentInhabitedChild
            }
            previous = recent as? Window
        }
        guard let (parent, index) = previous?.nearestAliveTilingParent() else {
            return BindingData(parent: root, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        }
        if parent === root && root.inhabitedChildren.count == 1 {
            root.layout = .tiles
            return BindingData(parent: root, adaptiveWeight: WEIGHT_AUTO, index: index + 1)
        }

        // A flattened container may still contain inactive native tabs. Keep
        // that subtree together when its visible window gets a new split.
        let previousBranch = parent.children[index]
        let binding = previousBranch.unbindFromParent()
        let split = TilingContainer(
            parent: parent,
            adaptiveWeight: binding.adaptiveWeight,
            parent.orientation.opposite,
            .tiles,
            index: binding.index,
        )
        previousBranch.bind(to: split, adaptiveWeight: WEIGHT_AUTO, index: 0)
        return BindingData(parent: split, adaptiveWeight: WEIGHT_AUTO, index: 1)
    }
}
