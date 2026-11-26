import AppKit

enum WinampAlertHelper {
    typealias ModalRunner = @MainActor (NSAlert) -> NSApplication.ModalResponse
    typealias SheetRunner = @MainActor (NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void

    /// Presents a single-button notice with Return acceptance and Escape dismissal.
    @MainActor
    static func present(
        _ alert: NSAlert,
        sheetFor parent: NSWindow? = nil,
        monitors: LocalEventMonitorRegistration = .appKit,
        run: ModalRunner = runModal,
        beginSheet: SheetRunner = beginSheetModal,
        completion: @escaping (NSApplication.ModalResponse) -> Void = { _ in }
    ) {
        precondition(alert.buttons.count == 1)
        let cancellation = AlertEscapeCancellation(alert: alert, monitors: monitors)
        if let parent {
            beginSheet(alert, parent) { response in
                cancellation.invalidate()
                completion(response)
            }
        } else {
            let response = run(alert)
            cancellation.invalidate()
            completion(response)
        }
    }

    @MainActor
    private static func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        guard !UnitTestSupport.isActive else { return .abort }
        return alert.runModal()
    }

    @MainActor
    private static func beginSheetModal(
        _ alert: NSAlert, _ parent: NSWindow, completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        guard !UnitTestSupport.isActive else { completion(.abort); return }
        alert.beginSheetModal(for: parent, completionHandler: completion)
    }

    /// Show a simple informational alert with OK button.
    @MainActor
    static func showInfo(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        present(alert)
    }

    /// Show an error/warning alert with OK button.
    @MainActor
    static func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        present(alert)
    }
}
