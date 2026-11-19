import AppKit
import Common
import CoreImage
import ScreenCaptureKit

@MainActor
final class FloatingWindowPreviews {
    static let shared = FloatingWindowPreviews()

    private struct Target {
        let windowId: OpaqueWindowId
        let pid: pid_t
        let frame: CGRect
    }

    private var targets: [CGWindowID: Target] = [:]
    private var previews: [CGWindowID: FloatingPreview] = [:]
    private var previewOrigins: [OpaqueWindowId: CGPoint] = [:]
    private var startTask: Task<Void, Never>?
    private var requestedPermission = false
    private var captureStoppedByUser = false
    private var failedTargets: Set<CGWindowID> = []
    private var sessionIsActive = true

    func setSessionActive(_ active: Bool) {
        sessionIsActive = active
        sync()
    }

    func blocksHover(at point: Point) -> Bool {
        let location = point.withYAxisFlipped.asCGPoint
        return targets.contains { id, target in
            if let preview = previews[id], preview.isVisible {
                return preview.frame.contains(location)
            }
            return startTask != nil && !failedTargets.contains(id) && panelFrame(for: target).contains(location)
        }
    }

    func sync() {
        if !config.floatingWindowPreviews { captureStoppedByUser = false }
        previewOrigins = previewOrigins.filter { id, _ in Window.get(byId: id)?.isFloating == true }
        targets = captureStoppedByUser ? [:] : findPreviewTargets()
        failedTargets.formIntersection(targets.keys)
        for id in Array(previews.keys) where targets[id] == nil {
            previews.removeValue(forKey: id)?.stop()
        }
        for (id, target) in targets {
            previews[id]?.setFrame(panelFrame(for: target))
        }
        guard startTask == nil, targets.keys.contains(where: { previews[$0] == nil && !failedTargets.contains($0) }) else { return }
        guard CGPreflightScreenCaptureAccess() else {
            if !requestedPermission {
                requestedPermission = true
                _ = CGRequestScreenCaptureAccess()
            }
            return
        }
        startTask = Task { await startMissingPreviews() }
    }

    private func findPreviewTargets() -> [CGWindowID: Target] {
        guard config.floatingWindowPreviews,
              sessionIsActive,
              !serverArgs.isReadOnly,
              TrayMenuModel.shared.isEnabled,
              globalFocus.windowOrNil?.parent is TilingContainer else { return [:] }

        let workspace = globalFocus.workspace
        guard !workspace.floatingWindows.isEmpty else { return [:] }
        guard let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [:] }

        // Native focus can reorder windows after the hover session completes.
        // Use AeroSpace's focus to decide when to switch to previews.
        var result: [CGWindowID: Target] = [:]
        for info in onScreen {
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let window = Window.get(byNativeId: id, pid: pid),
                  window.nodeWorkspace === workspace,
                  window.isFloating,
                  !window.isFullscreen,
                  window.lifeStatus == .alive,
                  (info[kCGWindowLayer as String] as? CGWindowLevel) == CGWindowLevelForKey(.normalWindow),
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  !frame.isEmpty else { continue }
            result[id] = Target(windowId: window.windowId, pid: pid, frame: frame)
        }
        return result
    }

    private func startMissingPreviews() async {
        let requestedTargets = Set(targets.keys)
        defer {
            startTask = nil
            if !Set(targets.keys).isSubset(of: requestedTargets) { sync() }
        }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }

        for source in content.windows {
            let id = source.windowID
            guard let target = targets[id],
                  source.owningApplication?.processID == target.pid,
                  !failedTargets.contains(id), previews[id] == nil else { continue }
            let preview = FloatingPreview(
                source: source,
                frame: panelFrame(for: target),
                onClick: { [weak self] in self?.focusOriginal(id) },
                onMove: { [weak self] origin in self?.previewOrigins[target.windowId] = origin },
                onStop: { [weak self] error in self?.captureDidStop(id, error: error) },
            )
            previews[id] = preview
            do {
                try await preview.start()
            } catch {
                if previews[id] === preview {
                    captureDidStop(id, error: error)
                }
            }
        }
    }

    private func captureDidStop(_ id: CGWindowID, error: Error) {
        failedTargets.insert(id)
        previews.removeValue(forKey: id)?.stop()
        if (error as? SCStreamError)?.code == .userStopped {
            captureStoppedByUser = true
            sync()
        }
    }

    private func focusOriginal(_ id: CGWindowID) {
        guard let target = targets[id], let token = RunSessionGuard.isServerEnabled else { return }
        // Drop the overlay before changing focus so the original receives the
        // next click. Native focus is applied by the normal refresh session.
        targets.removeValue(forKey: id)
        previews.removeValue(forKey: id)?.stop()
        Task.startUnstructured { @MainActor in
            try await runLightSession(.globalObserver("floating-preview-click"), token) {
                guard let window = Window.get(byId: target.windowId), window.isFloating else { return }
                _ = window.focusWindow()
            }
        }
    }

    private func panelFrame(for target: Target) -> CGRect {
        let original = CGRect(
            x: target.frame.minX,
            y: mainMonitorInfo.height - target.frame.maxY,
            width: target.frame.width,
            height: target.frame.height,
        )
        guard let origin = previewOrigins[target.windowId] else { return original }
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: original.midX, y: original.midY)) }
        let position = screen.map { clampPreviewOrigin(origin, size: original.size, to: $0.visibleFrame) } ?? original.origin
        return CGRect(origin: position, size: original.size)
    }
}

@MainActor
private final class FloatingPreview {
    private let panel: NSPanel
    private let view: FloatingPreviewView
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private let onStop: @MainActor (Error) -> Void
    private let queue = DispatchQueue(label: "aerospace.floating-window-preview")
    private var stream: SCStream?
    private var receiver: FloatingPreviewFrames?
    private var stopped = false

    var isVisible: Bool { panel.isVisible }
    var frame: CGRect { panel.frame }

    init(
        source: SCWindow,
        frame: CGRect,
        onClick: @escaping () -> Void,
        onMove: @escaping (CGPoint) -> Void,
        onStop: @escaping @MainActor (Error) -> Void,
    ) {
        self.onStop = onStop
        view = FloatingPreviewView(frame: CGRect(origin: .zero, size: frame.size), onClick: onClick, onMove: onMove)
        view.wantsLayer = true
        view.layer?.contentsGravity = .resize
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.contentView = view
        panel.isMovable = false

        let configuration = SCStreamConfiguration()
        let scale = min(1, 1440 / max(frame.width, frame.height))
        configuration.width = max(2, Int(frame.width * scale))
        configuration.height = max(2, Int(frame.height * scale))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = false
        if #available(macOS 14.0, *) {
            configuration.ignoreShadowsSingleWindow = true
        }
        filter = SCContentFilter(desktopIndependentWindow: source)
        self.configuration = configuration
    }

    func start() async throws {
        let receiver = FloatingPreviewFrames(
            draw: { [weak self] image in
                guard let self, !stopped else { return }
                view.layer?.contents = image
                if !panel.isVisible { panel.orderFrontRegardless() }
            },
            onStop: { [weak self] error in
                guard let self, !stopped else { return }
                onStop(error)
            },
        )
        self.receiver = receiver
        let stream = SCStream(filter: filter, configuration: configuration, delegate: receiver)
        self.stream = stream
        try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        if stopped { try? await stream.stopCapture() }
    }

    func setFrame(_ frame: CGRect) {
        if !view.isDragging, panel.frame != frame {
            panel.setFrame(frame, display: false)
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        panel.orderOut(nil)
        if let stream {
            Task { try? await stream.stopCapture() }
        }
    }
}

private final class FloatingPreviewView: NSView {
    private let onClick: () -> Void
    private let onMove: (CGPoint) -> Void
    private var dragStart: (mouse: CGPoint, origin: CGPoint, display: CGRect?)?
    private(set) var isDragging = false

    init(frame: CGRect, onClick: @escaping () -> Void, onMove: @escaping (CGPoint) -> Void) {
        self.onClick = onClick
        self.onMove = onMove
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragStart = (window.convertPoint(toScreen: event.locationInWindow), window.frame.origin, window.screen?.visibleFrame)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let window else { return }
        let mouse = window.convertPoint(toScreen: event.locationInWindow)
        let dx = mouse.x - dragStart.mouse.x
        let dy = mouse.y - dragStart.mouse.y
        guard isDragging || hypot(dx, dy) >= 5 else { return }
        isDragging = true
        let origin = CGPoint(x: dragStart.origin.x + dx, y: dragStart.origin.y + dy)
        let position = dragStart.display.map { clampPreviewOrigin(origin, size: window.frame.size, to: $0) } ?? origin
        window.setFrameOrigin(position)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil
            isDragging = false
        }
        if isDragging, let window {
            onMove(window.frame.origin)
        } else if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick()
        }
    }
}

private func clampPreviewOrigin(_ origin: CGPoint, size: CGSize, to bounds: CGRect) -> CGPoint {
    CGPoint(
        x: min(max(origin.x, bounds.minX), max(bounds.minX, bounds.maxX - size.width)),
        y: min(max(origin.y, bounds.minY), max(bounds.minY, bounds.maxY - size.height)),
    )
}

private final class FloatingPreviewFrames: NSObject, SCStreamOutput, SCStreamDelegate {
    private let context = CIContext()
    private let draw: @MainActor (CGImage) -> Void

    private let onStop: @MainActor (Error) -> Void

    init(draw: @escaping @MainActor (CGImage) -> Void, onStop: @escaping @MainActor (Error) -> Void) {
        self.draw = draw
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [onStop] in onStop(error) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              let buffer = sample.imageBuffer else { return }

        let frame = CIImage(cvPixelBuffer: buffer)
        if let image = context.createCGImage(frame, from: frame.extent) {
            DispatchQueue.main.async { [draw] in draw(image) }
        }
    }
}
