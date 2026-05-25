import AppKit

/// Window Focus Delegate - Updates WindowFocusState when windows gain/lose focus
/// Follows WindowPersistenceDelegate pattern from WindowCoordinator
/// Part of Bridge layer - wired through WindowDelegateMultiplexer
@MainActor
final class WindowFocusDelegate: NSObject, NSWindowDelegate {
    private let kind: WindowKind
    private let focusState: WindowFocusState
    private let zOrderController: WindowZOrderController

    init(kind: WindowKind, focusState: WindowFocusState, zOrderController: WindowZOrderController) {
        self.kind = kind
        self.focusState = focusState
        self.zOrderController = zOrderController
        super.init()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Reset all focus states, then set this window as focused
        focusState.isMainKey = (kind == .main)
        focusState.isEqualizerKey = (kind == .equalizer)
        focusState.isPlaylistKey = (kind == .playlist)
        focusState.isVideoKey = (kind == .video)
        focusState.isMilkdropKey = (kind == .milkdrop)

        // Keep MacAmp's windows visually grouped: lift all visible siblings
        // above any non-MacAmp windows that may have been overlapping them.
        let keyWindow = notification.object as? NSWindow
        zOrderController.bringAllWindowsForward(keyWindow: keyWindow)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Window lost focus - set its state to false
        switch kind {
        case .main:
            focusState.isMainKey = false
        case .equalizer:
            focusState.isEqualizerKey = false
        case .playlist:
            focusState.isPlaylistKey = false
        case .video:
            focusState.isVideoKey = false
        case .milkdrop:
            focusState.isMilkdropKey = false
        }
    }
}
