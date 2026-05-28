import AppKit

enum WindowKind: Hashable {
    case main
    case playlist
    case equalizer
    case video      // NEW: Video window (VIDEO.bmp chrome, AVPlayer)
    case milkdrop   // NEW: Milkdrop visualization window (Butterchurn)
}

/// Cluster semantics for a custom drag.
enum WindowDragScope {
    /// Winamp behavior: the main window drags the full connected cluster; every
    /// other window drags by itself (separating from the cluster, allowing
    /// re-snapping on release).
    case winampDefault
    /// macOS Ctrl+Cmd-drag behavior: every window in the connected cluster
    /// follows together, regardless of which window initiated the drag.
    case cohesiveCluster
}

@MainActor
final class WindowSnapManager: NSObject, NSWindowDelegate {
    static let shared = WindowSnapManager()

    private struct TrackedWindow {
        weak var window: NSWindow?
        let kind: WindowKind
    }

    private struct VirtualScreenSpace {
        let top: CGFloat
        let left: CGFloat
        let bounds: BoundingBox
        let screenBoxes: [Box]
    }

    private var windows: [WindowKind: TrackedWindow] = [:]
    private var lastOrigins: [ObjectIdentifier: NSPoint] = [:]
    private var lastFrames: [ObjectIdentifier: NSRect] = [:]
    private var isAdjusting = false

    /// Edge-coincidence tolerance for "docked" relationships. AppKit rounds
    /// frames to whole points so any sub-pixel difference is a true gap.
    private static let dockTolerance: CGFloat = 1.0

    // Public methods to disable snap manager during programmatic resizing
    func beginProgrammaticAdjustment() {
        isAdjusting = true
    }

    func endProgrammaticAdjustment() {
        isAdjusting = false
        // Update lastOrigins for all windows after programmatic adjustment
        for (_, tracked) in windows {
            if let w = tracked.window {
                let id = ObjectIdentifier(w)
                lastOrigins[id] = w.frame.origin
                lastFrames[id] = w.frame
            }
        }
    }

    func register(window: NSWindow, kind: WindowKind) {
        windows[kind] = TrackedWindow(window: window, kind: kind)
        // Delegate is set via WindowDelegateMultiplexer in WindowCoordinator
        let id = ObjectIdentifier(window)
        lastOrigins[id] = window.frame.origin
        lastFrames[id] = window.frame
    }

    func kind(for window: NSWindow) -> WindowKind? {
        windows.first(where: { $0.value.window === window })?.key
    }

    func clusterKinds(containing kind: WindowKind) -> Set<WindowKind>? {
        guard let (_, idToBox) = buildBoxes() else { return nil }
        guard let targetWindow = windows[kind]?.window else { return nil }
        let targetID = ObjectIdentifier(targetWindow)
        guard idToBox[targetID] != nil else { return nil }

        let clusterIDs = connectedCluster(start: targetID, boxes: idToBox)
        var connectedKinds: Set<WindowKind> = []
        for (candidateKind, tracked) in windows {
            guard let window = tracked.window else { continue }
            if clusterIDs.contains(ObjectIdentifier(window)) {
                connectedKinds.insert(candidateKind)
            }
        }
        return connectedKinds
    }

    func areConnected(_ first: WindowKind, _ second: WindowKind) -> Bool {
        guard let cluster = clusterKinds(containing: first) else { return false }
        return cluster.contains(second)
    }

    func windowDidMove(_ notification: Notification) {
        guard !isAdjusting else { return }
        guard let movedWindow = notification.object as? NSWindow else { return }

        // Determine which tracked kind moved
        guard let movedKind = windows.first(where: { $0.value.window === movedWindow })?.key else { return }

        guard let virtualSpace = makeVirtualSpace() else { return }
        let virtualTop = virtualSpace.top
        let virtualLeft = virtualSpace.left

        func box(for window: NSWindow) -> Box {
            let f = window.frame
            let x = f.origin.x - virtualLeft
            let yTop = virtualTop - (f.origin.y + f.size.height)
            return Box(x: x, y: yTop, width: f.size.width, height: f.size.height)
        }

        guard let moved = windows[movedKind]?.window else { return }
        let movedID = ObjectIdentifier(moved)

        // Compute user delta from last origin
        let currentOrigin = moved.frame.origin
        let lastOrigin = lastOrigins[movedID] ?? currentOrigin
        let userDelta = NSPoint(x: currentOrigin.x - lastOrigin.x, y: currentOrigin.y - lastOrigin.y)

        // Build mapping from window -> box (ONLY for visible windows)
        var idToWindow: [ObjectIdentifier: NSWindow] = [:]
        var idToBox: [ObjectIdentifier: Box] = [:]
        for (_, tracked) in windows {
            if let w = tracked.window, w.isVisible {  // FIX: Skip invisible windows
                let id = ObjectIdentifier(w)
                idToWindow[id] = w
                idToBox[id] = box(for: w)
            }
        }

        // Find connected cluster including the moved window
        let clusterIDs = connectedCluster(start: movedID, boxes: idToBox)
        let otherIDs = Set(idToBox.keys).subtracting(clusterIDs)

        // 1) Move the rest of the cluster by the user's delta (the moved window already moved)
        isAdjusting = true
        for id in clusterIDs where id != movedID {
            if let w = idToWindow[id] {
                let origin = w.frame.origin
                w.setFrameOrigin(NSPoint(x: origin.x + userDelta.x, y: origin.y + userDelta.y))
            }
        }
        isAdjusting = false

        // Recompute cluster boxes after move, mapping ID to Box
        var clusterIdToBox: [ObjectIdentifier: Box] = [:]
        for id in clusterIDs {
            if let w = idToWindow[id] {
                clusterIdToBox[id] = box(for: w)
            }
        }
        let clusterBoxes = Array(clusterIdToBox.values)
        guard !clusterBoxes.isEmpty else { return }
        let groupBox = SnapUtils.boundingBox(clusterBoxes)

        // Snap the whole cluster to other windows and screen edges
        let otherBoxes = otherIDs.compactMap { idToBox[$0] }
        let diffToOthers = SnapUtils.snapToMany(groupBox, otherBoxes)
        let diffWithin = SnapUtils.snapWithinUnion(groupBox, union: virtualSpace.bounds, regions: virtualSpace.screenBoxes)
        let snappedGroupPoint = SnapUtils.applySnap(Point(x: groupBox.x, y: groupBox.y), diffToOthers, diffWithin)
        let groupDelta = CGPoint(x: snappedGroupPoint.x - groupBox.x, y: snappedGroupPoint.y - groupBox.y)

        if abs(groupDelta.x) >= 1 || abs(groupDelta.y) >= 1 {
            isAdjusting = true
            for id in clusterIDs {
                if let w = idToWindow[id], var b = clusterIdToBox[id] {
                    // GEMINI FIX: Apply delta to box in top-left space
                    b.x += groupDelta.x
                    b.y += groupDelta.y
                    // Convert the new box position back to AppKit coordinates and apply
                    apply(box: b, to: w, virtualTop: virtualTop, virtualLeft: virtualLeft)
                }
            }
            isAdjusting = false
        }

        // Update last origins for all tracked windows to current
        for (_, tracked) in windows {
            if let w = tracked.window {
                let id = ObjectIdentifier(w)
                lastOrigins[id] = w.frame.origin
                lastFrames[id] = w.frame
            }
        }
    }

    /// Cascade a top-anchored resize (shade toggle, double-size) down to any
    /// windows docked to the resized window's bottom edge. The chain of docked
    /// windows below moves by the same delta as the bottom edge so they stay
    /// glued in place — matching classic Winamp window grouping where shading
    /// a window pulls the stack beneath it up.
    func windowDidResize(_ notification: Notification) {
        guard !isAdjusting else { return }
        guard let resized = notification.object as? NSWindow else { return }
        let resizedID = ObjectIdentifier(resized)
        let newFrame = resized.frame
        guard let oldFrame = lastFrames[resizedID] else {
            lastFrames[resizedID] = newFrame
            return
        }
        lastFrames[resizedID] = newFrame

        // Top-anchored means the visual top edge stayed put. AppKit's
        // top-left in macOS bottom-left coords is `origin.y + height`.
        let oldTop = oldFrame.origin.y + oldFrame.size.height
        let newTop = newFrame.origin.y + newFrame.size.height
        guard abs(oldTop - newTop) < Self.dockTolerance else { return }

        // Positive when the bottom moved UP (window shrank from bottom),
        // negative when it moved DOWN (window grew). Apply as-is to docked
        // windows' origin.y — they sit *below* the resized window, so they
        // need to follow the bottom edge in the same direction.
        let delta = newFrame.origin.y - oldFrame.origin.y
        guard abs(delta) > 0 else { return }

        let toMove = transitivelyDockedBelow(
            anchorBottomY: oldFrame.origin.y,
            anchorXRange: (oldFrame.minX, oldFrame.maxX),
            excludeID: resizedID
        )

        guard !toMove.isEmpty else { return }

        beginProgrammaticAdjustment()
        for id in toMove {
            guard let w = window(for: id) else { continue }
            var origin = w.frame.origin
            origin.y += delta
            w.setFrameOrigin(origin)
            lastFrames[id] = w.frame
            lastOrigins[id] = w.frame.origin
        }
        endProgrammaticAdjustment()
    }

    /// Walks the chain of windows whose top edge sits on the supplied bottom
    /// edge (transitively — a window docked to one of those windows is also
    /// included). Uses each candidate's *current* frame, valid here because
    /// `windowDidResize` fires before any of the cascaded moves run.
    private func transitivelyDockedBelow(
        anchorBottomY: CGFloat,
        anchorXRange: (CGFloat, CGFloat),
        excludeID: ObjectIdentifier
    ) -> [ObjectIdentifier] {
        var result: [ObjectIdentifier] = []
        var seen: Set<ObjectIdentifier> = [excludeID]
        var frontier: [(bottomY: CGFloat, xRange: (CGFloat, CGFloat))] = [(anchorBottomY, anchorXRange)]

        while let edge = frontier.popLast() {
            for (_, tracked) in windows {
                guard let w = tracked.window, w.isVisible else { continue }
                let id = ObjectIdentifier(w)
                guard !seen.contains(id) else { continue }
                let f = w.frame
                let wTop = f.origin.y + f.size.height
                guard abs(wTop - edge.bottomY) < Self.dockTolerance else { continue }
                guard xRangesOverlap(edge.xRange, (f.minX, f.maxX)) else { continue }

                seen.insert(id)
                result.append(id)
                frontier.append((f.origin.y, (f.minX, f.maxX)))
            }
        }
        return result
    }

    private func xRangesOverlap(_ a: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat)) -> Bool {
        a.0 < b.1 && b.0 < a.1
    }

    private func window(for id: ObjectIdentifier) -> NSWindow? {
        for (_, tracked) in windows {
            if let w = tracked.window, ObjectIdentifier(w) == id { return w }
        }
        return nil
    }

    // Two boxes belong to the same cluster only when an edge actually touches —
    // perpendicular ranges strictly overlap and parallel edges coincide within
    // `dockTolerance`. Using `SnapUtils.near` / `overlapX` / `overlapY` here
    // would leak the 15-pt snap-attraction radius into cluster membership, so
    // a window left 10 pt away after the snap source disappeared (e.g. shown
    // again after being hidden while the rest of the cluster moved) would
    // still be treated as docked.
    private func boxesAreConnected(_ a: Box, _ b: Box) -> Bool {
        let aLeft = SnapUtils.left(a), aRight = SnapUtils.right(a)
        let aTop = SnapUtils.top(a), aBottom = SnapUtils.bottom(a)
        let bLeft = SnapUtils.left(b), bRight = SnapUtils.right(b)
        let bTop = SnapUtils.top(b), bBottom = SnapUtils.bottom(b)
        let tol = Self.dockTolerance

        // Stacked: x ranges actually overlap, one box's bottom meets the other's top.
        if aLeft < bRight && bLeft < aRight {
            if abs(aBottom - bTop) < tol { return true }
            if abs(aTop - bBottom) < tol { return true }
        }
        // Side-by-side: y ranges actually overlap, one box's right meets the other's left.
        if aTop < bBottom && bTop < aBottom {
            if abs(aRight - bLeft) < tol { return true }
            if abs(aLeft - bRight) < tol { return true }
        }
        return false
    }

    private func connectedCluster(start: ObjectIdentifier, boxes: [ObjectIdentifier: Box]) -> Set<ObjectIdentifier> {
        var visited: Set<ObjectIdentifier> = []
        var stack: [ObjectIdentifier] = [start]
        while let id = stack.popLast() {
            if visited.contains(id) { continue }
            visited.insert(id)
            guard let box = boxes[id] else { continue }
            for (otherID, otherBox) in boxes where otherID != id {
                if !visited.contains(otherID) && boxesAreConnected(box, otherBox) {
                    stack.append(otherID)
                }
            }
        }
        return visited
    }

    // Helper to convert top-left box coordinates back to AppKit bottom-left origin and apply to window
    private func apply(box: Box, to window: NSWindow, virtualTop: CGFloat, virtualLeft: CGFloat) {
        // Convert top-left box back to AppKit bottom-left origin
        let newOriginX = box.x + virtualLeft
        let newOriginY = virtualTop - (box.y + box.height)
        let newOrigin = NSPoint(x: newOriginX, y: newOriginY)
        let currentOrigin = window.frame.origin
        // Only move if changed by at least 1px to avoid feedback loops
        if abs(currentOrigin.x - newOrigin.x) >= 1 || abs(currentOrigin.y - newOrigin.y) >= 1 {
            isAdjusting = true
            window.setFrameOrigin(newOrigin)
            isAdjusting = false
        }
    }

    // MARK: - Custom Drag Support

    private struct DragContext {
        let draggedWindowID: ObjectIdentifier
        let clusterIDs: Set<ObjectIdentifier>
        let baseBoxes: [ObjectIdentifier: Box]
        let virtualSpace: VirtualScreenSpace
        var lastInputDelta: CGPoint = .zero
    }

    private var dragContexts: [WindowKind: DragContext] = [:]

    func beginCustomDrag(
        kind: WindowKind,
        startPointInScreen _: NSPoint,
        scope: WindowDragScope = .winampDefault
    ) {
        guard let window = windows[kind]?.window else { return }
        guard let (virtualSpace, idToBox) = buildBoxes() else { return }
        let draggedID = ObjectIdentifier(window)
        guard idToBox[draggedID] != nil else { return }

        // Cluster membership depends on drag scope.
        // - winampDefault: main drags the full cluster; non-main windows detach.
        // - cohesiveCluster: any initiating window drags the full cluster as one.
        let clusterIDs: Set<ObjectIdentifier>
        switch scope {
        case .winampDefault:
            if kind == .main {
                clusterIDs = connectedCluster(start: draggedID, boxes: idToBox)
            } else {
                clusterIDs = [draggedID]
            }
        case .cohesiveCluster:
            clusterIDs = connectedCluster(start: draggedID, boxes: idToBox)
        }

        var baseBoxes: [ObjectIdentifier: Box] = [:]
        for id in clusterIDs {
            if let box = idToBox[id] {
                baseBoxes[id] = box
            }
        }

        dragContexts[kind] = DragContext(
            draggedWindowID: draggedID,
            clusterIDs: clusterIDs,
            baseBoxes: baseBoxes,
            virtualSpace: virtualSpace
        )
    }

    func updateCustomDrag(kind: WindowKind, cumulativeDelta delta: CGPoint) {
        guard var context = dragContexts[kind] else { return }
        guard delta != context.lastInputDelta else { return }

        var idToWindow: [ObjectIdentifier: NSWindow] = [:]
        for (_, tracked) in windows {
            if let window = tracked.window {
                idToWindow[ObjectIdentifier(window)] = window
            }
        }

        guard
            context.baseBoxes[context.draggedWindowID] != nil
        else {
            dragContexts.removeValue(forKey: kind)
            return
        }

        let liveBoxes = boxes(in: context.virtualSpace)
        let otherBoxes = liveBoxes.compactMap { entry -> Box? in
            context.clusterIDs.contains(entry.key) ? nil : entry.value
        }

        let topLeftDelta = CGPoint(x: delta.x, y: -delta.y)

        // Snap cluster bounding box, not just dragged window (prevents off-screen drift)
        let clusterBaseBox = SnapUtils.boundingBox(Array(context.baseBoxes.values))
        var translatedGroupBox = clusterBaseBox
        translatedGroupBox.x += topLeftDelta.x
        translatedGroupBox.y += topLeftDelta.y

        let diffToOthers = SnapUtils.snapToMany(translatedGroupBox, otherBoxes)
        let diffWithin = SnapUtils.snapWithinUnion(
            translatedGroupBox,
            union: context.virtualSpace.bounds,
            regions: context.virtualSpace.screenBoxes
        )
        let snappedPoint = SnapUtils.applySnap(
            Point(x: translatedGroupBox.x, y: translatedGroupBox.y),
            diffToOthers,
            diffWithin
        )
        let snapDelta = CGPoint(
            x: snappedPoint.x - translatedGroupBox.x,
            y: snappedPoint.y - translatedGroupBox.y
        )
        let finalDelta = CGPoint(
            x: topLeftDelta.x + snapDelta.x,
            y: topLeftDelta.y + snapDelta.y
        )

        // Compute the requested AppKit origin for every cluster member.
        var requestedOrigins: [ObjectIdentifier: NSPoint] = [:]
        for (id, baseBox) in context.baseBoxes {
            var movedBox = baseBox
            movedBox.x += finalDelta.x
            movedBox.y += finalDelta.y
            let originX = movedBox.x + context.virtualSpace.left
            let originY = context.virtualSpace.top - (movedBox.y + movedBox.height)
            requestedOrigins[id] = NSPoint(x: originX, y: originY)
        }

        // Pass 1: ask AppKit for those positions. Borderless+movable windows
        // get silently clamped down when their top would cross the menu bar;
        // the clamp shows up as drift between the requested and actual
        // origin. Applied per-window, that drift is exactly what tears the
        // cluster apart — main stops, EQ keeps going.
        isAdjusting = true
        for (id, requested) in requestedOrigins {
            guard let window = idToWindow[id] else { continue }
            let current = window.frame.origin
            if abs(current.x - requested.x) >= 1 || abs(current.y - requested.y) >= 1 {
                window.setFrameOrigin(requested)
            }
        }
        isAdjusting = false

        // Pass 2: pull the whole cluster back by the most-restrictive
        // downward clamp so the rubber band stops the cluster as one unit.
        // We only correct downward y drift (the menu-bar case) — other
        // edges don't trigger AppKit clamping for borderless windows, and
        // the user opted out of cohesive treatment there.
        let topClampDy = requestedOrigins.compactMap { id, requested -> CGFloat? in
            guard let window = idToWindow[id] else { return nil }
            let dy = window.frame.origin.y - requested.y
            return dy < 0 ? dy : nil
        }.min() ?? 0

        if topClampDy < -0.5 {
            isAdjusting = true
            for (id, requested) in requestedOrigins {
                guard let window = idToWindow[id] else { continue }
                let corrected = NSPoint(x: requested.x, y: requested.y + topClampDy)
                let current = window.frame.origin
                if abs(current.y - corrected.y) >= 1 {
                    window.setFrameOrigin(corrected)
                }
            }
            isAdjusting = false
        }

        context.lastInputDelta = delta
        dragContexts[kind] = context
    }

    func endCustomDrag(kind: WindowKind) {
        dragContexts.removeValue(forKey: kind)
        for (_, tracked) in windows {
            if let w = tracked.window {
                let id = ObjectIdentifier(w)
                lastOrigins[id] = w.frame.origin
                lastFrames[id] = w.frame
            }
        }
    }

    private func buildBoxes() -> (VirtualScreenSpace, [ObjectIdentifier: Box])? {
        guard let virtualSpace = makeVirtualSpace() else { return nil }
        return (virtualSpace, boxes(in: virtualSpace))
    }

    private func makeVirtualSpace() -> VirtualScreenSpace? {
        let allScreens = NSScreen.screens
        guard !allScreens.isEmpty else { return nil }

        let virtualTop: CGFloat = allScreens.map { $0.frame.maxY }.max() ?? 0
        let virtualLeft: CGFloat = allScreens.map { $0.frame.minX }.min() ?? 0
        let virtualRight: CGFloat = allScreens.map { $0.frame.maxX }.max() ?? 0
        let virtualBottom: CGFloat = allScreens.map { $0.frame.minY }.min() ?? 0
        let bounds = BoundingBox(width: virtualRight - virtualLeft, height: virtualTop - virtualBottom)
        let screenBoxes = allScreens.map { screen -> Box in
            let visible = screen.visibleFrame
            let x = visible.origin.x - virtualLeft
            let yTop = virtualTop - (visible.origin.y + visible.size.height)
            return Box(x: x, y: yTop, width: visible.size.width, height: visible.size.height)
        }
        return VirtualScreenSpace(top: virtualTop, left: virtualLeft, bounds: bounds, screenBoxes: screenBoxes)
    }

    private func boxes(in space: VirtualScreenSpace) -> [ObjectIdentifier: Box] {
        var idToBox: [ObjectIdentifier: Box] = [:]
        for (_, tracked) in windows {
            if let window = tracked.window, window.isVisible {  // CRITICAL: Skip invisible windows
                idToBox[ObjectIdentifier(window)] = box(for: window, in: space)
            }
        }
        return idToBox
    }

    private func box(for window: NSWindow, in space: VirtualScreenSpace) -> Box {
        let frame = window.frame
        let x = frame.origin.x - space.left
        let yTop = space.top - (frame.origin.y + frame.size.height)
        return Box(x: x, y: yTop, width: frame.size.width, height: frame.size.height)
    }
}
