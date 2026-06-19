import SwiftUI
import AppKit

@MainActor
@Observable
final class PlaylistWindowInteractionState {
    private static let escapeKeyCode: UInt16 = 53
    private static let aKeyCode: UInt16 = 0
    private static let deleteKeyCode: UInt16 = 51         // kVK_Delete (Backspace, the "delete" key on Mac laptops)
    private static let forwardDeleteKeyCode: UInt16 = 117 // kVK_ForwardDelete (full keyboards)
    private static let upArrowKeyCode: UInt16 = 126
    private static let downArrowKeyCode: UInt16 = 125
    private static let pageUpKeyCode: UInt16 = 116
    private static let pageDownKeyCode: UInt16 = 121
    private static let homeKeyCode: UInt16 = 115
    private static let endKeyCode: UInt16 = 119
    private static let returnKeyCode: UInt16 = 36
    private static let keypadEnterKeyCode: UInt16 = 76

    var selectedIndices: Set<Int> = []
    var cursorIndex: Int?
    /// Range anchor for Shift-extension (mouse and keyboard). Tracks the row
    /// from which the current range was started — moves on plain/Cmd click and
    /// plain arrow navigation, stays put under Shift. Equivalent to Winamp's
    /// `shiftsel_1` in `Src/Winamp/Peui.cpp:411`; reused for keyboard
    /// extension per the TODO at `Src/Winamp/Pledit.cpp:1276` ("ideally need
    /// to keep a record of the 'current selection' so we can then adjust from
    /// there"), which Winamp itself never wired up.
    var anchorIndex: Int?
    /// Vertical scroll offset of the track list, in pixels. Shared between
    /// the ScrollView (`PlaylistTrackListView`), the gold-thumb slider
    /// (`PlaylistScrollSlider`), and the keyboard-cursor visibility check.
    /// Continuous so mouse-wheel scrolling moves the thumb smoothly and
    /// slider drags move the list smoothly.
    var scrollOffsetPixels: CGFloat = 0
    /// Pre-move insertion index for an in-flight Finder drop, or nil when
    /// nothing is being dragged over the playlist. Drives the row-gap
    /// highlight in `PlaylistTrackListView`.
    var dropIndex: Int?
    var dragStartSize: Size2D?
    var isDragging: Bool = false
    private(set) var resizePreview = WindowResizePreviewOverlay()
    private(set) var keyboardMonitor: Any?

    func installKeyboardMonitor(
        playlistWindow: @escaping () -> NSWindow?,
        playlistCount: @escaping () -> Int,
        visibleTrackCount: @escaping () -> Int,
        removeTrack: @escaping (Int) -> Void,
        playTrackAt: @escaping (Int) -> Void,
        cropToSelection: @escaping (Set<Int>) -> Void,
        clearPlaylist: @escaping () -> Void
    ) {
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Do NOT use `self?.handleKeyPress(...) ?? event`: Swift collapses
            // `self?.method() -> NSEvent?` to a single optional, so `?? event`
            // silently swaps an intentional `nil` (consume) back to the
            // original event and the monitor passes through.
            guard let self else { return event }
            let isPlaylistEvent = event.window != nil && event.window === playlistWindow()
            return self.handleKeyPress(
                event: event,
                isPlaylistKey: isPlaylistEvent,
                playlistCount: playlistCount(),
                visibleTrackCount: visibleTrackCount(),
                removeTrack: removeTrack,
                playTrackAt: playTrackAt,
                cropToSelection: cropToSelection,
                clearPlaylist: clearPlaylist
            )
        }
    }

    func removeKeyboardMonitor() {
        if let monitor = keyboardMonitor {
            NSEvent.removeMonitor(monitor)
            keyboardMonitor = nil
        }
    }

    func handleTrackTap(index: Int) {
        // Mirrors Winamp `do_lb` in Src/Winamp/Peui.cpp:413-456 (Winamp's
        // Ctrl maps to Cmd on Mac, where Ctrl-click is reserved for the
        // context menu). Plain or Cmd click moves the anchor; Shift-click
        // leaves the anchor in place and selects an inclusive range from it.
        let modifiers = NSEvent.modifierFlags.intersection([.command, .shift])
        let isShift = modifiers.contains(.shift)
        let isCmd = modifiers.contains(.command)

        if isShift, let anchor = anchorIndex {
            if !isCmd { selectedIndices = [] }
            let lo = min(anchor, index)
            let hi = max(anchor, index)
            for i in lo...hi { selectedIndices.insert(i) }
        } else if isCmd {
            if selectedIndices.contains(index) {
                selectedIndices.remove(index)
            } else {
                selectedIndices.insert(index)
            }
            anchorIndex = index
        } else {
            selectedIndices = [index]
            anchorIndex = index
        }
        cursorIndex = index
    }

    func handleKeyPress(
        event: NSEvent,
        isPlaylistKey: Bool,
        playlistCount: Int,
        visibleTrackCount: Int,
        removeTrack: (Int) -> Void,
        playTrackAt: (Int) -> Void,
        cropToSelection: (Set<Int>) -> Void = { _ in },
        clearPlaylist: () -> Void = {}
    ) -> NSEvent? {
        guard isPlaylistKey else { return event }

        let appModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

        // ⌘⌫ crop to the selection, ⌘⇧⌫ clear the list. Consumed here so the
        // chord never falls through to a global handler when the playlist is key.
        if event.keyCode == Self.deleteKeyCode || event.keyCode == Self.forwardDeleteKeyCode {
            if appModifiers == .command {
                if !selectedIndices.isEmpty { cropToSelection(selectedIndices) }
                selectedIndices = []
                cursorIndex = nil
                anchorIndex = nil
                return nil
            }
            if appModifiers == [.command, .shift] {
                clearPlaylist()
                selectedIndices = []
                cursorIndex = nil
                anchorIndex = nil
                return nil
            }
        }

        // ⌘A → Select All when the playlist is key (Webamp menuWa5.ts item
        // 40205). Outside the playlist, the same shortcut reaches Always On
        // Top via `AppCommands` (menuWa5.ts item 40019).
        if appModifiers == .command, event.keyCode == Self.aKeyCode {
            selectedIndices = Set(0..<playlistCount)
            cursorIndex = selectedIndices.min()
            anchorIndex = 0
            return nil
        }

        // Delete / Fwd-Delete → Remove selected tracks (`menuWa5.ts` item 1034).
        // Consume the event even when nothing is selected so empty-selection
        // presses don't beep.
        if appModifiers.isEmpty,
           event.keyCode == Self.deleteKeyCode || event.keyCode == Self.forwardDeleteKeyCode {
            for index in selectedIndices.sorted(by: >) {
                removeTrack(index)
            }
            selectedIndices = []
            cursorIndex = nil
            anchorIndex = nil
            return nil
        }

        if event.keyCode == Self.escapeKeyCode {
            selectedIndices = []
            cursorIndex = nil
            anchorIndex = nil
            return nil
        }

        // Navigation keys — playlist-scoped, Shift extends the range from the
        // anchor (the "shrink on reverse direction" behavior `Pledit.cpp:1276`
        // wanted but never implemented). Consume even on an empty playlist so
        // an idle press doesn't beep.
        let nonShiftModifiers = appModifiers.subtracting(.shift)
        let isShiftHeld = appModifiers.contains(.shift)
        if nonShiftModifiers.isEmpty {
            switch event.keyCode {
            case Self.upArrowKeyCode:
                moveCursor(by: -1, isShiftHeld: isShiftHeld, playlistCount: playlistCount, visibleTrackCount: visibleTrackCount)
                return nil
            case Self.downArrowKeyCode:
                moveCursor(by: +1, isShiftHeld: isShiftHeld, playlistCount: playlistCount, visibleTrackCount: visibleTrackCount)
                return nil
            case Self.pageUpKeyCode:
                moveCursor(by: -max(1, visibleTrackCount), isShiftHeld: isShiftHeld, playlistCount: playlistCount, visibleTrackCount: visibleTrackCount)
                return nil
            case Self.pageDownKeyCode:
                moveCursor(by: +max(1, visibleTrackCount), isShiftHeld: isShiftHeld, playlistCount: playlistCount, visibleTrackCount: visibleTrackCount)
                return nil
            case Self.homeKeyCode:
                setCursor(to: 0, isShiftHeld: isShiftHeld, playlistCount: playlistCount, visibleTrackCount: visibleTrackCount)
                return nil
            case Self.endKeyCode:
                setCursor(to: playlistCount - 1, isShiftHeld: isShiftHeld, playlistCount: playlistCount, visibleTrackCount: visibleTrackCount)
                return nil
            default:
                break
            }
        }

        if appModifiers.isEmpty,
           event.keyCode == Self.returnKeyCode || event.keyCode == Self.keypadEnterKeyCode {
            if let target = cursorIndex ?? selectedIndices.min() {
                playTrackAt(target)
            }
            return nil
        }

        return event
    }

    private func moveCursor(by delta: Int, isShiftHeld: Bool, playlistCount: Int, visibleTrackCount: Int) {
        guard playlistCount > 0 else { return }
        // Cold start (no cursor): Down/PgDn/End land on the first row, Up/PgUp
        // land on the last row — matches Finder list-view convention.
        let current: Int = cursorIndex ?? (delta > 0 ? -1 : playlistCount)
        setCursor(to: current + delta, isShiftHeld: isShiftHeld, playlistCount: playlistCount, visibleTrackCount: visibleTrackCount)
    }

    private func setCursor(to index: Int, isShiftHeld: Bool, playlistCount: Int, visibleTrackCount: Int) {
        guard playlistCount > 0 else { return }
        let clamped = max(0, min(playlistCount - 1, index))
        cursorIndex = clamped
        if isShiftHeld, let anchor = anchorIndex {
            let lo = min(anchor, clamped)
            let hi = max(anchor, clamped)
            selectedIndices = Set(lo...hi)
        } else {
            selectedIndices = [clamped]
            anchorIndex = clamped
        }
        ensureCursorVisible(visibleTrackCount: visibleTrackCount, playlistCount: playlistCount)
    }

    private func ensureCursorVisible(visibleTrackCount: Int, playlistCount: Int) {
        guard let cursor = cursorIndex, visibleTrackCount > 0 else { return }
        let rowHeight = PlaylistWindowSizeState.trackRowHeight
        let cursorTop = CGFloat(cursor) * rowHeight
        let cursorBottom = cursorTop + rowHeight
        let viewportTop = scrollOffsetPixels
        let viewportBottom = viewportTop + CGFloat(visibleTrackCount) * rowHeight
        if cursorTop < viewportTop {
            scrollOffsetPixels = cursorTop
        } else if cursorBottom > viewportBottom {
            scrollOffsetPixels = cursorBottom - CGFloat(visibleTrackCount) * rowHeight
        }
    }

    func clampScrollOffset(maxOffsetPixels: CGFloat) {
        if scrollOffsetPixels > maxOffsetPixels {
            scrollOffsetPixels = max(0, maxOffsetPixels)
        }
        if scrollOffsetPixels < 0 {
            scrollOffsetPixels = 0
        }
    }
}
