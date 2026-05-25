import SwiftUI
import AppKit

@MainActor
@Observable
final class PlaylistWindowInteractionState {
    private static let escapeKeyCode: UInt16 = 53
    private static let aKeyCode: UInt16 = 0
    private static let deleteKeyCode: UInt16 = 51         // kVK_Delete (Backspace, the "delete" key on Mac laptops)
    private static let forwardDeleteKeyCode: UInt16 = 117 // kVK_ForwardDelete (full keyboards)
    var selectedIndices: Set<Int> = []
    var isShadeMode: Bool = false
    var scrollOffset: Int = 0
    var dragStartSize: Size2D?
    var isDragging: Bool = false
    private(set) var resizePreview = WindowResizePreviewOverlay()
    private(set) var keyboardMonitor: Any?

    func installKeyboardMonitor(
        playlistWindow: @escaping () -> NSWindow?,
        playlistCount: @escaping () -> Int,
        removeTrack: @escaping (Int) -> Void
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
                removeTrack: removeTrack
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
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.shift) {
            if selectedIndices.contains(index) {
                selectedIndices.remove(index)
            } else {
                selectedIndices.insert(index)
            }
        } else {
            selectedIndices = [index]
        }
    }

    func handleKeyPress(
        event: NSEvent,
        isPlaylistKey: Bool,
        playlistCount: Int,
        removeTrack: (Int) -> Void
    ) -> NSEvent? {
        guard isPlaylistKey else { return event }

        let appModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

        // ⌘A → Select All when the playlist is key (Webamp menuWa5.ts item
        // 40205). Outside the playlist, the same shortcut reaches Always On
        // Top via `AppCommands` (menuWa5.ts item 40019).
        if appModifiers == .command, event.keyCode == Self.aKeyCode {
            selectedIndices = Set(0..<playlistCount)
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
            return nil
        }

        if event.keyCode == Self.escapeKeyCode {
            selectedIndices = []
            return nil
        }

        return event
    }

    func clampScrollOffset(maxOffset: Int) {
        if scrollOffset > maxOffset {
            scrollOffset = maxOffset
        }
    }
}
